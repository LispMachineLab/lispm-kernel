// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Owned native jobs with bounded admission and retained terminal outcomes.
//!
//! A [`Kernel`] runs trusted Rust jobs on fixed CPU and blocking-I/O worker pools.
//! The frontend (Emacs) submits owned input, polls with nonblocking calls and
//! drains retained [`Event`]s within item and byte budgets.
//!
//! # Model
//!
//! Every accepted request yields exactly one final outcome (any [`Outcome`] other
//! than `Chunk`), preceded by the chunks its job emitted. Admission charges a slot,
//! the input capacity, the maximum output and [`EVENT_OVERHEAD`] against global and
//! per-owner limits until the final outcome is drained. Cancelling a request
//! releases its slot, owner quota and payload reservation as soon as no job holds
//! it (at once when queued, at commit when running), drops its undrained chunks,
//! and keeps only the `EVENT_OVERHEAD` charge of its final `Cancelled` event.
//!
//! # Locking and poisoning
//!
//! One mutex guards the admission table. Frontend calls use `try_lock` and return
//! [`Error::Busy`] instead of waiting. Adapter code never runs under the lock, and
//! every critical section is total, so the lock can only be poisoned by a kernel
//! bug or a panic on allocation failure. Every lock site then recovers the guard
//! with `PoisonError::into_inner`, audits the full table invariant, and continues
//! if it holds, so workers still publish computed outcomes. If the audit fails,
//! frontend calls return [`Error::Poisoned`], emitters [`EmitFailure::Poisoned`],
//! and workers exit without publishing.
//!
//! # Wake hints (Unix)
//!
//! [`Kernel::attach_notifications`] returns the reader of a socket pair; the kernel
//! writes at most one coalesced byte to it while retained events wait. No hint
//! write can raise `SIGPIPE`: std passes `MSG_NOSIGNAL` on Linux and the BSDs,
//! the kernel sets `SO_NOSIGPIPE` on Apple platforms, and other Unix platforms
//! refuse to attach. A failed write shuts the writer down so the reader sees EOF,
//! and [`Stats::notifications_broken`] reports it. After [`Kernel::shutdown`]
//! returns, the kernel never writes a hint again.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, TryLockError, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

mod audit;
mod ledger;
mod lifecycle;
#[cfg(unix)]
mod notification;
mod scheduler;
mod state;
mod stream;
mod worker;

use ledger::Limits;
use lifecycle::Cancellation;
pub use scheduler::{JobOptions, Priority, WorkClass};
use state::{State, Task};
pub use stream::{EmitError, EmitFailure};

/// Identifies the frontend object that owns requests, such as a buffer or provider.
pub type Owner = u64;
/// Identifies one accepted request within a runtime epoch.
pub type RequestId = u64;
/// Fixed byte charge of every retained event, added to its payload.
pub const EVENT_OVERHEAD: usize = 64;
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
/// Backstop for emitters waiting on stream capacity: `shutdown` notifies them
/// without the state lock, so a notification can race their final check.
const SPACE_POLL: Duration = Duration::from_millis(50);

/// Pool sizes and resource limits. Every limit is checked at admission or emission.
///
/// Per-owner limits above their global counterpart are allowed; the global limit
/// then binds.
#[derive(Clone, Copy, Debug)]
pub struct Config {
    /// CPU worker threads. At least 1.
    pub workers: usize,
    /// Blocking-I/O worker threads. At least 1.
    pub io_workers: usize,
    /// Undrained incremental chunks across all owners. At least 1.
    pub max_stream_items: usize,
    /// Allocation bytes of undrained chunks across all owners, each charged
    /// `EVENT_OVERHEAD` plus its capacity. At least `EVENT_OVERHEAD`.
    pub max_stream_bytes: usize,
    /// Requests holding a slot: queued, running, or completed but not drained.
    /// Cancelled requests give their slot back at once. At least 1.
    pub max_requests: usize,
    /// Slots of one owner. At least 1.
    pub max_requests_per_owner: usize,
    /// Sum of input and output reservations of all accepted requests.
    /// At least `EVENT_OVERHEAD`.
    pub max_reserved_bytes: usize,
    /// Reserved bytes of one owner. At least `EVENT_OVERHEAD`.
    pub max_reserved_bytes_per_owner: usize,
    /// Undrained chunks of one owner. At least 1.
    pub max_stream_items_per_owner: usize,
    /// Undrained chunk bytes of one owner. At least `EVENT_OVERHEAD`.
    pub max_stream_bytes_per_owner: usize,
}

