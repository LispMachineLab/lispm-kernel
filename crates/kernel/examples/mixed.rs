//! Synthetic runtime pressure benchmark, NOT an Emacs input-latency benchmark.
use lispm_kernel::{Config, Error, JobOptions, Kernel, Outcome, WorkClass};
use std::thread;
use std::time::{Duration, Instant};

fn main() {
    let kernel = Kernel::new(Config {
        workers: 2,
        io_workers: 2,
        max_stream_items: 8,
        max_stream_bytes: 4096,
        ..Config::default()
    })
    .unwrap();
    let start = Instant::now();
    // Admission contends with workers. Retry Busy only; capacity is a real overload.
    for owner in 0..8 {
        loop {
            let result = kernel.submit_with_options(
                owner,
                1,
                vec![],
                0,
                JobOptions {
                    class: if owner % 2 == 0 {
                        WorkClass::Cpu
                    } else {
                        WorkClass::Io
                    },
                    ..JobOptions::default()
                },
                move |context, _| {
                    for sequence in 0..1000u64 {
                        if context.is_cancelled() {
                            break;
                        }
                        let mut value = sequence;
                        for _ in 0..128 {
                            value = std::hint::black_box(
                                value.wrapping_mul(6364136223846793005).wrapping_add(1),
                            );
                        }
                        if owner % 2 == 1 && sequence % 100 == 0 {
                            thread::sleep(Duration::from_micros(100));
                        }
                        context
                            .emit(value.to_le_bytes().to_vec())
                            .map_err(|_| lispm_kernel::JobFailed)?;
                    }
                    Ok(vec![])
                },
            );
            match result {
                Ok(_) => break,
                Err(Error::Busy) => thread::yield_now(),
                other => panic!("{other:?}"),
            }
        }
    }
    let mut chunks = 0;
    let mut finals = 0;
    let mut drain_times = Vec::new();
    let mut contention = 0;
    while finals < 8 {
        assert!(start.elapsed() < Duration::from_secs(15));
        let call = Instant::now();
        match kernel.drain(4, 1024) {
            Ok(events) => {
                drain_times.push(call.elapsed().as_nanos());
                for event in events {
                    match event.outcome {
                        Outcome::Chunk { .. } => chunks += 1,
                        Outcome::Success(_) => finals += 1,
                        failure => panic!("{failure:?}"),
                    }
                }
            }
            Err(Error::Busy) => contention += 1,
            failure => panic!("{failure:?}"),
        }
        // Deliberately slow frontend to exercise backpressure.
        thread::sleep(Duration::from_micros(100));
    }
    drain_times.sort_unstable();
    let stats = loop {
        match kernel.stats() {
            Ok(stats) => break stats,
            Err(Error::Busy) => thread::yield_now(),
            failure => panic!("{failure:?}"),
        }
    };
    println!("synthetic mixed runtime benchmark\nchunks={chunks} finals={finals} elapsed_ms={}\ndrain_ns p50={} p95={} p99={} busy={}\nqueue_high_water={} stream_items_high_water={} stream_bytes_high_water={}\nmax_queue_wait_us={} max_run_time_us={}", start.elapsed().as_millis(), drain_times[drain_times.len()/2], drain_times[drain_times.len()*95/100], drain_times[drain_times.len()*99/100], contention, stats.queue_high_water, stats.stream_items_high_water, stats.stream_bytes_high_water, stats.max_queue_wait.as_micros(), stats.max_run_time.as_micros());
    assert_eq!(chunks, 8000);
    assert_eq!(stats.outstanding, 0);
    assert!(stats.stream_items_high_water <= 8);
    assert!(stats.stream_bytes_high_water <= 4096);
    kernel.shutdown();
}
