#!/usr/bin/env python3
"""Run synthetic session benchmark against an explicitly selected desktop checkout."""
import json
import os
from pathlib import Path
import subprocess
import resource
import sys
root = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    sys.exit("Usage: python3 scripts/bench-sessions.py /path/to/lispm-desktop")
desktop = Path(sys.argv[1]).resolve()
metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--offline", "--no-deps", "--format-version", "1"], cwd=root))
suffix = ".dylib" if sys.platform == "darwin" else ".so"
modules = [p for p in Path(metadata["target_directory"]).rglob("liblispm_kernel_emacs" + suffix) if p.parent.name == os.environ.get("LISPM_KERNEL_PROFILE", "debug")]
if not modules:
    sys.exit("Build the module first")
env = dict(os.environ, LISPM_KERNEL_MODULE=str(max(modules, key=lambda p: p.stat().st_mtime)))
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
