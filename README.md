# lispm-kernel

Shared Rust runtime for [LispM Desktop](https://github.com/LispMachineLab/lispm-desktop): bounded background jobs, cooperative Elisp dispatch, and responsive UI.

Status: design phase. The shared design and acceptance checklist live in [lispm-desktop#48](https://github.com/LispMachineLab/lispm-desktop/issues/48). Implementation follows baseline measurement and design review.

## Architecture

- Rust owns background computation, I/O, cancellation, scheduling, and retained results.
- Elisp owns buffers, windows, input, and redisplay, applying incremental results within a soft time budget.
- Workers operate on owned snapshots; they never retain Emacs values or call Emacs APIs. This runtime cannot preempt arbitrary Elisp or run existing Elisp closures in parallel.
- Reuse proven terminal mechanisms through client adapters. Validate both terminal workloads and session/transcript discovery before freezing the API.
- Evaluate the existing in-process module integration against worker-process crash isolation before choosing the final boundary.

## Runtime contract

Provisional operations: capabilities/version, submit, cancel, close-owner, drain, stats, and shutdown. Results carry runtime epoch, request ID, owner, and generation so stale work cannot overwrite newer state.

Bound admission and queues by both items and bytes, with per-owner quotas, fairness, cooperative cancellation, and explicit overload responses. Separate CPU work from blocking I/O and long-lived terminal loops. Coalesce replaceable state while preserving completion, error, and exit outcomes.

Notifications are hints to drain retained state. Define a lost-wakeup-safe drain/rearm handshake. Submission, locks, conversion, draining, and shutdown must avoid unbounded waits on the Emacs thread.

## Delivery sequence

1. Reproducible workloads and baseline instrumentation: input delay, callback duration, GC/redisplay, CPU/RSS, wakeups, and queue depths.
2. Review API, packaging, lifecycle, isolation, overload behavior, and numeric acceptance targets.
3. Implement runtime lifecycle and bounded scheduling in a small auditable PR.
4. Add incremental cancellable session discovery with Elisp fallback.
5. Integrate terminals and publish measured before/after results.

Preserve existing terminal behavior and macOS/Linux distribution paths. Test saturation, slow consumers, fairness, cancellation races, stale results, wakeup rearming, worker failures, and shutdown.

## Collaboration

Claude and Codex share the design record. Claim scoped tasks/files before editing, recheck concurrent changes, preserve other work, and keep implementation PRs small enough to audit.
