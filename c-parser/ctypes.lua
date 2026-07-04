
local ctypes = {}

local util = require("titan-compiler.util")
local inspect = require("inspect")
local typed = require("typed")

local equal_declarations
local calculate_or_original

local add_type = typed("TypeList, string, CType -> ()", function(lst, name, typ)
    lst[name] = typ
    table.insert(lst, { name = name, type = typ })
end)

-- Compare two lists of declarations
local equal_lists = typed("array, array -> boolean", function(l1, l2)
    if #l1 ~= #l2 then
        return false
    end
    for i, p1 in ipairs(l1) do
        local p2 = l2[i]
        if not equal_declarations(p1, p2) then
            return false
        end
    end
    return true
end)

equal_declarations = function(t1, t2)
    if type(t1) == "string" or type(t2) == "nil" then
        return t1 == t2
    end
    if not equal_declarations(t1.type, t2.type) then
        return false
    end
--    if not equal_lists(t1.name, t2.name) then
--        return false
--    end
    if t1.type == "struct" then
        if t1.name ~= t2.name then
            return false
        end
    elseif t1.type == "function" then
        if not equal_declarations(t1.ret.type, t2.ret.type) then
            return false
        end
        if not equal_lists(t1.params, t2.params) then
            return false
        end
        if t1.vararg ~= t2.vararg then
            return false
        end
    end
    return true
end

local function is_modifier(str)
    return str == "*" or str == "restrict" or str == "const"
end

local function extract_modifiers(ret_pointer, items)
    while is_modifier(items[1]) do
        table.insert(ret_pointer, table.remove(items, 1))
    end
end

local function get_name(name_src)
    local ret_pointer = {}
    if name_src == nil then
        return false, "could not find a name: " .. inspect(name_src), nil
    end
    local name
    local indices = {}
    if type(name_src) == "string" then
        if is_modifier(name_src) then
            table.insert(ret_pointer, name_src)
        else
            name = name_src
        end
    else
        name_src = name_src.declarator or name_src
        if type(name_src[1]) == "table" then
            extract_modifiers(ret_pointer, name_src[1])
        else
            extract_modifiers(ret_pointer, name_src)
        end
        for _, part in ipairs(name_src) do
            if part.idx then
                table.insert(indices, calculate_or_original(part.idx))
            end
        end
        name = name_src.name
    end
    return true, name, ret_pointer, next(indices) and indices
end

local get_type
local get_fields

local convert_value = typed("TypeList, table -> CType?, string?", function (lst, src)
    local name = nil
    local ret_pointer = {}
    local idxs = nil

    if type(src.id) == "table" or type(src.ids) == "table" then
        -- FIXME multiple ids, e.g.: int *x, y, *z;
        local ok
        -- get_name fills these only when ok is true (checked below); LuaLS can't correlate.
        ---@diagnostic disable-next-line: cast-local-type
        ok, name, ret_pointer, idxs = get_name(src.id or src.ids)
        if not ok then
            return nil, name
        end
    end

    local typ, err = get_type(lst, src, ret_pointer)
    if not typ then
        return nil, err
    end

    return typed.table("CType", {
        name = name,
        type = typ,
        idxs = idxs,
    }), nil
end)

local function mark_flexible_array_member(field)
    if field.idxs and #field.idxs == 1 and field.idxs[1] == "" then
        field.flexible_array = true
    end
end

-- Interpret field data from `field_src` and add it to `fields`.
local function add_to_fields(lst, field_src, fields)

    if type(field_src) == "table" and not field_src.ids then
        assert(field_src.type.type == "union")
        local subfields = get_fields(lst, field_src.type.fields)
        for _, subfield in ipairs(subfields) do
            table.insert(fields, subfield)
        end
        return true
    end

    if type(field_src.ids) == "table" then
        local i = 1
        while i <= #field_src.ids do
            local id = field_src.ids[i]
            local width
            if id.name or id.declarator then
                if field_src.ids[i + 1]
                and not (field_src.ids[i + 1].name or field_src.ids[i + 1].declarator) then
                    width = field_src.ids[i + 1]
                    i = i + 1
                end
            else
                width = id
                id = nil
            end

            local field, err = convert_value(lst, {
                type = field_src.type,
                id = id,
            })
            if not field then
                return nil, err
            end
            if width then
                field.bitfield = true
                field.width = calculate_or_original(width)
                if not id then
                    field.anonymous = true
                end
            end
            mark_flexible_array_member(field)

            table.insert(fields, field)
            i = i + 1
        end
    else
        local field, err = convert_value(lst, field_src)
        if not field then
            return nil, err
        end

        mark_flexible_array_member(field)
        table.insert(fields, field)
    end
    return true
end

get_fields = function(lst, fields_src)
    local fields = {}
    for _, field_src in ipairs(fields_src) do
        local ok, err = add_to_fields(lst, field_src, fields)
        if not ok then
            return false, err
        end
    end
    return fields
end

local function get_enum_items(_, values)
    local items = {}
    for _, v in ipairs(values) do
        -- TODO store enum actual values
        table.insert(items, { name = v.id })
    end
    return items
end

