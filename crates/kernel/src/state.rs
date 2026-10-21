// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! The admission table and its transitions. No locks, threads, clocks or IO: the
//! caller passes the time, and the only shared effect is the cancellation flag a
//! record shares with its job's `Context`.
//!
//! Each accepted request is in exactly one phase:
//!
//! - `Queued`: its task is in `queue`; it holds a slot and its full reservation.
//! - `Running`: a worker owns its task; it may have chunks in `ready`.
//! - `Finished`: its final event is in `ready`; it keeps slot and reservation
//!   until the frontend drains that event.
//! - released: a cancelled request whose final `Cancelled` (or `Panicked`) event is
//!   in `ready`. Its record is gone; it holds only `Usage::released()`, charged to
//!   the event's owner, and is counted in `released_finals`.
//!
//! `audit` states the full invariant; every transition preserves it.

use crate::ledger::{Ledger, Limits, Usage};
use crate::scheduler::{self, IdleWorkers, JobOptions, PerClass, WorkClass};
use crate::{
    Context, Error, Event, JobFailed, Outcome, Owner, Rejected, RequestId, EVENT_OVERHEAD,
};
use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub(crate) type Job = Box<dyn FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send>;

/// A queued job and its owned input.
pub(crate) struct Task {
    pub(crate) id: RequestId,
    pub(crate) owner: Owner,
    pub(crate) input: Vec<u8>,
    pub(crate) job: Job,
    pub(crate) options: JobOptions,
    pub(crate) submitted: Instant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Phase {
    Queued,
    Running,
    Finished,
}

impl Phase {
    /// Whether the request can still be cancelled.
    pub(crate) fn is_live(self) -> bool {
        matches!(self, Self::Queued | Self::Running)
    }
}

pub(crate) struct Record {
    pub(crate) owner: Owner,
    pub(crate) generation: u64,
    pub(crate) cancelled: Arc<AtomicBool>,
    pub(crate) output_limit: usize,
    pub(crate) charge: Usage,
    pub(crate) phase: Phase,
}

impl Record {
    pub(crate) fn cancel_requested(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    /// Whether the request's worker may still publish chunks.
    pub(crate) fn accepts_chunks(&self) -> bool {
        self.phase == Phase::Running
    }

    pub(crate) fn belongs_to(&self, owner: Owner) -> bool {
        self.owner == owner
    }

    /// Whether `supersede(owner, generation)` invalidates this request.
    pub(crate) fn is_superseded_by(&self, owner: Owner, generation: u64) -> bool {
        self.belongs_to(owner) && self.generation < generation
    }
}

/// Monotone counters and high-water marks.
#[derive(Debug, Default)]
pub(crate) struct Metrics {
    pub(crate) queue_high_water: usize,
    pub(crate) reserved_high_water: usize,
    pub(crate) stream_items_high_water: usize,
    pub(crate) stream_bytes_high_water: usize,
    pub(crate) completed: u64,
    pub(crate) cancelled: u64,
    pub(crate) failed: u64,
    pub(crate) panicked: u64,
    pub(crate) max_queue_wait: Duration,
    pub(crate) max_run_time: Duration,
}

impl Metrics {
    pub(crate) fn record_final(&mut self, outcome: &Outcome) {
        self.completed = self.completed.saturating_add(1);
        let counter = match outcome {
            Outcome::Cancelled => &mut self.cancelled,
            Outcome::Failed => &mut self.failed,
            Outcome::Panicked => &mut self.panicked,
            Outcome::Chunk { .. } | Outcome::Success(_) | Outcome::OutputTooLarge => return,
        };
        *counter = counter.saturating_add(1);
    }

