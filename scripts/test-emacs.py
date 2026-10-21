#!/usr/bin/env python3
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run real-module ERT with the most recently built debug module."""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
metadata = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--offline", "--no-deps", "--format-version", "1"], cwd=root
))
suffix = ".dylib" if sys.platform == "darwin" else ".so"
modules = [p for p in Path(metadata["target_directory"]).rglob("liblispm_kernel_emacs" + suffix)
           if p.parent.name == os.environ.get("LISPM_KERNEL_PROFILE", "debug")]
if not modules:
    sys.exit("Build first: cargo build --locked -p lispm-kernel-emacs")
module = max(modules, key=lambda path: path.stat().st_mtime)
env = dict(os.environ, LISPM_KERNEL_MODULE=str(module))
command = [os.environ.get("EMACS", "emacs"), "-Q", "--batch", "--eval", "(setq native-comp-enable-subr-trampolines nil)", "-L", str(root / "lisp"),
           "-l", str(root / "test/lispm-kernel-test.el")]
# Desktop tests use LISPM_DESKTOP_ROOT, else a lispm-desktop checkout next to this one.
desktop_root = os.environ.get("LISPM_DESKTOP_ROOT")
desktop = Path(desktop_root) if desktop_root else root.parent / "lispm-desktop"
if desktop_root or (desktop / "lisp").is_dir():
    command += ["-L", str(desktop / "lisp"),
                "-l", str(root / "test/lispm-kernel-desktop-test.el")]
else:
    print(f"Skipping desktop tests: no {desktop}", file=sys.stderr)
command += ["-f", "ert-run-tests-batch-and-exit"]
subprocess.run(command, cwd=root, env=env, check=True)
