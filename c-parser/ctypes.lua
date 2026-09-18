
local ctypes = {}

local util = require("titan-compiler.util")
local inspect = require("inspect")
local typed = require("c-parser.typed")

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

local function equal_symbolic_values(left, right)
    if type(left) ~= type(right) then
        return false
    elseif type(left) ~= "table" then
        return left == right
    end

    for key, value in pairs(left) do
        if not equal_symbolic_values(value, right[key]) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function normalized_declarator_operations(operations)
    local normalized = {}
    for _, operation in ipairs(operations or {}) do
        if operation == "*" then
            normalized[#normalized + 1] = {
                kind = "pointer",
                qualifiers = {},
            }
        elseif type(operation) == "string" then
            local pointer = normalized[#normalized]
            if not pointer or pointer.kind ~= "pointer" then
                return nil
            end
            pointer.qualifiers[operation] = true
        elseif type(operation) == "table"
           and operation.idx ~= nil then
            normalized[#normalized + 1] = {
                kind = "array",
                bound = operation.idx,
            }
        else
            return nil
        end
    end
    return normalized
end

local function equal_declarator_operations(left, right)
    local left_ops = normalized_declarator_operations(left)
    local right_ops = normalized_declarator_operations(right)
    if not left_ops or not right_ops or #left_ops ~= #right_ops then
        return false
    end

    for index, left_op in ipairs(left_ops) do
        local right_op = right_ops[index]
        if left_op.kind ~= right_op.kind then
            return false
        elseif left_op.kind == "pointer" then
            if not equal_symbolic_values(
                    left_op.qualifiers, right_op.qualifiers) then
                return false
            end
        else
            local left_unknown =
                left_op.bound == nil or left_op.bound == ""
            local right_unknown =
                right_op.bound == nil or right_op.bound == ""
            if not left_unknown and not right_unknown
               and not equal_symbolic_values(
                    left_op.bound, right_op.bound) then
                return false
            end
        end
    end
    return true
end

equal_declarations = function(t1, t2)
    if type(t1) == "string" or type(t2) == "nil" then
        return t1 == t2
    end
    if not equal_declarations(t1.type, t2.type) then
        return false
    end
    if (t1._declarator_ops or t2._declarator_ops)
       and not equal_declarator_operations(
            t1._declarator_ops, t2._declarator_ops) then
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
        if (t1._paramstyle or "prototype")
           ~= (t2._paramstyle or "prototype") then
            return false
        end
        if not equal_declarations(t1.ret.type, t2.ret.type) then
            return false
        end
        if not equal_lists(t1.params, t2.params) then
            return false
        end
        if t1.vararg ~= t2.vararg then
            return false
        end
    elseif t1.type == "functionptr" then
        if (t1._paramstyle or "prototype")
           ~= (t2._paramstyle or "prototype") then
            return false
        end
        if not equal_declarations(t1.ret.type, t2.ret.type) then
            return false
        end
        if not equal_lists(t1.params, t2.params) then
            return false
        end
        if t1.vararg ~= t2.vararg then
            return false
        end
        if not equal_lists(t1.pointer, t2.pointer) then
            return false
        end
    end
    return true
end

local function is_modifier(str)
    return str == "*" or str == "restrict"
        or str == "const" or str == "volatile"
end

local function extract_modifiers(ret_pointer, items)
    while is_modifier(items[1]) do
        table.insert(ret_pointer, table.remove(items, 1))
    end
end

local function leading_modifiers(items)
    local ret_pointer = {}
    if type(items) ~= "table" then
        return ret_pointer
    end
    local first = items[1]
    if type(first) == "table" then
        for _, item in ipairs(first) do
            if is_modifier(item) then
                table.insert(ret_pointer, item)
            end
        end
    else
        for _, item in ipairs(items) do
            if is_modifier(item) then
                table.insert(ret_pointer, item)
            else
                break
            end
        end
    end
    return ret_pointer
end

local function prepend_modifiers(prefix, rest)
    if not prefix or #prefix == 0 then
        return rest
    end
    local out = {}
    for _, item in ipairs(prefix) do
        table.insert(out, item)
    end
    for _, item in ipairs(rest) do
        table.insert(out, item)
    end
    return out
end

local function declarator_has_pointer(declarator)
    if type(declarator) ~= "table" then
        return false
    end
    if declarator.declarator and declarator_has_pointer(declarator.declarator) then
        return true
    end
    for _, part in ipairs(declarator) do
        if type(part) == "table" then
            for _, modifier in ipairs(part) do
                if modifier == "*" or modifier == "^" then
                    return true
                end
            end
        elseif part == "*" or part == "^" then
            return true
        end
    end
    return false
end

local function is_function_pointer_declarator(decl)
    return decl.declarator and declarator_has_pointer(decl.declarator)
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
local make_declarator_type

-- C declarators apply operators from the declaration specifiers out toward
-- the identifier. Parentheses therefore change the order in which pointer,
-- array, and function operators are applied. Preserve that order explicitly
-- instead of flattening a nested declarator into an independent pointer list
-- and array-dimension list.
local function collect_declarator_operations(decl, operations)
    operations = operations or {}
    if type(decl) ~= "table" then
        return operations
    end

    for _, modifier in ipairs(leading_modifiers(decl)) do
        operations[#operations + 1] = modifier
    end

    local dimensions = {}
    for _, part in ipairs(decl) do
        if type(part) == "table" and part.idx ~= nil then
            dimensions[#dimensions + 1] = {
                idx = calculate_or_original(part.idx),
            }
        end
    end
    for index = #dimensions, 1, -1 do
        operations[#operations + 1] = dimensions[index]
    end

    if decl.params then
        operations[#operations + 1] = {
            function_declarator = decl,
        }
    end
    if decl.declarator then
        collect_declarator_operations(decl.declarator, operations)
    end
    return operations
end

local function declarator_name(decl)
    if type(decl) ~= "table" then
        return type(decl) == "string" and decl or nil
    elseif decl.name then
        return decl.name
    elseif decl.declarator then
        return declarator_name(decl.declarator)
    end
end

local convert_value = typed("TypeList, table, boolean? -> CType?, string?", function (lst, src, adjust_function_parameter)
    local decl = src.id or src.ids
    if type(decl) == "table" then
        return make_declarator_type(
            lst, declarator_name(decl), src.type, decl,
            adjust_function_parameter)
    end

    local typ, err = get_type(lst, src, {})
    if not typ then return nil, err end
    return typed.table("CType", { name = nil, type = typ }), nil
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
    local by_name = {}
    local next_value = 0
    for _, v in ipairs(values) do
        local value
        if v.value then
            value = calculate_or_original(v.value, by_name)
        else
            value = next_value
        end
        -- Completion eligibility must use the original target-neutral expression;
        -- the historical `value` above intentionally uses host Lua arithmetic.
        table.insert(items, { name = v.id, value = value,
            expression = v.value, implicit = v.value == nil })
        if type(value) == "number" then
            by_name[v.id] = value
            next_value = value + 1
        else
            next_value = nil
        end
    end
    return items
end

local get_composite_type = typed("TypeList, string?, string, array, string, function -> CType, string",
                           function(lst, specid, spectype, parts, partsfield, get_parts)
    local name = specid
    local key = spectype .. "@" .. (name or tostring(parts))

    local typ = lst[key]
    if not typ then
        typ = typed.table("CType", {
            type = spectype,
            name = name,
        })
        lst[key] = typ
    end

    if parts then
        local err
        parts, err = get_parts(lst, parts)
        if not parts then
            return nil, err
        end
    end

    if parts then
        local completed = typed.table("CType", {
            type = spectype,
            name = name,
            [partsfield] = parts,
        })
        if typ[partsfield] and not equal_declarations(completed, typ) then
            return nil, "redeclaration for " .. key
        end
        typ[partsfield] = parts
    end

    if not typ._file_scope_tag and not typ._type_list_published then
        add_type(lst, key, typ)
        typ._type_list_published = true
    end

    return typ, key
end)

local function get_structunion(lst, spec)
    if spec.fields and not spec.fields[1] then
        spec.fields = { spec.fields }
    end
    local typ, key = get_composite_type(lst, spec.id, spec.type, spec.fields, "fields", get_fields)
    if typ then typ._tag_provenance = typ._tag_provenance or spec._c_tag_provenance end
    return typ, key
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
    if item._c_tag_binding == "prototype" then
        local scopes = lst.prototype_tags
        if not scopes then
            scopes = {}
            lst.prototype_tags = scopes
        end
        local scope = scopes[item._c_tag_scope_id]
        if not scope then
            scope = {}
            scopes[item._c_tag_scope_id] = scope
        end

        local typ = scope[item.id]
        if not typ then
            typ = typed.table("CType", {
                type = item.type,
                name = item.id,
                _prototype_scope_id = item._c_tag_scope_id,
                _allow_outer_binding = item._c_tag_allow_outer and true or false,
                _tag_provenance = item._c_tag_provenance,
            })
            scope[item.id] = typ
        end

        local parts = item.fields or item.values
        if parts then
            local converted, err
            if item.type == "enum" then
                converted, err = get_enum_items(lst, parts)
                if converted then typ.values = converted end
            else
                converted, err = get_fields(lst, parts)
                if converted then typ.fields = converted end
            end
            if not converted then return nil, err end
            typ._tag_provenance = item._c_tag_provenance or typ._tag_provenance
        end
        return typ
    end

    if item.id and not item.fields and not item.values then
        local key = item._c_tag_raw_key or (item.type .. "@" .. item.id)
        local canonical = lst[key]
        if not canonical then
            canonical = typed.table("CType", {
                type = item.type,
                name = item.id,
                _file_scope_tag = true,
                _tag_provenance = item._c_tag_provenance,
            })
            lst[key] = canonical
        end
        -- A declaration reference must not acquire fields merely because a
        -- later declaration completed the canonical raw tag during the
        -- registrar's whole-header pass. Keep a non-completing view here; the
        -- foreign-type converter interns it by the same raw key, and the raw
        -- canonical entry published after ordinary declarations completes
        -- that one Titan CStruct/CUnion object in place.
        return typed.table("CType", {
            type = item.type,
            name = item.id,
            _file_scope_tag = true,
            _canonical_tag = canonical,
            _tag_provenance = item._c_tag_provenance,
        })
    else
        local typ, key = get_fn(lst, item)
        if not typ then
            return nil, key
        end
        return typ
    end
end

local calculate

local function binop(val, env, fn)
    local e1, e2 = calculate(val[1], env), calculate(val[2], env)
    if type(e1) == "number" and type(e2) == "number" then
        return fn(e1, e2)
    else
        return { e1, e2, op = val.op }
    end
end

calculate = function(val, env)
    if type(val) == "string" then
        return tonumber(val) or (env and env[val]) or val
    end
    if type(val) ~= "table" then
        return val
    end
    if type(val) == "table" and val[1] and not val.op and not val.unop then
        if #val == 1 then
            return calculate(val[1], env)
        end
        return val
    end
    -- The language-expression grammar records both unary and binary operators
    -- in `op`; older hand-built expression values may still use `unop`.
    local unary = val.unop or (val.op and val[2] == nil and val.op)
    if unary == "+" then
        return calculate(val[1], env)
    elseif unary == "-" then
        local e = calculate(val[1], env)
        return type(e) == "number" and -e or { e, unop = "-" }
    end
    if val.op == "+" then
        return binop(val, env, function(a, b) return a + b end)
    elseif val.op == "-" then
        return binop(val, env, function(a, b) return a - b end)
    elseif val.op == "*" then
        return binop(val, env, function(a, b) return a * b end)
    elseif val.op == "/" then
        return binop(val, env, function(a, b) return a / b end)
    else
        return val
    end
end

calculate_or_original = function(val, env)
    local calculated = calculate(val, env)
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

local function same_names(left, right)
    if #left ~= #right then
        return false
    end
    for i = 1, #left do
        if left[i] ~= right[i] then
            return false
        end
    end
    return true
end

local function copy_names(names)
    if names == false then
        return false
    end
    local out = {}
    for _, name in ipairs(names) do
        table.insert(out, name)
    end
    return out
end

local function set_initial_paramnames(typ, paramnames)
    typ.paramnames = copy_names(paramnames)
    typ.paramnames_state = paramnames == false and "unknown" or "complete"
end

-- Parameter spellings are declaration metadata, not C type identity. Merge
-- them only after the ordinary declaration types have compared equal. An
-- incomplete prototype can be upgraded by a later complete one, while two
-- different complete lists permanently poison the declaration's name API.
local function merge_paramnames(previous, current)
    local previous_state = previous.paramnames_state or
        (previous.paramnames == false and "unknown" or "complete")
    local current_state = current.paramnames_state or
        (current.paramnames == false and "unknown" or "complete")

    if previous_state == "conflicting" then
        current.paramnames = false
        current.paramnames_state = "conflicting"
    elseif previous_state == "complete" then
        if current_state == "complete"
           and not same_names(previous.paramnames, current.paramnames) then
            current.paramnames = false
            current.paramnames_state = "conflicting"
        else
            current.paramnames = copy_names(previous.paramnames)
            current.paramnames_state = "complete"
        end
    elseif current_state ~= "complete" then
        current.paramnames = false
        current.paramnames_state = "unknown"
    end
end

local get_params = typed("TypeList, array, string? -> *, *, *", function(lst, params_src, paramstyle)
    local params = {}
    local vararg = false
    local paramnames = {}
    local seen_names = {}
    local names_available = paramstyle ~= "oldstyle"
        and (paramstyle == "prototype" or #params_src > 0)

    assert(not params_src.param)

    for _, param_src in ipairs(params_src) do
        if param_src == "..." then
            vararg = true
        elseif type(param_src) == "string" then
            return nil, "old-style function parameter lists are unsupported", false
        else
            local param, err =
                convert_value(lst, param_src.param, true)
            if not param then
                return nil, err, false
            end
            if not is_void(param) then
                table.insert(params, param)
                if type(param.name) ~= "string" or param.name == ""
                   or seen_names[param.name] then
                    names_available = false
                else
                    table.insert(paramnames, param.name)
                    seen_names[param.name] = true
                end
            end
        end
    end
    if not names_available then
        paramnames = false
    end
    return params, vararg, paramnames
end)

local function append_operations(parts, operations)
    local out = {}
    for _, part in ipairs(parts or {}) do out[#out + 1] = part end
    for _, operation in ipairs(operations or {}) do
        out[#out + 1] = operation
    end
    return out
end

local function legacy_operation_views(operations)
    local pointer, idxs = {}, {}
    for _, operation in ipairs(operations or {}) do
        if type(operation) == "string" then
            pointer[#pointer + 1] = operation
        elseif operation.idx ~= nil then
            -- The historical raw representation records dimensions in source
            -- order, while the exact operator path records application order.
            table.insert(idxs, 1, operation.idx)
        end
    end
    return pointer, next(idxs) and idxs or nil
end

local declaration_qualifiers = {
    const = true,
    restrict = true,
    volatile = true,
}

local declaration_qualifier_order = {
    "const",
    "restrict",
    "volatile",
}

local function copy_array(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[#out + 1] = value
    end
    return out
end

local function qualifier_set(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[value] = true
    end
    return out
end

local function qualifier_list(values)
    local present = type(values) == "table" and values or {}
    local out = {}
    for _, qualifier in ipairs(declaration_qualifier_order) do
        if present[qualifier] then
            out[#out + 1] = qualifier
        end
    end
    return out
end

local function same_qualifiers(left, right)
    return equal_symbolic_values(
        type(left) == "table" and left or {},
        type(right) == "table" and right or {})
end

local function canonical_base_parts(parts)
    local qualifiers_set = {}
    local strings, objects = {}, {}
    for _, part in ipairs(parts or {}) do
        if type(part) == "string"
           and declaration_qualifiers[part] then
            qualifiers_set[part] = true
        elseif type(part) == "string" then
            strings[#strings + 1] = part
        else
            objects[#objects + 1] = part
        end
    end
    table.sort(strings)
    local canonical = {}
    for _, part in ipairs(strings) do canonical[#canonical + 1] = part end
    for _, part in ipairs(objects) do canonical[#canonical + 1] = part end
    return canonical, qualifiers_set
end

local function canonical_base_object(value)
    if type(value) ~= "table" then return value end
    return value._canonical_tag or value
end

local function same_base_parts(left, right)
    if #left ~= #right then return false end
    for index, left_part in ipairs(left) do
        local right_part = right[index]
        if type(left_part) ~= type(right_part) then
            return false
        elseif type(left_part) == "table" then
            if canonical_base_object(left_part)
               ~= canonical_base_object(right_part) then
                return false
            end
        elseif left_part ~= right_part then
            return false
        end
    end
    return true
end

local declaration_shape

local function copy_shape_with_outer_qualifiers(shape, qualifiers_set)
    if not next(qualifiers_set) then return shape end
    local out = {}
    for key, value in pairs(shape) do out[key] = value end
    out.qualifiers = qualifier_set(qualifier_list(shape.qualifiers))
    for qualifier in pairs(qualifiers_set) do
        out.qualifiers[qualifier] = true
    end
    return out
end

local function apply_shape_operations(shape, operations)
    local normalized = normalized_declarator_operations(operations)
    if not normalized then return nil end
    for _, operation in ipairs(normalized) do
        if operation.kind == "pointer" then
            shape = {
                kind = "pointer",
                pointee = shape,
                qualifiers = operation.qualifiers,
                template = shape.template,
                array_origin = shape.array_origin,
            }
        else
            shape = {
                kind = "array",
                elem = shape,
                bound = operation.bound,
                qualifiers = {},
                template = shape.template,
                array_origin = true,
            }
        end
    end
    return shape
end

local function shape_from_base(lst, parts, operations, seen, template)
    local base_parts, base_qualifiers =
        canonical_base_parts(parts)
    local alias
    if #base_parts == 1 and type(base_parts[1]) == "string" then
        local candidate = lst[base_parts[1]]
        if candidate and candidate.type == "typedef" then
            alias = candidate
        end
    end

    local shape
    if alias and not seen[alias] then
        shape = declaration_shape(lst, alias, seen)
        if not shape then return nil end
        shape = copy_shape_with_outer_qualifiers(
            shape, base_qualifiers)
    else
        shape = {
            kind = "base",
            parts = base_parts,
            qualifiers = base_qualifiers,
            template = template,
        }
    end
    shape = apply_shape_operations(shape, operations)
    if shape then shape.template = template end
    return shape
end

local function adjust_parameter_shape(shape)
    if shape.kind == "array" then
        return {
            kind = "pointer",
            pointee = shape.elem,
            qualifiers = qualifier_set(
                qualifier_list(shape.qualifiers)),
            template = shape.template,
            array_origin = true,
        }
    elseif shape.kind == "function" then
        return {
            kind = "pointer",
            pointee = shape,
            qualifiers = {},
            template = shape.template,
            array_origin = shape.array_origin,
        }
    elseif shape.kind == "pointer"
       and next(shape.qualifiers or {}) then
        local adjusted = {}
        for key, value in pairs(shape) do adjusted[key] = value end
        -- Qualification of the parameter object itself is not part of the
        -- adjusted C function type.
        adjusted.qualifiers = {}
        return adjusted
    end
    return shape
end

declaration_shape = function(lst, typ, seen)
    if type(typ) ~= "table" then return nil end
    seen = seen or {}
    if seen[typ] then return nil end
    seen[typ] = true

    local shape
    if typ.type == "typedef" then
        if type(typ.def) == "table"
           and typ.def.type == "functionptr" then
            shape = declaration_shape(lst, typ.def, seen)
        elseif typ._declarator_base then
            shape = shape_from_base(
                lst, typ._declarator_base,
                typ._declarator_ops, seen, typ)
        elseif type(typ.def) == "table" then
            shape = shape_from_base(
                lst, typ.def, nil, seen, typ)
        end
    elseif typ.type == "function"
       or typ.type == "functionptr" then
        local return_shape =
            declaration_shape(lst, typ.ret, seen)
        if return_shape then
            local params = {}
            for _, parameter in ipairs(typ.params or {}) do
                local parameter_shape =
                    declaration_shape(lst, parameter, seen)
                if not parameter_shape then
                    return nil
                end
                params[#params + 1] =
                    adjust_parameter_shape(parameter_shape)
            end
            shape = {
                kind = "function",
                ret = return_shape,
                params = params,
                vararg = typ.vararg and true or false,
                paramstyle = typ._paramstyle,
                qualifiers = {},
                template = typ,
            }
            shape = apply_shape_operations(
                shape, typ._declarator_ops)
        end
    elseif typ._declarator_base then
        shape = shape_from_base(
            lst, typ._declarator_base,
            typ._declarator_ops, seen, typ)
    elseif type(typ.type) == "table" then
        local operations = {}
        for index = #(typ.idxs or {}), 1, -1 do
            operations[#operations + 1] = {
                idx = typ.idxs[index],
            }
        end
        shape = shape_from_base(
            lst, typ.type, operations, seen, typ)
    end

    seen[typ] = nil
    return shape
end

local function merge_declaration_shapes(left, right)
    if not left or not right or left.kind ~= right.kind
       or not same_qualifiers(
            left.qualifiers, right.qualifiers) then
        return nil
    end

    local merged = {
        kind = right.kind,
        qualifiers = qualifier_set(
            qualifier_list(right.qualifiers)),
        template = right.template or left.template,
        array_origin =
            left.array_origin or right.array_origin,
    }
    if left.kind == "base" then
        if not same_base_parts(left.parts, right.parts) then
            return nil
        end
        merged.parts = copy_array(right.parts)
    elseif left.kind == "pointer" then
        merged.pointee =
            merge_declaration_shapes(left.pointee, right.pointee)
        if not merged.pointee then return nil end
    elseif left.kind == "array" then
        merged.elem =
            merge_declaration_shapes(left.elem, right.elem)
        if not merged.elem then return nil end
        local left_unknown =
            left.bound == nil or left.bound == ""
        local right_unknown =
            right.bound == nil or right.bound == ""
        if not left_unknown and not right_unknown
           and not equal_symbolic_values(
                left.bound, right.bound) then
            return nil
        end
        merged.bound =
            not right_unknown and right.bound or left.bound
    elseif left.kind == "function" then
        if left.vararg ~= right.vararg
           or #left.params ~= #right.params then
            return nil
        end
        merged.ret =
            merge_declaration_shapes(left.ret, right.ret)
        if not merged.ret then return nil end
        merged.params = {}
        for index, right_parameter in ipairs(right.params) do
            local parameter = merge_declaration_shapes(
                left.params[index], right_parameter)
            if not parameter then return nil end
            merged.params[index] = parameter
        end
        merged.vararg = right.vararg
        merged.paramstyle =
            right.paramstyle or left.paramstyle
    else
        return nil
    end
    return merged
end

local function shape_has_array(shape, seen)
    if not shape then return false end
    if shape.kind == "array" or shape.array_origin then
        return true
    end
    seen = seen or {}
    if seen[shape] then return false end
    seen[shape] = true
    if shape.kind == "pointer" then
        return shape_has_array(shape.pointee, seen)
    elseif shape.kind == "function" then
        if shape_has_array(shape.ret, seen) then return true end
        for _, parameter in ipairs(shape.params or {}) do
            if shape_has_array(parameter, seen) then return true end
        end
    end
    return false
end

local function decompose_declaration_shape(shape)
    if shape.kind == "base" or shape.kind == "function" then
        return shape, {}
    end

    local child = shape.kind == "pointer"
        and shape.pointee or shape.elem
    local core, operations =
        decompose_declaration_shape(child)
    if shape.kind == "pointer" then
        operations[#operations + 1] = "*"
        for _, qualifier in ipairs(
                qualifier_list(shape.qualifiers)) do
            operations[#operations + 1] = qualifier
        end
    else
        operations[#operations + 1] = {
            idx = shape.bound == nil and "" or shape.bound,
        }
    end
    return core, operations
end

local function shape_to_declaration(shape, template)
    local core, operations =
        decompose_declaration_shape(shape)
    template = template or shape.template or core.template or {}
    local name = template.name

    if core.kind == "function" then
        local params = {}
        for index, parameter in ipairs(core.params or {}) do
            params[index] = shape_to_declaration(
                parameter,
                parameter.template
                    or (core.template
                        and core.template.params
                        and core.template.params[index]))
        end
        local pointer, idxs =
            legacy_operation_views(operations)
        local typ = typed.table("CType", {
            type = #operations == 0
                and "function" or "functionptr",
            name = name,
            idxs = idxs,
            ret = shape_to_declaration(
                core.ret,
                core.ret.template
                    or (core.template and core.template.ret)),
            params = params,
            vararg = core.vararg,
            pointer = pointer,
            _paramstyle = core.paramstyle,
            _declarator_ops = operations,
        })
        local names_source =
            (template.type == "function"
                or template.type == "functionptr")
            and template or core.template
        if names_source and names_source.paramnames ~= nil then
            typ.paramnames =
                copy_names(names_source.paramnames)
            typ.paramnames_state =
                names_source.paramnames_state
        else
            set_initial_paramnames(typ, false)
        end
        return typ
    end

    local base = qualifier_list(core.qualifiers)
    for _, part in ipairs(core.parts) do
        base[#base + 1] = part
    end
    local pointer, idxs =
        legacy_operation_views(operations)
    return typed.table("CType", {
        name = name,
        type = append_operations(base, pointer),
        idxs = idxs,
        _declarator_base = base,
        _declarator_ops = operations,
    })
end

local function composite_array_declaration(lst, previous, current)
    local previous_shape =
        declaration_shape(lst, previous)
    local current_shape =
        declaration_shape(lst, current)
    local merged = merge_declaration_shapes(
        previous_shape, current_shape)
    if not merged
       or not (shape_has_array(previous_shape)
            or shape_has_array(current_shape)) then
        return nil
    end

    local typ = shape_to_declaration(merged, current)
    typ._declaration_provenance =
        current._declaration_provenance
    return typ
end

local function composite_oldstyle_function(previous, current)
    local previous_function =
        previous.type == "function"
        or previous.type == "functionptr"
    local current_function =
        current.type == "function"
        or current.type == "functionptr"
    if not previous_function or not current_function then
        return nil
    end

    local previous_style =
        previous._paramstyle or "prototype"
    local current_style =
        current._paramstyle or "prototype"
    if previous_style == current_style then return nil end

    local oldstyle = previous_style == "oldstyle"
        and previous or current_style == "oldstyle"
        and current
    local prototype = previous_style == "prototype"
        and previous or current_style == "prototype"
        and current
    if not oldstyle or not prototype
       or #(oldstyle.params or {}) ~= 0
       or oldstyle.vararg
       or prototype.vararg
       or previous.type ~= current.type
       or not equal_declarations(
            previous.ret, current.ret)
       or not equal_declarator_operations(
            previous._declarator_ops,
            current._declarator_ops) then
        return nil
    end

    -- C accepts this pair only when every prototype parameter survives the
    -- default argument promotions. The registrar cannot decide that from its
    -- best-effort target model, so it retains the informative prototype
    -- tentatively; the checker's unconditional ordered-header compiler
    -- baseline is authoritative for rejecting an invalid pair.
    return prototype
end

local function complete_declarator_bounds(previous, current)
    if type(previous) ~= "table" or type(current) ~= "table" then
        return
    end

    local previous_ops = previous._declarator_ops or {}
    local current_ops = current._declarator_ops or {}
    if #previous_ops == #current_ops then
        for index, current_op in ipairs(current_ops) do
            local previous_op = previous_ops[index]
            if type(previous_op) == "table"
               and type(current_op) == "table"
               and previous_op.idx ~= nil
               and current_op.idx ~= nil
               and current_op.idx == ""
               and previous_op.idx ~= "" then
                current_op.idx = previous_op.idx
            end
        end
        local pointer, idxs =
            legacy_operation_views(current_ops)
        current.idxs = idxs
        if current.type == "functionptr" then
            current.pointer = pointer
        end
    end

    if (previous.type == "function"
        or previous.type == "functionptr")
       and (current.type == "function"
        or current.type == "functionptr") then
        complete_declarator_bounds(previous.ret, current.ret)
        for index, parameter in ipairs(current.params or {}) do
            complete_declarator_bounds(
                previous.params and previous.params[index],
                parameter)
        end
    elseif previous.type == "typedef"
       and current.type == "typedef"
       and type(previous.def) == "table"
       and type(current.def) == "table"
       and previous.def.type
       and current.def.type then
        complete_declarator_bounds(previous.def, current.def)
    end
end

make_declarator_type = function(
        lst, name, spec, decl, adjust_function_parameter)
    local base_type, err = get_type(lst, spec, {})
    if not base_type then return nil, err end

    local operations = collect_declarator_operations(decl)
    local function_index
    for index, operation in ipairs(operations) do
        if type(operation) == "table"
           and operation.function_declarator then
            if function_index then
                return nil, "nested C function declarators are unsupported"
            end
            function_index = index
        end
    end

    if not function_index then
        local _, _, legacy_pointer, legacy_idxs = get_name(decl)
        local legacy_type =
            append_operations(base_type, legacy_pointer)
        return typed.table("CType", {
            name = name,
            type = legacy_type,
            idxs = legacy_idxs,
            _declarator_base = base_type,
            _declarator_ops = operations,
        }), nil
    end

    local function_marker = operations[function_index]
    local return_operations, value_operations = {}, {}
    for index = 1, function_index - 1 do
        return_operations[#return_operations + 1] = operations[index]
    end
    for index = function_index + 1, #operations do
        value_operations[#value_operations + 1] = operations[index]
    end

    -- A parameter declared with bare function type is adjusted by C to a
    -- pointer to that function. Parenthesized function pointers and arrays of
    -- callbacks already carry their own value-side operators.
    if adjust_function_parameter and #value_operations == 0 then
        value_operations[#value_operations + 1] = "*"
    end

    local params, vararg, paramnames = get_params(
        lst, function_marker.function_declarator.params,
        function_marker.function_declarator.paramstyle)
    if not params then return nil, vararg end

    local pointer, idxs = legacy_operation_views(value_operations)
    local typ = typed.table("CType", {
        type = #value_operations == 0 and "function" or "functionptr",
        name = name,
        idxs = idxs,
        ret = {
            type = append_operations(base_type, return_operations),
            _declarator_base = base_type,
            _declarator_ops = return_operations,
        },
        params = params,
        vararg = vararg,
        pointer = pointer,
        _paramstyle =
            function_marker.function_declarator.paramstyle,
        _declarator_ops = value_operations,
    })
    set_initial_paramnames(typ, paramnames)
    return typ
end

local register_many = function(register_item_fn, lst, ids, spec, provenance)
    for _, id in ipairs(ids) do
        local ok, err =
            register_item_fn(lst, id, spec, provenance)
        if not ok then
            return false, err
        end
    end
    return true, nil
end

local register_decl_item = function(lst, id, spec, provenance)
    local name = declarator_name(id.decl)
    assert(name)
    local typ, err =
        make_declarator_type(lst, name, spec, id.decl, false)
    if not typ then return false, err end

    typ._declaration_provenance = provenance

    if lst[name] then
        if not equal_declarations(lst[name], typ) then
            local composite =
                composite_oldstyle_function(
                    lst[name], typ)
                or
                composite_array_declaration(
                    lst, lst[name], typ)
            if not composite then
                return false, "inconsistent declaration for " .. name .. " - " .. inspect(lst[name]) .. " VERSUS " .. inspect(typ)
            end
            typ = composite
        else
            complete_declarator_bounds(lst[name], typ)
        end
        if (typ.type == "function" or typ.type == "functionptr")
           and (lst[name].type == "function" or lst[name].type == "functionptr") then
            merge_paramnames(lst[name], typ)
        end
    end
    add_type(lst, name, typ)

    return true, nil
end

local register_decls = function(lst, item)
    return register_many(
        register_decl_item, lst, item.ids, item.spec,
        item._declaration_provenance)
end

-- Convert a parsed function definition into one compatible with
-- `register_decl`. Header definitions may be extern, static, or bare inline;
-- Darwin's __header_inline uses the last form under AppleClang in C99 mode.
local function register_function(lst, item)
    -- Preserve the complete definition declarator. Reconstructing only its
    -- name and parameter list silently discarded return-pointer/array shape
    -- from definitions such as `static struct Opaque *identity(...)`.
    local id = { decl = item.func }
    return register_decl_item(
        lst, id, item.spec, item._declaration_provenance)
end

local register_typedef_item = typed("TypeList, table, table, table? -> boolean, string?", function(lst, id, spec, provenance)
    local name = declarator_name(id.decl)
    if not name then return false, "could not find typedef name" end
    local def, err =
        make_declarator_type(lst, name, spec, id.decl, false)
    if not def then return false, err or "failed" end
    if def.type == "function" then
        -- A typedef of a bare C function type (not a function pointer)
        -- remains out of scope; do not mis-model it as a callable value.
        return true, nil
    end
    local typ = typed.table("CType", {
        type = "typedef",
        name = name,
        def = def.type == "functionptr" and def or def.type,
        idxs = def.idxs,
        _declarator_base = def._declarator_base,
        _declarator_ops = def._declarator_ops,
        _declaration_provenance = provenance,
        _ffi_scope = provenance and provenance.ffi_scope,
    })

    if lst[name] then
        if not equal_declarations(lst[name], typ) then
            return false, "inconsistent declaration for " .. name .. " - " .. inspect(lst[name]) .. " VERSUS " .. inspect(typ)
        end
        complete_declarator_bounds(lst[name], typ)
        -- Compatible redeclarations name the original C typedef; a later
        -- include does not move it into that consumer's module namespace.
        typ._ffi_scope = lst[name]._ffi_scope or typ._ffi_scope
    end
    add_type(lst, name, typ)

    return true, nil
end)

local register_typedefs = function(lst, item)
    return register_many(
        register_typedef_item, lst, item.ids, item.spec,
        item._declaration_provenance)
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
    if item.func then
        return register_function(lst, item)
    elseif spec_set.extern and item.ids then
        return register_decls(lst, item)
    elseif spec_set.typedef then
        return register_typedefs(lst, item)
    elseif (spec_type == "struct" or spec_type == "union")
           and not item.ids then
        return register_structunion(lst, item)
    elseif spec_type == "enum" and not item.ids then
        return register_enum(lst, item)
    elseif not item.ids then
        return true -- forward declaration (e.g. "struct foo;")
    elseif item.ids then
        return register_decls(lst, item)
    else
        return false, "uncategorized declaration"
    end
end

local tag_kinds = {
    struct = true,
    union = true,
    enum = true,
}

local function syntactic_declarator_name(decl)
    if type(decl) ~= "table" then return nil end
    if decl.name then return decl.name end
    if decl.declarator then
        return syntactic_declarator_name(decl.declarator)
    end
end

local function each_tag_spec(spec, visit, seen)
    if type(spec) ~= "table" then return end
    seen = seen or {}
    if seen[spec] then return end
    seen[spec] = true

    if tag_kinds[spec.type] then
        visit(spec)
        -- A struct/union member list is not a C tag scope. Tags introduced by
        -- member declaration specifiers therefore remain file-scoped when the
        -- containing aggregate is declared at file scope.
        for _, field in ipairs(spec.fields or {}) do
            each_tag_spec(field.type or field.spec, visit, seen)
        end
        return
    end
    for _, part in ipairs(spec) do
        each_tag_spec(part, visit, seen)
    end
end

local function prescan_declarations(parsed, options)
    options = options or {}
    local metadata = {
        typedef_names = {},
        file_scope_tags = {},
        file_scope_tag_order = {},
        next_prototype_scope = 0,
    }
    local visible_tags = {}
    local current_position

    local function provenance(order, scope, definition, spec)
        local nominal_scope, line, column
        if options.declaration_scope then
            nominal_scope, line, column = options.declaration_scope(
                spec and spec._source_position or current_position)
        end
        if nominal_scope then
            nominal_scope = nominal_scope .. "." .. (spec and spec.type or "typedef")
            if spec and (not spec.id or scope:match("^prototype")) then
                nominal_scope = nominal_scope .. ".site" .. line .. "_" .. column
            end
        end
        return {
            header = options.header,
            declaration_order = order,
            scope = scope,
            definition = definition and true or false,
            ffi_scope = nominal_scope,
        }
    end

    local function record_file_tag(spec, order)
        if not spec.id then
            if options.declaration_scope then
                spec._c_tag_provenance = provenance(order, "file", true, spec)
            end
            return true
        end
        local name = spec.id
        local kind = spec.type
        local previous = visible_tags[name]
        if previous and previous.kind ~= kind then
            local old = previous.declarations[#previous.declarations]
            return nil, ("conflicting C tag kinds for '%s' in foreign header '%s': "
                .. "%s declaration at item %d conflicts with %s declaration at item %d")
                :format(name, options.header or "<unknown>",
                    previous.kind, old.declaration_order, kind, order)
        end

        local record = previous
        if not record then
            record = {
                name = name,
                kind = kind,
                raw_key = kind .. "@" .. name,
                declarations = {},
            }
            visible_tags[name] = record
            metadata.file_scope_tags[name] = record
            table.insert(metadata.file_scope_tag_order, record)
        end
        local prov = provenance(order, "file", spec.fields or spec.values, spec)
        table.insert(record.declarations, prov)
        record.defined = record.defined or prov.definition
        spec._c_tag_binding = "file"
        spec._c_tag_raw_key = record.raw_key
        spec._c_tag_provenance = prov
        return true
    end

    local function prototype_tag_conflict(name, scope, previous_kind,
                                          current_kind)
        return ("conflicting C tag kinds for '%s' in prototype scope %d "
            .. "of foreign header '%s': %s conflicts with %s")
            :format(name, scope.id, options.header or "<unknown>",
                previous_kind, current_kind)
    end

    local function find_prototype_tag(scope, name)
        while scope do
            local tag = scope.tags[name]
            if tag then return tag, scope end
            scope = scope.parent
        end
    end

    local function bind_prototype_spec(spec, tag, owner_scope, order,
                                       is_definition)
        tag.specs = tag.specs or {}
        tag.specs[#tag.specs + 1] = spec
        if is_definition then
            tag.defined = true
            tag.allow_outer = false
            -- A later definition in the same prototype scope establishes that
            -- the tag is local. Earlier forward references must not
            -- opportunistically bind a file tag imported from another header.
            for _, previous_spec in ipairs(tag.specs) do
                previous_spec._c_tag_allow_outer = false
            end
        end
        spec._c_tag_binding = "prototype"
        spec._c_tag_scope_id = owner_scope.id
        spec._c_tag_allow_outer = tag.allow_outer
        spec._c_tag_provenance =
            provenance(order, "prototype:" .. owner_scope.id, is_definition, spec)
    end

    local function annotate_prototype_type(type_spec, scope, order)
        local ok, err = true
        each_tag_spec(type_spec, function(spec)
            if not ok then return end
            if not spec.id then
                if options.declaration_scope then
                    spec._c_tag_provenance = provenance(order, "prototype:" .. scope.id, true, spec)
                end
                return
            end
            local is_definition = spec.fields or spec.values
            if is_definition then
                -- A definition introduces or completes a tag in this exact
                -- prototype scope; unlike a reference it may shadow an outer
                -- prototype or file-scope tag.
                local local_tag = scope.tags[spec.id]
                if local_tag and local_tag.kind ~= spec.type then
                    ok = false
                    err = prototype_tag_conflict(
                        spec.id, scope, local_tag.kind, spec.type)
                    return
                elseif not local_tag then
                    local_tag = {
                        kind = spec.type,
                        allow_outer = false,
                    }
                    scope.tags[spec.id] = local_tag
                end
                bind_prototype_spec(
                    spec, local_tag, scope, order, true)
                return
            end

            local local_tag, owner_scope =
                find_prototype_tag(scope, spec.id)
            if local_tag then
                if local_tag.kind ~= spec.type then
                    ok = false
                    err = prototype_tag_conflict(
                        spec.id, scope, local_tag.kind, spec.type)
                    return
                end
                bind_prototype_spec(
                    spec, local_tag, owner_scope, order, false)
                return
            end

            -- A tag reference consults the ordinary visible tag namespace
            -- without filtering by kind first: using "union T" when "struct
            -- T" is visible is a constraint violation, not a new prototype
            -- tag.
            local visible = visible_tags[spec.id]
            if visible then
                if visible.kind ~= spec.type then
                    ok = false
                    err = prototype_tag_conflict(
                        spec.id, scope, visible.kind, spec.type)
                    return
                end
                spec._c_tag_binding = "file"
                spec._c_tag_raw_key = visible.raw_key
                spec._c_tag_provenance =
                    provenance(order, "prototype-reference", false, spec)
                return
            end

            local_tag = {
                kind = spec.type,
                allow_outer = true,
            }
            scope.tags[spec.id] = local_tag
            bind_prototype_spec(spec, local_tag, scope, order, false)
        end)
        return ok, err
    end

    local annotate_aggregate_declarators
    local annotate_declarator
    annotate_declarator = function(decl, order, parent_scope)
        if type(decl) ~= "table" then return true end
        local declarator_scope = parent_scope
        if decl.params then
            metadata.next_prototype_scope =
                metadata.next_prototype_scope + 1
            local scope = {
                id = metadata.next_prototype_scope,
                tags = {},
                parent = parent_scope,
            }
            declarator_scope = scope
            for _, wrapped in ipairs(decl.params) do
                local param = wrapped.param or wrapped
                local ok, err = annotate_prototype_type(
                    param.type, scope, order)
                if not ok then return nil, err end
                ok, err = annotate_aggregate_declarators(
                    param.type, order, scope)
                if not ok then return nil, err end
                ok, err = annotate_declarator(param.id, order, scope)
                if not ok then return nil, err end
            end
        end
        if decl.declarator then
            return annotate_declarator(
                decl.declarator, order, declarator_scope)
        end
        return true
    end

    -- Aggregate member declaration specifiers live in the aggregate's
    -- enclosing tag scope, but a function declarator nested in a member opens
    -- its own prototype scope. Walk the two pieces separately so callback
    -- parameter tags never leak into file-scope metadata.
    annotate_aggregate_declarators = function(type_spec, order, parent_scope,
                                               seen)
        if type(type_spec) ~= "table" then return true end
        seen = seen or {}
        if seen[type_spec] then return true end
        seen[type_spec] = true

        if tag_kinds[type_spec.type] then
            for _, field in ipairs(type_spec.fields or {}) do
                local field_type = field.type or field.spec
                local ok, err = annotate_aggregate_declarators(
                    field_type, order, parent_scope, seen)
                if not ok then return nil, err end
                for _, id in ipairs(field.ids or {}) do
                    ok, err = annotate_declarator(
                        id.decl or id,
                        order, parent_scope)
                    if not ok then return nil, err end
                end
            end
            return true
        end
        for _, part in ipairs(type_spec) do
            local ok, err = annotate_aggregate_declarators(
                part, order, parent_scope, seen)
            if not ok then return nil, err end
        end
        return true
    end

    for order, item in ipairs(parsed) do
        current_position = item._source_position
        if options.declaration_scope then
            item._declaration_provenance = provenance(order, "file", false)
        end
        local spec_set = util.to_set(item.spec)
        if spec_set.typedef then
            for _, id in ipairs(item.ids or {}) do
                local name = syntactic_declarator_name(id.decl)
                if name then metadata.typedef_names[name] = true end
            end
        end

        local ok, err = true
        each_tag_spec(item.spec, function(spec)
            if not ok then return end
            ok, err = record_file_tag(spec, order)
        end)
        if not ok then return nil, err end
        ok, err = annotate_aggregate_declarators(
            item.spec, order, nil)
        if not ok then return nil, err end

        for _, id in ipairs(item.ids or {}) do
            ok, err = annotate_declarator(id.decl, order, nil)
            if not ok then return nil, err end
        end
        if item.func then
            ok, err = annotate_declarator(item.func, order, nil)
            if not ok then return nil, err end
        end
    end

    return metadata
end

ctypes.register_types = typed("{Decl}, table? -> TypeList?, string?", function(parsed, options)
    local metadata, metadata_error = prescan_declarations(parsed, options)
    if not metadata then
        return nil, metadata_error
    end

    local lst = typed.table("TypeList", {})
    lst.typedef_names = metadata.typedef_names
    lst.file_scope_tags = metadata.file_scope_tags
    lst.prototype_tags = {}

    -- Seed every syntactic file-scope tag before best-effort conversion. This
    -- retains forward tags reached only through typedefs or pointer
    -- declarations and gives all declarations in this header one canonical
    -- raw CType object.
    for _, record in ipairs(metadata.file_scope_tag_order) do
        local typ = typed.table("CType", {
            type = record.kind,
            name = record.name,
            _file_scope_tag = true,
            _file_scope_tag_metadata = record,
            _tag_provenance = record.declarations[1],
        })
        lst[record.raw_key] = typ
        record.raw_type = typ
    end

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

    -- Publish canonical file tags after ordinary declaration entries.
    -- Forward typedefs/functions/objects therefore create incomplete Titan
    -- owners first, while this final entry supplies a definition only after
    -- every supporting typedef from the header has been converted.
    for _, record in ipairs(metadata.file_scope_tag_order) do
        table.insert(lst, {
            name = record.raw_key,
            type = record.raw_type,
        })
    end

    ctypes.skipped = skipped
    return lst, nil
end)

-- Convert a parsed C type-name (the first child of a cast expression) through
-- the exact declarator path used by real object declarations. A type-name has
-- no identifier: its optional final untyped table is the abstract declarator,
-- while aggregate/enum specifier tables carry their own `type` tag and remain
-- part of the declaration specifiers.
function ctypes.declaration_from_type_name(lst, name, type_name)
    if type(lst) ~= "table" then
        return nil, "type-name conversion requires a C type list"
    elseif type(name) ~= "string" or name == "" then
        return nil, "type-name conversion requires a declaration name"
    elseif type(type_name) ~= "table" or #type_name == 0 then
        return nil, "type-name conversion requires a parsed C type name"
    end

    local spec = {}
    local declarator = {}
    for index, part in ipairs(type_name) do
        if index == #type_name
           and type(part) == "table"
           and part.type == nil then
            declarator = part
        else
            spec[#spec + 1] = part
        end
    end
    if #spec == 0 then
        return nil, "parsed C type name has no declaration specifier"
    end
    return make_declarator_type(
        lst, name, spec, declarator, false)
end

return ctypes
