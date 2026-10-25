# Architecture

Emacs runs Lisp, process output and redisplay on one thread. Work that
takes longer than a frame belongs elsewhere, and the kernel is that
elsewhere: a second Lisp, SBCL, in a process of its own. It runs jobs on
native threads, without a global lock, and hands Emacs the results in
pieces Emacs can take in between keystrokes.

```
Emacs                                         kernel (SBCL)
  lispm-kernel-submit ──(submit ...)──stdin──▶  reader thread ─▶ queues ─▶ workers (:cpu, :io)
                                                                                │ emit
  filter ─▶ lines ─▶ frame clock ◀──stdout── writer thread ◀── outbox ◀────────┘
              lispm-kernel-dispatch: a slice at a time, giving way to typing
```

## The wire

Every message is one datum on one line, in Emacs Lisp's syntax. Emacs
reads the kernel's with its own `read`, and prints its own with `prin1`,
newlines and control characters escaped. Only data cross: integers,
strings, symbols, lists and vectors; Emacs strips strings of their text
properties and refuses what the kernel would not read, such as `1+`, a
symbol it would take for a number. The kernel's reader, `src/wire.lisp`,
is not Common Lisp's. It reads Emacs's string escapes, interns nothing
but keywords, and evaluates nothing. A plain symbol from Emacs arrives as
a keyword, `codex` as `:codex`. The kernel prints a keyword as `:name` and
any other symbol as its bare name, so its own words reach Emacs as plain
symbols.

| Emacs sends | The kernel answers |
|---|---|
| `(submit ID JOB INPUT :owner O :generation G :priority P)` | `(chunk ID DATA)`…, then one `(done ID STATUS VALUE)` |
| `(cancel ID)` | the request's `done`, `cancelled` |
| `(supersede OWNER GENERATION)` | the `done` of the owner's older requests, `cancelled` |
| `(stats)` | `(stats PLIST)` |
| `(ping DATA...)` | `(pong DATA...)` |
| `(clear-caches)`, `(quit)` | nothing |
| a malformed line | `(protocol-error TEXT)`, and `(done ID rejected malformed)` when it was a `submit` |

The kernel says `(hello :protocol 1 :pid … :lisp … :jobs …)` first. Emacs
refuses a kernel of another protocol.

## Requests

Emacs chooses each request's ID. Every request gets exactly one `done`,
and its chunks come before it. STATUS is one of:

- `success`, and the job's result;
- `failed`, and why;
- `cancelled`;
- `rejected`, and why: `capacity`, `stale`, `unknown-job`, `duplicate`,
  `closed`, or `malformed` for a submission the kernel could not read.

Admission is bounded: 256 requests at once, 64 of one owner. An owner's
newer generation cancels its older requests, queued or running, and a
request of an older one is rejected as stale. Emacs filters the same way,
so a superseded callback hears nothing more.

Requests wait in a queue per class, `:cpu` and `:io`, each served by
threads of its own. A worker takes the request of the highest priority,
raised by one for every 50 ms it has waited, the oldest of equals first.
Cancelling a queued request answers it at once. A running one stops at
its next `checkpoint`, or while it waits to emit. A job that signals an
error fails its request, and the worker goes on.

## The outbox

Messages for Emacs wait in the outbox, which one thread writes out.
Chunks count against a limit of 4 M characters. While Emacs reads slower
than jobs emit, an emitting job waits there, until there is room or it is
cancelled. Final and other messages never wait, so a final word is never
lost to a full outbox. A final message longer than the limit, or one
holding what Emacs cannot read, fails its request instead.

## Emacs's side

`lisp/lispm-kernel.el` starts the program, sends requests and takes the
kernel's output in. The process filter only splits lines. `lispm-kernel-dispatch`
reads and acts on them for `lispm-kernel-slice-seconds`, at least one, and
gives way to typing; `lispm-kernel-scheduler` decides when it runs: a
timer, unless a host sets it to a clock of its own. LispM Desktop sets it
to its frame clock, at depth 10, after the terminals
(`lisp/lispm-desktop-kernel.el` in its repository). Nothing polls.
Process output asks for a timer or a frame, and one timer a second
watches deadlines while requests wait. A request past `lispm-kernel-request-timeout` hears `timeout`, and
the kernel is asked to cancel it. When the kernel exits, every request
waiting hears `lost`.

## Sessions

`src/sessions.lisp` reads the agents' sessions as the editor's agents'
own readers do, which lispm-agent holds since they left LispM Desktop:
`lispm-agents-codex.el`, `lispm-agents-claude.el` and `lispm-agents.el`
are its reference, and `test/lispm-kernel-desktop-test.el` checks it
against them.

- Codex: `rollout-*.jsonl`, any case, below the root; symbolic links to
  directories are not followed. A session is its head's first
  `session_meta`, titled by the first prompt a person typed in its head,
  else in its first MiB, else in its tail, or by its thread name in
  Codex's session index, which wins. Untitled sessions are left out.
  Codex may record tools and instructions over the whole head before
  the first prompt, so the first MiB is read when the head holds none,
  its last line cut left out.
- Claude Code: `PROJECT/*.jsonl`. A session is named by its file and
  titled by the last custom title or summary of its head and tail, else
  by the head's first prompt, or by the `custom-title.json` beside it,
  which wins.

