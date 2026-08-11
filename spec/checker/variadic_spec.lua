-- Typechecker tests for variadic parameters (`...`). Covers the vararg
-- expressions `#...` and `...[i]`, the `{...}` array constructor, adjust-up
-- across (in)compatible representations, calls/returns/locals that pass or
-- spread `...`, variadic functions as first-class values, scope rules and
-- bans, and variadic methods.
--
-- These assertions run the type checker only (no code is generated or run);
-- the end-to-end code-generator counterparts live in spec/coder/variadic_spec.lua.
local types = require 'titan-compiler.types'
local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local assert_type_check = h.assert_type_check
local check_errs = h.check_errs

describe("variadic parameters (typechecker)", function()
    -- Convenience: wrap a body in a variadic `foo(...: integer)` and run the
    -- checker over the whole module.
    local function in_vararg(body, elem)
        return string.format([[
            function foo(...: %s): nil
                %s
            end
        ]], elem or "integer", body)
    end

    describe("vararg expressions inside a variadic function", function()
        it("accepts `#...` and types it integer", function()
            local ok, err, ast = run_checker(in_vararg("local n = #...; return nil"))
            assert.truthy(ok, err)
            local decl = ast[1].block.stats[1]
            -- `#...` was rewritten to an ExpDotsLen of type integer
            assert.same("Ast.ExpDotsLen", decl.exps[1]._tag)
            assert.same(types.Integer(), decl.exps[1]._type)
        end)

        it("types `...[i]` as the element type t (not t?)", function()
            local ok, err, ast = run_checker(in_vararg(
                "local x: integer = ...[1]; return nil"))
            assert.truthy(ok, err)
            local idx = ast[1].block.stats[1].exps[1]
            -- the synthesized cast wraps an ExpDotsIndex of type integer
            local node = idx._tag == "Ast.ExpCast" and idx.exp or idx
            assert.same("Ast.ExpDotsIndex", node._tag)
            assert.same(types.Integer(), node._type)
            assert.falsy(node._nilfill)
        end)

        it("types `...[i]` as value for `...: value`", function()
            local ok, err, ast = run_checker(string.format([[
                function foo(...: value): nil
                    local x: value = ...[1]
                    return nil
                end
            ]]))
            assert.truthy(ok, err)
            local node = ast[1].block.stats[1].exps[1]
            node = node._tag == "Ast.ExpCast" and node.exp or node
            assert.same("Ast.ExpDotsIndex", node._tag)
            assert.same(types.Value(), node._type)
        end)

        it("types `...[i]` as s? for `...: s?` (no double option)", function()
            local ok, err, ast = run_checker([[
                function foo(...: integer?): nil
                    local x: integer? = ...[1]
                    return nil
                end
            ]])
            assert.truthy(ok, err)
            local node = ast[1].block.stats[1].exps[1]
            node = node._tag == "Ast.ExpCast" and node.exp or node
            assert.same("Ast.ExpDotsIndex", node._tag)
            assert.same(types.Option(types.Integer()), node._type)
        end)

        it("coerces a float index of `...[i]` to integer", function()
            assert_type_check([[
                function foo(...: integer): integer
                    return ...[1]
                end
            ]])
        end)
    end)

    describe("array constructor with `...`", function()
        it("types `{...}` as {t}", function()
            local ok, err, ast = run_checker([[
                function foo(...: string): {string}
                    return {...}
                end
            ]])
            assert.truthy(ok, err)
            local lst = ast[1].block.stats[1].exps[1]
            assert.same("Ast.ExpInitList", lst._tag)
            assert.same(types.Array(types.String()), lst._type)
            -- the `...` field is kept as a marker for codegen
            local last = lst.fields[#lst.fields]
            assert.same("Ast.ExpDots", last.exp._tag)
        end)

        it("types `{1, 2, ...}` backward from the vararg", function()
            local ok, err, ast = run_checker([[
                function foo(...: integer): {integer}
                    return {1, 2, ...}
                end
            ]])
            assert.truthy(ok, err)
            local lst = ast[1].block.stats[1].exps[1]
            assert.same(types.Array(types.Integer()), lst._type)
        end)

        it("rejects `{..., 1}` (`...` must be last)", function()
            local errs = check_errs([[
                function foo(...: integer): nil
                    local x = {..., 1}
                    return nil
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("'%.%.%.' must be the last field", errs[1])
        end)

        it("rejects `...` in a map constructor", function()
            local errs = check_errs([[
                function foo(...: integer): nil
                    local x: {string:integer} = {a = 1, ...}
                    return nil
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("cannot mix", errs[1])
        end)

        it("rejects `...` in a record constructor", function()
            local errs = check_errs([[
                record Point
                    x: integer
                end
                function foo(...: integer): nil
                    local p: Point = { x = 1, ... }
                    return nil
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("cannot mix", errs[1])
        end)

        it("accepts `{...: integer}` into a {float} context (coerceable)", function()
            assert_type_check([[
                function foo(...: integer): {float}
                    return {...}
                end
            ]])
        end)

        it("accepts `{...: integer}` into a {value} context (boxes)", function()
            assert_type_check([[
                function foo(...: integer): {value}
                    return {...}
                end
            ]])
        end)

        it("rejects `{...: integer}` into a {string} context (not coerceable)", function()
            -- The `...` element type must be coerceable to the (context-overridden)
            -- array element type; an incompatible element is a clean compile error,
            -- not a silent bit-reinterpretation at runtime.
            local errs = check_errs([[
                function foo(...: integer): {string}
                    return {...}
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("'%.%.%.' element type integer is not coerceable to "
                .. "array element type string", errs[1])
        end)
    end)

    -- An optional adjust-up slot whose base is NOT coerceable from the vararg
    -- element type must be a clean compile error, NOT a silent miscompile /
    -- segfault (a raw store of e.g. integer into a string? slot would later be
    -- read as a TString*). One case per adjust-up site.
    describe("optional adjust-up across incompatible representations", function()
        it("rejects `local x: string? = ...: integer`", function()
            local errs = check_errs([[
                function f(...: integer): integer
                    local x: string? = ...
                    if x then return #x else return -1 end
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("expected string%? but found integer%?", errs[1])
        end)

        it("rejects `x = ...: integer` into a string? variable", function()
            local errs = check_errs([[
                function f(...: integer): integer
                    local x: string? = nil
                    x = ...
                    if x then return #x else return -1 end
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("expected string%? but found integer%?", errs[1])
        end)

        it("rejects `return ...: integer` from a function returning string?", function()
            local errs = check_errs([[
                function f(...: integer): string?
                    return ...
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("expected string%? but found integer%?", errs[1])
        end)

        it("rejects `...: integer` into a string? fixed param of a callee", function()
            local errs = check_errs([[
                function g(a: string?): integer
                    if a then return #a else return -1 end
                end
                function f(...: integer): integer
                    return g(...)
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("expected string%? but found integer%?", errs[1])
        end)
    end)

    describe("calls passing `...`", function()
        it("accepts `f(a, ...)` to a variadic callee (whole-tail)", function()
            assert_type_check([[
                function g(a: integer, ...: integer): integer
                    return a
                end
                function foo(...: integer): integer
                    return g(1, ...)
                end
            ]])
        end)

        it("accepts `f(...)` to a variadic callee", function()
            assert_type_check([[
                function g(...: integer): integer
                    return 0
                end
                function foo(...: integer): integer
                    return g(...)
                end
            ]])
        end)

        it("adjust-up into a non-variadic callee's fixed params", function()
            local ok, err, ast = run_checker([[
                function g(a: integer, b: integer): integer
                    return a + b
                end
                function foo(...: integer): integer
                    return g(...)
                end
            ]])
            assert.truthy(ok, err)
            local call = ast[2].block.stats[1].exps[1]
            -- `...` expanded to g(...[1], ...[2])
            assert.same(2, #call.args.args)
            local a1 = call.args.args[1]
            a1 = a1._tag == "Ast.ExpCast" and a1.exp or a1
            assert.same("Ast.ExpDotsIndex", a1._tag)
        end)

        it("gradual element types are compatible both ways across a call", function()
            assert_type_check([[
                function gv(...: value): integer
                    return 0
                end
                function fi(...: integer): integer
                    return gv(...)
                end
            ]])
            assert_type_check([[
                function gi(...: integer): integer
                    return 0
                end
                function fv(...: value): integer
                    return gi(...)
                end
            ]])
        end)

        -- A scalar representation MISMATCH between the caller's `...` element and
        -- the callee's `...` element (integer<->float) is NOT a legal forward:
        -- assignment adjustment rejects it, so forwarding codegen never has to
        -- bit-reinterpret one scalar slot as the other. (Only `value` widen/narrow
        -- is gradual; the int/float pair is not.)
        it("rejects forwarding `...: integer` to a `...: float` callee", function()
            local errs = check_errs([[
                function g(...: float): float
                    return 0.0
                end
                function f(...: integer): float
                    return g(...)
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("'...' element type integer is not compatible with the "
                .. "'...' element type float", errs[1])
        end)

        it("rejects forwarding `...: float` to a `...: integer` callee", function()
            local errs = check_errs([[
                function g(...: integer): integer
                    return 0
                end
                function f(...: float): integer
                    return g(...)
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("'...' element type float is not compatible with the "
                .. "'...' element type integer", errs[1])
        end)
    end)

    describe("return ...", function()
        it("accepts `return ...` into the fixed return arity", function()
            local ok, err, ast = run_checker([[
                function foo(...: integer): (integer, integer)
                    return ...
                end
            ]])
            assert.truthy(ok, err)
            local ret = ast[1].block.stats[1]
            assert.same(2, #ret.exps)
        end)

        it("accepts `return a, ...` adjust-up", function()
            assert_type_check([[
                function foo(...: integer): (integer, integer)
                    return 1, ...
                end
            ]])
        end)

        it("deficit-0 `return a, ...` is a legal no-op", function()
            local ok, err, ast = run_checker([[
                function foo(...: integer): integer
                    return 1, ...
                end
            ]])
            assert.truthy(ok, err)
            local ret = ast[1].block.stats[1]
            assert.same(1, #ret.exps) -- the trailing `...` was dropped
        end)

        it("discards `return ...` from a ()-returning function", function()
            local ok, err, tree = run_checker([[
                function foo(...: integer): ()
                    return ...
                end
            ]])
            assert.truthy(ok, err)
            local ret = tree[1].block.stats[1]
            assert.same({}, ret.exps)
            assert.same(1, #ret._result_adjustment.discards)
        end)

        it("retains and discards over-supply beyond fixed return arity", function()
            local ok, err, tree = run_checker([[
                function foo(...: integer): integer
                    return 1, 2, ...
                end
            ]])
            assert.truthy(ok, err)
            local ret = tree[1].block.stats[1]
            assert.same(2, #ret._result_adjustment.discards)
            assert.truthy(ret.exps[2]._discard_results)
        end)
    end)

    describe("local / assignment adjust-up", function()
        it("`local a, b, c = ...` synthesizes three `...[k]` reads", function()
            local ok, err, ast = run_checker([[
                function foo(...: integer): integer
                    local a, b, c = ...
                    return a + b + c
                end
            ]])
            assert.truthy(ok, err)
            local decl = ast[1].block.stats[1]
            assert.same(3, #decl.exps)
            for _, e in ipairs(decl.exps) do
                local node = e._tag == "Ast.ExpCast" and e.exp or e
                assert.same("Ast.ExpDotsIndex", node._tag)
            end
        end)

        it("an optional declared slot nil-fills", function()
            local ok, err, ast = run_checker([[
                function foo(...: integer): nil
                    local a: integer? = ...
                    return nil
                end
            ]])
            assert.truthy(ok, err)
            local e = ast[1].block.stats[1].exps[1]
            local node = e._tag == "Ast.ExpCast" and e.exp or e
            assert.same("Ast.ExpDotsIndex", node._tag)
            assert.truthy(node._nilfill)
        end)

        it("retains static over-supply and discards the trailing run", function()
            local ok, err, tree = run_checker([[
                function foo(...: integer): nil
                    local a: integer, b: integer = 2, 3, 5, ...
                    return nil
                end
            ]])
            assert.truthy(ok, err)
            local stat = tree[1].block.stats[1]
            assert.same(2, #stat._result_adjustment.discards)
            assert.truthy(stat.exps[3]._discard_results)
        end)

        it("adjust-up in an assignment", function()
            assert_type_check([[
                function foo(...: integer): integer
                    local a: integer, b: integer = 0, 0
                    a, b = ...
                    return a + b
                end
            ]])
        end)
    end)

    describe("variadic functions as first-class values", function()
        it("a variadic function assigns to a matching value type", function()
            assert_type_check([[
                function g(a: integer, ...: integer): integer
                    return a
                end
                function foo(): integer
                    local f: (integer, ...: integer) -> integer = g
                    return f(1)
                end
            ]])
        end)

        it("a variadic function passes/returns as a value (gradual via value)", function()
            assert_type_check([[
                function g(...: integer): integer
                    return 0
                end
                function foo(): (...: value) -> integer
                    return g
                end
            ]])
        end)

        it("a variadic value accepts fixed inputs moved into its tail", function()
            assert_type_check([[
                function g(...: integer): integer
                    return 0
                end
                function foo(): integer
                    local f: (integer) -> integer = g
                    return f(1)
                end
            ]])
        end)
    end)

    describe("scope and bans", function()
        it("rejects `...: nil`", function()
            local errs = check_errs([[
                function foo(...: nil): nil
                    return nil
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("variadic parameter cannot have type nil", errs[1])
        end)

        it("rejects `...` outside a variadic function", function()
            local errs = check_errs([[
                function foo(a: integer): integer
                    return ...[1]
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("'%.%.%.' can only be used inside a variadic function", errs[1])
        end)

        it("rejects a bare `...` in operand position", function()
            local errs = check_errs([[
                function foo(...: integer): integer
                    return 1 + ...
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("'%.%.%.' can only be used as the last item", errs[1])
        end)

        it("rejects `...` inside an inner lambda", function()
            local errs = check_errs([[
                function foo(...: integer): integer
                    local g = function(): integer return ...[1] end
                    return g()
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("'%.%.%.' is not visible inside an inner function", errs[1])
        end)

        it("a variadic lambda's own `...` resolves", function()
            assert_type_check([[
                function foo(): integer
                    local g = function(...: integer): integer return ...[1] end
                    return g(1, 2)
                end
            ]])
        end)

        it("discards surplus arguments and an unused trailing `...`", function()
            local ok, err, tree = run_checker([[
                function g(a: integer): integer
                    return a
                end
                function foo(...: integer): integer
                    return g(1, 2, ...)
                end
            ]])
            assert.truthy(ok, err)
            local call = tree[2].block.stats[1].exps[1]
            assert.same(1, call._npassed_args)
            assert.truthy(call.args.args[2]._discard_results)
        end)
    end)

    -- An UNTYPED lambda vararg `...` (no `: type`) takes its element type from the
    -- expected `(...: T) -> R` context, exactly like an untyped lambda parameter.
    describe("untyped lambda vararg inference", function()
        it("infers the element type from a typed local context", function()
            assert_type_check([[
                function foo(): integer
                    local f: (...: integer) -> integer = function(...)
                        return ...[1]
                    end
                    return f(1, 2)
                end
            ]])
        end)

        it("infers the element type from a parameter context", function()
            assert_type_check([[
                function apply(f: (...: integer) -> integer): integer
                    return f(1, 2, 3)
                end
                function foo(): integer
                    return apply(function(...) return ...[1] end)
                end
            ]])
        end)

        it("infers the element type from a return-type context", function()
            assert_type_check([[
                function make(): (...: string) -> integer
                    return function(...) return #... end
                end
            ]])
        end)

        it("an explicit `...: T` lambda vararg wins over context", function()
            assert_type_check([[
                function apply(f: (...: integer) -> integer): integer
                    return f(1, 2)
                end
                function foo(): integer
                    return apply(function(...: integer) return ...[1] end)
                end
            ]])
        end)

        it("rejects an untyped `...` lambda with no inferable context", function()
            local errs = check_errs([[
                function foo(): integer
                    local f = function(...) return ...[1] end
                    return f(1)
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("cannot infer the type of '%.%.%.'", errs[1])
        end)

        it("rejects an untyped `...` lambda in a NON-variadic context", function()
            -- Fixed arities match (one fixed param `a` against `(integer)`), so the
            -- context IS used -- but it is non-variadic (no `varargtype`), while the
            -- lambda is variadic. The inference path reports that specifically.
            local errs = check_errs([[
                function foo(): integer
                    local f: (integer) -> integer = function(a, ...)
                        return a + ...[1]
                    end
                    return f(1)
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("the lambda is variadic but the expected type is not",
                errs[1])
        end)

        it("applies the `nil` ban to an inferred lambda vararg element", function()
            -- Even when inferred, a `...: nil` element is illegal -- but a function
            -- type cannot annotate `...: nil` (banned), so exercise the explicit
            -- form to confirm the ban reaches the lambda path.
            local errs = check_errs([[
                function foo(): integer
                    local f = function(...: nil) return 1 end
                    return f()
                end
            ]])
            assert.truthy(#errs >= 1)
            assert.match("variadic parameter cannot have type nil", errs[1])
        end)
    end)

    describe("variadic methods", function()
        it("accepts a variadic method and a variadic call to it", function()
            assert_type_check([[
                record R
                    x: integer
                end
                function R:sum(...: integer): integer
                    return self.x + ...[1]
                end
                function foo(r: R): integer
                    return r:sum(1, 2, 3)
                end
            ]])
        end)

        it("a variadic method forwards `...` to itself", function()
            assert_type_check([[
                record R
                    x: integer
                end
                function R:sum(...: integer): integer
                    return self.x
                end
                function R:fwd(...: integer): integer
                    return self:sum(...)
                end
            ]])
        end)
    end)
end)
