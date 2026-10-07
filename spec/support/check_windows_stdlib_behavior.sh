#!/usr/bin/env bash
# Convenience full-gate entrypoint; Make also exposes separate build/run targets.
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_stdlib_behavior.sh NTFS_WORK_PARENT VALIDATED_SDK_PREFIX' >&2
  exit 2
fi
source_root=$(cd "$(dirname "$0")/../.." && pwd)
work_parent=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
bash "$source_root/spec/support/check_windows_stdlib_workspace.sh" "$work_parent"
# Reserve a unique name, then let the builder create and mark its owned directory.
work=$(mktemp -d "$work_parent/titan-stdlib-tests.XXXXXXXX")
rmdir "$work"
echo "Windows shared native suite workspace: $work"
bash "$source_root/spec/support/windows_stdlib_tests.sh" build "$work" "$prefix"
bash "$source_root/spec/support/windows_stdlib_tests.sh" run "$work"
