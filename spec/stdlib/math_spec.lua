-- Public titan.math behavior is a standard-library integration suite and runs
-- outside LuaCov.  It builds an exact private provider so the spec exercises
-- the checked-in source without mutating the shared standard image.
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

local TYPED_PROBE = [[
local math = import "titan.math"

function results(): (float, float, float, integer, float, float,
                     boolean, integer)
  local mantissa, exponent = math.frexp(12.0)
  local integral, fractional = math.modf(-3.25)
  local parsed: value? = math.tonumber("0x2a")
  return math.abs(-2), math.ceil(2.25), mantissa, exponent,
         integral, fractional, math.ult(-1, 0),
         (parsed as value) as integer
end
]]

describe("titan.math", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("math")
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.write_source(
            workspace, "titan.math", async_stdlib.read("titan/math.titan"))
        async_stdlib.compile(workspace, "titan.math", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.math")
        async_stdlib.write_source(workspace, "math_typed_probe", TYPED_PROBE)
        async_stdlib.compile(workspace, "math_typed_probe", {
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
            "TITAN_PATH_0_22=" .. quote(workspace),
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

    it("exposes the typed C-backed surface and constants", function()
        run([[
            local m = require "titan.math"
            local probe = require "math_typed_probe"
            local absolute, ceiling, mantissa, exponent,
                  integral, fractional, unsigned_less, parsed = probe.results()
            assert(absolute == 2.0 and math.type(absolute) == "float")
            assert(ceiling == 3.0 and math.type(ceiling) == "float")
            assert(mantissa == 0.75 and exponent == 4)
            assert(integral == -3.0 and fractional == -0.25)
            assert(not unsigned_less and parsed == 42)

            assert(m.pi == math.pi)
            assert(m.huge == math.huge)
            assert(m.maxinteger == math.maxinteger)
            assert(m.mininteger == math.mininteger)
            assert(m.abs(-m.huge) == m.huge)
            local square_root_nan = m.sqrt(-1.0)
            local remainder_nan = m.fmod(1.0, 0.0)
            assert(square_root_nan ~= square_root_nan)
            assert(remainder_nan ~= remainder_nan)
            local has_type = pcall(function() return m.type end)
            assert(not has_type)

            assert(m.acos(0.5) == math.acos(0.5))
            assert(m.asin(0.5) == math.asin(0.5))
            assert(m.atan(1.0) == math.atan(1.0))
            assert(m.atan(1.0, -1.0) == math.atan(1.0, -1.0))
            assert(m.cos(0.25) == math.cos(0.25))
            assert(m.deg(math.pi) == 180.0)
            assert(m.exp(1.0) == math.exp(1.0))
            assert(m.floor(-2.25) == -3.0)
            assert(m.fmod(-5.5, 2.0) == math.fmod(-5.5, 2.0))
            assert(m.ldexp(0.75, 4) == 12.0)
            assert(m.log(64.0, 2.0) == 6.0)
            assert(m.log(100.0, 10.0) == 2.0)
            assert(m.log2(64.0) == 6.0)
            assert(m.log10(100.0) == 2.0)
            assert(m.max(-3, 8, 2) == 8.0)
            assert(m.min(-3, 8, 2) == -3.0)
            assert(math.type(m.max(-3, 8, 2)) == "float")
            assert(m.rad(180.0) == math.pi)
            assert(m.sin(0.25) == math.sin(0.25))
            assert(m.sqrt(81.0) == 9.0)
            assert(m.tan(0.25) == math.tan(0.25))
            assert(m.ult(0, -1) and not m.ult(-1, 0))
            assert(m.tointeger(3.0) == 3)
            assert(m.tointeger("4.0") == 4)
            assert(m.tointeger(3.5) == nil)
        ]])
    end)

    it("ports Lua 5.5 xoshiro256-star-star exactly", function()
        run([[
            local m = require "titan.math"
            local function same(actual, expected)
                assert(actual == expected)
                assert(math.type(actual) == math.type(expected))
            end

            math.randomseed(0x123456789abcdef, -77)
            m.randomseed(0x123456789abcdef, -77)
            for _ = 1, 24 do same(m.random(), math.random()) end

            math.randomseed(-1, math.maxinteger)
            m.randomseed(-1, math.maxinteger)
            for _ = 1, 24 do same(m.random(0), math.random(0)) end

            math.randomseed(101, 202)
            m.randomseed(101, 202)
            for _ = 1, 24 do
                same(m.random(17), math.random(17))
                same(m.random(-30, 40), math.random(-30, 40))
                same(m.random(math.mininteger, math.maxinteger),
                     math.random(math.mininteger, math.maxinteger))
            end

            local first, second = m.randomseed(55, 66)
            assert(first == 55 and second == 66)
            local sequence = {m.random(0), m.random(0), m.random(0)}
            m.randomseed(first, second)
            for index = 1, #sequence do
                assert(m.random(0) == sequence[index])
            end
        ]])
    end)

    it("parses bounded Lua numerals and explicit bases", function()
        run([[
            local m = require "titan.math"
            local cases = {
                0, 2.0, -3.5, "", " ", "+", "-", "0", "-0", "+17",
                "  -42  ", "9223372036854775807",
                "-9223372036854775808", "9223372036854775808",
                "-9223372036854775809", "1.5", ".5", "4.", "1e2",
                "1e-4000", "1e4000", "0x0", "0xffffffffffffffff",
                "-0xffffffffffffffff", "0x10000000000000000",
                "0x1.8p1", "-0x1p-2", "0x1.2", "nan", "inf", "-inf",
                "1e", "0x", "0xp1", "1 2", "1\0",
            }
            for _, candidate in ipairs(cases) do
                local actual = m.tonumber(candidate)
                local expected = tonumber(candidate)
                assert(actual == expected or
                       (actual ~= actual and expected ~= expected))
                assert(math.type(actual) == math.type(expected))
            end

            for base = 2, 36 do
                for _, candidate in ipairs{
                    "0", "10", "-10", "+Z", " z ", "123xyz", "",
                } do
                    assert(m.tonumber(candidate, base) ==
                           tonumber(candidate, base))
                end
            end

            assert(math.type(m.tonumber(7)) == "integer")
            assert(math.type(m.tonumber(7.0)) == "float")

            local previous = os.setlocale(nil, "numeric")
            local selected = os.setlocale("de_DE.UTF-8", "numeric") or
                             os.setlocale("de_DE.utf8", "numeric")
            if selected then
                local converted = m.tonumber("1.5")
                local hexadecimal = m.tonumber("0x1.8p1")
                os.setlocale(previous, "numeric")
                assert(converted == 1.5 and hexadecimal == 3.0)
            end
        ]])
    end)

    it("rejects invalid typed ranges and base requests", function()
        run([[
            local m = require "titan.math"
            local ok, message = pcall(m.random, 5, 4)
            assert(not ok and message:find("random interval is empty", 1, true))
            ok, message = pcall(m.random, nil, 4)
            assert(not ok and
                   message:find("random lower limit is required", 1, true))
            ok, message = pcall(m.randomseed, nil, 4)
            assert(not ok and message:find(
                "randomseed first component is required", 1, true))
            ok, message = pcall(m.tonumber, "10", 1)
            assert(not ok and message:find("base out of range", 1, true))
            ok, message = pcall(m.tonumber, 10, 10)
            assert(not ok and message:find(
                "base conversion requires a string", 1, true))
            assert(not pcall(m.ldexp, 1.0, math.maxinteger))
            assert(not pcall(m.max, "not a number"))
        ]])
    end)
end)
