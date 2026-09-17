local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local check_errs = h.check_errs
local run_checker = h.run_checker

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

local function assert_rejected(source, first_sink)
    local errors = check_errs(source)
    assert.is_true(#errors > 0, "expected program to be rejected")
    if first_sink then
        assert.match(first_sink, errors[1])
    end
end

describe("type-relation soundness (checker)", function()
    it("separates logical truthiness from strict boolean sinks", function()
        local ok, err, tree = run_checker([[
            function negate(a: value): boolean
                return not a
            end
            function conjoin(a: value, b: value): boolean
                return a and b
            end
            function disjoin(a: value, b: value): boolean
                return a or b
            end
            function boolean_default(a: value)
                local result = a or false
            end
            function strict(a: value): boolean
                return a
            end
            function optional<|T|>(a: T?): boolean
                return not a
            end
        ]])
        assert.is_true(ok, err)
        local function assert_truthiness(exp, source_tag)
            assert.equal("Ast.ExpCast", exp._tag)
            assert.is_nil(exp._adjustment)
            assert.equal("operator_conversion", exp._operator_conversion.kind)
            assert.equal("truthiness", exp._operator_conversion.op)
            assert.equal(source_tag, exp._operator_conversion.source._tag)
            assert.equal("Type.Boolean", exp._type._tag)
        end
        assert_truthiness(tree[1].block.stats[1].exps[1].exp, "Type.Value")
        for index = 2, 3 do
            local op = tree[index].block.stats[1].exps[1]
            assert_truthiness(op.lhs, "Type.Value")
            assert_truthiness(op.rhs, "Type.Value")
        end
        local default = tree[4].block.stats[1].exps[1]
        assert_truthiness(default.lhs, "Type.Value")
        assert.equal("Ast.ExpBool", default.rhs._tag)
        local strict = tree[5].block.stats[1].exps[1]
        assert.equal("gradual_view", strict._adjustment.kind)
        assert.equal("project", strict._adjustment.op)
        assert_truthiness(tree[6].block.stats[1].exps[1].exp, "Type.Value")
    end)

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
        with_header("typedef double ffi_double;\n", function(header)
            assert_rejected([[
            foreign import "]] .. header .. [["

            function bridge(): integer
                local source: {float} = {2.0}
                local middle: {foreign ffi_double} = source
                local final: {integer} = middle
                return final[1]
            end
            ]], "middle")
        end)
    end)

    it("does not lift scalar coercions through fixed Function slots", function()
        local cases = {
            {
                sink = "optional_result",
                source = [[
                    function actual(): integer return 1 end
                    function probe()
                        local optional_result: function (): integer? = actual
                    end
                ]],
            },
            {
                sink = "narrowed_result",
                source = [[
                    function actual(): float return 1.5 end
                    function probe()
                        local narrowed_result: function (): integer = actual
                    end
                ]],
            },
            {
                sink = "converted_input",
                source = [[
                    function actual(x: float) end
                    function probe()
                        local converted_input: function (integer): () = actual
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
                local optional: function (): integer? = none
                local definite: function (): integer = optional
                return definite()
            end
        ]], "optional")

        assert_rejected([[
            function none(): nil return nil end

            function through_array(): integer
                local first: {function (): nil} = {none}
                local middle: {function (): integer?} = first
                local final: {function (): integer} = middle
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

                local dynamic_result: function (): integer = actual
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
                local narrow: function (integer): integer = short
                local wide: function (integer, integer): integer = short
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

    for _, op in ipairs({"==", "~="}) do
        for _, expression in ipairs({
            "candidate " .. op .. " nil",
            "nil " .. op .. " candidate",
        }) do
            it("compares an option with nil using " .. expression, function()
                local ok, err = run_checker([[
                    function fn(candidate: boolean?): boolean
                        return ]] .. expression .. [[
                    end
                ]])
                assert.is_true(ok, err)
            end)
        end
    end

    it("lifts nil directly to the option type used by equality", function()
        local ok, err, tree = run_checker([[
            function fn(candidate: boolean?): boolean
                return candidate == nil
            end
        ]])
        assert.is_true(ok, err)
        local comparison = tree[1].block.stats[1].exps[1]
        assert.equal("Ast.ExpCast", comparison.rhs._tag)
        assert.equal("Type.Option", comparison.rhs.target._tag)
        assert.equal("Type.Boolean", comparison.rhs.target.base._tag)
        assert.equal("Ast.ExpNil", comparison.rhs.exp._tag)
        assert.equal("direct_coercion", comparison.rhs._adjustment.kind)
        assert.equal("option_nil", comparison.rhs._adjustment.coercion.op)
        assert.equal("identity", comparison._comparison.op)
    end)

    it("does not make a non-option boolean comparable with nil", function()
        assert_rejected([[
            function fn(candidate: boolean): boolean
                return candidate == nil
            end
        ]], "trying to compare values of incomparable types")
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
        with_header("typedef int ffi_int;\n", function(header)
            local errors = check_errs([[
            foreign import "]] .. header .. [["

            function read_array(): integer
                local one = 1 as foreign ffi_int
                local xs: {foreign ffi_int} = {one}
                return xs[1]
            end

            function read_map(): integer
                local one = 1 as foreign ffi_int
                local map: {string: foreign ffi_int} = {
                    ["one"] = one
                }
                return map["one"]
            end
            ]])
            assert.equal(0, #errors, table.concat(errors, "\n"))
        end)
    end)

    it("keeps raw C pointers out of implicit and Array dynamic paths", function()
        with_header("typedef int ffi_int;\n", function(header)
            local errors = check_errs([[
                foreign import "]] .. header .. [["

                local function implicit(v: value): nil
                    local pointer: foreign *ffi_int = v
                end

                local function compare(
                    pointer: foreign *ffi_int,
                    dynamic: value
                ): boolean
                    return pointer == dynamic
                end

                local function construct(
                    pointer: foreign *ffi_int
                ): {foreign *ffi_int}
                    return {pointer}
                end

                local function raw(pointer: foreign *ffi_int): nil
                end

                local function expose(): value
                    return raw
                end
            ]])
            assert.same(4, #errors)
            local joined = table.concat(errors, "\n")
            assert.match("pointer", joined)
            assert.match("C binary operator", joined)
            assert.match("cannot construct an array", joined)
            assert.match("return", joined)
        end)
    end)

    it("rejects raw C pointer Array and Map observations statically", function()
        with_header("typedef int ffi_int;\n", function(header)
            local errors = check_errs([[
                foreign import "]] .. header .. [["

                local function read_array(
                    pointers: {foreign *ffi_int}
                )
                    local pointer = pointers[1]
                end

                local function read_map(
                    pointers: {string: foreign *ffi_int}
                )
                    local pointer = pointers["one"]
                end
            ]])
            assert.same(2, #errors)
            assert.match("cannot read array elements", errors[1])
            assert.match("cannot read map values", errors[2])
        end)
    end)

    it("allows raw C pointer Array and Map write-only lvalues", function()
        with_header("typedef int ffi_int;\n", function(header)
            local errors = check_errs([[
            foreign import "]] .. header .. [["

            local function write_array(
                pointers: {foreign *ffi_int},
                pointer: foreign *ffi_int
            )
                pointers[1] = pointer
            end

            local function write_map(
                pointer: foreign *ffi_int
            )
                local pointers: {string: foreign *ffi_int} = {
                    ["one"] = pointer,
                }
                pointers["two"] = pointer
            end
            ]])
            assert.equal(0, #errors, table.concat(errors, "\n"))
        end)
    end)
end)
