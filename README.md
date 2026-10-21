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
module, the four Lisp files, the license and a manifest with protocol, version and
commit. Architecture is read from the binary header, avoiding translated Python
process architecture mistakes. No download, auto-build or automatic installation occurs.

## Opt-in use

It needs a LispM Desktop with session readers and a frame clock. Load the bundle,
or `lisp/` of a checkout, after the desktop's Lisp directory is available:

```elisp
(add-to-list 'load-path "/path/to/bundle")
(require 'lispm-kernel-desktop)
(setq lispm-kernel-desktop-module
      "/path/to/bundle/liblispm_kernel_emacs-aarch64-apple-darwin.dylib")
(lispm-kernel-desktop-mode 1)
;; Give the sessions back to the desktop's own readers:
;; (lispm-kernel-desktop-mode -1)
```

Missing/incompatible modules keep the mode off and the desktop's own readers in
use. Only the agents sidebar asks the kernel; the session picker reads sessions the
desktop's way. Explicit refresh supersedes running scans. Remote and missing roots
are read the desktop's way. Native scan failure invokes the desktop's reader as a
fallback, which retains its main-thread latency. Enabling the mode does not change
saved config, and `unload-feature` undoes it.
