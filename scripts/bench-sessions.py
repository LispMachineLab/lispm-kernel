#!/usr/bin/env python3
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run synthetic session benchmark against a desktop checkout (default: ../lispm-desktop)."""
import json
import os
from pathlib import Path
import subprocess
import resource
import sys

from kernel_module import ROOT as root, build

if len(sys.argv) > 2:
    sys.exit("Usage: python3 scripts/bench-sessions.py [/path/to/lispm-desktop]")
desktop = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else root.parent / "lispm-desktop"
if not (desktop / "lisp").is_dir():
    sys.exit(f"No lispm-desktop checkout at {desktop}")
env = dict(os.environ, LISPM_KERNEL_MODULE=str(build(os.environ.get("LISPM_KERNEL_PROFILE", "dev"))))
before = resource.getrusage(resource.RUSAGE_CHILDREN)
result = subprocess.run([os.environ.get("EMACS", "emacs"), "-Q", "--batch", "-L", str(desktop / "lisp"), "-L", str(root / "lisp"), "-l", str(root / "bench/session-discovery.el")], env=env, cwd=root, check=True, stdout=subprocess.PIPE, text=True)
after = resource.getrusage(resource.RUSAGE_CHILDREN)
report = json.loads(result.stdout)
report["process_resources"] = {
    "user_cpu_seconds": after.ru_utime - before.ru_utime,
    "system_cpu_seconds": after.ru_stime - before.ru_stime,
    "child_max_rss_bytes": after.ru_maxrss * (1 if sys.platform == "darwin" else 1024),
    "scope": "whole batch process including fixture creation and all four cases; not per-case RSS"
}
print(json.dumps(report))
