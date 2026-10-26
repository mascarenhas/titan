#!/usr/bin/env bash
# The full shared native suite owns a private local NTFS workspace and SDK copy.
set -euo pipefail
source "$(dirname "$0")/../../scripts/windows_build_profile.sh"
titan_windows_profile validation
if [[ ${MSYSTEM:-} != CLANG64 || $# -lt 2 ||
      ( $1 != build && $1 != run ) ||
      ( $1 == build && $# != 3 ) || ( $1 == run && $# != 2 ) ]]; then
  echo 'usage (native CLANG64): windows_stdlib_tests.sh build WORKSPACE VALIDATED_SDK_PREFIX | run WORKSPACE' >&2
  exit 2
fi
mode=$1
source_root=$(cd "$(dirname "$0")/../.." && pwd)
workspace=$2
owner=titan-windows-stdlib-tests-v1
requested_profile=$TITAN_BUILD_PROFILE
requested_coverage=${TITAN_TEST_COVERAGE:-0}
if [[ $mode == build ]]; then
  prefix=$(cd "$3" && pwd)
  [[ -f $prefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc && -f $prefix/bin/lua.exe &&
     -f $prefix/lib/titan/0.6/titan.dll &&
     -f $prefix/share/lua/5.5/titan/sqlite3.lua ]]
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

# Manifests list only copied inputs, never generated SDK/output files. Removed
# inputs retire their exact old paths; unchanged bytes keep their timestamps.
owned_destination() {
  local path=$1
  while [[ $path != "$work" ]]; do
    [[ $path == "$work/"* && ! -L $path ]] || {
      echo "Refusing a linked or external owned destination: $path" >&2; return 1;
    }
    path=${path%/*}
  done
}
copy_input() {
  local input=$1 output=$2
  owned_destination "$output"
  if [[ ! -f $output ]] || ! cmp -s "$input" "$output"; then
    mkdir -p "${output%/*}"
    cp "$input" "$output"
  fi
}
refresh_inputs() {
  local base=$1 destination=$2 manifest=$3 input relative directory
  shift 3
  local -A current=()
  : > "$manifest.new"
  for input in "$@"; do
    relative=${input#"$base/"}
    [[ $relative != "$input" && $relative != /* && /$relative/ != */../* &&
       /$relative/ != */./* ]] || { echo "Invalid owned input: $input" >&2; return 1; }
    current["$relative"]=1
    printf '%s\0' "$relative" >> "$manifest.new"
  done
  if [[ -f $manifest ]]; then
    while IFS= read -r -d '' relative; do
      [[ -n $relative && $relative != /* && /$relative/ != */../* && /$relative/ != */./* ]] || {
        echo "Invalid owned input manifest: $manifest" >&2; return 1;
      }
      if [[ ! ${current["$relative"]+present} ]]; then
        owned_destination "$destination/$relative"
        rm -f "$destination/$relative"
        directory="$destination/$relative"
        directory=${directory%/*}
        while [[ $directory != "$destination" ]] && rmdir "$directory" 2>/dev/null; do
          directory=${directory%/*}
        done
      fi
    done < "$manifest"
  fi
  for input in "$@"; do
    relative=${input#"$base/"}
    copy_input "$input" "$destination/$relative"
  done
  mv -f "$manifest.new" "$manifest"
}

if [[ $mode == build ]]; then
  # Only this marked workspace owns these outputs. Refresh the supplied SDK
  # without deleting generated objects, providers, certificates or gcno notes.
  rm -f "$work/build.complete" "$work/build.log"
  for destination in "$work/sdk" "$work/source" "$work/cwd/spec/fixtures" "$work/cwd/.titan-tests"; do
    owned_destination "$destination"
  done
  mkdir -p "$work/sdk" "$work/source" "$work/cwd/spec/fixtures" "$work/cwd/.titan-tests"
  find "$prefix" \( -type f -o -type l \) -print0 > "$work/sdk.inputs.scan"
  mapfile -d '' -t sdk_inputs < "$work/sdk.inputs.scan"
  rm -f "$work/sdk.inputs.scan"
  refresh_inputs "$prefix" "$work/sdk" "$work/sdk.inputs" "${sdk_inputs[@]}"
  shopt -s globstar nullglob
  source_inputs=()
  for input in "$source_root"/spec/stdlib/titan/**/*.titan "$source_root"/spec/stdlib/titan/**/*.h \
      "$source_root"/spec/fixtures/stdlib/native/*.c "$source_root"/spec/fixtures/stdlib/native/*.h; do
    case "$input" in *.titan.h|*.ffi.h) continue ;; esac
    source_inputs+=("$input")
  done
  # Preserve authored relative imports of private collaboration headers.
  source_inputs+=("$source_root/titan/transfer_native.h" "$source_root/titan/protobuf/native.h")
  refresh_inputs "$source_root" "$work/source" "$work/source.inputs" "${source_inputs[@]}"
  # Fresh-process tests read authored fixtures from the ordinary root CWD.
  # Same-stem generated C and synthetic runner headers are not fixture inputs.
  fixture_inputs=()
  for input in "$source_root"/spec/fixtures/**/*; do
    [[ -f $input ]] || continue
    case "$input" in
      *.ffi.h|*.titan.h|*__test_support.*|*__test_runner.*|*__test_entrypoint.*) continue ;;
      *.c) [[ ! -f ${input%.c}.titan ]] || continue ;;
      *.titan|*.h|*.lua|*.pem|*.sh|*.txt|*.json) ;;
      *) continue ;;
    esac
    fixture_inputs+=("$input")
  done
  refresh_inputs "$source_root/spec/fixtures" "$work/cwd/spec/fixtures" \
    "$work/fixtures.inputs" "${fixture_inputs[@]}"
  "${MAKE:-make}" --no-print-directory -s \
    -f "$(cygpath -m "$source_root/spec/support/stdlib_test_modules.mk")" \
    print-stdlib-test-roots > "$work/roots.txt"
  mapfile -t roots < "$work/roots.txt"
  [[ ${#roots[@]} == 30 && ${roots[0]} == test.tests ]]
  copy_input "$source_root/spec/support/check_stdlib_test_output.lua" "$work/check_stdlib_test_output.lua"
  winprefix=$(cygpath -m "$work/sdk")
  winnative=$(cygpath -m "$work/cwd/.titan-tests")
  export CC=${CC:-clang} AR=${AR:-llvm-ar} RANLIB=${RANLIB:-llvm-ranlib}
  export TITAN_EXTRA_CFLAGS=${TITAN_EXTRA_CFLAGS-}
  export TITAN_EXTRA_CPPFLAGS="${TITAN_EXTRA_CPPFLAGS:-} -DUSING_UV_SHARED=1 -I\"$winprefix/include\" -I\"$winnative\""
  # Public fixture calls use the same DLL instances as the canonical provider;
  # these import libraries are final-link inputs, never Titan -X providers.
  [[ -f $work/sdk/lib/libsqlite3.dll.a ]]
  # Match the ordinary Unix main-thread budget for unchanged deep-recursion
  # oracles at -O0; CLANG64 otherwise gives launchers only a 1 MiB reserve.
  export TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} \"$winprefix/lib/libsqlite3.dll.a\" -luser32 -lws2_32 -Wl,--stack,8388608"
  # Parse configured tool/flag strings without evaluating command substitutions.
  for name in CC; do
    perl -MText::ParseWords=shellwords -e '
      my $s=$ENV{$ARGV[0]}; my @a=shellwords($s);
      die "Malformed argument string\n" if $s =~ /\S/ && !@a;
      die "Empty C compiler command\n" if $ARGV[0] eq "CC" && !@a;
      print "$_\0" for @a' "$name" > "$work/$name.argv"
  done
  mapfile -d '' -t compiler < "$work/CC.argv"
  titan_windows_raw_flags "$work" TEST
  [[ $("${compiler[@]}" -dumpmachine) == x86_64-w64-windows-gnu ]]
  for name in TITAN_BUILD_PROFILE CC AR RANLIB TITAN_EXTRA_CFLAGS TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_LDFLAGS TEST_CFLAGS TEST_CPPFLAGS TEST_LDFLAGS; do
    printf 'export %s=%q\n' "$name" "${!name}"
  done > "$work/compiler.env"
  printf 'export TITAN_TEST_COVERAGE=%q\n' "$requested_coverage" >> "$work/compiler.env"
  native_headers=("$work/cwd/spec/fixtures/stdlib/native/uv_coverage_threads.h"
    "$work/cwd/spec/fixtures/stdlib/native/uv_coverage_pty.h")
  for fixture in async_foreign_work fs_fixture uv_stdio_probe sqlite3_worker_fixture \
      ssl_allocator_fixture ssl_error_strings os_descriptor_limit; do
    if [[ -f $work/cwd/spec/fixtures/stdlib/native/$fixture.h ]]; then
      native_headers+=("$work/cwd/spec/fixtures/stdlib/native/$fixture.h")
    fi
  done
  refresh_inputs "$work/cwd/spec/fixtures/stdlib/native" "$work/cwd/.titan-tests" \
    "$work/native-headers.inputs" "${native_headers[@]}"
  # Pure-C executable rules depend only on authored inputs and this content-
  # stable native policy receipt, never on SDK/compiler publication mtimes.
  {
    printf '%s\0' "$TITAN_BUILD_PROFILE" "${compiler[@]}" "${cppflags[@]}" "${cflags[@]}" "${ldflags[@]}"
    "${compiler[@]}" --version
  } > "$work/native-flags.config.new"
  copy_input "$work/native-flags.config.new" "$work/native-flags.config"
  rm -f "$work/native-flags.config.new"
  (
    set -x
    ( cd "$source_root"
      "${MAKE:-make}" --no-print-directory -f Makefile.win windows-stdlib-test-native \
        "TITAN_TEST_BUILD_DIR=$(cygpath -m "$work")" )
    export TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1 TITAN_JOBS="${TITAN_JOBS:-4}"
    export TITAN_PROBE_CACHE_DISABLE=1 TITAN_PATH_0_6="$winprefix/lib/titan/0.6"
    unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5 ROCKS_TREE
    export PATH="$work/sdk/bin:$PATH"
    # Fresh child programs need fixed object paths, including the UV helper
    # also compiled into the aggregate. Certify each native source separately.
    native_args=(--cflag=-std=c99 --cflag=-Wall --cflag=-Wextra --cflag=-Werror
      -I "$winprefix/src/lua-5.5.1")
    for flag in "${cppflags[@]}" "${cflags[@]}"; do native_args+=("--cflag=$flag"); done
    for fixture in uv_stdio_probe sqlite3_worker_fixture ssl_allocator_fixture ssl_error_strings os_descriptor_limit; do
      native_output="$work/native/$fixture"
      TITAN_EXTRA_CPPFLAGS= TITAN_EXTRA_CFLAGS= TITAN_EXTRA_LDFLAGS= \
        "$work/sdk/bin/lua.exe" "$winprefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc" \
          -c --incremental -j "$TITAN_JOBS" --output "$(cygpath -m "$native_output")" \
          "${native_args[@]}" --c-source "$(cygpath -m "$work/source/spec/fixtures/stdlib/native/$fixture.c")"
      objects=("$native_output"/.native/*.o)
      [[ ${#objects[@]} == 1 && -f ${objects[0]} ]]
      copy_input "${objects[0]}" "$work/cwd/.titan-tests/$fixture.o"
    done
    test_tree=$(cygpath -m "$work/source/spec/stdlib/titan")
    coverage_args=()
    payload=()
    output="$work/sdk"
    if [[ ${TITAN_TEST_COVERAGE:-0} == 1 ]]; then output="$work/coverage"; fi
    if [[ ${TITAN_TEST_COVERAGE:-0} == 1 ]]; then
      # Use the same source graph and test runner. Only production source
      # objects below .coverage carry instrumentation; child fixture builds
      # retain the ordinary installed provider.
      ( unset MSYS2_ARG_CONV_EXCL
        bash "$source_root/scripts/build_windows_runtime.sh" "$work/native-payload" "$work/sdk" )
      winsource=$(cygpath -m "$source_root")
      winpayload=$(cygpath -m "$work/native-payload/runtime")
      test_tree+=";$winsource"
      coverage_args=(--coverage --coverage-module 'titan.*'
        --coverage-backend llvm-gcov
        --coverage-gcov "${TITAN_COVERAGE_GCOV:-llvm-cov.exe gcov}"
        --coverage-root "$winsource"
        --coverage-output "$(cygpath -m "${TITAN_COVERAGE_REPORT_DIR:-$work/report}")")
      for format in ${TITAN_COVERAGE_FORMATS:-}; do
        coverage_args+=(--coverage-format "$format")
      done
      if [[ -n ${TITAN_COVERAGE_GCOVR:-} ]]; then
        coverage_args+=(--coverage-gcovr "$TITAN_COVERAGE_GCOVR")
      fi
      payload+=("$winpayload/ltitanlib.o" "$winpayload/libtitan-lpeglabel.a")
      export TITAN_EXTRA_CPPFLAGS="$TITAN_EXTRA_CPPFLAGS -I\"$winsource/vendor/lpeglabel\""
      for library in libuv libllhttp libssl libcrypto; do
        TITAN_EXTRA_LDFLAGS+=" \"$winprefix/lib/$library.dll.a\""
      done
      export TITAN_EXTRA_LDFLAGS="$TITAN_EXTRA_LDFLAGS -lws2_32"
    fi
    if [[ ${#payload[@]} -gt 0 ]]; then payload=(-X "${payload[@]}"); fi
    cd "$work/sdk"
    "$work/sdk/bin/lua.exe" "$winprefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc" \
      --output "$(cygpath -m "$output")" --test --incremental --no-uv-bootstrap -j "$TITAN_JOBS" \
      --exe "$winprefix/bin/titan-stdlib-tests.exe" --tree "$test_tree" \
      --test-dir "$(cygpath -m "$work/source/spec/stdlib/titan")" "${coverage_args[@]}" \
      --c-source "$(cygpath -m "$work/source/spec/fixtures/stdlib/native/async_foreign_work.c")" \
      --c-source "$(cygpath -m "$work/source/spec/fixtures/stdlib/native/fs_fixture.c")" \
      --c-source "$(cygpath -m "$work/source/spec/fixtures/stdlib/native/uv_stdio_probe.c")" \
      test.tests "${payload[@]}"
  ) 2>&1 | tee "$work/build.log"
  [[ -f $work/sdk/bin/titan-stdlib-tests.exe ]]
  printf '%s\n' "Windows x64 CLANG64/UCRT; shared native inventory; local NTFS; profile=$TITAN_BUILD_PROFILE" > "$work/build.complete"
  echo "Built ${#roots[@]} shared native test roots in $work"
  exit 0
fi

[[ -f $work/build.complete && -f $work/sdk/bin/titan-stdlib-tests.exe ]]
# Runtime scratch is execution-owned; never reset compiler output trees here.
source "$work/compiler.env"
[[ $TITAN_BUILD_PROFILE == "$requested_profile" ]] || {
  echo 'The test workspace was built with a different profile; rebuild it first' >&2; exit 1;
}
[[ $TITAN_TEST_COVERAGE == "$requested_coverage" ]] || {
  echo 'The test workspace was built with a different coverage mode; rebuild it first' >&2; exit 1;
}
owned_destination "$work/scratch"
rm -rf "$work/scratch"
mkdir "$work/scratch"
rm -f "$work/stdout.log" "$work/stderr.log"
winprefix=$(cygpath -m "$work/sdk")
export TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1 TITAN_JOBS=1
# Preserve the controlled provider first and each child launcher's default
# executable-relative provider directory for fresh-process fixture programs.
export TITAN_PROBE_CACHE_DISABLE=1 TITAN_PATH_0_6="$winprefix/lib/titan/0.6;;"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5 ROCKS_TREE
export PATH="$work/sdk/bin:$PATH"
export TITAN_TEST_ROOT=$(cygpath -w "$work/scratch")
export TITAN_PROCESS_CHILD=$(cygpath -w "$work/sdk/bin/process child ação 東京.exe")
export TITAN_TEST_BUILD_DIR=$(cygpath -m "$work/cwd/.titan-tests")
export TITAN_TEST_SOURCE_ROOT=$(cygpath -m "$work/cwd")
export TITAN_TEST_SDK_ROOT="$winprefix"
export TMP="$TITAN_TEST_ROOT" TEMP="$TITAN_TEST_ROOT"
export TMPDIR=$(cygpath -m "$work/scratch")
export TITAN_BEHAVIOR_SUPERVISOR=$(cygpath -w "$work/sdk/bin/windows-test-supervisor.exe")
export TITAN_BEHAVIOR_EXE=$(cygpath -w "$work/sdk/bin/titan-stdlib-tests.exe")
export TITAN_BEHAVIOR_CWD=$(cygpath -w "$work/cwd")
export TITAN_TEST_TIMEOUT=${TITAN_TEST_TIMEOUT:-1800} TITAN_FILTER=${TITAN_FILTER:-}
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
    # Persist pipe output as it arrives, including an incomplete timed-out run.
    $stdoutStream = [IO.FileStream]::new($env:TITAN_BEHAVIOR_WORK + "\stdout.log", [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, $true)
    $stderrStream = [IO.FileStream]::new($env:TITAN_BEHAVIOR_WORK + "\stderr.log", [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, $true)
    $stdout = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
    $stderr = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
    # Allow launcher loading before the native deadline and its bounded teardown.
    if (-not $process.WaitForExit($timeout + 60000)) {
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
        $drainErrors = @()
        foreach ($capture in @(
          [PSCustomObject]@{ Task=$stdout; Reader=$process.StandardOutput; Writer=$stdoutStream; Name="stdout" },
          [PSCustomObject]@{ Task=$stderr; Reader=$process.StandardError; Writer=$stderrStream; Name="stderr" }
        )) {
          try {
            if (-not $capture.Task.Wait(10000)) {
              $capture.Reader.Close()
              $drainErrors += "Native suite " + $capture.Name + " did not close."
            }
          } catch { $drainErrors += $_.Exception.Message }
          finally {
            try { $capture.Writer.Flush() } finally { $capture.Writer.Dispose() }
          }
        }
        if ($drainErrors.Count) { throw ($drainErrors -join " ") }
      }
    } finally { $process.Dispose() }
  }
  if ($status -ne 0) {
    [Console]::Error.WriteLine("Native suite/supervisor failed with Windows exit code " + $status + ".")
  }
  if (@(Get-ChildItem -Force -LiteralPath $env:TITAN_TEST_ROOT).Count -ne 0) {
    throw "Public behavior cases left files in their owned scratch directory."
  }
  if ($status -ne 0) {
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
