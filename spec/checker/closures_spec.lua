-- Checker-level coverage for anonymous functions (lambdas): capture analysis
-- flags, parameter/return type inference, and the errors around them. These run
-- the checker only (no codegen) — end-to-end closure behavior is a later phase.
local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local assert_type_check = h.assert_type_check
local assert_type_error = h.assert_type_error

-- Walk the (post-checker) AST to the n-th top-level function's body statements.
local function tlfunc_stats(ast, n)
    return ast[n or 1].block.stats
end

describe("closures (capture analysis)", function()
    it("flags a captured-and-mutated local (boxed counter)", function()
        local ok, err, ast = run_checker([[
            function make(): (() -> (integer))
                local n: integer = 0
                local inc = function(): integer
                    n = n + 1
                    return n
                end
                return inc
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_true(n._captured)
        assert.is_true(n._assigned)
        assert.is_true(n._used)
    end)

    it("flags a captured-immutable local (not assigned)", function()
        local ok, err, ast = run_checker([[
            function make(): (() -> (integer))
                local n: integer = 7
                local get = function(): integer return n end
                return get
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_true(n._captured)
        assert.is_nil(n._assigned)
    end)

    it("does not flag a mutated-but-not-captured local", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local n: integer = 0
                n = n + 1
                return n
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_nil(n._captured)
        assert.is_true(n._assigned)
    end)

    it("does not flag a local that is neither captured nor mutated", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local n: integer = 3
                return n
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_nil(n._captured)
        assert.is_nil(n._assigned)
    end)

    it("a shadowing inner local does not capture the outer one", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local x: integer = 1
                local g = function(): integer
                    local x: integer = 2
                    return x
                end
                return x
            end
        ]])
        assert.truthy(ok, err)
        local outer = tlfunc_stats(ast)[1].decls[1]
        assert.is_nil(outer._captured)
    end)

    it("captures transitively across three function levels", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local a: integer = 1
                local b = function(): (() -> (integer))
                    local c = function(): integer
                        return a
                    end
                    return c
                end
                return 1
            end
        ]])
        assert.truthy(ok, err)
        local a = tlfunc_stats(ast)[1].decls[1]
        assert.is_true(a._captured)
        assert.equal(1, a._funcdepth)
    end)

    it("captures a parameter of the enclosing function", function()
        local ok, err, ast = run_checker([[
            function adder(x: integer): (() -> (integer))
                local g = function(): integer return x end
                return g
            end
        ]])
        assert.truthy(ok, err)
        local x = ast[1].params[1]
        assert.is_true(x._captured)
    end)
end)

describe("closures (parameter inference)", function()
    it("infers a param type from an assignment-target function type", function()
        assert_type_check([[
            function f(): integer
                local g: (integer) -> (integer) = function(x) return x + 1 end
                return g(2)
            end
        ]])
    end)

    it("infers a param type from an argument-position function type", function()
        assert_type_check([[
            function apply(g: (integer) -> (integer), x: integer): integer
                return g(x)
            end
            function f(): integer
                return apply(function(y) return y + 1 end, 5)
            end
        ]])
    end)

    it("infers a param type from a return-position function type", function()
        assert_type_check([[
            function make(): ((integer) -> (integer))
                return function(x) return x * 2 end
            end
        ]])
    end)

    it("uses the annotation when a param is annotated", function()
        assert_type_check([[
            function f(): integer
                local g: (integer) -> (integer) = function(x: integer) return x end
                return g(1)
            end
        ]])
    end)

    it("errors on an unannotated param with no usable context", function()
        assert_type_error("cannot infer type of parameter 'x'", [[
            function f(): integer
                local g = function(x) return x end
                return 1
            end
        ]])
    end)
end)

describe("closures (return inference)", function()
    it("infers a single return type from the body", function()
        assert_type_check([[
            function f(): integer
                local g = function(x: integer) return x + 1 end
                return g(2)
            end
        ]])
    end)

    it("infers a multi return type from the body", function()
        assert_type_check([[
            function f(): integer
                local g = function(x: integer) return x, x + 1 end
                local a: integer, b: integer = g(2)
                return a + b
            end
        ]])
    end)

    it("infers a zero-return lambda from an empty body", function()
        assert_type_check([[
            function f(): integer
                local g = function(x: integer) end
                g(1)
                return 1
            end
        ]])
    end)

    it("treats an explicit `: ()` as zero-return", function()
        assert_type_check([[
            function f(): integer
                local g = function(x: integer): () end
                g(1)
                return 1
            end
        ]])
    end)

    it("errors when inferred returns disagree", function()
        assert_type_error("returns disagree", [[
            function f(): integer
                local g = function(b: boolean)
                    if b then return 1 else return 1.0 end
                end
                return 1
            end
        ]])
    end)
end)

describe("closures (still-an-error cases)", function()
    it("rejects a top-level `local x = function...end`", function()
        assert_type_error("top level variable initialization must be constant", [[
            local x = function() end
        ]])
    end)

    it("rejects a self-reference inside its own anonymous initializer", function()
        -- `f` only binds after its initializer is checked, so the inner `f` is
        -- a clean 'not declared' error, not a silent miscompile (D2).
        assert_type_error("variable 'f' not declared", [[
            function g(): integer
                local f: (integer) -> (integer) = function(n: integer): integer
                    return f(n)
                end
                return 1
            end
        ]])
    end)
end)
