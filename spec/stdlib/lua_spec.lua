-- Public titan.lua behavior is a standard-library integration suite and runs
-- outside LuaCov.
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local prefix = os.getenv("PREFIX")
local LUA = prefix and exists(prefix .. "/bin/lua")
    and prefix .. "/bin/lua" or "lua"

local REQUIRED_TITAN_SOURCE = [[
function answer(): integer
  return 42
end
]]

describe("titan.lua", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("lua")
        async_stdlib.write_source(
            workspace, "lua_required_titan", REQUIRED_TITAN_SOURCE)
        async_stdlib.compile(workspace, "lua_required_titan")
    end)
    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run(source)
        local lua_path = workspace .. "/?.lua;;"
        local cpath = workspace .. "/?.so;;"
        local command_words = {
            "env", "-u", "LUA_PATH", "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
            "TITAN_PATH_0_22=" .. workspace,
            "TITAN_PATH=",
            "LUA_PATH=" .. lua_path,
            "LUA_PATH_5_5=" .. lua_path,
            "LUA_CPATH=" .. cpath,
            "LUA_CPATH_5_5=" .. cpath,
            LUA, "-e", source,
        }
        local quoted_words = {}
        for index, word in ipairs(command_words) do
            quoted_words[index] = quote(word)
        end
        local command = table.concat(quoted_words, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("does not leak descriptors after repeated file errors", function()
        local runtime_error = workspace .. "/dofile-runtime-error.lua"
        local syntax_error = workspace .. "/dofile-syntax-error.lua"
        run(string.format([[
local async = require "titan.async"
local tlua = require "titan.lua"
local lfs = require "lfs"

local function open_fd_count()
    local count = 0
    for entry in lfs.dir("/dev/fd") do
        if entry:match("^%%d+$") then count = count + 1 end
    end
    return count
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

write(%q, "error('runtime marker')")
write(%q, "this is not Lua")

local task = async.run(function()
    local baseline_fds = open_fd_count()
    for _ = 1, 24 do
        assert(not pcall(tlua.dofile, %q))
        assert(not pcall(tlua.dofile, %q))
    end
    local final_fds = open_fd_count()
    assert(final_fds <= baseline_fds + 2,
        ("dofile leaked descriptors: %%d -> %%d"):format(
            baseline_fds, final_fds))
end)
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(os.remove(%q))
assert(os.remove(%q))
]], runtime_error, syntax_error, runtime_error, syntax_error,
            runtime_error, syntax_error))
    end)

    it("loads Titan shims and C modules", function()
        run([[
local async = require "titan.async"
local tlua = require "titan.lua"

local task = async.run(function()
    local titan_module = tlua.require("lua_required_titan")
    assert(titan_module.answer() == 42)

    package.loaded.lfs = nil
    local lfs = tlua.require("lfs")
    assert(type(lfs.attributes) == "function")
end)
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
]])
    end)

end)
