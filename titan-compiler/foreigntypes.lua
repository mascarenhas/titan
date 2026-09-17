-- Module to convert c-parser types into Titan checker types.
local foreigntypes = {}

local types = require "titan-compiler.types"
local csemantics = require "titan-compiler.csemantics"
local inspect = require "inspect"

local qualifiers = {
    const = true,
    restrict = true,
    volatile = true,
}

local function c_name(name)
    if type(name) == "table" then
        return table.concat(name, ".")
    end
    return name
end

local function copy_list(xs)
    local out = {}
    for _, x in ipairs(xs or {}) do
        table.insert(out, x)
    end
    return out
end

local function same_qualifiers(left, right)
    local lset, rset = {}, {}
    for _, qualifier in ipairs(left or {}) do lset[qualifier] = true end
    for _, qualifier in ipairs(right or {}) do rset[qualifier] = true end
    for qualifier in pairs(lset) do
        if not rset[qualifier] then return false end
    end
    for qualifier in pairs(rset) do
        if not lset[qualifier] then return false end
    end
    return true
end

local function combined_qualifiers(...)
    local out = {}
    for index = 1, select("#", ...) do
        for _, qualifier in ipairs(select(index, ...) or {}) do
            out[#out + 1] = qualifier
        end
    end
    return out
end

-- A C typedef introduces a user-visible spelling, but declarations that use
-- two different typedef names can still denote the same C type. Preserve the
-- aliases in imported module members and peel them only for this compatibility
-- relation. Qualifiers attached by typedef declarations remain significant.
local function resolve_declaration_typedefs(typ)
    local qualifiers = {}
    local seen = {}
    local chain = {}
    while typ and typ._tag == "Type.CTypedef" do
        if seen[typ] then return nil end
        seen[typ] = true
        chain[#chain + 1] = typ
        for _, qualifier in ipairs(typ.quals or {}) do
            qualifiers[#qualifiers + 1] = qualifier
        end
        typ = typ.target
    end
    return typ, qualifiers, chain
end

local declaration_types_compatible

local function same_declaration_list(left, right, seen,
                                     ignore_outer_qualifiers,
                                     allow_anonymous_aggregate,
                                     allow_oldstyle_prototype,
                                     allow_array_bound_candidate,
                                     allow_prototype_tag_reextraction,
                                     prototype_tag_state)
    if #left ~= #right then return false end
    for index = 1, #left do
        if not declaration_types_compatible(
            left[index], right[index], seen, ignore_outer_qualifiers,
            allow_anonymous_aggregate,
            allow_oldstyle_prototype,
            allow_array_bound_candidate,
            allow_prototype_tag_reextraction,
            prototype_tag_state) then
            return false
        end
    end
    return true
end

local function same_declaration_value(left, right, seen)
    if left == right then return true end
    if type(left) ~= type(right) or type(left) ~= "table" then
        return false
    end
    seen = seen or {}
    local matches = seen[left]
    if matches and matches[right] then return true end
    if not matches then
        matches = {}
        seen[left] = matches
    end
    matches[right] = true
    for key, value in pairs(left) do
        if not same_declaration_value(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function is_anonymous_aggregate(typ)
    return (typ._tag == "Type.CStruct" or typ._tag == "Type.CUnion")
       and typ.cname == nil
       and typ.tagname == nil
       and typ.typedef == nil
end

local function unknown_array_bound(bound)
    return bound == nil or bound == false or bound == ""
end

local function array_bounds_compatible(
        left, right, allow_array_bound_candidate)
    return unknown_array_bound(left)
        or unknown_array_bound(right)
        or same_declaration_value(left, right)
        or allow_array_bound_candidate
end

local function anonymous_aggregates_compatible(
        left, right, seen, allow_oldstyle_prototype,
        allow_array_bound_candidate,
        allow_prototype_tag_reextraction,
        prototype_tag_state)
    if not is_anonymous_aggregate(left)
       or not is_anonymous_aggregate(right)
       or left.complete ~= right.complete
       or left.has_fam ~= right.has_fam
       or #(left.fields or {}) ~= #(right.fields or {}) then
        return false
    end
    for index, lfield in ipairs(left.fields or {}) do
        local rfield = right.fields[index]
        if not rfield
           or lfield.name ~= rfield.name
           or not same_declaration_value(
                lfield.bitfield, rfield.bitfield)
           or lfield.flexible_array ~= rfield.flexible_array
           or not declaration_types_compatible(
                lfield.type, rfield.type, seen, false, true,
                allow_oldstyle_prototype,
                allow_array_bound_candidate,
                allow_prototype_tag_reextraction,
                prototype_tag_state) then
            return false
        end
    end
    return true
end

-- Independently extracted declarations allocate a fresh canonical object for
-- each prototype-local struct/union tag. Two such objects may represent the
-- same guarded physical declaration, but this exception must not weaken C's
-- ordinary nominal tag identity. Require explicit prototype-scope metadata and
-- compare the complete aggregate graph exactly; the caller separately proves
-- that the enclosing declarations have the same physical source location.
local function prototype_tag_reextractions_compatible(
        left, right, seen, prototype_tag_state)
    if left._c_tag_scope ~= "prototype"
       or right._c_tag_scope ~= "prototype"
       or left.tagname == nil
       or left.tagname ~= right.tagname
       or left.cname ~= right.cname
       or left.typedef ~= right.typedef
       or left.complete ~= right.complete
       or left.has_fam ~= right.has_fam
       or #(left.fields or {}) ~= #(right.fields or {}) then
        return false
    end

    local mapped_right = prototype_tag_state.left_to_right[left]
    local mapped_left = prototype_tag_state.right_to_left[right]
    if (mapped_right ~= nil and mapped_right ~= right)
       or (mapped_left ~= nil and mapped_left ~= left) then
        return false
    end
    prototype_tag_state.left_to_right[left] = right
    prototype_tag_state.right_to_left[right] = left
    prototype_tag_state.matched = true
    for index, lfield in ipairs(left.fields or {}) do
        local rfield = right.fields[index]
        if not rfield
           or lfield.name ~= rfield.name
           or not same_declaration_value(
                lfield.bitfield, rfield.bitfield)
           or lfield.flexible_array ~= rfield.flexible_array
           or not declaration_types_compatible(
                lfield.type, rfield.type, seen, false,
                false, false, false, true,
                prototype_tag_state) then
            return false
        end
    end
    return true
end

local function function_returns_compatible(
        left, right, left_qualifiers, right_qualifiers, seen,
        allow_anonymous_aggregate, allow_oldstyle_prototype,
        allow_array_bound_candidate,
        allow_prototype_tag_reextraction,
        prototype_tag_state)
    local _, lalias_quals =
        resolve_declaration_typedefs(left)
    local _, ralias_quals =
        resolve_declaration_typedefs(right)
    return same_qualifiers(
            combined_qualifiers(left_qualifiers, lalias_quals),
            combined_qualifiers(right_qualifiers, ralias_quals))
       and declaration_types_compatible(
            left, right, seen, true,
            allow_anonymous_aggregate,
            allow_oldstyle_prototype,
            allow_array_bound_candidate,
            allow_prototype_tag_reextraction,
            prototype_tag_state)
end

local function function_paramstyle(typ)
    return typ._paramstyle or "prototype"
end

local function oldstyle_prototype_candidate(left, right)
    local left_style = function_paramstyle(left)
    local right_style = function_paramstyle(right)
    if left_style == right_style then return false end
    local oldstyle = left_style == "oldstyle"
        and left or right_style == "oldstyle"
        and right
    local prototype = left_style == "prototype"
        and left or right_style == "prototype"
        and right
    return oldstyle and prototype
       and #(oldstyle.params or {}) == 0
       and not oldstyle.vararg
       and not prototype.vararg
end

-- Exact compatibility for two declarations of one C ordinary identifier.
-- This is deliberately narrower than Titan's assignment compatibility:
-- integer promotions, void-pointer conversions, and unsafe pointer probes do
-- not make two declarations compatible. Named aggregates remain nominal and
-- therefore compare only through the canonical object interned by the tag
-- registry.
declaration_types_compatible = function(left, right, seen,
                                        ignore_outer_qualifiers,
                                        allow_anonymous_aggregate,
                                        allow_oldstyle_prototype,
                                        allow_array_bound_candidate,
                                        allow_prototype_tag_reextraction,
                                        prototype_tag_state)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local ltype, lquals =
        resolve_declaration_typedefs(left)
    local rtype, rquals =
        resolve_declaration_typedefs(right)
    if not ltype or not rtype then return false end
    if not ignore_outer_qualifiers
       and ltype._tag ~= "Type.CArray"
       and rtype._tag ~= "Type.CArray"
       and not same_qualifiers(lquals, rquals) then
        return false
    end
    if ltype == rtype and ltype._tag ~= "Type.CArray" then
        return true
    end
    if ltype._tag ~= rtype._tag then return false end

    seen = seen or {}
    local matches = seen[ltype]
    if matches and matches[rtype] then return true end
    if not matches then
        matches = {}
        seen[ltype] = matches
    end
    matches[rtype] = true

    local tag = ltype._tag
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
        local _, lpointee_quals =
            resolve_declaration_typedefs(ltype.pointee)
        local _, rpointee_quals =
            resolve_declaration_typedefs(rtype.pointee)
        return same_qualifiers(
                combined_qualifiers(ltype.quals, lpointee_quals),
                combined_qualifiers(rtype.quals, rpointee_quals))
           and declaration_types_compatible(
                ltype.pointee, rtype.pointee, seen, true,
                allow_anonymous_aggregate,
                allow_oldstyle_prototype,
                allow_array_bound_candidate,
                allow_prototype_tag_reextraction,
                prototype_tag_state)
    elseif tag == "Type.CArray" then
        local _, lelem_quals =
            resolve_declaration_typedefs(ltype.elem)
        local _, relem_quals =
            resolve_declaration_typedefs(rtype.elem)
        return array_bounds_compatible(
                ltype.len, rtype.len, allow_array_bound_candidate)
           and same_qualifiers(
                combined_qualifiers(
                    lquals, ltype.quals, lelem_quals),
                combined_qualifiers(
                    rquals, rtype.quals, relem_quals))
           and declaration_types_compatible(
                ltype.elem, rtype.elem, seen, true,
                allow_anonymous_aggregate,
                allow_oldstyle_prototype,
                allow_array_bound_candidate,
                allow_prototype_tag_reextraction,
                prototype_tag_state)
    elseif tag == "Type.CFunction" then
        local oldstyle_candidate =
            oldstyle_prototype_candidate(ltype, rtype)
        local params_compatible =
            function_paramstyle(ltype)
                == function_paramstyle(rtype)
            and ltype.vararg == rtype.vararg
            and same_declaration_list(
                ltype.params, rtype.params, seen, true,
                allow_anonymous_aggregate,
                allow_oldstyle_prototype,
                allow_array_bound_candidate,
                allow_prototype_tag_reextraction,
                prototype_tag_state)
            or allow_oldstyle_prototype
                and oldstyle_candidate
        return params_compatible
           and ltype.abi == rtype.abi
           and function_returns_compatible(
                ltype.ret, rtype.ret,
                ltype._return_declaration_qualifiers,
                rtype._return_declaration_qualifiers, seen,
                allow_anonymous_aggregate,
                allow_oldstyle_prototype,
                allow_array_bound_candidate,
                allow_prototype_tag_reextraction,
                prototype_tag_state)
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        if allow_prototype_tag_reextraction
           and prototype_tag_reextractions_compatible(
                ltype, rtype, seen, prototype_tag_state) then
            return true
        end
        if allow_anonymous_aggregate then
            return anonymous_aggregates_compatible(
                ltype, rtype, seen,
                allow_oldstyle_prototype,
                allow_array_bound_candidate,
                allow_prototype_tag_reextraction,
                prototype_tag_state)
        end
        -- Reaching this branch means the objects are distinct. Equal tag
        -- spellings do not collapse distinct file/prototype-scope identities,
        -- and anonymous objects compare structurally only through the
        -- shared physical typedef-declaration exception above.
        return false
    end
    return false
end

function foreigntypes.declaration_compatibility(
        left, right, left_declaration, right_declaration)
    local ltype, lalias_quals =
        resolve_declaration_typedefs(left)
    local rtype, ralias_quals =
        resolve_declaration_typedefs(right)
    if not ltype or not rtype then return false end
    local arrays = ltype._tag == "Type.CArray"
        and rtype._tag == "Type.CArray"
    if not arrays
       and not same_qualifiers(
            combined_qualifiers(
                left_declaration and left_declaration.qualifiers,
                lalias_quals),
            combined_qualifiers(
                right_declaration and right_declaration.qualifiers,
                ralias_quals)) then
        return false
    end
    -- Non-array declaration/typedef qualifiers were compared in their
    -- normalized object-level position above. Array qualification belongs to
    -- its element type and is therefore normalized by the array branch.
    if declaration_types_compatible(
        left, right, {}, not arrays, false, false, false) then
        return "exact"
    end
    -- Distinct anonymous aggregates, old-style/prototype pairs, and unequal
    -- known array-bound syntax from independently parsed header snapshots
    -- need target-C authority. Structural agreement only makes these
    -- declarations candidates for a probe in the final ordered-header
    -- context; it is never sufficient evidence by itself.
    if declaration_types_compatible(
        left, right, {}, not arrays, true, true, true) then
        return "conditional"
    end
    return false
end

function foreigntypes.declarations_compatible(...)
    return foreigntypes.declaration_compatibility(...) == "exact"
end

-- This relation is intentionally separate from ordinary declaration
-- compatibility. It accepts a pair only when every difference is an explicitly
-- marked prototype-local struct/union object created by independent extraction.
-- Physical source identity and the final ordered-header baseline remain the
-- checker's responsibility.
function foreigntypes.prototype_tag_reextraction_compatibility(
        left, right, left_declaration, right_declaration)
    local ltype, lalias_quals =
        resolve_declaration_typedefs(left)
    local rtype, ralias_quals =
        resolve_declaration_typedefs(right)
    if not ltype or not rtype then return false end
    local arrays = ltype._tag == "Type.CArray"
        and rtype._tag == "Type.CArray"
    if not arrays
       and not same_qualifiers(
            combined_qualifiers(
                left_declaration and left_declaration.qualifiers,
                lalias_quals),
            combined_qualifiers(
                right_declaration and right_declaration.qualifiers,
                ralias_quals)) then
        return false
    end

    local state = {
        matched = false,
        left_to_right = {},
        right_to_left = {},
    }
    return declaration_types_compatible(
            left, right, {}, not arrays,
            false, false, false, true, state)
       and state.matched
end

local function merge_declaration_composite(previous, current, seen)
    -- The first published declaration-owned view is shared by its earlier
    -- module member and the ordinary-name registry. Complete unknown array
    -- bounds recursively through that private graph so either import order
    -- exposes C's known-bound composite. Canonical typedef targets remain
    -- untouched; only aliases marked as declaration array views are descended.
    if previous == current
       or type(previous) ~= "table"
       or type(current) ~= "table"
       then
        return previous
    end
    if previous._tag == "Type.CTypedef" then
        if previous._declaration_array_view then
            merge_declaration_composite(
                previous.target,
                current._tag == "Type.CTypedef"
                    and current.target or current,
                seen)
        end
        return previous
    elseif current._tag == "Type.CTypedef" then
        return merge_declaration_composite(
            previous, current.target, seen)
    elseif previous._tag ~= current._tag then
        return previous
    end
    seen = seen or {}
    local merged = seen[previous]
    if merged and merged[current] then return previous end
    if not merged then
        merged = {}
        seen[previous] = merged
    end
    merged[current] = true

    local tag = previous._tag
    if tag == "Type.CArray" then
        if unknown_array_bound(previous.len)
           and not unknown_array_bound(current.len) then
            previous.len = current.len
            previous._c_origin_header = current._c_origin_header
                or previous._c_origin_header
        end
        merge_declaration_composite(
            previous.elem, current.elem, seen)
    elseif tag == "Type.CPointer" then
        merge_declaration_composite(
            previous.pointee, current.pointee, seen)
    elseif tag == "Type.CFunction" then
        if function_paramstyle(previous) == "oldstyle"
           and function_paramstyle(current) == "prototype" then
            previous.params = current.params
            previous.vararg = current.vararg
            previous._paramstyle = "prototype"
            previous._c_origin_header = current._c_origin_header
                or previous._c_origin_header
        end
        for index, param in ipairs(previous.params or {}) do
            merge_declaration_composite(
                param, current.params[index], seen)
        end
        merge_declaration_composite(
            previous.ret, current.ret, seen)
    end
    return previous
end

foreigntypes.merge_declaration_composite =
    merge_declaration_composite

local function c_type_key(ftype)
    if ftype.type == "struct" or ftype.type == "union" or ftype.type == "enum" then
        local name = c_name(ftype.name)
        if not name then
            return nil
        end
        return ftype.type .. "@" .. tostring(name)
    end
end

local function tag_provenance(ftype)
    local metadata = ftype._file_scope_tag_metadata
        or (ftype._canonical_tag
            and ftype._canonical_tag._file_scope_tag_metadata)
    local is_definition = ftype.fields ~= nil or ftype.values ~= nil
    if is_definition and metadata and metadata.declarations then
        for _, provenance in ipairs(metadata.declarations) do
            if provenance.definition then return provenance end
        end
    end
    if metadata and metadata.declarations
       and metadata.declarations[1] then
        return metadata.declarations[1]
    end
    return ftype._tag_provenance
        or (ftype._canonical_tag and ftype._canonical_tag._tag_provenance)
end

-- Complete tags use the actual definition's header, regardless of an earlier
-- forward declaration in another header. Opaque tags use their declaration.
local function tag_ffi_scope(ftype)
    local metadata = ftype._file_scope_tag_metadata
        or (ftype._canonical_tag and ftype._canonical_tag._file_scope_tag_metadata)
    local first = metadata and metadata.declarations and metadata.declarations[1]
    for _, declaration in ipairs(metadata and metadata.declarations or {}) do
        if declaration.definition then first = declaration; break end
    end
    local provenance = first or ftype._tag_provenance
        or (ftype._canonical_tag and ftype._canonical_tag._tag_provenance)
    return provenance and provenance.ffi_scope
end

local function retain_tag_ffi_scope(owner, ftype)
    if not (owner._tag == "Type.CStruct" and types.is_c_lua_state(owner)) then
        owner._ffi_scope = owner._ffi_scope or tag_ffi_scope(ftype)
    end
    return owner
end


-- Bind only parser-annotated tags. Legacy/manual declarations without scope
-- metadata retain the old raw-key behavior below.
local function bind_tag_record(st, ftype)
    local name = c_name(ftype.name)
    if not name then return nil end

    local provenance = tag_provenance(ftype)
    if ftype._file_scope_tag then
        if ftype.type == "enum" then
            return st:register_c_enum_tag(name, provenance)
        end
        return st:register_c_file_tag(name, ftype.type, provenance)
    elseif ftype._prototype_scope_id ~= nil then
        return st:bind_c_prototype_tag(
            name, ftype.type, ftype._prototype_scope_id, provenance,
            ftype._allow_outer_binding)
    end
end

local integer_specs = {
    ["_Bool"] = { "_Bool", false, 0, 1 },
    ["char"] = { "char", true, 1 },
    ["signed char"] = { "signed char", true, 1 },
    ["unsigned char"] = { "unsigned char", false, 1 },
    ["short"] = { "short", true, 2 },
    ["short int"] = { "short", true, 2 },
    ["signed short"] = { "signed short", true, 2 },
    ["signed short int"] = { "signed short", true, 2 },
    ["unsigned short"] = { "unsigned short", false, 2 },
    ["unsigned short int"] = { "unsigned short", false, 2 },
    ["int"] = { "int", true, 3 },
    ["signed"] = { "signed int", true, 3 },
    ["signed int"] = { "signed int", true, 3 },
    ["unsigned"] = { "unsigned int", false, 3 },
    ["unsigned int"] = { "unsigned int", false, 3 },
    ["long"] = { "long", true, 4 },
    ["long int"] = { "long", true, 4 },
    ["signed long"] = { "signed long", true, 4 },
    ["signed long int"] = { "signed long", true, 4 },
    ["unsigned long"] = { "unsigned long", false, 4 },
    ["unsigned long int"] = { "unsigned long", false, 4 },
    ["long long"] = { "long long", true, 5 },
    ["long long int"] = { "long long", true, 5 },
    ["signed long long"] = { "signed long long", true, 5 },
    ["signed long long int"] = { "signed long long", true, 5 },
    ["unsigned long long"] = { "unsigned long long", false, 5 },
    ["unsigned long long int"] = { "unsigned long long", false, 5 },
    ["__int128"] = { "__int128", true, 6, 128 },
    ["__int128_t"] = { "__int128_t", true, 6, 128 },
    ["__uint128_t"] = { "__uint128_t", false, 6, 128 },
}

local float_specs = {
    ["float"] = true,
    ["double"] = true,
    ["long double"] = true,
}

local function canonical_spelling(tokens)
    local unsigned = false
    local signed = false
    local longs = 0
    local seen = {}
    for _, token in ipairs(tokens) do
        if token == "unsigned" then
            unsigned = true
        elseif token == "signed" then
            signed = true
        elseif token == "long" then
            longs = longs + 1
        else
            seen[token] = true
        end
    end

    if seen.void then
        return "void"
    elseif seen._Complex then
        return nil
    elseif seen.float then
        return "float"
    elseif seen.double then
        return longs > 0 and "long double" or "double"
    elseif seen.char then
        if unsigned then return "unsigned char" end
        if signed then return "signed char" end
        return "char"
    elseif seen["__int128"] then
        if unsigned then return "unsigned __int128" end
        return "__int128"
    elseif seen.short then
        if unsigned then return "unsigned short" end
        return "short"
    elseif longs >= 2 then
        if unsigned then return "unsigned long long" end
        return "long long"
    elseif longs == 1 then
        if unsigned then return "unsigned long" end
        return "long"
    elseif seen.int or unsigned or signed then
        if unsigned then return "unsigned int" end
        return "int"
    end

    return table.concat(tokens, " ")
end

local function primitive_from_tokens(profile, tokens)
    local spelling = canonical_spelling(tokens)
    if spelling == "" then
        return nil
    elseif spelling == "void" then
        return types.CVoid()
    elseif profile and profile.floats
           and profile.floats[spelling] then
        return profile.floats[spelling].type
    elseif profile and profile.integers
           and profile.integers[spelling] then
        return profile.integers[spelling].type
    elseif profile then
        -- A configured profile is authoritative. In particular, compiler
        -- extension integers such as __int128 must not leak in from a
        -- hard-coded host assumption when the selected target lacks them.
        return nil
    elseif float_specs[spelling] then
        return types.CFloat(spelling)
    elseif integer_specs[spelling] then
        local spec = integer_specs[spelling]
        return types.CInteger(spec[1], spec[2], spec[3], spec[4])
    end
end

-- Titan exposes exactly the portable C99 arithmetic spellings below. The map
-- spells C `_Bool` as `bool`. These names are resolved only in foreign type
-- context; Titan's scalar `float` lives in a separate syntactic namespace.
-- C typedefs never enter this table, even when their targets do.
local surface_primitive_spellings = {
    void = "void",
    bool = "_Bool",
    char = "char",
    ["signed char"] = "signed char",
    ["unsigned char"] = "unsigned char",
    short = "short",
    ["unsigned short"] = "unsigned short",
    int = "int",
    ["unsigned int"] = "unsigned int",
    long = "long",
    ["unsigned long"] = "unsigned long",
    ["long long"] = "long long",
    ["unsigned long long"] = "unsigned long long",
    float = "float",
    double = "double",
    ["long double"] = "long double",
    lua_State = "lua_State",
}

local surface_primitive_components = {
    void = true,
    bool = true,
    char = true,
    signed = true,
    unsigned = true,
    short = true,
    int = true,
    long = true,
    double = true,
    lua_State = true,
}

function foreigntypes.surface_primitive(profile, surface)
    local spelling = surface_primitive_spellings[surface]
    if not spelling then return nil end
    if spelling == "void" then return types.CVoid() end
    if spelling == "lua_State" then
        return types.CStruct(nil, "lua_State", nil, {}, false, false)
    end
    local entry = profile and profile.integers
        and profile.integers[spelling]
    if not entry then
        entry = profile and profile.floats
            and profile.floats[spelling]
    end
    return entry and entry.type or nil
end

function foreigntypes.is_surface_primitive_name(name)
    return surface_primitive_spellings[name] ~= nil
end

function foreigntypes.is_surface_primitive_component(name)
    return surface_primitive_components[name] == true
end

local function merged_qualifiers(first, second)
    local out = {}
    for _, qual in ipairs(first or {}) do table.insert(out, qual) end
    for _, qual in ipairs(second or {}) do table.insert(out, qual) end
    return out
end

local function qualify_array(base, quals)
    if not quals or #quals == 0 then return base end
    local resolved = types.resolve_c_typedef(base)
    if not resolved or resolved._tag ~= "Type.CArray" then
        -- Top-level scalar/pointer qualification does not affect the value type
        -- imported by Titan. Array qualification is retained because it becomes
        -- pointee qualification on decay.
        return base
    end
    return types.CArray(resolved.elem, resolved.len,
        merged_qualifiers(resolved.quals, quals))
end

local function with_array_dims(base, idxs, quals)
    for i = #(idxs or {}), 1, -1 do
        base = types.CArray(base, idxs[i])
    end
    local resolved = types.resolve_c_typedef(base)
    if resolved and resolved._tag == "Type.CArray" then
        return qualify_array(base, quals), nil, {}
    end
    -- A direct declaration may ignore top-level scalar/pointer qualification,
    -- but a typedef definition must retain it for every later use of the name.
    return base, nil, copy_list(quals or {})
end

local convert_type
local convert_parts

local function apply_pointer_suffixes(base, suffixes)
    local quals = {}
    for _, suffix in ipairs(suffixes or {}) do
        if suffix == "*" then
            base = types.CPointer(base, copy_list(quals))
            quals = {}
        elseif qualifiers[suffix] then
            table.insert(quals, suffix)
        end
    end
    return base, quals
end

local function populate_struct_or_union(st, owner, ftype)
    if not ftype.fields then
        return owner
    end

    local fields = {}
    local has_fam = false
    for _, field in ipairs(ftype.fields) do
        if not field.anonymous and field.name then
            local ftyp, err = convert_type(st, field)
            if not ftyp then return nil, err end
            local cfield = types.CField(owner, field.name, ftyp,
                field.bitfield and field.width or false,
                field.flexible_array and true or false)
            table.insert(fields, cfield)
            fields[field.name] = cfield
            has_fam = has_fam or (field.flexible_array and true or false)
        end
    end
    -- Completion is atomic. A seeded raw tag can be visited before typedefs
    -- needed by its fields have been converted; a failed best-effort attempt
    -- must leave the canonical owner incomplete so a later declaration can
    -- complete it rather than freezing a partial field list.
    owner.fields = fields
    owner._c_origin_header = st._c_origin_header
        or owner._c_origin_header
    owner.complete = true
    owner._definition_order = st.current_toplevel_order or 0
    if owner._tag == "Type.CStruct" then
        owner.has_fam = has_fam
    end
    return owner
end

local function new_struct_or_union(ftype)
    local fields = {}
    local tagname = c_name(ftype.name)
    local owner = (ftype.type == "struct")
        and types.CStruct(nil, tagname, nil, fields, false, false)
        or types.CUnion(nil, tagname, nil, fields, false)
    return retain_tag_ffi_scope(owner, ftype)
end

local function convert_struct_or_union(st, ftype)
    local record, binding_err = bind_tag_record(st, ftype)
    if binding_err then return nil, binding_err end
    if record then
        local owner = record.canonical
        if not owner then
            local key
            local raw
            if record.scope == "file" then
                key = ftype.type .. "@" .. c_name(ftype.name)
                raw = st:find_foreign_type(key)
            end
            owner = st:set_c_tag_canonical(
                record, raw or new_struct_or_union(ftype))
            if key and not raw then
                st:add_foreign_type(key, owner)
            end
        end
        -- Keep scope provenance on the canonical aggregate without making it
        -- part of general Type.CStruct/CUnion equality. It is needed only for
        -- the narrowly scoped repeated-extraction relation above.
        owner._c_tag_scope = record.scope
        retain_tag_ffi_scope(owner, ftype)
        if ftype.fields and not owner.complete then
            return populate_struct_or_union(st, owner, ftype)
        end
        return owner
    end

    local key = c_type_key(ftype) or ""
    -- An anonymous definition has no spelling key, but all of its declarators
    -- still refer to the same raw CType object in this module's parsed graph.
    -- Keep that identity without equating independently declared aggregates.
    if key == "" then
        st._converted_c_aggregates = st._converted_c_aggregates
            or setmetatable({}, { __mode = "k" })
        local cached = st._converted_c_aggregates[ftype]
        if cached then
            if ftype.fields and not cached.complete then
                return populate_struct_or_union(st, cached, ftype)
            end
            return cached
        end
    end
    local existing = st:find_foreign_type(key)
    if existing then
        retain_tag_ffi_scope(existing, ftype)
        if ftype.fields and not existing.complete then
            return populate_struct_or_union(st, existing, ftype)
        end
        return existing
    end

    local owner = new_struct_or_union(ftype)
    if key ~= "" then
        st:add_foreign_type(key, owner)
    else
        st._converted_c_aggregates[ftype] = owner
    end

    return populate_struct_or_union(st, owner, ftype)
end

local function convert_struct_or_union_declarator(st, ftype)
    local base, err = convert_struct_or_union(st, ftype)
    if not base then return nil, err end
    local adjusted, quals =
        apply_pointer_suffixes(base, ftype.pointer)
    return with_array_dims(adjusted, ftype.idxs, quals)
end

local function convert_enum(st, ftype)
    st._converted_c_enums = st._converted_c_enums
        or setmetatable({}, { __mode = "k" })
    local cached = st._converted_c_enums[ftype]
    if cached then return cached end

    local record, binding_err = bind_tag_record(st, ftype)
    if binding_err then return nil, binding_err end
    local enum_type = record and record.canonical
    if not enum_type then
        local provisional = st.c_profile
            and st.c_profile.integers
            and st.c_profile.integers.int
            and st.c_profile.integers.int.type
            or types.CInteger("int", true, 3, false)
        enum_type = types.CInteger(
            provisional.spelling, provisional.signed,
            provisional.rank, provisional.bits)
        enum_type._c_numeric = provisional._c_numeric
        enum_type._c_numeric_carriers =
            provisional._c_numeric_carriers
    end

    local name = c_name(ftype.name)
    -- `allow_outer` is only a lookup request. If no outer tag exists,
    -- bind_c_prototype_tag returns a genuinely prototype-local record.
    local local_prototype = record and record.scope == "prototype"
    if name and not local_prototype then
        local origin = st._c_origin_header
            and st._c_origin_header.rendered or ""
        enum_type._c_enum_identity = enum_type._c_enum_identity
            or "enum-tag:" .. origin .. ":" .. name
        enum_type._c_declaration_spelling =
            enum_type._c_declaration_spelling or "enum " .. name
    else
        local scope = local_prototype
            and (":prototype:" .. tostring(ftype._prototype_scope_id)) or ""
        enum_type._c_enum_identity = enum_type._c_enum_identity
            or "anonymous-enum:" .. tostring(ftype) .. scope
        enum_type._c_enum_unspellable = true
        enum_type._c_declaration_spelling = nil
    end
    if ftype.values and st._c_origin_header then
        -- A later definition is the first header that makes a forward enum
        -- complete enough for carrier probing.
        enum_type._c_origin_header = st._c_origin_header
    end
    if record then
        enum_type = st:set_c_tag_canonical(record, enum_type)
    end
    st._converted_c_enums[ftype] = enum_type
    return enum_type
end

local function convert_function_type(st, ftype)
    local ptypes = {}
    for _, pdecl in ipairs(ftype.params) do
        local pt, err = convert_type(st, pdecl)
        if not pt then return nil, err end
        local rpt = types.resolve_c_typedef(pt)
        if rpt._tag == "Type.CArray" then
            pt = types.CPointer(rpt.elem, rpt.quals or {})
        end
        if pt._tag ~= "Type.CVoid" then
            table.insert(ptypes, pt)
        end
    end
    local rt, err, return_qualifiers =
        convert_type(st, ftype.ret)
    if not rt then return nil, err end
    local converted =
        types.CFunction(ptypes, rt, ftype.vararg, false)
    converted._paramstyle =
        ftype._paramstyle
    converted._return_declaration_qualifiers =
        copy_list(return_qualifiers or {})
    return converted
end

local function convert_function_pointer(st, ftype)
    local cfunc, err = convert_function_type(st, ftype)
    if not cfunc then return nil, err end
    if ftype._declarator_ops then
        local parts = { cfunc }
        for _, operation in ipairs(ftype._declarator_ops) do
            parts[#parts + 1] = operation
        end
        return convert_parts(st, parts)
    end
    local adjusted, quals =
        apply_pointer_suffixes(cfunc, ftype.pointer)
    return with_array_dims(adjusted, ftype.idxs, quals)
end

convert_parts = function(st, parts, idxs)
    local base_tokens = {}
    local suffixes = {}
    local quals = {}

    for _, part in ipairs(parts or {}) do
        if part == "*" then
            table.insert(suffixes, { tag = "pointer", quals = copy_list(quals) })
            quals = {}
        elseif type(part) == "table" and part.idx ~= nil then
            table.insert(suffixes, { tag = "array", len = part.idx })
        elseif type(part) == "table"
               and (part.type == "struct" or part.type == "union") then
            local ctyp, err = convert_struct_or_union(st, part)
            if not ctyp then return nil, err end
            table.insert(base_tokens, ctyp)
        elseif type(part) == "table" and part.type == "enum" then
            local ctyp, err = convert_enum(st, part)
            if not ctyp then return nil, err end
            table.insert(base_tokens, ctyp)
        elseif qualifiers[part] then
            table.insert(quals, part)
        elseif st:find_foreign_type(part) then
            table.insert(base_tokens, st:find_foreign_type(part))
        else
            table.insert(base_tokens, part)
        end
    end

    local base
    if #base_tokens == 1 and type(base_tokens[1]) == "table" then
        base = base_tokens[1]
    else
        local tokens = {}
        for _, item in ipairs(base_tokens) do
            if type(item) == "string" then
                table.insert(tokens, item)
            else
                return nil, "unsupported mixed C type: " .. inspect(parts)
            end
        end
        base = primitive_from_tokens(st.c_profile, tokens)
    end

    if not base then
        return nil, "unsupported C type: " .. inspect(parts)
    end

    for _, suffix in ipairs(suffixes) do
        if suffix.tag == "pointer" then
            base = types.CPointer(base, suffix.quals)
        elseif suffix.tag == "array" then
            base = types.CArray(base, suffix.len)
        end
    end

    return with_array_dims(base, idxs, quals)
end

convert_type = function(st, ftype)
    if ftype.type == "struct" or ftype.type == "union" then
        return convert_struct_or_union_declarator(st, ftype)
    elseif ftype.type == "enum" then
        return convert_enum(st, ftype)
    elseif ftype.type == "functionptr" then
        return convert_function_pointer(st, ftype)
    elseif ftype.type == "typedef" then
        return foreigntypes.convert(st, ftype)
    elseif ftype._declarator_base then
        local parts = {}
        for _, part in ipairs(ftype._declarator_base) do
            parts[#parts + 1] = part
        end
        for _, operation in ipairs(ftype._declarator_ops or {}) do
            parts[#parts + 1] = operation
        end
        return convert_parts(st, parts)
    elseif type(ftype.type) == "table" then
        return convert_parts(st, ftype.type, ftype.idxs)
    end
    return nil, "unsupported C declaration: " .. inspect(ftype)
end

local function convert_function(st, ftype)
    return convert_function_type(st, ftype)
end

local function convert_typedef(st, ftype)
    local target, err, quals
    if type(ftype.def) == "table" and ftype.def.type == "functionptr" then
        target, err, quals =
            convert_function_pointer(st, ftype.def)
    elseif ftype._declarator_base then
        local parts = {}
        for _, part in ipairs(ftype._declarator_base) do
            parts[#parts + 1] = part
        end
        for _, operation in ipairs(ftype._declarator_ops or {}) do
            parts[#parts + 1] = operation
        end
        target, err, quals = convert_parts(st, parts)
    else
        target, err, quals =
            convert_parts(st, ftype.def, ftype.idxs)
    end
    if not target then return nil, err end
    local converted = types.CTypedef(
        ftype.name, target, quals or {})
    converted._ffi_scope = ftype._ffi_scope
    local resolved_target = types.resolve_c_typedef(target)
    if resolved_target and resolved_target._tag == "Type.CInteger"
       and resolved_target._c_enum_identity
       and not resolved_target._c_declaration_spelling then
        resolved_target._c_declaration_spelling = tostring(ftype.name)
        local origin = st._c_origin_header
            and st._c_origin_header.rendered or ""
        resolved_target._c_enum_identity =
            "enum-typedef:" .. origin .. ":" .. tostring(ftype.name)
        resolved_target._c_enum_unspellable = nil
    end
    converted._declaration_provenance =
        ftype._declaration_provenance
    return converted
end

local function declaration_array_view(typ, memo)
    if type(typ) ~= "table" then return typ, false end
    memo = memo or {}
    local cached = memo[typ]
    if cached then return cached.type, cached.cloned end

    -- Install a conservative entry before descending. Valid C declarator
    -- graphs cannot contain an array cycle, while canonical aggregate cycles
    -- stop below because aggregates themselves are never cloned here.
    memo[typ] = { type = typ, cloned = false }
    local tag = typ._tag
    local view, cloned
    if tag == "Type.CArray" then
        local elem =
            declaration_array_view(typ.elem, memo)
        view = types.CArray(
            elem, typ.len, copy_list(typ.quals or {}))
        cloned = true
    elseif tag == "Type.CTypedef" then
        local target, target_cloned =
            declaration_array_view(typ.target, memo)
        if target_cloned then
            view = types.CTypedef(
                typ.name, target, copy_list(typ.quals or {}))
            view._declaration_provenance =
                typ._declaration_provenance
            view._declaration_array_view = true
            cloned = true
        end
    elseif tag == "Type.CPointer" then
        local pointee, pointee_cloned =
            declaration_array_view(typ.pointee, memo)
        if pointee_cloned then
            view = types.CPointer(
                pointee, copy_list(typ.quals or {}))
            cloned = true
        end
    elseif tag == "Type.CFunction" then
        local params, changed = {}, false
        for index, param in ipairs(typ.params or {}) do
            local converted, param_cloned =
                declaration_array_view(param, {})
            params[index] = converted
            changed = changed or param_cloned
        end
        local ret, ret_cloned =
            declaration_array_view(typ.ret, {})
        changed = changed or ret_cloned
        if changed then
            view = types.CFunction(
                params, ret, typ.vararg, typ.abi)
            view._paramstyle = typ._paramstyle
            view._return_declaration_qualifiers =
                copy_list(typ._return_declaration_qualifiers or {})
            cloned = true
        end
    end

    view = view or typ
    if cloned then
        view._c_origin_header = typ._c_origin_header
        view._ffi_scope = typ._ffi_scope
    end
    memo[typ] = { type = view, cloned = cloned and true or false }
    return view, cloned and true or false
end

local function convert_declaration(st, ftype, member_name)
    if ftype.macro_expression
       and (ftype.has_integer_literals
            or ftype.integer_literals and #ftype.integer_literals > 0)
       and st.c_profile then
        local evaluated, evaluation_error =
            csemantics.evaluate_macro_expression(
                st.c_profile, ftype.macro_expression)
        if not evaluated then
            return nil, "unsupported target integer macro expression: " ..
                tostring(evaluation_error)
        end
        return evaluated.type, nil, {
            qualifiers = {},
            provenance = ftype._declaration_provenance,
            origin_header = st._c_origin_header,
            integer_constant = evaluated.value,
        }
    end
    local converted, err, declaration_qualifiers
    if ftype.type == "function" then
        converted, err = convert_function(st, ftype)
    elseif ftype.type == "typedef" then
        converted, err = convert_typedef(st, ftype)
    elseif ftype.type == "struct" or ftype.type == "union" then
        converted, err, declaration_qualifiers =
            convert_struct_or_union_declarator(st, ftype)
    elseif ftype.type == "enum" then
        converted, err = convert_enum(st, ftype)
        local is_enumerator = false
        for _, item in ipairs(ftype.values or {}) do
            if item.name == member_name then
                is_enumerator = true
                break
            end
        end
        if converted and is_enumerator then
            local view = {}
            for key, value in pairs(converted) do view[key] = value end
            local origin = st._c_origin_header
                and st._c_origin_header.rendered or ""
            view._c_enum_identity = "enum-enumerator:" .. origin
                .. ":" .. tostring(member_name)
            view._c_declaration_spelling =
                "__typeof__((" .. tostring(member_name) .. "))"
            view._c_enum_probe_spelling = view._c_declaration_spelling
            view._c_enum_enumerator = tostring(member_name)
            view._c_enum_owner = converted
            view._c_enum_unspellable = nil
            converted = view
        end
    elseif ftype.type == "functionptr" then
        converted, err, declaration_qualifiers =
            convert_function_pointer(st, ftype)
    elseif type(ftype.type) == "table" then
        converted, err, declaration_qualifiers =
            convert_type(st, ftype)
        local resolved = converted and types.resolve_c_typedef(converted)
        if resolved and resolved._tag == "Type.CInteger"
           and resolved._c_enum_identity
           and resolved._c_enum_unspellable and member_name then
            local view = {}
            for key, value in pairs(resolved) do view[key] = value end
            -- The object-specific expression spelling is not a new nominal C
            -- type. Preserve the one anonymous enum owner shared by every
            -- declarator from this declaration.
            view._c_enum_identity = resolved._c_enum_identity
            view._c_enum_owner = resolved
            -- A scalar cast through the exact anonymous type removes top-level
            -- const/volatile from the value type without applying the integer
            -- promotions that would hide a short-enum carrier. Use that same
            -- exact unqualified spelling for generated temporaries and probes.
            view._c_declaration_spelling =
                "__typeof__(((__typeof__((" .. tostring(member_name)
                .. ")))0))"
            view._c_enum_probe_spelling = view._c_declaration_spelling
            view._c_enum_unspellable = nil
            converted = view
        end
    else
        return nil, "unsupported C declaration: " .. inspect(ftype)
    end
    if not converted then return nil, err end
    if ftype.type == "function"
       or ftype.type == "functionptr"
       or type(ftype.type) == "table" then
        converted = declaration_array_view(converted)
    end
    if ftype._macro_cast then
        local scalar = types.resolve_c_typedef(converted)
        if not scalar
           or (scalar._tag ~= "Type.CInteger"
               and scalar._tag ~= "Type.CFloat"
               and scalar._tag ~= "Type.CPointer") then
            -- A C cast expression can produce only a scalar value (or void).
            -- The parser also accepts syntactically shaped but semantically
            -- invalid aggregate/array targets, so do not publish those as
            -- usable macro members.
            return nil
        end
    end
    -- Direct scalar/pointer qualification is declaration metadata, not value
    -- type identity. Keep it beside the converted type: profile primitives and
    -- canonical tags are shared objects and must never be mutated per
    -- declaration.
    local declaration = {
        qualifiers = copy_list(declaration_qualifiers or {}),
        provenance = ftype._declaration_provenance,
        origin_header = st._c_origin_header,
    }
    return converted, nil, declaration
end

function foreigntypes.convert(st, ftype, member_name, origin_header)
    local previous = st._c_origin_header
    st._c_origin_header = origin_header
    local results = table.pack(pcall(
        convert_declaration, st, ftype, member_name))
    st._c_origin_header = previous
    if not results[1] then error(results[2], 0) end
    local converted, err, declaration =
        table.unpack(results, 2, results.n)
    if converted and origin_header then
        types.mark_c_ffi_include(converted, origin_header)
    end
    return converted, err, declaration
end

return foreigntypes
