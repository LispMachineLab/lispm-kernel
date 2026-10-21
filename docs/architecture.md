# Runtime contracts (G1/G2)

The core uses standard-library threads, a bounded admission table, work queues,
park/unpark worker wake tokens and a condition variable for stream capacity. It does not depend on Emacs and forbids unsafe code.
Trusted Rust adapters own all input, temporary state and result bytes.

## Admission and delivery

An accepted request reserves one slot, its input allocation capacity, a fixed event
charge, and its maximum final output capacity until its terminal outcome is drained.
Completed but undrained requests still occupy admission and per-owner quota.
Reliable final outcomes never compete with incremental chunks for storage.

Incremental chunks have separate global item and allocation-byte limits. `try_emit`
returns Backpressure with ownership of the rejected bytes; `emit` waits on worker
threads and cooperates with cancellation/shutdown. A chunk too large to ever fit
is rejected immediately. `try_replace(key, bytes)` coalesces only an unconsumed
chunk with the same request/key. Ordinary chunks and final outcomes are not dropped.
All earlier chunks for a request precede its final outcome. No chunk can be emitted
after completion. Slow frontends must drain or cancel: a worker blocked on stream
capacity cannot execute another job. Reserve a separate work class/pool for latency
critical services; the kernel does not preempt running adapters.

Captured closure state, stack use and temporary allocations are adapter responsibility.
Queue byte accounting is not a global RSS guarantee. Output allocation capacity,
including unused capacity, is checked against its reservation. Oversized final
results become OutputTooLarge; adapter panics become Panicked.

## Scheduling

CPU and blocking I/O have separate fixed worker pools. Within each class, dequeue
rotates over active owner IDs. Within an owner, priorities receive weights 0/1/2;
each 50 ms of queue age adds one point, and FIFO breaks ties. Aging avoids starvation
from a stream of newly admitted high-priority work. Fairness applies at dequeue,
not CPU-time preemption. Long-lived terminal event loops remain outside these pools.

## Lifecycle

Cancellation marks queued and running work. A worker skips canceled queued jobs;
running adapters check Context and wake from blocked emission on cancellation.
Cancellation wins over success if observed when committing the terminal outcome.
Cancellation after completion leaves the outcome immutable. Chunks emitted before
cancellation remain consumable; the frontend discards stale generations.

Every event carries a process-local runtime epoch, request ID, owner and generation.
Epochs prevent request ID reuse across runtime instances in one host process. An IPC
bridge must additionally identify the worker process session.
`supersede(owner, generation)` cancels older current requests, not a persistent
registration. Likewise close-owner cancels existing work; the caller prevents future
submissions to closed owners and maintains current generation independently.

Public polling methods use try_lock and return Busy. Frontends must schedule a retry,
never spin inside Emacs. Drain budgets charge metadata and payload length; storage
accounting charges allocation capacity. A too-small drain returns the first event's
required size without consuming it. Limits bound work, not hard real-time execution.

Shutdown closes admission, unparks workers and requests cancellation without joining workers.
Worker wake tokens survive wake-before-park races; idle workers do not poll.
Blocked stream emitters use cancellable condition-variable waits.
Drop detaches workers. A stuck trusted adapter can retain its thread/memory indefinitely.
No unsafe thread killing, automatic retries or fault isolation is provided. In-process
native faults can terminate Emacs; process isolation remains a packaging decision.

## Nonblocking wake hints (Unix)

`attach_notifications` returns a nonblocking UnixStream reader. It replaces an earlier
registration. The writer sends one coalesced byte; event payloads remain in retained
state. One-byte writes do not have a positive partial-write case: zero is failure,
WouldBlock means a hint is already buffered, and Interrupted has a bounded retry.
Repeated interruption shuts down the write side so EOF requests frontend recovery.

Frontend protocol:

1. Read until WouldBlock **before** calling drain.
2. Drain within a bounded item/byte budget. Busy requires a retry without waiting for
   a new hint. This is essential: reading the hint does not rearm the writer.
3. Drain rearms under the queue lock and signals again if work remains, including a
   zero-item drain or insufficient byte budget. Concurrent producers use that same
   lock, closing the empty-check/rearm race.
