local core = require "titan-compiler.checker.core"
local _ENV = core

-- A qualified type member's serialized type can be the transparent target
-- itself, which deliberately loses the alias spelling. Preserve the selected
-- module/name identity in a private checker descriptor for semantic tools;
-- ordinary type checking and serialization continue to use `target`.
local function bind_qualified_type(node, module_decl, module_type, target,
                                   islocal)
    node._module_decl = module_decl
    node._decl = {
        _tag = "Checker.TypeMember",
        modname = module_type.name,
        name = node.name,
        type = target,
        islocal = islocal and true or false,
        _documentation = module_type._type_documentation and module_type._type_documentation[node.name],
    }
end

local function local_owner_declaration(st, name)
    local declaration = st:find_symbol(name)
    if declaration and (declaration._tag == "Ast.TopLevelRecord"
            or declaration._tag == "Ast.TopLevelUnion") then
        return declaration
    end
    return st.interface_declarations
        and st.interface_declarations[name] or nil
end

function resolve_surface_c_type(name, st, errors, loc)
    if not foreigntypes.is_surface_primitive_name(name) then return nil end
    if name == "void" then return types.CVoid() end
    if name == "lua_State" then
        return types.CStruct(nil, "lua_State", nil, {}, false, false)
    end

    local profile, profile_error = ensure_c_profile(st)
    if not profile then
        return invalid(errors, loc,
            "cannot resolve C99 type '%s': %s", name,
            tostring(profile_error))
    end
    local typ = foreigntypes.surface_primitive(profile, name)
    if not typ then
        return invalid(errors, loc,
            "C99 type '%s' is unavailable in the target C profile", name)
    end
    return typ
end

-- Preserve converter-supplied C declaration origins for owner/callable keys.
-- Module scope is only a fallback for synthetic descriptors without an origin.
-- Follow structural wrappers only: a named typedef or aggregate is the identity
-- boundary, not its fields or definition.
local function scope_foreign_type_surface(typ, st, seen)
    if type(typ) ~= "table" then return end
    seen = seen or {}
    if seen[typ] then return end
    seen[typ] = true
    local tag = typ._tag
    if tag == "Type.CTypedef" or tag == "Type.CStruct"
       or tag == "Type.CUnion" then
        if not (tag == "Type.CStruct" and types.is_c_lua_state(typ)) then
            typ._ffi_scope = typ._ffi_scope or (st.modname .. ".ffi")
        end
    elseif tag == "Type.CPointer" then
        scope_foreign_type_surface(typ.pointee, st, seen)
    elseif tag == "Type.CArray" then
        scope_foreign_type_surface(typ.elem, st, seen)
    elseif tag == "Type.CFunction" then
        for _, param in ipairs(typ.params) do
            scope_foreign_type_surface(param, st, seen)
        end
        scope_foreign_type_surface(typ.ret, st, seen)
    end
end

