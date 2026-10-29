#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../scripts/windows_build_profile.sh"
titan_windows_profile validation
if [[ $# != 3 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_launcher.sh LUA_SDK BUILD_ROOT GENERATED_FIXTURE' >&2
  exit 2
fi
prefix=$(cd "$1" && pwd)
mkdir -p "$2"
build_root=$(cd "$2" && pwd)
generated=$(cd "$3" && pwd)
check_root=$(mktemp -d "$build_root/launcher.XXXXXX")
runtime="$check_root/launcher ü space"
mkdir -p "$runtime/bin" "$runtime/lib/titan/0.6/fixture" "$check_root/cwd"
cp "$prefix/bin/lua55.dll" "$runtime/bin/"
mapfile -t plan < "$generated/plan.txt"
mapfile -t system_libraries < "$generated/system-libraries.txt"
[[ ${#plan[@]} == 3 ]]
[[ ${plan[0]} == bin/fixture.launcher.exe && ${plan[1]} == bin/custom.exe ]]
[[ ${plan[2]} == lib/titan/0.6/fixture/launcher.dll ]]
CC=${CC:-clang} perl -MText::ParseWords=shellwords -e \
  'my @a = shellwords($ENV{CC}); die "Invalid CC command\n" unless @a; print "$_\0" for @a' \
  > "$check_root/compiler.argv"
mapfile -d '' -t compiler < "$check_root/compiler.argv"
titan_windows_raw_flags "$check_root" RUNTIME
[[ $("${compiler[@]}" -dumpmachine) == x86_64-w64-windows-gnu ]]
# Generated, runtime and fixture C consume the controlled Lua DLL's internals.
lua_dll_imports=(-DLUA_BUILD_AS_DLL
  '-DLUAI_FUNC=__declspec(dllimport) extern'
  '-DLUAI_DDEC(dec)=__declspec(dllimport) extern dec' '-DLUAI_DDEF=')
common=(-std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" "${lua_dll_imports[@]}" -Wno-unused-function \
  -I titan-runtime -I "$prefix/include" -I "$prefix/src/lua-5.5.1")
archive="$build_root/runtime/libtitan.a"
[[ -f $archive ]] || {
  echo "missing runtime archive: $archive (run make -f Makefile.win runtime-build first)" >&2
  exit 1
}
runtime_libraries=("$prefix/lib/libbacktrace.a" "$archive" "$prefix/lib/liblua55.a")
# Every link forbids auto-import: a consumer compiled without the explicit
# Lua import definitions then fails to resolve its internal references.
link_guard=(-Wl,--disable-auto-import)
"${compiler[@]}" "${common[@]}" -shared "${ldflags[@]}" "${link_guard[@]}" -Wl,--exclude-all-symbols \
  -DFIXTURE_DEPENDENCY spec/fixtures/windows/runtime_loader_provider.c \
  "${runtime_libraries[@]}" -static-libgcc \
  -o "$runtime/lib/titan/0.6/fixture-dependency.dll"
"${compiler[@]}" "${common[@]}" -shared "${ldflags[@]}" "${link_guard[@]}" -Wl,--exclude-all-symbols \
  spec/fixtures/windows/runtime_launcher_provider.c "$generated/launcher.def" \
  "${runtime_libraries[@]}" "${system_libraries[@]}" -o "$runtime/${plan[2]}"
llvm-readobj --coff-exports "$runtime/${plan[2]}" > "$check_root/provider.exports"
perl -0777 -e '
  my ($def, $report) = @ARGV;
  open my $f,"<",$def or die $!; local $/; my $expected = <$f>;
  open my $r,"<",$report or die $!; my $actual = <$r>;
  my @expected = sort $expected =~ /^\s+(\w+)\s*$/mg;
  my @actual = sort $actual =~ /^  Name: (\w+)\r?$/mg;
  die "Producer protocol export inventory differs\n"
    unless @expected == 7 && join("\n",@expected) eq join("\n",@actual);
' "$generated/launcher.def" "$check_root/provider.exports"
# Compile a resource under the Unicode path as well as the executable itself.
cp "$generated/launcher.manifest" "$generated/launcher ü.manifest"
llvm-rc -FO "$check_root/launcher.res" "$generated/launcher.rc"
for variant in launcher direct; do
  "${compiler[@]}" "${common[@]}" -c "$generated/$variant.c" -o "$check_root/$variant.o"
done
for name in "${plan[0]}" "${plan[1]}"; do
  "${compiler[@]}" "${ldflags[@]}" "${link_guard[@]}" "$check_root/launcher.o" \
    "$check_root/launcher.res" "${runtime_libraries[@]}" "${system_libraries[@]}" -o "$runtime/$name"
done
"${compiler[@]}" "${ldflags[@]}" "${link_guard[@]}" "$check_root/direct.o" \
  "$check_root/launcher.res" "${runtime_libraries[@]}" "${system_libraries[@]}" -o "$runtime/bin/direct.exe"
cp "$runtime/${plan[0]}" "$runtime/bin/renamed.exe"
cmp "$runtime/${plan[0]}" "$runtime/bin/renamed.exe"
for file in "$runtime/bin/"*.exe "$runtime/lib/titan/0.6/fixture/launcher.dll"; do
  report="$check_root/$(basename "$file").imports"
  llvm-readobj --coff-imports "$file" > "$report"
  perl -0777 -e '
    local $/; my $text=<>; my @names=$text =~ /^  Name: ([^\r\n]+)\r?$/mg;
    die "Empty import table\n" unless @names;
    for my $name (@names) {
      $name=lc $name;
      die "Unexpected launcher dependency: $name\n" unless $name eq "kernel32.dll" ||
        $name eq "lua55.dll" || $name eq "ucrtbase.dll" || $name eq "bcrypt.dll" ||
        $name =~ /^api-ms-win-crt-[a-z0-9-]+\.dll$/;
    }
  ' "$report"
done
unset TITAN_PATH TITAN_PATH_0_6 LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
run_expected() {
  local name=$1 expected=$2 status=0
  (cd "$check_root/cwd"; PATH='' "$runtime/$name" one ü) || status=$?
  [[ $status == "$expected" ]] || { echo "Unexpected launcher exit: $status, expected $expected" >&2; exit 1; }
}
run_expected "${plan[0]}" 38
run_expected "${plan[1]}" 38
run_expected bin/renamed.exe 38
run_expected bin/direct.exe 37
# A fresh incompatible provider must fail in the native value query, before its
# Lua opener is called. The process has exited before replacing this image.
"${compiler[@]}" "${common[@]}" -shared "${ldflags[@]}" "${link_guard[@]}" -Wl,--exclude-all-symbols \
  '-DFIXTURE_LAUNCHER_ABI="999"' spec/fixtures/windows/runtime_launcher_provider.c \
  "$generated/launcher.def" "${runtime_libraries[@]}" "${system_libraries[@]}" -o "$runtime/${plan[2]}"
status=0
(cd "$check_root/cwd"; PATH='' "$runtime/bin/renamed.exe" one ü) > "$check_root/incompatible.log" 2>&1 || status=$?
[[ $status == 1 ]]
abi=$(perl -ne 'print "$1\n" if /^#define\s+TITAN_ABI_VERSION\s+"([^"]+)"/' titan-runtime/titan.h)
[[ -n $abi ]]
grep -F "ABI mismatch: expected $abi but found 999" "$check_root/incompatible.log" >/dev/null
echo "Native Windows launcher evidence: $check_root"
