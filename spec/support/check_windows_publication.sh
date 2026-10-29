#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_publication.sh BUILD_ROOT SDK_PREFIX' >&2
  exit 2
fi
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
image="$build_root/runtime/titan.dll"
[[ -f $image && -f $prefix/bin/lua.exe ]] || {
  echo "missing support image or interpreter: $image" >&2
  exit 1
}
stage=$(mktemp -d "$build_root/.publication-check.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp "$image" "$stage/support.dll"
cp titan-compiler/windows_publication.lua "$stage/windows_publication.lua"
cp spec/support/windows_publication_probe.lua "$stage/probe.lua"
export MSYS2_ARG_CONV_EXCL='*'
"$prefix/bin/lua.exe" "$(cygpath -m "$stage/probe.lua")" "$(cygpath -m "$stage")"
