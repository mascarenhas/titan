#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo 'usage: check_libbacktrace_allocator.sh ALLOC_C SOURCE_HEADERS CONFIG_HEADERS NEW_OUTPUT [ORIGINAL_ALLOC_C]' >&2
  exit 2
fi
alloc=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
headers=$(cd "$2" && pwd)
config=$(cd "$3" && pwd)
output=$4
control=${5-}
script_root=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$script_root/spec/fixtures/libbacktrace/allocator_vector_probe.c
if [[ ${MSYSTEM-} == CLANG64 ]]; then
  cc=${TITAN_ALLOCATOR_TEST_CC:-clang.exe}
  # The compiler receives already converted native paths, including the quoted
  # include macro. MSYS must not rewrite any of them a second time.
  export MSYS2_ARG_CONV_EXCL='*'
else
  cc=${TITAN_ALLOCATOR_TEST_CC:-cc}
fi
for file in "$alloc" "$headers/internal.h" "$headers/backtrace.h" "$config/config.h" "$fixture"; do
  [[ -f $file ]] || { echo "Missing allocator probe input: $file" >&2; exit 2; }
done
[[ ! -e $output ]] || { echo 'Allocator probe output must be a fresh directory' >&2; exit 2; }
mkdir -p "$output/selected"
output=$(cd "$output" && pwd)
cp "$alloc" "$output/selected/alloc.c"
if [[ -n $control ]]; then
  control=$(cd "$(dirname "$control")" && pwd)/$(basename "$control")
  [[ -f $control ]] || { echo 'Missing original allocator control' >&2; exit 2; }
  mkdir "$output/original"
  cp "$control" "$output/original/alloc.c"
fi
native_path() {
  if [[ ${MSYSTEM-} == CLANG64 ]]; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
source_header_arg=$(native_path "$headers")
config_header_arg=$(native_path "$config")
fixture_arg=$(native_path "$fixture")
{
  "$cc" --version
  printf '%s\n' 'Profiles: -O0 and -O2; common flags: -std=c99 -fno-lto -g -Wall -Wextra -Werror'
  sha256sum "$alloc" "$headers/internal.h" "$headers/backtrace.h" "$config/config.h" "$fixture" "$0"
  if [[ -n $control ]]; then sha256sum "$control"; fi
} > "$output/inputs.receipt"
compile() {
  local selected=$1 destination=$2 optimization=$3 label=$4 selected_arg output_arg
  local -a arguments
  selected_arg=$(native_path "$selected")
  output_arg=$(native_path "$destination")
  case $selected_arg in *\"*|*$'\n'*|*$'\r'*) echo 'Unsafe C include path' >&2; exit 2 ;; esac
  arguments=(-std=c99 "$optimization" -fno-lto -g -Wall -Wextra -Werror
    -I "$config_header_arg" -I "$source_header_arg"
    "-DTITAN_ALLOC_SOURCE=\"$selected_arg\"" "$fixture_arg" -o "$output_arg")
  printf '%q ' "$cc" "${arguments[@]}" > "$output/$label.compile.command"
  printf '\n' >> "$output/$label.compile.command"
  "$cc" "${arguments[@]}" \
    > "$output/$label.compile.stdout" 2> "$output/$label.compile.stderr"
}
for optimization in -O0 -O2; do
  profile=${optimization#-}
  selected=$output/allocator-$profile
  [[ ${MSYSTEM-} != CLANG64 ]] || selected=$selected.exe
  compile "$output/selected/alloc.c" "$selected" "$optimization" "$profile"
  "$selected" all > "$output/$profile.stdout" 2> "$output/$profile.stderr"
  cat "$output/$profile.stdout"
  if [[ -n $control ]]; then
    original=$output/original-$profile
    [[ ${MSYSTEM-} != CLANG64 ]] || original=$original.exe
    compile "$output/original/alloc.c" "$original" "$optimization" "original-$profile"
    for mode in growth release-failure; do
      if "$original" "$mode" > "$output/original-$profile-$mode.stdout" \
           2> "$output/original-$profile-$mode.stderr"; then
        echo "Original allocator unexpectedly passed $mode at $profile" >&2
        exit 1
      else
        status=$?
        [[ $status == 1 ]] || { echo "Original allocator control crashed: $status" >&2; exit 1; }
        case $mode in
          growth)
            grep -F -e 'allocator.calls <= limit' \
              -e 'allocator.copied_bytes <= 4u * vector.size + 65536u' \
              "$output/original-$profile-$mode.stderr" > /dev/null ;;
          release-failure)
            grep -F 'vector->base == before->base' \
              "$output/original-$profile-$mode.stderr" > /dev/null ;;
        esac
      fi
    done
  fi
done
cmp "$alloc" "$output/selected/alloc.c"
[[ -z $control ]] || cmp "$control" "$output/original/alloc.c"
echo 'Actual-source allocator regression passed at O0 and O2.'
