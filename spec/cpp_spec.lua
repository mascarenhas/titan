local temporary = require "spec.support.temporary"
-- Tests for the hand-written C preprocessor used by the FFI (`foreign
-- import`). These pin the macro-expansion and conditional-compilation
-- contract so that refactors of the macro loop detection (and the rest of
-- cpp.lua) are safe to attempt -- there was previously no coverage here.
--
-- The recursion-guard cases below are the ones that matter most: removing
-- the "blue paint" mark for function-like macros makes them loop forever.
-- The instruction budget in `expand` turns such a regression into a clean
-- test failure instead of a hung suite.

local cpp = require "c-parser.cpp"
local c99 = require "c-parser.c99"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"

-- Run the preprocessor over `src` (a chunk of C) in isolation -- an empty
-- define set and no system include paths, so nothing is pulled in from the
-- host toolchain. Returns the context, or nil and the diagnostic, then the
-- name `src` was read under. A Lua error fails the calling test.
local function preprocess_source(src)
    local tmp = temporary.name()
    local f = assert(io.open(tmp, "wb"))
    f:write(src)
    f:close()
    local fd = assert(io.open(tmp, "rb"))
    local ctx = {
        incdirs = {},
        defines = {},
        ifmode = { true },
        output = {},
        current_dir = {},
    }
    -- Abort runaway expansion (an unbounded loop would otherwise hang busted).
    -- Legitimate expansions finish in a few thousand VM instructions; this is
    -- many orders of magnitude more headroom.
    local previous_hook, previous_mask, previous_count = debug.gethook()
    debug.sethook(function()
        error("cpp expansion exceeded its instruction budget "
            .. "(likely unbounded macro recursion)", 2)
    end, "", 20000000)
    local ok, rctx, err = pcall(cpp.parse_file, tmp, fd, ctx)
    debug.sethook(previous_hook, previous_mask, previous_count)
    os.remove(tmp)
    assert(ok, rctx)  -- on a hook/runtime error, rctx is the message
    return rctx, err, tmp
end

-- The output lines of `src` joined by a space; a diagnostic fails the test.
local function expand(src)
    local ctx, err = preprocess_source(src)
    assert(ctx, err) -- parse_file returned (nil, err)
    return table.concat(ctx.output, " ")
end

-- Ask the configured host preprocessor for the spelling of one output line.
-- This keeps the stringification differential focused: directives are
-- suppressed with -P, and surrounding newlines are not part of the contract.
local function host_expand(src)
    local tmp = temporary.name(".c")
    local f = assert(io.open(tmp, "wb"))
    f:write(src)
    f:close()
    local compiler = assert(cpp.split_shell_words(os.getenv("CC") or "cc"))
    table.insert(compiler, "-E")
    table.insert(compiler, "-P")
    table.insert(compiler, "-x")
    table.insert(compiler, "c")
    table.insert(compiler, tmp)
    local result = cpp.capture_command(compiler)
    os.remove(tmp)
    assert.is_true(result.started, result.diagnostic)
    assert.is_true(result.ok, result.diagnostic)
    return result.output:match("^%s*(.-)%s*$")
end

-- Preprocess `src` like the FFI does, then run the C99 declaration grammar
-- (c-parser/c99.lua) over the result. Returns (parsed_ok, recoveries) where
-- `recoveries` is how many top-level declarations the error-recovery rule had
-- to skip. This exercises the grammar pieces the FFI needs for real system
-- headers (extended floats, _Static_assert, function-body skipping, recovery).
local function parse_decls(src)
    local res = c99.match_language_grammar(expand(src) .. " $EOF$")
    return res ~= nil, c99.recoveries, res and #res or 0, res
end