local get_composite_type = typed("TypeList, string?, string, array, string, function -> CType, string",
                           function(lst, specid, spectype, parts, partsfield, get_parts)
    local name = specid
    local key = spectype .. "@" .. (name or tostring(parts))

    if not lst[key] then
        -- Forward declaration
        lst[key] = typed.table("CType", {
            type = spectype,
            name = name,
        })
    end

    if parts then
        local err
        parts, err = get_parts(lst, parts)
        if not parts then
            return nil, err
        end
    end

    local typ = typed.table("CType", {
        type = spectype,
        name = name,
        [partsfield] = parts,
    })

    if lst[key] then
        if typ[partsfield] and lst[key][partsfield] and not equal_declarations(typ, lst[key]) then
            return nil, "redeclaration for " .. key
        end
    end
    add_type(lst, key, typ)

    return typ, key
end)

local function get_structunion(lst, spec)
    if spec.fields and not spec.fields[1] then
        spec.fields = { spec.fields }
    end
    return get_composite_type(lst, spec.id, spec.type, spec.fields, "fields", get_fields)
end

local function get_enum(lst, spec)
    if spec.values and not spec.values[1] then
        spec.values = { spec.values }
    end
    local typ, key = get_composite_type(lst, spec.id, spec.type, spec.values, "values", get_enum_items)
    if typ.values then
        for _, value in ipairs(typ.values) do
            add_type(lst, value.name, typ)
        end
    end
    return typ, key
end

local function refer(lst, item, get_fn)
    if item.id and not item.fields then
        local key = item.type .. "@" .. item.id
        local su_typ = lst[key]
        if not su_typ then
            return {
                type = item.type,
                name = { item.id },
            }
        end
        return su_typ
    else
        local typ, key = get_fn(lst, item)
        if not typ then
            return nil, key
        end
        return typ
    end
end

local calculate

local function binop(val, fn)
    local e1, e2 = calculate(val[1]), calculate(val[2])
    if type(e1) == "number" and type(e2) == "number" then
        return fn(e1, e2)
    else
        return { e1, e2, op = val.op }
    end
end

calculate = function(val)
    if type(val) == "string" then
        return tonumber(val) or val
    end
    if type(val) == "table" and val[1] and not val.op and not val.unop then
        if #val == 1 then
            return calculate(val[1])
        end
        return val
    end
    if val.op == "+" then
        return binop(val, function(a, b) return a + b end)
    elseif val.op == "-" then
        return binop(val, function(a, b) return a - b end)
    elseif val.op == "*" then
        return binop(val, function(a, b) return a * b end)
    elseif val.op == "/" then
        return binop(val, function(a, b) return a / b end)
    else
        return val
    end
end

calculate_or_original = function(val)
    local calculated = calculate(val)
    if calculated == nil then
        return val
    end
    return calculated
end

local base_types = {
    ["char"] = true,
    ["const"] = true,
    ["double"] = true,
    ["float"] = true,
    ["int"] = true,
    ["long"] = true,
    ["short"] = true,
    ["signed"] = true,
    ["unsigned"] = true,
    ["void"] = true,
    ["volatile"] = true,
    ["_Bool"] = true,
    ["_Complex"] = true,
    ["__int128"] = true,
    ["__int128_t"] = true,
    ["__uint128_t"] = true,
    ["*"] = true,
}

local qualifiers = {
    ["extern"] = true,
    ["static"] = true,
    ["typedef"] = true,
    ["restrict"] = true,
    ["inline"] = true,
    ["register"] = true,
}

get_type = function(lst, spec, ret_pointer)
    local tarr = {}
    if type(spec.type) == "string" then
        spec.type = { spec.type }
    end
    if spec.type and not spec.type[1] then
        spec.type = { spec.type }
    end
    for _, part in ipairs(spec.type or spec) do
        if qualifiers[part] then
            -- skip
        elseif base_types[part] then
            table.insert(tarr, part)
        elseif lst[part] and lst[part].type == "typedef" then
            table.insert(tarr, part)
        elseif type(part) == "table" and
               (part.type == "struct" or part.type == "union") then
            local su_typ, err = refer(lst, part, get_structunion)
            if not su_typ then
                return nil, err or "failed to refer struct"
            end
            table.insert(tarr, su_typ)
        elseif type(part) == "table" and part.type == "enum" then
            local en_typ, err = refer(lst, part, get_enum)
            if not en_typ then
                return nil, err or "failed to refer enum"
            end
            table.insert(tarr, en_typ)
        else
            return nil, "FIXME unknown type " .. inspect(spec)
        end
    end
    if #ret_pointer > 0 then
        for _, item in ipairs(ret_pointer) do
            if type(item) == "table" and item.idx then
                table.insert(tarr, { idx = calculate(item.idx) })
            else
                table.insert(tarr, item)
            end
        end
    end
    return tarr, nil
end

local function is_void(param)
    return #param.type == 1 and param.type[1] == "void"
end

