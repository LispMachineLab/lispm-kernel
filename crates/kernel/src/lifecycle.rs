// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Cancellation and completion transitions of the admission table.
//!
//! Law: every accepted request yields exactly one final event. Cancellation of a
//! queued request appends it at once; a running request appends it when its worker
//! commits. Neither path can append a second one, because both require a live
//! record and both end its liveness.

use crate::ledger::Usage;
use crate::state::{stored_chunk, Phase, Record, State, Task};
use crate::{Outcome, Owner, RequestId};
use std::collections::BTreeSet;
use std::sync::atomic::Ordering;
use std::time::Duration;

/// What a cancellation removed. The caller drops it after releasing the lock.
#[derive(Default)]
#[must_use]
pub(crate) struct Cancellation {
    /// Live requests marked cancelled.
    pub(crate) count: usize,
    /// Final `Cancelled` events appended for queued requests.
    pub(crate) finals: usize,
    /// Dequeued tasks: job closures and inputs that never ran.
    pub(crate) tasks: Vec<Task>,
    /// Payloads of dropped chunks.
    pub(crate) payloads: Vec<Vec<u8>>,
}

/// The final outcome committed for a worker's raw result.
///
/// A panic is always reported as `Panicked`. Otherwise cancellation wins over
/// every other result, and an over-limit success becomes `OutputTooLarge`.
pub(crate) fn settle(raw: Outcome, cancelled: bool, output_limit: usize) -> Outcome {
    match raw {
        Outcome::Panicked => Outcome::Panicked,
        _ if cancelled => Outcome::Cancelled,
        Outcome::Success(bytes) if bytes.capacity() > output_limit => Outcome::OutputTooLarge,
        other => other,
    }
}

impl State {
    /// Cancel request `id` if it is still queued or running.
    pub(crate) fn cancel_one(&mut self, id: RequestId) -> Cancellation {
        let live = self
            .records
            .get(&id)
            .is_some_and(|record| record.phase.is_live());
        self.cancel_ids(live.then_some(id).into_iter().collect())
    }

    /// Cancel every queued or running request selected by `select`.
    pub(crate) fn cancel_where(&mut self, select: impl Fn(&Record) -> bool) -> Cancellation {
        let ids = self
            .records
            .iter()
            .filter(|(_, record)| record.phase.is_live() && select(record))
            .map(|(id, _)| *id)
            .collect();
        self.cancel_ids(ids)
    }

    /// Pre: every ID names a live record.
    /// Post: those records are cancelled; queued ones are released with a final
    /// `Cancelled` event; no chunk of any of them remains in `ready`.
    fn cancel_ids(&mut self, ids: BTreeSet<RequestId>) -> Cancellation {
        let mut queued = false;
        let mut streaming = BTreeSet::<Owner>::new();
        for record in ids.iter().filter_map(|id| self.records.get(id)) {
            record.cancelled.store(true, Ordering::Release);
            match record.phase {
                Phase::Queued => queued = true,
                Phase::Running => {
                    streaming.insert(record.owner);
                }
                Phase::Finished => {}
            }
        }
        let tasks = if queued {
            self.dequeue(&ids)
        } else {
            Vec::new()
        };
        let finals = tasks
            .iter()
            .filter(|task| self.release_queued(task.id))
            .count();
        let has_chunks = streaming
            .iter()
            .any(|owner| self.ledger.owner(*owner).stream_items > 0);
        let payloads = if has_chunks {
            self.drop_chunks(&ids)
        } else {
            Vec::new()
        };
        Cancellation {
            count: ids.len(),
            finals,
            tasks,
            payloads,
        }
    }

    fn dequeue(&mut self, ids: &BTreeSet<RequestId>) -> Vec<Task> {
        let (removed, kept): (Vec<Task>, Vec<Task>) = std::mem::take(&mut self.queue)
            .into_iter()
            .partition(|task| ids.contains(&task.id));
        // Vec to VecDeque reuses the allocation.
        self.queue = kept.into();
        removed
    }

    /// Append the final `Cancelled` event of a dequeued request and release it.
    fn release_queued(&mut self, id: RequestId) -> bool {
        let Some(record) = self.records.get(&id) else {
            return false;
        };
        let event = self.event(id, record, Outcome::Cancelled);
        self.ready.push_back(event);
        self.metrics.record_final(&Outcome::Cancelled);
        if let Some(record) = self.records.remove(&id) {
            self.release(record);
        }
        true
    }

