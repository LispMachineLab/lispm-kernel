# lispm-kernel

Rust background runtime and cooperative Emacs frontend for
[LispM Desktop](https://github.com/LispMachineLab/lispm-desktop).
Design record: [desktop#48](https://github.com/LispMachineLab/lispm-desktop/issues/48).

The native core provides bounded admission, CPU/I/O pools, owner fairness, priority
aging, cancellation, streaming/backpressure, replaceable state, retained final
outcomes and Unix wake hints. It has no dependencies and forbids unsafe code.

The first real client discovers Codex/Claude transcripts off-thread, with bounded
head/tail reads, bounded caching, incremental JSON delivery, generation filtering
and an explicit Elisp fallback. An opt-in desktop integration returns cached
snapshots while refreshing in the background. A shared cooperative broker schedules
existing terminal drawing before session callbacks within an 8 ms soft budget.
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
Build a distributable local module with:

```
cargo build --release --locked -p lispm-kernel-emacs
python3 scripts/package-module.py
```

The bundle contains the native module, four Lisp files, license and a protocol/hash
manifest. Architecture is read from the binary header, avoiding translated Python
process architecture mistakes. No download, auto-build or automatic installation occurs.

## Opt-in use

Load the bundle after desktop's Lisp directory is available:

```elisp
(add-to-list 'load-path "/path/to/bundle")
(require 'lispm-kernel-desktop)
(setq lispm-kernel-desktop-module "/path/to/bundle/lispm-kernel-module.so")
(lispm-kernel-desktop-mode 1)
;; Restore the existing providers and terminal scheduler:
;; (lispm-kernel-desktop-mode -1)
```

Missing/incompatible modules retain the Elisp path. Explicit refresh invalidates
cached snapshots and cancels older generations. Remote roots use the existing
provider. Native scan failure invokes the provided Elisp fallback, which retains
its original main-thread latency. Enabling the mode does not change saved config.
