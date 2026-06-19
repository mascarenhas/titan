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

    it("captures `self` of an enclosing method", function()
        -- A lambda nested in a method body captures `self` like any parameter:
        -- `self` is declared at the method's own func-depth (checkfuncbody).
        local ok, err, ast = run_checker([[
            record C n: integer end
            function C:m(): (() -> (integer))
                local g = function(): integer return self.n end
                return g
            end
        ]])
        assert.truthy(ok, err)
        local m = ast[#ast]
        assert.equal("Ast.TopLevelMethod", m._tag)
        assert.is_true(m._self._captured)
    end)

    it("a captured `for` control variable is not marked assigned", function()
        -- The implicit increment must not set `_assigned`, so a captured `for`
        -- variable stays immutable -> by-value (never boxed) -> fresh per
        -- iteration. (§3/§4.2 invariant.)
        local ok, err, ast = run_checker([[
            function f(): {() -> integer}
                local fns: {() -> integer} = {}
                for i = 1, 3 do
                    fns[i] = function(): integer return i end
                end
                return fns
            end
        ]])
        assert.truthy(ok, err)
        -- the `for` statement is the second stat of f's body; its control decl
        local forstat = tlfunc_stats(ast)[2]
        assert.equal("Ast.StatFor", forstat._tag)
        assert.is_true(forstat.decl._captured)
        assert.is_nil(forstat.decl._assigned)
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

    it("infers the full tuple from a trailing option-first multi-return call", function()
        -- `return h()` where h returns (integer?, integer): the trailing return
        -- values must be harvested from the original call BEFORE forcing the
        -- option-typed first value (forcing wraps it in an ExpCast carrying no
        -- `_types`), so the lambda infers a 2-tuple, not a single value.
        local ok, err, ast = run_checker([[
            function h(): (integer?, integer)
                return 1, 2
            end
            function f(): integer
                local g = function()
                    return h()
                end
                local a: integer?, b: integer = g()
                if a then return (a as integer) + b else return b end
            end
        ]])
        assert.truthy(ok, err)
        -- g is the first stat-decl of f's body (f is the 2nd top-level)
        local g = ast[2].block.stats[1].decls[1]
        assert.equal("Type.Function", g._type._tag)
        assert.equal(2, #g._type.rettypes)
        assert.equal("Type.Integer", g._type.rettypes[1]._tag)
        assert.equal("Type.Integer", g._type.rettypes[2]._tag)
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

    it("names a lambda generically in the duplicate-parameter error", function()
        -- A lambda has no name; the message must say "anonymous function", not
        -- "declaration of function 'nil'".
        assert_type_error("duplicate parameter 'x' in anonymous function", [[
            function g(): integer
                local f: (integer, integer) -> (integer) =
                    function(x: integer, x: integer): integer return x end
                return 1
            end
        ]])
    end)
end)

describe("bound method references (obj:m)", function()
    it("a bound method has the method's type with self removed", function()
        local ok, err, ast = run_checker([[
            record Adder base: integer end
            function Adder:add(x: integer): integer
                return self.base + x
            end
            function use(): (integer) -> integer
                local a = Adder.new(0)
                local f = a:add
                return f
            end
        ]])
        assert.truthy(ok, err)
        -- `use` is the last top-level; its body declares `f = a:add`
        local fnode = ast[#ast]
        local fdecl = fnode.block.stats[2]
        local ftype = fdecl.decls[1]._type
        assert.equal("Type.Function", ftype._tag)
        assert.equal(1, #ftype.params)
        assert.equal("Type.Integer", ftype.params[1]._tag)
        assert.equal(1, #ftype.rettypes)
        assert.equal("Type.Integer", ftype.rettypes[1]._tag)
    end)

    it("typechecks where a matching function value is expected", function()
        assert_type_check([[
            record Adder base: integer end
            function Adder:add(x: integer): integer return self.base + x end
            function use(): integer
                local a = Adder.new(1)
                local f: (integer) -> integer = a:add
                return f(2)
            end
        ]])
    end)

    it("rejects a bound method bound to an incompatible function type", function()
        assert_type_error(
            "do not match, expected %(string%) %-> string but found %(integer%) %-> integer",
            [[
                record Adder base: integer end
                function Adder:add(x: integer): integer return self.base + x end
                function use()
                    local a = Adder.new(1)
                    local f: (string) -> string = a:add
                end
            ]])
    end)

    it("rejects a method reference on a non-record receiver", function()
        assert_type_error("expected record in receiver of method reference", [[
            function use()
                local n = 3
                local f = n:bump
            end
        ]])
    end)

    it("rejects a reference to a non-existent method", function()
        assert_type_error("method 'nope' not found in record", [[
            record Adder base: integer end
            function use()
                local a = Adder.new(1)
                local f = a:nope
            end
        ]])
    end)

    it("rejects a foreign (C) method reference", function()
        assert_type_error("a foreign %(C%) method cannot be used as a first", [[
            local m = foreign import "math.h"
            function use()
                local f = m:fabs
            end
        ]])
    end)
end)
