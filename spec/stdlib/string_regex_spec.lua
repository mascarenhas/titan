-- Byte-regex behavior is a standard-library integration suite and therefore
-- runs outside LuaCov. The first matrix is a literal Titan port of the 89
-- assertions exercised by the six pinned ta-regex test programs, followed by
-- the corrected-defect and public-API contract.
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

describe("titan.string regex", function()
    local workspace
    local layout

    setup(function()
        assert.truthy(exists(LPEGLABEL_ARCHIVE),
            "run make lpeglabel before regex specs")
        workspace = async_stdlib.workspace("string-regex")
        for _, name in ipairs({
            "peg", "native", "combinators", "captures",
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

    it("ports the pinned ta-regex 89-assertion behavior corpus",
    function()
        run([=[
            local str = require "titan.string"
            local cases = {
                {"foo", "xxfooy", "foo"},
                {"foo", "bar", false},
                {"f.o", "xxfoo", "foo"},
                {".", "\n", false},
                {"[ab]", "xb", "b"},
                {"[A-Z]+", "xABCy", "ABC"},
                {"[ab]", "x", false},
                {"[^ab]+", "abXYZ", "XYZ"},
                {"\\w+", "--abc", "abc"},
                {"\\w+", "--9", "9"},
                {"\\w+", "--_", "_"},
                {"\\w", "\x80", false},
                {"\\W", "-", "-"},
                {"\\d+", "a123", "123"},
                {"\\D+", "1abc", "abc"},
                {"\\s", " x", " "},
                {"\\s", "\t", "\t"},
                {"\\s", "\v", "\v"},
                {"\\s", "\n", "\n"},
                {"\\s", "\r", "\r"},
                {"\\s", "\f", false},
                {"\\S", "\f", "\f"},
                {"\\t", "\t", "\t"},
                {"\\n", "\n", "\n"},
                {"\\r", "\r", "\r"},
                {"\\f", "\f", "\f"},
                {"\\e", "\27", "\27"},
                {"\\a", "\7", "\7"},
                {"\\.", ".", "."},
                {"\\*", "*", "*"},
                {"\\+", "+", "+"},
                {"\\?", "?", "?"},
                {"\\(x\\)", "(x)", "(x)"},
                {"\\[x\\]", "[x]", "[x]"},
                {"\\{x\\}", "{x}", "{x}"},
                {"foo|bar", "xxfoo", "foo"},
                {"foo|bar", "xxbar", "bar"},
                {"a|ab", "ab", "a"},
                {"ab", "zab", "ab"},
                {"", "abc", ""},
                {"|", "abc", ""},
                {"a|", "b", ""},
                {"(ab)", "zab", "ab"},
                {"((a)b)", "zab", "ab"},
                {"(?:ab)", "zab", "ab"},
                {"a*", "bbb", ""},
                {"a*", "aaab", "aaa"},
                {"a+", "baa", "aa"},
                {"a+", "bbb", false},
                {"ab?", "a", "a"},
                {"ab?", "ab", "ab"},
                {"a{3}", "aaaa", "aaa"},
                {"a{2,}", "baaa", "aaa"},
                {"a{2,}", "ba", false},
                {"a{2,3}", "aaaa", "aaa"},
                {"a{2,3}b", "aab", "aab"},
                {"(a)+", "aaa", "aaa"},
                {"^a", "abc", "a"},
                {"^a", "ba", false},
                {"a$", "ba", "a"},
                {"^a|b$", "xxb", false},
                {"^a|b$", "b", "b"},
                {"\\<foo", " foo", "foo"},
                {"\\<foo", "afoo", false},
                {"foo\\>", "foo!", "foo"},
                {"(a)\\1", "zaa", "aa"},
                {"(a)\\1", "zab", false},
                {"(a)\\1b", "zaab", "aab"},
                {"[-a]+", "--a", "--a"},
                {"[a-]+", "--a", "--a"},
                {"[a\\-]+", "--a", "--a"},
                {"[a\\]]+", "]]a", "]]a"},
                {"\x80", "x\x80", "\x80"},
                {"a\0b", "xa\0b", "a\0b"},
                {".", "\xff", "\xff"},
                {".", "\r", "\r"},
                {"|a", "a", ""},
                {"()", "abc", ""},
                {"(?:)", "abc", ""},
                {"(a){0}", "a", ""},
                {"(a){0,1}", "a", "a"},
                {"\\d{2}", "x42", "42"},
                {"[\\dA-F]+", "xA9F", "A9F"},
                {"\\W", "9", false},
                {"\\$", "$", "$"},
                {"\\^", "^", "^"},
                {"\\|", "|", "|"},
                {"\\\\", "\\", "\\"},
                {"$", "abc", ""},
            }
            assert(#cases == 89)
            for index, case in ipairs(cases) do
                local found = str.compile_regex(case[1]):find(case[2])
                local actual = found and found:whole() or false
                assert(actual == case[3],
                    ("case %d / %q / %q: %q ~= %q"):format(
                        index, case[1], case[2],
                        tostring(actual), tostring(case[3])))
            end
        ]=])
    end)

    it("implements compiled spans, captures, result shapes, and positions",
    function()
        run([=[
            local str = require "titan.string"
            local regex = str.compile_regex("(a|(b))+(c)?")
            assert(regex:source() == "(a|(b))+(c)?")
            assert(regex:group_count() == 3)
            local found = regex:find("xxabb", 1)
            assert(found and found:whole() == "abb")
            assert(found:group_count() == regex:group_count())
            assert(found:group(1) == "b")
            assert(found:group(2) == "b")
            assert(found:group(3) == nil)
            local span = found:span()
            assert(span.first == 3 and span.last == 5)
            span.first = 99
            assert(found:span().first == 3)
            local group_span = found:group_span(1)
            group_span.first = 99
            assert(found:group_span(1).first == 5)
            assert(not pcall(found.group, found, 0))
            assert(not pcall(found.group_span, found, 4))

            local packed = table.pack(str.find("a", "(a)?(b)?"))
            assert(packed.n == 4 and packed[1] == 1 and
                   packed[2] == 1 and packed[3] == "a" and
                   packed[4] == nil)
            packed = table.pack(str.find("x", "z"))
            assert(packed.n == 1 and packed[1] == nil)
            packed = table.pack(str.match("a", "(a)?(b)?"))
            assert(packed.n == 2 and packed[1] == "a" and
                   packed[2] == nil)
            packed = table.pack(str.match("xxab", "ab"))
            assert(packed.n == 1 and packed[1] == "ab")

            assert(str.match("ba", "^a", 2) == "a")
            assert(str.match("ba", "^a", 1) == nil)
            assert(str.match("ba", "^b", 0) == "b")
            assert(str.match("ba", "^b", -99) == "b")
            assert(str.match("ba", "^a", -1) == "a")
            assert(str.match("ba", "a", 4) == nil)
            assert(str.match("", "^$", 1) == "")
        ]=])
    end)

    it("corrects continuation, group accounting, classes, and backreferences",
    function()
        run([=[
            local str = require "titan.string"
            assert(str.match("aaab", "a*ab") == "aaab")
            assert(str.match("aaab", "a+ab") == "aaab")
            assert(str.match("aab", "(a)\\1b") == "a")
            assert(str.match("aa", "((a))\\1") == "a")
            assert(str.match("b", "(a)|(b)\\1") == nil)

            local nested = str.compile_regex("(ab*)+"):find("xxabbbab!")
            assert(nested and nested:whole() == "abbbab")
            assert(nested:group(1) == "ab")
            nested = str.compile_regex("(a+b+)*"):find("aaabbabx")
            assert(nested and nested:whole() == "aaabbab")
            assert(nested:group(1) == "ab")
            nested = str.compile_regex(
                "((?:ab*)+)-\\1"):find("xabbbab-abbbab!")
            assert(nested and nested:whole() == "abbbab-abbbab")
            assert(nested:group(1) == "abbbab")

            for _, expression in ipairs({
                "(a){0}", "(a){2}", "(a){2,}", "(a){2,4}",
            }) do
                assert(str.compile_regex(expression):group_count() == 1)
            end
            assert(str.compile_regex("(a)?\\1"):match("") == nil)
            assert(str.compile_regex("(a?)\\1"):match("") == "")

            assert(str.match("\0\xff", "[\0\xff]+") == "\0\xff")
            assert(str.match("\r", ".") == "\r")
            assert(str.match("\n", ".") == nil)
            assert(str.match("\v", "\\s") == "\v")
            assert(str.match("\f", "\\s") == nil)
            assert(str.match("\f", "\\S") == "\f")
            assert(str.match(" foo", "\\<foo") == "foo")
            assert(str.match("foo!", "foo\\>") == "foo")
            assert(str.match("-ac", "[-a-c]+") == "-ac")
            assert(str.match("c-", "[a-c-]+") == "c-")
            assert(str.match("a-c", "[a\\-c]+") == "a-c")
        ]=])
    end)

    it("reports stable labeled syntax and semantic diagnostics",
    function()
        run([=[
            local str = require "titan.string"
            local function diagnostic(expression, label)
                local ok, err = pcall(str.compile_regex, expression)
                assert(not ok, expression)
                err = tostring(err)
                assert(err:find("[" .. label .. "]", 1, true), err)
                assert(err:find("(byte ", 1, true), err)
                assert(err:find("\n", 1, true), err)
                assert(err:sub(-1) == "^", err)
                return err
            end

            diagnostic("*a", "misplaced_quantifier")
            local exact = diagnostic("a{5,2}", "bad_quantifier_bounds")
            assert(exact ==
                "invalid regular expression [bad_quantifier_bounds] " ..
                "at L1:C6 (byte 6): maximum repeat is smaller than minimum\n" ..
                "a{5,2}\n     ^")
            diagnostic("(a", "expected_group_close")
            local crlf_eof =
                diagnostic("a|\r\n[", "expected_class_close")
            assert(crlf_eof:find(
                "at L2:C2 (byte 6)", 1, true), crlf_eof)
            diagnostic("[]", "empty_class")
            diagnostic("[^]", "empty_class")
            diagnostic("[z-a]", "bad_range")
            diagnostic("[\\d-a]", "bad_range")
            diagnostic("[a-b-c]", "bad_range")
            diagnostic("[a-b--d]", "bad_range")
            diagnostic("\\", "dangling_escape")
            diagnostic("\\v", "unsupported_escape")
            local crlf_target =
                diagnostic("a\\\r\n", "unsupported_escape")
            assert(crlf_target ==
                "invalid regular expression [unsupported_escape] " ..
                "at L2:C1 (byte 4): unsupported escape\n\n^")
            diagnostic("\\10", "unsupported_escape")
            diagnostic("\\1", "invalid_backreference")
            diagnostic("(\\1a)", "invalid_backreference")
            diagnostic("a{,2}", "bad_quantifier")
            diagnostic("a**", "bad_quantifier")
            diagnostic("(a?)*", "nullable_repetition")
            diagnostic("(a?)\\1*", "nullable_repetition")
            diagnostic("a$b", "misplaced_anchor")
            diagnostic("a^b", "misplaced_anchor")
            diagnostic("($)", "misplaced_anchor")
            diagnostic("(a$)", "misplaced_anchor")
            diagnostic("a{10000}", "pattern_too_large")
            local after_prefix =
                diagnostic("prefixa{10000}", "pattern_too_large")
            assert(after_prefix:find(
                "at L1:C8 (byte 8)", 1, true), after_prefix)
            local after_newline =
                diagnostic("prefix\na{10000}", "pattern_too_large")
            assert(after_newline:find(
                "at L2:C2 (byte 9)", 1, true), after_newline)

            local groups198 = string.rep("()", 198)
            local regex = str.compile_regex(groups198)
            assert(regex:group_count() == 198)
            assert(select("#", str.find("", groups198)) == 200)
            diagnostic(string.rep("()", 199), "too_many_captures")
            diagnostic(string.rep("()", 200), "too_many_captures")
        ]=])
    end)

    it("preserves typed iteration and Lua empty-match progress",
    function()
        run([=[
            local str = require "titan.string"
            local iterator = str.gmatch("b a", "(a)|(b)")
            local seen = {}
            for found in iterator do
                seen[#seen + 1] = {
                    found:whole(), found:group(1), found:group(2),
                }
            end
            assert(#seen == 2)
            assert(seen[1][1] == "b" and seen[1][2] == nil and
                   seen[1][3] == "b")
            assert(seen[2][1] == "a" and seen[2][2] == "a" and
                   seen[2][3] == nil)

            local cases = {
                {"a", {"a"}, "X", 1},
                {"ba", {"", "a"}, "XbX", 2},
                {"ab", {"a", ""}, "XbX", 2},
                {"", {""}, "X", 1},
            }
            for _, case in ipairs(cases) do
                local values = {}
                local next_match = str.gmatch(case[1], "a*")
                while true do
                    local found = next_match()
                    if not found then break end
                    values[#values + 1] = found:whole()
                end
                assert(#values == #case[2])
                for index = 1, #values do
                    assert(values[index] == case[2][index])
                end
                local output, count =
                    str.gsub(case[1], "a*", "X")
                assert(output == case[3] and count == case[4])
            end
        ]=])
    end)

    it("implements every replacement form, nil slot, and maximum",
    function()
        run([=[
            local str = require "titan.string"
            local output, count =
                str.gsub("ab a", "(a)(b)?", "<%0:%1:%2:%%>")
            assert(output == "<ab:a:b:%> <a:a::%>" and count == 2)
            output, count = str.gsub("a a", "a", 42)
            assert(output == "42 42" and count == 2)

            local calls = {}
            output, count = str.gsub("b ab", "(a)?b",
                function(...)
                    calls[#calls + 1] = table.pack(...)
                    if select(1, ...) == nil then return false end
                    return "[" .. select(1, ...) .. "]"
                end)
            assert(output == "b [a]" and count == 2)
            assert(calls[1].n == 1 and calls[1][1] == nil)

            local lookup = setmetatable({a = "A"}, {
                __index = function(_, key)
                    assert(key == nil or key == "b")
                    return key and "B" or false
                end,
                __call = function() error("must not call table") end,
            })
            output, count = str.gsub("a b", "(a)|(b)", lookup)
            assert(output == "A b" and count == 2)

            output, count = str.gsub("aaaa", "a", "X", 2)
            assert(output == "XXaa" and count == 2)
            output, count = str.gsub("aaaa", "a", "X", 0)
            assert(output == "aaaa" and count == 0)
            output, count = str.gsub("a", "a", function() return nil end)
            assert(output == "a" and count == 1)

            assert(not pcall(str.gsub, "a", "a", "%"))
            assert(not pcall(str.gsub, "a", "a", "%1"))
            assert(not pcall(str.gsub, "a", "a", true))
            assert(not pcall(str.gsub, "a", "a", true, 0))
            assert(not pcall(str.gsub, "a", "a", io.stdout))
            assert(not pcall(str.gsub, "a", "a",
                function() return {} end))
            assert(not pcall(str.gsub, "a", "a",
                setmetatable({}, {
                    __index = function() error("lookup exploded") end,
                })))
            assert(str.gsub("a", "a", "ok") == "ok")
        ]=])
    end)

    it("keeps compiled backreferences, iterators, and replacement callbacks rooted across repeated full and generational GC",
    function()
        run([=[
            local str = require "titan.string"
            collectgarbage("generational")
            local iterator
            do
                local regex =
                    str.compile_regex("((a|b)+)-\\1")
                iterator = regex:gmatch(
                    "ab-ab xx b-b aa-aa")
            end
            for _ = 1, 12 do collectgarbage("collect") end
            local values = {}
            while true do
                collectgarbage("collect")
                local found = iterator()
                if not found then break end
                values[#values + 1] = found:whole()
                assert(found:group(1) ..
                       "-" .. found:group(1) == found:whole())
            end
            assert(table.concat(values, ",") ==
                   "ab-ab,b-b,aa-aa")

            local callback_calls = 0
            local output, count = str.gsub(
                "ab-ab b-b", "((a|b)+)-\\1",
                function(first, second)
                    callback_calls = callback_calls + 1
                    collectgarbage("collect")
                    assert(first and second)
                    return "<" .. first .. ">"
                end)
            assert(output == "<ab> <b>" and count == 2)
            assert(callback_calls == 2)

            collectgarbage("incremental")
            for _ = 1, 12 do collectgarbage("collect") end
            assert(str.match("zz-aa-aa", "((a)+)-\\1") == "aa")
        ]=])
    end)
end)
