-- Public relabel behavior is a standard-library integration suite and runs
-- outside LuaCov. The private upstream compatibility harness remains in
-- spec/lpeglabel_build_spec.lua.
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

local PROBE_SOURCE = [=[
local peg = import "peg"

local function add(accumulator: value, ...: value): value
  local result = accumulator as integer
  local index = 1
  while index <= #... do
    result = result + (...[index] as integer)
    index = index + 1
  end
  return result
end

local function decimal(candidate: value): integer
  local text = candidate as string
  if text == "3" then return 3
  elseif text == "401" then return 401
  elseif text == "50" then return 50
  end
  return 0
end

local function bracket(found: string): string
  return "[" .. found .. "]"
end

function letters(): peg.Pattern
  local definitions: {peg.Definition} = {
    peg.define("letter", peg.ranges("az")),
  }
  return peg.compile("%letter+", definitions)
end

function folded(): peg.Pattern
  local definitions: {peg.Definition} = {
    peg.define_value("decimal", decimal),
    peg.define_value("add", add),
  }
  return peg.compile([[
    S <- (number (%s+ number)*) ~> add
    number <- {%d+} -> decimal
  ]], definitions)
end

function substituted(subject: string): string
  return peg.gsub(subject, "'a'", bracket)
end

function definition_array(
    ...: peg.Definition): {peg.Definition}
  return {...}
end
]=]

