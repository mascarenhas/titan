#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../scripts/windows_build_profile.sh"
titan_windows_profile validation
[[ $# == 2 && ${MSYSTEM:-} == CLANG64 ]]
build=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
work="$build/runtime"
check=$(mktemp -d "$build/runtime-sdk-check.XXXXXX")
trap 'rm -rf "$check"' EXIT
export CC=${CC:-clang}
CC="$CC" perl -MText::ParseWords=shellwords -e \
  'my @a=shellwords($ENV{CC}); die "Invalid compiler command\n" unless @a; print "$_\0" for @a' > "$check/compiler.argv"
mapfile -d '' -t compiler < "$check/compiler.argv"
titan_windows_raw_flags "$check" RUNTIME
# Generated, runtime and fixture C consume the controlled Lua DLL's internals.
lua_dll_imports=(-DLUA_BUILD_AS_DLL
  '-DLUAI_FUNC=__declspec(dllimport) extern'
  '-DLUAI_DDEC(dec)=__declspec(dllimport) extern dec' '-DLUAI_DDEF=')
mkdir "$check/bin" "$check/unrelated"
cp "$prefix/bin/lua55.dll" "$check/bin/"
"${compiler[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" "${lua_dll_imports[@]}" -Werror \
  -I "$prefix/include" -I "$prefix/src/lua-5.5.1" -I vendor/lpeglabel \
  spec/fixtures/windows/runtime_sdk_probe.c "${ldflags[@]}" \
  -Wl,--whole-archive "$work/libtitan.a" "$work/libtitan-lpeglabel.a" \
  -Wl,--no-whole-archive "$prefix/lib/libbacktrace.a" \
  "$prefix/lib/liblua55.a" -static-libgcc \
  -o "$check/bin/runtime-sdk-probe.exe"
# The support opener is a real archive member, so static consumers (the
# language server) can link it without the native module.
llvm-nm --defined-only "$work/libtitan.a" > "$check/archive.symbols"
grep -E '(^|[^[:alnum:]_])T luaopen_titan$' "$check/archive.symbols" >/dev/null
perl spec/support/check_windows_compiler_pe.pl --allow-extra-exports \
  "$check/bin/runtime-sdk-probe.exe" luaopen_titan
(cd "$check/unrelated"; PATH='' "$check/bin/runtime-sdk-probe.exe")

# The support module is one ordinary Lua native module: its opener is its only
# export, and the runtime archive carries its objects for static consumers.
llvm-readobj --coff-exports "$work/titan.dll" > "$check/support.exports"
printf '%s\n' luaopen_titan > "$check/expected-support-exports.txt"
perl -ne 'print "$1\n" if /^  Name: ([^\r\n]+)\r?$/' "$check/support.exports" \
  | LC_ALL=C sort > "$check/support-export-names.txt"
diff -u "$check/expected-support-exports.txt" "$check/support-export-names.txt"
llvm-ar t "$work/libtitan.a" > "$check/archive.members"
printf '%s\n' titan.o minicoro.o titan_path.o ltitanlib.o | diff -u - "$check/archive.members"

# An ordinary unchanged build leaves the private native outputs untouched.
(cd "$work"; stat -c '%n %y' *.o *.a titan.dll) > "$check/before.stat"
bash scripts/build_windows_runtime.sh "$build" "$prefix"
(cd "$work"; stat -c '%n %y' *.o *.a titan.dll) > "$check/after.stat"
cmp "$check/before.stat" "$check/after.stat"
# The SDK publication installs the archive and headers only. The support module
# belongs to the compiler install, and the standard provider is never seeded
# from the runtime build.
cp -Rp "$prefix" "$check/prefix"
rm -f "$check/prefix/lib/titan/0.6/titan.dll"
make -f Makefile.win install-titan-sdk WINDOWS_BUILD_ROOT="$build" PREFIX="$check/prefix"
cmp "$work/libtitan.a" "$check/prefix/lib/titan/0.6/libtitan.a"
test ! -e "$check/prefix/lib/titan/0.6/titan.dll"
test ! -e "$check/prefix/lib/lua/5.5/titan.dll"
echo "Windows runtime SDK validation passed: $check"
