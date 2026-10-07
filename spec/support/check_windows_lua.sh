#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../scripts/windows_build_profile.sh"
titan_windows_profile validation

if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_lua.sh PREFIX BUILD_ROOT' >&2
  exit 2
fi
prefix=$(cd "$1" && pwd)
build_root=$2
check_root="$build_root/lua-check"
mkdir -p "$check_root"

# The reviewed default-source export inventory is independently derived from
# the pinned public/internal declarations, including all four exported arrays.
llvm-readobj --coff-exports "$prefix/bin/lua55.dll" > "$check_root/exports.txt"
perl -ne 'print "$1\n" if /^  Name: ([^\r\n]+)\r?$/' "$check_root/exports.txt" | LC_ALL=C sort > "$check_root/export-names.txt"
diff -u spec/fixtures/windows/lua-5.5.1-exports.txt "$check_root/export-names.txt"
if grep -F 'ForwardedTo:' "$check_root/exports.txt"; then
  echo 'Controlled Lua must own its exports, not forward them to another DLL' >&2
  exit 1
fi

inspect_imports() {
  local file=$1
  local report=$2
  llvm-readobj --coff-imports "$file" > "$report"
  perl -0777 -e '
    my $text = <>;
    die "Expected x64 COFF image in import report\n"
      unless $text =~ /^Format: COFF-x86-64\r?$/m;
    # llvm-readobj includes both Import and DelayImport DLL names here.
    my @names = $text =~ /^  Name: ([^\r\n]+)\r?$/mg;
    die "Expected a nonempty PE import table\n" unless @names;
    for my $name (@names) {
      $name = lc $name;
      die "Unexpected Lua runtime dependency: $name\n"
        unless $name eq "kernel32.dll" || $name eq "lua55.dll" ||
               $name eq "ucrtbase.dll" || $name =~ /^api-ms-win-crt-[a-z0-9-]+\.dll$/;
    }
  ' "$report"
}
inspect_imports "$prefix/bin/lua55.dll" "$check_root/lua-dll-imports.txt"
inspect_imports "$prefix/bin/lua.exe" "$check_root/lua-exe-imports.txt"
grep -F 'Name: lua55.dll' "$check_root/lua-exe-imports.txt" >/dev/null

# Preserve exact installed SDK bytes, including internal and public config.
for file in "$build_root/lua-5.5.1/src/"*.c "$build_root/lua-5.5.1/src/"*.h; do
  cmp "$file" "$prefix/src/lua-5.5.1/${file##*/}"
done
for file in lua.h luaconf.h lualib.h lauxlib.h; do
  cmp "$prefix/src/lua-5.5.1/$file" "$prefix/include/$file"
done
cmp "$build_root/lua-5.5.1/src/lua.hpp" "$prefix/include/lua.hpp"

# Parse quoted compiler arguments without evaluating shell syntax.
CC=${CC:-clang} perl -MText::ParseWords=shellwords -e 'my @a = shellwords($ENV{CC}); die "Invalid CC command\n" unless @a; print "$_\0" for @a' > "$check_root/compiler.argv"
mapfile -d '' -t compiler < "$check_root/compiler.argv"
titan_windows_raw_flags "$check_root" LUA
"${compiler[@]}" -std=c99 -Wall -Wextra "${cppflags[@]}" "${cflags[@]}" -Werror \
  -I "$prefix/src/lua-5.5.1" -c spec/fixtures/windows/lua_sdk_probe.c \
  -o "$check_root/consumer.o"
llvm-readobj --symbols "$check_root/consumer.o" > "$check_root/consumer-symbols.txt"
for name in lua_ident luai_ctype_ luaP_opmodes luaT_typenames_; do
  grep -F "Name: __imp_$name" "$check_root/consumer-symbols.txt" >/dev/null
done
"${compiler[@]}" "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
  -o "$check_root/lua-sdk-probe.dll" "$check_root/consumer.o" \
  "$prefix/lib/liblua55.a"