local get_params = typed("TypeList, array -> array, boolean", function(lst, params_src)
    local params = {}
    local vararg = false

    assert(not params_src.param)

    for _, param_src in ipairs(params_src) do
        if param_src == "..." then
            vararg = true
        else
            local param, err = convert_value(lst, param_src.param)
            if not param then
                return nil, err
            end
            if not is_void(param) then
                table.insert(params, param)
            end
        end
    end
    return params, vararg
end)

local register_many = function(register_item_fn, lst, ids, spec)
    for _, id in ipairs(ids) do
        local ok, err = register_item_fn(lst, id, spec)
        if not ok then
            return false, err
        end
    end
    return true, nil
end

local register_decl_item = function(lst, id, spec)
    local ok, name, ret_pointer, idxs = get_name(id.decl)
    if not ok then
        return false, name
    end
    assert(name)
    local ret_type, err = get_type(lst, spec, ret_pointer)
    if not ret_type then
        return false, err
    end
    local typ
    if id.decl.params then
        local params, vararg = get_params(lst, id.decl.params)
        if not params then
            return false, vararg
        end
        typ = typed.table("CType", {
            type = "function",
            name = name,
            idxs = idxs,
            ret = {
                type = ret_type,
            },
            params = params,
            vararg = vararg,
        })
    else
        typ = typed.table("CType", {
            type = ret_type,
            name = name,
            idxs = idxs,
        })
    end

    if lst[name] then
        if not equal_declarations(lst[name], typ) then
            return false, "inconsistent declaration for " .. name .. " - " .. inspect(lst[name]) .. " VERSUS " .. inspect(typ)
        end
    end
    add_type(lst, name, typ)

    return true, nil
end

local register_decls = function(lst, ids, spec)
    return register_many(register_decl_item, lst, ids, spec)
end

-- Convert an table produced by an `extern inline` declaration
-- into one compatible with `register_decl`.
local function register_function(lst, item)
    local id = {
        decl = {
            name = item.func.name,
            params = item.func.params,
        }
    }
    return register_decl_item(lst, id, item.spec)
end

local function register_static_function(_, _)
    return true
end

local register_typedef_item = typed("TypeList, table, table -> boolean, string?", function(lst, id, spec)
    if id.decl.params then
        -- Function-pointer typedefs are out of scope for the first C FFI
        -- iteration. Do not mis-model `typedef int (*cb)(int)` as `int *cb`;
        -- leave the typedef unavailable so users get a clean missing-member
        -- error, and dependent declarations are skipped by the converter.
        return true, nil
    end

    local ok, name, ret_pointer, idxs = get_name(id.decl)
    if not ok then
        return false, name or "failed"
    end
    local def, err = get_type(lst, spec, ret_pointer)
    if not def then
        return false, err or "failed"
    end
    local typ = typed.table("CType", {
        type = "typedef",
        name = name,
        def = def,
        idxs = idxs,
    })

    if lst[name] then
        if not equal_declarations(lst[name], typ) then
            return false, "inconsistent declaration for " .. name .. " - " .. inspect(lst[name]) .. " VERSUS " .. inspect(typ)
        end
    end
    add_type(lst, name, typ)

    return true, nil
end)

local register_typedefs = function(lst, item)
    return register_many(register_typedef_item, lst, item.ids, item.spec)
end

local function register_structunion(lst, item)
    local spec = item.spec.type and item.spec or item.spec[1]
    return get_structunion(lst, spec)
end

local function register_enum(lst, item)
    local spec = item.spec.type and item.spec or item.spec[1]
    return get_enum(lst, spec)
end

local function register_one(lst, item)
    local spec_set = util.to_set(item.spec)
    local spec_type = item.spec.type or (item.spec[1] and item.spec[1].type)
    if spec_set.extern and item.ids then
        return register_decls(lst, item.ids, item.spec)
    elseif spec_set.extern and item.func then
        return register_function(lst, item)
    elseif spec_set.static and item.func then
        return register_static_function(lst, item)
    elseif spec_set.typedef then
        return register_typedefs(lst, item)
    elseif spec_type == "struct" or spec_type == "union" then
        return register_structunion(lst, item)
    elseif spec_type == "enum" then
        return register_enum(lst, item)
    elseif not item.ids then
        return true -- forward declaration (e.g. "struct foo;")
    elseif item.ids then
        return register_decls(lst, item.ids, item.spec)
    else
        return false, "uncategorized declaration"
    end
end

ctypes.register_types = typed("{Decl} -> TypeList?, string?", function(parsed)
    local lst = typed.table("TypeList", {})
    local skipped = 0
    for _, item in ipairs(parsed) do
        -- Best-effort: any declaration we cannot model -- an unsupported C type
        -- from a system header, or a shape this hand-written parser produced
        -- that the registrar does not expect -- is skipped rather than failing
        -- the whole header (and a raised error is caught, not propagated). The
        -- generated C still #includes the real header, so only the types Titan
        -- actually references need to register here; referencing a skipped one
        -- is then a clean "not a member" error. ctypes.skipped reports how many
        -- declarations were dropped.
        local pok, rok = pcall(register_one, lst, item)
        if not (pok and rok) then
            skipped = skipped + 1
        end
    end
    ctypes.skipped = skipped
    return lst, nil
end)

return ctypes
