local lfs = require "lfs"
local assert = require "luassert"
local phase2 = require "spec.support.phase2"

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
    local workspace = phase2.workspace("phase3-fs-" .. label)
    local root = workspace .. "/data"
    assert.truthy(lfs.mkdir(root))
    return workspace, root
end

function M.copy_fixture(workspace, fixture, modname)
    write(workspace .. "/src/" .. modname .. ".titan",
        phase2.read(M.repo ..
            "/spec/fixtures/uv/phase3/" .. fixture))
end

function M.compile(workspace, modname, options)
    local standard = phase2.standard_dir()
    assert.truthy(lfs.attributes(standard .. "/fs.so"),
        "Phase 3 specs require prebuilt fs.so; run make stdlib first")
    options = options or {}
    options.stdlib = options.stdlib or standard
    return phase2.compile(workspace, modname, options)
end

function M.lua_command(workspace, script, ...)
    return phase2.lua_command(workspace, script, ...)
end

function M.variant_workspace(transformer)
    local workspace = phase2.variant_workspace(transformer)
    local root = workspace .. "/data"
    assert.truthy(lfs.mkdir(root))

    -- Build fs only after the transformed uv DSO exists. Keeping uv.titan out
    -- of src forces this through the private compiled-module boundary.
    write(workspace .. "/stdlib/fs.titan",
        phase2.read(M.repo .. "/stdlib/fs.titan"))
    local raw_lua = lfs.attributes(M.repo .. "/.lua/bin/lua") and
        M.repo .. "/.lua/bin/lua" or M.repo .. "/lua"
    local variant_cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS") or ""
    local variant_ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or ""
    local compiler = quote(raw_lua) .. " -e " .. quote(
        "package.path=\"" .. M.repo .. "/?.lua;" .. M.repo ..
        "/?/init.lua;\" .. package.path") .. " " .. quote(M.repo .. "/titanc")
    local command = table.concat({
        "env CCACHE_DISABLE=1", "TITAN_PATH_0_11=", "TITAN_PATH=",
        "TITAN_STDLIB_PATH=" .. quote(workspace),
        "TITAN_EXTRA_CPPFLAGS=''",
        "TITAN_EXTRA_CFLAGS=" .. quote(variant_cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(variant_ldflags), compiler,
        "--stdlib-build --tree", quote(workspace .. "/stdlib"),
        "--lua-name titan.fs fs",
    }, " ")
    local ok, _, output = phase2.run(command, workspace)
    assert.truthy(ok, output)
    ok, _, output = phase2.run("ln -s ../fs.so titan/fs.so", workspace)
    assert.truthy(ok, output)
    return workspace, root
end

M.cleanup = phase2.cleanup
M.read = phase2.read
M.run = phase2.run
M.variant_lua_command = phase2.variant_lua_command
M.variant_app_command = phase2.variant_app_command
M.repo = phase2.repo
return M