describe("c preprocessor (cpp)", function()
    it("uses native spelling for absolute lookup paths",
    function()
        if platform.windows then
            -- Windows absolute paths use lexical normalization.
            assert.equal("C:/work/root/header.h",
                cpp.absolute_lookup_path("./header.h", "C:/work//root"))
            assert.equal("C:/sdk/include/api.h",
                cpp.absolute_lookup_path(
                    "C:/sdk/link/../include/./api.h", "C:/ignored"))
            assert.equal("//server/share/api.h",
                cpp.absolute_lookup_path(
                    [[\\server\share\\.\api.h]], "C:/ignored"))
            assert.equal("C:/server/share.h",
                cpp.absolute_lookup_path("/server/share.h", "C:/ignored"))
            assert.equal("C:/sdk/include/api.h",
                cpp.absolute_lookup_path(
                    "C:/sdk///link/../include/api.h", "C:/ignored"))
            return
        end
        assert.equal("/work//root/header.h",
            cpp.absolute_lookup_path("./header.h", "/work//root"))
        assert.equal("/sdk/link/../include/api.h",
            cpp.absolute_lookup_path(
                "/sdk/link/../include/./api.h", "/ignored"))
        assert.equal("//server/share//api.h",
            cpp.absolute_lookup_path(
                "//server/./share//api.h", "/ignored"))
        assert.equal("/server/share.h",
            cpp.absolute_lookup_path(
                "/.//server/share.h", "/ignored"))
        assert.equal("//server/share.h",
            cpp.absolute_lookup_path(
                "//.///server/share.h", "/ignored"))
        assert.equal("/sdk///link/../include/api.h",
            cpp.absolute_lookup_path(
                "/sdk///link/../include/api.h", "/ignored"))
    end)

    it("treats include-search observer failure as terminal", function()
        local root = temporary.name()
        os.remove(root)
        assert(lfs.mkdir(root))
        local fallback = root .. "/fallback"
        assert(lfs.mkdir(fallback))
        local main = root .. "/main.h"
        local nested = root .. "/nested.h"
        local fallback_nested = fallback .. "/nested.h"
        local output = assert(io.open(main, "wb"))
        assert(output:write('#include "nested.h"\n'))
        assert(output:close())
        output = assert(io.open(fallback_nested, "wb"))
        assert(output:write("typedef int observer_was_swallowed;\n"))
        assert(output:close())

        local observed = {}
        local ctx = {
            incdirs = { quote = {}, system = { fallback } },
            defines = {},
            ifmode = { true },
            output = {},
            current_dir = {},
            include_search_observer = function(path)
                observed[#observed + 1] = path
                if path == nested then
                    return nil, "injected include observation failure"
                end
                return true
            end,
        }
        local parsed, err = cpp.parse_file(
            main, assert(io.open(main, "rb")), ctx)
        assert.is_nil(parsed)
        assert.matches("injected include observation failure", err, 1, true)
        assert.same({ nested }, observed)

        assert(os.remove(fallback_nested))
        assert(os.remove(main))
        assert(lfs.rmdir(fallback))
        assert(lfs.rmdir(root))
    end)

    for _, ending in ipairs({ "\n", "\r\n" }) do
        it("finds headers from " .. (ending == "\n" and "LF" or "CRLF")
            .. " compiler include output without trimming path bytes", function()
            local strategy = require("titan-compiler.io").new_sync()
            local root = temporary.name()
            assert(strategy:unlink(root))
            -- Ordinary Windows directory names cannot retain a trailing space.
            local windows = platform.windows
            root = root .. (windows and "-cpp include path" or "-cpp include ")
            assert(lfs.mkdir(root))
            local header = root .. "/discovered.h"
            local file = assert(io.open(header, "wb"))
            assert(file:write("int discovered_header;\n"))
            assert(file:close())
            local completed, failure = xpcall(function()
                strategy.run = function(_, argv)
                    local verbose = false
                    for _, word in ipairs(argv) do
                        if word == "-v" then verbose = true end
                    end
                    return {
                        started = true, ok = true, why = "exit", status = 0,
                        output = verbose and table.concat({
                            '#include "..." search starts here:',
                            '#include <...> search starts here:',
                            " " .. root,
                            "End of search list.", "",
                        }, ending) or "",
                    }
                end
                local context = assert(cpp.new_context({
                    compiler = { "cc" }, fixed_include_dirs = {}, io = strategy,
                }))
                assert.same({ quote = {}, system = { root } }, context.incdirs)
                local parsed, err = cpp.parse_contents("input.c",
                    "#include <discovered.h>\n", context)
                assert.truthy(parsed, err)
                assert.matches("int discovered_header ;",
                    table.concat(context.output, " "), 1, true)
            end, debug.traceback)
            assert(os.remove(header))
            assert(lfs.rmdir(root))
            assert(completed, failure)
        end)
    end

    describe("shell argument handling", function()
        it("splits quoted and escaped paths without losing argument boundaries", function()
            local words = assert(cpp.split_shell_words(
                [[-I'/tmp/include path' -DNAME="two words" plain\ value '' ]]))
            assert.same({
                "-I/tmp/include path",
                "-DNAME=two words",
                "plain value",
                "",
            }, words)
        end)

        it("quotes arbitrary paths for a lossless shell round trip", function()
            local values = {
                "",
                "plain",
                "/tmp/a path/header.h",
                "single'quote and spaces",
                "dollar$backtick`semicolon;",
            }
            for _, value in ipairs(values) do
                local quoted = assert(cpp.shell_quote(value))
                assert.same({ value }, assert(cpp.split_shell_words(quoted)))
            end
        end)

        it("rejects malformed shell strings instead of guessing", function()
            local words, err = cpp.split_shell_words("-I'unfinished")
            assert.is_nil(words)
            assert.matches("unterminated single quote", err)

            words, err = cpp.split_shell_words('-DNAME="unfinished')
            assert.is_nil(words)
            assert.matches("unterminated double quote", err)

            words, err = cpp.split_shell_words("-I/tmp/path\\")
            assert.is_nil(words)
            assert.matches("trailing backslash", err)
        end)

        it("fails closed for opaque preprocessing argument encodings",
        function()
            local cases = {
                { { "@compiler-options.rsp" }, "response%-file" },
                { { "-Wp,-include,forced.h" }, "pass%-through" },
                { { "-Xpreprocessor", "-include" }, "pass%-through" },
                { { "-include-pch", "forced.pch" }, "opaque" },
            }
            for _, case in ipairs(cases) do
                local ctx, err = cpp.new_context({
                    compiler = { "cc" },
                    compile_flags = case[1],
                    fixed_include_dirs = {},
                })
                assert.is_nil(ctx)
                assert.matches(case[2], err)
            end
        end)

        it("treats equals as part of a joined forced-header operand",
        function()
            local ctx, err = cpp.new_context({
                compiler = { "cc" },
                compile_flags = { "-include=titan-not-present.h" },
                fixed_include_dirs = {},
            })
            assert.is_nil(ctx)
            assert.matches("'=titan%-not%-present%.h'", err)
        end)

        it("partitions preprocessor contexts by exact compiler flags",
        function()
            local compiler = assert(
                cpp.split_shell_words(os.getenv("CC") or "cc"))
            local function context(compile_flags)
                return assert(cpp.new_context({
                    compiler = compiler,
                    language_mode = "c99",
                    compile_flags = compile_flags,
                    fixed_include_dirs = {},
                }))
            end

            local ordinary = context({})
            local warnings = context({ "-Wall" })
            assert.not_equal(ordinary.preprocessor_configuration_key,
                warnings.preprocessor_configuration_key)
        end)

        it("keys forced headers by exact operand spelling and contents",
        function()
            local root = temporary.name("-cpp-forced-identity")
            os.remove(root)
            assert(lfs.mkdir(root))
            local header = root .. "/forced.h"
            local output = assert(io.open(header, "wb"))
            assert(output:write([[
#ifndef TITAN_CPP_FORCED_IDENTITY
#define TITAN_CPP_FORCED_IDENTITY 1
#endif
]]))
            assert(output:close())

            local completed, failure = xpcall(function()
                local compiler = assert(
                    cpp.split_shell_words(os.getenv("CC") or "cc"))
                local function context(flags)
                    return assert(cpp.new_context({
                        compiler = compiler,
                        language_mode = "c99",
                        compile_flags = flags,
                        fixed_include_dirs = {},
                    }))
                end

                local ordinary = context({ "-include", header })
                local equivalent = context({
                    "-include" .. root .. "/./forced.h",
                })
                assert.not_equal(ordinary.forced_header_manifest,
                    equivalent.forced_header_manifest)
                assert.not_equal(ordinary.preprocessor_configuration_key,
                    equivalent.preprocessor_configuration_key)

                local repeated_flags = {}
                -- Duplicate operands exercise manifest identity. Keep the
                -- Windows fixture within cmd's command-length limit even
                -- when the private checkout has a long absolute pathname.
                local repetitions = platform.windows and 4 or 64
                for _ = 1, repetitions do
                    repeated_flags[#repeated_flags + 1] = "-include"
                    repeated_flags[#repeated_flags + 1] = header
                end
                local repeated = context(repeated_flags)
                assert.is_true(#repeated.forced_header_manifest >
                    #ordinary.forced_header_manifest)
                assert.not_equal(ordinary.preprocessor_configuration_key,
                    repeated.preprocessor_configuration_key)

                local stamp = assert(lfs.attributes(header, "modification"))
                output = assert(io.open(header, "wb"))
                assert(output:write([[
#ifndef TITAN_CPP_FORCED_IDENTITY
#define TITAN_CPP_FORCED_IDENTITY 2
#endif
]]))
                assert(output:close())
                assert(lfs.touch(header, stamp + 1, stamp + 1))
                local changed = context({ "-include", header })
                assert.not_equal(ordinary.forced_header_manifest,
                    changed.forced_header_manifest)
                assert.not_equal(ordinary.preprocessor_configuration_key,
                    changed.preprocessor_configuration_key)
            end, debug.traceback)

            os.remove(header)
            lfs.rmdir(root)
            assert.truthy(completed, failure)
        end)

        it("normalizes a shell-reported child signal as interruption",
            function()
                if platform.windows then
                    pending("POSIX shell signal status is unavailable through native Windows process transport")
                    return
                end
                local result = cpp.capture_command({
                    "/bin/sh", "-c", "kill -TERM $$",
                })
                assert.is_true(result.started)
                assert.is_false(result.ok)
                assert.is_true(result.interrupted)
                assert.equal("signal", result.why)
                assert.equal(15, result.signal)
                assert.equal(15, result.status)
                assert.equal(143, result.shell_status)
            end)

    end)

    describe("object-like macros", function()
        it("substitutes a simple value", function()
            assert.equal("42", expand("#define N 42\nN\n"))
        end)
        it("substitutes a multi-token body", function()
            assert.equal("3 + 4", expand("#define P 3 + 4\nP\n"))
        end)
        it("stops substituting after #undef", function()
            assert.equal("X", expand("#define X 1\n#undef X\nX\n"))
        end)
    end)

    describe("function-like macros", function()
        it("expands with one argument", function()
            assert.equal("( ( 5 ) * ( 5 ) )",
                expand("#define SQ(x) ((x)*(x))\nSQ(5)\n"))
        end)
        it("expands with multiple arguments", function()
            assert.equal("1 + 2", expand("#define ADD(a,b) a + b\nADD(1, 2)\n"))
        end)
        it("substitutes every standard variadic macro argument", function()
            assert.equal("call ( a , b + c , d )", expand([[
#define CALL(...) call(__VA_ARGS__)
CALL(a, b + c, d)
]]))
            assert.equal("head : tail1 , tail2", expand([[
#define PREFIX(head, ...) head : __VA_ARGS__
PREFIX(head, tail1, tail2)
]]))
            assert.equal('"a, b + c"', expand([[
#define STRINGIZE(...) #__VA_ARGS__
STRINGIZE(a, b + c)
]]))
            assert.equal("call ( )", expand([[
#define CALL(...) call(__VA_ARGS__)
CALL()
]]))
            assert.equal("void f ( int , ... ) ;", expand([[
#define DECL(name, ...) void name(int, ...);
DECL(f, ignored, extras)
]]))
        end)
        it("expands repeated uses independently", function()
            assert.equal("( 1 ) ( 2 ) ( 3 )",
                expand("#define F(x) (x)\nF(1) F(2) F(3)\n"))
        end)
        it("does not expand a function-like name that is not a call", function()
            -- the inner F is just an argument token, not followed by '('
            assert.equal("F", expand("#define F(x) x\nF(F)\n"))
        end)
    end)

    describe("nested and rescanned expansion", function()
        it("rescans the result of an expansion", function()
            assert.equal("1", expand("#define ID(x) x\nID(ID(ID(1)))\n"))
        end)
        it("follows a chain of macros", function()
            assert.equal("5", expand(
                "#define a(x) b(x)\n#define b(x) c(x)\n#define c(x) x\na(5)\n"))
        end)
        it("expands a function-like macro inside an argument", function()
            assert.equal("( ( ( 1 ) ) )",
                expand("#define F(x) (x)\nF(F(F(1)))\n"))
        end)
        it("expands a call produced by an object-like macro", function()
            assert.equal("7", expand("#define F(x) x\n#define G F(7)\nG\n"))
        end)
        it("expands an argument used more than once in the body", function()
            assert.equal("1 + 1 + 2 + 2 + 3 + 3",
                expand("#define F(x) x+x\nF(1)+F(2)+F(3)\n"))
        end)
        it("handles nested function-like calls", function()
            assert.equal(
                "( ( ( ( 1 ) > ( 2 ) ? ( 1 ) : ( 2 ) ) ) > ( 3 ) ? "
                .. "( ( ( 1 ) > ( 2 ) ? ( 1 ) : ( 2 ) ) ) : ( 3 ) )",
                expand("#define MAX(a,b) ((a)>(b)?(a):(b))\nMAX(MAX(1,2),3)\n"))
        end)
    end)

    describe("recursion guards (must terminate, not loop)", function()
        -- These encode the C "no recursive expansion" rule. They are exactly
        -- what regresses if the function-like macro is no longer marked to
        -- prevent re-expansion (see the rejected PR #11): each would otherwise
        -- expand forever.
        it("preserves active recursion guards through argument prescan", function()
            -- MinGW's _HUGE imports use an object macro that names itself
            -- inside the argument of a function-like token-pasting macro.
            local source = [[
#define CAT_RAW(a,b) a ## b
#define CAT(a,b) CAT_RAW(a,b)
#define IMPORT(sym) CAT(__imp_,sym)
#define VALUE (*IMPORT(VALUE))
#define HUGE VALUE
HUGE
VALUE
]]
            assert.equal("( * __imp_VALUE ) ( * __imp_VALUE )", expand(source))
            assert.same(cpp.tokenize(host_expand(source)), cpp.tokenize(expand(source)))
        end)
        it("extends ancestor recursion guards when an object replacement grows", function()
            local source = [[
#define A B
#define B (*F(A))
#define F(x) x
A F(7)
]]
            assert.equal("( * A ) 7", expand(source))
            assert.same(cpp.tokenize(host_expand(source)), cpp.tokenize(expand(source)))
        end)
        it("expires object aliases before prescanning caller-owned arguments", function()
            local source = [[
#define A F
#define F(x) STR(x)
#define STR(x) RAW(x)
#define RAW(x) #x
A(A)
A(F(A))
]]
            assert.equal([=["F" "\"F\""]=], expand(source))
            assert.same(cpp.tokenize(host_expand(source)), cpp.tokenize(expand(source)))
        end)
        it("prescans repeated function names before disabling their replacement", function()
            local source = [[
#define F(x) x + 1
#define WRAP(x) F(x)
F(F(1)) WRAP(F(2)) F(3)
]]
            assert.equal("1 + 1 + 1 2 + 1 + 1 3 + 1", expand(source))
            assert.same(cpp.tokenize(host_expand(source)), cpp.tokenize(expand(source)))
        end)
        it("stops a self-referential function-like macro", function()
            assert.equal("F ( 1 )", expand("#define F(x) F(x)\nF(1)\n"))
        end)
        it("stops mutually-recursive function-like macros", function()
            assert.equal("A ( 1 )",
                expand("#define A(x) B(x)\n#define B(x) A(x)\nA(1)\n"))
        end)
        it("stops a self-referential object-like macro", function()
            assert.equal("A", expand("#define A A\nA\n"))
        end)
        it("stops indirectly-recursive object-like macros", function()
            assert.equal("A", expand("#define A B\n#define B A\nA\n"))
        end)
    end)

    describe("stringize and token paste", function()
        it("stringizes an argument with #", function()
            assert.equal('"hello"', expand("#define STR(x) #x\nSTR(hello)\n"))
        end)
        it("stringizes raw tokens without expanding macro arguments", function()
            assert.equal('"NAME"', expand([[
#define NAME expanded
#define STR(x) #x
STR(NAME)
]]))
        end)
        it("does not prescan an argument used only by stringize", function()
            assert.equal('"FAIL(a)"', expand([[
#define FAIL(x) x ## +
#define STR(x) #x
STR(FAIL(a))
]]))
        end)
        it("preserves adjacency and collapses only existing whitespace", function()
            assert.equal('"a+b" "a + b"', expand([[
#define STR(x) #x
STR(a+b) STR(  a   +	 b  )
]]))
        end)
        it("turns comment replacement into one stringized space", function()
            assert.equal('"a + b"', expand([[
#define STR(x) #x
STR(a/**/+/* comment */b)
]]))
        end)
        it("preserves argument spelling through a generated macro call", function()
            assert.equal('"a+b"', expand([[
#define STR(x) #x
#define APPLY(x) STR(x)
APPLY(a+b)
]]))
        end)
        it("carries whitespace across an empty prescanned macro", function()
            assert.equal('"a +b" "a++b" "a++b"', expand([[
#define STR(x) #x
#define PASS(x) STR(x)
#define EMPTY
#define EMPTY_CALL(...)
PASS(a EMPTY+b) PASS(a+EMPTY_CALL( )+b) PASS(a+EMPTY_CALL(x  , y)+b)
]]))
        end)
        it("parses an object macro if there is whitespace before the opening parenthesis", function()
            assert.equal('( 42 ) ( A )', expand([[
#define VALUE 42
#define OBJ (VALUE)
OBJ(A)
]]))
        end)
        it("keeps raw digraph spelling while expanding canonical tokens",
            function()
                assert.equal('"a %: b" "a <: b :>"', expand([[
#define STR(x) #x
STR(a %: b) STR(a <: b :>)
]]))
                assert.equal("42 foobar", expand([[
%:define VALUE 42
#define CAT(a,b) a %:%: b
VALUE CAT(foo,bar)
]]))
            end)
        it("matches the host for adjacent, spaced, and comment-separated tokens",
            function()
                local src = [=[
#define STR(x) #x
#define PASS(x) STR(x)
#define EMPTY
#define EMPTY_CALL(...)
STR(a+b) STR(  a   + b  ) STR(a/**/+b) STR("a\b") PASS(a EMPTY+b) PASS(a+EMPTY_CALL( )+b) PASS(a+EMPTY_CALL(x  , y)+b) STR(a %: b) STR(a <: b :>)
]=]
                assert.equal(host_expand(src), expand(src))
            end)
        it("escapes quotes and backslashes while stringizing", function()
            assert.equal([["\"a\\b\""]], expand([[
#define STR(x) #x
STR("a\b")
]]))
        end)
        it("pastes tokens with ##", function()
            assert.equal("foobar", expand("#define CAT(a,b) a ## b\nCAT(foo,bar)\n"))
        end)
        it("uses raw arguments for one-level paste and prescanned arguments ordinarily", function()
            assert.equal("1 2", expand([[
#define A X
#define B Y
#define AB 1
#define XY 2
#define CAT(a,b) a ## b
#define EXPAND_CAT(a,b) CAT(a,b)
CAT(A,B) EXPAND_CAT(A,B)
]]))
        end)
        it("keeps raw and expanded forms independent for repeated parameters", function()
            assert.equal("prefix_NAME expanded", expand([[
#define NAME expanded
#define BOTH(x) prefix_ ## x x
BOTH(NAME)
]]))
        end)
        it("pastes with an empty argument (placemarker)", function()
            assert.equal("acos", expand("#define CAT(x,y) x ## y\nCAT(acos,)\n"))
        end)
        it("handles empty left, right, and chained paste arguments", function()
            assert.equal("left right ac", expand([[
#define CAT(a,b) a ## b
#define CHAIN(a,b,c) a ## b ## c
CAT(,left) CAT(right,) CHAIN(a,,c)
]]))
        end)
        it("pastes only the boundary token of a multi-token raw argument", function()
            assert.equal("a + bc", expand("#define CAT(a,b) a ## b\nCAT(a + b,c)\n"))
        end)
        it("rejects a paste that does not form one preprocessing token", function()
            local ok, err = pcall(
                expand, "#define CAT(a,b) a ## b\nCAT(+,*)\n")
            assert.falsy(ok)
            assert.matches(
                "invalid preprocessing token paste at line 2: '+' ## '*'",
                tostring(err), 1, true)
        end)
        it("preserves libuv-shaped X-macro enumerator names", function()
            assert.equal("UV_EIO , UV_EOF , UV_ECANCELED ,", expand([[
#define EIO 5
#define EOF -1
#define ECANCELED 125
#define UV_ERRNO_MAP(XX) XX(EIO) XX(EOF) XX(ECANCELED)
#define XX(code) UV_ ## code ,
UV_ERRNO_MAP(XX)
]]))
        end)
        -- Regression: a paste macro reused across sibling expansions must not be
        -- suppressed by the recursion guard. This mirrors glibc's <math.h>, where
        -- __MATHCALL_VEC expands __CONCAT once via __SIMD_DECL (which used to
        -- "blue paint" it for the rest of the line) and again in the actual
        -- declaration -- the second __CONCAT(name,) was dropped, losing the
        -- function name. See shift_noloop in cpp.lua.
        it("re-expands a paste macro reused in a later sibling expansion", function()
            assert.equal(
                "simd_acos extern double acos ( double __x ) ; "
                .. "extern double __acos ( double __x )",
                expand([[
#define CAT(x,y) x ## y
#define PRECNAME(name,r) CAT(name,r)
#define SIMD(f) CAT(simd_, f)
#define DECL1_IMPL(t,f,s,a) extern t PRECNAME(f,s) a
#define DECL1(t,f,s,a) DECL1_IMPL(t,f,s,a)
#define DECL(t,f,s,a) DECL1(t,f,s,a) ; DECL1(t, CAT(__,f), s, a)
#define CALL(f,s,a) DECL(double, f, s, a)
#define VEC(f,s,a) SIMD(PRECNAME(f,s)) CALL(f,s,a)
VEC(acos,, (double __x))
]]))
        end)
    end)

    describe("conditional compilation", function()
        it("keeps an #ifdef branch when the macro is defined", function()
            assert.equal("yes",
                expand("#define FEATURE\n#ifdef FEATURE\nyes\n#endif\n"))
        end)
        it("drops an #ifdef branch when the macro is undefined", function()
            assert.equal("after", expand("#ifdef NOPE\nno\n#endif\nafter\n"))
        end)
        it("keeps an #ifndef branch when the macro is undefined", function()
            assert.equal("yes", expand("#ifndef NOPE\nyes\n#endif\n"))
        end)
        it("evaluates an #if expression", function()
            assert.equal("ok", expand("#if 1 + 1 == 2\nok\n#endif\n"))
        end)
        it("takes the #else branch when #if is false", function()
            assert.equal("b", expand("#if 0\na\n#else\nb\n#endif\n"))
        end)
        it("expands macros inside an #if condition", function()
            assert.equal("hit", expand("#define V 1\n#if V == 1\nhit\n#endif\n"))
        end)
        it("does not write malformed #if diagnostics to stdout", function()
            local original_print = _G.print
            local printed = {}
            _G.print = function(...)
                printed[#printed + 1] = table.concat({ ... }, " ")
            end
            local ok, failure = pcall(expand, "#if (\nhit\n#endif\n")
            _G.print = original_print

            assert.is_false(ok)
            assert.matches("preprocessor expression", tostring(failure), 1, true)
            assert.same({}, printed)
        end)
    end)

    -- The C99 declaration grammar (c-parser/c99.lua) consumed by the FFI. These
    -- pin the additions made so real system headers (math.h, SDL2/SDL.h, ...)
    -- can be imported: extended float keywords, _Static_assert, function-body
    -- skipping, and error recovery over declarations the grammar can't model.
    -- The C99 declaration grammar (c-parser/c99.lua) consumed by the FFI. It was
    -- essentially untested before; these pin its real behaviour. `n` is the
    -- number of top-level declaration nodes (one per declaration, not per
    -- declarator), and recoveries must be 0 for well-formed input.
    describe("c99 declaration grammar (FFI): types and declarators", function()
        local function ok_decls(src, n)
            local ok, rec, ndecls = parse_decls(src)
            assert.is_true(ok)
            assert.equal(0, rec)
            assert.equal(n, ndecls)
        end
        it("accepts the extended floating-point type keywords", function()
            ok_decls("extern _Float128 f(_Float64 a, _Float32 b, _Float16 c);\n", 1)
        end)
        it("pointers and pointer-to-pointer", function()
            ok_decls("extern int *p; extern char **q;\n", 2)
        end)
        it("arrays, sized and unsized", function()
            ok_decls("extern int a[]; extern int b[10];\n", 2)
        end)
        it("multiple declarators count as one declaration node", function()
            ok_decls("int a, b, c;\n", 1)
        end)
        it("qualifiers and storage-class specifiers", function()
            ok_decls("static const volatile int x;\n", 1)
        end)

        for _, qualifier in ipairs({
            "_Nonnull", "_Nullable", "_Null_unspecified", "_Nullable_result",
        }) do
            it("accepts Clang pointer annotation " .. qualifier .. " without recovery", function()
                local source = [[
typedef int * NULLABILITY pointer_type;
typedef void (* NULLABILITY callback_type)(const char * NULLABILITY data);
struct annotated { int * NULLABILITY field; };
void * NULLABILITY annotated_function(
    void * NULLABILITY, int * const NULLABILITY * volatile NULLABILITY);
]]
                ok_decls(source:gsub("NULLABILITY", qualifier), 4)
            end)
        end
        it("varargs and (void) parameter lists", function()
            ok_decls("int p(const char *f, ...); int q(void);\n", 2)
        end)
        it("abstract (unnamed) parameter declarators", function()
            ok_decls("int f(int, char *);\n", 1)
        end)
        it("captures suffixes on abstract parameter declarators", function()
            local ok, rec, n, parsed = parse_decls([[
                extern int f(
                    int [7],
                    int (*)(double),
                    int (*)[7]);
            ]])
            assert.is_true(ok)
            assert.equal(0, rec)
            assert.equal(1, n)

            local params = parsed[1].ids[1].decl.params
            assert.same({ "7" }, params[1].param.id[1].idx)
            assert.same({ "*" }, params[2].param.id.declarator)
            assert.same(
                { "double" }, params[2].param.id.params[1].param.type)
            assert.same({ "*" }, params[3].param.id.declarator)
            assert.same({ "7" }, params[3].param.id[1].idx)
        end)
        it("separates array parameter markers from their bounds", function()
            local ok, rec, n, parsed = parse_decls([[
                extern int f(
                    int [static const 3],
                    int [volatile static 4],
                    int [*]);
            ]])
            assert.is_true(ok)
            assert.equal(0, rec)
            assert.equal(1, n)

            local params = parsed[1].ids[1].decl.params
            assert.same({
                array_static = "static",
                array_qualifiers = { "const" },
                idx = { "3" },
            }, params[1].param.id[1])
            assert.same({
                array_static = "static",
                array_qualifiers = { "volatile" },
                idx = { "4" },
            }, params[2].param.id[1])
            assert.same({
                idx = "*",
            }, params[3].param.id[1])
        end)
        it("function-pointer parameters (qsort-style)", function()
            ok_decls("void qs(void *b, int (*cmp)(const void *, const void *));\n", 1)
        end)
        it("the hard declarators: fn-returning-fn-pointer, fn-pointer array, pointer-to-array", function()
            ok_decls("int (*signal(int, void (*)(int)))(int);\n", 1)
            ok_decls("int (*fns[3])(void); int (*p)[10];\n", 2)
        end)
        it("typedef definition then use of the typedef name", function()
            ok_decls("typedef int myint;\nmyint x;\n", 2)
        end)
        it("struct/union with fields", function()
            ok_decls("struct P { int x; int y; };\n", 1)
        end)
        it("struct bitfields, including anonymous zero-width", function()
            ok_decls("struct B { unsigned a : 3; int : 0; };\n", 1)
        end)
        it("anonymous union member inside a struct", function()
            ok_decls("struct s { int tag; union { int i; float f; }; };\n", 1)
        end)
        it("keeps anonymous struct members nested inside anonymous unions", function()
            ok_decls([[
struct Overlapped {
    unsigned long long internal;
    union {
        struct { unsigned long offset; unsigned long offset_high; };
        void *pointer;
    };
    void *event;
};
typedef struct Overlapped Overlapped;
struct Request { Overlapped overlapped; int type; };
]], 3)
        end)
        it("enum with assigned values and a trailing comma", function()
            ok_decls("enum E { A, B = 5, C, };\n", 1)
        end)
        it("constant-expression grammar in an array size (sizeof, shift, ternary)", function()
            ok_decls("int arr[(sizeof(int) << 1) > 4 ? 8 : 4];\n", 1)
        end)
        it("GCC attributes on declarations and around struct/enum tags", function()
            ok_decls("__attribute__((deprecated)) int x;\n", 1)
            ok_decls("int y __attribute__((aligned(8)));\n", 1)
            ok_decls("struct s { int x; } __attribute__((packed));\n", 1)
            ok_decls("struct __attribute__((packed)) t { int x; };\n", 1)
            ok_decls("enum e { A, B } __attribute__((packed));\n", 1)
        end)
    end)

    -- Robustness features that let the FFI read messy real headers without
    -- failing the whole import. Regressions live here too.
    describe("c99 error recovery and robustness", function()
        it("a _Static_assert injects no phantom declarations", function()
            -- regression: its constant-expression/message captures used to leak
            -- as extra top-level entries (n was 3 here instead of 1).
            local ok, rec, n = parse_decls(
                '_Static_assert(sizeof(int) == 4, "sizeof (int) == 4");\n'
                .. "extern int g(void);\n")
            assert.is_true(ok); assert.equal(0, rec); assert.equal(1, n)
        end)
        it("_Static_assert: single-arg (C23) and concatenated message", function()
            local ok, rec, n = parse_decls("static_assert(1);\nextern int g(void);\n")
            assert.is_true(ok); assert.equal(0, rec); assert.equal(1, n)
            ok, rec, n = parse_decls('_Static_assert(1, "ab" "cd");\nextern int g(void);\n')
            assert.is_true(ok); assert.equal(0, rec); assert.equal(1, n)
        end)
        it("recovery resyncs at the next declaration, keeping both neighbours", function()
            -- regression: skip-to-`;` recovery used to swallow the following good
            -- declaration when the bad unit had no terminator of its own.
            local ok, _, n = parse_decls(
                "extern int a(void);\nunmodeled garbage here\nextern int b(void);\n")
            assert.is_true(ok); assert.equal(2, n)
        end)
        it("recovery degrades gracefully at end-of-input", function()
            -- regression: a brace- or token-terminated bad unit at EOF used to
            -- fail the entire parse instead of just dropping the bad unit.
            local ok, _, n = parse_decls("weird { x }\n")
            assert.is_true(ok); assert.equal(0, n)
            ok, _, n = parse_decls("extern int a(void);\ngarbage_token\n")
            assert.is_true(ok); assert.equal(1, n)
        end)
        it("counts each skipped token/unit and keeps the good neighbours", function()
            local ok, rec, n = parse_decls(
                "extern int a(void);\n1 2 3 ;\nextern int b(void);\n")
            assert.is_true(ok); assert.equal(4, rec); assert.equal(2, n)
        end)
        it("does not recover when everything parses cleanly", function()
            local ok, rec, n = parse_decls("extern int a(void);\nextern int b(void);\n")
            assert.is_true(ok); assert.equal(0, rec); assert.equal(2, n)
        end)
        it("skips function bodies (empty, Duff's device, brace/`;` in literals)", function()
            local ok, rec = parse_decls([[
static inline void fill(int *p, int n) {
    switch (n % 2) {
    case 0: do { *p++ = 0; do {} while (0);
    case 1: *p++ = 0;
            } while (--n > 0);
    }
}
extern int after(void);
]])
            assert.is_true(ok); assert.equal(0, rec)
            ok, rec = parse_decls(
                'static inline void f(void) { const char *s = "}{;}{"; char c = \'}\'; }\n'
                .. "extern int after(void);\n")
            assert.is_true(ok); assert.equal(0, rec)
        end)
        it("fails cleanly (no Lua error) on pathologically nested input", function()
            -- regression: an LPeg backtrack-stack overflow now returns a clean
            -- parse failure (pcall in match) instead of raising out of the FFI.
            local deep = "static inline void f(void) "
                .. string.rep("{", 250) .. string.rep("}", 250) .. "\n"
            assert.is_false((parse_decls(deep)))
        end)
    end)

    describe("comments and line continuation", function()
        it("strips a line comment", function()
            assert.equal("int x ; int y ;", expand("int x; // tail\nint y;\n"))
        end)
        it("strips a block comment", function()
            assert.equal("int x ;", expand("int /* c */ x;\n"))
        end)
        it("strips a block comment spanning lines", function()
            assert.equal("a b", expand("a /* l1\nl2 */ b\n"))
        end)
        it("does not treat comment markers inside a string as a comment", function()
            assert.equal([[char * s = "a \" /* x */" ;]],
                expand([[char *s = "a \" /* x */";]] .. "\n"))
        end)
        it("preserves an escaped backslash in a char literal", function()
            assert.equal([[c = '\\' ;]], expand([[c = '\\';]] .. "\n"))
        end)
        it("splices a backslash-newline mid-token (pure deletion)", function()
            assert.equal("int x ;", expand("in\\\nt x;\n"))
        end)
        it("splices a backslash-newline inside a macro body", function()
            assert.equal("a + b", expand("#define M a \\\n+ b\nM\n"))
        end)
        it("applies continuation before comment stripping", function()
            assert.equal("a b", expand("a /* l1 \\\nl2 */ b\n"))
        end)
        it("treats a trailing CR (CRLF) as whitespace on normal lines", function()
            assert.equal("int x ; int y ;", expand("int x;\r\nint y;\r\n"))
        end)
    end)

    describe("#if expression operators and #elif", function()
        local function on(expr) -- "OK" iff the #if branch is kept
            return expand("#if " .. expr .. "\nOK\n#endif\n")
        end
        local function assert_left_chain(source, outer, inner)
            local expression = assert(
                c99.match_preprocessing_expression_grammar(source))
            assert.equal(outer, expression.op)
            assert.equal(inner, expression[1].op)
            assert.equal(2, #expression)
            assert.equal(2, #expression[1])
        end
        it("arithmetic, shift, relational, logical, ternary, unary operators", function()
            assert.equal("OK", on("1 - 1 == 0"))
            assert.equal("OK", on("2 * 3 == 6"))
            assert.equal("OK", on("8 / 2 == 4"))
            assert.equal("OK", on("1 << 4 == 16"))
            assert.equal("OK", on("256 >> 2 == 64"))
            assert.equal("OK", on("3 > 2"))
            assert.equal("OK", on("2 < 3"))
            assert.equal("OK", on("2 <= 2"))
            assert.equal("OK", on("3 >= 3"))
            assert.equal("OK", on("1 != 2"))
            assert.equal("OK", on("1 && 1"))
            assert.equal("OK", on("0 || 1"))
            assert.equal("OK", on("!0"))
            assert.equal("", on("!2"))
            assert.equal("", on("!-1"))
            assert.equal("OK", on("(1 ? 2 : 0) == 2"))
        end)
        it("uses C integer division and remainder before shifts", function()
            assert.equal("OK", on("53 / 4 == 13"))
            assert.equal("OK", on("-7 / 3 == -2"))
            assert.equal("OK", on("7 / -3 == -2"))
            assert.equal("OK", on("-7 / -3 == 2"))
            assert.equal("OK", on("-7 % 3 == -1"))
            assert.equal("OK", on("7 % -3 == 1"))
            assert.equal("OK", on("(0x7fffffffffffffffLL >> (53 / 4)) > 0"))
        end)
        it("retains and left-folds every binary operator chain", function()
            assert_left_chain("18 / 3 * 2", "*", "/")
            assert_left_chain("10 - 3 + 2", "+", "-")
            assert_left_chain("16 >> 2 << 1", "<<", ">>")
            assert_left_chain("3 > 2 < 1", "<", ">")
            assert_left_chain("2 == 2 != 0", "!=", "==")
            assert_left_chain("7 & 3 & 1", "&", "&")
            assert_left_chain("7 ^ 3 ^ 1", "^", "^")
            assert_left_chain("1 | 2 | 4", "|", "|")
            assert_left_chain("1 && 2 && 3", "&&", "&&")
            assert_left_chain("0 || 2 || 3", "||", "||")

            assert.equal("OK", on("18 / 3 * 2 == 12"))
            assert.equal("OK", on("10 - 3 + 2 == 9"))
            assert.equal("OK", on("16 >> 2 << 1 == 8"))
            assert.equal("OK", on("(3 > 2 < 1) == 0"))
            assert.equal("OK", on("2 == 2 != 0"))
            assert.equal("OK", on("(0 && (1 / 0) && 1) == 0"))
            assert.equal("OK", on("1 || (1 / 0) || 0"))
        end)
        it("keeps conditional expressions right-associative", function()
            local expression = assert(
                c99.match_preprocessing_expression_grammar(
                    "1 ? 2 : 3 ? 4 : 5"))
            assert.equal("?", expression.op)
            assert.equal("?", expression[3].op)
            assert.is_nil(expression[1].op)
            assert.equal("OK", on("(0 ? 2 : 1 ? 4 : 5) == 4"))
        end)
        it("shares the folded binary AST with C language expressions", function()
            local parsers = {
                c99.match_language_expression_grammar,
                function(source)
                    return c99.match_typed_language_expression_grammar(
                        source, {})
                end,
            }
            for _, parse in ipairs(parsers) do
                local expression = assert(parse("18 / 3 * 2 + 1 "))
                assert.equal("+", expression.op)
                assert.equal("*", expression[1].op)
                assert.equal("/", expression[1][1].op)

                local conditional = assert(parse(
                    "1 ? 2 : 3 ? 4 : 5 "))
                assert.equal("?", conditional.op)
                assert.equal("?", conditional[3].op)
            end
        end)
        it("evaluates bitwise and uintmax_t expressions exactly", function()
            assert.equal("OK", on("(0xf0 & 0x3c) == 0x30"))
            assert.equal("OK", on("(0xf0 ^ 0x3c) == 0xcc"))
            assert.equal("OK", on("(0xf0 | 0x0f) == 0xff"))
            assert.equal("OK", on("~0 == -1"))
            assert.equal("OK", on("(-3LL >> 1) == -2"))
            assert.equal("OK", on("(0xffffffffffffffffULL >> 63) == 1"))
            assert.equal("OK", on("0xffffffffffffffffULL > 0"))
            assert.equal("OK", on(
                "18446744073709551615ULL == 0xffffffffffffffffULL"))
            assert.equal("OK", on(
                "18446744073709551615ULL / 3 == 6148914691236517205ULL"))
            assert.equal("OK", on("18446744073709551615ULL % 3 == 0"))
            assert.equal("OK", on(
                "0xffffffffffffffffULL / 0xffffffffffffffffULL == 1"))
            assert.equal("OK", on(
                "0xffffffffffffffffULL / 0x8000000000000000ULL == 1"))
            assert.equal("OK", on(
                "0xffffffffffffffffULL % 0x8000000000000000ULL == " ..
                "0x7fffffffffffffffULL"))
            assert.equal("OK", on(
                "0x8000000000000000ULL / 3 == 3074457345618258602ULL"))
            assert.equal("OK", on("0x8000000000000000ULL % 3 == 2"))
            assert.equal("OK", on("1u + 1UL + 1llu + 1ULL == 4U"))
            assert.equal("OK", on("0XABCDEFULL == 11259375u"))
        end)
        it("applies ?: conversions without evaluating the other branch", function()
            assert.equal("OK", on("(1 ? -1 : 1U) > 0"))
            assert.equal("OK", on("(0 ? 1U : -1) > 0"))
            assert.equal("OK", on("(1 ? 7 : 1 / 0) == 7"))
            assert.equal("OK", on("(0 ? 1 / 0 : 7) == 7"))
            assert.equal("OK", on("(1 ? (0 ? 0 : -1) : 1U) > 0"))
        end)
        it("reports invalid integer operations instead of using Lua floats",
        function()
            for _, expression in ipairs({
                "1 / 0", "1U % 0U", "1 << -1", "1 >> 64", "1.0",
            }) do
                local ok, err = pcall(on, expression)
                assert.is_false(ok)
                assert.matches("preprocessor expression", tostring(err), 1, true)
            end
        end)
        it("handles character constants and residual identifiers", function()
            assert.equal("OK", on("'A' == 65"))
            assert.equal("OK", on("'\\n' == 10"))
            assert.equal("OK", on("'\\101' == 65"))
            assert.equal("OK", on("'\\x41' == 65"))
            assert.equal("OK", on("'\\u0041' == 65"))
            assert.equal("OK", on("'\\U00000041' == 65"))
            assert.equal("OK", on("'AB' == 0x4142"))
            assert.equal("OK", expand([[
#define SELF SELF
#if SELF == 0
OK
#endif
]]))
        end)
        it("evaluates Titan's integer-fit preamble condition", function()
            assert.equal("OK", expand([[
#define LUA_MAXINTEGER 0x7fffffffffffffffLL
#define TITAN_NBM 53
#if ((((LUA_MAXINTEGER >> (TITAN_NBM / 4)) >> (TITAN_NBM / 4)) >> \
      (TITAN_NBM / 4)) >> (TITAN_NBM - (3 * (TITAN_NBM / 4)))) > 0
OK
#endif
]]))
        end)
        it("octal, hex, and parenthesized constants", function()
            assert.equal("OK", on("0x10 == 16"))
            assert.equal("OK", on("010 == 8"))
            assert.equal("OK", on("1 + (2 * 3) == 7"))
        end)
        it("the defined operator, with and without parentheses", function()
            assert.equal("yes", expand("#define F\n#if defined F\nyes\n#endif\n"))
            assert.equal("yes", expand("#define F\n#if defined(F)\nyes\n#endif\n"))
        end)
        it("expands a macro operand inside the condition", function()
            assert.equal("yes", expand("#define N 3\n#if N * 2 == 6\nyes\n#endif\n"))
        end)
        it("#elif takes a true branch after a false #if", function()
            assert.equal("b", expand("#if 0\na\n#elif 1\nb\n#else\nc\n#endif\n"))
        end)
        it("#elif is skipped after a true #if branch", function()
            assert.equal("a", expand("#if 1\na\n#elif 1\nb\n#endif\n"))
        end)
        it("skips a nested #if inside a dropped block", function()
            assert.equal("after", expand("#if 0\n#if 1\nx\n#endif\ny\n#endif\nafter\n"))
        end)
        it("accepts punctuation immediately after conditional directive names", function()
            local source = [[
#define ENABLED 1
#if(defined(ENABLED) && !defined(MISSING))
first
#else
wrong
#endif
#if+0
wrong
#elif!defined(MISSING)
second
#endif
#ifdef ENABLED
third
#endif
]]
            assert.equal("first second third", expand(source))
            assert.equal(host_expand(source):gsub("%s+", " "), expand(source))
        end)

        it("does not split longer identifiers into conditional directive names", function()
            local parsed, err = preprocess_source("#iffoo\nwrong\n#endif\n")
            assert.is_nil(parsed)
            assert.matches("invalid or incomplete preprocessing directive: #iffoo", err, 1, true)
            -- Split as `#elif 1`, this would keep `wrong`.
            assert.equal("", expand("#if 0\n#elif1\nwrong\n#endif\n"))
        end)

        it("ignores #error and pragmas other than once", function()
            assert.equal("kept", expand(
                "#error deliberately ignored\n#pragma pack(1)\nkept\n"))
        end)
    end)

    describe("malformed and token-less directives", function()
        it("accepts and ignores the directives C allows without operands", function()
            for _, directive in ipairs({
                "#", "# ", "%:", "#pragma", "#pragma ", "#pragma pack(1)", "#pragma-once",
                "#warning", "#warning ", "#warning text", '#warning"text"',
                "#error", "#error ", "#error text",
            }) do
                local ctx, err = preprocess_source("before\n" .. directive .. "\nafter\n")
                assert(ctx, directive .. ": " .. tostring(err))
                assert.same({ "before", "after" }, ctx.output, directive)
            end
        end)

        it("keeps every directive working with its operand", function()
            for _, case in ipairs({
                { "#define VALUE 1\nVALUE\n", "1" },
                { "#define VALUE 1\n#undef VALUE\nVALUE\n", "VALUE" },
                { "#if 1\nkept\n#endif\n", "kept" },
                { "#ifdef MISSING\ndropped\n#endif\nkept\n", "kept" },
                { "#ifndef MISSING\nkept\n#endif\n", "kept" },
                { "#if 0\ndropped\n#elif 1\nkept\n#else\ndropped\n#endif\n", "kept" },
                { "#line 7\nkept\n", "kept" },
            }) do
                local ctx, err = preprocess_source(case[1])
                assert(ctx, case[1] .. ": " .. tostring(err))
                assert.equal(case[2],
                    table.concat(ctx.output, " "):match("^%s*(.-)%s*$"), case[1])
            end
        end)

        it("diagnoses every other incomplete or unknown directive with its file and line", function()
            local invalid = "invalid or incomplete preprocessing directive: "
            for _, case in ipairs({
                { "#if", "#if with no expression" },
                { "#if ", "#if with no expression" },
                { "#ifdef", "no macro name given in #ifdef directive" },
                { "#ifdef ", "no macro name given in #ifdef directive" },
                { "#ifdef 3", "no macro name given in #ifdef directive" },
                { "#ifndef", "no macro name given in #ifndef directive" },
                { "#ifndef ", "no macro name given in #ifndef directive" },
                { "#elif", "unexpected directive elif" },
                { "#elif ", "unexpected directive elif" },
                { "#else", "unexpected directive else" },
                { "#endif", "unexpected directive endif" },
                { "#include", invalid .. "#include" },
                { "#include ", invalid .. "#include" },
                { "#include_next", invalid .. "#include_next" },
                { "#include_next ", invalid .. "#include_next" },
                { "#define", invalid .. "#define" },
                { "#define ", invalid .. "#define" },
                { "#undef", invalid .. "#undef" },
                { "#undef ", invalid .. "#undef" },
                { "#line", invalid .. "#line" },
                { "#line ", invalid .. "#line" },
                { "#foo", invalid .. "#foo" },
                { "# foo", invalid .. "# foo" },
                { "#!", invalid .. "#!" },
                { "#import x", invalid .. "#import x" },
                -- A longer word is not the directive it starts with.
                { "#elsewhere", invalid .. "#elsewhere" },
                { "#endif1", invalid .. "#endif1" },
                { "#errors", invalid .. "#errors" },
                { "#pragmatic", invalid .. "#pragmatic" },
                { "#warnings", invalid .. "#warnings" },
                { "#includes <a.h>", invalid .. "#includes <a.h>" },
                { "#ifdefX", invalid .. "#ifdefX" },
            }) do
                local ctx, err, filename = preprocess_source("kept\n" .. case[1] .. "\n")
                assert.is_nil(ctx, case[1])
                assert.matches(filename .. ":2: " .. case[2], err, 1, true)
                assert.not_matches("cpp.lua:", err, 1, true)
            end
        end)

        it("diagnoses an evaluated #elif that has no expression", function()
            local ctx, err, filename = preprocess_source("#if 0\n#elif\n#endif\n")
            assert.is_nil(ctx)
            assert.matches(filename .. ":2: #elif with no expression", err, 1, true)
            -- A group that is already decided does not evaluate its #elif.
            assert.equal("kept", expand("#if 1\nkept\n#elif\ndropped\n#endif\n"))
        end)

        it("ignores invalid directives in a skipped group and nests by directive name", function()
            assert.equal("kept", expand(
                "#if 0\n#foo\n#define\n#undef\n#include\n#line\n#\n#endif\nkept\n"))
            assert.equal("kept", expand(
                "#if 0\n#if\ndropped\n#endif\n#ifdef\n#endif\n#ifndef\n#else\n#endif\n"
                .. "dropped\n#endif\nkept\n"))
            assert.equal("kept", expand(
                "#if 1\nkept\n#else\n#if\n#foo\n#endif\ndropped\n#endif\n"))
        end)

        it("diagnoses an #include whose operand expands to nothing", function()
            for _, directive in ipairs({ "#include", "#include_next" }) do
                local ctx, err, filename = preprocess_source(
                    "#define EMPTY\n" .. directive .. " EMPTY\nmarker\n")
                assert.is_nil(ctx)
                assert.matches(filename .. ":2: " .. directive .. " expects a header name",
                    err, 1, true)
                assert.not_matches("platform.lua:", err, 1, true)
            end
        end)

        it("never dispatches a capture-less grammar match", function()
            local match = c99.match_preprocessing_grammar
            c99.match_preprocessing_grammar = function() return 3 end
            local ok, tokens = pcall(cpp.tokenize, "#unmatched")
            c99.match_preprocessing_grammar = match
            assert(ok, tokens)
            assert.same({ directive = "invalid" }, tokens)
        end)
    end)

    describe("include guards and depth", function()
        local function context(strategy)
            return {
                io = strategy,
                incdirs = { quote = {}, system = {} },
                defines = {}, ifmode = { true }, output = {}, current_dir = {},
            }
        end

        local function with_headers(sources, action)
            local root = temporary.name()
            assert(os.remove(root))
            assert(lfs.mkdir(root))
            local paths = {}
            local function write_header(name, source)
                local path = root .. "/" .. name
                if not paths[path] then
                    paths[path] = true
                    paths[#paths + 1] = path
                end
                local file = assert(io.open(path, "wb"))
                assert(file:write(source))
                assert(file:close())
                return path
            end
            local result = table.pack(xpcall(function()
                for name, source in pairs(sources) do write_header(name, source) end
                return action(root, write_header, function(name, symbolic)
                    local alias = root .. "/" .. name
                    local ok, err = lfs.link(root .. "/shared.h", alias, symbolic)
                    assert(ok, err)
                    paths[#paths + 1] = alias
                end)
            end, debug.traceback))
            for _, path in ipairs(paths) do assert(os.remove(path)) end
            assert(lfs.rmdir(root))
            assert(result[1], result[2])
            return table.unpack(result, 2, result.n)
        end

        local function preprocess(root, name, ctx)
            ctx = ctx or context()
            local previous_hook, previous_mask, previous_count = debug.gethook()
            debug.sethook(function()
                error("include preprocessing exceeded its instruction budget", 0)
            end, "", 20000000)
            local ok, parsed, err = pcall(cpp.parse_file, root .. "/" .. name, nil, ctx)
            debug.sethook(previous_hook, previous_mask, previous_count)
            assert(ok, parsed)
            assert.same({}, ctx.current_dir)
            return parsed, err
        end

        local function output(root, name, ctx)
            local parsed, err = preprocess(root, name or "main.h", ctx)
            assert(parsed, err)
            return table.concat(parsed.output, " "):match("^%s*(.-)%s*$"):gsub("%s+", " ")
        end

        it("accepts a header name written directly after #include", function()
            with_headers({
                ["main.h"] = '#include"quoted.h"\n#include<angled.h>\n',
                ["quoted.h"] = "quoted_marker\n",
                ["angled.h"] = "angled_marker\n",
            }, function(root)
                local ctx = context()
                ctx.incdirs.system = { root }
                assert.equal("quoted_marker angled_marker", output(root, "main.h", ctx))
            end)
        end)

        it("terminates a self-include after executing #pragma once", function()
            with_headers({ ["main.h"] =
                '#pragma once\nself_marker\n#include "main.h"\n' }, function(root)
                assert.equal("self_marker", output(root))
            end)
        end)

        it("honors #pragma once with trailing tokens in recursive and repeated includes", function()
            with_headers({
                ["main.h"] = '#include "shared.h"\n#include "shared.h"\n',
                ["shared.h"] = '#pragma once extra_tokens\n#include "shared.h"\nmarker\n',
            }, function(root)
                assert.equal("marker", output(root))
            end)
        end)

        it("terminates mutually-including #pragma once headers", function()
            with_headers({
                ["main.h"] = '#pragma once\nfirst\n#include "second.h"\n',
                ["second.h"] = '#pragma once\n#include "main.h"\nsecond\n',
            }, function(root)
                assert.equal("first second", output(root))
            end)
        end)

        it("keeps conventional #ifndef-guarded cycles working", function()
            with_headers({
                ["main.h"] = '#ifndef FIRST\n#define FIRST\nfirst\n#include "second.h"\n#endif\n',
                ["second.h"] = '#ifndef SECOND\n#define SECOND\n#include "main.h"\nsecond\n#endif\n',
            }, function(root)
                assert.equal("first second", output(root))
            end)
        end)

        it("enters one once header reached through two spellings only once", function()
            with_headers({
                ["main.h"] = '#include "shared.h"\n#include "./shared.h"\n',
                ["shared.h"] = "#pragma once\nshared_marker\n",
            }, function(root)
                assert.equal("shared_marker", output(root))
                assert.equal("shared_marker", output(root))
            end)
        end)

        for _, symbolic in ipairs({ false, true }) do
            it("recognizes " .. (symbolic and "symbolic" or "hard") ..
                " links to a once header", function()
                -- Windows' LFS fallback has no physical file identity.
                if symbolic then
                    local available, message = require("spec.support.filesystem").symlink_capability()
                    if not available then pending(message); return end
                end
                local strategy = require("titan-compiler.io").new_sync()
                with_headers({
                    ["main.h"] = '#include "shared.h"\n#include "alias.h"\n',
                    ["shared.h"] = "#pragma once\nshared_marker\n",
                }, function(root, _, link)
                    local stat = assert(strategy:stat(root .. "/shared.h"))
                    if stat.device == nil or stat.inode == nil then
                        pending("the I/O strategy has no physical file identity")
                        return
                    end
                    link("alias.h", symbolic)
                    assert.equal("shared_marker", output(root, nil, context(strategy)))
                end)
            end)
        end

        it("does not conflate distinct headers with identical contents", function()
            with_headers({
                ["main.h"] = '#include "first.h"\n#include "second.h"\n',
                ["first.h"] = "#pragma once\nmarker\n",
                ["second.h"] = "#pragma once\nmarker\n",
            }, function(root)
                assert.equal("marker marker", output(root))
            end)
        end)

        it("falls back to resolved spelling without device/inode identity", function()
            local strategy = require("titan-compiler.io").new_sync()
            local stat = strategy.stat
            function strategy:stat(path)
                local attributes, err = stat(self, path)
                if attributes then attributes.device, attributes.inode = nil, nil end
                return attributes, err
            end
            with_headers({ ["main.h"] =
                '#pragma once\nmarker\n#include "main.h"\n' }, function(root)
                assert.equal("marker", output(root, nil, context(strategy)))
            end)
        end)

        it("does not execute an inactive or macro-named pragma", function()
            with_headers({
                ["main.h"] = '#include "shared.h"\n#include "shared.h"\n',
                ["shared.h"] = "#if 0\n#pragma once\n#endif\n#define ONCE once\n#pragma ONCE\nmarker\n",
            }, function(root)
                assert.equal("marker marker", output(root))
            end)
        end)

        it("does not mark a header before reaching its pragma", function()
            with_headers({ ["main.h"] = [[
#ifndef ENTERED
#define ENTERED
#include "main.h"
#endif
#pragma once
marker
]] }, function(root)
                assert.equal("marker marker", output(root))
            end)
        end)

        it("diagnoses an unguarded cycle even when a pragma follows the include", function()
            with_headers({ ["main.h"] =
                '#include "main.h"\n#pragma once\n' }, function(root)
                local parsed, err = preprocess(root, "main.h")
                assert.is_nil(parsed)
                assert.matches("maximum C include depth (200) exceeded", err, 1, true)
                assert.matches(root .. "/main.h", err, 1, true)
                assert.not_matches("sha256.lua:", err, 1, true)
            end)
        end)

        it("accepts depth 200 and diagnoses depth 201 with the chain root", function()
            local sources = { ["main.h"] = '#include "level1.h"\n' }
            for depth = 1, 199 do
                sources["level" .. depth .. ".h"] =
                    '#include "level' .. (depth + 1) .. '.h"\n'
            end
            sources["level200.h"] = "boundary_marker\n"
            with_headers(sources, function(root, write_header)
                assert.equal("boundary_marker", output(root))
                write_header("level200.h", '#include "level201.h"\n')
                write_header("level201.h", "too_deep\n")
                local parsed, err = preprocess(root, "main.h")
                assert.is_nil(parsed)
                assert.matches("maximum C include depth (200) exceeded", err, 1, true)
                assert.matches("at '" .. root .. "/level201.h'", err, 1, true)
                assert.matches("include chain starts at '" .. root .. "/main.h'", err, 1, true)
                assert.not_matches("sha256.lua:", err, 1, true)
            end)
        end)
    end)

    describe("macro expansion edge cases", function()
        it("an empty object-like macro expands to nothing", function()
            assert.equal("a b", expand("#define E\na E b\n"))
        end)
        it("expands a function-like call spanning multiple lines", function()
            -- the consumed continuation line contributes the trailing space
            assert.equal("1 + 2 ", expand("#define ADD(a,b) a + b\nADD(1,\n2)\n"))
        end)
        it("keeps a comma inside parentheses within a single argument", function()
            assert.equal("( a , b )", expand("#define F(x) x\nF((a,b))\n"))
        end)
        it("chains ## across three operands", function()
            assert.equal("foobarbaz", expand("#define C(a,b,c) a ## b ## c\nC(foo,bar,baz)\n"))
        end)
        it("rescans a name formed by ## and expands it", function()
            assert.equal("7", expand("#define AB 7\n#define J(a,b) a ## b\nJ(A,B)\n"))
        end)
        it("stringizes a multi-token argument", function()
            assert.equal('"a + b"', expand("#define S(x) #x\nS(a + b)\n"))
        end)
    end)

    -- Regressions for pre-existing tokenizer/preprocessor defects in cpp.lua's
    -- hand-written state machine and the c99 preprocessing tokenizer. These were
    -- latent (the state machine was untested) and surfaced by the coverage
    -- audit; each one used to silently drop the rest of a line. None were
    -- regressions from the FFI work.
    describe("tokenizer and state-machine robustness", function()
        it("passes a stray non-C character through instead of truncating the line", function()
            -- C99 6.4p1: any non-whitespace char that is no other token is an
            -- "other" pp-token. It must not swallow the rest of the line.
            assert.equal("int x @ = 1 ; kept", expand("int x@ = 1;\nkept\n"))
            assert.equal("a $ b kept", expand("a $ b\nkept\n"))
            assert.equal("a ` b kept", expand("a ` b\nkept\n"))
        end)
        it("keeps a '/' at the end of a line (division operator)", function()
            assert.equal("a / b", expand("a /\nb\n"))
        end)
        it("keeps the buffered line when the file ends in a backslash-continuation", function()
            assert.equal("a", expand("a \\\n"))
        end)
        it("keeps the preceding code when the file ends in an unterminated block comment", function()
            assert.equal("kept more", expand("kept\nmore /* unterminated\n"))
        end)
        it("recognizes a backslash-continuation on a CRLF-terminated line", function()
            assert.equal("1 + 2", expand("#define A 1 \\\r\n+ 2\nA\n"))
        end)
        it("does not drop an unterminated string or char literal", function()
            assert.equal('a " unterminated next', expand("a \"unterminated\nnext\n"))
            assert.equal("a ' x next", expand("a 'x\nnext\n"))
        end)
        it("does not drop the rest of the line after an empty char literal", function()
            assert.equal("a ' ' b", expand("a '' b\n"))
        end)
    end)
end)

describe("C header identities with a digest adapter", function()
    local sha256 = require "titan-compiler.sha256"

    it("match the pure-Lua identity for first loads and input identities", function()
        local path = temporary.name()
        local contents = "typedef int header_item;\n\0binary tail\n"
        local file = assert(io.open(path, "wb"))
        assert(file:write(contents))
        assert(file:close())
        local digested = 0
        local options = { cache_adapter = { sha256_binary = function(bytes)
            digested = digested + 1
            return require("titan")._sha256_binary(bytes)
        end } }
        local plain = cpp.header_file_identity(contents, path)
        local native = cpp.header_file_identity(contents, path, nil, nil, options)
        assert.equal(plain, native)
        assert.equal(1, digested)
        assert.truthy(plain:find(sha256.hex(contents), 1, true), plain)
        assert.equal(plain, cpp.header_input_identity("file", path, nil, options))
        assert.equal(2, digested)
        assert(os.remove(path))
    end)
end)

describe("C preprocessor semantic digest adapters", function()
    local sha256 = require "titan-compiler.sha256"
    local semantic_tag = "titan-cpp-semantic-context-v1"

    local function fixture(callback, forced)
        local root = platform.windows and "C:/SDK 日本/include path" or "/SDK 日本/include path"
        local header = root .. "/forced.h"
        local contents = "#pragma once\n#define FORCED_VALUE 7\nforced_marker\n"
        local strategy = {}
        function strategy:run(argv)
            local verbose, included = false, false
            for _, argument in ipairs(argv) do
                if argument == "-v" then verbose = true end
                if argument == "-include" or argument == "-imacros" then included = true end
            end
            local macros = '#define VENDOR_VERSION "fixture"\n#define VALUE (1 + 2)\n#define JOIN(a,b) a ## b\n'
            return { started = true, ok = true, why = "exit", status = 0,
                output = verbose and table.concat({
                    '#include "..." search starts here:',
                    '#include <...> search starts here:',
                    " " .. root, "End of search list.", "",
                }, "\n") or macros .. (included and "#define FORCED_VALUE 7\n" or "") }
        end
        function strategy:cwd() return root end
        function strategy:stat(path)
            if path ~= header then return nil end
            return { kind = "file", size = #contents, mode = 0x81A4,
                device = 1, inode = 2, time_precision = "ns",
                modified_seconds = 100, modified_nanoseconds = 0,
                changed_seconds = 100, changed_nanoseconds = 1 }
        end
        strategy.lstat = strategy.stat
        function strategy:readable(path) return path == header end
        function strategy:read_file(path)
            if path == header then return contents end
            return nil, "missing"
        end
        return { io = strategy, compiler = { "fixture-cc" }, fixed_include_dirs = {},
            cppflags = forced and { "-include", header } or {},
            cache_adapter = callback and { sha256_binary = callback } or nil }
    end

    local function plain_context(forced)
        local hex, inputs = sha256.hex, {}
        sha256.hex = function(bytes)
            if bytes:find(semantic_tag, 1, true) then inputs[#inputs + 1] = bytes end
            return hex(bytes)
        end
        local ok, context, err = pcall(cpp.new_context, fixture(nil, forced))
        sha256.hex = hex
        assert.is_true(ok, context)
        assert(context, err)
        return context, inputs
    end

    for _, forced in ipairs({ false, true }) do
        it("preserves canonical bytes and keys with a native adapter for "
            .. (forced and "forced" or "ordinary") .. " contexts", function()
            local plain, inputs = plain_context(forced)
            local native_inputs = {}
            local options = fixture(function(bytes)
                if bytes:find(semantic_tag, 1, true) then native_inputs[#native_inputs + 1] = bytes end
                return require("titan")._sha256_binary(bytes)
            end, forced)
            local native = assert(cpp.new_context(options))
            assert.equal(forced and 2 or 1, #native_inputs)
            assert.same(inputs, native_inputs)
            assert.equal(plain.preprocessor_configuration_key, native.preprocessor_configuration_key)
            assert.equal(plain.forced_header_manifest, native.forced_header_manifest)
            assert.same(plain.incdirs, native.incdirs)
            assert.same(plain.defines, native.defines)
            assert.equal(native.preprocessor_configuration_key,
                assert(cpp.new_context(options)).preprocessor_configuration_key)
            assert.equal(forced and 2 or 1, #native_inputs)
        end)
    end

    for _, previous in ipairs({
        { name = "pragma once", policy = "" },
        { name = "Clang nullability", policy = "pragma-once=physical-file;include-depth=200" },
    }) do
        it("invalidates keys computed before " .. previous.name .. " support", function()
            local current = assert(cpp.new_context(fixture(nil, false)))
            local legacy_options = fixture(function(bytes)
                -- Replace the length-prefixed policy field to reconstruct the
                -- exact historical payload. This deliberately pins its framing
                -- and policy spelling; update it with semantic-policy changes.
                local policy = "pragma-once=physical-file;include-depth=200;pointer-nullability=clang"
                local field = #policy .. ":" .. policy .. "|"
                local replacement = previous.policy == "" and ""
                    or #previous.policy .. ":" .. previous.policy .. "|"
                local start = assert(bytes:find(field, 1, true))
                return require("titan")._sha256_binary(
                    bytes:sub(1, start - 1) .. replacement .. bytes:sub(start + #field))
            end, false)
            local legacy = assert(cpp.new_context(legacy_options))
            assert.not_equal(legacy.preprocessor_configuration_key,
                current.preprocessor_configuration_key)
        end)
    end

    for _, kind in ipairs({ "-include", "-imacros" }) do
        it("preserves once state from " .. kind .. " across cached contexts", function()
            local options = fixture(nil, true)
            options.cppflags[1] = kind
            for _ = 1, 2 do
                local ctx = assert(cpp.new_context(options))
                local parsed, err = cpp.parse_contents("main.c",
                    '#include <forced.h>\n#include <forced.h>\n', ctx)
                assert(parsed, err)
                assert.equal(kind == "-include" and "forced_marker" or "",
                    table.concat(ctx.output, " "):match("^%s*(.-)%s*$"))
            end
        end)

        it("refreshes once identity after byte-identical " .. kind .. " republishing", function()
            local options = fixture(nil, true)
            options.cppflags[1] = kind
            local original = assert(cpp.new_context(options))
            local stat = options.io.stat
            function options.io:stat(path)
                local attributes, err = stat(self, path)
                if attributes then attributes.inode = 3 end
                return attributes, err
            end
            options.io.lstat = options.io.stat
            local ctx = assert(cpp.new_context(options))
            assert.equal(original.preprocessor_configuration_key,
                ctx.preprocessor_configuration_key)
            local parsed, err = cpp.parse_contents("main.c", '#include <forced.h>\n', ctx)
            assert(parsed, err)
            assert.equal(kind == "-include" and "forced_marker" or "",
                table.concat(ctx.output, " "):match("^%s*(.-)%s*$"))
        end)
    end

    for _, case in ipairs({
        { "missing", function() end },
        { "boolean", function() return false end },
        { "short", function() return string.rep("x", 31) end },
        { "long", function() return string.rep("x", 33) end },
        { "table", function() return {} end },
        { "string error", function() error("native digest unavailable", 0) end },
    }) do
        it("preserves the fallback key for a " .. case[1] .. " digest result", function()
            local plain = plain_context(false)
            local calls = 0
            local context = assert(cpp.new_context(fixture(function(bytes)
                assert.is_not_nil(bytes:find(semantic_tag, 1, true))
                calls = calls + 1
                return case[2]()
            end)))
            assert.equal(1, calls)
            assert.equal(plain.preprocessor_configuration_key, context.preprocessor_configuration_key)
        end)
    end

    it("propagates digest cancellation without publishing a completed context", function()
        local plain = plain_context(false)
        local cancelled = {}
        local options = fixture(function() error(cancelled, 0) end)
        local ok, err = pcall(cpp.new_context, options)
        assert.is_false(ok)
        assert.equal(cancelled, err)
        local calls = 0
        options.cache_adapter.sha256_binary = function(bytes)
            calls = calls + 1
            return require("titan")._sha256_binary(bytes)
        end
        local context = assert(cpp.new_context(options))
        assert.equal(1, calls)
        assert.equal(plain.preprocessor_configuration_key, context.preprocessor_configuration_key)
    end)
end)
