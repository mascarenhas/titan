#!/usr/bin/env bash

# Exercise the installed system libuv and the pinned bundled archive through
# the production standard-library images. The caller builds the owned process
# fixture once and passes it through TITAN_PROCESS_SMOKE_CHILD.

set -euo pipefail

: "${TITAN_PROCESS_SMOKE_CHILD:?set TITAN_PROCESS_SMOKE_CHILD to the process smoke fixture}"

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

check_aliases() {
    local module
    for module in uv timer fs net os; do
        test -L "titan/$module.so"
        test "$(readlink "titan/$module.so")" = "../$module.so"
    done
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

    dependencies=$(inspect_dependencies uv.so)
    case "$expected" in
        present)
            grep -i libuv <<<"$dependencies"
            ;;
        absent)
            if grep -qi libuv <<<"$dependencies"; then
                echo "bundled uv.so unexpectedly has a dynamic libuv dependency" >&2
                exit 1
            fi
            ;;
        *)
            echo "unknown dependency expectation: $expected" >&2
            exit 2
            ;;
    esac

    for module in timer fs net os; do
        dependencies=$(inspect_dependencies "$module.so")
        if grep -qi libuv <<<"$dependencies"; then
            echo "$module.so unexpectedly has a dynamic libuv dependency" >&2
            exit 1
        fi
    done
}

run_mode_smoke() {
    local mode=$1

    if [[ $mode == system ]]; then
        env TITAN_STDLIB_PATH="$PWD" LUA_CPATH="$PWD/?.so;;" \
            .lua/bin/lua -e 'local uv = require "titan.uv"; local timer = require "titan.timer"; local fs = require "titan.fs"; local net = require "titan.net"; local path = os.tmpname(); os.remove(path); local task = uv.run(function() timer.sleep(0); fs.write_file(path, "system\0uv"); assert(fs.read_file(path) == "system\0uv"); fs.unlink(path); return true end); uv.loop(); assert(task:join()); assert(type(uv.version()) == "string"); assert(type(net) == "userdata")'
    else
        env TITAN_STDLIB_PATH="$PWD" LUA_CPATH="$PWD/?.so;;" \
            .lua/bin/lua -e 'local uv = require "titan.uv"; local timer = require "titan.timer"; local fs = require "titan.fs"; local net = require "titan.net"; local path = os.tmpname(); os.remove(path); local task = uv.run(function() timer.yield(); fs.write_file(path, "bundled"); local data = fs.read_file(path); fs.unlink(path); return data end); uv.loop(); assert(task:join() == "bundled"); assert(type(net) == "userdata")'
    fi

    env TITAN_STDLIB_PATH="$PWD" LUA_CPATH="$PWD/?.so;;" \
        .lua/bin/lua spec/fixtures/libuv/net_production_smoke.lua "$mode"
    env TITAN_STDLIB_PATH="$PWD" LUA_CPATH="$PWD/?.so;;" \
        .lua/bin/lua spec/fixtures/libuv/os_production_smoke.lua "$mode" \
        "$TITAN_PROCESS_SMOKE_CHILD"
}

LIBUV_MODE=system make stdlib
run_mode_smoke system
check_aliases
check_libuv_dependency present

# Finish in the normal bundled configuration so the prepared Linux artifact
# is ready for every isolated test shard without another standard-library
# rebuild.
LIBUV_MODE=bundled make stdlib
run_mode_smoke bundled
check_libuv_dependency absent
