local core = require "titan-compiler.checker.core"
local _ENV = core

-- Usage belongs to one consumer, never to the shared imported descriptors.
-- Import validation recovers complete public graphs; remembering those modules
-- here does not make their declarations dependencies of the current consumer.
function binary_remember_module(module)
    local st = active_check_state
    if st and module.name ~= st.modname then
        st.binary_modules[module.name] = module
    end
end

-- Follow checked syntax and explicit lowering plans, not arbitrary annotation
-- edges: an import's descriptor, a nominal registry entry, or a declaration
-- back-reference would otherwise turn every unused export into a requirement.
function binary_collect_usage(tree, st, registry)
    local usage = st.binary_usage
    local function module_usage(name)
        if not name or name == st.modname then return nil end
        local found = usage[name]
        if not found then
            found = {
                functions = {}, variables = {}, records = {},
                unions = {}, interfaces = {},
            }
            usage[name] = found
        end
        return found
    end

    local function nominal_usage(fqtn, module, name)
        local owner = registry[fqtn]
        if not owner then return nil end
        if not module then module, name = fqtn:match("^(.*)%.([^.]+)$") end
        local used = module_usage(module)
        if not used then return nil end
        if owner._tag == "Type.Interface" then
            used.interfaces[name] = true
            return nil
        end
        local category = owner._tag == "Type.Record" and used.records
            or owner._tag == "Type.Union" and used.unions
        if not category then return nil end
        local item = category[name]
        if not item then
            item = { functions = {}, methods = {} }
            category[name] = item
        end
        return item
    end

    local seen_types = {}
    local visit_type
    local function visit_list(list)
        for _, typ in ipairs(list or {}) do visit_type(typ) end
    end
    visit_type = function(typ)
        if type(typ) ~= "table" or seen_types[typ] then return end
        seen_types[typ] = true
        local tag = typ._tag
        if tag == "Type.Nominal" then
            nominal_usage(typ.fqtn)
            visit_list(typ.args)
        elseif tag == "Type.Record" or tag == "Type.Union"
                or tag == "Type.Interface" then
            nominal_usage(typ.name)
        elseif tag == "Type.GenericAlias" then
            nominal_usage(typ.target_owner_fqtn)
        elseif tag == "Type.FunctionScheme" then
            visit_type(typ.signature)
        elseif tag == "Type.Function" or tag == "Type.Method"
                or tag == "Type.StaticMethod" then
            visit_list(typ.params)
            visit_list(typ.rettypes)
            visit_type(typ.varargtype)
            visit_type(typ.flexrettype)
        elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable"
                or tag == "Type.Field" then
            visit_type(typ.type)
        elseif tag == "Type.Array" then
            visit_type(typ.elem)
        elseif tag == "Type.Map" then
            visit_type(typ.keys)
            visit_type(typ.values)
        elseif tag == "Type.Option" then
            visit_type(typ.base)
        elseif tag == "Type.Parameter" then
            visit_type(typ.erased_constraint)
        elseif tag == "Type.TypeParameter" then
            visit_type(typ.constraint)
        end
    end

    local function select(decl)
        if type(decl) ~= "table" then return end
        local tag = decl._tag
        if tag == "Type.ModuleVariable" then
            local used = module_usage(decl.modname)
            if used then used.variables[decl.name] = true end
        elseif tag == "Type.ModuleMember" then
            local typ = decl.type
            if typ._tag == "Type.Function" or typ._tag == "Type.FunctionScheme" then
                local used = module_usage(decl.modname)
                if used then used.functions[decl.name] = true end
            end
        elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
            local owner = nominal_usage(decl.fqtn)
            if owner then
                local members = tag == "Type.Method" and owner.methods
                    or owner.functions
                members[decl.name] = true
            end
        elseif tag == "Type.Field" or tag == "Type.Variant" then
            nominal_usage(decl.fqtn)
        elseif tag == "Checker.TypeMember" then
            local target = decl.type
            if target._tag == "Type.ModuleMember" then target = target.type end
            local fqtn = target._tag == "Type.Nominal" and target.fqtn
                or target._tag == "Type.GenericAlias" and target.target_owner_fqtn
                or (target._tag == "Type.Record" or target._tag == "Type.Union"
                    or target._tag == "Type.Interface") and target.name
            if fqtn then nominal_usage(fqtn, decl.modname, decl.name) end
            visit_type(target)
        end
        visit_type(decl)
    end

    local seen_plans, seen_nodes = {}, {}
    local visit_node
    local function visit_plan(plan)
        if type(plan) ~= "table" or seen_plans[plan] then return end
        seen_plans[plan] = true
        local tag = plan._tag
        if tag then
            if tag:match("^Type%.") then
                -- Concrete method mappings in Interface implementations are
                -- real native calls even without a written receiver:method.
                select(plan)
            elseif tag:match("^Ast%.") then
                visit_node(plan)
            end
            return
        end
        for _, child in pairs(plan) do visit_plan(child) end
    end

    visit_node = function(node)
        if type(node) ~= "table" or seen_nodes[node] or node._ignore then return end
        seen_nodes[node] = true
        local tag = node._tag
        if tag and not tag:match("^Ast%.") then return end
        if tag ~= "Ast.TopLevelImport" then
            visit_type(node._type)
            visit_list(node._types)
            visit_list(node._visible_types)
            select(node._decl)
            select(node._method)
            select(node._generic_declaration)
            select(node._callee_decl)
            if tag == "Ast.ExpInitList" and node._type
                    and node._type._tag == "Type.Nominal" then
                local owner = registry[node._type.fqtn]
                if owner and owner._tag == "Type.Record" then
                    local used = nominal_usage(owner.name)
                    if used then used.literal = true end
                end
            end
            local constructor = tag == "Ast.ExpCall"
                and node._nominal_constructor
            if constructor and constructor.kind == "record"
               and next(constructor.allocation_plans) ~= nil then
                -- Fused native arguments allocate inside the record itself;
                -- this call relies on generated raw construction just as a
                -- literal does, rather than only on `new`'s callable contract.
                local used = nominal_usage(constructor.owner.name)
                if used then used.literal = true end
            end
            if node._binary_closed_union then
                local used = nominal_usage(node._binary_closed_union)
                if used then used.closed = true end
            end
            for key, child in pairs(node) do
                if type(key) == "string" and key:sub(1, 1) == "_"
                        and (key:match("adjustment$")
                            or key:match("conversion$")
                            or key:match("adapter$")) then
                    visit_plan(child)
                end
            end
        end
        for key, child in pairs(node) do
            if type(key) ~= "string"
                    or (key:sub(1, 1) ~= "_" and key ~= "loc") then
                if type(child) == "table" then visit_node(child) end
            end
        end
    end
    visit_node(tree)
end

return core.checker
