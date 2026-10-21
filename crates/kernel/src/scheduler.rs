// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Dequeue policy: effective priority across owners, owner rotation at ties.
//!
//! The effective priority of a queued task is `weight(priority) + age / AGING_STEP`.
//! A worker takes a task with the highest effective priority of its class. Among
//! owners holding such a task, it rotates to the next owner ID after the previous
//! pick; within that owner, FIFO order breaks ties.
//!
//! Liveness: every queued task gains one point per `AGING_STEP`, and weights differ
//! by at most `weight(High) - weight(Low) = 2`. A task therefore outranks every task
//! admitted more than two steps after it, and waits only for the finitely many
//! tasks admitted before that point (admission is bounded). No task starves while
//! workers of its class keep dequeuing.

use crate::{Owner, Task};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// One point of effective priority per this much queue age.
pub(crate) const AGING_STEP: Duration = Duration::from_millis(50);

/// The worker pool that runs a job.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum WorkClass {
    /// Bounded computation. The default.
    #[default]
    Cpu,
    /// Blocking I/O, served by a separate pool so it cannot occupy CPU workers.
    Io,
}

/// Dequeue preference; queue age raises it over time (see `JobOptions`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Priority {
    /// Weight 0.
    Low,
    /// Weight 1. The default.
    #[default]
    Normal,
    /// Weight 2.
    High,
}

impl Priority {
    fn weight(self) -> u128 {
        match self {
            Self::Low => 0,
            Self::Normal => 1,
            Self::High => 2,
        }
    }
}

/// Scheduling options of one submission.
///
/// Workers of a class take the queued task with the highest effective priority,
/// `weight(priority) + queue_age / 50 ms`, across all owners. Owners holding such
/// a task take turns in ID order; FIFO order breaks ties within an owner. Aging
/// bounds the wait of every task, so a stream of `High` work cannot starve `Low`.
#[derive(Clone, Copy, Debug, Default)]
pub struct JobOptions {
    /// Worker pool that runs the job.
    pub class: WorkClass,
    /// Dequeue preference within the pool.
    pub priority: Priority,
}

/// One value per work class.
#[derive(Debug, Default)]
pub(crate) struct PerClass<T> {
    cpu: T,
    io: T,
}

impl<T> PerClass<T> {
    pub(crate) fn get(&self, class: WorkClass) -> &T {
        match class {
            WorkClass::Cpu => &self.cpu,
            WorkClass::Io => &self.io,
        }
    }

    pub(crate) fn get_mut(&mut self, class: WorkClass) -> &mut T {
        match class {
            WorkClass::Cpu => &mut self.cpu,
            WorkClass::Io => &mut self.io,
        }
    }
}

/// Workers parked without a task, per class.
///
/// Invariant: a worker is listed only while it holds no task and no submitter has
/// claimed it. A worker lists itself only while holding the state lock right after
/// observing no queued task of its class, and unlists itself whenever it re-acquires
/// the lock. A submitter that finds the list empty therefore knows that every worker
/// of the class is running a task or is awake and will re-check the queue before
/// parking, so a queued task never waits while a worker of its class sleeps.
#[derive(Debug, Default)]
pub(crate) struct IdleWorkers(PerClass<Vec<usize>>);

impl IdleWorkers {
    pub(crate) fn register(&mut self, class: WorkClass, worker: usize) {
        let idle = self.0.get_mut(class);
        if !idle.contains(&worker) {
            idle.push(worker);
        }
    }

    pub(crate) fn forget(&mut self, class: WorkClass, worker: usize) {
        self.0.get_mut(class).retain(|listed| *listed != worker);
    }

    /// Claim one idle worker of `class` to wake for a new task.
    pub(crate) fn claim(&mut self, class: WorkClass) -> Option<usize> {
        self.0.get_mut(class).pop()
    }

    #[cfg(test)]
    pub(crate) fn count(&self, class: WorkClass) -> usize {
        self.0.get(class).len()
    }
}

fn effective_priority(task: &Task, now: Instant) -> u128 {
    let age = now.saturating_duration_since(task.submitted).as_millis();
    task.options
        .priority
        .weight()
        .saturating_add(age.checked_div(AGING_STEP.as_millis()).unwrap_or(0))
}

/// The owner after `previous` in cyclic ID order among `owners`.
fn next_owner(
    owners: impl Iterator<Item = Owner> + Clone,
    previous: Option<Owner>,
) -> Option<Owner> {
    owners
        .clone()
        .filter(|owner| previous.is_none_or(|last| *owner > last))
        .min()
        .or_else(|| owners.min())
}

/// Index of the task a worker of `class` takes at `now`.
fn select(
    queue: &VecDeque<Task>,
    class: WorkClass,
    previous: Option<Owner>,
    now: Instant,
) -> Option<usize> {
    let eligible = || {
        queue
            .iter()
            .enumerate()
            .filter(|(_, task)| task.options.class == class)
    };
    let best = eligible()
        .map(|(_, task)| effective_priority(task, now))
        .max()?;
    let top = || eligible().filter(move |(_, task)| effective_priority(task, now) == best);
    let owner = next_owner(top().map(|(_, task)| task.owner), previous)?;
    top()
        .find(|(_, task)| task.owner == owner)
        .map(|(index, _)| index)
}

