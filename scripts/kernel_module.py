# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build the lispm-kernel Emacs module with Cargo and return the library it built.

Asking Cargo, rather than searching target/, means a stale build or one for
another target triple is never picked up.
"""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "lispm-kernel-emacs"
CRATE = "lispm_kernel_emacs"
# Cargo's profile names; "debug" is the directory of its "dev" profile.
PROFILES = {"debug": "dev", "dev": "dev", "release": "release"}


def build(profile="dev"):
    """Build the module with PROFILE for Cargo's default target; return its path."""
    output = subprocess.check_output(
        ["cargo", "build", "--locked", "-p", PACKAGE, "--profile", PROFILES.get(profile, profile),
         "--message-format=json-render-diagnostics"],
        cwd=str(ROOT), universal_newlines=True)
    for line in output.splitlines():
        message = json.loads(line)
        if (message.get("reason") == "compiler-artifact"
                and message["target"]["name"] == CRATE
                and "cdylib" in message["target"]["kind"]):
            for name in message["filenames"]:
                if name.endswith((".dylib", ".so")):
                    return Path(name)
    sys.exit("Cargo reported no {} library".format(CRATE))
