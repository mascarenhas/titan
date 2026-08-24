-- End-to-end tests pinning Titan's numeric operator semantics to Lua 5.5.1's,
-- exactly (two's-complement integer wrap, bitwise xor, the x^2 special case,
-- full-precision float literals, and -- the headline -- mixed integer/float
-- comparisons that compare mathematical values with NO promotion).
--
-- Wherever possible each Titan result is compared against the SAME expression
-- evaluated in reference Lua (`assert(test.f(a,b) == (a OP b))`), so the test
-- tracks Lua's behavior rather than hardcoded magic numbers; the documented
-- edge values are additionally pinned to their exact Lua answer.
--
-- Runs from the repo root (driver/artifact paths are relative to CWD). Flip
-- `h.verbose` in spec/support/helpers.lua to keep the generated `.c`.
local checker = require 'titan-compiler.checker'
local driver = require 'titan-compiler.driver'
local h = require 'spec.support.helpers'

local run_coder = h.run_coder
local parse = h.parse

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM")
    if not h.verbose then os.execute("rm -f *.c") end
end

describe("numeric operator semantics (Lua 5.5 parity)", function()
    after_each(clean)

    -- ===== migrated from coder_spec.lua: "Lua vs C operator semantics" =====
    describe("Lua vs C operator semantics", function()
        it("unary (-)", function()
            run_coder([[
                function f(x:integer): integer
                    return -x
                end
            ]], [[
                assert(math.mininteger == test.f(math.mininteger))
            ]])
        end)

        it("binary (+) overflow", function()
            run_coder([[
                function f(x:integer, y:integer): integer
                    return x + y
                end
            ]], [[
                assert(math.mininteger == test.f(math.maxinteger, 1))
                assert(math.maxinteger == test.f(math.mininteger, -1))
            ]])
        end)

        it("(//)", function()
            run_coder([[
                function f(x:integer, y:integer): integer
                    return x // y
                end
            ]], [[
                assert( 10 //  3 == test.f( 10,  3))
                assert( 10 // -3 == test.f( 10, -3))
                assert(-10 //  3 == test.f(-10,  3))
                assert(-10 // -3 == test.f(-10, -3))
                assert(math.mininteger == test.f(math.mininteger, -1))
            ]])
        end)

        it("(%)", function()
            run_coder([[
                function f(x:integer, y:integer): integer
                    return x % y
                end
            ]], [[
                assert( 10 %  3 == test.f( 10,  3))
                assert( 10 % -3 == test.f( 10, -3))
                assert(-10 %  3 == test.f(-10,  3))
                assert(-10 % -3 == test.f(-10, -3))
                assert(0 == test.f(math.mininteger, -1))
            ]])
        end)

        it("(>>)", function()
            run_coder([[
                function f(x:integer, y:integer): integer
                    return x >> y
                end
            ]], [[
                assert(0xdead >>  1 == test.f(0xdead,  1))
                assert(0xdead >> -1 == test.f(0xdead, -1))
                assert(0 == test.f(0xdead,  100))
                assert(0 == test.f(0xdead, -100))
                assert(0 == test.f(0xdead, math.maxinteger))
                assert(0 == test.f(0xdead, math.mininteger))
            ]])
        end)
    end)

    -- ===== migrated: float modulo sign, exponentiation, float formatting,
    --       LUA_MININTEGER literal, float->int range check =====

    it("computes float modulo with Lua-faithful sign (luai_nummod)", function()
        run_coder([[
            function fmod_f(a: float, b: float): float
                return a % b
            end
        ]], [[
            assert(test.fmod_f(5.0, -3.0) == (5.0 % -3.0))
            assert(test.fmod_f(-5.0, 3.0) == (-5.0 % 3.0))
            assert(test.fmod_f(5.5, 2.0) == (5.5 % 2.0))
            assert(test.fmod_f(-5.5, -2.0) == (-5.5 % -2.0))
            assert(test.fmod_f(-7.3, 2.5) == (-7.3 % 2.5))
            assert(test.fmod_f(5.0, -3.0) == -1.0)
            assert(test.fmod_f(-5.5, -2.0) == -1.5)
        ]])
    end)

    it("generates code for exponentiation", function()
        run_coder([[
            function power(a: float, b: float): float
                return a ^ b
            end
        ]], [[
            assert(test.power(2.0, 3.0) == 8.0)
            assert(test.power(2.0, 3.0) == (2.0 ^ 3.0))
        ]])
    end)

    it("formats integral floats with a .0 suffix like Lua", function()
        run_coder([[
            function fmt(x: float): string
                return "" .. x
            end
        ]], [[
            assert(test.fmt(3.0) == '3.0')
            assert(test.fmt(2.5) == '2.5')
            assert(test.fmt(3.0) == tostring(3.0))
        ]])
    end)

    it("emits LUA_MININTEGER instead of an out-of-range C literal", function()
        -- The most negative integer cannot be written as the literal
        -- -9223372036854775808 (C reads it as a too-large positive constant);
        -- the macro avoids the resulting compiler warning.
        local coder = require 'titan-compiler.coder'
        local types = require 'titan-compiler.types'
        types.registry = {}
        local code = [[
            function f(): integer
                return 0x8000000000000000
            end
        ]]
        local ast = parse(code)
        local _, errs = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #errs, table.concat(errs, "\n"))
        local c = coder.generate("test", ast, {}, driver.TITAN_ABI_VERSION)
        assert.truthy(c:find("LUA_MININTEGER", 1, true),
            "expected LUA_MININTEGER in the generated C")
        assert.falsy(c:find("9223372036854775808", 1, true),
            "the raw out-of-range literal must not appear")
    end)

    it("range-checks an out-of-range float-to-integer conversion", function()
        run_coder([[
            function toi(x: float): integer local y: integer = x return y end
        ]], [[
            assert(test.toi(3.0) == 3)
            assert(pcall(function() return test.toi(2.0 ^ 64) end) == false)
        ]])
    end)

    -- ===== new coverage =====

    describe("integer arithmetic wraps two's-complement", function()
        it("(+) at the integer boundaries", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x + y end
            ]], [[
                assert(test.f(math.maxinteger, 1) == (math.maxinteger + 1))
                assert(test.f(math.maxinteger, 1) == math.mininteger)
                assert(test.f(math.maxinteger, math.maxinteger)
                       == (math.maxinteger + math.maxinteger))
                assert(test.f(math.mininteger, -1) == (math.mininteger + -1))
                assert(test.f(math.mininteger, -1) == math.maxinteger)
            ]])
        end)

        it("(-) at the integer boundaries", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x - y end
            ]], [[
                assert(test.f(math.mininteger, 1) == (math.mininteger - 1))
                assert(test.f(math.mininteger, 1) == math.maxinteger)
                assert(test.f(math.maxinteger, -1) == (math.maxinteger - -1))
            ]])
        end)

        it("(*) wraps past the boundaries", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x * y end
            ]], [[
                assert(test.f(math.maxinteger, 2) == (math.maxinteger * 2))
                assert(test.f(math.maxinteger, 2) == -2)
                assert(test.f(math.mininteger, 2) == (math.mininteger * 2))
                assert(test.f(math.mininteger, 2) == 0)
                assert(test.f(math.maxinteger, math.maxinteger)
                       == (math.maxinteger * math.maxinteger))
            ]])
        end)

        it("unary (-) of mininteger is mininteger", function()
            run_coder([[
                function neg(x:integer): integer return -x end
            ]], [[
                assert(test.neg(math.mininteger) == -math.mininteger)
                assert(test.neg(math.mininteger) == math.mininteger)
                assert(test.neg(5) == -5)
            ]])
        end)
    end)

    describe("bitwise operators", function()
        it("(<<) handles any shift amount", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x << y end
            ]], [[
                assert(test.f(0xdead,  1)   == (0xdead <<  1))
                assert(test.f(0xdead, -1)   == (0xdead << -1))
                assert(test.f(0xdead,  100) == (0xdead <<  100))
                assert(test.f(0xdead,  100) == 0)
                assert(test.f(0xdead, -100) == (0xdead << -100))
                assert(test.f(0xdead, -100) == 0)
                assert(test.f(0xdead, math.maxinteger) == (0xdead << math.maxinteger))
                assert(test.f(0xdead, math.maxinteger) == 0)
                assert(test.f(0xdead, math.mininteger) == (0xdead << math.mininteger))
                assert(test.f(0xdead, math.mininteger) == 0)
            ]])
        end)

        it("(&) with negative operands and mininteger", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x & y end
            ]], [[
                assert(test.f(0xf0, 0x3c) == (0xf0 & 0x3c))
                assert(test.f(-1, 0x55)   == (-1 & 0x55))
                assert(test.f(-8, -3)     == (-8 & -3))
                assert(test.f(math.mininteger, -1) == (math.mininteger & -1))
                assert(test.f(math.mininteger, math.mininteger)
                       == (math.mininteger & math.mininteger))
            ]])
        end)

        it("(|) with negative operands and mininteger", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x | y end
            ]], [[
                assert(test.f(0xf0, 0x0c) == (0xf0 | 0x0c))
                assert(test.f(-8, 0x55)   == (-8 | 0x55))
                assert(test.f(math.mininteger, 1) == (math.mininteger | 1))
                assert(test.f(math.mininteger, math.maxinteger)
                       == (math.mininteger | math.maxinteger))
            ]])
        end)

        it("binary (~) is bitwise xor", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x ~ y end
            ]], [[
                assert(test.f(0xff, 0x0f) == (0xff ~ 0x0f))
                assert(test.f(0xff, 0x0f) == 0xf0)
                assert(test.f(-1, 0)      == (-1 ~ 0))
                assert(test.f(-1, -1)     == (-1 ~ -1))
                assert(test.f(-8, 3)      == (-8 ~ 3))
                assert(test.f(math.mininteger, math.mininteger)
                       == (math.mininteger ~ math.mininteger))
                assert(test.f(math.mininteger, -1) == (math.mininteger ~ -1))
            ]])
        end)

        it("unary (~) is bitwise not", function()
            run_coder([[
                function bnot(x:integer): integer return ~x end
            ]], [[
                assert(test.bnot(0)  == (~0))
                assert(test.bnot(0)  == -1)
                assert(test.bnot(5)  == (~5))
                assert(test.bnot(-1) == (~(-1)))
                assert(test.bnot(math.mininteger) == (~math.mininteger))
                assert(test.bnot(math.maxinteger) == (~math.maxinteger))
            ]])
        end)
    end)

    describe("exponentiation matches luai_numpow", function()
        it("x^2.0 equals x*x exactly", function()
            -- A value chosen so a naive pow(x,2.0) might differ from x*x by a
            -- ULP on some libm; Lua's b==2 special case (and ours) makes both
            -- equal to the C multiply, so this must hold on every platform.
            run_coder([[
                function p(x:float): float return x ^ 2.0 end
            ]], [[
                local x = 1.0006623000003867
                assert(test.p(x) == x * x)
                assert(test.p(x) == x ^ 2.0)
            ]])
        end)

        it("general exponentiation", function()
            run_coder([[
                function p(a:float, b:float): float return a ^ b end
            ]], [[
                assert(test.p(2.0, 10.0) == (2.0 ^ 10.0))
                assert(test.p(2.0, 10.0) == 1024.0)
                assert(test.p(2.0, 0.5) == (2.0 ^ 0.5))
            ]])
        end)
    end)

    describe("float literal precision and documented examples", function()
        it("keeps full precision for float literals", function()
            run_coder([[
                function pi(): float return 3.14159265358979 end
                function tenth(): float return 0.1 end
                function denorm(): float return 5e-324 end
            ]], [[
                assert(test.pi() == 3.14159265358979)
                assert(test.tenth() == 0.1)
                assert(test.denorm() == 5e-324)
            ]])
        end)

        it("matches the expressions.md operator examples", function()
            run_coder([[
                function idiv(): integer return -10 // 3 end
                function fmod(): integer return 10 % -3 end
                function shl(): integer return 1 << 100 end
                function shr(): integer return 4 >> -1 end
            ]], [[
                assert(test.idiv() == (-10 // 3))
                assert(test.idiv() == -4)
                assert(test.fmod() == (10 % -3))
                assert(test.fmod() == -2)
                assert(test.shl() == (1 << 100))
                assert(test.shl() == 0)
                assert(test.shr() == (4 >> -1))
                assert(test.shr() == 8)
            ]])
        end)

        it("emits integral-valued float literals as C floating constants", function()
            -- %.17g prints e.g. 1.0 as the bare token "1"; spliced straight into
            -- a raw C operator that silently becomes INTEGER arithmetic. The
            -- literal must stay a floating constant so the operation is float.
            run_coder([[
                function half(): float return 1.0 / 2.0 end
                function negidiv(): float return -1.0 // 2.0 end
                function prod(): float return 3.0 * 2.0 end
                function diff(): float return 2.0 - 5.0 end
            ]], [[
                assert(test.half() == 0.5)              -- not integer (1/2)==0
                assert(test.negidiv() == (-1.0 // 2.0))
                assert(test.negidiv() == -1.0)          -- not floor(-1/2)==0.0
                assert(test.prod() == 6.0)
                assert(test.diff() == -3.0)
            ]])
        end)

        it("float 0.0 / 0.0 literal is NaN, not an integer divide by zero", function()
            run_coder([[
                function nan(): float return 0.0 / 0.0 end
                function inf(): float return 1.0 / 0.0 end
            ]], [[
                local n = test.nan()
                assert(n ~= n)                          -- NaN, not integer 0/0 trap
                assert(test.inf() == math.huge)         -- not integer 1/0 trap
            ]])
        end)
    end)

    describe("mixed integer/float comparison compares mathematical values", function()
        -- For each relational op, build i OP f and f OP i functions and assert
        -- they agree with reference Lua across magnitudes beyond 2^53 (where
        -- promoting the integer to float would round and give the wrong answer).
        for _, op in ipairs({"==", "~=", "<", "<=", ">", ">="}) do
            it("op "..op.." agrees with Lua for int/float and float/int", function()
                run_coder([[
                    function intf(i:integer, f:float): boolean return i ]]..op..[[ f end
                    function flti(f:float, i:integer): boolean return f ]]..op..[[ i end
                ]], string.format([[
                    local op = %q
                    local function refint(i, f)
                        if op == "==" then return i == f
                        elseif op == "~=" then return i ~= f
                        elseif op == "<" then return i < f
                        elseif op == "<=" then return i <= f
                        elseif op == ">" then return i > f
                        else return i >= f end
                    end
                    local function refflt(f, i)
                        if op == "==" then return f == i
                        elseif op == "~=" then return f ~= i
                        elseif op == "<" then return f < i
                        elseif op == "<=" then return f <= i
                        elseif op == ">" then return f > i
                        else return f >= i end
                    end
                    local i53 = 1 << 53
                    local nan = 0.0 / 0.0
                    local cases = {
                        { math.maxinteger,  2.0 ^ 63 },
                        { math.mininteger, -(2.0 ^ 63) },
                        { i53,              2.0 ^ 53 },
                        { i53 + 1,          2.0 ^ 53 },
                        { 3,                3.5 },
                        { 3,                3.0 },
                        { 0,                nan },
                    }
                    for _, c in ipairs(cases) do
                        local i, f = c[1], c[2]
                        assert(test.intf(i, f) == refint(i, f),
                            "intf mismatch for " .. tostring(i) .. " " .. op .. " " .. tostring(f))
                        assert(test.flti(f, i) == refflt(f, i),
                            "flti mismatch for " .. tostring(f) .. " " .. op .. " " .. tostring(i))
                    end
                ]], op))
            end)
        end

        it("pins the documented headline edge answers", function()
            run_coder([[
                function eq(i:integer, f:float): boolean return i == f end
                function lt(i:integer, f:float): boolean return i < f end
                function gt(i:integer, f:float): boolean return i > f end
            ]], [[
                assert(test.eq(math.maxinteger, 2.0 ^ 63) == false)
                assert(test.lt(math.maxinteger, 2.0 ^ 63) == true)
                assert(test.gt(math.maxinteger, 2.0 ^ 63) == false)
                -- 2^53+1 (integer) is strictly greater than the float 2.0^53,
                -- which can only represent the even value 2^53.
                assert(test.eq((1 << 53) + 1, 2.0 ^ 53) == false)
                assert(test.gt((1 << 53) + 1, 2.0 ^ 53) == true)
                -- NaN: every ordered comparison false, ~= true.
                local nan = 0.0 / 0.0
                assert(test.eq(3, nan) == false)
                assert(test.lt(3, nan) == false)
                assert(test.gt(3, nan) == false)
            ]])
        end)
    end)

    describe("errors and IEEE float behavior", function()
        it("integer // by zero raises", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x // y end
            ]], [[
                test.f(1, 0)
            ]], "zero")
        end)

        it("integer %% by zero raises", function()
            run_coder([[
                function f(x:integer, y:integer): integer return x % y end
            ]], [[
                test.f(1, 0)
            ]], "zero")
        end)

        it("float / by zero yields inf/nan without raising", function()
            run_coder([[
                function div(a:float, b:float): float return a / b end
            ]], [[
                assert(test.div(1.0, 0.0) == math.huge)
                assert(test.div(-1.0, 0.0) == -math.huge)
                local n = test.div(0.0, 0.0)
                assert(n ~= n) -- nan is not equal to itself
            ]])
        end)

        it("bitwise op on a non-integral float operand raises", function()
            run_coder([[
                function f(x:float): integer return x & 1 end
            ]], [[
                test.f(3.5)
            ]], "no integer representation")
        end)
    end)
end)
