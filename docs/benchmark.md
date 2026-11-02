# Session discovery benchmark

Session discovery reads every Codex transcript below the agents'
directory and returns one row per session. Emacs can do it itself, as
`lispm-agents-codex-sessions` does, or hand it to the kernel. This
benchmark measures both, cold and warm, with and without the desktop's
terminals drawing, to answer the question a design cannot: how long the
scan takes, and how long Emacs stops answering while it runs.

The result is what the kernel makes of the work. It keeps Emacs's thread
free while the transcripts are read: a cold scan takes two to three
tenths of a second, during which Emacs answers timers and keys as usual.
The Elisp reader takes about as long, and spends the whole time not
answering. Whether the kernel also finishes first depends on how much of
a transcript it must read: without terminals it does, by about a tenth;
with them the two are about even.

## What is measured

- **Workload.** 256 synthetic Codex transcripts, 68.6 MB in all. Every
  fourth is short and ends no turn, the next short and ends one, then a
  long one that ends none, then a long one that does: 64 of each. All
  have a `session_meta` line and a user message, then `response_item`
  filler lines of 512 bytes, 128 of them or, in a long transcript, 768:
  about 77 KB and 459 KB. So a short transcript's head and tail hold all
  of it, while a long one's do not, and the kernel must read the end of a
  long transcript whose tail tells of no turn. They are generated afresh
  in a temporary directory for every batch Emacs, so no transcript of the
  user's is read and the operating system's cache starts as empty as it
  can be made.
- **Readers.** `lispm-agent`'s own `lispm-agents-codex-sessions`, with its
  directory and index variables bound to the fixtures, and
  `lispm-kernel-scan-sessions` over the kernel's `scan-sessions` job,
  collecting its chunks. Both must return all 256 rows, and the two id
  lists must be identical; a disagreement fails the run. The kernel's
  rows also carry `:turn-ended`, which lispm-agent's reader does not
  compute: the kernel tells it from the head and tail it has already
  read, and where they leave the end out and the tail tells of no turn,
  from the transcript's last 256 KiB. Both readers read the head and the
  tail of every transcript; the kernel reads 16.8 MB more, for the 64
  long transcripts without a turn — 37.1 MB against 20.3 MB in all, 1.8
  times the bytes.
- **Cold and warm.** Cold is the first read of the fixtures in that Emacs,
  warm the second. The kernel prints its cache count in the scan summary:
  0 for cold, 256 for warm. The order alternates between repetitions, so
  neither reader always reads files the other just brought into the
  operating system's cache.
- **Terminals.** Zero, or eight `/bin/sh` terminals each writing about
  300 KiB a second through `lispm-desktop-term`, one of them selected as
  the visible terminal. Without terminals the kernel's messages are
  dispatched directly in a timer on Emacs's thread; with them, the
  benchmark uses the desktop's frame clock: a client at depth 10, below
  the terminals, dispatching in slices of at most 3 ms.
- **Responsiveness.** A 2 ms timer runs during each case and records how
  late it was. The quantiles below are that lateness: p95 is how long a
  timer due every 2 ms had to wait. It is a proxy for Emacs not
  answering, not an input-to-paint measurement, and batch Emacs has no
  redisplay at all.
- **Startup is not measured.** The kernel is pinged before the first case,
  so the cold kernel case does not include SBCL's start.
- **Repetition.** Three batch Emacsen per configuration; the table gives
  the median of each figure, the maximum's included. Each batch process
  reports its own wall and CPU time, but that covers fixture creation,
  terminals and all four cases together, so it is not per-case CPU.

The machine is an Apple M1 Max (10 cores) running macOS 27.0.1, with
Emacs 31.1 and SBCL 2.6.9. lispm-kernel is this branch's build, and
`lispm-agent` is 0.16.0 from its `origin/main`.
Python, which times and repeats the batches, ran translated for x86-64
under Rosetta; every time in the table is measured by Emacs's clock and
by comparing Emacs's own timer to it, so the translation does not enter
the figures.

## Results

Medians of 3 runs, milliseconds. `rows` must equal 256 for a run to count;
`max` is the median of the runs' longest timer waits.

### No terminals

| case | elapsed | p50 | p95 | p99 | max | Emacs GCs |
|---|---:|---:|---:|---:|---:|---:|
| elisp-cold | 254.5 | 0.28 | 252.50 | 252.50 | 252.50 | 13 |
| kernel-cold | 224.7 | 0.08 | 0.37 | 0.80 | 5.35 | 0 |
| elisp-warm | 2.7 | 0.03 | 0.74 | 0.74 | 0.74 | 0 |
| kernel-warm | 4.4 | 0.20 | 0.40 | 0.40 | 0.40 | 0 |

### Eight terminals

| case | elapsed | p50 | p95 | p99 | max | Emacs GCs |
|---|---:|---:|---:|---:|---:|---:|
| elisp-cold | 275.4 | 0.17 | 273.37 | 273.37 | 273.37 | 11 |
| kernel-cold | 284.6 | 0.02 | 0.89 | 2.09 | 6.98 | 0 |
| elisp-warm | 2.3 | 0.19 | 0.66 | 0.66 | 0.66 | 0 |
| kernel-warm | 19.7 | 0.00 | 0.92 | 8.29 | 8.29 | 1 |

