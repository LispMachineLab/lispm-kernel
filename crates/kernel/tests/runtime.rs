// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

use lispm_kernel::{Config, Error, Event, JobOptions, Kernel, Outcome, RequestId, EVENT_OVERHEAD};
use std::collections::BTreeMap;
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
fn by_request(events: Vec<Event>) -> BTreeMap<RequestId, Outcome> {
    events.into_iter().map(|e| (e.request, e.outcome)).collect()
}
/// A job that must never run: it reports itself and panics, which the kernel
/// reports as `Panicked` even for cancelled requests.
fn must_not_run(
    ran: &mpsc::Sender<()>,
) -> impl FnOnce(lispm_kernel::Context, Vec<u8>) -> Result<Vec<u8>, lispm_kernel::JobFailed> + Send
{
    let ran = ran.clone();
    move |_, _| {
        let _ = ran.send(());
        panic!("cancelled adapter executed")
    }
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

// Regression: the queued adapter used to be skipped only by its worker, and its
// panic would have been masked as Cancelled. Now the cancel removes it from the
// queue at once, and a run would surface as Panicked.
#[test]
fn cancellation_skips_queued_adapter_and_cancels_running_result() {
    let kernel = Kernel::new(config()).unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let (ran_tx, ran_rx) = mpsc::channel();
    let first = start(&kernel, 1, move |_, _| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    });
    started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let second = retry(|| kernel.submit(1, 0, vec![], 0, must_not_run(&ran_tx))).unwrap();
    assert!(retry(|| kernel.cancel(second)).unwrap());
    let stats = retry(|| kernel.stats()).unwrap();
    assert_eq!((stats.queued, stats.ready, stats.cancelled), (0, 1, 1));
    assert!(retry(|| kernel.cancel(first)).unwrap());
    assert!(!retry(|| kernel.cancel(second)).unwrap());
    release_tx.send(()).unwrap();
    let result = by_request(events(&kernel, 2));
    assert_eq!(result[&second], Outcome::Cancelled);
    assert_eq!(result[&first], Outcome::Cancelled);
    assert!(ran_rx.try_recv().is_err());
    let stats = retry(|| kernel.stats()).unwrap();
    assert_eq!(
        (stats.cancelled, stats.panicked, stats.outstanding),
        (2, 0, 0)
    );
}

#[test]
fn cancel_releases_queued_slot_quota_and_bytes_immediately() {
    let kernel = Kernel::new(Config {
        max_requests_per_owner: 2,
        ..config()
    })
    .unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let (ran_tx, ran_rx) = mpsc::channel();
    start(&kernel, 1, move |_, _| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    });
    started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let running = retry(|| kernel.stats()).unwrap().reserved_bytes;
    let queued =
        retry(|| kernel.submit(1, 0, Vec::with_capacity(100), 50, must_not_run(&ran_tx))).unwrap();
    assert_eq!(
        retry(|| kernel.submit(1, 0, vec![], 0, |_, _| Ok(vec![]))),
        Err(Error::Capacity)
    );
    assert_eq!(retry(|| kernel.supersede(1, 1)).unwrap(), 2);
    let stats = retry(|| kernel.stats()).unwrap();
    // The cancelled queued request keeps only its final event's charge; the
    // running one keeps its reservation until its worker returns.
    assert_eq!(stats.reserved_bytes, running + EVENT_OVERHEAD);
    assert_eq!((stats.queued, stats.ready, stats.outstanding), (0, 1, 2));
    // Its slot is free before the frontend drains anything.
    let replacement = submit(&kernel, 1, 1);
    release_tx.send(()).unwrap();
    let result = by_request(events(&kernel, 3));
    assert_eq!(result[&queued], Outcome::Cancelled);
    assert_eq!(result[&replacement], Outcome::Success(vec![1, 2]));
    assert!(ran_rx.try_recv().is_err());
    assert_eq!(retry(|| kernel.stats()).unwrap().reserved_bytes, 0);
}

#[test]
fn per_owner_reserved_bytes_reject_one_owner_but_admit_another() {
    let kernel = Kernel::new(Config {
        // The blocked job holds EVENT_OVERHEAD; one more request may reserve 8 bytes.
        max_reserved_bytes_per_owner: 2 * EVENT_OVERHEAD + 8,
        ..config()
    })
    .unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    start(&kernel, 1, move |_, _| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    });
    started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(
        retry(|| kernel.submit(1, 0, vec![], 9, |_, _| Ok(vec![]))),
        Err(Error::Capacity)
    );
    retry(|| kernel.submit(1, 0, vec![], 8, |_, _| Ok(vec![]))).unwrap();
    assert_eq!(
        retry(|| kernel.submit(1, 0, vec![], 0, |_, _| Ok(vec![]))),
        Err(Error::Capacity)
    );
    retry(|| kernel.submit(2, 0, vec![], 8, |_, _| Ok(vec![]))).unwrap();
    release_tx.send(()).unwrap();
    assert_eq!(events(&kernel, 3).len(), 3);
}

