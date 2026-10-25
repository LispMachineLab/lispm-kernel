# lispm-kernel

LispM's kernel: the work Emacs should not wait on, done on threads of a
Lisp of its own. It is a Common Lisp program, SBCL's runtime with the
kernel's core in one executable. Emacs runs it as a process, and the two
Lisps talk in S-expressions, one per line:

```
Emacs   (submit 7 scan-sessions (:agent codex :root "~/.codex/sessions/") :owner 1 :generation 3)
kernel  (chunk 7 ((:id "…" :cwd "…" :title "…" :file "…" :mtime 1761…)))
        (done 7 success (:files 55 :rows 7 :empty 48 :skipped 0 :cached 0 :truncated nil))
```

What the kernel writes wakes Emacs as any process output does. Emacs takes
it in a slice at a time, by timers, or on the clock of a host that has one,
as [LispM Desktop](https://github.com/LispMachineLab/lispm-desktop)'s frame
clock, giving way to typing. SBCL has native threads and no global
lock, so the kernel's jobs run in parallel with each other and with Emacs. A
kernel that crashes takes none of Emacs with it.

Its first job reads the Codex and Claude Code sessions for the editor's
agents of [lispm-agent](https://github.com/LispMachineLab/lispm-agent), as
LispM Desktop's agents sidebar lists them. It reads them as the agents' own
readers do, to the
nanosecond of each transcript's time, on several threads at once. It keeps
what it read, so the next scan reads only transcripts that changed.

Its second job downloads for package.el. Even in the background, url.el
negotiates TLS on Emacs's thread, and through a proxy it waits for each
handshake, which freezes Emacs for most of a second at a time.
`lispm-kernel-package-mode` hands package.el's background downloads, as an
archive refresh makes them, to the kernel. The kernel fetches them with curl
on a thread of its own, and package.el checks and keeps what it got as
always. See [architecture](docs/architecture.md).

## Use

In LispM Desktop, `lispm-desktop-kernel` turns both modes on: Use LispM Kernel
in Control Panels › Kernel, or `setopt`, takes effect at once, and the
Installer gets what is missing; the desktop takes the kernel's messages in
on its frame clock. Elsewhere, with or without the desktop, load `lisp/` of
a checkout after lispm-agent's Lisp:

```elisp
(add-to-list 'load-path "/path/to/lispm-kernel/lisp")
(require 'lispm-kernel-desktop)
(lispm-kernel-sessions-mode 1)
(lispm-kernel-package-mode 1)
```

`lispm-kernel-sessions-mode` was called `lispm-kernel-desktop-mode`, a name
that still works.

Nobody has to build the program or say where it is. `lisp/lispm-kernel-program.el`
downloads the one built for this computer from these sources, in the
background. It keeps it only when its SHA-256 is the one pinned in
[`lisp/lispm-kernel-program-sums.eld`](lisp/lispm-kernel-program-sums.eld).
Those checksums come with the Lisp, from this repository's signed history,
not from the release beside the programs. Until the program is there, and
wherever it cannot be, the agents read sessions themselves, and the mode
says why. `lispm-kernel-program-progress-functions` hear how far the download is,
and `lispm-kernel-program-stop` stops it. Setting `lispm-kernel-desktop-program`
to a file runs that one as it is.

A kernel that exits is started again when the agents next read sessions.
One that exits within `lispm-kernel-desktop-restart-seconds` of its start is
started again after that many seconds, twice as many each time it does so
again, up to `lispm-kernel-desktop-restart-limit`; `M-x lispm-kernel-desktop-restart`
starts it again at once. `lispm-kernel-desktop-status` says how it stands.

To build it from the sources there are instead, which needs SBCL, run
`(setopt lispm-kernel-program-source 'build)`.

## Build and test

```
make                # build/lispm-kernel
make test-lisp      # the kernel's own tests, in SBCL
make test-emacs     # Emacs and the program, with lispm-agent beside (../lispm-agent/lisp)
make compile        # byte-compile the Emacs Lisp, warnings failing it
```

From the REPL, for SLY or SLIME: `(push #p"/path/to/lispm-kernel/" asdf:*central-registry*)`,
then `(asdf:load-system "lispm-kernel")` and `(asdf:test-system "lispm-kernel")`.

## Releasing

The [kernel-program workflow](.github/workflows/kernel-program.yml) builds the
program on main. It builds for macOS on Apple silicon and on Intel (11 and
later) and for GNU/Linux on x86_64, with an SBCL built from its pinned source
release. It publishes them as the release `kernel-program-<version>`, never
marked latest. The version is the first 16 digits of a SHA-256 over the
sources (`lispm-kernel.asd`, `scripts/build.lisp`, `src/**/*.lisp`), so a
release is made once per change of them. Releasing the kernel then takes two
steps:

1. Merge the change of the sources. The workflow publishes `kernel-program-<version>`.
2. In a "Version X.Y.Z" pull request, run `make pin`, and commit the pins with
   the new `Version` header of `lisp/lispm-kernel.el`.
