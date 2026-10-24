local core = require "titan-compiler.checker.core"
local _ENV = core

-- A type alias remains type-only as a value, but an alias whose transparent
-- target is a record or union may serve as that nominal's static namespace.
-- Return the canonical owner descriptor so selector lookup keeps the original
-- nominal identity, visibility, native symbols, and module userdata.
function alias_namespace_type(typ, st)
    local owner = typ
    if typ and typ._tag == "Type.Nominal" then
        -- A concrete alias pre-closes the owner's binders. Its constructor and
        -- statics retain that application rather than reopening the raw owner
        -- scheme and accepting a second, contradictory argument list.
        owner = generic_applied_owner_view(typ)
    elseif typ and typ._tag == "Type.GenericAlias" then
        owner = types.registry[typ.target_owner_fqtn]
    end
    if not owner
       or (owner._tag ~= "Type.Record" and owner._tag ~= "Type.Union")
       or not is_nominal_visible_from(st, owner.name) then
        return nil
    end
    return owner
end

function visible_record_fields(record, st)
    local out = {}
    for _, field in ipairs(record.fields) do
        if is_nominal_member_visible_from(st, field) then
            table.insert(out, field)
        end
    end
    return out
end

-- Interface implementation is deliberately authorized only at a concrete
-- scalar cast site. The generic type relations know about nominal identities
-- but do not resolve descriptors or decide member visibility; this policy
-- callback supplies those checker-owned facts for one assignment/cast query.
function interface_relation_policy(st, options)
    local policy = {}
    for key, value in pairs(options or {}) do
        policy[key] = value
    end
    policy.visibility = st.modname
    policy.method_visible = function(method)
        return is_nominal_member_visible_from(st, method)
    end
    policy.field_visible = function(field)
        return is_nominal_member_visible_from(st, field)
    end
    policy.interface_coercion = function(source, target, received)
        policy.interface_failure = nil
        local concrete = source._tag == "Type.Nominal"
            and generic_applied_owner_view(source) or nil
        local interface = target._tag == "Type.Nominal"
            and generic_applied_owner_view(target) or nil
        if not concrete
           or (concrete._tag ~= "Type.Record"
               and concrete._tag ~= "Type.Union")
           or not interface
           or interface._tag ~= "Type.Interface"
           or not is_nominal_visible_from(st, source.fqtn) then
            return nil
        end

        local implementation, failure =
            generic_interface_implementation(
                concrete, interface, received)
        policy.interface_failure = failure
        if implementation then
            implementation._surface_concrete = concrete
            implementation._surface_interface = interface
            implementation.cast_module = policy.visibility
            return implementation
        end
        return nil
    end
    return policy
end

function find_interface_wrapper(plan)
    if type(plan) ~= "table" then return nil end
    if plan.op == "interface_wrapper" then return plan end
    return find_interface_wrapper(plan.coercion)
        or find_interface_wrapper(plan.inner)
end

