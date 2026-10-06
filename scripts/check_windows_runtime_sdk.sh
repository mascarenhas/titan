#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile validation
[[ $# == 2 && ${MSYSTEM:-} == CLANG64 ]]
build=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
work="$build/runtime"
[[ $(cat "$work/.titan-runtime-owner") == titan-windows-runtime-v1 ]]
check=$(mktemp -d "$build/runtime-sdk-check.XXXXXX")
export CC=${CC:-clang}
CC="$CC" perl -MText::ParseWords=shellwords -e \
  'my @a=shellwords($ENV{CC}); die "Invalid compiler command\n" unless @a; print "$_\0" for @a' > "$check/compiler.argv"
mapfile -d '' -t compiler < "$check/compiler.argv"
titan_windows_raw_flags "$check" RUNTIME
mkdir "$check/bin" "$check/unrelated"
cp "$prefix/bin/lua55.dll" "$check/bin/"
"${compiler[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" -Werror \
  -I "$prefix/include" -I "$prefix/src/lua-5.5.1" -I vendor/lpeglabel \
  spec/fixtures/windows/runtime_sdk_probe.c "${ldflags[@]}" \
  -Wl,--whole-archive "$work/libtitan.a" "$work/libtitan-lpeglabel.a" \
  -Wl,--no-whole-archive "$prefix/lib/liblua-5.5.1.dll.a" \
  -o "$check/bin/runtime-sdk-probe.exe"
perl scripts/check_windows_compiler_pe.pl "$check/bin/runtime-sdk-probe.exe"
(cd "$check/unrelated"; PATH='' "$check/bin/runtime-sdk-probe.exe")

# Warm reuse must preserve exact outputs and mtimes, then repair real corruption.
(cd "$work"; stat -c '%n %y' *.o *.a titan.dll configuration output-sha256) > "$check/before.stat"
bash scripts/build_windows_runtime.sh "$build" "$prefix"
(cd "$work"; stat -c '%n %y' *.o *.a titan.dll configuration output-sha256) > "$check/after.stat"
cmp "$check/before.stat" "$check/after.stat"
cp "$work/output-sha256" "$check/expected-sha256"
printf 'corrupt owned bootstrap fixture\n' >> "$work/titan.dll"
bash scripts/build_windows_runtime.sh "$build" "$prefix"
cmp "$check/expected-sha256" "$work/output-sha256"
printf 'unrelated member fixture\n' > "$check/unrelated.o"
llvm-ar q "$work/libtitan.a" "$check/unrelated.o"
bash scripts/build_windows_runtime.sh "$build" "$prefix"
cmp "$check/expected-sha256" "$work/output-sha256"

# A usable canonical support image carrying extra payload must survive staging.
cp -R "$prefix" "$check/prefix"
printf '%s\n' '__declspec(dllexport) int titan_preserve_payload(void) { return 42; }' > "$check/preserve.c"
"${compiler[@]}" "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols -Wl,--no-insert-timestamp \
  "$check/preserve.c" "$work/ltitanlib.o" "$prefix/lib/liblua-5.5.1.dll.a" -lbcrypt \
  -o "$check/prefix/lib/titan/0.6/titan.dll"
cp "$check/prefix/lib/titan/0.6/titan.dll" "$check/expected-provider.dll"
bash scripts/install_windows_runtime.sh "$build" "$check/prefix"
cmp "$check/expected-provider.dll" "$check/prefix/lib/titan/0.6/titan.dll"
echo "Windows runtime SDK validation passed: $check"
