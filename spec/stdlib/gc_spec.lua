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

        async_stdlib.write_source(workspace, "gc_finalizable_probe", [[
local lua = foreign import "lua.h"
local gc = import "titan.gc"

local record Probe
  marker: integer
end

local finalized_marker = 0

function new_userdata(): value
  return Probe.new(17)
end

function finalize_userdata(candidate: value): ()
  local exact = candidate as Probe
  finalized_marker = exact.marker
end

function userdata_finalized_marker(): integer
  return finalized_marker
end

function finalizable_stack_delta(
    candidate: value, callback: (value) -> ()): integer
  local top = lua.lua_gettop(L)
  gc.finalizable(candidate, callback)
  return lua.lua_gettop(L) - top
end

function rejected_stack_delta(
    candidate: value, callback: (value) -> ()): integer
  local top = lua.lua_gettop(L)
  do
    gc.finalizable(candidate, callback)
  catch
    return lua.lua_gettop(L) - top
  end
  return 1000000
end
]])
        async_stdlib.compile(workspace, "gc_finalizable_probe", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(
            layout, "gc_finalizable_probe")
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
            "TITAN_PATH_0_21=" .. quote(workspace),
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

    it("finalizes tables while preserving their exact metatables", function()
        run([[
local gc = require "titan.gc"

local finalized = {}
local first_callback_calls = 0
local marker = {}
local protection = {}
local metatable = { marker = marker, __metatable = protection }
setmetatable(metatable, {
    __newindex = function() error("metatable assignment was not raw") end,
})

local first = { kind = "explicit" }
local preexisting = { kind = "preexisting" }
setmetatable(first, metatable)
setmetatable(preexisting, metatable)
local first_callback = function(_value)
    first_callback_calls = first_callback_calls + 1
end

gc.finalizable(first, first_callback)
local future = { kind = "future" }
setmetatable(future, metatable)
local current_callback = function(value)
    finalized[#finalized + 1] = value
end
gc.finalizable(first, current_callback)
assert(getmetatable(first) == protection)
assert(debug.getmetatable(first) == metatable)
assert(debug.getmetatable(first).marker == marker)
assert(rawget(metatable, "__gc") == current_callback)

first = nil
preexisting = nil
future = nil
gc.collect()
gc.collect()
assert(first_callback_calls == 0)
assert(#finalized == 2)
local kinds = {}
for _, value in ipairs(finalized) do
    kinds[value.kind] = true
    assert(getmetatable(value) == protection)
    assert(debug.getmetatable(value) == metatable)
end
assert(kinds.explicit)
assert(kinds.future)
assert(not kinds.preexisting)
finalized = {}

local without_metatable = {}
assert(getmetatable(without_metatable) == nil)
local created_calls = 0
local created_callback = function(_value)
    created_calls = created_calls + 1
end
gc.finalizable(without_metatable, created_callback)
local created = getmetatable(without_metatable)
assert(type(created) == "table")
assert(rawget(created, "__gc") == created_callback)
without_metatable = nil
gc.collect()
gc.collect()
assert(created_calls == 1)
]])
    end)

    it("finalizes full userdata without replacing its metatable", function()
        run([[
local gc = require "titan.gc"
local probe = require "gc_finalizable_probe"

local typed_userdata = probe.new_userdata()
local nominal_metatable = debug.getmetatable(typed_userdata)
assert(type(nominal_metatable) == "table")
assert(probe.finalizable_stack_delta(
    typed_userdata, probe.finalize_userdata) == 0)
assert(debug.getmetatable(typed_userdata) == nominal_metatable)
typed_userdata = nil
gc.collect()
gc.collect()
assert(probe.userdata_finalized_marker() == 17)

local userdata = probe.new_userdata()
assert(type(userdata) == "userdata")
local marker = {}
local protection = {}
local metatable = { marker = marker, __metatable = protection }
setmetatable(metatable, {
    __newindex = function() error("metatable assignment was not raw") end,
})
debug.setmetatable(userdata, metatable)
local finalized
local first_callback_calls = 0
local first_callback = function(_value)
    first_callback_calls = first_callback_calls + 1
end

assert(probe.finalizable_stack_delta(userdata, first_callback) == 0)
local capture_seen
local current_callback_calls = 0
local weak_capture = setmetatable({}, { __mode = "v" })
local current_callback
do
    local captured = {}
    weak_capture[1] = captured
    current_callback = function(value)
        current_callback_calls = current_callback_calls + 1
        capture_seen = captured
        finalized = value
    end
end
local installed_callback = current_callback
assert(probe.finalizable_stack_delta(userdata, current_callback) == 0)
current_callback = nil
assert(getmetatable(userdata) == protection)
assert(debug.getmetatable(userdata) == metatable)
assert(debug.getmetatable(userdata).marker == marker)
assert(rawget(metatable, "__gc") == installed_callback)
installed_callback = nil
gc.collect()
assert(weak_capture[1] ~= nil)
userdata = nil
gc.collect()
gc.collect()
assert(first_callback_calls == 0)
assert(current_callback_calls == 1)
assert(type(finalized) == "userdata")
assert(getmetatable(finalized) == protection)
assert(debug.getmetatable(finalized) == metatable)
assert(capture_seen == weak_capture[1])
finalized = nil

local without_metatable = probe.new_userdata()
debug.setmetatable(without_metatable, nil)
assert(debug.getmetatable(without_metatable) == nil)
local created_calls = 0
local created_callback = function(_value)
    created_calls = created_calls + 1
end
assert(probe.finalizable_stack_delta(
    without_metatable, created_callback) == 0)
local created = debug.getmetatable(without_metatable)
assert(type(created) == "table")
assert(rawget(created, "__gc") == created_callback)
without_metatable = nil
gc.collect()
gc.collect()
assert(created_calls == 1)
]])
    end)

    it("rejects values other than tables and full userdata", function()
        run([[
local gc = require "titan.gc"
local probe = require "gc_finalizable_probe"

local captured = true
local function with_upvalue() return captured end
local light_userdata = debug.upvalueid(with_upvalue, 1)
local rejected = {
    false,
    17,
    3.5,
    "text",
    function() end,
    coroutine.create(function() end),
    light_userdata,
}
local callback = function(_) end

assert(probe.rejected_stack_delta(17, callback) == 0)

local nil_ok, nil_error = pcall(gc.finalizable, nil, callback)
assert(not nil_ok)
assert(tostring(nil_error):find(
    "expects a table or full userdata", 1, true), nil_error)

for _, value in ipairs(rejected) do
    local ok, err = pcall(gc.finalizable, value, callback)
    assert(not ok)
    assert(tostring(err):find(
        "expects a table or full userdata", 1, true), err)
end
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