describe("titan.peg relabel", function()
    local workspace
    local layout

    setup(function()
        assert.truthy(exists(LPEGLABEL_ARCHIVE),
            "run make lpeglabel before relabel specs")
        workspace = async_stdlib.workspace("peg-relabel")
        for _, name in ipairs({
            "peg", "native", "combinators",
            "relabel", "relabel_parser",
        }) do
            async_stdlib.write_source(
                workspace, "titan.peg." .. name,
                async_stdlib.read("titan/peg/" .. name .. ".titan"))
        end
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.prepare_gc(workspace, layout)
        async_stdlib.compile(workspace, "titan.peg", {
            layout = layout,
            cppflags = LPEGLABEL_CPPFLAGS,
            extra_objects = { LPEGLABEL_ARCHIVE },
        })
        async_stdlib.register_exact_provider(layout, "titan.peg")

        async_stdlib.write_source(
            workspace, "peg_relabel_probe", PROBE_SOURCE)
        async_stdlib.compile(workspace, "peg_relabel_probe", {
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

    it("ports expressions, repetitions, classes, and recursive grammars",
    function()
        run([=[
            local peg = require "titan.peg"
            local probe = require "peg_relabel_probe"
            assert(probe.substituted("aba") == "[a]b[a]")
            local function anchored(subject, candidate, init)
                return peg.compile(candidate):match(subject, init)
            end
            local cases = {
                { "a", ".", 2 },
                { "a", "''", 1 },
                { "", " ! . ", 1 },
                { "abcde", "  ( . . ) * ", 5 },
                { "abbcde", " [a-c] +", 5 },
                { "0abbc1de", "'0' [a-c]+ '1'", 7 },
                { "0zz1dda", "'0' [^a-c]+ 'a'", 8 },
                { "abbc--", " [a-c] + +", 5 },
                { "abbc--", " [ac-] +", 2 },
                { "abbc--", " [-acb] + ", 7 },
                { "aaaaaaaa", "'a'^3", 4 },
                { "aaaaaaaa", "'a'^0", 1 },
                { "aaaaaaaa", "'a'^+3", 9 },
                { "aaaaaaaa", "'a'^-5", 6 },
            }
            for index, case in ipairs(cases) do
                assert(anchored(case[1], case[2]) == case[3], index)
            end
            assert(select(1, anchored("a", " ! . ")) == nil)
            assert(anchored(
                "01234567890123456789", "[0-9]^3+") == 19)

            local balanced =
                "balanced <- '(' ([^()] / balanced)* ')'"
            assert(anchored("(a(b)((c) (d)))", balanced))
            assert(not anchored("(a(b ((c) (d)))", balanced))

            local grammar = [[
              S <- "0" B / "1" A / ""
              A <- "0" S / "1" A A
              B <- "1" S / "0" B B
            ]]
            assert(anchored("00011011", grammar) == 9)

            local comments = peg.compile([[
              A <- _B   -- punctuation in comments: .<> <- -> --
              _B <- 'x'
            ]])
            assert(comments:match("xy") == 2)

            local _, label, position = anchored("", "%{0}")
            assert(type(label) == "string" and
                   label == "0" and position == 1)
            local recovered = peg.compile([[
              S <- ('a'^recover) 'b'
              recover <- 'x'
            ]])
            assert(recovered:match("xb") == 3)
        ]=])
    end)

    it("uses Titan Definition Arrays and dynamic Map values", function()
        run([=[
            local peg = require "titan.peg"
            local probe = require "peg_relabel_probe"
            local function definitions(...)
                return probe.definition_array(...)
            end
            local supplied = definitions(
                peg.define("letters", peg.ranges("az")),
                peg.define("digits", peg.ranges("09"))
            )
            local pattern = peg.compile(
                "%letters (%letters / %digits)*", supplied)
            assert(pattern:match("x123") == 5)

            local function tonumber10(text) return tonumber(text) end
            local converted = peg.compile(
                "{[0-9]+'.'?[0-9]*} -> tonumber10",
                definitions(
                    peg.define_value("tonumber10", tonumber10)))
            assert(converted:match("2.34") == 2.34)

            local lookup = setmetatable({}, {
                __index = function(_, key) return "<" .. key .. ">" end,
                __call = function()
                    error("map replacement was called")
                end,
            })
            local queried = peg.compile(
                "{%a+} -> lookup",
                definitions(peg.define_value("lookup", lookup)))
            assert(queried:match("word") == "<word>")
            local templated = peg.compile(
                "({.}{.}) -> swap",
                definitions(peg.define_value("swap", "%2%1")))
            assert(templated:match("ab") == "ba")
            local selected = peg.compile(
                "({.}{.}) -> second",
                definitions(peg.define_value("second", 2)))
            assert(selected:match("ab") == "b")

            assert(probe.letters():match("abc") == 4)
            assert(probe.folded():match("3 401 50") == 454)

            local already = peg.literal("x")
            assert(rawequal(peg.compile(
                already,
                definitions(
                    peg.define_value("ignored", "ignored"))), already))

            -- Definition names are opaque strings. Names that cannot be
            -- written in the relabel source syntax are accepted and inert.
            local inert = definitions(
                peg.define("not-valid!", already),
                peg.define("", already),
                peg.define("1", already),
                peg.define("binary\0name", already))
            assert(peg.compile("'x'", inert):match("x") == 2)
            assert(not pcall(peg.define_value, "x", nil))
            assert(not pcall(peg.define_value, "x", false))

            -- Ordinary Lua tables are not Titan Arrays.
            assert(not pcall(peg.compile, "%x", {
                peg.define("x", already),
            }))
            local ok, message = pcall(
                peg.compile, "%x", definitions(
                    peg.define("x", already),
                    peg.define("x", already)))
            assert(not ok)
            assert(tostring(message):find(
                "duplicate PEG definition name 'x'", 1, true), message)
        ]=])
    end)

    it("implements all capture and replacement suffix families", function()
        run([=[
            local peg = require "titan.peg"
            local probe = require "peg_relabel_probe"
            local function definitions(...)
                return probe.definition_array(...)
            end
            local function anchored(subject, candidate, init)
                return peg.compile(candidate):match(subject, init)
            end
            assert(anchored(
                "01234567890123456789",
                "({....}{...}) -> '%2%1'") == "4560123")

            local values = anchored("0123456789", "{| {.}* |}")
            assert(#values == 10)
            for index = 1, 10 do
                assert(values[index] == tostring((index - 1) % 10))
            end
            assert(anchored(
                "abcdef", "( {.} {.} {.} {.} {.} ) -> 3") == "c")
            assert(anchored(
                "abcdef",
                "( {:x: . :} {.} {.} {.} {.} ) -> 3") == "d")
            assert(anchored(
                "abcdef",
                "( {:x: . :} {.} {.} {.} {.} ) -> 0") == 6)
            assert(anchored("abc", "{: . . :}") == "ab")
            assert(anchored("abc", "{}") == 1)
            assert(anchored(
                "abc", "{~ ({.} -> '[%1]')* ~}") ==
                "[a][b][c]")
            local captured_table =
                anchored("abc", "({.}{.}) -> {}")
            assert(captured_table[1] == "a" and
                   captured_table[2] == "b")

            assert(not anchored(
                "abcdef", "{:x: ({.} {.} {.}) -> 2 :} =x"))
            assert(anchored(
                "abcbef", "{:x: ({.} {.} {.}) -> 2 :} =x"))

            local function add(accumulator, ...)
                for index = 1, select("#", ...) do
                    accumulator =
                        accumulator + select(index, ...)
                end
                return accumulator
            end
            local function number(text) return tonumber(text) end
            local folded = peg.compile([[
              S <- (number (%s+ number)*) ~> add
              number <- {%d+} -> number
            ]], definitions(
                peg.define_value("add", add),
                peg.define_value("number", number)
            ))
            assert(folded:match("3 401 50") == 454)

            local function tag(subject, position, table_value, tag_name)
                table_value.tag = tag_name
                return position, table_value
            end
            local document = peg.compile([[
              doc <- block !.
              block <- (start {| (block / { [^<]+ })* |} end?) => tag
              start <- '<' {:tag: [a-z]+ :} '>'
              end <- '</' { =tag } '>'
            ]], definitions(peg.define_value("tag", tag)))
            local tree = document:match(
                "<x>hi<b>hello</b>but<b>totheend</x>")
            assert(tree.tag == "x" and tree[1] == "hi")
            assert(tree[2].tag == "b" and tree[2][1] == "hello")
        ]=])
    end)

    it("defers dynamic suffix callability until callbacks are reached",
    function()
        run([=[
            local peg = require "titan.peg"
            local probe = require "peg_relabel_probe"
            local function definitions(...)
                return probe.definition_array(...)
            end

            local match_time_callable = setmetatable({}, {
                __call = function(_, subject, position, whole)
                    assert(subject == "a" and position == 2)
                    assert(whole == "a")
                    return true, "match-time"
                end,
            })
            local callable_match_time = peg.compile(
                "'a' => callback", definitions(
                    peg.define_value(
                        "callback", match_time_callable)
                ))
            assert(callable_match_time:match("a") == "match-time")

            local fold_callable = setmetatable({}, {
                __call = function(_, accumulator, next_value)
                    return accumulator .. next_value
                end,
            })
            local callable_fold = peg.compile(
                "({.}{.}) ~> callback",
                definitions(
                    peg.define_value("callback", fold_callable)))
            assert(callable_fold:match("ab") == "ab")

            local bad_definitions =
                definitions(peg.define_value("callback", true))
            local bad_replacement = peg.compile(
                "'x' ({.} -> callback)", bad_definitions)
            local bad_match_time = peg.compile(
                "'x' => callback", bad_definitions)
            local bad_fold = peg.compile(
                "({.}{.}) ~> callback", bad_definitions)

            assert(bad_replacement:match("a") == nil)
            assert(bad_match_time:match("a") == nil)
            assert(bad_fold:match("a") == nil)

            for _, case in ipairs({
                { bad_replacement, "xa" },
                { bad_match_time, "x" },
                { bad_fold, "ab" },
            }) do
                local ok, message = pcall(function()
                    return case[1]:match(case[2])
                end)
                assert(not ok)
                assert(tostring(message):find(
                    "call", 1, true), tostring(message))
            end

            local float_selector = peg.compile(
                "({.}{.}) -> selector",
                definitions(peg.define_value("selector", 2.0)))
            assert(float_selector:match("ab") == "b")
        ]=])
    end)

    it("searches with structured spans and exact capture values",
    function()
        run([=[
            local peg = require "titan.peg"
            assert(not pcall(function() return peg.find end))
            local source = "{:x:..:} =x"
            local found = assert(peg.match("hi alalo", source))
            assert(found.first == 4 and found.last == 7)
            assert(select("#", found:values()) == 0)
            assert(peg.match("hi alalo", source, 4).first == 4)
            assert(peg.match("hi alalo", source, 5) == nil)

            found = assert(peg.match("hi alalo", "{'al'}", 5))
            assert(found.first == 6 and found.last == 7)
            assert(found:values() == "al")

            found = assert(peg.match("", "!."))
            assert(found.first == 1 and found.last == 0)
            found = assert(peg.match("alo", "!."))
            assert(found.first == 4 and found.last == 3)

            found = assert(peg.match("alo", "{.}{'o'}"))
            assert(found.first == 2 and found.last == 3)
            local first_value, second_value, surplus = found:values()
            assert(first_value == "l" and second_value == "o" and
                   surplus == nil)
            assert(select("#", found:values()) == 2)
            assert(peg.match("alo", "'z'") == nil)

            found = assert(peg.match("", "''"))
            assert(found.first == 1 and found.last == 0)
            assert(select("#", found:values()) == 0)

            assert(peg.match("abc", "'c'", 0) == nil)
            assert(peg.match("abc", "'c'", -1).first == 3)
            assert(peg.match("abc", "'c'", -99).first == 3)
            assert(peg.match("abc", "'c'", 99) == nil)

            local nil_pattern = peg.function_capture(
                peg.capture(peg.literal("a")),
                function()
                    return nil, "middle", nil
                end)
            found = assert(peg.match("za", nil_pattern))
            assert(found.first == 2 and found.last == 2)
            local leading, middle, trailing = found:values()
            assert(leading == nil and middle == "middle" and
                   trailing == nil)
            assert(select("#", found:values()) == 3)

            local positions = assert(peg.match(
                "", ("{}"):rep(200)))
            assert(select("#", positions:values()) == 200)

            -- An ordinary failure advances the search. Other uncaught
            -- labels commit it; the reserved "fail" label is ordinary.
            assert(peg.match("ab", "'b'").first == 2)
            assert(peg.match("ab", "%{stop} / 'b'") == nil)
            assert(peg.match("ab", "%{fail} / 'b'").first == 2)

            local attempts = 0
            local inspected = peg.match_time(
                peg.capture(peg.any()),
                function(_, _, byte)
                    attempts = attempts + 1
                    return byte == "b"
                end)
            found = assert(peg.match("ab", inspected))
            assert(found.first == 2 and found.last == 2)
            assert(attempts == 2)

            local function x() return "x" end
            local function dot() return "." end
            assert(peg.gsub("alo alo", "[abc]", x) == "xlo xlo")
            assert(peg.gsub("alo alo", "%w+", dot) == ". .")
            local function upper(text) return text:upper() end
            assert(peg.gsub(
                "hi, how are you", "[aeiou]", upper) ==
                "hI, hOw ArE yOU")
            local function capital_x() return "X" end
            assert(peg.gsub(
                "abc", peg.literal("b"), capital_x) == "aXc")

            local seen = ""
            local function bracket_whole(text)
                seen = text
                return "[" .. text .. "]"
            end
            assert(peg.gsub(
                "ab", "{.}{.}", bracket_whole) == "[ab]")
            assert(seen == "ab")
            found = assert(peg.match("abc", peg.literal("a")))
            assert(found.first == 1 and found.last == 1)
            found = assert(peg.match("abc", peg.literal("b")))
            assert(found.first == 2 and found.last == 2)

            local first_compile = peg.compile("'cached'")
            local second_compile = peg.compile("'cached'")
            assert(rawequal(first_compile, second_compile))

            local weak = setmetatable({}, { __mode = "v" })
            do
                local ephemeral = peg.compile("'weakly cached'")
                weak.pattern = ephemeral
                assert(ephemeral:match("weakly cached") == 14)
            end
            collectgarbage("collect")
            collectgarbage("collect")
            assert(weak.pattern == nil)
            assert(peg.compile("'weakly cached'"):match(
                "weakly cached") == 14)

            do
                local callback = function(text) return "[" .. text .. "]" end
                weak.callback = callback
                assert(peg.gsub("aba", "'a'", callback) == "[a]b[a]")
                assert(peg.gsub("aba", "'a'", callback) == "[a]b[a]")
            end
            collectgarbage("collect")
            collectgarbage("collect")
            assert(weak.callback == nil)
        ]=])
    end)

    it("formats stable labeled diagnostics and corrected line positions",
    function()
        run([=[
            local peg = require "titan.peg"
            local function exact(source, expected)
                local ok, message = pcall(peg.compile, source)
                assert(not ok)
                assert(tostring(message) == expected,
                    "\nEXPECTED:\n" .. expected ..
                    "\nACTUAL:\n" .. tostring(message))
            end
            exact("'p' /",
                "PEG syntax error [ExpPatt1] at L1:C6 (byte 6): " ..
                "expected a pattern after '/'\n'p' /\n     ^")
            exact("&",
                "PEG syntax error [ExpPatt2] at L1:C2 (byte 2): " ..
                "expected a pattern after '&'\n&\n ^")
            exact("'That is the question...",
                "PEG syntax error [MisTerm1] at L1:C25 (byte 25): " ..
                "missing terminating single quote\n" ..
                "'That is the question...\n                        ^")
            exact("A <- 'a'\r\nB <-",
                "PEG syntax error [ExpPatt8] at L2:C5 (byte 15): " ..
                "expected a pattern after '<-'\nB <-\n    ^")

            local labels = {
                { "~", "NoPatt" },
                { "'p'~", "ExtraChars" },
                { "!", "ExpPatt3" },
                { "()", "ExpPatt4" },
                { "{: *** :}", "ExpPatt5" },
                { "{~~}", "ExpPatt6" },
                { "{||}", "ExpPatt7" },
                { "{0}", "ExpPattOrClose" },
                { "'p' ^ n", "ExpNumName" },
                { "'p' -> {", "ExpCap" },
                { "'p' =>", "ExpName1" },
                { "=", "ExpName2" },
                { "<>", "ExpName3" },
                { "%{}", "ExpLab1" },
                { "% s", "ExpNameOrLab" },
                { "('p'", "MisClose1" },
                { "{: 'p'", "MisClose2" },
                { "{~ 'p'", "MisClose3" },
                { "{| 'p'", "MisClose4" },
                { "{ 'p'", "MisClose5" },
                { "<patt", "MisClose6" },
                { "%{ a", "MisClose7" },
                { "[", "MisClose8" },
                { "\"unterminated", "MisTerm2" },
            }
            for _, item in ipairs(labels) do
                local ok, message = pcall(peg.compile, item[1])
                assert(not ok)
                assert(tostring(message):find(
                    "[" .. item[2] .. "]", 1, true), message)
            end
            local ok, syntax_first = pcall(
                peg.compile, " A <- %nosuch ('error'")
            assert(not ok)
            assert(tostring(syntax_first):find(
                "[MisClose1]", 1, true), syntax_first)
            assert(not tostring(syntax_first):find(
                "undefined", 1, true), syntax_first)

            local line, column = peg.line_column("a\r\nb", 1)
            assert(line == 1 and column == 1)
            line, column = peg.line_column("a\r\nb", 4)
            assert(line == 2 and column == 1)
            line, column = peg.line_column("a\r\nb", 5)
            assert(line == 2 and column == 2)
            assert(not pcall(peg.line_column, "abc", 0))
            assert(not pcall(peg.line_column, "abc", 5))
        ]=])
    end)

    it("refreshes locale patterns and reports semantic errors", function()
        run([=[
            assert(os.setlocale("C", "ctype"))
            local peg = require "titan.peg"
            local function anchored(subject, candidate)
                return peg.compile(candidate):match(subject)
            end
            assert(anchored("A9", "%w+") == 3)
            assert(anchored("!", "%W") == 2)
            assert(anchored("\n", "%nl") == 2)
            assert(anchored("7", "[_%w]") == 2)
            assert(anchored("!", "[^%w]") == 2)

            local before = peg.compile("%a+")
            peg.update_locale()
            local after = peg.compile("%a+")
            assert(not rawequal(before, after))
            assert(after:match("abc") == 4)

            local function fails(source, fragment)
                local ok, message = pcall(peg.compile, source)
                assert(not ok)
                assert(tostring(message):find(
                    fragment, 1, true), message)
            end
            fails("aaaa", "rule 'aaaa' used outside a grammar")
            fails("b <- a", "undefined in given grammar")
            fails("x <- 'a'  x <- 'b'",
                "'x' already defined as a rule")
            fails("%nosuch", "name 'nosuch' undefined")
        ]=])
    end)
end)
