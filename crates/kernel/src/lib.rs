//! Owned native jobs with bounded admission and retained terminal outcomes.
#![forbid(unsafe_code)]

use std::collections::{BTreeMap, VecDeque};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Weak;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, TryLockError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

mod scheduler;
mod stream;
pub use scheduler::{JobOptions, Priority, WorkClass};
pub use stream::{EmitError, EmitFailure};
#[cfg(unix)]
mod notification;

pub type Owner = u64;
pub type RequestId = u64;
pub const EVENT_OVERHEAD: usize = 64;
static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug)]
pub struct Config {
    pub workers: usize,
    pub io_workers: usize,
    pub max_stream_items: usize,
    pub max_stream_bytes: usize,
    /// Includes completed outcomes that have not yet been drained.
    pub max_requests: usize,
    pub max_requests_per_owner: usize,
    /// Sum of input and output reservations of all accepted requests.
    pub max_reserved_bytes: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            workers: 2,
            io_workers: 2,
            max_stream_items: 64,
            max_stream_bytes: 1024 * 1024,
            max_requests: 64,
            max_requests_per_owner: 16,
            max_reserved_bytes: 8 * 1024 * 1024,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    InvalidConfig,
    Busy,
    Closed,
    Capacity,
    IdExhausted,
    EpochExhausted,
    DrainBudget { required: usize },
    WorkerStart,
    Poisoned,
    NotificationIo,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Chunk { key: Option<u64>, bytes: Vec<u8> },
    Success(Vec<u8>),
    Failed,
    Cancelled,
    Panicked,
    OutputTooLarge,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Event {
    pub epoch: u64,
    pub request: RequestId,
    pub owner: Owner,
    pub generation: u64,
    pub outcome: Outcome,
}

impl Event {
    pub fn byte_cost(&self) -> usize {
        EVENT_OVERHEAD
            + match &self.outcome {
                Outcome::Success(bytes) | Outcome::Chunk { bytes, .. } => bytes.len(),
                _ => 0,
            }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    pub outstanding: usize,
    pub queued: usize,
    pub ready: usize,
    pub reserved_bytes: usize,
    pub closed: bool,
    pub stream_items: usize,
    pub stream_bytes: usize,
    pub queue_high_water: usize,
    pub reserved_high_water: usize,
    pub stream_items_high_water: usize,
    pub stream_bytes_high_water: usize,
    pub completed: u64,
    pub cancelled: u64,
    pub max_queue_wait: Duration,
    pub max_run_time: Duration,
}

/// A cooperative adapter must check cancellation and bound temporary allocations.
pub struct Context {
    cancelled: Arc<AtomicBool>,
    stopping: Arc<AtomicBool>,
    pub max_output_bytes: usize,
    shared: Weak<Shared>,
    request: RequestId,
}

impl Context {
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire) || self.stopping.load(Ordering::Acquire)
    }
}

#[derive(Debug)]
pub struct JobFailed;
type Job = Box<dyn FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send>;
struct Task {
    id: RequestId,
    input: Vec<u8>,
    job: Job,
    options: JobOptions,
    submitted: Instant,
}
struct Record {
    owner: Owner,
    generation: u64,
    cancelled: Arc<AtomicBool>,
    output_limit: usize,
    reservation: usize,
    complete: bool,
}
struct State {
    next_id: RequestId,
    records: BTreeMap<RequestId, Record>,
    queue: VecDeque<Task>,
    ready: VecDeque<Event>,
    reserved: usize,
    stream_items: usize,
    stream_bytes: usize,
    last_owner: [Option<Owner>; 2],
    metrics: Metrics,
    #[cfg(unix)]
    notification: Option<notification::Writer>,
}
#[derive(Default)]
struct Metrics {
    queue_high_water: usize,
    reserved_high_water: usize,
    stream_items_high_water: usize,
    stream_bytes_high_water: usize,
    completed: u64,
    cancelled: u64,
    max_queue_wait: Duration,
    max_run_time: Duration,
}

impl State {
    fn rearm(&mut self) {
        #[cfg(unix)]
        if let Some(writer) = &mut self.notification {
            writer.rearm();
        }
        if !self.ready.is_empty() {
            self.signal();
        }
    }
    fn signal(&mut self) {
        #[cfg(unix)]
        if let Some(writer) = &mut self.notification {
            writer.signal();
        }
    }
}

struct Shared {
    epoch: u64,
    config: Config,
    state: Mutex<State>,
    space: Condvar,
    stopping: Arc<AtomicBool>,
}

pub struct Kernel {
    shared: Arc<Shared>,
    workers: Vec<JoinHandle<()>>,
}

