local lfs = require "lfs"
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

local M = {}

function M.workspace(label)
    local workspace = async_stdlib.workspace("fs-" .. label)
    local root = workspace .. "/data"
    assert.truthy(lfs.mkdir(root))
    return workspace, root
end

function M.compile(workspace, modname, options)
    local standard = async_stdlib.standard_dir()
    assert.truthy(lfs.attributes(standard .. "/fs.so"),
        "fs specs require prebuilt fs.so; run make stdlib first")
    options = options or {}
    options.stdlib = options.stdlib or standard
    return async_stdlib.compile(workspace, modname, options)
end

function M.variant_workspace(transformer)
    local workspace = async_stdlib.variant_workspace(transformer)
    local root = workspace .. "/data"
    assert.truthy(lfs.mkdir(root))

    -- Build fs only after the transformed uv DSO exists. Dependencies use the
    -- private compiled-module boundary even when their sources are visible.
    async_stdlib.write_source(workspace, "titan.fs",
        async_stdlib.read(M.repo .. "/titan/fs.titan"))
    async_stdlib.compile(workspace, "titan.fs", {
        stdlib = workspace .. "/titan",
        cppflags = "",
    })
    return workspace, root
end

M.cleanup = async_stdlib.cleanup
M.run_lua_source = async_stdlib.run_lua_source
M.write_source = async_stdlib.write_source
M.repo = async_stdlib.repo
return M
