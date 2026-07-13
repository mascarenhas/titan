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
    local lua = phase2.host_lua()
    return quote(lua) .. " -e " .. quote(
        "package.path=\"" .. M.repo .. "/?.lua;" .. M.repo ..
        "/?/init.lua;\" .. package.path") .. " " .. quote(M.repo .. "/titanc")
end

local function net_test_source()
    local source = phase2.read(M.repo .. "/stdlib/net.titan")
    local hooks = [[
function __test_phase5_bound_port(server: Server): integer
  return uv.__test_phase5_bound_port(server.handle)
end
function __test_phase5_accept_queue_size(server: Server): integer
  return uv.__test_phase5_accept_queue_size(server.handle)
end
function __test_phase5_accept_overflow_closes(server: Server): integer
  return uv.__test_phase5_accept_overflow_closes(server.handle)
end
function __test_phase5_reset(connection: Connection)
  uv.__test_phase5_reset(connection.handle)
end
function __test_phase5_read_starts(connection: Connection): integer
  return uv.__test_phase5_read_starts(connection.handle)
end
]]
    local replaced, count = source:gsub("%-%- TITAN_NET_TEST_HOOKS",
        hooks, 1)
    assert.equals(1, count, "net.titan is missing TITAN_NET_TEST_HOOKS")
    return replaced
end

local function build_net(workspace)
    write(workspace .. "/stdlib/net.titan", net_test_source())
    local cflags = os.getenv("TITAN_TEST_EXTRA_CFLAGS") or ""
    local ldflags = os.getenv("TITAN_TEST_EXTRA_LDFLAGS") or ""
    local command = table.concat({
        "env CCACHE_DISABLE=1", "TITAN_PATH_0_11=", "TITAN_PATH=",
        "TITAN_STDLIB_PATH=" .. quote(workspace .. "/titan"),
        "TITAN_EXTRA_CPPFLAGS=''",
        "TITAN_EXTRA_CFLAGS=" .. quote(cflags),
        "TITAN_EXTRA_LDFLAGS=" .. quote(ldflags),
        compiler_command(), "--stdlib-build --tree",
        quote(workspace .. "/stdlib"), "--lua-name titan.net net",
    }, " ")
    local ok, _, output = phase2.run(command, workspace)
    assert.truthy(ok, output)
    phase2.move_compiled_module(workspace, "net")
end

-- The ordinary Phase 5 suite intentionally uses an isolated instrumented uv
-- image too: port-0 and bounded-accept checks need private counters without
-- expanding the production net API.
local PHASE5_TRANSFORMER =
    "spec/support/make_phase5_test_variant.lua"

local function cached_workspace(transformer)
    return phase2.cached_workspace("phase5-net:" .. transformer, function()
        local workspace = phase2.variant_workspace(transformer)
        build_net(workspace)
        return workspace
    end)
end

function M.workspace(_label)
    return cached_workspace(PHASE5_TRANSFORMER)
end

function M.variant_workspace(transformer)
    return cached_workspace(transformer)
end

function M.copy_fixture(workspace, fixture, modname)
    write(workspace .. "/src/" .. modname .. ".titan",
        phase2.read(M.repo .. "/spec/fixtures/uv/phase5/" .. fixture))
end

function M.compile(workspace, modname, options)
    options = options or {}
    options.stdlib = options.stdlib or workspace .. "/titan"
    return phase2.compile(workspace, modname, options)
end

M.cleanup = phase2.cleanup
M.read = phase2.read
M.run = phase2.run
M.lua_command = phase2.variant_lua_command
M.variant_lua_command = phase2.variant_lua_command
M.repo = phase2.repo
return M
