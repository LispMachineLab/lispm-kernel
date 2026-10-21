# Runtime contracts (G1/G2)

The core uses standard-library threads, a bounded admission table, work queues,
park/unpark worker wake tokens and a condition variable for stream capacity. It does not depend on Emacs and forbids unsafe code.
Its one dependency, socket2 on Apple targets, sets SO_NOSIGPIPE on the wake channel.
Trusted Rust adapters own all input, temporary state and result bytes.

## Admission and delivery

An accepted request reserves one slot, its input allocation capacity, a fixed event
charge, and its maximum final output capacity until its terminal outcome is drained.
Completed but undrained requests still occupy admission and per-owner quota. Each owner
also has its own reserved-byte, stream-item and stream-byte quota
(`max_reserved_bytes_per_owner`, `max_stream_items_per_owner`,
`max_stream_bytes_per_owner`), so one owner cannot take the whole runtime. Rejected
admission through `try_submit_with_options` hands the job and input back for a retry.
Reliable final outcomes never compete with incremental chunks for storage.

Incremental chunks have separate global item and allocation-byte limits. `try_emit`
returns Backpressure with ownership of the rejected bytes; `emit` waits on worker
threads and cooperates with cancellation/shutdown. A chunk too large to ever fit
is rejected immediately. `try_replace(key, bytes)` coalesces only an unconsumed
chunk with the same request/key, and the replacement is ordered after everything
emitted before it. Ordinary chunks of live requests and final outcomes are not dropped.
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
takes the highest effective priority across all owners: weights 0/1/2 plus one point
per 50 ms of queue age. Owners rotate only among equal effective priorities, and FIFO
breaks ties within an owner. Aging avoids starvation from a stream of newly admitted
high-priority work. Submission wakes one idle worker of the task's class. Fairness applies at dequeue,
not CPU-time preemption. Long-lived terminal event loops remain outside these pools.

## Lifecycle

Cancellation (cancel, close-owner, supersede) removes queued work at once: its slot,
per-owner count and reservation are freed and its one `Cancelled` final outcome is
queued immediately; the job closure is dropped outside the state lock. Undrained
chunks of cancelled requests are dropped and their stream budget released; final
outcomes never are. Running adapters check Context and wake from blocked emission;
a running request is released when its worker commits. Cancellation wins over
success and failure if observed when committing, but a panic is always reported as
`Panicked`; Stats count failed and panicked outcomes. Cancellation after completion
leaves the outcome immutable.

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
Production paths do not panic. A poisoned lock is recovered only when a full audit of
the state's invariants passes; otherwise calls return Poisoned and workers stop.
No unsafe thread killing, automatic retries or fault isolation is provided. In-process
native faults can terminate Emacs; process isolation remains a packaging decision.

## Nonblocking wake hints (Unix)

`attach_notifications` returns a nonblocking UnixStream reader. It replaces an earlier
registration. The writer sends one coalesced byte; event payloads remain in retained
state. One-byte writes do not have a positive partial-write case: zero is failure,
WouldBlock means a hint is already buffered, and Interrupted has a bounded retry.
Any other write failure, repeated interruption included, shuts down the write side
so EOF requests frontend recovery, and `Stats::notifications_broken` reports it.
Writes never raise SIGPIPE: SO_NOSIGPIPE on Apple, MSG_NOSIGNAL (std) on Linux and
the BSDs; other Unix targets refuse to attach.

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
stops admission and closes the writer before it returns, without the state lock;
the reader sees EOF and retained outcomes stay drainable. Broken readers do not
discard results or kill workers.

## Experimental Emacs bridge

The separate `lispm-kernel-emacs` cdylib uses emacs 0.23.0, pinned in Cargo.lock.
Dependency macros generate the FFI boundary; handwritten bridge code uses safe APIs.
All Env/Value access and conversion happens during Emacs-side module calls.

The UTF-8 echo adapter remains a transport test; real session scanning is described below.
Input size is checked in Emacs before copying into Rust; payloads cap at 60 KiB.
Drain conversion caps at 16 events / 64 KiB, except that a first event larger than the
budget comes back alone, so drain never stalls on one event. Drained events wait in the
bridge until their Lisp vector exists: a conversion error or non-local exit leaves them
for the next drain. Payloads convert lossily, so conversion cannot fail on invalid
UTF-8. Elisp drains one at a time. Elisp callbacks
stay in a local registry. Runtime epoch and current owner generation filter old events.
Native errors do not masquerade as empty success. Callback failures are recorded,
terminal requests are released, and nested timer dispatch cannot reenter callbacks.

