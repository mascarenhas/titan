local core = require "titan-compiler.coder.core"
local _ENV = core

-- Freeze an already generated value in a C temporary for lexical evaluation
-- order without publishing a tracing root. Native calls transport arguments in
-- C formals, not Lua-stack slots. The expression's ordinary allocation/result
-- publication and traced program homes retain ownership; any fresh allocation
-- performed while evaluating it establishes its own root immediately.
function coder._freeze_code(ctx, typ, stats, exp)
    if types.is_c_aggregate(typ) then
        local decl, name = newforeigntmp(ctx, typ, exp)
        return stats .. "\n" .. decl, name
    end
    local decl, name = newtmp(ctx, typ, false)
    return render([[
        $STATS
        $DECL
        $NAME = $EXP;
    ]], {
        STATS = stats,
        DECL = decl,
        NAME = name,
        EXP = exp,
    }), name
end

function coder._freeze(ctx, node)
    local stats, exp = codeexp(ctx, node)
    return coder._freeze_code(ctx, node._type, stats, exp)
end

function coder._nominal_owner_module_expr(ctx, fqtn)
    assert(type(fqtn) == "string",
        "nominal owner descriptor has no qualified name")
    local module = assert(fqtn:match("^(.*)%.[^.]+$"),
        "nominal owner is not module-qualified: " .. fqtn)
    if module == ctx.module then return "_mod" end
    if not ctx.modules[module] then
        ctx.modules[module] = nextupvalue(ctx.tlcontext)
    end
    return render("uvalue(&_mod->uv[$INDEX].uv)", {
        INDEX = c_integer_literal(ctx.modules[module]),
    })
end

function coder._interface_owner_module_expr(ctx, owner)
    assert(owner and type(owner.name) == "string",
        "Interface concrete/owner descriptor has no qualified name")
    return coder._nominal_owner_module_expr(ctx, owner.name)
end

function coder._interface_closed_record(value, allowed, use)
    assert(type(value) == "table", use .. " is not a table")
    for key in pairs(value) do
        assert(allowed[key] == true,
            use .. " has unknown field " .. tostring(key))
    end
end

function coder._interface_dense_list(value, use)
    assert(type(value) == "table", use .. " is not a list")
    local count = #value
    for key in pairs(value) do
        assert(type(key) == "number"
               and key >= 1 and key <= count
               and key == math.floor(key),
            use .. " is not a closed dense list")
    end
    return count
end

function coder._interface_frozen_value_equal(actual, expected)
    if type(actual) ~= type(expected) then return false end
    if type(expected) ~= "table" then return actual == expected end
    if expected._tag and expected._tag:match("^Type%.") then
        return actual._tag ~= nil and types.equals(actual, expected)
    end
    for key, value in pairs(expected) do
        if not coder._interface_frozen_value_equal(actual[key], value) then
            return false
        end
    end
    for key in pairs(actual) do
        if expected[key] == nil then return false end
    end
    return true
end

function coder._interface_adapter_is_gc(typ)
    if typ == nil then return false end
    local normalized = types.normalize(typ)
    return normalized ~= nil and types.is_gc(normalized) or false
end

function coder._interface_injection_may_relocate(typ)
    typ = types.normalize(typ)
    if not typ then return false end
    if typ._tag == "Type.Array" then return true end
    if typ._tag == "Type.Option" then
        return coder._interface_injection_may_relocate(typ.base)
    end
    return false
end

function coder._validate_interface_frozen_guard(
        guard, target, use, seen)
    target = assert(types.normalize(target),
        use .. " has an unnormalizable target")
    coder._interface_closed_record(guard, {
        kind = true, op = true, target = true,
        element = true, key = true, value = true,
        inner = true, name = true, isconst = true,
    }, use)
    assert(guard.kind == "gradual_guard"
           and guard.target
           and types.equals(guard.target, target),
        use .. " has a mismatched target")

    seen = seen or {}
    assert(not seen[guard], use .. " contains a recursive guard cycle")
    seen[guard] = true
    local tag = target._tag
    if tag == "Type.Array" then
        assert(guard.op == "array"
               and guard.isconst.tag == target.isconst.tag
               and (types.valid_array_constness(guard.isconst) and guard.isconst.tag ~= "maybe")
               and guard.element
               and guard.key == nil and guard.value == nil
               and guard.inner == nil and guard.name == nil,
            use .. " has a malformed Array guard")
        coder._validate_interface_frozen_guard(
            guard.element, target.elem, use .. " Array element", seen)
    elseif tag == "Type.Map" then
        assert(guard.op == "map"
               and guard.isconst == nil
               and guard.key and guard.value
               and guard.element == nil
               and guard.inner == nil and guard.name == nil,
            use .. " has a malformed Map guard")
        coder._validate_interface_frozen_guard(
            guard.key, target.keys, use .. " Map key", seen)
        coder._validate_interface_frozen_guard(
            guard.value, target.values, use .. " Map value", seen)
    elseif tag == "Type.Option" then
        assert(guard.op == "option"
               and guard.isconst == nil
               and guard.inner
               and guard.element == nil
               and guard.key == nil and guard.value == nil
               and guard.name == nil,
            use .. " has a malformed Option guard")
        coder._validate_interface_frozen_guard(
            guard.inner, target.base, use .. " Option value", seen)
    elseif tag == "Type.Nominal"
           or tag == "Type.Record"
           or tag == "Type.Union" then
        local name = target.fqtn or target.name
        assert(guard.op == "nominal" and guard.name == name
               and guard.isconst == nil
               and guard.element == nil
               and guard.key == nil and guard.value == nil
               and guard.inner == nil,
            use .. " has a malformed nominal guard")
    else
        local expected = types.is_c_tvalue(target)
            and "c_tvalue" or coder._gradual_op_for_tag[tag]
        assert(expected and guard.op == expected
               and guard.isconst == nil
               and guard.element == nil
               and guard.key == nil and guard.value == nil
               and guard.inner == nil and guard.name == nil,
            use .. " has a malformed leaf guard")
    end
    seen[guard] = nil
end

function coder._validate_interface_adapter_operation(
        operation, declared_source, declared_target, use, seen)
    coder._interface_closed_record(operation, {
        kind = true, mode = true,
        source = true, target = true,
        declared_source = true, declared_target = true,
        timing = true, may_raise = true, may_relocate = true,
        guard = true, callable = true, adapter = true,
    }, use)
    local source = assert(types.normalize(declared_source),
        use .. " has an unnormalizable declared source")
    local target = assert(types.normalize(declared_target),
        use .. " has an unnormalizable declared target")
    assert(operation.source and operation.target
           and operation.declared_source
           and operation.declared_target
           and types.equals(operation.source, source)
           and types.equals(operation.target, target)
           and types.equals(
               types.normalize(operation.declared_source), source)
           and types.equals(
               types.normalize(operation.declared_target), target),
        use .. " changes its frozen endpoints")

    if operation.kind == "identity" then
        assert(types.equals(source, target)
               and operation.mode == nil
               and operation.timing == "immediate"
               and operation.may_raise == false
               and operation.may_relocate == false
               and operation.guard == nil
               and operation.callable == nil
               and operation.adapter == nil,
            use .. " has a malformed identity operation")
    elseif operation.kind == "gradual_inject" then
        local relocates =
            coder._interface_injection_may_relocate(source)
        assert(target._tag == "Type.Value"
               and operation.mode == nil
               and operation.timing == "immediate"
               and operation.may_raise == relocates
               and operation.may_relocate == relocates
               and operation.guard == nil
               and operation.callable == nil
               and operation.adapter == nil,
            use .. " has a malformed gradual injection")
    elseif operation.kind == "gradual_guard" then
        local delayed = operation.mode == "structural"
            and target._tag ~= "Type.Option"
        assert((operation.mode == "project"
                or operation.mode == "structural")
               and operation.timing == (delayed
                    and "delayed_observation" or "immediate")
               and operation.may_raise == not delayed
               and operation.may_relocate == not delayed
               and operation.guard ~= nil
               and operation.callable == nil
               and operation.adapter == nil,
            use .. " has a malformed gradual guard")
        coder._validate_interface_frozen_guard(
            operation.guard, target, use .. " guard", {})
        -- Keep the central strict helper's closed low-level representation
        -- check as a second assertion, without asking any type relation.
        coder._checked_gradual_guard(
            operation.guard, target, use .. " guard")
    elseif operation.kind == "callable_view" then
        assert(source._tag == "Type.Function"
               and target._tag == "Type.Function"
               and operation.mode == nil
               and operation.timing == "immediate"
               and operation.may_raise == true
               and operation.may_relocate == false
               and operation.guard == nil
               and operation.adapter ~= nil
               and operation.callable == operation.adapter.callable,
            use .. " has a malformed callable view")
        coder._validate_callable_adapter_plan(
            operation.adapter, source, target,
            use .. " callable view", seen)
    else
        error(use .. " has unknown operation "
            .. tostring(operation.kind))
    end
    return operation
end

function coder._validate_interface_adapter_action(
        action, expected, operation_source, operation_target, use, seen)
    assert(type(action) == "table", use .. " is not a table")
    local allowed = {}
    for key in pairs(expected) do allowed[key] = true end
    local has_operation = operation_source ~= nil
    if has_operation then allowed.operation = true end
    coder._interface_closed_record(action, allowed, use)
    if has_operation then
        assert(action.operation ~= nil,
            use .. " lacks its frozen component operation")
        coder._validate_interface_adapter_operation(
            action.operation, operation_source, operation_target,
            use .. " operation", seen)
        expected.rebase_after = action.operation.may_relocate
    end
    for key, value in pairs(expected) do
        assert(coder._interface_frozen_value_equal(action[key], value),
            use .. " has a mismatched " .. tostring(key))
    end
    if has_operation then
        assert(action.rebase_after
               == action.operation.may_relocate,
            use .. " has a mismatched rebase marker")
    else
        assert(action.operation == nil
               and action.rebase_after == false,
            use .. " has an unexpected component operation")
    end
end

function coder._interface_expected_action(
        kind, order, phase, source_type, target_type, extra)
    local expected = {
        kind = kind,
        order = order,
        id = phase .. ":" .. tostring(order),
        phase = phase,
        source_type = source_type,
        target_type = target_type,
        source_gc =
            coder._interface_adapter_is_gc(source_type),
        destination_gc =
            coder._interface_adapter_is_gc(target_type),
        rebase_after = false,
    }
    for key, value in pairs(extra or {}) do expected[key] = value end
    return expected
end

