local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

local REPO = async_stdlib.repo
local LPEGLABEL_ARCHIVE =
    REPO .. "/lpeglabel-build/libtitan-lpeglabel.a"
local LPEGLABEL_CPPFLAGS = "-I" .. REPO .. "/vendor/lpeglabel"

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
local str = import "titan.string"

local observed = ""

local function mark(text: string): value
  observed = observed .. text
  return text
end

function omitted(): string
  return str.tostring()
end

function one(candidate: value): string
  return str.tostring(candidate)
end

function surplus(candidate: value): (string, string)
  observed = ""
  local converted =
    str.tostring(candidate, mark("left"), mark("right"))
  return converted, observed
end
]]

describe("titan.string", function()
    local workspace
    local layout

    setup(function()
        assert.truthy(exists(LPEGLABEL_ARCHIVE),
            "run make lpeglabel before titan.string specs")
        workspace = async_stdlib.workspace("string-core")
        for _, name in ipairs({
            "peg", "native", "combinators", "captures",
            "relabel", "relabel_parser",
        }) do
            async_stdlib.write_source(
                workspace, "titan.peg." .. name,
                async_stdlib.read("titan/peg/" .. name .. ".titan"))
        end
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.compile(workspace, "titan.peg", {
            layout = layout,
            cppflags = LPEGLABEL_CPPFLAGS,
            extra_objects = { LPEGLABEL_ARCHIVE },
        })
        async_stdlib.register_exact_provider(layout, "titan.peg")

        for _, name in ipairs({
            "string", "bytes", "format", "pack",
            "regex_api", "regex_compile", "regex_parser",
        }) do
            async_stdlib.write_source(
                workspace, "titan.string." .. name,
                async_stdlib.read(
                    "titan/string/" .. name .. ".titan"))
        end
        async_stdlib.compile(workspace, "titan.string", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.string")

        async_stdlib.write_source(
            workspace, "string_core_probe", PROBE_SOURCE)
        async_stdlib.compile(workspace, "string_core_probe", {
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
            "TITAN_PATH_0_18=" .. quote(workspace),
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

    it("matches Lua 5.5 byte operations over binary strings and indices",
    function()
        run([[
            assert(os.setlocale("C", "ctype"))
            local native = string
            local str = require "titan.string"
            assert(require("string") == native)
            assert(_G.string == native)

            local subjects = {
                "",
                "abc",
                "a\0b",
                native.char(0, 65, 90, 97, 122, 127, 128, 255),
                native.rep("ab\0", 40),
            }
            local positions = {
                math.mininteger, -1000, -5, -1, 0,
                1, 2, 5, 1000, math.maxinteger,
            }

            local function same_results(actual, expected, ...)
                local left = table.pack(actual(...))
                local right = table.pack(expected(...))
                assert(left.n == right.n,
                    ("result count %d ~= %d"):format(left.n, right.n))
                for index = 1, left.n do
                    assert(left[index] == right[index],
                        ("result %d differs"):format(index))
                end
            end

            for _, subject in ipairs(subjects) do
                assert(str.len(subject) == native.len(subject))
                assert(str.reverse(subject) == native.reverse(subject))
                assert(str.lower(subject) == native.lower(subject))
                assert(str.upper(subject) == native.upper(subject))
                for _, first in ipairs(positions) do
                    assert(str.sub(subject, first) ==
                           native.sub(subject, first))
                    same_results(str.byte, native.byte, subject, first)
                    for _, last in ipairs(positions) do
                        assert(str.sub(subject, first, last) ==
                               native.sub(subject, first, last))
                        same_results(
                            str.byte, native.byte, subject, first, last)
                    end
                end
            end

            assert(str.sub("a\0bc\0d", 2, 5) == "\0bc\0")
            assert(str.reverse("a\0bc") == "cb\0a")
            assert(select("#", str.byte("abc", 0)) == 0)
            assert(select("#", str.byte("abc", -1000)) == 0)
            assert(select("#",
                str.byte("x", math.maxinteger, math.maxinteger)) == 0)
        ]])
    end)

    it("finds literal byte strings with binary-safe Lua position semantics",
    function()
        run([[
            local native = string
            local str = require "titan.string"
            local subjects = {
                "", "abcabc", "a\0b\0c", native.char(0, 255, 0, 255),
            }
            local needles = {
                "", "a", "abc", "\0", "\0b", native.char(255, 0), "missing",
            }
            local positions = {
                math.mininteger, -1000, -5, -1, 0,
                1, 2, 5, 1000, math.maxinteger,
            }

            for _, subject in ipairs(subjects) do
                for _, needle in ipairs(needles) do
                    for _, position in ipairs(positions) do
                        local actual =
                            table.pack(str.find(subject, needle, position))
                        local expected =
                            table.pack(native.find(
                                subject, needle, position, true))
                        assert(actual.n == 2)
                        for index = 1, 2 do
                            assert(actual[index] == expected[index])
                        end
                    end
                end
            end

            local found = table.pack(str.find("a\0b\0c", "\0b"))
            assert(found.n == 2 and found[1] == 2 and found[2] == 3)
            local missing = table.pack(str.find("abc", "z"))
            assert(missing.n == 2 and missing[1] == nil and
                   missing[2] == nil)
            assert(not pcall(str.find, 42, "2"))
            assert(not pcall(str.find, "42", 2))
            assert(not pcall(str.find, "42", "2", 1.5))
        ]])
    end)

    it("matches repeat and byte construction including checked failures",
    function()
        run([[
            local native = string
            local str = require "titan.string"
            local subjects = { "", "x", "a\0b", native.rep("z", 64) }
            local separators = { "", "-", "\0" }
            local counts = { -5, 0, 1, 2, 7 }

            for _, subject in ipairs(subjects) do
                for _, separator in ipairs(separators) do
                    for _, count in ipairs(counts) do
                        assert(str.rep(subject, count, separator) ==
                               native.rep(subject, count, separator))
                    end
                end
            end

            assert(str.rep("ab", 3) == "ababab")
            assert(str.rep("", math.maxinteger, "") == "")
            local ok, err = pcall(str.rep, "xx", math.maxinteger)
            assert(not ok)
            assert(tostring(err):find(
                "resulting string is too large", 1, true), tostring(err))

            assert(str.char() == "")
            assert(str.char(0, 65, 127, 128, 255) ==
                   native.char(0, 65, 127, 128, 255))
            for _, invalid in ipairs({ -1, 256, math.mininteger,
                                        math.maxinteger }) do
                ok, err = pcall(str.char, invalid)
                assert(not ok)
                assert(tostring(err):find(
                    "character value out of range", 1, true), tostring(err))
            end
        ]])
    end)

    it("enforces typed Lua boundaries and the 200-value limit", function()
        run([[
            local str = require "titan.string"

            assert(str.sub("abc", 1.0, 2.0) == "ab")
            assert(str.rep("x", 2.0) == "xx")
            assert(str.char(65.0) == "A")

            local rejected = {
                function() return str.len(123) end,
                function() return str.reverse(123) end,
                function() return str.sub("abc", 1.5) end,
                function() return str.rep("x", "2") end,
                function() return str.rep("x", 2, 9) end,
                function() return str.byte("abc", math.huge) end,
                function() return str.char(65.5) end,
                function() return str.char("65") end,
            }
            for _, attempt in ipairs(rejected) do
                assert(not pcall(attempt))
            end

            local octets = {}
            for index = 1, 201 do
                octets[index] = (index - 1) % 256
            end
            local built = str.char(table.unpack(octets, 1, 200))
            assert(#built == 200)
            local returned = table.pack(str.byte(built, 1, 200))
            assert(returned.n == 200)
            for index = 1, 200 do
                assert(returned[index] == octets[index])
            end

            local ok, err = pcall(function()
                return str.char(table.unpack(octets, 1, 201))
            end)
            assert(not ok)
            assert(tostring(err):find(
                "too many variadic arguments", 1, true), tostring(err))

            ok, err = pcall(function()
                return str.byte(string.rep("x", 201), 1, 201)
            end)
            assert(not ok)
            assert(tostring(err):find(
                "too many flexible return values", 1, true), tostring(err))
        ]])
    end)

    it("uses fixed-call adjustment for tostring and restores conversion state",
    function()
        run([[
            local str = require "titan.string"
            local probe = require "string_core_probe"
            local native_tostring = _G.tostring

            assert(str.tostring() == "nil")
            assert(str.tostring(nil) == "nil")
            assert(probe.omitted() == "nil")
            assert(probe.one(false) == "false")
            local converted, observed = probe.surplus(42)
            assert(converted == "42")
            assert(observed == "leftright")

            local direct_seen = ""
            local function extra(text)
                direct_seen = direct_seen .. text
                return text
            end
            assert(str.tostring(17, extra("a"), extra("b")) == "17")
            assert(direct_seen == "ab")

            local object = setmetatable({}, {
                __tostring = function()
                    return "custom\0text"
                end,
            })
            assert(str.tostring(object) == "custom\0text")

            _G.tostring = function() return "replaced" end
            local independent = str.tostring(73)
            _G.tostring = native_tostring
            assert(independent == "73")

            local bad = setmetatable({}, {
                __tostring = function()
                    error("conversion failed")
                end,
            })
            local ok, err = pcall(str.tostring, bad)
            assert(not ok)
            assert(native_tostring(err):find(
                "conversion failed", 1, true), native_tostring(err))
            for index = 1, 100 do
                assert(str.tostring(index) == native_tostring(index))
            end
        ]])
    end)

    it("matches Lua 5.5 formatting and restores failed conversions",
    function()
        run([[
            assert(os.setlocale("C", "all"))
            local native = string
            local str = require "titan.string"

            local cases = {
                table.pack("literal %% tail"),
                table.pack("%c|%5c|%-5c", 65, 66, 67),
                table.pack("%d|%+08i|%u|%#o|%#08x|%X",
                           math.mininteger, -42, -1, 10, 255, -1),
                table.pack("%a|%A|%.3e|%10.2f|%g|%G",
                           1.5, -0.0, 1 / 3, 1 / 3,
                           math.huge, 0 / 0),
                table.pack("%p|%15p", nil, {}),
                table.pack("%q|%q|%q|%q|%q|%q",
                           "a\0b\n\"\\\1", math.mininteger,
                           math.huge, -math.huge, false, nil),
                table.pack("%s|%10s|%.2s|%s",
                           true, "abc", "abcd",
                           native.rep("long", 40)),
                table.pack("%d %s %q", "42", 123.5, "x"),
            }

            for index, case in ipairs(cases) do
                local expected = native.format(
                    case[1], table.unpack(case, 2, case.n))
                local actual = str.format(
                    case[1], table.unpack(case, 2, case.n))
                assert(actual == expected,
                    ("format case %d differs"):format(index))
            end

            local object = setmetatable({}, {
                __tostring = function() return "custom\0text" end,
            })
            assert(str.format("%s", object) ==
                   native.format("%s", object))

            local bad = setmetatable({}, {
                __tostring = function() error("format conversion failed") end,
            })
            local ok, err = pcall(str.format, "%s", bad)
            assert(not ok)
            assert(tostring(err):find(
                "format conversion failed", 1, true), tostring(err))
            for index = 1, 100 do
                assert(str.format("%d:%q", index, "x") ==
                       native.format("%d:%q", index, "x"))
            end

            local invalid = {
                table.pack("%"),
                table.pack("%q", {}),
                table.pack("%10q", "x"),
                table.pack("%100d", 1),
                table.pack("%y", 1),
                table.pack("%5s", "a\0b"),
            }
            for _, case in ipairs(invalid) do
                local native_ok = pcall(
                    native.format, case[1],
                    table.unpack(case, 2, case.n))
                local titan_ok = pcall(
                    str.format, case[1],
                    table.unpack(case, 2, case.n))
                assert(titan_ok == native_ok)
            end
        ]])
    end)

    it("matches target-native packing, sizing, and unpacking",
    function()
        run([[
            local native = string
            local str = require "titan.string"

            local cases = {
                table.pack("bBhH", -128, 255, -32768, 65535),
                table.pack("lLjJT", math.mininteger, -1,
                           math.maxinteger, -1, 123),
                table.pack("i1I1i2I2i8I8i16I16",
                           -7, 250, -1234, 54321,
                           math.mininteger, -1, -1, -1),
                table.pack("fnd", 1.25, 1 / 3, -math.pi),
                table.pack("c0c4s1s2s8z",
                           "", "a\0", "abc", "a\0b", "hello", "a b"),
                table.pack("<i2I4", -100, 4000000000),
                table.pack(">i2I4", -100, 4000000000),
                table.pack("=i2", -100),
                table.pack("!4bXi4i4", 1, 12345),
                table.pack("!8bXd d", 1, 1.5, 2.5),
                table.pack("x b x B", -2, 200),
                table.pack("<i2 c3 z s2 f d",
                           -5, "xy", "abc", "qq", 1.5, -2.25),
            }

            local function same_results(left, right)
                assert(left.n == right.n)
                for index = 1, left.n do
                    local a, b = left[index], right[index]
                    assert(a == b or
                           (type(a) == "number" and
                            a ~= a and b ~= b),
                           ("unpack result %d differs"):format(index))
                end
            end

            for index, case in ipairs(cases) do
                local expected = native.pack(
                    case[1], table.unpack(case, 2, case.n))
                local actual = str.pack(
                    case[1], table.unpack(case, 2, case.n))
                assert(actual == expected,
                    ("pack case %d differs"):format(index))
                same_results(
                    table.pack(str.unpack(case[1], actual)),
                    table.pack(native.unpack(case[1], expected)))
            end
            local empty_unpack = table.pack(str.unpack("", ""))
            assert(empty_unpack.n == 1 and empty_unpack[1] == 1)

            local fixed = {
                "", "bBhHlLjJTfnd", "i1i2i4i8i16I1I16",
                "c0c3x", "!4bXi4i4", "!8bXd d",
                "<i2I4", ">i2I4", "i2\0?",
            }
            for _, format in ipairs(fixed) do
                assert(str.packsize(format) ==
                       native.packsize(format))
            end

            local data = native.pack("i2", 42) .. "x"
            local positions = {
                math.mininteger, -100, -1, 0, 1, 2, 4,
                5, 100, math.maxinteger,
            }
            for _, position in ipairs(positions) do
                local native_ok, native_value, native_next =
                    pcall(native.unpack, "i2", data, position)
                local titan_ok, titan_value, titan_next =
                    pcall(str.unpack, "i2", data, position)
                assert(titan_ok == native_ok)
                if native_ok then
                    assert(titan_value == native_value)
                    assert(titan_next == native_next)
                end
            end
        ]])
    end)

    it("checks binary format failures and flexible-value bounds",
    function()
        run([[
            local native = string
            local str = require "titan.string"

            local bad_pack = {
                table.pack("i0", 1),
                table.pack("i17", 1),
                table.pack("c", "x"),
                table.pack("c1", "xx"),
                table.pack("z", "a\0b"),
                table.pack("I1", 256),
                table.pack("I1", -1),
                table.pack("i1", 128),
                table.pack("i1", -129),
                table.pack("s1", native.rep("x", 256)),
                table.pack("X"),
                table.pack("Xc1"),
                table.pack("Xz"),
                table.pack("!3i4", 1),
                table.pack("?"),
                table.pack("i4"),
            }
            for _, case in ipairs(bad_pack) do
                local native_ok = pcall(
                    native.pack, case[1],
                    table.unpack(case, 2, case.n))
                local titan_ok = pcall(
                    str.pack, case[1],
                    table.unpack(case, 2, case.n))
                assert(titan_ok == native_ok)
            end

            for _, format in ipairs({
                "s", "z", "i0", "i17", "c",
                "X", "Xc2", "!3i4", "?",
            }) do
                assert(pcall(str.packsize, format) ==
                       pcall(native.packsize, format))
            end

            local bad_unpack = {
                table.pack("i4", "\0"),
                table.pack("z", "abc"),
                table.pack("s1", "\5abc"),
                table.pack("I16", native.rep("\255", 16)),
                table.pack("i16",
                           native.rep("\0", 8) .. native.rep("\1", 8)),
                table.pack("?", ""),
                table.pack("X", ""),
            }
            for _, case in ipairs(bad_unpack) do
                local native_ok =
                    pcall(native.unpack, case[1], case[2])
                local titan_ok =
                    pcall(str.unpack, case[1], case[2])
                assert(titan_ok == native_ok)
            end

            local octets = {}
            for index = 1, 201 do octets[index] = index % 256 end
            local format200 = native.rep("%d", 200)
            assert(str.format(
                format200, table.unpack(octets, 1, 200)) ==
                native.format(
                    format200, table.unpack(octets, 1, 200)))
            local ok, err = pcall(function()
                return str.format(
                    native.rep("%d", 201),
                    table.unpack(octets, 1, 201))
            end)
            assert(not ok)
            assert(tostring(err):find(
                "too many variadic arguments", 1, true), tostring(err))

            assert(#str.pack(
                native.rep("B", 200),
                table.unpack(octets, 1, 200)) == 200)
            ok, err = pcall(function()
                return str.pack(
                    native.rep("B", 201),
                    table.unpack(octets, 1, 201))
            end)
            assert(not ok)
            assert(tostring(err):find(
                "too many variadic arguments", 1, true), tostring(err))

            local format199 = native.rep("B", 199)
            local packed199 = native.rep("\1", 199)
            local returned =
                table.pack(str.unpack(format199, packed199))
            assert(returned.n == 200)
            assert(returned[200] == 200)

            ok, err = pcall(
                str.unpack, native.rep("B", 200),
                native.rep("\1", 200))
            assert(not ok)
            assert(tostring(err):find(
                "too many flexible return values", 1, true), tostring(err))
        ]])
    end)
end)