impl Kernel {
    pub fn new(config: Config) -> Result<Self, Error> {
        if config.workers == 0
            || config.io_workers == 0
            || config.max_stream_items == 0
            || config.max_stream_bytes < EVENT_OVERHEAD
            || config.max_requests == 0
            || config.max_requests_per_owner == 0
            || config.max_reserved_bytes == 0
        {
            return Err(Error::InvalidConfig);
        }
        // Never wrap and reuse a runtime epoch.
        let epoch = NEXT_EPOCH
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
            .map_err(|_| Error::EpochExhausted)?;
        let shared = Arc::new(Shared {
            epoch,
            config,
            state: Mutex::new(State {
                next_id: 1,
                records: BTreeMap::new(),
                queue: VecDeque::new(),
                ready: VecDeque::new(),
                reserved: 0,
                stream_items: 0,
                stream_bytes: 0,
                last_owner: [None; 2],
                metrics: Metrics::default(),
                #[cfg(unix)]
                notification: None,
            }),
            space: Condvar::new(),
            stopping: Arc::new(AtomicBool::new(false)),
        });
        let mut kernel = Self {
            shared,
            workers: Vec::new(),
        };
        for (class, count) in [
            (WorkClass::Cpu, config.workers),
            (WorkClass::Io, config.io_workers),
        ] {
            for index in 0..count {
                let shared = Arc::clone(&kernel.shared);
                match thread::Builder::new()
                    .name(format!("lispm-{class:?}-{index}"))
                    .spawn(move || worker(shared, class))
                {
                    Ok(handle) => kernel.workers.push(handle),
                    Err(_) => return Err(Error::WorkerStart),
                }
            }
        }
        Ok(kernel)
    }

    /// Unique for this runtime instance within the current process.
    pub fn epoch(&self) -> u64 {
        self.shared.epoch
    }

