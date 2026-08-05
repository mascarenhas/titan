-- Public titan.iter behavior is a standard-library integration suite and runs
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

local PROBE_SOURCE = [[
local iter = import "titan.iter"

function map_summary(map: {string: integer}): (integer, integer)
  local count = 0
  local sum = 0
  for _key: string, item: integer in iter.pairs(map) do
    count = count + 1
    sum = sum + item
  end
  return count, sum
end

function false_key_survives(): boolean
  local map: {value: value} = {
    [false] = 17,
    ["other"] = 25,
  }
  local saw_false = false
  local count = 0
  for key, _item in iter.pairs(map) do
    count = count + 1
    if key is boolean and not (key as boolean) then
      saw_false = true
    end
  end
  return saw_false and count == 2
end

function array_holes(): (integer, boolean, string)
  local array: {value} = { "first", nil, "third" }
  local count = 0
  local middle_is_nil = false
  local last = ""
  for index, item in iter.ipairs(array) do
    count = count + 1
    if index == 2 then middle_is_nil = item == nil end
    if index == 3 then last = item as string end
  end
  return count, middle_is_nil, last
end

function array_trailing_hole(): (integer, integer)
  local array: {value} = { "first", "second", "third" }
  array[3] = nil
  local count = 0
  for _index, _item in iter.ipairs(array) do
    count = count + 1
  end
  return #array, count
end
]]

describe("titan.iter", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("iter")
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.write_source(
            workspace, "titan.iter", async_stdlib.read("titan/iter.titan"))
        async_stdlib.compile(workspace, "titan.iter", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.iter")
        async_stdlib.write_source(workspace, "iter_probe", PROBE_SOURCE)
        async_stdlib.compile(workspace, "iter_probe", {
            layout = layout,
            cppflags = "",
        })
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

    it("returns next, map, init, and close in generic-for order", function()
        run([[
local iter = require "titan.iter"
local empty_key, empty_item = iter.next({}, nil)
assert(empty_key == nil and empty_item == nil)

local map = { answer = 42 }
local tuple = table.pack(iter.pairs(map))
assert(tuple.n == 4)
assert(type(tuple[1]) == "function")
assert(tuple[2] == map)
assert(tuple[3] == nil and tuple[4] == nil)
local key, item = tuple[1](tuple[2], tuple[3])
assert(key == "answer" and item == 42)
assert(tuple[1](tuple[2], key) == nil)

local object_key = {}
local object_value = {}
local arbitrary = {[object_key] = object_value}
local actual_key, actual_value = iter.next(arbitrary, nil)
assert(actual_key == object_key and actual_value == object_value)
]])
    end)

    it("iterates typed maps and does not stop on a false key", function()
        run([[
local probe = require "iter_probe"
local count, sum = probe.map_summary({ a = 10, b = 20, c = 12 })
assert(count == 3 and sum == 42)
assert(probe.false_key_survives())
]])
    end)

    it("iterates through inner nil Array elements", function()
        run([[
local probe = require "iter_probe"
local count, middle_is_nil, last =
    probe.array_holes()
assert(count == 3)
assert(middle_is_nil)
assert(last == "third")
local length, shortened_count = probe.array_trailing_hole()
assert(length == 2 and shortened_count == 2)
]])
    end)

    it("preserves Lua next errors for invalid control keys", function()
        run([[
local iter = require "titan.iter"
local map = { answer = 42 }
local ok, err = pcall(iter.next, map, {})
assert(not ok)
assert(tostring(err):find("invalid key to 'next'", 1, true), err)
local key, item = iter.next(map, nil)
assert(key == "answer" and item == 42)
]])
    end)
end)