inspect_imports "$check_root/lua-sdk-probe.dll" "$check_root/consumer-imports.txt"
grep -F 'Name: lua55.dll' "$check_root/consumer-imports.txt" >/dev/null
llvm-readobj --coff-exports "$check_root/lua-sdk-probe.dll" | \
  perl -ne 'print "$1\n" if /^  Name: ([^\r\n]+)\r?$/' > "$check_root/consumer-exports.txt"
printf '%s\n' luaopen_titan_lua_sdk_probe > "$check_root/expected-consumer-exports.txt"
diff -u "$check_root/expected-consumer-exports.txt" "$check_root/consumer-exports.txt"

# The module shares the interpreter's Lua instance and imports internal data
# through its IAT. No package.path override or DLL PATH entry is necessary.
"$prefix/bin/lua.exe" -E spec/fixtures/windows/lua_sdk_probe.lua "$check_root/lua-sdk-probe.dll"


# Relocate the runtime subset into a fresh Unicode/space path, away from the
# installed SDK and current directory. No Lua-path overrides or CLANG64 PATH.
check_root=$(cd "$check_root" && pwd)
probe_root=$(mktemp -d "$check_root/loader.XXXXXX")
runtime="$probe_root/runtime ü space"
provider="$probe_root/providers é"
hostile_cwd="$probe_root/cwd"
hostile_path="$probe_root/path"
mkdir -p "$runtime/bin" "$runtime/lib/lua/5.5" "$runtime/share/lua/5.5" \
  "$provider" "$hostile_cwd" "$hostile_path"
cp "$prefix/bin/lua.exe" "$prefix/bin/lua55.dll" "$runtime/bin/"
cp "$check_root/lua-sdk-probe.dll" "$runtime/lib/lua/5.5/titan_lua_sdk_probe.dll"
printf '%s\n' 'return "relocated UTF-8 Lua source"' > "$runtime/share/lua/5.5/relocation_é.lua"
cp spec/fixtures/windows/lua_loader_probe.lua "$probe_root/probe.lua"
"${compiler[@]}" "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols \
  -Xlinker --out-implib -Xlinker "$probe_root/loader-dependency.dll.a" \
  -o "$probe_root/titan_lua_loader_dependency.dll" spec/fixtures/windows/lua_loader_dependency.c
"${compiler[@]}" "${cppflags[@]}" "${cflags[@]}" -shared "${ldflags[@]}" -Wl,--exclude-all-symbols -I "$prefix/include" \
  -o "$provider/titan_loader_canary.dll" spec/fixtures/windows/lua_loader_canary.c \
  "$probe_root/loader-dependency.dll.a" "$prefix/lib/liblua55.a"
# Each invocation is fresh: an earlier mapping cannot satisfy a later lookup.
# The dependency is initially absent from every Windows DLL search directory.
(cd "$hostile_cwd"; PATH="$hostile_path" "$runtime/bin/lua.exe" -E \
  "$probe_root/probe.lua" "$provider/titan_loader_canary.dll" reject)
# A native dependency on process PATH follows the ordinary Windows search.
cp "$probe_root/titan_lua_loader_dependency.dll" "$hostile_path/"
(cd "$hostile_cwd"; PATH="$hostile_path" "$runtime/bin/lua.exe" -E \
  "$probe_root/probe.lua" "$provider/titan_loader_canary.dll" accept)
rm "$hostile_path/titan_lua_loader_dependency.dll"
cp "$probe_root/titan_lua_loader_dependency.dll" "$runtime/bin/"
(cd "$hostile_cwd"; PATH="$hostile_path" "$runtime/bin/lua.exe" -E \
  "$probe_root/probe.lua" "$provider/titan_loader_canary.dll" accept)
# Relative requests use the same module and ordinary native dependency rules.
(cd "$provider"; PATH="$hostile_path" "$runtime/bin/lua.exe" -E \
  "$probe_root/probe.lua" './titan_loader_canary.dll' accept)

# This marker is written only after all native shell checks pass. The separate
# PowerShell gate reads the exact latest successful fixture directory.
cygpath -w "$probe_root" > "$check_root/native-probe-path.txt"