-- Converts an AST type declaration into a typechecker type
--   node: AST node
--   errors: list of compile-time errors
--   returns a type (from types.lua)
typefromnode = util.make_visitor({
    ["Ast.TypeNil"] = function(_, _, _)
        return types.Nil()
    end,

    ["Ast.TypeBoolean"] = function(_, _, _)
        return types.Boolean()
    end,

    ["Ast.TypeInteger"] = function(_, _, _)
        return types.Integer()
    end,

    ["Ast.TypeFloat"] = function(_, _, _)
        return types.Float()
    end,

    ["Ast.TypeString"] = function(_, _, _)
        return types.String()
    end,

    ["Ast.TypeValue"] = function(_, _, _)
        return types.Value()
    end,

    ["Ast.TypeName"] = function(node, st, errors,
                                    defer_c_enum_carrier)
        completion_lexical(node, st, errors, "type")
        local parameter = st:find_type_parameter(node.name)
        if parameter then
            node._decl = parameter._decl or parameter
            if #(node.typeargs or {}) > 0 then
                return invalid(errors, node.loc,
                    "type parameter '%s' cannot be applied to type arguments",
                    node.name)
            end
            return parameter
        end

        local alias = st:find_type_alias(node.name)
        if alias then
            node._decl = alias
            local typ = resolve_type_alias(alias, st, errors)
            if typ._tag == "Type.GenericAlias" then
                return generic_apply_generic_alias(
                    typ, node.typeargs, st, errors, node.loc,
                    "type alias '" .. node.name .. "'")
            elseif #(node.typeargs or {}) > 0 then
                return invalid(errors, node.loc,
                    "type alias '%s' is not a generic type constructor",
                    node.name)
            end
            if checker._ensure_c_enum_supported(
                    st, typ, node.loc, errors, nil,
                    defer_c_enum_carrier and true or false) then
                return typ
            end
            return types.Invalid()
        end


        local owner = generic_resolve_local_owner(node.name, st)
        if owner and (owner._tag == "Type.Record"
                or owner._tag == "Type.Union"
                or owner._tag == "Type.Interface") then
            node._decl = local_owner_declaration(st, node.name) or owner
            return generic_apply_named_owner(owner, node.typeargs, st, errors,
                node.loc, "type '" .. node.name .. "'")
        end
        if #(node.typeargs or {}) > 0 then
            return invalid(errors, node.loc,
                "type '%s' is not a generic nominal or interface", node.name)
        end
        return types.Nominal(st.modname .. "." .. node.name)
    end,

    ["Ast.TypeQualName"] = function(node, st, errors,
                                        defer_c_enum_carrier)
        completion_qualified_type(node, st, errors)
        local mod = st:find_symbol(node.module)
        if mod then node._module_decl = mod end
        if mod and mod._current_module then
            -- The implicit M denotes this module, not a lexical value or
            -- generic type binder with the selected member's spelling.
            local alias = st:find_type_alias(node.name)
            if alias then
                node._decl = alias
                local typ = resolve_type_alias(alias, st, errors)
                if typ._tag == "Type.GenericAlias" then
                    return generic_apply_generic_alias(typ, node.typeargs,
                        st, errors, node.loc, "type alias 'M." .. node.name .. "'")
                elseif #(node.typeargs or {}) > 0 then
                    return invalid(errors, node.loc,
                        "type alias 'M.%s' is not a generic type constructor", node.name)
                end
                if checker._ensure_c_enum_supported(st, typ, node.loc, errors,
                        nil, defer_c_enum_carrier and true or false) then
                    return typ
                end
                return types.Invalid()
            end
            local declaration = st.interface_declarations
                and st.interface_declarations[node.name] or st.blocks[1][node.name]
            if declaration and (declaration._tag == "Ast.TopLevelRecord"
                    or declaration._tag == "Ast.TopLevelUnion"
                    or declaration._tag == "Ast.TopLevelInterface") then
                node._decl = declaration
                return generic_apply_named_owner(declaration._type,
                    node.typeargs, st, errors, node.loc,
                    "type 'M." .. node.name .. "'")
            end
            return invalid(errors, node.loc,
                "type '%s' not found inside the current module", node.name)
        end
        if node._contextual_c_name and mod and mod._type
           and mod._type._tag ~= "Type.CModule" then
            return invalid(errors, node.loc,
                "Titan keyword '%s' is only contextual for a C type",
                node.name)
        end
        if mod and mod._type and mod._type._tag == "Type.Module" then
            local type_member, type_member_islocal =
                types.module_type_member(
                    mod._type, node.name, mod._source_import)
            local subject = "type '" .. mod._type.name .. "." ..
                node.name .. "'"
            if type_member and type_member._tag == "Type.GenericAlias" then
                local owner = types.registry[type_member.target_owner_fqtn]
                if owner and not is_nominal_visible_from(st, owner.name) then
                    return invalid(errors, node.loc,
                        "nominal type '%s' is local to module '%s'",
                        owner.name, mod._type.name)
                end
                bind_qualified_type(node, mod, mod._type, type_member,
                    type_member_islocal)
                return generic_apply_generic_alias(
                    type_member, node.typeargs, st, errors,
                    node.loc, subject)
            elseif type_member and type_member._tag == "Type.Interface" then
                if not is_nominal_visible_from(st, type_member.name) then
                    return invalid(errors, node.loc,
                        "interface type '%s' is local to module '%s'",
                        node.name, mod._type.name)
                end
                bind_qualified_type(node, mod, mod._type, type_member,
                    type_member_islocal)
                return generic_apply_named_owner(
                    type_member, node.typeargs, st, errors,
                    node.loc, subject)
            elseif type_member then
                -- A non-GenericAlias type member is a concrete transparent
                -- alias. It has zero constructor arity even when its Nominal
                -- target is an applied generic owner.
                if #(node.typeargs or {}) > 0 then
                    return invalid(errors, node.loc,
                        "type alias '%s.%s' is not a generic type constructor",
                        node.module, node.name)
                elseif type_member._tag == "Type.Nominal"
                   and types.registry[type_member.fqtn]
                   and not is_nominal_visible_from(st, type_member.fqtn) then
                    return invalid(errors, node.loc,
                        "nominal type '%s' is local to module '%s'",
                        type_member.fqtn, mod._type.name)
                end
                if checker._ensure_c_enum_supported(
                        st, type_member, node.loc, errors, nil,
                        defer_c_enum_carrier and true or false) then
                    bind_qualified_type(node, mod, mod._type, type_member,
                        type_member_islocal)
                    return type_member
                end
                return types.Invalid()
            end

            local fqtn = mod._type.name .. "." .. node.name
            local member = types.module_member(
                mod._type, node.name, mod._source_import)
            if not member then
                return invalid(errors, node.loc,
                    "type '%s' not found inside module '%s'",
                    node.name, mod._type.name)
            elseif member.type._tag ~= "Type.Record"
               and member.type._tag ~= "Type.Union" then
                return invalid(errors, node.loc,
                    "member '%s' inside module '%s' is not a nominal type",
                    node.name, mod._type.name)
            elseif not is_nominal_visible_from(st, fqtn) then
                return invalid(errors, node.loc,
                    "%s type '%s' is local to module '%s'",
                    member.type._tag == "Type.Record" and "record" or "union",
                    node.name, mod._type.name)
            end
            bind_qualified_type(node, mod, mod._type, member,
                member.islocal)
            return generic_apply_named_owner(member.type, node.typeargs,
                st, errors, node.loc, "type '" .. fqtn .. "'")
        elseif mod and mod._type and mod._type._tag == "Type.Union" then
            local member = mod._type.variants[node.name]
                or mod._type.functions[node.name]
                or mod._type.methods[node.name]
            if member then
                return invalid(errors, node.loc,
                    "union member '%s.%s' is not a type; use union type '%s' "
                    .. "or a case statement",
                    node.module, node.name, node.module)
            end
        end
        return invalid(errors, node.loc,
            "module '%s' referenced by type not found", node.module)
    end,

    ["Ast.TypeForeignName"] = function(node, st, errors,
                                           defer_c_enum_carrier)
        completion_foreign(node, st, errors, defer_c_enum_carrier)
        local alias = st:find_foreign_alias(node.name)
        local typ
        if alias then
            node._decl = alias
            typ = resolve_foreign_type_alias(alias, st, errors)
        elseif foreigntypes.is_surface_primitive_name(node.name) then
            node._surface_c_type = true
            typ = resolve_surface_c_type(node.name, st, errors, node.loc)
        else
            local namespace = st.ffi_namespace and st.ffi_namespace._type
            typ = namespace and namespace.type_members[node.name]
        end
        if not typ then
            return invalid(errors, node.loc,
                "foreign type '%s' is not declared", node.name)
        end
        if not node._surface_c_type then scope_foreign_type_surface(typ, st) end
        if checker._ensure_c_enum_supported(st, typ, node.loc, errors, nil,
                defer_c_enum_carrier and true or false) then
            return typ
        end
        return types.Invalid()
    end,

    ["Ast.TypeCPointer"] = function(node, st, errors)
        -- Forming a pointer needs only an exact pointee spelling. It does not
        -- carry an enum value and therefore must not force a wide-enum carrier.
        local pointee = typefromnode(node.subtype, st, errors, true)
        local resolved = c_resolve(pointee)
        if not types.is_direct_c(pointee)
           or (resolved and resolved._tag == "Type.COwned") then
            return invalid(errors, node.loc,
                "C pointer type can only point to a C FFI type, not '%s'",
                types.tostring(pointee))
        end
        return types.CPointer(pointee, node.const and { "const" } or {})
    end,

    ["Ast.TypeCArray"] = function(node, st, errors)
        -- Exact C array storage needs element spelling, not a numeric carrier.
        local elem = typefromnode(node.base, st, errors, true)
        local resolved = c_resolve(elem)
        if not types.is_direct_c(elem)
           or (resolved and resolved._tag == "Type.COwned") then
            elem = invalid(errors, node.base.loc or node.loc,
                "fixed C array element type must be a C FFI type, not '%s'",
                types.tostring(elem))
        end
        local len = node.length and node.length.value
        return types.CArray(elem, len, node.const and { "const" } or {})
    end,

    ["Ast.TypeOwned"] = function(node, st, errors)
        -- `owned` is a Titan constructor over a foreign pointer/array shape.
        -- Resolve aliases before selecting the payload and countedness.
        local foreign = typefromnode(node.subtype, st, errors, true)
        local shape = types.resolve_c_typedef(foreign)
        if shape._tag == "Type.Invalid" then return shape end
        if shape._tag ~= "Type.CPointer" and shape._tag ~= "Type.CArray" then
            return invalid(errors, node.loc,
                "owned type requires a foreign pointer or array, not '%s'",
                types.tostring(foreign))
        end
        if #(shape.quals or {}) > 0
           or #types.c_type_qualifiers(foreign) > 0 then
            return invalid(errors, node.loc,
                "owned type cannot have outer foreign pointer or array qualifiers")
        end
        local counted = shape._tag == "Type.CArray"
        local payload = counted and shape.elem or shape.pointee
        -- `owned Alias` removes the alias's outer pointer/array constructor.
        -- Keep the selected payload's scope just as a directly written
        -- `owned *ImportedType` does, including nested structural wrappers.
        scope_foreign_type_surface(payload, st)
        local alloc_err = c_allocation_error(payload, st)
        if alloc_err then
            return invalid(errors, node.loc, alloc_err)
        end
        return types.COwned(payload, counted)
    end,

    ["Ast.TypeArray"] = function(node, st, errors,
                                     defer_c_enum_carrier)
        return types.Array(deoptionize(typefromnode(
            node.subtype, st, errors, defer_c_enum_carrier)),
            node.isconst)
    end,

    ["Ast.TypeMap"] = function(node, st, errors,
                                   defer_c_enum_carrier)
        local key = typefromnode(
            node.keystype, st, errors, defer_c_enum_carrier)
        if key._tag == "Type.Nil" then
            checker.typeerror(errors, node.loc, "type of map key cannot be nil", node.module)
            key = types.Invalid()
        elseif key._tag == "Type.Option" then
            checker.typeerror(errors, node.loc, "type of map key cannot be option type", node.module)
            key = deoptionize(key)
        end
        return types.Map(key,
            deoptionize(typefromnode(
                node.valuestype, st, errors, defer_c_enum_carrier)))
    end,

    ["Ast.TypeForeignFunction"] = function(node, st, errors)
        local cfunction = checker._foreign_function_signature(
            node.argtypes, node.rettypes, node.varargtype,
            node.flexrettype, st, errors, "foreign function type")
        return types.CPointer(cfunction, {})
    end,

    ["Ast.TypeFunction"] = function(node, st, errors,
                                        defer_c_enum_carrier)
        -- First-class function type `(P...) -> (R...)`. argtypes and rettypes
        -- are lists of type nodes; a nested arrow (`a -> b -> c`, right
        -- associative) shows up as a TypeFunction inside rettypes and recurses.
        local ptypes = {}
        for _, pt in ipairs(node.argtypes) do
            table.insert(ptypes, typefromnode(
                pt, st, errors, defer_c_enum_carrier))
        end
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(
                rt, st, errors, defer_c_enum_carrier))
        end
        -- A first-class variadic function type `(P..., ...: t) -> (R...)` carries
        -- its element type node on `node.varargtype` (nil when absent); set
        -- the resulting Type.Function's `varargtype` slot accordingly.
        local varargtype = node.varargtype
            and check_varg_elem(typefromnode(
                node.varargtype, st, errors, defer_c_enum_carrier),
                                node.varargtype.loc, errors, "parameter")
            or nil
        local flexrettype = flexible_return_type(
            node, st, errors, defer_c_enum_carrier)
        return types.Function(ptypes, rettypes, false, varargtype, flexrettype)
    end,

    ["Ast.TypeOption"] = function(node, st, errors,
                                      defer_c_enum_carrier)
        local typ = optionize(typefromnode(
            node.basetype, st, errors, defer_c_enum_carrier))
        if typ._tag == "Type.Option"
           and not types.has_tvalue_representation(typ.base) then
            return invalid(errors, node.loc,
                "option type cannot contain '%s' because it has no TValue representation",
                types.tostring(typ.base))
        end
        return typ
    end
})

