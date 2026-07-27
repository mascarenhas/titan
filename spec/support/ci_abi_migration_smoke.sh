#!/usr/bin/env bash

# Prove the supported upgrade boundary for Lua's compiled-in Titan C path.
# The prepare phase gives one disposable prefix a genuinely ABI-0.17-configured
# Lua and LuaRocks, then advances that same prefix through the required 0.18
# `make lua` and `make luarocks` steps. The verify phase runs after the first
# 0.18 rock install and proves that bare native support is found without path
# overrides while a complete predecessor 0.17 artifact tree remains byte- and
# metadata-identical.

set -euo pipefail

phase=${1:-}
platform=${2:-}
case "$phase" in
    prepare)
        if [[ -z $platform ]]; then
            echo "usage: $0 prepare <lua-platform>" >&2
            exit 2
        fi
        ;;
    verify) ;;
    *)
        echo "usage: $0 {prepare <lua-platform>|verify}" >&2
        exit 2
        ;;
esac

: "${PREFIX:?set PREFIX to a disposable absolute installation prefix}"
if [[ $PREFIX != /* ]]; then
    echo "migration smoke PREFIX must be absolute: $PREFIX" >&2
    exit 2
fi

repo=$(pwd -P)
canonical_prefix() {
    local path=$1
    local parent
    local leaf
    if [[ -d $path ]]; then
        (CDPATH= cd "$path" && pwd -P)
        return
    fi
    parent=${path%/*}
    leaf=${path##*/}
    if [[ -z $leaf || $leaf == . || $leaf == .. || ! -d $parent ]]; then
        return 1
    fi
    parent=$(CDPATH= cd "$parent" && pwd -P) || return
    printf '%s/%s\n' "${parent%/}" "$leaf"
}

requested_prefix=$PREFIX
if ! canonical=$(canonical_prefix "$requested_prefix"); then
    echo "migration smoke PREFIX needs an existing parent: " \
        "$requested_prefix" >&2
    exit 2
fi
PREFIX=$canonical
export PREFIX

