#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && ${MSYSTEM:-} == CLANG64 ]]
prefix=$(cd "$1" && pwd)
build=$(cd "$2" && pwd)
perl scripts/windows_compiler_receipt.pl check "$prefix"
check=$(mktemp -d "$build/compiler-check.XXXXXX")
# The complete isolated copy proves EXE-relative Lua paths, including non-ACP
# characters. Keep its files/logs as failure evidence rather than auto-removing.
runtime="$check/compiler space 文 😀"
mkdir -p "$runtime" "$check/cwd"
cp -R "$prefix/bin" "$prefix/lib" "$prefix/share" "$runtime/"
perl scripts/windows_compiler_receipt.pl check "$runtime"
cp spec/fixtures/windows/compiler_launcher_probe.lua "$runtime/bin/titanc.lua"
exe="$runtime/bin/titanc.exe"
for image in "$prefix/bin/titanc.exe" "$prefix/lib/lua/5.5/lfs.dll" "$prefix/lib/lua/5.5/lpeglabel.dll"; do
    llvm-readobj --coff-imports --coff-exports "$image" > "$check/$(basename "$image").pe.txt"
done
unset LUA_INIT LUA_INIT_5_5 LUA_PATH LUA_PATH_5_5 LUA_CPATH LUA_CPATH_5_5
args=(capture '' 'space value' 'quote"value' 'trailing\' '文😀' '&|<>^%!')
(cd "$check/cwd"; PATH='' "$exe" "${args[@]}") > "$check/native.txt"
(cd "$check/cwd"; PATH='' "$runtime/bin/lua.exe" "$(cygpath -m "$runtime/bin/titanc.lua")" "${args[@]}") > "$check/lua.txt"
cmp "$check/native.txt" "$check/lua.txt"
printf '%s\n' 'titan_launcher_init = "preserved"' > "$check/init.lua"
init_path=$(cygpath -m "$check/init.lua")
(cd "$check/cwd"; PATH='' LUA_INIT_5_5="@$init_path" "$exe" init) > "$check/init.txt"
set +e
(cd "$check/cwd"; PATH='' "$exe" exit) > "$check/exit.txt" 2>&1
status=$?
set -e
[[ $status == 37 ]]
set +e
(cd "$check/cwd"; PATH='' "$exe" error) > "$check/error.txt" 2>&1
status=$?
set -e
[[ $status == 1 ]]
grep -F 'native launcher diagnostic' "$check/error.txt"
grep -F 'stack traceback:' "$check/error.txt"
printf '%s\n' "$runtime" > "$build/compiler-check-runtime.txt"
printf 'Native launcher relocation/argv/Lua-init/status/import/dependency gates passed: %s\n' "$check"
