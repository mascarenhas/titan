-- Pure rendering of Titan's structural C types as C99 declarators.
--
-- C declarators grow around their name rather than reading strictly
-- left-to-right. Keeping that recursion here prevents declarations, casts,
-- and compiler probes from each approximating arrays and function pointers in
-- a different way.
local cdeclarator = {}

local types = require "titan-compiler.types"

local function tag_name(name)
    if type(name) == "table" then
        return table.concat(name, ".")
    end
    return name
end

local function qualified_base(base, quals)
    if quals and #quals > 0 then
        return table.concat(quals, " ") .. " " .. base
    end
    return base
end

local function finish_base(base, name, quals)
    base = qualified_base(base, quals)
    if name == "" then
        return base
    end
    return base .. " " .. name
end

local function aggregate_base(kind, typ)
    local tag = tag_name(typ.tagname or typ.cname)
    if tag then
        if tag:match("^" .. kind .. "%s+") then
            return tag
        end
        return kind .. " " .. tag
    elseif typ.typedef then
        -- Anonymous aggregates can only be named through their real typedef.
        return tag_name(typ.typedef)
    end
    error("cannot render anonymous C " .. kind .. " without a typedef", 3)
end

local function pointer_name(name, quals, parenthesize)
    local out = "*"
    if quals and #quals > 0 then
        out = out .. " " .. table.concat(quals, " ")
        if name ~= "" then
            out = out .. " "
        end
    end
    out = out .. name
    if parenthesize then
        out = "(" .. out .. ")"
    end
    return out
end

local function combined_qualifiers(first, second)
    if not first or #first == 0 then
        return second
    elseif not second or #second == 0 then
        return first
    end
    local out = {}
    for _, qual in ipairs(first) do
        table.insert(out, qual)
    end
    for _, qual in ipairs(second) do
        table.insert(out, qual)
    end
    return out
end

local binary_expression_operators = {
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
    ["+"] = true,
    ["-"] = true,
    ["<<"] = true,
    [">>"] = true,
    ["<"] = true,
    ["<="] = true,
    [">"] = true,
    [">="] = true,
    ["=="] = true,
    ["!="] = true,
    ["&"] = true,
    ["^"] = true,
    ["|"] = true,
    ["&&"] = true,
    ["||"] = true,
}

local unary_expression_operators = {
    ["+"] = true,
    ["-"] = true,
    ["~"] = true,
    ["!"] = true,
    ["*"] = true,
    ["&"] = true,
}

local render_extent_expression
local render_extent_type_fragment

local extent_pointer_qualifiers = {
    const = true,
    restrict = true,
    volatile = true,
    ["_Atomic"] = true,
}

local function is_extent_pointer_sequence(value)
    if type(value) ~= "table" or #value == 0 then return false end
    local saw_pointer = false
    for _, token in ipairs(value) do
        if token == "*" or token == "^" then
            saw_pointer = true
        elseif not extent_pointer_qualifiers[token] then
            return false
        end
    end
    return saw_pointer
end

local function render_extent_pointer_sequence(value, name)
    local pointer = table.concat(value, " ")
    if name == "" then return pointer end
    return pointer .. " " .. name
end

