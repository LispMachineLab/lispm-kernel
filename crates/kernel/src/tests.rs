// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Kernel tests that need private state: wakeups, lock recovery and races.

use super::*;
use crate::ledger::Usage;
use std::collections::BTreeMap;
use std::sync::mpsc;

fn wait_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !condition() {
        assert!(Instant::now() < deadline, "condition not reached");
        thread::yield_now();
    }
}

fn retry<T>(mut call: impl FnMut() -> Result<T, Error>) -> T {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match call() {
            Err(Error::Busy) if Instant::now() < deadline => thread::yield_now(),
            result => return result.unwrap(),
        }
    }
}

#[test]
fn frontend_reports_busy_instead_of_waiting() {
    let kernel = Kernel::new(Config::default()).unwrap();
    let _guard = kernel.shared.state.lock().unwrap();
    assert_eq!(kernel.stats(), Err(Error::Busy));
    assert_eq!(kernel.cancel(1), Err(Error::Busy));
    assert_eq!(kernel.close_owner(1), Err(Error::Busy));
    assert_eq!(kernel.supersede(1, 1), Err(Error::Busy));
    assert_eq!(kernel.drain(1, 1024), Err(Error::Busy));
    assert_eq!(
        kernel.submit(1, 0, vec![], 0, |_, _| Ok(vec![])),
        Err(Error::Busy)
    );
    #[cfg(unix)]
    assert_eq!(kernel.detach_notifications(), Ok(()));
    kernel.shutdown(); // Even shutdown does not need the state lock.
}

#[test]
fn invalid_configuration_is_rejected() {
    let invalid = [
        Config {
            workers: 0,
            ..Config::default()
        },
        Config {
            io_workers: 0,
            ..Config::default()
        },
        Config {
            max_stream_items_per_owner: 0,
            ..Config::default()
        },
        Config {
            max_stream_bytes_per_owner: EVENT_OVERHEAD - 1,
            ..Config::default()
        },
        Config {
            max_reserved_bytes_per_owner: EVENT_OVERHEAD - 1,
            ..Config::default()
        },
        Config {
            max_reserved_bytes: EVENT_OVERHEAD - 1,
            ..Config::default()
        },
        Config {
            max_requests_per_owner: 0,
            ..Config::default()
        },
    ];
    for config in invalid {
        assert!(matches!(Kernel::new(config), Err(Error::InvalidConfig)));
    }
    // Per-owner limits above the global ones are valid; the global limit binds.
    assert!(Kernel::new(Config {
        max_stream_items: 1,
        max_reserved_bytes: EVENT_OVERHEAD,
        ..Config::default()
    })
    .is_ok());
}

fn idle_counts(kernel: &Kernel) -> (usize, usize) {
    let state = kernel.shared.state.lock().unwrap();
    (
        state.idle.count(WorkClass::Cpu),
        state.idle.count(WorkClass::Io),
    )
}

/// Submit a CPU job that reports its start and blocks until released.
fn blocked(kernel: &Kernel, started: &mpsc::Sender<()>) -> mpsc::Sender<()> {
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let started = started.clone();
    let job = Arc::new(Mutex::new(Some(move |_: Context, _: Vec<u8>| {
        started.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    })));
    retry(|| {
        let job = Arc::clone(&job);
        kernel.submit(1, 0, vec![], 0, move |context, input| {
            let job = job.lock().unwrap().take().unwrap();
            job(context, input)
        })
    });
    release_tx
}

// A submission claims exactly one idle worker of its class; an idle worker of the
// class picks up new work while another is busy, and the other pool sleeps on.
#[test]
fn submit_wakes_one_idle_worker_of_the_task_class_only() {
    let kernel = Kernel::new(Config {
        workers: 2,
        io_workers: 2,
        ..Config::default()
    })
    .unwrap();
    wait_until(|| idle_counts(&kernel) == (2, 2));
    let (started_tx, started_rx) = mpsc::channel();
    let first = blocked(&kernel, &started_tx);
    assert_eq!(idle_counts(&kernel), (1, 2));
    started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let second = blocked(&kernel, &started_tx);
    assert_eq!(idle_counts(&kernel), (0, 2));
    started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    first.send(()).unwrap();
    second.send(()).unwrap();
    wait_until(|| retry(|| kernel.stats()).completed == 2);
    wait_until(|| idle_counts(&kernel) == (2, 2));
}

/// Poison the state lock while every other worker is parked, so nobody recovers
/// it before the test observes it.
fn poison(kernel: &Kernel, corrupt: impl FnOnce(&mut State) + Send + 'static) {
    let shared = Arc::clone(&kernel.shared);
    let result = thread::spawn(move || {
        let mut state = shared.state.lock().unwrap();
        corrupt(&mut state);
        panic!("poison the state lock");
    })
    .join();
    assert!(result.is_err());
    assert!(kernel.shared.state.is_poisoned());
}

#[test]
fn poisoned_lock_is_recovered_when_the_invariant_holds() {
    let kernel = Kernel::new(Config::default()).unwrap();
    wait_until(|| idle_counts(&kernel) == (2, 2));
    poison(&kernel, |_| {});
    assert!(kernel.stats().is_ok());
    assert!(!kernel.shared.state.is_poisoned());
    // Workers poisoned mid-run still publish their outcome.
    let (started_tx, started_rx) = mpsc::channel();
    let release = blocked(&kernel, &started_tx);
    started_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    poison(&kernel, |_| {});
    release.send(()).unwrap();
    wait_until(|| retry(|| kernel.stats()).ready == 1);
    let events = retry(|| kernel.drain(1, 1024));
    assert_eq!(events[0].outcome, Outcome::Success(vec![]));
}

