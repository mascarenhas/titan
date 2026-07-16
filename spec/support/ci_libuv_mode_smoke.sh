#!/usr/bin/env bash

# Exercise the installed system libuv and the pinned bundled archive through
# the production standard-library images. Only titan/uv.so consumes libuv's headers
# and linker inputs; the higher-level modules import its stable Titan ABI. Keep
# those modules in place while swapping titan/uv.so so this smoke does not rebuild
# five identical DSOs in each mode. The caller builds the owned process fixture
# once and passes it through TITAN_PROCESS_SMOKE_CHILD.

set -euo pipefail

: "${TITAN_PROCESS_SMOKE_CHILD:?set TITAN_PROCESS_SMOKE_CHILD to the process smoke fixture}"

scope=${1:-both}
case "$scope" in
    both|bundled) ;;
    *)
        echo "usage: $0 [both|bundled]" >&2
        exit 2
        ;;
esac

LUA="${PREFIX:-$PWD/.lua}/bin/lua"
test -x "$LUA"

case "$(uname -s)" in
    Darwin)
        platform=macos
        export PKG_CONFIG_PATH="$(brew --prefix libuv)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        ;;
    Linux)
        platform=linux
        ;;
    *)
        echo "unsupported libuv smoke platform: $(uname -s)" >&2
        exit 2
        ;;
esac

check_canonical_modules() {
    local module
    for module in coroutine uv async timer fs net os; do
        test -f "titan/$module.so"
        test ! -L "titan/$module.so"
        test ! -e "$module.so"
        test ! -e "$module.so.dSYM"
        if [[ $platform == macos ]]; then
            test -d "titan/$module.so.dSYM"
        fi
    done
    test ! -e coro.so
    test ! -e coro.so.dSYM
}

inspect_dependencies() {
    if [[ $platform == macos ]]; then
        otool -L "$1"
    else
        readelf -d "$1"
    fi
}

check_libuv_dependency() {
    local expected=$1
    local dependencies
    local module

    dependencies=$(inspect_dependencies titan/uv.so)
    case "$expected" in
        present)
            grep -i libuv <<<"$dependencies"
            ;;
        absent)
            if grep -qi libuv <<<"$dependencies"; then
                echo "bundled titan/uv.so unexpectedly has a dynamic libuv dependency" >&2
                exit 1
            fi
            ;;
        *)
            echo "unknown dependency expectation: $expected" >&2
            exit 2
            ;;
    esac

    for module in async timer fs net os; do
        dependencies=$(inspect_dependencies "titan/$module.so")
        if grep -qi libuv <<<"$dependencies"; then
            echo "titan/$module.so unexpectedly has a dynamic libuv dependency" >&2
            exit 1
        fi
    done
}

run_mode_smoke() {
    local mode=$1

    if [[ $mode == system ]]; then
        env TITAN_PATH_0_15="$PWD" LUA_CPATH="$PWD/?.so;;" \
            "$LUA" -e 'local uv = require "titan.uv"; local async = require "titan.async"; local timer = require "titan.timer"; local fs = require "titan.fs"; local net = require "titan.net"; local path = os.tmpname(); os.remove(path); local task = async.run(function() timer.sleep(0); fs.write_file(path, "system\0uv"); assert(fs.read_file(path) == "system\0uv"); fs.unlink(path); return true end); async.loop(); assert(task:join()); assert(type(async.version()) == "string"); assert(type(uv) == "userdata"); assert(type(net) == "userdata")'
    else
        env TITAN_PATH_0_15="$PWD" LUA_CPATH="$PWD/?.so;;" \
            "$LUA" -e 'local uv = require "titan.uv"; local async = require "titan.async"; local timer = require "titan.timer"; local fs = require "titan.fs"; local net = require "titan.net"; local path = os.tmpname(); os.remove(path); local task = async.run(function() timer.yield(); fs.write_file(path, "bundled"); local data = fs.read_file(path); fs.unlink(path); return data end); async.loop(); assert(task:join() == "bundled"); assert(type(uv) == "userdata"); assert(type(net) == "userdata")'
    fi

    env TITAN_PATH_0_15="$PWD" LUA_CPATH="$PWD/?.so;;" \
        "$LUA" spec/fixtures/libuv/net_production_smoke.lua "$mode"
    env TITAN_PATH_0_15="$PWD" LUA_CPATH="$PWD/?.so;;" \
        "$LUA" spec/fixtures/libuv/os_production_smoke.lua "$mode" \
        "$TITAN_PROCESS_SMOKE_CHILD"
}

# The preceding rock build and tests leave every standard module in bundled
# mode. Exercise that image before changing any build output.
run_mode_smoke bundled
check_canonical_modules
check_libuv_dependency absent

if [[ $scope == bundled ]]; then
    exit 0
fi

# Only the uv binary boundary consumes mode-specific compile/link inputs. The
# higher-level images intentionally remain unchanged while the system-linked
# titan/uv.so replaces it. CI archives/runs the bundled suite before invoking this
# script, so the job may end here without paying for an identical rebuild.
LIBUV_MODE=system make titan/uv.so
run_mode_smoke system
check_canonical_modules
check_libuv_dependency present