function coder._validate_interface_callable_actions(
        callable, source, target, use, seen)
    coder._interface_closed_record(callable, {
        kind = true, source = true, target = true,
        exact = true, arguments = true, results = true,
    }, use)
    assert(source._tag == "Type.Function"
           and target._tag == "Type.Function"
           and callable.kind == "interface_callable_actions"
           and callable.source and callable.target
           and types.equals(callable.source, source)
           and types.equals(callable.target, target)
           and callable.exact == types.equals(source, target),
        use .. " has mismatched callable signatures")
    coder._interface_dense_list(
        callable.arguments, use .. " arguments")
    coder._interface_dense_list(
        callable.results, use .. " results")

    seen = seen or {}
    assert(not seen[callable],
        use .. " contains a recursive callable cycle")
    seen[callable] = true

    local ai = 0
    local function argument(kind, source_type, target_type, extra,
            operation_source, operation_target)
        ai = ai + 1
        local expected = coder._interface_expected_action(
            kind, ai, "argument", source_type, target_type, extra)
        coder._validate_interface_adapter_action(
            callable.arguments[ai], expected,
            operation_source, operation_target,
            use .. " argument " .. tostring(ai), seen)
    end

    local shared = math.min(#source.params, #target.params)
    for index = 1, shared do
        argument("argument",
            target.params[index], source.params[index], {
                expected_index = index,
                actual_index = index,
                source_kind = "interface_fixed",
                destination_kind = "concrete_fixed",
            }, target.params[index], source.params[index])
    end
    for index = #target.params + 1, #source.params do
        if target.varargtype then
            argument("tail_or_nil_to_argument",
                target.varargtype, source.params[index], {
                    actual_index = index,
                    expected_tail_offset =
                        index - #target.params,
                    source_kind = "interface_tail",
                    source_open = true,
                    destination_kind = "concrete_fixed",
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = source.params[index],
                    },
                    present_arm = "operation",
                }, target.varargtype, source.params[index])
        else
            argument("nil_fill",
                types.Nil(), source.params[index], {
                    actual_index = index,
                    source_kind = "constant_nil",
                    destination_kind = "concrete_fixed",
                    admissible = true,
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = source.params[index],
                    },
                })
        end
    end
    for index = #source.params + 1, #target.params do
        if source.varargtype then
            argument("argument_to_tail",
                target.params[index], source.varargtype, {
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "concrete_tail",
                    destination_open = true,
                }, target.params[index], source.varargtype)
        else
            argument("ignore_argument",
                target.params[index], nil, {
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "discard",
                    destination_gc = false,
                    effect = "evaluate_and_discard",
                })
        end
    end
    if source.varargtype and target.varargtype then
        argument("tail_to_tail",
            target.varargtype, source.varargtype, {
                expected_tail_consumed =
                    math.max(0, #source.params - #target.params),
                source_kind = "interface_tail",
                source_open = true,
                destination_kind = "concrete_tail",
                destination_open = true,
            }, target.varargtype, source.varargtype)
    elseif source.varargtype then
        argument("empty_tail", nil, source.varargtype, {
            source_kind = "empty",
            destination_kind = "concrete_tail",
            source_gc = false,
            destination_open = true,
            count = 0,
        })
    elseif target.varargtype then
        argument("ignore_tail", target.varargtype, nil, {
            expected_tail_consumed =
                math.max(0, #source.params - #target.params),
            source_kind = "interface_tail",
            source_open = true,
            destination_kind = "discard",
            destination_gc = false,
            effect = "evaluate_run_and_discard",
        })
    end
    assert(ai == #callable.arguments,
        use .. " has extra argument actions")

    local ri = 0
    local function result(kind, source_type, target_type, extra,
            operation_source, operation_target)
        ri = ri + 1
        local expected = coder._interface_expected_action(
            kind, ri, "result", source_type, target_type, extra)
        coder._validate_interface_adapter_action(
            callable.results[ri], expected,
            operation_source, operation_target,
            use .. " result " .. tostring(ri), seen)
    end

    for index, expected_type in ipairs(target.rettypes) do
        local actual_type = source.rettypes[index]
        if actual_type then
            result("result", actual_type, expected_type, {
                actual_index = index,
                expected_index = index,
                source_kind = "concrete_fixed",
                destination_kind = "interface_fixed",
            }, actual_type, expected_type)
        elseif source.flexrettype then
            local optional = expected_type._tag == "Type.Option"
            local wraps =
                callable.results[ri + 1].wrap_present == true
            local operation_target =
                wraps and expected_type.base or expected_type
            result(optional and "flex_to_optional_result"
                    or "flex_to_result",
                source.flexrettype, expected_type, {
                    expected_index = index,
                    actual_flex_offset =
                        index - #source.rettypes,
                    source_kind = "concrete_flex",
                    source_open = true,
                    destination_kind = "interface_fixed",
                    operation_target_type = operation_target,
                    missing_arm = {
                        kind = optional and "nil_fill"
                            or "raise_missing_result",
                        target_type = expected_type,
                    },
                    present_arm = {
                        kind = "operation",
                        wrap_present = wraps,
                        target_type = operation_target,
                    },
                    wrap_present = wraps,
                }, source.flexrettype, operation_target)
            assert(optional
                   or callable.results[ri].wrap_present == false,
                use .. " has Option wrapping on a non-Option result")
        else
            result("nil_fill_result", types.Nil(), expected_type, {
                expected_index = index,
                expected_type = expected_type,
                source_kind = "constant_nil",
                destination_kind = "interface_fixed",
                admissible = true,
                effect = "synthesize_nil",
                missing_arm = {
                    kind = "nil_fill",
                    admissible = true,
                    target_type = expected_type,
                },
            })
        end
    end
    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype then
            result("result_to_flex",
                source.rettypes[index], target.flexrettype, {
                    actual_index = index,
                    expected_flex_offset =
                        index - #target.rettypes,
                    source_kind = "concrete_fixed",
                    destination_kind = "interface_flex",
                    destination_open = true,
                }, source.rettypes[index], target.flexrettype)
        else
            result("hide_result", source.rettypes[index], nil, {
                actual_index = index,
                source_kind = "concrete_fixed",
                destination_kind = "discard",
                destination_gc = false,
                effect = "discard",
            })
        end
    end
    if source.flexrettype and target.flexrettype then
        result("flex_to_flex",
            source.flexrettype, target.flexrettype, {
                actual_flex_consumed =
                    math.max(0,
                        #target.rettypes - #source.rettypes),
                source_kind = "concrete_flex",
                source_open = true,
                destination_kind = "interface_flex",
                destination_open = true,
            }, source.flexrettype, target.flexrettype)
    elseif source.flexrettype then
        result("hide_flex", source.flexrettype, nil, {
            actual_flex_consumed =
                math.max(0,
                    #target.rettypes - #source.rettypes),
            source_kind = "concrete_flex",
            source_open = true,
            destination_kind = "discard",
            destination_gc = false,
            effect = "discard_run",
        })
    elseif target.flexrettype then
        result("end_flex", nil, target.flexrettype, {
            source_kind = "empty",
            destination_kind = "interface_flex",
            source_gc = false,
            destination_open = true,
            count = 0,
        })
    end
    assert(ri == #callable.results,
        use .. " has extra result actions")
    seen[callable] = nil
end

function coder._validate_callable_strict_slot(
        slot, typ, index, use)
    coder._interface_closed_record(slot, {
        index = true, type = true, guard = true,
    }, use)
    local normalized = assert(types.normalize(typ),
        use .. " has an unnormalizable boundary type")
    assert(slot.index == index
           and slot.type
           and types.equals(slot.type, normalized)
           and slot.guard ~= nil,
        use .. " has a mismatched boundary slot")
    local guard = maybe3.get_checked(slot.guard, use .. " guard")
    if guard then
        coder._validate_interface_frozen_guard(
            guard, normalized, use .. " guard", {})
        coder._checked_gradual_guard(guard, normalized, use .. " guard")
    end
end

function coder._validate_callable_strict_relay(relay, target, use)
    coder._interface_closed_record(relay, {
        kind = true, parameters = true, vararg = true,
        results = true, flexible_result = true,
    }, use)
    assert(relay.kind == "callable_strict_relay",
        use .. " has an unknown relay kind")
    assert(coder._interface_dense_list(
        relay.parameters, use .. " parameters") == #target.params,
        use .. " has a mismatched parameter count")
    for index, typ in ipairs(target.params) do
        coder._validate_callable_strict_slot(
            relay.parameters[index], typ, index,
            use .. " parameter " .. tostring(index))
    end
    if target.varargtype then
        assert(type(relay.vararg) == "table",
            use .. " lacks its variadic boundary")
        coder._validate_callable_strict_slot(
            relay.vararg, target.varargtype, "vararg",
            use .. " variadic boundary")
    else
        assert(relay.vararg == nil,
            use .. " has an unexpected variadic boundary")
    end
    assert(coder._interface_dense_list(
        relay.results, use .. " results") == #target.rettypes,
        use .. " has a mismatched result count")
    for index, typ in ipairs(target.rettypes) do
        coder._validate_callable_strict_slot(
            relay.results[index], typ, index,
            use .. " result " .. tostring(index))
    end
    if target.flexrettype then
        assert(type(relay.flexible_result) == "table",
            use .. " lacks its flexible-result boundary")
        coder._validate_callable_strict_slot(
            relay.flexible_result, target.flexrettype,
            "flexible_result", use .. " flexible-result boundary")
    else
        assert(relay.flexible_result == nil,
            use .. " has an unexpected flexible-result boundary")
    end
end

function coder._validate_callable_adapter_demand(
        demand, source, target, use)
    coder._interface_closed_record(demand, {
        kind = true, abi_cap = true,
        source_has_flex = true, target_has_flex = true,
        fixed_source_flex_consumed = true,
        fixed_source_surplus = true,
        remaining_source_capacity = true,
        within_abi_cap = true, mode = true,
        target_demand_parameter = true,
        unlimited_demand = true,
    }, use)
    local consumed = math.max(
        0, #target.rettypes - #source.rettypes)
    local surplus = math.max(
        0, #source.rettypes - #target.rettypes)
    local source_has_flex = source.flexrettype ~= nil
    local target_has_flex = target.flexrettype ~= nil
    local expected = {
        kind = "callable_flexible_result_demand",
        abi_cap = 200,
        source_has_flex = source_has_flex,
        target_has_flex = target_has_flex,
        fixed_source_flex_consumed = consumed,
        fixed_source_surplus = surplus,
        remaining_source_capacity = 200 - consumed,
        within_abi_cap = consumed <= 200,
        mode = not source_has_flex and "none"
            or (target_has_flex and "forward_target_demand"
                or "fixed_prefix"),
        target_demand_parameter = target_has_flex
            and "_flexwant" or nil,
        unlimited_demand = target_has_flex
            and "LUA_MULTRET" or nil,
    }
    assert(coder._interface_frozen_value_equal(demand, expected),
        use .. " is not canonical")
end

function coder._callable_action_rebase_reason(action)
    assert(action.operation
            and action.operation.timing == "immediate"
            and action.operation.may_relocate == true
            and action.operation.kind ~= "callable_view",
        "callable adapter has a rebase for a non-relocating action")
    return "immediate_gradual_guard"
end

function coder._validate_callable_adapter_rebases(adapter, use)
    coder._interface_dense_list(
        adapter.rebase_points, use .. " rebase points")
    local expected = {}
    for _, action in ipairs(adapter.arguments) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    expected[#expected + 1] = {
        kind = "after_native_call",
        backend = "immediate_source_closure",
        reason = "source_call_may_relocate_stack",
    }
    for _, action in ipairs(adapter.results) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    for index, point in ipairs(adapter.rebase_points) do
        local wanted = expected[index]
        assert(wanted, use .. " has an extra rebase point")
        local allowed
        if point.kind == "after_action" then
            allowed = { kind = true, action = true, reason = true }
        elseif point.kind == "after_native_call" then
            allowed = { kind = true, backend = true, reason = true }
        else
            allowed = { kind = true, reason = true }
        end
        coder._interface_closed_record(
            point, allowed,
            use .. " rebase point " .. tostring(index))
        assert(coder._interface_frozen_value_equal(point, wanted),
            use .. " has a mismatched rebase point " .. tostring(index))
    end
    assert(#adapter.rebase_points == #expected,
        use .. " is missing a rebase point")
end

-- Implementation notes: doc/implementation/closure-adjustment-wrappers.md#one-frozen-callable-adapter-plan
function coder._validate_callable_adapter_plan(
        adapter, source_type, target_type, use, seen)
    use = use or "callable adapter"
    coder._interface_closed_record(adapter, {
        kind = true, source = true, target = true, exact = true,
        location = true, trace_name = true,
        callable = true, arguments = true, results = true,
        dense = true, strict_relay = true, rooting = true,
        rebase_points = true, flexible_result_demand = true,
        relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true,
    }, use)
    local source = assert(types.normalize(source_type),
        use .. " has an unnormalizable source")
    local target = assert(types.normalize(target_type),
        use .. " has an unnormalizable target")
    assert(source._tag == "Type.Function"
           and target._tag == "Type.Function"
           and adapter.kind == "callable_adapter_plan"
           and adapter.source and adapter.target
           and types.equals(adapter.source, source)
           and types.equals(adapter.target, target)
           and adapter.exact == types.equals(source, target)
           and adapter.arguments == adapter.callable.arguments
           and adapter.results == adapter.callable.results
           and adapter.relation_free == true
           and adapter.no_nested_interface_conversions == true
           and adapter.uses_base_off == true,
        use .. " has mismatched identity/signatures")

    seen = seen or {}
    assert(not seen[adapter],
        use .. " contains a recursive adapter cycle")
    seen[adapter] = true

    coder._interface_closed_record(adapter.location, {
        filename = true, line = true, col = true,
    }, use .. " location")
    local loc = adapter.location
    assert(type(loc.filename) == "string"
           and type(loc.line) == "number" and loc.line >= 1
           and loc.line == math.floor(loc.line)
           and type(loc.col) == "number" and loc.col >= 1
           and loc.col == math.floor(loc.col),
        use .. " lacks a real source location")
    local expected_trace = string.format(
        "[callable adapter %s -> %s at %s:%d:%d]",
        types.tostring(source), types.tostring(target),
        loc.filename, loc.line, loc.col)
    assert(adapter.trace_name == expected_trace,
        use .. " has a mismatched trace name")

    coder._validate_interface_callable_actions(
        adapter.callable, source, target,
        use .. " callable actions", seen)
    coder._interface_closed_record(adapter.dense, {
        argument_count = true, result_count = true,
    }, use .. " dense inventory")
    assert(adapter.dense.argument_count == #adapter.arguments
           and adapter.dense.result_count == #adapter.results,
        use .. " has a mismatched dense inventory")
    coder._validate_callable_strict_relay(
        adapter.strict_relay, target, use .. " strict relay")
    coder._validate_callable_adapter_rooting(adapter, use)
    coder._validate_callable_adapter_rebases(adapter, use)
    coder._validate_callable_adapter_demand(
        adapter.flexible_result_demand, source, target,
        use .. " flexible-result demand")

    seen[adapter] = nil
    return adapter
end

function coder._adapter_operation_allocates(action)
    return action.operation ~= nil
        and action.operation.kind == "callable_view"
end

function coder._adapter_has_open_source(actions)
    for _, action in ipairs(actions) do
        if action.operation and action.source_open then return true end
    end
    return false
end

function coder._adapter_has_open_allocating_destination(actions)
    for _, action in ipairs(actions) do
        if coder._adapter_operation_allocates(action)
           and action.destination_open then
            return true
        end
    end
    return false
end

function coder._adapter_actions_allocate(adapter)
    for _, actions in ipairs({ adapter.arguments, adapter.results }) do
        for _, action in ipairs(actions) do
            if coder._adapter_operation_allocates(action) then return true end
        end
    end
    return false
end

function coder._validate_interface_adapter_fixed_roots(
        roots, actions, policy, use, retain_until)
    coder._interface_dense_list(roots, use)
    local expected = {}
    for _, action in ipairs(actions) do
        local include
        local typ
        if policy == "none" then
            include = false
        elseif policy == "allocation_destination" then
            include = coder._adapter_operation_allocates(action)
                and action.destination_gc
                and not action.destination_open
            typ = action.target_type
        elseif policy == "result_source" then
            include = action.operation ~= nil
                and action.source_gc
                and not action.source_open
            typ = action.source_type
        else
            error(use .. " has unknown fixed-root policy " .. tostring(policy))
        end
        if include then
            expected[#expected + 1] = {
                action = action.id,
                type = typ,
                storage = "lua_stack_slot",
                retain_until = retain_until,
            }
        end
    end
    assert(coder._interface_frozen_value_equal(roots, expected),
        use .. " does not match its action inventory")
end

function coder._validate_interface_adapter_range(
        range, id, phase, side, element_type, lifetime, traced, use)
    local present = element_type ~= nil
    local gc_bearing = present
        and coder._interface_adapter_is_gc(element_type) or false
    traced = gc_bearing and traced == true
    local expected = {
        kind = "open_root_range",
        id = id,
        phase = phase,
        side = side,
        present = present,
        element_type = element_type or nil,
        gc_bearing = gc_bearing,
        traced = traced,
        storage = traced and "parallel_lua_stack_range" or nil,
        dynamic_start = present and "run_start" or nil,
        dynamic_count = present and "run_count" or nil,
        retain_until = lifetime,
        raw_storage_is_root = false,
    }
    coder._interface_closed_record(range, {
        kind = true, id = true, phase = true, side = true,
        present = true, element_type = true,
        gc_bearing = true, traced = true, storage = true,
        dynamic_start = true, dynamic_count = true,
        retain_until = true, raw_storage_is_root = true,
    }, use)
    assert(coder._interface_frozen_value_equal(range, expected),
        use .. " is not canonical")
end

function coder._validate_adapter_rooting(
        adapter, source, target, lifetimes, construction, use)
    local rooting = adapter.rooting
    local allowed = {
        raw_descriptors_are_roots = true,
        raw_buffers_are_roots = true,
        fixed = true, ranges = true,
    }
    if construction then allowed.construction = true end
    coder._interface_closed_record(rooting, allowed, use .. " rooting")
    assert(rooting.raw_descriptors_are_roots == false
           and rooting.raw_buffers_are_roots == false,
        use .. " treats raw adapter storage as a root")

    if construction then
        coder._interface_closed_record(rooting.construction, {
            result = true,
        }, use .. " construction roots")
        local expected = {
            type = target,
            gc_bearing = true,
            traced = true,
            storage = "conditional_lua_stack_slot",
            condition = "eligible_exact_titan_clone",
            retain_until = lifetimes.result_destination,
        }
        coder._interface_closed_record(rooting.construction.result, {
            type = true, gc_bearing = true, traced = true,
            storage = true, condition = true, retain_until = true,
        }, use .. " construction result root")
        assert(coder._interface_frozen_value_equal(
                rooting.construction.result, expected),
            use .. " has a mismatched construction result root")
    end

    coder._interface_closed_record(rooting.fixed, {
        argument_source = true,
        argument_destination = true,
        result_source = true,
        result_destination = true,
    }, use .. " fixed roots")
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.argument_source, adapter.arguments,
        "none", use .. " argument source roots",
        lifetimes.argument_source)
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.argument_destination, adapter.arguments,
        "allocation_destination", use .. " argument destination roots",
        lifetimes.argument_destination)
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.result_source, adapter.results,
        "result_source", use .. " result source roots",
        lifetimes.result_source)
    coder._validate_interface_adapter_fixed_roots(
        rooting.fixed.result_destination, adapter.results,
        "allocation_destination", use .. " result destination roots",
        lifetimes.result_destination)

    coder._interface_closed_record(rooting.ranges, {
        argument_source = true,
        argument_destination = true,
        result_source = true,
        result_destination = true,
    }, use .. " root ranges")
    coder._validate_interface_adapter_range(
        rooting.ranges.argument_source,
        "argument_source", "argument", "source",
        target.varargtype, lifetimes.argument_source,
        false, use .. " argument source range")
    coder._validate_interface_adapter_range(
        rooting.ranges.argument_destination,
        "argument_destination", "argument", "destination",
        source.varargtype, lifetimes.argument_destination,
        coder._adapter_has_open_allocating_destination(adapter.arguments),
        use .. " argument destination range")
    coder._validate_interface_adapter_range(
        rooting.ranges.result_source,
        "result_source", "result", "source",
        source.flexrettype, lifetimes.result_source,
        coder._adapter_has_open_source(adapter.results),
        use .. " result source range")
    coder._validate_interface_adapter_range(
        rooting.ranges.result_destination,
        "result_destination", "result", "destination",
        target.flexrettype, lifetimes.result_destination,
        coder._adapter_has_open_allocating_destination(adapter.results),
        use .. " result destination range")
end

function coder._validate_callable_adapter_rooting(adapter, use)
    coder._validate_adapter_rooting(
        adapter, adapter.source, adapter.target, {
            argument_source = "all_arguments_converted",
            argument_destination = "source_native_call_returns",
            result_source = "all_results_converted",
            result_destination = "target_caller_handoff",
        }, true, use)
end

function coder._validate_interface_adapter_rooting(adapter, use)
    coder._validate_adapter_rooting(
        adapter, adapter.concrete_signature, adapter.interface_signature, {
            argument_source = "all_arguments_converted",
            argument_destination = "concrete_call_returns",
            result_source = "all_results_converted",
            result_destination = "interface_caller_handoff",
        }, false, use)
end

function coder._validate_interface_adapter_rebases(adapter, use)
    coder._interface_dense_list(
        adapter.rebase_points, use .. " rebase points")
    local expected = {}
    for _, action in ipairs(adapter.arguments) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    expected[#expected + 1] = {
        kind = "after_native_call",
        method = adapter.concrete_method,
        reason = "concrete_call_may_relocate_stack",
    }
    for _, action in ipairs(adapter.results) do
        if action.rebase_after then
            expected[#expected + 1] = {
                kind = "after_action",
                action = action.id,
                reason = coder._callable_action_rebase_reason(action),
            }
        end
    end
    for index, point in ipairs(adapter.rebase_points) do
        local wanted = expected[index]
        assert(wanted, use .. " has an extra rebase point")
        coder._interface_closed_record(point,
            point.kind == "after_action"
                and { kind = true, action = true, reason = true }
                or { kind = true, method = true, reason = true },
            use .. " rebase point " .. tostring(index))
        assert(coder._interface_frozen_value_equal(point, wanted),
            use .. " has a mismatched rebase point "
                .. tostring(index))
    end
    assert(#adapter.rebase_points == #expected,
        use .. " is missing a rebase point")
end

function coder._validate_interface_adapter(
        adapter, concrete, interface, mapping, use)
    coder._interface_closed_record(adapter, {
        kind = true, slot = true, slot_kind = true,
        name = true, symbol_key = true, trace_name = true,
        concrete_owner = true, concrete_owner_module = true,
        concrete_method = true, concrete_signature = true,
        interface = true, interface_method = true,
        native_signature = true, interface_signature = true,
        hidden_operands = true,
        arguments = true, results = true, callable = true,
        callable_adapter = true, relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true, rooting = true,
        rebase_points = true,
    }, use)
    local owner_module = assert(
        concrete.name:match("^(.*)%.[^.]+$"),
        use .. " concrete owner is not module-qualified")
    assert(adapter.kind == "interface_method_adapter"
           and adapter.slot == mapping.index
           and adapter.slot_kind == "adapter"
           and adapter.name == mapping.name
           and adapter.symbol_key == string.format(
               "%s->%s#%d:%s", concrete.name, interface.name,
               mapping.index, mapping.name)
           and adapter.trace_name == string.format(
               "%s:%s [adapter for %s:%s]",
               interface.name, mapping.name,
               concrete.name, mapping.name)
           and adapter.concrete_owner == concrete
           and adapter.concrete_owner_module == owner_module
           and adapter.concrete_method == mapping.concrete
           and adapter.concrete_signature == mapping.source
           and adapter.interface == interface
           and adapter.interface_method == mapping.required
           and adapter.native_signature == mapping.required
           and adapter.interface_signature == mapping.target
           and adapter.arguments == adapter.callable.arguments
           and adapter.results == adapter.callable.results
           and adapter.callable_adapter
           and adapter.callable == adapter.callable_adapter.callable
           and adapter.callable_adapter
                == mapping.adjustment._callable_adapter
           and adapter.relation_free == true
           and adapter.no_nested_interface_conversions == true
           and adapter.uses_base_off == true,
        use .. " has mismatched adapter identity/signatures")

    coder._interface_closed_record(adapter.hidden_operands, {
        concrete_owner_module = true,
        closure = true, self = true,
    }, use .. " hidden operands")
    local module_operand =
        adapter.hidden_operands.concrete_owner_module
    coder._interface_closed_record(module_operand, {
        parameter = true, provenance = true,
        owner = true, module = true,
    }, use .. " concrete module operand")
    assert(module_operand.parameter == "_mod"
           and module_operand.provenance
               == "adapter_owner_module"
           and module_operand.owner == concrete
           and module_operand.module == owner_module,
        use .. " changes concrete-owner module provenance")
    local closure_operand = adapter.hidden_operands.closure
    coder._interface_closed_record(closure_operand, {
        parameter = true, adapter_value = true,
        concrete_call_value = true,
    }, use .. " closure operand")
    assert(closure_operand.parameter == "_fn"
           and closure_operand.adapter_value == "NULL"
           and closure_operand.concrete_call_value == "NULL",
        use .. " does not freeze NULL payload closures")
    local self_operand = adapter.hidden_operands.self
    coder._interface_closed_record(self_operand, {
        provenance = true, type = true,
        forwards_unchanged = true,
    }, use .. " self operand")
    assert(self_operand.provenance
               == "interface_wrapper_uservalue_1"
           and self_operand.type
           and types.equals(
               self_operand.type, types.Nominal(concrete.name))
           and self_operand.forwards_unchanged == true,
        use .. " changes concrete self provenance")

    coder._validate_callable_adapter_plan(
        adapter.callable_adapter, mapping.source, mapping.target,
        use .. " shared callable adapter", {})
    coder._validate_interface_callable_actions(
        adapter.callable, mapping.source, mapping.target,
        use .. " callable", {})
    coder._validate_interface_adapter_rooting(adapter, use)
    coder._validate_interface_adapter_rebases(adapter, use)
    return adapter
end

function coder._interface_adapter_signature(name, method, is_pointer)
    assert(method._tag == "Type.Method")
    local params = {
        "lua_State *L",
        "Udata *_mod",
        "CClosure *_fn",
        "Udata *_self",
    }
    for index, typ in ipairs(method.params) do
        params[#params + 1] =
            cvardecl(nil, typ, "_ia_param_" .. tostring(index))
    end
    if method.varargtype then
        params[#params + 1] =
            varg_struct_name(method.varargtype) .. " *_varargs"
        params[#params + 1] = "int _start"
    end
    for index = 2, #method.rettypes do
        params[#params + 1] = cpointertype(method.rettypes[index])
            .. " _ia_out_" .. tostring(index)
    end
    if method.flexrettype then
        params[#params + 1] =
            varg_struct_name(method.flexrettype) .. " *_flexout"
        params[#params + 1] = "int _flexwant"
    end
    return cfunctiondecl(
        method.rettypes[1], name,
        table.concat(params, ", "), is_pointer)
end

function coder._callable_adapter_signature(name, typ, is_pointer)
    assert(typ._tag == "Type.Function")
    local params = {
        "lua_State *L",
        "Udata *_mod",
        "CClosure *_fn",
    }
    for index, param in ipairs(typ.params) do
        params[#params + 1] =
            cvardecl(nil, param, "_ia_param_" .. tostring(index))
    end
    if typ.varargtype then
        params[#params + 1] =
            varg_struct_name(typ.varargtype) .. " *_varargs"
        params[#params + 1] = "int _start"
    end
    for index = 2, #typ.rettypes do
        params[#params + 1] = cpointertype(typ.rettypes[index])
            .. " _ia_out_" .. tostring(index)
    end
    if typ.flexrettype then
        params[#params + 1] =
            varg_struct_name(typ.flexrettype) .. " *_flexout"
        params[#params + 1] = "int _flexwant"
    end
    return cfunctiondecl(
        typ.rettypes[1], name,
        table.concat(params, ", "), is_pointer)
end

function coder._adapter_source_signature(adapter)
    if adapter.kind == "callable_adapter_plan" then
        return adapter.source
    end
    assert(adapter.kind == "interface_method_adapter")
    return adapter.concrete_signature
end

function coder._adapter_target_signature(adapter)
    if adapter.kind == "callable_adapter_plan" then
        return adapter.target
    end
    assert(adapter.kind == "interface_method_adapter")
    return adapter.interface_signature
end

function coder._adapter_error_kind(adapter)
    return adapter.kind == "callable_adapter_plan"
        and "callable adapter" or "Interface adapter"
end



function coder._interface_adapter_allocate_roots(ctx, adapter)
    -- Keep this in lockstep with titan-runtime/titan.h's TITAN_VARARG_MAX.
    -- Existing callable lowering uses the same 200-element ABI bound. The
    -- emitted adapter checks every dynamic count before indexing either its C
    -- buffer or the parallel traced range.
    local open_cap = 200
    local roots = {
        argument_source = {},
        argument_destination = {},
        result_source = {},
        result_destination = {},
        ranges = {},
    }
    local frame_base = ctx.depth
    local frame_end = frame_base
    for _, phase in ipairs({ "argument", "result" }) do
        -- Fresh argument-destination allocation roots die when the concrete
        -- call returns. Native result roots are born only after that return, so
        -- both phases safely reuse one physical frame region while retaining
        -- distinct frozen logical inventories.
        ctx.depth = frame_base
        local names = {
            phase .. "_source",
            phase .. "_destination",
        }
        for _, name in ipairs(names) do
            local list = adapter.rooting.fixed[name]
            for _, root in ipairs(list) do
                roots[name][root.action] = reserveslot(ctx)
            end
        end
        for _, name in ipairs(names) do
            local range = adapter.rooting.ranges[name]
            if range.traced then
                roots.ranges[name] = ctx.depth
                for _ = 1, open_cap do reserveslot(ctx) end
            end
        end
        if ctx.depth > frame_end then frame_end = ctx.depth end
    end
    ctx.depth = frame_end
    return roots
end

function coder._interface_adapter_anchor(
        typ, depth, value)
    if depth == nil then return "" end
    return setslot(typ, slotat(depth), value)
end

function coder._interface_adapter_anchor_range(
        typ, depth, count, value)
    if depth == nil then return "" end
    return render([[
        for (int _ia_root_i = 0;
             _ia_root_i < $COUNT; _ia_root_i++) {
            $STORE
        }
    ]], {
        COUNT = count,
        STORE = setslot(typ,
            "s2v(" .. stackslotat(depth) .. " + _ia_root_i)",
            value),
    })
end

function coder._interface_adapter_nil_fill(typ, destination)
    typ = types.normalize(typ)
    assert(typ, "Interface adapter nil-fill target is unnormalizable")
    if coder._is_native_option(typ) then
        return coder._option_nil(typ, destination)
    elseif typ._tag == "Type.Value"
       or typ._tag == "Type.Option"
       or types.is_c_tvalue(typ) then
        return "setnilvalue(&" .. destination .. ");"
    elseif typ._tag == "Type.Nil" then
        return destination .. " = 0;"
    elseif typ._tag == "Type.CPointer" then
        return destination .. " = NULL;"
    end
    error("Interface adapter cannot nil-fill "
        .. types.tostring(typ))
end

function coder._emit_interface_adapter_operation(
        ctx, operation, source, destination, loc, use, result_root)
    local code
    if operation.kind == "identity"
       or (operation.kind == "gradual_guard"
           and operation.timing == "delayed_observation") then
        code = destination .. " = " .. source .. ";"
    elseif operation.kind == "callable_view" then
        local wrapper_stats, wrapper_value =
            coder._emit_callable_adapter_value(
                ctx, operation.adapter, source, loc, use,
                assert(result_root,
                    use .. " lacks its allocating-operation root"))
        code = wrapper_stats .. "\n"
            .. destination .. " = " .. wrapper_value .. ";"
    elseif operation.kind == "gradual_inject" then
        code = setboxed(
            ctx, operation.source, "&" .. destination, source)
    elseif operation.kind == "gradual_guard" then
        code = coder._strictcheckandget(
            ctx, operation.guard, operation.target,
            destination, "&" .. source, loc, use, true)
    else
        error(use .. " has unsupported operation "
            .. tostring(operation.kind))
    end
    if operation.may_relocate then
        code = code
            .. "\n_base = restorestack(L, _base_off);"
    end
    return code
end

function coder._emit_interface_adapter_argument_sources(
        ctx, adapter, roots, loc)
    local code = {}
    local interface = coder._adapter_target_signature(adapter)
    if interface.varargtype then
        code[#code + 1] = render([[
            if (TITAN_UNLIKELY(
                    _varargs == NULL
                    || _start < 0
                    || _start > (int)_varargs->n_args
                    || (int)_varargs->n_args > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "malformed Interface adapter variadic input for %s",
                    $TRACE);
            }
            int _ia_interface_tail_count =
                (int)_varargs->n_args - _start;
            (void)_ia_interface_tail_count;
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end

    -- Native fixed arguments and open runs remain C inputs, not tracing-stack
    -- values. The canonical inventory therefore emits no source anchors.
    for _, action in ipairs(adapter.arguments) do
        local depth = roots.argument_source[action.id]
        if depth ~= nil then
            local index = action.expected_index
            assert(index and action.source_kind == "interface_fixed",
                "fixed Interface argument root has no fixed source")
            code[#code + 1] =
                coder._interface_adapter_anchor(
                    action.source_type, depth,
                    "_ia_param_" .. tostring(index))
        end
    end
    if roots.ranges.argument_source ~= nil then
        code[#code + 1] =
            coder._interface_adapter_anchor_range(
                interface.varargtype,
                roots.ranges.argument_source,
                "_ia_interface_tail_count",
                "_varargs->args[_start + _ia_root_i]")
    end
    return table.concat(code, "\n")
end

function coder._emit_interface_adapter_arguments(
        ctx, adapter, roots, loc)
    local code = {}
    local concrete = coder._adapter_source_signature(adapter)
    if concrete.varargtype then
        code[#code + 1] = render([[
            $ELEM _ia_concrete_vargs[TITAN_VARARG_MAX] = {0};
            int _ia_concrete_vcount = 0;
        ]], {
            ELEM = ctype(concrete.varargtype),
        })
    end
    for index, typ in ipairs(concrete.params) do
        code[#code + 1] = render("$DECL = $INIT;", {
            DECL = cvardecl(
                ctx, typ, "_ia_concrete_arg_" .. tostring(index)),
            INIT = initval(typ),
        })
    end

    local function root_fixed(action)
        local depth = roots.argument_destination[action.id]
        return depth ~= nil and slotat(depth) or nil
    end
    local function root_tail()
        local depth = roots.ranges.argument_destination
        return depth ~= nil and ("s2v(" .. stackslotat(depth)
            .. " + _ia_concrete_vcount)") or nil
    end
    local function append_guard()
        return render([[
            if (TITAN_UNLIKELY(
                    _ia_concrete_vcount >= TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "too many variadic arguments in Interface adapter %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end

    for _, action in ipairs(adapter.arguments) do
        local use = adapter.trace_name
            .. " " .. action.id
        if action.kind == "argument" then
            code[#code + 1] =
                coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_ia_param_" .. tostring(action.expected_index),
                    "_ia_concrete_arg_" .. tostring(action.actual_index),
                    loc, use, root_fixed(action))
        elseif action.kind == "tail_or_nil_to_argument" then
            code[#code + 1] = render([[
                if (_ia_interface_tail_count >= $OFFSET) {
                    $PRESENT
                } else {
                    $MISSING
                }
            ]], {
                OFFSET =
                    c_integer_literal(action.expected_tail_offset),
                PRESENT = coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_varargs->args[_start + "
                        .. c_integer_literal(
                            action.expected_tail_offset - 1)
                        .. "]",
                    "_ia_concrete_arg_"
                        .. tostring(action.actual_index),
                    loc, use, root_fixed(action)),
                MISSING = coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_concrete_arg_"
                        .. tostring(action.actual_index)),
            })
        elseif action.kind == "nil_fill" then
            code[#code + 1] =
                coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_concrete_arg_"
                        .. tostring(action.actual_index))
        elseif action.kind == "argument_to_tail" then
            code[#code + 1] = append_guard()
            code[#code + 1] =
                coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_ia_param_" .. tostring(action.expected_index),
                    "_ia_concrete_vargs[_ia_concrete_vcount]",
                    loc, use, root_tail())
            code[#code + 1] = "_ia_concrete_vcount++;"
        elseif action.kind == "tail_to_tail" then
            code[#code + 1] = render([[
                for (int _ia_tail_i = $CONSUMED;
                     _ia_tail_i < _ia_interface_tail_count;
                     _ia_tail_i++) {
                    $GUARD
                    $CONVERT
                    _ia_concrete_vcount++;
                }
            ]], {
                CONSUMED = c_integer_literal(
                    action.expected_tail_consumed),
                GUARD = append_guard(),
                CONVERT =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_varargs->args[_start + _ia_tail_i]",
                        "_ia_concrete_vargs[_ia_concrete_vcount]",
                        loc, use, root_tail()),
            })
        elseif action.kind == "empty_tail"
               or action.kind == "ignore_argument"
               or action.kind == "ignore_tail" then
            -- Parameters have already been evaluated by the caller. Ignored
            -- native C values/runs require neither conversion nor a stack copy.
        else
            error(use .. " has unsupported argument action "
                .. tostring(action.kind))
        end
    end
    if concrete.varargtype then
        code[#code + 1] = render([[
            $STRUCT _ia_concrete_vdesc = {
                (lu_byte)_ia_concrete_vcount,
                _ia_concrete_vargs
            };
        ]], {
            STRUCT = varg_struct_name(concrete.varargtype),
        })
    end
    return table.concat(code, "\n")
end

function coder._emit_interface_adapter_call(
        ctx, adapter, roots)
    local code = {}
    local concrete = coder._adapter_source_signature(adapter)
    local interface = coder._adapter_target_signature(adapter)
    for index, typ in ipairs(concrete.rettypes) do
        code[#code + 1] = render("$DECL = $INIT;", {
            DECL = cvardecl(
                ctx, typ,
                "_ia_concrete_result_" .. tostring(index)),
            INIT = initval(typ),
        })
    end
    if concrete.flexrettype then
        local demand = adapter.kind == "callable_adapter_plan"
            and adapter.flexible_result_demand
            or adapter.callable_adapter.flexible_result_demand
        local consumed = demand.fixed_source_flex_consumed
        local fixed_surplus = demand.fixed_source_surplus
        assert(demand.within_abi_cap
               and demand.abi_cap == 200,
            coder._adapter_error_kind(adapter)
                .. " fixed flex demand exceeds ABI cap")
        code[#code + 1] = render([[
            $ELEM _ia_concrete_fargs[TITAN_VARARG_MAX] = {0};
            $STRUCT _ia_concrete_fdesc = {
                0, _ia_concrete_fargs
            };
            int _ia_concrete_fwant = $DEMAND;
        ]], {
            ELEM = ctype(concrete.flexrettype),
            STRUCT = varg_struct_name(concrete.flexrettype),
            DEMAND = interface.flexrettype and render([[
                (_flexwant == LUA_MULTRET)
                    ? LUA_MULTRET
                    : ((_flexwant <= $SURPLUS)
                        ? $PREFIX
                        : (((_flexwant - $SURPLUS) >= $REMAINING)
                            ? TITAN_VARARG_MAX
                            : _flexwant - $SURPLUS + $PREFIX))
            ]], {
                REMAINING = c_integer_literal(
                    demand.remaining_source_capacity),
                PREFIX = c_integer_literal(consumed),
                SURPLUS = c_integer_literal(fixed_surplus),
            }) or c_integer_literal(consumed),
        })
    end

    local args
    local invocation_name
    if adapter.kind == "callable_adapter_plan" then
        code[#code + 1] = render([[
            if (TITAN_UNLIKELY(_fn == NULL
                    || _fn->nupvalues < 6
                    || !ttisCclosure(
                        &_fn->upvalue[_fn->nupvalues - 2]))) {
                luaL_error(L, "invalid callable adapter wrapper for %s", $TRACE);
            }
            CClosure *_ia_source = clCvalue(
                &_fn->upvalue[_fn->nupvalues - 2]);
            if (TITAN_UNLIKELY(_ia_source->nupvalues < 5
                    || !ttisfulluserdata(&_ia_source->upvalue[0])
                    || !ttislightuserdata(&_ia_source->upvalue[1])
                    || !ttislightuserdata(&_ia_source->upvalue[2])
                    || pvalue(&_ia_source->upvalue[1]) != $SOURCE_TAG)) {
                luaL_error(L, "invalid callable adapter source for %s", $TRACE);
            }
            Udata *_ia_source_mod = uvalue(&_ia_source->upvalue[0]);
            typedef $SOURCE_FP_DECL;
            $SOURCE_FP_TYPE _ia_source_fp = titan_cast_func(
                $SOURCE_FP_TYPE, pvalue(&_ia_source->upvalue[2]));
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
            SOURCE_TAG = function_type_tag(ctx.tlcontext, concrete),
            SOURCE_FP_DECL = function_sig(
                "_ia_source_fp_type", concrete, true),
            SOURCE_FP_TYPE = "_ia_source_fp_type",
        })
        args = { "L", "_ia_source_mod", "_ia_source" }
        invocation_name = "_ia_source_fp"
    else
        local concrete_mod = coder._interface_owner_module_expr(
            ctx, adapter.concrete_owner)
        args = { "L", concrete_mod, "NULL", "_self" }
        invocation_name = method_name(adapter.concrete_method)
        invocation_name = coder._external_reference(ctx,
            adapter.concrete_method.fqtn:match("^(.*)[.]"), invocation_name)
    end
    for index = 1, #concrete.params do
        args[#args + 1] =
            "_ia_concrete_arg_" .. tostring(index)
    end
    if concrete.varargtype then
        args[#args + 1] = "&_ia_concrete_vdesc"
        args[#args + 1] = "0"
    end
    for index = 2, #concrete.rettypes do
        args[#args + 1] =
            "&_ia_concrete_result_" .. tostring(index)
    end
    if concrete.flexrettype then
        args[#args + 1] = "&_ia_concrete_fdesc"
        args[#args + 1] = "_ia_concrete_fwant"
    end
    local invocation = invocation_name
        .. "(" .. table.concat(args, ", ") .. ")"
    if #concrete.rettypes > 0 then
        invocation = "_ia_concrete_result_1 = "
            .. invocation .. ";"
    else
        invocation = invocation .. ";"
    end
    if adapter.kind == "callable_adapter_plan" then
        code[#code + 1] = emitline({ loc = adapter.location })
    end
    code[#code + 1] = invocation
    if adapter.kind == "callable_adapter_plan" then
        code[#code + 1] = emitline({ loc = adapter.location })
    end
    code[#code + 1] =
        "_base = restorestack(L, _base_off);"
    for index = 1, #concrete.rettypes do
        code[#code + 1] =
            "(void)_ia_concrete_result_" .. tostring(index) .. ";"
    end

    if concrete.flexrettype then
        code[#code + 1] = render([[
            if (TITAN_UNLIKELY(
                    (int)_ia_concrete_fdesc.n_args
                        > TITAN_VARARG_MAX
                    || (_ia_concrete_fwant != LUA_MULTRET
                        && (int)_ia_concrete_fdesc.n_args
                            > _ia_concrete_fwant))) {
                luaL_error(L,
                    "malformed flexible result run in adapter %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end

    for _, action in ipairs(adapter.results) do
        local depth = roots.result_source[action.id]
        if depth ~= nil then
            assert(action.source_kind == "concrete_fixed"
                   and action.actual_index,
                "fixed Interface result root has no fixed source")
            code[#code + 1] =
                coder._interface_adapter_anchor(
                    action.source_type, depth,
                    "_ia_concrete_result_"
                        .. tostring(action.actual_index))
        end
    end
    if roots.ranges.result_source ~= nil then
        code[#code + 1] =
            coder._interface_adapter_anchor_range(
                concrete.flexrettype,
                roots.ranges.result_source,
                "(int)_ia_concrete_fdesc.n_args",
                "_ia_concrete_fargs[_ia_root_i]")
    end
    return table.concat(code, "\n")
end

function coder._emit_interface_adapter_results(
        ctx, adapter, roots, loc)
    local code = {}
    local interface = coder._adapter_target_signature(adapter)
    for index, typ in ipairs(interface.rettypes) do
        code[#code + 1] = render("$DECL = $INIT;", {
            DECL = cvardecl(
                ctx, typ,
                "_ia_interface_result_" .. tostring(index)),
            INIT = initval(typ),
        })
    end
    if interface.flexrettype then
        code[#code + 1] = [[
            int _ia_interface_fcount = 0;
            _flexout->n_args = 0;
        ]]
    end

    local function root_fixed(action)
        local depth = roots.result_destination[action.id]
        return depth ~= nil and slotat(depth) or nil
    end
    local function root_flex()
        local depth = roots.ranges.result_destination
        return depth ~= nil and ("s2v(" .. stackslotat(depth)
            .. " + _ia_interface_fcount)") or nil
    end
    local function append_guard()
        return render([[
            if (TITAN_UNLIKELY(
                    _ia_interface_fcount >= TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "too many flexible results in Interface adapter %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end
    local function wants_more()
        return "(_flexwant == LUA_MULTRET"
            .. " || _ia_interface_fcount < _flexwant)"
    end

    for _, action in ipairs(adapter.results) do
        local use = adapter.trace_name
            .. " " .. action.id
        if action.kind == "result" then
            code[#code + 1] =
                coder._emit_interface_adapter_operation(
                    ctx, action.operation,
                    "_ia_concrete_result_"
                        .. tostring(action.actual_index),
                    "_ia_interface_result_"
                        .. tostring(action.expected_index),
                    loc, use, root_fixed(action))
        elseif action.kind == "nil_fill_result" then
            code[#code + 1] =
                coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_interface_result_"
                        .. tostring(action.expected_index))
        elseif action.kind == "flex_to_optional_result"
               or action.kind == "flex_to_result" then
            local present
            if action.wrap_present then
                local base_name = "_ia_present_"
                    .. tostring(action.order)
                present = render([[
                    $DECL = $INIT;
                    $CONVERT
                    $WRAP
                ]], {
                    DECL = cvardecl(
                        ctx, action.operation_target_type, base_name),
                    INIT = initval(action.operation_target_type),
                    CONVERT =
                        coder._emit_interface_adapter_operation(
                            ctx, action.operation,
                            "_ia_concrete_fargs["
                                .. c_integer_literal(
                                    action.actual_flex_offset - 1)
                                .. "]",
                            base_name, loc, use, root_fixed(action)),
                    WRAP = setslot(
                        action.operation_target_type,
                        "&_ia_interface_result_"
                            .. tostring(action.expected_index),
                        base_name),
                })
            else
                present =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_ia_concrete_fargs["
                            .. c_integer_literal(
                                action.actual_flex_offset - 1)
                            .. "]",
                        "_ia_interface_result_"
                            .. tostring(action.expected_index),
                        loc, use, root_fixed(action))
            end
            local missing
            if action.missing_arm.kind == "nil_fill" then
                missing = coder._interface_adapter_nil_fill(
                    action.target_type,
                    "_ia_interface_result_"
                        .. tostring(action.expected_index))
            else
                missing = render([[
                    luaL_error(L,
                        "adapter %s expected result %d",
                        $TRACE, $INDEX);
                ]], {
                    TRACE = c_string_literal(adapter.trace_name),
                    INDEX = c_integer_literal(action.expected_index),
                })
            end
            code[#code + 1] = render([[
                if ((int)_ia_concrete_fdesc.n_args >= $OFFSET) {
                    $PRESENT
                } else {
                    $MISSING
                }
            ]], {
                OFFSET =
                    c_integer_literal(action.actual_flex_offset),
                PRESENT = present,
                MISSING = missing,
            })
        elseif action.kind == "result_to_flex" then
            code[#code + 1] = render([[
                if ($WANTS) {
                    $GUARD
                    $CONVERT
                    _ia_interface_fcount++;
                }
            ]], {
                WANTS = wants_more(),
                GUARD = append_guard(),
                CONVERT =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_ia_concrete_result_"
                            .. tostring(action.actual_index),
                        "_flexout->args[_ia_interface_fcount]",
                        loc, use, root_flex()),
            })
        elseif action.kind == "flex_to_flex" then
            code[#code + 1] = render([[
                for (int _ia_flex_i = $CONSUMED;
                     _ia_flex_i < (int)_ia_concrete_fdesc.n_args
                        && $WANTS;
                     _ia_flex_i++) {
                    $GUARD
                    $CONVERT
                    _ia_interface_fcount++;
                }
            ]], {
                CONSUMED = c_integer_literal(
                    action.actual_flex_consumed),
                WANTS = wants_more(),
                GUARD = append_guard(),
                CONVERT =
                    coder._emit_interface_adapter_operation(
                        ctx, action.operation,
                        "_ia_concrete_fargs[_ia_flex_i]",
                        "_flexout->args[_ia_interface_fcount]",
                        loc, use, root_flex()),
            })
        elseif action.kind == "hide_result"
               or action.kind == "hide_flex"
               or action.kind == "end_flex" then
            -- Concrete results were evaluated by the call, but these actions
            -- do not make them live at the target boundary. They publish no
            -- source or destination root and perform no later allocating work.
        else
            error(use .. " has unsupported result action "
                .. tostring(action.kind))
        end
    end
    if interface.flexrettype then
        code[#code + 1] =
            "_flexout->n_args = (lu_byte)_ia_interface_fcount;"
    end
    return table.concat(code, "\n")
end

-- Implementation notes: doc/implementation/interfaces.md#native-entry-abi-and-adjustment-entries
function coder._emit_interface_adapter(
        tlcontext, pair, index, mapping)
    local adapter = assert(mapping.interface_adapter)
    local name = assert(pair.adapter_ids[index])
    local ctx = newcontext(tlcontext)
    local roots =
        coder._interface_adapter_allocate_roots(ctx, adapter)
    local loc = {
        -- Native traceback filtering recognizes generated Titan frames by a
        -- `.titan` line-table source. The separately registered symbol name is
        -- the stable logical adapter trace shown to the user.
        filename = adapter.trace_name .. ".titan",
        line = 1,
        col = 1,
    }
    local argument_sources =
        coder._emit_interface_adapter_argument_sources(
            ctx, adapter, roots, loc)
    local flex_validation = ""
    if coder._adapter_target_signature(adapter).flexrettype then
        flex_validation = render([[
            if (TITAN_UNLIKELY(
                    _flexout == NULL
                    || (_flexwant != LUA_MULTRET
                        && (_flexwant < 0
                            || _flexwant > TITAN_VARARG_MAX)))) {
                luaL_error(L,
                    "malformed Interface adapter flexible-result demand for %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end
    local arguments = coder._emit_interface_adapter_arguments(
        ctx, adapter, roots, loc)
    local call = coder._emit_interface_adapter_call(
        ctx, adapter, roots)
    local results = coder._emit_interface_adapter_results(
        ctx, adapter, roots, loc)
    local interface = coder._adapter_target_signature(adapter)
    local handoff = {}
    for index = 2, #interface.rettypes do
        handoff[#handoff + 1] = render([[
            *_ia_out_$INDEX = _ia_interface_result_$INDEX;
        ]], {
            INDEX = c_integer_literal(index),
        })
    end
    local finish
    if #interface.rettypes == 0 then
        finish = "L->top.p = _base;\nreturn;"
    else
        finish = [[
            L->top.p = _base;
            return _ia_interface_result_1;
        ]]
    end
    register_trace_name(tlcontext, name, adapter.trace_name)
    local signature =
        coder._interface_adapter_signature(
            name, adapter.native_signature, false)
    local root_preamble
    if ctx.nslots > 0 then
        root_preamble = render([[
            /* Rooted scratch occupies NSLOTS entries. */
            titan_ensure_stack(L, $NSLOTS);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for (StkId _ia_slot = L->top.p - 1;
                 _base <= _ia_slot; _ia_slot--) {
                setnilvalue2s(_ia_slot);
            }
            ptrdiff_t _base_off = savestack(L, _base);
        ]], {
            NSLOTS = c_integer_literal(ctx.nslots),
        })
    else
        root_preamble = [[
            StkId _base = L->top.p;
            ptrdiff_t _base_off = savestack(L, _base);
        ]]
    end
    local body = render([[
        static TITAN_NOINLINE $SIGNATURE {
            (void)_fn;
            $GC_POLL
            $ROOT_PREAMBLE
            $ARGUMENT_SOURCES
            $FLEX_VALIDATION
            $ARGUMENTS
            $CALL
            $RESULTS
            $HANDOFF
            $FINISH
        }
    ]], {
        SIGNATURE = signature,
        GC_POLL = coder._adapter_actions_allocate(adapter)
            and "luaC_checkGC(L);" or "",
        ROOT_PREAMBLE = root_preamble,
        ARGUMENT_SOURCES = argument_sources,
        FLEX_VALIDATION = flex_validation,
        ARGUMENTS = arguments,
        CALL = call,
        RESULTS = results,
        HANDOFF = table.concat(handoff, "\n"),
        FINISH = finish,
    })
    return "static TITAN_NOINLINE "
        .. coder._interface_adapter_signature(
            name, adapter.native_signature, false)
        .. ";", body
end

-- Encode a source identity injectively into a portable C identifier fragment.
-- Pair/adapter identities must not depend on AST discovery order, and the
-- ordinary source-name mangler is intentionally not injective (`.` and `-`
-- both become `_`). Two hex digits per source byte keep this private symbol
-- namespace deterministic without relying on a collision-prone hash.
function coder._interface_symbol_fragment(name)
    assert(type(name) == "string" and name ~= "",
        "Interface symbol identity is not a nonempty string")
    local bytes = {}
    for i = 1, #name do
        bytes[i] = string.format("%02x", name:byte(i))
    end
    return table.concat(bytes)
end

-- Emit the common Interface wrapper body. uv[0]/uv[1] retain the emitting
-- module's `_mod` and the concrete value; uv[2+i] retains Interface field i's
-- immutable, target-typed snapshot. Static conversions and dynamic-discovery
-- witnesses differ only in how they prepare those snapshots, name the fresh
-- Udata, and address its traced result slot.
-- Implementation notes: doc/implementation/interfaces.md#wrapper-representation
function coder._render_interface_wrapper_allocation(args)
    local vtable_size = args.vtable
        and "sizeof(" .. args.vtable .. ")" or "0"
    local copy_vtable = args.vtable and render([[
        memcpy(getudatamem($WRAPPER), $VTABLE, sizeof($VTABLE));
    ]], {
        WRAPPER = assert(args.wrapper),
        VTABLE = args.vtable,
    }) or ""
    return render([[
        $SOURCE_STATS
        $WRAPPER_DECL
        {
            Table *_titan_interface_metatable = $INTERFACE_METATABLE;
            $FIELD_STATS
            $WRAPPER = luaS_newudata(
                L, $VTABLE_SIZE, $USERVALUE_COUNT);
            $AFTER_ALLOCATION
            setuvalue(L, $WRAPPER_SLOT, $WRAPPER);
            $WRAPPER->metatable = _titan_interface_metatable;
            setuvalue(L, &$WRAPPER->uv[0].uv, _mod);
            luaC_barrierback(L, obj2gco($WRAPPER),
                &$WRAPPER->uv[0].uv);
            setuvalue(L, &$WRAPPER->uv[1].uv, $CONCRETE_VALUE);
            luaC_barrierback(L, obj2gco($WRAPPER),
                &$WRAPPER->uv[1].uv);
            $FIELD_STORES
            $COPY_VTABLE
        }
    ]], {
        SOURCE_STATS = args.source_stats or "",
        WRAPPER_DECL = args.wrapper_decl or "",
        WRAPPER = assert(args.wrapper),
        WRAPPER_SLOT = assert(args.wrapper_slot),
        CONCRETE_VALUE = assert(args.concrete_value),
        INTERFACE_METATABLE = assert(args.interface_metatable),
        FIELD_STATS = args.field_stats or "",
        FIELD_STORES = args.field_stores or "",
        VTABLE_SIZE = vtable_size,
        USERVALUE_COUNT = c_integer_literal(
            2 + assert(args.field_count)),
        AFTER_ALLOCATION = args.after_allocation or "",
        COPY_VTABLE = copy_vtable,
    })
end

-- Consume the checker's complete field mappings in Interface declaration
-- order. Every target value is frozen before wrapper allocation, and any
-- freshly allocated nested Interface/callable view is published in a traced
-- temporary until the wrapper uservalue takes ownership.
local function concrete_field_for_mapping(concrete, mapping)
    -- Compiled Record metadata omits local fields but preserves every public
    -- field's absolute Udata slot. The visible list can therefore be sparse in
    -- physical-index space; never treat source_index as a Lua list position.
    for _, field in ipairs(concrete.fields or {}) do
        if field.index == mapping.source_index
           and field.name == mapping.name then
            return field
        end
    end
    return nil
end

function coder._code_interface_field_snapshots(
        ctx, pair, concrete_value, wrapper_value, loc)
    local stats, stores = {}, {}
    for index, mapping in ipairs(pair.fields) do
        local required = pair.interface.fields[index]
        local concrete = concrete_field_for_mapping(pair.concrete, mapping)
        assert(mapping.required == required
               and concrete
               and mapping.concrete == concrete
               and mapping.name == required.name
               and mapping.target_index == required.index
               and mapping.source_index == concrete.index
               and concrete.isconst == true
               and types.equals(mapping.source, concrete.type)
               and types.equals(mapping.target, required.type),
            "Interface field snapshot has a malformed mapping at slot "
                .. tostring(index - 1))
        coder._checked_adjustment_plan(
            mapping.adjustment, mapping.source, mapping.target,
            "Interface field snapshot adjustment")

        local plan = coder._nominal_plan(ctx, pair.concrete)
        local read_stats, source = coder._nominal_read(ctx, plan,
            assert(plan.by_index[concrete.index]), concrete.type, concrete_value)
        stats[#stats + 1] = read_stats
        local result_root
        if coder._adjustment_allocates_gc(mapping.adjustment) then
            result_root = newslot(ctx)
        end
        local conversion_stats, converted =
            coder._code_adjustment_value(
                ctx, mapping.adjustment, mapping.source, mapping.target,
                source, loc, nil, result_root)
        local frozen_stats, frozen = coder._freeze_code(
            ctx, mapping.target, conversion_stats, converted)
        stats[#stats + 1] = frozen_stats

        local destination = render("&$WRAPPER->uv[$INDEX].uv", {
            WRAPPER = wrapper_value,
            INDEX = c_integer_literal(2 + mapping.target_index),
        })
        stores[#stores + 1] = setslot(
            mapping.target, destination, frozen)
        if types.is_gc(mapping.target) then
            stores[#stores + 1] = render([[
                luaC_barrierback(L, obj2gco($WRAPPER),
                    $DESTINATION);
            ]], {
                WRAPPER = wrapper_value,
                DESTINATION = destination,
            })
        end
    end
    return table.concat(stats, "\n"), table.concat(stores, "\n")
end

-- Validate and inventory one concrete/Interface pair. Exact slots point
-- directly at the concrete method; adjusted slots carry one checker-frozen
-- adapter plan and receive a deterministic private adapter symbol.
-- Implementation notes: doc/implementation/interfaces.md#frozen-conversion-and-adapter-plans
function coder._interface_pair(ctx, conversion, loc)
    local use = "concrete-to-Interface conversion"
    assert(conversion and conversion.kind == "interface_conversion",
        use .. " lacks its checker annotation")
    local concrete = assert(conversion.concrete,
        use .. " lacks its concrete descriptor")
    local interface = assert(conversion.interface,
        use .. " lacks its Interface descriptor")
    assert(concrete._tag == "Type.Record" or concrete._tag == "Type.Union",
        use .. " has a non-concrete owner")
    assert(interface._tag == "Type.Interface"
           and types.validate_interface_descriptor(interface),
        use .. " has an invalid Interface descriptor")
    assert(conversion.concrete_type
           and conversion.concrete_type._tag == "Type.Nominal"
           and conversion.concrete_type.fqtn == concrete.name,
        use .. " has a mismatched concrete value type")
    assert(conversion.interface_type
           and conversion.interface_type._tag == "Type.Nominal"
           and conversion.interface_type.fqtn == interface.name,
        use .. " has a mismatched Interface value type")
    assert(type(conversion.methods) == "table"
           and #conversion.methods == #interface.methods,
        use .. " has a noncanonical ordered method mapping")
    assert(type(conversion.fields) == "table"
           and #conversion.fields == #interface.fields,
        use .. " has a noncanonical ordered field mapping")
    local tlcontext = ctx.tlcontext
    local key = concrete.name .. "\0" .. interface.name
    local prior = tlcontext.interface_pairs[key]
    local entry = prior
    if not entry then
        local concrete_fragment =
            coder._interface_symbol_fragment(concrete.name)
        local interface_fragment =
            coder._interface_symbol_fragment(interface.name)
        local pair_fragment =
            concrete_fragment
            .. "_to_"
            .. interface_fragment
        local concrete_metatable_slot =
            type2metatable(ctx, conversion.concrete_type)
        local interface_metatable_slot =
            type2metatable(ctx, conversion.interface_type)
        entry = {
            key = key,
            id = tlcontext.prefix .. "interface_pair_" .. pair_fragment,
            wrapper_id = coder._function_prefix(
                tlcontext.module, concrete_fragment)
                .. "_\\u2131_" .. interface_fragment
                .. "_\\u2131_wrapper",
            allocator_id = coder._function_prefix(
                tlcontext.module, concrete_fragment)
                .. "_\\u2131_" .. interface_fragment
                .. "_\\u2131_allocate",
            concrete = concrete,
            interface = interface,
            concrete_metatable_slot = concrete_metatable_slot,
            interface_metatable_slot = interface_metatable_slot,
            fields = conversion.fields,
            methods = conversion.methods,
            adapter_ids = {},
            loc = assert(loc, use .. " has no source location"),
        }
        tlcontext.interface_pairs[key] = entry
        table.insert(tlcontext.interface_pair_list, entry)
    else
        assert(entry.concrete == concrete
               and entry.interface == interface
               and entry.concrete_metatable_slot
                    == type2metatable(ctx, conversion.concrete_type)
               and entry.interface_metatable_slot
                    == type2metatable(ctx, conversion.interface_type)
               and #entry.fields == #conversion.fields
               and #entry.methods == #conversion.methods,
            use .. " disagrees with an existing pair obligation")
    end

    local all_exact = true
    for index, mapping in ipairs(conversion.fields) do
        local required = interface.fields[index]
        local field = concrete_field_for_mapping(concrete, mapping)
        assert(mapping.target_index == index - 1
               and mapping.name == required.name
               and mapping.required == required
               and mapping.concrete == field
               and field
               and field._tag == "Type.Field"
               and field.fqtn == concrete.name
               and field.isconst == true
               and types.equals(mapping.source, field.type)
               and types.equals(mapping.target, required.type),
            use .. " has a malformed field mapping at slot "
                .. tostring(index - 1))
        coder._checked_adjustment_plan(
            mapping.adjustment, mapping.source, mapping.target,
            use .. " field slot " .. tostring(index - 1))
        assert(mapping.exact == types.equals(
                mapping.source, mapping.target),
            use .. " has an inconsistent field exactness marker")
        all_exact = all_exact and mapping.exact
        if prior then
            local old = prior.fields[index]
            assert(old.concrete == mapping.concrete
                   and old.required == mapping.required
                   and old.exact == mapping.exact,
                use .. " disagrees with an existing field mapping at slot "
                    .. tostring(index - 1))
        end
    end
    for index, mapping in ipairs(conversion.methods) do
        local required = interface.methods[index]
        assert(mapping.index == index - 1
               and mapping.name == required.name
               and mapping.required == required
               and mapping.concrete
               and mapping.concrete._tag == "Type.Method"
               and mapping.concrete.fqtn == concrete.name,
            use .. " has a malformed mapping at slot "
                .. tostring(index - 1))
        assert(mapping.source
               and mapping.source._tag == "Type.Function"
               and mapping.target
               and mapping.target._tag == "Type.Function"
               and types.equals(
                   mapping.source,
                   types.method_function_type(mapping.concrete))
               and types.equals(
                   mapping.target,
                   types.method_function_type(required)),
            use .. " has mismatched projected signatures at slot "
                .. tostring(index - 1))
        assert(mapping.exact == types.equals(
                mapping.source, mapping.target),
            use .. " has an inconsistent exactness marker")
        all_exact = all_exact and mapping.exact
        if mapping.slot_kind == "exact" then
            assert(mapping.exact
                   and mapping.interface_adapter == nil,
                use .. " has a malformed exact mapping")
        else
            assert(mapping.slot_kind == "adapter"
                   and mapping.interface_adapter,
                use .. " has an adjusted mapping without a frozen adapter")
            entry.adapter_ids[index] =
                entry.id .. "_adapter_" .. tostring(index - 1)
            coder._validate_interface_adapter(
                mapping.interface_adapter,
                concrete, interface, mapping,
                use .. " slot " .. tostring(index - 1))
        end
        if prior then
            local old = prior.methods[index]
            assert(old.concrete == mapping.concrete
                   and old.required == mapping.required
                   and old.exact == mapping.exact,
                use .. " disagrees with an existing mapping at slot "
                    .. tostring(index - 1))
        end

        local method = mapping.concrete
        local module, record =
            assert(method.fqtn:match("^(.*)%.([^.]+)$"))
        if module ~= ctx.module then
            local symbol = method_name(method)
            ctx.functions[method.fqtn .. ":interface:"
                .. interface.name .. ":" .. method.name] = {
                module = module,
                record = record,
                name = method.name,
                type = method,
                mangled = symbol,
            }
        end
    end
    assert(conversion.exact == all_exact,
        use .. " has a mismatched pair exactness marker")
    return entry
end

-- Prepare the private Lua-stack witness advertised from the concrete
-- metatable. This is a growing inventory pass: lowering a field snapshot may
-- discover nested Interface pairs or callable adapters, all of which must be
-- known before deterministic file-scope emission begins.
function coder._prepare_interface_pair_wrapper(tlcontext, pair)
    if pair.wrapper_body then return end
    assert(not pair.preparing, "recursive Interface pair preparation")
    pair.preparing = true

    -- Preserve the established method-only witness exactly: it needs no
    -- snapshot conversion helper or private stack frame.
    if #pair.fields == 0 then
        local allocation = coder._render_interface_wrapper_allocation({
            wrapper_decl =
                "Udata *_titan_interface_wrapper = NULL;",
            wrapper = "_titan_interface_wrapper",
            wrapper_slot =
                "s2v(restorestack(L, _titan_interface_result))",
            concrete_value = "_titan_interface_concrete",
            interface_metatable = render(
                "hvalue(&_mod->uv[$SLOT].uv)", {
                    SLOT = c_integer_literal(
                        pair.interface_metatable_slot),
                }),
            field_count = 0,
            vtable = coder._module_native_ref(tlcontext, pair.id),
        })
        pair.wrapper_sig = render(
            "static int $NAME(lua_State *L);", {
                NAME = pair.wrapper_id,
            })
        pair.wrapper_body = render([[
            static int $NAME(lua_State *L) {
                StkId _titan_interface_func = L->ci->func.p;
                CClosure *_titan_interface_witness =
                    clCvalue(s2v(_titan_interface_func));
                Udata *_mod =
                    uvalue(&_titan_interface_witness->upvalue[0]);
                Udata *_titan_interface_concrete =
                    uvalue(s2v(_titan_interface_func + 1));
                ptrdiff_t _titan_interface_result =
                    savestack(L, _titan_interface_func + 1);
                $ALLOCATION
                return 1;
            }
        ]], {
            NAME = pair.wrapper_id,
            ALLOCATION = allocation,
        })
        pair.preparing = nil
        return
    end

    local ctx = newcontext(tlcontext)
    local wrapper = "_titan_interface_wrapper"
    local wrapper_root = newslot(ctx)
    local field_stats, field_stores =
        coder._code_interface_field_snapshots(
            ctx, pair, "_titan_interface_concrete", wrapper, pair.loc)
    local allocation = coder._render_interface_wrapper_allocation({
        wrapper_decl = "Udata *" .. wrapper .. " = NULL;",
        wrapper = wrapper,
        wrapper_slot = wrapper_root,
        concrete_value = "_titan_interface_concrete",
        interface_metatable = render("hvalue(&_mod->uv[$SLOT].uv)", {
            SLOT = c_integer_literal(pair.interface_metatable_slot),
        }),
        field_count = #pair.fields,
        field_stats = field_stats,
        field_stores = field_stores,
        after_allocation = "_base = restorestack(L, _base_off);",
        vtable = #pair.methods > 0
            and coder._module_native_ref(tlcontext, pair.id) or nil,
    })

    local reserve = ""
    if ctx.nslots > 0 then
        reserve = render([[
            titan_ensure_stack(L, $NSLOTS);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for (StkId _slot = L->top.p - 1;
                 _base <= _slot; _slot--) {
                setnilvalue2s(_slot);
            }
        ]], {
            NSLOTS = c_integer_literal(ctx.nslots),
        })
    else
        reserve = "StkId _base = L->top.p;"
    end
    pair.wrapper_sig = render([[
        static Udata *$ALLOCATOR(
            lua_State *L, Udata *_mod,
            Udata *_titan_interface_concrete);
        static int $WRAPPER(lua_State *L);
    ]], {
        ALLOCATOR = pair.allocator_id,
        WRAPPER = pair.wrapper_id,
    })
    pair.wrapper_body = render([[
        static Udata *$ALLOCATOR(
                lua_State *L, Udata *_mod,
                Udata *_titan_interface_concrete) {
            $RESERVE
            ptrdiff_t _base_off = savestack(L, _base);
            $ALLOCATION
            Udata *_titan_interface_result_value =
                _titan_interface_wrapper;
            L->top.p = restorestack(L, _base_off);
            return _titan_interface_result_value;
        }

        static int $WRAPPER(lua_State *L) {
            StkId _titan_interface_func = L->ci->func.p;
            CClosure *_titan_interface_witness =
                clCvalue(s2v(_titan_interface_func));
            Udata *_mod =
                uvalue(&_titan_interface_witness->upvalue[0]);
            Udata *_titan_interface_concrete =
                uvalue(s2v(_titan_interface_func + 1));
            ptrdiff_t _titan_interface_result =
                savestack(L, _titan_interface_func + 1);
            Udata *_titan_interface_wrapper = $ALLOCATOR(
                L, _mod, _titan_interface_concrete);
            setuvalue(L,
                s2v(restorestack(L, _titan_interface_result)),
                _titan_interface_wrapper);
            return 1;
        }
    ]], {
        ALLOCATOR = pair.allocator_id,
        WRAPPER = pair.wrapper_id,
        RESERVE = reserve,
        ALLOCATION = allocation,
    })
    pair.preparing = nil
end

function coder._emit_interface_pair_wrapper(pair)
    assert(pair.wrapper_sig and pair.wrapper_body
           and not pair.preparing,
        "Interface pair wrapper was not prepared before emission")
    return pair.wrapper_sig, pair.wrapper_body
end

-- Build a wrapper from an already authorized scalar conversion. The shared
-- pair allocator owns field conversion, rooting, barriers, and recursive pair
-- calls; the enclosing expression only freezes its concrete source and
-- publishes the returned value in its caller-owned traced result slot.
function coder._code_interface_wrapper(
        ctx, conversion, source_stats, source_exp, result_root, loc)
    local pair = coder._interface_pair(ctx, conversion, loc)
    local frozen_stats, concrete_value = coder._freeze_code(
        ctx, conversion.concrete_type, source_stats, source_exp)
    local wrapper_decl, wrapper, wrapper_slot
    if result_root then
        assert(type(result_root) == "string",
            "Interface allocation root is not a C expression")
        wrapper_decl, wrapper =
            newtmp(ctx, conversion.interface_type, false)
        wrapper_slot = result_root
    else
        wrapper_decl, wrapper, wrapper_slot =
            newtmp(ctx, conversion.interface_type, true)
    end

    if #pair.fields == 0 then
        -- Keep the established method-only lowering inline and byte-layout
        -- compatible. Field-bearing pairs use the shared allocator below to
        -- make recursive snapshot conversions finite at code-generation time.
        ctx.uses_base_off = true
        return coder._render_interface_wrapper_allocation({
            source_stats = frozen_stats,
            wrapper_decl = wrapper_decl,
            wrapper = wrapper,
            wrapper_slot = wrapper_slot,
            concrete_value = concrete_value,
            interface_metatable = render(
                "hvalue(&_mod->uv[$SLOT].uv)", {
                    SLOT = c_integer_literal(
                        pair.interface_metatable_slot),
                }),
            field_count = 0,
            after_allocation =
                "_base = restorestack(L, _base_off);",
            vtable = coder._module_native_ref(ctx, pair.id),
        }), wrapper
    end

    -- The allocator may resize the Lua stack. Rebase the caller before
    -- addressing its result slot, then publish without another allocating
    -- operation in between.
    ctx.uses_base_off = true
    return render([[
        $SOURCE_STATS
        $WRAPPER_DECL
        $WRAPPER = $ALLOCATOR(L, _mod, $CONCRETE);
        _base = restorestack(L, _base_off);
        $ANCHOR
    ]], {
        SOURCE_STATS = frozen_stats,
        WRAPPER_DECL = wrapper_decl,
        WRAPPER = wrapper,
        ALLOCATOR = pair.allocator_id,
        CONCRETE = concrete_value,
        ANCHOR = setslot(
            conversion.interface_type, wrapper_slot, wrapper),
    }), wrapper
end

function coder._code_interface_conversion(ctx, node)
    local conversion = assert(node._interface_conversion,
        "Interface cast is missing its checker conversion")
    local result_root = node._allocation_result_root
    assert(result_root == nil or type(result_root) == "string",
        "Interface conversion allocation root is not a C expression")
    assert(conversion.source and conversion.target
           and types.equals(conversion.source, node.exp._type)
           and types.equals(conversion.target, node._type),
        "Interface conversion does not match its cast node")

    if conversion.option == "interface_wrapper" then
        assert(not conversion.source_optional
               and not conversion.target_optional,
            "scalar Interface wrapper has optional endpoints")
        local source_stats, source_exp = codeexp(ctx, node.exp)
        return coder._code_interface_wrapper(
            ctx, conversion, source_stats, source_exp, result_root,
            node.loc)
    end

    assert(conversion.option == "option_map"
           or conversion.option == "option_wrap"
           or conversion.option == "option_force",
        "unknown Interface Option operation "
            .. tostring(conversion.option))

    if conversion.option == "option_wrap" then
        assert(not conversion.source_optional
               and conversion.target_optional,
            "Interface Option-wrap has mismatched endpoints")
        local source_stats, source_exp = codeexp(ctx, node.exp)
        local wrapper_stats, wrapper =
            coder._code_interface_wrapper(
                ctx, conversion, source_stats, source_exp, result_root,
                node.loc)
        local result_decl, result = newtmp(ctx, node._type)
        return render([[
            $WRAPPER_STATS
            $RESULT_DECL
            setuvalue(L, &$RESULT, $WRAPPER);
        ]], {
            WRAPPER_STATS = wrapper_stats,
            RESULT_DECL = result_decl,
            RESULT = result,
            WRAPPER = wrapper,
        }), result
    end

    local source_stats, source =
        coder._freeze(ctx, node.exp)
    local concrete_decl, concrete =
        newtmp(ctx, conversion.concrete_type)
    local wrapper_stats, wrapper =
        coder._code_interface_wrapper(
            ctx, conversion, "", concrete, result_root, node.loc)
    local result_decl, result = newtmp(ctx, node._type)
    local nil_arm
    local present_store
    if conversion.option == "option_map" then
        assert(conversion.source_optional
               and conversion.target_optional
               and conversion.nil_propagates,
            "Interface Option-map has mismatched endpoints")
        nil_arm = "setnilvalue(&" .. result .. ");"
        present_store = "setuvalue(L, &" .. result .. ", "
            .. wrapper .. ");"
    else
        assert(conversion.option == "option_force"
               and conversion.source_optional
               and not conversion.target_optional
               and conversion.forces_source,
            "Interface Option-force has mismatched endpoints")
        nil_arm = codethrow(node.loc,
            "%s:%d:%d: type error, expected %s but found nil", {
                c_string_literal(node.loc.filename),
                c_integer_literal(node.loc.line),
                c_integer_literal(node.loc.col),
                c_string_literal(
                    types.tostring(conversion.interface_type)),
            })
        present_store = result .. " = " .. wrapper .. ";"
    end
    return render([[
        $SOURCE_STATS
        $RESULT_DECL
        if (TITAN_UNLIKELY(ttisnil(&$SOURCE))) {
            $NIL_ARM
        } else {
            $CONCRETE_DECL
            $GET_CONCRETE;
            $WRAPPER_STATS
            $PRESENT_STORE
        }
    ]], {
        SOURCE_STATS = source_stats,
        SOURCE = source,
        RESULT_DECL = result_decl,
        RESULT = result,
        NIL_ARM = nil_arm,
        CONCRETE_DECL = concrete_decl,
        GET_CONCRETE = getslot(
            conversion.concrete_type, concrete, "&" .. source),
        WRAPPER_STATS = wrapper_stats,
        PRESENT_STORE = present_store,
    }), result
end

-- Implementation notes: doc/implementation/interfaces.md#tests-and-concrete-downcasts
function coder._code_interface_downcast(ctx, node, predicate_only)
    local downcast = assert(node._interface_downcast,
        "Interface downcast lacks its checker annotation")
    assert(downcast.kind == "interface_downcast"
           and downcast.interface
           and downcast.interface._tag == "Type.Interface"
           and downcast.concrete
           and (downcast.concrete._tag == "Type.Record"
                or downcast.concrete._tag == "Type.Union"),
        "malformed Interface downcast annotation")
    local target = node.target or node._type
    assert(target._tag == "Type.Nominal"
           and target.fqtn == downcast.concrete.name,
        "Interface downcast target is not its concrete nominal")

    local source_stats, source = materialize(ctx, node.exp)
    local wrapper_decl, wrapper =
        newtmp(ctx, types.Nominal(downcast.interface.name))
    local concrete_decl, concrete =
        newtmp(ctx, target)
    local result_decl, result = newtmp(
        ctx, predicate_only and types.Boolean() or target)
    local metatable_slot = type2metatable(ctx, target)
    local unwrap
    if downcast.source_optional then
        unwrap = render([[
            if (!ttisnil(&$SOURCE)) {
                $GET_WRAPPER;
            }
        ]], {
            SOURCE = source,
            GET_WRAPPER = getslot(
                types.Nominal(downcast.interface.name),
                wrapper, "&" .. source),
        })
    else
        unwrap = wrapper .. " = " .. source .. ";"
    end

    local failure
    local success
    if predicate_only then
        failure = result .. " = 0;"
        success = result .. " = 1;"
    else
        failure = codethrow(node.loc,
            "%s:%d:%d: type error, Interface value does not wrap %s", {
                c_string_literal(node.loc.filename),
                c_integer_literal(node.loc.line),
                c_integer_literal(node.loc.col),
                c_string_literal(types.tostring(target)),
            })
        success = result .. " = " .. concrete .. ";"
    end
    return render([[
        $SOURCE_STATS
        $WRAPPER_DECL
        $CONCRETE_DECL
        $RESULT_DECL
        $UNWRAP
        if ($WRAPPER != NULL) {
            $CONCRETE = uvalue(&$WRAPPER->uv[1].uv);
        }
        if (TITAN_LIKELY($CONCRETE != NULL
                && $CONCRETE->metatable ==
                    hvalue(&_mod->uv[$METATABLE_SLOT].uv))) {
            $SUCCESS
        } else {
            $FAILURE
        }
    ]], {
        SOURCE_STATS = source_stats,
        WRAPPER_DECL = wrapper_decl,
        WRAPPER = wrapper,
        CONCRETE_DECL = concrete_decl,
        CONCRETE = concrete,
        RESULT_DECL = result_decl,
        RESULT = result,
        UNWRAP = unwrap,
        METATABLE_SLOT = c_integer_literal(metatable_slot),
        SUCCESS = success,
        FAILURE = failure,
    }), result
end

return core.coder
