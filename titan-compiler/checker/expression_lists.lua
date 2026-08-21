local core = require "titan-compiler.checker.core"
local _ENV = core

-- Expression-list demand.  `fixed` is always dense: UNKNOWN_SLOT represents a
-- position whose type is not known yet (notably an inferred local).  `tail` is
-- false for a finite consumer, a Type.* value for an open typed consumer, or
-- INFER_OPEN for an open consumer whose element type is inferred from its
-- inputs.  Keeping the sentinels as real table values is important: using nil
-- for an unknown slot would make Lua's length operator collapse the demand.
UNKNOWN_SLOT = {}

INFER_OPEN = {}

TITAN_VARARG_MAX = 200

-- Lua 5.5 stores a finite VM result request in the current CallInfo's
-- CIST_NRESULTS field.  `MAXRESULTS` is therefore an independent boundary from
-- Titan's 200-element flexible descriptor: a finite generic function-value
-- call may not ask the VM for more results than this. Statically open generic
-- calls use LUA_MULTRET and do not cross the finite-result encoding boundary.
LUA_VM_MAX_RESULTS = 250

function result_demand(fixed, tail, opts)
    opts = opts or {}
    return {
        fixed = fixed or {},
        tail = tail or false,
        missing = opts.missing or "error",
        explicit_surplus = opts.explicit_surplus or "discard",
        term = opts.term or "expression list",
        slot_term = opts.slot_term,
        loc = opts.loc,
        open_term = opts.open_term,
        return_arity = opts.return_arity,
        open_coerce = opts.open_coerce,
        check_expression = opts.check_expression,
        dots_limit = opts.dots_limit,
        dots_nilfill = opts.dots_nilfill,
        defer_open_check = opts.defer_open_check,
        suppress_flex_cap = opts.suppress_flex_cap,
        -- Ordinary consumers keep UNKNOWN_SLOT nonsemantic. Generic discovery
        -- may additionally preserve its unresolved pattern here so a direct
        -- contextual call through `value` can publish provisional result
        -- evidence and close that AST-owned operation with the ambient use.
        inference_fixed = opts.inference_fixed,
        inference_tail = opts.inference_tail,
    }
end

function expected_type(typ)
    if typ == UNKNOWN_SLOT or typ == INFER_OPEN then
        return nil
    end
    return typ
end

-- Build a structural function result shape from the same demand vocabulary
-- used by expression-list adjustment. Unknown finite/open slots become
-- `value`; a typed open slot is validated as a flexible-return descriptor at
-- the sink location. Generic-for and ordinary calls through `value` share this
-- constructor so their contextual function types cannot drift apart.
function synthesize_function_type(params, varargtype, demand, loc,
                                        errors)
    local rettypes = {}
    for i, target in ipairs(demand.fixed) do
        -- A generic discovery slot remains unknown to ordinary expression
        -- checking, but a contextual `value` call is itself the producer of
        -- that slot. Preserve the fresh inference pattern provisionally so a
        -- later sibling can close it before code-facing annotations freeze.
        rettypes[i] = expected_type(target)
            or (demand.inference_fixed and demand.inference_fixed[i])
            or types.Value()
    end

    local flexrettype = false
    if demand.tail then
        flexrettype = expected_type(demand.tail)
            or demand.inference_tail
            or types.Value()
        flexrettype = check_varg_elem(flexrettype,
            demand.loc or loc, errors, "return")
    end

    return types.Function(params, rettypes, false, varargtype or false,
        flexrettype)
end

function demand_term(demand, index)
    if demand.slot_term then
        return demand.slot_term(index)
    end
    return demand.term
end

function mark_discarded(exp)
    exp._discard_results = true
    if exp._tag == "Ast.ExpCall" then
        exp._voidok = true
    end
end

function coerce_demanded_value(exp, target, term, errors)
    target = expected_type(target)
    if not target then return exp end
    local source = exp
    exp = coerce_and_check(exp, target, term, errors, exp.loc)
    if source._missing_value then exp._missing_value = true end
    return exp
end

function remaining_demand(demand, first)
    local fixed, inference_fixed = {}, {}
    for i = first, #demand.fixed do
        table.insert(fixed, demand.fixed[i])
        table.insert(inference_fixed,
            demand.inference_fixed and demand.inference_fixed[i] or false)
    end
    return result_demand(fixed, demand.tail, {
        missing = demand.missing,
        explicit_surplus = demand.explicit_surplus,
        term = demand.term,
        slot_term = demand.slot_term and function(i)
            return demand.slot_term(first + i - 1)
        end or nil,
        loc = demand.loc,
        open_term = demand.open_term,
        return_arity = demand.return_arity,
        open_coerce = demand.open_coerce,
        check_expression = demand.check_expression,
        dots_limit = demand.dots_limit,
        dots_nilfill = demand.dots_nilfill,
        defer_open_check = demand.defer_open_check,
        suppress_flex_cap = demand.suppress_flex_cap,
        inference_fixed = inference_fixed,
        inference_tail = demand.inference_tail,
    })
end

-- Return the finite values made visible by checking `exp` under its demand.
-- Calls publish a consumer-visible projection separately from their declared
-- ABI result list; every other expression is scalar.
function finite_result_expressions(exp)
    if exp._tag ~= "Ast.ExpCall" then
        return { exp }
    end

    local visible = exp._visible_types or exp._types or {}
    local out = {}
    for i, typ in ipairs(visible) do
        local value
        if i == 1 then
            value = exp
        else
            value = ast.ExpExtra(exp.loc, exp, i, typ)
        end
        local source = exp._result_sources and exp._result_sources[i]
        if source then
            value._result_source = source
            if source.kind == "flex" then
                value._from_flex = true
                value._possibly_absent = source.may_absent and true or false
            end
        end
        table.insert(out, value)
    end
    return out
end