The generated reports are [session-benchmark.json](session-benchmark.json)
and [session-benchmark-terminals.json](session-benchmark-terminals.json),
with every repetition's figures and the kernel's stats.

## Reading the table

- **The Elisp reader stops Emacs for the whole scan.** Its p95 lateness
  is the scan's own elapsed time: 253 ms without terminals, 273 with.
  The timer that should have run every 2 ms was held for a quarter of a
  second, and Emacs's GC ran 11 to 13 times during it, 105 to 122 ms in
  all, on the same thread.
- **The kernel does not stop Emacs.** Its p95 lateness is 0.37 ms without
  terminals and 0.89 ms with them; p99 0.80 and 2.09 ms; the worst single
  wait 5.4 and 7.0 ms. The kernel's own GC (77 to 90 ms) runs in the
  kernel process, not in Emacs, and Emacs itself collected nothing during
  the kernel's cold scan. In the kernel's warm case with terminals it
  collected once, 9 ms, and its p99 reached 8.3 ms.
- **The kernel finishes first without terminals, and is about level with
  them.** Cold, without terminals, it took 225 ms against 254 (1.13x);
  with them, 285 ms against 275 (0.97x). It reads each transcript's head
  and tail once and parses them on four threads, but for the 64 long
  transcripts whose tail tells of no turn it reads 256 KiB more to say
  whether the turn ended: 37.1 MB against the Elisp reader's 20.3 MB.
  With terminals, its completion also waits for frame-clock slices shared
  with terminal drawing, and the longer read means more of them.
- **Warm scans are cheap either way.** The Elisp reader's second read is
  2.7 ms without terminals and 2.3 ms with them. The kernel's is 4.4 and
  19.7 ms: its cached rows are already in the kernel, and its completion
  waits for an Emacs turn, which with terminals also carries the
  terminals' output. Neither stops Emacs answering: its p95 lateness is
  0.40 and 0.92 ms. A desktop that shows its cached session list and
  refreshes it in the background does not make the user wait for that
  19.7 ms.
- **The kernel's caches stay bounded.** For the cold scan: one request
  accepted, peak queue 1, outbox peak 37 KB, kernel heap 54 to 62 MB
  without terminals and 57 to 73 MB with them, 77 to 90 ms of kernel GC.

So the kernel's reason is the freeze it prevents: 253 to 273 ms of p95
lateness becomes 0.4 to 0.9 ms, and Emacs answers timers throughout a
scan that takes 0.2 to 0.3 s. Finishing first is a second claim, and this
mix does not support it in every case: the kernel is about a tenth faster
cold without terminals, and about level with them, where the turn state it
returns costs reads the Elisp reader does not make and completion waits
for frame-clock slices shared with terminal drawing.

## Limits

- The transcripts are synthetic, with real Codex line shapes but
  generated content: a quarter short without a turn, a quarter short with
  one, a quarter long without, a quarter long with.
- Batch Emacs does not redisplay and takes no input. Terminal work here
  is the module reading output and updating its model, not painting a
  screen, and timer lateness is not input-to-paint.
- Eight terminals writing 300 KiB/s each are a load, not a shell user.
- Three repetitions on one machine; the medians hide variance and there
  are no confidence intervals. The kernel's terminal cases varied most:
  across the three repetitions its cold scan ran 271 to 287 ms and its
  warm scan 6 to 38 ms, because completion waits for frame-clock turns
  shared with terminal drawing, and the Elisp reader's terminal cold scan
  varied almost as widely, 262 to 298 ms.
- The kernel's process CPU and memory are outside Emacs's measured
  process. Its stats report heap and GC, but not per-case CPU.
- Not measured: what the Elisp reader would cost if it also computed the
  turn state the kernel returns; concurrent kernel jobs, cancellation,
  the fallback to the Elisp reader when the kernel fails, and discovery
  through the desktop's actual session list.

## Reproducing it

With `lispm-agent`, `lispm-kit`, `lispm-ui` and `lispm-desktop` checked
out beside this one, and the desktop's terminal module built:

```
make bench
```

```
make bench BENCH_TERMINALS=8 BENCH_OUTPUT=docs/session-benchmark-terminals.json
```

`make bench` builds the kernel program if needed, then runs
`scripts/bench-sessions.py`, which repeats the batch Emacs and writes the
JSON report. Set `LISPM_AGENT`, `LISPM_KIT`, `LISPM_UI` or
`LISPM_DESKTOP` when a checkout lives elsewhere, and `BENCH_REPEATS`,
`BENCH_TERMINALS` or `BENCH_OUTPUT` to change the run. The script also
takes `--count`, `--filler` and `--timeout`; by hand, `bench/session-discovery.el`
documents its own environment variables and prints the JSON after a
`BENCH-JSON` line.