    /// Give up everything but the final event's charge.
    fn release(&mut self, record: Record) {
        let freed = record.charge.saturating_sub(Usage::released());
        self.ledger.sub(record.owner, freed);
        self.released_finals = self.released_finals.saturating_add(1);
    }

    fn drop_chunks(&mut self, ids: &BTreeSet<RequestId>) -> Vec<Vec<u8>> {
        let State { ready, ledger, .. } = self;
        let mut payloads = Vec::new();
        ready.retain_mut(|event| match &mut event.outcome {
            Outcome::Chunk { bytes, .. } if ids.contains(&event.request) => {
                ledger.sub(event.owner, stored_chunk(bytes.capacity()));
                payloads.push(std::mem::take(bytes));
                false
            }
            _ => true,
        });
        payloads
    }

    /// Commit the raw result of running request `id`.
    ///
    /// A cancelled request (or any request once the runtime is stopping) is released:
    /// its slot, owner quota and payload reservation return at once. Other results
    /// keep them until the final event is drained.
    /// Returns whether a final event was appended.
    pub(crate) fn commit(
        &mut self,
        id: RequestId,
        raw: Outcome,
        stopping: bool,
        run_time: Duration,
    ) -> bool {
        let Some(record) = self
            .records
            .get(&id)
            .filter(|record| record.phase == Phase::Running)
        else {
            return false;
        };
        let cancelled = stopping || record.cancel_requested();
        let outcome = settle(raw, cancelled, record.output_limit);
        self.metrics.record_final(&outcome);
        let event = self.event(id, record, outcome);
        self.ready.push_back(event);
        if cancelled {
            if let Some(record) = self.records.remove(&id) {
                self.release(record);
            }
        } else if let Some(record) = self.records.get_mut(&id) {
            record.phase = Phase::Finished;
        }
        self.metrics.max_run_time = self.metrics.max_run_time.max(run_time);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ledger::Ledger;
    use crate::state::tests::{admit, run, state};
    use crate::{Config, Error, EVENT_OVERHEAD};

    #[test]
    fn settle_reports_panics_and_lets_cancellation_win_over_other_results() {
        let table = [
            (Outcome::Panicked, true, Outcome::Panicked),
            (Outcome::Panicked, false, Outcome::Panicked),
            (Outcome::Failed, true, Outcome::Cancelled),
            (Outcome::Failed, false, Outcome::Failed),
            (Outcome::Success(vec![1]), true, Outcome::Cancelled),
            (Outcome::Success(vec![1]), false, Outcome::Success(vec![1])),
            (Outcome::Success(vec![1, 2]), false, Outcome::OutputTooLarge),
            (Outcome::Cancelled, false, Outcome::Cancelled),
        ];
        // vec! allocates exactly its length, so capacity 2 exceeds the limit of 1.
        for (raw, cancelled, expected) in table {
            assert_eq!(settle(raw, cancelled, 1), expected);
        }
    }

    #[test]
    fn cancelling_a_queued_request_releases_slot_quota_and_bytes_at_once() {
        let mut state = state(Config {
            max_requests_per_owner: 1,
            ..Config::default()
        });
        let id = admit(&mut state, 1, 0);
        let rejected = state.admit(
            1,
            0,
            vec![],
            0,
            Default::default(),
            |_, _| Ok(vec![]),
            std::time::Instant::now(),
        );
        assert_eq!(rejected.map_err(|r| r.error), Err(Error::Capacity));
        let cancellation = state.cancel_one(id);
        state.audit().unwrap();
        assert_eq!((cancellation.count, cancellation.finals), (1, 1));
        assert_eq!(cancellation.tasks.len(), 1);
        assert!(state.queue.is_empty());
        assert_eq!(state.ledger.owner(1), Usage::released());
        assert_eq!(state.outstanding(), 1);
        assert_eq!(state.metrics.cancelled, 1);
        // The owner may submit its replacement before the frontend drains.
        admit(&mut state, 1, 1);
        // A second cancellation finds no live request and appends nothing.
        assert_eq!(state.cancel_one(id).count, 0);
        let events = state.drain(8, 4096).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(
            (events[0].request, &events[0].outcome),
            (id, &Outcome::Cancelled)
        );
        assert_eq!(state.released_finals, 0);
        assert_eq!(state.ledger.owner(1), Usage::request(EVENT_OVERHEAD));
        state.audit().unwrap();
    }

    #[test]
    fn cancelling_a_running_request_drops_its_chunks_but_not_other_requests_chunks() {
        let mut state = state(Config::default());
        let first = admit(&mut state, 1, 0);
        let second = admit(&mut state, 2, 0);
        run(&mut state);
        run(&mut state);
        state.push_chunk(first, None, vec![1]).unwrap();
        state.push_chunk(second, None, vec![2]).unwrap();
        state.push_chunk(first, Some(3), vec![3]).unwrap();
        let cancellation = state.cancel_where(|record| record.belongs_to(1));
        state.audit().unwrap();
        assert_eq!((cancellation.count, cancellation.finals), (1, 0));
        assert_eq!(cancellation.payloads, vec![vec![1], vec![3]]);
        assert_eq!(state.ready.len(), 1);
        assert_eq!(state.ledger.owner(1).stream_items, 0);
        // The worker's success is committed as the single Cancelled final.
        assert!(state.commit(first, Outcome::Success(vec![]), false, Duration::ZERO));
        assert!(!state.commit(first, Outcome::Success(vec![]), false, Duration::ZERO));
        state.audit().unwrap();
        assert_eq!(state.ledger.owner(1), Usage::released());
        let outcomes: Vec<_> = state
            .drain(8, 4096)
            .unwrap()
            .into_iter()
            .map(|event| (event.request, event.outcome))
            .collect();
        assert_eq!(
            outcomes,
            vec![
                (
                    second,
                    Outcome::Chunk {
                        key: None,
                        bytes: vec![2]
                    }
                ),
                (first, Outcome::Cancelled),
            ]
        );
    }

    #[test]
    fn supersede_selects_only_older_generations_of_the_owner() {
        let mut state = state(Config::default());
        let old = admit(&mut state, 1, 1);
        let current = admit(&mut state, 1, 2);
        let other = admit(&mut state, 2, 1);
        let cancellation = state.cancel_where(|record| record.is_superseded_by(1, 2));
        assert_eq!(cancellation.count, 1);
        assert_eq!(
            state.queue.iter().map(|task| task.id).collect::<Vec<_>>(),
            vec![current, other]
        );
        assert_eq!(state.ready.front().map(|event| event.request), Some(old));
        state.audit().unwrap();
    }

    #[test]
    fn finished_requests_are_immutable_under_cancellation() {
        let mut state = state(Config::default());
        let id = admit(&mut state, 1, 0);
        run(&mut state);
        assert!(state.commit(id, Outcome::Success(vec![]), false, Duration::ZERO));
        assert_eq!(state.cancel_one(id).count, 0);
        assert_eq!(state.cancel_where(|record| record.belongs_to(1)).count, 0);
        assert_eq!(
            state.drain(1, 4096).unwrap()[0].outcome,
            Outcome::Success(vec![])
        );
        assert_eq!(state.ledger, Ledger::default());
    }

    #[test]
    fn panics_of_cancelled_requests_stay_panicked_and_are_counted() {
        let mut state = state(Config::default());
        let id = admit(&mut state, 1, 0);
        run(&mut state);
        let _ = state.cancel_one(id);
        assert!(state.commit(id, Outcome::Panicked, false, Duration::ZERO));
        let failed = admit(&mut state, 1, 0);
        run(&mut state);
        assert!(state.commit(failed, Outcome::Failed, false, Duration::ZERO));
        assert_eq!((state.metrics.panicked, state.metrics.failed), (1, 1));
        let outcomes: Vec<_> = state
            .drain(8, 4096)
            .unwrap()
            .into_iter()
            .map(|e| e.outcome)
            .collect();
        assert_eq!(outcomes, vec![Outcome::Panicked, Outcome::Failed]);
    }

    #[test]
    fn stopping_runtime_commits_cancellations_and_releases_them() {
        let mut state = state(Config::default());
        let id = admit(&mut state, 1, 0);
        run(&mut state);
        assert!(state.commit(id, Outcome::Success(vec![9]), true, Duration::ZERO));
        state.audit().unwrap();
        assert_eq!(state.ledger.owner(1), Usage::released());
        assert_eq!(state.drain(1, 4096).unwrap()[0].outcome, Outcome::Cancelled);
    }
}
