#!/usr/bin/env python3
"""Run a native test command under a portable POSIX process-group deadline."""

import os
import signal
import subprocess
import sys


def usage() -> int:
    print(f"usage: {sys.argv[0]} SECONDS COMMAND [ARG ...]", file=sys.stderr)
    return 2


def main() -> int:
    if len(sys.argv) < 3:
        return usage()
    try:
        timeout = float(sys.argv[1])
    except ValueError:
        return usage()
    if timeout <= 0:
        return usage()

    process = subprocess.Popen(sys.argv[2:], start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(
            f"native Titan test deadline exceeded after {timeout:g}s: "
            + " ".join(sys.argv[2:]),
            file=sys.stderr,
            flush=True,
        )
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
