# lispm-kernel

Rust background runtime and cooperative Emacs frontend for
[LispM Desktop](https://github.com/LispMachineLab/lispm-desktop).
Design record: [desktop#48](https://github.com/LispMachineLab/lispm-desktop/issues/48).

The native core provides bounded admission, CPU/I/O pools, owner fairness, priority
aging, cancellation, streaming/backpressure, replaceable state, retained final
outcomes and Unix wake hints. It forbids unsafe code; its one dependency, socket2 on
Apple targets, keeps wake-hint writes from raising SIGPIPE.

The first real client discovers Codex/Claude transcripts off-thread, with bounded
head/tail reads, bounded caching, incremental JSON delivery, generation filtering
and an explicit Elisp fallback. An opt-in desktop integration returns cached
snapshots to the agents sidebar while refreshing in the background, through LispM
Desktop's public session readers. Kernel dispatch runs on the desktop's frame clock,
after terminal drawing, within what is left of each frame's budget.
PTY emulation, status, exit and clipboard handling stay in the existing terminal module.

This is an experimental prototype, not a stable API or released package. Timers
poll while native requests exist; the native UnixStream notifier is not yet wired
directly into Emacs. GC, redisplay and long callbacks still affect responsiveness.
See [Goals](docs/GOALS.md), [architecture](docs/architecture.md) and
[validation](docs/validation.md) for completed checks and remaining acceptance gates.

## Build and test

```
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo fmt --all -- --check
cargo build --locked -p lispm-kernel-emacs
python3 scripts/test-emacs.py
```

Check this repository out next to lispm-desktop (`~/agents/lispm-kernel` beside
`~/agents/lispm-desktop`, say): the desktop parity/broker tests and the session
benchmark find it as `../lispm-desktop`. Set `LISPM_DESKTOP_ROOT` to use another checkout.
`scripts/test-emacs.py` builds the module with Cargo itself and tests the library
Cargo reports. Build a distributable local module with:

```
python3 scripts/package-module.py
```

It builds the release module for rustc's host target (or `--target`) and writes
`dist/kernel-module-<version>/`: `liblispm_kernel_emacs-<target>.dylib` (`.so` off
macOS), named and checksummed (`SHA256SUMS`) as LispM Desktop names its terminal
module, the Lisp files, the license and a manifest with protocol, version and
commit. Architecture is read from the binary header, avoiding translated Python
process architecture mistakes.

## The module, downloaded and checked

Nobody has to build the module or say where it is. `lisp/lispm-kernel-library.el`
downloads the library built for this computer from these sources, in the
background, and keeps and loads it only when its SHA-256 is the one pinned in
[`lisp/lispm-kernel-module-sums.eld`](lisp/lispm-kernel-module-sums.eld). Those
checksums come with the Lisp, from this repository's signed history, not from the
release beside the binaries: a library changed on the release after it was pinned is
refused, whatever the release's own `SHA256SUMS` says. When the download or the
check fails, the mode stays off and says why, and the desktop reads sessions itself.

Cargo is used only when asked: `(setopt lispm-kernel-library-source 'build)` builds
the module with `cargo build --release` from the sources there are, and again when
one is newer than the library Cargo built; nothing is downloaded then. That is the
way to run sources of your own, which no release has pinned.

The [kernel module workflow](.github/workflows/kernel-module.yml) builds the module
on main for macOS on Apple silicon and on Intel (11 and later) and for GNU/Linux on
x86_64, and publishes it as the release `kernel-module-<version>`, never marked
latest. The version is the first 16 digits of a SHA-256 over the sources (the
workspace's manifest and lock file, each crate's manifest, build script and
`src/**/*.rs`), so a release is made once per source change. Downloads are kept in
`prebuilt/<version>/`; `lispm-kernel-library-prebuilt-url` says where releases are.

### Releasing

Checksums exist only once the workflow has built the libraries, so a release of the
kernel takes two steps:

1. Merge the change of the sources. The workflow publishes `kernel-module-<version>`.
2. In a "Version X.Y.Z" pull request, run `python3 scripts/pin-module.py`. It
   downloads every library the release lists, refuses one that is not what its
   `SHA256SUMS` says or a release lacking a target, and writes the pins for the
   sources' version. Commit them with the new `Version` header of
   `lisp/lispm-kernel.el`.

That commit is the release package-vc, and so LispM Desktop, installs: its sources
and its pins agree. Between the two steps main's sources are not pinned, and only
`build` gets a module for them. The workflow's Version job checks the pins against
the release whenever they pin the sources (`pin-module.py --check`). Sources never at
main's tip have no release; run the workflow on main with their commit as `ref`.

## Opt-in use

It needs a LispM Desktop with session readers and a frame clock. In LispM Desktop,
setting `lispm-desktop-kernel` to t finds this repository beside the desktop's
checkout (`../lispm-kernel`), or installs its latest release with package-vc, and
turns the mode on, at once and at every start. Elsewhere, load `lisp/` of a checkout, or a
bundle, after the desktop's Lisp directory is available:

```elisp
(add-to-list 'load-path "/path/to/lispm-kernel/lisp")
(require 'lispm-kernel-desktop)
(lispm-kernel-desktop-mode 1)
;; Give the sessions back to the desktop's own readers:
;; (lispm-kernel-desktop-mode -1)
```

Until the module is downloaded and checked, or built, the mode is on and the
desktop's own readers answer. A bundle loads the library beside its Lisp files.
Setting `lispm-kernel-desktop-module` to a library loads that one as it is, nothing
being downloaded or built. Where no module can be had, or it is incompatible, the
mode turns off, saying why, and the desktop's own readers stay in use. Only the agents sidebar asks
the kernel; the session picker reads sessions the desktop's way. Explicit refresh
supersedes running scans. Remote and missing roots are read the desktop's way.
Native scan failure invokes the desktop's reader as a fallback, which retains its
main-thread latency. Enabling the mode does not change saved config, and
`unload-feature` undoes it.
