#!/usr/bin/env bash

# Focused sanitizer production proof for the private PEG engine and its regex
# client. The broad behavior matrix remains in the ordinary library cohort.

set -euo pipefail

PREFIX=${PREFIX:-$PWD/.lua}
if [[ $PREFIX != /* ]]; then PREFIX=$PWD/$PREFIX; fi
PREFIX=$(CDPATH= cd "$PREFIX" && pwd -P)
LUA="$PREFIX/bin/lua"
TITANC="$PREFIX/bin/titanc"
LIBRARY_ROOT="$PREFIX/lib/titan/0.6"
PROVIDER="$LIBRARY_ROOT/titan.so"
RUNTIME_ARCHIVE="$LIBRARY_ROOT/libtitan.a"

test -x "$LUA"
test -x "$TITANC"
test -f "$PROVIDER" && test ! -L "$PROVIDER"
test -f "$LIBRARY_ROOT/titan.a" && test ! -L "$LIBRARY_ROOT/titan.a"
test -f "$RUNTIME_ARCHIVE" && test ! -L "$RUNTIME_ARCHIVE"
test ! -e "$PREFIX/lib/libtitan.a"

SMOKE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/titan-peg-string-san.XXXXXX")
PROVIDER_HIDDEN="$LIBRARY_ROOT/.titan.so.peg-string-san.$$"

restore_provider() {
    if [[ -e $PROVIDER_HIDDEN || -L $PROVIDER_HIDDEN ]]; then
        mv "$PROVIDER_HIDDEN" "$PROVIDER"
    fi
}

cleanup() {
    restore_provider
    rm -rf "$SMOKE_TMP"
}
trap cleanup EXIT HUP INT TERM

env TITAN_PATH_0_6="$LIBRARY_ROOT;;" TITAN_PATH= \
    "$LUA" -E - <<'LUA'
-- The support module is the only image that opens `titan`; loading it installs
-- the Titan searcher, which then finds the combined provider modules below.
require "titan"

local peg = require "titan.peg"
local strings = require "titan.string"
assert(peg.literal("ok"):match("ok") == 3)
local found = strings.match("ab-abx", "((a|b)+)-\\1x")
assert(found and found:whole() == "ab-abx" and found:group(1) == "ab")
assert(strings.find("a\0b\0c", "\0b") == 2)
local ok, failure = pcall(strings.compile_regex, "[a-b-c]")
assert(not ok and tostring(failure):find("[bad_range]", 1, true), failure)

peg.set_max_stack(1)
local nested = string.rep("(?:", 512) .. "a" .. string.rep(")", 512)
local nested_regex = strings.compile_regex(nested)
assert(nested_regex:match("a"):whole() == "a")
peg.set_max_stack(400)

local too_deep = string.rep("(?:", 513) .. "a" .. string.rep(")", 513)
ok, failure = pcall(strings.compile_regex, too_deep)
assert(not ok and
       tostring(failure):find("[group_nesting_too_deep]", 1, true),
       failure)
LUA

cat >"$SMOKE_TMP/static_peg_string_smoke.titan" <<'TITAN'
local peg = import "peg"
local strings = import "string"

function main(_args: {string}): integer
  if #peg.version() == 0 then
    raise "private PEG engine did not initialize"
  end
  local found = strings.match("ab-abx", "((a|b)+)-\\1x")
  if not found or found:group(1) ~= "ab" then
    raise "regex backreference lost its continuation"
  end
  local first, last = strings.find("a\0b\0c", "\0b")
  if first ~= 2 or last ~= 3 then
    raise "literal binary find returned the wrong span"
  end
  local malformed = false
  do
    strings.compile_regex("[a-b-c]")
  catch
    malformed = true
  end
  if not malformed then
    raise "malformed regex unexpectedly compiled"
  end
  return 0
end
TITAN

(
    cd "$SMOKE_TMP"
    env -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5 \
        TITAN_ROOT="$PREFIX" \
        TITAN_PATH_0_6="$LIBRARY_ROOT" TITAN_PATH= \
        TITAN_RUNTIME_PREBUILT=1 \
        TITAN_EXTRA_CPPFLAGS="${TITAN_EXTRA_CPPFLAGS:-} -I$PREFIX/include -D_GNU_SOURCE" \
        TITAN_EXTRA_CFLAGS="${TITAN_EXTRA_CFLAGS:-}" \
        TITAN_EXTRA_LDFLAGS="${TITAN_EXTRA_LDFLAGS:-} -lpthread -lrt" \
        "$TITANC" --static static_peg_string_smoke
)

test -x "$SMOKE_TMP/static_peg_string_smoke"
mv "$PROVIDER" "$PROVIDER_HIDDEN"
env \
    LUA_PATH="$SMOKE_TMP/no-lua/?.lua" \
    LUA_CPATH="$SMOKE_TMP/no-lua/?.so" \
    LUA_PATH_5_5="$SMOKE_TMP/no-lua/?.lua" \
    LUA_CPATH_5_5="$SMOKE_TMP/no-lua/?.so" \
    "$SMOKE_TMP/static_peg_string_smoke"
restore_provider

echo "RESULT PEG/string sanitizer production smoke passed"