    fn observe(&mut self, usage: Usage, queued: usize) {
        self.queue_high_water = self.queue_high_water.max(queued);
        self.reserved_high_water = self.reserved_high_water.max(usage.reserved);
        self.stream_items_high_water = self.stream_items_high_water.max(usage.stream_items);
        self.stream_bytes_high_water = self.stream_bytes_high_water.max(usage.stream_bytes);
    }
}

/// What a worker needs to run a dequeued task.
pub(crate) struct Started {
    pub(crate) cancelled: Arc<AtomicBool>,
    pub(crate) output_limit: usize,
}

/// Storage charge of a chunk payload: allocation capacity plus the event charge.
pub(crate) fn chunk_cost(capacity: usize) -> Option<usize> {
    EVENT_OVERHEAD.checked_add(capacity)
}

/// Ledger charge of a chunk already stored in `ready`. Its cost was checked when it
/// was published, so the saturating fallback is never taken.
pub(crate) fn stored_chunk(capacity: usize) -> Usage {
    Usage::chunk(chunk_cost(capacity).unwrap_or(usize::MAX))
}

pub(crate) struct State {
    pub(crate) epoch: u64,
    pub(crate) limits: Limits,
    next_id: RequestId,
    pub(crate) records: BTreeMap<RequestId, Record>,
    pub(crate) queue: VecDeque<Task>,
    pub(crate) ready: VecDeque<Event>,
    pub(crate) ledger: Ledger,
    /// Undrained final events of released requests.
    pub(crate) released_finals: usize,
    pub(crate) cursors: PerClass<Option<Owner>>,
    pub(crate) idle: IdleWorkers,
    pub(crate) metrics: Metrics,
}

impl State {
    pub(crate) fn new(epoch: u64, limits: Limits) -> Self {
        Self {
            epoch,
            limits,
            next_id: 1,
            records: BTreeMap::new(),
            queue: VecDeque::new(),
            ready: VecDeque::new(),
            ledger: Ledger::default(),
            released_finals: 0,
            cursors: PerClass::default(),
            idle: IdleWorkers::default(),
            metrics: Metrics::default(),
        }
    }

    /// Accepted requests whose final outcome has not been drained.
    pub(crate) fn outstanding(&self) -> usize {
        self.records.len().saturating_add(self.released_finals)
    }

    pub(crate) fn has_ready(&self) -> bool {
        !self.ready.is_empty()
    }

    pub(crate) fn event(&self, id: RequestId, record: &Record, outcome: Outcome) -> Event {
        Event {
            epoch: self.epoch,
            request: id,
            owner: record.owner,
            generation: record.generation,
            outcome,
        }
    }

    /// Admit a request, or hand job and input back with the reason.
    ///
    /// Post (Ok): a `Queued` record and its task exist, and the owner is charged
    /// `Usage::request(input capacity + max_output_bytes + EVENT_OVERHEAD)`.
    #[allow(
        clippy::too_many_arguments,
        reason = "mirrors Kernel::try_submit_with_options plus the clock"
    )]
    pub(crate) fn admit<F>(
        &mut self,
        owner: Owner,
        generation: u64,
        input: Vec<u8>,
        max_output_bytes: usize,
        options: JobOptions,
        job: F,
        now: Instant,
    ) -> Result<RequestId, Rejected<F>>
    where
        F: FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send + 'static,
    {
        let reservation = input
            .capacity()
            .checked_add(max_output_bytes)
            .and_then(|bytes| bytes.checked_add(EVENT_OVERHEAD));
        let charge = match reservation {
            Some(reservation) => Usage::request(reservation),
            None => return Err(Rejected::new(Error::Capacity, input, job)),
        };
        if !self
            .ledger
            .admits(owner, Usage::default(), charge, &self.limits)
        {
            return Err(Rejected::new(Error::Capacity, input, job));
        }
        let id = self.next_id;
        let Some(next_id) = id.checked_add(1) else {
            return Err(Rejected::new(Error::IdExhausted, input, job));
        };
        // Allocate first: a failed allocation must leave the counters unchanged.
        self.queue.push_back(Task {
            id,
            owner,
            input,
            job: Box::new(job),
            options,
            submitted: now,
        });
        self.records.insert(
            id,
            Record {
                owner,
                generation,
                cancelled: Arc::new(AtomicBool::new(false)),
                output_limit: max_output_bytes,
                charge,
                phase: Phase::Queued,
            },
        );
        self.next_id = next_id;
        self.ledger.add(owner, charge);
        self.metrics.observe(self.ledger.total(), self.queue.len());
        Ok(id)
    }

