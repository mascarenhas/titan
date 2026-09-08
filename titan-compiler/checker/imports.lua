local core = require "titan-compiler.checker.core"
local _ENV = core

-- Walk a recovered interface type and, for every Nominal or forwarding
-- GenericAlias that names another module, recover that module before
-- reconciling generic arity and canonical binder projections. This preserves
-- the existing nominal-owner/exposer provenance path; it does not introduce a
-- second registry or another provider identity mechanism.
function checker._recovered_nominal_owner(module, fqtn)
    if type(module) ~= "table" then return nil end
    for _, member in ipairs(module.members or {}) do
        local typ = member.type or member
        if type(typ) == "table" and typ.name == fqtn
           and (typ._tag == "Type.Record" or typ._tag == "Type.Union") then
            return typ
        end
    end
    local name = fqtn:match("([^.]+)$")
    local typ = name and module.type_members and module.type_members[name]
    if type(typ) == "table" and typ.name == fqtn
       and typ._tag == "Type.Interface" then
        return typ
    end
end

function checker._recovered_generic_alias(module, fqtn)
    if type(module) ~= "table" then return nil end
    local name = fqtn:match("([^.]+)$")
    local alias = name and module.type_members and module.type_members[name]
    if type(alias) == "table" and alias._tag == "Type.GenericAlias"
       and alias.module .. "." .. alias.name == fqtn then
        return alias
    end
end

function checker._recovered_typeparams_equal(left, right)
    left, right = left or {}, right or {}
    if #left ~= #right then return false end
    for index = 1, #left do
        if not types.alpha_equals(left[index], right[index]) then
            return false
        end
    end
    return true
end

function checker._recover_referenced_module(
        modname, loader, seen, exposing_module, interface_seen)
    local module_key = "\0module-interface:" .. modname
    if seen[module_key] then return seen[module_key] end

    local memo = { pending = true }
    seen[module_key] = memo
    local request = {
        kind = "nominal-owner",
        exposer = exposing_module,
        interface_seen = interface_seen,
        reference_seen = seen,
    }
    -- Loader calls can suspend through the resolver's compiler I/O strategy.
    -- Ordinary lookup failures are already returned as nil/error; exceptions
    -- (in particular Titan Task cancellation) must continue unwinding.
    local module, err = checker.checkimport(modname, loader, request)
    memo.pending = nil
    if module then
        memo.module = module
    else
        memo.error = err
    end
    return memo
end

function checker._recover_referenced_owner(
        fqtn, loader, seen, exposing_module, interface_seen)
    local modname = fqtn:match("^(.*)%.[^.]+$")
    if not modname or modname == "" then return nil, nil end
    local memo = checker._recover_referenced_module(
        modname, loader, seen, exposing_module, interface_seen)
    local owner = checker._recovered_nominal_owner(memo.module, fqtn)
    if memo.module then
        if not owner then
            return nil, "recovered module '" .. modname ..
                "' does not publish nominal owner '" .. fqtn .. "'"
        end
    else
        owner = types.registry[fqtn]
    end
    return owner, memo.error
end

function generic_validate_recovered_application(
        nominal, owner, policy)
    local arguments = nominal.args or {}
    for index, argument in ipairs(arguments) do
        if not types.transient_roundtrip(argument) then
            return nil, "recovered nominal '" .. nominal.fqtn ..
                "' type argument " .. index ..
                " has no sound transient round trip"
        end
    end

    if owner.scope ~= false then
        local reconstructed, reconstruction_error = pcall(
            types.substitute, owner, owner.scope, arguments)
        if not reconstructed then
            return nil, "recovered nominal '" .. nominal.fqtn ..
                "' is not a canonical application: " ..
                tostring(reconstruction_error)
        end
    end
    for index, typeparam in ipairs(owner.typeparams or {}) do
        if typeparam.constraint ~= false then
            local closed, constraint = pcall(
                types.substitute, typeparam.constraint,
                owner.scope, arguments)
            if not closed then
                return nil, "recovered nominal '" .. nominal.fqtn ..
                    "' constraint " .. index ..
                    " could not be reconstructed: " .. tostring(constraint)
            end
            if generic_constraint_satisfied(
                    arguments[index], constraint, nil, policy) ~= true then
                return nil, "recovered nominal '" .. nominal.fqtn ..
                    "' type argument " .. index .. " ('" ..
                    types.tostring(arguments[index]) ..
                    "') does not satisfy constraint '" ..
                    types.tostring(constraint) .. "'"
            end
        end
    end
    return true