case "$PREFIX" in
    "$repo" | /tmp | /private/tmp)
        echo "refusing to reconfigure disposable root itself: $PREFIX" >&2
        exit 2
        ;;
    "$repo/.lua" | /tmp/* | /private/tmp/*) ;;
    *)
        echo "refusing to reconfigure non-disposable prefix: $PREFIX" >&2
        exit 2
        ;;
esac

lua="$PREFIX/bin/lua"
provider="$PREFIX/lib/titan/0.18/titan.so"
old_tree="$PREFIX/lib/titan/0.17"
old_tree_manifest="$PREFIX/etc/titan/abi-0.17-preservation.tar"

clean_lua() {
    env \
        -u LUA_PATH \
        -u LUA_CPATH \
        -u LUA_PATH_5_5 \
        -u LUA_CPATH_5_5 \
        -u LUA_INIT \
        -u LUA_INIT_5_5 \
        -u TITAN_PATH \
        -u TITAN_PATH_0_15 \
        -u TITAN_PATH_0_16 \
        -u TITAN_PATH_0_17 \
        -u TITAN_PATH_0_18 \
        -u TITAN_ROCKS_ROOT \
        "$@"
}

assert_configured_abi() {
    local abi=$1
    local previous=$2
    local expected="$PREFIX/lib/titan/$abi/?.so"
    local stale="$PREFIX/lib/titan/$previous/?.so"

    test -x "$lua"
    TITAN_EXPECTED_CPATH="$expected" TITAN_STALE_CPATH="$stale" \
        clean_lua "$lua" -E -e '
            local cpath = package.cpath
            local expected = assert(os.getenv("TITAN_EXPECTED_CPATH"))
            local stale = assert(os.getenv("TITAN_STALE_CPATH"))
            assert(cpath:find(expected, 1, true), cpath)
            assert(not cpath:find(stale, 1, true), cpath)
        '
}

if [[ $phase == prepare ]]; then
    # Build a real old configured interpreter first. This uses the same
    # content-stamp machinery that upgrades an existing developer prefix.
    make lua PREFIX="$PREFIX" LUA_PLATFORM="$platform" \
        TITAN_ABI_VERSION=0.17
    make luarocks PREFIX="$PREFIX" LUA_PLATFORM="$platform" \
        TITAN_ABI_VERSION=0.17
    assert_configured_abi 0.17 0.18

    # The dependency cache can contain the preceding commit's registered Titan
    # rock and direct, manifest-external shims. Remove only those known
    # Titan-owned entries from this disposable prefix so the later normal rock
    # build is genuinely its first 0.18 Titan install.
    if clean_lua "$PREFIX/bin/luarocks" show titan >/dev/null 2>&1; then
        clean_lua "$PREFIX/bin/luarocks" remove titan --force
    fi
    for module in coroutine uv async timer fs net os peg string; do
        rm -f "$PREFIX/share/lua/5.5/titan/$module.lua"
    done
    rm -f "$PREFIX/share/lua/5.5/titan.lua" \
        "$PREFIX/lib/lua/5.5/titan.so"
    if clean_lua "$PREFIX/bin/luarocks" show titan >/dev/null 2>&1; then
        echo "cached Titan rock remained registered after removal" >&2
        exit 1
    fi

    # Seed a complete predecessor pair plus representative legacy layout under
    # 0.17. The 0.18 installer must never inspect, retire, or rewrite this
    # versioned tree. A tar manifest captures bytes, modes, and mtimes portably
    # on both GNU/Linux and macOS for the verify phase.
    mkdir -p "$old_tree/titan.so.dSYM/Contents/Resources/DWARF" \
        "$old_tree/titan"
    printf '%s\n' "preserved ABI 0.17 provider" > "$old_tree/titan.so"
    printf '%s\n' "preserved ABI 0.17 archive" > "$old_tree/titan.a"
    printf '%s\n' "preserved ABI 0.17 symbols" \
        > "$old_tree/titan.so.dSYM/Contents/Resources/DWARF/titan.so"
    printf '%s\n' "preserved ABI 0.17 legacy child" \
        > "$old_tree/titan/uv.so"
    chmod 0751 "$old_tree/titan.so"
    chmod 0640 "$old_tree/titan.a"
    chmod 0600 \
        "$old_tree/titan.so.dSYM/Contents/Resources/DWARF/titan.so"
    chmod 0644 "$old_tree/titan/uv.so"
    touch -t 200101010101.01 "$old_tree/titan.so"
    touch -t 200101010102.02 "$old_tree/titan.a"
    touch -t 200101010103.03 \
        "$old_tree/titan.so.dSYM/Contents/Resources/DWARF/titan.so"
    touch -t 200101010104.04 "$old_tree/titan/uv.so"
    mkdir -p "$PREFIX/etc/titan"
    tar --format=ustar -C "$PREFIX" -cpf "$old_tree_manifest" \
        lib/titan/0.17

    # The unversioned shims are the predecessor public names. Seed the exact
    # generated template so the 0.18 transaction owns and replaces them.
    mkdir -p "$PREFIX/share/lua/5.5/titan"
    clean_lua "$lua" -E - "$PREFIX/share/lua/5.5/titan" <<'LUA'
local root = assert(arg[1])
local template = [=[-- Generated by titanc; do not edit.
local path, search_error = package.searchpath("titan", package.cpath)
if not path then error(search_error, 0) end

local titan = require "titan"
local open, open_error = titan._loadlibglobal(path, %q)
if not open then error(open_error, 0) end

return open()
]=]
for _, module in ipairs({
    "coroutine", "uv", "async", "timer", "fs", "net", "os",
    "peg", "string",
}) do
    local file = assert(io.open(root .. "/" .. module .. ".lua", "wb"))
    assert(file:write(template:format("luaopen_titan_" .. module)))
    assert(file:close())
end
LUA

    test ! -e "$provider"

    make lua PREFIX="$PREFIX" LUA_PLATFORM="$platform"
    make luarocks PREFIX="$PREFIX" LUA_PLATFORM="$platform"
    assert_configured_abi 0.18 0.17
    exit 0
fi

test -f "$provider"
test -f "$old_tree_manifest"
old_tree_verify="$old_tree_manifest.verify.$$"
trap 'rm -f "$old_tree_verify"' EXIT
tar --format=ustar -C "$PREFIX" -cpf "$old_tree_verify" lib/titan/0.17
if ! cmp -s "$old_tree_manifest" "$old_tree_verify"; then
    echo "ABI-0.17 predecessor tree changed during 0.18 installation" >&2
    exit 1
fi
TITAN_EXPECTED_PROVIDER="$provider" clean_lua "$lua" -E -e '
    local expected = assert(os.getenv("TITAN_EXPECTED_PROVIDER"))
    local found = assert(package.searchpath("titan", package.cpath))
    assert(found == expected, found .. " ~= " .. expected)
    local titan = require "titan"
    assert(type(titan) == "table")
    assert(type(titan.backtrace) == "function")
    assert(type(titan._loadlibglobal) == "function")
'
