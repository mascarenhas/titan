local core = require "titan-compiler.checker.core"
local _ENV = core

--
-- Stat
--

-- Typechecks a repeat/until statement
--   node: StatRepeat AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether the statement cannot fall through (always false here)
function checkcondition(node, st, errors)
    if checker._foreign_function_depth == 0 then
        checkexp(node, st, errors, types.Boolean())
        if node._type._tag == "Type.Parameter" then
            checker.typeerror(errors, node.loc,
                "rigid type parameter '%s' cannot be used as a condition",
                node._type.diagnostic_name)
        end
        return
    end

    checkexp(node, st, errors)
    local typ = c_resolve(node._type)
    if not typ or (typ._tag ~= "Type.CInteger"
                   and typ._tag ~= "Type.CFloat"
                   and typ._tag ~= "Type.CPointer"
                   and typ._tag ~= "Type.CArray"
                   and typ._tag ~= "Type.Boolean") then
        checker.typeerror(errors, node.loc,
            "a foreign function condition must have a C scalar type, found %s",
            types.tostring(node._type))
    else
        node._foreign_condition = true
    end
end

function checkrepeat(node, st, errors)
    for _, stat in ipairs(node.block.stats) do
        checkstat(stat, st, errors)
    end
    checkcondition(node.condition, st, errors)
    return false
end

-- Typechecks a for loop statement
--   node: StatFor AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether the statement cannot fall through (always false here)
function checkfor(node, st, errors)
    checkexp(node.start, st, errors)
    node.start = tryforce(node.start)
    checkexp(node.finish, st, errors)
    node.finish = tryforce(node.finish)
    if node.inc then
        checkexp(node.inc, st, errors)
        node.inc = tryforce(node.inc)
    end

    -- Add loop variable to symbol table only after checking expressions
    if not node.decl.type then
        node.decl._type = node.start._type
    end
    checkdecl(node.decl, st, errors)
    declare(node.decl, st, errors)
    -- The numeric-for control variable is read-only (as in Lua 5.4+):
    -- assigning to it is a clean compile-time error, not a silent miscompile.
    node.decl._forcontrol = true

    local loop_type_is_valid
    local resolved_control = c_resolve(node.decl._type)
    if checker._foreign_function_depth > 0
       and resolved_control
       and (resolved_control._tag == "Type.CInteger"
            or resolved_control._tag == "Type.CFloat") then
        loop_type_is_valid = true
        if not node.inc then
            node.inc = resolved_control._tag == "Type.CInteger"
                and ast.ExpInteger(node.finish.loc, 1)
                or ast.ExpFloat(node.finish.loc, 1.0)
            node.inc._type = node.decl._type
            node.inc._foreign_literal = true
        end
        for _, bound in ipairs({ node.start, node.finish, node.inc }) do
            if bound._foreign_literal then bound._type = node.decl._type end
        end
        if checker._numeric_literal_is_zero(node.inc) then
            checker.typeerror(errors, node.inc.loc,
                "a numeric for loop inside a foreign function requires a nonzero step")
        end
    elseif node.decl._type._tag == "Type.Integer" then
        loop_type_is_valid = true
        if not node.inc then
            node.inc = ast.ExpInteger(node.finish.loc, 1)
            node.inc._type = types.Integer()
        end
    elseif node.decl._type._tag == "Type.Float" then
        loop_type_is_valid = true
        if not node.inc then
            node.inc = ast.ExpFloat(node.finish.loc, 1.0)
            node.inc._type = types.Float()
        end
    else
        loop_type_is_valid = false
        checker.typeerror(errors, node.decl.loc,
            "type of for control variable %s must be integer or float",
            node.decl.name)
    end

    if loop_type_is_valid then
        -- Numeric-for bounds share the exact control representation. They do
        -- not form assignment sinks and therefore neither coerce nor create a
        -- gradual view of the control type.
        check_exact_match("'for' start expression",
            node.decl._type, node.start, errors, node.start.loc)
        check_exact_match("'for' finish expression",
            node.decl._type, node.finish, errors, node.finish.loc)
        check_exact_match("'for' step expression",
            node.decl._type, node.inc, errors, node.inc.loc)
    end

    checkstat(node.block, st, errors)

    return false
end

function hidden_decl(loc, name, typ)
    local decl = ast.Decl(loc, name, false, false, false)
    decl._type = typ
    decl._used = true
    return decl
end

function hidden_exp(loc, decl)
    local var = ast.VarName(loc, decl.name)
    var._decl = decl
    var._type = decl._type
    local exp = ast.ExpVar(loc, var)
    exp._type = decl._type
    return exp
end

function nil_exp(loc)
    local exp = ast.ExpNil(loc)
    exp._type = types.Nil()
    return exp
end

