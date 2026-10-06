#!/usr/bin/env bash
# Regression for the builder ownership boundary; all destructive candidates are
# disposable fixtures, and every rejected build must preserve their exact bytes.
set -euo pipefail
if [[ $# != 1 || ${MSYSTEM:-} != CLANG64 ]]; then
  echo 'usage (native CLANG64): check_windows_stdlib_workspace.sh NTFS_WORK_PARENT' >&2
  exit 2
fi
source_root=$(cd "$(dirname "$0")/../.." && pwd)
work_parent=$(cd "$1" && pwd)
trial=$(mktemp -d "$work_parent/stdlib-workspace-guard.XXXXXX")
trial=$(cd "$trial" && pwd)
seed="$trial/owned/sdk"
mkdir -p "$seed/bin" "$seed/lib/titan/0.6" "$seed/share/lua/5.5/titan" "$seed/etc/titan" "$seed/nested"
for path in bin/titanc.exe bin/lua.exe lib/titan/0.6/titan.dll share/lua/5.5/titan/sqlite3.lua etc/titan/lua-5.5.1-windows.config; do
  printf 'guard fixture %s\n' "$path" > "$seed/$path"
done
printf '%s\n' "${TITAN_BUILD_PROFILE-validation}" > "$seed/etc/titan/build-profile"
for path in "$trial/owned" "$seed" "$seed/nested"; do
  printf '%s\n' titan-windows-stdlib-tests-v1 > "$path/.titan-test-owner"
  printf '%s\n' 'retained guard sentinel' > "$path/sentinel"
done
manifest() { (cd "$trial"; find owned -type f -print0 | sort -z | xargs -0 sha256sum); }
manifest > "$trial/before.sha256"
reject() {
  local label=$1 work=$2 sdk=$3
  if bash "$source_root/scripts/windows_stdlib_tests.sh" build "$work" "$sdk" > "$trial/$label.log" 2>&1; then
    echo "unexpected acceptance: $label" >&2; exit 1
  fi
  grep -F 'must be separate directory trees' "$trial/$label.log" >/dev/null
  manifest > "$trial/after.sha256"
  cmp "$trial/before.sha256" "$trial/after.sha256"
  printf 'PASS %s; owned markers and every SDK byte retained\n' "$label"
}
reject source-inside-workspace "$trial/owned" "$seed"
reject workspace-inside-sdk "$seed/nested" "$seed"
reject equal-workspace-sdk "$seed" "$seed"
reject absent-workspace-inside-sdk "$seed/not-created" "$seed"
test ! -e "$seed/not-created"
reject case-insensitive-ancestor "${trial^^}/OWNED" "$seed"
rm -rf "$trial"
printf '%s\n' 'Workspace overlap rejection passed; disposable regression fixtures removed.'
