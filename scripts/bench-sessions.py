#!/usr/bin/env python3
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run the synthetic session-discovery benchmark, repeat it and aggregate it.

Each repetition runs one batch Emacs which generates the fixtures and reads
them four ways: lispm-agent's reader and the kernel, each cold then warm.
Repetitions alternate the order, so neither reader always finds the files
in the operating system's cache.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
MODES = ("elisp-cold", "kernel-cold", "elisp-warm", "kernel-warm")


def existing_directory(value, what):
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        sys.exit(f"No {what} at {path}")
    return path


def emacs_paths(args):
    paths = {
        "agent": args.agent or os.environ.get("LISPM_AGENT_LISP")
        or ROOT.parent / "lispm-agent" / "lisp",
        "kit": args.kit or os.environ.get("LISPM_KIT") or ROOT.parent / "lispm-kit",
        "ui": args.ui or os.environ.get("LISPM_UI") or ROOT.parent / "lispm-ui",
        "desktop": args.desktop or os.environ.get("LISPM_DESKTOP_LISP")
        or ROOT.parent / "lispm-desktop" / "lisp",
    }
    agent = existing_directory(paths["agent"], "lispm-agent lisp directory "
                               "(set LISPM_AGENT_LISP or --agent)")
    kit = existing_directory(paths["kit"], "LISPM Kit checkout")
    ui = existing_directory(paths["ui"], "LISPM UI checkout")
    load_path = [ROOT / "lisp", agent, kit, ui]
    if args.terminals > 0:
        load_path.append(existing_directory(paths["desktop"], "LISPM Desktop lisp directory"))
    elif Path(paths["desktop"]).is_dir():
        load_path.append(Path(paths["desktop"]).resolve())
    return [str(path) for path in load_path]


def build_program(args):
    program = ROOT / "build" / "lispm-kernel"
    if program.is_file() and not args.build:
        return program
    print(f"Building {program} ...", file=sys.stderr)
    subprocess.run(args.make, cwd=ROOT, check=True)
    if not program.is_file():
        sys.exit(f"The build left no program at {program}")
    return program


def run_once(args, program, load_path, order):
    env = dict(os.environ,
               LISPM_KERNEL_PROGRAM=str(program),
               LISPM_BENCH_COUNT=str(args.count),
               LISPM_BENCH_FILLER=str(args.filler),
               LISPM_BENCH_TERMINALS=str(args.terminals),
               LISPM_BENCH_ORDER=order)
    command = [args.emacs, "-Q", "--batch"]
    for path in load_path:
        command += ["-L", path]
    command += ["-l", str(ROOT / "bench" / "session-discovery.el")]
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.time()
    completed = subprocess.run(command, env=env, cwd=ROOT, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=args.timeout)
    elapsed = time.time() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr[-4000:])
        sys.exit(f"Emacs exited {completed.returncode} for order {order}")
    lines = completed.stdout.splitlines()
    if "BENCH-JSON" not in lines:
        sys.stderr.write(completed.stdout[-2000:])
        sys.stderr.write(completed.stderr[-4000:])
        sys.exit(f"No BENCH-JSON in Emacs's output for order {order}")
    report = json.loads(lines[lines.index("BENCH-JSON") + 1])
    report["process_resources"] = {
        "wall_seconds": round(elapsed, 3),
        "user_cpu_seconds": round(after.ru_utime - before.ru_utime, 3),
        "system_cpu_seconds": round(after.ru_stime - before.ru_stime, 3),
        "scope": "whole batch process: fixture creation, terminals and every case",
    }
    return report


