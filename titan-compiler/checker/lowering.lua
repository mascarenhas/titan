local core = require "titan-compiler.checker.core"
local _ENV = core

-- Generic declarations are checked against their precise surface schemes, but
-- code generation consumes one ordinary constraint-erased body.  Keep the
-- lowering here, after every body and exported-surface validation has
-- completed, so it cannot participate in inference or silently become a
-- second type checker.
-- Build the ordinary import descriptor carried only by the code-facing AST.
-- The declared Type.Module remains detached on `_declared_type` for metadata.
function generic_lower_import_descriptor(module, erased_registry)
    local erased = types.erase(module)
    local function canonicalize_owner(member)
        local owner = member and member.type
        local canonical = owner and erased_registry
            and erased_registry[owner.name]
        if canonical and (owner._tag == "Type.Record"
                or owner._tag == "Type.Union") then
            member.type = canonical
        end
        return member
    end
    for _, member in ipairs(erased.members or {}) do
        canonicalize_owner(member)
    end
    if module._source then
        erased._source = true
        erased.source_members = {}
        for index, member in ipairs(module.source_members or {}) do
            local item = canonicalize_owner(types.erase(member))
            erased.source_members[index] = item
            erased.source_members[item.name] = item
        end
        erased.source_type_members = {}
        for name, typ in pairs(module.source_type_members or {}) do
            erased.source_type_members[name] = types.erase(typ)
        end
    end
    return erased
end

function generic_prepare_erased_registry(surface_registry)
    local erased = {}
    for fqtn, owner in pairs(surface_registry) do
        local lowered = types.erase(owner)
        lowered._generic_header = nil
        lowered._generic_parameters = nil
        lowered._source_complete = owner._source_complete
        lowered.islocal = owner.islocal
        if lowered._tag == "Type.Record" then
            for index, field in ipairs(lowered.fields) do
                local source = owner.fields[index]
                field.islocal = source and source.islocal or nil
                field.dynamic_plan = types.dynamic_coercion(field.type) or false
            end
        elseif lowered._tag == "Type.Interface" then
            for _, field in ipairs(lowered.fields) do
                field.dynamic_plan =
                    types.dynamic_coercion(field.type) or false
            end
        elseif lowered._tag == "Type.Union" then
            for index, variant in ipairs(lowered.variants) do
                local source = owner.variants[index]
                variant.islocal = source and source.islocal or nil
            end
        end
        erased[fqtn] = lowered
    end
    return erased
end

-- Binary interfaces omit local fields and variants, but each remaining
-- descriptor retains its physical slot or tag. Visible-list position therefore
-- cannot identify the corresponding member in an erased owner.
function generic_canonical_indexed_member(items, member)
    for _, candidate in ipairs(items or {}) do
        if candidate.index == member.index and candidate.name == member.name then
            return candidate
        end
    end
    return nil
end

function generic_erased_descriptor(typ, state)
    if type(typ) ~= "table" or type(typ._tag) ~= "string" then return typ end
    local cached = state.erased_descriptors[typ]
    if cached then return cached end
    local tag = typ._tag
    if not types.contains_generic(typ)
       and tag ~= "Type.Record" and tag ~= "Type.Union"
       and tag ~= "Type.Interface" and tag ~= "Type.Field"
       and tag ~= "Type.Variant" and tag ~= "Type.StaticMethod"
       and tag ~= "Type.Method" and tag ~= "Type.ModuleMember"
       and tag ~= "Type.ModuleVariable" and tag ~= "Type.Module" then
        state.erased_descriptors[typ] = typ
        return typ
    end
    local erased
    if tag == "Type.Record" or tag == "Type.Union"
       or tag == "Type.Interface" then
        erased = state.erased_registry[typ.name] or types.erase(typ)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable" then
        local module = state.import_descriptors[typ.modname]
        erased = module and types.module_member(module, typ.name, true)
            or types.erase(typ)
    elseif tag == "Type.Field" then
        local owner = state.erased_registry[typ.fqtn]
        erased = generic_canonical_indexed_member(
            owner and owner.fields, typ) or types.erase(typ)
    elseif tag == "Type.Variant" then
        local owner = state.erased_registry[typ.fqtn]
        erased = generic_canonical_indexed_member(
            owner and owner.variants, typ) or types.erase(typ)
    elseif tag == "Type.StaticMethod" then
        local owner = state.erased_registry[typ.fqtn]
        erased = owner and owner.functions and owner.functions[typ.name]
            or types.erase(typ)
    elseif tag == "Type.Method" then
        local owner = state.erased_registry[typ.fqtn]
        if owner and owner.methods then
            if owner._tag == "Type.Interface" then
                for _, method in ipairs(owner.methods) do
                    if method.name == typ.name then erased = method break end
                end
            else
                erased = owner.methods[typ.name]
            end
        end
        erased = erased or types.erase(typ)
    elseif tag == "Type.Module" then
        erased = state.import_descriptors[typ.name]
            or generic_lower_import_descriptor(
                typ, state.erased_registry)
    else
        erased = types.erase(typ)
    end
    state.erased_descriptors[typ] = erased
    return erased
end

function generic_ordinary_assignment(
        source, target, state, options)
    local adjustment, conversion = checker_assignment_adjustment(
        source, target, state.st, options)
    return adjustment, conversion
end

function generic_interface_downcast_expression(
        exp, source, target, state, subject)
    local downcast = interface_downcast_plan(source, target, state.st)
    if not downcast then return nil end
    local node = ast.ExpCast(exp.loc, exp, target)
    node._type = target
    node._implicit_coercion = true
    node._interface_downcast = downcast
    node._written_cast = {
        kind = "written_cast",
        op = "interface_downcast",
        source = source,
        target = target,
        interface = downcast.interface,
        concrete = downcast.concrete,
        source_optional = downcast.source_optional,
        downcast = downcast,
        _erased_boundary = subject,
    }
    return node
end

function generic_erased_boundary_expression(
        exp, target, state, subject)
    local source = types.erase(exp._type)
    target = types.erase(target)
    exp._type = source
    exp._assignment_adjustment = nil
    if types.equals(source, target) then return exp end

    local adjustment = generic_ordinary_assignment(
        source, target, state)
    if not adjustment then
        local downcast = generic_interface_downcast_expression(
            exp, source, target, state, subject)
        if downcast then return downcast end
        error(string.format(
            "generic erased boundary for %s has no ordinary adjustment from %s to %s",
            subject, types.tostring(source), types.tostring(target)), 0)
    end
    local lowered, accepted = trycoerce(
        exp, target, state.errors, subject, adjustment)
    if not accepted then
        error("generic erased boundary lost its ordinary adjustment for "
            .. subject, 0)
    end
    return lowered