-- Check and elaborate one expression list under a finite/open demand.  The
-- returned `exps` preserves every written expression in lexical order; extra
-- fixed projections are synthesized after the trailing producer, while
-- explicit surplus expressions remain present and are marked for effect-only
-- lowering.  `fixed` and `tail_scalars` describe the values delivered to the
-- sink, and `open_source` identifies the sole possible runtime-sized final run.
function adjust_explist(exps, demand, st, errors)
    local adjusted = {
        exps = {},
        fixed = {},
        tail_scalars = {},
        discards = {},
        open_source = false,
        open_type = false,
        open_target = false,
        open_start = false,
        open_adjustment = false,
    }
    local next_fixed = 1

    local function current_target()
        if next_fixed <= #demand.fixed then
            return demand.fixed[next_fixed], false
        elseif demand.tail then
            return demand.tail, true
        end
        return nil, false
    end

    local function accept(exp, target, intail)
        local index = next_fixed
        local term = intail and demand.term or demand_term(demand, index)
        exp = coerce_demanded_value(exp, target, term, errors)
        if intail then
            exp._demand_tail = true
            table.insert(adjusted.tail_scalars, exp)
        else
            exp._demand_slot = index
            adjusted.fixed[index] = exp
            next_fixed = next_fixed + 1
        end
        return exp
    end

    local function discard(exp, explicit)
        mark_discarded(exp)
        table.insert(adjusted.discards, exp)
        if explicit and demand.explicit_surplus == "error" then
            adjusted.explicit_surplus = (adjusted.explicit_surplus or 0) + 1
        end
        return exp
    end

    local n = #exps
    local last = exps[n]
    local has_dots = last and last._tag == "Ast.ExpDots"

    local function check_expression(exp, context, subdemand, sink_index)
        if demand.check_expression then
            demand.check_expression(exp, st, errors, context, subdemand,
                sink_index)
        else
            checkexp(exp, st, errors, context, subdemand)
        end
    end

    -- Every non-final expression is scalar.  Once the finite prefix is full it
    -- contributes one tail scalar, or is retained under a zero-result demand.
    for i = 1, math.max(n - 1, 0) do
        local exp = exps[i]
        local target, intail = current_target()
        local subdemand
        if target then
            local inference_target = intail and demand.inference_tail
                or (demand.inference_fixed
                    and demand.inference_fixed[next_fixed])
            subdemand = result_demand({ target }, false, {
                term = demand_term(demand, next_fixed),
                inference_fixed = { inference_target or false },
            })
        else
            subdemand = result_demand({}, false, { term = demand.term })
            mark_discarded(exp)
        end
        check_expression(exp, expected_type(target), subdemand, next_fixed)
        if target then
            exp = accept(exp, target, intail)
        else
            exp = discard(exp, true)
        end
        table.insert(adjusted.exps, exp)
    end

    if has_dots then
        check_dots_marker(last, st, errors)
        local elem = last._vararg_elem
        local projection = 1
        -- Some structured finite consumers deliberately use fewer elements of
        -- a trailing `...` than their padded storage width. Generic `for`, for
        -- example, borrows only the iterator's state/control inputs unless the
        -- source explicitly reaches the optional close slot; its fourth tuple
        -- position is then synthesized as nil. The callback runs after every
        -- written prefix expression has been checked, so it can inspect the
        -- iterator's resolved function type without a separate checking pass.
        local dots_limit = demand.dots_limit
            and demand.dots_limit(exps) or #demand.fixed
        while next_fixed <= #demand.fixed and next_fixed <= dots_limit do
            local target = demand.fixed[next_fixed]
            local target_type = expected_type(target)
            local index = ast.ExpInteger(last.loc, projection)
            index._type = types.Integer()
            local exp = ast.ExpDotsIndex(last.loc, index)
            local forced_nilfill = demand.dots_nilfill
            if type(forced_nilfill) == "function" then
                forced_nilfill = forced_nilfill(next_fixed, target_type)
            end
            local nilfill = forced_nilfill
                or (target_type and nil_can_adjust_to(target_type))
            exp._nilfill = nilfill and true or false
            exp._type = nilfill and optionize(elem) or elem
            exp._from_dots = true
            exp._dots_index = projection
            exp = accept(exp, target, false)
            table.insert(adjusted.exps, exp)
            projection = projection + 1
        end
        if demand.tail then
            last._open_dots = {
                source_type = elem,
                target_type = expected_type(demand.tail) or elem,
                start = projection,
            }
            adjusted.open_source = last
            adjusted.open_type = elem
            adjusted.open_target = expected_type(demand.tail) or elem
            adjusted.open_start = projection
            table.insert(adjusted.exps, last)
        elseif projection == 1 then
            discard(last, true)
        end
    elseif last then
        local target = current_target()
        local subdemand = remaining_demand(demand, next_fixed)
        if not target and not demand.tail then
            mark_discarded(last)
        end
        check_expression(last, expected_type(target), subdemand, next_fixed)
        table.insert(adjusted.exps, last)

        local values = finite_result_expressions(last)
        if #values == 0 then
            -- A flex-only producer has no finite scalar but its dynamic run is
            -- the value consumed by an open sink. Do not simultaneously mark
            -- that same call as effect-only/discarded. A statically zero-result
            -- fixed producer has no open run and remains an effect-only entry.
            if not last._open_results then
                discard(last, target == nil and not demand.tail)
            end
        else
            for i, exp in ipairs(values) do
                local value_target, intail = current_target()
                if value_target then
                    exp = accept(exp, value_target, intail)
                    if i == 1 then
                        adjusted.exps[#adjusted.exps] = exp
                    else
                        table.insert(adjusted.exps, exp)
                    end
                elseif i == 1 then
                    adjusted.exps[#adjusted.exps] = discard(exp, true)
                end
            end
        end

        if last._open_results then
            adjusted.open_source = last
            adjusted.open_type = last._open_results.source_type
            adjusted.open_target = last._open_results.target_type
            adjusted.open_start = last._open_results.start
        end
    end

    if next_fixed <= #demand.fixed then
        adjusted.missing = #demand.fixed - next_fixed + 1
        if demand.missing == "nil" then
            while next_fixed <= #demand.fixed do
                local exp = ast.ExpNil(last and last.loc or demand.loc)
                exp._type = types.Nil()
                exp._missing_value = true
                exp = accept(exp, demand.fixed[next_fixed], false)
                table.insert(adjusted.exps, exp)
            end
        elseif demand.missing ~= "ignore" then
            if demand.return_arity then
                checker.typeerror(errors, last and last.loc or demand.loc,
                    "returned %d value(s) but function expected %d",
                    next_fixed - 1, #demand.fixed)
            else
                checker.typeerror(errors, last and last.loc or demand.loc,
                    "%s expects %d value(s) but the expression list produces %d",
                    demand.term, #demand.fixed, next_fixed - 1)
            end
        end
    end


    -- A deferred open consumer has not selected its final element type yet.
    -- In particular, inferred positional constructors deoptionize the
    -- producer type below. Do not classify a provisional edge and then
    -- overwrite its plan: the eventual sink must own exactly one
    -- assignment_adjustment call and one stored plan.
    local allow_open_coercion = adjusted.open_source
        and not demand.defer_open_check
        and (adjusted.open_source._tag ~= "Ast.ExpDots"
             or demand.open_coerce)
    local open_adjustment, open_interface_conversion,
        open_interface_failure
    if adjusted.open_source and not demand.defer_open_check then
        open_adjustment, open_interface_conversion,
            open_interface_failure =
            checker_assignment_adjustment(
                adjusted.open_type, adjusted.open_target, st, {
                -- Flexible call results are converted element-wise by their
                -- sink. Preserve the input-`...` contract: forwarding a whole
                -- descriptor does not silently lift a scalar coercion.
                allow_coercion = allow_open_coercion and true or false,
            })
    end
    adjusted.open_adjustment = open_adjustment or false
    adjusted.open_callable_adapter = open_adjustment
        and open_adjustment.kind == "callable"
        and checker.freeze_callable_adapter(
            open_adjustment, adjusted.open_type,
            adjusted.open_target, adjusted.open_source.loc)
        or false
    adjusted.open_interface_conversion =
        open_interface_conversion or false
    if adjusted.open_source and not demand.defer_open_check then
        local open = adjusted.open_source._tag == "Ast.ExpDots"
            and adjusted.open_source._open_dots
            or adjusted.open_source._open_results
        if open then
            open.adjustment = adjusted.open_adjustment
            open.callable_adapter = adjusted.open_callable_adapter
        end
    end
    if adjusted.open_source and not demand.defer_open_check
       and adjusted.open_type._tag ~= "Type.Invalid"
       and adjusted.open_target._tag ~= "Type.Invalid"
       and not open_adjustment then
        if report_interface_failure(
                errors, adjusted.open_source.loc,
                open_interface_failure) then
            -- The ordered implementation matcher already described the first
            -- failing Interface method.
        elseif adjusted.open_source._tag == "Ast.ExpDots" then
            checker.typeerror(errors, adjusted.open_source.loc,
                "'...' element type %s is not compatible with the '...' element type %s of %s",
                types.tostring(adjusted.open_type),
                types.tostring(adjusted.open_target),
                demand.open_term or demand.term)
        else
            checker.typeerror(errors, adjusted.open_source.loc,
                "open result element type %s is not compatible with %s element type %s",
                types.tostring(adjusted.open_type), demand.term,
                types.tostring(adjusted.open_target))
        end
    end

    return adjusted
end

function replace_adjusted_value(adjusted, old, new)
    if old == new then return end
    for i, exp in ipairs(adjusted.exps) do
        if exp == old then
            adjusted.exps[i] = new
            break
        end
    end
    for i = 1, #adjusted.fixed do
        if adjusted.fixed[i] == old then adjusted.fixed[i] = new end
    end
    for i, exp in ipairs(adjusted.tail_scalars) do
        if exp == old then adjusted.tail_scalars[i] = new end
    end
end

function constructor_field_kind(field)
    -- Parser-built positional fields use false; synthesized fields may use nil.
    if not field.name then
        return "positional"
    elseif type(field.name) == "table" then
        return "computed"
    else
        return "named"
    end
end

-- Classify an initializer before checking any of its expressions. This keeps a
-- positional field away from the computed-Map key path (where a nil key used to
-- reach checkexp), and makes every mixed ordering fail in the same deliberate
-- way. A bare `...` is positional, but it must be the sole trailing open
-- producer.
function classify_constructor_fields(node, errors)
    local seen, kinds = {}, {}
    local dots_field
    local invalid_dots = false

    for i, field in ipairs(node.fields) do
        local kind = constructor_field_kind(field)
        if not seen[kind] then
            seen[kind] = true
            table.insert(kinds, kind)
        end
        if kind == "positional" and field.exp._tag == "Ast.ExpDots" then
            if dots_field then
                checker.typeerror(errors, field.loc,
                    "'...' can appear only once in a positional constructor")
                invalid_dots = true
            else
                dots_field = field
            end
            if i ~= #node.fields then
                checker.typeerror(errors, field.loc,
                    "'...' must be the last field in a positional constructor")
                invalid_dots = true
            end
        end
    end

    if #kinds == 0 then
        return "empty", kinds, dots_field, invalid_dots
    elseif #kinds == 1 then
        return kinds[1], kinds, dots_field, invalid_dots
    else
        return "mixed", kinds, dots_field, invalid_dots
    end
end

-- Check every written expression of a constructor that has already been
-- rejected for its field shape. This preserves scope/name diagnostics without
-- routing a bare trailing `...` through its scalar-only checkexp arm.
function check_rejected_constructor_fields(node, st, errors, context)
    local value_context
    local key_context
    if context and context._tag == "Type.Array" then
        value_context = context.elem
    elseif context and context._tag == "Type.Map" then
        key_context = context.keys
        value_context = context.values
    end

    for _, field in ipairs(node.fields) do
        local kind = constructor_field_kind(field)
        if kind == "positional" and field.exp._tag == "Ast.ExpDots" then
            check_dots_marker(field.exp, st, errors)
        else
            if kind == "computed" then
                checkexp(field.name, st, errors, key_context)
            end
            checkexp(field.exp, st, errors, value_context)
        end
    end
end

function positional_initializer_term(container_tag)
    if container_tag == "Type.Array" then
        return "array initializer"
    else
        return "positional map initializer"
    end
end

-- Freeze the construction-time Lua writer policy after contextual element
-- adjustment has selected the Array's final type.  The coder consumes these
-- annotations verbatim; it must not re-run a semantic relation from the
-- emitted Array type.  Raw C pointers (and compound types containing one)
-- deliberately have no DynamicCoercionPlan, so an Array that would need such
-- a writer is rejected at its construction site.
function annotate_array_writer(node, elem, errors)
    local normalized = types.normalize(elem)
    if not normalized then
        node._array_element_type = types.Invalid()
        node._array_writer_plan = false
        return
    end
    node._array_element_type = normalized
    local writer_type = generic_runtime_carrier(normalized)
    node._array_writer_plan = types.dynamic_coercion(writer_type) or false
    if writer_type ~= normalized then
        node._generic_array_writer_type = writer_type
    end
    if node._array_writer_plan == false
       and normalized._tag ~= "Type.Invalid" then
        checker.typeerror(errors, node.loc,
            "cannot construct an array with element type %s because genuine "
            .. "Lua writes have no sound dynamic coercion for that type",
            types.tostring(normalized))
    end
end

-- Arrays and positional integer-keyed Maps are the same kind of open
-- expression-list consumer. The checker elaboration is intentionally
-- representation-neutral; code generation decides whether the sink is a
-- private Array backing or an ordinary Map Table.
function generic_constructor_context_for_expression(operation, pattern, exp)
    if not pattern then return nil end
    if not operation then return pattern end
    local context = operation.context
    local closed = generic_closed_inference_pattern(context, pattern)
    if closed then return closed end
    -- Only another constructor can consume an unresolved structural owner as
    -- an ordinary expected type without freezing an adjustment. Other
    -- expressions contribute their provisional types through explicit
    -- constructor evidence below; a contextual `value` call separately sees
    -- the pattern through its nonsemantic inference demand.
    if exp._tag == "Ast.ExpInitList" then
        return generic_substitute_inference(context, pattern, false)
    end
    return nil
end

function generic_constructor_result_demand(
        expected, demand, operation, pattern)
    local provisional = operation and pattern and
        generic_substitute_inference(
            operation.context, pattern, false) or false
    if not expected and not provisional then return demand end

    local fixed, inference_fixed = {}, {}
    for index, target in ipairs(demand.fixed or {}) do
        fixed[index] = expected or target
        inference_fixed[index] = provisional
            or (demand.inference_fixed
                and demand.inference_fixed[index])
            or false
    end
    local tail = demand.tail and (expected or demand.tail) or false
    local inference_tail = demand.tail and
        (provisional or demand.inference_tail) or false
    return result_demand(fixed, tail, {
        term = demand.term,
        loc = demand.loc,
        missing = demand.missing,
        explicit_surplus = demand.explicit_surplus,
        open_coerce = demand.open_coerce,
        defer_open_check = demand.defer_open_check,
        inference_fixed = inference_fixed,
        inference_tail = inference_tail,
    })
end

function generic_dependent_scalar_demand(
        operation, pattern, expected, term, loc)
    -- Preserve the ordinary default demand (and its diagnostics) whenever a
    -- real expected type exists. This side channel exists only for an
    -- unresolved dependent field/key/value; every expression except a direct
    -- contextual `value` call continues to treat the slot as unknown.
    if expected or not operation or not pattern then return nil end
    local provisional = generic_substitute_inference(
        operation.context, pattern, false)
    return result_demand({ UNKNOWN_SLOT }, false, {
        term = term,
        loc = loc,
        inference_fixed = { provisional },
    })
end

function generic_constructor_unify(operation, pattern, evidence, term, loc)
    if not operation or not pattern or not evidence then return end
    generic_unify_inference(
        operation.context, pattern, evidence, term, loc)
    generic_infer_constraint_evidence(operation.context)
end

function generic_constructor_expression_needs_context(
        exp, st, errors)
    if exp._tag == "Ast.ExpFunction" then
        local nparams = #exp.params
        local vararg = exp.params[nparams]
        local has_vararg = vararg and vararg.name == false
        local nfixed = has_vararg and nparams - 1 or nparams
        for index = 1, nfixed do
            if not exp.params[index].type then return true end
        end
        if has_vararg and not vararg.type then return true end
        return type(exp.rettypes) ~= "table"
    elseif exp._tag == "Ast.ExpMethodRef" then
        return false
    elseif exp._tag == "Ast.ExpInitList" then
        local shape = classify_constructor_fields(exp, {})
        if shape == "empty" or shape == "named" then return true end
        if shape == "computed" then
            for _, field in ipairs(exp.fields) do
                if generic_constructor_expression_needs_context(
                        field.name, st, errors)
                   or generic_constructor_expression_needs_context(
                        field.exp, st, errors) then
                    return true
                end
            end
            return false
        end
        if shape ~= "positional" then return false end
        -- A nested positional constructor has independent shape evidence only
        -- when at least one delivered component does. Recurse syntactically so
        -- an all-contextual subtree remains pending as a whole; every probe
        -- transfers any completed receiver/variable descent to its eventual
        -- one real check.
        for _, field in ipairs(exp.fields) do
            if field.exp._tag == "Ast.ExpDots"
               or not generic_constructor_expression_needs_context(
                    field.exp, st, errors) then
                return false
            end
        end
        return true
    elseif exp._tag == "Ast.ExpVar" then
        -- A generic first-class value can register its own open occurrence now;
        -- the enclosing constructor then relates that function-shaped equation
        -- to later context without closing its local cells prematurely.
        return false
    elseif exp._tag == "Ast.ExpCall" then
        local callee = exp.exp
        if callee._tag == "Ast.ExpVar" then
            generic_precheckvar_for_expression(
                callee, st, errors, c_pseudo_callee_context)
            callee._type = callee.var._type
        elseif not exp._generic_callee_prechecked then
            checkexp(callee, st, errors)
            exp._generic_callee_prechecked = true
        end
        local typ = callee._type
        return typ and typ._tag == "Type.Value" or false
    end
    return false
end

function generic_defer_contextual_constructor_component(
        operation, exp, pattern, st, errors, term, demand)
    if not operation or not pattern
       or generic_closed_inference_pattern(
            operation.context, pattern) then
        return nil
    end

    local contextual = false
    if exp._tag == "Ast.ExpFunction" then
        generic_prepare_lambda_inference(
            exp, pattern, operation.context, st, errors)
        contextual = not generic_lambda_full_explicit_type(exp)
    end
    if not contextual then return nil end

    local item = {
        exp = exp,
        pattern = pattern,
        demand = demand,
        term = term,
        checked = false,
    }
    exp._type = generic_substitute_inference(
        operation.context, pattern, false)

    local function finish(recover)
        if item.checked then return true end
        local expected = recover
            and generic_substitute_inference(
                operation.context, pattern, true)
            or generic_closed_inference_pattern(
                operation.context, pattern)
        if not expected then return false end
        checkexp(exp, st, errors, expected,
            generic_constructor_result_demand(
                expected, demand, operation, pattern))
        item.checked = true
        return true
    end
    item.finish = finish
    generic_add_inference_discovery(operation, function()
        return finish(false)
    end, "evidence")
    return item
end

function generic_close_contextual_constructor_components(adjusted)
    for _, item in ipairs(adjusted._generic_deferred_components or {}) do
        item.finish(true)
    end
    adjusted._generic_deferred_components = nil
    adjusted._generic_deferred_by_exp = nil
end

function generic_substitute_constructor_type(operation, typ, recover)
    if not operation or not typ then return typ end
    return generic_substitute_inference(
        operation.context, typ, recover)
end

function generic_positional_constructor_element_type(
        adjusted, elem_context, operation, recover)
    local etype = elem_context
        or (adjusted.open_type
            and adjusted.open_type._tag ~= "Type.Invalid"
            and deoptionize(adjusted.open_type))
        or (adjusted.tail_scalars[1]
            and deoptionize(adjusted.tail_scalars[1]._type))
        or types.Integer()
    return generic_substitute_constructor_type(operation, etype, recover)
end

function generic_finish_positional_constructor(node, st, errors, container_tag,
                                               keytype, elem_context, adjusted,
                                               operation, array_isconst)
    generic_close_contextual_constructor_components(adjusted)
    if operation then
        generic_refresh_finalized_argument_projections(adjusted)
    end
    local etype = generic_positional_constructor_element_type(
        adjusted, elem_context, operation, true)
    local closed_keytype = generic_substitute_constructor_type(
        operation, keytype, true)

    if container_tag == "Type.Array" then
        node._type = types.Array(etype, array_isconst and true or false)
        annotate_array_writer(node, etype, errors)
    else
        node._type = types.Map(assert(closed_keytype), etype)
    end

    -- An AST-owned inference operation deliberately checked its written
    -- expressions without committing provisional adjustments. Freeze each
    -- scalar now, after child uses and all sibling evidence have closed.
    if operation or not elem_context then
        local term = positional_initializer_term(container_tag)
        for i, exp in ipairs({ table.unpack(adjusted.tail_scalars) }) do
            if exp._type._tag ~= "Type.Invalid" then
                local old = exp
                exp = coerce_and_check(exp, etype,
                    term .. " at position " .. i, errors, exp.loc)
                replace_adjusted_value(adjusted, old, exp)
            end
        end
    end

    if adjusted.open_source then
        local source = generic_substitute_constructor_type(
            operation, adjusted.open_type, true)
        adjusted.open_type = source
        local container_name = container_tag == "Type.Array"
            and "array" or "positional map"
        local open_adjustment, open_interface_conversion,
            open_interface_failure =
            checker_assignment_adjustment(source, etype, st)
        if source._tag ~= "Type.Invalid"
           and not open_adjustment then
            if report_interface_failure(
                    errors, adjusted.open_source.loc,
                    open_interface_failure) then
                -- The matcher emitted the source-level Interface failure.
            elseif adjusted.open_source._tag == "Ast.ExpDots" then
                checker.typeerror(errors, adjusted.open_source.loc,
                    "'...' element type %s is not coerceable to %s element type %s",
                    types.tostring(source), container_name,
                    types.tostring(etype))
            else
                checker.typeerror(errors, adjusted.open_source.loc,
                    "open result element type %s is not coerceable to %s element type %s",
                    types.tostring(source), container_name,
                    types.tostring(etype))
            end
        end
        adjusted.open_target = etype
        adjusted.open_adjustment = open_adjustment or false
        adjusted.open_callable_adapter = open_adjustment
            and open_adjustment.kind == "callable"
            and checker.freeze_callable_adapter(
                open_adjustment, source, etype,
                adjusted.open_source.loc)
            or false
        adjusted.open_interface_conversion =
            open_interface_conversion or false
        if adjusted.open_source._tag == "Ast.ExpCall"
           and adjusted.open_source._open_results then
            adjusted.open_source._open_results.target_type = etype
            adjusted.open_source._open_results.adjustment =
                adjusted.open_adjustment
            adjusted.open_source._open_results.callable_adapter =
                adjusted.open_callable_adapter
        elseif adjusted.open_source._tag == "Ast.ExpDots"
               and adjusted.open_source._open_dots then
            adjusted.open_source._open_dots.target_type = etype
            adjusted.open_source._open_dots.adjustment =
                adjusted.open_adjustment
            adjusted.open_source._open_dots.callable_adapter =
                adjusted.open_callable_adapter
        end
    end

    node.fields = {}
    for _, exp in ipairs(adjusted.exps) do
        table.insert(node.fields, ast.Field(exp.loc, nil, exp))
    end
    node._positional_adjustment = adjusted
end

function check_positional_constructor(node, st, errors, container_tag,
                                              keytype, elem_context, operation,
                                              array_isconst)
    local exps = {}
    for _, field in ipairs(node.fields) do
        assert(constructor_field_kind(field) == "positional")
        table.insert(exps, field.exp)
    end

    local term = positional_initializer_term(container_tag)
    local demand_elem = operation and INFER_OPEN
        or elem_context or INFER_OPEN
    local evidence_pattern = elem_context
    local delivered = 0
    local open_consumed = false
    local deferred_components = {}
    local deferred_by_exp = {}
    local adjusted = adjust_explist(exps,
        result_demand({}, demand_elem, {
            term = term,
            loc = node.loc,
            missing = "error",
            explicit_surplus = "discard",
            open_coerce = true,
            defer_open_check = true,
            check_expression = operation and function(
                    exp, est, eerrors, _, demand)
                local deferred =
                    generic_defer_contextual_constructor_component(
                        operation, exp, elem_context, est, eerrors,
                        term, demand)
                if deferred then
                    deferred_components[#deferred_components + 1] = deferred
                    deferred_by_exp[exp] = deferred
                    return
                end

                local expected = generic_constructor_context_for_expression(
                    operation, elem_context, exp)
                checkexp(exp, est, eerrors, expected,
                    generic_constructor_result_demand(
                        expected, demand, operation, elem_context))

                -- Consume every delivered result at the written expression's
                -- lexical slot. A final call contributes fixed results from
                -- left to right and then its open tail without being checked or
                -- evaluated again.
                local results, open =
                    generic_expression_result_types(exp)
                for _, actual in ipairs(results) do
                    delivered = delivered + 1
                    evidence_pattern = evidence_pattern or deoptionize(actual)
                    generic_constructor_unify(operation,
                        evidence_pattern, deoptionize(actual),
                        term .. " at position " .. delivered, exp.loc)
                end
                if open then
                    evidence_pattern = evidence_pattern or deoptionize(open)
                    generic_constructor_unify(operation,
                        evidence_pattern, deoptionize(open),
                        term .. " open result", exp.loc)
                    open_consumed = true
                end
            end or nil,
        }), st, errors)
    adjusted._generic_deferred_components = deferred_components
    adjusted._generic_deferred_by_exp = deferred_by_exp

    local etype = generic_positional_constructor_element_type(
        adjusted, elem_context, operation, false)
    if operation then
        -- A trailing `...` bypasses the ordinary expression callback. Its open
        -- descriptor still occupies the final lexical delivery position.
        if adjusted.open_source and not open_consumed then
            evidence_pattern = evidence_pattern
                or deoptionize(adjusted.open_type)
            generic_constructor_unify(operation, evidence_pattern,
                deoptionize(adjusted.open_type),
                term .. " open result", adjusted.open_source.loc)
        end
        etype = generic_substitute_constructor_type(operation, etype, false)
        local provisional_key = generic_substitute_constructor_type(
            operation, keytype, false)
        node._type = container_tag == "Type.Array"
            and types.Array(etype, array_isconst and true or false)
            or types.Map(assert(provisional_key), etype)
        node._positional_adjustment = adjusted
        generic_add_inference_finalizer(operation, function()
            generic_finish_positional_constructor(node, st, errors, container_tag,
                keytype, elem_context, adjusted, operation, array_isconst)
        end)
    else
        generic_finish_positional_constructor(node, st, errors, container_tag,
            keytype, elem_context, adjusted, false, array_isconst)
    end
end

function generic_computed_map_constructor_types(
        context, ktypes, vtypes, operation, recover)
    local ktype = context and context.keys
        or (ktypes[1] and deoptionize(ktypes[1]))
        or types.Integer()
    local vtype = context and context.values
        or (vtypes[1] and deoptionize(vtypes[1]))
        or types.Integer()
    return generic_substitute_constructor_type(operation, ktype, recover),
        generic_substitute_constructor_type(operation, vtype, recover)
end

function generic_finish_computed_map_constructor(
        node, errors, context, ktypes, vtypes, operation,
        deferred_components)
    for _, item in ipairs(deferred_components or {}) do item.finish(true) end
    local ktype, vtype = generic_computed_map_constructor_types(
        context, ktypes, vtypes, operation, true)
    node._type = types.Map(ktype, vtype)
    for i, field in ipairs(node.fields) do
        field.name = coerce_and_check(field.name, ktype,
            "map key initializer at position " .. i,
            errors, field.name.loc)
        field.exp = coerce_and_check(field.exp, vtype,
            "map value initializer at position " .. i,
            errors, field.exp.loc)
    end
end

function check_computed_map_constructor(
        node, st, errors, context, operation)
    local kcontext = context and context.keys
    local vcontext = context and context.values
    local ktypes, vtypes = {}, {}
    local key_pattern = kcontext
    local value_pattern = vcontext
    local deferred_components = {}

    for index, field in ipairs(node.fields) do
        assert(constructor_field_kind(field) == "computed")
        local key_demand = generic_dependent_scalar_demand(
            operation, kcontext, nil,
            "map key initializer", field.name.loc)
        local deferred =
            generic_defer_contextual_constructor_component(
                operation, field.name, kcontext, st, errors,
                "map key initializer", key_demand)
        if deferred then
            deferred_components[#deferred_components + 1] = deferred
        else
            local key_expected =
                generic_constructor_context_for_expression(
                    operation, kcontext, field.name)
            checkexp(field.name, st, errors, key_expected,
                generic_dependent_scalar_demand(
                    operation, kcontext, key_expected,
                    "map key initializer", field.name.loc))
        end
        local keytype = field.name._type
        table.insert(ktypes, keytype)
        if operation and not deferred then
            key_pattern = key_pattern or deoptionize(keytype)
            generic_constructor_unify(operation,
                key_pattern, deoptionize(keytype),
                "map key initializer at position " .. index,
                field.name.loc)
        end

        -- A computed field evaluates and contributes its key before its value.
        -- Do not batch all keys ahead of all values: K and V may be the same
        -- inference cell.
        local value_demand = generic_dependent_scalar_demand(
            operation, vcontext, nil,
            "map value initializer", field.exp.loc)
        deferred = generic_defer_contextual_constructor_component(
            operation, field.exp, vcontext, st, errors,
            "map value initializer", value_demand)
        if deferred then
            deferred_components[#deferred_components + 1] = deferred
        else
            local value_expected =
                generic_constructor_context_for_expression(
                    operation, vcontext, field.exp)
            checkexp(field.exp, st, errors, value_expected,
                generic_dependent_scalar_demand(
                    operation, vcontext, value_expected,
                    "map value initializer", field.exp.loc))
        end
        local valuetype = field.exp._type
        table.insert(vtypes, valuetype)
        if operation and not deferred then
            value_pattern = value_pattern or deoptionize(valuetype)
            generic_constructor_unify(operation,
                value_pattern, deoptionize(valuetype),
                "map value initializer at position " .. index,
                field.exp.loc)
        end
    end

    -- Empty constructors reach this helper only with a Map context; a
    -- no-context empty constructor is the default empty Array.
    local ktype, vtype = generic_computed_map_constructor_types(
        context, ktypes, vtypes, operation, false)
    if operation then
        ktype = generic_substitute_constructor_type(operation, ktype, false)
        vtype = generic_substitute_constructor_type(operation, vtype, false)
        node._type = types.Map(ktype, vtype)
        generic_add_inference_finalizer(operation, function()
            generic_finish_computed_map_constructor(
                node, errors, context, ktypes, vtypes, operation,
                deferred_components)
        end)
    else
        generic_finish_computed_map_constructor(
            node, errors, context, ktypes, vtypes, false)
    end
end

function generic_resolve_named_record_constructor_context(
        node, st, errors, context)
    if not context then
        node._type = invalid(errors, node.loc,
            "no context to provide type for record constructor")
        return nil
    elseif context._tag ~= "Type.Nominal"
       or not types.registry[context.fqtn] then
        node._type = invalid(errors, node.loc,
            "record type '%s' in context of record constructor does not exist",
            types.tostring(context))
        return nil
    end

    local record = generic_applied_owner_view(
        context, errors, node.loc)
    if record._tag == "Type.Union" then
        node._type = invalid(errors, node.loc,
            "union type '%s' cannot be constructed with a record "
            .. "initializer; call one of its variant constructors",
            context.fqtn)
        return nil
    elseif record._tag ~= "Type.Record" then
        node._type = invalid(errors, node.loc,
            "nominal type '%s' is not a record type",
            context.fqtn)
        return nil
    elseif record.islocal
       and not is_nominal_visible_from(st, context.fqtn) then
        node._type = invalid(errors, node.loc,
            "record type '%s' is local to module '%s'",
            context.fqtn, nominal_module(context.fqtn))
        return nil
    end

    local visible_fields = visible_record_fields(record, st)
    if (record.nfields or #record.fields) > #visible_fields then
        node._type = invalid(errors, node.loc,
            "cannot construct record type '%s' outside module '%s' because it has local fields",
            context.fqtn, nominal_module(context.fqtn))
        return nil
    end
    local visible_by_name = {}
    for _, field in ipairs(visible_fields) do
        visible_by_name[field.name] = field
    end
    return record, visible_fields, visible_by_name
end

function generic_finish_named_record_constructor(
        node, st, errors, context, written_fields, operation,
        deferred_components)
    for _, item in ipairs(deferred_components or {}) do item.finish(true) end
    -- Discovery resolves a context-only record owner through the same single
    -- outer Option projection accepted by ordinary result/constructor evidence.
    -- Finish against that nominal base; the enclosing argument sink owns any
    -- eventual Plain -> Plain? adjustment.
    local closed_context = deoptionize(
        generic_substitute_constructor_type(
            operation, context, true))
    local record = generic_applied_owner_view(
        closed_context, errors, node.loc)
    local visible_fields = visible_record_fields(record, st)
    local visible_by_name = {}
    for _, field in ipairs(visible_fields) do
        visible_by_name[field.name] = field
    end
    local supplied = {}
    local finalized_fields = {}

    for _, cfield in ipairs(written_fields) do
        if cfield._field then
            local found = visible_by_name[cfield.name]
            if found then
                cfield.exp = coerce_and_check(
                    cfield.exp, found.type, "field " .. cfield.name,
                    errors, cfield.loc)
                cfield._field = found
                cfield._decl = found
                supplied[found.name] = true
                table.insert(finalized_fields, cfield)
            end
        end
    end
    for _, rfield in ipairs(visible_fields) do
        if not supplied[rfield.name] then
            local exp = ast.ExpNil(node.loc)
            exp._type = types.Nil()
            local adjustment = types.assignment_adjustment(
                exp._type, rfield.type)
            if adjustment then
                exp = coerce_and_check(
                    exp, rfield.type,
                    "omitted field " .. rfield.name,
                    errors, node.loc, adjustment)
                exp._named_omitted = true
                local cfield = ast.Field(node.loc, rfield.name, exp)
                cfield._field = rfield
                cfield._decl = rfield
                table.insert(finalized_fields, cfield)
            else
                checker.typeerror(errors, node.loc,
                    "field '%s' of record '%s' cannot be omitted because its type %s does not accept nil",
                    rfield.name, types.tostring(closed_context),
                    types.tostring(rfield.type))
            end
        end
    end
    -- A rejected written field was already checked and diagnosed during the
    -- discovery mapping. Do not redispatch it, but do keep the runtime-facing
    -- recovery constructor limited to fields with resolved descriptors.
    node.fields = finalized_fields
    node._type = closed_context
end

function generic_check_named_record_constructor(
        node, st, errors, context, operation)
    local provisional = operation and context
        and generic_substitute_constructor_type(
            operation, context, false) or context
    local deferred_owner = operation and provisional
        and provisional._tag == "Type.Parameter"
        and generic_inference_type_has_unresolved(
            operation.context, provisional)
    if deferred_owner then
        local written_fields = { table.unpack(node.fields) }
        local deferred_by_field = {}
        -- Independently typed fields still own their lexical checking slot now.
        -- A contextual field cannot be checked until the later nominal witness
        -- supplies its descriptor, so retain that AST and finish it once during
        -- owner discovery under this constructor's original inference use.
        for _, field in ipairs(written_fields) do
            if generic_constructor_expression_needs_context(
                    field.exp, st, errors) then
                deferred_by_field[field] = { checked = false }
                field.exp._type = types.Invalid()
            else
                checkexp(field.exp, st, errors)
            end
        end
        node._type = context

        local plan = { complete = false, owner_valid = false }
        local function finish_field(cfield, expected)
            local item = deferred_by_field[cfield]
            if not item or item.checked then return end
            local demand = expected and generic_dependent_scalar_demand(
                operation, expected, expected,
                "field " .. tostring(cfield.name), cfield.loc) or nil
            checkexp(cfield.exp, st, errors, expected, demand)
            item.checked = true
        end
        local function map_fields(candidate, visible_by_name, contribute)
            for _, cfield in ipairs(written_fields) do
                local found = visible_by_name[cfield.name]
                if not found then
                    finish_field(cfield, nil)
                    if cfield.name then
                        checker.typeerror(errors, cfield.loc,
                            "field '%s' not found in record type '%s'",
                            cfield.name, types.tostring(candidate))
                    else
                        checker.typeerror(errors, cfield.loc,
                            "missing field in initializer for record type '%s'",
                            types.tostring(candidate))
                    end
                else
                    finish_field(cfield, found.type)
                    cfield._field = found
                    cfield._decl = found
                    if contribute then
                        generic_constructor_unify(operation,
                            found.type, cfield.exp._type,
                            "field " .. cfield.name, cfield.loc)
                    end
                end
            end
        end

        generic_add_inference_discovery(operation, function()
            local candidate = generic_substitute_constructor_type(
                operation, context, false)
            candidate = candidate and deoptionize(candidate)
            if candidate and candidate._tag == "Type.Parameter"
               and generic_inference_type_has_unresolved(
                   operation.context, candidate) then
                return false
            end
            local _, _, visible_by_name =
                generic_resolve_named_record_constructor_context(
                    node, st, errors, candidate)
            plan.complete = true
            if visible_by_name then
                plan.owner_valid = true
                map_fields(candidate, visible_by_name, true)
            end
            return true
        end)

        generic_add_inference_discovery(operation, function()
            if plan.complete then return true end
            local candidate = generic_substitute_constructor_type(
                operation, context, false)
            candidate = candidate and deoptionize(candidate)
            if not generic_inference_type_has_unresolved(
                    operation.context, candidate) then
                return true -- the evidence-phase callback owns this case
            end
            checker.typeerror(errors, node.loc,
                "no context to provide type for record constructor")
            plan.complete = true
            for _, cfield in ipairs(written_fields) do
                finish_field(cfield, nil)
            end
            node._type = types.Invalid()
            return true
        end, "default")

        generic_add_inference_finalizer(operation, function()
            local candidate = generic_substitute_constructor_type(
                operation, context, true)
            candidate = candidate and deoptionize(candidate)
            if not plan.complete then
                local _, _, visible_by_name =
                    generic_resolve_named_record_constructor_context(
                        node, st, errors, candidate)
                plan.complete = true
                if visible_by_name then
                    plan.owner_valid = true
                    -- Carrier defaults have already run. This recovery mapping
                    -- may freeze diagnostics and annotations but never adds late
                    -- equations to the closed owner.
                    map_fields(candidate, visible_by_name, false)
                end
            end
            if plan.owner_valid then
                -- Even a failed written-field mapping owns the ordinary omission
                -- pass. It consumes only the descriptors discovered above, so
                -- every written expression remains checked exactly once while
                -- every missing required field is still diagnosed.
                generic_finish_named_record_constructor(
                    node, st, errors, context, written_fields, operation)
            else
                -- The invalid owner was already diagnosed. Context-only fields
                -- still belong to this source subtree and must be checked once
                -- for recovery, even though no descriptor can contextualize them.
                for _, cfield in ipairs(written_fields) do
                    finish_field(cfield, nil)
                end
                -- Never leave the original fresh Parameter on the
                -- runtime-facing constructor.
                node._type = candidate
                    and candidate._tag == "Type.Nominal"
                    and candidate or types.Invalid()
            end
        end)
        return
    end

    local record, visible_fields, visible_by_name =
        generic_resolve_named_record_constructor_context(
            node, st, errors, context)
    if not record then
        for _, field in ipairs(node.fields) do
            checkexp(field.exp, st, errors)
        end
        return
    end

    local written_fields = { table.unpack(node.fields) }
    local supplied = {}
    local deferred_components = {}
    for _, cfield in ipairs(written_fields) do
        local found = visible_by_name[cfield.name]
        if not found then
            if cfield.name then
                checker.typeerror(errors, cfield.loc,
                    "field '%s' not found in record type '%s'",
                    cfield.name, types.tostring(context))
            else
                checker.typeerror(errors, cfield.loc,
                    "missing field in initializer for record type '%s'",
                    types.tostring(context))
            end
            checkexp(cfield.exp, st, errors)
        else
            local field_demand = generic_dependent_scalar_demand(
                operation, found.type, nil,
                "field " .. cfield.name, cfield.loc)
            local deferred =
                generic_defer_contextual_constructor_component(
                    operation, cfield.exp, found.type, st, errors,
                    "field " .. cfield.name, field_demand)
            if deferred then
                deferred_components[#deferred_components + 1] = deferred
            else
                local expected =
                    generic_constructor_context_for_expression(
                        operation, found.type, cfield.exp)
                checkexp(cfield.exp, st, errors, expected,
                    generic_dependent_scalar_demand(
                        operation, found.type, expected,
                        "field " .. cfield.name, cfield.loc))
            end
            cfield._field = found
            cfield._decl = found
            supplied[found.name] = true
            if operation and not deferred then
                generic_constructor_unify(operation,
                    found.type, cfield.exp._type,
                    "field " .. cfield.name, cfield.loc)
            elseif not operation then
                cfield.exp = coerce_and_check(
                    cfield.exp, found.type, "field " .. cfield.name,
                    errors, cfield.loc)
            end
        end
    end

    if operation then
        -- Omitted record fields are synthesized after every written field, in
        -- declaration order. Their nil values are real fallback evidence for
        -- still-open field cells; the finalizer below alone owns the ordinary
        -- omission adjustment or diagnostic.
        for _, rfield in ipairs(visible_fields) do
            if not supplied[rfield.name] then
                generic_constructor_unify(operation,
                    rfield.type, types.Nil(),
                    "omitted field " .. rfield.name, node.loc)
            end
        end
        node._type = generic_substitute_constructor_type(
            operation, context, false)
        generic_add_inference_finalizer(operation, function()
            generic_finish_named_record_constructor(
                node, st, errors, context, written_fields, operation,
                deferred_components)
        end)
    else
        -- Preserve the established omission behavior on the nondependent path.
        for _, rfield in ipairs(visible_fields) do
            if not supplied[rfield.name] then
                local exp = ast.ExpNil(node.loc)
                exp._type = types.Nil()
                local adjustment = types.assignment_adjustment(
                    exp._type, rfield.type)
                if adjustment then
                    exp = coerce_and_check(
                        exp, rfield.type,
                        "omitted field " .. rfield.name,
                        errors, node.loc, adjustment)
                    exp._named_omitted = true
                    local cfield = ast.Field(node.loc, rfield.name, exp)
                    cfield._field = rfield
                    cfield._decl = rfield
                    table.insert(node.fields, cfield)
                else
                    checker.typeerror(errors, node.loc,
                        "field '%s' of record '%s' cannot be omitted because its type %s does not accept nil",
                        rfield.name, types.tostring(context),
                        types.tostring(rfield.type))
                end
            end
        end
        node._type = context
    end
end

function generic_inference_type_has_invalid(typ, seen)
    if type(typ) ~= "table" then return false end
    if typ._tag == "Type.Invalid" then return true end
    seen = seen or {}
    if seen[typ] then return false end
    seen[typ] = true
    for key, child in pairs(typ) do
        if key ~= "scope" and type(child) == "table" then
            if child._tag then
                if generic_inference_type_has_invalid(child, seen) then
                    return true
                end
            else
                for _, item in pairs(child) do
                    if generic_inference_type_has_invalid(item, seen) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Computed syntax fixes Map shape, but a direct open whole-value sink still
-- has no key/value cells of its own. If either side is context-only, keep the
-- constructor pending until a later whole Map supplies those component types;
-- otherwise build the ordinary Map now and let it select the whole cell.
function generic_check_direct_computed_constructor(
        node, st, errors, pattern, operation)
    local contextual = false
    for _, field in ipairs(node.fields) do
        assert(constructor_field_kind(field) == "computed")
        contextual = generic_constructor_expression_needs_context(
            field.name, st, errors) or contextual
        contextual = generic_constructor_expression_needs_context(
            field.exp, st, errors) or contextual
    end

    if not contextual then
        check_computed_map_constructor(node, st, errors, nil, operation)
        if generic_inference_type_has_invalid(node._type) then
            -- Never advertise a structural Invalid component to an enclosing
            -- phase-one edge; keep the finalizer only to restore Invalid after
            -- the local constructor's own pending finalizer has run.
            node._type = types.Invalid()
            generic_add_inference_finalizer(operation, function()
                node._type = types.Invalid()
            end)
        else
            generic_constructor_unify(operation, pattern, node._type,
                "computed map constructor", node.loc)
            node._type = generic_substitute_constructor_type(
                operation, pattern, false)
        end
        return
    end

    local plan = { complete = false }
    node._type = pattern
    local function finish(recover)
        if plan.complete then return true end
        local candidate = generic_substitute_constructor_type(
            operation, pattern, recover)
        if generic_inference_type_has_unresolved(
                operation.context, candidate) then
            return false
        end
        candidate = deoptionize(candidate)
        plan.complete = true
        if candidate._tag == "Type.Map" then
            check_computed_map_constructor(
                node, st, errors, candidate, operation)
        else
            check_computed_map_constructor(node, st, errors, nil, operation)
        end
        return true
    end

    generic_add_inference_discovery(operation, function()
        return finish(false)
    end, "evidence")
    generic_add_inference_discovery(operation, function()
        if finish(false) then return true end
        -- Settle component producers inside-out. A nested empty constructor or
        -- generic first-class value may yield a complete Map without any later
        -- whole witness; feed that valid type upward instead of poisoning
        -- generic erasure with a provisional Invalid component.
        plan.complete = true
        check_computed_map_constructor(node, st, errors, nil, operation)
        if generic_inference_type_has_invalid(node._type) then
            -- Never advertise a structural Invalid component to an enclosing
            -- phase-one edge; keep the finalizer only to restore Invalid after
            -- the local constructor's own pending finalizer has run.
            node._type = types.Invalid()
            generic_add_inference_finalizer(operation, function()
                node._type = types.Invalid()
            end)
        else
            generic_constructor_unify(operation, pattern, node._type,
                "default computed map constructor", node.loc)
            node._type = generic_substitute_constructor_type(
                operation, pattern, false)
        end
        return true
    end, "default")
end

-- A nonempty positional constructor in a direct open `T` position has no
-- structural owner yet. Check independently typed children once in source
-- order. Real component evidence selects the ordinary Array shape immediately;
-- if every component still needs context, keep the whole constructor
-- pending so later whole-value evidence may select Array or integer-keyed Map.
function generic_check_direct_positional_constructor(
        node, st, errors, pattern, operation)
    local exps = {}
    for _, field in ipairs(node.fields) do
        assert(constructor_field_kind(field) == "positional")
        exps[#exps + 1] = field.exp
    end

    local plan = {
        selected = false,
        rejected = false,
        deferred = {},
        deferred_by_exp = {},
    }

    local function current_type(typ, recover)
        return generic_substitute_constructor_type(
            operation, typ, recover)
    end

    local function select_first_component(typ, loc)
        if plan.selected or not typ
           or generic_inference_type_has_invalid(typ) then
            return false
        end
        typ = deoptionize(current_type(typ, false))
        if generic_inference_type_has_invalid(typ) then
            return false
        end
        if generic_inference_type_has_unresolved(
                operation.context, typ) then
            return false
        end
        generic_unify_inference(operation.context, pattern,
            types.Array(typ, false),
            "positional constructor first component", loc)
        local candidate = current_type(pattern, false)
        if candidate._tag ~= "Type.Array" then return false end
        plan.selected = true
        plan.context = candidate
        plan.container_tag = "Type.Array"
        plan.elem = candidate.elem
        plan.key = nil
        node._type = candidate
        return true
    end

    local adjusted = adjust_explist(exps,
        result_demand({}, INFER_OPEN, {
            term = "positional constructor",
            loc = node.loc,
            missing = "error",
            explicit_surplus = "discard",
            open_coerce = true,
            defer_open_check = true,
            check_expression = function(exp, est, eerrors, _, demand)
                if not plan.selected
                   and generic_constructor_expression_needs_context(
                        exp, est, eerrors) then
                    local item = {
                        exp = exp,
                        checked = false,
                        demand = demand,
                    }
                    plan.deferred[#plan.deferred + 1] = item
                    plan.deferred_by_exp[exp] = item
                    exp._type = types.Invalid()
                    if exp._tag == "Ast.ExpCall" then
                        if demand.tail then
                            -- A final contextual call owns its whole open run.
                            -- Preserve that expression-list shape provisionally;
                            -- the one real check below replaces the placeholder
                            -- descriptor after the element context closes.
                            exp._types = {}
                            exp._visible_types = {}
                            exp._open_results = {
                                source_type = exp._type,
                                target_type = exp._type,
                                start = 1,
                            }
                        else
                            -- A nonfinal call contributes only its first scalar.
                            exp._types = { exp._type }
                            exp._visible_types = { exp._type }
                            exp._open_results = false
                        end
                    end
                    return
                end
                local expected = plan.selected
                    and current_type(plan.elem, false) or nil
                checkexp(exp, est, eerrors, expected,
                    expected and generic_constructor_result_demand(
                        expected, demand, operation, plan.elem) or demand)
                if not plan.selected then
                    local results = generic_expression_result_types(exp)
                    select_first_component(results[1], exp.loc)
                end
            end,
        }), st, errors)
    plan.adjusted = adjusted
    node._positional_adjustment = adjusted
    node._type = pattern

    local function independent_sources(require_closed)
        local out = {}
        for _, exp in ipairs(adjusted.tail_scalars) do
            if not plan.deferred_by_exp[exp]
               and exp._type
               and not generic_inference_type_has_invalid(exp._type) then
                local typ = deoptionize(current_type(exp._type, false))
                local unresolved = generic_inference_type_has_unresolved(
                    operation.context, typ)
                if not generic_inference_type_has_invalid(typ)
                   and (not require_closed or not unresolved) then
                    out[#out + 1] = { type = typ, loc = exp.loc }
                end
            end
        end
        if adjusted.open_source
           and not plan.deferred_by_exp[adjusted.open_source]
           and adjusted.open_type
           and not generic_inference_type_has_invalid(
                adjusted.open_type) then
            local typ = deoptionize(current_type(adjusted.open_type, false))
            local unresolved = generic_inference_type_has_unresolved(
                operation.context, typ)
            if not generic_inference_type_has_invalid(typ)
               and (not require_closed or not unresolved) then
                out[#out + 1] = {
                    type = typ,
                    loc = adjusted.open_source.loc,
                    open = true,
                }
            end
        end
        return out
    end

    local function select(candidate)
        if plan.selected then return true end
        candidate = deoptionize(current_type(candidate, false))
        if generic_inference_type_has_invalid(candidate)
           or generic_inference_type_has_unresolved(
                operation.context, candidate) then
            return false
        end
        plan.selected = true
        plan.context = candidate
        if candidate._tag == "Type.Array" then
            plan.container_tag = "Type.Array"
            plan.elem = candidate.elem
            plan.key = nil
        elseif candidate._tag == "Type.Map" then
            plan.container_tag = "Type.Map"
            plan.elem = candidate.values
            plan.key = candidate.keys
            if not types.equals(plan.key, types.Integer()) then
                checker.typeerror(errors, node.loc,
                    "positional fields require an integer-keyed map, but found key type %s",
                    types.tostring(plan.key))
                plan.rejected = true
            end
        elseif candidate._tag == "Type.Nominal" then
            plan.rejected = true
            for _, field in ipairs(node.fields) do
                checker.typeerror(errors, field.loc,
                    "missing field in initializer for record type '%s'",
                    types.tostring(candidate))
            end
            local _, visible_fields =
                generic_resolve_named_record_constructor_context(
                    node, st, errors, candidate)
            for _, field in ipairs(visible_fields or {}) do
                if not types.assignment_adjustment(types.Nil(), field.type) then
                    checker.typeerror(errors, node.loc,
                        "field '%s' of record '%s' cannot be omitted because its type %s does not accept nil",
                        field.name, types.tostring(candidate),
                        types.tostring(field.type))
                end
            end
        else
            -- The whole generic target is already a nonconstructor type. Build
            -- the ordinary Array evidence for recovery; the enclosing argument
            -- edge reports the directional mismatch.
            local sources = independent_sources(false)
            plan.container_tag = "Type.Array"
            plan.elem = sources[1] and sources[1].type or types.Integer()
            plan.context = types.Array(plan.elem, false)
        end

        if not plan.rejected then
            for index, source in ipairs(independent_sources(false)) do
                generic_constructor_unify(operation,
                    plan.elem, source.type,
                    "positional constructor at position " .. index,
                    source.loc)
            end
            plan.elem = current_type(plan.elem, false)
            plan.key = current_type(plan.key, false)
            node._type = plan.container_tag == "Type.Array"
                and types.Array(plan.elem, false)
                or types.Map(plan.key, plan.elem)
        else
            node._type = candidate
        end
        return true
    end

    local function finish_deferred()
        if plan.rejected then
            for _, item in ipairs(plan.deferred) do
                if not item.checked then
                    checkexp(item.exp, st, errors)
                    item.checked = true
                end
            end
            return
        end
        local expected = current_type(plan.elem, true)
        for _, item in ipairs(plan.deferred) do
            if not item.checked then
                checkexp(item.exp, st, errors, expected,
                    generic_constructor_result_demand(
                        expected, item.demand, operation, plan.elem))
                item.checked = true
            end
        end
    end

    local closed = generic_closed_inference_pattern(
        operation.context, pattern)
    local sources = independent_sources(true)
    if closed then
        select(closed)
    elseif sources[1] then
        generic_unify_inference(operation.context, pattern,
            types.Array(sources[1].type, false),
            "positional constructor first component", sources[1].loc)
        select(generic_substitute_inference(
            operation.context, pattern, false))
    end

    generic_add_inference_discovery(operation, function()
        if plan.selected then return true end
        local candidate = generic_closed_inference_pattern(
            operation.context, pattern)
        if candidate then return select(candidate) end
        local ready = independent_sources(true)
        if ready[1] then
            generic_unify_inference(operation.context, pattern,
                types.Array(ready[1].type, false),
                "positional constructor first component", ready[1].loc)
            return select(generic_substitute_inference(
                operation.context, pattern, false))
        end
        return false
    end, "evidence")

    generic_add_inference_discovery(operation, function()
        if plan.selected then return true end
        local candidate = generic_closed_inference_pattern(
            operation.context, pattern)
        if candidate then return select(candidate) end

        local equations = independent_sources(false)
        if equations[1] then
            generic_unify_inference(operation.context, pattern,
                types.Array(equations[1].type, false),
                "default positional constructor shape", equations[1].loc)
            return select(generic_substitute_inference(
                operation.context, pattern, false))
        end

        -- Settle pending component producers inside-out before defaulting this
        -- nonempty constructor. A generic first-class value contributes its
        -- open function equation, and a nested empty constructor contributes
        -- its own `{integer}` default. Only the separate empty-constructor path
        -- may invent integer evidence for the outer element itself.
        for _, item in ipairs(plan.deferred) do
            if not item.checked then
                checkexp(item.exp, st, errors, nil, item.demand)
                item.checked = true
            end
            local results, open =
                generic_expression_result_types(item.exp)
            local elem = results[1] or open
            if elem
               and not generic_inference_type_has_invalid(elem) then
                generic_unify_inference(operation.context, pattern,
                    types.Array(deoptionize(elem), false),
                    "default positional constructor component", item.exp.loc)
                return select(generic_substitute_inference(
                    operation.context, pattern, false))
            end
        end

        plan.no_evidence = true
        node._type = types.Invalid()
        return true
    end, "default")

    generic_add_inference_finalizer(operation, function()
        if plan.no_evidence then
            finish_deferred()
            node._type = types.Invalid()
            return
        end
        if not plan.selected then
            select(generic_substitute_inference(
                operation.context, pattern, true))
        end
        finish_deferred()
        if not plan.rejected then
            generic_finish_positional_constructor(
                node, st, errors, plan.container_tag, plan.key,
                current_type(plan.elem, true), adjusted, operation,
                plan.container_tag == "Type.Array"
                    and plan.context.isconst or false)
        elseif generic_inference_type_has_unresolved(
                operation.context, node._type) then
            node._type = current_type(node._type, true)
        end
    end)
end

-- An empty constructor carries no evaluated type evidence. When its immediate
-- generic sink is a direct open cell, retain the written AST as one pending
-- producer: a later whole-value witness may select Array, integer-keyed Map, or
-- record context. Only the constructor-default phase may otherwise select the
-- ordinary `{integer}` Array, before generic carrier fallback.
function generic_defer_empty_constructor(
        node, st, errors, pattern, operation)
    local plan = { complete = false }
    node._type = pattern

    local function finish(recover)
        if plan.complete then return true end
        local candidate = generic_substitute_constructor_type(
            operation, pattern, recover)
        if generic_inference_type_has_unresolved(
                operation.context, candidate) then
            return false
        end
        candidate = deoptionize(candidate)
        plan.complete = true
        if candidate._tag == "Type.Array" then
            check_positional_constructor(node, st, errors, "Type.Array", nil,
                candidate.elem, operation, candidate.isconst)
        elseif candidate._tag == "Type.Map" then
            check_computed_map_constructor(
                node, st, errors, candidate, operation)
        elseif candidate._tag == "Type.Nominal" then
            generic_check_named_record_constructor(
                node, st, errors, candidate, operation)
        else
            -- A closed nonconstructor target cannot reshape brace syntax. Build
            -- the ordinary fallback Array once and let the enclosing edge issue
            -- its normal directional mismatch.
            check_positional_constructor(node, st, errors, "Type.Array", nil,
                nil, operation)
        end
        return true
    end

    generic_add_inference_discovery(operation, function()
        return finish(false)
    end, "evidence")
    generic_add_inference_discovery(operation, function()
        if finish(false) then return true end
        generic_unify_inference(operation.context, pattern,
            types.Array(types.Integer(), false),
            "default empty constructor", node.loc)
        return finish(false)
    end, "default")
    generic_add_inference_finalizer(operation, function()
        if not plan.complete then finish(true) end
        if generic_inference_type_has_unresolved(
                operation.context, node._type) then
            node._type = generic_substitute_constructor_type(
                operation, node._type, true)
        end
    end)
end

--
-- Decl
--

checkdecl = function(node, st, errors)
    node._type = node._type or typefromnode(node.type, st, errors)
    checktype(node._type, node.loc, errors)
    report_incomplete_c_object(node._type, st,
        "declaration of local variable '" .. tostring(node.name) .. "'",
        node.loc, errors)
end

function declare(node, st, errors)
    local builtin = st:find_symbol(node.name)
    if builtin and builtin._readonly then
        checker.typeerror(errors, node.loc,
            "cannot declare local '%s' because it shadows a built-in local",
            node.name)
    end
    -- Stamp the function-nesting depth at which this local was declared, so the
    -- VarName visitor can tell a capture (use from a deeper function) apart from
    -- a same-function reference.
    node._funcdepth = #func_stack
    st:add_symbol(node.name, node)
end

return core.checker
