local core = require "titan-compiler.checker.core"
local _ENV = core

--
-- Var
--

-- Typechecks an variable node
--   node: Var_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   mode: "write" only for the outer variable of an assignment target
--   annotates the node with its type in a "_type" field
checkvar = util.make_visitor({
    ["Ast.VarName"] = function(node, st, errors, _)
        completion_lexical(node, st, errors, node._current_module_member and "dot" or "lexical", node._current_module_member)
        local decl
        if node._current_module_member then
            decl = st.blocks[1][node.name]
            if decl and (decl._builtin or st:hidden_from_initializer(decl)) then
                decl = nil
            end
        else
            decl = st:find_symbol(node.name)
        end
        if not decl then
            local alias = st:find_type_alias(node.name)
            local resolved_alias = alias
                and resolve_type_alias(alias, st, errors) or nil
            local namespace = resolved_alias
                and alias_namespace_type(resolved_alias, st)
            local interface = st.interface_declarations
                and st.interface_declarations[node.name]
            if namespace then
                generic_annotate_alias_namespace(
                    node, resolved_alias, namespace)
                node._alias_decl = alias
                node._decl = alias
                node._type = namespace
            elseif interface then
                node._type = invalid(errors, node.loc,
                    "interface '%s' is a type and has no runtime value",
                    node.name)
            else
                node._type = invalid(errors, node.loc,
                    "variable '%s' not declared", node.name)
            end
        else
            node._decl = decl
            node._type = decl._type
            if node._type and (node._type._tag == "Type.Record"
                    or node._type._tag == "Type.Union") then
                node._generic_namespace_owner = node._type.scope ~= false
                    and node._type or types.registry[node._type.name]
                node._generic_namespace_arguments = false
                node._generic_namespace_fixed = false
            end
            if checker._foreign_function_depth > 0 then
                local tag = decl._tag
                local allowed = tag == "Ast.Decl"
                    or tag == "Ast.TopLevelForeignFunc"
                    or tag == "Checker.ForeignNamespace"
                    or (tag == "Ast.TopLevelImport" and decl._source_import)
                if not allowed then
                    node._type = invalid(errors, node.loc,
                        "ordinary Titan declaration '%s' is not visible inside a foreign function",
                        node.name)
                end
            end
            -- Capture detection (single chokepoint). A local/param (`Ast.Decl`,
            -- which excludes top-level functions/vars and module members) used
            -- from a function nested deeper than where it was declared is
            -- captured by every intervening lambda, INCLUSIVE of the current
            -- (innermost) one.
            if decl._tag == "Ast.Decl" and decl._funcdepth
               and decl._funcdepth < #func_stack then
                if types.is_c_aggregate(decl._type) then
                    checker.typeerror(errors, node.loc,
                        "cannot capture C aggregate variable '%s'; capture "
                        .. "an explicit pointer to its automatic storage "
                        .. "instead",
                        node.name)
                elseif decl._c_address_taken then
                    checker.typeerror(errors, node.loc,
                        "cannot capture variable '%s' after taking its mutable C address",
                        node.name)
                else
                    decl._captured = true
                    -- A variable only *written* (never read) by a nested
                    -- function would otherwise miss StatDecl's `_used` gate
                    -- and never get a box allocated; force it used here.
                    decl._used = true
                    for d = decl._funcdepth + 1, #func_stack do
                        local frame = func_stack[d]
                        if not frame.capture_set[decl] then
                            frame.capture_set[decl] = true
                            table.insert(frame.captures, decl)
                        end
                    end
                end
            end
        end
    end,

    ["Ast.VarDot"] = function(node, st, errors, context, mode)
        local receiver = node.exp
        if receiver._tag == "Ast.ExpVar"
           and receiver.var._tag == "Ast.VarName" then
            local binding = st:find_symbol(receiver.var.name)
            if binding and binding._current_module then
                completion_lexical(node, st, errors, "dot", true)
                node._tag = "Ast.VarName"
                node._module_loc = receiver.loc
                node._current_module_member = true
                node.exp = nil
                return checkvar(node, st, errors, context)
            end
        end
        return generic_with_inference_operation(node, st,
        function(operation)
        local written_exp = node.exp
        local nominal_field_projection = false
        if node.exp._tag == "Ast.ExpVar" then
            generic_checkvar_for_expression(node.exp, st, errors)
            if node.exp.var._decl then node.exp.var._decl._used = true end
            node.exp._type = node.exp.var._type
        else
            checkexp(node.exp, st, errors,
                node.exp._tag == "Ast.ExpForeignType"
                    and c_type_namespace_context or nil)
        end
        if node.exp._nominal_typeargs ~= nil then
            generic_apply_namespace_typeargs(node.exp, st, errors)
        end
        node.exp = tryforce(node.exp)
        local ltype = node.exp._type
        if ltype._tag == "Type.Parameter"
           and ltype.erased_constraint ~= false
           and ltype.erased_constraint._tag == "Type.Nominal" then
            local constraint = generic_applied_owner_view(
                ltype.erased_constraint, errors, node.loc)
            if constraint and constraint._tag == "Type.Interface" then
                node._rigid_receiver_type = ltype
                ltype = ltype.erased_constraint
            end
        end
        completion_members(node, node.exp, ltype, st, errors, "dot")
        if node._contextual_c_name
           and ltype._tag ~= "Type.CModule"
           and not types.is_direct_c(ltype)
           and not is_c_type_namespace(node.exp) then
            node._type = invalid(errors, node.loc,
                "Titan keyword '%s' is only contextual for a C member",
                node.name)
            return
        end
        if ltype._tag == "Type.Module" or ltype._tag == "Type.CModule" then
            local mod = ltype
            local import_decl = node.exp._tag == "Ast.ExpVar"
                and node.exp.var and node.exp.var._decl
            local include_source = import_decl
                and import_decl._tag == "Ast.TopLevelImport"
                and import_decl._source_import == true
            local module_member = ltype._tag == "Type.Module"
                and types.module_member(mod, node.name, include_source)
                or mod.members[node.name]
            local type_member, type_member_islocal
            if ltype._tag == "Type.Module" then
                type_member, type_member_islocal =
                    types.module_type_member(
                        mod, node.name, include_source)
            end
            if module_member then
                node._decl = module_member
                node._type = node._decl.type
                if ltype._tag == "Type.Module"
                   and (node._type._tag == "Type.Record"
                        or node._type._tag == "Type.Union") then
                    node._generic_namespace_owner = node._type.scope ~= false
                        and node._type or types.registry[node._type.name]
                    node._generic_namespace_arguments = false
                    node._generic_namespace_fixed = false
                end
            elseif type_member then
                local namespace = alias_namespace_type(type_member, st)
                if namespace then
                    generic_annotate_alias_namespace(
                        node, type_member, namespace)
                    node._alias_type = type_member
                    node._decl = {
                        _tag = "Checker.TypeMember",
                        modname = mod.name,
                        name = node.name,
                        type = type_member,
                        islocal = type_member_islocal,
                    }
                    node._type = namespace
                elseif type_member._tag == "Type.Interface" then
                    node._type = invalid(errors, node.loc,
                        "interface '%s' is a type and has no runtime value",
                        node.name)
                else
                    node._type = invalid(errors, node.loc,
                        "member '%s' not found inside module '%s'",
                        node.name, mod.name)
                end
            elseif not module_member then
                node._type = invalid(errors, node.loc,
                    "member '%s' not found inside module '%s'",
                    node.name, mod.name)
            end
        elseif ltype._tag == "Type.Record"
           or ltype._tag == "Type.Union" then
            local namespace = node.exp._tag == "Ast.ExpVar"
                and node.exp.var or nil
            local owner = namespace and namespace._generic_namespace_owner
                or types.registry[ltype.name] or ltype
            local decl = ltype.functions[node.name]
            local canonical = owner.functions and owner.functions[node.name]
                or decl
            if decl then
                if not is_nominal_member_visible_from(st, decl) then
                    local kind = ltype._tag == "Type.Record"
                        and "record" or "union"
                    node._type = invalid(errors, node.loc,
                        "%s function '%s.%s' is local to module '%s'",
                        kind, ltype.name, node.name,
                        nominal_module(ltype.name))
                else
                    node._decl = canonical
                    node._closed_generic_declaration = decl
                    node._type = types.Function(decl.params, decl.rettypes, false,
                        decl.varargtype, decl.flexrettype)
                    node._generic_owner = owner
                    node._generic_owner_arguments = namespace
                        and namespace._generic_namespace_arguments or false
                    node._generic_owner_fixed = namespace
                        and namespace._generic_namespace_fixed or false
                    node._generic_owner_explicit = namespace
                        and namespace._generic_namespace_explicit or false
                    if canonical._owner_scope or canonical.scope or owner.scope then
                        node._generic_declaration = canonical
                    end
                    -- Preserve the physical imported-module userdata that owns
                    -- a qualified namespace (`m.Rec.static` / `m.U.variant`).
                    -- Direct calls already recover this through the nested
                    -- VarDot shape; first-class selector reads need an explicit
                    -- stable decoration once checking has resolved the static.
                    local namespace = node.exp._tag == "Ast.ExpVar"
                        and node.exp.var or nil
                    if namespace and namespace._alias_namespace then
                        node._alias_namespace = true
                    end
                    local import_var = namespace
                        and namespace._tag == "Ast.VarDot"
                        and namespace.exp
                        and namespace.exp._tag == "Ast.ExpVar"
                        and namespace.exp.var or nil
                    if import_var and import_var._decl
                       and import_var._decl._tag == "Ast.TopLevelImport" then
                        node._import_decl = import_var._decl
                    end
                end
            else
                local kind = ltype._tag == "Type.Record"
                    and "record" or "union"
                node._type = invalid(errors, node.loc,
                    "trying to access invalid %s function '%s'",
                    kind, node.name)
            end
        elseif ltype._tag == "Type.Nominal" then
            local type = generic_applied_owner_view(ltype, errors, node.loc)
            if not type then
                node._type = invalid(errors, node.loc,
                    "type '%s' not found", ltype.fqtn)
            elseif not is_nominal_visible_from(st, ltype.fqtn) then
                node._type = invalid(errors, node.loc,
                    "record type '%s' is local to module '%s'",
                    ltype.fqtn, nominal_module(ltype.fqtn))
            elseif type._tag == "Type.Union" then
                node._type = invalid(errors, node.loc,
                    "union value of type '%s' has no fields; use a case statement",
                    ltype.fqtn)
            elseif type._tag == "Type.Interface" then
                local field = type.fields and type.fields[node.name]
                if field then
                    node._decl = field
                    node._type = field.type
                    node._interface = type
                    node._interface_field = field
                    node._interface_field_index = field.index
                    nominal_field_projection = true
                else
                    node._type = invalid(errors, node.loc,
                        "field '%s' not found in interface '%s'",
                        node.name, ltype.fqtn)
                end
            elseif type._tag ~= "Type.Record" then
                node._type = invalid(errors, node.loc,
                    "trying to access field '%s' of type '%s' that is not a record but '%s'",
                    node.name, ltype.fqtn, type._tag)
            else
                for _, field in ipairs(type.fields) do
                    if field.name == node.name
                       and is_nominal_member_visible_from(st, field) then
                        node._decl = field
                        local storage = checker._nominal_storage_plan(field.type)
                        node._nominal_storage = storage
                        node._nominal_projection_type = storage.projection_type
                        node._type = mode == "write" and storage.storage_type
                            or storage.projection_type
                        nominal_field_projection = true
                        break
                    end
                end
                if not node._type then
                node._type = invalid(errors, node.loc,
                    "field '%s' not found in record '%s'",
                    node.name, ltype.fqtn)
                end
            end
        elseif types.is_direct_c(ltype) or is_c_type_namespace(node.exp) then
            if is_c_type_namespace(node.exp) then
                local pseudo_error
                node._decl, pseudo_error =
                    c_pseudo_member(ltype, node.name, st)
                if node._decl
                   and node._decl._tag == "Checker.CPseudoNew" then
                    if context == c_pseudo_callee_context then
                        -- This syntax-bound declaration has no value type. The
                        -- enclosing ExpCall consumes `_decl` before ordinary
                        -- invalid-callee recovery.
                        node._type = types.Invalid()
                    else
                        node._type = invalid(errors, node.loc,
                            "C allocation pseudo-member '%s' can only be called directly",
                            node.name)
                    end
                elseif node._decl then
                    node._type = node._decl.type
                elseif pseudo_error then
                    node._type = invalid(errors, node.loc,
                        pseudo_error)
                else
                    node._type = invalid(errors, node.loc,
                        "C type '%s' has no pseudo-member '%s'",
                        types.tostring(ltype), node.name)
                end
            else
                local field_error
                node._decl, field_error =
                    c_field_decl(ltype, node.name, st)
                if node._decl then
                    node._type = node._decl.type
                elseif field_error then
                    node._type = invalid(errors, node.loc,
                        field_error)
                else
                    node._type = invalid(errors, node.loc,
                        "field '%s' not found in C type '%s'",
                        node.name, types.tostring(ltype))
                end
            end
        else
            node._type = invalid(errors, node.loc,
                "trying to access a member of value of type '%s'",
                types.tostring(ltype))
        end
        if node._decl and node._decl._tag == "Type.CField"
           and node._decl.flexible_array then
            local resolved_base = c_resolve(ltype)
            if resolved_base._tag == "Type.COwned"
               and not resolved_base.count then
                local owner = c_resolve(resolved_base.pointee)
                if owner._tag == "Type.CStruct" and owner.has_fam then
                    node._c_fam_access = {
                        kind = "owned",
                        field = node._decl,
                    }
                end
            elseif node.exp._tag == "Ast.ExpVar"
                   and node.exp.var._tag == "Ast.VarName" then
                local root = node.exp.var._decl
                local plan = root and root._c_allocation_plan
                if plan and plan.storage == "automatic_fam" then
                    node._c_fam_access = {
                        kind = "automatic",
                        field = node._decl,
                        count = plan.fam_count_literal,
                        root = root,
                    }
                end
            end
        end
        if checker._foreign_function_depth > 0 and ltype._tag == "Type.Module"
           and not checker._foreign_function_reference(node) then
            node._type = invalid(errors, node.loc,
                "ordinary Titan member '%s.%s' is not visible inside a foreign function",
                ltype.name, node.name)
        end
        if node._type and node._type._tag ~= "Type.Invalid" then
            local spelling_only = context
                and node.exp._type._tag == "Type.CModule"
                and node._type._tag == "Type.CFunction"
                and c_function_pointer_type(context) ~= nil
            if not checker._ensure_c_enum_supported(
                    st, node._type, node.loc, errors, nil,
                    spelling_only and true or false) then
                node._type = types.Invalid()
            end
        end
        if nominal_field_projection then
            generic_defer_inference_derived_annotations(
                operation, node, {
                    _type = true,
                    _decl = true,
                    _interface = true,
                    _interface_field = true,
                    _interface_field_index = true,
                    _rigid_receiver_type = true,
                    _nominal_storage = true,
                    _nominal_projection_type = true,
                    _assignment_adjustment = function(value)
                        return generic_finalize_adjustment_annotation(
                            operation, value)
                    end,
                }, function()
                    -- Rebuild only the checker-synthesized Option projection.
                    -- The written receiver and its nested uses were checked
                    -- exactly once and have already finalized in postorder.
                    node.exp = written_exp
                    if node.exp._type._tag == "Type.Option"
                       and node.exp._type.base._tag == "Type.Nominal" then
                        node.exp = tryforce(node.exp)
                    end
                end)
        end
        end, "field projection")
    end,

    ["Ast.VarBracket"] = function(node, st, errors, _, mode)
        return generic_with_inference_operation(node, st,
        function(operation)
        local written_exp1, written_exp2 = node.exp1, node.exp2
        checkexp(node.exp1, st, errors)
        node.exp1 = tryforce(node.exp1)

        local provisional = node.exp1._type
        local dependent_container = operation
            and (provisional._tag == "Type.Array"
                or provisional._tag == "Type.Map")
            and generic_inference_type_has_unresolved(
                operation.context, provisional)
        if dependent_container then
            local keystype, term
            if provisional._tag == "Type.Array" then
                node._type = optionize(provisional.elem)
                keystype = types.Integer()
                term = "array indexing"
            else
                node._type = optionize(provisional.values)
                keystype = provisional.keys
                term = "map indexing"
            end
            node._read_guard = false
            node._generic_read_type = nil

            local expected = generic_closed_inference_pattern(
                operation.context, keystype)
            checkexp(written_exp2, st, errors, expected,
                generic_dependent_scalar_demand(
                    operation, keystype, expected,
                    term .. " key", written_exp2.loc))
            node.exp2 = written_exp2
            generic_unify_inference(operation.context,
                keystype, written_exp2._type, term .. " key", node.loc)

            generic_defer_inference_derived_annotations(
                operation, node, {
                    _type = true,
                    _assignment_adjustment = function(value)
                        return generic_finalize_adjustment_annotation(
                            operation, value)
                    end,
                }, function()
                    node.exp1 = written_exp1
                    node.exp1 = tryforce(node.exp1)
                    local closed = node.exp1._type
                    local final_key, elem
                    if closed._tag == "Type.Array" then
                        final_key, elem = types.Integer(), closed.elem
                        term = "array indexing"
                    elseif closed._tag == "Type.Map" then
                        final_key, elem = closed.keys, closed.values
                        term = "map indexing"
                    else
                        -- The provisional structural owner cannot change after
                        -- invariant unification; retain finite recovery if an
                        -- earlier conflict made the context invalid.
                        node._type = types.Invalid()
                        node._read_guard = false
                        return
                    end
                    node._type = optionize(elem)
                    local read_type = generic_runtime_carrier(
                        node._type)
                    node._read_guard = types.gradual_guard(read_type) or false
                    node._generic_read_type = read_type ~= node._type
                        and node._type or nil
                    if mode ~= "write" and not node._read_guard then
                        if closed._tag == "Type.Array" then
                            checker.typeerror(errors, node.loc,
                                "cannot read array elements of type '%s' "
                                .. "because the type has no sound runtime guard",
                                types.tostring(elem))
                        else
                            checker.typeerror(errors, node.loc,
                                "cannot read map values of type '%s' "
                                .. "because the type has no sound runtime guard",
                                types.tostring(elem))
                        end
                    end
                    node.exp2 = coerce_and_check(written_exp2, final_key,
                        term, errors, written_exp2.loc)
                    if node._type._tag ~= "Type.Invalid"
                       and not checker._ensure_c_enum_supported(
                           st, node._type, node.loc, errors) then
                        node._type = types.Invalid()
                    end
                end)
            return
        end

        local keystype, term
        local fam_access = node.exp1._c_fam_access
        local celem, cterm, cerr
        if fam_access then
            local array = c_resolve(fam_access.field.type)
            celem, cterm = c_resolve(array.elem),
                "flexible C array member indexing"
            node._c_fam_access = fam_access
        else
            celem, cterm, cerr = c_index_elem_type(node.exp1._type)
        end
        if node.exp1._type._tag == "Type.Array" then
            local elem = node.exp1._type.elem
            node._type = optionize(elem)
            local read_type = generic_runtime_carrier(node._type)
            node._read_guard = types.gradual_guard(read_type) or false
            if read_type ~= node._type then
                node._generic_read_type = node._type
            end
            if mode ~= "write" and not node._read_guard then
                checker.typeerror(errors, node.loc,
                    "cannot read array elements of type '%s' because the type has no sound runtime guard",
                    types.tostring(elem))
            end
            keystype = types.Integer()
            term = "array indexing"
        elseif node.exp1._type._tag == "Type.Map" then
            local values = node.exp1._type.values
            node._type = optionize(values)
            local read_type = generic_runtime_carrier(node._type)
            node._read_guard = types.gradual_guard(read_type) or false
            if read_type ~= node._type then
                node._generic_read_type = node._type
            end
            if mode ~= "write" and not node._read_guard then
                checker.typeerror(errors, node.loc,
                    "cannot read map values of type '%s' because the type has no sound runtime guard",
                    types.tostring(values))
            end
            keystype = node.exp1._type.keys
            term = "map indexing"
        elseif celem then
            node._type, term = celem, cterm
            if checker._foreign_function_depth > 0 then
                local spelling = st.c_profile and st.c_profile.int or "int"
                keystype = st.c_profile and st.c_profile.integers
                    and st.c_profile.integers[spelling]
                    and st.c_profile.integers[spelling].type
                    or types.CInteger("int", true, 3, 32)
            else
                keystype = types.Integer()
            end
        elseif cerr then
            node._type = invalid(errors, node.exp1.loc, cerr)
            return
        else
            node._type = invalid(errors, node.exp1.loc,
                "expression in indexing is not an array, map, C pointer, C array, or owned C array but %s",
                types.tostring(node.exp1._type))
            return
        end

        checkexp(node.exp2, st, errors, keystype)
        -- always try to coerce index key to key type
        node.exp2 = coerce_and_check(
            node.exp2, keystype, term, errors, node.exp2.loc)
        if node._type and node._type._tag ~= "Type.Invalid"
           and not checker._ensure_c_enum_supported(
               st, node._type, node.loc, errors) then
            node._type = types.Invalid()
        end
        end, "index projection")
    end,
})