end

function register_referenced_nominals(
        t, loader, seen, exposing_module, interface_seen, position,
        constraint_policy)
    if type(t) ~= "table" or not t._tag then return true end
    local tag = t._tag
    constraint_policy = constraint_policy or {
        visibility = exposing_module and tostring(exposing_module)
            or "<recovered-interface>",
        method_visible = function(method) return not method.islocal end,
        field_visible = function(field) return not field.islocal end,
        generic_scope_bindings = {},
    }
    constraint_policy.generic_scope_bindings =
        constraint_policy.generic_scope_bindings or {}
    local function register_scope(scope, typeparams)
        if scope == false or scope == nil then return true end
        local key_ok, key = pcall(types.generic_scope_key, scope)
        if not key_ok then
            return nil, "recovered generic scope has an invalid schema"
        end
        local previous = constraint_policy.generic_scope_bindings[key]
        if previous and not checker._recovered_typeparams_equal(
                previous, typeparams) then
            return nil,
                "recovered generic scope has conflicting binder declarations"
        end
        constraint_policy.generic_scope_bindings[key] = previous or typeparams
        return true
    end
    local alias_key
    -- Constraint satisfaction depends on the visibility policy. In particular,
    -- a trusted source-private view may admit local methods that the public
    -- serialized view must reject. Keep graph-cycle/module recovery memoization
    -- shared, but never let a permissive type visit satisfy a stricter policy.
    -- Hold the policy and type objects as real keys rather than stringifying
    -- their addresses, so GC address reuse cannot alias two later visits.
    local policy_visits = seen["\0generic-visit-policies"]
    if not policy_visits then
        policy_visits = {}
        seen["\0generic-visit-policies"] = policy_visits
    end
    local type_visits = policy_visits[constraint_policy]
    if not type_visits then
        type_visits = {}
        policy_visits[constraint_policy] = type_visits
    end
    local position_visits = type_visits[t]
    if not position_visits then
        position_visits = {}
        type_visits[t] = position_visits
    end
    local visit_position = position or "value"
    if tag == "Type.GenericAlias" then
        alias_key = t.module .. "." .. t.name
        local resolving_key = "\0generic-alias-resolving:" .. alias_key
        if seen[resolving_key] then
            return nil, "recovered GenericAlias chain is cyclic at '" ..
                alias_key .. "'"
        elseif position_visits[visit_position] then
            return true
        end
        seen[resolving_key] = true
    elseif position_visits[visit_position] then
        return true
    end
    position_visits[visit_position] = true

    local function visit(child, child_position)
        return register_referenced_nominals(
            child, loader, seen, exposing_module, interface_seen,
            child_position, constraint_policy)
    end
    local function visit_list(list, child_position)
        for _, child in ipairs(list or {}) do
            local ok, err = visit(child, child_position)
            if not ok then return nil, err end
        end
        return true
    end
    local function visit_binders(typeparams)
        for _, typeparam in ipairs(typeparams or {}) do
            if typeparam.constraint ~= false then
                local ok, err = visit(typeparam.constraint, "constraint")
                if not ok then return nil, err end
            end
        end
        return true
    end

    local ok, err = true, nil
    if tag == "Type.Nominal" then
        local owner, recovery_error = checker._recover_referenced_owner(
            t.fqtn, loader, seen, exposing_module, interface_seen)
        if owner then
            local expected = #(owner.typeparams or {})
            if #(t.args or {}) ~= expected then
                ok, err = nil, "recovered nominal '" .. t.fqtn ..
                    "' expects " .. expected .. " type arguments but found " ..
                    #(t.args or {})
            elseif position == "constraint"
               and owner._tag ~= "Type.Interface" then
                ok, err = nil, "generic constraint '" .. t.fqtn ..
                    "' does not name an Interface"
            end
        elseif recovery_error then
            -- Preserve the historical best-effort nominal recovery boundary:
            -- an unavailable owner stays unresolved and the ordinary checker
            -- reports it at its use. Successfully recovered owners, however,
            -- must reconcile before the import can be trusted.
        end
        if ok then ok, err = visit_list(t.args) end
        if ok and owner then
            ok, err = generic_validate_recovered_application(
                t, owner, constraint_policy)
        end
    elseif tag == "Type.GenericAlias" then
        ok, err = register_scope(t.target_scope, t.typeparams)
        local owner, owner_error
        if ok then
            owner, owner_error = checker._recover_referenced_owner(
                t.target_owner_fqtn, loader, seen,
                exposing_module, interface_seen)
            if not owner then
                ok, err = nil, owner_error or
                    ("could not recover GenericAlias owner '" ..
                        t.target_owner_fqtn .. "'")
            elseif not types.same_generic_scope(t.target_scope, owner.scope)
               or not checker._recovered_typeparams_equal(
                    t.typeparams, owner.typeparams) then
                ok, err = nil,
                    "recovered GenericAlias projection does not match owner '" ..
                        t.target_owner_fqtn .. "'"
            end
        end
        if ok and t.target_alias_fqtn ~= false then
            local target_module_name =
                t.target_alias_fqtn:match("^(.*)%.[^.]+$")
            local memo = checker._recover_referenced_module(
                target_module_name, loader, seen,
                exposing_module, interface_seen)
            local target = checker._recovered_generic_alias(
                memo.module, t.target_alias_fqtn)
            if not target then
                ok, err = nil, memo.error or
                    ("could not recover target GenericAlias '" ..
                        t.target_alias_fqtn .. "'")
            elseif target.target_owner_fqtn ~= t.target_owner_fqtn
               or not types.same_generic_scope(
                    target.target_scope, t.target_scope)
               or not checker._recovered_typeparams_equal(
                    target.typeparams, t.typeparams) then
                ok, err = nil,
                    "recovered GenericAlias projection does not match alias '" ..
                        t.target_alias_fqtn .. "'"
            else
                ok, err = visit(target)
            end
        end
        if ok then ok, err = visit_binders(t.typeparams) end
    elseif tag == "Type.Parameter" then
        if t.erased_constraint ~= false then
            ok, err = visit(t.erased_constraint, "erased-constraint")
        end
    elseif tag == "Type.TypeParameter" then
        if t.constraint ~= false then
            ok, err = visit(t.constraint, "constraint")
        end
    elseif tag == "Type.FunctionScheme" then
        ok, err = register_scope(t.scope, t.typeparams)
        if ok then ok, err = visit_binders(t.typeparams) end
        if ok then ok, err = visit(t.signature) end
    elseif tag == "Type.Array" then
        ok, err = visit(t.elem)
    elseif tag == "Type.Map" then
        ok, err = visit(t.keys)
        if ok then ok, err = visit(t.values) end
    elseif tag == "Type.Option" then
        ok, err = visit(t.base)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable" then
        ok, err = visit(t.type)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        ok, err = register_scope(t.scope, t.typeparams)
        if ok then ok, err = visit_binders(t.typeparams) end
        if ok then ok, err = visit_list(t.params) end
        if ok then ok, err = visit_list(t.rettypes) end
        if ok and t.varargtype then ok, err = visit(t.varargtype) end
        if ok and t.flexrettype then ok, err = visit(t.flexrettype) end
    elseif tag == "Type.Record" then
        ok, err = register_scope(t.scope, t.typeparams)
        if ok then ok, err = visit_binders(t.typeparams) end
        if ok then
            for _, field in ipairs(t.fields or {}) do
                if not field.islocal then
                    ok, err = visit(field.type)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, fn in pairs(t.functions or {}) do
                if not fn.islocal then
                    ok, err = visit(fn)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, method in pairs(t.methods or {}) do
                if not method.islocal then
                    ok, err = visit(method)
                    if not ok then break end
                end
            end
        end
    elseif tag == "Type.Union" then
        ok, err = register_scope(t.scope, t.typeparams)
        if ok then ok, err = visit_binders(t.typeparams) end
        if ok then
            for _, variant in ipairs(t.variants or {}) do
                if not variant.islocal and variant.payload ~= false then
                    ok, err = visit(variant.payload)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, fn in pairs(t.functions or {}) do
                if not fn.islocal then
                    ok, err = visit(fn)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, method in pairs(t.methods or {}) do
                if not method.islocal then
                    ok, err = visit(method)
                    if not ok then break end
                end
            end
        end
    elseif tag == "Type.Interface" then
        ok, err = register_scope(t.scope, t.typeparams)
        if ok then ok, err = visit_binders(t.typeparams) end
        if ok then
            for _, field in ipairs(t.fields or {}) do
                ok, err = visit(field.type)
                if not ok then break end
            end
        end
        if ok then ok, err = visit_list(t.methods) end
    end

    if alias_key then
        seen["\0generic-alias-resolving:" .. alias_key] = nil
    end
    return ok, err
