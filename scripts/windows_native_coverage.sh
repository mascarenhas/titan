#!/usr/bin/env bash
# Native line coverage owns a private SDK copy and never installs into its input.
set -euo pipefail
source "$(dirname "$0")/windows_build_profile.sh"
titan_windows_profile validation
usage() {
  echo 'usage (native CLANG64): windows_native_coverage.sh build BUILD SDK PYTHON GCOV GCOVR ROOT... | run BUILD RUN PYTHON | report BUILD RUN REPORT PYTHON GCOVR' >&2
  exit 2
}
[[ ${MSYSTEM:-} == CLANG64 && $# -ge 2 ]] || usage
mode=$1
build=$2
case $mode in
  build) [[ $# -ge 8 ]] || usage ;;
  run) [[ $# == 4 ]] || usage ;;
  report) [[ $# == 6 ]] || usage ;;
  *) usage ;;
esac
source_root=$(cd "$(dirname "$0")/.." && pwd)
owner=titan-windows-native-coverage-v1
export MSYS2_ARG_CONV_EXCL='*'
export TITAN_COVERAGE_WORK=$(cygpath -aw "$build")
# Existing SDK/harness validation uses this same local-drive/reparse boundary.
powershell.exe -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  $work = [IO.Path]::GetFullPath($env:TITAN_COVERAGE_WORK)
  $directory = [IO.DirectoryInfo]::new($work)
  while ($null -ne $directory) {
    if ($directory.Exists -and
        ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "The coverage workspace must not traverse a directory link or mount point."
    }
    $directory = $directory.Parent
  }
  $root = [IO.Path]::GetPathRoot($work)
  $drive = [IO.DriveInfo]::new($root)
  if ($root -notmatch "^[A-Za-z]:\\$" -or
      $drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -ne "NTFS") {
    throw "Native coverage requires a runner-owned local NTFS workspace."
  }
'
build=$(cygpath -au "$build")
prefix=$build/sdk-input
host=$prefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titan-coverage
manifest=$build/provider/build.json
parse_python() {
  local argument=$1
  mapfile -d '' -t python < <(perl -MText::ParseWords=shellwords -e '
    my @a=shellwords($ARGV[0]); die "Invalid native Python command\n" unless @a;
    print "$_\0" for @a' "$argument")
  [[ ${#python[@]} -gt 0 ]] || { echo 'Invalid native Python command' >&2; exit 2; }
}

if [[ $mode == build ]]; then
  sdk=$(cd "$3" && pwd)
  python_command=$4
  gcov=$5
  gcovr=$6
  roots=("${@:7}")
  [[ ${#roots[@]} == 23 && -f $sdk/bin/lua.exe &&
     -f $sdk/lib/titan/0.6/titan.dll &&
     -f $sdk/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc &&
     -f $sdk/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titan-coverage ]] || {
    echo 'Coverage requires the prepared current Windows SDK and all 23 standard roots' >&2
    exit 1
  }
  export TITAN_COVERAGE_SOURCE_SDK=$(cygpath -aw "$sdk")
  powershell.exe -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    $sdk = [IO.Path]::GetFullPath($env:TITAN_COVERAGE_SOURCE_SDK).TrimEnd([char]92,[char]47)
    $work = [IO.Path]::GetFullPath($env:TITAN_COVERAGE_WORK).TrimEnd([char]92,[char]47)
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if ($work.Equals($sdk,$comparison) -or $work.StartsWith($sdk+"\",$comparison) -or
        $sdk.StartsWith($work+"\",$comparison)) { throw "Input SDK and coverage build must be disjoint." }
    $directory = [IO.DirectoryInfo]::new($sdk)
    while ($null -ne $directory) {
      if ($directory.Exists -and
          ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The input SDK must not traverse a directory link or mount point."
      }
      $directory = $directory.Parent
    }
  '
  [[ ! -e $build ]] || { echo "Coverage build directory must be fresh: $build" >&2; exit 1; }
  mkdir -p "$build"
  printf '%s\n' "$owner" > "$build/.titan-coverage-owner"
  mkdir "$prefix" "$build/scratch" "$build/preparation-counters"
  cp -R "$sdk/." "$prefix/"
  parse_python "$python_command"
  winprefix=$(cygpath -m "$prefix")
  winbuild=$(cygpath -m "$build")
  winsource=$(cygpath -m "$source_root")
  export TMP=$(cygpath -w "$build/scratch")
  export TEMP="$TMP" TMPDIR=$(cygpath -m "$build/scratch")
  # Even provider metadata probes must avoid source-adjacent run counters.
  export GCOV_PREFIX="$winbuild/preparation-counters" GCOV_PREFIX_STRIP=1
  export CC=${CC:-clang.exe} AR=${AR:-llvm-ar} RANLIB=${RANLIB:-llvm-ranlib}
  export TITAN_PROBE_CACHE_DISABLE=1 TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1
  export TITAN_PATH_0_6="$winprefix/lib/titan/0.6" TITAN_JOBS=${TITAN_JOBS:-1}
  unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5 ROCKS_TREE
  export PATH="$prefix/bin:$PATH"
  cd "$source_root"
  # This ordinary native builder passes MSYS paths to the compiler and owns
  # their normal argument conversion. Explicit native argv below stays separate.
  (
    unset MSYS2_ARG_CONV_EXCL
    bash scripts/build_windows_runtime.sh "$build/native-payload" "$prefix"
  )
  export TITAN_EXTRA_CFLAGS='-O0 -fno-lto'
  export TITAN_EXTRA_CPPFLAGS="${TITAN_EXTRA_CPPFLAGS:-} -DUSING_UV_SHARED=1 -I\"$winprefix/include\" -I\"$winsource/vendor/lpeglabel\""
  export TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} -O0 -fno-lto"
  for library in libuv libllhttp libsqlite3 libssl libcrypto; do
    [[ -f $prefix/lib/$library.dll.a ]]
    TITAN_EXTRA_LDFLAGS+=" \"$winprefix/lib/$library.dll.a\""
  done
  TITAN_EXTRA_LDFLAGS+=' -lws2_32'
  coverage_modules=()
  for root in "${roots[@]}"; do
    [[ $root == titan.test ]] || coverage_modules+=(--coverage-module "$root")
  done
  [[ ${#coverage_modules[@]} == 44 ]]
  "$prefix/bin/lua.exe" -E "$winprefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc" \
    --source-first -j "$TITAN_JOBS" --tree "$winsource" \
    --coverage "$winbuild/provider" --coverage-root "$winsource" \
    --coverage-backend llvm-gcov --coverage-python "$python_command" --coverage-gcov "$gcov" \
    "${coverage_modules[@]}" "${roots[@]}" \
    -X "$winbuild/native-payload/runtime/ltitanlib.o" "$winbuild/native-payload/runtime/libtitan-lpeglabel.a"
  # The compiler records actual Windows artifacts, rather than Unix .so guesses.
  "${python[@]}" -I -S -B - "$(cygpath -m "$manifest")" "$winprefix" "$winsource" "${roots[@]}" <<'PY'
import json
import pathlib
import shutil
import sys

manifest = pathlib.Path(sys.argv[1])
sdk = pathlib.Path(sys.argv[2])
source_root = pathlib.Path(sys.argv[3])
build = json.loads(manifest.read_text(encoding="utf-8"))
images = [pathlib.Path(item["path"]) for item in build["providers"]]
providers = [image for image in images if image.name == "titan.dll"]
roots = sys.argv[4:]
expected = {pathlib.Path(*name.split(".")).with_suffix(".lua") for name in roots}
if len(expected) != 23 or len(providers) != 1 or len(build["objects"]) != 22:
    raise SystemExit("Expected one actual standard DLL and 22 measured production objects")
production = set(roots) - {"titan.test"}
if {item["module"] for item in build["sources"]} != production:
    raise SystemExit("Measured standard-module inventory differs from the requested production roots")
expected_sources = set()
for module in production:
    stem = source_root.joinpath(*module.split("."))
    if stem.with_suffix(".titan").is_file():
        contributors = [stem.with_suffix(".titan")]
    else:
        contributors = list(stem.glob("*.titan"))
    if not contributors:
        raise SystemExit(f"Missing production source ensemble: {module}")
    expected_sources.update(str(path.resolve()).casefold() for path in contributors)
actual_sources = [str(pathlib.Path(item["path"]).resolve()).casefold() for item in build["sources"]]
if len(actual_sources) != len(set(actual_sources)) or set(actual_sources) != expected_sources:
    raise SystemExit("Measured standard source contributors are missing, duplicated or unexpected")
shutil.copy2(providers[0], sdk / "lib/titan/0.6/titan.dll")
shims = manifest.parent / "shims/titan"
inputs = sorted(shims.glob("*.lua"))
if {pathlib.Path("titan") / source.name for source in inputs} != expected:
    raise SystemExit("Expected exactly 23 generated standard-module shims")
for source in inputs:
    shutil.copy2(source, sdk / "share/lua/5.5/titan" / source.name)
PY
  # Ordinary consumers keep their ordinary flags; only the selected provider
  # carries LLVM's static profiling runtime and measured Titan objects.
  unset TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS TITAN_EXTRA_LDFLAGS
  bash spec/support/windows_stdlib_tests.sh build "$build/native" "$prefix"
  "${python[@]}" -I -S -B - "$winbuild" "$winsource" <<'PY'
import json
import pathlib
import sys

build = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
inputs = set()
def add(path):
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"Invalid coverage provenance input: {path}")
    inputs.add(str(path.resolve()))
def tree(root):
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"Linked coverage provenance input: {path}")
        if path.is_file():
            add(path)
for relative in ("sdk-input", "native/sdk", "native/source", "native/cwd/spec/fixtures", "native-payload"):
    tree(build / relative)
for path in (build / "native/cwd/.titan-tests").iterdir():
    if path.is_file():
        add(path)
for relative in ("native/roots.txt", "native/compiler.env", "native/check_stdlib_test_output.lua",
                 "native/build.complete", ".titan-coverage-owner"):
    add(build / relative)
for relative in ("Makefile.win", "scripts/windows_native_coverage.sh", "scripts/windows_build_profile.sh",
                 "scripts/build_windows_runtime.sh", "spec/support/windows_stdlib_tests.sh",
                 "spec/support/stdlib_test_modules.mk", "spec/support/check_stdlib_test_output.lua"):
    add(source / relative)
# Retain original test and fixture provenance as well as the staged inputs.
for root in (source / "spec/stdlib/titan", source / "spec/fixtures"):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name.endswith((".ffi.h", ".titan.h")):
            continue
        if path.suffix in (".titan", ".h", ".lua", ".pem", ".sh", ".txt", ".json") or (
            path.suffix == ".c" and not path.with_suffix(".titan").exists()
        ):
            add(path)
target = build / "unmeasured-inputs.json"
target.write_text(json.dumps(sorted(inputs), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  "${python[@]}" "$(cygpath -m "$host")" seal --manifest "$(cygpath -m "$manifest")" \
    --cc "$CC" --gcov "$gcov" --gcovr "$gcovr" \
    --unmeasured-input-file "$winbuild/unmeasured-inputs.json"
  printf '%s\n' "Windows LLVM-gcov; 22 production roots; 28 native test roots; profile=$TITAN_BUILD_PROFILE" > "$build/build.complete"
  exit 0
fi

[[ ! -L $build && -f $build/.titan-coverage-owner &&
   $(cat "$build/.titan-coverage-owner") == "$owner" &&
   -f $build/build.complete && -f $manifest && -f $host ]]
if [[ $mode == run ]]; then
  export TITAN_TEST_TIMEOUT=${TITAN_TEST_TIMEOUT:-600}
  exec bash "$source_root/spec/support/windows_stdlib_tests.sh" coverage-run \
    "$build/native" "$manifest" "$3" "$4" "$host"
fi
run=$(cygpath -au "$3")
report=$(cygpath -au "$4")
audit_file=$run/native-audit.exit
[[ -f $audit_file ]] || {
  echo 'Coverage report requires retained native output inventory audit evidence' >&2
  exit 1
}
audit_status=$(cat "$audit_file")
[[ $audit_status =~ ^(0|[1-9][0-9]{0,2})$ && $audit_status -le 255 ]] &&
  cmp -s "$audit_file" <(printf '%s\n' "$audit_status") || {
  echo 'Coverage report has malformed native output inventory audit evidence' >&2
  exit 1
}
[[ ! -e $report ]] || { echo "Coverage report directory must be fresh: $report" >&2; exit 1; }
parse_python "$5"
report_status=0
"${python[@]}" "$(cygpath -m "$host")" report --manifest "$(cygpath -m "$manifest")" \
  --run "$(cygpath -m "$run")" --output "$(cygpath -m "$report")" --gcovr "$6" || report_status=$?
# Keep valid diagnostic artifacts while retaining a failed suite/audit result.
if [[ -d $report ]]; then cp "$audit_file" "$report/native-audit.exit"; fi
[[ $audit_status == 0 ]] || exit "$audit_status"
exit "$report_status"
