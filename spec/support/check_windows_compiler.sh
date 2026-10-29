#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && ${MSYSTEM:-} == CLANG64 ]]
prefix=$(cd "$1" && pwd)
build=$(cd "$2" && pwd)
check=$(mktemp -d "$build/compiler-check.XXXXXX")
runtime="$check/compiler space 文 😀"
mkdir -p "$runtime" "$check/cwd"
cp -R "$prefix/bin" "$prefix/lib" "$prefix/share" "$runtime/"
for module in lfs lpeglabel luv; do
  perl spec/support/check_windows_compiler_pe.pl --allow-extra-exports "$runtime/lib/lua/5.5/$module.dll" "luaopen_$module"
done
# The support module is one ordinary native module with a single export.
perl spec/support/check_windows_compiler_pe.pl "$runtime/lib/lua/5.5/titan.dll" luaopen_titan
unset LUA_INIT LUA_INIT_5_5 LUA_PATH LUA_PATH_5_5 LUA_CPATH LUA_CPATH_5_5
export MSYS2_ARG_CONV_EXCL='*'
(cd "$check/cwd"; "$runtime/bin/lua.exe" -E -e '
  for _, name in ipairs {"argparse", "inspect", "lfs", "lpeglabel", "luv", "relabel", "titan-compiler.driver"} do
    assert(require(name), name)
  end
  print("LuaRocks-installed compiler and dependencies load from the relocated Lua SDK.")
')
(cd "$check/cwd"; "$runtime/bin/lua.exe" -E "$(cygpath -m "$runtime/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc")" --help) > "$check/help.txt"
grep -F 'Titan compiler' "$check/help.txt"
printf '%s\n' "$runtime" > "$build/compiler-check-runtime.txt"
printf 'LuaRocks compiler/dependency/import gates passed: %s\n' "$check"