impl Default for Config {
    /// Two workers per pool; each owner may hold a quarter of every global limit.
    fn default() -> Self {
        Self {
            workers: 2,
            io_workers: 2,
            max_stream_items: 64,
            max_stream_bytes: 1024 * 1024,
            max_requests: 64,
            max_requests_per_owner: 16,
            max_reserved_bytes: 8 * 1024 * 1024,
            max_reserved_bytes_per_owner: 2 * 1024 * 1024,
            max_stream_items_per_owner: 16,
            max_stream_bytes_per_owner: 256 * 1024,
        }
    }
}

impl Config {
    /// Whether every pool can run and every limit admits a minimal request and chunk.
    fn is_valid(&self) -> bool {
        let counts = [
            self.workers,
            self.io_workers,
            self.max_stream_items,
            self.max_stream_items_per_owner,
            self.max_requests,
            self.max_requests_per_owner,
        ];
        let byte_limits = [
            self.max_stream_bytes,
            self.max_stream_bytes_per_owner,
            self.max_reserved_bytes,
            self.max_reserved_bytes_per_owner,
        ];
        counts.iter().all(|count| *count > 0)
            && byte_limits.iter().all(|bytes| *bytes >= EVENT_OVERHEAD)
    }
}

/// Why a kernel operation did not take effect.
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// A `Config` limit cannot admit any work.
    InvalidConfig,
    /// The state lock is held; retry later without blocking the caller.
    Busy,
    /// The kernel is shut down and accepts no new work or registrations.
    Closed,
    /// A global or per-owner admission limit is exhausted, or the reservation overflows.
    Capacity,
    /// This runtime has issued every request ID.
    IdExhausted,
    /// The process has created every runtime epoch.
    EpochExhausted,
    /// The next event needs a larger drain byte budget; it was not consumed.
    DrainBudget {
        /// Drain bytes the next event needs.
        required: usize,
    },
    /// A worker thread could not be spawned.
    WorkerStart,
    /// The state lock was poisoned and its invariant audit failed.
    Poisoned,
    /// The notification transport could not be created or configured.
    NotificationIo,
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidConfig => formatter.write_str("invalid kernel configuration"),
            Self::Busy => formatter.write_str("kernel state is busy; retry later"),
            Self::Closed => formatter.write_str("kernel is shut down"),
            Self::Capacity => formatter.write_str("admission capacity exhausted"),
            Self::IdExhausted => formatter.write_str("request IDs exhausted"),
            Self::EpochExhausted => formatter.write_str("runtime epochs exhausted"),
            Self::DrainBudget { required } => {
                write!(
                    formatter,
                    "drain budget too small: next event needs {required} bytes"
                )
            }
            Self::WorkerStart => formatter.write_str("failed to start a worker thread"),
            Self::Poisoned => formatter.write_str("kernel state failed its audit after a panic"),
            Self::NotificationIo => formatter.write_str("notification transport failed"),
        }
    }
}

impl std::error::Error for Error {}

/// One retained result of a request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// An incremental chunk; zero or more precede the final outcome.
    Chunk {
        /// Replacement key of a coalescible state update, or `None` for a reliable chunk.
        key: Option<u64>,
        /// Chunk payload.
        bytes: Vec<u8>,
    },
    /// Final: the job returned these bytes.
    Success(Vec<u8>),
    /// Final: the job returned `JobFailed`.
    Failed,
    /// Final: the request was cancelled, superseded, closed or shut down.
    Cancelled,
    /// Final: the job panicked, whether or not it was also cancelled.
    Panicked,
    /// Final: the job's output capacity exceeded its declared maximum.
    OutputTooLarge,
}

