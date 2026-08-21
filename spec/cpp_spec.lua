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

-- Run the preprocessor over `src` (a chunk of C) in isolation -- an empty
-- define set and no system include paths, so nothing is pulled in from the
-- host toolchain -- and return the produced output lines joined by a space.
local function expand(src)
    local tmp = os.tmpname()
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
    debug.sethook(function()
        error("cpp expansion exceeded its instruction budget "
            .. "(likely unbounded macro recursion)", 2)
    end, "", 20000000)
    local ok, rctx, err = pcall(cpp.parse_file, tmp, fd, ctx)
    debug.sethook()
    os.remove(tmp)
    assert(ok, rctx)  -- on a hook/runtime error, rctx is the message
    assert(rctx, err) -- parse_file returned (nil, err)
    return table.concat(ctx.output, " ")
end

-- Ask the configured host preprocessor for the spelling of one output line.
-- This keeps the stringification differential focused: directives are
-- suppressed with -P, and surrounding newlines are not part of the contract.
local function host_expand(src)
    local tmp = os.tmpname() .. ".c"
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
    it("treats include-search observer failure as terminal", function()
        local root = os.tmpname()
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

        it("normalizes a shell-reported child signal as interruption",
            function()
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
        it("ignores #pragma", function()
            assert.equal("kept", expand("#pragma once\nkept\n"))
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
