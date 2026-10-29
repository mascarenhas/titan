local lfs = require "lfs"
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

local M = {}

function M.workspace(label)
    local workspace = async_stdlib.workspace("fs-" .. label)
    async_stdlib.refresh_private_runtime(workspace)
    local root = workspace .. "/data"
    assert.truthy(lfs.mkdir(root))
    return workspace, root
end

function M.compile(workspace, modname, options)
    local standard = async_stdlib.standard_layout()
    assert.truthy(lfs.attributes(standard.container),
        "fs specs require prebuilt titan.so; run make stdlib first")
    options = options or {}
    options.layout = options.layout or standard
    return async_stdlib.compile(workspace, modname, options)
end

M.cleanup = async_stdlib.cleanup
M.run_lua_source = async_stdlib.run_lua_source
M.write_source = async_stdlib.write_source
M.repo = async_stdlib.repo
return M