--
-- Exp
--

-- Returns best guess of expression name
function expname(node)
    if node._tag == "Ast.ExpForeignType" and node._type then
        return types.tostring(node._type)
    elseif node._tag == "Ast.ExpVar" then
        if node.var._tag == "Ast.VarName" then
            return node.var.name
        elseif node.var._tag == "Ast.VarDot" then
            return expname(node.var.exp) .. "." .. node.var.name
        else
            return "(expression)"
        end
    else
        return "(expression)"
    end
end

-- Mirror the lowering distinction that matters to the checker: declarations
-- with a statically named native entry never need Lua's finite-result request,
-- while calls through locals, fields, casts, lambdas, bound methods, and other
-- function values retain a generic VM branch.  C calls are handled before this
-- predicate is consulted.
function uses_generic_callable_boundary(node)
    if node.args._tag ~= "Ast.ArgsFunc" then return false end
    if node.exp._tag ~= "Ast.ExpVar" then return true end
    local decl = node.exp.var._decl
    return not (decl and (decl._tag == "Ast.TopLevelFunc"
        or decl._tag == "Type.ModuleMember"
        or decl._tag == "Type.StaticMethod"))
end

check_generic_result_limit = function(node, errors, report_error)
    if not uses_generic_callable_boundary(node) then return end
    -- Every statically open generic producer uses LUA_MULTRET. Its actual count
    -- is measured from the restored stack top and adjusted by Titan afterward,
    -- so only genuinely finite calls use CallInfo's bounded result field.
    if node._open_results then return end

    local requested = #(node._visible_types or {})
    if requested and requested > LUA_VM_MAX_RESULTS
       and report_error ~= false then
        checker.typeerror(errors, node.loc,
            "function-value call can require %d finite VM results, but "
            .. "Lua 5.5 supports at most %d; reduce the result demand or "
            .. "use a direct Titan call",
            requested, LUA_VM_MAX_RESULTS)
    end
