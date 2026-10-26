#!/usr/bin/env bash
# Focused fresh-process regression; no production fixture hooks are installed.
set -euo pipefail
if [[ $(uname -s) != Linux ]]; then
  printf 'SKIP: controlled dup wrapping requires Linux syscall support\n'
  exit 0
fi
if [[ $# != 2 || $1 != /* || $2 != /* ]]; then
  printf 'usage: %s ABSOLUTE_SDK_PREFIX ABSOLUTE_NEW_OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi
sdk=$1
output=$2
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ -e $output ]]; then
  printf 'refusing to reuse an existing output directory: %s\n' "$output" >&2
  exit 2
fi
mkdir -p "$output"
env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5 \
  "$sdk/bin/lua" -E - "$root" "$output" <<'LUA'
local root, output = ...
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io".new_sync()
local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
for _, flag in ipairs({"-c", "-fPIC", "-std=c99", "-Wall", "-Wextra", "-Werror"}) do
  argv[#argv + 1] = flag
end
for _, name in ipairs({"TITAN_EXTRA_CPPFLAGS", "TITAN_EXTRA_CFLAGS"}) do
  for _, flag in ipairs(assert(cdriver.split_shell_words(os.getenv(name) or ""))) do
    argv[#argv + 1] = flag
  end
end
argv[#argv + 1] = root .. "/spec/fixtures/stdlib/native/io_transfer_dup_failure.c"
argv[#argv + 1] = "-o"
argv[#argv + 1] = output .. "/io_transfer_dup_failure.o"
local result = compiler_io:run(argv)
assert(result.ok, result.output or result.diagnostic)
LUA
# Link-time wrapping keeps the fault injection inside this child executable and
# preserves sanitizer runtime ordering without LD_PRELOAD.
env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5 \
  TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} -Wl,--wrap=dup,--wrap=close" \
  TITAN_ROCKS_ROOT="$sdk" "$sdk/bin/titanc" \
  --tree "$root/spec/fixtures/stdlib/titan" --output "$output/native" \
  --static io_transfer_failure_app -X "$output/io_transfer_dup_failure.o" \
  > "$output/build.log" 2>&1 || { cat "$output/build.log" >&2; exit 1; }
executable="$output/native/io_transfer_failure_app"
env -u TITAN_IO_DUP_FAILURE -u TITAN_IO_EXIT_PROBE \
  "$executable" > "$output/recovery.log" 2>&1 || { cat "$output/recovery.log" >&2; exit 1; }
grep -Fqx 'PASS: second-pipe failure retained write/retry/close ownership' \
  "$output/recovery.log" || { cat "$output/recovery.log" >&2; exit 1; }
grep -Fqx 'PASS: terminal close error consumed retained ownership without retry' \
  "$output/recovery.log" || { cat "$output/recovery.log" >&2; exit 1; }
grep -Fqx 'PASS: endpoint disposers returned terminal close errors without adoption' \
  "$output/recovery.log" || { cat "$output/recovery.log" >&2; exit 1; }
env -u TITAN_IO_DUP_FAILURE TITAN_IO_EXIT_PROBE=1 \
  "$executable" > "$output/exit.log" 2>&1 || { cat "$output/exit.log" >&2; exit 1; }
grep -Fqx 'PASS: exit cleanup discarded retained pipe with adoption still closed' \
  "$output/exit.log" || { cat "$output/exit.log" >&2; exit 1; }
[[ $(grep -Fxc 'PASS: staged descriptor retired' "$output/exit.log") == 1 ]] || \
  { cat "$output/exit.log" >&2; exit 1; }
cat "$output/recovery.log" "$output/exit.log"
