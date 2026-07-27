-- Public titan.peg behavior is a standard-library integration suite and runs
-- outside LuaCov. The private native engine itself has a separate upstream
-- harness in spec/lpeglabel_build_spec.lua.
local assert = require "luassert"
local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"

local REPO = async_stdlib.repo
local LPEGLABEL_ARCHIVE =
    REPO .. "/lpeglabel-build/libtitan-lpeglabel.a"
local LPEGLABEL_CPPFLAGS = "-I" .. REPO .. "/vendor/lpeglabel"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local prefix = os.getenv("PREFIX")
local LUA = prefix and exists(prefix .. "/bin/lua")
    and prefix .. "/bin/lua" or "lua"

local PROBE_SOURCE = [[
local peg = import "peg"

local function runtime_callback(
    subject: string, position: integer,
    whole: string): (integer, string, string, string)
  return position + 1, "titan-runtime", whole, subject
end

local function delayed_callback(
    first: value, ...: value): (string, value, ...: value)
  return "titan-function", first, ...
end

local function fold_callback(
    accumulator: value, ...: value): value
  local total = accumulator as integer
  local index = 1
  while index <= #... do
    total = total + (...[index] as integer)
    index = index + 1
  end
  return total
end

local function no_results(): ()
end

local function first_only(first: value): value
  return first
end

function recursive(): peg.Pattern
  local rules: {integer: peg.Rule} = {
    peg.rule("S", peg.sequence(
      peg.literal("a"),
      peg.optional(peg.variable("S")))),
  }
  return peg.grammar("S", rules)
end

function runtime_pattern(): peg.Pattern
  return peg.runtime(runtime_callback)
end

function function_pattern(): peg.Pattern
  return peg.function_capture(
    peg.capture(peg.literal("x")), delayed_callback)
end

function fold_pattern(): peg.Pattern
  return peg.fold_capture(
    peg.sequence(
      peg.constant(10),
      peg.constant(20, 3),
      peg.constant(7)),
    fold_callback)
end

function zero_runtime_pattern(): peg.Pattern
  return peg.runtime(no_results)
end

function zero_match_time_pattern(): peg.Pattern
  return peg.match_time(peg.succeed(), no_results)
end

function zero_function_pattern(): peg.Pattern
  return peg.function_capture(peg.succeed(), no_results)
end

function fixed_function_pattern(): peg.Pattern
  return peg.function_capture(
    peg.constant("first", "ignored"), first_only)
end
]]