/// A retained outcome with the identity of its request.
#[derive(Debug, PartialEq, Eq)]
pub struct Event {
    /// Runtime epoch; distinguishes request IDs of different runtimes in a process.
    pub epoch: u64,
    /// Request that produced the outcome.
    pub request: RequestId,
    /// Owner given at submission.
    pub owner: Owner,
    /// Generation given at submission.
    pub generation: u64,
    /// The outcome itself.
    pub outcome: Outcome,
}

impl Event {
    /// Drain budget charge: `EVENT_OVERHEAD` plus the payload length.
    pub fn byte_cost(&self) -> usize {
        EVENT_OVERHEAD.saturating_add(match &self.outcome {
            Outcome::Success(bytes) | Outcome::Chunk { bytes, .. } => bytes.len(),
            Outcome::Failed | Outcome::Cancelled | Outcome::Panicked | Outcome::OutputTooLarge => 0,
        })
    }
}

/// A snapshot of occupancy, high-water marks and counters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    /// Accepted requests whose final outcome has not been drained.
    pub outstanding: usize,
    /// Requests waiting for a worker.
    pub queued: usize,
    /// Retained events: chunks and final outcomes.
    pub ready: usize,
    /// Reserved bytes of accepted requests.
    pub reserved_bytes: usize,
    /// Whether `shutdown` has been called.
    pub closed: bool,
    /// Undrained chunks.
    pub stream_items: usize,
    /// Allocation bytes of undrained chunks.
    pub stream_bytes: usize,
    /// Highest `queued` observed.
    pub queue_high_water: usize,
    /// Highest `reserved_bytes` observed.
    pub reserved_high_water: usize,
    /// Highest `stream_items` observed.
    pub stream_items_high_water: usize,
    /// Highest `stream_bytes` observed.
    pub stream_bytes_high_water: usize,
    /// Final outcomes committed, including cancellations of queued requests.
    pub completed: u64,
    /// Final `Cancelled` outcomes.
    pub cancelled: u64,
    /// Final `Failed` outcomes.
    pub failed: u64,
    /// Final `Panicked` outcomes.
    pub panicked: u64,
    /// Longest time a request waited in the queue.
    pub max_queue_wait: Duration,
    /// Longest job run time.
    pub max_run_time: Duration,
    /// Whether the attached wake channel failed and was shut down (EOF).
    pub notifications_broken: bool,
}

/// A running job's view of its request.
///
/// A cooperative adapter must check cancellation and bound temporary allocations.
pub struct Context {
    cancelled: Arc<AtomicBool>,
    stopping: Arc<AtomicBool>,
    /// Maximum allocation capacity of the job's final output.
    pub max_output_bytes: usize,
    shared: Weak<Shared>,
    request: RequestId,
}

impl Context {
    /// Whether the request was cancelled or the runtime is shutting down.
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire) || self.stopping.load(Ordering::Acquire)
    }
}

/// A job's failure; reported as `Outcome::Failed`.
#[derive(Debug)]
pub struct JobFailed;

impl fmt::Display for JobFailed {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("job failed")
    }
}

impl std::error::Error for JobFailed {}

/// A submission the kernel did not accept; the caller keeps job and input to retry.
pub struct Rejected<F> {
    /// Why the submission was rejected.
    pub error: Error,
    /// The submitted input, unchanged.
    pub input: Vec<u8>,
    /// The submitted job, never called.
    pub job: F,
}

impl<F> Rejected<F> {
    fn new(error: Error, input: Vec<u8>, job: F) -> Self {
        Self { error, input, job }
    }
}

impl<F> fmt::Debug for Rejected<F> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Rejected")
            .field("error", &self.error)
            .field("input_len", &self.input.len())
            .finish_non_exhaustive()
    }
}

