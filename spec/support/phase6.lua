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

local function compiler_command()
    local lua = lfs.attributes(M.repo .. "/lua") and
        M.repo .. "/lua" or M.repo .. "/.lua/bin/lua"
    return quote(lua) .. " -e " .. quote(
        "package.path=\"" .. M.repo .. "/?.lua;" .. M.repo ..
        "/?/init.lua;\" .. package.path") .. " " .. quote(M.repo .. "/titanc")
end

local function build_os(workspace)
    write(workspace .. "/stdlib/os.titan",
        phase2.read(M.repo .. "/stdlib/os.titan"))
    local cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS") or ""
    local ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or ""
    local command = table.concat({
        "env CCACHE_DISABLE=1", "TITAN_PATH_0_11=", "TITAN_PATH=",
        "TITAN_STDLIB_PATH=" .. quote(workspace),
        "TITAN_EXTRA_CPPFLAGS=''",
        "TITAN_EXTRA_CFLAGS=" .. quote(cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(ldflags),
        compiler_command(), "--stdlib-build --tree",
        quote(workspace .. "/stdlib"), "--lua-name titan.os os",
    }, " ")
    local ok, _, output = phase2.run(command, workspace)
    assert.truthy(ok, output)
    ok, _, output = phase2.run("ln -s ../os.so titan/os.so", workspace)
    assert.truthy(ok, output)
end

function M.workspace()
    local workspace = phase2.variant_workspace(
        "spec/support/make_phase6_test_variant.lua")
    build_os(workspace)
    return workspace
end

function M.copy_fixture(workspace, fixture, modname)
    write(workspace .. "/src/" .. modname .. ".titan",
        phase2.read(M.repo .. "/spec/fixtures/uv/phase6/" .. fixture))
end

function M.compile(workspace, modname, options)
    options = options or {}
    options.stdlib = options.stdlib or workspace
    return phase2.compile(workspace, modname, options)
end

M.cleanup = phase2.cleanup
M.read = phase2.read
M.run = phase2.run
M.lua_command = phase2.variant_lua_command
M.variant_lua_command = phase2.variant_lua_command
M.repo = phase2.repo
return M