Elisp uses a native monotonic clock, a soft 3 ms budget, 16-event cap, and input checks.
A callback can exceed the budget; overruns are counted. A one-shot timer polls at 10 ms only while waiting for work,
then uses 1 ms cooperative continuations while results remain ready; under the desktop the frame clock replaces
those timers (`lispm-kernel-scheduler`). The UnixStream wake channel is NOT wired into Emacs yet.
Every accepted request ends in exactly one final event for its callback: a native outcome, `timeout` after
`lispm-kernel-request-timeout` (the native work is cancelled), or `lost` once a drain error shows the runtime
cannot deliver more. Unloading the library shuts its runtimes down. Session format parity, caching and fallback are covered by fixture tests.
Default enablement remains gated on complete G0 interactive validation.

## Real session client and opt-in terminal integration

The sessions crate reads at most 64 KiB of head and 16 KiB of tail per transcript,
matching desktop's read ranges and partial-line handling. It filters injected
context, handles Codex metadata and Claude summaries/custom titles, and reads
external naming independently of transcript caching. Naming files never fail a
scan, as in the desktop: an unreadable, oversized or directory custom-title file
means no custom title, an unreadable index means no names, and an index over 4 MiB
is read from its last 4 MiB (dropping the leading partial line; the last entry wins).
Transcript IDs/paths are bounded at 4096 bytes; titles cap at 4096 UTF-8 bytes, and
emitted JSON at 60 KiB. Blank means only space, tab, newline and return, as in Elisp.

Problems of one entry are skipped and counted in the summary's `skipped`: a file
gone between listing and opening, a transcript changed during its read (read once
more first), a non-UTF-8 or overlong path, an unreadable entry. Only a root that
is missing or cannot be listed counts in `errors`, which sends callers to the
desktop's reader. The summary is `{files, rows, empty, skipped, errors, cached,
truncated}`.

Traversal is incremental, limited to 16 directory levels / 1,000,000 entries; past
them, or past a directory below the root that cannot be listed to its end, it
reports `truncated` instead of failing, and a truncated scan never sweeps the cache. Listing matches the
desktop's Elisp: Claude reads project/*.jsonl (case-sensitive, dot-directories and
symlinked project directories included); Codex recursively reads rollout-*.jsonl
(case-insensitive, symlinked files followed, symlinked directories not). A
directory that is its own ancestor is skipped. Opens follow symlinks with NONBLOCK
and accept only regular files.

The cache is keyed by agent and path, valid only for the file's stamp (size,
mtime, device, inode, ctime), and swept after each complete scan of a root of the
entries it did not see; truncated or failed scans do not sweep. It is bounded to
250,000 entries / 64 MiB; when full, new transcripts are parsed but not cached, so
repeated scans keep their hits instead of thrashing. `cached` counts the hits.
`lispm-kernel-module-clear-session-cache` frees it; disabling the desktop mode does.
Cancellation checks occur between entries and during blocked emission.

Elisp collects at most 200,000 unique sessions by default, keeping the newest
transcript per ID. Errors and collection-limit overflow never publish partial final
lists. Fallback runs only when explicitly provided and remains synchronous Elisp
work scheduled later. Closed/superseded runtimes suppress stale completion callbacks.

The in-process module is the chosen prototype packaging, protocol 2, preserving
existing desktop installation. Native faults remain process-wide. The standalone
core still supports a future isolated process without coupling to Emacs objects.
Local packaging verifies binary architecture and records SHA-256; Linux/macOS CI
runs on every push and pull request.

The integration uses only LispM Desktop's public seams; it advises nothing.
`lispm-kernel-desktop-mode` registers a session reader for Codex and for Claude
(`lispm-desktop-agent-add-session-reader`). The agents sidebar asks readers, and
nothing else does: the session picker and every other caller keep the desktop's
own synchronous readers, so they always get complete, fresh lists. A reader
answers with the last native snapshot, or `pending` before the first one; the
sidebar shows that sessions are still being read. A missing or stale snapshot
(older than `lispm-kernel-desktop-cache-seconds`) starts a background scan, and
its arrival asks the desktop to re-render the sidebar
(`lispm-desktop-agent-sessions-arrived`), shown or not. Only an explicit refresh
or a renamed/archived/deleted session (`lispm-desktop-agent-reread-sessions-hook`)
supersedes a running scan; status changes and exits re-render from the snapshot.
A remote root is read the desktop's way. Busy admission retries through at most
one timer per agent, a scan past `lispm-kernel-desktop-scan-timeout` is cancelled
and falls back, and a request whose final event never arrives is given up.
Disabling, or `unload-feature`, removes the readers and hook, leaves the frame
clock, shuts the runtime down and frees the native session cache.

`lispm-kernel-broker` runs kernel dispatch as a client of the desktop's frame
clock (`lispm-desktop-frame-add-client`, depth 10), after the terminals at depth
0, within what is left of the frame's budget. The clock runs its first due client
even while a key waits, so terminals keep their own policy (the selected window's
terminal drawn first); later clients, the kernel among them, wait for the next
frame. Client errors are isolated by the clock. It does not move long-lived PTY
loops into a worker pool or merge the two native modules' state ownership.
Existing terminal render/happening functions remain the single implementation of
visibility, final screen, status, exit and clipboard behavior.