end

function first_local_nominal_type(typ, seen)
    if type(typ) ~= "table" or not typ._tag then return nil end
    seen = seen or {}
    if seen[typ] then return nil end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Nominal" then
        local nominal = types.registry[typ.fqtn]
        if nominal and nominal.islocal then return typ end
        for _, argument in ipairs(typ.args or {}) do
            local found = first_local_nominal_type(argument, seen)
            if found then return found end
        end
        for _, argument in ipairs(typ.args or {}) do
            local found = first_local_nominal_type(argument, seen)
            if found then return found end
        end
    elseif tag == "Type.Parameter" then
        if typ.erased_constraint ~= false then
            return first_local_nominal_type(
                typ.erased_constraint, seen)
        end
    elseif tag == "Type.TypeParameter" then
        if typ.constraint ~= false then
            return first_local_nominal_type(typ.constraint, seen)
        end
    elseif tag == "Type.FunctionScheme" then
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        return first_local_nominal_type(typ.signature, seen)
    elseif tag == "Type.GenericAlias" then
        local owner = types.registry[typ.target_owner_fqtn]
        if owner and owner.islocal then
            return types.Nominal(typ.target_owner_fqtn)
        end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
    elseif tag == "Type.Record" then
        if typ.islocal then return typ end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, field in ipairs(typ.fields or {}) do
            if not field.islocal then
                local found = first_local_nominal_type(field.type, seen)
                if found then return found end
            end
        end
        for _, func in pairs(typ.functions or {}) do
            if not func.islocal then
                local found = first_local_nominal_type(func, seen)
                if found then return found end
            end
        end
        for _, method in pairs(typ.methods or {}) do
            if not method.islocal then
                local found = first_local_nominal_type(method, seen)
                if found then return found end
            end
        end
    elseif tag == "Type.Union" then
        if typ.islocal then return typ end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, variant in ipairs(typ.variants or {}) do
            if not variant.islocal and variant.payload ~= false then
                local found =
                    first_local_nominal_type(variant.payload, seen)
                if found then return found end
            end
        end
        for _, func in pairs(typ.functions or {}) do
            if not func.islocal then
                local found = first_local_nominal_type(func, seen)
                if found then return found end
            end
        end
        for _, method in pairs(typ.methods or {}) do
            if not method.islocal then
                local found = first_local_nominal_type(method, seen)
                if found then return found end
            end
        end
    elseif tag == "Type.Interface" then
        if typ.islocal then return typ end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, field in ipairs(typ.fields or {}) do
            local found = first_local_nominal_type(field.type, seen)
            if found then return found end
        end
        for _, method in ipairs(typ.methods or {}) do
            local found = first_local_nominal_type(method, seen)
            if found then return found end
        end
    elseif tag == "Type.Array" then
        return first_local_nominal_type(typ.elem, seen)
    elseif tag == "Type.Map" then
        return first_local_nominal_type(typ.keys, seen)
            or first_local_nominal_type(typ.values, seen)
    elseif tag == "Type.Option" then
        return first_local_nominal_type(typ.base, seen)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable"
           or tag == "Type.Field" then
        return first_local_nominal_type(typ.type, seen)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, p in ipairs(typ.params or {}) do
            local found = first_local_nominal_type(p, seen)
            if found then return found end
        end
        for _, r in ipairs(typ.rettypes or {}) do
            local found = first_local_nominal_type(r, seen)
            if found then return found end
        end
        if typ.varargtype then
            local found = first_local_nominal_type(typ.varargtype, seen)
            if found then return found end
        end
        if typ.flexrettype then
            return first_local_nominal_type(typ.flexrettype, seen)
        end
    end
