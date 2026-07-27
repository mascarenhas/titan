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
        Array       = {"elem"},
        Map         = {"keys", "values"},
        Record      = {"name", "fields", "functions", "methods", "nfields"},
        Nominal     = {"fqtn"},
        Field       = {"fqtn", "name", "type", "index"},
        Method      = {"fqtn", "name", "params", "rettypes", "varargtype", "flexrettype", "paramnames"},
        ModuleMember = {"modname", "name", "type", "paramnames"},
        ModuleVariable = {"modname", "name", "type"},
        StaticMethod = {"fqtn", "name", "params", "rettypes", "varargtype", "flexrettype", "paramnames"},
        Option       = {"base"},
        CVoid        = {},
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

-- Registry for nominal types
-- Keys are canonical FQTNs (fully qualified type names)
-- Values are types
types.registry = {}

local function is_c_tag(tag)
    return type(tag) == "string" and tag:match("^Type%.C") ~= nil
        and tag ~= "Type.CModule"
end

local legacy_c_tags = {
    ["Type.Pointer"] = true,
    ["Type.Typedef"] = true,
    Struct = true,
    Union = true,
}

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

local function find_c_type(t, include_legacy, descend_function_values)
    local function visit_type(typ, seen)
        if type(typ) ~= "table" then
            return nil
        end
        if seen[typ] then
            return nil
        end
        seen[typ] = true

        local tag = typ._tag
        if is_c_tag(tag) or (include_legacy and legacy_c_tags[tag]) then
            return typ
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
        elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
            if typ.islocal then return nil end
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

function types.first_c_ffi_type(t)
    return find_c_type(t, true, true)
end

function types.is_c(t)
    return types.first_c_type(t) ~= nil
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
    return types.first_c_ffi_type(t) ~= nil
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
           tag == "Type.Function" or
           tag == "Type.Array" or
           tag == "Type.Map" or
           tag == "Type.Record" or
           tag == "Type.Interface" or
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

--- Check if two pointer types are different and can be coerced.
local function can_coerce_pointer(source, target)
    if types.equals(source, target) then
        return false
    elseif target.type._tag == "Type.Nil" then
        -- all pointers are convertible to void*
        if source._tag == "Type.String" then
            return true
        elseif source.tag == "Type.Nil" then
            return true
        elseif source._tag == "Type.Pointer" then
            return true
        end
    end
    return false
end

local function is_void_pointer(typ)
    return typ._tag == "Type.Pointer" and typ.type._tag == "Type.Nil"
end

local function resolved_c(t)
    return types.resolve_c_typedef(t)
end

local function is_c_integer(t)
    t = resolved_c(t)
    return t and t._tag == "Type.CInteger"
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
        return c_assignable_equal(source.pointee, target.pointee)
            or resolved_c(target.pointee)._tag == "Type.CVoid"
    end
    return false
end

local function is_c_function_pointer(t)
    t = resolved_c(t)
    return t and t._tag == "Type.CPointer"
        and resolved_c(t.pointee)._tag == "Type.CFunction"
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

    if source._tag == "Type.Value" then
        return target_pointee._tag == "Type.CVoid"
            or types.is_c_tvalue(target_res.pointee)
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

local function c_value_compatible(t)
    t = resolved_c(t)
    return t and (t._tag == "Type.CInteger"
        or t._tag == "Type.CFloat"
        or (t._tag == "Type.CPointer"
            and resolved_c(t.pointee)._tag ~= "Type.CFunction")
        or t._tag == "Type.COwned"
        or types.is_c_tvalue(t))
end

-- Returns true if type always holds truthy values
function types.is_truthy(typ)
    typ = resolved_c(typ)
    local tag = typ._tag
    return tag ~= "Type.Nil" and tag ~= "Type.Value" and tag ~= "Type.Option"
        and tag ~= "Type.Pointer" and tag ~= "Type.Boolean"
        and tag ~= "Type.CPointer"
end

-- Returns true if type always holds falsy values
function types.is_falsy(typ)
    return typ._tag == "Type.Nil"
end

function types.explicitly_coerceable(source, target)
    return (is_void_pointer(source) and target._tag == "Type.String")
        or (is_c_void_pointer(source) and target._tag == "Type.String")
        or (is_c_char_pointer(source) and target._tag == "Type.String")
        or ((is_c_integer(source) or is_c_float(source))
            and (is_c_integer(target) or is_c_float(target)))
        or c_object_to_void_pointer_compatible(source, target)
        or c_void_to_object_pointer_compatible(source, target, true)
