#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && ${MSYSTEM:-} == CLANG64 ]]
prefix=$(cd "$1" && pwd)
build=$(cd "$2" && pwd)
check=$(mktemp -d "$build/compiler-check.XXXXXX")
runtime="$check/compiler space 文 😀"
mkdir -p "$runtime" "$check/cwd"
# A complete relocated SDK: the compiler derives its root from titanc.exe.
cp -R "$prefix/bin" "$prefix/lib" "$prefix/share" "$prefix/include" "$prefix/src" \
  "$prefix/etc" "$runtime/"
for module in lfs lpeglabel luv; do
  perl spec/support/check_windows_compiler_pe.pl --allow-extra-exports "$runtime/lib/lua/5.5/$module.dll" "luaopen_$module"
done
# The support module is one ordinary native module with a single export.
perl spec/support/check_windows_compiler_pe.pl "$runtime/lib/lua/5.5/titan.dll" luaopen_titan
# LuaRocks deploys the native compiler program itself: no batch or script
# launcher. The unchanged titanc script is the rock's Lua file that it runs.
# MSYS resolves an extensionless `titanc` to `titanc.exe` in existence tests,
# so compare the directory's exact entries instead of stat-ing those names.
launchers=$(find "$prefix/bin" -maxdepth 1 \
  \( -name titanc -o -name titanc.bat -o -name titanc.lua \) -print)
[[ -z $launchers ]] || { echo "unexpected installed launcher: $launchers" >&2; exit 1; }
[[ -f $prefix/bin/titanc.exe ]]
[[ -f $prefix/share/lua/5.5/titan-compiler/titanc.lua ]]
cmp titanc "$prefix/share/lua/5.5/titan-compiler/titanc.lua"
# titanc.exe imports only the controlled Lua DLL and Windows/UCRT and exports
# nothing. Its RT_MANIFEST (type 24) resource is the vendored UTF-8,
# long-path-aware manifest; the Unicode SDK path below also needs it at run time.
perl spec/support/check_windows_compiler_pe.pl "$runtime/bin/titanc.exe"
llvm-readobj --coff-resources "$runtime/bin/titanc.exe" > "$check/titanc-resources.txt"
grep -F '(ID 24)' "$check/titanc-resources.txt" >/dev/null
perl -e '
  my ($manifest_path, $image_path) = @ARGV;
  local $/;
  open my $manifest_file, "<:raw", $manifest_path or die "$manifest_path: $!\n";
  my $manifest = <$manifest_file>;
  open my $image_file, "<:raw", $image_path or die "$image_path: $!\n";
  my $image = <$image_file>;
  die "the manifest must select the UTF-8 code page\n"
    unless $manifest =~ m{<activeCodePage[^>]*>UTF-8</activeCodePage>};
  die "the manifest must be long-path aware\n"
    unless $manifest =~ m{<longPathAware[^>]*>true</longPathAware>};
  die "titanc.exe does not embed the vendored manifest\n"
    unless index($image, $manifest) >= 0;