#[test]
fn rejected_submission_returns_job_and_input_for_retry() {
    let kernel = Kernel::new(Config {
        max_requests: 1,
        ..config()
    })
    .unwrap();
    submit(&kernel, 1, 0);
    wait_ready(&kernel, 1);
    let rejected = loop {
        match kernel.try_submit_with_options(
            2,
            5,
            vec![4, 2],
            2,
            JobOptions::default(),
            |_, input| Ok(input),
        ) {
            Err(rejected) if rejected.error == Error::Busy => thread::yield_now(),
            Err(rejected) => break rejected,
            Ok(id) => panic!("admitted {id} beyond max_requests"),
        }
    };
    assert_eq!(rejected.error, Error::Capacity);
    assert_eq!(rejected.input, vec![4, 2]);
    assert_eq!(
        rejected.to_string(),
        "submission rejected: admission capacity exhausted"
    );
    events(&kernel, 1);
    let lispm_kernel::Rejected { input, job, .. } = rejected;
    let id = loop {
        match kernel.try_submit_with_options(2, 5, input.clone(), 2, JobOptions::default(), job) {
            Err(rejected) if rejected.error == Error::Busy => thread::yield_now(),
            result => break result.unwrap(),
        }
    };
    let event = events(&kernel, 1).pop().unwrap();
    assert_eq!(
        (event.request, event.outcome),
        (id, Outcome::Success(vec![4, 2]))
    );
    kernel.shutdown();
    let rejected = kernel
        .try_submit_with_options(2, 5, vec![1], 1, JobOptions::default(), job)
        .unwrap_err();
    assert_eq!((rejected.error, rejected.input), (Error::Closed, vec![1]));
}

#[test]
fn owner_supersede_does_not_cancel_newer_or_other_owner() {
    let kernel = Kernel::new(config()).unwrap();
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let blocker = start(&kernel, 9, move |_, _| {
        started_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        Ok(vec![])
    });
    started_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let old = submit(&kernel, 1, 1);
    let current = submit(&kernel, 1, 2);
    let other = submit(&kernel, 2, 1);
    assert_eq!(retry(|| kernel.supersede(1, 2)).unwrap(), 1);
    release_tx.send(()).unwrap();
    let result = by_request(events(&kernel, 4));
    assert_eq!(result[&old], Outcome::Cancelled);
    assert_eq!(result[&blocker], Outcome::Success(vec![]));
    assert_eq!(result[&current], Outcome::Success(vec![1, 2]));
    assert_eq!(result[&other], Outcome::Success(vec![1, 2]));
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
    let stats = retry(|| kernel.stats()).unwrap();
    assert_eq!((stats.failed, stats.panicked, stats.cancelled), (1, 1, 0));
}

/// A panic payload whose own `Drop` panics.
struct PanicsOnDrop;
impl Drop for PanicsOnDrop {
    fn drop(&mut self) {
        panic!("payload drop");
    }
}

// Regression: dropping such a payload outside `catch_unwind` killed the worker, so
// the request never got a final event and the pool shrank for good.
#[test]
fn panic_payload_that_panics_on_drop_does_not_kill_worker() {
    let kernel = Kernel::new(config()).unwrap();
    retry(|| kernel.submit(1, 0, vec![], 0, |_, _| std::panic::panic_any(PanicsOnDrop))).unwrap();
    submit(&kernel, 1, 0);
    let result = events(&kernel, 2);
    assert_eq!(result[0].outcome, Outcome::Panicked);
    assert!(matches!(result[1].outcome, Outcome::Success(_)));
}

// Regression: any outcome of a cancelled request used to become Cancelled, which
// hid adapter panics. A Failed result of a cancelled request may stay Cancelled.
#[test]
fn cancelled_request_that_panics_is_reported_as_panicked() {
    let kernel = Kernel::new(config()).unwrap();
    let (tx, rx) = mpsc::channel();
    let panicking = start(&kernel, 1, move |context, _| {
        tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !context.is_cancelled() && Instant::now() < deadline {
            thread::yield_now();
        }
        panic!("adapter panic after cancellation")
    });
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(retry(|| kernel.cancel(panicking)).unwrap());
    let (tx, rx) = mpsc::channel();
    let failing = start(&kernel, 1, move |context, _| {
        tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !context.is_cancelled() && Instant::now() < deadline {
            thread::yield_now();
        }
        Err(lispm_kernel::JobFailed)
    });
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(retry(|| kernel.cancel(failing)).unwrap());
    let result = by_request(events(&kernel, 2));
    assert_eq!(result[&panicking], Outcome::Panicked);
    assert_eq!(result[&failing], Outcome::Cancelled);
    let stats = retry(|| kernel.stats()).unwrap();
    assert_eq!((stats.panicked, stats.cancelled, stats.failed), (1, 1, 0));
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
    let (ran_tx, ran_rx) = mpsc::channel();
    // The queued adapter is skipped by its worker; running it would be Panicked.
    retry(|| kernel.submit(2, 0, vec![], 0, must_not_run(&ran_tx))).unwrap();
    kernel.shutdown();
    assert!(!kernel.workers_finished());
    assert_eq!(
        retry(|| kernel.submit(2, 0, vec![], 0, |_, _| Ok(vec![]))),
        Err(Error::Closed)
    );
    release_tx.send(()).unwrap();
    let outcomes: Vec<_> = events(&kernel, 2).into_iter().map(|e| e.outcome).collect();
    assert_eq!(outcomes, vec![Outcome::Cancelled, Outcome::Cancelled]);
    assert!(ran_rx.try_recv().is_err());
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
