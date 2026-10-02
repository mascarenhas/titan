#!/usr/bin/env bash
# Build in a new private SDK copy; never change the caller's prepared provider.
set -euo pipefail
if [[ $# != 2 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_stdlib_behavior.sh NTFS_WORK_PARENT VALIDATED_SDK_PREFIX' >&2
  exit 2
fi
source_root=$(cd "$(dirname "$0")/.." && pwd)
work_parent=$(cd "$1" && pwd)
prefix=$(cd "$2" && pwd)
[[ -f $prefix/bin/titanc.exe && -f $prefix/bin/lua.exe &&
   -f $prefix/lib/titan/0.6/titan.dll && -f $prefix/share/lua/5.5/titan/sqlite3.lua &&
   -f $prefix/etc/titan/lua-5.5.1-windows.config ]]
# The four shared roots remain owned by the Unix source inventory. The separate
# Windows inventory owns only the additional roots and is also checked by the
# repository-wide source completeness gate.
roots=(coroutine.tests timer.tests net.tests ssl.tests)
declare -A root_names=()
for module in "${roots[@]}"; do root_names[$module]=1; done
windows_roots=0
while IFS=$'\t' read -r module source_file extra || [[ -n $module$source_file$extra ]]; do
  [[ -z $module || $module == \#* ]] && continue
  if [[ ! $module =~ ^[a-zA-Z_][a-zA-Z0-9_]*([.][a-zA-Z_][a-zA-Z0-9_]*)*$ ||
        $source_file != "spec/stdlib/titan/${module//.//}.titan" || -n $extra ||
        ! -f $source_root/$source_file || -n ${root_names[$module]:-} ]]; then
    echo "invalid or duplicate Windows test inventory entry: $module" >&2
    exit 2
  fi
  selected=0
  while IFS= read -r case_name; do
    if [[ $case_name == "$module."* ]]; then selected=1; break; fi
  done < "$source_root/spec/support/windows_stdlib_cases.txt"
  if [[ $selected != 1 ]]; then
    echo "Windows test root has no selected behavior case: $module" >&2
    exit 2
  fi
  root_names[$module]=1
  roots+=("$module")
  windows_roots=$((windows_roots + 1))
done < "$source_root/spec/support/windows_stdlib_modules.tsv"
[[ $windows_roots -gt 0 ]]
work=$(mktemp -d "$work_parent/titan-stdlib-behavior.XXXXXXXX")
echo "Windows stdlib subset workspace: $work"
export TITAN_BEHAVIOR_WORK=$(cygpath -w "$work")
export MSYS2_ARG_CONV_EXCL='*'
powershell.exe -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  $directory = [IO.DirectoryInfo]::new($env:TITAN_BEHAVIOR_WORK)
  while ($null -ne $directory) {
    if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "The local NTFS workspace must not traverse a directory link or mount point."
    }
    $directory = $directory.Parent
  }
  $root = [IO.Path]::GetPathRoot($env:TITAN_BEHAVIOR_WORK)
  $drive = [IO.DriveInfo]::new($root)
  if ($root -notmatch "^[A-Za-z]:\\$" -or $drive.DriveType -ne [IO.DriveType]::Fixed -or
      $drive.DriveFormat -ne "NTFS") {
    throw "This subset requires a runner-owned local NTFS workspace."
  }
'
mkdir -p "$work/sdk" "$work/source" "$work/scratch" "$work/cwd/spec/fixtures/ssl"
cp -R "$prefix/." "$work/sdk/"
# Copy source only; neither other tests' generated objects nor a POSIX aggregate
# fixture can enter the native test link through this staging step.
shopt -s globstar nullglob
for input in "$source_root"/spec/stdlib/titan/**/*.titan "$source_root"/spec/stdlib/titan/**/*.h; do
  case "$input" in *.titan.h|*.ffi.h) continue ;; esac
  relative=${input#"$source_root/spec/stdlib/titan/"}
  mkdir -p "$work/source/$(dirname "$relative")"
  cp "$input" "$work/source/$relative"
done
for pem in server.pem wrong-server.pem server-key.pem ca.pem; do
  cp "$source_root/spec/fixtures/ssl/$pem" "$work/cwd/spec/fixtures/ssl/$pem"
done
cp "$source_root/spec/support/windows_stdlib_cases.txt" "$work/cases.txt"
cp "$source_root/spec/support/windows_stdlib_modules.tsv" "$work/modules.tsv"
winprefix=$(cygpath -m "$work/sdk")
export TITAN_ROCKS_ROOT="$winprefix" TITAN_RUNTIME_PREBUILT=1 TITAN_JOBS=1
export TITAN_PROBE_CACHE_DISABLE=1
export TITAN_PATH_0_6="$winprefix/lib/titan/0.6"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5 ROCKS_TREE TITAN_FILTER TITAN_WINDOWS_PROCESS_ABSENT_185
export TITAN_EXTRA_CFLAGS=${TITAN_EXTRA_CFLAGS:--O0}
export TITAN_EXTRA_CPPFLAGS="${TITAN_EXTRA_CPPFLAGS:-} -DUSING_UV_SHARED=1 -I\"$winprefix/include\""
export PATH="$work/sdk/bin:$PATH"
# This fixture uses UTF-16 wmain independently of Titan's UTF-8 spawn API.
# Keep the executable's space/Unicode spelling in the supplied native path.
child="$work/sdk/bin/process child ação 東京.exe"
clang -std=c99 -O2 -Wall -Wextra -Werror -municode \
  "$(cygpath -m "$source_root/spec/fixtures/stdlib/native/os_process_host_child.c")" \
  -o "$(cygpath -m "$child")"
supervisor="$work/sdk/bin/windows-test-supervisor.exe"
clang -std=c99 -O2 -Wall -Wextra -Werror -municode \
  "$(cygpath -m "$source_root/spec/fixtures/stdlib/native/windows_test_supervisor.c")" \
  -o "$(cygpath -m "$supervisor")"
(
  cd "$work/sdk"
  "$work/sdk/bin/titanc.exe" --test --no-uv-bootstrap -j 1 \
    --launcher-name windows-stdlib-subset --tree "$(cygpath -m "$work/source")" \
    "${roots[@]}"
) 2>&1 | tee "$work/build.log"
export TITAN_WINDOWS_PROCESS_CHILD=$(cygpath -w "$child")
export TITAN_WINDOWS_TEST_ROOT=$(cygpath -w "$work/scratch")
export TITAN_BEHAVIOR_SUPERVISOR=$(cygpath -w "$supervisor")
export TITAN_BEHAVIOR_EXE=$(cygpath -w "$work/sdk/bin/windows-stdlib-subset.exe")
export TITAN_BEHAVIOR_CWD=$(cygpath -w "$work/cwd")
# Ordinary inline PowerShell drains pipes and owns the supervisor handle.
# The native test-only supervisor atomically assigns the subset to its private
# job, limits inherited handles, and bounds/reaps the entire owned process tree.
# No execution-policy change, script-file evaluation, or PID-based kill is used.
set +e
powershell.exe -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  $cases = @(Get-Content -LiteralPath ($env:TITAN_BEHAVIOR_WORK + "\cases.txt") |
    Where-Object { $_ -ne "" -and -not $_.StartsWith("#") })
  if ($cases.Count -ne 53 -or ($cases | Select-Object -Unique).Count -ne 53) {
    throw "Expected exactly 53 distinct subset cases."
  }
  foreach ($case in $cases) {
    if ($case -notmatch "^[a-zA-Z0-9_.]+$") { throw "Invalid case name: $case" }
  }
  $arguments = ($cases | ForEach-Object { "--filter=^" + $_.Replace(".", "[.]") + "$" }) -join " "
  $process = [Diagnostics.Process]::new()
  $process.StartInfo.FileName = $env:TITAN_BEHAVIOR_SUPERVISOR
  # Windows paths cannot contain a quote, and this exact path names an EXE,
  # so it has no terminal backslash requiring additional CRT escaping.
  $process.StartInfo.Arguments = "180000 `"" + $env:TITAN_BEHAVIOR_EXE + "`" " + $arguments
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
    # The child deadline belongs to the job supervisor; this extra guard bounds
    # infrastructure failure. Killing our held supervisor closes its job handle.
    if (-not $process.WaitForExit(195000)) {
      $process.Kill()
      if (-not $process.WaitForExit(10000)) { throw "Supervisor did not terminate." }
      throw "Native test supervisor exceeded its own cleanup deadline."
    }
    $status = $process.ExitCode
    $encoding = [Text.UTF8Encoding]::new($false)
    if ($stdout.Wait(10000)) {
      [IO.File]::WriteAllText($env:TITAN_BEHAVIOR_WORK + "\stdout.log", $stdout.Result, $encoding)
    } else { throw "Subset stdout did not close." }
    if ($stderr.Wait(10000)) {
      [IO.File]::WriteAllText($env:TITAN_BEHAVIOR_WORK + "\stderr.log", $stderr.Result, $encoding)
    } else { throw "Subset stderr did not close." }
  } finally {
    try {
      if ($started -and -not $process.HasExited) {
        $process.Kill()
        if (-not $process.WaitForExit(10000)) { throw "Supervisor cleanup failed." }
      }
    } finally { $process.Dispose() }
  }
  if ($status -ne 0) {
    [Console]::Error.WriteLine("Native subset/supervisor failed with Windows exit code " + $status + ".")
    # MSYS Bash keeps only eight exit bits; 256 must not become shell success.
    exit 1
  }
  $actual = @($stdout.Result -split "\r?\n" | Where-Object { $_.StartsWith("[       OK ] ") } |
    ForEach-Object { $_.Substring(13) } | Sort-Object)
  $expected = @($cases | Sort-Object)
  if ($actual.Count -ne 53 -or (Compare-Object $expected $actual) -or
      $stdout.Result -notmatch "(?m)^\[  PASSED  \] 53 tests\.[\r]?$" -or
      $stdout.Result -match "\[  (SKIPPED|FAILED)" ) {
    throw "Native subset did not pass every exact expected case."
  }
  if (@(Get-ChildItem -Force -LiteralPath $env:TITAN_WINDOWS_TEST_ROOT).Count -ne 0) {
    throw "Public behavior cases left files in their owned scratch directory."
  }
  Write-Output "Windows stdlib subset: 53 exact cases passed; scratch cleanup passed."
'
status=$?
set -e
[[ ! -f $work/stdout.log ]] || cat "$work/stdout.log"
[[ ! -f $work/stderr.log ]] || cat "$work/stderr.log" >&2
exit "$status"
