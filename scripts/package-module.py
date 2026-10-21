#!/usr/bin/env python3
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Package a previously built module and a reproducible compatibility manifest."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import struct
import sys
root = Path(__file__).resolve().parents[1]
metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--offline", "--no-deps", "--format-version", "1"], cwd=root))
profile = os.environ.get("LISPM_KERNEL_PROFILE", "release")
suffix = ".dylib" if sys.platform == "darwin" else ".so"
modules = [p for p in Path(metadata["target_directory"]).rglob("liblispm_kernel_emacs" + suffix) if p.parent.name == profile]
if not modules:
    sys.exit("Build first: cargo build --release --locked -p lispm-kernel-emacs")
source = max(modules, key=lambda p: p.stat().st_mtime)
header = source.read_bytes()[:64]
if header[:4] == b"\xcf\xfa\xed\xfe":
    architecture = {0x0100000C: "aarch64", 0x01000007: "x86_64"}.get(struct.unpack_from("<I", header, 4)[0])
elif header[:4] == b"\x7fELF":
    architecture = {183: "aarch64", 62: "x86_64"}.get(struct.unpack_from("<H" if header[5] == 1 else ">H", header, 18)[0])
else:
    architecture = None
if architecture is None:
    sys.exit("Unsupported module header: cannot safely label target architecture")
output = root / "dist" / (platform.system().lower() + "-" + architecture)
output.mkdir(parents=True, exist_ok=True)
module = output / "lispm-kernel-module.so"
shutil.copyfile(source, module)
for name in ("lispm-kernel.el", "lispm-kernel-sessions.el", "lispm-kernel-desktop.el", "lispm-kernel-broker.el"):
    shutil.copyfile(root / "lisp" / name, output / name)
shutil.copyfile(root / "LICENSE", output / "LICENSE")
version = next(package["version"] for package in metadata["packages"] if package["name"] == "lispm-kernel-emacs")
manifest = {"version": version, "protocol": 1, "emacs_minimum": "28", "profile": profile,
            "system": platform.system(), "machine": architecture,
            "module": module.name, "sha256": hashlib.sha256(module.read_bytes()).hexdigest()}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(output)