impl<F> fmt::Display for Rejected<F> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "submission rejected: {}", self.error)
    }
}

impl<F> std::error::Error for Rejected<F> {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.error)
    }
}

/// The state lock failed its invariant audit after being poisoned.
pub(crate) struct Corrupt;

pub(crate) struct Shared {
    epoch: u64,
    state: Mutex<State>,
    space: Condvar,
    stopping: Arc<AtomicBool>,
    /// Lock order: `state` before `notifier`. Only `shutdown` and `detach` take the
    /// notifier alone; every notifier critical section is a bounded nonblocking step.
    #[cfg(unix)]
    notifier: Mutex<notification::Notifier>,
}

impl Shared {
    fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::Acquire)
    }

    /// Blocking lock for workers and emitters.
    fn lock(&self) -> Result<MutexGuard<'_, State>, Corrupt> {
        match self.state.lock() {
            Ok(guard) => Ok(guard),
            Err(poisoned) => self.recover(poisoned.into_inner()),
        }
    }

    /// Nonblocking lock for frontend calls.
    fn try_lock(&self) -> Result<MutexGuard<'_, State>, Error> {
        match self.state.try_lock() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::WouldBlock) => Err(Error::Busy),
            Err(TryLockError::Poisoned(poisoned)) => self
                .recover(poisoned.into_inner())
                .map_err(|Corrupt| Error::Poisoned),
        }
    }

    /// Wait until stream capacity may have changed, or `SPACE_POLL` elapses.
    fn wait_for_space<'a>(
        &self,
        guard: MutexGuard<'a, State>,
    ) -> Result<MutexGuard<'a, State>, Corrupt> {
        match self.space.wait_timeout(guard, SPACE_POLL) {
            Ok((guard, _)) => Ok(guard),
            Err(poisoned) => self.recover(poisoned.into_inner().0),
        }
    }

    /// Continue with a poisoned guard iff the table invariant still holds.
    fn recover<'a>(&self, guard: MutexGuard<'a, State>) -> Result<MutexGuard<'a, State>, Corrupt> {
        if guard.audit().is_ok() {
            self.state.clear_poison();
            Ok(guard)
        } else {
            Err(Corrupt)
        }
    }

    /// Hint that events are ready. `_held` witnesses the state lock, which orders
    /// this hint with `drain`'s rearm.
    fn hint(&self, _held: &State) {
        #[cfg(unix)]
        self.notifier().signal();
    }

    /// Allow the next hint, and send it at once if events remain.
    fn rearm(&self, held: &State) {
        #[cfg(unix)]
        {
            let mut notifier = self.notifier();
            notifier.rearm();
            if held.has_ready() {
                notifier.signal();
            }
        }
        #[cfg(not(unix))]
        let _ = held;
    }

    fn notifications_broken(&self, _held: &State) -> bool {
        #[cfg(unix)]
        return self.notifier().is_broken();
        #[cfg(not(unix))]
        false
    }

    /// Post: no hint is written after this returns.
    fn disable_notifications(&self) {
        #[cfg(unix)]
        {
            let writer = self.notifier().disable();
            drop(writer);
        }
    }
}

/// The background runtime: worker pools and the retained-outcome table.
///
/// Dropping the kernel shuts it down without joining workers.
pub struct Kernel {
    shared: Arc<Shared>,
    workers: Vec<JoinHandle<()>>,
}

