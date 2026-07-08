local typedecl = require 'titan-compiler.typedecl'

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
        Function    = {"params", "rettypes", "vararg", "varargtype"},
        Array       = {"elem"},
        Map         = {"keys", "values"},
        Record      = {"name", "fields", "functions", "methods", "nfields"},
        Nominal     = {"fqtn"},
        Field       = {"fqtn", "name", "type", "index"},
        Method      = {"fqtn", "name", "params", "rettypes", "varargtype"},
        ModuleMember = {"modname", "name", "type"},
        ModuleVariable = {"modname", "name", "type"},
        StaticMethod = {"fqtn", "name", "params", "rettypes", "varargtype"},
        Option       = {"base"},
        CVoid        = {},
        CInteger     = {"spelling", "signed", "rank", "bits"},
        CFloat       = {"spelling"},
        CPointer     = {"pointee", "quals"},
        CArray       = {"elem", "len"},
        CFunction    = {"params", "ret", "vararg", "abi"},
        CStruct      = {"cname", "tagname", "typedef", "fields", "complete", "has_fam"},
        CUnion       = {"cname", "tagname", "typedef", "fields", "complete"},
        CField       = {"owner", "name", "type", "bitfield", "flexible_array"},
        CTypedef     = {"name", "target"},
        COwned       = {"pointee", "count"},
        CModule      = {"name", "members"}
    }
})

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

local function find_c_type(t, include_legacy)
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
            for _, param in ipairs(typ.params) do
                local ctyp = visit_type(param, seen)
                if ctyp then return ctyp end
            end
            for _, ret in ipairs(typ.rettypes) do
                local ctyp = visit_type(ret, seen)
                if ctyp then return ctyp end
            end
            return visit_type(typ.varargtype, seen)
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
            return visit_type(typ.varargtype, seen)
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
    return find_c_type(t, false)
end

function types.first_c_ffi_type(t)
    return find_c_type(t, true)
end

function types.is_c(t)
    return types.first_c_type(t) ~= nil
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
    return tag == "Type.String" or
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
function types.Module(modname, members)
    for _, member in ipairs(members) do
        members[member.name] = member
    end
    return { _tag = "Type.Module", name = modname,
        prefix = modname:gsub("[%-.]", "_") .. "_",
        file = modname:gsub("[.]", "/") .. ".so",
        members = members }
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

local function is_c_object_pointer(t)
    return is_c_pointer(t) and not is_c_function_pointer(t)
end

local function c_assignable_equal(t1, t2)
    return types.equals(resolved_c(t1), resolved_c(t2))
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
    elseif source._tag == "Type.CArray" then
        return c_assignable_equal(source.elem, target.pointee)
            or resolved_c(target.pointee)._tag == "Type.CVoid"
    elseif source._tag == "Type.COwned" then
        return c_assignable_equal(source.pointee, target.pointee)
            or resolved_c(target.pointee)._tag == "Type.CVoid"
    end
    return false
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
        or t._tag == "Type.COwned")
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
        or (is_c_object_pointer(source) and is_c_void_pointer(target))
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
    elseif c_pointer_compatible(source, target) then
        return true
    elseif is_c_object_pointer(source) and is_c_void_pointer(target) then
        return true
    elseif source._tag == "Type.String" and
           (is_c_char_pointer(target) or is_c_void_pointer(target)) then
        return true
    elseif c_value_compatible(source) and target._tag == "Type.Value" then
        return true
    elseif source._tag == "Type.Value" and c_value_compatible(target) then
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

-- The type consistency relation, a-la gradual typing
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
    elseif c_pointer_compatible(t1, t2) then
        return true
    elseif is_c_void_pointer(t1) and is_c_object_pointer(t2) then
        return true
    elseif t1._tag == "Type.String" and
           (is_c_char_pointer(t2) or is_c_void_pointer(t2)) then
        return true
    elseif c_value_compatible(t1) and t2._tag == "Type.Value" then
        return true
    elseif t1._tag == "Type.Value" and c_value_compatible(t2) then
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
        if #t1.params ~= #t2.params then
            return false
        end

        for i = 1, #t1.params do
            if not types.compatible(t1.params[i], t2.params[i]) then
                return false
            end
        end

        if #t1.rettypes ~= #t2.rettypes then
            return false
        end

        for i = 1, #t1.rettypes do
            if not types.compatible(t1.rettypes[i], t2.rettypes[i]) then
                return false
            end
        end

        -- Titan vararg presence must match (a variadic and a non-variadic
        -- function are structurally distinct, never compatible); when both are
        -- Titan-variadic, the element types must be `compatible` (gradual, so
        -- `(integer, ...: integer)` is compatible with `(integer, ...: value)` both
        -- ways via `value`). The C-FFI `vararg` boolean is disjoint and not
        -- part of first-class Titan function compatibility.
        local v1, v2 = t1.varargtype, t2.varargtype
        if (v1 and true) ~= (v2 and true) then
            return false
        end
        if v1 and v2 and not types.compatible(v1, v2) then
            return false
        end

        return true
    else
        return false
    end
