// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Worker threads: dequeue under the lock, run the job outside it, commit under it.
//!
//! Wakeups: a worker parks only after listing itself idle under the state lock
//! with no task of its class queued. A submitter claims one listed worker of the
//! task's class and unparks it after unlocking. `unpark` leaves a token when it
//! precedes `park`, so neither a submission nor `shutdown` can be lost between the
//! worker's check and its park. Idle workers do not poll.

use crate::state::{Job, Started, Task};
use crate::{Context, Outcome, Shared, WorkClass};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

/// Serve tasks of `class` until shutdown empties the queue or the state is corrupt.
pub(crate) fn run(shared: &Arc<Shared>, class: WorkClass, index: usize) {
    while let Some((task, started)) = next(shared, class, index) {
        let Task { id, input, job, .. } = task;
        let context = Context {
            cancelled: started.cancelled,
            stopping: Arc::clone(&shared.stopping),
            max_output_bytes: started.output_limit,
            shared: Arc::downgrade(shared),
            request: id,
        };
        let clock = Instant::now();
        let raw = execute(job, context, input);
        let run_time = clock.elapsed();
        // A corrupt table cannot take the outcome; the worker stops instead.
        let Ok(mut state) = shared.lock() else {
            return;
        };
        if state.commit(id, raw, shared.is_stopping(), run_time) {
            shared.hint(&state);
        }
    }
}

/// Wait for and start the next task of `class`; `None` ends the worker.
fn next(shared: &Shared, class: WorkClass, index: usize) -> Option<(Task, Started)> {
    let mut state = shared.lock().ok()?;
    loop {
        state.idle.forget(class, index);
        match state.start(class, Instant::now()) {
            Some(Ok(started)) => return Some(started),
            Some(Err(orphan)) => {
                // Unreachable while the invariant holds; drop it outside the lock.
                drop(state);
                drop(orphan);
                state = shared.lock().ok()?;
                continue;
            }
            None => {}
        }
        if shared.is_stopping() {
            return None;
        }
        state.idle.register(class, index);
        drop(state);
        thread::park();
        state = shared.lock().ok()?;
    }
}

/// Run a job unless it was cancelled while queued; its captures drop here,
/// outside the state lock.
fn execute(job: Job, context: Context, input: Vec<u8>) -> Outcome {
    let result = catch_unwind(AssertUnwindSafe(move || {
        if context.is_cancelled() {
            return Outcome::Cancelled;
        }
        match job(context, input) {
            Ok(bytes) => Outcome::Success(bytes),
            Err(_) => Outcome::Failed,
        }
    }));
    result.unwrap_or_else(|payload| {
        // A payload whose Drop panics again must not unwind out of the worker;
        // that second payload is leaked rather than dropped.
        if let Err(again) = catch_unwind(AssertUnwindSafe(move || drop(payload))) {
            std::mem::forget(again);
        }
        Outcome::Panicked
    })
}
