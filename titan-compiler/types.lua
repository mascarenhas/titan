local typedecl = require 'titan-compiler.typedecl'
local util = require 'titan-compiler.util'

local types = typedecl("Type", {
    Types = {
        Invalid     = {},
        Nil         = {},
        Void        = {},
        Boolean     = {},
        Integer     = {},
        Float       = {},
        String      = {},
        Value       = {},
        Function    = {"params", "rettypes", "vararg", "varargtype", "flexrettype"},
        Array       = {"elem", "isconst"},
        Map         = {"keys", "values"},
        GenericScope = {"modname", "owner_fqtn", "callable_name", "role", "declaration_kind"},
        TypeParameter = {"name", "constraint"},
        Parameter   = {"scope", "index", "diagnostic_name", "erased_constraint"},
        FunctionScheme = {"scope", "typeparams", "signature"},
        GenericAlias = {"module", "name", "locality", "target_owner_fqtn", "target_alias_fqtn", "target_scope", "typeparams"},
        Record      = {"name", "fields", "functions", "methods", "nfields", "scope", "typeparams"},
        Union       = {"name", "variants", "functions", "methods", "nvariants", "scope", "typeparams"},
        Interface   = {"name", "fields", "methods", "scope", "typeparams"},
        Variant     = {"fqtn", "name", "payload", "index"},
        Nominal     = {"fqtn", "args"},
        Field       = {"fqtn", "name", "type", "index", "isconst"},
        Method      = {"fqtn", "name", "params", "rettypes", "varargtype", "flexrettype", "paramnames", "scope", "typeparams"},
        ModuleMember = {"modname", "name", "type", "paramnames"},
        ModuleVariable = {"modname", "name", "type", "isconst"},
        StaticMethod = {"fqtn", "name", "params", "rettypes", "varargtype", "flexrettype", "paramnames", "scope", "typeparams"},
        Option       = {"base"},
        CVoid        = {},
        CNamed         = { "tagname" },
        CInteger     = {"spelling", "signed", "rank", "bits"},
        CFloat       = {"spelling"},
        CPointer     = {"pointee", "quals"},
        CArray       = {"elem", "len", "quals"},
        CFunction    = {"params", "ret", "vararg", "abi"},
        CStruct      = {"cname", "tagname", "typedef", "fields", "complete", "has_fam"},
        CUnion       = {"cname", "tagname", "typedef", "fields", "complete"},
        CField       = {"owner", "name", "type", "bitfield", "flexible_array"},
        CTypedef     = {"name", "target", "quals"},
        COwned       = {"pointee", "count"},
        CModule      = {"name", "members", "type_members"}
    }
})

-- Mutability is an ABI-visible axis of an Array, record field, and module
-- variable. Arrays admit exactly false, true, or "maybe"; field and variable
-- qualifiers require booleans. Constructors reject absent or hostile metadata
-- instead of silently normalizing it to mutable.
local raw_Array = types.Array
function types.Array(elem, isconst)
    if type(isconst) ~= "boolean" and isconst ~= "maybe" then
        error("Array const qualifier must be a boolean or 'maybe'", 2)
    end
    return raw_Array(elem, isconst)
end

local raw_Field = types.Field
function types.Field(fqtn, name, typ, index, isconst)
    if type(isconst) ~= "boolean" then
        error("Field const qualifier must be a boolean", 2)
    end
    return raw_Field(fqtn, name, typ, index, isconst)
end

local raw_ModuleVariable = types.ModuleVariable
function types.ModuleVariable(modname, name, typ, isconst)
    if type(isconst) ~= "boolean" then
        error("ModuleVariable const qualifier must be a boolean", 2)
    end
    return raw_ModuleVariable(modname, name, typ, isconst)
end

-- Serialized Function constructors retain their third positional field. It is
-- a reserved false sentinel, not a callable-shape property: C
-- variadicity belongs exclusively to Type.CFunction.vararg, while Titan input
-- tails use Type.Function.varargtype. Removing the reserved slot waits for a
-- future ABI boundary so provider metadata keeps the same constructor arity.

-- Array qualification belongs to the element type in C declarator syntax, but
-- it must remain attached to the array shape until decay. Keep the constructor
-- source-compatible for existing unqualified callers while making the
-- qualifier list explicit in the structural type.
local raw_CArray = types.CArray
function types.CArray(elem, len, quals)
    return raw_CArray(elem, len, quals or {})
end

local raw_CTypedef = types.CTypedef
function types.CTypedef(name, target, quals)
    return raw_CTypedef(name, target, quals or {})
end

-- Keep the pre-generics constructors source-compatible while making the
-- generic surface metadata explicit. An absent scope means that the
-- descriptor is ordinary and its binder list is therefore empty.
local raw_Nominal = types.Nominal
function types.Nominal(fqtn, args)
    if args == nil then args = {} end
    return raw_Nominal(fqtn, args)
end

local raw_Record = types.Record
function types.Record(name, fields, functions, methods, nfields, scope, typeparams)
    if scope == nil then scope = false end
    if typeparams == nil then typeparams = {} end
    return raw_Record(name, fields, functions, methods, nfields,
        scope, typeparams)
end

local raw_Method = types.Method
function types.Method(fqtn, name, params, rettypes, varargtype,
                      flexrettype, paramnames, scope, typeparams)
    if scope == nil then scope = false end
    if typeparams == nil then typeparams = {} end
    return raw_Method(fqtn, name, params, rettypes, varargtype,
        flexrettype, paramnames, scope, typeparams)
end

local raw_StaticMethod = types.StaticMethod
function types.StaticMethod(fqtn, name, params, rettypes, varargtype,
                            flexrettype, paramnames, scope, typeparams)
    if scope == nil then scope = false end
    if typeparams == nil then typeparams = {} end
    return raw_StaticMethod(fqtn, name, params, rettypes, varargtype,
        flexrettype, paramnames, scope, typeparams)
end

-- A union's variants retain source order for their stable integer tags while
-- also supporting namespace lookup by name. Keep both views on the same
-- descriptor objects, like Type.Module's member list/map.
local raw_Union = types.Union
function types.Union(name, variants, functions, methods, nvariants,
                     scope, typeparams)
    if scope == nil then scope = false end
    if typeparams == nil then typeparams = {} end
    for _, variant in ipairs(variants) do
        variants[variant.name] = variant
    end
    return raw_Union(name, variants, functions, methods, nvariants,
        scope, typeparams)
end

-- An interface's fields and methods retain independent declaration order for
-- their stable wrapper and payload slots while also supporting namespace
-- lookup by name. Unlike the legacy union constructor above, serialized
-- Interface input is deliberately only a pair of dense numeric lists:
-- accepting preexisting keyed decorations would let hostile metadata silently
-- replace either canonical list-to-map projection.
local raw_Interface = types.Interface

local function interface_constructor_error(message)
    error("invalid Interface members: " .. message, 3)
end

local function validate_interface_member_input(name, list, kind, names)
    if type(list) ~= "table" then
        interface_constructor_error(
            kind .. " must be a dense numeric list")
    end

    local count = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            interface_constructor_error(
                kind .. " input must contain numeric list keys only")
        end
        count = count + 1
    end

    local wanted_tag = kind == "fields" and "Type.Field" or "Type.Method"
    for index = 1, count do
        local member = list[index]
        if member == nil then
            interface_constructor_error(kind .. " input list must be dense")
        elseif type(member) ~= "table" or member._tag ~= wanted_tag then
            interface_constructor_error(
                kind .. " entry " .. index .. " is not a " ..
                (kind == "fields" and "field" or "method") ..
                " descriptor")
        elseif member.fqtn ~= name then
            interface_constructor_error(
                kind:sub(1, -2) .. " '" .. tostring(member.name) ..
                "' belongs to a different owner")
        elseif type(member.name) ~= "string" then
            interface_constructor_error(
                kind .. " entry " .. index .. " has no name")
        elseif names[member.name] then
            interface_constructor_error(
                "duplicate or cross-kind member '" .. member.name .. "'")
        elseif kind == "fields"
           and (member.index ~= index - 1 or member.isconst ~= true) then
            interface_constructor_error(
                "field '" .. member.name ..
                "' has a noncanonical index or const qualifier")
        end
        names[member.name] = true
    end
    return count
end

local function validate_interface_constructor_input(name, fields, methods)
    if type(name) ~= "string" then
        interface_constructor_error("owner name must be a string")
    end
    local names = {}
    local nfields = validate_interface_member_input(
        name, fields, "fields", names)
    local nmethods = validate_interface_member_input(
        name, methods, "methods", names)
    if nfields + nmethods == 0 then
        interface_constructor_error("at least one member is required")
    end
end

function types.Interface(name, fields, methods, scope, typeparams)
    if scope == nil then scope = false end
    if typeparams == nil then typeparams = {} end
    validate_interface_constructor_input(name, fields, methods)
    for _, field in ipairs(fields) do
        fields[field.name] = field
    end
    for _, method in ipairs(methods) do
        methods[method.name] = method
    end
    return raw_Interface(name, fields, methods, scope, typeparams)
end

-- Validate the canonical hybrid list/map after construction. This is kept
-- public so the closed compiled-interface validator can reuse exactly the
-- same identity and density checks instead of independently reconstructing
-- the in-memory decoration.
function types.validate_interface_descriptor(interface)
    if type(interface) ~= "table"
       or interface._tag ~= "Type.Interface" then
        return nil, "descriptor is not an interface"
    elseif type(interface.name) ~= "string" then
        return nil, "interface owner name is not a string"
    elseif type(interface.fields) ~= "table" then
        return nil, "interface fields are not a table"
    elseif type(interface.methods) ~= "table" then
        return nil, "interface methods are not a table"
    end

    local member_names = {}
    local function validate_projection(list, kind)
        local singular = kind:sub(1, -2)
        local numeric_count, numeric_max = 0, 0
        for key in pairs(list) do
            if type(key) == "number" then
                if key < 1 or key % 1 ~= 0 then
                    return nil, "interface " .. singular ..
                        " list has a non-list index"
                end
                numeric_count = numeric_count + 1
                numeric_max = math.max(numeric_max, key)
            elseif type(key) ~= "string" then
                return nil, "interface " .. kind ..
                    " have an invalid derived key"
            end
        end
        if numeric_count ~= numeric_max then
            return nil, "interface " .. singular .. " list is sparse"
        end

        local by_name = {}
        local wanted_tag = kind == "fields" and "Type.Field" or "Type.Method"
        for index = 1, numeric_count do
            local member = list[index]
            if type(member) ~= "table" or member._tag ~= wanted_tag then
                return nil, "interface " .. singular .. " " ..
                    index .. " is not a " .. singular ..
                    " descriptor"
            elseif member.fqtn ~= interface.name then
                return nil, "interface " .. singular .. " '" ..
                    tostring(member.name) .. "' belongs to a different owner"
            elseif type(member.name) ~= "string" then
                return nil, "interface " .. singular .. " " ..
                    index .. " has no name"
            elseif by_name[member.name] or member_names[member.name] then
                return nil, "interface member '" .. member.name ..
                    "' is duplicated"
            elseif kind == "fields"
               and (member.index ~= index - 1
                    or member.isconst ~= true
                    or member.islocal) then
                return nil, "interface field '" .. member.name ..
                    "' has a noncanonical index, const qualifier, or locality"
            end
            by_name[member.name] = member
            member_names[member.name] = member
        end

        for name, member in pairs(by_name) do
            if list[name] ~= member then
                return nil, "interface " .. singular ..
                    " key '" .. name ..
                    "' does not reference its ordered descriptor"
            end
        end
        for key in pairs(list) do
            if type(key) == "string" and not by_name[key] then
                return nil, "interface " .. kind ..
                    " have extra derived key '" .. key .. "'"
            end
        end
        return numeric_count
    end

    local nfields, field_error = validate_projection(
        interface.fields, "fields")
    if nfields == nil then return nil, field_error end
    local nmethods, method_error = validate_projection(
        interface.methods, "methods")
    if nmethods == nil then return nil, method_error end
    if nfields + nmethods == 0 then
        return nil, "interface has no members"
    end
    return interface
end

-- Project a declaration method to the callable value shape used by bound
-- methods and Interface implementation matching. Parameter names remain on
-- the declaration descriptor for named calls, but are not part of callable
-- identity or adjustment.
function types.method_function_type(method)
    assert(type(method) == "table"
        and method._tag == "Type.Method",
        "expected a method descriptor")
    return types.Function(
        method.params,
        method.rettypes,
        false,
        method.varargtype,
        method.flexrettype)
end

-- Registry for nominal types
-- Keys are canonical FQTNs (fully qualified type names)
-- Values are types
types.registry = {}

local function is_c_tag(tag)
    return type(tag) == "string" and tag:match("^Type%.C") ~= nil
        and tag ~= "Type.CModule"
end

local portable_c_integer_specs = {
    ["_Bool"] = { signed = false, rank = 0 },
    char = { rank = 1 },
    ["signed char"] = { signed = true, rank = 1 },
    ["unsigned char"] = { signed = false, rank = 1 },
    short = { signed = true, rank = 2 },
    ["unsigned short"] = { signed = false, rank = 2 },
    int = { signed = true, rank = 3 },
    ["unsigned int"] = { signed = false, rank = 3 },
    long = { signed = true, rank = 4 },
    ["unsigned long"] = { signed = false, rank = 4 },
    ["long long"] = { signed = true, rank = 5 },
    ["unsigned long long"] = { signed = false, rank = 5 },
}

local portable_c_float_spellings = {
    float = true,
    double = true,
    ["long double"] = true,
}

local function dense_plain_list_length(list)
    if type(list) ~= "table" then return nil end
    local count, maximum = 0, 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil
        end
        count = count + 1
        maximum = math.max(maximum, key)
    end
    if count ~= maximum then return nil end
    return maximum
end

local function dense_const_qualifiers(quals)
    local count = dense_plain_list_length(quals)
    if not count or count > 1 then return false end
    return count == 0 or quals[1] == "const"
end

function types.is_portable_c_primitive(t)
    if type(t) ~= "table" then return false end
    if t._tag == "Type.CVoid" then return true end
    if t._tag == "Type.CFloat" then
        return portable_c_float_spellings[t.spelling] == true
    end
    if t._tag ~= "Type.CInteger" or t._c_enum_identity ~= nil then
        return false
    end
    local spec = portable_c_integer_specs[t.spelling]
    if not spec or type(t.signed) ~= "boolean"
       or type(t.rank) ~= "number" or math.type(t.rank) ~= "integer"
       or type(t.bits) ~= "number" or math.type(t.bits) ~= "integer"
       or t.bits <= 0 or t.rank ~= spec.rank then
        return false
    end
    if spec.signed ~= nil and t.signed ~= spec.signed then return false end
    return true
end

-- Validate the complete closed portable-C descriptor graph. A wrapper is not
-- portable merely because its own tag and flags are familiar: every child
-- must itself be one of the C categories valid in that declarator position.
-- This prevents hostile or hand-built graphs such as `CPointer(Integer())`
-- from being serialized into code paths that require a C declarator.
function types.is_portable_c_type_graph(root)
    local active = {}
    local function visit(t, position)
        if type(t) ~= "table" or active[t] then return false end
        active[t] = true
        local tag = t._tag
        local ok = false
        if tag == "Type.CVoid" then
            ok = position == "root" or position == "pointee"
                or position == "return"
        elseif tag == "Type.CInteger" then
            ok = types.is_portable_c_primitive(t)
                and t._c_enum_owner == nil
                and t._c_declaration_spelling == nil
                and t._c_enum_enumerator == nil
                and t._c_enum_probe_spelling == nil
                and t._c_enum_unspellable == nil
        elseif tag == "Type.CFloat" then
            ok = types.is_portable_c_primitive(t)
        elseif tag == "Type.CPointer" then
            local pointee_tag = type(t.pointee) == "table"
                and t.pointee._tag
            ok = dense_const_qualifiers(t.quals)
                and (pointee_tag == "Type.CVoid"
                     or pointee_tag == "Type.CInteger"
                     or pointee_tag == "Type.CFloat"
                     or pointee_tag == "Type.CPointer"
                     or pointee_tag == "Type.CFunction"
                     or types.is_c_lua_state(t.pointee))
                and visit(t.pointee, "pointee")
        elseif tag == "Type.CFunction" then
            ok = t._paramstyle == nil
                and dense_plain_list_length(t.params) ~= nil
                and type(t.ret) == "table"
                and t.vararg == false and t.abi == false
            if ok then
                for _, param in ipairs(t.params) do
                    local param_tag = type(param) == "table" and param._tag
                    if param_tag ~= "Type.CInteger"
                       and param_tag ~= "Type.CFloat"
                       and param_tag ~= "Type.CPointer"
                       or not visit(param, "parameter") then
                        ok = false
                        break
                    end
                end
            end
            if ok then
                local ret_tag = t.ret._tag
                ok = (ret_tag == "Type.CVoid"
                      or ret_tag == "Type.CInteger"
                      or ret_tag == "Type.CFloat"
                      or ret_tag == "Type.CPointer")
                    and visit(t.ret, "return")
            end
        elseif tag == "Type.COwned" then
            local pointee_tag = type(t.pointee) == "table"
                and t.pointee._tag
            ok = type(t.count) == "boolean"
                and (pointee_tag == "Type.CInteger"
                     or pointee_tag == "Type.CFloat"
                     or pointee_tag == "Type.CPointer")
                and visit(t.pointee, "owned")
        elseif tag == "Type.CStruct" then
            ok = types.is_c_lua_state(t) and position == "pointee"
        end
        active[t] = nil
        return ok
    end
    return visit(root, "root")
end

function types.resolve_c_typedef(t)
    local seen = {}
    while t and t._tag == "Type.CTypedef" do
        if seen[t] then
            return t
        end
        seen[t] = true
        t = t.target
    end
    return t
end

-- Qualifiers written into a typedef declaration are semantically part of
-- every use of that name even though C declarators should continue to render
-- the typedef spelling itself. Array qualifiers likewise qualify the element
-- object reached by decay. Return only qualification of this object level:
-- CPointer.quals belongs to its pointee and is handled by the pointer layer.
function types.c_type_qualifiers(t)
    local out, seen_quals, seen_types = {}, {}, {}
    while t and t._tag == "Type.CTypedef" and not seen_types[t] do
        seen_types[t] = true
        for _, qual in ipairs(t.quals or {}) do
            if not seen_quals[qual] then
                seen_quals[qual] = true
                table.insert(out, qual)
            end
        end
        t = t.target
    end
    if t and t._tag == "Type.CArray" then
        for _, qual in ipairs(t.quals or {}) do
            if not seen_quals[qual] then
                seen_quals[qual] = true
                table.insert(out, qual)
            end
        end
    end
    return out
end

function types.c_pointer_pointee_qualifiers(t)
    t = types.resolve_c_typedef(t)
    if not t or t._tag ~= "Type.CPointer" then return {} end
    local out, seen = {}, {}
    for _, quals in ipairs({
            t.quals or {}, types.c_type_qualifiers(t.pointee)}) do
        for _, qual in ipairs(quals) do
            if not seen[qual] then
                seen[qual] = true
                table.insert(out, qual)
            end
        end
    end
    return out
end

function types.c_pointer_has_qual(t, wanted)
    for _, qual in ipairs(types.c_pointer_pointee_qualifiers(t)) do
        if qual == wanted then return true end
    end
    return false
end