function generic_scope_for_node(node, st, owner)
    local owner_fqtn = owner and owner._type and owner._type.name or nil
    local tag = node._tag
    local role, kind
    if tag == "Ast.TopLevelRecord" then
        role, kind, owner_fqtn = "owner", "record", st.modname .. "." .. node.name
    elseif tag == "Ast.TopLevelUnion" then
        role, kind, owner_fqtn = "owner", "union", st.modname .. "." .. node.name
    elseif tag == "Ast.TopLevelInterface" then
        role, kind, owner_fqtn = "owner", "interface", st.modname .. "." .. node.name
    elseif tag == "Ast.TopLevelMethod" then
        role, kind = "method", "method"
    elseif tag == "Ast.TopLevelStatic" then
        role, kind = "static", "static"
    elseif tag == "Ast.InterfaceMethod" then
        role, kind = "method", "method"
    else
        role, kind, owner_fqtn = "function", "function", nil
    end
    local callable_name = nil
    if role ~= "owner" then callable_name = node.name end
    return types.GenericScope(st.modname, owner_fqtn,
        callable_name, role, kind)
end

function generic_reserve_generic_binders(node, scope, st, errors)
    if node._generic_bindings then return end
    node._generic_scope = scope
    node._generic_bindings = {}
    node._generic_parameters = {}
    node._generic_typeparams = {}

    local active_names = {}
    for index, typeparam in ipairs(node.typeparams or {}) do
        typeparam._decl = typeparam
        local name = typeparam.name
        local active = st:find_type_parameter(name)
        if active then
            checker.typeerror(errors, typeparam.loc,
                "type parameter '%s' cannot shadow an active owner type parameter",
                name)
        elseif active_names[name] then
            checker.typeerror(errors, typeparam.loc,
                "duplicate type parameter '%s' in declaration '%s'",
                name, tostring(node.name))
        else
            active_names[name] = true
        end
        local parameter = types.Parameter(scope, index, name, nil)
        parameter._decl = typeparam
        node._generic_parameters[index] = parameter
        if not node._generic_bindings[name] then
            node._generic_bindings[name] = parameter
        end
        node._generic_typeparams[index] = types.TypeParameter(name, nil)
        typeparam._type = parameter
    end
    st.generic_scope_bindings[types.generic_scope_key(scope)] =
        node._generic_typeparams
