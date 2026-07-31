-- Public titan.gc behavior is a standard-library integration suite and runs
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

describe("titan.gc", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("gc")
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.write_source(
            workspace, "titan.gc", async_stdlib.read("titan/gc.titan"))
        async_stdlib.compile(workspace, "titan.gc", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.gc")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run(source)
        local lua_path = workspace .. "/?.lua;;"
        local cpath = workspace .. "/?.so;" ..
            workspace .. "/titan-runtime/bootstrap/?.so;;"
        local command = table.concat({
            "env -u LUA_PATH -u LUA_CPATH" ..
                " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
            "TITAN_PATH_0_20=" .. quote(workspace),
            "TITAN_PATH=",
            "LUA_PATH=" .. quote(lua_path),
            "LUA_PATH_5_5=" .. quote(lua_path),
            "LUA_CPATH=" .. quote(cpath),
            "LUA_CPATH_5_5=" .. quote(cpath),
            quote(LUA) .. " -e " .. quote(source),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("marks maps weak while preserving an existing metatable", function()
        run([[
local gc = require "titan.gc"

local first = {}
local second = {}
local marker = {}
local metatable = { marker = marker }
setmetatable(metatable, {
    __newindex = function() error("metatable assignment was not raw") end,
})
setmetatable(first, metatable)
setmetatable(second, metatable)

gc.weak(first)
assert(getmetatable(first) == metatable)
assert(getmetatable(first).marker == marker)
assert(getmetatable(first).__mode == "v")
assert(getmetatable(second).__mode == "v")

do
    local object = {}
    first.object = object
end
gc.collect()
gc.collect()
assert(first.object == nil)
]])
    end)

    it("creates ephemeron metatables and collects key-value cycles", function()
        run([[
local gc = require "titan.gc"
local map = {}
gc.ephemeron(map)
assert(getmetatable(map).__mode == "k")
do
    local key = {}
    map[key] = { owner = key }
end
gc.collect()
gc.collect()
assert(next(map) == nil)
]])
    end)

    it("controls collector state, modes, steps, and byte counts", function()
        run([[
local gc = require "titan.gc"
local originally_paused = gc.paused()
local originally_incremental = gc.incremental()
if not originally_incremental then gc.generational() end

local ok, err = xpcall(function()
    gc.resume()
    assert(not gc.paused())
    assert(not gc.paused())
    gc.pause()
    assert(gc.paused())
    assert(gc.paused())
    gc.resume()
    assert(not gc.paused())

    assert(type(gc.step()) == "boolean")
    assert(type(gc.step(0)) == "boolean")
    assert(math.type(gc.count()) == "integer")
    assert(gc.count() > 0)

    gc.incremental()
    assert(gc.incremental())
    assert(not gc.generational())
    assert(gc.generational())
end, debug.traceback)

if originally_incremental then gc.incremental() else gc.generational() end
if originally_paused then gc.pause() else gc.resume() end
assert(ok, err)
]])
    end)

    it("gets, sets, and validates all collector parameters", function()
        run([[
local gc = require "titan.gc"
local accessors = {
    gc.minormul,
    gc.majorminor,
    gc.minormajor,
    gc.pause_percent,
    gc.stepmul,
    gc.stepsize,
}

local originally_incremental = gc.incremental()
local originals = {}
for index, accessor in ipairs(accessors) do
    originals[index] = accessor()
    assert(math.type(originals[index]) == "integer")
end

local ok, err = xpcall(function()
    local function round_trip_in_mode(select_mode)
        select_mode()
        for index, accessor in ipairs(accessors) do
            local original = originals[index]
            -- Both values are represented exactly by Lua's compressed GC
            -- parameter encoding and remain safe settings for every slot.
            local replacement = original == 100 and 200 or 100
            assert(accessor(replacement) == original)
            assert(accessor() == replacement)
            assert(accessor(original) == replacement)
            assert(accessor() == original)
        end
    end

    round_trip_in_mode(gc.incremental)
    round_trip_in_mode(gc.generational)

    local low_ok, low_err = pcall(gc.minormul, -1)
    assert(not low_ok)
    assert(tostring(low_err):find(
        "between 0 and 100000", 1, true), low_err)
    local high_ok, high_err = pcall(gc.stepsize, 100001)
    assert(not high_ok)
    assert(tostring(high_err):find(
        "between 0 and 100000", 1, true), high_err)
    local step_ok, step_err = pcall(gc.step, -1)
    assert(not step_ok)
    assert(tostring(step_err):find(
        "must be non-negative", 1, true), step_err)
end, debug.traceback)

local restored, restore_err = xpcall(function()
    for index, accessor in ipairs(accessors) do
        accessor(originals[index])
    end
    if originally_incremental then gc.incremental() else gc.generational() end
end, debug.traceback)
assert(restored, restore_err)
assert(ok, err)
]])
    end)
end)