end

local type_equals

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
        return type_equals(t1.pointee, t2.pointee, seen) and
               same_value(t1.quals, t2.quals, seen)
    elseif tag1 == "Type.CArray" then
        return t1.len == t2.len and type_equals(t1.elem, t2.elem, seen)
    elseif tag1 == "Type.CFunction" then
        return t1.vararg == t2.vararg and
               t1.abi == t2.abi and
               same_list(t1.params, t2.params, seen) and
               type_equals(t1.ret, t2.ret, seen)
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
        return t1.name == t2.name and type_equals(t1.target, t2.target, seen)
    elseif tag1 == "Type.COwned" then
        return t1.count == t2.count and type_equals(t1.pointee, t2.pointee, seen)
    elseif tag1 == "Type.CModule" then
        return t1.name == t2.name and same_value(t1.members, t2.members, seen)
    elseif tag1 == "Type.Function" then
        if #t1.params ~= #t2.params then
            return false
        end

        for i = 1, #t1.params do
            if not type_equals(t1.params[i], t2.params[i], seen) then
                return false
            end
        end

        if #t1.rettypes ~= #t2.rettypes then
            return false
        end

        for i = 1, #t1.rettypes do
            if not type_equals(t1.rettypes[i], t2.rettypes[i], seen) then
                return false
            end
        end

        -- Same Titan vararg presence rule as `compatible`, but element types are
        -- compared with `equals` (this drives the runtime type tag, so
        -- `...: integer` and `...: value` are NOT equal → different tags → the
        -- first-class fast path correctly falls back to the generic path).
        local v1, v2 = t1.varargtype, t2.varargtype
        if (v1 and true) ~= (v2 and true) then
            return false
        end
        if v1 and v2 and not type_equals(v1, v2, seen) then
            return false
        end

        return true
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
        for _, rettype in ipairs(t.rettypes) do
            table.insert(rtypes, types.tostring(rettype))
        end
        if #rtypes == 1 then
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
        if #rtypes == 1 then
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
        local quals = t.quals and #t.quals > 0 and " " .. table.concat(t.quals, " ") or ""
        return types.tostring(t.pointee) .. " *" .. quals
    elseif tag == "Type.CArray" then
        local len = t.len and tostring(t.len) or ""
        return types.tostring(t.elem) .. "[" .. len .. "]"
    elseif tag == "Type.CFunction" then
        local params = {}
        local rendered_params = tostring_list(t.params)
        if rendered_params ~= "" then
            table.insert(params, rendered_params)
        end
        if t.vararg then
            table.insert(params, "...")
        end
        return types.tostring(t.ret) .. " (" .. table.concat(params, ", ") .. ")"
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
            t.name .. "', " .. types.serialize(t.type) .. ")"
    elseif tag == "Type.ModuleVariable" then
        return "ModuleVariable('" .. t.modname .. "', '" ..
            t.name .. "', " .. types.serialize(t.type) .. ")"
    elseif tag == "Type.Module" then
        local members = {}
        for _, member in ipairs(t.members) do
            table.insert(members, types.serialize(member))
        end
        return "Module(" ..
            "'" .. t.name .. "'" .. "," ..
            "{" .. table.concat(members, ",") .. "}" ..
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
            (t.varargtype and types.serialize(t.varargtype) or "false") .. ")"
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
            (t.varargtype and types.serialize(t.varargtype) or "false") .. ")"
    elseif tag == "Type.Record" then
        local functions, fields, methods = {}, {}, {}
        for _, field in ipairs(t.fields) do
            if not field.islocal then
                table.insert(fields, types.serialize(field))
            end
        end
        for name, method in pairs(t.methods) do
            if not method.islocal then
                table.insert(methods, name .. " = " .. types.serialize(method))
            end
        end
        for name, func in pairs(t.functions) do
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