-- A trailing `...` in the generic-for setup tuple supplies the iterator plus
-- only the fixed state/control inputs that iterator can consume. The tuple's
-- fourth storage slot is the optional close callable; it must remain the
-- ordinary synthesized nil unless the written prefix actually reaches it.
-- This preserves the pre-demand-elaboration generic-for contract while still
-- routing the projections through `adjust_explist`.
function forin_dots_limit(exps)
    local prefix = #exps - 1
    local limit = 4
    local callable = exps[1] and exps[1]._type
    local cfunc = callable and c_function_pointer_type(callable)
    local signature = call_signature(cfunc or callable)
    if signature then
        limit = math.max(prefix + 1,
            1 + math.min(#signature.params, 2))
        if limit > 4 then limit = 4 end
    end
    return limit
end

function check_forin_decl_init(decl, exp, st, errors)
    local term = "generic for variable " .. decl.name
    if decl.type then
        checkdecl(decl, st, errors)
        exp = coerce_and_check(
            exp, decl._type, term, errors, decl.loc)
    elseif decl.option then
        decl._type = optionize(exp._type)
        checkdecl(decl, st, errors)
        exp = coerce_and_check(
            exp, decl._type, term, errors, decl.loc)
    else
        exp = tryforce(exp)
        decl._type = exp._type
        checkdecl(decl, st, errors)
    end
    return exp
end

function forin_signature_from_slot_type(typ)
    local cfunc = c_function_pointer_type(typ)
    if cfunc then
        return call_signature(cfunc), cfunc
    elseif typ._tag == "Type.Function" then
        return call_signature(typ), nil
    end
end

function check_forin_callable_exp(exp, st, errors, context, demand)
    if exp._tag == "Ast.ExpVar" and exp.var._tag == "Ast.VarDot" then
        generic_precheckvar_for_expression(exp, st, errors)
        if exp.var._decl then exp.var._decl._used = true end
        local ftype = exp.var._type
        local cfunc = c_resolve(ftype)
        if exp.var.exp and exp.var.exp._type
           and exp.var.exp._type._tag == "Type.CModule"
           and cfunc and cfunc._tag == "Type.CFunction" then
            exp._type = types.CPointer(cfunc, {})
            exp._foreign_function_pointer = exp.var.name
            return
        end
    end
    checkexp(exp, st, errors, context, demand)
end

function forin_decl_return_type(decl, index, st, errors)
    local typ
    if decl.type then
        decl._type = decl._type or typefromnode(decl.type, st, errors)
        typ = decl._type
    else
        typ = types.Value()
    end
    if index == 1 then
        return optionize(typ)
    else
        return typ
    end
end

function synthesize_forin_iterator_type(node, st, errors)
    local exps = node.exps
    local params = {}
    if exps[3]._type._tag ~= "Type.Nil" then
        table.insert(params, exps[2]._type)
        table.insert(params, exps[3]._type)
    elseif exps[2]._type._tag ~= "Type.Nil" then
        table.insert(params, exps[2]._type)
    end

    local rettypes = {}
    for i, decl in ipairs(node.decls) do
        table.insert(rettypes, forin_decl_return_type(decl, i, st, errors))
    end
    return synthesize_function_type(params, false,
        result_demand(rettypes, false, { loc = node.loc }), node.loc, errors)
end

function synthesize_forin_close_type(exps)
    local params = {}
    if exps[2]._type._tag ~= "Type.Nil" then
        table.insert(params, exps[2]._type)
    end
    return types.Function(params, {}, false, false, false)
end

function forin_nil_capable_control(typ)
    local rtyp = c_resolve(typ)
    return typ._tag == "Type.Option"
        or typ._tag == "Type.Value"
        or typ._tag == "Type.Invalid"
        or types.is_c_tvalue(typ)
        or (rtyp and rtyp._tag == "Type.CPointer")
end

function forin_effective_results(ftype, count)
    local results = {}
    for i = 1, count do
        if ftype.rettypes[i] then
            results[i] = ftype.rettypes[i]
        elseif ftype.flexrettype then
            results[i] = optionize(ftype.flexrettype)
        else
            break
        end
    end
    return results
end

function make_forin_call(loc, iter_decl, args, ftype, nresults, cfunc,
                               errors, report_result_limit)
    local call = ast.ExpCall(loc, hidden_exp(loc, iter_decl),
        ast.ArgsFunc(loc, args), {})
    call._c_pointer_call = cfunc
    local fixed = {}
    for i = 1, nresults do fixed[i] = UNKNOWN_SLOT end
    local demand = result_demand(fixed, false, {
        term = "generic for iterator results",
        loc = loc,
        suppress_flex_cap = true,
    })
    annotate_call_results(call, ftype, demand, errors)
    if not cfunc then
        check_generic_result_limit(call, errors, report_result_limit)
    end
    call._arg_adjustment = {
        exps = args,
        fixed = args,
        tail_scalars = {},
        discards = {},
        open_source = false,
    }
    call._npassed_args = #args
    call._open_args = false
    return call
end

function generic_infer_forin_scheme(
        exp, scheme, node, st, errors)
    local subject = "generic for iterator"
    -- The iterator owns an isolated occurrence context, as before, but its
    -- complete four-slot setup tuple now descends while that context is ambient.
    -- Nested generic state/control producers therefore retain equations, and a
    -- trailing multi-result expression contributes state then control (and close)
    -- in delivered slot order without being checked twice.
    local context = generic_new_inference_context(
        subject, {}, st, errors, exp.loc)
    context.owner = exp
    local scopes = { generic_inference_scope_entry(
        scheme.scope, scheme.typeparams) }
    generic_freshen_inference_entries(
        context, scopes, subject, exp.loc)
    local use = generic_register_inference_use(
        context, exp, subject, exp.loc, scopes, true)
    for _, entry in ipairs(scopes) do
        entry.subject = subject
        entry.loc = exp.loc
        entry.use = use
        for _, cell in ipairs(entry.cells) do
            cell.subject = subject
            cell.loc = exp.loc
            cell.entry = entry
        end
        context.scopes[#context.scopes + 1] = entry
        context.scope_entries[entry.scope] = entry
        for index, typeparam in ipairs(entry.typeparams) do
            if typeparam.constraint ~= false then
                context.next_constraint_sequence =
                    context.next_constraint_sequence + 1
                local record = {
                    cell = entry.cells[index],
                    typeparam = typeparam,
                    sequence = context.next_constraint_sequence,
                }
                local root = entry.cells[index]
                root.constraint_records = root.constraint_records or {}
                root.constraint_records[#root.constraint_records + 1] = record
            end
        end
    end
    exp._generic_inference_context = context
    exp._generic_inference_use = use

    local signature = generic_freshen_inference_type(
        context, scheme.signature, scopes, subject, exp.loc)
    local tuple_adjustment
    local consumed_results = {}
    generic_with_inference_use(context, use, st, function()
        local tuple_fixed = {
            UNKNOWN_SLOT, UNKNOWN_SLOT, UNKNOWN_SLOT, UNKNOWN_SLOT,
        }
        tuple_adjustment = adjust_explist(node.exps,
            result_demand(tuple_fixed, false, {
                term = "generic for iterator tuple",
                loc = node.loc,
                missing = "nil",
                explicit_surplus = "discard",
                dots_limit = forin_dots_limit,
                dots_nilfill = function(slot) return slot < 4 end,
                check_expression = function(actual, est, eerrors, ordinary,
                                              demand, sink_index)
                    if sink_index == 1 and actual == exp then return end
                    local formal_index = sink_index - 1
                    local pattern = signature.params[formal_index]
                    if pattern then
                        local expected =
                            generic_inference_expression_context(
                                context, pattern, actual)
                        checkexp(actual, est, eerrors, expected,
                            generic_discovery_demand(
                                context, signature, formal_index, demand))
                        generic_unify_expression_results(
                            context, signature, actual, formal_index,
                            "generic for hidden argument")
                        local results =
                            generic_expression_result_types(actual)
                        consumed_results[actual] = #results
                    elseif sink_index == 4
                       and generic_is_generic_first_class_expression(
                            actual, est, eerrors) then
                        local params = {}
                        if signature.params[1] then
                            params[1] = generic_substitute_inference(
                                context, signature.params[1], false)
                        end
                        local expected = types.Function(
                            params, {}, false, false, false)
                        checkexp(actual, est, eerrors, expected,
                            result_demand({ expected }, false, {
                                term = "generic for close function",
                            }))
                    elseif sink_index == 1 or sink_index == 4 then
                        check_forin_callable_exp(
                            actual, est, eerrors, ordinary, demand)
                    else
                        checkexp(actual, est, eerrors, ordinary, demand)
                    end
                end,
            }), st, errors)

        local function already_consumed(actual)
            local source = actual._tag == "Ast.ExpExtra"
                and actual.exp or actual
            local result_index = actual._tag == "Ast.ExpExtra"
                and actual.index or 1
            return consumed_results[source]
                and result_index <= consumed_results[source]
        end

        -- `...` projections and missing setup values are synthesized without
        -- invoking the written-expression callback. Consume those delivered
        -- state/control slots left-to-right after all written expressions; a
        -- written multi-result producer was already recorded above and is not
        -- replayed here.
        for index, parameter in ipairs(signature.params) do
            local actual = tuple_adjustment.fixed[index + 1]
            if actual and not already_consumed(actual) then
                generic_unify_adjusted_inference(context, parameter,
                    actual._type, "generic for hidden argument " .. index,
                    actual.loc)
            end
        end

        for index, decl in ipairs(node.decls) do
            if decl.type then
                decl._type = decl._type or typefromnode(decl.type, st, errors)
                local expected = index == 1
                    and optionize(decl._type) or decl._type
                local pattern = signature.rettypes[index]
                if not pattern and signature.flexrettype then
                    pattern = optionize(signature.flexrettype)
                end
                if pattern then
                    generic_unify_adjusted_inference(context, pattern,
                        expected, "generic for variable " .. decl.name,
                        decl.loc)
                end
            end
        end
    end)

    generic_add_inference_finalizer(use, function()
        generic_refresh_finalized_argument_projections(
            tuple_adjustment, context)
        use.closed = generic_substitute_inference(
            context, signature, true)
        exp._generic_scheme = scheme
        exp._generic_type_arguments =
            generic_inference_type_arguments(context, scopes)
        exp._type = use.closed
    end)
    generic_close_inference_context(context)
    return use.closed, tuple_adjustment
end

function checkforin(node, st, errors)
    local generic_prechecked = {}
    local inferred_tuple
    local iterator = node.exps[1]
    if iterator
       and generic_is_generic_first_class_expression(
            iterator, st, errors)
       and iterator._type._tag == "Type.FunctionScheme" then
        _, inferred_tuple = generic_infer_forin_scheme(
            iterator, iterator._type, node, st, errors)
        generic_prechecked[iterator] = true
    end

    local tuple_fixed = {
        UNKNOWN_SLOT, UNKNOWN_SLOT, UNKNOWN_SLOT, UNKNOWN_SLOT,
    }
    local tuple_adjustment = inferred_tuple or adjust_explist(node.exps,
        result_demand(tuple_fixed, false, {
            term = "generic for iterator tuple",
            loc = node.loc,
            missing = "nil",
            explicit_surplus = "discard",
            dots_limit = forin_dots_limit,
            -- Lua's generic-for setup tuple adjusts missing state/control
            -- values upward with nil. A close callable projected into slot 4
            -- retains the established typed/raising `...` read: the current
            -- lowering has a statically present close call and therefore must
            -- not turn its type into an option merely because the backing run
            -- can be short.
            dots_nilfill = function(slot)
                return slot < 4
            end,
            check_expression = function(exp, est, eerrors, context, demand,
                                        sink_index)
                if generic_prechecked[exp] then return end
                if sink_index == 4
                   and generic_is_generic_first_class_expression(
                        exp, est, eerrors) then
                    local params = {}
                    local state = node.exps[2]
                    if state and state._type
                       and state._type._tag ~= "Type.Nil" then
                        params[1] = state._type
                    end
                    local expected = types.Function(
                        params, {}, false, false, false)
                    checkexp(exp, est, eerrors, expected,
                        result_demand({ expected }, false, {
                            term = "generic for close function",
                        }))
                elseif sink_index == 1 or sink_index == 4 then
                    check_forin_callable_exp(exp, est, eerrors, context,
                        demand)
                else
                    checkexp(exp, est, eerrors, context, demand)
                end
            end,
        }), st, errors)
    node._tuple_adjustment = tuple_adjustment
    local exps = {}
    for i = 1, 4 do exps[i] = tuple_adjustment.fixed[i] end
    -- Keep the four lowered tuple values in the legacy field for current
    -- generic-for codegen. Every written surplus expression remains owned by
    -- `_tuple_adjustment.exps` with discard metadata for the demand-aware coder.
    node.exps = exps

    -- The iterator slot is required. A finite projection from a flexible tuple
    -- is optional, so use the ordinary runtime unwrap before callable
    -- resolution; an absent iterator fails at the same force boundary as any
    -- other optional callable used as a value.
    local raw_iter = exps[1]
    exps[1] = tryforce(exps[1])
    replace_adjusted_value(tuple_adjustment, raw_iter, exps[1])
    node.exps[1] = exps[1]

    local ftype = exps[1]._type
    local iter_cfunc
    if ftype._tag == "Type.Value" then
        ftype = synthesize_forin_iterator_type(node, st, errors)
        local old = exps[1]
        exps[1] = trycoerce(exps[1], ftype, errors)
        replace_adjusted_value(tuple_adjustment, old, exps[1])
        ftype = call_signature(exps[1]._type)
    else
        ftype, iter_cfunc = forin_signature_from_slot_type(ftype)
    end
    if not ftype then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator must be a function, value, or C function pointer but found %s",
            types.tostring(exps[1]._type))
        ftype = call_signature(
            types.Function({}, { types.Invalid() }, false, false, false))
    end

    if ftype.c_vararg or ftype.varargtype then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator cannot be variadic")
    end
    if #ftype.params > 2 then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator expects at most 2 parameter(s) but found %d",
            #ftype.params)
    end
    local effective_count = math.max(#node.decls, 1)
    if ftype.flexrettype then
        local flex_count = math.max(effective_count - #ftype.rettypes, 0)
        if flex_count > TITAN_VARARG_MAX then
            checker.typeerror(errors, exps[1].loc,
                "finite flexible-result demand is %d value(s), maximum is %d",
                flex_count, TITAN_VARARG_MAX)
        end
    end
    local effective_results = forin_effective_results(ftype, effective_count)
    if #effective_results == 0 then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator must return at least one value")
        ftype = call_signature(types.Function(
            ftype.params, { types.Invalid() }, false, false, false))
        effective_results = { types.Invalid() }
    else
        local ctrltype = effective_results[1]
        if ctrltype._tag == "Type.Nil" then
            checker.typeerror(errors, exps[1].loc,
                "generic for iterator control result cannot be nil-only")
        elseif not forin_nil_capable_control(ctrltype) then
            checker.typeerror(errors, exps[1].loc,
                "generic for iterator control result must be optional, value, or a nullable C pointer but found %s",
                types.tostring(ctrltype))
        end
    end

    if ftype.params[1] then
        local old = exps[2]
        exps[2] = coerce_and_check(exps[2], ftype.params[1],
            "generic for iterator state", errors, exps[2].loc)
        replace_adjusted_value(tuple_adjustment, old, exps[2])
    end
    if ftype.params[2] then
        local old = exps[3]
        exps[3] = coerce_and_check(exps[3], ftype.params[2],
            "generic for iterator initial control", errors, exps[3].loc)
        replace_adjusted_value(tuple_adjustment, old, exps[3])
    end

    local close_type = exps[4]._type
    local close_ftype
    local close_cfunc
    -- A close slot whose static type is `value` can hold nil at run time. Keep
    -- the synthesized callable type for non-nil values, but tell codegen that
    -- nil means the optional close slot is absent rather than a call target.
    local runtime_optional_close = close_type._tag == "Type.Value"
    if close_type._tag == "Type.Nil" then
        node._has_close = false
    else
        if close_type._tag == "Type.Value" then
            close_ftype = synthesize_forin_close_type(exps)
            local old = exps[4]
            exps[4] = trycoerce(exps[4], close_ftype, errors)
            replace_adjusted_value(tuple_adjustment, old, exps[4])
            close_type = exps[4]._type
            close_ftype = call_signature(close_ftype)
        else
            close_ftype, close_cfunc =
                forin_signature_from_slot_type(close_type)
        end
    end
    if close_ftype then
        local close_ok = true
        if close_ftype.c_vararg or close_ftype.varargtype
           or #close_ftype.params > 1 then
            checker.typeerror(errors, exps[4].loc,
                "generic for close function must accept zero or one state argument")
            close_ok = false
        elseif close_ftype.params[1] then
            local state_for_close = exps[2]
            state_for_close = coerce_and_check(
                state_for_close, close_ftype.params[1],
                "generic for close argument", errors, exps[2].loc)
        end
        node._has_close = close_ok
    elseif close_type._tag ~= "Type.Nil" and close_type._tag ~= "Type.Invalid" then
        checker.typeerror(errors, exps[4].loc,
            "generic for close value must be nil, a function, value, or C function pointer but found %s",
            types.tostring(close_type))
        node._has_close = false
    end
    node._runtime_optional_close = node._has_close
        and runtime_optional_close or false

    node._tuple_decls = {
        hidden_decl(node.loc, "__forin_iter", exps[1]._type),
        hidden_decl(node.loc, "__forin_state", exps[2]._type),
        hidden_decl(node.loc, "__forin_init", exps[3]._type),
        hidden_decl(node.loc, "__forin_close", exps[4]._type),
    }
    node._result_decls = {}
    for i, rtype in ipairs(effective_results) do
        node._result_decls[i] = hidden_decl(node.loc,
            "__forin_result_" .. i, rtype)
    end

    local function arg_state()
        return hidden_exp(node.loc, node._tuple_decls[2])
    end
    local function arg_init()
        return hidden_exp(node.loc, node._tuple_decls[3])
    end
    local init_args = {}
    if ftype.params[1] then table.insert(init_args, arg_state()) end
    if ftype.params[2] then table.insert(init_args, arg_init()) end
    node._init_call = make_forin_call(node.loc, node._tuple_decls[1],
        init_args, ftype, #effective_results, iter_cfunc, errors, true)

    local next_args = {}
    if ftype.params[1] then table.insert(next_args, arg_state()) end
    if ftype.params[2] then
        local ctrlarg = hidden_exp(node.loc, node._result_decls[1])
        ctrlarg = tryforce(ctrlarg)
        ctrlarg = coerce_and_check(ctrlarg, ftype.params[2],
            "generic for iterator control argument", errors, node.loc)
        table.insert(next_args, ctrlarg)
    end
    node._next_call = make_forin_call(node.loc, node._tuple_decls[1],
        next_args, ftype, #effective_results, iter_cfunc, errors, false)

    if node._has_close then
        local close_args = {}
        if close_ftype.params[1] then
            local close_arg = hidden_exp(node.loc, node._tuple_decls[2])
            close_arg = trycoerce(close_arg, close_ftype.params[1], errors)
            table.insert(close_args, close_arg)
        end
        node._close_call = make_forin_call(node.loc, node._tuple_decls[4],
            close_args, close_ftype, 0, close_cfunc, errors, false)
        node._close_call._voidok = true
    end

    local visible_exps = {}
    for i, decl in ipairs(node.decls) do
        local exp
        if effective_results[i] then
            exp = hidden_exp(node.loc, node._result_decls[i])
            if i == 1 then
                exp = tryforce(exp)
            end
            exp = check_forin_decl_init(decl, exp, st, errors)
        else
            if decl.type then
                checkdecl(decl, st, errors)
                exp = coerce_and_check(nil_exp(node.loc), decl._type,
                    "generic for variable " .. decl.name,
                    errors, decl.loc)
            else
                checker.typeerror(errors, decl.loc,
                    "cannot infer type of generic for variable '%s' from a missing iterator result",
                    decl.name)
                decl._type = types.Invalid()
                exp = nil_exp(node.loc)
            end
        end
        decl._forcontrol = true
        table.insert(visible_exps, exp)
    end
    node._visible_stat = ast.StatDecl(node.loc, node.decls, visible_exps)

    for _, decl in ipairs(node.decls) do
        declare(decl, st, errors)
    end
    checkstat(node.block, st, errors)
    return false
end

-- Typechecks a block statement
--   node: StatBlock AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether the block cannot fall through to its following statement
function checkblock(node, st, errors)
    local ret = false
    for _, stat in ipairs(node.stats) do
        ret = ret or checkstat(stat, st, errors)
    end
    return ret
end

function copy_block(block)
    local copy = {}
    for name, decl in pairs(block) do
        copy[name] = decl
    end
    return copy
end

-- Falling through or writing a bare return can synthesize exactly one fixed
-- nil result. A flexible tail, when present, is independently empty. Multiple
-- fixed results must still be supplied explicitly, even when the first is nil.
function checker._accepts_implicit_nil_result(signature)
    return #signature.rettypes == 1
        and signature.rettypes[1]._tag == "Type.Nil"
end

local function const_module_write_authorized(decl, st)
    if not decl._initializerless_const then return false end
    local frame = func_stack[#func_stack]
    return frame
       and frame.module_initializer == st.modname
       and decl._module_name == st.modname
end

local function check_const_assignment(var, st, errors)
    local decl = var._decl
    if var._tag == "Ast.VarName" and decl then
        if decl._tag == "Ast.Decl" and decl.isconst then
            checker.typeerror(errors, var.loc,
                "cannot assign to const local '%s'", decl.name)
            var._const_write_rejected = true
        elseif decl._tag == "Ast.TopLevelVar" and decl.isconst
               and not const_module_write_authorized(decl, st) then
            if decl._initializerless_const
               and decl._module_name == st.modname then
                checker.typeerror(errors, var.loc,
                    "const module variable '%s' may only be assigned in its module initializer",
                    decl.decl.name)
            else
                checker.typeerror(errors, var.loc,
                    "cannot assign to const module variable '%s'",
                    decl.decl.name)
            end
            var._const_write_rejected = true
        end
    elseif var._tag == "Ast.VarDot" and decl then
        if decl._tag == "Type.ModuleVariable" and decl.isconst then
            checker.typeerror(errors, var.loc,
                "cannot assign to const module variable '%s'", decl.name)
            var._const_write_rejected = true
        elseif decl._tag == "Type.Field" and decl.isconst then
            checker.typeerror(errors, var.loc,
                "cannot assign to const field '%s'", decl.name)
            var._const_write_rejected = true
        end
    elseif var._tag == "Ast.VarBracket"
       and var.exp1 and var.exp1._type
       and var.exp1._type._tag == "Type.Array"
       and var.exp1._type.isconst then
        checker.typeerror(errors, var.loc,
            "cannot assign to an element of const Array '%s'",
            types.tostring(var.exp1._type))
        var._const_write_rejected = true
    end
end

-- Typechecks a statement or declaration
--   node: A DeclDecl or Stat_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether the statement cannot fall through
checkstat_visitor = util.make_visitor({
    ["Ast.StatDecl"] = function(node, st, errors)
        if #node.exps == 0 then
            node._omitted_initializer = true
            local nils = {}
            for index, decl in ipairs(node.decls) do
                local value = ast.ExpNil(decl.loc)
                if not decl.type then
                    checker.typeerror(errors, decl.loc,
                        "local variable '%s' without an initializer requires an explicit type",
                        decl.name)
                    decl._type = types.Invalid()
                    value._type = decl._type
                else
                    checkdecl(decl, st, errors)
                    if not types.accepts_missing_nil(decl._type) then
                        checker.typeerror(errors, decl.loc,
                            "local variable '%s' cannot be initialized with nil because type '%s' does not accept nil",
                            decl.name, types.tostring(decl._type))
                        value._type = types.Invalid()
                    else
                        checkexp(value, st, errors, decl._type)
                        value = coerce_and_check(
                            value, decl._type,
                            "nil initialization of local variable " ..
                                decl.name,
                            errors, decl.loc)
                    end
                end
                nils[index] = value
                declare(decl, st, errors)
            end
            node.exps = nils
            node._result_adjustment = {
                kind = "expression_list_adjustment",
                exps = nils,
                fixed = nils,
                tail_scalars = {},
                discards = {},
                open_source = false,
            }
            return
        end

        local fixed = {}
        for i, decl in ipairs(node.decls) do
            if decl.type then
                if decl.type._tag == "Ast.TypeCArray"
                   and not decl.type.length then
                    local written = typefromnode(decl.type, st, errors)
                    decl._written_c_array_view = written
                    decl._type = types.CPointer(written.elem, written.quals or {})
                    checktype(decl._type, decl.loc, errors)
                else
                    checkdecl(decl, st, errors)
                end
                fixed[i] = decl._type
            else
                fixed[i] = UNKNOWN_SLOT
            end
        end

        local adjusted = adjust_explist(node.exps,
            result_demand(fixed, false, {
                term = "left-hand side",
                loc = node.loc,
                missing = "error",
                explicit_surplus = "discard",
                slot_term = function(i)
                    local decl = node.decls[i]
                    return decl and
                        ("declaration of local variable " .. decl.name)
                        or "local declaration"
                end,
                check_expression = function(exp, est, eerrors, context,
                                             subdemand, sink_index)
                    subdemand.allocation_decl = node.decls[sink_index]
                    checkexp(exp, est, eerrors, context, subdemand)
                end,
            }), st, errors)
        node.exps = adjusted.exps
        node._result_adjustment = adjusted

        for i, decl in ipairs(node.decls) do
            local exp = adjusted.fixed[i]
            if exp and not decl.type then
                local old = exp
                if decl.option then
                    decl._type = optionize(exp._type)
                else
                    exp = tryforce(exp) -- never infer an option type
                    decl._type = exp._type
                end
                checkdecl(decl, st, errors)
                if types.is_c_array(decl._type)
                   and not (decl._c_allocation_plan
                            and decl._c_allocation_plan.storage == "automatic_array") then
                    checker.typeerror(errors, decl.loc,
                        "cannot initialize a local by copying a whole C array")
                end
                exp = coerce_and_check(exp, decl._type,
                    "declaration of local variable " .. decl.name,
                    errors, decl.loc)
                replace_adjusted_value(adjusted, old, exp)
            end
            if exp and decl.type and types.is_c_array(decl._type)
               and not (decl._c_allocation_plan
                        and decl._c_allocation_plan.storage == "automatic_array") then
                checker.typeerror(errors, decl.loc,
                    "cannot initialize a local by copying a whole C array")
            end
            if not decl._type then
                -- no initializer reached this declaration (too few values on
                -- the right-hand side, e.g. `local a, b = (f())`): the arity
                -- error above is already reported; recover the type so later
                -- uses of this variable don't crash the checker with a nil type
                if decl.type then
                    checkdecl(decl, st, errors)
                else
                    decl._type = types.Invalid()
                end
            end
            decl._init_exp = exp
            declare(decl, st, errors)
        end
        node.exps = adjusted.exps
    end,

    ["Ast.StatBlock"] = function(node, st, errors)
        return st:with_block(checkblock, node, st, errors)
    end,

    ["Ast.StatWhile"] = function(node, st, errors)
        checkcondition(node.condition, st, errors)
        local frame = { has_break = false }
        loop_depth = loop_depth + 1
        table.insert(loop_frames, frame)
        st:with_block(checkstat, node.block, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1

        -- A literal-true while cannot fall through unless a reachable break
        -- targets it. Errors still compose soundly: a surrounding StatTry
        -- requires its catch to be non-fallthrough too.
        return node.condition._tag == "Ast.ExpBool"
            and node.condition.value == true
            and not frame.has_break
    end,

    ["Ast.StatRepeat"] = function(node, st, errors)
        loop_depth = loop_depth + 1
        table.insert(loop_frames, { has_break = false })
        st:with_block(checkrepeat, node, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1
        return false
    end,

    ["Ast.StatFor"] = function(node, st, errors)
        local frame = { has_break = false }
        loop_depth = loop_depth + 1
        table.insert(loop_frames, frame)
        st:with_block(checkfor, node, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatForIn"] = function(node, st, errors)
        local frame = { has_break = false }
        loop_depth = loop_depth + 1
        table.insert(loop_frames, frame)
        st:with_block(checkforin, node, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatBreak"] = function(node, _, errors)
        local valid = true
        if loop_depth == 0 then
            checker.typeerror(errors, node.loc,
                "'break' outside a loop")
            valid = false
        elseif in_finally > 0 and loop_depth <= finally_loop_floor then
            -- Inside a finally with no loop opened *inside* it: the target loop
            -- encloses the finally, so this `break` would escape it (forbidden).
            -- A `break` to a loop written inside the finally (loop_depth above
            -- the floor) is contained and legal.
            checker.typeerror(errors, node.loc,
                "'break' cannot escape a finally block")
            valid = false
        end
        if valid then
            local frame = loop_frames[#loop_frames]
            if frame then
                frame.has_break = true
            end
        end
        return false
    end,

    ["Ast.StatRaise"] = function(node, st, errors)
        if not node.exp then
            -- Bare `raise` (re-raise the in-flight error) is legal only lexically
            -- inside a catch block. `catch_depth` is reset across nested function
            -- bodies, so a bare `raise` in a lambda defined in a catch is still
            -- rejected (it has no in-flight error of its own).
            if catch_depth == 0 then
                checker.typeerror(errors, node.loc,
                    "bare 'raise' (a re-raise) is only valid inside a catch block")
            end
        else
            -- `raise <exp>`: the error object may be any value, so check the
            -- operand with `value` as the expected type (every value coerces to
            -- `value`) and materialize the coercion so the coder boxes it.
            checkexp(node.exp, st, errors, types.Value())
            node.exp = coerce_and_check(
                node.exp, types.Value(), "raise", errors, node.loc)
        end
        -- `raise` is a terminator: control never falls through it.
        return true
    end,

    ["Ast.StatTry"] = function(node, st, errors)
        -- The protected body, the catch handler, and the finally cleanup are
        -- SIBLING scopes, not nested: a body local may be undeclared when the
        -- error fires, so it must not be visible in catch/finally. Check each in
        -- its own block, closing the previous one first.
        local saved_block_index, saved_body_block
        local bret
        if node._defer_tail then
            -- Parser-lowered `defer` protects the rest of the same simpleblock.
            -- A `repeat ... until` condition is scoped with its body, so locals
            -- declared in that tail must remain visible after the synthetic try.
            -- They must still be hidden from the cleanup itself, which is checked
            -- as the sibling `finally` below.
            saved_block_index = #st.blocks
            local before_body = copy_block(st.blocks[saved_block_index])
            bret = checkblock(node.block, st, errors)
            saved_body_block = st.blocks[saved_block_index]
            st.blocks[saved_block_index] = before_body
        else
            bret = st:with_block(checkstat, node.block, st, errors)
        end

        local cret = false
        if node.catchblock then
            -- The catch block binds two implicit locals: `error: value` (the
            -- raised value) and `traceback: string` (its captured trace). They
            -- live in a fresh sibling scope so the body's locals are out of
            -- view. Mark them `_used` so the unused-local analysis ignores them.
            st:open_block(node.catchblock)
            local errdecl = ast.Decl(node.loc, "error", false, false, false)
            errdecl._type = types.Value()
            errdecl._used = true
            errdecl._catch_implicit = true
            declare(errdecl, st, errors)
            local tbdecl = ast.Decl(
                node.loc, "traceback", false, false, false)
            tbdecl._type = types.String()
            tbdecl._used = true
            tbdecl._catch_implicit = true
            declare(tbdecl, st, errors)
            node._error_decl = errdecl
            node._traceback_decl = tbdecl
            catch_depth = catch_depth + 1
            cret = checkstat(node.catchblock, st, errors)
            catch_depth = catch_depth - 1
            st:close_block()
        end

        local fret = false
        if node.finallyblock then
            -- A finally is straight-line: no `return` and no finally-escaping
            -- `break` may leave it (only a `raise` overrides). Bump `in_finally`
            -- and stamp `finally_loop_floor` to the current loop depth (so a
            -- `break` to a loop opened INSIDE the finally is still legal),
            -- saving/restoring the outer floor for nested constructs.
            st:open_block(node.finallyblock)
            in_finally = in_finally + 1
            local saved_catch = catch_depth
            catch_depth = 0
            local saved_floor = finally_loop_floor
            finally_loop_floor = loop_depth
            fret = checkstat(node.finallyblock, st, errors)
            finally_loop_floor = saved_floor
            catch_depth = saved_catch
            in_finally = in_finally - 1
            st:close_block()
        end

        if saved_body_block then
            st.blocks[saved_block_index] = saved_body_block
        end

        -- Non-fallthrough (B.2): the construct cannot reach its successor iff
        -- the finally cannot fall through, OR the body cannot fall through and
        -- (there is no catch, or the catch also cannot fall through). `raise`
        -- counts as a terminator, so an unconditional finally raise satisfies
        -- `fret`.
        return (node.finallyblock and fret)
            or (bret and (not node.catchblock or cret))
    end,

    ["Ast.StatAssign"] = function(node, st, errors)
        if node._parsed_candidates then
            local vars, valid = {}, true
            for i, exp in ipairs(node.vars) do
                if exp._tag == "Ast.ExpVar" and not exp._parenthesized
                   and not exp._nominal_typeargs then
                    vars[i] = exp.var
                else
                    checker.typeerror(errors, exp.loc,
                        "left-hand side of assignment is not an assignable variable")
                    valid = false
                end
            end
            if not valid then
                for _, exp in ipairs(node.exps) do checkexp(exp, st, errors) end
                return false
            end
            node.vars, node._parsed_candidates = vars, nil
        end
        for _, var in ipairs(node.vars) do
            -- The outer lvalue is not an observation. In particular, a typed
            -- Array/Map write may store a raw C pointer even though reading
            -- that same slot type cannot establish its pointee identity.
            -- Nested receivers (as in a[i][j]) are still checked normally
            -- when the outer VarBracket checks its exp1.
            checkvar(var, st, errors, nil, "write")
            check_const_assignment(var, st, errors)
            check_c_assignment_storage(var, errors)
            if var._type and types.is_c_array(var._type) then
                checker.typeerror(errors, var.loc,
                    "cannot assign to a whole C array; assign its elements "
                    .. "or retain a pointer instead")
            end
        end
        local fixed = {}
        for i, var in ipairs(node.vars) do
            -- Module values are never assignable and have no ordinary value
            -- coercion/tostring path; preserve the dedicated diagnostic below
            -- while still reserving their finite expression-list slot.
            local decl = var._decl
            local function_decl =
                (var._type._tag == "Type.Function"
                 or var._type._tag == "Type.CFunction")
                and decl
                and (decl._tag == "Ast.TopLevelFunc"
                     or decl._tag == "Ast.TopLevelForeignFunc"
                     or decl._tag == "Type.ModuleMember"
                     or decl._tag == "Type.StaticMethod")
            fixed[i] = (var._type._tag == "Type.Module" or function_decl)
                and UNKNOWN_SLOT or var._type
        end
        local adjusted = adjust_explist(node.exps,
            result_demand(fixed, false, {
                term = "left-hand side",
                loc = node.loc,
                missing = "error",
                explicit_surplus = "discard",
                slot_term = function() return "assignment" end,
            }), st, errors)
        node.exps = adjusted.exps
        node._result_adjustment = adjusted

        for i, var in ipairs(node.vars) do
            local exp = adjusted.fixed[i]
            if exp then
                local texp = var._type
                if texp._tag == "Type.Module" then
                    checker.typeerror(errors, var.loc, "trying to assign to a module")
                elseif (texp._tag == "Type.Function"
                        or texp._tag == "Type.CFunction") and var._decl
                       and (var._decl._tag == "Ast.TopLevelFunc"
                            or var._decl._tag == "Ast.TopLevelForeignFunc"
                            or var._decl._tag == "Type.ModuleMember"
                            or var._decl._tag == "Type.StaticMethod") then
                    -- Cannot rebind a function *declaration* (top-level
                    -- function, imported module function, or record function).
                    -- Assigning a value *into* a function-typed local, param
                    -- or field is fine and falls through to the normal path.
                    checker.typeerror(errors, var.loc, "trying to assign to a function")
                elseif var._tag == "Ast.VarDot" and var._decl
                       and var._decl._tag == "Type.ModuleMember" then
                    checker.typeerror(errors, var.loc, "cannot assign to foreign variable '%s'", var.name)
                else
                    -- mark this declared variable as assigned to
                    if var._tag == "Ast.VarName" and var._decl then
                        if var._decl._readonly then
                            checker.typeerror(errors, var.loc,
                                "cannot assign to built-in local '%s'",
                                var._decl.name)
                        end
                        if var._decl._forcontrol then
                            checker.typeerror(errors, var.loc,
                                "cannot assign to 'for' control variable '%s'",
                                var._decl.name)
                        end
                        if var._decl._catch_implicit then
                            checker.typeerror(errors, var.loc,
                                "cannot assign to catch local '%s'",
                                var._decl.name)
                        end
                        if not var._const_write_rejected then
                            var._decl._assigned = true
                        end
                    end
                    local old = exp
                    exp = coerce_and_check(
                        exp, var._type, "assignment", errors, var.loc)
                    replace_adjusted_value(adjusted, old, exp)
                end
            end
        end
        node.exps = adjusted.exps
    end,

    ["Ast.StatCall"] = function(node, st, errors)
        if node.callexp._tag ~= "Ast.ExpCall" then
            local marked = completion_contains(node.callexp, st)
            if marked then checkexp(node.callexp, st, errors) end
            checker.typeerror(errors, node.callexp.loc,
                "only a function call may be used as a statement")
            if marked then
                st.completion_statement_errors = st.completion_statement_errors or {}
                st.completion_statement_errors[errors[#errors]] = true
            end
            return false
        end
        -- A call in statement position may discard its result, including a
        -- zero-return `() -> ()` call that produces no value at all.
        node.callexp._voidok = true
        checkexp(node.callexp, st, errors)
    end,

    ["Ast.StatReturn"] = function(node, st, errors)
        -- Nothing may statically leave a finally (only an unpreventable raise
        -- can): a `return` lexically inside a finally is a compile error.
        -- `in_finally` is reset across nested function bodies, so a `return` in a
        -- lambda DEFINED in a finally is the lambda's own and is legal.
        if in_finally > 0 then
            checker.typeerror(errors, node.loc,
                "cannot 'return' from inside a finally block")
        end
        local ftype = st:find_symbol("$function")._type
        local signature = assert(call_signature(ftype),
            "return statement lacks a callable signature")
        local implicit_nil = checker._accepts_implicit_nil_result(signature)
        local fixed = {}
        for i, typ in ipairs(signature.rettypes) do fixed[i] = typ end
        local adjusted = adjust_explist(node.exps,
            result_demand(fixed, signature.flexrettype, {
                term = "return",
                loc = node.loc,
                missing = implicit_nil and "nil" or "error",
                explicit_surplus = "discard",
                return_arity = true,
                open_coerce = true,
                slot_term = function() return "return" end,
            }), st, errors)
        node.exps = adjusted.exps
        node._result_adjustment = adjusted
        return true
    end,

    ["Ast.StatCase"] = function(node, st, errors)
        checkexp(node.exp, st, errors)
        node.exp = tryforce(node.exp)

        local union
        local scrutinee_type = node.exp._type
        if scrutinee_type._tag ~= "Type.Nominal" then
            checker.typeerror(errors, node.exp.loc,
                "case expression must have a union type, but found '%s'",
                types.tostring(scrutinee_type))
        else
            local owner = generic_applied_owner_view(
                scrutinee_type, errors, node.exp.loc)
            if not owner then
                checker.typeerror(errors, node.exp.loc,
                    "union type '%s' in case expression does not exist",
                    scrutinee_type.fqtn)
            elseif owner._tag ~= "Type.Union" then
                checker.typeerror(errors, node.exp.loc,
                    "case expression must have a union type, but found '%s'",
                    types.tostring(scrutinee_type))
            elseif not is_nominal_visible_from(st, scrutinee_type.fqtn) then
                checker.typeerror(errors, node.exp.loc,
                    "union type '%s' is local to module '%s'",
                    scrutinee_type.fqtn,
                    nominal_module(scrutinee_type.fqtn))
            else
                union = owner
                node._union = owner
            end
        end

        local seen_variants = {}
        local covered_variants = 0
        local all_arms_return = true
        for _, arm in ipairs(node.arms) do
            st:open_block(arm)
            local variant = union and union.variants[arm.name] or nil
            if variant
               and not is_nominal_member_visible_from(st, variant) then
                variant = nil
            end
            if not variant then
                checker.typeerror(errors, arm.loc,
                    "variant '%s' not found in union '%s'",
                    arm.name,
                    union and union.name or types.tostring(scrutinee_type))
            else
                local previous = seen_variants[variant]
                if previous then
                    checker.typeerror(errors, arm.loc,
                        "duplicate case arm for variant '%s', previous one at %s",
                        arm.name, location.format(previous.loc))
                else
                    seen_variants[variant] = arm
                    covered_variants = covered_variants + 1
                end
                arm._variant = variant
                arm._decl = variant
                arm._variant_index = variant.index
            end

            if arm.binding then
                if not variant then
                    arm.binding._type = types.Invalid()
                elseif variant.payload == false then
                    arm.binding._type = types.Invalid()
                    checker.typeerror(errors, arm.binding.loc,
                        "empty variant '%s.%s' has no payload to bind",
                        union.name, variant.name)
                else
                    arm.binding._type = variant.payload
                end
                declare(arm.binding, st, errors)
            end

            local arm_returns = checkstat(arm.block, st, errors)
            if not arm_returns then all_arms_return = false end
            st:close_block()
        end

        local else_returns = false
        if node.elseblock then
            else_returns = checkstat(node.elseblock, st, errors)
        end
        local variants_exhausted = union ~= nil
            and covered_variants == union.nvariants
        return all_arms_return and (variants_exhausted or else_returns)
    end,

    ["Ast.StatIf"] = function(node, st, errors)
        local ret = true
        for _, thn in ipairs(node.thens) do
            checkcondition(thn.condition, st, errors)
            ret = checkstat(thn.block, st, errors) and ret
        end
        if node.elsestat then
            ret = checkstat(node.elsestat, st, errors) and ret
        else
            ret = false
        end
        return ret
    end,
})

-- Preserve the existing reachability result on every checked statement.
-- Compound coders need the same fact even when checkblock short-circuits after
-- an earlier non-fallthrough child. `_always_returns` is the historical field
-- name for this generalized fact.
checkstat = function(node, st, errors)
    local ret = checkstat_visitor(node, st, errors)
    node._always_returns = ret and true or false
    return ret
end

return core.checker