end

function types.coerceable(source, target)
    if types.equals(source, target) then
        return false
    elseif is_c_integer(source) and target._tag == "Type.Integer" then
        return true
    elseif source._tag == "Type.Integer" and is_c_integer(target) then
        return true
    elseif is_c_float(source) and target._tag == "Type.Float" then
        return true
    elseif source._tag == "Type.Float" and is_c_float(target) then
        return true
    elseif source._tag == "Type.Integer" and is_c_float(target) then
        return true
    elseif is_c_pointer(source) and target._tag == "Type.Boolean" then
        return true
    elseif source._tag == "Type.Nil" and is_c_pointer(target) then
        return true
    elseif types.c_address_coerceable(source, target) then
        return true
    elseif c_pointer_compatible(source, target) then
        return true
    elseif c_object_to_void_pointer_compatible(source, target) then
        return true
    elseif c_void_to_object_pointer_compatible(source, target, false) then
        return true
    elseif source._tag == "Type.String" and
           (is_c_char_pointer(target) or is_c_void_pointer(target)) then
        return true
    elseif c_value_compatible(source) and target._tag == "Type.Value" then
        return true
    elseif source._tag == "Type.Value" and c_value_compatible(target) then
        return true
    elseif c_value_compatible(source) and types.is_c_tvalue(target) then
        return true
    elseif types.is_c_tvalue(target) and not types.is_c(source) then
        return true
    elseif types.is_c(source) or types.is_c(target) then
        return false
    end

    return (target._tag == "Type.Pointer" and
            can_coerce_pointer(source, target)) or

           (source._tag == "Type.Integer" and
            target._tag == "Type.Float") or

           (source._tag == "Type.Float" and
            target._tag == "Type.Integer") or

           (target._tag == "Type.Boolean" and
            source._tag ~= "Type.Boolean") or

           (target._tag == "Type.Value" and
            source._tag ~= "Type.Value") or

           (source._tag == "Type.Value" and
            target._tag ~= "Type.Value") or

           (target._tag == "Type.Option" and
            types.equals(source, target.base)) or

           (source._tag == "Type.Option" and
            types.equals(target, source.base)) or

           (target._tag == "Type.Option" and
            source._tag == "Type.Nil") or

           -- t1? -> t2? whenever t1 is coerceable to t2: the conversion
           -- propagates nil and converts/re-wraps a present value (see the
           -- option-to-option case in trycoerce and the coder's ExpCast).
           (target._tag == "Type.Option" and
            source._tag == "Type.Option" and
            types.coerceable(source.base, target.base)) or

           (target._tag == "Type.Option" and
            source._tag ~= "Type.Option" and
            types.coerceable(source, target.base)) or

           (source._tag == "Type.Option" and
            target._tag ~= "Type.Option" and
            types.coerceable(source.base, target))

end

local function optional_result_type(t)
    if t._tag == "Type.Option" or t._tag == "Type.Value" then
        return t
    end
    return types.Option(t)
end

-- Directional function compatibility. `expected` is the static callable type
-- that controls future calls; `actual` is the value being stored there.
-- Component values use the same compatibility/coercion boundary as ordinary
-- checker slots. Parameter positions reverse the direction; result positions
-- preserve it.
local function slot_compatible(target, source)
    return types.compatible(target, source)
        or types.coerceable(source, target)
end

local function function_compatible(expected, actual)
    -- `vararg` is the untyped C-FFI variadic bit. C call shapes remain strict;
    -- exact equality was handled before reaching this helper.
    if expected.vararg or actual.vararg then
        return false
    end

    for i = 1, math.min(#actual.params, #expected.params) do
        if not slot_compatible(actual.params[i], expected.params[i]) then
            return false
        end
    end

    -- Calls through a shorter expected fixed prefix adjust omitted arguments
    -- upward with nil. If the expected type also has an input tail, each extra
    -- actual fixed slot can instead receive one of its elements. The actual
    -- slot must therefore accept every value that adjustment can place there.
    for i = #expected.params + 1, #actual.params do
        if not slot_compatible(actual.params[i], types.Nil()) then
            return false
        end
        if expected.varargtype
           and not slot_compatible(actual.params[i],
                                   expected.varargtype) then
            return false
        end
    end

    -- A shorter fixed actual ignores the expected suffix. A shorter variadic
    -- actual observes that suffix, so validate each moved fixed value and the
    -- expected tail against the actual input element type.
    if actual.varargtype then
        for i = #actual.params + 1, #expected.params do
            if not slot_compatible(actual.varargtype, expected.params[i]) then
                return false
            end
        end
        if expected.varargtype
           and not slot_compatible(actual.varargtype,
                                   expected.varargtype) then
            return false
        end
    end

    -- Expected fixed results are covariant. An actual flexible tail supplies
    -- optional finite projections. A non-option expected slot may also accept
    -- the raw tail type: an absent result is nil-padded at the generic boundary
    -- and fails through the normal runtime unwrap.
    for i = 1, #expected.rettypes do
        local produced = actual.rettypes[i]
        if produced then
            if not slot_compatible(expected.rettypes[i], produced) then
                return false
            end
        elseif actual.flexrettype then
            local projected = optional_result_type(actual.flexrettype)
            if not slot_compatible(expected.rettypes[i], projected)
               and not slot_compatible(expected.rettypes[i],
                                       actual.flexrettype) then
                return false
            end
        else
            return false
        end
    end

    -- A finite expected type hides all additional actual results. An open
    -- expected tail observes every remaining fixed result and the actual tail,
    -- if one exists; a fixed-only actual may simply end.
    if expected.flexrettype then
        for i = #expected.rettypes + 1, #actual.rettypes do
            if not slot_compatible(expected.flexrettype,
                                   actual.rettypes[i]) then
                return false
            end
        end
        if actual.flexrettype
           and not slot_compatible(expected.flexrettype,
                                   actual.flexrettype) then
            return false
        end
    end

    return true
end

-- The type consistency relation, a-la gradual typing. Its argument order is
-- directional: `t1` is expected and `t2` is found.
function types.compatible(t1, t2)
    if types.equals(t1, t2) then
        return true
    elseif t1._tag == "Type.CTypedef" then
        return types.compatible(types.resolve_c_typedef(t1), t2)
    elseif t2._tag == "Type.CTypedef" then
        return types.compatible(t1, types.resolve_c_typedef(t2))
    elseif is_c_integer(t1) and t2._tag == "Type.Integer" then
        return true
    elseif t1._tag == "Type.Integer" and is_c_integer(t2) then
        return true
    elseif is_c_float(t1) and t2._tag == "Type.Float" then
        return true
    elseif t1._tag == "Type.Float" and is_c_float(t2) then
        return true
    elseif t1._tag == "Type.Integer" and is_c_float(t2) then
        return true
    elseif is_c_pointer(t1) and t2._tag == "Type.Boolean" then
        return true
    elseif t1._tag == "Type.Nil" and is_c_pointer(t2) then
        return true
    elseif types.c_address_coerceable(t1, t2) then
        return true
    elseif c_pointer_compatible(t1, t2) then
        return true
    elseif c_object_to_void_pointer_compatible(t1, t2) then
        return true
    elseif c_object_to_void_pointer_compatible(t2, t1) then
        return true
    elseif c_void_to_object_pointer_compatible(t1, t2, true) then
        return true
    elseif c_void_to_object_pointer_compatible(t2, t1, true) then
        return true
    elseif t1._tag == "Type.String" and
           (is_c_char_pointer(t2) or is_c_void_pointer(t2)) then
        return true
    elseif c_value_compatible(t1) and t2._tag == "Type.Value" then
        return true
    elseif t1._tag == "Type.Value" and c_value_compatible(t2) then
        return true
    elseif c_value_compatible(t1) and types.is_c_tvalue(t2) then
        return true
    elseif types.is_c_tvalue(t2) and not types.is_c(t1) then
        return true
    elseif t1._tag == "Type.Typedef" then
        return types.compatible(t1._type, t2)
    elseif t2._tag == "Type.Typedef" then
        return types.compatible(t1, t2._type)
    elseif t1._tag == "Type.CPointer" and t2._tag == "Type.Nil" then
        return true
    elseif t1._tag == "Type.Nil" and t2._tag == "Type.CPointer" then
        return true
    elseif types.is_c(t1) or types.is_c(t2) then
        return false
    elseif t1._tag == "Type.Pointer" and t2._tag == "Type.Nil" then
        return true -- nullable pointer
    elseif t1._tag == "Type.Nil" and t2._tag == "Type.Pointer" then
        return true -- nullable pointer
    elseif types.explicitly_coerceable(t1, t2) then
        return true
    elseif t1._tag == "Type.Value" or t2._tag == "Type.Value" then
        return true
    elseif t1._tag == "Type.Array" and t2._tag == "Type.Array" then
        return types.compatible(t1.elem, t2.elem)
    elseif t1._tag == "Type.Map" and t2._tag == "Type.Map" then
        return types.compatible(t1.keys, t2.keys) and
               types.compatible(t1.values, t2.values)
    elseif t1._tag == "Type.Nominal" and t2._tag == "Type.Nominal" then
        return t1.fqtn == t2.fqtn
    elseif t1._tag == "Type.Function" and t2._tag == "Type.Function" then
        return function_compatible(t1, t2)
    else
        return false
    end
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
        -- File/prototype-scope tag binding and the conditional-header
        -- baseline canonicalize compatible aggregate identities before value
        -- compatibility reaches this relation.
        return ltype == rtype
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

-- Compare the callable ABI shape shared by ordinary function values and
-- declaration descriptors for methods/record functions. `vararg` is the
-- foreign-C variadic flag and exists only on Type.Function; the typed Titan
-- input/output tails are present on all three shapes. Declaration-only
-- parameter names deliberately stay outside exact type identity.
local function callable_shape_equals(t1, t2, seen, compare_c_vararg)
    local exact_c_signature =
        compare_c_vararg and t1._c_function and t2._c_function
    if exact_c_signature then
        -- Foreign functions retain their declaration carrier because Titan's
        -- projected result list cannot represent a qualified void return and
        -- nominal typedef spellings can obscure otherwise equal C signatures.
        if not c_function_type_equals(
                t1._c_function, t2._c_function, seen) then
            return false
        end
    else
        if compare_c_vararg and t1.vararg ~= t2.vararg then
            return false
        end
        if not same_list(t1.params, t2.params, seen)
           or not same_list(t1.rettypes, t2.rettypes, seen) then
            return false
        end
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

    if tag1 == "Type.Array" then
        return type_equals(t1.elem, t2.elem, seen)
    elseif tag1 == "Type.Map" then
        return type_equals(t1.keys, t2.keys, seen) and
               type_equals(t1.values, t2.values, seen)
    elseif tag1 == "Type.Pointer" then
        return type_equals(t1.type, t2.type, seen)
    elseif tag1 == "Type.Typedef" then
        return t1.name == t2.name
    elseif tag1 == "Type.CInteger" then
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
        -- Typed input/output tails are part of the exact runtime function tag;
        -- differing tail element types must therefore fall back from the
        -- first-class native path.
        return callable_shape_equals(t1, t2, seen, true)
    elseif tag1 == "Type.Method" or tag1 == "Type.StaticMethod" then
        return t1.fqtn == t2.fqtn
           and t1.name == t2.name
           and callable_shape_equals(t1, t2, seen, false)
    elseif tag1 == "Type.Nominal" then
        return t1.fqtn == t2.fqtn
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

function types.tostring(t)
    local tag = t._tag
    if     tag == "Type.Integer"     then return "integer"
    elseif tag == "Type.Boolean"     then return "boolean"
    elseif tag == "Type.String"      then return "string"
    elseif tag == "Type.Nil"         then return "nil"
    elseif tag == "Type.Void"        then return "()"
    elseif tag == "Type.Float"       then return "float"
    elseif tag == "Type.Value"       then return "value"
    elseif tag == "Type.Invalid"     then return "invalid type"
    elseif tag == "Type.Array" then
        return "{ " .. types.tostring(t.elem) .. " }"
    elseif tag == "Type.Map" then
        return "{ " .. types.tostring(t.keys) .. " : " .. types.tostring(t.values) .. " }"
    elseif tag == "Type.Pointer" then
        if is_void_pointer(t) then
            return "void pointer"
        else
            return "pointer to " .. types.tostring(t.type)
        end
    elseif tag == "Type.Typedef" then
        return t.name
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
        local c_return_qualifiers =
            t._return_declaration_qualifiers
            and #t._return_declaration_qualifiers > 0
            and table.concat(
                t._return_declaration_qualifiers, " ") .. " "
            or ""
        for index, rettype in ipairs(t.rettypes) do
            table.insert(rtypes,
                (index == 1 and c_return_qualifiers or "")
                    .. types.tostring(rettype))
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
        elseif c_return_qualifiers ~= ""
           and t._c_return_type then
            -- Titan projects C void to zero results. Retain its declaration
            -- qualification in diagnostics even though call semantics stay
            -- the ordinary zero-result shape.
            table.insert(out, " -> ")
            table.insert(out, c_return_qualifiers)
            table.insert(out, types.tostring(t._c_return_type))
        else
            -- zero return values: canonicalize as `(P...) -> ()`, distinct
            -- from a `nil`-returning function `(P...) -> nil`
            table.insert(out, " -> ()")
        end
        return table.concat(out)
    elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
        local out = {t.fqtn,
             tag == "Type.Method" and ":" or ".",
             t.name, "("}
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
        for _, rettype in ipairs(t.rettypes) do
            table.insert(rtypes, types.tostring(rettype))
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
    elseif tag == "Type.Record" then
        return t.name
    elseif tag == "Type.Nominal" then
        return t.fqtn
    elseif tag == "Type.Option" then
        return types.tostring(t.base) .. "?"
    elseif tag == "Type.CVoid" then
        return "void"
    elseif tag == "Type.CInteger" then
        return t.spelling
    elseif tag == "Type.CFloat" then
        return t.spelling
    elseif tag == "Type.CPointer" then
        local quals = t.quals and #t.quals > 0
            and table.concat(t.quals, " ") .. " " or ""
        return quals .. types.tostring(t.pointee) .. " *"
    elseif tag == "Type.CArray" then
        local len = t.len and tostring(t.len) or ""
        local quals = t.quals and #t.quals > 0
            and table.concat(t.quals, " ") .. " " or ""
        return quals .. types.tostring(t.elem) .. "[" .. len .. "]"
    elseif tag == "Type.CFunction" then
        local params = {}
        local rendered_params = tostring_list(t.params)
        if rendered_params ~= "" then
            table.insert(params, rendered_params)
        end
        if t.vararg then
            table.insert(params, "...")
        end
        local return_qualifiers =
            t._return_declaration_qualifiers
            and #t._return_declaration_qualifiers > 0
            and table.concat(
                t._return_declaration_qualifiers, " ") .. " "
            or ""
        return return_qualifiers .. types.tostring(t.ret)
            .. " (" .. table.concat(params, ", ") .. ")"
    elseif tag == "Type.CStruct" then
        return "struct " .. (c_display_name(t.tagname or t.cname or t.typedef) or "<anonymous>")
    elseif tag == "Type.CUnion" then
        return "union " .. (c_display_name(t.tagname or t.cname or t.typedef) or "<anonymous>")
    elseif tag == "Type.CField" then
        return t.name .. ": " .. types.tostring(t.type)
    elseif tag == "Type.CTypedef" then
        return t.name
    elseif tag == "Type.COwned" then
        return "owned " .. types.tostring(t.pointee)
    elseif tag == "Type.CModule" then
        return "C module " .. t.name
    elseif tag == "Struct" then
        return "struct " .. (t.name or "<anonymous>")
    elseif tag == "Union" then
        return "union " .. (t.name or "<anonymous>")
    else
        error("impossible: " .. tostring(tag))
    end
end

function types.serialize(t)
    local tag = t._tag
    local ctyp = types.first_c_ffi_type(t)
    if ctyp then
        error("cannot serialize C FFI type " .. types.tostring(ctyp))
    end

    if tag == "Type.Array" then
        return "Array(" ..types.serialize(t.elem) .. ")"
    elseif tag == "Type.Map" then
        return "Map(" .. types.serialize(t.keys) .. ", " .. types.serialize(t.values) .. ")"
    elseif tag == "Type.ModuleMember" then
        return "ModuleMember('" .. t.modname .. "', '" ..
            t.name .. "', " .. types.serialize(t.type) .. ", " ..
            serialize_names(t.paramnames) .. ")"
    elseif tag == "Type.ModuleVariable" then
        return "ModuleVariable('" .. t.modname .. "', '" ..
            t.name .. "', " .. types.serialize(t.type) .. ")"
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
            tostring(t.vararg) .. "," ..
            (t.varargtype and types.serialize(t.varargtype) or "false") .. "," ..
            (t.flexrettype and types.serialize(t.flexrettype) or "false") .. ")"
    elseif tag == "Type.Nominal" then
        return "Nominal('" .. t.fqtn .. "')"
    elseif tag == "Type.Field" then
        return "Field('" .. t.fqtn .. "', '" ..
             t.name .. "', " .. types.serialize(t.type) ..
             ", " .. tostring(t.index) .. ")"
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
            serialize_names(t.paramnames) .. ")"
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
            ")"
    elseif tag == "Type.Option" then
        return "Option(" .. types.serialize(t.base) .. ")"
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
