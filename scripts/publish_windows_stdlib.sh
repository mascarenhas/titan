#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 || ${MSYSTEM:-} != CLANG64 || ! $3 =~ ^(check|publish)$ ]]; then
  echo 'usage (native CLANG64): publish_windows_stdlib.sh BUILD_ROOT SDK_PREFIX check|publish' >&2
  exit 2
fi
build_root=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
perl scripts/windows_compiler_receipt.pl check "$prefix"
source_root=$(pwd)
mode=$3
[[ -f titan.dll && ! -L titan.dll && -f $build_root/runtime/titan.dll ]]
# All copied inputs belong to this invocation. The validation child exits before
# the separate publisher maps its private support-only bootstrap.
stage=$(mktemp -d "$build_root/.stdlib-publication.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp titan.dll "$stage/titan.dll"
cp "$build_root/runtime/titan.dll" "$stage/support.dll"
cp titan/test.titan "$stage/test.titan"
modules=(coroutine uv async timer io fs net ssl url http websocket os peg string math lua iteration gc test reflect sqlite3 json)
for module in "${modules[@]}"; do
  [[ -f titan/$module.lua && ! -L titan/$module.lua ]]
  cp "titan/$module.lua" "$stage/$module.lua"
done
llvm-readobj --coff-exports "$stage/titan.dll" > "$stage/provider.exports"
llvm-readobj --coff-imports "$stage/titan.dll" > "$stage/provider.imports"
if [[ -e $prefix/lib/titan/0.6/titan.dll ]]; then
  llvm-readobj --coff-exports "$prefix/lib/titan/0.6/titan.dll" > "$stage/previous.exports"
  llvm-readobj --coff-imports "$prefix/lib/titan/0.6/titan.dll" > "$stage/previous.imports"
fi
export TITAN_ROCKS_ROOT="$(cygpath -m "$prefix")" TITAN_RUNTIME_PREBUILT=1
export MSYS2_ARG_CONV_EXCL='*'
args=("$(cygpath -m "$stage")" "$(cygpath -m "$prefix")" "$(cygpath -m "$source_root")" "$(cygpath -m "$stage/support.dll")")
"$prefix/bin/lua.exe" "$(cygpath -m "$source_root/scripts/windows_stdlib.lua")" validate "${args[@]}"
if [[ $mode == publish ]]; then
  "$prefix/bin/lua.exe" "$(cygpath -m "$source_root/scripts/windows_stdlib.lua")" publish "${args[@]}"
fi