A transcript's head is its first 64 KiB, and its tail its last 16 KiB
after that; a line cut at either end is left out. Lines are JSON as
Emacs's `json-parse-string` takes it: a lone surrogate escape, a number
that rounds to infinity or nesting deeper than 10001 leave the line out,
as in Emacs. One difference remains: where a region is not valid UTF-8,
the kernel reads U+FFFD for each invalid byte, while Emacs may decode the
whole region another way. A file's stamp is its
kind, size, inode, device, and modification and change times in
nanoseconds, from the C library's `stat` (`src/files.lisp`), checked
against sb-posix on first use. Each transcript read is kept with its
stamp, so the next scan reads only those that changed. A complete scan
forgets those it did not see; a scan cut short at 32 levels or a million
entries does not. Transcripts are read on four threads at once, and of the
sessions of one id the newest transcript's is kept. Files that vanish,
are no regular files or cannot be read are counted as skipped. Only a
root that cannot be listed fails a scan, and Emacs then reads it the
agents' own way.

`lisp/lispm-kernel-desktop.el`'s `lispm-kernel-sessions-mode` gives the
editor's agents session readers that answer at once with what the kernel
read last, or `pending`. They have it read again once that is older than
`lispm-kernel-desktop-cache-seconds`, or when the agents' list reads
sessions anew. Each session also says whether its latest turn had ended
(`:turn-ended`), read from the transcript's end as lispm-agent's `:ready`
reads it: its last 16 KiB, or its last 256 KiB when those hold no record
of a turn. The same readings answer three more callers in lispm-agent.
`lispm-agents-session-lookup-functions` looks a session up, for its
transcript and its turn, when the agents bridge asks whether an agent is
free for a message; it never waits and never reads the agents' own way.
`lispm-agents-read-sessions-function` lists every session. A terminal
learning its session takes a reading of any age and is told when a newer
one comes. The session picker takes one no older than the cache, waiting
up to `lispm-kernel-desktop-wait-seconds` for the kernel to read anew.
Only readings that say whether turns ended are used there: an older
kernel's may lack sessions lispm-agent lists. A remote or missing root
is read the agents' own way. A kernel that
exits is started again when a reader is next asked, unless it ran shorter
than `lispm-kernel-desktop-restart-seconds`; then it is not started again
until the mode is turned on anew.

## Downloads

`src/fetch.lisp` downloads a URL into a file Emacs names, with curl, which
the kernel runs; SBCL speaks no TLS of its own. Only http and https are
fetched, redirections included. Emacs says which proxy to use, the one
url.el would use for the URL, or none, and curl then uses no proxy of the
environment either. A download that fails fails its request with what curl
said, and one that is cancelled stops curl. Either removes the file.

`lisp/lispm-kernel-package.el` advises `package--with-response-buffer-1`,
through which package.el makes every download. A download package.el makes
in the background, from http or https, goes to the agents' kernel when it
runs and knows the job. Its body then runs on what the kernel wrote, in a
unibyte buffer, as package.el runs it on url.el's response, and package.el
checks the signatures and keeps the archives as always. The others go to
url.el: downloads package.el waits for, files, URLs url.el would reach
through SOCKS or a gateway of its own, and every download while no such
kernel runs.

The mode advises `lispm-prebuilt-fetch-function` too, through which
[lispm-prebuilt](https://github.com/LispMachineLab/lispm-prebuilt)
downloads the native code of LispM's packages in the background: a
module, as lispm-gl's, or a program, as lispm-doom's engine. The kernel
fetches it through the proxy url.el would use, and lispm-prebuilt checks
it against the SHA-256 its package pins. What the kernel cannot fetch
lispm-prebuilt downloads with curl itself.

## Programs

`src/exec.lisp` runs a program Emacs names, a file it found in `exec-path`,
with its arguments, directory and whole environment, and the text for its
standard input. What the program prints on its standard output comes as
chunks as it comes, read as UTF-8, a character cut between two reads kept
for the next; the result is its exit code, or the signal that ended it,
with the last 64 KiB of its standard error. The job ends with the program,
not with what the program left running holding its output, as Emacs
ends a process. Cancelling the request, or a program running past its
timeout, stops the program's process group, SIGTERM and then SIGKILL.

`lisp/lispm-kernel-exec.el` gives Emacs `lispm-kernel-exec`, which calls back
with the exit code and what was printed, and runs the program in Emacs, in
the background, where no kernel knowing the job runs, or the program or
directory is not on this computer. lispm-agent runs its programs through
`lispm-exec`, whose `lispm-exec-function` `lispm-kernel-exec-mode` advises;
LispM Desktop runs its own, as ps for the Buffer Manager and git for
Software Update, through it too.

## The program

`scripts/build.lisp` compiles the system afresh, failing on any warning,
and saves it with `save-lisp-and-die` as one executable. It needs nothing
but the system's C library. Releases are built with SBCL built from its
pinned source release (`scripts/build-sbcl.sh`), without core
compression, and on macOS for macOS 11 and later. They are gzipped for
download; see the README for how they are pinned and released.

## Limits

- The kernel cannot run Emacs Lisp, touch buffers or preempt Emacs. Emacs
  still applies results on its own thread, a slice at a time.
- SBCL's garbage collector stops the kernel's threads while it runs; it
  never stops Emacs.
- A job's own memory and time are its business: the kernel bounds
  requests and queued output, not what a running job allocates.