end

function generic_collect_local_constraint_parameters(
        typ, scope, found, seen)
    if type(typ) ~= "table" or not typ._tag then return end
    seen = seen or {}
    if seen[typ] then return end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Parameter" then
        if types.same_generic_scope(typ.scope, scope) then
            found[typ.index] = true
        end
        -- The referenced binder's own constraint is a graph edge handled by
        -- the caller, not a structural child of this occurrence.
    elseif tag == "Type.Nominal" then
        for _, argument in ipairs(typ.args or {}) do
            generic_collect_local_constraint_parameters(
                argument, scope, found, seen)
        end
    elseif tag == "Type.Option" then
        generic_collect_local_constraint_parameters(
            typ.base, scope, found, seen)
    elseif tag == "Type.Array" then
        generic_collect_local_constraint_parameters(
            typ.elem, scope, found, seen)
    elseif tag == "Type.Map" then
        generic_collect_local_constraint_parameters(
            typ.keys, scope, found, seen)
        generic_collect_local_constraint_parameters(
            typ.values, scope, found, seen)
    elseif tag == "Type.Function" then
        for _, parameter in ipairs(typ.params or {}) do
            generic_collect_local_constraint_parameters(
                parameter, scope, found, seen)
        end
        for _, result in ipairs(typ.rettypes or {}) do
            generic_collect_local_constraint_parameters(
                result, scope, found, seen)
        end
        if typ.varargtype then
            generic_collect_local_constraint_parameters(
                typ.varargtype, scope, found, seen)
        end
        if typ.flexrettype then
            generic_collect_local_constraint_parameters(
                typ.flexrettype, scope, found, seen)
        end
    elseif tag == "Type.CTypedef" then
        generic_collect_local_constraint_parameters(
            typ.target, scope, found, seen)
    end