    /// Dequeue the next task of `class` and mark it `Running`.
    ///
    /// `Err(task)` hands back a task without a `Queued` record; that would violate
    /// the invariant, so the worker only drops it.
    pub(crate) fn start(
        &mut self,
        class: WorkClass,
        now: Instant,
    ) -> Option<Result<(Task, Started), Task>> {
        let task = scheduler::take_at(&mut self.queue, &mut self.cursors, class, now)?;
        let Some(record) = self
            .records
            .get_mut(&task.id)
            .filter(|record| record.phase == Phase::Queued)
        else {
            return Some(Err(task));
        };
        record.phase = Phase::Running;
        let started = Started {
            cancelled: Arc::clone(&record.cancelled),
            output_limit: record.output_limit,
        };
        let wait = now.saturating_duration_since(task.submitted);
        self.metrics.max_queue_wait = self.metrics.max_queue_wait.max(wait);
        Some(Ok((task, started)))
    }

    /// Pop events within an item and byte budget, releasing what they held.
    ///
    /// A first event larger than `max_bytes` stays queued and is reported as
    /// `DrainBudget`; later events never overtake it.
    pub(crate) fn drain(
        &mut self,
        max_items: usize,
        max_bytes: usize,
    ) -> Result<Vec<Event>, Error> {
        let mut events = Vec::new();
        let mut remaining = max_bytes;
        while events.len() < max_items {
            let Some(cost) = self.ready.front().map(Event::byte_cost) else {
                break;
            };
            if cost > remaining {
                if events.is_empty() {
                    return Err(Error::DrainBudget { required: cost });
                }
                break;
            }
            let Some(event) = self.ready.pop_front() else {
                break;
            };
            self.release_drained(&event);
            remaining = remaining.saturating_sub(cost);
            events.push(event);
        }
        Ok(events)
    }

    fn release_drained(&mut self, event: &Event) {
        match &event.outcome {
            Outcome::Chunk { bytes, .. } => {
                self.ledger.sub(event.owner, stored_chunk(bytes.capacity()));
            }
            _ => match self.records.remove(&event.request) {
                Some(record) => self.ledger.sub(record.owner, record.charge),
                None => {
                    self.released_finals = self.released_finals.saturating_sub(1);
                    self.ledger.sub(event.owner, Usage::released());
                }
            },
        }
    }

    /// Append a chunk of a running request, or replace its keyed predecessor.
    ///
    /// A replacement removes the old chunk and appends the new one, so it is
    /// ordered after everything emitted before it.
    /// Post (Ok): the ledger charges exactly the chunks in `ready`; the replaced
    /// event, if any, is returned so the caller can drop it outside the lock.
    pub(crate) fn push_chunk(
        &mut self,
        id: RequestId,
        key: Option<u64>,
        bytes: Vec<u8>,
    ) -> Result<Option<Event>, PushRefused> {
        let Some(cost) = chunk_cost(bytes.capacity())
            .filter(|cost| self.limits.could_ever_admit(Usage::chunk(*cost)))
        else {
            return Err(PushRefused::TooLarge(bytes));
        };
        let Some(record) = self
            .records
            .get(&id)
            .filter(|record| record.accepts_chunks())
        else {
            return Err(PushRefused::Closed(bytes));
        };
        let owner = record.owner;
        let replaced = key.and_then(|key| self.replaceable(id, key));
        let release =
            replaced
                .and_then(|index| self.ready.get(index))
                .map_or(Usage::default(), |event| match &event.outcome {
                    Outcome::Chunk { bytes, .. } => stored_chunk(bytes.capacity()),
                    _ => Usage::default(),
                });
        let charge = Usage::chunk(cost);
        if !self.ledger.admits(owner, release, charge, &self.limits) {
            return Err(PushRefused::Full(bytes));
        }
        let event = self.event(id, record, Outcome::Chunk { key, bytes });
        let old = replaced.and_then(|index| self.ready.remove(index));
        self.ready.push_back(event);
        self.ledger.sub(owner, release);
        self.ledger.add(owner, charge);
        self.metrics.observe(self.ledger.total(), self.queue.len());
        Ok(old)
    }

    /// Index of an undrained chunk of request `id` with the same replacement key.
    fn replaceable(&self, id: RequestId, key: u64) -> Option<usize> {
        self.ready.iter().position(|event| {
            event.request == id
                && matches!(&event.outcome, Outcome::Chunk { key: Some(old), .. } if *old == key)
        })
    }
}

