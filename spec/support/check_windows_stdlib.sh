#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_stdlib.sh BUILD_ROOT SDK_PREFIX' >&2
  exit 2
fi
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
source_root=$(pwd)
stage=$(mktemp -d "$build_root/.stdlib-check.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp titan.dll "$stage/titan.dll"
cp "$build_root/runtime/titan.dll" "$stage/support.dll"
cp titan/test.titan "$stage/test.titan"
for module in coroutine uv async timer io fs net ssl url http websocket os path peg string math lua iteration gc test reflect sqlite3 json; do
  cp "titan/$module.lua" "$stage/$module.lua"
done
llvm-readobj --coff-exports "$stage/titan.dll" > "$stage/provider.exports"
llvm-readobj --coff-imports "$stage/titan.dll" > "$stage/provider.imports"
export TITAN_ROCKS_ROOT="$(cygpath -m "$prefix")" TITAN_RUNTIME_PREBUILT=1
export MSYS2_ARG_CONV_EXCL='*'
"$prefix/bin/lua.exe" "$(cygpath -m "$source_root/spec/support/check_windows_stdlib.lua")" \
  "$(cygpath -m "$stage")" "$(cygpath -m "$prefix")" \
  "$(cygpath -m "$source_root")" "$(cygpath -m "$stage/support.dll")"
