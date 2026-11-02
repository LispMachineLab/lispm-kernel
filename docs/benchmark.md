# Session discovery benchmark

Session discovery reads every Codex transcript below the agents'
directory and returns one row per session. Emacs can do it itself, as
`lispm-agents-codex-sessions` does, or hand it to the kernel. This
benchmark measures both, cold and warm, with and without the desktop's
terminals drawing, to answer the question a design cannot: how long the
scan takes, and how long Emacs stops answering while it runs.

The result is what the kernel makes of the work. It reads the transcripts
faster than Emacs does, and keeps Emacs's thread free while they are
read: a cold scan finishes in about a tenth of a second, during which
Emacs answers timers and keys as usual. The Elisp reader spends a quarter
of a second on the same scan, and spends it not answering.

## What is measured

- **Workload.** 256 synthetic Codex transcripts, 19.6 MB in all. Each has
  a `session_meta` line, a user message and 128 `response_item` filler
  lines of 512 bytes. They are generated afresh in a temporary directory
  for every batch Emacs, so no transcript of the user's is read and the
  operating system's cache starts as empty as it can be made.
- **Readers.** `lispm-agent`'s own `lispm-agents-codex-sessions`, with its
  directory and index variables bound to the fixtures, and
  `lispm-kernel-scan-sessions` over the kernel's `scan-sessions` job,
  collecting its chunks. Both must return all 256 rows, and the two id
  lists must be identical; a disagreement fails the run. The kernel's
  rows also carry `:turn-ended`, which lispm-agent's reader does not
  compute: the kernel tells it from the head and tail it has already
  read, and reads no more of a transcript than the Elisp reader does.
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
  the median of each figure. Each batch process reports its own wall and
  CPU time, but that covers fixture creation, terminals and all four
  cases together, so it is not per-case CPU.

The machine is an Apple M1 Max (10 cores) running macOS 27.0.1, with
Emacs 31.1 and SBCL 2.6.9. lispm-kernel is this branch's build, and
`lispm-agent` is 0.16.0 from its `origin/main`.
Python, which times and repeats the batches, ran translated for x86-64
under Rosetta; every time in the table is measured by Emacs's clock and
by comparing Emacs's own timer to it, so the translation does not enter
the figures.

## Results

Medians of 3 runs, milliseconds. `rows` must equal 256 for a run to count.

### No terminals

| case | elapsed | p50 | p95 | p99 | max | Emacs GCs |
|---|---:|---:|---:|---:|---:|---:|
| elisp-cold | 236.7 | 0.04 | 234.76 | 234.76 | 241.68 | 13 |
| kernel-cold | 108.6 | 0.00 | 0.24 | 5.38 | 6.03 | 0 |
| elisp-warm | 2.6 | 0.00 | 0.63 | 0.63 | 0.66 | 0 |
| kernel-warm | 4.3 | 0.07 | 0.22 | 0.22 | 0.31 | 0 |

### Eight terminals

| case | elapsed | p50 | p95 | p99 | max | Emacs GCs |
|---|---:|---:|---:|---:|---:|---:|
| elisp-cold | 256.3 | 0.24 | 254.36 | 254.36 | 304.17 | 11 |
| kernel-cold | 146.3 | 0.00 | 1.08 | 9.22 | 12.12 | 0 |
| elisp-warm | 2.3 | 0.05 | 0.35 | 0.35 | 0.99 | 0 |
| kernel-warm | 5.5 | 0.02 | 0.38 | 0.38 | 0.86 | 0 |

The generated reports are [session-benchmark.json](session-benchmark.json)
and [session-benchmark-terminals.json](session-benchmark-terminals.json),
with every repetition's figures and the kernel's stats.

## Reading the table

- **The Elisp reader stops Emacs for the whole scan.** Its p95 lateness
  is the scan's own elapsed time: 235 ms without terminals, 254 ms with.
  The timer that should have run every 2 ms was held for a quarter of a
  second, and Emacs's GC ran 11 to 13 times during it, 104 to 109 ms in
  all, on the same thread.
- **The kernel does not stop Emacs.** Its p95 lateness is 0.24 ms without
  terminals and 1.08 ms with them; p99 5.38 and 9.22 ms; the worst single
  wait 6.0 and 12.1 ms. The kernel's own GC (32 to 42 ms) runs in the
  kernel process, not in Emacs, and Emacs itself collected nothing during
  the kernel's cold scan without terminals.
- **The kernel also finishes first.** Cold, it took 109 ms against 237 ms
  without terminals (2.18x), and 146 ms against 256 ms with them (1.75x).
  It reads each transcript's head and tail once and parses them on four
  threads; its turn state comes out of those same lines, so it returns a
  field the Elisp reader does not compute without reading more of the
  transcript. An earlier version of the kernel reopened every transcript
  to look at its end for the turn, 2.2 times the bytes, and finished no
  sooner than Emacs; the head-and-tail reuse is what the current figures
  measure. With terminals, the kernel's result still waits for
  frame-clock slices shared with terminal drawing; the shorter scan means
  fewer of them.
- **Warm scans are cheap either way.** The Elisp reader's second read is
  2.6 ms. The kernel's is 4.3 ms without terminals and 5.5 ms with them:
  its cached rows are already in the kernel, and its completion waits for
  an Emacs turn. A desktop that shows its cached session list and
  refreshes it in the background does not make the user wait for that
  5.5 ms.
- **The kernel's caches stay bounded.** For the cold scan: one request
  accepted, peak queue 1, outbox peak 37 KB, kernel heap 57 to 62 MB,
  32 to 42 ms of kernel GC. Eight terminals change the figure only
  slightly.

So the kernel wins on both counts: it finishes a cold scan in 109 to
146 ms where Emacs's own reader takes 237 to 256 ms, and it leaves
Emacs's only thread answering timers throughout. The freeze the kernel
exists to prevent is 235 to 254 ms of p95 lateness; the scan it replaces
now also completes sooner.

## Limits

- The transcripts are synthetic, with real Codex line shapes but
  generated content.
- Batch Emacs does not redisplay and takes no input. Terminal work here
  is the module reading output and updating its model, not painting a
  screen, and timer lateness is not input-to-paint.
- Eight terminals writing 300 KiB/s each are a load, not a shell user.
- Three repetitions on one machine; the medians hide variance and there
  are no confidence intervals. The kernel's terminal cases varied most:
  across the three repetitions its cold scan ran 136 to 160 ms and its
  warm scan 4 to 7 ms, because completion waits for frame-clock turns
  shared with terminal drawing.
- The kernel's process CPU and memory are outside Emacs's measured
  process. Its stats report heap and GC, but not per-case CPU.
- Not measured: concurrent kernel jobs, cancellation, the fallback to the
  Elisp reader when the kernel fails, and discovery through the desktop's
  actual session list.

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
