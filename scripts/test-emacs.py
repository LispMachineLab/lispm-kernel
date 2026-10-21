#!/usr/bin/env python3
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run real-module ERT with the module Cargo builds (LISPM_KERNEL_PROFILE, default dev)."""
import os
from pathlib import Path
import subprocess
import sys

from kernel_module import ROOT as root, build

module = build(os.environ.get("LISPM_KERNEL_PROFILE", "dev"))
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