4. EOF/transport failure requires polling or re-registration. Re-registration signals
   already retained work. Detach before closing the frontend's notification transport.

Socket writes are nonblocking and held only under bounded state access. Shutdown
stops admission but leaves final notification/draining available until explicit detach
or runtime destruction. Broken readers do not discard results or kill workers.

## Experimental Emacs bridge

The separate `lispm-kernel-emacs` cdylib uses emacs 0.23.0, pinned in Cargo.lock.
Dependency macros generate the FFI boundary; handwritten bridge code uses safe APIs.
All Env/Value access and conversion happens during Emacs-side module calls.

The UTF-8 echo adapter remains a transport test; real session scanning is described below.
Input size is checked in Emacs before copying into Rust; payloads cap at 60 KiB.
Drain conversion caps at 16 events / 64 KiB; Elisp drains one at a time. Elisp callbacks
stay in a local registry. Runtime epoch and current owner generation filter old events.
Native errors do not masquerade as empty success. Callback failures are recorded,
terminal requests are released, and nested timer dispatch cannot reenter callbacks.

Elisp uses a native monotonic clock, a soft 3 ms budget, 16-event cap, and input checks.
A callback can exceed the budget; overruns are counted. A one-shot timer polls at 10 ms only while waiting for work,
then uses 1 ms cooperative continuations while results remain ready. The UnixStream wake channel is NOT wired into Emacs yet. Session format parity, caching and fallback are covered by fixture tests.
Default enablement remains gated on complete G0 interactive validation.

## Real session client and opt-in terminal integration

The sessions crate reads at most 64 KiB of head and 16 KiB of tail per transcript,
matching desktop's read ranges and partial-line handling. It filters injected
context, handles Codex metadata and Claude summaries/custom titles, and reads
external naming independently of transcript caching. Codex's index is bounded at
4 MiB and each custom-title file at 64 KiB. Exceeding these bounds fails the native
path so callers can use the explicit legacy fallback. Transcript IDs/paths are
bounded at 4096 bytes; titles cap at 4096 UTF-8 bytes, and emitted JSON at 60 KiB.

Traversal is incremental, limited to 16 directory levels / 100,000 entries. Claude
reads only project/*.jsonl; Codex recursively reads rollout-*.jsonl. Symlink entries
are skipped. Unix file opens use NOFOLLOW/NONBLOCK and reject non-regular files.
The cache is bounded to 1024 entries / 4 MiB of retained path/session payload,
including negative parses. Cache keys include size/mtime and Unix inode/ctime.
File state is rechecked after parsing; concurrent changes produce a retry/fallback
outcome. Cancellation checks occur between entries and during blocked emission.

Elisp collects at most 10,000 unique sessions by default, keeping the newest
transcript per ID. Errors and collection-limit overflow never publish partial final
lists. Fallback runs only when explicitly provided and remains synchronous Elisp
work scheduled later. Closed/superseded runtimes suppress stale completion callbacks.

The in-process module is the chosen prototype packaging, protocol 1, preserving
existing desktop installation. Native faults remain process-wide. The standalone
core still supports a future isolated process without coupling to Emacs objects.
Local packaging verifies binary architecture and records SHA-256; Linux/macOS CI
runs on every push and pull request.

`lispm-kernel-desktop-mode` advises only built-in session providers and manual
refresh. Third-party providers continue through the existing aggregator. Snapshots
are cached per provider/root; root changes, refresh and disable invalidate their
lifecycle. Busy admission retries through at most one timer per provider. Disabling
removes advice, cancels retry/repaint timers and shuts down its runtime.

`lispm-kernel-broker` coordinates native result application with the existing terminal
frame scheduler. One timer tracks each client's due time, preserves the terminal
frame interval, runs due terminal work first, then gives callbacks the remaining
soft budget. Pending input defers work, overruns are counted, and terminal callback
errors are isolated from kernel dispatch. Disabling restores each original scheduler.
It does not move long-lived PTY loops into a worker pool or merge the two native
modules' state ownership. Existing terminal render/happening functions remain the
single implementation of visibility, final screen, status, exit and clipboard behavior.
