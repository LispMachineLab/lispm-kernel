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
- [x] Replaceable state coalescing, owner rotation and priority aging.
- [x] Separate CPU/blocking-I/O pools; long-lived PTY loops remain outside them.
- [x] Nonblocking UnixStream wake hints; drain/rearm, budget errors, reader teardown.
- [x] Queue/byte high-water marks, queue/run latency and cancellation counters.

## G3 — Real client and Emacs bridge (prototype complete)

- [x] Choose in-process protocol-1 module for this prototype; document fault limits.
- [x] Confine Env/Value conversion to Emacs calls with input/conversion caps.
- [x] Callback registry, stale filtering, monotonic budgets, input yielding and no reentrancy.
- [x] Codex/Claude discovery, bounded head/tail parsing and traversal.
- [x] Bounded cache, independent title/index refresh, cancellation and explicit fallback.
- [x] Desktop-compatible plists, newest-per-ID collection and collection bounds.
- [x] Opt-in desktop mode with snapshot caching, invalidation and admission retries.
- [x] Cold/warm comparisons against the actual desktop parser on generated fixtures.
- [ ] Wire native wake hints into Emacs instead of adaptive polling, if profiling
  justifies the extra bridge/transport complexity.

## G4 — Terminal coordination and delivery

- [x] Share an 8 ms cooperative frontend budget through an opt-in broker, preserving
  the existing terminal implementation and native event ownership.
- [x] Verify existing terminal visibility, final screen, status, input, sizing and
  lifecycle regression tests with kernel/desktop integration enabled.
- [x] Test terminal-first ordering, remaining-budget application, input yielding,
  callback error isolation and overrun deferral.
- [x] Restore original schedulers/providers and cancel owned timers on disable.
- [x] Build a local release bundle with four Lisp files, protocol/hash manifest and
  binary-derived architecture labeling.
- [ ] Run Linux/macOS CI and publish a reviewable branch/PR/release after access works.
- [ ] Complete interactive G0 acceptance before default enablement/API stabilization.

## Collaboration and current blockers

Codex scope: kernel repository, adapter/bridge/broker, opt-in integration, tests,
benchmarks and documentation. No tracked desktop files or Claude's work were edited.
The desktop baseline during this execution was e6c4adc24e335522874c009df336e624ba31c733.

The local repository was initialized because GitHub DNS was unavailable; it has not
fetched remote history. GPG signing was also inaccessible in the sandbox. Reconcile
with remote main before any commit/push; do not force-push a new root history.

Current verified counts: 34 Rust tests, 23 integration ERT tests, 24 terminal tests.
Full desktop regression: 421 pass / 1 skip / 1 failure due to denied server socket bind.
