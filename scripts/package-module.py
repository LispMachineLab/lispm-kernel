#!/usr/bin/env python3
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build and package the kernel's Emacs module as lispm-desktop serves its
prebuilt terminal module.

The output directory (default dist/kernel-module-VERSION) holds, for each
packaged Rust target, liblispm_kernel_emacs-TARGET.dylib (Darwin) or .so,
SHA256SUMS over those libraries as sha256sum writes it, the Lisp files,
LICENSE, and manifest.json with the protocol, version and git commit.

The library is built here with Cargo for rustc's host target (not Python's,
which can run translated) or for --target, so a stale artifact is never
packaged, and its binary header must name the target's machine. Packaging
another target into the same directory adds its library when the build
identity (protocol, version, commit, dirty) is the same, and replaces the
libraries there otherwise.

LISPM_KERNEL_PROFILE sets the default profile, release; dev and debug both
name Cargo's dev profile, which builds into target/TRIPLE/debug.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "lispm-kernel-emacs"
CRATE = "lispm_kernel_emacs"
LIBRARY = "lib" + CRATE
LISP = ("lispm-kernel.el", "lispm-kernel-sessions.el",
        "lispm-kernel-desktop.el", "lispm-kernel-broker.el", "lispm-kernel-library.el")
# Cargo's profile names: `debug' is only the directory of the dev profile.
PROFILES = {"debug": "dev"}
# Machine codes of the binary headers, by the first field of a Rust triple.
MACH_O = {"aarch64": 0x0100000C, "x86_64": 0x01000007}
ELF = {"aarch64": 183, "x86_64": 62}


def run(*command):
    return subprocess.check_output(command, cwd=str(ROOT), universal_newlines=True)


def host_target():
    for line in run("rustc", "-vV").splitlines():
        if line.startswith("host: "):
            return line[len("host: "):].strip()
    sys.exit("rustc -vV names no host target")


def extension(target):
    """The suffix lispm-desktop-term.el gives libraries: dylib on Darwin, else so."""
    return "dylib" if target.endswith("-darwin") else "so"


def build(target, profile):
    """Build the module with Cargo and return the cdylib Cargo reports."""
    output = run("cargo", "build", "--locked", "-p", PACKAGE, "--target", target,
                 "--profile", profile, "--message-format=json-render-diagnostics")
    suffix = "." + extension(target)
    for line in output.splitlines():
        message = json.loads(line)
        if (message.get("reason") == "compiler-artifact"
                and message["target"]["name"] == CRATE
                and "cdylib" in message["target"]["kind"]):
            for name in message["filenames"]:
                if name.endswith(suffix):
                    return Path(name)
    sys.exit("Cargo reported no {} cdylib for {}".format(CRATE, target))


def check_header(library, target):
    """Refuse a library whose binary header does not name TARGET's machine."""
    machine = target.split("-")[0]
    header = library.read_bytes()[:64]
    if target.endswith("-darwin"):
        found = (header[:4] == b"\xcf\xfa\xed\xfe"
                 and struct.unpack_from("<I", header, 4)[0] == MACH_O.get(machine))
    elif "-linux-" in target:
        order = "<H" if header[5:6] == b"\x01" else ">H"
        found = (header[:4] == b"\x7fELF"
                 and struct.unpack_from(order, header, 18)[0] == ELF.get(machine))
    else:
        found = False
    if not found:
        sys.exit("{} is not a {} module: refusing to label it".format(library, target))


def python_runs(target):
    """Whether this Python process can load TARGET's libraries."""
    machine = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine().lower(),
                                                         platform.machine().lower())
    system = {"darwin": "-darwin", "linux": "-linux-"}.get(sys.platform)
    return target.split("-")[0] == machine and bool(system) and system in target


def check_loads(library):
    """Load LIBRARY and find an Emacs module's entry points, as the desktop's
    term-module workflow checks its library."""
    handle = ctypes.CDLL(str(library))
    for symbol in ("emacs_module_init", "plugin_is_GPL_compatible"):
        getattr(handle, symbol)


def protocol():
    source = (ROOT / "crates/emacs-module/src/lib.rs").read_text()
    match = re.search(r"const PROTOCOL_VERSION: u64 = (\d+);", source)
    if not match:
        sys.exit("crates/emacs-module/src/lib.rs defines no PROTOCOL_VERSION")
    return int(match.group(1))


def version():
    metadata = json.loads(run("cargo", "metadata", "--offline", "--no-deps",
                              "--format-version", "1"))
    return next(package["version"] for package in metadata["packages"]
                if package["name"] == PACKAGE)


def identity(package_version):
    """What makes two packaged libraries belong to one release."""
    commit = run("git", "rev-parse", "HEAD").strip()
    dirty = bool(run("git", "status", "--porcelain", "--untracked-files=no").strip())
    return {"protocol": protocol(), "version": package_version,
            "commit": commit, "dirty": dirty}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy(source, destination):
    """Copy SOURCE whole or not at all, as the desktop installs a download."""
    part = destination.with_name(destination.name + ".part")
    shutil.copyfile(str(source), str(part))
    os.replace(str(part), str(destination))


def libraries(output):
    return sorted(path for path in output.glob(LIBRARY + "-*")
                  if path.suffix in (".dylib", ".so"))


def kept_modules(output, build_identity):
    """The modules OUTPUT's manifest lists when they come from the same build
    identity; otherwise remove OUTPUT's libraries and keep none."""
    try:
        old = json.loads((output / "manifest.json").read_text())
    except (OSError, ValueError):
        old = {}
    if all(old.get(key) == value for key, value in build_identity.items()):
        return old.get("modules", {})
    for path in libraries(output):
        path.unlink()
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--target", help="Rust target triple (default: rustc's host)")
    parser.add_argument("--profile", default=os.environ.get("LISPM_KERNEL_PROFILE", "release"),
                        help="Cargo profile (default: release)")
    parser.add_argument("--output", type=Path, help="directory to package into")
    arguments = parser.parse_args()
    target = arguments.target or host_target()
    profile = PROFILES.get(arguments.profile, arguments.profile)
    package_version = version()
    output = arguments.output or ROOT / "dist" / ("kernel-module-" + package_version)

    library = build(target, profile)
    check_header(library, target)
    if python_runs(target):
        check_loads(library)
    else:
        print("Not loading the {} library into this {} Python".format(target, platform.machine()),
              file=sys.stderr)

    output.mkdir(parents=True, exist_ok=True)
    build_identity = identity(package_version)
    modules = kept_modules(output, build_identity)
    name = "{}-{}.{}".format(LIBRARY, target, extension(target))
    copy(library, output / name)
    for lisp in LISP:
        copy(ROOT / "lisp" / lisp, output / lisp)
    copy(ROOT / "LICENSE", output / "LICENSE")
    sums = "".join("{}  {}\n".format(sha256(path), path.name) for path in libraries(output))
    (output / "SHA256SUMS").write_text(sums)
    modules[target] = {"file": name, "sha256": sha256(output / name), "profile": profile}
    manifest = dict(build_identity, name="lispm-kernel-module", emacs_minimum="28",
                    modules=modules, lisp=list(LISP))
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(output)


if __name__ == "__main__":
    main()