impl Kernel {
    /// Start a runtime with a fresh epoch and its worker pools.
    pub fn new(config: Config) -> Result<Self, Error> {
        if !config.is_valid() {
            return Err(Error::InvalidConfig);
        }
        // Never wrap and reuse a runtime epoch.
        let epoch = NEXT_EPOCH
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
            .map_err(|_| Error::EpochExhausted)?;
        let shared = Arc::new(Shared {
            epoch,
            state: Mutex::new(State::new(epoch, Limits::from_config(&config))),
            space: Condvar::new(),
            stopping: Arc::new(AtomicBool::new(false)),
            #[cfg(unix)]
            notifier: Mutex::new(notification::Notifier::default()),
        });
        let mut kernel = Self {
            shared,
            workers: Vec::new(),
        };
        let pools = [
            (WorkClass::Cpu, config.workers),
            (WorkClass::Io, config.io_workers),
        ];
        for (class, count) in pools {
            for ordinal in 0..count {
                let shared = Arc::clone(&kernel.shared);
                let index = kernel.workers.len();
                let handle = thread::Builder::new()
                    .name(format!("lispm-{class:?}-{ordinal}"))
                    .spawn(move || worker::run(&shared, class, index))
                    .map_err(|_| Error::WorkerStart)?;
                kernel.workers.push(handle);
            }
        }
        Ok(kernel)
    }

    /// Unique for this runtime instance within the current process.
    pub fn epoch(&self) -> u64 {
        self.shared.epoch
    }