end

function generic_open_descriptor(source)
    while source and source._tag == "Ast.ExpCast" do source = source.exp end
    if not source then return nil end
    if source._tag == "Ast.ExpCall" then
        return source._open_results
    elseif source._tag == "Ast.ExpDots" then
        return source._open_dots
    elseif source._tag == "Ast.ExpSpread" then
        return source._open_spread
    end
    return nil
end

function generic_reclassify_open_adjustment(
        adjusted, state, subject, mirror)
    if not adjusted or not adjusted.open_source then return end
    local open = generic_open_descriptor(adjusted.open_source)
    local source = types.erase(open and open.source_type
        or adjusted.open_type)
    local target = types.erase(adjusted.open_target
        or (open and open.target_type) or source)
    local prior = adjusted.open_adjustment
    local prior_source = prior and prior.source
    local prior_target = prior and prior.target
    local stale = types.contains_generic(adjusted.open_type)
        or types.contains_generic(adjusted.open_target)
        or types.contains_generic(prior)
        or not types.equals(types.erase(adjusted.open_type), source)
        or not prior_source or not prior_target
        or not types.equals(types.erase(prior_source), source)
        or not types.equals(types.erase(prior_target), target)
    if not stale then return end

    local plan = generic_ordinary_assignment(
        source, target, state, { allow_coercion = true })
    if not plan then
        error(string.format(
            "%s has no ordinary open adjustment from %s to %s",
            subject, types.tostring(source), types.tostring(target)), 0)
    end
    local callable_adapter = plan.kind == "callable"
        and checker.freeze_callable_adapter(
            plan, source, target, adjusted.open_source.loc)
        or false
    adjusted.open_type = source
    adjusted.open_target = target
    adjusted.open_adjustment = plan
    adjusted.open_callable_adapter = callable_adapter
    adjusted.open_interface_conversion = plan.interface_conversion or false
    if open then
        open.source_type = source
        open.target_type = target
        open.adjustment = plan
        open.callable_adapter = callable_adapter
    end
    if mirror and mirror ~= false then
        mirror.source_type = source
        mirror.target_type = target
        mirror.adjustment = plan
        mirror.callable_adapter = callable_adapter
    end
end

function generic_reclassify_node_open_adjustments(node, state)
    generic_reclassify_open_adjustment(
        node._arg_adjustment, state, "erased call arguments", node._open_args)
    generic_reclassify_open_adjustment(
        node._result_adjustment, state, "erased expression results")
    generic_reclassify_open_adjustment(
        node._positional_adjustment, state, "erased positional constructor")
    generic_reclassify_open_adjustment(
        node._tuple_adjustment, state, "erased iterator tuple")
end

function generic_surface_callable_for_call(node, state)
    if node._generic_scheme then
        return node._generic_scheme.signature, node._generic_scheme
    elseif node._generic_declaration then
        return generic_callable_function_type(
            node._generic_declaration), node._generic_declaration
    end

    local method = node._method or node._interface_method
    if method and method.fqtn then
        local owner = state.surface_registry[method.fqtn]
        local canonical
        if owner and owner._tag == "Type.Interface" then
            for _, candidate in ipairs(owner.methods or {}) do
                if candidate.name == method.name then canonical = candidate break end
            end
        elseif owner and owner.methods then
            canonical = owner.methods[method.name]
        end
        if canonical and types.contains_generic(canonical) then
            return generic_callable_function_type(canonical), canonical
        end
    end
    return nil
end

function generic_replace_argument_reference(node, old, new)
    if old == new then return end
    local args = node.args
    local values = args.args
    if values then
        for index, value in ipairs(values) do
            if value == old then values[index] = new end
        end
    elseif args.fields then
        for _, field in ipairs(args.fields) do
            if field.exp == old then field.exp = new end
        end
    end
    if node._arg_adjustment then
        replace_adjusted_value(node._arg_adjustment, old, new)
    end
end

function generic_peel_generic_ingress(exp, surface_target)
    surface_target = types.normalize(surface_target)
    if not surface_target or surface_target._tag ~= "Type.Parameter" then
        return exp
    end
    -- Surface checking validates the closed application before erasure.  A
    -- direct rigid leaf is the one intentional exception to retaining that
    -- projection: literal `value` enters its real constraint carrier raw (or
    -- through the ordinary value-to-Interface boundary) and is checked only
    -- when a precise closed consumer later eliminates it.
    local current = exp
    if current._tag == "Ast.ExpCast" and current._implicit_coercion
       and current.exp and current.exp._type
       and current.exp._type._tag == "Type.Value" then
        local plan = current._adjustment
        if plan and plan.kind == "gradual_view"
           and plan.op == "project" then
            current = current.exp
            current._assignment_adjustment = nil
        end
    end
    return current
end