/// Remove and return the next task of `class`, advancing that class's owner cursor.
pub(crate) fn take_at(
    queue: &mut VecDeque<Task>,
    cursors: &mut PerClass<Option<Owner>>,
    class: WorkClass,
    now: Instant,
) -> Option<Task> {
    let index = select(queue, class, *cursors.get(class), now)?;
    let task = queue.remove(index)?;
    *cursors.get_mut(class) = Some(task.owner);
    Some(task)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task(id: u64, owner: Owner, priority: Priority, age_ms: u64, now: Instant) -> Task {
        Task {
            id,
            owner,
            input: vec![],
            job: Box::new(|_, _| Ok(vec![])),
            options: JobOptions {
                class: WorkClass::Cpu,
                priority,
            },
            submitted: now - Duration::from_millis(age_ms),
        }
    }

    fn order(tasks: Vec<Task>, now: Instant) -> Vec<u64> {
        let mut queue: VecDeque<Task> = tasks.into();
        let mut cursors = PerClass::default();
        std::iter::from_fn(|| take_at(&mut queue, &mut cursors, WorkClass::Cpu, now))
            .map(|task| task.id)
            .collect()
    }

    fn step_ms() -> u64 {
        AGING_STEP.as_millis() as u64
    }

    #[test]
    fn high_priority_of_one_owner_does_not_wait_for_other_owners_turns() {
        let now = Instant::now();
        let ids = order(
            vec![
                task(1, 1, Priority::Normal, 0, now),
                task(2, 2, Priority::Normal, 0, now),
                task(3, 3, Priority::High, 0, now),
            ],
            now,
        );
        assert_eq!(ids, vec![3, 1, 2]);
    }

    #[test]
    fn equal_effective_priority_rotates_owners_and_keeps_fifo_within_owner() {
        let now = Instant::now();
        let ids = order(
            vec![
                task(1, 1, Priority::Normal, 0, now),
                task(2, 1, Priority::Normal, 0, now),
                task(3, 2, Priority::Normal, 0, now),
                task(4, 3, Priority::Normal, 0, now),
                task(5, 2, Priority::Normal, 0, now),
            ],
            now,
        );
        assert_eq!(ids, vec![1, 3, 4, 2, 5]);
    }

    #[test]
    fn aging_lets_old_low_priority_work_outrank_new_high_priority_work() {
        let now = Instant::now();
        // Low aged by three steps scores 3; fresh High scores 2.
        let ids = order(
            vec![
                task(1, 1, Priority::High, 0, now),
                task(2, 2, Priority::Low, 3 * step_ms(), now),
                task(3, 1, Priority::High, 0, now),
            ],
            now,
        );
        assert_eq!(ids, vec![2, 1, 3]);
        // Two steps tie with High; rotation then decides by owner order.
        let ids = order(
            vec![
                task(1, 2, Priority::High, 0, now),
                task(2, 1, Priority::Low, 2 * step_ms(), now),
            ],
            now,
        );
        assert_eq!(ids, vec![2, 1]);
    }

    // Liveness witness: under an overload of fresh High work from many owners
    // (four arrivals, one dequeue per step), the Low task is dequeued before any
    // High task admitted more than weight(High) - weight(Low) steps after it.
    #[test]
    fn low_priority_task_is_not_starved_by_a_stream_of_high_priority_work() {
        let start = Instant::now();
        let mut queue: VecDeque<Task> = VecDeque::new();
        queue.push_back(task(0, 99, Priority::Low, 0, start));
        let mut cursors = PerClass::default();
        let mut next_id = 1;
        for tick in 0..40u64 {
            let now = start + Duration::from_millis(tick * step_ms());
            for owner in 0..4 {
                queue.push_back(task(next_id, owner, Priority::High, 0, now));
                next_id += 1;
            }
            let taken = take_at(&mut queue, &mut cursors, WorkClass::Cpu, now).unwrap();
            if taken.id == 0 {
                return;
            }
            let admitted_tick = (taken.id - 1) / 4;
            assert!(
                admitted_tick <= 2,
                "High from tick {admitted_tick} overtook Low"
            );
        }
        panic!("Low task starved");
    }

    #[test]
    fn classes_are_scheduled_independently() {
        let now = Instant::now();
        let mut queue: VecDeque<Task> = vec![task(1, 1, Priority::High, 0, now)].into();
        let mut cursors = PerClass::default();
        assert!(take_at(&mut queue, &mut cursors, WorkClass::Io, now).is_none());
        assert_eq!(cursors.get(WorkClass::Io), &None);
        assert_eq!(
            take_at(&mut queue, &mut cursors, WorkClass::Cpu, now)
                .unwrap()
                .id,
            1
        );
        assert_eq!(cursors.get(WorkClass::Cpu), &Some(1));
    }

    #[test]
    fn idle_workers_are_claimed_per_class_without_duplicates() {
        let mut idle = IdleWorkers::default();
        idle.register(WorkClass::Cpu, 0);
        idle.register(WorkClass::Cpu, 0);
        idle.register(WorkClass::Io, 2);
        assert_eq!(idle.count(WorkClass::Cpu), 1);
        assert_eq!(idle.claim(WorkClass::Cpu), Some(0));
        assert_eq!(idle.claim(WorkClass::Cpu), None);
        idle.forget(WorkClass::Io, 2);
        assert_eq!(idle.claim(WorkClass::Io), None);
    }
}