' vendor/windows-compiler/titanc.manifest "$runtime/bin/titanc.exe"
unset LUA_INIT LUA_INIT_5_5 LUA_PATH LUA_PATH_5_5 LUA_CPATH LUA_CPATH_5_5
unset TITAN_ROOT TITANC TITAN_PATH_0_6 TITAN_PATH TITAN_TARGET
export MSYS2_ARG_CONV_EXCL='*'
(cd "$check/cwd"; "$runtime/bin/lua.exe" -E -e '
  for _, name in ipairs {"argparse", "inspect", "lfs", "lpeglabel", "luv", "relabel", "titan-compiler.driver"} do
    assert(require(name), name)
  end
  print("LuaRocks-installed compiler and dependencies load from the relocated Lua SDK.")
')
(cd "$check/cwd"; "$runtime/bin/titanc.exe" --help) > "$check/help.txt"
grep -F 'Titan compiler' "$check/help.txt"

# Windows paths compare without regard to case or separator spelling.
same_path() {
  local left=${1%$'\r'} right=${2%$'\r'}
  left=${left//\//\\} right=${right//\//\\}
  [[ ${left,,} == "${right,,}" ]]
}
# Both the support module's answer and the full compiler name the relocated
# SDK: the parent of titanc.exe's directory.
expected_root=$(cygpath -w "$runtime")
for form in --print-root '--print-root -v'; do
  # shellcheck disable=SC2086 # the form is two fixed words
  printed=$(cd "$check/cwd"; "$runtime/bin/titanc.exe" $form)
  same_path "$printed" "$expected_root" || {
    echo "titanc.exe $form printed '$printed', expected '$expected_root'" >&2
    exit 1
  }
done

# The relocated titanc.exe builds a provider (its module workers run the
# lua.exe beside it) that is reachable only through the SDK fallback.
mkdir -p "$check/src"
printf '%s\n' 'function answer(): integer' '  return 42' 'end' > "$check/src/fallback_probe.titan"
(cd "$check/cwd"; "$runtime/bin/titanc.exe" -j 2 --tree "$(cygpath -m "$check/src")" \
  --output "$(cygpath -m "$check/out")" fallback_probe)
cp "$check/out/fallback_probe.dll" "$runtime/lib/titan/0.6/fallback_probe.dll"

# A plain Lua host whose executable-relative Titan roots hold no provider,
# with TITAN_ROOT, TITANC, TITAN_PATH_0_6 and TITAN_PATH unset, finds the
# provider through `titanc.exe --print-root` from the PATH entries alone.
host="$check/host ü/bin"
mkdir -p "$host" "$check/empty path"
cp "$runtime/bin/lua.exe" "$runtime/bin/lua55.dll" "$host/"
cat > "$check/fallback.lua" <<'LUA'
local cpath, expectation = ...
package.path = ""
package.cpath = cpath
require "titan"
if expectation == "missing" then
  local ok, message = pcall(require, "fallback_probe")
  assert(not ok, "the provider resolved without titanc.exe on PATH")
  io.write(message, "\n")
else
  local probe, provider = require "fallback_probe"
  assert(probe.answer() == 42, "the fallback selected the wrong provider")
  io.write(provider, "\n")
end
LUA
probe_script=$(cygpath -m "$check/fallback.lua")
support_cpath="$(cygpath -m "$runtime/lib/lua/5.5")/?.dll"
expected_provider="$expected_root\\lib\\titan\\0.6\\fallback_probe.dll"
# DIRECTORY PATH [TITANC] [EXPECTATION]: run the host with exactly that PATH.
run_fallback() {
  local directory=$1 search=$2 selected=${3-} expectation=${4-found}
  ( cd "$directory"
    export PATH="$search"
    if [[ -n $selected ]]; then export TITANC="$selected"; fi
    "$host/lua.exe" -E "$probe_script" "$support_cpath" "$expectation" )
}
# The default name, then a bare TITANC with and without its extension.
for selected in '' titanc titanc.exe; do
  provider=$(run_fallback "$check/cwd" "$runtime/bin" "$selected")
  same_path "$provider" "$expected_provider" || {
    echo "TITANC='$selected' selected '$provider', expected '$expected_provider'" >&2
    exit 1
  }
done
# Neither the current directory nor the application directory is searched,
# even when both hold titanc.exe: only PATH entries are.
cp "$runtime/bin/titanc.exe" "$host/"
for selected in '' titanc; do
  message=$(run_fallback "$runtime/bin" "$check/empty path" "$selected" missing)
  [[ $message == *"no Titan SDK fallback: 'titanc' was not found on PATH"* ]] || {
    echo "TITANC='$selected' outside PATH: unexpected result: $message" >&2
    exit 1
  }
done
rm "$host/titanc.exe"

printf '%s\n' "$runtime" > "$build/compiler-check-runtime.txt"
printf 'LuaRocks compiler/dependency/import gates passed: %s\n' "$check"
