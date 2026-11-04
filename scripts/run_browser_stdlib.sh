#!/usr/bin/env bash
set -euo pipefail

stdout_log=${1:?stdout log required}
stderr_log=${2:?stderr log required}
shift 2

# Keep stderr diagnostics out of the runner's line-oriented test report.
status=0
"$@" >"$stdout_log" 2>"$stderr_log" || status=$?
cat "$stdout_log"
cat "$stderr_log" >&2
exit "$status"
