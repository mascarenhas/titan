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

function letters(): peg.Pattern
  local definitions: {integer: peg.Definition} = {
    peg.define("letter", peg.ranges("az")),
  }
  return peg.compile("%letter+", definitions)
end

function folded(): peg.Pattern
  local definitions: {integer: peg.Definition} = {
    peg.define_value("decimal", decimal),
    peg.define_value("add", add),
  }
  return peg.compile([[
    S <- (number (%s+ number)*) ~> add
    number <- {%d+} -> decimal
  ]], definitions)
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

    it("ports expressions, repetitions, classes, and recursive grammars",
    function()
        run([=[
            local peg = require "titan.peg"
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
                assert(peg.match(case[1], case[2]) == case[3], index)
            end
            assert(select(1, peg.match("a", " ! . ")) == nil)
            assert(peg.match(
                "01234567890123456789", "[0-9]^3+") == 19)

            local balanced =
                "balanced <- '(' ([^()] / balanced)* ')'"
            assert(peg.match("(a(b)((c) (d)))", balanced))
            assert(not peg.match("(a(b ((c) (d)))", balanced))

            local grammar = [[
              S <- "0" B / "1" A / ""
              A <- "0" S / "1" A A
              B <- "1" S / "0" B B
            ]]
            assert(peg.match("00011011", grammar) == 9)

            local comments = peg.compile([[
              A <- _B   -- punctuation in comments: .<> <- -> --
              _B <- 'x'
            ]])
            assert(comments:match("xy") == 2)

            local _, label, position = peg.match("", "%{0}")
            assert(label == 0 and position == 1)
            local recovered = peg.compile([[
              S <- ('a'^recover) 'b'
              recover <- 'x'
            ]])
            assert(recovered:match("xb") == 3)
        ]=])
    end)

    it("uses public definitions from Lua tables and Titan Maps", function()
        run([=[
            local peg = require "titan.peg"
            local definitions = {
                peg.define("letters", peg.ranges("az")),
                peg.define("digits", peg.ranges("09")),
            }
            local pattern = peg.compile(
                "%letters (%letters / %digits)*", definitions)
            assert(pattern:match("x123") == 5)

            local function tonumber10(text) return tonumber(text) end
            local converted = peg.compile(
                "{[0-9]+'.'?[0-9]*} -> tonumber10", {
                    peg.define_value("tonumber10", tonumber10),
                })
            assert(converted:match("2.34") == 2.34)

            local lookup = setmetatable({}, {
                __index = function(_, key) return "<" .. key .. ">" end,
            })
            local queried = peg.compile("{%a+} -> lookup", {
                peg.define_value("lookup", lookup),
            })
            assert(queried:match("word") == "<word>")
            local templated = peg.compile("({.}{.}) -> swap", {
                peg.define_value("swap", "%2%1"),
            })
            assert(templated:match("ab") == "ba")
            local selected = peg.compile("({.}{.}) -> second", {
                peg.define_value("second", 2),
            })
            assert(selected:match("ab") == "b")

            local probe = require "peg_relabel_probe"
            assert(probe.letters():match("abc") == 4)
            assert(probe.folded():match("3 401 50") == 454)

            local already = peg.literal("x")
            assert(rawequal(peg.compile(already, {
                peg.define_value("ignored", "ignored"),
            }), already))

            assert(not pcall(peg.define, "not-valid!", already))
            assert(not pcall(peg.define_value, "x", nil))
            assert(not pcall(peg.define_value, "x", false))
            assert(not pcall(peg.compile, "%x", {
                [2] = peg.define("x", already),
            }))
            assert(not pcall(peg.compile, "%x", {
                bad = peg.define("x", already),
            }))
            local ok, message = pcall(peg.compile, "%x", {
                peg.define("x", already),
                peg.define("x", already),
            })
            assert(not ok)
            assert(tostring(message):find(
                "duplicate PEG definition name 'x'", 1, true), message)
        ]=])
    end)

    it("implements all capture and replacement suffix families", function()
        run([=[
            local peg = require "titan.peg"
            assert(peg.match(
                "01234567890123456789",
                "({....}{...}) -> '%2%1'") == "4560123")

            local values = peg.match("0123456789", "{| {.}* |}")
            assert(#values == 10)
            for index = 1, 10 do
                assert(values[index] == tostring((index - 1) % 10))
            end
            assert(peg.match(
                "abcdef", "( {.} {.} {.} {.} {.} ) -> 3") == "c")
            assert(peg.match(
                "abcdef",
                "( {:x: . :} {.} {.} {.} {.} ) -> 3") == "d")
            assert(peg.match(
                "abcdef",
                "( {:x: . :} {.} {.} {.} {.} ) -> 0") == 6)
            assert(peg.match("abc", "{: . . :}") == "ab")
            assert(peg.match("abc", "{}") == 1)
            assert(peg.match(
                "abc", "{~ ({.} -> '[%1]')* ~}") ==
                "[a][b][c]")
            local captured_table =
                peg.match("abc", "({.}{.}) -> {}")
            assert(captured_table[1] == "a" and
                   captured_table[2] == "b")

            assert(not peg.match(
                "abcdef", "{:x: ({.} {.} {.}) -> 2 :} =x"))
            assert(peg.match(
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
            ]], {
                peg.define_value("add", add),
                peg.define_value("number", number),
            })
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
            ]], { peg.define_value("tag", tag) })
            local tree = document:match(
                "<x>hi<b>hello</b>but<b>totheend</x>")
            assert(tree.tag == "x" and tree[1] == "hi")
            assert(tree[2].tag == "b" and tree[2][1] == "hello")
        ]=])
    end)

    it("preserves convenience result shape, positions, and caching",
    function()
        run([=[
            local peg = require "titan.peg"
            local source = "{:x:..:} =x"
            assert(peg.find("hi alalo", source) == 4)
            assert(peg.find("hi alalo", source, 4) == 4)
            assert(peg.find("hi alalo", source, 5) == nil)
            assert(peg.find("hi alalo", "{'al'}", 5) == 6)
            assert(peg.find("", "!.") == 1)
            assert(peg.find("alo", "!.") == 4)

            local first, last, surplus =
                peg.find("alo", "{.}{'o'}")
            assert(first == 2 and last == 3 and surplus == nil)
            local missing_first, missing_last =
                peg.find("alo", "'z'")
            assert(select("#", peg.find("alo", "'z'")) == 2)
            assert(missing_first == nil and missing_last == nil)
            assert(select("#", peg.find("alo", "'a'")) == 2)
            local empty_first, empty_last = peg.find("", "''")
            assert(empty_first == 1 and empty_last == 0)

            assert(peg.find("abc", "'c'", 0) == nil)
            assert(peg.find("abc", "'c'", -1) == 3)
            assert(peg.find("abc", "'c'", -99) == 3)
            assert(peg.find("abc", "'c'", 99) == nil)

            assert(peg.gsub("alo alo", "[abc]", "x") == "xlo xlo")
            assert(peg.gsub("alo alo", "%w+", ".") == ". .")
            local function upper(text) return text:upper() end
            assert(peg.gsub(
                "hi, how are you", "[aeiou]", upper) ==
                "hI, hOw ArE yOU")
            assert(peg.gsub("abc", peg.literal("b"), "X") == "aXc")
            assert(peg.match("abc", peg.literal("a")) == 2)
            assert(peg.find("abc", peg.literal("b")) == 2)

            local first_compile = peg.compile("'cached'")
            local second_compile = peg.compile("'cached'")
            assert(rawequal(first_compile, second_compile))

            local weak = setmetatable({}, { __mode = "v" })
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
            assert(peg.match("A9", "%w+") == 3)
            assert(peg.match("!", "%W") == 2)
            assert(peg.match("\n", "%nl") == 2)
            assert(peg.match("7", "[_%w]") == 2)
            assert(peg.match("!", "[^%w]") == 2)

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
