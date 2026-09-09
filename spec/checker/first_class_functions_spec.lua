-- Typechecker tests for first-class function values: which programs the checker
-- accepts and which it rejects, and with what error. These run the checker only
-- -- no code is generated or executed. The end-to-end behaviour lives in
-- spec/coder/first_class_functions_spec.lua, the pure type-algebra assertions in
-- spec/types_spec.lua, and the zero-return `() -> ()` checker tests alongside the
-- rest of the checker tests in spec/checker/checker_spec.lua.
local h = require 'spec.support.helpers'
local check_errs = h.check_errs

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = table.pack(pcall(fn, header))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

describe("first-class function values (typechecker)", function()

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
        with_header("extern double ffi_sqrt(double value);\n", function(header)
            local errs = check_errs([[
                foreign import "]] .. header .. [["
                function g(): value
                    return ffi.ffi_sqrt
                end
            ]])
            assert.truthy(#errs >= 1)
        end)
    end)
end)
