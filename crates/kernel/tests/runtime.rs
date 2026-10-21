// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

use lispm_kernel::{Config, Error, Event, Kernel, Outcome, EVENT_OVERHEAD};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

fn config() -> Config {
    Config {
        workers: 1,
        max_requests: 8,
        max_requests_per_owner: 4,
        max_reserved_bytes: 4096,
        ..Config::default()
    }
}
fn retry<T>(mut call: impl FnMut() -> Result<T, Error>) -> Result<T, Error> {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match call() {
            Err(Error::Busy) if Instant::now() < deadline => thread::yield_now(),
            result => return result,
        }
    }
}
fn wait_ready(kernel: &Kernel, count: usize) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if retry(|| kernel.stats()).unwrap().ready >= count {
            return;
        }
        assert!(Instant::now() < deadline, "worker did not produce outcomes");
        thread::yield_now();
    }
}
fn events(kernel: &Kernel, count: usize) -> Vec<Event> {
    wait_ready(kernel, count);
    retry(|| kernel.drain(count, 4096)).unwrap()
}
fn submit(kernel: &Kernel, owner: u64, generation: u64) -> u64 {
    retry(|| kernel.submit(owner, generation, vec![1, 2], 2, |_, input| Ok(input))).unwrap()
}

fn start<F>(kernel: &Kernel, owner: u64, job: F) -> u64
where
    F: FnOnce(lispm_kernel::Context, Vec<u8>) -> Result<Vec<u8>, lispm_kernel::JobFailed>
        + Send
        + 'static,
{
    let job = std::sync::Arc::new(std::sync::Mutex::new(Some(job)));
    retry(|| {
        let job = job.clone();
        kernel.submit(owner, 0, vec![], 0, move |context, input| {
            let adapter = job.lock().unwrap().take().unwrap();
            adapter(context, input)
        })
    })
    .unwrap()
}

#[test]
fn input_and_identity_roundtrip() {
    let kernel = Kernel::new(config()).unwrap();
    let id = submit(&kernel, 7, 3);
    assert_eq!(
        events(&kernel, 1),
        vec![Event {
            epoch: kernel.epoch(),
            request: id,
            owner: 7,
            generation: 3,
            outcome: Outcome::Success(vec![1, 2])
        }]
    );
    assert_eq!(retry(|| kernel.stats()).unwrap().reserved_bytes, 0);
    assert!(!retry(|| kernel.cancel(id)).unwrap());
}

#[test]
fn undrained_outcomes_hold_slots_and_owner_quota() {
    let kernel = Kernel::new(Config {
        max_requests: 2,
        max_requests_per_owner: 1,
        ..config()
    })
    .unwrap();
    submit(&kernel, 1, 0);
    wait_ready(&kernel, 1);
    assert_eq!(
        retry(|| kernel.submit(1, 0, vec![], 0, |_, _| Ok(vec![]))),
        Err(Error::Capacity)
    );
    submit(&kernel, 2, 0);
    wait_ready(&kernel, 2);
    assert_eq!(
        retry(|| kernel.submit(3, 0, vec![], 0, |_, _| Ok(vec![]))),
        Err(Error::Capacity)
    );
    assert_eq!(retry(|| kernel.drain(1, 4096)).unwrap().len(), 1);
    submit(&kernel, 1, 1);
}

#[test]
fn byte_reservation_and_overflow_are_rejected() {
    let kernel = Kernel::new(Config {
        max_reserved_bytes: EVENT_OVERHEAD + 4,
        ..config()
    })
    .unwrap();
    submit(&kernel, 1, 0);
    wait_ready(&kernel, 1);
    assert_eq!(
        retry(|| kernel.stats()).unwrap().reserved_bytes,
        EVENT_OVERHEAD + 4
    );
    assert_eq!(
        retry(|| kernel.submit(2, 0, vec![], 0, |_, _| Ok(vec![]))),
        Err(Error::Capacity)
    );
    assert_eq!(
        kernel.submit(2, 0, vec![], usize::MAX, |_, _| Ok(vec![])),
        Err(Error::Capacity)
    );
    events(&kernel, 1);
    submit(&kernel, 1, 1);
}

#[test]
fn drain_preserves_event_when_byte_budget_is_too_small() {
    let kernel = Kernel::new(config()).unwrap();
    submit(&kernel, 1, 0);
    wait_ready(&kernel, 1);
    assert!(retry(|| kernel.drain(0, 0)).unwrap().is_empty());
    assert_eq!(
        retry(|| kernel.drain(1, EVENT_OVERHEAD)),
        Err(Error::DrainBudget {
            required: EVENT_OVERHEAD + 2
        })
    );
    assert_eq!(events(&kernel, 1).len(), 1);
}

#[test]
fn cancellation_skips_queued_adapter_and_cancels_running_result() {
    let kernel = Kernel::new(config()).unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let first = start(&kernel, 1, move |_, _| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    });
    started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let second =
        retry(|| kernel.submit(1, 0, vec![], 0, |_, _| panic!("cancelled adapter executed")))
            .unwrap();
    assert!(retry(|| kernel.cancel(second)).unwrap());
    assert!(retry(|| kernel.cancel(first)).unwrap());
    release_tx.send(()).unwrap();
    let result = events(&kernel, 2);
    assert_eq!(
        result.iter().map(|e| &e.outcome).collect::<Vec<_>>(),
        vec![&Outcome::Cancelled, &Outcome::Cancelled]
    );
}

