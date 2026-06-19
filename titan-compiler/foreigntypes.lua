-- Module to convert c-parser types into Titan types
local foreigntypes = {}

local types = require "titan-compiler.types"
local inspect = require "inspect"

local function type_from_name(st, typename)
    for i = #typename, 1, -1 do
        local token = typename[i]
        if token == "const"
        or token == "restrict" then
            table.remove(typename, i)
        end
    end
    if #typename == 1 then
        local itype = st:find_foreign_type(typename[1])
        if itype then
            return itype
        elseif typename[1] == "void" then
            return types.Nil()
        elseif typename[1] == "int" then
            return types.Integer()
        elseif typename[1] == "long" then
            return types.Integer()
        elseif typename[1] == "double" then
            return types.Float()
        end
    elseif #typename == 2 and typename[1] == "char" and typename[2] == "*" then
        return types.String()
    elseif typename[#typename] == "*" then
        table.remove(typename)
        local inner, err = type_from_name(st, typename)
        if not inner then return nil, err end
        return {
            _tag = "Type.Pointer",
            type = inner
        }
    end
    -- Unsupported C type: signal a conversion failure so the importer can
    -- skip this member (referencing it is then a clean "member not found",
    -- never a checker/codegen crash on an unhandled type).
    local parts = {}
    for _, tok in ipairs(typename) do
        parts[#parts + 1] = type(tok) == "string" and tok or "?"
    end
    return nil, "unsupported C type: " .. table.concat(parts, " ")
end

local function convert_function(st, ftype)
    local decl = {
        islocal = true,
        isforeign = true,
        name = ftype.name,
    }
    local ptypes = {}
    for _, pdecl in ipairs(ftype.params) do
        local pt, err = foreigntypes.convert(st, pdecl)
        if not pt then return nil, err end
        table.insert(ptypes, pt)
    end
    local rt, err = foreigntypes.convert(st, ftype.ret)
    if not rt then return nil, err end
    local rettypes = { rt }
    decl._type = types.Function(ptypes, rettypes, ftype.vararg)
    decl.params = ptypes
    decl.rettypes = rettypes
    return decl._type
end

local function convert_typedef(st, ftype)
    local decl = {
        _tag = "Type.Typedef",
        name = ftype.name,
    }
    local ttype
    local longs = 0
    for _, item in ipairs(ftype.def) do
        if type(item) == "table" then
            ttype = foreigntypes.convert(st, item)
        else
            local itype = st:find_foreign_type(item)
            if itype then
                ttype = itype
            elseif item == "long" then
                longs = longs + 1
            elseif item == "double" then
                if longs > 0 then
                    error("NYI long double")
                end
                ttype = types.Float()
            elseif item == "int" then
                ttype = types.Integer()
            elseif item == "char" then
                ttype = types.Integer()
            elseif item == "short" then
                ttype = types.Integer()
            end
        end
    end
    if not ttype and longs > 0 then
        ttype = types.Integer()
    end
    if ttype then
        decl._type = ttype
        return decl
    end
    --decl.data = ftype
    return decl
end

local function convert_struct(_, ftype)
    local decl = {
        _tag = "Struct",
        name = ftype.name,
        data = ftype,
    }
    -- TODO process fields
    return decl
end

local function convert_union(_, ftype)
    local decl = {
        _tag = "Union",
        name = ftype.name,
        data = ftype,
    }
    -- TODO process fields
    return decl
end

local function convert_enum(_, _)
    -- A C enum (and each of its constants) is integer-like; map its Titan
    -- type to integer so imported enum constants can be used and
    -- type-checked like integers. (Struct/union field processing is still
    -- TODO; only the enum-as-integer mapping is handled here.)
    return types.Integer()
end

function foreigntypes.convert(st, ftype)
    if ftype.type == "function" then
        return convert_function(st, ftype)
    elseif ftype.type == "typedef" then
        return convert_typedef(st, ftype)
    elseif ftype.type == "struct" then
        return convert_struct(st, ftype)
    elseif ftype.type == "union" then
        return convert_union(st, ftype)
    elseif ftype.type == "enum" then
        return convert_enum(st, ftype)
    elseif type(ftype.type) == "table" and ftype.type[1] then
        return type_from_name(st, ftype.type)
    else
        return nil, "FIXME unconverted " .. inspect(ftype)
    end
end

return foreigntypes

