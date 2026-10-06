#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile production
[[ $# == 3 && ${MSYSTEM:-} == CLANG64 ]]
build=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
mode=$3
export CC=${CC:-clang} RC=${RC:-llvm-rc}
# Parse configured command words without shell evaluation.
mapfile -d '' -t cc < <(perl -MText::ParseWords=shellwords -e 'print "$_\0" for shellwords($ENV{CC})')
mapfile -d '' -t rc < <(perl -MText::ParseWords=shellwords -e 'print "$_\0" for shellwords($ENV{RC})')
[[ ${#cc[@]} -gt 0 && ${#rc[@]} -gt 0 ]]
[[ -f "$prefix/etc/titan/lua-5.5.1-windows.config" ]]
[[ -f "$prefix/bin/lua55.dll" && -f "$prefix/lib/liblua-5.5.1.dll.a" ]]
mkdir -p "$build/compiler-objects" "$prefix/lib/lua/5.5" "$prefix/share/lua/5.5"
objects=$build/compiler-objects
source=$build/compiler-src
titan_windows_raw_flags "$objects" COMPILER
if [[ $mode == deps ]]; then
    "${cc[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
        -Wl,--no-insert-timestamp -I "$prefix/include" \
        "$source/luafilesystem-1_9_0/src/lfs.c" "$prefix/lib/liblua-5.5.1.dll.a" \
        -o "$objects/lfs.dll"
    lpeg_sources=()
    for file in lplcap lplcode lplprint lpltree lplvm; do
        lpeg_sources+=("$source/lpeglabel-1.6.2-1/$file.c")
    done
    "${cc[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
        -Wl,--no-insert-timestamp -I "$prefix/include" "${lpeg_sources[@]}" \
        vendor/windows-compiler/lpeglabel.def "$prefix/lib/liblua-5.5.1.dll.a" \
        -o "$objects/lpeglabel.dll"
    perl scripts/check_windows_compiler_pe.pl "$objects/lfs.dll" luaopen_lfs
    perl scripts/check_windows_compiler_pe.pl "$objects/lpeglabel.dll" luaopen_lpeglabel
    install -m 0755 "$objects/lfs.dll" "$objects/lpeglabel.dll" "$prefix/lib/lua/5.5/"
    install -m 0644 "$source/lpeglabel-1.6.2-1/relabel.lua" \
        "$source/argparse-0.7.2/src/argparse.lua" "$source/inspect.lua-3.1.3/inspect.lua" \
        "$prefix/share/lua/5.5/"
    notices=$prefix/share/titan/0.6/licenses
    mkdir -p "$notices"
    install -m 0644 "$source/lpeglabel-1.6.2-1/LICENSE" "$notices/lpeglabel.txt"
    install -m 0644 "$source/argparse-0.7.2/LICENSE" "$notices/argparse.txt"
    install -m 0644 "$source/inspect.lua-3.1.3/MIT-LICENSE.txt" "$notices/inspect.txt"
    install -m 0644 "$source/luafilesystem-1_9_0/LICENSE" "$notices/luafilesystem.txt"
    perl scripts/windows_compiler_receipt.pl write "$prefix" "$build"
elif [[ $mode == compiler ]]; then
    perl scripts/windows_compiler_receipt.pl check "$prefix"
    "${cc[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" -Dmain=titan_lua_main \
        -c "$prefix/src/lua-5.5.1/lua.c" -o "$objects/lua-front-end.o"
    "${cc[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" -Werror \
        -c titan-runtime/titanc_windows.c -o "$objects/titanc-windows.o"
    "${rc[@]}" -I vendor/windows-compiler -FO "$objects/titanc.res" vendor/windows-compiler/titanc.rc
    "${cc[@]}" "${ldflags[@]}" -municode -Wl,--no-insert-timestamp -o "$objects/titanc.exe" \
        "$objects/titanc-windows.o" "$objects/lua-front-end.o" "$objects/titanc.res" \
        "$prefix/lib/liblua-5.5.1.dll.a"
    perl scripts/check_windows_compiler_pe.pl "$objects/titanc.exe"
    install -m 0755 "$objects/titanc.exe" "$prefix/bin/"
    install -m 0644 titanc "$prefix/bin/titanc.lua"
    perl scripts/stage_windows_compiler.pl titan-0.6.0-1.rockspec "$prefix/share/lua/5.5"
else
    echo 'Expected deps or compiler phase' >&2
    exit 1
fi
