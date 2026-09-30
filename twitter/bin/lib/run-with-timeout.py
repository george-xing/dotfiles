#!/usr/bin/env python3
"""Run a command in its own process group with a hard wall-clock deadline."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time


TIMEOUT_EXIT = 124


def terminate_group(proc: subprocess.Popen[bytes], grace_seconds: float) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    deadline = time.monotonic() + max(0.0, grace_seconds)
    while proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.1)

    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--grace", type=float, default=10.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if args.timeout <= 0 or not command:
        parser.error("--timeout must be positive and a command is required")

    proc = subprocess.Popen(command, start_new_session=True)
    deadline = time.monotonic() + args.timeout
    forwarded_signal: int | None = None

    def forward(signum: int, _frame: object) -> None:
        nonlocal forwarded_signal
        forwarded_signal = signum
        terminate_group(proc, args.grace)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, forward)

    while proc.poll() is None:
        if forwarded_signal is not None:
            proc.wait()
            return 128 + forwarded_signal
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(
                f"twitter-agent-runner: timed out after {args.timeout:g}s; "
                "terminating process group",
                file=sys.stderr,
                flush=True,
            )
            terminate_group(proc, args.grace)
            proc.wait()
            return TIMEOUT_EXIT
        try:
            proc.wait(timeout=min(0.25, remaining))
        except subprocess.TimeoutExpired:
            pass

    return int(proc.returncode or 0)


if __name__ == "__main__":
    raise SystemExit(main())
