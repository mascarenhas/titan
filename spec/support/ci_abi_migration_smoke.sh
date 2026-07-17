#!/usr/bin/env bash

# Prove the supported upgrade boundary for Lua's compiled-in Titan C path.
# The prepare phase gives one disposable prefix a genuinely ABI-0.15-configured
# Lua and LuaRocks, then advances that same prefix through the required 0.16
# `make lua` and `make luarocks` steps. The verify phase runs after the first
# 0.16 rock install and proves that bare native support is found without path
# overrides.

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
provider="$PREFIX/lib/titan/0.16/titan.so"

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
        TITAN_ABI_VERSION=0.15
    make luarocks PREFIX="$PREFIX" LUA_PLATFORM="$platform" \
        TITAN_ABI_VERSION=0.15
    assert_configured_abi 0.15 0.16

    # The dependency cache can contain the preceding commit's registered Titan
    # rock and direct, manifest-external shims. Remove only those known
    # Titan-owned entries from this disposable prefix so the later normal rock
    # build is genuinely its first 0.16 Titan install.
    if clean_lua "$PREFIX/bin/luarocks" show titan >/dev/null 2>&1; then
        clean_lua "$PREFIX/bin/luarocks" remove titan --force
    fi
    for module in coroutine uv async timer fs net os; do
        rm -f "$PREFIX/share/lua/5.5/titan/$module.lua"
    done
    rm -f "$PREFIX/share/lua/5.5/titan.lua" \
        "$PREFIX/lib/lua/5.5/titan.so"
    if clean_lua "$PREFIX/bin/luarocks" show titan >/dev/null 2>&1; then
        echo "cached Titan rock remained registered after removal" >&2
        exit 1
    fi
    test ! -e "$provider"

    make lua PREFIX="$PREFIX" LUA_PLATFORM="$platform"
    make luarocks PREFIX="$PREFIX" LUA_PLATFORM="$platform"
    assert_configured_abi 0.16 0.15
    exit 0
fi

test -f "$provider"
TITAN_EXPECTED_PROVIDER="$provider" clean_lua "$lua" -E -e '
    local expected = assert(os.getenv("TITAN_EXPECTED_PROVIDER"))
    local found = assert(package.searchpath("titan", package.cpath))
    assert(found == expected, found .. " ~= " .. expected)
    local titan = require "titan"
    assert(type(titan) == "table")
    assert(type(titan.backtrace) == "function")
    assert(type(titan._loadlibglobal) == "function")
'