interface_adapters = (function()

local function interface_adapter_assert(condition, message)
    if not condition then
        error("invalid checker Interface adapter plan: " .. message, 2)
    end
end

-- Copy one gradual guard into the checker-owned adapter graph. Keeping this
-- graph independent from the relation result lets coder consume a closed,
-- typed decision without consulting `types.gradual_guard` again.
local function freeze_interface_guard(plan, target, seen)
    interface_adapter_assert(
        type(plan) == "table"
            and plan.kind == "gradual_guard",
        "component lacks a gradual guard")
    interface_adapter_assert(
        plan.target and types.equals(plan.target, target),
        "gradual guard target does not match its component")

    seen = seen or {}
    local prior = seen[plan]
    if prior then
        interface_adapter_assert(
            not prior.active,
            "recursive gradual-guard cycle")
        return prior.frozen
    end

    local frozen = {
        kind = "gradual_guard",
        op = plan.op,
        target = target,
    }
    seen[plan] = { active = true, frozen = frozen }

    local tag = target._tag
    if tag == "Type.Array" then
        interface_adapter_assert(
            plan.op == "array"
                and plan.isconst.tag == target.isconst.tag
                and (types.valid_array_constness(plan.isconst) and plan.isconst.tag ~= "maybe")
                and plan.element,
            "Array guard has the wrong shape")
        frozen.isconst = target.isconst
        frozen.element = freeze_interface_guard(
            plan.element, target.elem, seen)
    elseif tag == "Type.Map" then
        interface_adapter_assert(
            plan.op == "map" and plan.key and plan.value,
            "Map guard has the wrong shape")
        frozen.key = freeze_interface_guard(
            plan.key, target.keys, seen)
        frozen.value = freeze_interface_guard(
            plan.value, target.values, seen)
    elseif tag == "Type.Option" then
        interface_adapter_assert(
            plan.op == "option" and plan.inner,
            "Option guard has the wrong shape")
        frozen.inner = freeze_interface_guard(
            plan.inner, target.base, seen)
    elseif tag == "Type.Nominal"
        or tag == "Type.Record"
        or tag == "Type.Union" then
        local name = target.fqtn or target.name
        interface_adapter_assert(
            plan.op == "nominal" and plan.name == name,
            "nominal guard has the wrong identity")
        frozen.name = name
    else
        local leaf_ops = {
            ["Type.Integer"] = "integer",
            ["Type.Float"] = "float",
            ["Type.Boolean"] = "boolean",
            ["Type.Nil"] = "nil",
            ["Type.String"] = "string",
            ["Type.Value"] = "value",
            ["Type.Function"] = "callable",
            ["Type.COwned"] = "c_owned",
            ["Type.CInteger"] = "c_integer",
            ["Type.CFloat"] = "c_float",
        }
        local expected = leaf_ops[tag]
        if types.is_c_tvalue(target) then
            expected = "c_tvalue"
        end
        interface_adapter_assert(
            expected and plan.op == expected,
            "guard has unsupported leaf " .. tostring(tag))
    end

    seen[plan].active = false
    return frozen
end

local freeze_callable_actions
local freeze_callable_adapter_plan

local function interface_adapter_is_gc(typ)
    local normalized = types.normalize(typ)
    return normalized and types.is_gc(normalized) or false
end

local function interface_injection_may_relocate(typ)
    typ = types.normalize(typ)
    if not typ then return false end
    if typ._tag == "Type.Array" then return true end
    if typ._tag == "Type.Option" then
        return interface_injection_may_relocate(typ.base)
    end
    return false
end

-- Normalize a callable component edge into the only operations an Interface
-- adapter may execute. Ordinary coercions and representation-changing nested
-- Interface construction are intentionally absent.
local function freeze_callable_component(
        adjustment, source, target, context)
    local normalized_source = types.normalize(source)
    local normalized_target = types.normalize(target)
    interface_adapter_assert(
        type(adjustment) == "table",
        "callable component lacks an adjustment")
    interface_adapter_assert(
        normalized_source and normalized_target
            and adjustment.source and adjustment.target
            and types.equals(
                adjustment.source, normalized_source)
            and types.equals(
                adjustment.target, normalized_target),
        "callable component endpoints do not match")
    interface_adapter_assert(
        not adjustment.interface_conversion,
        "nested concrete-to-Interface conversion")

    if adjustment.kind == "identity" then
        return {
            kind = "identity",
            source = normalized_source,
            target = normalized_target,
            declared_source = source,
            declared_target = target,
            timing = "immediate",
            may_raise = false,
            may_relocate = false,
        }
    elseif adjustment.kind == "gradual_view" then
        if adjustment.op == "inject" then
            local may_relocate =
                interface_injection_may_relocate(
                    normalized_source)
            interface_adapter_assert(
                normalized_target._tag == "Type.Value"
                    and adjustment.guard == nil,
                "malformed gradual injection")
            return {
                kind = "gradual_inject",
                source = normalized_source,
                target = normalized_target,
                declared_source = source,
                declared_target = target,
                timing = "immediate",
                may_raise = may_relocate,
                may_relocate = may_relocate,
            }
        end

        interface_adapter_assert(
            adjustment.op == "project"
                or adjustment.op == "structural",
            "unsupported gradual operation "
                .. tostring(adjustment.op))
        local delayed = adjustment.op == "structural"
            and normalized_target._tag ~= "Type.Option"
        return {
            kind = "gradual_guard",
            mode = adjustment.op,
            source = normalized_source,
            target = normalized_target,
            declared_source = source,
            declared_target = target,
            guard = freeze_interface_guard(
                adjustment.guard, normalized_target, {}),
            timing = delayed and "delayed_observation"
                or "immediate",
            may_raise = not delayed,
            -- Conservatively require a rebase after an immediate guard. A
            -- particular leaf check may not allocate, but its checked helper
            -- is allowed to do so without invalidating adapter stack aliases.
            may_relocate = not delayed,
        }
    elseif adjustment.kind == "callable" then
        return {
            kind = "callable_view",
            source = normalized_source,
            target = normalized_target,
            declared_source = source,
            declared_target = target,
            timing = "immediate",
            may_raise = true,
            -- Direct luaF_newCclosure construction performs no stack API call
            -- or ordinary GC poll, so successful construction cannot relocate
            -- the Lua stack. Its allocation may still raise.
            may_relocate = false,
            adapter = freeze_callable_adapter_plan(
                adjustment, normalized_source,
                normalized_target, context.location, context),
        }
    end

    interface_adapter_assert(
        adjustment.kind ~= "direct_coercion",
        "ordinary component coercion is forbidden")
    interface_adapter_assert(false,
        "unknown component operation "
            .. tostring(adjustment.kind))
end

-- Fill the compatibility alias only after constructing the complete nested
-- plan. Existing Interface consumers read `callable`; closure consumers use
-- the full `adapter` including roots, rebases, location, and strict plans.
local function finish_callable_component(operation)
    if operation.kind == "callable_view" then
        operation.callable = operation.adapter.callable
    end
    return operation
end

local function adapter_action(kind, order, fields)
    fields = fields or {}
    fields.kind = kind
    fields.order = order
    fields.id = fields.phase .. ":" .. tostring(order)
    return fields
end

local function component_action(
        raw, kind, order, phase, source, target, context, fields)
    fields = fields or {}
    fields.phase = phase
    fields.source_type = source
    fields.target_type = target
    fields.source_gc = interface_adapter_is_gc(source)
    fields.destination_gc =
        interface_adapter_is_gc(target)
    fields.operation = finish_callable_component(
        freeze_callable_component(
            raw.adjustment, source, target, context))
    fields.rebase_after = fields.operation.may_relocate
    return adapter_action(kind, order, fields)
end

local function callable_dense_count(list, name)
    interface_adapter_assert(type(list) == "table", name .. " is not a table")
    local maximum, count = 0, 0
    for key in pairs(list) do
        interface_adapter_assert(
            type(key) == "number" and key >= 1
                and key == math.floor(key),
            name .. " has a non-array key")
        if key > maximum then maximum = key end
        count = count + 1
    end
    interface_adapter_assert(count == maximum,
        name .. " is not dense")
    for index = 1, maximum do
        interface_adapter_assert(list[index] ~= nil,
            name .. " has a hole at " .. tostring(index))
    end
    return maximum
end

-- Freeze one directional callable plan while preserving every action index and
-- offset. This is structural elaboration only: it never asks any relation to
-- prove a new edge.
freeze_callable_actions = function(raw, source, target, context)
    interface_adapter_assert(
        type(raw) == "table" and raw.kind == "callable",
        "method adjustment is not callable")
    interface_adapter_assert(
        source._tag == "Type.Function"
            and target._tag == "Type.Function"
            and raw.source and raw.target
            and types.equals(raw.source, source)
            and types.equals(raw.target, target),
        "callable plan has mismatched signatures")
    interface_adapter_assert(
        source.vararg == false and target.vararg == false,
        "callable plan has a non-false reserved Function slot")
    interface_adapter_assert(
        raw.exact == types.equals(source, target),
        "callable exactness marker is wrong")
    interface_adapter_assert(
        type(raw.arguments) == "table"
            and type(raw.results) == "table",
        "callable plan lacks ordered action lists")
    local raw_argument_count = callable_dense_count(
        raw.arguments, "callable argument actions")
    local raw_result_count = callable_dense_count(
        raw.results, "callable result actions")

    interface_adapter_assert(
        type(context) == "table",
        "callable freezer lacks its context")

    local frozen = {
        kind = "interface_callable_actions",
        source = source,
        target = target,
        exact = raw.exact,
        arguments = {},
        results = {},
    }
    local argument_index = 0
    local function argument(kind)
        argument_index = argument_index + 1
        local action = raw.arguments[argument_index]
        interface_adapter_assert(
            action and action.kind == kind,
            "expected argument action " .. kind
                .. " at " .. tostring(argument_index))
        return action, argument_index
    end

    local shared = math.min(#source.params, #target.params)
    for index = 1, shared do
        local action, order = argument("argument")
        interface_adapter_assert(
            action.expected_index == index
                and action.actual_index == index,
            "shared argument indexes are not canonical")
        frozen.arguments[order] = component_action(
            action, "argument", order, "argument",
            target.params[index], source.params[index], context, {
                expected_index = index,
                actual_index = index,
                source_kind = "interface_fixed",
                destination_kind = "concrete_fixed",
            })
    end

    for index = #target.params + 1, #source.params do
        if target.varargtype then
            local action, order =
                argument("tail_or_nil_to_argument")
            interface_adapter_assert(
                action.actual_index == index
                    and action.expected_tail_offset
                        == index - #target.params,
                "tail-to-fixed argument indexes are not canonical")
            frozen.arguments[order] = component_action(
                action, "tail_or_nil_to_argument", order, "argument",
                target.varargtype, source.params[index], context, {
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
                })
        else
            local action, order = argument("nil_fill")
            interface_adapter_assert(
                action.actual_index == index
                    and action.adjustment == nil,
                "nil-fill argument is malformed")
            frozen.arguments[order] = adapter_action(
                "nil_fill", order, {
                    phase = "argument",
                    actual_index = index,
                    source_kind = "constant_nil",
                    destination_kind = "concrete_fixed",
                    source_type = types.Nil(),
                    target_type = source.params[index],
                    source_gc = false,
                    destination_gc =
                        interface_adapter_is_gc(
                            source.params[index]),
                    admissible = true,
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = source.params[index],
                    },
                    rebase_after = false,
                })
        end
    end

    for index = #source.params + 1, #target.params do
        if source.varargtype then
            local action, order = argument("argument_to_tail")
            interface_adapter_assert(
                action.expected_index == index,
                "fixed-to-tail argument index is not canonical")
            frozen.arguments[order] = component_action(
                action, "argument_to_tail", order, "argument",
                target.params[index], source.varargtype, context, {
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "concrete_tail",
                    destination_open = true,
                })
        else
            local action, order = argument("ignore_argument")
            interface_adapter_assert(
                action.expected_index == index
                    and action.adjustment == nil,
                "ignored argument is malformed")
            frozen.arguments[order] = adapter_action(
                "ignore_argument", order, {
                    phase = "argument",
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "discard",
                    source_type = target.params[index],
                    target_type = nil,
                    source_gc =
                        interface_adapter_is_gc(
                            target.params[index]),
                    destination_gc = false,
                    effect = "evaluate_and_discard",
                    rebase_after = false,
                })
        end
    end

    if source.varargtype and target.varargtype then
        local action, order = argument("tail_to_tail")
        local consumed =
            math.max(0, #source.params - #target.params)
        interface_adapter_assert(
            action.expected_tail_consumed == consumed,
            "input tail offset is not canonical")
        frozen.arguments[order] = component_action(
            action, "tail_to_tail", order, "argument",
            target.varargtype, source.varargtype, context, {
                expected_tail_consumed = consumed,
                source_kind = "interface_tail",
                source_open = true,
                destination_kind = "concrete_tail",
                destination_open = true,
            })
    elseif source.varargtype then
        local action, order = argument("empty_tail")
        interface_adapter_assert(
            action.adjustment == nil,
            "empty-tail action has an adjustment")
        frozen.arguments[order] = adapter_action(
            "empty_tail", order, {
                phase = "argument",
                source_kind = "empty",
                destination_kind = "concrete_tail",
                source_type = nil,
                target_type = source.varargtype,
                source_gc = false,
                destination_gc =
                    interface_adapter_is_gc(
                        source.varargtype),
                destination_open = true,
                count = 0,
                rebase_after = false,
            })
    elseif target.varargtype then
        local action, order = argument("ignore_tail")
        local consumed =
            math.max(0, #source.params - #target.params)
        interface_adapter_assert(
            action.expected_tail_consumed == consumed
                and action.adjustment == nil,
            "ignored-tail action is malformed")
        frozen.arguments[order] = adapter_action(
            "ignore_tail", order, {
                phase = "argument",
                expected_tail_consumed = consumed,
                source_kind = "interface_tail",
                source_open = true,
                destination_kind = "discard",
                source_type = target.varargtype,
                target_type = nil,
                source_gc =
                    interface_adapter_is_gc(
                        target.varargtype),
                destination_gc = false,
                effect = "evaluate_run_and_discard",
                rebase_after = false,
            })
    end
    interface_adapter_assert(
        argument_index == raw_argument_count,
        "callable plan has extra argument actions")

    local result_index = 0
    local function result(kind)
        result_index = result_index + 1
        local action = raw.results[result_index]
        interface_adapter_assert(
            action and action.kind == kind,
            "expected result action " .. kind
                .. " at " .. tostring(result_index))
        return action, result_index
    end

    for index, expected in ipairs(target.rettypes) do
        local actual = source.rettypes[index]
        if actual then
            local action, order = result("result")
            interface_adapter_assert(
                action.actual_index == index
                    and action.expected_index == index,
                "fixed result indexes are not canonical")
            frozen.results[order] = component_action(
                action, "result", order, "result",
                actual, expected, context, {
                    actual_index = index,
                    expected_index = index,
                    source_kind = "concrete_fixed",
                    destination_kind = "interface_fixed",
                })
        elseif source.flexrettype then
            local optional = expected._tag == "Type.Option"
            local kind = optional
                and "flex_to_optional_result"
                or "flex_to_result"
            local action, order = result(kind)
            local offset = index - #source.rettypes
            interface_adapter_assert(
                action.expected_index == index
                    and action.actual_flex_offset == offset,
                "flexible result indexes are not canonical")
            interface_adapter_assert(
                optional
                    and (action.wrap_present == nil
                         or action.wrap_present == true)
                    or (not optional
                        and action.wrap_present == nil),
                "flexible result has invalid Option metadata")
            local wraps = action.wrap_present == true
            local operation_target =
                wraps and expected.base or expected
            local frozen_action = component_action(
                action, kind, order, "result",
                source.flexrettype, operation_target, context, {
                    expected_index = index,
                    actual_flex_offset = offset,
                    source_kind = "concrete_flex",
                    source_open = true,
                    destination_kind = "interface_fixed",
                    target_type = expected,
                    operation_target_type = operation_target,
                    destination_gc =
                        interface_adapter_is_gc(expected),
                    missing_arm = {
                        kind = optional and "nil_fill"
                            or "raise_missing_result",
                        target_type = expected,
                    },
                    present_arm = {
                        kind = "operation",
                        wrap_present = wraps,
                        target_type = operation_target,
                    },
                    wrap_present = wraps,
                })
            -- The operation may target the Option base, but the adapter slot
            -- and its destination root always carry the complete expected
            -- result type.
            frozen_action.target_type = expected
            frozen_action.destination_gc =
                interface_adapter_is_gc(expected)
            frozen.results[order] = frozen_action
        else
            local action, order = result("nil_fill_result")
            interface_adapter_assert(
                action.expected_index == index
                    and action.expected_type
                    and types.equals(action.expected_type, expected)
                    and action.adjustment == nil,
                "missing-result nil fill is malformed")
            frozen.results[order] = adapter_action(
                "nil_fill_result", order, {
                    phase = "result",
                    expected_index = index,
                    expected_type = expected,
                    source_kind = "constant_nil",
                    destination_kind = "interface_fixed",
                    source_type = types.Nil(),
                    target_type = expected,
                    source_gc = false,
                    destination_gc =
                        interface_adapter_is_gc(expected),
                    admissible = true,
                    effect = "synthesize_nil",
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = expected,
                    },
                    rebase_after = false,
                })
        end
    end

    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype then
            local action, order = result("result_to_flex")
            local offset = index - #target.rettypes
            interface_adapter_assert(
                action.actual_index == index
                    and action.expected_flex_offset == offset,
                "fixed-to-flex result indexes are not canonical")
            frozen.results[order] = component_action(
                action, "result_to_flex", order, "result",
                source.rettypes[index], target.flexrettype, context, {
                    actual_index = index,
                    expected_flex_offset = offset,
                    source_kind = "concrete_fixed",
                    destination_kind = "interface_flex",
                    destination_open = true,
                })
        else
            local action, order = result("hide_result")
            interface_adapter_assert(
                action.actual_index == index
                    and action.adjustment == nil,
                "hidden result is malformed")
            frozen.results[order] = adapter_action(
                "hide_result", order, {
                    phase = "result",
                    actual_index = index,
                    source_kind = "concrete_fixed",
                    destination_kind = "discard",
                    source_type = source.rettypes[index],
                    target_type = nil,
                    source_gc =
                        interface_adapter_is_gc(
                            source.rettypes[index]),
                    destination_gc = false,
                    effect = "discard",
                    rebase_after = false,
                })
        end
    end

    if source.flexrettype and target.flexrettype then
        local action, order = result("flex_to_flex")
        local consumed =
            math.max(0, #target.rettypes - #source.rettypes)
        interface_adapter_assert(
            action.actual_flex_consumed == consumed,
            "output flex offset is not canonical")
        frozen.results[order] = component_action(
            action, "flex_to_flex", order, "result",
            source.flexrettype, target.flexrettype, context, {
                actual_flex_consumed = consumed,
                source_kind = "concrete_flex",
                source_open = true,
                destination_kind = "interface_flex",
                destination_open = true,
            })
    elseif source.flexrettype then
        local action, order = result("hide_flex")
        local consumed =
            math.max(0, #target.rettypes - #source.rettypes)
        interface_adapter_assert(
            action.actual_flex_consumed == consumed
                and action.adjustment == nil,
            "hidden flex result is malformed")
        frozen.results[order] = adapter_action(
            "hide_flex", order, {
                phase = "result",
                actual_flex_consumed = consumed,
                source_kind = "concrete_flex",
                source_open = true,
                destination_kind = "discard",
                source_type = source.flexrettype,
                target_type = nil,
                source_gc =
                    interface_adapter_is_gc(
                        source.flexrettype),
                destination_gc = false,
                effect = "discard_run",
                rebase_after = false,
            })
    elseif target.flexrettype then
        local action, order = result("end_flex")
        interface_adapter_assert(
            action.adjustment == nil,
            "end-flex action has an adjustment")
        frozen.results[order] = adapter_action(
            "end_flex", order, {
                phase = "result",
                source_kind = "empty",
                destination_kind = "interface_flex",
                source_type = nil,
                target_type = target.flexrettype,
                source_gc = false,
                destination_gc =
                    interface_adapter_is_gc(
                        target.flexrettype),
                destination_open = true,
                count = 0,
                rebase_after = false,
            })
    end
    interface_adapter_assert(
        result_index == raw_result_count,
        "callable plan has extra result actions")

    return frozen
end

local function adapter_root_range(
        id, phase, side, element_type, lifetime, traced)
    local present = element_type ~= nil
    local gc_bearing =
        present and interface_adapter_is_gc(
            element_type) or false
    traced = gc_bearing and traced == true
    return {
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
end

local function adapter_operation_allocates(action)
    return action.operation ~= nil
        and action.operation.kind == "callable_view"
end

local function adapter_has_open_source(actions)
    for _, action in ipairs(actions) do
        if action.operation and action.source_open then return true end
    end
    return false
end

local function adapter_has_open_allocating_destination(actions)
    for _, action in ipairs(actions) do
        if adapter_operation_allocates(action)
           and action.destination_open then
            return true
        end
    end
    return false
end

local function adapter_fixed_allocation_roots(actions, lifetime)
    local roots = {}
    for _, action in ipairs(actions) do
        if adapter_operation_allocates(action)
           and action.destination_gc
           and not action.destination_open then
            roots[#roots + 1] = {
                action = action.id,
                type = action.target_type,
                storage = "lua_stack_slot",
                retain_until = lifetime,
            }
        end
    end
    return roots
end

local function adapter_fixed_result_source_roots(actions, lifetime)
    local roots = {}
    for _, action in ipairs(actions) do
        if action.operation and action.source_gc
           and not action.source_open then
            roots[#roots + 1] = {
                action = action.id,
                type = action.source_type,
                storage = "lua_stack_slot",
                retain_until = lifetime,
            }
        end
    end
    return roots
end

local function adapter_rooting(source, target, actions, lifetimes, construction)
    return {
        raw_descriptors_are_roots = false,
        raw_buffers_are_roots = false,
        construction = construction,
        fixed = {
            -- Native inputs remain C arguments and acquire no tracing-only
            -- source roots. Only a freshly allocated nested wrapper needs an
            -- immediate destination root.
            argument_source = {},
            argument_destination = adapter_fixed_allocation_roots(
                actions.arguments, lifetimes.argument_destination),
            -- Every live GC-bearing native result is rooted immediately after
            -- return. Fresh converted wrappers separately root their allocation.
            result_source = adapter_fixed_result_source_roots(
                actions.results, lifetimes.result_source),
            result_destination = adapter_fixed_allocation_roots(
                actions.results, lifetimes.result_destination),
        },
        ranges = {
            argument_source = adapter_root_range(
                "argument_source", "argument", "source",
                target.varargtype, lifetimes.argument_source, false),
            argument_destination = adapter_root_range(
                "argument_destination", "argument", "destination",
                source.varargtype, lifetimes.argument_destination,
                adapter_has_open_allocating_destination(actions.arguments)),
            result_source = adapter_root_range(
                "result_source", "result", "source",
                source.flexrettype, lifetimes.result_source,
                adapter_has_open_source(actions.results)),
            result_destination = adapter_root_range(
                "result_destination", "result", "destination",
                target.flexrettype, lifetimes.result_destination,
                adapter_has_open_allocating_destination(actions.results)),
        },
    }
end

local CALLABLE_ADAPTER_VARARG_CAP = 200

local function callable_adapter_location(loc)
    interface_adapter_assert(
        type(loc) == "table"
            and type(loc.filename) == "string"
            and type(loc.line) == "number"
            and loc.line >= 1 and loc.line == math.floor(loc.line)
            and type(loc.col) == "number"
            and loc.col >= 1 and loc.col == math.floor(loc.col),
        "callable adapter lacks a real source location")
    return {
        filename = loc.filename,
        line = loc.line,
        col = loc.col,
    }
end

local function same_adapter_location(left, right)
    return left and right
        and left.filename == right.filename
        and left.line == right.line
        and left.col == right.col
end

local function freeze_strict_guard_slot(typ, index)
    local normalized = types.normalize(typ)
    interface_adapter_assert(normalized,
        "strict relay has an unnormalizable boundary type")
    local guard = types.gradual_guard(normalized)
    return {
        index = index,
        type = normalized,
        guard = maybe3.from_optional(guard
            and freeze_interface_guard(guard, normalized, {}) or nil),
    }
end

local function freeze_strict_relay(target)
    local relay = {
        kind = "callable_strict_relay",
        parameters = {},
        vararg = nil,
        results = {},
        flexible_result = nil,
    }
    for index, typ in ipairs(target.params) do
        relay.parameters[index] = freeze_strict_guard_slot(typ, index)
    end
    if target.varargtype then
        relay.vararg = freeze_strict_guard_slot(
            target.varargtype, "vararg")
    end
    for index, typ in ipairs(target.rettypes) do
        relay.results[index] = freeze_strict_guard_slot(typ, index)
    end
    if target.flexrettype then
        relay.flexible_result = freeze_strict_guard_slot(
            target.flexrettype, "flexible_result")
    end
    return relay
end

local function callable_adapter_rooting(source, target, actions)
    return adapter_rooting(source, target, actions, {
        argument_source = "all_arguments_converted",
        argument_destination = "source_native_call_returns",
        result_source = "all_results_converted",
        result_destination = "target_caller_handoff",
    }, {
        result = {
            type = target,
            gc_bearing = true,
            traced = true,
            storage = "conditional_lua_stack_slot",
            condition = "eligible_exact_titan_clone",
            retain_until = "target_caller_handoff",
        },
    })
end

local function callable_action_rebase_reason(action)
    interface_adapter_assert(
        action.operation
            and action.operation.timing == "immediate"
            and action.operation.may_relocate == true
            and action.operation.kind ~= "callable_view",
        "callable adapter has a rebase for a non-relocating action")
    return "immediate_gradual_guard"
end

local function callable_adapter_rebases(actions)
    local points = {}
    for _, action in ipairs(actions.arguments) do
        if action.rebase_after then
            points[#points + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    points[#points + 1] = {
        kind = "after_native_call",
        backend = "immediate_source_closure",
        reason = "source_call_may_relocate_stack",
    }
    for _, action in ipairs(actions.results) do
        if action.rebase_after then
            points[#points + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    return points
end

local function freeze_flexible_result_demand(source, target)
    local consumed = math.max(
        0, #target.rettypes - #source.rettypes)
    local fixed_surplus = math.max(
        0, #source.rettypes - #target.rettypes)
    local source_has_flex = source.flexrettype ~= nil
    local target_has_flex = target.flexrettype ~= nil
    return {
        kind = "callable_flexible_result_demand",
        abi_cap = CALLABLE_ADAPTER_VARARG_CAP,
        source_has_flex = source_has_flex,
        target_has_flex = target_has_flex,
        fixed_source_flex_consumed = consumed,
        fixed_source_surplus = fixed_surplus,
        remaining_source_capacity =
            CALLABLE_ADAPTER_VARARG_CAP - consumed,
        within_abi_cap = consumed <= CALLABLE_ADAPTER_VARARG_CAP,
        mode = not source_has_flex and "none"
            or (target_has_flex and "forward_target_demand"
                or "fixed_prefix"),
        target_demand_parameter = target_has_flex
            and "_flexwant" or nil,
        unlimited_demand = target_has_flex
            and "LUA_MULTRET" or nil,
    }
end

freeze_callable_adapter_plan = function(raw, source, target, loc, context)
    source = types.normalize(source)
    target = types.normalize(target)
    interface_adapter_assert(
        source and target
            and source._tag == "Type.Function"
            and target._tag == "Type.Function",
        "callable adapter endpoints are not functions")
    local frozen_location = callable_adapter_location(loc)

    context = context or {}
    context.adapters = context.adapters or {}
    context.location = context.location or frozen_location
    local prior = context.adapters[raw]
    if prior then
        interface_adapter_assert(not prior.active,
            "recursive callable-plan cycle")
        return prior.frozen
    end

    local attached = raw._callable_adapter
    if attached then
        interface_adapter_assert(
            attached.source and attached.target
                and types.equals(attached.source, source)
                and types.equals(attached.target, target)
                and same_adapter_location(
                    attached.location, frozen_location),
            "callable plan already has a different frozen adapter")
        return attached
    end

    local frozen = {
        kind = "callable_adapter_plan",
        source = source,
        target = target,
        exact = raw.exact,
        location = frozen_location,
        trace_name = string.format(
            "[callable adapter %s -> %s at %s:%d:%d]",
            types.tostring(source), types.tostring(target),
            frozen_location.filename, frozen_location.line,
            frozen_location.col),
        callable = nil,
        arguments = nil,
        results = nil,
        dense = nil,
        strict_relay = nil,
        rooting = nil,
        rebase_points = nil,
        flexible_result_demand = nil,
        relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true,
    }
    context.adapters[raw] = { active = true, frozen = frozen }

    local previous_location = context.location
    context.location = frozen_location
    local actions = freeze_callable_actions(raw, source, target, context)
    context.location = previous_location
    frozen.callable = actions
    frozen.arguments = actions.arguments
    frozen.results = actions.results
    frozen.dense = {
        argument_count = #actions.arguments,
        result_count = #actions.results,
    }
    frozen.strict_relay = freeze_strict_relay(target)
    frozen.rooting = callable_adapter_rooting(source, target, actions)
    frozen.rebase_points = callable_adapter_rebases(actions)
    frozen.flexible_result_demand =
        freeze_flexible_result_demand(source, target)

    context.adapters[raw].active = false
    raw._callable_adapter = frozen
    return frozen
end

-- Implementation notes: doc/implementation/interfaces.md#frozen-conversion-and-adapter-plans
local function make_interface_adapter(
        concrete, interface, mapping, cast_module)
    interface_adapter_assert(
        mapping and mapping.required and mapping.concrete,
        "method mapping lacks descriptors")
    interface_adapter_assert(
        mapping.index >= 0
            and interface.methods[mapping.index + 1]
                == mapping.required
            and mapping.required.name == mapping.name
            and mapping.concrete.fqtn == concrete.name,
        "method mapping does not match its Interface slot")
    interface_adapter_assert(
        mapping.source and mapping.target
            and mapping.source._tag == "Type.Function"
            and mapping.target._tag == "Type.Function",
        "method mapping lacks projected signatures")
    interface_adapter_assert(
        mapping.exact == types.equals(
            mapping.source, mapping.target),
        "method mapping exactness is inconsistent")

    local owner_module = nominal_module(concrete.name)
    if mapping.exact and (not cast_module or owner_module == cast_module) then
        mapping.slot_kind = "exact"
        mapping.interface_adapter = nil
        return nil
    end

    local trace_name = string.format(
        "%s:%s [adapter for %s:%s]",
        interface.name, mapping.name,
        concrete.name, mapping.name)
    local shared = freeze_callable_adapter_plan(
        mapping.adjustment, mapping.source, mapping.target,
        location.new(trace_name .. ".titan", 1, 1), nil)
    local actions = shared.callable
    local owner_module = nominal_module(concrete.name)
    local adapter = {
        kind = "interface_method_adapter",
        slot = mapping.index,
        slot_kind = "adapter",
        name = mapping.name,
        symbol_key = string.format(
            "%s->%s#%d:%s",
            concrete.name, interface.name,
            mapping.index, mapping.name),
        trace_name = trace_name,
        concrete_owner = concrete,
        concrete_owner_module = owner_module,
        concrete_method = mapping.concrete,
        concrete_signature = mapping.source,
        interface = interface,
        interface_method = mapping.required,
        -- The native adapter ABI is the Interface Method descriptor (hidden
        -- L/module/closure/self included by function_sig). Its self-removed
        -- callable projection is recorded separately.
        native_signature = mapping.required,
        interface_signature = mapping.target,
        hidden_operands = {
            concrete_owner_module = {
                parameter = "_mod",
                provenance = "adapter_owner_module",
                owner = concrete,
                module = owner_module,
            },
            closure = {
                parameter = "_fn",
                adapter_value = "NULL",
                concrete_call_value = "NULL",
            },
            self = {
                provenance = "interface_wrapper_uservalue_1",
                type = types.Nominal(concrete.name),
                forwards_unchanged = true,
            },
        },
        arguments = actions.arguments,
        results = actions.results,
        callable = actions,
        callable_adapter = shared,
        relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true,
    }

    adapter.rooting = adapter_rooting(
        mapping.source, mapping.target, actions, {
            argument_source = "all_arguments_converted",
            argument_destination = "concrete_call_returns",
            result_source = "all_results_converted",
            result_destination = "interface_caller_handoff",
        }, nil)

    local argument_rebases, result_rebases = {}, {}
    for _, action in ipairs(adapter.arguments) do
        if action.rebase_after then
            argument_rebases[#argument_rebases + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    for _, action in ipairs(adapter.results) do
        if action.rebase_after then
            result_rebases[#result_rebases + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    adapter.rebase_points = {}
    for _, point in ipairs(argument_rebases) do
        adapter.rebase_points[#adapter.rebase_points + 1] = point
    end
    adapter.rebase_points[#adapter.rebase_points + 1] = {
        kind = "after_native_call",
        method = mapping.concrete,
        reason = "concrete_call_may_relocate_stack",
    }
    for _, point in ipairs(result_rebases) do
        adapter.rebase_points[#adapter.rebase_points + 1] = point
    end

    mapping.slot_kind = "adapter"
    mapping.interface_adapter = adapter
    return adapter
end

return {
    make = make_interface_adapter,
    freeze = freeze_callable_adapter_plan,
}

end)()

-- Freeze a checker-authorized Function-to-Function edge into the closed action,
-- rooting, rebase, strict-boundary, and demand graph consumed by codegen. This
-- is elaboration only: it never asks an assignment/callable relation again.
function checker.freeze_callable_adapter(
        raw, source, target, loc)
    return interface_adapters.freeze(raw, source, target, loc, nil)
end

local freeze_interface_implementation

local function interface_conversion_assert(condition, message)
    if not condition then
        error("invalid checker Interface conversion plan: " .. message, 2)
    end
end

-- Interface field snapshots are ordinary assignment conversions, but their
-- complete plan is stored inside the enclosing Interface implementation rather
-- than on a source expression. Freeze every callable view and recursively
-- discovered Interface implementation now, while the checker still owns all
-- relation decisions. Code generation may only consume this closed graph.
local function freeze_interface_field_adjustment(adjustment, seen)
    if type(adjustment) ~= "table" or seen[adjustment] then return end
    seen[adjustment] = true

    if adjustment.kind == "callable" then
        checker.freeze_callable_adapter(
            adjustment, adjustment.source, adjustment.target,
            location.new(string.format(
                "[interface field callable %s -> %s].titan",
                types.tostring(adjustment.source),
                types.tostring(adjustment.target)), 1, 1))
    end

    if find_interface_wrapper(adjustment) then
        adjustment.interface_conversion = assert(
            make_interface_conversion(
                adjustment.source, adjustment.target, adjustment, seen),
            "nested Interface field adjustment lost its conversion")
        return
    end
    freeze_interface_field_adjustment(adjustment.coercion, seen)
    freeze_interface_field_adjustment(adjustment.inner, seen)
    freeze_interface_field_adjustment(adjustment.element_view, seen)
end

freeze_interface_implementation = function(implementation, seen)
    seen = seen or {}
    if seen[implementation] then return end
    seen[implementation] = true
    interface_conversion_assert(
        type(implementation) == "table"
            and implementation.kind == "interface_implementation"
            and implementation.concrete
            and implementation.interface
            and type(implementation.fields) == "table"
            and type(implementation.methods) == "table",
        "conversion lacks its complete implementation")

    local concrete = implementation.concrete
    local interface = implementation.interface
    for index, mapping in ipairs(implementation.fields) do
        interface_conversion_assert(
            mapping.required and mapping.concrete
                and mapping.required == interface.fields[index]
                and mapping.required.name == mapping.name
                and mapping.required.index == mapping.target_index
                and mapping.concrete.index == mapping.source_index
                and mapping.concrete.fqtn == concrete.name
                and mapping.source and mapping.target
                and types.equals(mapping.source, mapping.concrete.type)
                and types.equals(mapping.target, mapping.required.type)
                and type(mapping.adjustment) == "table",
            "field mapping does not match its source and target slots")
        freeze_interface_field_adjustment(mapping.adjustment, seen)
    end
    for _, mapping in ipairs(implementation.methods) do
        interface_adapters.make(concrete, interface, mapping, implementation.cast_module)
    end
end

function make_interface_conversion(source, target, adjustment, seen)
    local wrapper = find_interface_wrapper(adjustment)
    if not wrapper then return nil end
    local implementation = assert(wrapper.implementation,
        "Interface coercion lacks its implementation plan")
    local concrete = implementation._surface_concrete
        or implementation.concrete
        or types.registry[wrapper.source.fqtn]
    local interface = implementation._surface_interface
        or implementation.interface
        or types.registry[wrapper.target.fqtn]
    implementation.concrete = concrete
    implementation.interface = interface
    freeze_interface_implementation(implementation, seen or {})
    local root = adjustment.coercion or adjustment
    return {
        kind = "interface_conversion",
        source = source,
        target = target,
        concrete = concrete,
        interface = interface,
        concrete_type = wrapper.source,
        interface_type = wrapper.target,
        fields = implementation.fields,
        methods = implementation.methods,
        implementation = implementation,
        exact = implementation.exact,
        option = root.op or "interface_wrapper",
        source_optional = source._tag == "Type.Option",
        target_optional = target._tag == "Type.Option",
        nil_propagates = root.op == "option_map",
        forces_source = root.op == "option_force",
        wraps_present = root.op == "option_wrap",
    }
end

function generic_rigid_parameter_carrier(parameter)
    if not parameter or parameter._tag ~= "Type.Parameter" then return nil end
    return parameter.erased_constraint ~= nil
        and parameter.erased_constraint or types.Value()
end

-- Surface generic types have not reached the erased-core pass yet.  Whenever
-- an existing checker annotation needs the eventual runtime carrier, erase a
-- detached Type view rather than weakening the rigid surface type itself.
function generic_runtime_carrier(typ)
    if types.contains_generic(typ) then return types.erase(typ) end
    return typ
end

-- Ordinary nominal identity is intentionally the shared run-time owner, but
-- applied generic nominals remain distinct static types.  Preserve the one
-- sanctioned shallow consistency edge pointwise: an argument may move to or
-- from its binder's erased carrier, never directly to another precise
-- application merely because both values share one metatable.
function generic_surface_argument_consistent(
        left, right, typeparam, owner, left_args, right_args, st)
    left, right = types.normalize(left), types.normalize(right)
    if not left or not right then return false end
    if types.equals(left, right) then return true end
    if not typeparam then return false end

    -- Shallow generic consistency is narrower than ordinary structural
    -- consistency. One side must be this owner binder's exact erased carrier;
    -- recursively consistent arguments such as {integer} and {value} do not
    -- turn G<{integer}> and G<{value}> into the same application view.
    if typeparam.constraint == nil then
        return left._tag == "Type.Value" or right._tag == "Type.Value"
    end

    local left_constraint = generic_substitute(
        typeparam.constraint, owner.scope, left_args)
    local right_constraint = generic_substitute(
        typeparam.constraint, owner.scope, right_args)
    if not left_constraint or not right_constraint then return false end
    return (types.equals(right, right_constraint)
            and generic_constraint_satisfied(
                left, left_constraint, st) == true)
        or (types.equals(left, left_constraint)
            and generic_constraint_satisfied(
                right, right_constraint, st) == true)
end

function generic_applied_nominal_adjustment(source, target, st)
    source, target = types.normalize(source), types.normalize(target)
    if not source or not target
       or source._tag ~= "Type.Nominal"
       or target._tag ~= "Type.Nominal"
       or source.fqtn ~= target.fqtn then
        return false, nil
    end

    local source_args, target_args = source.args or {}, target.args or {}
    if #source_args == 0 and #target_args == 0 then return false, nil end
    if #source_args ~= #target_args then return true, nil end
    if types.equals(source, target) then return false, nil end

    local owner = types.registry[source.fqtn]
    for index = 1, #source_args do
        local typeparam = owner and owner.typeparams
            and owner.typeparams[index] or nil
        local consistent = generic_surface_argument_consistent(
            source_args[index], target_args[index], typeparam, owner,
            source_args, target_args, st)
        if not consistent then return true, nil end
    end

    return true, {
        kind = "identity",
        source = source,
        target = target,
    }
end

function checker_assignment_adjustment(source, target, st, options)
    st = st or active_check_state
    local applied, application_plan =
        generic_applied_nominal_adjustment(source, target, st)
    if applied then return application_plan, nil, nil end
    if source._tag == "Type.Option" or target._tag == "Type.Option" then
        local source_base = source._tag == "Type.Option" and source.base or source
        local target_base = target._tag == "Type.Option" and target.base or target
        local inner_applied, inner_plan =
            generic_applied_nominal_adjustment(
                source_base, target_base, st)
        if inner_applied then
            if not inner_plan then return nil, nil, nil end
            return checker_assignment_adjustment(
                types.erase(source), types.erase(target), st, options)
        end
    end

    -- Rigid transport to or from the binder's own erased constraint is a
    -- representation identity at the generic surface. Distinct parameters do
    -- not become assignable merely because their carriers happen to match.
    local source_carrier = generic_rigid_parameter_carrier(source)
    local target_carrier = generic_rigid_parameter_carrier(target)
    if source_carrier and not target_carrier
       and types.equals(source_carrier, target) then
        return { kind = "identity", source = source, target = target }, nil, nil
    elseif target_carrier and not source_carrier
       and types.equals(source, target_carrier) then
        return { kind = "identity", source = source, target = target }, nil, nil
    elseif target_carrier and not source_carrier
       and (source._tag == "Type.Value" or types.is_c_tvalue(source)) then
        return checker_assignment_adjustment(
            source, target_carrier, st, options)
    elseif source_carrier and not target_carrier
       and (target._tag == "Type.Value" or types.is_c_tvalue(target)) then
        return checker_assignment_adjustment(
            source_carrier, target, st, options)
    -- Check the cheap target/source shape before walking a type graph.
    elseif (target._tag == "Type.Value" or types.is_c_tvalue(target))
       and types.contains_generic(source) then
        return checker_assignment_adjustment(
            types.erase(source), target, st, options)
    elseif (source._tag == "Type.Value" or types.is_c_tvalue(source))
       and types.contains_generic(target) then
        return checker_assignment_adjustment(
            source, types.erase(target), st, options)
    end
    if not st then
        return types.assignment_adjustment(source, target, options),
            nil, nil
    end
    local policy = interface_relation_policy(st, options)
    local adjustment =
        types.assignment_adjustment(source, target, policy)
    local conversion = adjustment
        and make_interface_conversion(
            source, target, adjustment)
        or nil
    if conversion then
        adjustment.interface_conversion = conversion
    end
    return adjustment, conversion,
        policy.interface_failure or nil
end

function report_interface_failure(errors, loc, failure)
    if not failure then return false end
    local concrete = failure.concrete
    local interface = failure.interface
    if not concrete or not interface then return false end
    local concrete_kind = concrete._tag == "Type.Union"
        and "union" or "record"
    local prefix = string.format(
        "%s '%s' does not implement interface '%s'",
        concrete_kind, concrete.name, interface.name)
    local field = failure.member_kind == "field"
    if failure.reason == "fields_require_record" then
        checker.typeerror(errors, loc,
            "%s: interface fields require a record implementation; field '%s' cannot be supplied by a union",
            prefix, failure.name)
    elseif failure.reason == "missing" and field then
        checker.typeerror(errors, loc,
            "%s: const field '%s' is missing",
            prefix, failure.name)
    elseif failure.reason == "not_field" then
        checker.typeerror(errors, loc,
            "%s: member '%s' is not a field",
            prefix, failure.name)
    elseif failure.reason == "mutable" then
        checker.typeerror(errors, loc,
            "%s: field '%s' is mutable; a const field is required",
            prefix, failure.name)
    elseif failure.reason == "inaccessible" and field then
        checker.typeerror(errors, loc,
            "%s: field '%s' is local to module '%s'",
            prefix, failure.name,
            nominal_module(failure.member.fqtn))
    elseif failure.reason == "incompatible" and field then
        checker.typeerror(errors, loc,
            "%s: field '%s' has incompatible type '%s'; expected '%s'",
            prefix, failure.name,
            types.tostring(failure.concrete_type),
            types.tostring(failure.required_type))
    elseif failure.reason == "missing" then
        checker.typeerror(errors, loc,
            "%s: method '%s' is missing",
            prefix, failure.name)
    elseif failure.reason == "not_method" then
        checker.typeerror(errors, loc,
            "%s: member '%s' is not a method",
            prefix, failure.name)
    elseif failure.reason == "inaccessible" then
        checker.typeerror(errors, loc,
            "%s: method '%s' is local to module '%s'",
            prefix, failure.name,
            nominal_module(failure.member.fqtn))
    elseif failure.reason == "incompatible" then
        checker.typeerror(errors, loc,
            "%s: method '%s' has incompatible type '%s'; expected '%s'",
            prefix, failure.name,
            types.tostring(failure.concrete_type),
            types.tostring(failure.required_type))
    else
        checker.typeerror(errors, loc,
            "%s: interface implementation could not be validated",
            prefix)
    end
    return true
end

function interface_method_index(interface, name)
    for index, method in ipairs(interface.methods or {}) do
        if method.name == name then return index - 1 end
    end
    return nil
end

-- Generic applications are surface-only checker types. The owner registry keeps
-- one declaration descriptor; an application substitutes its immutable binder
-- scope into a fresh view for field, variant, and method lookup.
function generic_owner_type(typ)
    if not typ then return nil end
    if typ._tag == "Type.Nominal" then
        return types.registry[typ.fqtn]
    elseif typ._tag == "Type.Record" or typ._tag == "Type.Union"
        or typ._tag == "Type.Interface" then
        return typ
    end
end

function generic_parameter_arguments(owner)
    local arguments = {}
    if owner and owner.scope ~= nil then
        for index, typeparam in ipairs(owner.typeparams or {}) do
            arguments[index] = owner._generic_parameters
                and owner._generic_parameters[index]
                or types.Parameter(owner.scope, index, typeparam.name, nil)
        end
    end
    return arguments
end

function generic_substitute(typ, scope, arguments, errors, loc, subject)
    local ok, result = pcall(types.substitute, typ, scope, arguments)
    if ok then return result end
    checker.typeerror(errors, loc, "%s: %s", subject, tostring(result))
    return nil
end

function generic_applied_owner_view(nominal, errors, loc)
    local owner = generic_owner_type(nominal)
    if not owner or owner.scope == nil then return owner end
    local arguments = nominal.args or {}
    if #arguments ~= #(owner.typeparams or {}) then return owner end
    local ok, view = pcall(types.substitute, owner, owner.scope, arguments)
    if ok then return view end
    if errors and loc then
        checker.typeerror(errors, loc,
            "cannot form applied type '%s': %s",
            types.tostring(nominal), tostring(view))
    end
    return owner
end

function generic_interface_implementation(
        concrete, interface, policy)
    return types.generic_interface_implementation(concrete, interface, policy)
end

function generic_constraint_satisfied(
        argument, constraint, st, policy)
    if argument._tag == "Type.Parameter" then
        local bindings = policy and policy.generic_scope_bindings
            or (st and st.generic_scope_bindings)
        local surface, valid = types.parameter_surface_constraint(argument, bindings)
        return valid and surface ~= nil
            and types.equals(surface, constraint)
    elseif argument._tag ~= "Type.Nominal" then
        return false
    elseif types.equals(argument, constraint) then
        return true
    end

    local concrete = generic_owner_type(argument)
    local interface = generic_owner_type(constraint)
    if not concrete or not interface
        or (concrete._tag ~= "Type.Record" and concrete._tag ~= "Type.Union")
        or interface._tag ~= "Type.Interface" then
        return false
    end
    if concrete._generic_header or interface._generic_header
       or (st and st.generic_signatures_incomplete) then
        return nil -- method sets are not complete yet; validate after signatures
    end
    concrete = generic_applied_owner_view(argument)
    interface = generic_applied_owner_view(constraint)
    if not policy then
        policy = {
            visibility = st.modname,
            method_visible = function(method)
                return is_nominal_member_visible_from(st, method)
            end,
            field_visible = function(field)
                return is_nominal_member_visible_from(st, field)
            end,
        }
    end
    local implementation = generic_interface_implementation(
        concrete, interface, policy)
    return implementation ~= nil
end

function generic_defer_constraint_application(
        scope, typeparams, arguments, st, loc, subject)
    st.pending_generic_constraints = st.pending_generic_constraints or {}
    st.pending_generic_constraints[#st.pending_generic_constraints + 1] = {
        scope = scope,
        typeparams = typeparams,
        arguments = arguments,
        loc = loc,
        subject = subject,
    }
end

function generic_validate_binder_arguments(scope, typeparams, arguments,
                                         st, errors, loc, subject,
                                         allow_defer)
    local valid, argument_error =
        types.validate_type_arguments(typeparams or {}, arguments or {})
    if not valid then
        checker.typeerror(errors, loc, "%s %s", subject, argument_error)
        return false
    end

    -- Owner headers share their dense type-parameter list with the later
    -- completed descriptor. While those headers' constraints are being
    -- resolved, even a currently unconstrained entry may acquire its real
    -- constraint later in the same reservation pass. Queue the whole
    -- application once and validate it only after all declarations and method
    -- sets are complete.
    if allow_defer and st.resolving_generic_owner_constraints
       and #(typeparams or {}) > 0 then
        generic_defer_constraint_application(
            scope, typeparams, arguments, st, loc, subject)
        return true
    end

    local ok = true
    local deferred = false
    for index, typeparam in ipairs(typeparams or {}) do
        if typeparam.constraint ~= nil then
            local constraint = typeparam.constraint
            if scope ~= nil then
                constraint = generic_substitute(
                    constraint, scope, arguments, errors, loc, subject)
                    or constraint
            end
            local satisfied = generic_constraint_satisfied(
                arguments[index], constraint, st)
            if satisfied == nil and allow_defer then
                deferred = true
            elseif not satisfied then
                checker.typeerror(errors, loc,
                    "type argument %d ('%s') for %s does not satisfy constraint '%s'",
                    index, types.tostring(arguments[index]), subject,
                    types.tostring(constraint))
                ok = false
            end
        end
    end
    if deferred then
        generic_defer_constraint_application(
            scope, typeparams, arguments, st, loc, subject)
    end
    return ok
end

function generic_resolve_type_argument_nodes(nodes, st, errors)
    local arguments = {}
    for index, typenode in ipairs(nodes or {}) do
        local argument = typefromnode(typenode, st, errors)
        -- Runtime lowering clears the public generic syntax lists, but source
        -- tooling still needs the exact checked application (including
        -- aliases and parameters from another generic scope). Keep that
        -- resolved surface type beside the retained syntax node instead of
        -- asking clients to reconstruct checker semantics from the AST.
        typenode._resolved_typearg = argument
        arguments[index] = argument
    end
    return arguments
end

function generic_validate_owner_reconstruction(
        owner, arguments, st, errors, loc, subject, allow_defer)
    if owner.scope == nil then return true end
    if allow_defer and (owner._generic_header
            or (st and st.generic_signatures_incomplete)) then
        st.pending_generic_reconstructions =
            st.pending_generic_reconstructions or {}
        st.pending_generic_reconstructions[
            #st.pending_generic_reconstructions + 1] = {
                fqtn = owner.name,
                arguments = arguments,
                loc = loc,
                subject = subject,
            }
        return true
    end
    local closed = generic_substitute(
        owner, owner.scope, arguments, errors, loc,
        "cannot form " .. subject)
    return closed ~= nil
end

function generic_application_arguments(
        typearg_nodes, count, st, errors)
    if #(typearg_nodes or {}) == 0 and count > 0 then
        local arguments = {}
        for index = 1, count do arguments[index] = types.Value() end
        return arguments
    end
    return generic_resolve_type_argument_nodes(
        typearg_nodes, st, errors)
end

function generic_apply_named_owner(
        owner, typearg_nodes, st, errors, loc, subject)
    local count = #(owner.typeparams or {})
    local arguments = generic_application_arguments(
        typearg_nodes, count, st, errors)

    if #arguments ~= count then
        checker.typeerror(errors, loc,
            "%s expected %d type arguments but found %d",
            subject, count, #arguments)
        return types.Nominal(owner.name, arguments)
    end
    local valid = generic_validate_binder_arguments(
        owner.scope, owner.typeparams, arguments,
        st, errors, loc, subject, true)
    if valid then
        generic_validate_owner_reconstruction(
            owner, arguments, st, errors, loc, subject, true)
    end
    return types.Nominal(owner.name, arguments)
end

function generic_apply_generic_alias(
        alias, typearg_nodes, st, errors, loc, subject)
    local owner = types.registry[alias.target_owner_fqtn]
    if not owner or (owner._tag ~= "Type.Record"
            and owner._tag ~= "Type.Union"
            and owner._tag ~= "Type.Interface") then
        return invalid(errors, loc,
            "%s does not have a recoverable nominal owner", subject)
    end

    local count = #(owner.typeparams or {})
    local arguments = generic_application_arguments(
        typearg_nodes, count, st, errors)
    if #arguments ~= count then
        return invalid(errors, loc,
            "%s expected %d type arguments but found %d",
            subject, count, #arguments)
    end
    local valid = generic_validate_binder_arguments(
        owner.scope, owner.typeparams, arguments,
        st, errors, loc, subject, true)
    if valid then
        generic_validate_owner_reconstruction(
            owner, arguments, st, errors, loc, subject, true)
    end
    return types.Nominal(owner.name, arguments)
end

-- Record how a type-only alias reaches its canonical runtime namespace.  A
-- forwarding alias leaves the owner's binders open; a concrete alias fixes
-- them once and cannot be applied again.
function generic_annotate_alias_namespace(node, alias_type, namespace)
    node._alias_namespace = true
    local owner, arguments, fixed
    if alias_type and alias_type._tag == "Type.GenericAlias" then
        owner = types.registry[alias_type.target_owner_fqtn]
        arguments = nil
        fixed = false
    elseif alias_type and alias_type._tag == "Type.Nominal" then
        owner = types.registry[alias_type.fqtn]
        arguments = alias_type.args or {}
        fixed = owner ~= nil and #(owner.typeparams or {}) > 0
    end
    if not owner and namespace and (namespace._tag == "Type.Record"
            or namespace._tag == "Type.Union") then
        owner = namespace.scope ~= nil and namespace
            or types.registry[namespace.name]
    end
    if owner then
        node._generic_namespace_owner = owner
        node._generic_namespace_arguments = arguments
        node._generic_namespace_fixed = fixed and true or false
    end
end

-- Close the explicit application attached to a record/union namespace before
-- selecting its constructor or nominal function.  The selected expression
-- retains the canonical owner separately so the later code-facing lowering
-- still sees the shared generic declaration.
function generic_apply_namespace_typeargs(exp, st, errors)
    local nodes = exp._nominal_typeargs
    if nodes == nil then return exp._type end
    local variable = exp._tag == "Ast.ExpVar" and exp.var or nil
    local owner = variable and variable._generic_namespace_owner or nil
    local typ = exp._type
    if not owner and typ and (typ._tag == "Type.Record"
            or typ._tag == "Type.Union") then
        owner = typ.scope ~= nil and typ or types.registry[typ.name]
    end

    if not variable or not owner
       or (owner._tag ~= "Type.Record" and owner._tag ~= "Type.Union") then
        checker.typeerror(errors, exp._nominal_typeargs_loc or exp.loc,
            "type arguments can only be attached to a record or union namespace")
        return typ
    elseif variable._generic_namespace_fixed then
        checker.typeerror(errors, exp._nominal_typeargs_loc or exp.loc,
            "concrete type alias namespace '%s' cannot receive type arguments",
            variable.name)
        variable._written_nominal_typeargs = true
        return typ
    end

    local subject = "nominal namespace '" .. (variable.name or owner.name) .. "'"
    local nominal = generic_apply_named_owner(
        owner, nodes, st, errors,
        exp._nominal_typeargs_loc or exp.loc, subject)
    local closed = generic_applied_owner_view(
        nominal, errors, exp._nominal_typeargs_loc or exp.loc) or owner
    variable._generic_namespace_owner = owner
    variable._generic_namespace_arguments = nominal.args or {}
    variable._generic_namespace_fixed = true
    variable._generic_namespace_explicit = true
    variable._written_nominal_typeargs = true
    variable._type = closed
    exp._type = closed
    return closed
end

function generic_resolve_local_owner(name, st)
    local declaration = st:find_symbol(name)
    if declaration and (declaration._tag == "Ast.TopLevelRecord"
            or declaration._tag == "Ast.TopLevelUnion") then
        return declaration._type
    end
    local interface = st.interface_declarations
        and st.interface_declarations[name]
    if interface then return interface._type end
    return types.registry[st.modname .. "." .. name]
end

function checker._foreign_signature_component(
        typenode, st, errors, subject, allow_void)
    local typ = typefromnode(typenode, st, errors, true)
    local resolved = c_resolve(typ)
    if typ._tag == "Type.Invalid" then return typ end
    if not types.is_direct_c(typ) or not resolved
       or resolved._tag == "Type.CModule"
       or resolved._tag == "Type.COwned"
       or resolved._tag == "Type.CFunction"
       or resolved._tag == "Type.CArray"
       or (resolved._tag == "Type.CVoid" and not allow_void) then
        return invalid(errors, typenode.loc,
            "%s must be a direct C FFI type%s, not '%s'",
            subject, allow_void and "" or " other than void",
            types.tostring(typ))
    end
    return typ
end

function checker._foreign_function_signature(
        argnodes, rettypenodes, varargtype, flexrettype,
        st, errors, subject)
    local params = {}
    for index, typenode in ipairs(argnodes) do
        params[index] = checker._foreign_signature_component(
            typenode, st, errors,
            string.format("parameter %d of %s", index, subject), false)
    end

    if varargtype then
        checker.typeerror(errors, type(varargtype) == "table" and varargtype.loc
            or argnodes[1] and argnodes[1].loc
            or rettypenodes[1] and rettypenodes[1].loc
            or { filename = st.filename, line = 1, col = 1 },
            "%s cannot have variadic parameters", subject)
    end
    if flexrettype then
        checker.typeerror(errors, flexrettype.loc,
            "%s cannot have flexible returns", subject)
    end
    if #rettypenodes > 1 then
        checker.typeerror(errors, rettypenodes[2].loc,
            "%s can return at most one value", subject)
    end

    local ret = types.CVoid()
    if rettypenodes[1] then
        ret = checker._foreign_signature_component(
            rettypenodes[1], st, errors,
            "return type of " .. subject, true)
    end
    return types.CFunction(params, ret, false, nil)
end

return core.checker