#[test]
fn poisoned_lock_with_a_broken_invariant_is_reported() {
    let kernel = Kernel::new(Config::default()).unwrap();
    wait_until(|| idle_counts(&kernel) == (2, 2));
    poison(&kernel, |state| state.ledger.add(1, Usage::chunk(1)));
    assert_eq!(kernel.stats(), Err(Error::Poisoned));
    assert_eq!(kernel.drain(1, 1024), Err(Error::Poisoned));
    assert_eq!(
        kernel.submit(1, 0, vec![], 0, |_, _| Ok(vec![])),
        Err(Error::Poisoned)
    );
}

/// Deterministic per-thread choices for the stress test.
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

fn stress_job(kind: u64) -> impl FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send {
    move |context, _| match kind {
        0 => Ok(vec![1]),
        1 => {
            for n in 0..6u8 {
                context.emit(vec![n]).map_err(|_| JobFailed)?;
            }
            Ok(vec![])
        }
        2 => {
            for n in 0..6u8 {
                let _ = context.try_replace(u64::from(n % 2), vec![n]);
            }
            Ok(vec![])
        }
        3 => {
            for _ in 0..200 {
                if context.is_cancelled() {
                    break;
                }
                thread::yield_now();
            }
            Ok(vec![])
        }
        _ => Err(JobFailed),
    }
}

fn submitter(kernel: &Kernel, seed: u64, count: usize) -> Vec<RequestId> {
    let mut random = Lcg(seed);
    let mut accepted = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while accepted.len() < count {
        assert!(Instant::now() < deadline, "submissions starved");
        let owner = random.next(4);
        let options = JobOptions {
            class: if random.next(2) == 0 {
                WorkClass::Cpu
            } else {
                WorkClass::Io
            },
            priority: [Priority::Low, Priority::Normal, Priority::High][random.next(3) as usize],
        };
        let job = stress_job(random.next(5));
        match kernel.submit_with_options(owner, random.next(3), vec![], 4, options, job) {
            Ok(id) => accepted.push(id),
            Err(Error::Busy | Error::Capacity) => thread::yield_now(),
            Err(error) => panic!("{error:?}"),
        }
    }
    accepted
}

fn canceller(kernel: &Kernel, seed: u64, done: &AtomicBool) {
    let mut random = Lcg(seed);
    while !done.load(Ordering::Acquire) {
        let owner = random.next(4);
        let _ = match random.next(3) {
            0 => kernel.cancel(random.next(400) + 1).map(usize::from),
            1 => kernel.close_owner(owner),
            _ => kernel.supersede(owner, random.next(3)),
        };
        thread::yield_now();
    }
}

/// Record drained events; panic on a second final or a chunk after a final.
fn record(finals: &mut BTreeMap<RequestId, usize>, events: Vec<Event>) {
    for event in events {
        let count = finals.entry(event.request).or_default();
        assert_eq!(*count, 0, "event after the final of {}", event.request);
        if !matches!(event.outcome, Outcome::Chunk { .. }) {
            *count += 1;
        }
    }
}

// Bounded race: submitters, a canceller (cancel/close/supersede) and a drainer run
// concurrently. Every accepted request yields exactly one final, never followed by
// a chunk; the table invariant holds throughout; everything is released at the end.
#[test]
fn cancel_close_supersede_and_drain_races_keep_one_final_per_request() {
    let kernel = Kernel::new(Config {
        workers: 2,
        io_workers: 2,
        max_requests: 12,
        max_requests_per_owner: 4,
        max_stream_items: 6,
        max_stream_items_per_owner: 2,
        max_stream_bytes: 6 * (EVENT_OVERHEAD + 8),
        max_stream_bytes_per_owner: 2 * (EVENT_OVERHEAD + 8),
        ..Config::default()
    })
    .unwrap();
    let done = AtomicBool::new(false);
    let mut finals = BTreeMap::new();
    let accepted = thread::scope(|scope| {
        let submitters: Vec<_> = (0..2)
            .map(|seed| {
                let kernel = &kernel;
                scope.spawn(move || submitter(kernel, seed + 11, 150))
            })
            .collect();
        let cancel = scope.spawn(|| canceller(&kernel, 7, &done));
        let mut random = Lcg(3);
        let mut rounds = 0usize;
        while !submitters.iter().all(|handle| handle.is_finished()) {
            let budget = random.next(4) as usize * EVENT_OVERHEAD;
            if let Ok(events) = kernel.drain(random.next(4) as usize, budget) {
                record(&mut finals, events);
            }
            rounds += 1;
            if rounds.is_multiple_of(64) {
                kernel.shared.lock().ok().unwrap().audit().unwrap();
            }
            thread::yield_now();
        }
        done.store(true, Ordering::Release);
        cancel.join().unwrap();
        submitters
            .into_iter()
            .flat_map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>()
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while finals.values().filter(|count| **count == 1).count() < accepted.len() {
        assert!(Instant::now() < deadline, "finals missing");
        if let Ok(events) = kernel.drain(16, usize::MAX) {
            record(&mut finals, events);
        }
        thread::yield_now();
    }
    kernel.shared.lock().ok().unwrap().audit().unwrap();
    assert_eq!(finals.keys().copied().collect::<Vec<_>>(), {
        let mut ids = accepted;
        ids.sort_unstable();
        ids
    });
    let stats = retry(|| kernel.stats());
    assert_eq!(stats.outstanding, 0);
    assert_eq!(stats.reserved_bytes, 0);
    assert_eq!((stats.stream_items, stats.stream_bytes), (0, 0));
    assert_eq!(stats.completed, 300);
}
