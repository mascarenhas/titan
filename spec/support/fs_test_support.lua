local lfs = require "lfs"
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

local M = {}

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

function M.workspace(label)
    local workspace = async_stdlib.workspace("fs-" .. label)
    local root = workspace .. "/data"
    assert.truthy(lfs.mkdir(root))
    return workspace, root
end

function M.copy_fixture(workspace, fixture, modname)
    write(workspace .. "/src/" .. modname .. ".titan",
        async_stdlib.read(M.repo ..
            "/spec/fixtures/stdlib/fs/" .. fixture))
end

function M.compile(workspace, modname, options)
    local standard = async_stdlib.standard_dir()
    assert.truthy(lfs.attributes(standard .. "/fs.so"),
        "fs specs require prebuilt fs.so; run make stdlib first")
    options = options or {}
    options.stdlib = options.stdlib or standard
    return async_stdlib.compile(workspace, modname, options)
end

function M.lua_command(workspace, script, ...)
    return async_stdlib.lua_command(workspace, script, ...)
end

function M.variant_workspace(transformer)
    local workspace = async_stdlib.variant_workspace(transformer)
    local root = workspace .. "/data"
    assert.truthy(lfs.mkdir(root))

    -- Build fs only after the transformed uv DSO exists. Dependencies use the
    -- private compiled-module boundary even when their sources are visible.
    local raw_lua = async_stdlib.host_lua()
    write(workspace .. "/titan/fs.titan",
        async_stdlib.read(M.repo .. "/titan/fs.titan"))
    local variant_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS") or ""
    local variant_ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or ""
    local compiler = quote(raw_lua) .. " -e " .. quote(
        "package.path=\"" .. M.repo .. "/?.lua;" .. M.repo ..
        "/?/init.lua;\" .. package.path") .. " " .. quote(M.repo .. "/titanc")
    local command = table.concat({
        "env CCACHE_DISABLE=1",
        "TITAN_PATH_0_11=" .. quote(workspace), "TITAN_PATH=",
        "TITAN_EXTRA_CPPFLAGS=''",
        "TITAN_EXTRA_CFLAGS=" .. quote(variant_cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(variant_ldflags), compiler,
        "--tree", quote(workspace), "titan.fs",
    }, " ")
    local ok, _, output = async_stdlib.run(command, workspace)
    assert.truthy(ok, output)
    return workspace, root
end

M.cleanup = async_stdlib.cleanup
M.run = async_stdlib.run
M.variant_lua_command = async_stdlib.variant_lua_command
M.repo = async_stdlib.repo
return M
