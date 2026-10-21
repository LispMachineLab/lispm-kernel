// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

use lispm_kernel::{
    Config, Context, EmitFailure, Error, JobFailed, JobOptions, Kernel, Outcome, WorkClass,
    EVENT_OVERHEAD,
};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

fn retry<T>(mut call: impl FnMut() -> Result<T, Error>) -> T {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match call() {
            Err(Error::Busy) if Instant::now() < deadline => thread::yield_now(),
            result => return result.unwrap(),
        }
    }
}
fn start<F>(kernel: &Kernel, options: JobOptions, job: F) -> u64
where
    F: FnOnce(Context, Vec<u8>) -> Result<Vec<u8>, JobFailed> + Send + 'static,
{
    let job = Arc::new(Mutex::new(Some(job)));
    retry(|| {
        let job = job.clone();
        kernel.submit_with_options(1, 0, vec![], 0, options, move |context, input| {
            let job = job.lock().unwrap().take().unwrap();
            job(context, input)
        })
    })
}
fn wait(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(3);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out");
        thread::yield_now();
    }
}
fn kernel() -> Kernel {
    Kernel::new(Config {
        workers: 1,
        io_workers: 1,
        max_stream_items: 1,
        max_stream_bytes: EVENT_OVERHEAD + 4,
        ..Config::default()
    })
    .unwrap()
}

#[test]
fn reliable_chunks_apply_backpressure_without_using_final_reservation() {
    let kernel = kernel();
    start(&kernel, JobOptions::default(), |ctx, _| {
        ctx.try_emit(vec![1, 2]).unwrap();
        let error = ctx.try_emit(vec![3, 4]).unwrap_err();
        assert_eq!(error.reason, EmitFailure::Backpressure);
        assert_eq!(error.bytes, vec![3, 4]);
        Ok(vec![])
    });
    wait(|| retry(|| kernel.stats()).completed == 1);
    let stats = retry(|| kernel.stats());
    assert_eq!(stats.stream_items, 1);
    assert_eq!(stats.ready, 2); // A full stream never loses the final outcome.
    assert_eq!(stats.stream_bytes_high_water, EVENT_OVERHEAD + 2);
    let result = retry(|| kernel.drain(1, 1024));
    assert!(matches!(
        result[0].outcome,
        Outcome::Chunk { key: None, .. }
    ));
    assert_eq!(retry(|| kernel.stats()).outstanding, 1);
    let result = retry(|| kernel.drain(1, 1024));
    assert_eq!(result[0].outcome, Outcome::Success(vec![]));
    assert_eq!(retry(|| kernel.stats()).outstanding, 0);
}

#[test]
fn coalescing_keeps_latest_state_and_adjusts_allocation_accounting() {
    let kernel = kernel();
    start(&kernel, JobOptions::default(), |ctx, _| {
        ctx.try_replace(7, vec![1; 4]).unwrap();
        ctx.try_replace(7, vec![2]).unwrap();
        assert_eq!(
            ctx.try_replace(8, vec![3]).unwrap_err().reason,
            EmitFailure::Backpressure
        );
        Ok(vec![])
    });
    wait(|| retry(|| kernel.stats()).completed == 1);
    assert_eq!(retry(|| kernel.stats()).stream_bytes, EVENT_OVERHEAD + 1);
    let result = retry(|| kernel.drain(2, 1024));
    assert_eq!(
        result[0].outcome,
        Outcome::Chunk {
            key: Some(7),
            bytes: vec![2]
        }
    );
    assert_eq!(result[1].outcome, Outcome::Success(vec![]));
}

#[test]
fn waiting_emitter_resumes_when_frontend_drains() {
    let kernel = kernel();
    let (tx, rx) = mpsc::channel();
    start(&kernel, JobOptions::default(), move |ctx, _| {
        ctx.emit(vec![1]).unwrap();
        tx.send(()).unwrap();
        ctx.emit(vec![2]).unwrap();
        Ok(vec![])
    });
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(matches!(
        retry(|| kernel.drain(1, 1024))[0].outcome,
        Outcome::Chunk { .. }
    ));
    wait(|| retry(|| kernel.stats()).completed == 1);
    let result = retry(|| kernel.drain(2, 1024));
    assert_eq!(
        result[0].outcome,
        Outcome::Chunk {
            key: None,
            bytes: vec![2]
        }
    );
    assert_eq!(result[1].outcome, Outcome::Success(vec![]));
}

#[test]
fn cancellation_interrupts_backpressure_wait_and_retains_prior_chunk() {
    let kernel = kernel();
    let (tx, rx) = mpsc::channel();
    let id = start(&kernel, JobOptions::default(), move |ctx, _| {
        ctx.emit(vec![1]).unwrap();
        tx.send(()).unwrap();
        assert_eq!(
            ctx.emit(vec![2]).unwrap_err().reason,
            EmitFailure::Cancelled
        );
        Ok(vec![])
    });
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(retry(|| kernel.cancel(id)));
    wait(|| retry(|| kernel.stats()).completed == 1);
    let result = retry(|| kernel.drain(2, 1024));
    assert!(matches!(result[0].outcome, Outcome::Chunk { .. }));
    assert_eq!(result[1].outcome, Outcome::Cancelled);
    assert_eq!(retry(|| kernel.stats()).cancelled, 1);
}