end

function generic_reject_constraint_cycles(node, errors)
    local count = #(node._generic_typeparams or {})
    if count == 0 or node._generic_scope == nil then return end

    local edges = {}
    for index, typeparam in ipairs(node._generic_typeparams) do
        edges[index] = {}
        if typeparam.constraint ~= nil then
            generic_collect_local_constraint_parameters(
                typeparam.constraint, node._generic_scope, edges[index])
        end
    end

    local state, stack, position, cyclic = {}, {}, {}, {}
    local function visit(index)
        state[index] = 1
        stack[#stack + 1] = index
        position[index] = #stack
        for target = 1, count do
            if edges[index][target] then
                if state[target] == nil then
                    visit(target)
                elseif state[target] == 1 then
                    for slot = position[target], #stack do
                        cyclic[stack[slot]] = true
                    end
                end
            end
        end
        position[index] = nil
        stack[#stack] = nil
        state[index] = 2
    end
    for index = 1, count do
        if state[index] == nil then visit(index) end
    end

    local names, first_loc = {}, nil
    for index = 1, count do
        if cyclic[index] then
            local syntax = node.typeparams[index]
            names[#names + 1] = "'" .. syntax.name .. "'"
            first_loc = first_loc
                or (syntax.constraint and syntax.constraint.loc)
                or syntax.loc
            -- Recover as an unconstrained binder after the declaration error;
            -- this breaks the carrier cycle for later graph walks.
            node._generic_typeparams[index] =
                types.TypeParameter(syntax.name, nil)
            node._generic_parameters[index].erased_constraint = nil
        end
    end
    if #names > 0 then
        checker.typeerror(errors, first_loc or node.loc,
            "cyclic type parameter constraints involving %s",
            table.concat(names, ", "))
    end
end

function generic_resolve_generic_constraints(node, st, errors)
    if node._generic_constraints_resolved then return end
    node._generic_constraints_resolved = true
    st:push_generic_type_scope(node._generic_bindings)
    for index, syntax in ipairs(node.typeparams or {}) do
        local constraint = nil
        if syntax.constraint then
            local resolved = typefromnode(syntax.constraint, st, errors)
            local owner = generic_owner_type(resolved)
            if resolved._tag ~= "Type.Nominal" or not owner
               or owner._tag ~= "Type.Interface" then
                checker.typeerror(errors, syntax.constraint.loc or syntax.loc,
                    "constraint of type parameter '%s' must be an Interface application, found '%s'",
                    syntax.name, types.tostring(resolved))
            else
                constraint = resolved
            end
        end
        node._generic_typeparams[index] =
            types.TypeParameter(syntax.name, constraint)
    end
    generic_reject_constraint_cycles(node, errors)
    -- Every same-scope binder is reserved before constraints resolve, so a
    -- forward acyclic constraint may depend on a later binder's carrier.
    -- Iterate the finite dependency DAG after cycle recovery until every
    -- recursively erased Interface application is stable.
    for _ = 1, math.max(1, #(node.typeparams or {})) do
        local changed = false
        for index, typeparam in ipairs(node._generic_typeparams) do
            local carrier = typeparam.constraint and types.erase_constraint(typeparam.constraint)
            local previous = node._generic_parameters[index].erased_constraint
            if (previous == nil) ~= (carrier == nil)
               or (carrier ~= nil
                   and not types.equals(previous, carrier)) then
                node._generic_parameters[index].erased_constraint = carrier
                changed = true
            end
        end
        if not changed then break end
    end
    st:pop_generic_type_scope()
end

function generic_prepare_generic_binders(node, st, errors, owner)
    if #(node.typeparams or {}) == 0 then
        node._generic_scope = nil
        node._generic_bindings = node._generic_bindings or {}
        node._generic_parameters = node._generic_parameters or {}
        node._generic_typeparams = node._generic_typeparams or {}
        node._generic_constraints_resolved = true
        return
    end
    local scope = node._generic_scope or generic_scope_for_node(node, st, owner)
    generic_reserve_generic_binders(node, scope, st, errors)
    generic_resolve_generic_constraints(node, st, errors)
end

function generic_with_generic_binding_map(st, bindings, body, ...)
    if not bindings or next(bindings) == nil then
        return body(...)
    end
    st:push_generic_type_scope(bindings)
    local results = table.pack(body(...))
    st:pop_generic_type_scope()
    return table.unpack(results, 1, results.n)
end

function generic_with_owner_bindings(owner, st, body, ...)
    return generic_with_generic_binding_map(
        st, owner and owner._generic_bindings, body, ...)
end

function generic_with_declaration_bindings(node, st, body, ...)
    local owner = node._nominal_owner
    local function with_local(...)
        return generic_with_generic_binding_map(
            st, node._generic_bindings, body, ...)
    end
    return generic_with_owner_bindings(owner, st, with_local, ...)
end

-- tries to coerce node to target type
--    node: expression node
--    target: target type
--    returns node wrapped in a coercion, or original node
function is_mutable_c_address_source(source)
    if source._tag ~= "Ast.ExpVar" or source.var._tag ~= "Ast.VarName" then
        return false
    end
    local decl = source.var._decl
    return decl and decl._tag == "Ast.Decl"
        and not decl.isconst
        and not decl._captured
        and types.is_direct_c(source._type)
end

function mark_mutable_c_address_source(source)
    if source._tag == "Ast.ExpVar" and source.var._tag == "Ast.VarName"
       and source.var._decl then
        source.var._decl._assigned = true
        source.var._decl._c_address_taken = source.loc
    end
end

function c_pointer_is_const(target)
    target = types.resolve_c_typedef(target)
    if not target or target._tag ~= "Type.CPointer" then return false end
    return types.c_pointer_has_qual(target, "const")
end

-- Binding constness on an inline C aggregate is shallow but still covers the
-- bytes owned by that declaration.  It may be passed by value or borrowed
-- through a pointer-to-const; it must never regain a mutable address through
-- array decay, an out-parameter adjustment, or an explicit reinterpretation.
function reject_const_c_mutable_address(source, target, errors, use)
    local target_resolved = types.resolve_c_typedef(target)
    if not target_resolved
       or target_resolved._tag ~= "Type.CPointer"
       or c_pointer_is_const(target) then
        return false
    end
    local decl = const_inline_c_storage_decl(source)
    if not decl then return false end
    checker.typeerror(errors, source.loc,
        "cannot take a mutable C address of inline storage from const local '%s'%s",
        decl.name, use and (" in " .. use) or "")
    return true
end

function failed_c_adjustment(source, target)
    local n = ast.ExpCast(source.loc, source, target)
    n._implicit_coercion = true
    n._c_conversion_failed = true
    n._type = target
    return n
end

function pointer_category_diagnostic(
        source_pointer, target, errors, loc, use)
    local source_category = types.c_pointer_category(source_pointer)
    local target_category = types.c_pointer_category(target)
    if not source_category or not target_category
       or source_category == target_category then
        return false
    end
    if (source_category == "object" and target_category == "function")
       or (source_category == "function"
           and target_category == "object") then
        checker.typeerror(errors, loc,
            "cannot convert %s pointer '%s' to %s pointer '%s'%s",
            source_category, types.tostring(source_pointer),
            target_category, types.tostring(target),
            use and (" in " .. use) or "")
        return true
    end
    return false
end

-- Validate one contextual or explicit object-pointer reinterpretation. Returns
-- an optional conversion plus whether a definitive diagnostic was emitted.
-- An unrelated pointer pair returns nil without claiming diagnostic ownership.
function checker._unsafe_c_pointer_conversion(
        source, target, errors, use)
    if types.equals(types.resolve_c_typedef(source._type),
                    types.resolve_c_typedef(target)) then
        return nil
    end

    local source_pointer = source._type
    local conversion_kind = "unsafe_object_pointer"
    local address_source = false
    local source_res = types.resolve_c_typedef(source._type)

    -- An array expression always reaches a pointer conversion through ordinary
    -- C decay, regardless of whether it names a local or an imported object.
    -- Keep it distinct from struct/union local-address adjustment: codegen casts
    -- the decayed expression and must never synthesize `&array`.
    if source_res and source_res._tag == "Type.CArray" then
        source_pointer = assert(types.c_local_address_pointer(source._type))
    end

    local candidate = types.c_unsafe_object_pointer_candidate(
        source_pointer, target)
    if not candidate and source_res
       and source_res._tag ~= "Type.CArray"
       and is_mutable_c_address_source(source) then
        local natural_pointer =
            types.c_local_address_pointer(source._type)
        if natural_pointer then
            source_pointer = natural_pointer
            candidate = types.c_unsafe_object_pointer_candidate(
                source_pointer, target)
            if candidate then
                conversion_kind =
                    "address_then_unsafe_object_pointer"
                address_source = true
            end
        end
    end

    local discarded =
        types.c_discarded_pointer_qualifier(source_pointer, target)
    if discarded then
        checker.typeerror(errors, source.loc,
            "unsafe C conversion from '%s' to '%s' would discard %s%s",
            types.tostring(source_pointer), types.tostring(target),
            discarded, use and (" in " .. use) or "")
        return nil, true
    end

    if not candidate then
        if pointer_category_diagnostic(
                source_pointer, target, errors, source.loc, use) then
            return nil, true
        end
        return nil
    end

    local st = active_check_state
    local module_probe, probe_error
    if st then
        module_probe, probe_error = checker._probe_for_c_types(
            st, { source_pointer, target })
    else
        probe_error = "no active checker context"
    end
    if not module_probe then
        checker.typeerror(errors, source.loc,
            "cannot validate C conversion because the probe service " ..
            "could not be configured%s: %s",
            use and (" for " .. use) or "", tostring(probe_error))
        return nil, true
    end

    local result = module_probe:probe_unsafe_object_pointer(
        source_pointer, target)
    if result.status ~= "success" then
        checker.typeerror(errors, source.loc, "%s%s",
            result.message or
                "cannot validate the unsafe C object-pointer conversion",
            use and (" in " .. use) or "")
        return nil, true
    end

    if address_source then
        mark_mutable_c_address_source(source)
    end
    return {
        kind = conversion_kind,
        source = source_pointer,
        target = target,
        probe_key = result.key,
    }
end

function adjust_unsafe_c_pointer(source, target, errors, use)
    local conversion, rejected = checker._unsafe_c_pointer_conversion(
        source, target, errors, use)
    if not conversion then
        return rejected and failed_c_adjustment(source, target) or source
    end
    local n = ast.ExpCast(source.loc, source, target)
    n._implicit_coercion = true
    n._c_conversion = conversion
    n._type = target
    return n
end

-- Implementation notes: doc/implementation/checker.md#trycoerce-tryforce-trytostr
function trycoerce(source, target, errors, use,
                         precomputed_adjustment)
    if reject_const_c_mutable_address(
            source, target, errors, use) then
        return failed_c_adjustment(source, target), nil, true
    end
    if is_mutable_c_address_source(source)
       and types.c_mutable_address_coerceable(source._type, target)
       and not types.c_address_coerceable(source._type, target) then
        mark_mutable_c_address_source(source)
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = {
            kind = "direct_coercion",
            source = source._type,
            target = target,
            coercion = {
                kind = "coercion",
                op = "mutable_c_address",
                source = source._type,
                target = target,
            },
        }
        n._type = target
        return n, n._adjustment
    end

    local source_c_type = types.resolve_c_typedef(source._type)
    if source_c_type and source_c_type._tag == "Type.CPointer"
       and types.c_mutable_address_coerceable(source._type, target) then
        -- An exact pointer out-parameter denotes the pointer variable's own
        -- storage. A const/captured binding or temporary has no mutable local
        -- address; do not silently reinterpret its pointer value instead.
        checker.typeerror(errors, source.loc,
            "cannot take a mutable C address of non-addressable "
            .. "expression of type '%s'%s", types.tostring(source._type),
            use and (" in " .. use) or "")
        return failed_c_adjustment(source, target), nil, true
    end

    local prepared = precomputed_adjustment
    if prepared == nil then prepared = maybe3.unknown() end
    assert(maybe3.validate(prepared), "invalid precomputed adjustment state")
    local adjustment, interface_conversion, interface_failure
    if prepared.tag == "unknown" then
        adjustment, interface_conversion, interface_failure =
            checker_assignment_adjustment(
                source._type, target, active_check_state)
    else
        adjustment = maybe3.get_checked(prepared, "precomputed adjustment")
        interface_conversion = adjustment and adjustment.interface_conversion
    end
    if not adjustment then
        if report_interface_failure(
                errors, source.loc, interface_failure) then
            return source, nil, true
        end
        -- A raw `value` cannot implicitly establish a C pointee type. Keep the
        -- old unsafe C-object probe for actual C address expressions only.
        if source._type._tag == "Type.Value" then
            return source, nil, false
        end
        local adjusted =
            adjust_unsafe_c_pointer(source, target, errors, use)
        if adjusted._c_conversion then
            return adjusted, adjusted._c_conversion, false
        elseif adjusted._c_conversion_failed then
            return adjusted, nil, true
        else
            return adjusted, nil, false
        end
    elseif adjustment.kind == "identity" then
        return source, adjustment
    elseif adjustment.kind == "callable" then
        -- A non-exact callable edge is an allocating semantic operation even
        -- though both endpoints use TValue representation. Reify the one
        -- already-classified plan as the existing cast node; the child keeps
        -- its actual type and no metadata copy is left to trigger a second
        -- lowering pass.
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = adjustment
        n._callable_adapter = checker.freeze_callable_adapter(
            adjustment, source._type, target, source.loc)
        n._type = target
        return n, adjustment
    elseif adjustment.kind == "gradual_view"
        and adjustment.op == "structural" then
        -- Structural Array/Map views retain their producer type and carry the
        -- complete checker decision on the expression delivered to the sink.
        source._assignment_adjustment = adjustment
        return source, adjustment
    elseif adjustment.kind == "gradual_view" then
        assert(adjustment.op == "inject" or adjustment.op == "project",
            "unknown gradual assignment view")
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = adjustment
        n._interface_conversion = interface_conversion
        n._type = target
        return n, adjustment
    elseif adjustment.kind == "direct_coercion" then
        -- Keep one node for the one checker decision. Option force/wrap/map
        -- plans already carry their inner operation; the coder lowers that
        -- recorded plan without asking the relation again.
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = adjustment
        n._interface_conversion = interface_conversion
        n._type = target
        return n, adjustment
    elseif adjustment.kind == "written_cast" then
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = adjustment
        n._written_cast = maybe3.just(adjustment)
        n._interface_conversion = interface_conversion
        n._type = target
        return n, adjustment
    else
        error("unknown assignment adjustment kind " ..
            tostring(adjustment.kind))
    end
end

function coerce_and_check(source, target, term, errors, loc,
                                precomputed_adjustment)
    local exp, adjustment, precise_error = trycoerce(
        source, target, errors, term, precomputed_adjustment)
    if adjustment and adjustment.kind ~= "identity" then
        local stored = exp._adjustment
            or exp._assignment_adjustment
            or exp._c_conversion
        assert(stored == adjustment,
            "accepted nonidentity sink lost its checker decision")
    end
    checkmatch(term, target, exp, errors, loc or exp.loc,
        maybe3.from_optional(adjustment),
        precise_error)
    return exp
end

-- force option if present
--    node: expression node
--    returns node wrapped in a coercion, or original node
function tryforce(node)
    if node._type._tag == "Type.Option" then
        local n = ast.ExpCast(node.loc, node, node._type.base)
        n._implicit_coercion = true
        n._adjustment = assert(types.assignment_adjustment(
            node._type, node._type.base),
            "automatic Option projection lacks an assignment plan")
        n._type = node._type.base
        return n
    else
        return node
    end
end

-- Logical operators observe truthiness; they do not assign their operands to
-- boolean sinks. In particular, a value may hold any Lua value here, whereas
-- an ordinary value-to-boolean assignment requires an actual boolean tag.
function truthiness(node)
    if node._type._tag == "Type.Boolean" then return node end
    local target = types.Boolean()
    local n = ast.ExpCast(node.loc, node, target)
    n._implicit_coercion = true
    n._operator_conversion = {
        kind = "operator_conversion",
        op = "truthiness",
        source = node._type,
        target = target,
    }
    n._type = target
    return n
end

function trytostr(node)
    local source = node._type
    if source._tag == "Type.Integer" or
       source._tag == "Type.Float" then
        local n = ast.ExpCast(node.loc, node, types.String())
        n._implicit_coercion = true
        n._operator_conversion = {
            kind = "operator_conversion",
            op = "number_to_string",
            source = source,
            target = types.String(),
        }
        n._type = types.String()
        return n
    else
        return node
    end
end

function nil_can_adjust_to(typ)
    return typ and types.assignment_adjustment(types.Nil(), typ) ~= nil
end

return core.checker
