-- Module to convert c-parser types into Titan checker types.
local foreigntypes = {}

local types = require "titan-compiler.types"
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

local function c_type_key(ftype)
    if ftype.type == "struct" or ftype.type == "union" or ftype.type == "enum" then
        local name = c_name(ftype.name)
        if not name then
            return nil
        end
        return ftype.type .. "@" .. tostring(name)
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

    if #tokens == 1 and integer_specs[tokens[1]] then
        return tokens[1]
    elseif seen.void then
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
    elseif seen.short then
        if unsigned then return "unsigned short" end
        if signed then return "signed short" end
        return "short"
    elseif longs >= 2 then
        if unsigned then return "unsigned long long" end
        if signed then return "signed long long" end
        return "long long"
    elseif longs == 1 then
        if unsigned then return "unsigned long" end
        if signed then return "signed long" end
        return "long"
    elseif seen.int or unsigned or signed then
        if unsigned then return "unsigned int" end
        if signed then return "signed int" end
        return "int"
    end

    return table.concat(tokens, " ")
end

local function primitive_from_tokens(tokens)
    local spelling = canonical_spelling(tokens)
    if spelling == "" then
        return nil
    elseif spelling == "void" then
        return types.CVoid()
    elseif float_specs[spelling] then
        return types.CFloat(spelling)
    elseif integer_specs[spelling] then
        local spec = integer_specs[spelling]
        return types.CInteger(spec[1], spec[2], spec[3], spec[4])
    end
end

local function with_array_dims(base, idxs)
    for i = #(idxs or {}), 1, -1 do
        base = types.CArray(base, idxs[i])
    end
    return base
end

local convert_type

local function convert_struct_or_union(st, ftype)
    local key = c_type_key(ftype) or ""
    local existing = st:find_foreign_type(key)
    if existing then
        return existing
    end

    local owner
    local fields = {}
    local has_fam = false
    local tagname = c_name(ftype.name)
    owner = (ftype.type == "struct")
        and types.CStruct(nil, tagname, nil, fields, ftype.fields ~= nil, false)
        or types.CUnion(nil, tagname, nil, fields, ftype.fields ~= nil)
    if key ~= "" then
        st:add_foreign_type(key, owner)
    end

    for _, field in ipairs(ftype.fields or {}) do
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

    if owner._tag == "Type.CStruct" then
        owner.has_fam = has_fam
    end
    return owner
end

local function convert_enum()
    return types.CInteger("int", true, 3, false)
end

local function convert_parts(st, parts, idxs)
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
            table.insert(base_tokens, convert_enum(part))
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
        base = primitive_from_tokens(tokens)
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

    return with_array_dims(base, idxs)
end

convert_type = function(st, ftype)
    if ftype.type == "struct" or ftype.type == "union" then
        return convert_struct_or_union(st, ftype)
    elseif ftype.type == "enum" then
        return convert_enum(ftype)
    elseif ftype.type == "typedef" then
        return foreigntypes.convert(st, ftype)
    elseif type(ftype.type) == "table" then
        return convert_parts(st, ftype.type, ftype.idxs)
    end
    return nil, "unsupported C declaration: " .. inspect(ftype)
end

local function convert_function(st, ftype)
    local ptypes = {}
    for _, pdecl in ipairs(ftype.params) do
        local pt, err = convert_type(st, pdecl)
        if not pt then return nil, err end
        local rpt = types.resolve_c_typedef(pt)
        if rpt._tag == "Type.CArray" then
            pt = types.CPointer(rpt.elem, {})
        end
        if pt._tag ~= "Type.CVoid" then
            table.insert(ptypes, pt)
        end
    end
    local rt, err = convert_type(st, ftype.ret)
    if not rt then return nil, err end
    local rettypes = rt._tag == "Type.CVoid" and {} or { rt }
    return types.Function(ptypes, rettypes, ftype.vararg, false)
end

local function convert_typedef(st, ftype)
    local target, err = convert_parts(st, ftype.def, ftype.idxs)
    if not target then return nil, err end
    return types.CTypedef(ftype.name, target)
end

function foreigntypes.convert(st, ftype)
    if ftype.type == "function" then
        return convert_function(st, ftype)
    elseif ftype.type == "typedef" then
        return convert_typedef(st, ftype)
    elseif ftype.type == "struct" or ftype.type == "union" then
        return convert_struct_or_union(st, ftype)
    elseif ftype.type == "enum" then
        return convert_enum(ftype)
    elseif type(ftype.type) == "table" then
        return convert_type(st, ftype)
    else
        return nil, "FIXME unconverted " .. inspect(ftype)
    end
end

return foreigntypes