    fn state(&self) -> Result<MutexGuard<'_, State>, Error> {
        self.shared.state.try_lock().map_err(|error| match error {
            TryLockError::WouldBlock => Error::Busy,
            TryLockError::Poisoned(_) => Error::Poisoned,
        })
    }

    /// Captured closure allocations are trusted adapter state, not accounted input.
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
        let reservation = input
            .capacity()
            .checked_add(max_output_bytes)
            .and_then(|n| n.checked_add(EVENT_OVERHEAD))
            .ok_or(Error::Capacity)?;
        let mut state = self.state()?;
        if self.shared.stopping.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        let config = self.shared.config;
        if state.records.len() >= config.max_requests
            || state.records.values().filter(|r| r.owner == owner).count()
                >= config.max_requests_per_owner
            || reservation > config.max_reserved_bytes.saturating_sub(state.reserved)
        {
            return Err(Error::Capacity);
        }
        let id = state.next_id;
        state.next_id = id.checked_add(1).ok_or(Error::IdExhausted)?;
        state.records.insert(
            id,
            Record {
                owner,
                generation,
                cancelled: Arc::new(AtomicBool::new(false)),
                output_limit: max_output_bytes,
                reservation,
                complete: false,
            },
        );
        state.reserved += reservation;
        state.queue.push_back(Task {
            id,
            input,
            job: Box::new(job),
            options,
            submitted: Instant::now(),
        });
        state.metrics.queue_high_water = state.metrics.queue_high_water.max(state.queue.len());
        state.metrics.reserved_high_water = state.metrics.reserved_high_water.max(state.reserved);
        drop(state);
        for worker in &self.workers {
            worker.thread().unpark();
        }
        Ok(id)
    }

    /// Returns false for unknown or already completed requests.
    pub fn cancel(&self, id: RequestId) -> Result<bool, Error> {
        let state = self.state()?;
        let Some(record) = state.records.get(&id).filter(|r| !r.complete) else {
            return Ok(false);
        };
        record.cancelled.store(true, Ordering::Release);
        self.shared.space.notify_all();
        Ok(true)
    }

    fn cancel_owner(&self, owner: Owner, before: Option<u64>) -> Result<usize, Error> {
        let state = self.state()?;
        let mut count = 0;
        for record in state
            .records
            .values()
            .filter(|r| r.owner == owner && !r.complete && before.is_none_or(|g| r.generation < g))
        {
            record.cancelled.store(true, Ordering::Release);
            count += 1;
        }
        self.shared.space.notify_all();
        Ok(count)
    }

    /// Cancels current owner work. The caller must prevent future submissions.
    pub fn close_owner(&self, owner: Owner) -> Result<usize, Error> {
        self.cancel_owner(owner, None)
    }
    pub fn supersede(&self, owner: Owner, generation: u64) -> Result<usize, Error> {
        self.cancel_owner(owner, Some(generation))
    }

    pub fn drain(&self, max_items: usize, max_bytes: usize) -> Result<Vec<Event>, Error> {
        let mut state = self.state()?;
        let mut events = Vec::new();
        let mut remaining = max_bytes;
        while events.len() < max_items {
            let Some(front) = state.ready.front() else {
                break;
            };
            let cost = front.byte_cost();
            if cost > remaining {
                if events.is_empty() {
                    state.rearm();
                    return Err(Error::DrainBudget { required: cost });
                }
                break;
            }
            let event = state.ready.pop_front().expect("front exists");
            if let Outcome::Chunk { bytes, .. } = &event.outcome {
                state.stream_items -= 1;
                state.stream_bytes -= EVENT_OVERHEAD + bytes.capacity();
            } else {
                let record = state
                    .records
                    .remove(&event.request)
                    .expect("accepted request");
                state.reserved -= record.reservation;
            }
            remaining -= cost;
            events.push(event);
        }
        state.rearm();
        drop(state);
        self.shared.space.notify_all();
        Ok(events)
    }

    pub fn stats(&self) -> Result<Stats, Error> {
        let state = self.state()?;
        Ok(Stats {
            outstanding: state.records.len(),
            queued: state.queue.len(),
            ready: state.ready.len(),
            reserved_bytes: state.reserved,
            closed: self.shared.stopping.load(Ordering::Acquire),
            stream_items: state.stream_items,
            stream_bytes: state.stream_bytes,
            queue_high_water: state.metrics.queue_high_water,
            reserved_high_water: state.metrics.reserved_high_water,
            stream_items_high_water: state.metrics.stream_items_high_water,
            stream_bytes_high_water: state.metrics.stream_bytes_high_water,
            completed: state.metrics.completed,
            cancelled: state.metrics.cancelled,
            max_queue_wait: state.metrics.max_queue_wait,
            max_run_time: state.metrics.max_run_time,
        })
    }

    /// Never joins workers or waits for adapters. Remaining outcomes can be drained.
    pub fn shutdown(&self) {
        self.shared.stopping.store(true, Ordering::Release);
        for worker in &self.workers {
            worker.thread().unpark();
        }
        self.shared.space.notify_all();
    }
    pub fn workers_finished(&self) -> bool {
        self.workers.iter().all(JoinHandle::is_finished)
    }
}
impl Drop for Kernel {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn worker(shared: Arc<Shared>, class: WorkClass) {
    loop {
        let (task, context) = {
            let Ok(mut state) = shared.state.lock() else {
                return;
            };
            while !state.queue.iter().any(|task| task.options.class == class) {
                if shared.stopping.load(Ordering::Acquire) {
                    return;
                }
                drop(state);
                // unpark retains a token even if submission/shutdown happens
                // before park. No timeout poll or check/wait lost-wakeup race.
                thread::park();
                let Ok(next) = shared.state.lock() else {
                    return;
                };
                state = next;
            }
            let task = scheduler::take(&mut state, class).expect("matching task");
            state.metrics.max_queue_wait =
                state.metrics.max_queue_wait.max(task.submitted.elapsed());
            let record = &state.records[&task.id];
            let context = Context {
                cancelled: Arc::clone(&record.cancelled),
                stopping: Arc::clone(&shared.stopping),
                max_output_bytes: record.output_limit,
                shared: Arc::downgrade(&shared),
                request: task.id,
            };
            (task, context)
        };
        let Task { id, input, job, .. } = task;
        let started = Instant::now();
        // Drop cancelled adapters and their captures on a worker, outside the state lock.
        let outcome = match catch_unwind(AssertUnwindSafe(|| {
            if context.is_cancelled() {
                return Outcome::Cancelled;
            }
            match job(context, input) {
                Ok(bytes) => Outcome::Success(bytes),
                Err(_) => Outcome::Failed,
            }
        })) {
            Ok(outcome) => outcome,
            Err(_) => Outcome::Panicked,
        };
        let Ok(mut state) = shared.state.lock() else {
            return;
        };
        let record = state.records.get_mut(&id).expect("accepted request");
        let outcome = if record.cancelled.load(Ordering::Acquire)
            || shared.stopping.load(Ordering::Acquire)
        {
            Outcome::Cancelled
        } else if matches!(&outcome, Outcome::Success(bytes) if bytes.capacity() > record.output_limit)
        {
            Outcome::OutputTooLarge
        } else {
            outcome
        };
        record.complete = true;
        let (owner, generation) = (record.owner, record.generation);
        state.metrics.completed = state.metrics.completed.saturating_add(1);
        if outcome == Outcome::Cancelled {
            state.metrics.cancelled = state.metrics.cancelled.saturating_add(1);
        }
        state.metrics.max_run_time = state.metrics.max_run_time.max(started.elapsed());
        state.ready.push_back(Event {
            epoch: shared.epoch,
            request: id,
            owner,
            generation,
            outcome,
        });
        state.signal();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontend_reports_busy_instead_of_waiting() {
        let kernel = Kernel::new(Config::default()).unwrap();
        let _guard = kernel.shared.state.lock().unwrap();
        assert_eq!(kernel.stats(), Err(Error::Busy));
        assert_eq!(kernel.cancel(1), Err(Error::Busy));
        assert_eq!(kernel.close_owner(1), Err(Error::Busy));
        assert_eq!(kernel.drain(1, 1024), Err(Error::Busy));
        assert_eq!(
            kernel.submit(1, 0, vec![], 0, |_, _| Ok(vec![])),
            Err(Error::Busy)
        );
        kernel.shutdown(); // Even shutdown does not need the state lock.
    }

    #[test]
    fn invalid_configuration_is_rejected() {
        assert!(matches!(
            Kernel::new(Config {
                workers: 0,
                ..Config::default()
            }),
            Err(Error::InvalidConfig)
        ));
    }
}
