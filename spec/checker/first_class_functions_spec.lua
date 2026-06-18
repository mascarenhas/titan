-- Typechecker tests for first-class function values and the zero-return
-- `() -> ()` function type: which programs the checker accepts and which it
-- rejects, and with what error. These run the checker only -- no code is
-- generated or executed. The end-to-end behaviour of the same feature (and the
-- `.so`-import variants) lives in spec/coder/first_class_functions_spec.lua;
-- the pure type-algebra assertions live in spec/types_spec.lua.
local checker = require 'titan-compiler.checker'
local parser = require 'titan-compiler.parser'
local types = require 'titan-compiler.types'

local function parse(code) return parser.parse("(fcf_checker)", code) end

-- Run the checker over `titan_code` and return its list of error strings.
local function check_errs(titan_code)
    types.registry = {}
    local ast = assert(parse(titan_code))
    local _, errs = checker.check("test", ast, titan_code, "test.titan")
    return errs
end

describe("first-class functions and zero-return () functions (typechecker)", function()

    -- ===== zero-return () functions =====

    it("rejects return nil in a () function", function()
        local errs = check_errs([[
            function f(): ()
                return nil
            end
        ]])
        assert.equal(1, #errs)
        assert.match("returned 1 value.* but function expected 0", errs[1])
    end)

    it("rejects a ()-call used as a value (annotated)", function()
        local errs = check_errs([[
            local function vd(): ()
            end
            function g(): integer
                local x: integer = vd()
                return x
            end
        ]])
        assert.truthy(#errs >= 1)
        assert.match("function returning no values cannot be used as a value", errs[1])
    end)

    it("rejects a ()-call used as a value (inferred local — no silent Void)", function()
        local errs = check_errs([[
            local function vd(): ()
            end
            function g()
                local x = vd()
            end
        ]])
        assert.truthy(#errs >= 1)
        assert.match("function returning no values cannot be used as a value", errs[1])
    end)

    it("rejects a ()-call as an operand", function()
        local errs = check_errs([[
            local function vd(): ()
            end
            function g(): integer
                return 1 + vd()
            end
        ]])
        assert.truthy(#errs >= 1)
    end)

    -- ===== first-class function values =====

    it("accepts a function-type annotation", function()
        assert.equal(0, #check_errs([[
            function apply(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
        ]]))
    end)

    it("accepts a top-level function referenced as a value", function()
        assert.equal(0, #check_errs([[
            function dbl(x: integer): integer return x * 2 end
            function get(): (integer) -> integer
                return dbl
            end
        ]]))
    end)

    it("accepts a function value stored in a local and called", function()
        assert.equal(0, #check_errs([[
            function dbl(x: integer): integer return x * 2 end
            function use(): integer
                local f: (integer) -> integer = dbl
                return f(21)
            end
        ]]))
    end)

    it("accepts assigning a function value into a function-typed local", function()
        assert.equal(0, #check_errs([[
            function a(x: integer): integer return x end
            function b(x: integer): integer return x + 1 end
            function use(): integer
                local f: (integer) -> integer = a
                f = b
                return f(1)
            end
        ]]))
    end)

    it("accepts a higher-order function type", function()
        assert.equal(0, #check_errs([[
            function inc(y: integer): integer return y + 1 end
            function twice(f: (integer) -> integer, x: integer): integer
                return f(f(x))
            end
            function make(): (integer) -> integer
                return inc
            end
        ]]))
    end)

    it("rejects assignment to a function name", function()
        local errs = check_errs([[
            function foo(): integer foo = 2 return 0 end
        ]])
        assert.truthy(#errs >= 1)
        assert.match("assign to a function", errs[1])
    end)

    it("rejects a foreign (C) function used as a value", function()
        local errs = check_errs([[
            local m = foreign import "math.h"
            function g(): value
                return m.sqrt
            end
        ]])
        assert.truthy(#errs >= 1)
    end)
end)
