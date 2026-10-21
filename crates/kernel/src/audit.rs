// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! The admission-table invariant as an executable predicate.
//!
//! Invariant (every public operation preserves it):
//! 1. The ledger equals the sum of record charges, stored chunk charges and one
//!    `Usage::released()` per final event without a record.
//! 2. Queued records and queued tasks correspond one to one, with equal owners.
//! 3. Every final event with a record belongs to a `Finished` record of the same
//!    owner, and each `Finished` record has exactly one; the remaining final events
//!    number `released_finals`.
//! 4. No chunk belongs to a queued request or follows its request's final event.
//! 5. Every record holds exactly one admission slot.
//!
//! The kernel runs the audit when it recovers a poisoned lock; tests run it after
//! every transition.

use crate::ledger::{Ledger, Usage};
use crate::state::{stored_chunk, Phase, State};
use crate::{Outcome, RequestId};
use std::collections::{BTreeMap, BTreeSet};

/// The first invariant clause found false.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Violation {
    Ledger,
    QueuedTask,
    FinalEvent,
    ReleasedCount,
    ChunkPlacement,
    Slot,
}

impl State {
    /// Check the invariant in time linear in records, queue and ready events.
    pub(crate) fn audit(&self) -> Result<(), Violation> {
        self.audit_queue()?;
        let released = self.audit_ready()?;
        if released != self.released_finals {
            return Err(Violation::ReleasedCount);
        }
        if self
            .records
            .values()
            .any(|record| record.charge.requests != 1)
        {
            return Err(Violation::Slot);
        }
        let mut charges: Vec<_> = self
            .records
            .values()
            .map(|record| (record.owner, record.charge))
            .collect();
        charges.extend(self.ready.iter().map(|event| {
            let charge = match &event.outcome {
                Outcome::Chunk { bytes, .. } => stored_chunk(bytes.capacity()),
                _ if self.records.contains_key(&event.request) => Usage::default(),
                _ => Usage::released(),
            };
            (event.owner, charge)
        }));
        if Ledger::from_charges(charges) != self.ledger {
            return Err(Violation::Ledger);
        }
        Ok(())
    }

    fn audit_queue(&self) -> Result<(), Violation> {
        let queued = self
            .records
            .values()
            .filter(|record| record.phase == Phase::Queued)
            .count();
        let consistent = queued == self.queue.len()
            && self.queue.iter().all(|task| {
                self.records.get(&task.id).is_some_and(|record| {
                    record.phase == Phase::Queued && record.owner == task.owner
                })
            });
        consistent.then_some(()).ok_or(Violation::QueuedTask)
    }

