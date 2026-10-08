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
: "${CC:=clang}" "${AR:=llvm-ar}" "${RANLIB:=llvm-ranlib}"
export CC AR RANLIB
for name in CC AR RANLIB; do
  perl -MText::ParseWords=shellwords -e '
    my @a=shellwords($ENV{$ARGV[0]}); die "Invalid tool command\n" unless @a;
    print "$_\0" for @a' "$name" > "$arguments/$name.argv"
done
mapfile -d '' -t compiler < "$arguments/CC.argv"
mapfile -d '' -t archiver < "$arguments/AR.argv"
mapfile -d '' -t indexer < "$arguments/RANLIB.argv"
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
for name in titan minicoro ltitanlib; do
  if needs_build "$work/$name.o" "titan-runtime/$name.c" "${headers[@]}"; then
    write_output "$work/$name.o" "${compiler[@]}" "${common[@]}" "${runtime_cflags[@]}" \
      -c "titan-runtime/$name.c" -o "$work/$name.o"
  fi
done
if needs_build "$work/libtitan.a" "$work/titan.o" "$work/minicoro.o"; then
  archive_objects "$work/libtitan.a" "$work/titan.o" "$work/minicoro.o"
fi
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
if needs_build "$work/titan.dll" "$work/ltitanlib.o" "$prefix/lib/liblua55.a"; then
  write_output "$work/titan.dll" "${compiler[@]}" -shared "${runtime_ldflags[@]}" \
    -Wl,--exclude-all-symbols -Wl,--no-insert-timestamp \
    -o "$work/titan.dll" "$work/ltitanlib.o" "$prefix/lib/liblua55.a"
fi
