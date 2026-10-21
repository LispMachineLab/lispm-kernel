# Goal: background work must not block interaction

Deliver a shared Rust kernel for LispM Desktop. Rust executes owned native jobs;
Elisp owns UI state and applies bounded cooperative updates. Arbitrary Elisp
cannot be preempted or executed on Rust workers.
Design source: https://github.com/LispMachineLab/lispm-desktop/issues/48

## G0 — Baseline and acceptance (interactive gate remains open)

- [x] Reproduce synthetic cold/warm discovery with 0, 1 and 8 real native PTYs
  (one visible); preserve fixture counts and record repeated independent runs.
- [x] Record Emacs/Rust versions, desktop commit, corpus, release/debug distinction,
  timer-lateness proxy, GC, batch CPU and peak child RSS.
- [x] Clearly separate timer lateness from actual input-to-paint latency.
- [x] Set provisional batch targets: no lost sessions; native cold completion under
  50% of baseline; native maximum probe lateness under 25 ms; warm completion under
  150 ms for 256 fixtures. Warm background completion can be slower than the old
  in-memory path; the desktop integration returns a cached snapshot immediately.
- [ ] Measure actual GUI input-to-paint p50/p95/p99, redisplay and idle overhead
  under sustained typing/output before enabling by default.
- [ ] Confirm production numeric targets and macOS/Linux CI evidence.

Batch results do not establish real GUI latency or a stable performance guarantee.
See `docs/session-benchmark.json` and `docs/validation.md`.

## G1 — Native execution core (complete)

- [x] Standalone dependency-free core, no Emacs objects and no unsafe code.
- [x] Bounded requests, per-owner quotas and byte reservations.
- [x] Nonblocking submit/cancel/drain/stats: Busy requests later retry.
- [x] Fixed worker pools; queued cancellation skips execution.
- [x] Cooperative cancellation, owner/generation invalidation, runtime epochs.
- [x] Exactly one retained terminal outcome per accepted job.
- [x] Budgeted result reads, panic isolation and nonblocking shutdown.

## G2 — Streaming, scheduling and wake protocol (complete)

- [x] Bounded incremental results, backpressure and independent final capacity.
- [x] Replaceable state coalescing (in emission order), cross-owner priority with
  aging, owner rotation at equal priority, per-owner item and byte quotas.
- [x] Separate CPU/blocking-I/O pools; long-lived PTY loops remain outside them.
- [x] Nonblocking UnixStream wake hints; drain/rearm, budget errors, reader teardown.
- [x] Queue/byte high-water marks, queue/run latency, cancellation, failure and panic
  counters; cancellation frees admission at once; SIGPIPE-free wake hints.

## G3 — Real client and Emacs bridge (prototype complete)

- [x] Choose in-process module (protocol 2) for this prototype; document fault limits.
- [x] Confine Env/Value conversion to Emacs calls with input/conversion caps.
- [x] Callback registry, stale filtering, monotonic budgets, input yielding and no reentrancy.
- [x] Codex/Claude discovery, bounded head/tail parsing and traversal.
- [x] Stamp-checked cache swept per scan, independent title/index refresh,
  cancellation, per-entry skips and explicit fallback only for whole-scan errors.
- [x] Desktop-compatible plists, newest-per-ID collection and collection bounds.
- [x] Opt-in desktop mode through the desktop's session readers: snapshot caching,
  re-read on explicit refresh only, admission retries, timeouts and unload.
- [x] Cold/warm comparisons against the actual desktop parser on generated fixtures.
- [ ] Wire native wake hints into Emacs instead of adaptive polling, if profiling
  justifies the extra bridge/transport complexity.

## G4 — Terminal coordination and delivery

- [x] Run kernel dispatch on the desktop's frame clock after the terminals, within
  the frame's remaining budget, preserving the terminal implementation, its
  input policy and native event ownership. No advice on desktop internals.
- [x] Verify existing terminal visibility, final screen, status, input, sizing and
  lifecycle regression tests with kernel/desktop integration enabled.
- [x] Test frame-clock registration, remaining-budget application and return to
  timers; the desktop tests the clock's ordering, input yielding and error isolation.
- [x] Give sessions and scheduling back on disable and on `unload-feature`.
- [x] Build a local release bundle with four Lisp files, protocol/hash manifest and
  binary-derived architecture labeling.
- [ ] Green Linux/macOS CI on main and a first tagged release.
- [ ] Complete interactive G0 acceptance before default enablement/API stabilization.

## Baseline

CI tests against LispM Desktop's main, which has the frame clock and session
readers since lispm-desktop#64. Verified counts: 118 Rust tests, 33 integration ERT
tests; the desktop's own suite (451 tests) passes with the seams.