    /// Returns the number of final events without a record.
    fn audit_ready(&self) -> Result<usize, Violation> {
        let mut finished = BTreeMap::<RequestId, usize>::new();
        let mut closed = BTreeSet::<RequestId>::new();
        let mut released = 0usize;
        for event in &self.ready {
            let record = self.records.get(&event.request);
            if closed.contains(&event.request) {
                return Err(Violation::ChunkPlacement);
            }
            match &event.outcome {
                Outcome::Chunk { .. } => {
                    if record.is_some_and(|record| record.phase == Phase::Queued) {
                        return Err(Violation::ChunkPlacement);
                    }
                }
                _ => {
                    closed.insert(event.request);
                    match record {
                        Some(record)
                            if record.phase == Phase::Finished && record.owner == event.owner =>
                        {
                            let count = finished.entry(event.request).or_default();
                            *count = count.saturating_add(1);
                        }
                        Some(_) => return Err(Violation::FinalEvent),
                        None => released = released.saturating_add(1),
                    }
                }
            }
        }
        let finished_records = self
            .records
            .values()
            .filter(|record| record.phase == Phase::Finished)
            .count();
        if finished.len() != finished_records || finished.values().any(|count| *count != 1) {
            return Err(Violation::FinalEvent);
        }
        Ok(released)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scheduler::{JobOptions, WorkClass};
    use crate::state::tests::{admit, state};
    use crate::{Config, Owner, EVENT_OVERHEAD};
    use std::time::{Duration, Instant};

    #[test]
    fn audit_detects_each_kind_of_corruption() {
        let mut state = state(Config::default());
        let id = admit(&mut state, 1, 0);
        state.ledger.add(1, Usage::chunk(1));
        assert_eq!(state.audit(), Err(Violation::Ledger));
        state.ledger.sub(1, Usage::chunk(1));
        state.released_finals = 1;
        assert_eq!(state.audit(), Err(Violation::ReleasedCount));
        state.released_finals = 0;
        let task = state.queue.pop_front().unwrap();
        assert_eq!(state.audit(), Err(Violation::QueuedTask));
        state.queue.push_back(task);
        let event = state.event(id, &state.records[&id], Outcome::Failed);
        state.ready.push_back(event);
        assert_eq!(state.audit(), Err(Violation::FinalEvent));
        state.ready.clear();
        state.audit().unwrap();
    }

    /// A tiny deterministic generator; the tests need reproducible schedules.
    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self, bound: u64) -> u64 {
            self.0 = self
                .0
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (self.0 >> 33) % bound
        }
    }

    // Model check over random schedules: the invariant holds after every
    // transition, each accepted request yields exactly one final event, chunks
    // never follow it, and draining everything returns the ledger to zero.
    #[test]
    fn random_schedules_preserve_invariant_and_yield_one_final_per_request() {
        for seed in 0..24 {
            let mut explorer = Explorer::new(seed);
            for _ in 0..600 {
                explorer.step();
                explorer.state.audit().unwrap();
            }
            explorer.quiesce();
        }
    }

    /// Random walk over the table's transitions with a record of drained finals.
    struct Explorer {
        random: Lcg,
        state: State,
        accepted: BTreeSet<RequestId>,
        running: Vec<RequestId>,
        finals: BTreeMap<RequestId, usize>,
    }

    impl Explorer {
        fn new(seed: u64) -> Self {
            Self {
                random: Lcg(seed),
                state: state(Config {
                    max_requests: 6,
                    max_requests_per_owner: 3,
                    max_stream_items: 4,
                    max_stream_items_per_owner: 2,
                    max_stream_bytes: 4 * (EVENT_OVERHEAD + 8),
                    max_stream_bytes_per_owner: 2 * (EVENT_OVERHEAD + 8),
                    max_reserved_bytes: 40 * EVENT_OVERHEAD,
                    max_reserved_bytes_per_owner: 20 * EVENT_OVERHEAD,
                    ..Config::default()
                }),
                accepted: BTreeSet::new(),
                running: Vec::new(),
                finals: BTreeMap::new(),
            }
        }

        fn class(&mut self) -> WorkClass {
            if self.random.next(2) == 0 {
                WorkClass::Cpu
            } else {
                WorkClass::Io
            }
        }

        fn step(&mut self) {
            let owner: Owner = self.random.next(3);
            match self.random.next(9) {
                0 | 1 => self.admit(owner),
                2 => {
                    let class = self.class();
                    if let Some(Ok((task, _))) = self.state.start(class, Instant::now()) {
                        self.running.push(task.id);
                    }
                }
                3 => self.emit(),
                4 => self.commit(),
                5 => {
                    let newest = self.accepted.last().copied().unwrap_or(0);
                    let id = self.random.next(newest + 1) + 1;
                    let _ = self.state.cancel_one(id);
                }
                6 => {
                    let _ = self.state.cancel_where(|record| record.belongs_to(owner));
                }
                7 => {
                    let generation = self.random.next(3);
                    let _ = self
                        .state
                        .cancel_where(|record| record.is_superseded_by(owner, generation));
                }
                _ => {
                    let items = self.random.next(4) as usize;
                    let bytes = self.random.next(4) as usize * EVENT_OVERHEAD;
                    self.drain(items, bytes);
                }
            }
        }

        fn admit(&mut self, owner: Owner) {
            let options = JobOptions {
                class: self.class(),
                ..JobOptions::default()
            };
            let output = self.random.next(3) as usize;
            let generation = self.random.next(3);
            let job = |_: crate::Context, _: Vec<u8>| Ok(vec![]);
            let result = self.state.admit(
                owner,
                generation,
                vec![],
                output,
                options,
                job,
                Instant::now(),
            );
            if let Ok(id) = result {
                self.accepted.insert(id);
            }
        }

        fn emit(&mut self) {
            if self.running.is_empty() {
                return;
            }
            let index = self.random.next(self.running.len() as u64) as usize;
            let id = self.running[index];
            let key = (self.random.next(2) == 0).then(|| self.random.next(2));
            let len = self.random.next(8) as usize;
            let _ = self.state.push_chunk(id, key, vec![0; len]);
        }

        fn commit(&mut self) {
            if self.running.is_empty() {
                return;
            }
            let index = self.random.next(self.running.len() as u64) as usize;
            let id = self.running.swap_remove(index);
            let raw = match self.random.next(3) {
                0 => Outcome::Success(vec![0; self.random.next(3) as usize]),
                1 => Outcome::Failed,
                _ => Outcome::Panicked,
            };
            assert!(self.state.commit(id, raw, false, Duration::ZERO));
        }

        fn drain(&mut self, items: usize, bytes: usize) {
            for event in self.state.drain(items, bytes).unwrap_or_default() {
                let count = self.finals.entry(event.request).or_default();
                assert_eq!(*count, 0, "event after final for {}", event.request);
                if !matches!(event.outcome, Outcome::Chunk { .. }) {
                    *count += 1;
                }
            }
        }

        /// Cancel everything, let running jobs return, drain, and check the laws.
        fn quiesce(mut self) {
            let _ = self.state.cancel_where(|_| true);
            for id in std::mem::take(&mut self.running) {
                assert!(self
                    .state
                    .commit(id, Outcome::Success(vec![]), false, Duration::ZERO));
            }
            self.state.audit().unwrap();
            assert!(self.state.queue.is_empty());
            self.drain(usize::MAX, usize::MAX);
            assert_eq!(self.state.ledger, Ledger::default());
            assert_eq!(self.state.outstanding(), 0);
            assert_eq!(
                self.finals.keys().copied().collect::<BTreeSet<_>>(),
                self.accepted
            );
            assert!(self.finals.values().all(|count| *count == 1));
        }
    }
}
