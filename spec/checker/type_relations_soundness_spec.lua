local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local check_errs = h.check_errs
local run_checker = h.run_checker

local function assert_rejected(source, first_sink)
    local errors = check_errs(source)
    assert.is_true(#errors > 0, "expected program to be rejected")
    if first_sink then
        assert.match(first_sink, errors[1])
    end
end

describe("type-relation soundness (checker)", function()
    it("classifies each fixed sink once and keeps one outer Option cast",
    function()
        local original = types.assignment_adjustment
        local counts = {
            identity = 0,
            force = 0,
            wrap = 0,
        }
        types.assignment_adjustment = function(source, target, ...)
            if source._tag == "Type.Integer"
               and target._tag == "Type.Integer" then
                counts.identity = counts.identity + 1
            elseif source._tag == "Type.Option"
               and source.base._tag == "Type.Integer"
               and target._tag == "Type.Float" then
                counts.force = counts.force + 1
            elseif source._tag == "Type.Integer"
               and target._tag == "Type.Option"
               and target.base._tag == "Type.Float" then
                counts.wrap = counts.wrap + 1
            end
            return original(source, target, ...)
        end

        local ok, err, tree
        local ran, failure = pcall(function()
            ok, err, tree = run_checker([[
                function identity(x: integer)
                    local y: integer = x
                end

                function force(x: integer?)
                    local y: float = x
                end

                function wrap(x: integer)
                    local y: float? = x
                end
            ]])
        end)
        types.assignment_adjustment = original
        assert.is_true(ran, failure)
        assert.is_true(ok, err)
        assert.same({
            identity = 1,
            force = 1,
            wrap = 1,
        }, counts)

        local identity = tree[1].block.stats[1].exps[1]
        assert.equal("Ast.ExpVar", identity._tag)
        assert.equal("identity", identity._assignment_adjustment.kind)

        local force = tree[2].block.stats[1].exps[1]
        assert.equal("Ast.ExpCast", force._tag)
        assert.equal("Ast.ExpVar", force.exp._tag)
        assert.equal("option_force", force._adjustment.coercion.op)
        assert.equal("integer_to_float",
            force._adjustment.coercion.inner.op)

        local wrap = tree[3].block.stats[1].exps[1]
        assert.equal("Ast.ExpCast", wrap._tag)
        assert.equal("Ast.ExpVar", wrap.exp._tag)
        assert.equal("option_wrap", wrap._adjustment.coercion.op)
        assert.equal("integer_to_float",
            wrap._adjustment.coercion.inner.op)
    end)

    it("classifies each deferred constructor open run exactly once", function()
        local original = types.assignment_adjustment
        local counts = {
            inferred = 0,
            contextual = 0,
        }
        types.assignment_adjustment = function(source, target, ...)
            if source._tag == "Type.Option"
               and source.base._tag == "Type.Integer" then
                if target._tag == "Type.Integer" then
                    counts.inferred = counts.inferred + 1
                elseif target._tag == "Type.Float" then
                    counts.contextual = counts.contextual + 1
                end
            end
            return original(source, target, ...)
        end

        local ok, err, tree
        local ran, failure = pcall(function()
            ok, err, tree = run_checker([[
                function produce(): (...: integer?)
                    return 1
                end

                function inferred(): {integer}
                    return {produce()}
                end

                function contextual(): {float}
                    local values: {float} = {produce()}
                    return values
                end
            ]])
        end)
        types.assignment_adjustment = original
        assert.is_true(ran, failure)
        assert.is_true(ok, err)
        assert.same({
            inferred = 1,
            contextual = 1,
        }, counts)

        local inferred =
            tree[2].block.stats[1].exps[1]._positional_adjustment
        local contextual =
            tree[3].block.stats[1].exps[1]._positional_adjustment
        for _, adjusted in ipairs({ inferred, contextual }) do
            assert.is_truthy(adjusted.open_adjustment)
            assert.is_true(adjusted.open_adjustment ==
                adjusted.open_source._open_results.adjustment)
        end
        assert.equal("option_force",
            inferred.open_adjustment.coercion.op)
        assert.equal("identity",
            inferred.open_adjustment.coercion.inner.kind)
        assert.equal("option_force",
            contextual.open_adjustment.coercion.op)
        assert.equal("integer_to_float",
            contextual.open_adjustment.coercion.inner.op)
    end)

    it("keeps numeric-for bounds exact after Option forcing", function()
        assert_rejected([[
            function bad(v: value)
                for i: integer = v, 3 do
                end
            end
        ]], "'for' start expression")

        assert_rejected([[
            function bad()
                for i: float = 1, 3.0 do
                end
            end
        ]], "'for' start expression")

        local errors = check_errs([[
            function good(first: integer?, last: integer?)
                for i: integer = first, last do
                end
            end
        ]])
        assert.equal(0, #errors, table.concat(errors, "\n"))
    end)

    it("does not lift C numeric conversions through Arrays", function()
        assert_rejected([[
            local ffi = foreign import "titan/ffi.h"

            function bridge(): integer
                local source: {float} = {2.0}
                local middle: {ffi.titan_ffi_double} = source
                local final: {integer} = middle
                return final[1]
            end
        ]], "middle")
    end)

    it("does not lift scalar coercions through fixed Function slots", function()
        local cases = {
            {
                sink = "optional_result",
                source = [[
                    function actual(): integer return 1 end
                    function probe()
                        local optional_result: () -> integer? = actual
                    end
                ]],
            },
            {
                sink = "narrowed_result",
                source = [[
                    function actual(): float return 1.5 end
                    function probe()
                        local narrowed_result: () -> integer = actual
                    end
                ]],
            },
            {
                sink = "converted_input",
                source = [[
                    function actual(x: float) end
                    function probe()
                        local converted_input: (integer) -> () = actual
                    end
                ]],
            },
        }

        for _, case in ipairs(cases) do
            assert_rejected(case.source, case.sink)
        end
    end)

    it("rejects the Option Function chain at its first invalid edge", function()
        assert_rejected([[
            function none(): nil return nil end

            function through(): integer
                local optional: () -> integer? = none
                local definite: () -> integer = optional
                return definite()
            end
        ]], "optional")

        assert_rejected([[
            function none(): nil return nil end

            function through_array(): integer
                local first: {() -> nil} = {none}
                local middle: {() -> integer?} = first
                local final: {() -> integer} = middle
                return final[1]()
            end
        ]], "middle")
    end)

    it("retains only the intended value-bearing gradual bridges", function()
        local errors = check_errs([[
            function actual(): value return 1 end

            function accepted(): integer
                local ints: {integer} = {1}
                local dynamic_array: {value} = ints
                local ints_again: {integer} = dynamic_array

                local int_map: {string: integer} = { ["x"] = 2 }
                local dynamic_map: {string: value} = int_map
                local int_map_again: {string: integer} = dynamic_map

                local dynamic_result: () -> integer = actual
                return ints_again[1] + int_map_again["x"] +
                    dynamic_result()
            end
        ]])
        assert.equal(0, #errors, table.concat(errors, "\n"))
    end)

    it("stores strict read guards and symmetric callable comparisons", function()
        local ok, err, tree = run_checker([[
            local function short(x: integer): integer
                return x
            end

            function observations(
                values: {integer},
                entries: {string: integer}
            ): (integer, integer, boolean, boolean)
                local narrow: (integer) -> integer = short
                local wide: (integer, integer) -> integer = short
                return values[1], entries["x"],
                    narrow == wide, wide == narrow
            end
        ]])
        assert.is_true(ok, err)

        local returned = tree[2].block.stats[3].exps
        assert.equal("option", returned[1].exp.var._read_guard.op)
        assert.equal("integer",
            returned[1].exp.var._read_guard.inner.op)
        assert.equal("option", returned[2].exp.var._read_guard.op)
        assert.equal("integer",
            returned[2].exp.var._read_guard.inner.op)
        assert.equal("consistent", returned[3]._comparison.op)
        assert.equal("consistent", returned[4]._comparison.op)
    end)

    it("admits distinct strict and explicitly dynamic value projections", function()
        local errors = check_errs([[
            local function identity(v: value): value
                return v
            end

            function project(v: value): (integer, integer, boolean)
                local strict: integer = v
                local written = identity(v) as integer
                local predicate = identity(v) is integer
                return strict, written, predicate
            end
        ]])
        assert.equal(0, #errors, table.concat(errors, "\n"))
    end)

    it("records structural open-run adjustment instead of scalar casts", function()
        local errors = check_errs([[
            function produce(): (...: {value})
                return {1}
            end

            function consume(): {{integer}}
                return {produce()}
            end

            function sink(...: {{integer}})
            end

            function forward(...: {{value}})
                sink(...)
            end
        ]])
        assert.equal(0, #errors, table.concat(errors, "\n"))
    end)

    it("admits C scalar Array and Map reads for complete lowering", function()
        local errors = check_errs([[
            local ffi = foreign import "titan/ffi.h"

            function read_array(): integer
                local one = 1 as ffi.titan_ffi_int
                local xs: {ffi.titan_ffi_int} = {one}
                return xs[1]
            end

            function read_map(): integer
                local one = 1 as ffi.titan_ffi_int
                local map: {string: ffi.titan_ffi_int} = {
                    ["one"] = one
                }
                return map["one"]
            end
        ]])
        assert.equal(0, #errors, table.concat(errors, "\n"))
    end)

    it("keeps raw C pointers out of implicit and Array dynamic paths", function()
        assert_rejected([[
            local ffi = foreign import "titan/ffi.h"

            function implicit(v: value): nil
                local pointer: *ffi.titan_ffi_int = v
            end
        ]], "pointer")

        assert_rejected([[
            local ffi = foreign import "titan/ffi.h"

            function compare(
                pointer: *ffi.titan_ffi_int,
                dynamic: value
            ): boolean
                return pointer == dynamic
            end
        ]], "C binary operator")

        assert_rejected([[
            local ffi = foreign import "titan/ffi.h"

            local function construct(
                pointer: *ffi.titan_ffi_int
            ): {*ffi.titan_ffi_int}
                return {pointer}
            end
        ]], "cannot construct an array")

        assert_rejected([[
            local ffi = foreign import "titan/ffi.h"

            local function raw(pointer: *ffi.titan_ffi_int): nil
            end

            function expose(): value
                return raw
            end
        ]], "return")
    end)

    it("rejects raw C pointer Array and Map observations statically", function()
        assert_rejected([[
            local ffi = foreign import "titan/ffi.h"

            local function read(
                pointers: {*ffi.titan_ffi_int}
            )
                local pointer = pointers[1]
            end
        ]], "cannot read array elements")

        assert_rejected([[
            local ffi = foreign import "titan/ffi.h"

            local function read(
                pointers: {string: *ffi.titan_ffi_int}
            )
                local pointer = pointers["one"]
            end
        ]], "cannot read map values")
    end)

    it("allows raw C pointer Array and Map write-only lvalues", function()
        local errors = check_errs([[
            local ffi = foreign import "titan/ffi.h"

            local function write_array(
                pointers: {*ffi.titan_ffi_int},
                pointer: *ffi.titan_ffi_int
            )
                pointers[1] = pointer
            end

            local function write_map(
                pointer: *ffi.titan_ffi_int
            )
                local pointers: {string: *ffi.titan_ffi_int} = {
                    ["one"] = pointer,
                }
                pointers["two"] = pointer
            end
        ]])
        assert.equal(0, #errors, table.concat(errors, "\n"))
    end)
end)
