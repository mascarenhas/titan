#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile production
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): build_windows_runtime.sh BUILD_ROOT LUA_SDK' >&2
  exit 2
fi
mkdir -p "$1/runtime"
work=$(cd "$1/runtime" && pwd)
prefix=$(cd "$2" && pwd)
arguments=$(mktemp -d "$work/.argv.XXXXXX")
pending_output=
trap '[[ -z $pending_output ]] || rm -f "$pending_output"; rm -rf "$arguments"' EXIT
: "${CC:=clang}" "${AR:=llvm-ar}" "${RANLIB:=llvm-ranlib}" "${RC:=llvm-rc}"
export CC AR RANLIB RC
for name in CC AR RANLIB RC; do
  perl -MText::ParseWords=shellwords -e '
    my @a=shellwords($ENV{$ARGV[0]}); die "Invalid tool command\n" unless @a;
    print "$_\0" for @a' "$name" > "$arguments/$name.argv"
done
mapfile -d '' -t compiler < "$arguments/CC.argv"
mapfile -d '' -t archiver < "$arguments/AR.argv"
mapfile -d '' -t indexer < "$arguments/RANLIB.argv"
mapfile -d '' -t resource_compiler < "$arguments/RC.argv"
titan_windows_raw_flags "$arguments" RUNTIME
runtime_cflags=("${cflags[@]}")
runtime_ldflags=("${ldflags[@]}")
titan_windows_host_flags "$arguments" RUNTIME LPEGLABEL_BUILD_CFLAGS
parser_cflags=("${cflags[@]}")
headers=(titan-runtime/*.h titan-runtime/titan/*.h "$prefix/src/lua-5.5.1/"*.h
  "$prefix/include/backtrace.h" "$prefix/include/backtrace-supported.h")
# Ordinary source/header timestamps own rebuilds. Clean this directory when
# changing the compiler, SDK, profile or flags.
needs_build() {
  local output=$1 input
  shift
  [[ -f $output ]] || return 0
  for input in "$@"; do [[ ! $input -nt $output ]] || return 0; done
  return 1
}
# Failed compiler/archive commands must not leave apparently current outputs.
write_output() {
  pending_output=$1
  shift
  "$@"
  pending_output=
}
archive_objects() {
  local output=$1
  shift
  pending_output=$output
  rm -f "$output"
  "${archiver[@]}" rcs "$output" "$@"
  "${indexer[@]}" "$output"
  pending_output=
}
common=(-std=c99 -Wall -Wextra "${cppflags[@]}" -I titan-runtime -I "$prefix/src/lua-5.5.1" -I "$prefix/include")
# The controlled Lua DLL exposes its public and internal surface. Name those
# imports explicitly; MinGW auto-import alone does not cover every data symbol.
lua_dll_imports=(-DLUA_BUILD_AS_DLL
  '-DLUAI_FUNC=__declspec(dllimport) extern'
  '-DLUAI_DDEC(dec)=__declspec(dllimport) extern dec' '-DLUAI_DDEF=')
for name in titan minicoro titan_path ltitanlib; do
  if needs_build "$work/$name.o" "titan-runtime/$name.c" "${headers[@]}"; then
    write_output "$work/$name.o" "${compiler[@]}" "${common[@]}" "${lua_dll_imports[@]}" "${runtime_cflags[@]}" \
      -c "titan-runtime/$name.c" -o "$work/$name.o"
  fi
done
if needs_build "$work/libtitan.a" "$work/titan.o" "$work/minicoro.o" \
    "$work/titan_path.o" "$work/ltitanlib.o"; then
  archive_objects "$work/libtitan.a" "$work/titan.o" "$work/minicoro.o" \
    "$work/titan_path.o" "$work/ltitanlib.o"
fi
# lpeglabel is deliberately compiled without the Lua consumer definitions:
# its own headers reuse LUAI_FUNC for private cross-unit symbols, so a
# dllimport definition would warn, and it reaches Lua only through the public
# API import thunks.
peg_objects=()
for name in lplcap lplcode lplprint lpltree lplvm; do
  if needs_build "$work/$name.o" "vendor/lpeglabel/$name.c" vendor/lpeglabel/*.h "${headers[@]}"; then
    write_output "$work/$name.o" "${compiler[@]}" "${common[@]}" "${parser_cflags[@]}" -I vendor/lpeglabel \
      -c "vendor/lpeglabel/$name.c" -o "$work/$name.o"
  fi
  peg_objects+=("$work/$name.o")
done
if needs_build "$work/libtitan-lpeglabel.a" "${peg_objects[@]}"; then
  archive_objects "$work/libtitan-lpeglabel.a" "${peg_objects[@]}"
fi
# The support module exports only luaopen_titan: it is the path/searcher
# helpers plus the Lua import library, not the whole runtime archive.
if needs_build "$work/titan.dll" "$work/ltitanlib.o" "$work/titan_path.o" "$prefix/lib/liblua55.a"; then
  write_output "$work/titan.dll" "${compiler[@]}" -shared "${runtime_ldflags[@]}" \
    -Wl,--exclude-all-symbols -Wl,--no-insert-timestamp \
    -o "$work/titan.dll" "$work/ltitanlib.o" "$work/titan_path.o" \
    "$prefix/lib/liblua55.a"
fi
# The native compiler frontend titanc.exe: the installed configured lua.c with
# the stock Lua consumer definition and its main renamed to titan_lua_main,
# the wide-argv entry that runs the installed titanc script, and the UTF-8,
# long-path-aware manifest. Like lua.exe it imports only lua55.dll and system
# DLLs. Compiler host code keeps the host flags.
titanc_lua="$prefix/src/lua-5.5.1/lua.c"
if needs_build "$work/titanc-lua.o" "$titanc_lua" "${headers[@]}"; then
  write_output "$work/titanc-lua.o" "${compiler[@]}" "${common[@]}" -DLUA_BUILD_AS_DLL \
    -Dmain=titan_lua_main "${parser_cflags[@]}" -c "$titanc_lua" -o "$work/titanc-lua.o"
fi
if needs_build "$work/titanc_windows.o" titan-runtime/titanc_windows.c "${headers[@]}"; then
  write_output "$work/titanc_windows.o" "${compiler[@]}" "${common[@]}" -DLUA_BUILD_AS_DLL \
    "${parser_cflags[@]}" -c titan-runtime/titanc_windows.c -o "$work/titanc_windows.o"
fi
# llvm-rc resolves the manifest named in the .rc file from that file's directory.
if needs_build "$work/titanc.res" vendor/windows-compiler/titanc.rc \
    vendor/windows-compiler/titanc.manifest; then
  write_output "$work/titanc.res" "${resource_compiler[@]}" -FO "$work/titanc.res" \
    vendor/windows-compiler/titanc.rc
fi
if needs_build "$work/titanc.exe" "$work/titanc_windows.o" "$work/titanc-lua.o" \
    "$work/titanc.res" "$prefix/lib/liblua55.a"; then
  write_output "$work/titanc.exe" "${compiler[@]}" -municode "${runtime_ldflags[@]}" \
    -Wl,--no-insert-timestamp -o "$work/titanc.exe" "$work/titanc_windows.o" \
    "$work/titanc-lua.o" "$work/titanc.res" "$prefix/lib/liblua55.a"
fi