local function find_c_type(
        t, descend_function_values, skip_portable)
    local function visit_type(typ, seen)
        if type(typ) ~= "table" then
            return nil
        end
        if seen[typ] then
            return nil
        end
        seen[typ] = true

        local tag = typ._tag
        if skip_portable and tag == "Type.CModule" then
            return typ
        elseif is_c_tag(tag) then
            if not skip_portable
               or not types.is_portable_c_type_graph(typ) then
                return typ
            end
            return nil
        end

        if tag == "Type.TypeParameter" then
            return typ.constraint ~= false
                and visit_type(typ.constraint, seen) or nil
        elseif tag == "Type.Parameter" then
            return typ.erased_constraint ~= false
                and visit_type(typ.erased_constraint, seen) or nil
        elseif tag == "Type.FunctionScheme" then
            for _, typeparam in ipairs(typ.typeparams) do
                local ctyp = visit_type(typeparam, seen)
                if ctyp then return ctyp end
            end
            return visit_type(typ.signature, seen)
        elseif tag == "Type.GenericAlias" then
            for _, typeparam in ipairs(typ.typeparams) do
                local ctyp = visit_type(typeparam, seen)
                if ctyp then return ctyp end
            end
        elseif tag == "Type.Nominal" then
            for _, argument in ipairs(typ.args or {}) do
                local ctyp = visit_type(argument, seen)
                if ctyp then return ctyp end
            end
        elseif tag == "Type.Array" then
            return visit_type(typ.elem, seen)
        elseif tag == "Type.Map" then
            return visit_type(typ.keys, seen) or
                   visit_type(typ.values, seen)
        elseif tag == "Type.Function" then
            if not descend_function_values then
                return nil
            end
            for _, param in ipairs(typ.params) do
                local ctyp = visit_type(param, seen)
                if ctyp then return ctyp end
            end
            for _, ret in ipairs(typ.rettypes) do
                local ctyp = visit_type(ret, seen)
                if ctyp then return ctyp end
            end
            return visit_type(typ.varargtype, seen) or
                   visit_type(typ.flexrettype, seen)
        elseif tag == "Type.Option" then
            return visit_type(typ.base, seen)
        elseif tag == "Type.Field" then
            if typ.islocal then return nil end
            return visit_type(typ.type, seen)
        elseif tag == "Type.Variant" then
            if typ.islocal or typ.payload == false then return nil end
            return visit_type(typ.payload, seen)
        elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
            if typ.islocal then return nil end
            for _, typeparam in ipairs(typ.typeparams or {}) do
                local ctyp = visit_type(typeparam, seen)
                if ctyp then return ctyp end
            end
            for _, param in ipairs(typ.params) do
                local ctyp = visit_type(param, seen)
                if ctyp then return ctyp end
            end
            for _, ret in ipairs(typ.rettypes) do
                local ctyp = visit_type(ret, seen)
                if ctyp then return ctyp end
            end
            return visit_type(typ.varargtype, seen) or
                   visit_type(typ.flexrettype, seen)
        elseif tag == "Type.Record" then
            for _, typeparam in ipairs(typ.typeparams or {}) do
                local ctyp = visit_type(typeparam, seen)
                if ctyp then return ctyp end
            end
            for _, field in ipairs(typ.fields) do
                local ctyp = not field.islocal and visit_type(field, seen)
                if ctyp then return ctyp end
            end
            for _, func in pairs(typ.functions) do
                local ctyp = not func.islocal and visit_type(func, seen)
                if ctyp then return ctyp end
            end
            for _, method in pairs(typ.methods) do
                local ctyp = not method.islocal and visit_type(method, seen)
                if ctyp then return ctyp end
            end
        elseif tag == "Type.Interface" then
            for _, typeparam in ipairs(typ.typeparams or {}) do
                local ctyp = visit_type(typeparam, seen)
                if ctyp then return ctyp end
            end
            -- Declaration order is ABI-significant for Interfaces. Traverse
            -- only the canonical dense lists, not their duplicate name maps.
            for _, field in ipairs(typ.fields) do
                local ctyp = visit_type(field, seen)
                if ctyp then return ctyp end
            end
            for _, method in ipairs(typ.methods) do
                local ctyp = visit_type(method, seen)
                if ctyp then return ctyp end
            end
        elseif tag == "Type.Union" then
            for _, typeparam in ipairs(typ.typeparams or {}) do
                local ctyp = visit_type(typeparam, seen)
                if ctyp then return ctyp end
            end
            for _, variant in ipairs(typ.variants) do
                local ctyp = not variant.islocal
                    and visit_type(variant, seen)
                if ctyp then return ctyp end
            end
            for _, func in pairs(typ.functions) do
                local ctyp = not func.islocal and visit_type(func, seen)
                if ctyp then return ctyp end
            end
            for _, method in pairs(typ.methods) do
                local ctyp = not method.islocal and visit_type(method, seen)
                if ctyp then return ctyp end
            end
        elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable" then
            return visit_type(typ.type, seen)
        elseif tag == "Type.Module" then
            for _, member in ipairs(typ.members) do
                local ctyp = visit_type(member, seen)
                if ctyp then return ctyp end
            end
            for _, member in pairs(typ.type_members or {}) do
                local ctyp = visit_type(member, seen)
                if ctyp then return ctyp end
            end
        elseif tag == "Type.CPointer" then
            return visit_type(typ.pointee, seen)
        elseif tag == "Type.CArray" then
            return visit_type(typ.elem, seen)
        elseif tag == "Type.CFunction" then
            for _, param in ipairs(typ.params) do
                local ctyp = visit_type(param, seen)
                if ctyp then return ctyp end
            end
            return visit_type(typ.ret, seen)
        elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
            for _, field in ipairs(typ.fields or {}) do
                local ctyp = visit_type(field, seen)
                if ctyp then return ctyp end
            end
        elseif tag == "Type.CField" then
            return visit_type(typ.type, seen)
        elseif tag == "Type.CTypedef" then
            return visit_type(typ.target, seen)
        elseif tag == "Type.COwned" then
            return visit_type(typ.pointee, seen)
        end
        return nil
    end

    return visit_type(t, {})
end

function types.first_c_type(t)
    return find_c_type(t, false, false)
end

function types.first_non_exportable_type(t)
    return find_c_type(t, true, true)
end

function types.is_c(t)
    return types.first_c_type(t) ~= nil
end

-- `is_c` follows C provenance through ordinary storage shapes such as
-- Option/Array/Map, but deliberately stops at boxed callable signatures.
-- Full interface/export validation uses `first_non_exportable_type`;
-- representation and
-- expression lowering instead need `is_direct_c`, which asks whether the value
-- itself has a direct C representation. An Option/Array/Map/function
-- containing an owned C value remains an ordinary boxed Titan value.
function types.is_direct_c(t)
    t = types.resolve_c_typedef(t)
    return t and is_c_tag(t._tag) or false
end

function types.is_c_lua_state(t)
    if not t then
        return false
    end
    local rt = types.resolve_c_typedef(t)
    return rt and rt._tag == "Type.CStruct"
        and (rt.tagname == "lua_State" or rt.cname == "lua_State")
end

function types.is_c_tvalue(t)
    if not t then
        return false
    end
    local rt = types.resolve_c_typedef(t)
    return rt and rt._tag == "Type.CStruct" and rt.tagname == "TValue"
end

-- A pointer to Lua's internal Udata object is not an ordinary C object
-- pointer when wrapped in a TValue: it already denotes a full userdata GC
-- object. Recognize typedef and tag-only spellings alike.
function types.is_c_udata_pointer(t)
    if not t then
        return false
    end
    local rt = types.resolve_c_typedef(t)
    if not (rt and rt._tag == "Type.CPointer") then
        return false
    end
    local pointee = types.resolve_c_typedef(rt.pointee)
    return pointee and pointee._tag == "Type.CStruct"
        and (pointee.tagname == "Udata" or pointee.cname == "Udata")
end

-- Automatic C aggregate storage is not represented in Lua's traced object
-- graph. Keep this predicate structural: a pointer normally contributes only
-- its pointer bits (and therefore does not recurse into its pointee), while the
-- compiler's special Udata pointer representation is itself GC-bearing.
-- Struct/union fields and array elements are embedded by value, so they do
-- recurse. The returned second value is the first offending embedded type and
-- is useful for a precise checker diagnostic.
function types.c_automatic_gc_bearing(t, seen)
    if not t then return false end
    t = types.resolve_c_typedef(t)
    if not t then return false end
    if types.is_c_tvalue(t) or types.is_c_udata_pointer(t)
       or t._tag == "Type.COwned" then
        return true, t
    end

    seen = seen or {}
    if seen[t] then return false end
    seen[t] = true

    if t._tag == "Type.CArray" then
        return types.c_automatic_gc_bearing(t.elem, seen)
    elseif t._tag == "Type.CStruct" or t._tag == "Type.CUnion" then
        for _, field in ipairs(t.fields or {}) do
            local bearing, offender =
                types.c_automatic_gc_bearing(field.type, seen)
            if bearing then return true, offender end
        end
    end
    return false
end

function types.is_c_aggregate(t)
    t = types.resolve_c_typedef(t)
    return t and (t._tag == "Type.CStruct"
        or t._tag == "Type.CUnion"
        or t._tag == "Type.CArray") or false
end

function types.is_c_array(t)
    t = types.resolve_c_typedef(t)
    return t and t._tag == "Type.CArray" or false
end

function types.contains_c_ffi_type(t)
    return find_c_type(t, true, false) ~= nil
end


function types.contains_c_numeric_type(root)
    local seen = {}
    local function visit(value)
        if type(value) ~= "table" or seen[value] then return false end
        seen[value] = true
        if value._tag == "Type.CInteger" or value._tag == "Type.CFloat" then
            return true
        end
        for key, child in pairs(value) do
            if key ~= "_c_numeric" and key ~= "_c_numeric_carriers"
               and visit(child) then
                return true
            end
        end
        return false
    end
    return visit(root)
end

-- Portable C scalar metadata deliberately serializes only its structural
-- target description. Reattach the selected target profile's lowering traits
-- after a compiled interface is recovered, rejecting metadata that disagrees
-- with that profile before it can reach numeric code generation.
function types.normalize_portable_c_numeric_types(root, profile)
    if type(profile) ~= "table" then
        return nil, "target C profile is unavailable"
    end
    local seen = {}
    local function visit(value)
        if type(value) ~= "table" or seen[value] then return true end
        seen[value] = true
        if value._tag == "Type.CInteger"
           and portable_c_integer_specs[value.spelling]
           and value._c_enum_identity == nil then
            local entry = profile.integers and profile.integers[value.spelling]
            local canonical = entry and entry.type
            if not canonical
               or value.signed ~= canonical.signed
               or value.rank ~= canonical.rank
               or value.bits ~= canonical.bits then
                return nil, "serialized C integer type '" ..
                    tostring(value.spelling) ..
                    "' disagrees with the selected target profile"
            end
            value._c_numeric = canonical._c_numeric
            value._c_numeric_carriers = canonical._c_numeric_carriers
            return true
        elseif value._tag == "Type.CFloat"
           and portable_c_float_spellings[value.spelling] then
            local entry = profile.floats and profile.floats[value.spelling]
            local canonical = entry and entry.type
            if not canonical then
                return nil, "serialized C floating type '" ..
                    tostring(value.spelling) ..
                    "' is unavailable in the selected target profile"
            end
            value._c_numeric = canonical._c_numeric
            value._c_numeric_carriers = canonical._c_numeric_carriers
            return true
        end
        for key, child in pairs(value) do
            if key ~= "_c_numeric" and key ~= "_c_numeric_carriers" then
                local ok, err = visit(child)
                if not ok then return nil, err end
            end
        end
        return true
    end
    return visit(root)
end

function types.is_basic(t)
    local tag = t._tag
    return tag == "Type.Nil" or
           tag == "Type.Boolean" or
           tag == "Type.Integer" or
           tag == "Type.Float" or
           tag == "Type.String" or
           tag == "Type.Value"
end

function types.is_gc(t)
    local tag = t._tag
    return types.is_c_tvalue(t) or
           types.is_c_udata_pointer(t) or
           tag == "Type.String" or
           tag == "Type.Value" or
           tag == "Type.Parameter" or
           tag == "Type.Function" or
           tag == "Type.Array" or
           tag == "Type.Map" or
           tag == "Type.Record" or
           tag == "Type.Nominal" or
           tag == "Type.COwned" or
           (tag == "Type.Option" and types.is_gc(t.base))
end

-- XXX this should be inside typedecl call
-- constructors shouldn't do more than initalize members
-- XXX this should not be a type. This makes it possible to
-- construct nonsense things like a function type that returns
-- a module type
function types.Module(modname, members, type_members)
    for _, member in ipairs(members) do
        members[member.name] = member
    end
    type_members = type_members or {}
    return { _tag = "Type.Module", name = modname,
        prefix = modname:gsub("[%-.]", "_") .. "_",
        file = modname:gsub("[.]", "/") .. ".so",
        members = members,
        type_members = type_members }
end