describe("titan.peg", function()
    local workspace
    local layout

    setup(function()
        assert.truthy(exists(LPEGLABEL_ARCHIVE),
            "run make lpeglabel before titan.peg specs")
        workspace = async_stdlib.workspace("peg")
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

        async_stdlib.write_source(
            workspace, "peg_core_probe", PROBE_SOURCE)
        async_stdlib.compile(workspace, "peg_core_probe", {
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

    it("loads the private engine and implements constructors and folds",
    function()
        run([[
            local peg = require "titan.peg"
            assert(type(peg.version()) == "string")
            assert(peg.version():find("LPegLabel", 1, true))

            assert(peg.literal("a\0b"):match("a\0bc") == 4)
            assert(peg.any():match("abc") == 2)
            assert(peg.any(0):match("abc") == 1)
            assert(peg.any(2):match("abc") == 3)
            assert(peg.any(-2):match("a") == 1)
            assert(peg.succeed():match("abc") == 1)
            assert(select(1, peg.fail():match("abc")) == nil)

            assert(peg.set("az\0"):match("z") == 2)
            assert(peg.set("az\0"):match("\0") == 2)
            assert(peg.ranges("az", "AZ"):match("M") == 2)
            assert(select(1, peg.ranges():match("M")) == nil)
            assert(not pcall(peg.ranges, "a"))
            assert(not pcall(peg.ranges, "abc"))

            assert(peg.utf_range(0, 0):match("\0") == 2)
            assert(peg.utf_range(0x7f, 0x7f):match("\x7f") == 2)
            assert(peg.utf_range(0x80, 0x7ff):match(
                utf8.char(0x3ff)) == 3)
            -- Native utfR intentionally accepts surrogate code points.
            assert(peg.utf_range(0xd800, 0xd800):match(
                string.char(0xed, 0xa0, 0x80)) == 4)
            assert(peg.utf_range(0x10ffff, 0x10ffff):match(
                utf8.char(0x10ffff)) == 5)
            assert(not pcall(peg.utf_range, -1, 0))
            assert(not pcall(peg.utf_range, 2, 1))
            assert(not pcall(peg.utf_range, 0, 0x110000))

            assert(peg.sequence():match("x") == 1)
            local one = peg.literal("x")
            assert(peg.sequence(one) == one)
            assert(peg.sequence(
                peg.literal("a"), peg.literal("b"),
                peg.literal("c")):match("abc") == 4)

            assert(select(1, peg.choice():match("x")) == nil)
            assert(peg.choice(one) == one)
            assert(peg.choice(
                peg.literal("a"), peg.literal("b"),
                peg.literal("c")):match("c") == 2)

            assert(peg.difference(peg.any()):match("x") == 2)
            assert(peg.difference(
                peg.any(), peg.literal("a"),
                peg.literal("b")):match("c") == 2)
            assert(select(1, peg.difference(
                peg.any(), peg.literal("a"),
                peg.literal("b")):match("b")) == nil)

            assert(peg.sequence(
                peg.lookahead(peg.literal("a")),
                peg.literal("a")):match("a") == 2)
            assert(peg.sequence(
                peg.negative(peg.literal("a")),
                peg.any()):match("b") == 2)
            assert(select(2,
                peg.lookahead(peg.throw("inside")):match("a")) == "fail")
            assert(peg.negative(peg.throw("inside")):match("a") == 1)

            assert(peg.zero_or_more(peg.literal("a")):match("aaab") == 4)
            assert(peg.one_or_more(peg.literal("a")):match("aaab") == 4)
            assert(peg.optional(peg.literal("a")):match("b") == 1)
            assert(peg.at_least(peg.literal("a"), 2):match("aaab") == 4)
            assert(peg.at_most(peg.literal("a"), 2):match("aaab") == 3)
            assert(peg.at_most(peg.literal("a"), 0):match("aaab") == 1)
            assert(not pcall(peg.at_least, peg.any(), -1))
            assert(not pcall(peg.at_most, peg.any(), -1))

            local committed = peg.choice(
                peg.throw("committed"), peg.literal("a"))
            local _, label, position = committed:match("a")
            assert(label == "committed" and position == 1)
        ]])
    end)

    it("enforces native and conservative construction limits", function()
        run([[
            local peg = require "titan.peg"
            local function raises(fragment, callback)
                local ok, err = pcall(callback)
                assert(not ok)
                assert(tostring(err):find(fragment, 1, true), tostring(err))
            end

            assert(peg.any(16379))
            raises("pattern is too large", function() peg.any(16380) end)
            assert(peg.any(-16378))
            raises("pattern is too large", function() peg.any(-16379) end)
            raises("pattern is too large", function()
                peg.any(math.maxinteger)
            end)
            raises("pattern is too large", function()
                peg.any(math.mininteger)
            end)

            assert(peg.at_least(peg.set("a"), 5458))
            raises("pattern is too large", function()
                peg.at_least(peg.set("a"), 5459)
            end)
            local locale = peg.locale()
            assert(peg.at_least(locale.alpha, 5458))
            raises("pattern is too large", function()
                peg.at_least(locale.alpha, 5459)
            end)
            assert(peg.at_least(peg.utf_range(0, 0x7f), 5458))
            raises("pattern is too large", function()
                peg.at_least(peg.utf_range(0, 0x7f), 5459)
            end)

            assert(peg.behind(peg.any(255)))
            raises("pattern too long to look behind", function()
                peg.behind(peg.any(256))
            end)
            raises("pattern have captures", function()
                peg.behind(peg.capture(peg.any()))
            end)

            raises("argument index is out of range", function()
                peg.argument(0)
            end)
            assert(peg.argument(1))
            assert(peg.argument(32767))
            raises("argument index is out of range", function()
                peg.argument(32768)
            end)

            assert(peg.select_capture(peg.capture(peg.any()), 0))
            assert(peg.select_capture(peg.capture(peg.any()), 32767))
            raises("capture index is out of range", function()
                peg.select_capture(peg.capture(peg.any()), 32768)
            end)
            assert(peg.select_capture(peg.capture(peg.any()), 1.0))
            assert(not pcall(
                peg.select_capture, peg.capture(peg.any()), 1.5))
        ]])
    end)

    it("builds dense grammars and preserves typed label identity", function()
        run([[
            local peg = require "titan.peg"
            local probe = require "peg_core_probe"
            assert(probe.recursive():match("aaaa") == 5)

            local recursive = peg.grammar("S", {
                peg.rule("S", peg.sequence(
                    peg.literal("a"),
                    peg.optional(peg.variable("S")))),
            })
            assert(recursive:match("aaa") == 4)

            local recovered = peg.grammar("S", {
                peg.rule("S", peg.sequence(
                    peg.throw(1), peg.literal("z"))),
                peg.rule(1, peg.literal("a")),
            })
            assert(recovered:match("az") == 3)

            local not_recovered = peg.grammar("S", {
                peg.rule("S", peg.throw(1)),
                peg.rule("1", peg.literal("a")),
            })
            local _, label = not_recovered:match("a")
            assert(type(label) == "number" and label == 1)

            for _, expected in ipairs({ "1", "01", 1, 0 }) do
                local _, actual = peg.throw(expected):match("")
                assert(type(actual) == type(expected))
                assert(actual == expected)
            end

            local binary = "\0s\0i"
            local _, actual = peg.throw(binary):match("")
            assert(actual == binary)

            local function fails(fragment, callback)
                local ok, err = pcall(callback)
                assert(not ok)
                assert(tostring(err):find(fragment, 1, true), tostring(err))
            end
            fails("duplicate PEG grammar rule name", function()
                peg.grammar("S", {
                    peg.rule("S", peg.succeed()),
                    peg.rule("S", peg.fail()),
                })
            end)
            fails("has no start rule", function()
                peg.grammar("missing", {
                    peg.rule("S", peg.succeed()),
                })
            end)
            fails("must be dense", function()
                peg.grammar("S", {
                    [1] = peg.rule("S", peg.succeed()),
                    [3] = peg.rule("X", peg.fail()),
                })
            end)
            fails("indices must be integers", function()
                peg.grammar("S", {
                    [1] = peg.rule("S", peg.succeed()),
                    extra = peg.rule("X", peg.fail()),
                })
            end)

            local rules = {}
            for index = 1, 1000 do
                rules[index] = peg.rule(
                    "rule" .. index,
                    index == 1 and peg.succeed() or peg.fail())
            end
            assert(peg.grammar("rule1", rules):match("") == 1)
            rules[1001] = peg.rule("rule1001", peg.fail())
            fails("too many rules", function()
                peg.grammar("rule1", rules)
            end)
        ]])
    end)

    it("normalizes match positions without confusing nil captures",
    function()
        run([[
            local peg = require "titan.peg"
            local packed = table.pack(
                peg.constant(nil, "fail", 1):match(""))
            assert(packed.n == 3)
            assert(packed[1] == nil and packed[2] == "fail" and
                   packed[3] == 1)

            packed = table.pack(
                peg.constant(nil, "middle", nil):match(""))
            assert(packed.n == 3)
            assert(packed[1] == nil and packed[2] == "middle" and
                   packed[3] == nil)

            local pattern = peg.sequence(
                peg.literal("a"), peg.literal("b"))
            local initial = {
                { 1, 2 },
                { 2, 3 },
                { -1, 5 },
                { -99, 2 },
                { 0, 5 },
                { 99, 5 },
            }
            for _, item in ipairs(initial) do
                local result, label, position =
                    pattern:match("aaaa", item[1])
                assert(result == nil and label == "fail")
                assert(position == item[2],
                    tostring(item[1]) .. " => " .. tostring(position))
            end

            assert(peg.literal("b"):match("abc", 2) == 3)
            assert(peg.literal("\0b"):match("a\0b", 2) == 4)
            local _, label, position =
                peg.throw("binary\0label"):match("x", 2)
            assert(label == "binary\0label" and position == 2)

            assert(peg.argument(1):match("", nil, "extra") == "extra")
            local ok, err = pcall(function()
                return peg.argument(1):match("")
            end)
            assert(not ok)
            assert(tostring(err):find(
                "absent extra argument #1", 1, true), tostring(err))

            local two_hundred = peg.succeed()
            for index = 1, 200 do
                two_hundred = peg.sequence(
                    two_hundred, peg.constant(index))
            end
            packed = table.pack(two_hundred:match(""))
            assert(packed.n == 200)
            assert(packed[1] == 1 and packed[200] == 200)

            local too_many = peg.sequence(
                two_hundred, peg.constant(201))
            ok, err = pcall(function() return too_many:match("") end)
            assert(not ok)
            assert(tostring(err):find(
                "too many flexible return values", 1, true), tostring(err))

            -- The failed oversized call restored the exact Lua stack.
            assert(peg.literal("ok"):match("ok") == 3)
            packed = table.pack(
                peg.constant(nil, "fail", 1):match(""))
            assert(packed.n == 3 and packed[1] == nil and
                   packed[2] == "fail" and packed[3] == 1)
        ]])
    end)

    it("implements every delayed and immediate capture form", function()
        run([[
            local peg = require "titan.peg"
            local packed = table.pack(peg.capture(peg.sequence(
                peg.literal("a"), peg.constant("nested"),
                peg.literal("b"))):match("ab"))
            assert(packed.n == 2 and packed[1] == "ab" and
                   packed[2] == "nested")

            packed = table.pack(peg.constant(1, nil, "x"):match(""))
            assert(packed.n == 3 and packed[1] == 1 and
                   packed[2] == nil and packed[3] == "x")
            assert(peg.position():match("abc", 2) == 2)

            local anonymous = peg.group(peg.literal("a"))
            assert(anonymous:match("a") == "a")
            local named = peg.sequence(
                peg.group(peg.literal("a"), "key"),
                peg.back_capture("key"))
            assert(named:match("a") == "a")
            assert(not pcall(function()
                return peg.back_capture("missing"):match("")
            end))
            assert(not pcall(peg.back_capture, nil))

            local captured_table = peg.table_capture(peg.sequence(
                peg.capture(peg.literal("a")),
                peg.group(peg.capture(peg.literal("b")), "letter")))
                :match("ab")
            assert(captured_table[1] == "a")
            assert(captured_table.letter == "b")
            assert(next(peg.table_capture(
                peg.literal("a")):match("a")) == nil)

            local folded = peg.fold_capture(peg.sequence(
                peg.constant(1), peg.constant(2),
                peg.constant(3)), function(accumulator, ...)
                    local out = accumulator
                    for index = 1, select("#", ...) do
                        out = out + select(index, ...)
                    end
                    return out
                end)
            assert(folded:match("") == 6)
            assert(not pcall(function()
                return peg.fold_capture(
                    peg.literal("a"), function(x) return x end)
                    :match("a")
            end))

            local substituted = peg.substitution(peg.sequence(
                peg.template_capture(
                    peg.capture(peg.literal("a")), "X"),
                peg.literal("b")))
            assert(substituted:match("ab") == "Xb")

            assert(peg.select_capture(
                peg.capture(peg.literal("a")), 0):match("a") == 2)
            assert(peg.select_capture(
                peg.literal("a"), 1):match("a") == "a")
            assert(peg.template_capture(
                peg.literal("a"), "<%0>"):match("a") == "<a>")
            assert(not pcall(function()
                return peg.template_capture(
                    peg.literal("a"), "%1"):match("a")
            end))

            local lookup = setmetatable({}, {
                __index = function(_, key) return "<" .. key .. ">" end,
            })
            assert(peg.query_capture(
                peg.literal("a"), lookup):match("a") == "<a>")
            assert(peg.function_capture(
                peg.literal("a"), function(value)
                    return "<" .. value .. ">"
                end):match("a") == "<a>")

            packed = table.pack(peg.function_capture(
                peg.constant("a", "b"), function(...)
                    assert(select("#", ...) == 2)
                    local first, second = ...
                    return nil, first, second, nil
                end):match(""))
            assert(packed.n == 4 and packed[1] == nil and
                   packed[2] == "a" and packed[3] == "b" and
                   packed[4] == nil)

            local callback_count
            local match_time = peg.match_time(
                peg.literal("ab"), function(subject, position, ...)
                    callback_count = select("#", ...)
                    assert(subject == "abx" and position == 3)
                    assert((...) == "ab")
                    return true, "matched", position
                end)
            packed = table.pack(match_time:match("abx"))
            assert(callback_count == 1)
            assert(packed.n == 2 and packed[1] == "matched" and
                   packed[2] == 3)

            local runtime_count
            local runtime = peg.runtime(
                function(subject, position, ...)
                    runtime_count = select("#", ...)
                    assert(subject == "abc" and position == 1)
                    assert((...) == "")
                    return position + 1, "runtime"
                end)
            assert(runtime:match("abc") == "runtime")
            assert(runtime_count == 1)
        ]])
    end)

    it("preserves callback timing, errors, and tight Titan types", function()
        run([[
            local peg = require "titan.peg"
            local probe = require "peg_core_probe"

            local packed = table.pack(
                probe.runtime_pattern():match("a"))
            assert(packed.n == 3)
            assert(packed[1] == "titan-runtime")
            assert(packed[2] == "" and packed[3] == "a")

            packed = table.pack(
                probe.function_pattern():match("x"))
            assert(packed.n == 2)
            assert(packed[1] == "titan-function" and packed[2] == "x")
            assert(probe.fold_pattern():match("") == 40)
            assert(probe.zero_runtime_pattern():match("") == nil)
            assert(probe.zero_match_time_pattern():match("") == nil)
            assert(probe.zero_function_pattern():match("") == 1)
            assert(probe.fixed_function_pattern():match("") == "first")

            local events = {}
            local delayed = peg.function_capture(
                peg.capture(peg.literal("a")), function(value)
                    events[#events + 1] = "delayed"
                    return value
                end)
            local immediate = peg.runtime(function(_, position)
                events[#events + 1] = "runtime"
                return position
            end)
            local pattern = peg.choice(
                peg.sequence(delayed, peg.literal("x")),
                peg.sequence(immediate, peg.literal("a")))
            assert(pattern:match("a") == 2)
            assert(#events == 1 and events[1] == "runtime")

            local fold_arities = {}
            local fold = peg.fold_capture(peg.sequence(
                peg.constant(1),
                peg.group(peg.succeed(), "hidden"),
                peg.constant(2, 3)), function(accumulator, ...)
                    fold_arities[#fold_arities + 1] =
                        select("#", ...)
                    local total = accumulator
                    for index = 1, select("#", ...) do
                        total = total + select(index, ...)
                    end
                    return total
                end)
            assert(fold:match("") == 6)
            assert(fold_arities[1] == 0 and fold_arities[2] == 2)

            local bad = peg.function_capture(
                peg.literal("a"), function()
                    error("callback exploded")
                end)
            local ok, err = pcall(function() return bad:match("a") end)
            assert(not ok)
            assert(tostring(err):find(
                "callback exploded", 1, true), tostring(err))
            assert(peg.literal("a"):match("a") == 2)

            local callable = setmetatable({}, {
                __call = function() return true end,
            })
            assert(not pcall(peg.runtime, callable))
            assert(not pcall(
                peg.function_capture, peg.literal("a"), callable))

            local yielding = peg.function_capture(
                peg.literal("a"), function() coroutine.yield() end)
            local thread = coroutine.create(function()
                return yielding:match("a")
            end)
            local resumed, message = coroutine.resume(thread)
            assert(not resumed)
            assert(tostring(message):find("yield", 1, true), message)
        ]])
    end)

    it("exposes locale snapshots and state-local engine controls", function()
        run([[
            assert(os.setlocale("C", "ctype"))
            local peg = require "titan.peg"
            local locale = peg.locale()
            assert(locale.alnum:match("A") == 2)
            assert(locale.alpha:match("z") == 2)
            assert(locale.cntrl:match("\n") == 2)
            assert(locale.digit:match("7") == 2)
            assert(locale.graph:match("!") == 2)
            assert(locale.lower:match("z") == 2)
            assert(locale.print:match(" ") == 2)
            assert(locale.punct:match("!") == 2)
            assert(locale.space:match("\t") == 2)
            assert(locale.upper:match("Z") == 2)
            assert(locale.xdigit:match("f") == 2)

            local recursive = peg.grammar("S", {
                peg.rule("S", peg.choice(
                    peg.sequence(
                        peg.literal("0"), peg.variable("S")),
                    peg.literal("0"))),
            })
            local subject = string.rep("0", 500)
            peg.set_max_stack(500)
            local ok, message = pcall(
                function() return recursive:match(subject) end)
            assert(not ok)
            assert(tostring(message):find(
                "backtrack stack overflow", 1, true), message)
            peg.set_max_stack(1004)
            assert(recursive:match(subject) == 501)

            peg.set_max_stack(1)
            peg.set_max_stack(400)
            peg.set_max_stack(21474836)
            peg.set_max_stack(400)
            assert(not pcall(peg.set_max_stack, 0))
            assert(not pcall(peg.set_max_stack, 21474837))
            assert(not pcall(peg.set_max_stack, math.maxinteger))
        ]])
    end)

    it("GC roots patterns and callbacks across repeated collections",
    function()
        run([[
            local peg = require "titan.peg"
            collectgarbage("collect")
            collectgarbage("generational")

            local weak = setmetatable({}, { __mode = "v" })
            local function build()
                local callback = function(value)
                    return value .. "!"
                end
                local lookup = setmetatable({}, {
                    __index = function(_, key) return key .. "?" end,
                })
                weak.callback = callback
                weak.lookup = lookup
                local delayed = peg.function_capture(
                    peg.capture(peg.literal("a")), callback)
                local queried = peg.query_capture(
                    peg.capture(peg.literal("b")), lookup)
                return peg.choice(delayed, queried)
            end

            local pattern = build()
            for index = 1, 100 do
                if index % 2 == 0 then
                    collectgarbage("collect")
                else
                    collectgarbage("step", 0)
                end
                assert(pattern:match("a") == "a!")
                assert(pattern:match("b") == "b?")
            end
            assert(weak.callback and weak.lookup)

            local record_weak = setmetatable(
                { pattern = pattern }, { __mode = "v" })
            pattern = nil
            collectgarbage("collect")
            collectgarbage("collect")
            assert(record_weak.pattern == nil)
            assert(weak.callback == nil and weak.lookup == nil)
        ]])
    end)

    it("keeps private and external LPegLabel engines isolated", function()
        local function exercise(load_private_first)
            local prefix = load_private_first and [[
                package.loaded.lpeglabel = nil
                local peg = require "titan.peg"
                assert(package.loaded.lpeglabel == nil)
                local external = require "lpeglabel"
                local private_has_larger_stack = true
            ]] or [[
                package.loaded.lpeglabel = nil
                local external = require "lpeglabel"
                local peg = require "titan.peg"
                assert(package.loaded.lpeglabel == external)
                local private_has_larger_stack = false
            ]]
            run(prefix .. [[
                local private_pattern = peg.literal("a")
                local external_pattern = external.P("a")
                assert(private_pattern:match("a") == 2)
                assert(external.match(external_pattern, "a") == 2)
                assert(not pcall(peg.sequence, external_pattern))
                assert(not pcall(
                    external.match, private_pattern, "a"))

                local private_recursive = peg.grammar("S", {
                    peg.rule("S", peg.choice(
                        peg.sequence(
                            peg.literal("0"), peg.variable("S")),
                        peg.literal("0"))),
                })
                local external_recursive = external.P({
                    "0" * external.V(1) + "0",
                })
                local subject = string.rep("0", 300)

                if private_has_larger_stack then
                    peg.set_max_stack(1000)
                    external.setmaxstack(500)
                    assert(private_recursive:match(subject) == 301)
                    assert(not pcall(
                        external.match, external_recursive, subject))
                else
                    external.setmaxstack(1000)
                    peg.set_max_stack(500)
                    assert(external.match(
                        external_recursive, subject) == 301)
                    assert(not pcall(function()
                        return private_recursive:match(subject)
                    end))
                end
                peg.set_max_stack(400)
                external.setmaxstack(400)
            ]])
        end

        exercise(true)
        exercise(false)
    end)
end)
