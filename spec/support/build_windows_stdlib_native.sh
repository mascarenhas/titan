#!/usr/bin/env bash
# Keep UTF-8 artifact names inside MSYS Bash, not native Make's ANSI recipes.
set -euo pipefail
if [[ ${MSYSTEM:-} != CLANG64 || $# != 1 ]]; then
  echo 'usage (native CLANG64): build_windows_stdlib_native.sh WORKSPACE' >&2
  exit 2
fi
work=$(cd "$1" && pwd)
[[ ! -L $1 && -f $work/.titan-test-owner &&
   $(cat "$work/.titan-test-owner") == titan-windows-stdlib-tests-v1 ]]
source_root=$(cd "$(dirname "$0")/../.." && pwd)
inputs="$work/cwd/spec/fixtures/stdlib/native"
policy="$work/native-flags.config"
compiler=()
while IFS= read -r -d '' word; do compiler+=("$word"); done < "$work/CC.argv"
cppflags=()
while IFS= read -r -d '' word; do cppflags+=("$word"); done < "$work/cppflags.argv"
cflags=()
while IFS= read -r -d '' word; do cflags+=("$word"); done < "$work/cflags.argv"
ldflags=()
while IFS= read -r -d '' word; do ldflags+=("$word"); done < "$work/ldflags.argv"
[[ ${compiler[0]+present} && -f $policy ]]
# Match the native runtime build's timestamp policy, checking the actual UTF-8
# output rather than asking an ANSI Make process to stat or spell its name.
needs_build() {
  local output=$1 input
  shift
  [[ -f $output ]] || return 0
  for input in "$@"; do [[ ! $input -nt $output ]] || return 0; done
  return 1
}
pending_output=
trap '[[ -z $pending_output ]] || rm -f "$pending_output"' EXIT
compile_program() {
  local source=$1 output=$2
  pending_output=$output
  "${compiler[@]}" -std=c99 -Wall -Wextra -Werror \
    ${cppflags[@]+"${cppflags[@]}"} ${cflags[@]+"${cflags[@]}"} ${ldflags[@]+"${ldflags[@]}"} -municode \
    "$(cygpath -m -C UTF8 "$source")" -o "$(cygpath -m -C UTF8 "$output")"
  [[ -f $output ]]
  pending_output=
}
recipe="$source_root/spec/support/build_windows_stdlib_native.sh"
host_child="$work/sdk/bin/process child ação 東京.exe"
if needs_build "$host_child" "$inputs/os_process_host_child.c" \
    "$inputs/os_process_host_child_windows.h" "$policy" "$recipe"; then
  compile_program "$inputs/os_process_host_child.c" "$host_child"
fi
supervisor="$work/sdk/bin/windows-test-supervisor.exe"
if needs_build "$supervisor" "$inputs/windows_test_supervisor.c" "$policy" "$recipe"; then
  compile_program "$inputs/windows_test_supervisor.c" "$supervisor"
fi