    fn state(&self) -> Result<MutexGuard<'_, State>, Error> {
        self.shared.try_lock()
    }

    /// Submit a CPU job with normal priority. See [`Kernel::try_submit_with_options`].
    pub fn submit<F>(
        &self,
        owner: Owner,
        generation: u64,
        input: Vec<u8>,
        max_output_bytes: usize,
        job: F,
    ) -> Result<RequestId, Error>
    where
        F: FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send + 'static,
    {
        self.submit_with_options(
            owner,
            generation,
            input,
            max_output_bytes,
            JobOptions::default(),
            job,
        )
    }

    /// Submit a job; on rejection the job and input are dropped.
    /// See [`Kernel::try_submit_with_options`].
    pub fn submit_with_options<F>(
        &self,
        owner: Owner,
        generation: u64,
        input: Vec<u8>,
        max_output_bytes: usize,
        options: JobOptions,
        job: F,
    ) -> Result<RequestId, Error>
    where
        F: FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send + 'static,
    {
        self.try_submit_with_options(owner, generation, input, max_output_bytes, options, job)
            .map_err(|rejected| rejected.error)
    }

    /// Submit a job, or get job and input back with the reason for a later retry.
    ///
    /// Never blocks: a held state lock is `Busy`. Admission reserves the input's
    /// allocation capacity, `max_output_bytes` and `EVENT_OVERHEAD` against the
    /// global and per-owner limits. Captured closure allocations are trusted adapter
    /// state, not accounted input. An accepted job wakes at most one idle worker,
    /// and only of its own class.
    pub fn try_submit_with_options<F>(
        &self,
        owner: Owner,
        generation: u64,
        input: Vec<u8>,
        max_output_bytes: usize,
        options: JobOptions,
        job: F,
    ) -> Result<RequestId, Rejected<F>>
    where
        F: FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send + 'static,
    {
        let mut state = match self.state() {
            Ok(state) => state,
            Err(error) => return Err(Rejected::new(error, input, job)),
        };
        if self.shared.is_stopping() {
            return Err(Rejected::new(Error::Closed, input, job));
        }
        let now = Instant::now();
        let id = state.admit(
            owner,
            generation,
            input,
            max_output_bytes,
            options,
            job,
            now,
        )?;
        let wake = state.idle.claim(options.class);
        drop(state);
        if let Some(handle) = wake.and_then(|index| self.workers.get(index)) {
            handle.thread().unpark();
        }
        Ok(id)
    }

    /// Cancel one queued or running request.
    ///
    /// A queued request gets its final `Cancelled` event at once and gives back its
    /// slot, owner quota and payload reservation. A running request is told through
    /// its `Context`. Undrained chunks of the request are dropped. Returns true while
    /// the request has not completed, cancelled before or not, and false for unknown
    /// or completed requests, whose outcome stays unchanged.
    pub fn cancel(&self, id: RequestId) -> Result<bool, Error> {
        let mut state = self.state()?;
        let cancellation = state.cancel_one(id);
        Ok(self.finish_cancellation(state, cancellation) > 0)
    }

    /// Cancel every current request of `owner` as `cancel` does; returns how many.
    /// The caller must prevent future submissions to the closed owner.
    pub fn close_owner(&self, owner: Owner) -> Result<usize, Error> {
        let mut state = self.state()?;
        let cancellation = state.cancel_where(|record| record.belongs_to(owner));
        Ok(self.finish_cancellation(state, cancellation))
    }

    /// Cancel current requests of `owner` older than `generation`; returns how many.
    /// This is not a persistent registration: later submissions are unaffected.
    pub fn supersede(&self, owner: Owner, generation: u64) -> Result<usize, Error> {
        let mut state = self.state()?;
        let cancellation = state.cancel_where(|record| record.is_superseded_by(owner, generation));
        Ok(self.finish_cancellation(state, cancellation))
    }

    /// Hint new finals under the lock, then drop removed jobs, inputs and chunk
    /// payloads outside it and wake emitters that may now proceed or stop.
    fn finish_cancellation(
        &self,
        state: MutexGuard<'_, State>,
        cancellation: Cancellation,
    ) -> usize {
        if cancellation.finals > 0 {
            self.shared.hint(&state);
        }
        drop(state);
        let Cancellation {
            count,
            tasks,
            payloads,
            ..
        } = cancellation;
        drop(tasks);
        drop(payloads);
        if count > 0 {
            self.shared.space.notify_all();
        }
        count
    }

    /// Remove up to `max_items` events in order, charging `byte_cost` against
    /// `max_bytes`.
    ///
    /// If the first event alone exceeds `max_bytes`, nothing is consumed and
    /// `DrainBudget` reports its cost. Every call, successful or not, rearms the
    /// wake hint and hints again if events remain.
    pub fn drain(&self, max_items: usize, max_bytes: usize) -> Result<Vec<Event>, Error> {
        let mut state = self.state()?;
        let result = state.drain(max_items, max_bytes);
        self.shared.rearm(&state);
        drop(state);
        if result.as_ref().is_ok_and(|events| !events.is_empty()) {
            self.shared.space.notify_all();
        }
        result
    }

    /// Snapshot occupancy and counters.
    pub fn stats(&self) -> Result<Stats, Error> {
        let state = self.state()?;
        let usage = state.ledger.total();
        let metrics = &state.metrics;
        Ok(Stats {
            outstanding: state.outstanding(),
            queued: state.queue.len(),
            ready: state.ready.len(),
            reserved_bytes: usage.reserved,
            closed: self.shared.is_stopping(),
            stream_items: usage.stream_items,
            stream_bytes: usage.stream_bytes,
            queue_high_water: metrics.queue_high_water,
            reserved_high_water: metrics.reserved_high_water,
            stream_items_high_water: metrics.stream_items_high_water,
            stream_bytes_high_water: metrics.stream_bytes_high_water,
            completed: metrics.completed,
            cancelled: metrics.cancelled,
            failed: metrics.failed,
            panicked: metrics.panicked,
            max_queue_wait: metrics.max_queue_wait,
            max_run_time: metrics.max_run_time,
            notifications_broken: self.shared.notifications_broken(&state),
        })
    }

    /// Close admission, disable wake hints, and ask all work to stop.
    ///
    /// Never takes the state lock, joins workers or waits for adapters; it waits
    /// only for an in-flight nonblocking hint write. Queued jobs are skipped and
    /// running jobs are cancelled; their outcomes stay drainable by polling. After
    /// this returns, no hint is written, so the frontend may tear down its reader.
    pub fn shutdown(&self) {
        self.shared.stopping.store(true, Ordering::Release);
        self.shared.disable_notifications();
        for worker in &self.workers {
            worker.thread().unpark();
        }
        self.shared.space.notify_all();
    }

    /// Whether every worker thread has exited.
    pub fn workers_finished(&self) -> bool {
        self.workers.iter().all(JoinHandle::is_finished)
    }
}

impl Drop for Kernel {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests;