end

-- A process may encounter the same owner through both a trusted source edge
-- and a compiled facade. Keep the complete source descriptor canonical in the
-- process-global nominal registry; visibility checks still require a direct
-- source import, so retaining the richer descriptor grants no permission by
-- itself. Unknown `_source_complete` fields are never serialized.
function checker._register_nominal_descriptor(typ, trusted_source)
    local current = types.registry[typ.name]
    if trusted_source then typ._source_complete = true end
    if not current or trusted_source or not current._source_complete then
        -- A metadata expression cannot self-assert this compiler-only marker.
        if not trusted_source then typ._source_complete = nil end
        types.registry[typ.name] = typ
    end
end

function checker.register_module_interface(
        modname, type_or_error, loader, exposer, interface_seen,
        trusted_source, reference_seen)
    exposer = exposer or modname
    interface_seen = interface_seen or {}
    local exposer_key
    if type(exposer) == "table" then
        exposer_key = exposer.static_archive or exposer.filename or
            exposer.name or tostring(exposer)
    else
        exposer_key = tostring(exposer)
    end
    local interface_key = exposer_key .. "\0" .. modname
    if interface_seen[interface_key] then return true end

    -- Normalize before publishing either the interface-seen success marker or
    -- the recovered-module memo. A target-profile mismatch is a real load
    -- failure and must not make a later edge in the same recovery graph reuse
    -- the unnormalized candidate as though registration had succeeded.
    if active_check_state and types.contains_c_numeric_type(type_or_error) then
        local profile, profile_error = ensure_c_profile(active_check_state)
        if not profile then return nil, profile_error end
        local normalized, normalization_error =
            types.normalize_portable_c_numeric_types(
                type_or_error, profile)
        if not normalized then return nil, normalization_error end
    end

    interface_seen[interface_key] = true

    local seen = reference_seen or {}
    local module_key = "\0module-interface:" .. modname
    local module_memo = seen[module_key]
    if not module_memo then
        module_memo = {}
        seen[module_key] = module_memo
    end
    module_memo.module = type_or_error

    -- Type-only re-exports do not copy a nominal's static closures into the
    -- facade module. Stamp the canonical descriptors with their deterministic
    -- owner-userdata prefix slots while the complete owner interface is in
    -- hand, so first-class static references through direct or chained aliases
    -- can recover the closure from that owner after initialization.
    for slot, entry in ipairs(
            types.public_module_prefix_layout(type_or_error)) do
        local index = slot - 1
        if entry.kind == "variable" then
            entry.value._upvalue = index
        else
            entry.value._closure_upvalue = index
        end
    end

    -- Interfaces are type-only module entries. Register every direct
    -- descriptor before traversing any signature so mutually referring
    -- Interfaces have their complete nominal environment available. A source
    -- interface has an additional non-serialized local view; a binary one has
    -- only the ordinary public collections.
    local type_views = { type_or_error.type_members or {} }
    if trusted_source then
        type_views[#type_views + 1] =
            type_or_error.source_type_members or {}
    end
    for _, view in ipairs(type_views) do
        for _, t in pairs(view) do
            if t and t._tag == "Type.Interface" then
                checker._register_nominal_descriptor(t, trusted_source)
            end
        end
    end

    local member_views = { type_or_error.members or {} }
    if trusted_source then
        member_views[#member_views + 1] =
            type_or_error.source_members or {}
    end
    for _, view in ipairs(member_views) do
        for _, member in ipairs(view) do
            -- Nominals arrive wrapped in a Type.ModuleMember. The source view
            -- additionally registers local owners for direct source importers.
            local t = member.type or member
            if t and (t._tag == "Type.Record"
                      or t._tag == "Type.Union") then
                checker._register_nominal_descriptor(t, trusted_source)
            end
        end
    end

    for view_index, view in ipairs(member_views) do
        local policy = { visibility = modname }
        if view_index == 1 then
            policy.method_visible = function(method)
                return not method.islocal
            end
            policy.field_visible = function(field)
                return not field.islocal
            end
        end
        for _, member in ipairs(view) do
            local registered, register_error = register_referenced_nominals(
                member.type or member, loader, seen,
                exposer, interface_seen, nil, policy)
            if not registered then return nil, register_error end
        end
    end
    for view_index, view in ipairs(type_views) do
        local policy = { visibility = modname }
        if view_index == 1 then
            policy.method_visible = function(method)
                return not method.islocal
            end
            policy.field_visible = function(field)
                return not field.islocal
            end
        end
        for _, member in pairs(view) do
            local registered, register_error = register_referenced_nominals(
                member, loader, seen, exposer, interface_seen,
                nil, policy)
            if not registered then return nil, register_error end
        end
    end
    return true
end

function checker.checkimport(modname, loader, request)
    local ok, type_or_error, errors, import_info = loader(modname, request)
    if not ok then return nil, type_or_error end
    local registered, register_error = checker.register_module_interface(
        modname, type_or_error, loader, request and request.exposer,
        request and request.interface_seen,
        import_info and import_info.kind == "source"
            and type_or_error._source == true,
        request and request.reference_seen)
    if not registered then return nil, register_error end
    return type_or_error, errors, import_info
end

-- Builds a type for the module from the types of its public members
--   modast: AST for the module
--   returns "Type.Module" type
function makemoduletype(modname, modast, st)
    local members = {}
    local type_members = {}
    local source_members = {}
    local source_type_members = {}
    local has_source_foreign = false

    local function add_source_member(member)
        member.islocal = true
        source_members[#source_members + 1] = member
        source_members[member.name] = member
    end

    for _, tlnode in ipairs(modast) do
        if not tlnode._ignore then
            local tag = tlnode._tag
            if tag == "Ast.TopLevelImport"
               or tag == "Ast.TopLevelForeignImport" then
                -- Imports are compile-time declarations, not module members.
            elseif tag == "Ast.TopLevelVar" then
                local member = types.ModuleVariable(
                    modname, tlnode.decl.name, tlnode._type,
                    tlnode.isconst and true or false)
                if tlnode.islocal then
                    add_source_member(member)
                else
                    members[#members + 1] = member
                end
            elseif tag == "Ast.TopLevelFunc" then
                local member = types.ModuleMember(modname, tlnode.name,
                    tlnode._type, tlnode._paramnames)
                member._parameter_decls = tlnode._parameter_decls
                if tlnode.islocal then
                    add_source_member(member)
                else
                    members[#members + 1] = member
                end
            elseif tag == "Ast.TopLevelForeignFunc" then
                local member = types.ModuleMember(modname, tlnode.name,
                    tlnode._type, tlnode._paramnames)
                member._foreign_source = true
                has_source_foreign = true
                add_source_member(member)
            elseif tag == "Ast.TopLevelRecord"
                   or tag == "Ast.TopLevelUnion" then
                local member = types.ModuleMember(
                    modname, tlnode.name, tlnode._type, false)
                if tlnode.islocal then
                    add_source_member(member)
                else
                    members[#members + 1] = member
                end
            elseif tag == "Ast.TopLevelTypeAlias" then
                if tlnode.islocal then
                    source_type_members[tlnode.name] = tlnode._type
                else
                    type_members[tlnode.name] = tlnode._type
                end
            elseif tag == "Ast.TopLevelInterface" then
                type_members[tlnode.name] = tlnode._type
            end
        end
    end

    local modtype = types.Module(modname, members, type_members)
    modtype._source = true
    modtype.source_members = source_members
    modtype.source_type_members = source_type_members
    if has_source_foreign then
        local header_inputs = {}
        for index, input in ipairs(modast._c_header_dependencies or {}) do
            header_inputs[index] = {
                kind = input.kind,
                path = input.path,
                identity = input.identity,
            }
        end
        local macro_changes = {}
        for name in pairs(st.foreign_macro_changes or {}) do
            macro_changes[name] = true
        end
        local macro_definitions = {}
        local macro_environment = st:foreign_macro_environment() or {}
        for name, definition in pairs(macro_environment) do
            macro_definitions[name] = definition
        end
        local diagnostic_aliases = {}
        local seen_diagnostic_aliases = {}
        local function add_diagnostic_alias(physical_path, public_path)
            if type(physical_path) ~= "string" or
               type(public_path) ~= "string" then
                return
            end
            local key = physical_path .. "\0" .. public_path
            if seen_diagnostic_aliases[key] then return end
            seen_diagnostic_aliases[key] = true
            diagnostic_aliases[#diagnostic_aliases + 1] = {
                physical_path = physical_path,
                public_path = public_path,
            }
        end
        for _, node in ipairs(modast) do
            local public_header = node._tag == "Ast.TopLevelImport"
                and node._source_import
                and node._foreign_header_probe_identity or nil
            if type(public_header) == "string" then
                add_diagnostic_alias(node._foreign_header, public_header)
                local nested = node._source_c_context and
                    node._source_c_context.diagnostic_aliases or {}
                for _, alias in ipairs(nested) do
                    add_diagnostic_alias(
                        alias.physical_path, alias.public_path)
                end
            end
        end
        -- Source-only compiler metadata.  The callable descriptors already
        -- live in `source_members`; this context carries only the generated
        -- companion's transitive real-header inputs, diagnostic path aliases,
        -- and final macro environment plus changed-name delta.
        -- Binary metadata validation rejects this field.
        modtype._source_c_context = {
            header_inputs = header_inputs,
            diagnostic_aliases = diagnostic_aliases,
            macro_changes = macro_changes,
            macro_definitions = macro_definitions,
        }
    end
    return modtype
end

function reject_exported_c_ffi_type(modname, errors, loc, typ)
    local ctyp = types.first_non_exportable_type(typ)
    if ctyp then
        checker.typeerror(errors, loc,
            "cannot export C FFI type '%s' from Titan module '%s'; "
            .. "this non-portable header-defined type remains local to modules that import its header",
            types.tostring(ctyp), modname)
    end
end

function reject_exported_c_ffi_types(modname, modast, errors)
    for _, node in ipairs(modast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and not node.islocal then
                reject_exported_c_ffi_type(modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelFunc" and not node.islocal then
                reject_exported_c_ffi_type(modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelTypeAlias" and not node.islocal then
                reject_exported_c_ffi_type(modname, errors,
                    node.type.loc or node.loc, node._type)
            elseif tag == "Ast.TopLevelInterface" then
                reject_exported_c_ffi_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelRecord" and not node.islocal then
                for i, field in ipairs(node._type.fields) do
                    if not field.islocal then
                        local loc = node.fields[i] and node.fields[i].loc or node.loc
                        reject_exported_c_ffi_type(modname, errors, loc, field.type)
                    end
                end
            elseif tag == "Ast.TopLevelUnion" and not node.islocal then
                for _, variant in ipairs(node.variants) do
                    if variant._type and not variant._type.islocal
                       and variant._type.payload ~= false then
                        reject_exported_c_ffi_type(
                            modname, errors,
                            variant.payload.loc or variant.loc,
                            variant._type.payload)
                    end
                end
            elseif (tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic")
                   and not node.islocal then
                reject_exported_c_ffi_type(modname, errors, node.loc, node._type)
            end
        end
    end
end

function reject_exported_local_nominal_type(modname, errors, loc, typ)
    local local_nominal = first_local_nominal_type(typ)
    if local_nominal then
        local name = local_nominal.fqtn or local_nominal.name
        local owner = types.registry[name]
        local kind = owner and owner._tag == "Type.Union"
            and "union" or "record"
        checker.typeerror(errors, loc,
            "cannot export local %s type '%s' from Titan module '%s'",
            kind, name, modname)
    end
end

function reject_exported_local_nominal_types(modname, modast, errors)
    for _, node in ipairs(modast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and not node.islocal then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelFunc" and not node.islocal then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelTypeAlias" and not node.islocal then
                reject_exported_local_nominal_type(modname, errors,
                    node.type.loc or node.loc, node._type)
            elseif tag == "Ast.TopLevelInterface" then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelRecord" and not node.islocal then
                for i, field in ipairs(node._type.fields) do
                    if not field.islocal then
                        local loc = node.fields[i] and node.fields[i].loc or node.loc
                        reject_exported_local_nominal_type(
                            modname, errors, loc, field.type)
                    end
                end
            elseif tag == "Ast.TopLevelUnion" and not node.islocal then
                for _, variant in ipairs(node.variants) do
                    if variant._type and not variant._type.islocal
                       and variant._type.payload ~= false then
                        reject_exported_local_nominal_type(
                            modname, errors,
                            variant.payload.loc or variant.loc,
                            variant._type.payload)
                    end
                end
            elseif (tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic")
                   and not node.islocal then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            end
        end
    end
end

return core.checker