#[test]
fn owner_supersede_does_not_cancel_newer_or_other_owner() {
    let kernel = Kernel::new(config()).unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    start(&kernel, 9, move |_, _| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    });
    started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    submit(&kernel, 1, 1);
    submit(&kernel, 1, 2);
    submit(&kernel, 2, 1);
    assert_eq!(retry(|| kernel.supersede(1, 2)).unwrap(), 1);
    release_tx.send(()).unwrap();
    let result = events(&kernel, 4);
    assert_eq!(result[1].outcome, Outcome::Cancelled);
    assert!(matches!(result[2].outcome, Outcome::Success(_)));
    assert!(matches!(result[3].outcome, Outcome::Success(_)));
}

#[test]
fn failure_panic_and_output_limit_do_not_kill_worker() {
    let kernel = Kernel::new(config()).unwrap();
    retry(|| kernel.submit(1, 0, vec![], 0, |_, _| Err(lispm_kernel::JobFailed))).unwrap();
    retry(|| kernel.submit(1, 0, vec![], 0, |_, _| panic!("adapter panic"))).unwrap();
    retry(|| kernel.submit(1, 0, vec![], 1, |_, _| Ok(vec![0; 2]))).unwrap();
    submit(&kernel, 1, 0);
    let result = events(&kernel, 4);
    assert_eq!(result[0].outcome, Outcome::Failed);
    assert_eq!(result[1].outcome, Outcome::Panicked);
    assert_eq!(result[2].outcome, Outcome::OutputTooLarge);
    assert!(matches!(result[3].outcome, Outcome::Success(_)));
}

#[test]
fn shutdown_returns_while_adapter_is_blocked_and_retains_cancellations() {
    let kernel = Kernel::new(config()).unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    start(&kernel, 1, move |_, _| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    });
    started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    submit(&kernel, 2, 0);
    kernel.shutdown();
    assert!(!kernel.workers_finished());
    assert_eq!(
        retry(|| kernel.submit(2, 0, vec![], 0, |_, _| Ok(vec![]))),
        Err(Error::Closed)
    );
    release_tx.send(()).unwrap();
    assert!(events(&kernel, 2)
        .iter()
        .all(|e| e.outcome == Outcome::Cancelled));
    let deadline = Instant::now() + Duration::from_secs(3);
    while !kernel.workers_finished() {
        assert!(Instant::now() < deadline);
        thread::yield_now();
    }
}

#[test]
fn workers_execute_concurrently() {
    let kernel = Kernel::new(Config {
        workers: 2,
        ..config()
    })
    .unwrap();
    let (tx, rx) = mpsc::channel();
    let mut releases = Vec::new();
    for owner in 0..2 {
        let (release_tx, release_rx) = mpsc::channel();
        releases.push(release_tx);
        let tx = tx.clone();
        start(&kernel, owner, move |_, _| {
            tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(vec![])
        });
        rx.recv_timeout(Duration::from_secs(3)).unwrap();
    }
    for tx in releases {
        tx.send(()).unwrap();
    }
    assert_eq!(events(&kernel, 2).len(), 2);
}

#[test]
fn allocated_capacity_counts_even_for_empty_vectors() {
    let kernel = Kernel::new(Config {
        max_reserved_bytes: 100,
        ..config()
    })
    .unwrap();
    assert_eq!(
        retry(|| kernel.submit(1, 0, Vec::with_capacity(128), 0, |_, input| Ok(input))),
        Err(Error::Capacity)
    );
    retry(|| kernel.submit(1, 0, vec![], 1, |_, _| Ok(Vec::with_capacity(128)))).unwrap();
    assert_eq!(events(&kernel, 1)[0].outcome, Outcome::OutputTooLarge);
}

#[test]
fn close_owner_is_visible_to_running_cooperative_job() {
    let kernel = Kernel::new(config()).unwrap();
    let (tx, rx) = mpsc::channel();
    start(&kernel, 8, move |context, _| {
        tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !context.is_cancelled() {
            assert!(Instant::now() < deadline);
            thread::yield_now();
        }
        Ok(vec![])
    });
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(retry(|| kernel.close_owner(8)).unwrap(), 1);
    assert_eq!(events(&kernel, 1)[0].outcome, Outcome::Cancelled);
}

#[test]
fn restarted_runtime_has_distinct_epoch() {
    let first = Kernel::new(config()).unwrap();
    let second = Kernel::new(config()).unwrap();
    assert_ne!(first.epoch(), second.epoch());
    submit(&first, 1, 0);
    submit(&second, 1, 0);
    let a = events(&first, 1).pop().unwrap();
    let b = events(&second, 1).pop().unwrap();
    assert_eq!(a.request, b.request);
    assert_ne!(a.epoch, b.epoch);
}

#[test]
fn idle_shutdown_and_submission_do_not_lose_unpark_tokens() {
    for turn in 0..32 {
        let kernel = Kernel::new(config()).unwrap();
        if turn % 2 == 0 {
            // Exercise submission both before and after workers can enter park.
            submit(&kernel, 1, 0);
            assert_eq!(events(&kernel, 1).len(), 1);
        }
        kernel.shutdown();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !kernel.workers_finished() {
            assert!(
                Instant::now() < deadline,
                "idle worker lost shutdown wakeup"
            );
            thread::yield_now();
        }
    }
}
