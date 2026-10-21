# Validation checkpoint: 2026-10-21

Local host: macOS / aarch64, rustc 1.97.0. Debug test builds and an optimized
synthetic example. These checks do not measure actual Emacs input-to-paint latency
or establish a performance improvement over desktop.

## Reproduce

```
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo build --locked -p lispm-kernel-emacs
python3 scripts/test-emacs.py
cargo run --release --locked -p lispm-kernel --example mixed
```

34 Rust tests cover admission, allocation capacity accounting, worker concurrency,
owner rotation/priority aging, cancellation, stale epochs, shutdown, slow consumers,
streaming backpressure/coalescing, independent I/O capacity, notification rearming,
budget errors and reader teardown/re-registration. 23 ERT tests load the actual
native module and cover Unicode, generation filtering, callback error isolation,
input yielding, callback overruns, reentrant dispatch, oversized input and shutdown.

## Synthetic pressure smoke test

One optimized run: 8 mixed CPU/simulated-I/O requests, 1,000 chunks each, 2 CPU and
2 I/O workers. Frontend drains at most 4 events / 1,024 bytes and sleeps 100 us
between attempts. Stream cap: 8 items / 4,096 bytes.

- All 8,000 chunks and 8 final outcomes consumed.
- Observed stream high-water: 8 items / 576 allocation bytes.
- Observed elapsed: 320 ms.
- Successful drain call p50/p95/p99: 5.2 / 26.5 / 59.6 us.

These numbers are a single smoke run, affected by host scheduling and load. They
exclude true UI/GC/redisplay behavior, and are not benchmark acceptance targets.
The checked-in example asserts counts and bounds; its absolute timings are informational.

## Remaining gates

G0 still needs representative desktop workloads and before/after evidence. G3 now has real session discovery, cache correctness and Elisp fallback. Adaptive
polling is used at the Emacs boundary; direct notification wiring remains optional.
The shared broker preserves the existing terminal implementation.

## Real session client and broker checkpoint

The current suite includes 34 Rust tests and 23 real-module/desktop ERT tests.
`python3 scripts/test-emacs.py` runs the desktop tests against a lispm-desktop
checkout next to this one (`../lispm-desktop`), or against `LISPM_DESKTOP_ROOT`.
They include parser parity, reversible desktop integration, bounded admission retries,
and shared broker scheduling. These load the real module; they are not mock-only
transport tests. Existing terminal regression with integration enabled: 24/24 pass.
The full desktop suite with kernel integration loaded but disabled: 421 pass,
1 skip (music player), 1 failure (`Cannot bind server socket: Operation not permitted`).

The session fixture benchmark compares actual desktop parser code at commit
`e6c4adc24e335522874c009df336e624ba31c733` with the release kernel module. Each case
contains 256 transcripts with 128 filler lines each, uses bounded head/tail reads,
and checks all 256 results arrive. Three independent fresh-process runs exist for
0 terminals, and three each for 1 and 8 PTYs, one visible. GC and whole-process
resource figures are included in newer runs. CPU/RSS cover fixture creation and
all cases, not isolated per-case costs. The Python process may be translated x86_64;
the native module is aarch64, verified from its Mach-O header. Hardware sysctl was
denied, so no CPU model is claimed.

One 8-PTY independent-scheduler run observed:

| Path | Completion | Maximum timer lateness |
|---|---:|---:|
| Desktop cold | 905 ms | 894 ms |
| Kernel cold | 165 ms | 6.3 ms |
| Desktop warm | 33 ms | 14 ms |
| Kernel warm | 101 ms | 3.0 ms |

A shared-broker smoke run observed 668/156 ms cold completion (desktop/kernel),
610/12.8 ms maximum probe lateness, and kernel warm completion 110 ms. This
tradeoff remains visible: background warm refresh takes longer than the legacy
in-memory path. The opt-in UI returns a prior snapshot while refreshing, so it does
not wait synchronously for that round-trip.

Reproduce the real PTY mixed load using:

```
cargo build --release --locked -p lispm-kernel-emacs
LISPM_KERNEL_PROFILE=release LISPM_BENCH_TERMINALS=8 LISPM_BENCH_BROKER=1 \
  python3 scripts/bench-sessions.py [/path/to/lispm-desktop]
```

Without an argument the benchmark uses `../lispm-desktop`.

These are generated fixtures and batch timer-lateness probes. Physical key delivery,
GUI redisplay, and actual input-to-paint percentiles remain an explicit acceptance
gate. No personal transcript corpus or active desktop configuration was changed.

Final local package smoke: 14/14 real-module ERT tests pass using only the
packaged module and bundled Lisp files. All four Lisp files also pass byte
compilation with warnings treated as errors; compiled and source integration
paths were verified. Idle workers now use retained park/unpark tokens rather than
periodic polling. Three final 8-PTY shared-broker runs pass all provisional batch
checks recorded in session-benchmark.json. GUI acceptance remains open.
