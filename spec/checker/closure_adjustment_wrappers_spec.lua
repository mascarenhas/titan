local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local run_checker = h.run_checker

local function find_function(tree, name)
    for _, node in ipairs(tree) do
        if node._tag == "Ast.TopLevelFunc" and node.name == name then
            return node
        end
    end
    error("missing function " .. name)
end

local function assert_callable_cast(cast)
    assert.equal("Ast.ExpCast", cast._tag)
    assert.is_true(cast._implicit_coercion)
    assert.equal("callable", cast._adjustment.kind)
    assert.is_nil(cast._assignment_adjustment)
    assert.is_nil(cast.exp._assignment_adjustment)
    assert.equal("Type.Function", cast.exp._type._tag)
    assert.equal("Type.Function", cast._type._tag)
    assert.is_false(types.equals(cast.exp._type, cast._type))
    assert.equal(cast._type, cast.target)
end

describe("closure adjustment wrappers (checker)", function()
    it("classifies one finite edge and freezes its target-typed cast", function()
        local original = types.assignment_adjustment
        local count = 0
        local classified
        types.assignment_adjustment = function(source, target, ...)
            local adjustment = original(source, target, ...)
            if source._tag == "Type.Function"
               and target._tag == "Type.Function"
               and not types.equals(source, target) then
                count = count + 1
                classified = adjustment
            end
            return adjustment
        end

        local ok, err, tree
        local ran, failure = pcall(function()
            ok, err, tree = run_checker([[
                local function actual(x: integer)
                end

                function probe()
                    local adjusted: (integer, value) -> value = actual
                end
            ]])
        end)
        types.assignment_adjustment = original
        assert.is_true(ran, failure)
        assert.is_true(ok, err)
        assert.equal(1, count)

        local cast = find_function(tree, "probe").block.stats[1].exps[1]
        assert_callable_cast(cast)
        assert.equal(classified, cast._adjustment)
        assert.equal(cast.loc, cast.exp.loc)

        local frozen = assert(cast._callable_adapter)
        assert.equal("callable_adapter_plan", frozen.kind)
        assert.equal(frozen, cast._adjustment._callable_adapter)
        assert.equal(cast.exp._type, frozen.source)
        assert.equal(cast._type, frozen.target)
        assert.is_true(frozen.relation_free)
        assert.is_true(frozen.no_nested_interface_conversions)
        assert.equal(#frozen.arguments,
            frozen.dense.argument_count)
        assert.equal(#frozen.results,
            frozen.dense.result_count)
        assert.equal("nil_fill_result", frozen.results[1].kind)
        assert.equal(1, frozen.results[1].expected_index)
        assert.equal("Type.Value",
            frozen.results[1].expected_type._tag)
        assert.equal("Type.Value",
            cast._adjustment.results[1].expected_type._tag)
        assert.is_nil(cast._adjustment.results[1].adjustment)
        assert.equal("callable_strict_relay",
            frozen.strict_relay.kind)
        assert.equal(2, #frozen.strict_relay.parameters)
        assert.equal("integer",
            frozen.strict_relay.parameters[1].guard.op)
        assert.equal("value",
            frozen.strict_relay.parameters[2].guard.op)
        assert.equal("value",
            frozen.strict_relay.results[1].guard.op)
        assert.is_false(frozen.strict_relay.vararg)
        assert.is_true(frozen.rooting.construction.source.traced)
        assert.is_true(frozen.rooting.construction.result.traced)
        assert.equal("after_wrapper_construction",
            frozen.rebase_points[1].kind)
        assert.equal("after_native_call",
            frozen.rebase_points[#frozen.rebase_points].kind)
        assert.equal(200, frozen.flexible_result_demand.abi_cap)
        assert.same({
            filename = cast.loc.filename,
            line = cast.loc.line,
            col = cast.loc.col,
        }, frozen.location)
        assert.match("callable adapter", frozen.trace_name, 1, true)
    end)

    it("leaves exact, is, and dynamic views unchanged and freezes written as",
    function()
        local ok, err, tree = run_checker([[
            local function actual(x: integer): integer
                return x
            end

            function probe(v: value)
                local exact: (integer) -> integer = actual
                local written = actual as (integer, value) -> value
                local predicate = actual is (integer, value) -> value
                local dynamic: (integer) -> integer = v
            end
        ]])
        assert.is_true(ok, err)
        local stats = find_function(tree, "probe").block.stats

        local exact = stats[1].exps[1]
        assert.equal("Ast.ExpVar", exact._tag)
        assert.equal("identity", exact._assignment_adjustment.kind)
        assert.is_nil(exact._callable_adapter)

        local written = stats[2].exps[1]
        assert.equal("Ast.ExpCast", written._tag)
        assert.equal("callable", written._written_cast.op)
        assert.equal(written._written_cast.callable._callable_adapter,
            written._callable_adapter)
        assert.is_nil(written._adjustment)

        local predicate = stats[3].exps[1]
        assert.equal("Ast.ExpIs", predicate._tag)
        assert.equal("callable", predicate._written_cast.op)
        assert.is_nil(predicate._callable_adapter)
        assert.is_nil(predicate._written_cast.callable._callable_adapter)

        local dynamic = stats[4].exps[1]
        assert.equal("Ast.ExpCast", dynamic._tag)
        assert.equal("gradual_view", dynamic._adjustment.kind)
        assert.equal("project", dynamic._adjustment.op)
        assert.is_nil(dynamic._callable_adapter)
    end)

    it("keeps open and nested callable adapters reachable without reclassification",
    function()
        local ok, err, tree = run_checker([[
            local function actual(x: integer): integer
                return x
            end

            function produce(): (...: (integer) -> integer)
                return actual
            end

            function collect(): {(integer, value) -> value}
                return {produce()}
            end

            local function accepts_wide(
                callback: (integer, integer) -> ()
            )
            end

            function nested(
                callback: (integer) -> ()
            )
                local adjusted:
                    ((integer) -> ()) -> () = accepts_wide
            end
        ]])
        assert.is_true(ok, err)

        local constructor = find_function(tree, "collect")
            .block.stats[1].exps[1]._positional_adjustment
        local raw = assert(constructor.open_adjustment)
        local frozen = assert(constructor.open_callable_adapter)
        assert.equal("callable", raw.kind)
        assert.equal(frozen, raw._callable_adapter)
        assert.equal(frozen,
            constructor.open_source._open_results.callable_adapter)

        local cast = find_function(tree, "nested")
            .block.stats[1].exps[1]
        assert_callable_cast(cast)
        local operation = cast._callable_adapter
            .arguments[1].operation
        assert.equal("callable_view", operation.kind)
        assert.equal("immediate", operation.timing)
        assert.is_true(operation.may_relocate)
        assert.equal("callable_adapter_plan", operation.adapter.kind)
        assert.equal(operation.adapter.callable, operation.callable)
        assert.equal(operation.adapter,
            cast._adjustment.arguments[1]
                .adjustment._callable_adapter)
    end)

    it("shares nil-filled result actions with Interface adapters", function()
        local ok, err, tree = run_checker([[
            interface Callback
                function invoke(): value
            end

            record Concrete
            end

            function Concrete:invoke()
            end

            function wrap(concrete: Concrete): Callback
                return concrete
            end
        ]])
        assert.is_true(ok, err)
        local conversion = find_function(tree, "wrap")
            .block.stats[1].exps[1]._interface_conversion
        local mapping = assert(conversion.methods[1])
        assert.equal("adapter", mapping.slot_kind)
        assert.equal("nil_fill_result",
            mapping.adjustment.results[1].kind)

        local adapter = assert(mapping.interface_adapter)
        assert.equal("interface_method_adapter", adapter.kind)
        assert.equal("nil_fill_result", adapter.results[1].kind)
        assert.equal("synthesize_nil", adapter.results[1].effect)
        assert.equal("Type.Value", adapter.results[1].target_type._tag)
        assert.equal(mapping.adjustment._callable_adapter,
            adapter.callable_adapter)
        assert.equal(adapter.callable,
            adapter.callable_adapter.callable)
        assert.is_true(adapter.relation_free)
        assert.equal("after_native_call",
            adapter.rebase_points[#adapter.rebase_points].kind)
    end)
end)
