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
        assert.is_nil(frozen.rooting.construction.source)
        assert.is_true(frozen.rooting.construction.result.traced)
        assert.equal("conditional_lua_stack_slot",
            frozen.rooting.construction.result.storage)
        assert.equal("eligible_exact_titan_clone",
            frozen.rooting.construction.result.condition)
        assert.same({}, frozen.rooting.fixed.argument_source)
        assert.same({}, frozen.rooting.fixed.argument_destination)
        assert.same({}, frozen.rooting.fixed.result_source)
        assert.same({}, frozen.rooting.fixed.result_destination)
        assert.is_false(frozen.rooting.ranges.argument_source.traced)
        assert.equal(1, #frozen.rebase_points)
        assert.equal("after_native_call",
            frozen.rebase_points[1].kind)
        assert.equal(200, frozen.flexible_result_demand.abi_cap)
        assert.same({
            filename = cast.loc.filename,
            line = cast.loc.line,
            col = cast.loc.col,
        }, frozen.location)
        assert.match("callable adapter", frozen.trace_name, 1, true)
    end)

    it("freezes callable views at ordinary sinks without wrapping contextual lambdas",
    function()
        local ok, err, tree = run_checker([[
            local function source(x: integer): integer
                return x
            end

            record Holder
                callback: (value) -> value;
            end

            module_callback: (value) -> value =
                function(v: value): value return v end
            module_adjusted_lambda: (value) -> value =
                function(v: integer): integer return v end

            local function take(callback: (value) -> value)
            end

            function returned(): (value) -> value
                return source
            end

            function sinks()
                local contextual: (value) -> value =
                    function(v: value): value return v end
                local source_lambda: (integer) -> integer =
                    function(v: integer): integer return v end
                local adjusted_lambda: (value) -> value = source_lambda
                local declared: (value) -> value = source
                module_callback = source
                declared = source
                take(source)
                take { callback = source }
                local holder = Holder.new(source)
                holder.callback = source
                local array: {(value) -> value} = {source}
                local map: {string: (value) -> value} = {["x"] = source}
            end
        ]])
        assert.is_true(ok, err)

        local casts, seen = {}, {}
        local function collect(value)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            if value._tag == "Ast.ExpCast" and value._callable_adapter then
                casts[#casts + 1] = value
            end
            for key, child in pairs(value) do
                if type(key) ~= "string" or key:sub(1, 1) ~= "_" then
                    collect(child)
                end
            end
        end
        collect(tree)
        assert.equal(12, #casts)
        for _, cast in ipairs(casts) do
            assert.equal("Ast.ExpCast", cast._tag)
            assert.is_true(cast._implicit_coercion)
            assert.equal("callable", cast._adjustment.kind)
            assert.equal(cast.target, cast._type)
            assert.equal(cast.exp._type, cast._callable_adapter.source)
            assert.equal(cast._type, cast._callable_adapter.target)
            assert.is_true(cast._callable_adapter.relation_free)
        end

        local sinks = find_function(tree, "sinks")
        assert.equal("Ast.ExpFunction", sinks.block.stats[1].exps[1]._tag)
        assert.is_nil(sinks.block.stats[1].exps[1]._callable_adapter)

        local module_adjusted
        for _, node in ipairs(tree) do
            if node._tag == "Ast.TopLevelVar"
               and node.decl.name == "module_adjusted_lambda" then
                module_adjusted = node
                break
            end
        end
        assert.truthy(module_adjusted)
        assert_callable_cast(module_adjusted.value)
        assert.equal("Ast.ExpFunction", module_adjusted.value.exp._tag)
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

            function open_return():
                (...: (integer, value) -> value)
                return produce()
            end

            local function consume(
                ...: (integer, value) -> value
            )
            end

            function forward(...: (integer) -> integer)
                consume(...)
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

        local returned = find_function(tree, "open_return").block.stats[1]
        raw = assert(returned._result_adjustment.open_adjustment)
        frozen = assert(returned._result_adjustment.open_callable_adapter)
        assert.equal("callable", raw.kind)
        assert.equal(frozen, raw._callable_adapter)
        assert.equal(frozen,
            returned.exps[1]._open_results.callable_adapter)

        local call = find_function(tree, "forward")
            .block.stats[1].callexp
        raw = assert(call._arg_adjustment.open_adjustment)
        frozen = assert(call._arg_adjustment.open_callable_adapter)
        assert.equal("callable", raw.kind)
        assert.equal(frozen, raw._callable_adapter)
        assert.equal(frozen,
            call.args.args[1]._open_dots.callable_adapter)

        local cast = find_function(tree, "nested")
            .block.stats[1].exps[1]
        assert_callable_cast(cast)
        local operation = cast._callable_adapter
            .arguments[1].operation
        assert.equal("callable_view", operation.kind)
        assert.equal("immediate", operation.timing)
        assert.is_false(operation.may_relocate)
        assert.is_false(cast._callable_adapter.arguments[1].rebase_after)
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