def sysctl(key):
    """Return the macOS system control KEY's value, or None elsewhere."""
    if platform.system() != "Darwin":
        return None
    try:
        completed = subprocess.run(["sysctl", "-n", key], text=True,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
    except OSError:
        return None
    value = completed.stdout.strip()
    return value or None


def host_info():
    """Return what this run's machine is.

    platform.machine() reports X86_64 when Python itself runs translated
    under Rosetta on Apple Silicon, so ask the kernel instead: hw.optional.arm64
    is 1 on such a machine whatever the translating process reports.
    """
    arm64 = sysctl("hw.optional.arm64") == "1"
    return {
        "system": platform.platform(),
        "machine": "arm64" if arm64 else platform.machine(),
        "processor": sysctl("machdep.cpu.brand_string"),
        "cpus": os.cpu_count(),
        "python": platform.python_version(),
        "python_machine": platform.machine(),
        "python_translated": bool(arm64 and platform.machine() != "arm64"),
    }


def median(values):
    return statistics.median(values) if values else None


def summarize(runs):
    summary = {}
    for mode in MODES:
        cases = [next(r for r in run["results"] if r["mode"] == mode) for run in runs]
        summary[mode] = {
            "elapsed_ms": round(median([c["elapsed_ms"] for c in cases]), 3),
            "p50_ms": round(median([c["probe"]["p50"] for c in cases]), 3),
            "p95_ms": round(median([c["probe"]["p95"] for c in cases]), 3),
            "p99_ms": round(median([c["probe"]["p99"] for c in cases]), 3),
            "max_ms": round(max(c["probe"]["max"] for c in cases), 3),
            "gcs": round(median([c["gcs"] for c in cases]), 3),
            "gc_ms": round(median([c["gc_ms"] for c in cases]), 3),
            "rows": cases[0]["rows"],
        }
    return summary


def comparison(summary):
    def ratio(kernel, elisp):
        if not summary[kernel]["elapsed_ms"] or not summary[elisp]["elapsed_ms"]:
            return None
        return round(summary[elisp]["elapsed_ms"] / summary[kernel]["elapsed_ms"], 2)

    return {
        "cold_kernel_over_elisp": ratio("kernel-cold", "elisp-cold"),
        "warm_kernel_over_elisp": ratio("kernel-warm", "elisp-warm"),
        "note": "ratios above 1 mean the kernel finished in less time",
    }


def print_table(summary):
    print(f"{'mode':<14} {'elapsed':>10} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8} {'rows':>6}")
    for mode in MODES:
        row = summary[mode]
        print(f"{mode:<14} {row['elapsed_ms']:>10.1f} {row['p50_ms']:>8.2f} "
              f"{row['p95_ms']:>8.2f} {row['p99_ms']:>8.2f} {row['max_ms']:>8.2f} "
              f"{row['rows']:>6}")
    print("(elapsed in ms; probe lateness in ms; rows must equal the fixture count)")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--terminals", type=int, default=0,
                        help="terminals writing at once, one shown")
    parser.add_argument("--count", type=int, default=256,
                        help="synthetic transcripts (default 256)")
    parser.add_argument("--filler", type=int, default=128,
                        help="filler lines per transcript (default 128)")
    parser.add_argument("--output", type=Path, default=ROOT / "docs" / "session-benchmark.json")
    parser.add_argument("--emacs", default=os.environ.get("EMACS", "emacs"))
    parser.add_argument("--make", default=os.environ.get("MAKE", "make"))
    parser.add_argument("--build", action="store_true", help="build the kernel program first")
    parser.add_argument("--agent", help="lispm-agent lisp directory")
    parser.add_argument("--kit", help="LISPM Kit checkout")
    parser.add_argument("--ui", help="LISPM UI checkout")
    parser.add_argument("--desktop", help="LISPM Desktop lisp directory")
    parser.add_argument("--timeout", type=int, default=600)
    return parser.parse_args()


def main():
    args = parse_args()
    if args.repeats < 1:
        sys.exit("--repeats must be at least 1")
    program = build_program(args)
    load_path = emacs_paths(args)
    runs = []
    for index in range(args.repeats):
        order = "elisp-first" if index % 2 == 0 else "kernel-first"
        print(f"Run {index + 1}/{args.repeats} ({order}, {args.terminals} terminals) ...",
              file=sys.stderr)
        runs.append(run_once(args, program, load_path, order))
    summary = summarize(runs)
    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "repeats": args.repeats,
        "host": host_info(),
        "orders": ["elisp-first" if i % 2 == 0 else "kernel-first" for i in range(args.repeats)],
        "environment": runs[0]["environment"],
        "summary": summary,
        "comparison": comparison(summary),
        "runs": runs,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print_table(summary)
    print(f"kernel/elisp speedups (above 1 means the kernel was faster): "
          f"cold {report['comparison']['cold_kernel_over_elisp']}x, "
          f"warm {report['comparison']['warm_kernel_over_elisp']}x")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