-- Enumerate the ABI-visible prefix of a Titan module userdata. Producers and
-- consumers must derive the same order without relying on source ASTs: public
-- variables, public top-level function closures, then public nominal static
-- closures by module-member and bytewise static-name order. Keeping this in
-- the type layer also lets the checker decorate a transitively recovered
-- nominal owner's statics before code generation needs a first-class closure
-- through a re-exported type alias.
function types.public_module_prefix_layout(modtype)
    assert(modtype and modtype._tag == "Type.Module")
    local layout = {}
    for _, member in ipairs(modtype.members or {}) do
        if member._tag == "Type.ModuleVariable" then
            layout[#layout + 1] = {
                kind = "variable",
                value = member,
                key = "variable:" .. member.name,
            }
        end
    end
    for _, member in ipairs(modtype.members or {}) do
        if member._tag == "Type.ModuleMember"
           and (member.type._tag == "Type.Function"
                or member.type._tag == "Type.FunctionScheme") then
            layout[#layout + 1] = {
                kind = "function",
                value = member,
                key = "function:" .. member.name,
            }
        end
    end
    for _, member in ipairs(modtype.members or {}) do
        local owner = member._tag == "Type.ModuleMember" and member.type
        if owner and (owner._tag == "Type.Record"
                      or owner._tag == "Type.Union") then
            local names = {}
            for name, static in pairs(owner.functions or {}) do
                if not static.islocal then
                    names[#names + 1] = name
                end
            end
            table.sort(names, util.bytewise_less)
            for _, name in ipairs(names) do
                local static = owner.functions[name]
                layout[#layout + 1] = {
                    kind = "static",
                    value = static,
                    owner = owner,
                    key = "static:" .. static.fqtn .. "." .. static.name,
                }
            end
        end
    end
    return layout
end

-- A source interface carries a second, non-serialized member view. Its
-- first-class local functions and local nominal statics need canonical closure
-- slots just like public callables, but those slots must remain outside the
-- importer-reconstructible ABI prefix. They occupy a deterministic source-only
-- prefix after the unconditional mutable/const Array-metatable slots and the
-- source-provider identity. Binary interfaces never have `source_members`, so
-- they expose no such layout.
function types.source_module_prefix_layout(modtype)
    assert(modtype and modtype._tag == "Type.Module")
    local layout = {}
    if not modtype._source then return layout end

    for _, member in ipairs(modtype.source_members or {}) do
        if member._tag == "Type.ModuleVariable" then
            layout[#layout + 1] = {
                kind = "variable",
                value = member,
                key = "variable:" .. member.name,
            }
        end
    end

    for _, member in ipairs(modtype.source_members or {}) do
        if member._tag == "Type.ModuleMember"
           and (member.type._tag == "Type.Function"
                or member.type._tag == "Type.FunctionScheme") then
            layout[#layout + 1] = {
                kind = "function",
                value = member,
                key = "function:" .. member.name,
            }
        end
    end

    local nominal_members = {}
    for _, member in ipairs(modtype.members or {}) do
        nominal_members[#nominal_members + 1] = member
    end
    for _, member in ipairs(modtype.source_members or {}) do
        nominal_members[#nominal_members + 1] = member
    end
    for _, member in ipairs(nominal_members) do
        local owner = member._tag == "Type.ModuleMember" and member.type
        if owner and (owner._tag == "Type.Record"
                      or owner._tag == "Type.Union") then
            local names = {}
            for name, static in pairs(owner.functions or {}) do
                if static.islocal then names[#names + 1] = name end
            end
            table.sort(names, util.bytewise_less)
            for _, name in ipairs(names) do
                local static = owner.functions[name]
                layout[#layout + 1] = {
                    kind = "static",
                    value = static,
                    owner = owner,
                    key = "static:" .. static.fqtn .. "." .. static.name,
                }
            end
        end
    end
    return layout
end

function types.module_member(modtype, name, include_source)
    return modtype.members[name]
        or (include_source and modtype.source_members
            and modtype.source_members[name])
end

-- The second result identifies the namespace view which supplied the member.
-- Transparent aliases can resolve to a type with no declaration-locality
-- field, so callers must not infer source visibility from the target itself.
function types.module_type_member(modtype, name, include_source)
    local member = modtype.type_members and modtype.type_members[name]
    if member then return member, false end
    member = include_source and modtype.source_type_members
        and modtype.source_type_members[name]
    if member then return member, true end
    return nil, false
end

-- Preserve cycles and sharing while isolating mutable checker inputs. Foreign
-- conversion completes C graphs in place, so each checker clones the probe
-- service's otherwise shared target profile before attaching provenance.
function types.clone_graph(value, memo)
    if type(value) ~= "table" then return value end
    memo = memo or {}
    if memo[value] then return memo[value] end
    local copy = {}
    memo[value] = copy
    for key, child in pairs(value) do
        copy[types.clone_graph(key, memo)] =
            types.clone_graph(child, memo)
    end
    return copy
end

-- C declaration nodes retain the normalized umbrella header that produced
-- their spelling. The metadata is compiler-only: binary interfaces reject C
-- FFI types and serialization ignores underscore fields.
function types.mark_c_ffi_include(typ, include, seen)
    if type(typ) ~= "table" then return end
    seen = seen or {}
    if seen[typ] then return end
    seen[typ] = true

    local tag = typ._tag
    local declaration_node = tag == "Type.CPointer"
        or tag == "Type.CArray" or tag == "Type.CFunction"
        or tag == "Type.CStruct" or tag == "Type.CUnion"
        or tag == "Type.CField" or tag == "Type.CTypedef"
        or tag == "Type.COwned"
        or (tag == "Type.CInteger" and typ._c_enum_identity)
    if declaration_node and not typ._c_origin_header then
        typ._c_origin_header = include
    end

    if tag == "Type.CPointer" then
        types.mark_c_ffi_include(typ.pointee, include, seen)
    elseif tag == "Type.CArray" then
        types.mark_c_ffi_include(typ.elem, include, seen)
    elseif tag == "Type.CFunction" then
        for _, param in ipairs(typ.params or {}) do
            types.mark_c_ffi_include(param, include, seen)
        end
        types.mark_c_ffi_include(typ.ret, include, seen)
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        for _, field in ipairs(typ.fields or {}) do
            types.mark_c_ffi_include(field, include, seen)
        end
    elseif tag == "Type.CField" then
        types.mark_c_ffi_include(typ.type, include, seen)
    elseif tag == "Type.CTypedef" then
        types.mark_c_ffi_include(typ.target, include, seen)
    elseif tag == "Type.COwned" then
        types.mark_c_ffi_include(typ.pointee, include, seen)
    end
end

-- Return every origin reached through the exact C declaration graph being
-- rendered. Do not walk Titan namespaces or nominal member maps.
function types.c_ffi_includes(typ)
    local includes, seen_includes, seen = {}, {}, {}
    local function add(include)
        if not include then return end
        local key = assert(include.rendered,
            "C origin header has no normalized spelling")
        if seen_includes[key] then return end
        seen_includes[key] = true
        includes[#includes + 1] = include
    end
    local function visit(value)
        if type(value) ~= "table" or seen[value] then return end
        seen[value] = true
        local tag = value._tag
        -- These Titan values render as Udata */TValue and do not spell their
        -- semantic C payload. A later payload cast records the pointee itself.
        if tag == "Type.COwned" or tag == "Type.Function" then return end

        add(value._c_origin_header)
        if tag == "Type.CPointer" then
            visit(value.pointee)
        elseif tag == "Type.CArray" then
            visit(value.elem)
        elseif tag == "Type.CFunction" then
            for _, param in ipairs(value.params or {}) do visit(param) end
            visit(value.ret)
        elseif tag == "Type.CField" then
            visit(value.type)
        end
        -- A retained C typedef, struct, union, or enum emits only its own
        -- spelling. Do not walk the hidden target or aggregate fields.
    end
    visit(typ)
    return includes
end

local function resolved_c(t)
    return types.resolve_c_typedef(t)
end

local function is_c_integer(t)
    t = resolved_c(t)
    return t and t._tag == "Type.CInteger"
end

function types.is_c_enum_integer_conversion(source, target)
    source, target = resolved_c(source), resolved_c(target)
    return source and target
        and source._tag == "Type.CInteger"
        and target._tag == "Type.CInteger"
        and source._c_enum_owner ~= nil
        and source._c_enum_owner == (target._c_enum_owner or target)
end

local function is_c_float(t)
    t = resolved_c(t)
    return t and t._tag == "Type.CFloat"
end

local function is_c_void_pointer(t)
    t = resolved_c(t)
    return t and t._tag == "Type.CPointer"
        and resolved_c(t.pointee)._tag == "Type.CVoid"
end

local function is_c_pointer(t)
    t = resolved_c(t)
    return t and t._tag == "Type.CPointer"
end

local function is_c_function_pointer(t)
    t = resolved_c(t)
    return t and t._tag == "Type.CPointer"
        and resolved_c(t.pointee)._tag == "Type.CFunction"
end

function types.is_c_function_pointer_void_cast(source, target)
    return is_c_function_pointer(source) and is_c_void_pointer(target)
end

function types.is_c_void_function_pointer_cast(source, target)
    return is_c_void_pointer(source) and is_c_function_pointer(target)
end

local function c_pointer_category(t)
    t = resolved_c(t)
    if not (t and t._tag == "Type.CPointer") then return nil end
    local pointee = resolved_c(t.pointee)
    if pointee._tag == "Type.CFunction" then
        return "function"
    elseif pointee._tag == "Type.CVoid" then
        return "void"
    end
    return "object"
end

local function has_qual(typ, wanted)
    for _, qual in ipairs(typ.quals or {}) do
        if qual == wanted then return true end
    end
    return false
end

local function has_const_qual(typ)
    return typ and typ._tag == "Type.CPointer"
        and types.c_pointer_has_qual(typ, "const")
        or has_qual(typ, "const")
end

local function discarded_pointer_qualifier(source, target)
    source = resolved_c(source)
    target = resolved_c(target)
    if not (source and target
            and source._tag == "Type.CPointer"
            and target._tag == "Type.CPointer") then
        return nil
    end
    for _, qualifier in ipairs({ "const", "volatile" }) do
        if types.c_pointer_has_qual(source, qualifier) and
           not types.c_pointer_has_qual(target, qualifier) then
            return qualifier
        end
    end

    local source_pointee = resolved_c(source.pointee)
    local target_pointee = resolved_c(target.pointee)
    if source_pointee._tag == "Type.CPointer"
       and target_pointee._tag == "Type.CPointer" then
        return discarded_pointer_qualifier(
            source.pointee, target.pointee)
    end
    return nil
end

local function qualifiers_include(target, source)
    return discarded_pointer_qualifier(source, target) == nil
end

function types.c_pointer_category(t)
    return c_pointer_category(t)
end

function types.c_discarded_pointer_qualifier(source, target)
    return discarded_pointer_qualifier(source, target)
end

function types.c_unsafe_object_pointer_candidate(source, target)
    local source_res = resolved_c(source)
    local target_res = resolved_c(target)
    if c_pointer_category(source_res) ~= "object"
       or c_pointer_category(target_res) ~= "object" then
        return nil
    end
    local discarded =
        discarded_pointer_qualifier(source_res, target_res)
    if discarded then
        return nil, discarded
    end
    return true, nil, source_res, target_res
end

-- Natural pointer produced by using a local C object as an address source.
-- Arrays undergo C decay; every other admissible object becomes `T *`.
function types.c_local_address_pointer(source)
    local resolved = resolved_c(source)
    if not resolved or not types.is_c(source) then return nil end
    if resolved._tag == "Type.CArray" then
        return types.CPointer(resolved.elem, resolved.quals or {})
    elseif resolved._tag == "Type.CStruct"
        or resolved._tag == "Type.CUnion" then
        return types.CPointer(source, {})
    end
    return nil
end

local function c_assignable_equal(t1, t2)
    return types.equals(resolved_c(t1), resolved_c(t2))
end

local function c_object_to_void_pointer_compatible(source, target)
    source = resolved_c(source)
    target = resolved_c(target)
    if not (source and target
            and source._tag == "Type.CPointer"
            and target._tag == "Type.CPointer") then
        return false
    end
    local source_pointee = resolved_c(source.pointee)
    local target_pointee = resolved_c(target.pointee)
    return source_pointee._tag ~= "Type.CFunction"
        and target_pointee._tag == "Type.CVoid"
        and qualifiers_include(target, source)
end

local function c_void_to_object_pointer_compatible(source, target, allow_char_pointer)
    source = resolved_c(source)
    target = resolved_c(target)
    if not (source and target
            and source._tag == "Type.CPointer"
            and target._tag == "Type.CPointer") then
        return false
    end
    local source_pointee = resolved_c(source.pointee)
    local target_pointee = resolved_c(target.pointee)
    if not allow_char_pointer
       and target_pointee._tag == "Type.CInteger"
       and (target_pointee.spelling == "char"
            or target_pointee.spelling == "signed char"
            or target_pointee.spelling == "unsigned char") then
        return false
    end
    return source_pointee._tag == "Type.CVoid"
        and target_pointee._tag ~= "Type.CFunction"
        and qualifiers_include(target, source)
end

local function c_pointer_compatible(source, target)
    source = resolved_c(source)
    target = resolved_c(target)
    if not (target and target._tag == "Type.CPointer") then
        return false
    elseif source._tag == "Type.CPointer" then
        local source_pointee = resolved_c(source.pointee)
        local target_pointee = resolved_c(target.pointee)
        if source_pointee._tag == "Type.CFunction"
           or target_pointee._tag == "Type.CFunction" then
            return false
        end
        return c_assignable_equal(source.pointee, target.pointee)
            and qualifiers_include(target, source)
    elseif source._tag == "Type.CArray" then
        local decayed =
            types.CPointer(source.elem, source.quals or {})
        return c_pointer_compatible(decayed, target)
            or c_object_to_void_pointer_compatible(decayed, target)
    elseif source._tag == "Type.COwned" then
        local adjusted = types.CPointer(source.pointee, {})
        return c_pointer_compatible(adjusted, target)
            or c_object_to_void_pointer_compatible(adjusted, target)
    end
    return false
end

-- Exact endpoint predicates for the named C-pointer plan operations.  The
-- checker and coder share these shape classifiers so a stored plan cannot
-- relabel a checked reinterpretation as one of the ordinary C conversions.
function types.is_c_pointer_coercion(source, target)
    return c_pointer_compatible(source, target)
end

function types.is_c_object_to_void_pointer_conversion(source, target)
    return c_object_to_void_pointer_compatible(source, target)
end

function types.is_c_void_to_object_pointer_coercion(source, target)
    return c_void_to_object_pointer_compatible(source, target, false)
end

function types.is_written_c_void_to_object_pointer_cast(source, target)
    return c_void_to_object_pointer_compatible(source, target, true)
end

function types.c_address_coerceable(source, target)
    local target_res = resolved_c(target)
    if not (target_res and target_res._tag == "Type.CPointer"
            and has_const_qual(target_res)) then
        return false
    end

    local target_pointee = resolved_c(target_res.pointee)
    if target_pointee._tag == "Type.CFunction" then
        return false
    end

    local source_res = resolved_c(source)
    if not (source_res and types.is_c(source)) then
        return false
    elseif is_c_function_pointer(source_res) then
        return false
    elseif source_res._tag == "Type.CVoid"
        or source_res._tag == "Type.CPointer"
        or source_res._tag == "Type.CArray"
        or source_res._tag == "Type.CFunction"
        or source_res._tag == "Type.COwned"
        or source_res._tag == "Type.CModule" then
        return false
    end

    return c_assignable_equal(source, target_res.pointee)
        or target_pointee._tag == "Type.CVoid"
end

function types.c_mutable_address_coerceable(source, target)
    local target_res = resolved_c(target)
    if not (target_res and target_res._tag == "Type.CPointer")
       or has_const_qual(target_res) then
        return false
    end

    local target_pointee = resolved_c(target_res.pointee)
    if target_pointee._tag == "Type.CFunction" then
        return false
    end

    local source_res = resolved_c(source)
    if not (source_res and types.is_c(source)) then
        return false
    elseif is_c_function_pointer(source_res) then
        return false
    elseif source_res._tag == "Type.CVoid"
        or source_res._tag == "Type.CPointer"
        or source_res._tag == "Type.CArray"
        or source_res._tag == "Type.CFunction"
        or source_res._tag == "Type.COwned"
        or source_res._tag == "Type.CModule" then
        return false
    end

    return c_assignable_equal(source, target_res.pointee)
        or target_pointee._tag == "Type.CVoid"
end

local function is_c_char_pointer(t)
    t = resolved_c(t)
    if not (t and t._tag == "Type.CPointer") then
        return false
    end
    local pointee = resolved_c(t.pointee)
    return pointee._tag == "Type.CInteger"
        and (pointee.spelling == "char"
             or pointee.spelling == "signed char"
             or pointee.spelling == "unsigned char")
end

function types.is_counted_c_character_owner(t)
    t = resolved_c(t)
    if not (t and t._tag == "Type.COwned" and t.count) then
        return false
    end
    local pointee = resolved_c(t.pointee)
    return pointee and pointee._tag == "Type.CInteger"
        and (pointee.spelling == "char"
             or pointee.spelling == "signed char"
             or pointee.spelling == "unsigned char")
end

function types.is_pointer_to_string_cast(source, target)
    return (is_c_void_pointer(source)
            or is_c_char_pointer(source))
        and target._tag == "Type.String"
end

function types.is_string_to_c_pointer_coercion(source, target)
    return source._tag == "Type.String"
        and (is_c_char_pointer(target)
             or is_c_void_pointer(target))
end

-- A written cast of one of these statically GC-backed Titan values to C
-- `void *` exposes the address of its native representation object, not a
-- payload buffer. Function values are TValue-backed and therefore need a
-- runtime collectability check in the coder; arbitrary `value` is excluded.
function types.is_gc_identity_void_pointer_cast(source, target)
    source = resolved_c(source)
    return is_c_void_pointer(target)
        and source
        and (source._tag == "Type.Array"
            or source._tag == "Type.Map"
            or source._tag == "Type.Nominal"
            or source._tag == "Type.Function")
end

local function c_value_compatible(t)
    t = resolved_c(t)
    return t and (t._tag == "Type.CInteger"
        or t._tag == "Type.CFloat"
        or t._tag == "Type.CPointer"
        or t._tag == "Type.COwned"
        or types.is_c_tvalue(t))
end

-- Whether a source value of `t` can be stored in and recovered from a TValue.
-- This is deliberately a representation predicate, not the structural
-- `is_c`: ordinary Titan containers and callables remain boxed values even
-- when one of their component types contains C FFI data. Conversely, direct C
-- aggregates and functions have no scalar TValue representation.
function types.has_tvalue_representation(t, seen)
    if not t then return false end

    seen = seen or {}
    if seen[t] ~= nil then return seen[t] end
    -- A malformed legacy alias/Option cycle must not recurse forever or prove
    -- its own representation. Valid recursive nominal graphs stop at their
    -- nominal descriptor before reaching this predicate again.
    seen[t] = false

    local result
    if types.is_direct_c(t) then
        result = c_value_compatible(t)
    else
        local tag = t._tag
        result = tag == "Type.Invalid"
        or tag == "Type.Integer"
        or tag == "Type.Float"
        or tag == "Type.Boolean"
        or tag == "Type.Nil"
        or tag == "Type.String"
        or tag == "Type.Array"
        or tag == "Type.Map"
        or tag == "Type.Value"
        or tag == "Type.Parameter"
        or tag == "Type.Nominal"
        or tag == "Type.Function"
        or (tag == "Type.Option"
            and types.has_tvalue_representation(t.base, seen))
    end
    seen[t] = result and true or false
    return seen[t]
end

local function optional_owner_to_pointer(source, target)
    source = resolved_c(source)
    target = resolved_c(target)
    return source and source._tag == "Type.COwned"
        and target and target._tag == "Type.CPointer"
end

-- Returns true if type always holds truthy values
function types.is_truthy(typ)
    typ = resolved_c(typ)
    local tag = typ._tag
    if tag == "Type.Parameter" then
        if typ.erased_constraint == false then return false end
        return types.is_truthy(types.erase_constraint(
            typ.erased_constraint))
    end
    return tag ~= "Type.Nil" and tag ~= "Type.Value" and tag ~= "Type.Option"
        and tag ~= "Type.Boolean"
        and tag ~= "Type.CPointer"
end

-- Returns true if type always holds falsy values
function types.is_falsy(typ)
    return typ._tag == "Type.Nil"
end

local type_equals

local function c_qualifier_sets_equal(first, second)
    local left, right = {}, {}
    for _, qualifier in ipairs(first or {}) do left[qualifier] = true end
    for _, qualifier in ipairs(second or {}) do right[qualifier] = true end
    for qualifier in pairs(left) do
        if not right[qualifier] then return false end
    end
    for qualifier in pairs(right) do
        if not left[qualifier] then return false end
    end
    return true
end

local function c_combined_qualifiers(...)
    local out = {}
    for index = 1, select("#", ...) do
        for _, qualifier in ipairs(select(index, ...) or {}) do
            out[#out + 1] = qualifier
        end
    end
    return out
end

local function c_resolve_with_qualifiers(typ)
    local quals, seen = {}, {}
    while typ and typ._tag == "Type.CTypedef" and not seen[typ] do
        seen[typ] = true
        for _, qualifier in ipairs(typ.quals or {}) do
            quals[#quals + 1] = qualifier
        end
        typ = typ.target
    end
    return typ, quals
end

local function c_same_value(left, right, seen)
    if left == right then return true end
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return false end
    seen = seen or {}
    local matches = seen[left]
    if matches and matches[right] then return true end
    if not matches then
        matches = {}
        seen[left] = matches
    end
    matches[right] = true
    for key, value in pairs(left) do
        if not c_same_value(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function c_array_bounds_compatible(left, right)
    local left_unknown =
        left == nil or left == false or left == ""
    local right_unknown =
        right == nil or right == false or right == ""
    return left_unknown or right_unknown
        or c_same_value(left, right)
end

local c_declaration_type_equals

local function c_function_type_equals(left, right, seen)
    left = types.resolve_c_typedef(left)
    right = types.resolve_c_typedef(right)
    if not (left and right
            and left._tag == "Type.CFunction"
            and right._tag == "Type.CFunction")
       or left.vararg ~= right.vararg
       or left.abi ~= right.abi
       or (left._paramstyle or "prototype")
            ~= (right._paramstyle or "prototype")
       or #left.params ~= #right.params then
        return false
    end
    for index, parameter in ipairs(left.params) do
        -- C adjusts away the outer qualification of a parameter declaration.
        if not c_declaration_type_equals(
                parameter, right.params[index], seen, true) then
            return false
        end
    end
    return c_declaration_type_equals(
        left.ret, right.ret, seen, false,
        left._return_declaration_qualifiers,
        right._return_declaration_qualifiers)
end

c_declaration_type_equals = function(
        left, right, seen, ignore_outer_qualifiers,
        left_extra_qualifiers, right_extra_qualifiers)
    if type(left) ~= "table" or type(right) ~= "table" then
        return left == right
    end
    local ltype, lalias_quals = c_resolve_with_qualifiers(left)
    local rtype, ralias_quals = c_resolve_with_qualifiers(right)
    if not ltype or not rtype or ltype._tag ~= rtype._tag then return false end

    local tag = ltype._tag
    if not ignore_outer_qualifiers and tag ~= "Type.CArray"
       and not c_qualifier_sets_equal(
            c_combined_qualifiers(
                left_extra_qualifiers, lalias_quals),
            c_combined_qualifiers(
                right_extra_qualifiers, ralias_quals)) then
        return false
    end
    if ltype == rtype and tag ~= "Type.CArray" then return true end

    seen = seen or {}
    local matches = seen[ltype]
    if matches and matches[rtype] then return true end
    if not matches then
        matches = {}
        seen[ltype] = matches
    end
    matches[rtype] = true

    if tag == "Type.CVoid" then
        return true
    elseif tag == "Type.CInteger" then
        if ltype._c_enum_identity or rtype._c_enum_identity then
            return ltype._c_enum_identity ~= nil
               and ltype._c_enum_identity == rtype._c_enum_identity
        end
        return ltype.spelling == rtype.spelling
           and ltype.signed == rtype.signed
           and ltype.rank == rtype.rank
           and ltype.bits == rtype.bits
    elseif tag == "Type.CFloat" then
        return ltype.spelling == rtype.spelling
    elseif tag == "Type.CPointer" then
        local _, lpointee_alias_quals =
            c_resolve_with_qualifiers(ltype.pointee)
        local _, rpointee_alias_quals =
            c_resolve_with_qualifiers(rtype.pointee)
        return c_qualifier_sets_equal(
                c_combined_qualifiers(
                    ltype.quals, lpointee_alias_quals),
                c_combined_qualifiers(
                    rtype.quals, rpointee_alias_quals))
           and c_declaration_type_equals(
                ltype.pointee, rtype.pointee, seen, true)
    elseif tag == "Type.CArray" then
        local _, lelem_alias_quals =
            c_resolve_with_qualifiers(ltype.elem)
        local _, relem_alias_quals =
            c_resolve_with_qualifiers(rtype.elem)
        return c_array_bounds_compatible(
                ltype.len, rtype.len)
           and c_qualifier_sets_equal(
                c_combined_qualifiers(
                    left_extra_qualifiers, lalias_quals,
                    ltype.quals, lelem_alias_quals),
                c_combined_qualifiers(
                    right_extra_qualifiers, ralias_quals,
                    rtype.quals, relem_alias_quals))
           and c_declaration_type_equals(
                ltype.elem, rtype.elem, seen, true)
    elseif tag == "Type.CFunction" then
        return c_function_type_equals(ltype, rtype, seen)
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        -- Source-imported declarations retain their producer descriptor, but
        -- generated C places inherited and direct headers in one file-scope
        -- tag namespace. Equal named file-scope tags therefore denote the same
        -- C type even when independent extraction allocated two objects.
        return ltype == rtype
            or (types.is_c_lua_state(ltype) and types.is_c_lua_state(rtype))
            or (ltype._c_tag_scope == "file"
                and rtype._c_tag_scope == "file"
                and ltype.tagname ~= nil
                and ltype.tagname == rtype.tagname)
    end
    return false
end

function types.c_declaration_type_equals(left, right, ignore_outer_qualifiers)
    return c_declaration_type_equals(
        left, right, {}, ignore_outer_qualifiers and true or false)
end

function types.c_function_types_equal(left, right)
    return c_function_type_equals(left, right, {})
end

local function same_value(v1, v2, seen)
    if v1 == v2 then
        return true
    elseif type(v1) ~= type(v2) then
        return false
    elseif type(v1) ~= "table" then
        return false
    elseif v1._tag or v2._tag then
        return type_equals(v1, v2, seen)
    else
        for k, v in pairs(v1) do
            if not same_value(v, v2[k], seen) then
                return false
            end
        end
        for k in pairs(v2) do
            if v1[k] == nil then
                return false
            end
        end
        return true
    end
end

local function same_list(l1, l2, seen)
    if #l1 ~= #l2 then
        return false
    end
    for i = 1, #l1 do
        if not type_equals(l1[i], l2[i], seen) then
            return false
        end
    end
    return true
end

local function generic_scope_equals(left, right)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table"
       or left._tag ~= "Type.GenericScope"
       or right._tag ~= "Type.GenericScope" then
        return false
    end
    return left.modname == right.modname
       and left.owner_fqtn == right.owner_fqtn
       and left.callable_name == right.callable_name
       and left.role == right.role
       and left.declaration_kind == right.declaration_kind
end

local function same_typeparams(left, right, seen)
    left, right = left or {}, right or {}
    if #left ~= #right then return false end
    for index = 1, #left do
        if not type_equals(left[index], right[index], seen) then
            return false
        end
    end
    return true
end

local function generic_metadata_equals(left, right, seen)
    local lscope, rscope = left.scope or false, right.scope or false
    if lscope == false or rscope == false then
        if lscope ~= rscope then return false end
    elseif not generic_scope_equals(lscope, rscope) then
        return false
    end
    return same_typeparams(left.typeparams, right.typeparams, seen)
end

local function scope_component(value)
    if value == false then return "-" end
    assert(type(value) == "string", "generic scope components are strings")
    return #value .. ":" .. value
end

function types.generic_scope_key(scope)
    assert(type(scope) == "table" and scope._tag == "Type.GenericScope",
        "expected a generic scope")
    return table.concat({
        scope_component(scope.modname),
        scope_component(scope.owner_fqtn),
        scope_component(scope.callable_name),
        scope_component(scope.role),
        scope_component(scope.declaration_kind),
    }, "|")
end

function types.same_generic_scope(left, right)
    return generic_scope_equals(left, right)
end

-- Resolve a rigid Parameter back to the declaration binder that owns its
-- surface constraint. Parameter.erased_constraint is lowering metadata and
-- must never serve as evidence that one generic constraint entails another.
-- Callers keep binder lists indexed by canonical GenericScope spelling because
-- decoded and reconstructed descriptors need not share scope table identity.
-- False is an unconstrained binder; nil is missing or malformed evidence.
function types.parameter_surface_constraint(parameter, scope_bindings)
    if type(parameter) ~= "table"
       or parameter._tag ~= "Type.Parameter"
       or type(scope_bindings) ~= "table" then
        return nil
    end
    local ok, key = pcall(types.generic_scope_key, parameter.scope)
    if not ok then return nil end
    local typeparams = scope_bindings[key]
    if type(typeparams) ~= "table"
       or type(parameter.index) ~= "number"
       or math.type(parameter.index) ~= "integer"
       or parameter.index < 1 then
        return nil
    end
    local typeparam = typeparams[parameter.index]
    if type(typeparam) ~= "table"
       or typeparam._tag ~= "Type.TypeParameter"
       or (typeparam.constraint ~= false
           and (type(typeparam.constraint) ~= "table"
                or not typeparam.constraint._tag)) then
        return nil
    end
    return typeparam.constraint
end

-- Compare the Titan/Lua callable ABI shape shared by ordinary function values
-- and declaration descriptors for methods/record functions. C declarations use
-- Type.CFunction and its separate C compatibility relation. Declaration-only
-- parameter names deliberately stay outside exact callable identity.
local function callable_shape_equals(t1, t2, seen)
    if not same_list(t1.params, t2.params, seen)
       or not same_list(t1.rettypes, t2.rettypes, seen) then
        return false
    end

    local v1, v2 = t1.varargtype, t2.varargtype
    if (v1 and true) ~= (v2 and true) then
        return false
    end
    if v1 and not type_equals(v1, v2, seen) then
        return false
    end

    local f1, f2 = t1.flexrettype, t2.flexrettype
    if (f1 and true) ~= (f2 and true) then
        return false
    end
    if f1 and not type_equals(f1, f2, seen) then
        return false
    end

    return true
end

type_equals = function(t1, t2, seen)
    if t1 == t2 then
        return true
    elseif type(t1) ~= "table" or type(t2) ~= "table" then
        return false
    end

    local tag1, tag2 = t1._tag, t2._tag
    if tag1 ~= tag2 then
        return false
    end

    seen = seen or {}
    local pairkey = tostring(t1) .. "\0" .. tostring(t2)
    if seen[pairkey] then
        return true
    end
    seen[pairkey] = true

    if tag1 == "Type.GenericScope" then
        return generic_scope_equals(t1, t2)
    elseif tag1 == "Type.TypeParameter" then
        -- Binder spellings are diagnostic only. Dense binder position and
        -- Parameter(scope,index) references carry semantic identity.
        if (t1.constraint == false) ~= (t2.constraint == false) then
            return false
        end
        return t1.constraint == false
            or type_equals(t1.constraint, t2.constraint, seen)
    elseif tag1 == "Type.Parameter" then
        -- A rigid leaf's semantic identity is exactly (scope,index). The
        -- binder list owns and validates its constraint; this repeated erased
        -- carrier is lowering metadata rather than another identity axis.
        return t1.index == t2.index
           and generic_scope_equals(t1.scope, t2.scope)
    elseif tag1 == "Type.FunctionScheme" then
        return generic_scope_equals(t1.scope, t2.scope)
           and same_typeparams(t1.typeparams, t2.typeparams, seen)
           and type_equals(t1.signature, t2.signature, seen)
    elseif tag1 == "Type.GenericAlias" then
        return t1.module == t2.module
           and t1.name == t2.name
           and t1.locality == t2.locality
           and t1.target_owner_fqtn == t2.target_owner_fqtn
           and t1.target_alias_fqtn == t2.target_alias_fqtn
           and generic_scope_equals(t1.target_scope, t2.target_scope)
           and same_typeparams(t1.typeparams, t2.typeparams, seen)
    elseif tag1 == "Type.Array" then
        return t1.isconst == t2.isconst
           and (type(t1.isconst) == "boolean" or t1.isconst == "maybe")
           and type_equals(t1.elem, t2.elem, seen)
    elseif tag1 == "Type.Map" then
        return type_equals(t1.keys, t2.keys, seen) and
               type_equals(t1.values, t2.values, seen)
    elseif tag1 == "Type.CInteger" then
        if t1._c_enum_identity or t2._c_enum_identity then
            return t1._c_enum_identity ~= nil
               and t1._c_enum_identity == t2._c_enum_identity
        end
        return t1.spelling == t2.spelling and
               t1.signed == t2.signed and
               t1.rank == t2.rank and
               t1.bits == t2.bits
    elseif tag1 == "Type.CFloat" then
        return t1.spelling == t2.spelling
    elseif tag1 == "Type.CPointer" then
        return c_declaration_type_equals(
            t1, t2, seen, false)
    elseif tag1 == "Type.CArray" then
        return c_declaration_type_equals(
            t1, t2, seen, false)
    elseif tag1 == "Type.CFunction" then
        return c_function_type_equals(t1, t2, seen)
    elseif tag1 == "Type.CStruct" then
        if types.is_c_lua_state(t1) and types.is_c_lua_state(t2) then
            return true
        end
        return t1.cname == t2.cname and
               t1.tagname == t2.tagname and
               t1.typedef == t2.typedef and
               t1.complete == t2.complete and
               t1.has_fam == t2.has_fam and
               same_value(t1.fields, t2.fields, seen)
    elseif tag1 == "Type.CUnion" then
        return t1.cname == t2.cname and
               t1.tagname == t2.tagname and
               t1.typedef == t2.typedef and
               t1.complete == t2.complete and
               same_value(t1.fields, t2.fields, seen)
    elseif tag1 == "Type.CField" then
        return t1.name == t2.name and
               t1.bitfield == t2.bitfield and
               t1.flexible_array == t2.flexible_array and
               type_equals(t1.owner, t2.owner, seen) and
               type_equals(t1.type, t2.type, seen)
    elseif tag1 == "Type.CTypedef" then
        -- C typedef names are nominal in Titan's foreign-type namespace. Their
        -- targets still drive representation through resolve_c_typedef(), but
        -- duplicate declarations imported from different headers can build
        -- distinct target graphs for the same typedef name (for example through
        -- system-header typedef chains). Those are the same C name for equality.
        return t1.name == t2.name
            and same_value(t1.quals or {}, t2.quals or {}, seen)
    elseif tag1 == "Type.COwned" then
        return t1.count == t2.count and type_equals(t1.pointee, t2.pointee, seen)
    elseif tag1 == "Type.CModule" then
        return t1.name == t2.name
           and same_value(t1.members, t2.members, seen)
           and same_value(t1.type_members, t2.type_members, seen)
    elseif tag1 == "Type.Function" then
        -- The third constructor slot is reserved, not an identity
        -- dimension. Malformed non-false shapes are never callable values.
        if t1.vararg ~= false or t2.vararg ~= false then return false end
        -- Typed input/output tails are part of the exact runtime function tag;
        -- differing tail element types must therefore fall back from the
        -- first-class native path.
        return callable_shape_equals(t1, t2, seen)
    elseif tag1 == "Type.Field" then
        return t1.fqtn == t2.fqtn
           and t1.name == t2.name
           and t1.index == t2.index
           and t1.isconst == t2.isconst
           and type(t1.isconst) == "boolean"
           and type_equals(t1.type, t2.type, seen)
    elseif tag1 == "Type.ModuleMember" then
        return t1.modname == t2.modname
           and t1.name == t2.name
           and same_value(t1.paramnames, t2.paramnames, seen)
           and type_equals(t1.type, t2.type, seen)
    elseif tag1 == "Type.ModuleVariable" then
        return t1.modname == t2.modname
           and t1.name == t2.name
           and t1.isconst == t2.isconst
           and type(t1.isconst) == "boolean"
           and type_equals(t1.type, t2.type, seen)
    elseif tag1 == "Type.Module" then
        return t1.name == t2.name
           and same_value(t1.members, t2.members, seen)
           and same_value(t1.type_members or {},
                t2.type_members or {}, seen)
    elseif tag1 == "Type.Record" then
        return t1.name == t2.name
           and t1.nfields == t2.nfields
           and generic_metadata_equals(t1, t2, seen)
           and same_value(t1.fields, t2.fields, seen)
           and same_value(t1.functions, t2.functions, seen)
           and same_value(t1.methods, t2.methods, seen)
    elseif tag1 == "Type.Variant" then
        return t1.fqtn == t2.fqtn
           and t1.name == t2.name
           and t1.index == t2.index
           and ((t1.payload == false and t2.payload == false)
                or (t1.payload ~= false and t2.payload ~= false
                    and type_equals(t1.payload, t2.payload, seen)))
    elseif tag1 == "Type.Union" then
        return t1.name == t2.name
           and t1.nvariants == t2.nvariants
           and generic_metadata_equals(t1, t2, seen)
           and same_value(t1.variants, t2.variants, seen)
           and same_value(t1.functions, t2.functions, seen)
           and same_value(t1.methods, t2.methods, seen)
    elseif tag1 == "Type.Interface" then
        return types.validate_interface_descriptor(t1) ~= nil
           and types.validate_interface_descriptor(t2) ~= nil
           and t1.name == t2.name
           and generic_metadata_equals(t1, t2, seen)
           and same_list(t1.fields, t2.fields, seen)
           and same_list(t1.methods, t2.methods, seen)
    elseif tag1 == "Type.Method" or tag1 == "Type.StaticMethod" then
        return t1.fqtn == t2.fqtn
           and t1.name == t2.name
           and generic_metadata_equals(t1, t2, seen)
           and callable_shape_equals(t1, t2, seen)
    elseif tag1 == "Type.Nominal" then
        return t1.fqtn == t2.fqtn
           and same_list(t1.args or {}, t2.args or {}, seen)
    elseif tag1 == "Type.Option" then
        return type_equals(t1.base, t2.base, seen)
    elseif tag1 == tag2 then
        return true
    else
        return false
    end
end

function types.equals(t1, t2)
    return type_equals(t1, t2)
end

-- Alpha-equivalence pairs declaration binders by structural position, not by
-- the owner/callable spelling embedded in their serialized GenericScope. Exact
-- equality deliberately retains those spellings for ordinary descriptor
-- identity; Interface implementation matching uses this separate relation.
function types.alpha_equals(t1, t2)
    local scope_map, paired = {}, {}

    local function pair(left, right)
        if type(left) ~= "table" or type(right) ~= "table" then return end
        local seen_right = paired[left]
        if seen_right and seen_right[right] then return end
        if not seen_right then
            seen_right = {}
            paired[left] = seen_right
        end
        seen_right[right] = true
        if left._tag ~= right._tag then return end

        local tag = left._tag
        if tag == "Type.FunctionScheme" or tag == "Type.Record"
           or tag == "Type.Union" or tag == "Type.Interface"
           or tag == "Type.Method" or tag == "Type.StaticMethod" then
            if left.scope ~= false and right.scope ~= false then
                scope_map[right.scope] = left.scope
            end
        elseif tag == "Type.GenericAlias" then
            if left.target_scope ~= false and right.target_scope ~= false then
                scope_map[right.target_scope] = left.target_scope
            end
        end

        for key, child in pairs(left) do
            if key ~= "_tag" then
                local other = right[key]
                if type(child) == "table" and type(other) == "table" then
                    pair(child, other)
                end
            end
        end
    end
    pair(t1, t2)

    local clone = types.clone_graph(t2)
    local seen = {}
    local function rebind(value)
        if type(value) ~= "table" then return value end
        if scope_map[value] then return scope_map[value] end
        if seen[value] then return value end
        seen[value] = true
        for key, child in pairs(value) do
            local replacement = scope_map[child]
            if replacement then
                value[key] = replacement
            elseif type(child) == "table" then
                rebind(child)
            end
        end
        return value
    end
    -- clone_graph preserves sharing but not the original table keys used by
    -- scope_map. Pair the cloned scopes by their structural spellings.
    local clone_scope_map = {}
    local original_seen = {}
    local function align(original, copied)
        if type(original) ~= "table" or type(copied) ~= "table"
           or original_seen[original] then return end
        original_seen[original] = true
        if scope_map[original] then clone_scope_map[copied] = scope_map[original] end
        for key, child in pairs(original) do
            if type(child) == "table" and type(copied[key]) == "table" then
                align(child, copied[key])
            end
        end
    end
    align(t2, clone)
    scope_map = clone_scope_map
    return type_equals(t1, rebind(clone))
end

-- The relations below deliberately separate gradual consistency from the
-- operations that may be performed at an assignment or language boundary.
-- Keep their result objects data-only: later checker/coder phases can attach
-- and lower these plans without having to rerun a semantic relation.

-- Collapse transparent aliases before relation dispatch. Qualification that
-- affects a surrounding C declarator remains on that declarator; the named
-- value type itself is transparent here. Alias chains are cycle-safe.
function types.normalize(typ)
    local seen = {}
    while typ do
        if seen[typ] then
            -- Cyclic aliases are malformed legacy graphs, not a recursive type
            -- constructor. Reject the chain uniformly regardless of which
            -- alias in the cycle was supplied as the entry point.
            return nil
        end
        seen[typ] = true
        if typ._tag == "Type.CTypedef" then
            typ = typ.target
        else
            break
        end
    end
    return typ
end

-- Generic type argument and reconstruction helpers. These deliberately know
-- only Titan's existing structural type grammar; constraint satisfaction and
-- call inference remain checker policy.
local function dense_list_length(list)
    if type(list) ~= "table" then
        return nil, "expected a dense numeric list"
    end
    local count, maximum = 0, 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, "expected numeric list keys only"
        end
        count = count + 1
        if key > maximum then maximum = key end
    end
    if count ~= maximum then
        return nil, "expected a dense numeric list"
    end
    return count
end

function types.dense_type_list_length(list)
    return dense_list_length(list)
end

local function deoptionized(typ)
    if typ._tag == "Type.Option" then return typ.base end
    return typ
end

function types.canonical_option(typ)
    assert(type(typ) == "table" and typ._tag,
        "option base must be a type")
    if typ._tag == "Type.Option" or typ._tag == "Type.Value" then
        return typ
    end
    return types.Option(typ)
end

function types.canonical_array(elem, isconst)
    assert(type(elem) == "table" and elem._tag,
        "array element must be a type")
    assert(type(isconst) == "boolean" or isconst == "maybe",
        "array const qualifier must be a boolean or 'maybe'")
    return types.Array(deoptionized(elem), isconst)
end

function types.canonical_map(keys, values)
    assert(type(keys) == "table" and keys._tag
        and type(values) == "table" and values._tag,
        "map components must be types")
    if keys._tag == "Type.Nil" then
        error("type of map key cannot be nil", 2)
    elseif keys._tag == "Type.Option" then
        error("type of map key cannot be option type", 2)
    end
    return types.Map(keys, deoptionized(values))
end

-- Input variadics and flexible-result tails share the TitanVargX carrier
-- inventory. Keep the structural admission query in the type layer so generic
-- substitution and metadata validation reconstruct the same canonical callable
-- shapes as the source checker.
function types.valid_varg_element(typ)
    if type(typ) ~= "table" or type(typ._tag) ~= "string" then return false end
    if types.is_c_tvalue(typ) then return true end

    local tag = typ._tag
    if tag == "Type.Invalid" then
        return true -- suppress cascades after an earlier source error
    elseif tag == "Type.Integer" or tag == "Type.Float"
        or tag == "Type.Boolean" or tag == "Type.String"
        or tag == "Type.Array" or tag == "Type.Map"
        or tag == "Type.Value" or tag == "Type.Nominal"
        or tag == "Type.Function" or tag == "Type.COwned" then
        return true
    elseif tag == "Type.Option" then
        return types.has_tvalue_representation(typ.base)
    elseif tag == "Type.Parameter" then
        local carrier = typ.erased_constraint ~= false
            and typ.erased_constraint or types.Value()
        return types.valid_varg_element(carrier)
    end
    return false
end

local function canonical_callable_tail(typ, role)
    if typ == false then return false end
    if typ._tag == "Type.Nil" then
        error("a " .. role .. " cannot have type nil", 3)
    elseif types.resolve_c_typedef(typ)._tag == "Type.CPointer" then
        error("a " .. role .. " cannot have a foreign pointer type", 3)
    elseif not types.valid_varg_element(typ) then
        error("a " .. role .. " cannot use type " .. types.tostring(typ) ..
            " because it has no supported variadic-value representation", 3)
    end
    return typ
end

function types.canonical_function(
        params, rettypes, varargtype, flexrettype)
    return types.Function(params, rettypes, false,
        canonical_callable_tail(varargtype, "variadic parameter"),
        canonical_callable_tail(flexrettype, "flexible return"))
end

local function copy_scalar_metadata(source, target)
    for key, value in pairs(source) do
        if key ~= "_tag" and target[key] == nil
           and type(key) == "string" and type(value) ~= "table" then
            target[key] = value
        end
    end
    return target
end

local function rewrite_map(map, rewrite)
    local out = {}
    for key, value in pairs(map or {}) do
        if type(key) ~= "number" then
            out[key] = rewrite(value)
        end
    end
    return out
end

local function rewrite_list(list, rewrite)
    local out = {}
    for index, value in ipairs(list or {}) do
        out[index] = rewrite(value)
    end
    return out
end

local function rewrite_type(root, policy)
    local memo, active = {}, {}

    local function rewrite(typ)
        if typ == false or typ == nil then return typ end
        if type(typ) ~= "table" or type(typ._tag) ~= "string" then
            error("generic type rewrite expected a Type descriptor", 3)
        end
        if memo[typ] then return memo[typ] end
        if active[typ] then
            error("cyclic structural type in generic type rewrite", 3)
        end
        active[typ] = true

        local tag, out = typ._tag
        if tag == "Type.Parameter" then
            out = policy.parameter(typ, rewrite)
            if out == nil then
                local erased = typ.erased_constraint
                out = types.Parameter(typ.scope, typ.index,
                    typ.diagnostic_name,
                    erased == false and false or rewrite(erased))
            end
        elseif tag == "Type.GenericScope" then
            out = typ
        elseif tag == "Type.TypeParameter" then
            if policy.drop_generic then
                out = typ.constraint == false and types.Value()
                    or rewrite(typ.constraint)
            else
                out = types.TypeParameter(typ.name,
                    typ.constraint == false and false
                        or rewrite(typ.constraint))
            end
        elseif tag == "Type.FunctionScheme" then
            if policy.drop_generic or policy.closes(typ.scope) then
                out = rewrite(typ.signature)
            else
                out = types.FunctionScheme(typ.scope,
                    rewrite_list(typ.typeparams, rewrite),
                    rewrite(typ.signature))
            end
        elseif tag == "Type.GenericAlias" then
            if policy.drop_generic then
                out = types.Nominal(typ.target_owner_fqtn)
            elseif policy.closes(typ.target_scope) then
                out = types.Nominal(typ.target_owner_fqtn,
                    policy.arguments)
            else
                out = types.GenericAlias(typ.module, typ.name,
                    typ.locality, typ.target_owner_fqtn,
                    typ.target_alias_fqtn, typ.target_scope,
                    rewrite_list(typ.typeparams, rewrite))
            end
        elseif tag == "Type.Nominal" then
            if policy.drop_generic
               and not policy.keep_nominal_arguments then
                out = types.Nominal(typ.fqtn)
            else
                out = types.Nominal(typ.fqtn,
                    rewrite_list(typ.args or {}, rewrite))
            end
        elseif tag == "Type.Option" then
            out = types.canonical_option(rewrite(typ.base))
        elseif tag == "Type.Array" then
            out = types.canonical_array(rewrite(typ.elem), typ.isconst)
            if typ.linear then out.linear = true end
        elseif tag == "Type.Map" then
            out = types.canonical_map(
                rewrite(typ.keys), rewrite(typ.values))
        elseif tag == "Type.Function" then
            if typ.vararg ~= false then
                error("Type.Function reserved vararg field must be false", 3)
            end
            out = types.canonical_function(
                rewrite_list(typ.params, rewrite),
                rewrite_list(typ.rettypes, rewrite),
                typ.varargtype == false and false
                    or rewrite(typ.varargtype),
                typ.flexrettype == false and false
                    or rewrite(typ.flexrettype))
        elseif tag == "Type.Field" then
            out = types.Field(typ.fqtn, typ.name,
                rewrite(typ.type), typ.index, typ.isconst)
        elseif tag == "Type.Variant" then
            out = types.Variant(typ.fqtn, typ.name,
                typ.payload == false and false or rewrite(typ.payload),
                typ.index)
        elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
            local constructor = tag == "Type.Method"
                and types.Method or types.StaticMethod
            local closes = policy.drop_generic
                or (typ.scope ~= false and policy.closes(typ.scope))
            local varargtype = typ.varargtype == false and false
                or rewrite(typ.varargtype)
            local flexrettype = typ.flexrettype == false and false
                or rewrite(typ.flexrettype)
            canonical_callable_tail(varargtype, "variadic parameter")
            canonical_callable_tail(flexrettype, "flexible return")
            out = constructor(typ.fqtn, typ.name,
                rewrite_list(typ.params, rewrite),
                rewrite_list(typ.rettypes, rewrite),
                varargtype, flexrettype, typ.paramnames,
                (not closes and typ.scope) or false,
                closes and {} or rewrite_list(
                    typ.typeparams or {}, rewrite))
        elseif tag == "Type.Record" then
            local fields = rewrite_list(typ.fields, rewrite)
            local closes = policy.drop_generic
                or (typ.scope ~= false and policy.closes(typ.scope))
            out = types.Record(typ.name, fields,
                rewrite_map(typ.functions, rewrite),
                rewrite_map(typ.methods, rewrite), typ.nfields,
                (not closes and typ.scope) or false,
                closes and {} or rewrite_list(
                    typ.typeparams or {}, rewrite))
        elseif tag == "Type.Union" then
            local variants = rewrite_list(typ.variants, rewrite)
            local closes = policy.drop_generic
                or (typ.scope ~= false and policy.closes(typ.scope))
            out = types.Union(typ.name, variants,
                rewrite_map(typ.functions, rewrite),
                rewrite_map(typ.methods, rewrite), typ.nvariants,
                (not closes and typ.scope) or false,
                closes and {} or rewrite_list(
                    typ.typeparams or {}, rewrite))
        elseif tag == "Type.Interface" then
            local closes = policy.drop_generic
                or (typ.scope ~= false and policy.closes(typ.scope))
            out = types.Interface(typ.name,
                rewrite_list(typ.fields, rewrite),
                rewrite_list(typ.methods, rewrite),
                (not closes and typ.scope) or false,
                closes and {} or rewrite_list(
                    typ.typeparams or {}, rewrite))
        elseif tag == "Type.ModuleMember" then
            out = types.ModuleMember(typ.modname, typ.name,
                rewrite(typ.type), typ.paramnames)
        elseif tag == "Type.ModuleVariable" then
            out = types.ModuleVariable(typ.modname, typ.name,
                rewrite(typ.type), typ.isconst)
        elseif tag == "Type.Module" then
            out = types.Module(typ.name,
                rewrite_list(typ.members, rewrite),
                rewrite_map(typ.type_members, rewrite))
            -- These transient provider-selection fields are deliberately not
            -- serialized, but rewriting a recovered module must not silently
            -- select a different physical DSO.
            out.file = typ.file
            out.prefix = typ.prefix
        elseif tag == "Type.Invalid" or tag == "Type.Nil"
            or tag == "Type.Void" or tag == "Type.Boolean"
            or tag == "Type.Integer" or tag == "Type.Float"
            or tag == "Type.String" or tag == "Type.Value"
            or tag:match("^Type%.C") then
            -- C declarations are compilation-unit-local immutable leaves from
            -- the generic algebra's perspective. Type parameters cannot occur
            -- inside their declarator graph.
            out = typ
        else
            error("unsupported tag in generic type rewrite: " .. tag, 3)
        end

        active[typ] = nil
        if out._tag == typ._tag then
            out = copy_scalar_metadata(typ, out)
        end
        memo[typ] = out
        return out
    end

    return rewrite(root)
end

local function substitution_arguments(arguments, require_roundtrip)
    local count, list_error = dense_list_length(arguments)
    if not count then error(list_error, 3) end
    local copy = {}
    for index = 1, count do
        local argument = arguments[index]
        if type(argument) ~= "table" or not argument._tag then
            error("type argument " .. index .. " is not a type", 3)
        end
        if require_roundtrip and not types.transient_roundtrip(argument) then
            error("type argument " .. index .. " ('" ..
                types.tostring(argument) ..
                "') has no sound transient round trip", 3)
        end
        copy[index] = argument
    end
    return copy
end

local function substitute_arguments(typ, scope, args)
    return rewrite_type(typ, {
        arguments = args,
        drop_generic = false,
        closes = function(candidate)
            return generic_scope_equals(scope, candidate)
        end,
        parameter = function(parameter)
            if not generic_scope_equals(parameter.scope, scope) then
                return nil
            end
            local replacement = args[parameter.index]
            if replacement == nil then
                error("missing type argument " .. parameter.index ..
                    " for " .. types.generic_scope_key(scope), 3)
            end
            return replacement
        end,
    })
end

-- Substitute one structural declaration scope. Repeated calls handle owner
-- and callable-local binders without conflating their identities.
function types.substitute(typ, scope, arguments)
    assert(type(scope) == "table" and scope._tag == "Type.GenericScope",
        "substitution scope must be a GenericScope")
    return substitute_arguments(
        typ, scope, substitution_arguments(arguments, true))
end

-- Inference must retain the first selected surface type long enough to freeze
-- ordinary later edges, even when that selection will be rejected as a generic
-- type argument. This internal structural substitution validates density and
-- type shape but deliberately leaves transient-roundtrip admission to the
-- inference-context close, which reports it once before bounded recovery.
function types.substitute_inference(typ, scope, arguments)
    assert(type(scope) == "table" and scope._tag == "Type.GenericScope",
        "substitution scope must be a GenericScope")
    return substitute_arguments(
        typ, scope, substitution_arguments(arguments, false))
end

function types.validate_type_arguments(typeparams, arguments)
    local parameter_count, parameter_error =
        dense_list_length(typeparams)
    if not parameter_count then return nil, parameter_error end
    local argument_count, argument_error =
        dense_list_length(arguments)
    if not argument_count then return nil, argument_error end
    if argument_count ~= parameter_count then
        return nil, string.format("expected %d type arguments but found %d",
            parameter_count, argument_count)
    end
    for index, argument in ipairs(arguments) do
        if type(argument) ~= "table" or not argument._tag then
            return nil, string.format(
                "type argument %d is not a type", index)
        elseif not types.transient_roundtrip(argument) then
            return nil, string.format(
                "type argument %d ('%s') has no sound transient round trip",
                index, types.tostring(argument))
        end
    end
    return arguments
end

function types.apply_scheme(scheme, arguments)
    assert(type(scheme) == "table"
        and scheme._tag == "Type.FunctionScheme",
        "expected a FunctionScheme")
    local valid, argument_error =
        types.validate_type_arguments(scheme.typeparams, arguments)
    if not valid then error(argument_error, 2) end
    return types.substitute(scheme, scheme.scope, arguments)
end

function types.apply_generic_alias(alias, arguments)
    assert(type(alias) == "table"
        and alias._tag == "Type.GenericAlias",
        "expected a GenericAlias")
    local valid, argument_error =
        types.validate_type_arguments(alias.typeparams, arguments)
    if not valid then error(argument_error, 2) end
    return types.substitute(alias, alias.target_scope, arguments)
end

-- Constraint erasure retains recursively erased nominal applications long
-- enough for surface consistency, constraint checking, member substitution,
-- and boundary elaboration to observe their component carriers. The later
-- code-facing erasure drops those applications because runtime identity is
-- owner-only.
function types.erase_constraint(typ)
    return rewrite_type(typ, {
        arguments = {},
        drop_generic = true,
        keep_nominal_arguments = true,
        closes = function() return true end,
        parameter = function(parameter, rewrite)
            if parameter.erased_constraint == false then
                return types.Value()
            end
            return rewrite(parameter.erased_constraint)
        end,
    })
end

-- Erasure selects only an existing ordinary Titan carrier. Applied nominal
-- arguments disappear after their dependent members have been rewritten.
function types.erase(typ)
    return rewrite_type(typ, {
        arguments = {},
        drop_generic = true,
        closes = function() return true end,
        parameter = function(parameter, rewrite)
            if parameter.erased_constraint == false then
                return types.Value()
            end
            return rewrite(parameter.erased_constraint)
        end,
    })
end

function types.contains_generic(typ)
    local seen = {}
    local function visit(value)
        if type(value) ~= "table" or seen[value] then return false end
        seen[value] = true
        local tag = value._tag
        if tag == "Type.GenericScope" or tag == "Type.TypeParameter"
           or tag == "Type.Parameter" or tag == "Type.FunctionScheme"
           or tag == "Type.GenericAlias" then
            return true
        elseif tag == "Type.Nominal" and #(value.args or {}) > 0 then
            return true
        elseif (tag == "Type.Record" or tag == "Type.Union"
                or tag == "Type.Interface" or tag == "Type.Method"
                or tag == "Type.StaticMethod")
           and (value.scope ~= false or #(value.typeparams or {}) > 0) then
            return true
        end
        for key, child in pairs(value) do
            if key ~= "_tag" and visit(child) then return true end
        end
        return false
    end
    return visit(typ)
end

function types.is_erased(typ)
    return not types.contains_generic(typ)
end

function types.assert_erased(typ)
    if types.contains_generic(typ) then
        error("generic type reached erased core", 2)
    end
    return typ
end

local function plan(kind, fields)
    fields = fields or {}
    fields.kind = kind
    return fields
end

local function normalized_pair(left, right)
    return types.normalize(left), types.normalize(right)
end

local function is_relation_nominal(typ)
    local tag = typ and typ._tag
    return tag == "Type.Nominal"
        or tag == "Type.Record"
        or tag == "Type.Union"
end

local function nominal_name(typ)
    return typ.fqtn or typ.name
end

local function relation_identity(left, right)
    left, right = normalized_pair(left, right)
    if not left or not right
       or left._tag == "Type.Variant"
       or right._tag == "Type.Variant"
       or left._tag == "Type.Interface"
       or right._tag == "Type.Interface" then
        return false
    elseif is_relation_nominal(left) or is_relation_nominal(right) then
        if left._tag ~= right._tag
           or nominal_name(left) ~= nominal_name(right) then
            return false
        elseif left._tag == "Type.Nominal" then
            return types.equals(left, right)
        end
        return true
    end
    return types.equals(left, right)
end

local function sound_guardable(typ, seen)
    typ = types.normalize(typ)
    if not typ then return false end

    seen = seen or {}
    if seen[typ] ~= nil then return seen[typ] end
    -- Titan's structural type grammar is finite. Recursion through a record,
    -- union, or interface stops at its nominal descriptor; revisiting an
    -- Array/Map/Option/Function table can therefore only be a malformed
    -- internal graph, not evidence that the graph is guardable.
    seen[typ] = false

    local tag = typ._tag
    local ok
    if tag == "Type.Integer" or tag == "Type.Float"
       or tag == "Type.Boolean" or tag == "Type.Nil"
       or tag == "Type.String" or tag == "Type.Value"
       or tag == "Type.Nominal" or tag == "Type.Record"
       or tag == "Type.Union"
       or tag == "Type.COwned" or tag == "Type.CInteger"
       or tag == "Type.CFloat" or types.is_c_tvalue(typ) then
        ok = true
    elseif tag == "Type.Array" then
        ok = sound_guardable(typ.elem, seen)
    elseif tag == "Type.Map" then
        ok = sound_guardable(typ.keys, seen)
            and sound_guardable(typ.values, seen)
    elseif tag == "Type.Option" then
        ok = sound_guardable(typ.base, seen)
    elseif tag == "Type.Function" then
        ok = typ.vararg == false
        for _, param in ipairs(typ.params) do
            ok = ok and sound_guardable(param, seen)
        end
        for _, result in ipairs(typ.rettypes) do
            ok = ok and sound_guardable(result, seen)
        end
        if typ.varargtype then
            ok = ok and sound_guardable(typ.varargtype, seen)
        end
        if typ.flexrettype then
            ok = ok and sound_guardable(typ.flexrettype, seen)
        end
    else
        -- In particular, raw C/legacy pointers are TValue-boxable but do not
        -- retain enough pointee identity for a sound gradual guard.
        ok = false
    end
    seen[typ] = ok
    return ok
end

function types.has_sound_gradual_guard(typ)
    return sound_guardable(typ, {})
end

local function complete_owned_payload(owned)
    local payload, seen = owned.pointee, {}
    while payload and payload._tag == "Type.CTypedef" do
        if seen[payload] then return false end
        seen[payload] = true
        payload = payload.target
    end
    if not payload or not is_c_tag(payload._tag)
       or payload._tag == "Type.CVoid"
       or payload._tag == "Type.CFunction"
       or payload._tag == "Type.CArray"
       or payload._tag == "Type.COwned"
       or payload._tag == "Type.CModule" then
        return false
    elseif payload._tag == "Type.CStruct" then
        return (payload.complete == true and payload.has_fam ~= true)
            or types.is_c_tvalue(payload)
    elseif payload._tag == "Type.CUnion" then
        return payload.complete == true or types.is_c_tvalue(payload)
    end
    return true
end

local function generic_tail_eligible(typ, seen)
    seen = seen or {}
    if seen[typ] ~= nil then return seen[typ] end
    seen[typ] = false
    if typ._tag == "Type.Parameter" then
        return generic_tail_eligible(
            typ.erased_constraint == false and types.Value()
                or types.erase_constraint(typ.erased_constraint), seen)
    elseif typ._tag == "Type.Option" then
        local ok = typ.base._tag ~= "Type.Option"
            and typ.base._tag ~= "Type.Value"
            and types.has_tvalue_representation(typ.base)
        seen[typ] = ok
        return ok
    elseif types.is_c_tvalue(typ) then
        seen[typ] = true
        return true
    end
    local tag = typ._tag
    local ok = tag == "Type.Integer" or tag == "Type.Float"
        or tag == "Type.Boolean" or tag == "Type.String"
        or tag == "Type.Array" or tag == "Type.Map"
        or tag == "Type.Value" or tag == "Type.Nominal"
        or tag == "Type.Function" or tag == "Type.COwned"
    seen[typ] = ok
    return ok
end

-- Prove that generic erasure has a canonical traced carrier and that the
-- existing strict projection can recover the closed value. This is an
-- eligibility predicate only; it never authorizes a coercion or checks an
-- Interface constraint.
function types.transient_roundtrip(typ)
    local results, offenders = {}, {}

    local function visit(value)
        if type(value) ~= "table" or type(value._tag) ~= "string" then
            return false, value
        end
        if results[value] ~= nil then
            return results[value], offenders[value]
        end
        -- Structural cycles are malformed. Nominal recursion ends at a
        -- Nominal leaf and therefore never depends on accepting such a cycle.
        results[value] = false
        offenders[value] = value

        local tag, ok, offender = value._tag, false, value
        if tag == "Type.Nil" or tag == "Type.Boolean"
           or tag == "Type.Integer" or tag == "Type.Float"
           or tag == "Type.String" or tag == "Type.Value" then
            ok = true
        elseif tag == "Type.CTypedef" then
            ok, offender = visit(value.target)
        elseif types.is_c_tvalue(value) then
            ok = true
        elseif tag == "Type.CInteger" then
            -- An unresolved enum's provisional carrier has no certified width.
            ok = type(value.bits) == "number"
        elseif tag == "Type.CFloat" then
            ok = true
        elseif tag == "Type.COwned" then
            ok = complete_owned_payload(value)
        elseif tag == "Type.Parameter" then
            ok = type(value.scope) == "table"
                and value.scope._tag == "Type.GenericScope"
                and type(value.index) == "number"
                and value.index >= 1 and value.index % 1 == 0
            if ok and value.erased_constraint ~= false then
                ok = value.erased_constraint._tag == "Type.Nominal"
                if ok then ok, offender = visit(value.erased_constraint) end
            end
        elseif tag == "Type.Nominal" then
            local count
            count, offender = dense_list_length(value.args or {})
            ok = count ~= nil and types.has_sound_gradual_guard(value)
            if ok then
                for index = 1, count do
                    ok, offender = visit(value.args[index])
                    if not ok then break end
                end
            end
        elseif tag == "Type.Option" then
            if value.base._tag == "Type.Option"
               or value.base._tag == "Type.Value" then
                ok, offender = false, value.base
            else
                ok, offender = visit(value.base)
            end
        elseif tag == "Type.Array" then
            if value.elem._tag == "Type.Option" then
                ok, offender = false, value.elem
            else
                ok, offender = visit(value.elem)
            end
        elseif tag == "Type.Map" then
            if value.keys._tag == "Type.Nil"
               or value.keys._tag == "Type.Option"
               or value.values._tag == "Type.Option" then
                ok, offender = false,
                    value.keys._tag == "Type.Option"
                        and value.keys or value.values
            else
                ok, offender = visit(value.keys)
                if ok then ok, offender = visit(value.values) end
            end
        elseif tag == "Type.Function" then
            local pcount, rcount = dense_list_length(value.params),
                dense_list_length(value.rettypes)
            ok = value.vararg == false and pcount ~= nil and rcount ~= nil
                and (value.varargtype == false
                    or generic_tail_eligible(value.varargtype))
                and (value.flexrettype == false
                    or generic_tail_eligible(value.flexrettype))
            if ok then
                for index = 1, pcount do
                    ok, offender = visit(value.params[index])
                    if not ok then break end
                end
            end
            if ok then
                for index = 1, rcount do
                    ok, offender = visit(value.rettypes[index])
                    if not ok then break end
                end
            end
            if ok and value.varargtype ~= false then
                ok, offender = visit(value.varargtype)
            end
            if ok and value.flexrettype ~= false then
                ok, offender = visit(value.flexrettype)
            end
        end

        results[value] = ok and true or false
        if ok then
            offenders[value] = nil
        else
            offenders[value] = offender
        end
        return results[value], offenders[value]
    end

    return visit(typ)
end

local function guard_plan(target, seen)
    target = types.normalize(target)
    if not target or not sound_guardable(target, {}) then return false end

    seen = seen or {}
    if seen[target] then return seen[target] end

    local result = plan("gradual_guard", { target = target })
    seen[target] = result
    local tag = target._tag
    if tag == "Type.Integer" then
        result.op = "integer"
    elseif tag == "Type.Float" then
        result.op = "float"
    elseif tag == "Type.Boolean" then
        result.op = "boolean"
    elseif tag == "Type.Nil" then
        result.op = "nil"
    elseif tag == "Type.String" then
        result.op = "string"
    elseif tag == "Type.Value" then
        result.op = "value"
    elseif tag == "Type.Array" then
        result.op = "array"
        result.isconst = target.isconst
        result.element = guard_plan(target.elem, seen)
    elseif tag == "Type.Map" then
        result.op = "map"
        result.key = guard_plan(target.keys, seen)
        result.value = guard_plan(target.values, seen)
    elseif tag == "Type.Option" then
        result.op = "option"
        result.inner = guard_plan(target.base, seen)
    elseif tag == "Type.Function" then
        result.op = "callable"
    elseif is_relation_nominal(target) then
        result.op = "nominal"
        result.name = nominal_name(target)
    elseif tag == "Type.COwned" then
        result.op = "c_owned"
    elseif tag == "Type.CInteger" then
        result.op = "c_integer"
    elseif tag == "Type.CFloat" then
        result.op = "c_float"
    elseif types.is_c_tvalue(target) then
        result.op = "c_tvalue"
    else
        return false
    end
    return result
end

function types.gradual_guard(target)
    return guard_plan(target, {})
end

local relation_consistent
local callable_adjustment_impl
local rigid_erased_carrier

local function gradual_view_plan(source, target)
    source, target = normalized_pair(source, target)
    if not source or not target then
        return false
    elseif source._tag == "Type.Value" then
        local guard = guard_plan(target, {})
        if not guard then return false end
        return plan("gradual_view", {
            op = "project",
            source = source,
            target = target,
            guard = guard,
        })
    elseif target._tag == "Type.Value" then
        if not types.has_tvalue_representation(source)
           or not sound_guardable(source, {}) then
            return false
        end
        return plan("gradual_view", {
            op = "inject",
            source = source,
            target = target,
        })
    end
    local guard = guard_plan(target, {})
    if not guard then return false end
    return plan("gradual_view", {
        op = "structural",
        source = source,
        target = target,
        guard = guard,
    })
end

local function component_adjustment(source, target, context)
    source, target = normalized_pair(source, target)
    if not source or not target then
        return false
    elseif relation_identity(source, target) then
        return plan("identity", { source = source, target = target })
    elseif source._tag == "Type.Function"
       and target._tag == "Type.Function" then
        return callable_adjustment_impl(source, target, context)
    elseif relation_consistent(source, target) then
        return gradual_view_plan(source, target)
    end
    return false
end

function types.accepts_missing_nil(target)
    target = types.normalize(target)
    local tag = target and target._tag
    return tag == "Type.Nil" or tag == "Type.Value"
        or tag == "Type.Option"
        or tag == "Type.CPointer"
end

local accepts_missing_nil = types.accepts_missing_nil

callable_adjustment_impl = function(source, target, context)
    source, target = normalized_pair(source, target)
    if not source or not target
       or source._tag ~= "Type.Function"
       or target._tag ~= "Type.Function"
       or source.vararg ~= false
       or target.vararg ~= false then
        return false
    end

    context = context or {
        callable_seen = {},
        allow_partial_flex = true,
    }
    local matches = context.callable_seen[source]
    if matches and matches[target] ~= nil then
        return matches[target]
    end

    local exact = relation_identity(source, target)

    local result = plan("callable", {
        source = source,
        target = target,
        exact = exact,
        arguments = {},
        results = {},
    })
    if not matches then
        matches = {}
        context.callable_seen[source] = matches
    end
    -- Callable adjustment is an inductive derivation. A recursive revisit
    -- before any finite component has completed is not evidence for itself:
    -- reject that pending branch. Exact/bisimilar cycles have already stopped
    -- at relation_identity above, while ordinary recursive records/unions are
    -- nominal leaves rather than structural Function-table cycles.
    matches[target] = false

    local nargs = math.min(#source.params, #target.params)
    for index = 1, nargs do
        -- A call through `target` supplies a target parameter to the actual
        -- `source` function.
        local adjustment = component_adjustment(
            target.params[index], source.params[index], context)
        if not adjustment then
            matches[target] = nil
            return false
        end
        result.arguments[#result.arguments + 1] = {
            kind = "argument",
            expected_index = index,
            actual_index = index,
            adjustment = adjustment,
        }
    end

    -- Fixed actual suffixes receive either an expected tail element or nil.
    for index = #target.params + 1, #source.params do
        if not accepts_missing_nil(source.params[index]) then
            matches[target] = nil
            return false
        end
        if target.varargtype then
            local adjustment = component_adjustment(
                target.varargtype, source.params[index], context)
            if not adjustment then
                matches[target] = nil
                return false
            end
            result.arguments[#result.arguments + 1] = {
                kind = "tail_or_nil_to_argument",
                actual_index = index,
                expected_tail_offset = index - #target.params,
                adjustment = adjustment,
            }
        else
            result.arguments[#result.arguments + 1] = {
                kind = "nil_fill",
                actual_index = index,
            }
        end
    end

    -- A shorter fixed actual ignores the expected suffix unless it has an
    -- input tail that observes those values.
    for index = #source.params + 1, #target.params do
        if source.varargtype then
            local adjustment = component_adjustment(
                target.params[index], source.varargtype, context)
            if not adjustment then
                matches[target] = nil
                return false
            end
            result.arguments[#result.arguments + 1] = {
                kind = "argument_to_tail",
                expected_index = index,
                adjustment = adjustment,
            }
        else
            result.arguments[#result.arguments + 1] = {
                kind = "ignore_argument",
                expected_index = index,
            }
        end
    end

    if source.varargtype and target.varargtype then
        local adjustment = component_adjustment(
            target.varargtype, source.varargtype, context)
        if not adjustment then
            matches[target] = nil
            return false
        end
        result.arguments[#result.arguments + 1] = {
            kind = "tail_to_tail",
            expected_tail_consumed =
                math.max(0, #source.params - #target.params),
            adjustment = adjustment,
        }
    elseif source.varargtype then
        result.arguments[#result.arguments + 1] = {
            kind = "empty_tail",
        }
    elseif target.varargtype then
        result.arguments[#result.arguments + 1] = {
            kind = "ignore_tail",
            expected_tail_consumed =
                math.max(0, #source.params - #target.params),
        }
    end

    for index, expected in ipairs(target.rettypes) do
        local actual = source.rettypes[index]
        if actual then
            local adjustment =
                component_adjustment(actual, expected, context)
            if not adjustment then
                matches[target] = nil
                return false
            end
            result.results[#result.results + 1] = {
                kind = "result",
                actual_index = index,
                expected_index = index,
                adjustment = adjustment,
            }
        elseif source.flexrettype then
            local adjustment
            local optional = expected._tag == "Type.Option"
            local wrap_present = false
            if optional then
                adjustment = component_adjustment(
                    source.flexrettype, expected, context)
                if not adjustment then
                    adjustment = component_adjustment(
                        source.flexrettype, expected.base, context)
                    wrap_present = adjustment and true or false
                end
            elseif context.allow_partial_flex ~= false then
                adjustment = component_adjustment(
                    source.flexrettype, expected, context)
            end
            if not adjustment then
                matches[target] = nil
                return false
            end
            result.results[#result.results + 1] = {
                kind = optional and "flex_to_optional_result"
                    or "flex_to_result",
                expected_index = index,
                actual_flex_offset = index - #source.rettypes,
                adjustment = adjustment,
                wrap_present = optional and wrap_present or nil,
            }
        elseif accepts_missing_nil(expected) then
            -- A call through the expected view requests one more fixed result
            -- than the actual function can produce. This is a named shape
            -- action, not a component coercion: the adapter materializes the
            -- absent result directly in the expected nil-bearing
            -- representation.
            result.results[#result.results + 1] = {
                kind = "nil_fill_result",
                expected_index = index,
                expected_type = expected,
            }
        else
            matches[target] = nil
            return false
        end
    end

    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype then
            local adjustment = component_adjustment(
                source.rettypes[index], target.flexrettype, context)
            if not adjustment then
                matches[target] = nil
                return false
            end
            result.results[#result.results + 1] = {
                kind = "result_to_flex",
                actual_index = index,
                expected_flex_offset = index - #target.rettypes,
                adjustment = adjustment,
            }
        else
            result.results[#result.results + 1] = {
                kind = "hide_result",
                actual_index = index,
            }
        end
    end

    if source.flexrettype and target.flexrettype then
        local adjustment = component_adjustment(
            source.flexrettype, target.flexrettype, context)
        if not adjustment then
            matches[target] = nil
            return false
        end
        result.results[#result.results + 1] = {
            kind = "flex_to_flex",
            actual_flex_consumed =
                math.max(0, #target.rettypes - #source.rettypes),
            adjustment = adjustment,
        }
    elseif source.flexrettype then
        result.results[#result.results + 1] = {
            kind = "hide_flex",
            actual_flex_consumed =
                math.max(0, #target.rettypes - #source.rettypes),
        }
    elseif target.flexrettype then
        result.results[#result.results + 1] = {
            kind = "end_flex",
        }
    end

    matches[target] = result
    return result
end

local consistent_impl

local function callable_shape_consistent(source, target, context)
    if source.vararg ~= false or target.vararg ~= false then return false end
    local nargs = math.min(#source.params, #target.params)
    for index = 1, nargs do
        -- A call through `target` supplies a target parameter to the actual
        -- `source` callable.
        if not consistent_impl(
                target.params[index], source.params[index], context) then
            return false
        end
    end

    for index = #target.params + 1, #source.params do
        if not accepts_missing_nil(source.params[index]) then
            return false
        elseif target.varargtype
           and not consistent_impl(
               target.varargtype, source.params[index], context) then
            return false
        end
    end

    for index = #source.params + 1, #target.params do
        if source.varargtype
           and not consistent_impl(
               target.params[index], source.varargtype, context) then
            return false
        end
    end

    if source.varargtype and target.varargtype
       and not consistent_impl(
           target.varargtype, source.varargtype, context) then
        return false
    end

    for index, expected_unresolved in ipairs(target.rettypes) do
        local actual = source.rettypes[index]
        if actual then
            if not consistent_impl(actual, expected_unresolved, context) then
                return false
            end
        elseif source.flexrettype then
            local expected = types.normalize(expected_unresolved)
            local compatible =
                consistent_impl(
                    source.flexrettype, expected_unresolved, context)
            if not compatible
               and expected and expected._tag == "Type.Option" then
                compatible =
                    consistent_impl(
                        source.flexrettype, expected.base, context)
            end
            if not compatible then return false end
        else
            return false
        end
    end

    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype
           and not consistent_impl(
               source.rettypes[index], target.flexrettype, context) then
            return false
        end
    end

    if source.flexrettype and target.flexrettype
       and not consistent_impl(
           source.flexrettype, target.flexrettype, context) then
        return false
    end

    return true
end

rigid_erased_carrier = function(parameter)
    if parameter.erased_constraint == false then
        return types.Value()
    end
    return types.erase_constraint(parameter.erased_constraint)
end

local function owner_argument_carrier(owner, index, arguments)
    if not owner or owner.scope == false
       or type(owner.typeparams) ~= "table"
       or not owner.typeparams[index] then
        return false
    end
    local binder = owner.typeparams[index]
    if binder.constraint == false then return types.Value() end
    local ok, substituted = pcall(
        types.substitute, binder.constraint, owner.scope, arguments)
    if not ok then return false end
    return types.erase_constraint(substituted)
end

consistent_impl = function(left, right, context)
    left, right = normalized_pair(left, right)
    if not left or not right
       or left._tag == "Type.Variant"
       or right._tag == "Type.Variant" then
        return false
    elseif relation_identity(left, right) then
        return true
    end

    local completed_left = context.completed[left]
    if completed_left and completed_left[right] ~= nil then
        return completed_left[right]
    end

    -- Titan's grammar does not admit recursive structural types. Alias
    -- resolution rejects cycles, while recursion in records, unions, and
    -- interfaces reaches a nominal leaf. Keep this pending-pair check only as
    -- a defense against a malformed cycle supplied by an internal caller
    -- serving as its own non-identity proof; it is not a fixed-point rule in
    -- the language relation.
    local active = context.active
    local left_active = active[left]
    local right_active = active[right]
    if (left_active and left_active[right])
       or (right_active and right_active[left]) then
        return false
    end
    if not left_active then
        left_active = {}
        active[left] = left_active
    end
    if not right_active then
        right_active = {}
        active[right] = right_active
    end
    left_active[right] = true
    right_active[left] = true

    local result
    if left._tag == "Type.Parameter"
       and right._tag == "Type.Parameter" then
        -- Distinct rigid binders do not become mutually consistent merely
        -- because they erase to the same carrier; gradual consistency is not
        -- transitive through value.
        result = false
    elseif left._tag == "Type.Parameter" then
        local carrier = rigid_erased_carrier(left)
        if carrier._tag == "Type.Value" then
            result = right._tag == "Type.Value"
        elseif right._tag == "Type.Value" then
            result = false
        else
            result = consistent_impl(carrier, right, context)
        end
    elseif right._tag == "Type.Parameter" then
        local carrier = rigid_erased_carrier(right)
        if carrier._tag == "Type.Value" then
            result = left._tag == "Type.Value"
        elseif left._tag == "Type.Value" then
            result = false
        else
            result = consistent_impl(left, carrier, context)
        end
    elseif left._tag == "Type.Value"
       or right._tag == "Type.Value" then
        local other = left._tag == "Type.Value" and right or left
        result = sound_guardable(other, {})
            and types.has_tvalue_representation(other)
    elseif left._tag == "Type.Nominal"
       and right._tag == "Type.Nominal"
       and left.fqtn == right.fqtn
       and #(left.args or {}) == #(right.args or {}) then
        result = true
        local owner = types.registry[left.fqtn]
        for index = 1, #(left.args or {}) do
            local larr, rarr = left.args[index], right.args[index]
            local component = types.equals(larr, rarr)
            if not component and owner then
                local left_carrier = owner_argument_carrier(
                    owner, index, left.args)
                local right_carrier = owner_argument_carrier(
                    owner, index, right.args)
                component = (left_carrier
                        and types.equals(rarr, left_carrier))
                    or (right_carrier
                        and types.equals(larr, right_carrier))
            end
            if not component then
                result = false
                break
            end
        end
    elseif left._tag == "Type.Array"
       and right._tag == "Type.Array" then
        result = left.isconst == right.isconst
            and (type(left.isconst) == "boolean" or left.isconst == "maybe")
            and consistent_impl(left.elem, right.elem, context)
    elseif left._tag == "Type.Map"
       and right._tag == "Type.Map" then
        result = consistent_impl(left.keys, right.keys, context)
            and consistent_impl(left.values, right.values, context)
    elseif left._tag == "Type.Option"
       and right._tag == "Type.Option" then
        result = consistent_impl(left.base, right.base, context)
    elseif left._tag == "Type.Function"
       and right._tag == "Type.Function" then
        result = callable_shape_consistent(left, right, context)
            or callable_shape_consistent(right, left, context)
    else
        result = false
    end

    left_active[right] = nil
    right_active[left] = nil
    completed_left = context.completed[left]
    if not completed_left then
        completed_left = {}
        context.completed[left] = completed_left
    end
    local completed_right = context.completed[right]
    if not completed_right then
        completed_right = {}
        context.completed[right] = completed_right
    end
    completed_left[right] = result and true or false
    completed_right[left] = result and true or false
    return result
end

relation_consistent = function(left, right)
    return consistent_impl(left, right, {
        active = {},
        completed = {},
    })
end

function types.consistent(left, right)
    return relation_consistent(left, right)
end

function types.callable_adjustment(source_actual, target_expected, policy)
    policy = policy or {}
    return callable_adjustment_impl(source_actual, target_expected, {
        callable_seen = {},
        allow_partial_flex = policy.allow_partial_flex ~= false,
    })
end

local function interface_match_failure(
        reason, concrete, interface, index, required, fields)
    fields = fields or {}
    fields.kind = "interface_mismatch"
    fields.reason = reason
    fields.concrete = concrete
    fields.interface = interface
    fields.index = index
    fields.name = required and required.name or nil
    fields.required = required
    return false, fields
end

local function non_method_named(concrete, name)
    if concrete.functions and concrete.functions[name] then
        return concrete.functions[name]
    end
    for _, field in ipairs(concrete.fields or {}) do
        if field.name == name then return field end
    end
    if concrete._tag == "Type.Union"
       and concrete.variants and concrete.variants[name] then
        return concrete.variants[name]
    end
    return nil
end

local function concrete_field_named(concrete, name)
    for _, field in ipairs(concrete.fields or {}) do
        if field.name == name then return field end
    end
    return nil
end

local function non_field_named(concrete, name)
    if concrete.methods and concrete.methods[name] then
        return concrete.methods[name]
    elseif concrete.functions and concrete.functions[name] then
        return concrete.functions[name]
    elseif concrete._tag == "Type.Union"
       and concrete.variants and concrete.variants[name] then
        return concrete.variants[name]
    end
    return nil
end

local function interface_method_visible(
        method, concrete, policy)
    if policy.method_visible then
        return policy.method_visible(method, concrete, policy)
            and true or false
    end
    if not method.islocal then return true end
    local owner_module =
        method.fqtn and method.fqtn:match("^(.*)%.[^.]+$")
    return owner_module == policy.visibility
end


local function interface_field_visible(field, concrete, policy)
    if policy.field_visible then
        return policy.field_visible(field, concrete, policy)
            and true or false
    end
    if not field.islocal then return true end
    local owner_module =
        field.fqtn and field.fqtn:match("^(.*)%.[^.]+$")
    return owner_module == policy.visibility
end

-- Check one concrete Record/Union descriptor against one Interface descriptor.
-- This is intentionally not a general type relation: descriptor resolution is
-- owned by the cast-site policy, the scan follows Interface declaration order,
-- and aligned callable slots admit only exact/gradual component adjustment.
function types.interface_implementation(concrete, interface, policy)
    if type(concrete) ~= "table"
       or (concrete._tag ~= "Type.Record"
           and concrete._tag ~= "Type.Union") then
        return interface_match_failure(
            "invalid_concrete", concrete, interface)
    elseif type(interface) ~= "table"
       or interface._tag ~= "Type.Interface" then
        return interface_match_failure(
            "invalid_interface", concrete, interface)
    end

    local valid, validation_error =
        types.validate_interface_descriptor(interface)
    if not valid then
        return interface_match_failure(
            "invalid_interface", concrete, interface, nil, nil, {
                detail = validation_error,
            })
    elseif type(concrete.methods) ~= "table" then
        return interface_match_failure(
            "invalid_concrete", concrete, interface)
    elseif type(policy) ~= "table"
       or (type(policy.visibility) ~= "string"
           and ((#interface.fields > 0
                 and type(policy.field_visible) ~= "function")
                or (#interface.methods > 0
                    and type(policy.method_visible) ~= "function"))) then
        return interface_match_failure(
            "missing_visibility", concrete, interface)
    end

    if #interface.fields > 0 and concrete._tag ~= "Type.Record" then
        return interface_match_failure(
            "fields_require_record", concrete, interface,
            1, interface.fields[1], { member_kind = "field" })
    end

    local field_mappings, method_mappings = {}, {}
    local all_exact = true
    for index, required in ipairs(interface.fields) do
        local field = concrete_field_named(concrete, required.name)
        if field == nil then
            local collision = non_field_named(concrete, required.name)
            if collision then
                return interface_match_failure(
                    "not_field", concrete, interface,
                    index, required, {
                        member = collision,
                        member_kind = "field",
                    })
            end
            return interface_match_failure(
                "missing", concrete, interface, index, required, {
                    member_kind = "field",
                })
        elseif type(field) ~= "table"
           or field._tag ~= "Type.Field"
           or field.fqtn ~= concrete.name then
            return interface_match_failure(
                "not_field", concrete, interface,
                index, required, {
                    member = field,
                    member_kind = "field",
                })
        elseif field.isconst ~= true then
            return interface_match_failure(
                "mutable", concrete, interface,
                index, required, {
                    member = field,
                    member_kind = "field",
                })
        elseif not interface_field_visible(field, concrete, policy) then
            return interface_match_failure(
                "inaccessible", concrete, interface,
                index, required, {
                    member = field,
                    member_kind = "field",
                })
        end

        local adjustment = types.assignment_adjustment(
            field.type, required.type, policy)
        if not adjustment then
            return interface_match_failure(
                "incompatible", concrete, interface,
                index, required, {
                    member = field,
                    member_kind = "field",
                    concrete_type = field.type,
                    required_type = required.type,
                })
        end

        local exact = types.equals(field.type, required.type)
        all_exact = all_exact and exact
        field_mappings[index] = {
            source_index = field.index,
            target_index = required.index,
            name = required.name,
            required = required,
            concrete = field,
            source = field.type,
            target = required.type,
            adjustment = adjustment,
            exact = exact,
        }
    end

    for index, required in ipairs(interface.methods) do
        local method = concrete.methods[required.name]
        if method == nil then
            local collision =
                non_method_named(concrete, required.name)
            if collision then
                return interface_match_failure(
                    "not_method", concrete, interface,
                    index, required, { member = collision })
            end
            return interface_match_failure(
                "missing", concrete, interface, index, required)
        elseif type(method) ~= "table"
           or method._tag ~= "Type.Method"
           or method.fqtn ~= concrete.name then
            return interface_match_failure(
                "not_method", concrete, interface,
                index, required, { member = method })
        elseif not interface_method_visible(
                method, concrete, policy) then
            return interface_match_failure(
                "inaccessible", concrete, interface,
                index, required, { member = method })
        end

        local concrete_type =
            types.method_function_type(method)
        local required_type =
            types.method_function_type(required)
        local adjustment = types.callable_adjustment(
            concrete_type, required_type, {
                aligned_coercions = false,
                allow_partial_flex =
                    policy.allow_partial_flex ~= false,
            })
        if not adjustment then
            return interface_match_failure(
                "incompatible", concrete, interface,
                index, required, {
                    member = method,
                    concrete_type = concrete_type,
                    required_type = required_type,
                })
        end

        local exact = types.equals(concrete_type, required_type)
        all_exact = all_exact and exact
        method_mappings[index] = {
            index = index - 1,
            name = required.name,
            required = required,
            concrete = method,
            source = concrete_type,
            target = required_type,
            adjustment = adjustment,
            exact = exact,
        }
    end

    return {
        kind = "interface_implementation",
        concrete = concrete,
        interface = interface,
        fields = field_mappings,
        methods = method_mappings,
        exact = all_exact,
    }
end

local function generic_method_constraint_view(typeparam, scope, arguments)
    if typeparam.constraint == false then return false end
    local ok, constraint = pcall(
        types.substitute, typeparam.constraint, scope, arguments)
    if not ok then return nil end
    return constraint
end

local function close_generic_method_pair(concrete, required)
    local concrete_params = concrete.typeparams or {}
    local required_params = required.typeparams or {}
    if #concrete_params == 0 and #required_params == 0 then
        return concrete, required
    elseif #concrete_params ~= #required_params
       or concrete.scope == false or required.scope == false then
        return nil
    end

    local arguments = {}
    for index, typeparam in ipairs(required_params) do
        arguments[index] = types.Parameter(
            required.scope, index, typeparam.name, false)
    end
    for index = 1, #arguments do
        local concrete_constraint = generic_method_constraint_view(
            concrete_params[index], concrete.scope, arguments)
        local required_constraint = generic_method_constraint_view(
            required_params[index], required.scope, arguments)
        if concrete_constraint == nil or required_constraint == nil
           or (concrete_constraint == false)
                ~= (required_constraint == false)
           or (concrete_constraint ~= false
               and not types.equals(
                   concrete_constraint, required_constraint)) then
            return nil
        end
        arguments[index].erased_constraint = required_constraint
    end

    local concrete_ok, concrete_closed =
        pcall(types.substitute, concrete, concrete.scope, arguments)
    local required_ok, required_closed =
        pcall(types.substitute, required, required.scope, arguments)
    if not concrete_ok or not required_ok then return nil end
    return concrete_closed, required_closed
end

-- Close declaration-local method binders alpha-stably before using the ordinary
-- Interface matcher. This shared semantic proof is used both by the source
-- checker and by closed metadata validation/recovery.
function types.generic_interface_implementation(concrete, interface, policy)
    -- Owner-generic applications reach this helper after `types.substitute`
    -- has rewritten the complete Record/Interface descriptor, including both
    -- field lists. Keep the surface field descriptors explicit so the
    -- method-local alpha-closing view below cannot leak into the returned
    -- lowering map.
    local original_fields = {}
    local required_fields = {}
    for index, required in ipairs(interface.fields or {}) do
        required_fields[index] = required
        original_fields[index] = {
            required = required,
            concrete = concrete_field_named(concrete, required.name),
        }
    end
    local concrete_methods = {}
    for name, method in pairs(concrete.methods or {}) do
        concrete_methods[name] = method
    end
    local required_methods = {}
    local originals = {}

    for index, required in ipairs(interface.methods or {}) do
        local method = concrete.methods and concrete.methods[required.name]
        if method and method._tag == "Type.Method" then
            local concrete_view, required_view =
                close_generic_method_pair(method, required)
            if not concrete_view then
                return false, {
                    kind = "interface_mismatch",
                    reason = "incompatible",
                    concrete = concrete,
                    interface = interface,
                    index = index,
                    name = required.name,
                    required = required,
                    member = method,
                    concrete_type = types.method_function_type(method),
                    required_type = types.method_function_type(required),
                }
            end
            concrete_methods[required.name] = concrete_view
            required_methods[index] = required_view
            originals[index] = {
                concrete = method,
                required = required,
            }
        else
            required_methods[index] = required
        end
    end

    local concrete_view = {}
    for key, value in pairs(concrete) do concrete_view[key] = value end
    concrete_view.methods = concrete_methods
    local interface_view = types.Interface(
        interface.name, required_fields, required_methods, interface.scope,
        interface.typeparams)
    interface_view.islocal = interface.islocal

    local implementation, failure = types.interface_implementation(
        concrete_view, interface_view, policy)
    if not implementation then
        if failure then
            failure.concrete = concrete
            failure.interface = interface
            local original
            if failure.index then
                original = failure.member_kind == "field"
                    and original_fields[failure.index]
                    or originals[failure.index]
            end
            if original then
                failure.required = original.required
                failure.member = original.concrete
            end
        end
        return false, failure
    end

    implementation.concrete = concrete
    implementation.interface = interface
    for index, mapping in ipairs(implementation.fields) do
        local original = original_fields[index]
        if original then
            mapping.required = original.required
            mapping.concrete = original.concrete
        end
    end
    for index, mapping in ipairs(implementation.methods) do
        local original = originals[index]
        if original then
            mapping.required = original.required
            mapping.concrete = original.concrete
        end
    end
    return implementation
end

local function coercion_plan(op, source, target, fields)
    fields = fields or {}
    fields.op = op
    fields.source = source
    fields.target = target
    return plan("coercion", fields)
end

local function coercion_impl(source, target, policy, seen)
    source, target = normalized_pair(source, target)
    if not source or not target
       or source._tag == "Type.Variant"
       or target._tag == "Type.Variant"
       or relation_identity(source, target) then
        return false
    end

    seen = seen or {}
    local matches = seen[source]
    if matches and matches[target] ~= nil then
        return matches[target]
    end
    if not matches then
        matches = {}
        seen[source] = matches
    end
    -- Recursive Option plans are the only recursive direct coercions. Mark a
    -- pending pair rejected; a named rule below replaces it on success.
    matches[target] = false

    local result
    if is_c_integer(source) and target._tag == "Type.Integer" then
        result = coercion_plan("c_integer_to_integer", source, target)
    elseif source._tag == "Type.Integer" and is_c_integer(target) then
        result = coercion_plan("integer_to_c_integer", source, target)
    elseif types.is_c_enum_integer_conversion(source, target) then
        result = coercion_plan("c_enum_integer", source, target)
    elseif is_c_float(source) and target._tag == "Type.Float" then
        result = coercion_plan("c_float_to_float", source, target)
    elseif source._tag == "Type.Float" and is_c_float(target) then
        result = coercion_plan("float_to_c_float", source, target)
    elseif source._tag == "Type.Integer" and is_c_float(target) then
        result = coercion_plan("integer_to_c_float", source, target)
    elseif target._tag == "Type.COwned"
       and not target.count
       and (types.resolve_c_typedef(source)._tag == "Type.CStruct"
            or types.resolve_c_typedef(source)._tag == "Type.CUnion")
       and types.equals(source, types.normalize(target.pointee)) then
        result = coercion_plan("c_automatic_to_owned", source, target)
    elseif target._tag == "Type.COwned" and target.count
       and source._tag == "Type.CArray"
       and type(source.len) == "number"
       and types.equals(source.elem, target.pointee) then
        result = coercion_plan("c_automatic_array_to_owned", source, target)
    elseif source._tag == "Type.COwned"
       and target._tag == "Type.Boolean" then
        result = coercion_plan("c_owner_truthiness", source, target)
    elseif is_c_pointer(source) and target._tag == "Type.Boolean" then
        result = coercion_plan("c_pointer_truthiness", source, target)
    elseif source._tag == "Type.Nil" and is_c_pointer(target) then
        result = coercion_plan("nil_to_c_pointer", source, target)
    elseif source._tag == "Type.Value" and is_c_pointer(target) then
        result = false
    elseif types.c_address_coerceable(source, target) then
        result = coercion_plan("c_address", source, target)
    elseif types.is_c_pointer_coercion(source, target) then
        result = coercion_plan("c_pointer", source, target)
    elseif types.is_c_object_to_void_pointer_conversion(source, target) then
        result = coercion_plan(
            "c_object_to_void_pointer", source, target)
    elseif types.is_c_void_to_object_pointer_coercion(source, target) then
        result = coercion_plan(
            "c_void_to_object_pointer", source, target)
    elseif types.is_string_to_c_pointer_coercion(source, target) then
        result = coercion_plan("string_to_c_pointer", source, target)
    elseif c_value_compatible(source)
       and target._tag == "Type.Value" then
        -- Boxing an ordinary object pointer as untyped lightuserdata is safe;
        -- only recovery of a precise pointee type is non-reifiable and
        -- restricted to an explicitly written unsafe cast.
        result = coercion_plan("c_value_to_value", source, target)
    elseif source._tag == "Type.Value"
       and c_value_compatible(target)
       and sound_guardable(target, {}) then
        result = coercion_plan("value_to_c_value", source, target, {
            guard = guard_plan(target, {}),
        })
    elseif c_value_compatible(source)
       and types.is_c_tvalue(target) then
        result = coercion_plan("c_value_to_c_tvalue", source, target)
    elseif types.is_c_tvalue(target)
       and not types.is_direct_c(source) then
        -- This is intentionally a whole-slot operation, including for Option:
        -- nil must not be forced before it is copied into the C TValue.
        result = coercion_plan("to_c_tvalue", source, target)
    elseif target._tag == "Type.Boolean"
       and source._tag ~= "Type.Boolean"
       and source._tag ~= "Type.Value"
       and not types.is_direct_c(source) then
        result = coercion_plan("truthiness", source, target)
    elseif target._tag == "Type.Option" then
        if types.has_tvalue_representation(target.base) then
            if source._tag == "Type.Nil" then
                result = coercion_plan("option_nil", source, target)
            elseif source._tag == "Type.Option" then
                if types.has_tvalue_representation(source.base)
                   and not optional_owner_to_pointer(
                       source.base, target.base) then
                    local inner
                    if relation_identity(source.base, target.base) then
                        inner = plan("identity", {
                            source = source.base,
                            target = target.base,
                        })
                    else
                        inner = coercion_impl(
                            source.base, target.base, policy, seen)
                    end
                    if inner then
                        result = coercion_plan(
                            "option_map", source, target, { inner = inner })
                    end
                end
            else
                local inner
                if relation_identity(source, target.base) then
                    inner = plan("identity", {
                        source = source,
                        target = target.base,
                    })
                else
                    inner = coercion_impl(
                        source, target.base, policy, seen)
                end
                if inner then
                    result = coercion_plan(
                        "option_wrap", source, target, { inner = inner })
                end
            end
        end
    elseif source._tag == "Type.Option" then
        if types.has_tvalue_representation(source.base)
           and not optional_owner_to_pointer(source.base, target) then
            local inner
            if relation_identity(source.base, target) then
                inner = plan("identity", {
                    source = source.base,
                    target = target,
                })
            else
                inner = coercion_impl(
                    source.base, target, policy, seen)
            end
            if inner then
                result = coercion_plan(
                    "option_force", source, target, { inner = inner })
            end
        end
    elseif types.is_direct_c(source) or types.is_direct_c(target) then
        result = false
    elseif source._tag == "Type.Integer"
       and target._tag == "Type.Float" then
        result = coercion_plan("integer_to_float", source, target)
    elseif source._tag == "Type.Float"
       and target._tag == "Type.Integer" then
        result = coercion_plan("float_to_integer", source, target)
    elseif source._tag == "Type.Nominal"
       and target._tag == "Type.Nominal"
       and policy and policy.interface_coercion then
        -- Scalar expressions carry nominals, not their Record/Union/Interface
        -- declaration descriptors. The cast-site callback owns descriptor
        -- resolution, owner-kind checks, and visibility. A false result leaves
        -- unrelated nominal pairs rejected; a successful result authorizes
        -- only this direct outer wrapper coercion.
        local implementation =
            policy.interface_coercion(source, target, policy)
        if implementation then
            local methods = implementation.kind == "interface_implementation"
                and implementation.methods or implementation
            result = coercion_plan(
                "interface_wrapper", source, target, {
                    implementation = implementation.kind ==
                        "interface_implementation" and implementation or nil,
                    fields = implementation.kind ==
                        "interface_implementation" and implementation.fields
                        or {},
                    methods = methods,
                })
        end
    end

    matches[target] = result or false
    return result or false
end

function types.coercion(source, target, policy)
    return coercion_impl(source, target, policy or {}, {})
end

local function dynamic_plan(target, seen)
    target = types.normalize(target)
    if not target or target._tag == "Type.Variant"
       or not sound_guardable(target, {}) then
        return false
    end

    seen = seen or {}
    if seen[target] ~= nil then return seen[target] end
    seen[target] = false

    local tag = target._tag
    local result = plan("dynamic_coercion", { target = target })
    if tag == "Type.Integer" then
        result.op = "integer"
    elseif tag == "Type.Float" then
        result.op = "float"
    elseif tag == "Type.Boolean" then
        result.op = "truthiness"
    elseif tag == "Type.Nil" then
        result.op = "nil"
    elseif tag == "Type.String" then
        result.op = "string"
    elseif tag == "Type.Value" then
        result.op = "value"
    elseif tag == "Type.Array" then
        result.op = "array"
        result.isconst = target.isconst
    elseif tag == "Type.Map" then
        result.op = "map"
    elseif tag == "Type.Function" then
        result.op = "callable"
    elseif is_relation_nominal(target) then
        result.op = "nominal"
        result.name = nominal_name(target)
    elseif tag == "Type.Option" then
        local inner = dynamic_plan(target.base, seen)
        if not inner then return false end
        result.op = "option"
        result.inner = inner
    elseif tag == "Type.CInteger" then
        result.op = "c_integer"
    elseif tag == "Type.CFloat" then
        result.op = "c_float"
    elseif tag == "Type.COwned" then
        result.op = "c_owned"
    elseif types.is_c_tvalue(target) then
        result.op = "c_tvalue"
    else
        -- Raw C pointers deliberately have no implicit dynamic plan: a
        -- lightuserdata address cannot establish its requested pointee type.
        return false
    end
    seen[target] = result
    return result
end

function types.dynamic_coercion(target)
    return dynamic_plan(target, {})
end

local function explicit_conversion(source, target)
    local op
    if types.is_pointer_to_string_cast(source, target) then
        op = "pointer_to_string"
    elseif types.is_gc_identity_void_pointer_cast(source, target) then
        op = "gc_identity_to_void_pointer"
    elseif types.is_c_function_pointer_void_cast(source, target) then
        op = "c_function_pointer_to_void"
    elseif types.is_c_void_function_pointer_cast(source, target) then
        op = "c_void_to_function_pointer"
    elseif types.is_counted_c_character_owner(source)
       and target._tag == "Type.String" then
        op = "counted_owner_to_string"
    elseif (is_c_integer(source) or is_c_float(source))
       and (is_c_integer(target) or is_c_float(target)) then
        op = "c_numeric"
    elseif types.is_c_object_to_void_pointer_conversion(source, target) then
        op = "c_object_to_void_pointer"
    elseif types.is_written_c_void_to_object_pointer_cast(source, target) then
        op = "c_void_to_object_pointer"
    end
    if not op then return false end
    return {
        kind = "explicit_conversion",
        op = op,
        source = source,
        target = target,
    }
end

function types.written_cast(source, target, policy)
    source, target = normalized_pair(source, target)
    if not source or not target
       or source._tag == "Type.Variant"
       or target._tag == "Type.Variant" then
        return false
    elseif relation_identity(source, target) then
        return plan("written_cast", {
            op = "identity",
            source = source,
            target = target,
        })
    end

    -- Freezing is the sole relation that crosses Array mutability. A shallow
    -- freeze cannot convert element representations, so the element types
    -- must be exact or gradually consistent. The checker later refines
    -- `mode` to `freeze` only after a linear-use proof; the semantic default is
    -- always a shallow copy. `is` shares this admission plan but consumes only
    -- its allocation-free test metadata.
    if source._tag == "Type.Array"
       and target._tag == "Type.Array" then
        if source.isconst == false
           and target.isconst == true
           and (types.equals(source.elem, target.elem)
                or relation_consistent(source.elem, target.elem)) then
            local element_view = false
            if not types.equals(source.elem, target.elem) then
                element_view = gradual_view_plan(source.elem, target.elem)
                if not element_view then return false end
            end
            local mode = (source.linear == true) and "freeze" or "copy"
            return plan("written_cast", {
                op = "array_freeze",
                source = source,
                target = target,
                mode = mode,
                element_view = element_view,
                allocation_free_test = true,
            })
        elseif source.isconst == "maybe"
           and (target.isconst == false or target.isconst == true)
           and (types.equals(source.elem, target.elem)
                or relation_consistent(source.elem, target.elem)) then
            local element_view = false
            if not types.equals(source.elem, target.elem) then
                element_view = gradual_view_plan(source.elem, target.elem)
                if not element_view then return false end
            end
            local op = (target.isconst == false)
                and "maybe_array_cast_mutable"
                or "maybe_array_cast_const"
            return plan("written_cast", {
                op = op,
                source = source,
                target = target,
                element_view = element_view,
                allocation_free_test = false,
            })
        elseif (source.isconst == false or source.isconst == true)
           and target.isconst == "maybe"
           and (types.equals(source.elem, target.elem)
                or relation_consistent(source.elem, target.elem)) then
            local element_view = false
            if not types.equals(source.elem, target.elem) then
                element_view = gradual_view_plan(source.elem, target.elem)
                if not element_view then return false end
            end
            return plan("written_cast", {
                op = "maybe_array_cast_upcast",
                source = source,
                target = target,
                element_view = element_view,
                allocation_free_test = true,
            })
        end
    end

    if source._tag == "Type.Value" then
        local dynamic = dynamic_plan(target, {})
        if dynamic then
            return plan("written_cast", {
                op = "dynamic",
                source = source,
                target = target,
                dynamic = dynamic,
            })
        elseif target._tag == "Type.CPointer" then
            -- Recommended raw-pointer policy: only written syntax may request
            -- this unchecked pointee reinterpretation.
            return plan("written_cast", {
                op = "explicit",
                source = source,
                target = target,
                conversion = {
                    kind = "explicit_conversion",
                    op = "unsafe_dynamic_c_pointer",
                    source = source,
                    target = target,
                },
            })
        end
    end

    local direct = coercion_impl(source, target, policy or {}, {})
    if direct then
        return plan("written_cast", {
            op = "coercion",
            source = source,
            target = target,
            coercion = direct,
        })
    end

    local conversion = explicit_conversion(source, target)
    if conversion then
        return plan("written_cast", {
            op = "explicit",
            source = source,
            target = target,
            conversion = conversion,
        })
    end

    if source._tag == "Type.Function"
       and target._tag == "Type.Function" then
        local callable = types.callable_adjustment(source, target, policy)
        if callable then
            return plan("written_cast", {
                op = "callable",
                source = source,
                target = target,
                callable = callable,
            })
        end
    elseif relation_consistent(source, target) then
        local view = gradual_view_plan(source, target)
        if view then
            return plan("written_cast", {
                op = "gradual",
                source = source,
                target = target,
                guard = view.guard,
                view = view,
            })
        end
    end
    return false
end

function types.comparable(left, right)
    left, right = normalized_pair(left, right)
    if not left or not right
       or left._tag == "Type.Variant"
       or right._tag == "Type.Variant" then
        return false
    elseif relation_identity(left, right) then
        return plan("comparison", {
            op = "identity",
            left = left,
            right = right,
        })
    elseif relation_consistent(left, right) then
        local result = {
            op = "consistent",
            left = left,
            right = right,
        }
        -- Equality is symmetric, but code generation still needs both
        -- operands in a common boxed representation when exactly one side is
        -- the gradual `value` hole. Record that injection as part of the
        -- ComparisonPlan instead of asking the checker to discover a
        -- directional assignment after comparability has been established.
        if left._tag == "Type.Value"
           and right._tag ~= "Type.Value" then
            result.right_adjustment =
                gradual_view_plan(right, left)
        elseif right._tag == "Type.Value"
           and left._tag ~= "Type.Value" then
            result.left_adjustment =
                gradual_view_plan(left, right)
        end
        return plan("comparison", result)
    elseif (left._tag == "Type.Integer" and right._tag == "Type.Float")
        or (left._tag == "Type.Float"
            and right._tag == "Type.Integer") then
        return plan("comparison", {
            op = "numeric",
            left = left,
            right = right,
        })
    elseif left._tag == "Type.Option"
       and right._tag == "Type.Option" then
        local inner = types.comparable(left.base, right.base)
        if inner then
            return plan("comparison", {
                op = "option",
                left = left,
                right = right,
                inner = inner,
            })
        end
    end
    return false
end

function types.generic_owner_view(source, target)
    source, target = normalized_pair(source, target)
    if not source or not target
       or source._tag ~= "Type.Nominal"
       or target._tag ~= "Type.Nominal"
       or source.fqtn ~= target.fqtn
       or not relation_consistent(source, target) then
        return false
    end
    return plan("generic_owner_view", {
        source = source,
        target = target,
        erased_source = types.erase(source),
        erased_target = types.erase(target),
    })
end

function types.assignment_adjustment(source, target, policy)
    policy = policy or {}
    source, target = normalized_pair(source, target)
    if not source or not target
       or source._tag == "Type.Variant"
       or target._tag == "Type.Variant" then
        return false
    elseif relation_identity(source, target) then
        return plan("identity", { source = source, target = target })
    elseif source._tag == "Type.Nominal"
       and target._tag == "Type.Nominal"
       and source.fqtn == target.fqtn then
        -- Applied owners are invariant for ordinary static assignment. The
        -- generic lowering pass uses generic_owner_view only at a frozen
        -- closed/erased boundary where both applications denote the same
        -- runtime owner.
        return false
    end

    -- Symmetric function consistency is useful during structural descent, but
    -- assignment must retain the actual-to-expected direction.
    if source._tag == "Type.Function"
       and target._tag == "Type.Function" then
        return types.callable_adjustment(source, target, policy)
    end

    -- Array assignment rules
    if source._tag == "Type.Array" and target._tag == "Type.Array" then
        -- In-place freeze for unaliased linear array
        if source.isconst == false and source.linear == true and target.isconst == true
           and (types.equals(source.elem, target.elem) or relation_consistent(source.elem, target.elem)) then
            local element_view = false
            if not types.equals(source.elem, target.elem) then
                element_view = gradual_view_plan(source.elem, target.elem)
                if not element_view then return false end
            end
            return plan("written_cast", {
                op = "array_freeze",
                source = source,
                target = target,
                mode = "freeze",
                element_view = element_view,
                allocation_free_test = true,
            })
        end

        -- Maybe-const target admits mutable, const, or maybe-const source
        if target.isconst == "maybe" and (source.isconst == false or source.isconst == true or source.isconst == "maybe") then
            if types.equals(source.elem, target.elem) then
                return plan("identity", { source = source, target = target })
            elseif relation_consistent(source.elem, target.elem) then
                local view = gradual_view_plan(source, target)
                if view then return view end
            end
            return false
        end

        -- Maybe-const source cannot be assigned to mutable or const target
        if source.isconst == "maybe" and target.isconst ~= "maybe" then
            return false
        end
    end

    -- Consistent structural views preserve the existing representation,
    -- including an outer Option. Array qualifier changes still use the
    -- separate rules below because consistency requires matching qualifiers.
    if relation_consistent(source, target) then
        local view = gradual_view_plan(source, target)
        if view then return view end
    end

    -- Option(Array) assignment
    if source._tag == "Type.Option" and target._tag == "Type.Option" then
        if source.base._tag == "Type.Array" and target.base._tag == "Type.Array" then
            local inner = types.assignment_adjustment(source.base, target.base, policy)
            if inner then
                if inner.kind == "identity" then
                    return plan("identity", { source = source, target = target })
                else
                    return plan("option_adjustment", {
                        source = source,
                        target = target,
                        inner = inner,
                    })
                end
            end
            return false
        end
    end

    if policy.allow_coercion ~= false then
        local direct = coercion_impl(source, target, policy, {})
        if direct then
            return plan("direct_coercion", {
                source = source,
                target = target,
                coercion = direct,
            })
        end
    end
    return false
end

local function tostring_list(items)
    local out = {}
    for _, item in ipairs(items) do
        table.insert(out, types.tostring(item))
    end
    return table.concat(out, ", ")
end

local function c_display_name(name)
    if type(name) == "table" then
        return table.concat(name, ".")
    end
    return name
end

local function serialize_names(names)
    if names == false then
        return "false"
    end
    local out = {}
    for _, name in ipairs(names) do
        table.insert(out, string.format("%q", name))
    end
    return "{" .. table.concat(out, ",") .. "}"
end

local function tostring_typeparams(typeparams)
    if not typeparams or #typeparams == 0 then return "" end
    local rendered = {}
    for _, typeparam in ipairs(typeparams) do
        rendered[#rendered + 1] = types.tostring(typeparam)
    end
    return "<" .. table.concat(rendered, ", ") .. ">"
end

function types.tostring(t, wrap)
    local tag = t._tag
    if tag == "Type.GenericScope" then
        return "scope[" .. types.generic_scope_key(t) .. "]"
    elseif tag == "Type.TypeParameter" then
        if t.constraint == false then return t.name end
        return t.name .. ": " .. types.tostring(t.constraint)
    elseif tag == "Type.Parameter" then
        return t.diagnostic_name
    elseif tag == "Type.FunctionScheme" then
        return tostring_typeparams(t.typeparams) ..
            types.tostring(t.signature)
    elseif tag == "Type.GenericAlias" then
        local binders = tostring_typeparams(t.typeparams)
        local arguments = {}
        for _, typeparam in ipairs(t.typeparams) do
            arguments[#arguments + 1] = typeparam.name
        end
        local target = t.target_owner_fqtn
        if #arguments > 0 then
            target = target .. "<" .. table.concat(arguments, ", ") .. ">"
        end
        return t.module .. "." .. t.name .. binders .. " = " .. target
    elseif tag == "Type.Integer"     then return "integer"
    elseif tag == "Type.Boolean"     then return "boolean"
    elseif tag == "Type.String"      then return "string"
    elseif tag == "Type.Nil"         then return "nil"
    elseif tag == "Type.Void"        then return "()"
    elseif tag == "Type.Float"       then return "float"
    elseif tag == "Type.Value"       then return "value"
    elseif tag == "Type.Invalid"     then return "invalid type"
    elseif tag == "Type.Array" then
        local prefix = ""
        if t.isconst == true then
            prefix = "const "
        elseif t.isconst == "maybe" then
            prefix = "const? "
        end
        return prefix .. "{ " .. types.tostring(t.elem) .. " }"
    elseif tag == "Type.Map" then
        return "{ " .. types.tostring(t.keys) .. " : " .. types.tostring(t.values) .. " }"
    elseif tag == "Type.Function" then
        local out = {"("}
        local ptypes = {}
        for _, param in ipairs(t.params) do
            table.insert(ptypes, types.tostring(param))
        end
        if t.varargtype then
            table.insert(ptypes, "...: " .. types.tostring(t.varargtype))
        end
        table.insert(out, table.concat(ptypes, ", "))
        table.insert(out, ")")
        local rtypes = {}
        if #t.rettypes == 1 and not t.flexrettype then
          table.insert(rtypes, types.tostring(t.rettypes[1], true))
        else
          for _, rettype in ipairs(t.rettypes) do
            table.insert(rtypes, types.tostring(rettype))
          end
        end
        if t.flexrettype then
            table.insert(rtypes, "...: " .. types.tostring(t.flexrettype))
            -- A flexible tail is legal only in a parenthesized result list;
            -- retaining those parentheses also keeps the rendering
            -- collision-free when its element type is itself a function.
            table.insert(out, " -> (")
            table.insert(out, table.concat(rtypes, ", "))
            table.insert(out, ")")
        elseif #rtypes == 1 then
            table.insert(out, " -> ")
            table.insert(out, rtypes[1])
        elseif #rtypes > 1 then
            table.insert(out, " -> (")
            table.insert(out, table.concat(rtypes, ", "))
            table.insert(out, ")")
        else
            -- zero return values: canonicalize as `(P...) -> ()`, distinct
            -- from a `nil`-returning function `(P...) -> nil`
            table.insert(out, " -> ()")
        end
        local res = table.concat(out)
        return wrap and "(" .. res .. ")" or res
    elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
        local out = {t.fqtn,
             tag == "Type.Method" and ":" or ".",
             t.name, tostring_typeparams(t.typeparams), "("}
        local ptypes = {}
        for _, param in ipairs(t.params) do
            table.insert(ptypes, types.tostring(param))
        end
        if t.varargtype then
            table.insert(ptypes, "...: " .. types.tostring(t.varargtype))
        end
        table.insert(out, table.concat(ptypes, ", "))
        table.insert(out, ")")
        local rtypes = {}
        if #t.rettypes == 1 and not t.flexrettype then
          table.insert(rtypes, types.tostring(t.rettypes[1], true))
        else
          for _, rettype in ipairs(t.rettypes) do
            table.insert(rtypes, types.tostring(rettype))
          end
        end
        if t.flexrettype then
            table.insert(rtypes, "...: " .. types.tostring(t.flexrettype))
            table.insert(out, ": (")
            table.insert(out, table.concat(rtypes, ", "))
            table.insert(out, ")")
        elseif #rtypes == 1 then
            table.insert(out, ": ")
            table.insert(out, rtypes[1])
        elseif #rtypes > 1 then
            table.insert(out, ": (")
            table.insert(out, table.concat(rtypes, ", "))
            table.insert(out, ")")
        end
        return table.concat(out)
    elseif tag == "Type.Record" or tag == "Type.Union"
       or tag == "Type.Interface" then
        return t.name .. tostring_typeparams(t.typeparams)
    elseif tag == "Type.Variant" then
        return t.fqtn .. "." .. t.name
    elseif tag == "Type.Nominal" then
        local args = t.args or {}
        if #args == 0 then return t.fqtn end
        return t.fqtn .. "<" .. tostring_list(args) .. ">"
    elseif tag == "Type.Option" then
        return types.tostring(t.base, true) .. "?"
    elseif tag == "Type.CVoid" then
        return "void"
    elseif tag == "Type.CInteger" then
        if t.spelling == "_Bool" then return "bool" end
        return t.spelling
    elseif tag == "Type.CFloat" then
        if t.spelling == "float" then return "foreign float" end
        return t.spelling
    elseif tag == "Type.CPointer" then
        local quals = t.quals and #t.quals > 0
            and table.concat(t.quals, " ")
        local base = "*" .. types.tostring(t.pointee, true)
        if quals then
          if wrap then
            return "(" .. quals .. " " .. base .. ")"
          else
            return quals .. " " .. base
          end
        else
          return base
        end
    elseif tag == "Type.CArray" then
        local len = t.len and tostring(t.len) or ""
        local quals = t.quals and #t.quals > 0
            and table.concat(t.quals, " ")
        local base = types.tostring(t.elem, true) .. "[" .. len .. "]"
        if quals then
          if wrap then
            return "(" .. quals .. " " .. base .. ")"
          else
            return quals .. " " .. base
          end
        else
          return base
        end
    elseif tag == "Type.CFunction" then
        local params = {}
        local rendered_params = tostring_list(t.params)
        if rendered_params ~= "" then
            table.insert(params, rendered_params)
        end
        if t.vararg then
            table.insert(params, "...")
        end
        local res = "foreign " .. " (" .. table.concat(params, ", ") .. ")" .. " -> " .. types.tostring(t.ret, true)
        if wrap then
            return "(" .. res .. ")"
        else
            return res
        end
    elseif tag == "Type.CStruct" then
        if types.is_c_lua_state(t) then
            return "lua_State"
        end
        local display_name = c_display_name(t.tagname or t.cname or t.typedef)
        if t._ffi_scope and display_name then
          return t._ffi_scope .. "." .. display_name
        else
          local wrap_left = wrap and "(" or ""
          local wrap_right = wrap and ")" or ""
          return wrap_left .. "struct " .. (display_name or "<anonymous>") .. wrap_right
        end
    elseif tag == "Type.CUnion" then
        local display_name = c_display_name(t.tagname or t.cname or t.typedef)
        if t._ffi_scope and display_name then
          return t._ffi_scope .. "." .. display_name
        else
          local wrap_left = wrap and "(" or ""
          local wrap_right = wrap and ")" or ""
          return wrap_left .. "union " .. (display_name or "<anonymous>") .. wrap_right
        end
    elseif tag == "Type.CField" then
        return t.name .. ": " .. types.tostring(t.type)
    elseif tag == "Type.CTypedef" then
        if t._ffi_scope then
          return t._ffi_scope .. "." .. t.name
        else
          -- avoid accidentaly aliasing Titan type
          return "foreign " .. t.name
        end
    elseif tag == "Type.COwned" then
        if t.count then
            return "owned " .. types.tostring(t.pointee, true) .. "[]"
        end
        return "owned *" .. types.tostring(t.pointee, true)
    elseif tag == "Type.CModule" then
        return "C module " .. t.name
    else
        error("impossible: " .. tostring(tag))
    end
end

-- Build the public view serialized for a source union. Keeping this projection
-- in one helper lets the checker prove the variant/constructor locality pairs
-- against the exact view that serialization emits.
function types.public_union_projection(union)
    assert(union and union._tag == "Type.Union")
    local variants, functions, methods = {}, {}, {}
    for _, variant in ipairs(union.variants) do
        if not variant.islocal then
            variants[#variants + 1] = variant
            variants[variant.name] = variant
        end
    end
    for name, fn in pairs(union.functions) do
        if not fn.islocal then functions[name] = fn end
    end
    for name, method in pairs(union.methods) do
        if not method.islocal then methods[name] = method end
    end
    return {
        variants = variants,
        functions = functions,
        methods = methods,
    }
end

-- Validate the full source descriptor before it loses locality metadata. A
-- decoder cannot reconstruct hidden variants, so this proof belongs on the
-- producer side rather than in recovered-interface validation.
function types.validate_union_source_projection(union)
    if not union or union._tag ~= "Type.Union" then
        return nil, "descriptor is not a union"
    end
    local projection = types.public_union_projection(union)
    for _, variant in ipairs(union.variants) do
        local constructor = union.functions[variant.name]
        if not constructor
           or constructor._tag ~= "Type.StaticMethod"
           or constructor.fqtn ~= union.name
           or constructor.name ~= variant.name
           or constructor.varargtype ~= false
           or constructor.flexrettype ~= false
           or constructor.paramnames ~= false
           or #constructor.rettypes ~= 1
           or constructor.rettypes[1]._tag ~= "Type.Nominal"
           or constructor.rettypes[1].fqtn ~= union.name then
            return nil, "variant '" .. variant.name ..
                "' has no matching constructor"
        end
        if variant.payload == false then
            if #constructor.params ~= 0 then
                return nil, "empty variant '" .. variant.name ..
                    "' has a payload constructor"
            end
        elseif #constructor.params ~= 1
               or not types.equals(
                   constructor.params[1], variant.payload) then
            return nil, "payload variant '" .. variant.name ..
                "' has a mismatched constructor"
        end

        local expected_local =
            (union.islocal or variant.islocal) and true or false
        if (constructor.islocal and true or false) ~= expected_local then
            return nil, "variant '" .. variant.name ..
                "' and its constructor disagree on locality"
        end
        local projected_variant =
            projection.variants[variant.name] == variant
        local projected_constructor =
            projection.functions[variant.name] == constructor
        if projected_variant ~= not expected_local
           or projected_constructor ~= not expected_local then
            return nil, "variant '" .. variant.name ..
                "' was not projected with its constructor"
        end
    end
    if union.islocal then
        for name, fn in pairs(union.functions) do
            if not fn.islocal then
                return nil, "local union publishes function '" .. name .. "'"
            end
        end
        for name, method in pairs(union.methods) do
            if not method.islocal then
                return nil, "local union publishes method '" .. name .. "'"
            end
        end
    end
    return projection
end

local function serialize_literal(value)
    if value == false or value == nil then return "false" end
    if value == true then return "true" end
    if type(value) == "string" then return string.format("%q", value) end
    error("cannot serialize generic metadata literal " .. tostring(value), 3)
end

local function serialize_type_list(list, seen_ctypes)
    local out = {}
    for _, typ in ipairs(list or {}) do
        out[#out + 1] = types.serialize(typ, seen_ctypes)
    end
    return "{" .. table.concat(out, ",") .. "}"
end

local function serialize_generic_tail(scope, typeparams)
    if scope == false and #(typeparams or {}) == 0 then return "" end
    return "," .. types.serialize(scope) .. "," ..
        serialize_type_list(typeparams)
end

function types.serialize(t, seen_ctypes)
    seen_ctypes = seen_ctypes or {}
    local tag = t._tag

    if tag == "Type.GenericScope" then
        return "GenericScope(" ..
            serialize_literal(t.modname) .. "," ..
            serialize_literal(t.owner_fqtn) .. "," ..
            serialize_literal(t.callable_name) .. "," ..
            serialize_literal(t.role) .. "," ..
            serialize_literal(t.declaration_kind) .. ")"
    elseif tag == "Type.TypeParameter" then
        return "TypeParameter(" .. string.format("%q", t.name) .. "," ..
            (t.constraint == false and "false"
                or types.serialize(t.constraint)) .. ")"
    elseif tag == "Type.Parameter" then
        return "Parameter(" .. types.serialize(t.scope) .. "," ..
            tostring(t.index) .. "," ..
            string.format("%q", t.diagnostic_name) .. "," ..
            (t.erased_constraint == false and "false"
                or types.serialize(t.erased_constraint)) .. ")"
    elseif tag == "Type.FunctionScheme" then
        return "FunctionScheme(" .. types.serialize(t.scope) .. "," ..
            serialize_type_list(t.typeparams) .. "," ..
            types.serialize(t.signature) .. ")"
    elseif tag == "Type.GenericAlias" then
        return "GenericAlias(" .. string.format("%q", t.module) .. "," ..
            string.format("%q", t.name) .. "," ..
            serialize_literal(t.locality) .. "," ..
            string.format("%q", t.target_owner_fqtn) .. "," ..
            serialize_literal(t.target_alias_fqtn) .. "," ..
            types.serialize(t.target_scope) .. "," ..
            serialize_type_list(t.typeparams) .. ")"
    elseif tag == "Type.Array" then
        local const_repr
        if t.isconst == "maybe" then
            const_repr = '"maybe"'
        elseif type(t.isconst) == "boolean" then
            const_repr = tostring(t.isconst)
        else
            error("cannot serialize malformed Array const qualifier")
        end
        return "Array(" .. types.serialize(t.elem) .. "," .. const_repr .. ")"
    elseif tag == "Type.Map" then
        return "Map(" .. types.serialize(t.keys) .. ", " .. types.serialize(t.values) .. ")"
    elseif tag == "Type.ModuleMember" then
        return "ModuleMember('" .. t.modname .. "', '" ..
            t.name .. "', " .. types.serialize(t.type) .. ", " ..
            serialize_names(t.paramnames) .. ")"
    elseif tag == "Type.ModuleVariable" then
        if type(t.isconst) ~= "boolean" then
            error("cannot serialize malformed ModuleVariable const qualifier")
        end
        return "ModuleVariable('" .. t.modname .. "', '" ..
            t.name .. "', " .. types.serialize(t.type) .. ", " ..
            tostring(t.isconst) .. ")"
    elseif tag == "Type.Module" then
        local members = {}
        for _, member in ipairs(t.members) do
            table.insert(members, types.serialize(member))
        end
        local type_member_names = {}
        for name in pairs(t.type_members or {}) do
            table.insert(type_member_names, name)
        end
        table.sort(type_member_names, util.bytewise_less)
        local type_members = {}
        for _, name in ipairs(type_member_names) do
            table.insert(type_members,
                "[" .. string.format("%q", name) .. "] = " ..
                types.serialize(t.type_members[name]))
        end
        return "Module(" ..
            "'" .. t.name .. "'" .. "," ..
            "{" .. table.concat(members, ",") .. "}" ..
            ",{" .. table.concat(type_members, ",") .. "}" ..
            ")"
    elseif tag == "Type.Function" then
        if t.vararg ~= false then
            error("Type.Function reserved vararg field must be false")
        end
        local ptypes = {}
        for _, pt in ipairs(t.params) do
            table.insert(ptypes, types.serialize(pt))
        end
        local rettypes = {}
        for _, rt in ipairs(t.rettypes) do
            table.insert(rettypes, types.serialize(rt))
        end
        return "Function(" ..
            "{" .. table.concat(ptypes, ",") .. "}" .. "," ..
            "{" .. table.concat(rettypes, ",") .. "}" .. "," ..
            "false," ..
            (t.varargtype and types.serialize(t.varargtype) or "false") .. "," ..
            (t.flexrettype and types.serialize(t.flexrettype) or "false") .. ")"
    elseif tag == "Type.Nominal" then
        local args = t.args or {}
        if #args == 0 then
            return "Nominal('" .. t.fqtn .. "')"
        end
        return "Nominal(" .. string.format("%q", t.fqtn) .. "," ..
            serialize_type_list(args, seen_ctypes) .. ")"
    elseif tag == "Type.Field" then
        if type(t.isconst) ~= "boolean" then
            error("cannot serialize malformed Field const qualifier")
        end
        return "Field('" .. t.fqtn .. "', '" ..
             t.name .. "', " .. types.serialize(t.type) ..
             ", " .. tostring(t.index) .. ", " ..
             tostring(t.isconst) .. ")"
    elseif tag == "Type.Variant" then
        return "Variant('" .. t.fqtn .. "', '" .. t.name .. "', " ..
            (t.payload == false and "false"
                or types.serialize(t.payload)) .. ", " ..
            tostring(t.index) .. ")"
    elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
        local ptypes = {}
        for _, pt in ipairs(t.params) do
            table.insert(ptypes, types.serialize(pt))
        end
        local rettypes = {}
        for _, rt in ipairs(t.rettypes) do
            table.insert(rettypes, types.serialize(rt))
        end
        return (tag == "Type.Method" and "Method('" or "StaticMethod('") ..
            t.fqtn .. "', '" .. t.name .. "'," ..
            "{" .. table.concat(ptypes, ",") .. "}" .. "," ..
            "{" .. table.concat(rettypes, ",") .. "}," ..
            (t.varargtype and types.serialize(t.varargtype) or "false") .. "," ..
            (t.flexrettype and types.serialize(t.flexrettype) or "false") .. "," ..
            serialize_names(t.paramnames) ..
            serialize_generic_tail(t.scope, t.typeparams) .. ")"
    elseif tag == "Type.Record" then
        local functions, fields, methods = {}, {}, {}
        for _, field in ipairs(t.fields) do
            if not field.islocal then
                table.insert(fields, types.serialize(field))
            end
        end
        local method_names = {}
        for name in pairs(t.methods) do
            table.insert(method_names, name)
        end
        table.sort(method_names, util.bytewise_less)
        for _, name in ipairs(method_names) do
            local method = t.methods[name]
            if not method.islocal then
                table.insert(methods, name .. " = " .. types.serialize(method))
            end
        end
        local function_names = {}
        for name in pairs(t.functions) do
            table.insert(function_names, name)
        end
        table.sort(function_names, util.bytewise_less)
        for _, name in ipairs(function_names) do
            local func = t.functions[name]
            if not func.islocal then
                table.insert(functions, name .. " = " .. types.serialize(func))
            end
        end
        return "Record('" .. t.name ..
            "',{" .. table.concat(fields, ",") ..
            "},{" ..table.concat(functions, ",") .. "}" .. "," ..
            "{" .. table.concat(methods, ",") .. "}" .. "," ..
            tostring(t.nfields or #t.fields) ..
            serialize_generic_tail(t.scope, t.typeparams) ..
            ")"
    elseif tag == "Type.Union" then
        local functions, variants, methods = {}, {}, {}
        local public = types.public_union_projection(t)
        for _, variant in ipairs(public.variants) do
            table.insert(variants, types.serialize(variant))
        end
        local method_names = {}
        for name in pairs(public.methods) do
            table.insert(method_names, name)
        end
        table.sort(method_names, util.bytewise_less)
        for _, name in ipairs(method_names) do
            local method = public.methods[name]
            table.insert(methods,
                "[" .. string.format("%q", name) .. "] = " ..
                types.serialize(method))
        end
        local function_names = {}
        for name in pairs(public.functions) do
            table.insert(function_names, name)
        end
        table.sort(function_names, util.bytewise_less)
        for _, name in ipairs(function_names) do
            local func = public.functions[name]
            table.insert(functions,
                "[" .. string.format("%q", name) .. "] = " ..
                types.serialize(func))
        end
        return "Union(" .. string.format("%q", t.name) ..
            ",{" .. table.concat(variants, ",") ..
            "},{" .. table.concat(functions, ",") .. "}" .. "," ..
            "{" .. table.concat(methods, ",") .. "}" .. "," ..
            tostring(t.nvariants or #t.variants) ..
            serialize_generic_tail(t.scope, t.typeparams) ..
            ")"
    elseif tag == "Type.Interface" then
        local valid, validation_error =
            types.validate_interface_descriptor(t)
        if not valid then
            error("cannot serialize malformed Interface descriptor: " ..
                validation_error)
        end
        local fields, methods = {}, {}
        for _, field in ipairs(t.fields) do
            fields[#fields + 1] = types.serialize(field)
        end
        for _, method in ipairs(t.methods) do
            methods[#methods + 1] = types.serialize(method)
        end
        return "Interface(" .. string.format("%q", t.name) ..
            ",{" .. table.concat(fields, ",") .. "}" ..
            ",{" .. table.concat(methods, ",") .. "}" ..
            serialize_generic_tail(t.scope, t.typeparams) .. ")"
    elseif tag == "Type.Option" then
        return "Option(" .. types.serialize(t.base) .. ")"
    elseif tag == "Type.CVoid" then
        return "CVoid()"
    elseif tag == "Type.CInteger" then
        return "CInteger(" .. string.format("%q", t.spelling) .. "," ..
            tostring(t.signed) .. "," .. tostring(t.rank) .. "," ..
            tostring(t.bits) .. ")"
    elseif tag == "Type.CFloat" then
        return "CFloat(" .. string.format("%q", t.spelling) .. ")"
    elseif tag == "Type.CPointer" then
        return "CPointer(" .. types.serialize(t.pointee, seen_ctypes) .. "," ..
            serialize_names(t.quals) .. ")"
    elseif tag == "Type.CArray" then
        return "CArray(" .. types.serialize(t.elem, seen_ctypes) .. "," ..
            util.tostring(t.len) .. "," ..
            serialize_names(t.quals) .. ")"
    elseif tag == "Type.CFunction" then
        return "CFunction(" .. serialize_type_list(t.params, seen_ctypes) .. "," ..
            types.serialize(t.ret, seen_ctypes) .. "," ..
            tostring(t.vararg or false) .. "," ..
            (t.abi and string.format("%q", t.abi) or "false") .. ")"
    elseif tag == "Type.CStruct" then
        local name = t.cname or t.tagname
        if name then
            local name = "struct@" .. name
            if seen_ctypes[name] then
                return "CNamed(" .. string.format("%q", name) .. ")"
            end
            seen_ctypes[name] = true
        end
        local fields = {}
        for _, field in ipairs(t.fields) do
            table.insert(fields, types.serialize(field, seen_ctypes))
        end
        return "CStruct(" .. serialize_literal(t.cname) .. "," ..
            serialize_literal(t.tagname) .. "," ..
            serialize_literal(t.typedef) .. ",{" ..
            table.concat(fields, ",") .. "}," ..
            tostring(t.complete or false) .. "," ..
            tostring(t.has_fam or false) .. ")"
    elseif tag == "Type.CUnion" then
        local name = t.cname or t.tagname
        if name then
            local name = "union@" .. name
            if seen_ctypes[name] then
                return "CNamed(" .. string.format("%q", name) .. ")"
            end
            seen_ctypes[name] = true
        end
        local fields = {}
        for _, field in ipairs(t.fields) do
            table.insert(fields, types.serialize(field, seen_ctypes))
        end
        return "CUnion(" .. serialize_literal(t.cname) .. "," ..
            serialize_literal(t.tagname) .. "," ..
            serialize_literal(t.typedef) .. ",{" ..
            table.concat(fields, ",") .. "}," ..
            tostring(t.complete or false) .. ")"
    elseif tag == "Type.CField" then
        return "CField(false," ..
            string.format("%q", t.name) .. "," ..
            types.serialize(t.type, seen_ctypes) .. "," ..
            util.tostring(t.bitfield) .. "," ..
            tostring(t.flexible_array or false) .. ")"
    elseif tag == "Type.CTypedef" then
        local name = "typedef@" .. t.name
        if seen_ctypes[name] then
            return "CNamed(" .. string.format("%q", name) .. ")"
        end
        seen_ctypes[name] = true
        return "CTypedef(" .. string.format("%q", t.name) .. "," ..
            types.serialize(t.target, seen_ctypes) .. "," ..
            serialize_names(t.quals) .. ")"
    elseif tag == "Type.COwned" then
        return "COwned(" .. types.serialize(t.pointee, seen_ctypes) .. "," ..
            tostring(t.count) .. ")"
    elseif tag == "Type.CModule" then
        local member_names = {}
        for name in pairs(t.members or {}) do
            table.insert(member_names, name)
        end
        table.sort(member_names, util.bytewise_less)
        local members = {}
        for _, name in ipairs(member_names) do
            table.insert(members,
                "[" .. string.format("%q", name) .. "] = " ..
                types.serialize(t.members[name]))
        end
        local type_member_names = {}
        for name in pairs(t.type_members or {}) do
            table.insert(type_member_names, name)
        end
        table.sort(type_member_names, util.bytewise_less)
        local type_members = {}
        for _, name in ipairs(type_member_names) do
            table.insert(type_members,
                "[" .. string.format("%q", name) .. "] = " ..
                types.serialize(t.type_members[name]))
        end
        return "CModule(" ..
            string.format("%q", t.name) .. "," ..
            "{" .. table.concat(members, ",") .. "}" ..
            ",{" .. table.concat(type_members, ",") .. "}" ..
            ")"
    elseif tag == "Type.Integer"     then return "Integer()"
    elseif tag == "Type.Boolean"     then return "Boolean()"
    elseif tag == "Type.String"      then return "String()"
    elseif tag == "Type.Nil"         then return "Nil()"
    elseif tag == "Type.Void"        then return "Void()"
    elseif tag == "Type.Float"       then return "Float()"
    elseif tag == "Type.Value"       then return "Value()"
    elseif tag == "Type.Invalid"     then return "Invalid()"
    else
        error("invalid tag " .. tag)
    end
end

return types
