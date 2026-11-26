#!/usr/bin/env python3
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Three-way multi-agent concurrency benchmark for lispm-kernel + lispm-agent."""

from __future__ import annotations

import argparse
import http.server
import json
import os
import platform
import re
import shutil
import socketserver
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

MODES = ("elisp", "kernel-sse", "kernel-actors")
SHELL_PADDING = "bench_" * 630  # ~3.78 KB to stress streaming JSON accumulation


def _flatten_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
        return "\n".join(parts)
    return ""


def _make_handler(chunk_delay_s: float):
    class MockAnthropicHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            return

        def _send_sse(self, event: str, payload: dict[str, Any]) -> None:
            raw = f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode("utf-8")
            self.wfile.write(raw)
            self.wfile.flush()
            if chunk_delay_s > 0:
                time.sleep(chunk_delay_s)

        def _stream_text_block(self, idx: int, text: str, parts: int) -> None:
            self._send_sse(
                "content_block_start",
                {"type": "content_block_start", "index": idx, "content_block": {"type": "text", "text": ""}},
            )
            step = max(1, (len(text) + parts - 1) // parts)
            sent = 0
            while sent < len(text):
                self._send_sse(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": {"type": "text_delta", "text": text[sent : sent + step]},
                    },
                )
                sent += step
            self._send_sse("content_block_stop", {"type": "content_block_stop", "index": idx})

        def _stream_thinking_block(self, idx: int, chunks: int) -> None:
            self._send_sse(
                "content_block_start",
                {"type": "content_block_start", "index": idx, "content_block": {"type": "thinking", "thinking": ""}},
            )
            for k in range(chunks):
                self._send_sse(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": {"type": "thinking_delta", "thinking": f"step-thought-{k} "},
                    },
                )
            self._send_sse("content_block_stop", {"type": "content_block_stop", "index": idx})

        def _stream_tool_block(self, idx: int, call_id: str, name: str, tool_input: dict[str, Any]) -> None:
            self._send_sse(
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": idx,
                    "content_block": {"type": "tool_use", "id": call_id, "name": name, "input": {}},
                },
            )
            encoded = json.dumps(tool_input)
            for pos in range(0, len(encoded), 64):
                self._send_sse(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": idx,
                        "delta": {"type": "input_json_delta", "partial_json": encoded[pos : pos + 64]},
                    },
                )
            self._send_sse("content_block_stop", {"type": "content_block_stop", "index": idx})

        def do_POST(self) -> None:  # noqa: N802
            try:
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length).decode("utf-8"))
                messages = body.get("messages", [])
                prompt_text = _flatten_content(messages[0].get("content", "")) if messages else ""
                match = re.search(r"bench-target:(bench-buf-\d+)", prompt_text)
                buf_name = match.group(1) if match else "bench-buf-00"

                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()

                self._send_sse(
                    "message_start",
                    {"type": "message_start", "message": {"id": f"msg_{len(messages)}", "usage": {"input_tokens": 18}}},
                )
                turn_len = len(messages)
                if turn_len == 1:
                    self._stream_thinking_block(0, 16)
                    self._stream_text_block(1, "Inspecting workspace via run_shell now. ", 8)
                    cmd = f"printf sh-ok && ls tracked.txt # {SHELL_PADDING}"
                    self._stream_tool_block(
                        2,
                        f"{buf_name}_s1",
                        "run_shell",
                        {"command": cmd, "why": "bench shell check"},
                    )
                    stop_reason = "tool_use"
                elif turn_len == 3:
                    self._stream_thinking_block(0, 8)
                    self._stream_tool_block(
                        1, f"{buf_name}_s2a", "search_files", {"pattern": "bench-needle"}
                    )
                    self._stream_tool_block(
                        2, f"{buf_name}_s2b", "read_file", {"path": "tracked.txt", "offset": 1, "limit": 10}
                    )
                    stop_reason = "tool_use"
                elif turn_len == 5:
                    self._stream_text_block(0, f"Updating live buffer {buf_name} now. ", 8)
                    self._stream_tool_block(
                        1,
                        f"{buf_name}_s3",
                        "edit_buffer",
                        {"buffer": buf_name, "old_text": "OLD", "new_text": "NEW"},
                    )
                    stop_reason = "tool_use"
                else:
                    self._stream_text_block(0, "Multi-agent verification complete: agent-bench-complete ok.", 24)
                    stop_reason = "end_turn"

                self._send_sse(
                    "message_delta",
                    {
                        "type": "message_delta",
                        "delta": {"stop_reason": stop_reason},
                        "usage": {"output_tokens": 20},
                    },
                )
                self._send_sse("message_stop", {"type": "message_stop"})
            except BrokenPipeError:
                return
            except Exception as exc:  # noqa: BLE001
                print(f"MockAnthropicHandler error: {exc}", file=sys.stderr)

    return MockAnthropicHandler


class BenchHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 256


def _setup_workspace() -> str:
    root = tempfile.mkdtemp(prefix="lispm-bench-ws-")
    with open(os.path.join(root, "tracked.txt"), "w", encoding="utf-8") as fh:
        fh.write("bench-needle line 1\nbench-needle line 2\n")
    src_dir = os.path.join(root, "src")
    os.makedirs(src_dir, exist_ok=True)
    for k in range(20):
        with open(os.path.join(src_dir, f"f{k:02d}.txt"), "w", encoding="utf-8") as fh:
            fh.write(f"module {k} content\n" * 4)
    subprocess.run(["git", "init", "-q"], cwd=root, check=True, timeout=15)
    subprocess.run(["git", "add", "."], cwd=root, check=True, timeout=15)
    subprocess.run(
        ["git", "-c", "user.name=Bench", "-c", "user.email=bench@example.invalid", "commit", "-q", "-m", "init"],
        cwd=root,
        check=True,
        timeout=15,
    )
    return root


def _run_emacs_trial(
    args: argparse.Namespace,
    repo_root: Path,
    workspace: str,
    url: str,
    count: int,
    mode: str,
) -> dict[str, Any]:
    env = os.environ.copy()
    env["LISPM_KERNEL_PROGRAM"] = os.path.abspath(args.program)
    env["LISPM_BENCH_AGENT_DEPS"] = os.path.abspath(args.agent_deps)
    env["LISPM_BENCH_MODE"] = mode
    env["LISPM_BENCH_AGENTS"] = str(count)
    env["LISPM_BENCH_URL"] = url
    env["LISPM_BENCH_WORKSPACE"] = workspace
    env["LISPM_BENCH_AGENTS_RUN"] = "1"

    cmd = [
        args.emacs,
        "-Q",
        "--batch",
        "-L",
        str(repo_root / "lisp"),
        "-L",
        os.path.abspath(args.ui),
        "-L",
        os.path.abspath(args.auth),
        "-L",
        os.path.abspath(args.agent),
        "-l",
        str(repo_root / "bench" / "agent-control-plane.el"),
    ]
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Trial failed (agents={count}, mode={mode}, rc={proc.returncode}):\n"
            f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    lines = proc.stdout.splitlines()
    try:
        marker_idx = lines.index("BENCH-JSON")
    except ValueError as exc:
        raise RuntimeError(f"Missing BENCH-JSON in output for {mode}/{count}:\n{proc.stdout}\n{proc.stderr}") from exc
    return json.loads(lines[marker_idx + 1])


def _aggregate(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[int, str], list[dict[str, Any]]] = {}
    for run in runs:
        grouped.setdefault((run["agents"], run["mode"]), []).append(run)
    metrics = (
        "wall_ms",
        "throughput_agents_per_sec",
        "event_loop_p50_ms",
        "event_loop_p95_ms",
        "event_loop_p99_ms",
        "event_loop_max_ms",
        "stalls_over_16ms",
        "timer_samples",
        "emacs_gcs",
        "emacs_gc_ms",
        "wire_frames",
        "kernel_heap_mb",
        "kernel_gc_ms",
        "kernel_outbox_peak",
        "kernel_reactor_peak",
    )
    summary = []
    for (agents, mode) in sorted(grouped, key=lambda key: (key[0], MODES.index(key[1]))):
        items = grouped[(agents, mode)]
        row: dict[str, Any] = {"agents": agents, "mode": mode, "repeats": len(items)}
        for m in metrics:
            row[m] = round(float(statistics.median(item[m] for item in items)), 2)
        summary.append(row)
    return summary


def _print_table(summary: list[dict[str, Any]]) -> None:
    print(
        "| Agents | Mode | Wall (ms) | Throughput (agents/s) | p95 lag (ms) | max lag (ms) | >16ms stalls | Emacs GCs | Wire frames | Kernel heap (MB) |"
    )
    print("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in summary:
        print(
            f"| {r['agents']} | {r['mode']} | {r['wall_ms']:.1f} | {r['throughput_agents_per_sec']:.2f} | "
            f"{r['event_loop_p95_ms']:.2f} | {r['event_loop_max_ms']:.2f} | {int(r['stalls_over_16ms'])} | "
            f"{int(r['emacs_gcs'])} | {int(r['wire_frames'])} | {r['kernel_heap_mb']:.1f} |"
        )


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emacs", default="emacs")
    parser.add_argument("--program", default=str(repo_root / "build" / "lispm-kernel"))
    parser.add_argument("--agent", default=str(repo_root.parent / "lispm-agent" / "lisp"))
    parser.add_argument("--agent-deps", default=str(repo_root.parent / "lispm-agent" / ".deps"))
    parser.add_argument("--ui", default=str(repo_root.parent / "lispm-ui"))
    parser.add_argument("--auth", default=str(repo_root.parent / "lispm-auth"))
    parser.add_argument("--agents", default="8,24,32")
    parser.add_argument("--repeats", type=int, default=4)
    parser.add_argument("--chunk-delay-ms", type=float, default=0.5)
    parser.add_argument("--output", default=str(repo_root / "docs" / "agent-benchmark.json"))
    args = parser.parse_args()

    agent_counts = [int(x.strip()) for x in args.agents.split(",") if x.strip()]
    workspace = _setup_workspace()
    handler = _make_handler(args.chunk_delay_ms / 1000.0)
    srv = BenchHTTPServer(("127.0.0.1", 0), handler)
    url = f"http://127.0.0.1:{srv.server_address[1]}"
    runs: list[dict[str, Any]] = []
    try:
        import threading

        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        for count in agent_counts:
            for rep in range(args.repeats):
                order = MODES[rep % len(MODES) :] + MODES[: rep % len(MODES)]
                for mode in order:
                    res = _run_emacs_trial(args, repo_root, workspace, url, count, mode)
                    res["repeat"] = rep + 1
                    runs.append(res)
                    print(
                        f"[{count} agents | rep {rep + 1}/{args.repeats} | {mode:13s}] "
                        f"wall={res['wall_ms']:.1f}ms p95={res['event_loop_p95_ms']:.2f}ms "
                        f"max={res['event_loop_max_ms']:.2f}ms stalls={res['stalls_over_16ms']}",
                        flush=True,
                    )
    finally:
        srv.shutdown()
        srv.server_close()
        shutil.rmtree(workspace, ignore_errors=True)

    summary = _aggregate(runs)
    emacs_ver = subprocess.check_output([args.emacs, "--version"], text=True, timeout=10).splitlines()[0]
    report = {
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
            "emacs": emacs_ver,
            "program": os.path.relpath(os.path.abspath(args.program), repo_root),
            "agent_counts": agent_counts,
            "repeats": args.repeats,
            "chunk_delay_ms": args.chunk_delay_ms,
        },
        "summary": summary,
        "runs": runs,
    }
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print()
    _print_table(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