/// Why a chunk was not published; the payload goes back to the adapter.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PushRefused {
    /// The chunk exceeds a global or per-owner stream limit on its own.
    TooLarge(Vec<u8>),
    /// The request is not running.
    Closed(Vec<u8>),
    /// Global or per-owner stream capacity is exhausted for now.
    Full(Vec<u8>),
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::Config;

    pub(crate) fn state(config: Config) -> State {
        State::new(1, Limits::from_config(&config))
    }

    pub(crate) fn admit(state: &mut State, owner: Owner, generation: u64) -> RequestId {
        admit_class(state, owner, generation, WorkClass::Cpu)
    }

    pub(crate) fn admit_class(
        state: &mut State,
        owner: Owner,
        generation: u64,
        class: WorkClass,
    ) -> RequestId {
        let options = JobOptions {
            class,
            ..JobOptions::default()
        };
        let result = state.admit(
            owner,
            generation,
            vec![],
            0,
            options,
            |_, _| Ok(vec![]),
            Instant::now(),
        );
        let id = result.map_err(|rejected| rejected.error).unwrap();
        state.audit().unwrap();
        id
    }

    pub(crate) fn run(state: &mut State) -> RequestId {
        let (task, _) = state
            .start(WorkClass::Cpu, Instant::now())
            .unwrap()
            .ok()
            .unwrap();
        state.audit().unwrap();
        task.id
    }

    #[test]
    fn admission_charges_slot_bytes_and_owner_quota() {
        let mut state = state(Config {
            max_requests_per_owner: 1,
            ..Config::default()
        });
        admit(&mut state, 1, 0);
        assert_eq!(state.ledger.owner(1), Usage::request(EVENT_OVERHEAD));
        let rejected = state
            .admit(
                1,
                0,
                vec![7; 3],
                0,
                JobOptions::default(),
                |_, _| Ok(vec![]),
                Instant::now(),
            )
            .unwrap_err();
        assert_eq!(rejected.error, Error::Capacity);
        assert_eq!(rejected.input, vec![7; 3]);
        admit(&mut state, 2, 0);
        assert_eq!(state.outstanding(), 2);
    }

    #[test]
    fn per_owner_reserved_bytes_are_enforced_at_admission() {
        let mut state = state(Config {
            max_reserved_bytes_per_owner: 2 * EVENT_OVERHEAD + 10,
            ..Config::default()
        });
        let submit = |state: &mut State, owner, output| {
            state
                .admit(
                    owner,
                    0,
                    vec![],
                    output,
                    JobOptions::default(),
                    |_, _| Ok(vec![]),
                    Instant::now(),
                )
                .map_err(|rejected| rejected.error)
        };
        submit(&mut state, 1, 10).unwrap();
        assert_eq!(submit(&mut state, 1, 1), Err(Error::Capacity));
        submit(&mut state, 1, 0).unwrap();
        submit(&mut state, 2, 10).unwrap();
        state.audit().unwrap();
    }

    #[test]
    fn overflowing_reservation_is_capacity_not_a_panic() {
        let mut state = state(Config::default());
        let rejected = state
            .admit(
                1,
                0,
                vec![],
                usize::MAX,
                JobOptions::default(),
                |_, _| Ok(vec![]),
                Instant::now(),
            )
            .unwrap_err();
        assert_eq!(rejected.error, Error::Capacity);
    }

    #[test]
    fn drain_releases_finished_reservations_and_chunk_budget() {
        let mut state = state(Config::default());
        let id = admit(&mut state, 1, 0);
        run(&mut state);
        state.push_chunk(id, None, vec![1, 2]).unwrap();
        assert_eq!(state.ledger.owner(1).stream_bytes, EVENT_OVERHEAD + 2);
        assert!(state.commit(id, Outcome::Success(vec![]), false, Duration::ZERO));
        state.audit().unwrap();
        let events = state.drain(1, EVENT_OVERHEAD + 2).unwrap();
        assert!(matches!(events[0].outcome, Outcome::Chunk { .. }));
        assert_eq!(state.ledger.owner(1).stream_items, 0);
        assert_eq!(
            state.drain(1, EVENT_OVERHEAD - 1),
            Err(Error::DrainBudget {
                required: EVENT_OVERHEAD
            })
        );
        assert_eq!(state.drain(4, 4096).unwrap().len(), 1);
        assert_eq!(state.ledger, Ledger::default());
        state.audit().unwrap();
    }

    // Regression: replace(7, P2) after [P1(key 7), C] must deliver C before P2.
    #[test]
    fn replacement_is_ordered_after_everything_emitted_before_it() {
        let mut state = state(Config::default());
        let id = admit(&mut state, 1, 0);
        run(&mut state);
        state.push_chunk(id, Some(7), vec![1; 8]).unwrap();
        state.push_chunk(id, None, vec![2]).unwrap();
        let old = state.push_chunk(id, Some(7), vec![3]).unwrap();
        assert!(matches!(
            old,
            Some(Event {
                outcome: Outcome::Chunk { key: Some(7), .. },
                ..
            })
        ));
        state.audit().unwrap();
        assert_eq!(
            state.ledger.owner(1),
            Usage {
                requests: 1,
                reserved: EVENT_OVERHEAD,
                stream_items: 2,
                stream_bytes: 2 * (EVENT_OVERHEAD + 1),
            }
        );
        let payloads: Vec<_> = state
            .drain(8, 4096)
            .unwrap()
            .into_iter()
            .map(|event| event.outcome)
            .collect();
        assert_eq!(
            payloads,
            vec![
                Outcome::Chunk {
                    key: None,
                    bytes: vec![2]
                },
                Outcome::Chunk {
                    key: Some(7),
                    bytes: vec![3]
                },
            ]
        );
    }

    #[test]
    fn per_owner_stream_quota_refuses_one_owner_but_not_another() {
        let mut state = state(Config {
            max_stream_items_per_owner: 1,
            max_stream_bytes_per_owner: EVENT_OVERHEAD + 4,
            ..Config::default()
        });
        let first = admit(&mut state, 1, 0);
        let second = admit(&mut state, 2, 0);
        run(&mut state);
        run(&mut state);
        state.push_chunk(first, None, vec![1]).unwrap();
        assert_eq!(
            state.push_chunk(first, None, vec![2]),
            Err(PushRefused::Full(vec![2]))
        );
        // Another owner has its own quota.
        state.push_chunk(second, Some(1), vec![3; 4]).unwrap();
        // A replacement gives its item back but must fit the owner's bytes.
        let mut wide = Vec::with_capacity(5);
        wide.push(4);
        assert_eq!(
            state.push_chunk(second, Some(1), wide),
            Err(PushRefused::TooLarge(vec![4]))
        );
        state.push_chunk(second, Some(1), vec![5; 2]).unwrap();
        state.audit().unwrap();
        assert_eq!(state.ledger.total().stream_items, 2);
        assert_eq!(state.ledger.owner(2).stream_bytes, EVENT_OVERHEAD + 2);
    }

    #[test]
    fn replacement_that_does_not_fit_beside_other_chunks_is_backpressure() {
        let mut state = state(Config {
            max_stream_bytes_per_owner: 2 * EVENT_OVERHEAD + 4,
            ..Config::default()
        });
        let id = admit(&mut state, 1, 0);
        run(&mut state);
        state.push_chunk(id, None, vec![1; 2]).unwrap();
        state.push_chunk(id, Some(9), vec![2; 1]).unwrap();
        assert_eq!(
            state.push_chunk(id, Some(9), vec![3; 3]),
            Err(PushRefused::Full(vec![3; 3]))
        );
        state.push_chunk(id, Some(9), vec![4; 2]).unwrap();
        state.audit().unwrap();
    }

    #[test]
    fn chunks_are_refused_unless_the_request_is_running() {
        let mut state = state(Config::default());
        let id = admit(&mut state, 1, 0);
        assert_eq!(
            state.push_chunk(id, None, vec![1]),
            Err(PushRefused::Closed(vec![1]))
        );
        run(&mut state);
        assert!(state.commit(id, Outcome::Success(vec![]), false, Duration::ZERO));
        assert_eq!(
            state.push_chunk(id, None, vec![1]),
            Err(PushRefused::Closed(vec![1]))
        );
    }
}