function generic_lower_call_arguments(
        node, signature, surface_signature, state)
    local adjusted = node._arg_adjustment
    if adjusted then
        for index = 1, #adjusted.fixed do
            local exp = adjusted.fixed[index]
            local target = signature.params[index]
            if target then
                local ingress = generic_peel_generic_ingress(
                    exp, surface_signature.params[index])
                if ingress ~= exp then
                    generic_replace_argument_reference(
                        node, exp, ingress)
                    exp = ingress
                end
                local lowered = generic_erased_boundary_expression(
                    exp, target, state,
                    "argument " .. index .. " of erased generic call")
                generic_replace_argument_reference(
                    node, exp, lowered)
            end
        end
        if signature.varargtype then
            local copy = {}
            for index, exp in ipairs(adjusted.tail_scalars) do copy[index] = exp end
            for _, exp in ipairs(copy) do
                local ingress = generic_peel_generic_ingress(
                    exp, surface_signature.varargtype)
                if ingress ~= exp then
                    generic_replace_argument_reference(
                        node, exp, ingress)
                    exp = ingress
                end
                local lowered = generic_erased_boundary_expression(
                    exp, signature.varargtype, state,
                    "variadic argument of erased generic call")
                generic_replace_argument_reference(
                    node, exp, lowered)
            end
            if adjusted.open_source then
                local open = generic_open_descriptor(adjusted.open_source)
                local source = open and open.source_type
                    or types.erase(adjusted.open_type)
                local target = signature.varargtype
                source, target = types.erase(source), types.erase(target)
                local plan = generic_ordinary_assignment(
                    source, target, state)
                if not plan then
                    error(string.format(
                        "generic open argument has no ordinary adjustment from %s to %s",
                        types.tostring(source), types.tostring(target)), 0)
                end
                adjusted.open_type = source
                adjusted.open_target = target
                adjusted.open_adjustment = plan
                adjusted.open_callable_adapter = plan.kind == "callable"
                    and checker.freeze_callable_adapter(
                        plan, source, target, adjusted.open_source.loc)
                    or false
                adjusted.open_interface_conversion =
                    plan.interface_conversion or false
                if open then
                    open.target_type = target
                    open.adjustment = plan
                    open.callable_adapter = adjusted.open_callable_adapter
                end
            end
        end
    else
        local values = node.args.args or {}
        local fixed = math.min(#signature.params, #values)
        for index = 1, fixed do
            values[index] = generic_peel_generic_ingress(
                values[index], surface_signature.params[index])
            values[index] = generic_erased_boundary_expression(
                values[index], signature.params[index], state,
                "argument " .. index .. " of erased generic call")
        end
        if signature.varargtype then
            for index = #signature.params + 1, #values do
                if not is_open_expression_marker(values[index]) then
                    values[index] = generic_erased_boundary_expression(
                        values[index], signature.varargtype, state,
                        "variadic argument of erased generic call")
                end
            end
        end
    end
end

function generic_lower_call_in_place(node, state)
    local prior = state.calls[node]
    if prior then return prior end

    -- Install a pending entry before descending because ExpExtra nodes share
    -- their producer call by identity.
    local info = { pending = true, generic = false }
    state.calls[node] = info

    node.exp = generic_lower_expression(node.exp, state)
    local values = node.args.args
    if values then
        for index, exp in ipairs(values) do
            local lowered = generic_lower_expression(exp, state)
            generic_replace_argument_reference(
                node, exp, lowered)
            values[index] = lowered
        end
    elseif node.args.fields then
        for _, field in ipairs(node.args.fields) do
            local old = field.exp
            local lowered = generic_lower_expression(old, state)
            generic_replace_argument_reference(node, old, lowered)
            field.exp = lowered
        end
    end

    local surface_signature, declaration =
        generic_surface_callable_for_call(node, state)
    if not surface_signature and node._callee_type
       and node._callee_type._tag == "Type.Function"
       and types.contains_generic(node._callee_type) then
        surface_signature = node._callee_type
        declaration = node._callee_type
    end
    if not surface_signature then
        generic_reclassify_node_open_adjustments(node, state)
        info.pending = nil
        return info
    end

    local erased_declaration = generic_erased_descriptor(
        declaration, state)
    local signature
    if erased_declaration._tag == "Type.Function" then
        signature = erased_declaration
    else
        signature = generic_callable_function_type(erased_declaration)
    end
    types.assert_erased(signature)

    info.generic = true
    info.declaration = declaration
    info.primary_sink = node._assignment_adjustment
        and node._assignment_adjustment.target or false
    info.surface_visible = {}
    for index, typ in ipairs(node._visible_types or node._types or {}) do
        info.surface_visible[index] = typ
    end
    info.surface_flex = node._flexrettype or false
    info.surface_open_target = node._open_results
        and node._open_results.target_type or false

    generic_lower_call_arguments(
        node, signature, surface_signature, state)

    if node.args._tag == "Ast.ArgsMethod" then
        -- Runtime lowering must rebind the call to the erased method, but
        -- source tooling still needs the applied surface declaration that was
        -- selected for the written method name (including owner/type-argument
        -- substitutions). Keep that descriptor on a private semantic edge.
        node.args._declared_method = node.args._decl
            or node._method or node._interface_method or declaration
        node._method = erased_declaration
        if node._interface_method then
            node._interface_method = erased_declaration
            node._interface = state.erased_registry[erased_declaration.fqtn]
        end
    else
        node.exp._type = signature
        if node.exp._tag == "Ast.ExpVar" and node.exp.var then
            node.exp.var._type = signature
            if node.exp.var._decl
               and node.exp.var._decl._tag:match("^Type%.") then
                node.exp.var._decl = generic_erased_descriptor(
                    node.exp.var._decl, state)
            elseif node.exp.var._decl
               and node.exp.var._decl._tag == "Ast.Decl" then
                node.exp.var._decl._type = signature
            end
        end
    end

    node._callee_type = signature
    node._types = signature.rettypes
    node._flexrettype = signature.flexrettype or false
    node._visible_types = {}
    node._lua_result_dynamic_plans = {}
    node._strict_result_guard_plans = {}
    local sources = node._result_sources or {}
    for index, source in ipairs(sources) do
        local carrier
        if source.kind == "fixed" then
            carrier = signature.rettypes[source.index]
        else
            carrier = optionize(assert(signature.flexrettype,
                "generic finite flexible result lost its erased tail"))
        end
        node._visible_types[index] = carrier
        node._lua_result_dynamic_plans[index] =
            types.dynamic_coercion(carrier) or false
        node._strict_result_guard_plans[index] =
            types.gradual_guard(carrier) or false
    end
    node._type = node._visible_types[1] or types.Void()
    if node._open_results then
        local source = assert(signature.flexrettype,
            "generic open result lost its erased flexible tail")
        local target = types.erase(info.surface_open_target or source)
        local plan = generic_ordinary_assignment(
            source, target, state, { allow_coercion = true })
        if not plan then
            error(string.format(
                "generic open result has no ordinary adjustment from %s to %s",
                types.tostring(source), types.tostring(target)), 0)
        end
        node._open_results.source_type = source
        node._open_results.target_type = target
        node._open_results.adjustment = plan
        node._open_results.callable_adapter = plan.kind == "callable"
            and checker.freeze_callable_adapter(
                plan, source, target, node.loc)
            or false
        node._lua_open_result_dynamic_plan =
            types.dynamic_coercion(source) or false
        node._strict_open_result_guard_plan =
            types.gradual_guard(source) or false
    end
    generic_reclassify_node_open_adjustments(node, state)
    node._assignment_adjustment = nil
    info.pending = nil
    return info
end

function generic_canonical_surface_method(node, state)
    local method = node._method
    if not method or not method.fqtn then return nil end
    local owner = state.surface_registry[method.fqtn]
    if not owner or not owner.methods then return nil end
    if owner._tag == "Type.Interface" then
        for _, candidate in ipairs(owner.methods) do
            if candidate.name == method.name then return candidate end
        end
        return nil
    end
    return owner.methods[method.name]
end

function generic_lower_method_reference(node, state)
    node.exp = generic_lower_expression(node.exp, state)
    local canonical = node._generic_declaration
        or generic_canonical_surface_method(node, state)
    if not canonical or not types.contains_generic(canonical) then return node end

    local surface = node._type
    local erased_method = generic_erased_descriptor(canonical, state)
    local carrier = generic_callable_function_type(erased_method)
    node._method = erased_method
    node._type = carrier
    node._assignment_adjustment = nil
    local projected = generic_erased_boundary_expression(
        node, types.erase(surface), state,
        "first-class erased generic method")
    if projected ~= node then state.reverse_wrappers[projected] = node end
    return projected
end

function generic_lower_first_class_declaration(node, state)
    local declaration = node._generic_scheme or node._generic_declaration
    if not declaration then return node end
    local surface = node._type
    local erased = generic_erased_descriptor(declaration, state)
    local carrier = erased._tag == "Type.Function"
        and erased or generic_callable_function_type(erased)
    node._type = carrier
    node._assignment_adjustment = nil
    if node.var then
        node.var._type = carrier
        if node.var._decl and node.var._decl._tag ~= "Ast.TopLevelFunc" then
            node.var._decl = generic_erased_descriptor(
                node.var._decl, state)
        end
    end
    local projected = generic_erased_boundary_expression(
        node, types.erase(surface), state,
        "first-class erased generic declaration")
    if projected ~= node then state.reverse_wrappers[projected] = node end
    return projected
end

function generic_field_pair(field, state)
    if not field or field._tag ~= "Type.Field" then return nil end
    local owner = state.surface_registry[field.fqtn]
    if not owner
       or (owner._tag ~= "Type.Record"
           and owner._tag ~= "Type.Interface")
       or owner.scope == false then
        return nil
    end
    local canonical = generic_canonical_indexed_member(
        owner.fields, field)
    if not canonical or not types.contains_generic(canonical.type) then
        return nil
    end
    local erased_owner = state.erased_registry[field.fqtn]
    local erased = generic_canonical_indexed_member(
        erased_owner and erased_owner.fields, canonical)
    if not erased then return nil end
    return canonical, erased
end

function generic_lower_field_read(node, state)
    local var = node.var
    if not var or var._tag ~= "Ast.VarDot" then return node end
    local surface_field, carrier = generic_field_pair(var._decl, state)
    if not carrier then return node end
    local surface_type = node._type
    var._decl = carrier
    var._type = carrier.type
    if var._interface_field then
        var._interface = state.erased_registry[surface_field.fqtn]
        var._interface_field = carrier
        var._interface_field_index = carrier.index
    end
    node._type = carrier.type
    node._assignment_adjustment = nil
    local projected = generic_erased_boundary_expression(
        node, types.erase(surface_type), state,
        "projection from erased generic field '" .. carrier.name .. "'")
    if projected ~= node then state.reverse_wrappers[projected] = node end
    return projected
end

function generic_lower_field_write(var, exp, state)
    local surface, carrier = generic_field_pair(
        var._decl, state)
    if not carrier then return exp end
    exp = generic_peel_generic_ingress(exp, surface.type)
    var._decl = carrier
    var._type = carrier.type
    return generic_erased_boundary_expression(
        exp, carrier.type, state,
        "write to erased generic field '" .. carrier.name .. "'")
end

function generic_lower_init_fields(node, state)
    for _, field in ipairs(node.fields or {}) do
        field.exp = generic_lower_expression(field.exp, state)
        local surface, carrier = generic_field_pair(
            field._field, state)
        if carrier then
            field.exp = generic_peel_generic_ingress(
                field.exp, surface.type)
            field._field = carrier
            field.exp = generic_erased_boundary_expression(
                field.exp, carrier.type, state,
                "construction of erased generic field '" .. carrier.name .. "'")
        elseif field._field then
            field._field = generic_erased_descriptor(
                field._field, state)
        end
    end
end

function generic_lower_union_init(node, state)
    if node.value and node.value ~= false then
        node.value = generic_lower_expression(node.value, state)
    end
    local surface = node._variant
    if not surface or surface._tag ~= "Type.Variant" then return end
    local owner = state.surface_registry[surface.fqtn]
    local erased_owner = state.erased_registry[surface.fqtn]
    local canonical = generic_canonical_indexed_member(
        owner and owner.variants, surface)
    local carrier = generic_canonical_indexed_member(
        erased_owner and erased_owner.variants, surface)
    if not carrier then return end
    node._union = erased_owner
    node._variant = carrier
    if canonical and canonical.payload ~= false
       and types.contains_generic(canonical.payload) then
        node.value = generic_peel_generic_ingress(
            node.value, canonical.payload)
        node.value = generic_erased_boundary_expression(
            node.value, carrier.payload, state,
            "construction of erased generic union payload")
    end
end

function generic_reclassify_assignment(node, state)
    local plan = node._assignment_adjustment
    if not plan or not types.contains_generic(plan) then return end
    local source = types.erase(node._type)
    local target = types.erase(plan.target)
    node._type = source
    node._assignment_adjustment = nil
    local adjustment = generic_ordinary_assignment(
        source, target, state)
    if not adjustment then
        error(string.format(
            "generic assignment annotation has no erased adjustment from %s to %s",
            types.tostring(source), types.tostring(target)), 0)
    end
    if adjustment.kind ~= "identity" then
        node._assignment_adjustment = adjustment
    end
end

function generic_ordinary_written_plan(node, source, target, state)
    local plan = types.written_cast(source, target)
    node._interface_conversion = nil
    node._interface_downcast = nil
    node._interface_test = nil
    node._callable_adapter = nil
    if not plan and source._tag == "Type.Nominal"
       and target._tag == "Type.Nominal" then
        local concrete = types.registry[source.fqtn]
        local interface = types.registry[target.fqtn]
        if concrete
           and (concrete._tag == "Type.Record"
                or concrete._tag == "Type.Union")
           and interface and interface._tag == "Type.Interface" then
            local policy = interface_relation_policy(state.st)
            plan = types.written_cast(source, target, policy)
            if plan then
                local conversion = make_interface_conversion(
                    source, target, plan)
                plan.interface_conversion = conversion
                node._interface_conversion = conversion
                if node._tag == "Ast.ExpIs" then
                    node._interface_test = {
                        kind = "interface_implementation_test",
                        conversion = conversion,
                        allocation_free = true,
                    }
                end
            end
        end
    end
    if not plan then
        local downcast = interface_downcast_plan(source, target, state.st)
        if downcast then
            node._interface_downcast = downcast
            plan = {
                kind = "written_cast",
                op = "interface_downcast",
                source = source,
                target = target,
                interface = downcast.interface,
                concrete = downcast.concrete,
                source_optional = downcast.source_optional,
                downcast = downcast,
            }
            if node._tag == "Ast.ExpIs" then
                node._interface_test = {
                    kind = "interface_downcast_test",
                    downcast = downcast,
                    allocation_free = true,
                }
            end
        end
    end
    if plan and plan.op == "callable" and node._tag == "Ast.ExpCast" then
        node._callable_adapter = checker.freeze_callable_adapter(
            plan.callable, source, target, node.loc)
    end
    return plan
end

function generic_reclassify_written_expression(
        node, lowered, surface_target, state)
    local source = types.erase(lowered._type)
    local target = types.erase(surface_target)
    lowered._type = source
    if node._tag == "Ast.ExpCast" and types.equals(source, target) then
        return lowered
    end
    local plan = generic_ordinary_written_plan(
        node, source, target, state)
    if not plan then
        error(string.format(
            "generic written boundary has no ordinary cast from %s to %s",
            types.tostring(source), types.tostring(target)), 0)
    end
    node.exp = lowered
    node.target = target
    node._written_cast = plan
    node._adjustment = nil
    node._type = node._tag == "Ast.ExpIs" and types.Boolean() or target
    return node
end

function generic_reclassify_comparison(node, state)
    node.lhs._type = generic_erased_descriptor(
        node.lhs._type, state)
    node.rhs._type = generic_erased_descriptor(
        node.rhs._type, state)
    local comparison = types.comparable(node.lhs._type, node.rhs._type)
    if not comparison then
        error(string.format(
            "generic equality has no ordinary comparison between %s and %s",
            types.tostring(node.lhs._type),
            types.tostring(node.rhs._type)), 0)
    end
    local function apply(exp, adjustment, side)
        if not adjustment then return exp end
        local adjusted, consumed = trycoerce(
            exp, adjustment.target, state.errors,
            "erased generic equality " .. side .. " operand", adjustment)
        assert(consumed == adjustment,
            "erased generic equality lost its ComparisonPlan adjustment")
        return adjusted
    end
    node.lhs = apply(node.lhs, comparison.left_adjustment, "left")
    node.rhs = apply(node.rhs, comparison.right_adjustment, "right")
    node._comparison = comparison
end

function generic_lower_spread_in_place(node, state)
    local prior = state.spreads[node]
    if prior then return prior end
    -- ExpSpreadIndex nodes share this carrier by identity. Install the memo
    -- before descending so the shared DAG is lowered exactly once.
    state.spreads[node] = node
    node.exp = generic_lower_expression(node.exp, state)
    if node.first then
        node.first = generic_lower_expression(
            node.first, state)
    end
    if node.last then
        node.last = generic_lower_expression(
            node.last, state)
    end

    node._spread_elem = generic_erased_descriptor(
        node._spread_elem, state)
    node._spread_optional_type = optionize(node._spread_elem)
    node._spread_optional_guard = types.gradual_guard(
        generic_runtime_carrier(node._spread_optional_type)) or false
    node._spread_open_guard = types.gradual_guard(
        generic_runtime_carrier(node._spread_elem)) or false
    node._type = types.Nil()
    if node._open_spread then
        node._open_spread.source_type = node._spread_elem
        node._open_spread.target_type = generic_erased_descriptor(
            node._open_spread.target_type, state)
    end
    return node
end

-- A checked spread force around a structural generic result needs two erased
-- operations: force the erased Option container, then apply the ordinary
-- same-kind element view selected by the precise surface type. Lowering the
-- child call through its usual surface projection first would instead ask for
-- one unsupported Option(structural-view)-plus-force edge.
function generic_lower_spread_subject_force(node, state)
    if not node._spread_subject_force then return nil end
    local written = node.exp
    local adjusted = false
    local call = written
    if written._tag == "Ast.ExpAdjust" then
        adjusted = written
        call = written.exp
    end
    if not call or call._tag ~= "Ast.ExpCall" then return nil end

    local surface_target = types.erase(node._type)
    local target_kind = spread_subject_container(surface_target)
    if not target_kind then return nil end
    local info = generic_lower_call_in_place(call, state)
    if not info.generic then return nil end

    local source = call
    if adjusted then
        adjusted.exp = call
        adjusted._type = call._type
        adjusted._assignment_adjustment = nil
        source = adjusted
    end
    local source_type = types.normalize(source._type)
    if not source_type or source_type._tag ~= "Type.Option" then return nil end
    local source_kind = spread_subject_container(source_type.base)
    if source_kind ~= target_kind then return nil end

    local forced = tryforce(source)
    return generic_erased_boundary_expression(
        forced, surface_target, state,
        "forced spread subject from erased generic call")
end

function generic_lower_expression(node, state)
    if type(node) ~= "table" or type(node._tag) ~= "string" then return node end
    local tag = node._tag
    if tag == "Ast.ExpSpread" then
        return generic_lower_spread_in_place(node, state)
    elseif tag == "Ast.ExpSpreadIndex" then
        node.spread = generic_lower_spread_in_place(node.spread, state)
        node._type = node.spread._spread_optional_type
    elseif tag == "Ast.ExpCall" then
        local info = generic_lower_call_in_place(node, state)
        if not info.generic or not info.surface_visible[1] then return node end
        if not info.primary then
            local target = info.surface_visible[1]
            if info.primary_sink
               and types.equals(types.erase(info.primary_sink), node._type) then
                target = info.primary_sink
            end
            info.primary = generic_erased_boundary_expression(
                node, types.erase(target), state,
                "result of erased generic call")
            if info.primary ~= node then
                state.reverse_wrappers[info.primary] = node
            end
        end
        return info.primary
    elseif tag == "Ast.ExpExtra" then
        local producer = node.exp
        while producer and producer._tag == "Ast.ExpCast" do
            producer = producer.exp
        end
        local info = producer and producer._tag == "Ast.ExpCall"
            and generic_lower_call_in_place(producer, state) or nil
        if info and info.generic and info.surface_visible[node.index] then
            node.exp = producer
            local source = producer._visible_types[node.index]
            local sink = node._assignment_adjustment
                and node._assignment_adjustment.target or false
            node._type = source
            node._assignment_adjustment = nil
            local target = info.surface_visible[node.index]
            if sink and types.equals(types.erase(sink), source) then
                target = sink
            end
            local projected = generic_erased_boundary_expression(
                node, types.erase(target), state,
                "extra result of erased generic call")
            if projected ~= node then
                state.reverse_wrappers[projected] = node
            end
            return projected
        end
        if node.exp then node.exp = generic_lower_expression(node.exp, state) end
    elseif tag == "Ast.ExpCast" then
        local surface_target = node._type
        local generic_adjustment = node._adjustment
            and types.contains_generic(node._adjustment)
        local generic_written = node._written_cast
            and types.contains_generic(node._written_cast)
        local spread_force = generic_lower_spread_subject_force(node, state)
        if spread_force then return spread_force end
        local lowered = generic_lower_expression(node.exp, state)
        local carrier = state.reverse_wrappers[lowered]
        if carrier and types.equals(
                types.erase(surface_target), types.erase(carrier._type)) then
            return carrier
        end
        if generic_written then
            return generic_reclassify_written_expression(
                node, lowered, surface_target, state)
        end
        if generic_adjustment
           or (node._adjustment
               and not types.equals(types.erase(node._adjustment.source), types.erase(lowered._type))) then
            return generic_erased_boundary_expression(
                lowered, types.erase(surface_target), state,
                "erased generic implicit cast")
        end
        node.exp = lowered
        if node.target and type(node.target) == "table"
           and node.target._tag and node.target._tag:match("^Type%.") then
            node.target = generic_erased_descriptor(
                node.target, state)
        end
    elseif tag == "Ast.ExpIs" then
        local surface_target = node.target
        local generic_written = node._written_cast
            and types.contains_generic(node._written_cast)
        local lowered = generic_lower_expression(node.exp, state)
        if generic_written then
            return generic_reclassify_written_expression(
                node, lowered, surface_target, state)
        end
        node.exp = lowered
        if node.target and type(node.target) == "table"
           and node.target._tag and node.target._tag:match("^Type%.") then
            node.target = generic_erased_descriptor(
                node.target, state)
        end
    elseif tag == "Ast.ExpBinop" then
        local generic_comparison = (node.op == "==" or node.op == "~=")
            and (types.contains_generic(node.lhs._type)
                 or types.contains_generic(node.rhs._type)
                 or types.contains_generic(node._comparison))
        node.lhs = generic_lower_expression(node.lhs, state)
        node.rhs = generic_lower_expression(node.rhs, state)
        if generic_comparison then
            generic_reclassify_comparison(node, state)
        end
    elseif tag == "Ast.ExpMethodRef" then
        return generic_lower_method_reference(node, state)
    elseif tag == "Ast.ExpVar" then
        if node.var._tag == "Ast.VarDot" then
            node.var.exp = generic_lower_expression(
                node.var.exp, state)
        elseif node.var._tag == "Ast.VarBracket" then
            node.var.exp1 = generic_lower_expression(
                node.var.exp1, state)
            node.var.exp2 = generic_lower_expression(
                node.var.exp2, state)
        end
        local first_class = generic_lower_first_class_declaration(
            node, state)
        if first_class ~= node then return first_class end
        return generic_lower_field_read(node, state)
    elseif tag == "Ast.ExpInitList" then
        generic_lower_init_fields(node, state)
    elseif tag == "Ast.ExpUnionInit" then
        generic_lower_union_init(node, state)
    else
        -- Public AST edges are acyclic.  Type syntax and resolved Type graphs
        -- are metadata rather than executable children and are erased later.
        for key, value in pairs(node) do
            if type(key) == "string" and key:sub(1, 1) ~= "_"
               and key ~= "loc" and key ~= "target"
               and key ~= "type" and key ~= "rettypes"
               and key ~= "flexrettype" and key ~= "typeparams"
               and key ~= "typeargs" and type(value) == "table" then
                if value._tag and value._tag:match("^Ast%.Exp") then
                    node[key] = generic_lower_expression(value, state)
                elseif value._tag then
                    generic_lower_node(value, state)
                else
                    for index, child in ipairs(value) do
                        if type(child) == "table" and child._tag
                           and child._tag:match("^Ast%.Exp") then
                            value[index] = generic_lower_expression(
                                child, state)
                        elseif type(child) == "table" then
                            generic_lower_node(child, state)
                        end
                    end
                end
            end
        end
    end
    generic_reclassify_assignment(node, state)
    generic_reclassify_node_open_adjustments(node, state)
    return node
end

function generic_lower_case(node, state)
    node.exp = generic_lower_expression(node.exp, state)
    if node._union then
        node._union = generic_erased_descriptor(node._union, state)
    end
    for _, arm in ipairs(node.arms or {}) do
        local surface_variant = arm._variant
        local carrier = surface_variant
            and generic_erased_descriptor(surface_variant, state)
            or nil
        if carrier then arm._variant = carrier end
        if arm.binding and surface_variant and carrier
           and surface_variant.payload ~= false then
            local target = types.erase(arm.binding._type)
            local source = carrier.payload
            if not types.equals(source, target) then
                state.hidden_case = state.hidden_case + 1
                local original = arm.binding
                local hidden = hidden_decl(arm.loc,
                    "__generic_case_payload_" .. state.hidden_case, source)
                arm.binding = hidden
                local value = hidden_exp(arm.loc, hidden)
                local projection = generic_erased_boundary_expression(
                    value, target, state,
                    "projection from erased generic union payload")
                original._type = target
                local declaration = ast.StatDecl(
                    arm.loc, { original }, { projection })
                table.insert(arm.block.stats, 1, declaration)
            else
                arm.binding._type = source
            end
        end
        generic_lower_node(arm.block, state)
    end
    if node.elseblock then generic_lower_node(node.elseblock, state) end
end

function generic_lower_assignment(node, state)
    for _, var in ipairs(node.vars or {}) do
        if var._tag == "Ast.VarDot" then
            var.exp = generic_lower_expression(var.exp, state)
        elseif var._tag == "Ast.VarBracket" then
            var.exp1 = generic_lower_expression(var.exp1, state)
            var.exp2 = generic_lower_expression(var.exp2, state)
        end
    end
    for index, exp in ipairs(node.exps or {}) do
        local old = exp
        local lowered = generic_lower_expression(exp, state)
        local var = node.vars[index]
        if var and var._tag == "Ast.VarDot" then
            lowered = generic_lower_field_write(var, lowered, state)
        end
        node.exps[index] = lowered
        if node._result_adjustment then
            replace_adjusted_value(node._result_adjustment, old, lowered)
        end
    end
    generic_reclassify_node_open_adjustments(node, state)
end

function generic_lower_forin(node, state)
    -- The adjusted tuple owns every evaluated setup expression, including
    -- surplus values absent from the four legacy `exps` slots.
    local adjusted = node._tuple_adjustment
    for _, exp in ipairs(adjusted.exps) do
        local lowered = generic_lower_expression(exp, state)
        replace_adjusted_value(adjusted, exp, lowered)
        for index, discard in ipairs(adjusted.discards) do
            if discard == exp then adjusted.discards[index] = lowered end
        end
    end
    node.exps = adjusted.fixed
    generic_reclassify_node_open_adjustments(node, state)

    -- These private edges are executable AST, not just type annotations.
    -- Reclassify their casts before erasing types (T? -> T may become
    -- value -> value). Keep calls as raw producers for the coder's hidden
    -- result declarations and extra-result slots.
    generic_lower_call_in_place(node._init_call, state)
    generic_lower_call_in_place(node._next_call, state)
    if node._close_call then
        generic_lower_call_in_place(node._close_call, state)
    end
    generic_lower_node(node._visible_stat, state)
    generic_lower_node(node.block, state)
end

function generic_lower_node(node, state)
    if type(node) ~= "table" or type(node._tag) ~= "string" then return end
    local tag = node._tag
    if tag:match("^Ast%.Exp") then
        return generic_lower_expression(node, state)
    elseif tag == "Ast.StatAssign" then
        generic_lower_assignment(node, state)
        return
    elseif tag == "Ast.StatCase" then
        generic_lower_case(node, state)
        return
    elseif tag == "Ast.StatForIn" then
        generic_lower_forin(node, state)
        return
    end

    if node.exps then
        for index, exp in ipairs(node.exps) do
            local lowered = generic_lower_expression(exp, state)
            node.exps[index] = lowered
            if node._result_adjustment then
                replace_adjusted_value(
                    node._result_adjustment, exp, lowered)
            end
        end
    end
    generic_reclassify_node_open_adjustments(node, state)

    for key, value in pairs(node) do
        if type(key) == "string" and key:sub(1, 1) ~= "_"
           and key ~= "loc" and key ~= "type" and key ~= "rettypes"
           and key ~= "flexrettype" and key ~= "typeparams"
           and key ~= "typeargs" and key ~= "target"
           and key ~= "exps"
           and type(value) == "table" then
            if value._tag and value._tag:match("^Ast%.Exp") then
                node[key] = generic_lower_expression(value, state)
            elseif value._tag then
                generic_lower_node(value, state)
            else
                for index, child in ipairs(value) do
                    if type(child) == "table" and child._tag
                       and child._tag:match("^Ast%.Exp") then
                        value[index] = generic_lower_expression(
                            child, state)
                    elseif type(child) == "table" then
                        generic_lower_node(child, state)
                    end
                end
            end
        end
    end
end

function generic_lower_erased_annotations(root, state)
    -- AST annotations may borrow list and plan tables from the declared type
    -- graph.  Detach those containers while replacing their Type leaves so
    -- lowering cannot rewrite a cached source interface through an alias.
    local memo = {}
    local function visit(value)
        if type(value) ~= "table" then return value end
        local cached = memo[value]
        if cached then return cached end
        if type(value._tag) == "string"
           and value._tag:match("^Type%.") then
            local erased = generic_erased_descriptor(value, state)
            memo[value] = erased
            return erased
        end

        local is_ast = type(value._tag) == "string"
            and value._tag:match("^Ast%.") ~= nil
        local is_list = value[1] ~= nil
        local result = (is_ast or not is_list) and value or {}
        memo[value] = result
        if is_ast then
            -- Runtime lowering still consumes the erased public lists. Keep
            -- the written generic syntax on private edges so source tooling
            -- can visit type-parameter declarations and type-argument
            -- references after checking has resolved their bindings.
            if value.typeparams ~= nil then
                if value._surface_typeparams == nil
                   and type(value.typeparams) == "table"
                   and #value.typeparams > 0 then
                    value._surface_typeparams = value.typeparams
                end
                value.typeparams = {}
            end
            if value.typeargs ~= nil then
                if value._surface_typeargs == nil
                   and type(value.typeargs) == "table"
                   and #value.typeargs > 0 then
                    value._surface_typeargs = value.typeargs
                end
                value.typeargs = {}
            end
        end

        for key, child in pairs(value) do
            if key ~= "_declared_type" and key ~= "_declared_method"
               and key ~= "_resolved_typearg" then
                if type(key) == "string"
                   and (key:match("^_generic")
                        or key == "_nominal_typeargs"
                        or key == "_nominal_typeargs_loc"
                        or key == "_written_nominal_typeargs"
                        or key == "_closed_generic_declaration"
                        or key == "_rigid_receiver_type") then
                    result[key] = nil
                elseif key == "_decl" and is_ast
                   and (value._tag == "Ast.TypeName"
                        or value._tag == "Ast.TypeQualName"
                        or value._tag == "Ast.TypeParam") then
                    -- These nodes have no code-facing role after checking.
                    -- Retain their canonical semantic binding while the
                    -- ordinary runtime type annotations are erased below.
                    result[key] = child
                else
                    result[key] = visit(child)
                end
            elseif result ~= value then
                result[key] = child
            end
        end
        return result
    end
    return visit(root)
end

function generic_refresh_erased_annotations(node)
    local seen = {}
    local function visit(value)
        if type(value) ~= "table" or seen[value] then return end
        seen[value] = true
        local tag = value._tag
        if tag == "Ast.TopLevelFunc" or tag == "Ast.TopLevelStatic"
           or tag == "Ast.TopLevelMethod" or tag == "Ast.ExpFunction"
           or tag == "Ast.InterfaceMethod" then
            annotate_lua_function_boundary(value)
        elseif tag == "Ast.TopLevelVar" then
            value._lua_write_dynamic_plan =
                types.dynamic_coercion(value._type) or false
        elseif tag == "Ast.TopLevelRecord" or tag == "Ast.TopLevelUnion"
               or tag == "Ast.TopLevelInterface" then
            value._dynamic_receiver_plan = types.dynamic_coercion(
                types.Nominal(value._type.name)) or false
            if tag == "Ast.TopLevelInterface" then
                for index, field in ipairs(value.fields or {}) do
                    local descriptor = value._type.fields[index]
                    field._field = descriptor
                    field._dynamic_plan = descriptor
                        and descriptor.dynamic_plan or false
                end
            end
        elseif tag == "Ast.VarBracket" then
            value._read_guard = types.gradual_guard(value._type) or false
        end
        for key, child in pairs(value) do
            if key ~= "_declared_type" and type(child) == "table"
               and not (type(child._tag) == "string"
                        and child._tag:match("^Type%.")) then
                visit(child)
            end
        end
    end
    visit(node)
end

-- The declared module/type snapshots are the public semantic interface handed
-- to resolvers and retained independently of the source AST. Source navigation
-- metadata points in the opposite direction: Type.Parameter._decl reaches its
-- Ast.TypeParam (and potentially the whole declaration tree), while callable
-- _parameter_decls contain Checker.Parameter descriptors shared with the AST.
-- Clone the type graph across that ownership boundary without those two
-- source-only edges. The original type graph and annotated AST keep them.
local declared_interface_source_edge = {
    _decl = true,
    _parameter_decls = true,
}
local declared_interface_cpp = require "c-parser.cpp"

local function clone_declared_interface_graph(value, memo)
    if type(value) ~= "table" then return value end
    memo = memo or {}
    if memo[value] then return memo[value] end
    local copy = {}
    memo[value] = copy
    for key, child in pairs(value) do
        if not declared_interface_source_edge[key] then
            copy[clone_declared_interface_graph(key, memo)] =
                clone_declared_interface_graph(child, memo)
        end
    end
    declared_interface_cpp.copy_graph_annotations(value, copy, function(child)
        return clone_declared_interface_graph(child, memo)
    end)
    return copy
end

function generic_freeze_declared_annotations(root, clone_memo)
    local seen = {}
    local function visit(node)
        if type(node) ~= "table" or seen[node] then return end
        seen[node] = true
        local tag = node._tag
        if type(tag) == "string" and tag:match("^Ast%.") then
            if node._type and (tag:match("^Ast%.TopLevel")
                    or tag == "Ast.Decl"
                    or tag == "Ast.InterfaceMethod"
                    or tag == "Ast.UnionVariant") then
                node._declared_type = clone_memo[node._type]
                    or clone_declared_interface_graph(
                        node._type, clone_memo)
            end
            for key, child in pairs(node) do
                if type(key) == "number" or (type(key) == "string"
                        and (key:sub(1, 1) ~= "_"
                            or key == "_self"
                            or key == "_result_decls")) then
                    if type(child) == "table" then
                        if child._tag then
                            visit(child)
                        else
                            for _, item in ipairs(child) do visit(item) end
                        end
                    end
                end
            end
        elseif tag == nil then
            for _, item in ipairs(node) do visit(item) end
        end
    end
    visit(root)
end

function generic_lower_erased_core(modname, tree, st, errors)
    local clone_memo = {}
    local declared = clone_declared_interface_graph(assert(tree._type,
        "generic erasure requires the declared module graph"), clone_memo)
    tree._declared_type = declared
    generic_freeze_declared_annotations(tree, clone_memo)

    local surface_registry = types.registry
    local erased_registry = generic_prepare_erased_registry(
        surface_registry)
    local state = {
        st = st,
        errors = errors,
        surface_registry = surface_registry,
        erased_registry = erased_registry,
        erased_descriptors = {},
        calls = {},
        spreads = {},
        reverse_wrappers = {},
        hidden_case = 0,
        import_descriptors = {},
    }
    for _, node in ipairs(tree) do
        if node._tag == "Ast.TopLevelImport" and node._type then
            state.import_descriptors[node.modname] =
                generic_lower_import_descriptor(
                    node._type, erased_registry)
        end
    end
    types.registry = erased_registry

    for _, node in ipairs(tree) do generic_lower_node(node, state) end
    generic_lower_erased_annotations(tree, state)

    -- Rebind every top-level declaration to the canonical erased owner member
    -- when it has one.  This keeps module-slot enumeration, nominal methods,
    -- field layouts, and source-private entries on one detached ordinary graph.
    for _, node in ipairs(tree) do
        if node._type then
            node._type = generic_erased_descriptor(node._type, state)
        end
        if node._tag == "Ast.TopLevelRecord"
           or node._tag == "Ast.TopLevelUnion"
           or node._tag == "Ast.TopLevelInterface" then
            node._type = erased_registry[modname .. "." .. node.name]
        elseif node._tag == "Ast.TopLevelStatic" and node._nominal_owner then
            local owner = erased_registry[modname .. "." .. node.class]
            if owner and owner.functions then node._type = owner.functions[node.name] end
        elseif node._tag == "Ast.TopLevelMethod" and node._nominal_owner then
            local owner = erased_registry[modname .. "." .. node.class]
            if owner and owner.methods then node._type = owner.methods[node.name] end
        end
    end

    tree._type = makemoduletype(modname, tree, st)
    tree._erased_registry = erased_registry
    generic_refresh_erased_annotations(tree)
    -- Tooling restores this declared owner graph when normalizing an opaque
    -- checked-project payload. Share the already-frozen interface nodes and
    -- strip the same source-navigation edges from external owners; an erased
    -- registry cannot recover generic or source-private surface summaries.
    tree._declared_registry = clone_declared_interface_graph(surface_registry, clone_memo)
    types.assert_erased(tree._type)
    for _, owner in pairs(erased_registry) do types.assert_erased(owner) end
    return declared, surface_registry
end

return core.checker
