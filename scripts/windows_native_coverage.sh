#!/usr/bin/env bash
# Coverage retains its own compiler output tree and gcno inventory in WORKSPACE,
# while reusing the ordinary SDK refresh, incremental build and serial runner.
set -euo pipefail
if [[ ${MSYSTEM:-} != CLANG64 || $# -lt 2 ||
      ( $1 != build && $1 != run ) ||
      ( $1 == build && $# != 3 ) || ( $1 == run && $# != 2 ) ]]; then
  echo 'usage (native CLANG64): windows_native_coverage.sh build WORKSPACE SDK | run WORKSPACE' >&2
  exit 2
fi
export TITAN_TEST_COVERAGE=1
exec bash "$(dirname "$0")/../spec/support/windows_stdlib_tests.sh" "$@"