end

-- Typecheck a positional argument list through the shared expression-list
-- demand. Titan calls nil-pad missing fixed positions and retain explicit
-- surplus expressions for effects; strict C calls neither pad nor relax their
-- ABI shape. `allow_missing == false` is the existing call-site signal for a C
-- function pointer/direct FFI/pseudo-constructor.
function checkargs(callable, args, loc, fname, st, errors,
                         allow_missing, nominal_constructor)
    local signature = assert(call_signature(callable),
        "call checking requires a callable signature")
    if allow_missing == nil then allow_missing = true end
    local strict_arity = not allow_missing
    local fixed = {}
    for i, ptype in ipairs(signature.params) do fixed[i] = ptype end
    local tail = signature.varargtype
        or (signature.c_vararg and INFER_OPEN) or false
    local original_count = #args
    local adjusted = adjust_explist(args,
        result_demand(fixed, tail, {
            term = "call to " .. fname,
            open_term = fname,
            loc = loc,
            missing = strict_arity and "ignore" or "nil",
            explicit_surplus = strict_arity and "error" or "discard",
            slot_term = function(i)
                return "argument " .. i .. " of call to " .. fname
            end,
            check_expression = nominal_constructor and function(
                    exp, est, eerrors, context, demand, index)
                checker._nominal_argument_demand(
                    demand, nominal_constructor, index)
                checkexp(exp, est, eerrors, context, demand)
            end or nil,
        }), st, errors)

    -- A runtime-sized Titan run has no C vararg promotion/ABI contract. Keep
    -- ordinary explicit C varargs, but never pass `...` or a flexible-result
    -- run through that boundary.
    if signature.c_vararg and adjusted.open_source then
        checker.typeerror(errors, adjusted.open_source.loc,
            "cannot pass a runtime-open Titan result sequence to a foreign (C) variadic function")
    end

    if strict_arity and (adjusted.missing or adjusted.explicit_surplus) then
        local supplied = adjusted.explicit_surplus and original_count
            or (#signature.params - adjusted.missing)
        checker.typeerror(errors, loc,
            "%s called with %d arguments but expects %d.\n%s",
            fname, supplied, #signature.params,
            signature.description or types.tostring(signature.callable))
    end

    for i = #args, 1, -1 do args[i] = nil end
    for _, exp in ipairs(adjusted.exps) do table.insert(args, exp) end
    return adjusted
end

function annotate_call_arguments(node, adjusted)
    node._arg_adjustment = adjusted
    node._npassed_args = 0
    for _, _ in pairs(adjusted.fixed) do
        node._npassed_args = node._npassed_args + 1
    end
    node._npassed_args = node._npassed_args + #adjusted.tail_scalars
    node._open_args = adjusted.open_source and {
        source = adjusted.open_source,
        source_type = adjusted.open_type,
        target_type = adjusted.open_target,
        start = adjusted.open_start,
        adjustment = adjusted.open_adjustment,
    } or false
end

-- Return the direct automatic object whose address/decay is passed to a
-- mutable C parameter. Pointer-valued aliases intentionally do not qualify:
-- after their creation the checker cannot know which object a pointer denotes.
function mutable_c_call_argument_decl(exp, target)
    if not target or c_pointer_is_const(target) then return nil end

    local adjusted = exp
    local unsafe_array_decay = false
    local direct_address_source = false
    while exp and exp._tag == "Ast.ExpCast" do
        local conversion = exp._c_conversion
        if conversion and conversion.kind == "unsafe_object_pointer" then
            unsafe_array_decay = true
        elseif conversion and conversion.kind ==
               "address_then_unsafe_object_pointer" then
            direct_address_source = exp.exp
        elseif (exp._adjustment
                and exp._adjustment.kind == "direct_coercion"
                and exp._adjustment.coercion.op == "mutable_c_address")
           or (exp._written_cast
                and exp._written_cast.op == "coercion"
                and exp._written_cast.coercion.op == "mutable_c_address") then
            -- An inner explicit cast may take the exact local address before
            -- an outer unsafe pointer reinterpretation reaches the parameter.
            direct_address_source = exp.exp
        end
        exp = exp.exp
    end
    exp = direct_address_source or exp
    if not is_mutable_c_address_source(exp) then return nil end

    if direct_address_source then
        return exp.var._decl, exp
    end

    local source = types.resolve_c_typedef(exp._type)
    -- Pointer-local mutation needs the actual address plan found above. An
    -- explicit pointer reinterpretation may have the same endpoint types but
    -- addresses external storage, not the local variable containing its bits.
    if source and source._tag == "Type.CPointer" then return nil end

    if types.c_mutable_address_coerceable(exp._type, target) then
        return exp.var._decl, exp
    end

    local planned_conversion = adjusted._adjustment
        or adjusted._assignment_adjustment
        or adjusted._written_cast
        or adjusted._c_conversion
    if source and source._tag == "Type.CArray"
       and (unsafe_array_decay
            or (planned_conversion
                and adjusted._type
                and types.equals(adjusted._type, target))) then
        return exp.var._decl, exp
    end
    return nil
end

-- A C variadic tail has no formal parameter type, but an explicit pointer cast
-- still describes the exact argument type passed across the ABI. Direct arrays
-- likewise undergo the ordinary C call-site decay. Recover only those two
-- pointer-bearing shapes here; a struct/union passed by value and an already
-- stored pointer alias intentionally do not become tracked automatic roots.
function c_variadic_mutation_target(exp)
    local resolved = exp and types.resolve_c_typedef(exp._type)
    if not resolved then
        return nil
    elseif resolved._tag == "Type.CPointer" then
        return exp._type
    elseif resolved._tag == "Type.CArray" then
        return types.CPointer(resolved.elem, resolved.quals or {})
    end
    return nil
end

function annotate_c_call_mutations(node, cfunc)
    assert(cfunc and cfunc._tag == "Type.CFunction",
        "C call mutation analysis requires a C function declaration")
    local mutated, seen = {}, {}
    local function observe(arg, target)
        if target then
            local decl, source =
                mutable_c_call_argument_decl(arg, target)
            if decl and not seen[decl] then
                seen[decl] = true
                mark_mutable_c_address_source(source)
                table.insert(mutated, decl)
            end
        end
    end

    local adjusted = node._arg_adjustment
    if adjusted then
        -- The lexical list can contain an effect-only spread carrier before its
        -- synthesized projections. Mutation authority follows ABI/formal
        -- positions, so pair the fixed projections (and explicit C-vararg tail)
        -- with their actual targets rather than walking adjusted.exps.
        for i, target in ipairs(cfunc.params or {}) do
            local arg = adjusted.fixed[i]
            if arg then observe(arg, target) end
        end
        if cfunc.vararg then
            for _, arg in ipairs(adjusted.tail_scalars) do
                observe(arg, c_variadic_mutation_target(arg))
            end
        end
    else
        -- Named FFI calls are already stored densely in formal order and do not
        -- carry the positional expression-list adjustment descriptor.
        for i, arg in ipairs(node.args.args) do
            local target = (cfunc.params or {})[i]
            if not target and cfunc.vararg then
                target = c_variadic_mutation_target(arg)
            end
            observe(arg, target)
        end
    end
    node._c_mutated_decls = #mutated > 0 and mutated or false
end

-- Return the expressions carried by either positional or named call syntax.
-- Named calls are normalized only after eligibility and per-name checking, so
-- every error-recovery path must understand both payload shapes.
function call_argument_expressions(args)
    if args._tag == "Ast.ArgsFunc" or args._tag == "Ast.ArgsMethod" then
        return args.args
    end
    assert(args._tag == "Ast.ArgsNamedFunc"
        or args._tag == "Ast.ArgsNamedMethod")
    local exps = {}
    for _, field in ipairs(args.fields) do
        table.insert(exps, field.exp)
    end
    return exps
end

function check_call_argument_expressions(args, st, errors)
    for _, exp in ipairs(call_argument_expressions(args)) do
        checkexp(exp, st, errors)
    end
end

function default_call_result_demand(node, context)
    if node._voidok then
        return result_demand({}, false, { term = "discarded call" })
    end
    return result_demand({ context or UNKNOWN_SLOT }, false, {
        term = "call expression",
    })
end

-- Discover the complete statically visible positional input shape of a call
-- through `value`. The discovery demand is open and untyped, so it checks each
-- written argument exactly once, preserves all fixed results of the trailing
-- producer, and retains at most one runtime-open final run. Those statically
-- visible scalars then become the synthesized function's fixed parameters;
-- only the dynamic run remains its input vararg.
function synthesize_value_call_inputs(args, loc, st, errors)
    local adjusted = adjust_explist(args,
        result_demand({}, INFER_OPEN, {
            term = "contextual value-call arguments",
            open_term = "contextual value call",
            loc = loc,
            missing = "error",
            explicit_surplus = "discard",
            -- The synthesized signature may still mention ambient inference
            -- cells. Its AST-owned close classifies the one open input edge
            -- only after those cells and nested producers have finalized.
            defer_open_check = true,
        }), st, errors)

    local params = {}
    local fixed = {}
    for i, exp in ipairs(adjusted.tail_scalars) do
        params[i] = exp._type
        fixed[i] = exp
        exp._demand_tail = nil
        exp._demand_slot = i
    end
    adjusted.fixed = fixed
    adjusted.tail_scalars = {}

    for i = #args, 1, -1 do args[i] = nil end
    for _, exp in ipairs(adjusted.exps) do
        table.insert(args, exp)
    end

    return params, adjusted.open_source and adjusted.open_type or false,
        adjusted
end

function synthesize_value_call_type(node, demand, st, errors)
    local params, varargtype, adjusted = synthesize_value_call_inputs(
        node.args.args, node.loc, st, errors)

    return synthesize_function_type(params, varargtype, demand, node.loc,
        errors), adjusted
end

function generic_finalize_contextual_value_callee(
        node, original, synthesized, errors)
    local cast = trycoerce(original, synthesized, errors)
    if cast == original then
        -- Error recovery: an invalid synthesized component (or an
        -- unreifiable raw-pointer tail) has already been diagnosed. Retain the
        -- contextual call shape without claiming that an assignment plan
        -- exists, so later checker passes can report each source error once.
        cast = ast.ExpCast(original.loc, original, synthesized)
        cast._type = synthesized
        cast._implicit_coercion = true
        cast._adjustment_failed = true
    end
    assert(cast._tag == "Ast.ExpCast")
    -- This cast target is already a resolved Type.Function. It is deliberately
    -- not redispatched through the ExpCast visitor: the callee and every
    -- argument were checked exactly once.
    cast._contextual_value_cast = true
    node.exp = cast
    node._contextual_value_call = true
    node._contextual_function_type = synthesized
end

-- Record both result shapes of a checked call. `_types` remains the callable's
-- declared fixed ABI prefix for the existing coder; `_visible_types` and
-- `_result_sources` describe only what this consumer observes. A finite flex
-- projection is optional because its runtime slot may be absent. An open run
-- exists only when both the sink is open and the static callable type declares
-- a flexible tail.
annotate_call_results = function(node, callable, demand, errors)
    demand = demand or default_call_result_demand(node)
    local signature = assert(call_signature(callable),
        "result checking requires a callable signature")
    node._callee_type = signature.callable
    node._types = signature.rettypes
    node._flexrettype = signature.flexrettype or false
    node._visible_types = {}
    node._result_sources = {}
    -- A function value may turn out to be an ordinary Lua callable at run
    -- time.  Record the target-directed conversion for every result that such
    -- a callable can place into a Titan result slot.  `false` is deliberate:
    -- it means this result type has no sound dynamic conversion (notably a raw
    -- C pointer), so the generated Lua-callable branch must reject rather than
    -- rediscovering a permissive category check.
    node._lua_result_dynamic_plans = {}
    node._strict_result_guard_plans = {}
    node._open_results = false
    node._finite_flex_prefix = 0

    local nfixed = #signature.rettypes
    local ndemand = #demand.fixed
    local function add(typ, source)
        table.insert(node._visible_types, typ)
        table.insert(node._result_sources, source)
        table.insert(node._lua_result_dynamic_plans,
            types.dynamic_coercion(typ) or false)
        table.insert(node._strict_result_guard_plans,
            types.gradual_guard(typ) or false)
    end

    for i = 1, math.min(ndemand, nfixed) do
        add(signature.rettypes[i], { kind = "fixed", index = i })
    end
    if signature.flexrettype and ndemand > nfixed then
        local count = ndemand - nfixed
        if count > TITAN_VARARG_MAX and not demand.suppress_flex_cap then
            checker.typeerror(errors, node.loc,
                "finite flexible-result demand is %d value(s), maximum is %d",
                count, TITAN_VARARG_MAX)
        end
        node._finite_flex_prefix = count
        for i = 1, count do
            add(optionize(signature.flexrettype), {
                kind = "flex", index = i, may_absent = true,
            })
        end
    end

    if demand.tail then
        for i = ndemand + 1, nfixed do
            add(signature.rettypes[i], { kind = "fixed", index = i })
        end
        if signature.flexrettype then
            local start = math.max(ndemand - nfixed, 0) + 1
            local target = expected_type(demand.tail) or signature.flexrettype
            node._open_results = {
                source = node,
                source_type = signature.flexrettype,
                target_type = target,
                start = start,
            }
            node._lua_open_result_dynamic_plan =
                types.dynamic_coercion(signature.flexrettype) or false
            node._strict_open_result_guard_plan =
                types.gradual_guard(signature.flexrettype) or false
            node._flex_result_demand = "open"
        end
    elseif signature.flexrettype then
        node._flex_result_demand = node._finite_flex_prefix
    else
        node._flex_result_demand = nil
    end

    node._type = node._visible_types[1] or types.Void()
end

-- Named syntax is deliberately declaration-only. Structural function values
-- do not carry parameter labels, so provenance -- not merely Type.Function --
-- decides eligibility. Returns (paramnames, lowering_kind, recognized_ffi),
-- where lowering_kind is "titan" or "foreign" and paramnames may be false for
-- a direct foreign declaration whose prototypes did not publish one complete,
-- unambiguous list.
function named_function_metadata(node)
    if node.exp._tag ~= "Ast.ExpVar" then
        return nil
    end
    local var = node.exp.var
    local decl = var._decl
    if not decl then
        return nil
    elseif decl._tag == "Ast.TopLevelFunc" then
        return decl._paramnames, "titan", false
    elseif decl._tag == "Ast.TopLevelForeignFunc" then
        return decl._paramnames, "foreign", true
    elseif decl._tag == "Type.StaticMethod" then
        return decl.paramnames, "titan", false
    elseif decl._tag == "Type.ModuleMember" and decl.type then
        local foreign = checker._foreign_function_reference(var) ~= nil
        if decl.type._tag == "Type.Function"
           or decl.type._tag == "Type.FunctionScheme" then
            return decl.paramnames, "titan", false
        elseif foreign and decl.type._tag == "Type.CFunction" then
            return decl.paramnames, "foreign", true
        end
    end
    return nil
end

function named_target_error(errors, loc)
    checker.typeerror(errors, loc,
        "named arguments require a direct Titan module function, "
        .. "record function, method, or fixed-arity FFI function")
end

return core.checker