local function render_extent_array_suffix(value)
    local parts = {}
    if value.array_static then
        parts[#parts + 1] = "static"
    end
    for _, qualifier in ipairs(value.array_qualifiers or {}) do
        parts[#parts + 1] = qualifier
    end
    if value.idx ~= nil and value.idx ~= "" then
        parts[#parts + 1] = render_extent_expression(value.idx)
    end
    return table.concat(parts, " ")
end

local render_extent_type_name

local function render_extent_parameter(value)
    if value == "..." then return "..." end
    local parameter = type(value) == "table" and
        (value.param or value) or nil
    if not parameter or type(parameter.type) ~= "table" then
        error("cannot render a symbolic C array extent", 4)
    end
    return render_extent_type_name(parameter.type, parameter.id)
end

local function render_extent_parameters(params, paramstyle)
    local rendered = {}
    for _, parameter in ipairs(params or {}) do
        rendered[#rendered + 1] = render_extent_parameter(parameter)
    end
    if #rendered == 0 and paramstyle ~= "oldstyle" then
        rendered[1] = "void"
    end
    return table.concat(rendered, ", ")
end

local function render_extent_declarator(value, name)
    if value == nil then return name end
    if type(value) == "string" then
        return value ~= "" and value or name
    elseif type(value) ~= "table" then
        error("cannot render a symbolic C array extent", 4)
    end

    -- A pointer-only abstract declarator is captured directly rather than
    -- inside the ordinary declarator wrapper.
    if is_extent_pointer_sequence(value) then
        return render_extent_pointer_sequence(value, name)
    end

    local direct_name = value.name or name
    if value.declarator then
        direct_name = "(" ..
            render_extent_declarator(value.declarator, direct_name) .. ")"
    end

    for _, part in ipairs(value) do
        if is_extent_pointer_sequence(part) then
            direct_name =
                render_extent_pointer_sequence(part, direct_name)
        end
    end
    for _, part in ipairs(value) do
        if type(part) == "table" and part.idx ~= nil then
            direct_name = direct_name .. "[" ..
                render_extent_array_suffix(part) .. "]"
        end
    end
    if value.params ~= nil then
        direct_name = direct_name .. "(" ..
            render_extent_parameters(value.params, value.paramstyle) .. ")"
    end
    return direct_name
end

local function render_extent_base_part(value)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    elseif type(value) ~= "table" then
        error("cannot render a symbolic C array extent", 4)
    elseif value.type == "struct"
        or value.type == "union"
        or value.type == "enum" then
        if value.fields or value.values or not value.id then
            error("cannot render an inline C tag definition in an array extent",
                4)
        end
        return value.type .. " " .. value.id
    end
    error("cannot render a symbolic C array extent", 4)
end

local function is_extent_declarator(value)
    if is_extent_pointer_sequence(value) then return true end
    if type(value) ~= "table" then return false end
    if value.declarator ~= nil or value.params ~= nil
        or value.name ~= nil then
        return true
    end
    for _, part in ipairs(value) do
        if is_extent_pointer_sequence(part)
            or type(part) == "table" and part.idx ~= nil then
            return true
        end
    end
    return false
end

render_extent_type_name = function(parts, declarator)
    local base_count = #parts
    if declarator == nil and base_count > 0
        and is_extent_declarator(parts[base_count]) then
        declarator = parts[base_count]
        base_count = base_count - 1
    end

    local base = {}
    for index = 1, base_count do
        base[index] = render_extent_base_part(parts[index])
    end
    if #base == 0 then
        error("cannot render a symbolic C array extent", 4)
    end

    local rendered_declarator =
        render_extent_declarator(declarator, "")
    if rendered_declarator == "" then
        return table.concat(base, " ")
    end
    return table.concat(base, " ") .. " " .. rendered_declarator
end

-- Array extents retained by c-parser are syntax trees, not target values.
-- Render the bounded type-name subset that can occur in a cast or sizeof
-- operand without trying to evaluate it in host Lua. The configured C
-- compiler remains authoritative for whether the resulting expression is an
-- integer constant expression and whether two extents denote the same value.
render_extent_type_fragment = function(value)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    elseif type(value) ~= "table" then
        error("cannot render a symbolic C array extent", 4)
    elseif value.type == "struct"
        or value.type == "union"
        or value.type == "enum" then
        if value.fields or value.values or not value.id then
            error("cannot render an inline C tag definition in an array extent",
                4)
        end
        return value.type .. " " .. value.id
    elseif value.idx ~= nil then
        return "[" .. render_extent_array_suffix(value) .. "]"
    elseif type(value[1]) == "string"
        or type(value[1]) == "table"
        and (value[1].type == "struct"
            or value[1].type == "union"
            or value[1].type == "enum") then
        return render_extent_type_name(value)
    end

    local parts = {}
    for index = 1, #value do
        parts[index] = render_extent_type_fragment(value[index])
    end
    if #parts == 0 then
        error("cannot render a symbolic C array extent", 4)
    end
    return table.concat(parts, " ")
end

local function render_postfix_expression(base, postfix)
    if type(postfix) ~= "table" then
        error("cannot render a symbolic C array extent", 4)
    end
    if postfix.idx ~= nil then
        base = base .. "[" .. render_extent_expression(postfix.idx) .. "]"
    elseif postfix.args ~= nil then
        local args = {}
        for index, arg in ipairs(postfix.args) do
            args[index] = render_extent_expression(arg)
        end
        base = base .. "(" .. table.concat(args, ", ") .. ")"
    elseif postfix.dot then
        base = base .. "." .. postfix.dot
    elseif postfix.arrow then
        base = base .. "->" .. postfix.arrow
    else
        error("cannot render a symbolic C array extent", 4)
    end

    -- The grammar nests a following postfix operation as the sole positional
    -- child of the current postfix record.
    if postfix[1] ~= nil then
        return render_postfix_expression(base, postfix[1])
    end
    return base
end

local function looks_like_extent_type_fragment(value)
    if type(value) ~= "table" or value.op or value.unop
        or value.postfix then
        return false
    end
    if value.declarator ~= nil then return true end
    local first = value[1]
    if type(first) == "string" then return true end
    if type(first) == "table" then
        if #value == 2 and first.type == nil then
            -- A type-name cast is captured as { type-name, operand }; a raw
            -- type name with an abstract declarator starts with a string or a
            -- struct/union/enum descriptor instead.
            return false
        end
        return first.type == "struct"
            or first.type == "union"
            or first.type == "enum"
            or looks_like_extent_type_fragment(first)
    end
    return false
end

render_extent_expression = function(expression)
    local kind = type(expression)
    if kind == "number" or kind == "string" then
        return tostring(expression)
    elseif kind ~= "table" then
        error("cannot render a symbolic C array extent", 3)
    end

    local op = expression.op or expression.unop
    if op == "sizeof" then
        if expression[1] == nil or expression[2] ~= nil then
            error("cannot render a malformed sizeof array extent", 3)
        end
        local operand = looks_like_extent_type_fragment(expression[1])
            and render_extent_type_fragment(expression[1])
            or render_extent_expression(expression[1])
        return "(sizeof(" ..
            operand .. "))"
    elseif op == "?" then
        if expression[1] == nil or expression[2] == nil
            or expression[3] == nil or expression[4] ~= nil then
            error("cannot render a malformed conditional array extent", 3)
        end
        return "(" .. render_extent_expression(expression[1])
            .. " ? " .. render_extent_expression(expression[2])
            .. " : " .. render_extent_expression(expression[3]) .. ")"
    elseif op == "," then
        local parts = {}
        for index, part in ipairs(expression) do
            parts[index] = render_extent_expression(part)
        end
        if #parts == 0 then
            error("cannot render an empty comma array extent", 3)
        end
        return "(" .. table.concat(parts, ", ") .. ")"
    elseif op and expression[2] == nil
        and unary_expression_operators[op] then
        if expression[1] == nil then
            error("cannot render a malformed unary array extent", 3)
        end
        return "(" .. op .. render_extent_expression(expression[1]) .. ")"
    elseif op and binary_expression_operators[op] then
        if expression[1] == nil or expression[2] == nil
            or expression[3] ~= nil then
            error("cannot render a malformed binary array extent", 3)
        end
        return "(" .. render_extent_expression(expression[1])
            .. " " .. op .. " "
            .. render_extent_expression(expression[2]) .. ")"
    elseif op then
        error("cannot render unsupported operator '" .. tostring(op)
            .. "' in a symbolic C array extent", 3)
    end

    local rendered
    if #expression == 1 then
        rendered = render_extent_expression(expression[1])
    elseif #expression == 2 then
        -- The grammar represents a cast as { type-name, operand }.
        rendered = "((" .. render_extent_type_fragment(expression[1])
            .. ")" .. render_extent_expression(expression[2]) .. ")"
    else
        error("cannot render a symbolic C array extent", 3)
    end
    if expression.postfix then
        rendered = render_postfix_expression(rendered, expression.postfix)
    end
    return rendered
end

local function render_array_extent(len)
    if len == nil or len == false or len == "" then
        return ""
    elseif type(len) == "number" or type(len) == "string"
        or type(len) == "table" then
        return render_extent_expression(len)
    end
    error("cannot render a symbolic C array extent", 3)
end

local render_declarator

local function selected_typedef_target(typ, expand_typedef)
    local seen = {}
    while type(typ) == "table"
        and typ._tag == "Type.CTypedef"
        and expand_typedef
        and expand_typedef(typ)
        and not seen[typ] do
        seen[typ] = true
        typ = typ.target
    end
    return typ
end

local function render_parameter(typ, expand_typedef)
    -- A parameter written through a typedef keeps that spelling; the C
    -- compiler performs the required array/function adjustment after resolving
    -- it. Expanding here would discard useful header vocabulary.
    if typ._tag == "Type.CTypedef" then
        -- When a selected private alias is expanded, keep its array/function
        -- declarator intact here and let C perform parameter adjustment. That
        -- preserves typedef-level qualification on an array element.
        return render_declarator(typ, "", nil, expand_typedef)
    end
    return render_declarator(
        cdeclarator.adjust_parameter_type(typ), "", nil, expand_typedef)
end

local function render_parameters(typ, expand_typedef)
    local params = {}
    for _, param in ipairs(typ.params or {}) do
        table.insert(params, render_parameter(param, expand_typedef))
    end
    if typ.vararg then
        table.insert(params, "...")
    end
    if #params == 0 then
        if typ._paramstyle ~= "oldstyle" then
            table.insert(params, "void")
        end
    end
    return table.concat(params, ", ")
end

render_declarator = function(typ, name, quals, expand_typedef)
    local tag = typ and typ._tag
    if tag == "Type.CTypedef" then
        if expand_typedef and expand_typedef(typ) then
            return render_declarator(
                typ.target, name,
                combined_qualifiers(quals, typ.quals), expand_typedef)
        end
        return finish_base(typ.name, name, quals)
    elseif tag == "Type.COwned" then
        return render_declarator({
            _tag = "Type.CPointer",
            pointee = { _tag = "Type.CTypedef", name = "Udata", target = { _tag = "Type.CStruct", tagname = "Udata" }, quals = {} },
            quals = {},
        }, name, quals, expand_typedef)
    elseif tag == "Type.CVoid" then
        return finish_base("void", name, quals)
    elseif tag == "Type.CInteger" or tag == "Type.CFloat" then
        return finish_base(
            typ._c_declaration_spelling or typ.spelling, name, quals)
    elseif tag == "Type.CStruct" then
        return finish_base(aggregate_base("struct", typ), name, quals)
    elseif tag == "Type.CUnion" then
        return finish_base(aggregate_base("union", typ), name, quals)
    elseif tag == "Type.CPointer" then
        local declarator_pointee = selected_typedef_target(
            typ.pointee, expand_typedef)
        local pointee_tag = declarator_pointee
            and declarator_pointee._tag
        local resolved_pointee = types.resolve_c_typedef(typ.pointee)
        local points_to_function = resolved_pointee
            and resolved_pointee._tag == "Type.CFunction"
        -- C does not permit a qualified function type. Historical CPointer
        -- values therefore use this otherwise-pointee qualifier list for the
        -- function-pointer star itself.
        local star_quals = quals
        local pointee_quals = typ.quals
        if points_to_function then
            star_quals = combined_qualifiers(quals, typ.quals)
            pointee_quals = nil
        end
        local nested_name = pointer_name(name, star_quals,
            pointee_tag == "Type.CArray" or
            pointee_tag == "Type.CFunction")
        return render_declarator(
            typ.pointee, nested_name, pointee_quals, expand_typedef)
    elseif tag == "Type.CArray" then
        local len = render_array_extent(typ.len)
        return render_declarator(
            typ.elem, name .. "[" .. len .. "]",
            combined_qualifiers(quals, typ.quals), expand_typedef)
    elseif tag == "Type.CFunction" then
        if quals and #quals > 0 then
            error("cannot qualify a C function type", 3)
        end
        local nested_name = name .. "(" ..
            render_parameters(typ, expand_typedef) .. ")"
        return render_declarator(
            typ.ret, nested_name,
            typ._return_declaration_qualifiers, expand_typedef)
    end
    error("unknown foreign C type " .. tostring(tag), 3)
end

-- Apply the adjustment made to a parameter declared with an array or function
-- type. Resolving an alias is necessary when it hides one of those adjusted
-- shapes; aliases for ordinary object types remain untouched.
function cdeclarator.adjust_parameter_type(typ)
    local resolved = types.resolve_c_typedef(typ)
    if resolved._tag == "Type.CArray" then
        return types.CPointer(resolved.elem, resolved.quals or {})
    elseif resolved._tag == "Type.CFunction" then
        return types.CPointer(typ, {})
    end
    return typ
end

-- Render a C type name suitable for casts and expression-level type syntax.
-- Arrays and functions are not scalar cast targets; pointers to either are.
function cdeclarator.render_type_name(typ)
    local resolved = types.resolve_c_typedef(typ)
    if resolved and resolved._tag == "Type.CArray" then
        error("cannot render a C array as an expression type", 2)
    elseif resolved and resolved._tag == "Type.CFunction" then
        error("cannot render a C function as an expression type", 2)
    end
    return render_declarator(typ, "", nil)
end

-- Render a named C object or function declaration. This is deliberately the
-- only entry point that accepts a direct array type. `quals` carries the
-- declaration-level qualifiers that the C parser stores separately from the
-- structural type (for example the `const` in `extern const T value`).
function cdeclarator.render_declaration(
    typ, name, quals, expand_typedef)
    assert(type(name) == "string", "C declaration name must be a string")
    if expand_typedef ~= nil then
        assert(type(expand_typedef) == "function",
            "C typedef expansion selector must be a function")
    end
    return render_declarator(typ, name, quals, expand_typedef)
end

cdeclarator.render_array_extent = render_array_extent

return cdeclarator
