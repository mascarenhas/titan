-- End-to-end tests pinning Titan's numeric operator semantics to Lua 5.5.0's,
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
local h = require 'spec.support.helpers'

local run_coder = h.run_coder
local compile = h.compile
local call = h.call
local parse = h.parse

local function clean()
    os.execute("rm -f *.o *.so")
    if not h.verbose then os.execute("rm -f *.c") end
end

describe("numeric operator semantics (Lua 5.5 parity)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
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
        local c = coder.generate("test", ast, {})
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
end)