#[test]
fn oversized_chunk_is_rejected_without_waiting() {
    let kernel = kernel();
    start(&kernel, JobOptions::default(), |ctx, _| {
        assert_eq!(
            ctx.emit(Vec::with_capacity(5)).unwrap_err().reason,
            EmitFailure::TooLarge
        );
        Ok(vec![])
    });
    wait(|| retry(|| kernel.stats()).completed == 1);
    assert_eq!(retry(|| kernel.stats()).stream_items, 0);
}

#[test]
fn blocked_io_does_not_occupy_cpu_worker() {
    let kernel = kernel();
    let (tx, rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    start(
        &kernel,
        JobOptions {
            class: WorkClass::Io,
            ..JobOptions::default()
        },
        move |_, _| {
            tx.send(()).unwrap();
            release_rx.recv_timeout(Duration::from_secs(3)).unwrap();
            Ok(vec![])
        },
    );
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    start(&kernel, JobOptions::default(), |_, _| Ok(vec![]));
    wait(|| retry(|| kernel.stats()).completed == 1);
    release_tx.send(()).unwrap();
    wait(|| retry(|| kernel.stats()).completed == 2);
}

#[cfg(unix)]
#[test]
fn notifications_coalesce_rearm_partial_drains_and_recover_budget_errors() {
    use std::io::{ErrorKind, Read};
    let kernel = kernel();
    let mut reader = retry(|| kernel.attach_notifications());
    start(&kernel, JobOptions::default(), |ctx, _| {
        ctx.emit(vec![1]).unwrap();
        Ok(vec![])
    });
    wait(|| retry(|| kernel.stats()).completed == 1);
    let mut buffer = [0; 32];
    assert_eq!(reader.read(&mut buffer).unwrap(), 1); // Two events, one hint.
    assert_eq!(
        reader.read(&mut buffer).unwrap_err().kind(),
        ErrorKind::WouldBlock
    );
    assert_eq!(retry(|| kernel.drain(1, 1024)).len(), 1);
    assert_eq!(reader.read(&mut buffer).unwrap(), 1); // Partial drain rearms.
    assert!(matches!(kernel.drain(1, 0), Err(Error::DrainBudget { .. })));
    assert_eq!(reader.read(&mut buffer).unwrap(), 1); // Even budget error rearms.
    assert_eq!(retry(|| kernel.drain(1, 1024)).len(), 1);
    assert_eq!(
        reader.read(&mut buffer).unwrap_err().kind(),
        ErrorKind::WouldBlock
    );
    start(&kernel, JobOptions::default(), |_, _| Ok(vec![]));
    wait(|| retry(|| kernel.stats()).completed == 2);
    assert_eq!(reader.read(&mut buffer).unwrap(), 1); // New work cannot lose wakeup.
    retry(|| kernel.detach_notifications());
    assert_eq!(reader.read(&mut buffer).unwrap(), 0);
}

#[cfg(unix)]
#[test]
fn dropped_reader_does_not_kill_workers_and_reregistration_wakes_retained_work() {
    use std::io::Read;
    let kernel = kernel();
    drop(retry(|| kernel.attach_notifications()));
    start(&kernel, JobOptions::default(), |_, _| Ok(vec![]));
    wait(|| retry(|| kernel.stats()).completed == 1);
    let mut reader = retry(|| kernel.attach_notifications());
    assert_eq!(reader.read(&mut [0; 1]).unwrap(), 1);
    assert_eq!(retry(|| kernel.drain(1, 1024)).len(), 1);
}

#[test]
fn shutdown_wakes_blocked_emitter() {
    let kernel = kernel();
    let (tx, rx) = mpsc::channel();
    start(&kernel, JobOptions::default(), move |ctx, _| {
        ctx.emit(vec![1]).unwrap();
        tx.send(()).unwrap();
        assert_eq!(
            ctx.emit(vec![2]).unwrap_err().reason,
            EmitFailure::Cancelled
        );
        Ok(vec![])
    });
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    kernel.shutdown();
    wait(|| kernel.workers_finished());
    let result = retry(|| kernel.drain(2, 1024));
    assert_eq!(result[1].outcome, Outcome::Cancelled);
}

#[test]
fn multiple_producers_and_slow_consumer_stay_bounded() {
    let kernel = Kernel::new(Config {
        workers: 2,
        max_stream_items: 2,
        max_stream_bytes: 2 * (EVENT_OVERHEAD + 4),
        ..Config::default()
    })
    .unwrap();
    for _ in 0..2 {
        start(&kernel, JobOptions::default(), |ctx, _| {
            for n in 0..100u32 {
                ctx.emit(n.to_le_bytes().to_vec()).unwrap();
            }
            Ok(vec![])
        });
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut chunks = [0usize; 2];
    let mut finals = 0;
    while finals < 2 {
        assert!(Instant::now() < deadline);
        let stats = retry(|| kernel.stats());
        assert!(stats.stream_items <= 2);
        assert!(stats.stream_bytes <= 2 * (EVENT_OVERHEAD + 4));
        for event in retry(|| kernel.drain(1, 1024)) {
            match event.outcome {
                Outcome::Chunk { bytes, .. } => {
                    let slot = &mut chunks[event.request as usize - 1];
                    assert_eq!(
                        u32::from_le_bytes(bytes.try_into().unwrap()) as usize,
                        *slot
                    );
                    *slot += 1;
                }
                Outcome::Success(_) => finals += 1,
                outcome => panic!("unexpected {outcome:?}"),
            }
        }
        thread::yield_now();
    }
    assert_eq!(chunks, [100, 100]);
    let stats = retry(|| kernel.stats());
    assert_eq!(stats.outstanding, 0);
    assert_eq!(stats.stream_bytes, 0);
    assert_eq!(stats.stream_items, 0);
}
