#!/usr/bin/env bash
# The full shared native suite owns a private local NTFS workspace and SDK copy.
set -euo pipefail
if [[ ${MSYSTEM:-} != CLANG64 || $# -lt 2 || $# -gt 3 ||
      ( $1 != build && $1 != run ) || ( $1 == build && $# != 3 ) ]]; then
  echo 'usage (native CLANG64): windows_stdlib_tests.sh build WORKSPACE VALIDATED_SDK_PREFIX | run WORKSPACE' >&2
  exit 2
fi
mode=$1
source_root=$(cd "$(dirname "$0")/.." && pwd)
workspace=$2
owner=titan-windows-stdlib-tests-v1
if [[ $mode == build ]]; then
  prefix=$(cd "$3" && pwd)
  [[ -f $prefix/bin/titanc.exe && -f $prefix/bin/lua.exe &&
     -f $prefix/lib/titan/0.6/titan.dll &&
     -f $prefix/share/lua/5.5/titan/sqlite3.lua &&
     -f $prefix/etc/titan/lua-5.5.1-windows.config ]]
  export TITAN_BEHAVIOR_SOURCE_SDK=$(cygpath -aw "$prefix")
fi
export TITAN_BEHAVIOR_WORK=$(cygpath -aw "$workspace") TITAN_BEHAVIOR_MODE=$mode
export MSYS2_ARG_CONV_EXCL='*'
powershell.exe -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  function Normalized-Directory([string] $path) {
    if (Test-Path -LiteralPath $path) { $path = (Resolve-Path -LiteralPath $path).ProviderPath }
    $path = [IO.Path]::GetFullPath($path).TrimEnd([char]92, [char]47)
    $directory = [IO.DirectoryInfo]::new($path)
    while ($null -ne $directory) {
      if ($directory.Exists -and
          ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The workspace and SDK must not traverse a directory link or mount point."
      }
      $directory = $directory.Parent
    }
    return $path
  }
  $work = Normalized-Directory $env:TITAN_BEHAVIOR_WORK
  if ($env:TITAN_BEHAVIOR_MODE -eq "build") {
    $sdk = Normalized-Directory $env:TITAN_BEHAVIOR_SOURCE_SDK
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if ($work.Equals($sdk, $comparison) -or
        $work.StartsWith($sdk + "\", $comparison) -or
        $sdk.StartsWith($work + "\", $comparison)) {
      throw "The test workspace and supplied SDK must be separate directory trees."
    }
  }
  $root = [IO.Path]::GetPathRoot($work)
  $drive = [IO.DriveInfo]::new($root)
  if ($root -notmatch "^[A-Za-z]:\\$" -or $drive.DriveType -ne [IO.DriveType]::Fixed -or
      $drive.DriveFormat -ne "NTFS") {
    throw "The shared native suite requires a runner-owned local NTFS workspace."
  }
'

if [[ $mode == build ]]; then
  mkdir -p "$(dirname "$workspace")"
  if [[ -e $workspace ]]; then
    [[ -d $workspace && ! -L $workspace && -f $workspace/.titan-test-owner &&
       $(cat "$workspace/.titan-test-owner") == "$owner" ]] || {
      echo "Refusing to replace an unowned test workspace: $workspace" >&2; exit 1;
    }
  else
    mkdir "$workspace"
    printf '%s\n' "$owner" > "$workspace/.titan-test-owner"
  fi
fi
work=$(cd "$workspace" && pwd)
[[ ! -L $workspace && -f $work/.titan-test-owner &&
   $(cat "$work/.titan-test-owner") == "$owner" ]]

if [[ $mode == build ]]; then
  # Only this marked workspace owns these outputs. Never rebuild or publish into
  # the supplied SDK, or mix native outputs with a Unix source checkout.
  rm -rf "$work/sdk" "$work/source" "$work/cwd" "$work/scratch"
  rm -f "$work/build.complete" "$work/build.log" "$work/stdout.log" "$work/stderr.log"
  mkdir -p "$work/sdk" "$work/source" "$work/cwd/spec/fixtures" "$work/cwd/.titan-tests" "$work/scratch"
  cp -R "$prefix/." "$work/sdk/"
  shopt -s globstar nullglob
  for input in "$source_root"/spec/stdlib/titan/**/*.titan "$source_root"/spec/stdlib/titan/**/*.h; do
    case "$input" in *.titan.h|*.ffi.h) continue ;; esac
    relative=${input#"$source_root/spec/stdlib/titan/"}
    mkdir -p "$work/source/$(dirname "$relative")"
    cp "$input" "$work/source/$relative"
  done
  # Fresh-process tests read their authored fixtures from the ordinary root CWD.
  # Same-stem generated C and synthetic runner headers are not fixture inputs.
  for input in "$source_root"/spec/fixtures/**/*; do
    [[ -f $input ]] || continue
    case "$input" in
      *.ffi.h|*.titan.h|*__test_support.*|*__test_runner.*|*__test_entrypoint.*) continue ;;
      *.c) [[ ! -f ${input%.c}.titan ]] || continue ;;
      *.titan|*.h|*.lua|*.pem|*.sh|*.txt|*.json) ;;
      *) continue ;;
    esac
    relative=${input#"$source_root/spec/fixtures/"}
    mkdir -p "$work/cwd/spec/fixtures/$(dirname "$relative")"
    cp "$input" "$work/cwd/spec/fixtures/$relative"
  done
  make --no-print-directory -s -f "$source_root/spec/support/stdlib_test_modules.mk" \
    print-stdlib-test-roots > "$work/roots.txt"
  mapfile -t roots < "$work/roots.txt"
  [[ ${#roots[@]} -gt 0 && ${roots[0]} == test.tests ]]
  cp "$source_root/scripts/check_stdlib_test_output.lua" "$work/check_stdlib_test_output.lua"
  winprefix=$(cygpath -m "$work/sdk")
  winnative=$(cygpath -m "$work/cwd/.titan-tests")
  export CC=${CC:-clang} AR=${AR:-llvm-ar} RANLIB=${RANLIB:-llvm-ranlib}
  export TITAN_EXTRA_CFLAGS=${TITAN_EXTRA_CFLAGS:--O0}
  export TITAN_EXTRA_CPPFLAGS="${TITAN_EXTRA_CPPFLAGS:-} -DUSING_UV_SHARED=1 -I\"$winprefix/include\" -I\"$winnative\""
  # Public fixture calls use the same DLL instances as the canonical provider;
  # these import libraries are final-link inputs, never Titan -X providers.
  [[ -f $work/sdk/lib/libsqlite3.dll.a ]]
  export TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} \"$winprefix/lib/libsqlite3.dll.a\" -luser32"
  # Parse configured tool/flag strings without evaluating command substitutions.
  for name in CC TITAN_EXTRA_CFLAGS TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_LDFLAGS; do
    perl -MText::ParseWords=shellwords -e '
      my $s=$ENV{$ARGV[0]}; my @a=shellwords($s);
      die "Malformed argument string\n" if $s =~ /\S/ && !@a;
      die "Empty C compiler command\n" if $ARGV[0] eq "CC" && !@a;
      print "$_\0" for @a' "$name" > "$work/$name.argv"
  done
  mapfile -d '' -t compiler < "$work/CC.argv"
  mapfile -d '' -t cflags < "$work/TITAN_EXTRA_CFLAGS.argv"
  mapfile -d '' -t cppflags < "$work/TITAN_EXTRA_CPPFLAGS.argv"
  [[ $("${compiler[@]}" -dumpmachine) == x86_64-w64-windows-gnu ]]
  for name in CC AR RANLIB TITAN_EXTRA_CFLAGS TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_LDFLAGS; do
    printf 'export %s=%q\n' "$name" "${!name}"
  done > "$work/compiler.env"
  (
    set -x
    for fixture in async_foreign_work fs_fixture uv_stdio_probe sqlite3_worker_fixture; do
      if [[ -f $work/cwd/spec/fixtures/stdlib/native/$fixture.h ]]; then
        cp "$work/cwd/spec/fixtures/stdlib/native/$fixture.h" "$work/cwd/.titan-tests/$fixture.h"
      fi
      "${compiler[@]}" -std=c99 -Wall -Wextra -Werror "${cppflags[@]}" "${cflags[@]}" \
        -I"$winprefix/src/lua-5.5.1" \
        -c "$(cygpath -m "$source_root/spec/fixtures/stdlib/native/$fixture.c")" \
        -o "$winnative/$fixture.o"
    done
    "${compiler[@]}" -std=c99 -O2 -Wall -Wextra -Werror -municode \
      "$(cygpath -m "$work/cwd/spec/fixtures/stdlib/native/os_process_host_child.c")" \
      -o "$winprefix/bin/process child ação 東京.exe"
    "${compiler[@]}" -std=c99 -O2 -Wall -Wextra -Werror -municode \
      "$(cygpath -m "$work/cwd/spec/fixtures/stdlib/native/windows_test_supervisor.c")" \
      -o "$winprefix/bin/windows-test-supervisor.exe"
    export TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1 TITAN_JOBS=1
    export TITAN_PROBE_CACHE_DISABLE=1 TITAN_PATH_0_6="$winprefix/lib/titan/0.6"
    unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5 ROCKS_TREE
    export PATH="$work/sdk/bin:$PATH"
    cd "$work/sdk"
    "$work/sdk/bin/titanc.exe" --test --no-uv-bootstrap -j 1 \
      --launcher-name titan-stdlib-tests --tree "$(cygpath -m "$work/source")" \
      "${roots[@]}" -X "$winnative/async_foreign_work.o" "$winnative/fs_fixture.o" "$winnative/uv_stdio_probe.o"
  ) 2>&1 | tee "$work/build.log"
  [[ -f $work/sdk/bin/titan-stdlib-tests.exe ]]
  printf '%s\n' 'Windows x64 CLANG64/UCRT; shared native inventory; local NTFS' > "$work/build.complete"
  echo "Built ${#roots[@]} shared native test roots in $work"
  exit 0
fi

[[ -f $work/build.complete && -f $work/sdk/bin/titan-stdlib-tests.exe ]]
rm -f "$work/stdout.log" "$work/stderr.log"
source "$work/compiler.env"
winprefix=$(cygpath -m "$work/sdk")
export TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1 TITAN_JOBS=1
export TITAN_PROBE_CACHE_DISABLE=1 TITAN_PATH_0_6="$winprefix/lib/titan/0.6"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5 ROCKS_TREE
export PATH="$work/sdk/bin:$PATH"
export TITAN_TEST_ROOT=$(cygpath -w "$work/scratch")
export TITAN_PROCESS_CHILD=$(cygpath -w "$work/sdk/bin/process child ação 東京.exe")
export TITAN_TEST_BUILD_DIR=$(cygpath -m "$work/cwd/.titan-tests")
export TITAN_TEST_SOURCE_ROOT=$(cygpath -m "$work/cwd")
export TITAN_TEST_SDK_ROOT="$winprefix"
export TMP="$TITAN_TEST_ROOT" TEMP="$TITAN_TEST_ROOT"
export TITAN_BEHAVIOR_SUPERVISOR=$(cygpath -w "$work/sdk/bin/windows-test-supervisor.exe")
export TITAN_BEHAVIOR_EXE=$(cygpath -w "$work/sdk/bin/titan-stdlib-tests.exe")
export TITAN_BEHAVIOR_CWD=$(cygpath -w "$work/cwd")
export TITAN_TEST_TIMEOUT=${TITAN_TEST_TIMEOUT:-300} TITAN_FILTER=${TITAN_FILTER:-}
[[ $TITAN_TEST_TIMEOUT =~ ^[1-9][0-9]*$ && ${#TITAN_TEST_TIMEOUT} -le 7 &&
   $TITAN_TEST_TIMEOUT -le 2147468 ]] || {
  echo 'TITAN_TEST_TIMEOUT must be a positive bounded number of seconds' >&2; exit 2;
}
printf 'Windows x64 CLANG64/UCRT native suite; local NTFS; roots:\n'
cat "$work/roots.txt"
set +e
# Inline PowerShell owns the supervisor handle and drains both output pipes.
# The native supervisor atomically assigns the suite to its private Job Object;
# every normal, failed, timed-out, or interrupted run reaps its whole child tree.
powershell.exe -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  function Quote-Argument([string] $argument) {
    $result = [Text.StringBuilder]::new()
    [void]$result.Append([char]34)
    $slashes = 0
    foreach ($character in $argument.ToCharArray()) {
      if ($character -eq [char]92) { $slashes++; continue }
      if ($character -eq [char]34) {
        [void]$result.Append([char]92, 2 * $slashes + 1)
      } else { [void]$result.Append([char]92, $slashes) }
      [void]$result.Append($character)
      $slashes = 0
    }
    [void]$result.Append([char]92, 2 * $slashes)
    [void]$result.Append([char]34)
    return $result.ToString()
  }
  $timeout = [int]$env:TITAN_TEST_TIMEOUT * 1000
  $arguments = @($timeout.ToString(), $env:TITAN_BEHAVIOR_EXE)
  if (-not [string]::IsNullOrEmpty($env:TITAN_FILTER)) { $arguments += "--filter=" + $env:TITAN_FILTER }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo.FileName = $env:TITAN_BEHAVIOR_SUPERVISOR
  $process.StartInfo.Arguments = ($arguments | ForEach-Object { Quote-Argument $_ }) -join " "
  $process.StartInfo.WorkingDirectory = $env:TITAN_BEHAVIOR_CWD
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true
  $process.StartInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $process.StartInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $started = $false
  try {
    $started = $process.Start()
    if (-not $started) { throw "Could not start native test supervisor." }
    $heldHandle = $process.Handle
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeout + 15000)) {
      $process.Kill()
      if (-not $process.WaitForExit(10000)) { throw "Supervisor did not terminate." }
      throw "Native test supervisor exceeded its own cleanup deadline."
    }
    $status = $process.ExitCode
  } finally {
    try {
      if ($started -and -not $process.HasExited) {
        $process.Kill()
        if (-not $process.WaitForExit(10000)) { throw "Supervisor cleanup failed." }
      }
      if ($started) {
        $encoding = [Text.UTF8Encoding]::new($false)
        if (-not $stdout.Wait(10000)) { throw "Native suite stdout did not close." }
        [IO.File]::WriteAllText($env:TITAN_BEHAVIOR_WORK + "\stdout.log", $stdout.Result, $encoding)
        if (-not $stderr.Wait(10000)) { throw "Native suite stderr did not close." }
        [IO.File]::WriteAllText($env:TITAN_BEHAVIOR_WORK + "\stderr.log", $stderr.Result, $encoding)
      }
    } finally { $process.Dispose() }
  }
  if (@(Get-ChildItem -Force -LiteralPath $env:TITAN_TEST_ROOT).Count -ne 0) {
    throw "Public behavior cases left files in their owned scratch directory."
  }
  if ($status -ne 0) {
    [Console]::Error.WriteLine("Native suite/supervisor failed with Windows exit code " + $status + ".")
    # Bash keeps only eight exit bits; a native code such as 256 is still failure.
    exit 1
  }
'
status=$?
set -e
[[ ! -f $work/stdout.log ]] || cat "$work/stdout.log"
[[ ! -f $work/stderr.log ]] || cat "$work/stderr.log" >&2
audit=0
if [[ -f $work/stdout.log ]]; then
  "$work/sdk/bin/lua.exe" -E "$(cygpath -m "$work/check_stdlib_test_output.lua")" \
    "$(cygpath -m "$work/stdout.log")" "$(cygpath -m "$work/roots.txt")" "$TITAN_FILTER" || audit=$?
else
  echo 'Native stdlib report: incomplete; no native output was captured.' >&2
  audit=1
fi
[[ $status == 0 ]] || exit "$status"
[[ $audit == 0 ]] || exit "$audit"
echo 'Owned scratch cleanup passed; native supervisor reaped the owned process tree.'
