#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../scripts/windows_build_profile.sh"
titan_windows_profile validation

if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_runtime_loader.sh LUA_SDK BUILD_ROOT' >&2
  exit 2
fi
prefix=$(cd "$1" && pwd)
mkdir -p "$2"
build_root=$(cd "$2" && pwd)
check_root=$(mktemp -d "$build_root/runtime-loader.XXXXXX")
runtime="$check_root/runtime ü space"
providers="$runtime/lib/titan/0.6"
archive="$build_root/runtime/libtitan.a"
[[ -f $archive ]] || {
  echo "missing runtime archive: $archive (run make -f Makefile.win runtime-build first)" >&2
  exit 1
}
hostile_cwd="$check_root/cwd"
hostile_path="$check_root/path"
mkdir -p "$runtime/bin" "$providers" "$runtime/lib/lua/5.5" "$hostile_cwd" "$hostile_path"
cp "$prefix/bin/lua55.dll" "$runtime/bin/"

# Parse the configured compiler as argv; never evaluate shell input.
CC=${CC:-clang} perl -MText::ParseWords=shellwords -e \
  'my @a = shellwords($ENV{CC}); die "Invalid CC command\n" unless @a; print "$_\0" for @a' \
  > "$check_root/compiler.argv"
mapfile -d '' -t compiler < "$check_root/compiler.argv"
titan_windows_raw_flags "$check_root" RUNTIME
[[ $("${compiler[@]}" -dumpmachine) == x86_64-w64-windows-gnu ]]
printf '%s\n' '#include <_mingw.h>' \
  '#if !defined(__clang__) || !defined(_WIN64) || !defined(_UCRT)' \
  '#error Expected native Clang x64 with UCRT headers' '#endif' | \
  "${compiler[@]}" -x c -E - > /dev/null

# Generated, runtime and fixture C consume the controlled Lua DLL's internals.
lua_dll_imports=(-DLUA_BUILD_AS_DLL
  '-DLUAI_FUNC=__declspec(dllimport) extern'
  '-DLUAI_DDEC(dec)=__declspec(dllimport) extern dec' '-DLUAI_DDEF=')
common=(-std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" "${lua_dll_imports[@]}" -Wno-unused-function \
  -I titan-runtime -I "$prefix/include" -I "$prefix/src/lua-5.5.1")
lua_import="$prefix/lib/liblua55.a"
runtime_libraries=("$prefix/lib/libbacktrace.a" "$build_root/runtime/libtitan.a" \
  "$lua_import" -static-libgcc)
# The support module is one ordinary Lua native module that exports only its
# opener; providers and executables link the runtime archive instead.
"${compiler[@]}" "${common[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
  -Wl,--disable-auto-import titan-runtime/ltitanlib.c titan-runtime/titan_path.c \
  "$lua_import" -lbcrypt -o "$runtime/lib/lua/5.5/titan.dll"
fixture=spec/fixtures/windows/runtime_loader_provider.c
for variant in provider dependency bad missing null; do
  defines=()
  case $variant in
    dependency) defines=(-DFIXTURE_DEPENDENCY) ;;
    bad) defines=('-DFIXTURE_ABI="999"') ;;
    missing) defines=(-DFIXTURE_OMIT_VALUE) ;;
    null) defines=(-DFIXTURE_ABI=NULL) ;;
  esac
  "${compiler[@]}" "${common[@]}" "${defines[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
    -Wl,--disable-auto-import \
    "$fixture" "${runtime_libraries[@]}" \
    -o "$providers/fixture-$variant.dll"
done
"${compiler[@]}" "${common[@]}" "${ldflags[@]}" -Wl,--disable-auto-import \
  spec/fixtures/windows/runtime_loader_probe.c \
  "${runtime_libraries[@]}" -o "$runtime/bin/runtime-loader-probe.exe"

# The dependency initially exists outside every Windows DLL search directory.
# Fresh processes distinguish missing, process-PATH, and executable-bin lookup.
"${compiler[@]}" "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
  -Xlinker --out-implib -Xlinker "$check_root/dependency.dll.a" \
  spec/fixtures/windows/runtime_loader_dependency.c \
  -o "$check_root/titan-loader-dependency.dll"
"${compiler[@]}" "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
  spec/fixtures/windows/runtime_loader_native.c "$check_root/dependency.dll.a" \
  -o "$providers/fixture-native.dll"

for file in "$providers/"*.dll "$runtime/lib/lua/5.5/"*.dll "$runtime/bin/"*.dll \
    "$runtime/bin/runtime-loader-probe.exe"; do
  report="$check_root/$(basename "$file").imports"
  llvm-readobj --coff-imports "$file" > "$report"
  perl -0777 -e '
    my $support = $ARGV[0] =~ /titan[.]dll[.]imports$/;
    my $text = <>;
    die "Expected x64 COFF image in import report\n"
      unless $text =~ /^Format: COFF-x86-64\r?$/m;
    my @names = $text =~ /^  Name: ([^\r\n]+)\r?$/mg;
    die "Expected a nonempty PE import table\n" unless @names;
    for my $name (@names) {
      $name = lc $name;
      die "Unexpected native runtime dependency: $name\n"
        unless $name eq "kernel32.dll" || ($support && $name eq "bcrypt.dll") ||
               $name eq "lua55.dll" ||
               $name eq "titan-loader-dependency.dll" || $name eq "ucrtbase.dll" ||
               $name =~ /^api-ms-win-crt-[a-z0-9-]+\.dll$/;
    }
  ' "$report"
done

unset TITAN_PATH TITAN_PATH_0_6 LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
(cd "$hostile_cwd"; PATH="$hostile_path" "$runtime/bin/runtime-loader-probe.exe" reject-native)
cp "$check_root/titan-loader-dependency.dll" "$hostile_path/"
(cd "$hostile_cwd"; PATH="$hostile_path" "$runtime/bin/runtime-loader-probe.exe")
rm "$hostile_path/titan-loader-dependency.dll"
cp "$check_root/titan-loader-dependency.dll" "$runtime/bin/"
(cd "$hostile_cwd"; PATH="$hostile_path" "$runtime/bin/runtime-loader-probe.exe")
provider_windows=$(cygpath -w "$providers")
(cd "$hostile_cwd"; TITAN_PATH_0_6="$provider_windows" TITAN_PATH=wrong \
  PATH="$hostile_path" "$runtime/bin/runtime-loader-probe.exe")
(cd "$hostile_cwd"; TITAN_PATH_0_6='' TITAN_PATH="$provider_windows" \
  PATH="$hostile_path" "$runtime/bin/runtime-loader-probe.exe" reject-empty)
echo "Native Windows runtime loader evidence: $check_root"
