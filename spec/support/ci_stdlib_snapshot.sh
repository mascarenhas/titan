#!/usr/bin/env bash

# Some compiler specs rebuild the checkout runtime. Preserve that Make-owned
# archive plus the canonical installed standard-library provider pair, shims,
# and test-support compiler source around those groups so later production
# smokes see the exact build that the library gates tested. The source-rock hook
# owns those installed artifacts; this
# snapshot must not depend on a packaging spec having built checkout-root
# standard-library outputs as a side effect.

set -euo pipefail

mode=${1:-}
archive=${2:-}

if [[ -z $archive ]]; then
    echo "usage: $0 {save|restore} ARCHIVE" >&2
    exit 2
fi

workspace=$(pwd -P)
prefix=${PREFIX:-$workspace/.lua}
if [[ $prefix != /* ]]; then prefix=$workspace/$prefix; fi
prefix=$(CDPATH= cd "$prefix" && pwd -P)
case "$prefix" in
    "$workspace"/*) prefix_rel=${prefix#"$workspace"/} ;;
    *)
        echo "snapshot PREFIX must be inside the prepared workspace: $prefix" \
            >&2
        exit 2
        ;;
esac

provider=$prefix_rel/lib/titan/0.6/titan.so
static_archive=${provider%.so}.a
shim_dir=$prefix_rel/share/lua/5.5/titan
test_source=$prefix_rel/share/titan/0.6/src/titan/test.titan

artifacts=(
    titan-runtime/libtitan.a
    titan-runtime/.titan-runtime-archive-build-config
    "$provider"
    "$static_archive"
    "$shim_dir/coroutine.lua" "$shim_dir/uv.lua"
    "$shim_dir/async.lua" "$shim_dir/timer.lua"
    "$shim_dir/io.lua"
    "$shim_dir/fs.lua" "$shim_dir/net.lua" "$shim_dir/ssl.lua"
    "$shim_dir/url.lua" "$shim_dir/http.lua" "$shim_dir/websocket.lua" "$shim_dir/os.lua"
    "$shim_dir/peg.lua" "$shim_dir/string.lua"
    "$shim_dir/math.lua" "$shim_dir/lua.lua"
    "$shim_dir/iteration.lua" "$shim_dir/gc.lua" "$shim_dir/test.lua"
    "$shim_dir/reflect.lua" "$shim_dir/sqlite3.lua" "$shim_dir/json.lua"
    "$test_source"

)

if [[ $(uname -s) == Darwin ]]; then artifacts+=("$provider.dSYM"); fi

manifest=$archive.manifest

# Record exact contents, modes, and mtimes independently of tar's extraction
# result. LuaFileSystem is part of the prepared prefix and gives one portable
# implementation on GNU/Linux and macOS.
write_manifest() {
    local output=$1
    shift
    "$prefix/bin/lua" -E - "$output" "$@" <<'LUA'
local lfs = require "lfs"

local output = assert(arg[1])
local out = assert(io.open(output, "wb"))

local function hash_file(path)
    local file = assert(io.open(path, "rb"))
    local hash = 1469598103934665603
    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        for index = 1, #chunk do
            hash = (hash ~ chunk:byte(index)) * 1099511628211
        end
    end
    assert(file:close())
    return string.format("%016x", hash)
end

local function write_entry(path)
    local attr = assert(lfs.symlinkattributes(path), path)
    local fields = {
        attr.mode,
        attr.permissions or "",
        string.format("%.0f", attr.modification or 0),
        tostring(attr.size or 0),
        attr.mode == "file" and hash_file(path) or "-",
        path,
    }
    assert(out:write(table.concat(fields, "\t"), "\n"))

    if attr.mode == "directory" then
        local names = {}
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do write_entry(path .. "/" .. name) end
    end
end

for index = 2, #arg do write_entry(arg[index]) end
assert(out:close())
LUA
}

remove_installed_artifacts() {
    rm -rf "$provider" "$provider.dSYM"
    rm -f "$static_archive"
    rm -f "$shim_dir/coroutine.lua" "$shim_dir/uv.lua" \
        "$shim_dir/async.lua" "$shim_dir/timer.lua" \
        "$shim_dir/io.lua" \
        "$shim_dir/fs.lua" "$shim_dir/net.lua" "$shim_dir/ssl.lua" \
        "$shim_dir/url.lua" "$shim_dir/http.lua" "$shim_dir/websocket.lua" "$shim_dir/os.lua" \
        "$shim_dir/peg.lua" "$shim_dir/string.lua" \
        "$shim_dir/math.lua" "$shim_dir/lua.lua" \
        "$shim_dir/iteration.lua" "$shim_dir/gc.lua" "$shim_dir/test.lua" \
        "$shim_dir/reflect.lua" "$shim_dir/sqlite3.lua" "$shim_dir/json.lua"
    rm -f "$test_source"

}

case "$mode" in
    save)
        for artifact in "${artifacts[@]}"; do
            if [[ ! -e $artifact ]]; then
                echo "cannot snapshot missing prepared artifact: $artifact" >&2
                exit 1
            fi
        done
        write_manifest "$manifest" "${artifacts[@]}"
        tar -cpf "$archive" "${artifacts[@]}"
        ;;
    restore)
        if [[ ! -f $archive || ! -f $manifest ]]; then
            echo "cannot restore stdlib snapshot without archive and manifest" \
                >&2
            exit 1
        fi
        remove_installed_artifacts
        tar -xpf "$archive"
        for artifact in "${artifacts[@]}"; do
            if [[ ! -e $artifact ]]; then
                echo "restored stdlib snapshot is missing: $artifact" >&2
                exit 1
            fi
        done
        restored_manifest=$manifest.restored.$$
        write_manifest "$restored_manifest" "${artifacts[@]}"
        if ! cmp -s "$manifest" "$restored_manifest"; then
            echo "restored stdlib snapshot changed content, mode, or mtime" >&2
            diff -u "$manifest" "$restored_manifest" >&2 || true
            rm -f "$restored_manifest"
            exit 1
        fi
        rm -f "$restored_manifest"
        ;;
    *)
        echo "usage: $0 {save|restore} ARCHIVE" >&2
        exit 2
        ;;
esac
