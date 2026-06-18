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
    assert(ok, rctx)        -- on a hook/runtime error, rctx is the message
    assert(rctx, err)       -- parse_file returned (nil, err)
    return table.concat(ctx.output, " ")
end

describe("c preprocessor (cpp)", function()

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
        it("pastes tokens with ##", function()
            assert.equal("foobar", expand("#define CAT(a,b) a ## b\nCAT(foo,bar)\n"))
        end)
        it("pastes with an empty argument (placemarker)", function()
            assert.equal("acos", expand("#define CAT(x,y) x ## y\nCAT(acos,)\n"))
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
    end)

end)
