
local cdefines = {}

local c99 = require("c-parser.c99")
local cpp = require("c-parser.cpp")
local ctypes = require("c-parser.ctypes")
local typed = require("c-parser.typed")
local util = require("titan-compiler.util")

local function add_type(lst, name, typ)
    lst[name] = typ
    table.insert(lst, { name = name, type = typ })
end

local base_c_types = {
    CONST_CHAR_PTR = { "const", "char", "*" },
    CONST_CHAR = { "const", "char" },
    LONG_LONG = { "long", "long" },
    LONG = { "long" },
    FLOAT = { "float" },
    DOUBLE = { "double" },
    LONG_DOUBLE = { "long", "double" },
    INT = { "int" },
}

-- These GCC/Clang builtins are the constant leaves used by ordinary <math.h>
-- definitions of INFINITY, NAN and HUGE_VAL*. They need no C declarations.
-- This does not infer arbitrary calls or expose function-like macros.
local floating_constant_builtins = {}
for _, family in ipairs({ "inf", "huge_val", "nan", "nans" }) do
    for suffix, typ in pairs({
        f = base_c_types.FLOAT,
        [""] = base_c_types.DOUBLE,
        l = base_c_types.LONG_DOUBLE,
    }) do
        floating_constant_builtins["__builtin_" .. family .. suffix] = {
            type = typ,
            arguments = (family == "nan" or family == "nans") and 1 or 0,
        }
    end
end

local function floating_literal_type(token)
    -- The C grammar already validated this token. Exclude integer tokens
    -- before looking for exponent letters, which are also hexadecimal digits.
    if token:match("^0[xX][0-9a-fA-F]+[uUlL]*$")
       or token:match("^[0-9]+[uUlL]*$")
       or not token:match("^[0-9.]") then return nil end
    if token:match("[fF]$") then return base_c_types.FLOAT end
    if token:match("[lL]$") then return base_c_types.LONG_DOUBLE end
    return base_c_types.DOUBLE
end

local function floating_builtin_type(exp)
    local builtin = floating_constant_builtins[exp[1]]
    local postfix = exp.postfix
    local arguments = postfix and postfix.args
    if not builtin or not arguments or #arguments ~= builtin.arguments then
        return nil
    end
    for key in pairs(postfix) do if key ~= "args" then return nil end end
    if builtin.arguments == 1 then
        local arg = arguments[1]
        if #arg ~= 1 or type(arg[1]) ~= "string"
           or arg[1]:sub(1, 1) ~= '"' or arg.op or arg.postfix then
            return nil
        end
    end
    return builtin.type
end

-- Target-neutral metadata for an integer constant token. The candidate list is
-- the ordered C99 6.4.4.1 list; a later target profile chooses the first class
-- whose range contains the token's value. Keeping the candidates structured
-- avoids encoding target width, plain-char signedness, or the host Lua number
-- representation in the registrar.
local function candidate_class(rank, unsigned)
    local spelling
    if rank == "int" then
        spelling = unsigned and "unsigned int" or "int"
    elseif rank == "long" then
        spelling = unsigned and "unsigned long" or "long"
    else
        assert(rank == "long_long")
        spelling = unsigned and "unsigned long long" or "long long"
    end
    return {
        rank = rank,
        unsigned = unsigned,
        spelling = spelling,
    }
end

local function integer_candidates(base, rank_suffix, unsigned)
    if unsigned then
        if rank_suffix == "long_long" then
            return {
                candidate_class("long_long", true),
            }
        elseif rank_suffix == "long" then
            return {
                candidate_class("long", true),
                candidate_class("long_long", true),
            }
        else
            return {
                candidate_class("int", true),
                candidate_class("long", true),
                candidate_class("long_long", true),
            }
        end
    elseif base == "decimal" then
        if rank_suffix == "long_long" then
            return {
                candidate_class("long_long", false),
            }
        elseif rank_suffix == "long" then
            return {
                candidate_class("long", false),
                candidate_class("long_long", false),
            }
        else
            return {
                candidate_class("int", false),
                candidate_class("long", false),
                candidate_class("long_long", false),
            }
        end
    elseif rank_suffix == "long_long" then
        return {
            candidate_class("long_long", false),
            candidate_class("long_long", true),
        }
    elseif rank_suffix == "long" then
        return {
            candidate_class("long", false),
            candidate_class("long", true),
            candidate_class("long_long", false),
            candidate_class("long_long", true),
        }
    else
        return {
            candidate_class("int", false),
            candidate_class("int", true),
            candidate_class("long", false),
            candidate_class("long", true),
            candidate_class("long_long", false),
            candidate_class("long_long", true),
        }
    end
end

local function integer_literal_metadata(token)
    local base, radix, digits, suffix
    digits, suffix = token:match("^0[xX]([0-9a-fA-F]+)([uUlL]*)$")
    if digits then
        base, radix = "hexadecimal", 16
    else
        digits, suffix = token:match("^0([0-7]*)([uUlL]*)$")
        if digits then
            base, radix = "octal", 8
            if digits == "" then digits = "0" end
        else
            digits, suffix = token:match("^([1-9][0-9]*)([uUlL]*)$")
            if not digits then return nil end
            base, radix = "decimal", 10
        end
    end

    local normalized_suffix = suffix:lower()
    local unsigned = normalized_suffix:find("u", 1, true) ~= nil
    local rank_letters = normalized_suffix:gsub("u", "")
    local rank_suffix
    if rank_letters == "ll" then
        rank_suffix = "long_long"
    elseif rank_letters == "l" then
        rank_suffix = "long"
    else
        assert(rank_letters == "")
        rank_suffix = "none"
    end

    return {
        token = token,
        base = base,
        radix = radix,
        digits = digits,
        suffix = suffix,
        normalized_suffix = normalized_suffix,
        unsigned = unsigned,
        rank_suffix = rank_suffix,
        candidate_classes =
            integer_candidates(base, rank_suffix, unsigned),
    }
end

-- Compact declaration expressions retain exact token spellings and rebuild
-- this target-neutral information only while evaluating the expression.
cdefines.integer_literal_metadata = integer_literal_metadata

-- Annotate the parsed expression in place and return its integer literal
-- occurrences in deterministic source/tree order. Numeric children carry the
-- expression order; keyed child tables cover postfix/argument shapes without
-- relying on Lua's `pairs` order.
local function annotate_integer_literals(exp)
    local literals = {}
    local floating = false
    local seen = {}

    local function visit(node)
        if type(node) ~= "table" or seen[node] then return end
        seen[node] = true

        if #node == 1 and type(node[1]) == "string" then
            local metadata = integer_literal_metadata(node[1])
            if metadata then
                node.integer_literal = metadata
                literals[#literals + 1] = metadata
            elseif (not node.postfix and floating_literal_type(node[1]))
                   or floating_builtin_type(node) then
                floating = true
            end
        end

        for i = 1, #node do
            if type(node[i]) == "table" then visit(node[i]) end
        end

        local keys = {}
        for key, value in pairs(node) do
            if type(key) ~= "number" and key ~= "integer_literal"
               and type(value) == "table" then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys, function(left, right)
            return tostring(left) < tostring(right)
        end)
        for _, key in ipairs(keys) do visit(node[key]) end
    end

    visit(exp)
    return literals, floating
end

local function get_binop_type(e1, e2)
    if e1[2] == "double" or e2[2] == "double" then
        return base_c_types.LONG_DOUBLE
    end
    if e1[1] == "double" or e2[1] == "double" then
        return base_c_types.DOUBLE
    end
    if e1[1] == "float" or e2[1] == "float" then
        return base_c_types.FLOAT
    end
    if e1[2] == "long" or e2[2] == "long" then
        return base_c_types.LONG_LONG
    end
    if e1[1] == "long" or e2[1] == "long" then
        return base_c_types.LONG
    end
    return base_c_types.INT
end

local binop_set = {
    ["+"] = true,
    ["-"] = true,
    ["*"] = true,
    ["/"] = true,
    ["%"] = true,
}

local relop_set = {
    ["<"] = true,
    [">"] = true,
    [">="] = true,
    ["<="] = true,
    ["=="] = true,
    ["!="] = true,
    ["&&"] = true,
    ["||"] = true,
    ["!"] = true,
}

local bitop_set = {
    ["<<"] = true,
    [">>"] = true,
    ["&"] = true,
    ["^"] = true,
    ["|"] = true,
    ["~"] = true,
}

-- Best-effort assessment of the type of a #define
local get_type_of_exp
get_type_of_exp = typed("Exp, TypeList -> {string}?", function(exp, lst)
    if type(exp[1]) == "string" and exp[2] == nil
       and not exp.postfix then
        local val = exp[1]
        if val:sub(1,1) == '"' or val:sub(1,2) == 'L"' then
            return base_c_types.CONST_CHAR_PTR
        elseif val:sub(1,1) == "'" or val:sub(1,2) == "L'" then
            return base_c_types.CONST_CHAR
        elseif val:match("^0[xX][0-9a-fA-F]+[uUlL]*$") or
               val:match("^[0-9]+[uUlL]*$") then
            -- Recognize explicit L/LL rank suffixes on decimal, octal, and
            -- hexadecimal literals, with or without U. System headers commonly
            -- spell the same limit in different bases; treating 0x...L or
            -- ...ULL as int creates false cross-header declaration conflicts.
            local suffix = val:match("([uUlL]*)$"):lower()
            if suffix:find("ll", 1, true) then
                return base_c_types.LONG_LONG
            elseif suffix:find("l", 1, true) then
                return base_c_types.LONG
            end
            return base_c_types.INT
        elseif floating_literal_type(val) then
            return floating_literal_type(val)
        else
            local declaration = lst[val]
            if declaration and type(declaration.type) == "table" then
                return declaration.type
            elseif declaration and declaration.type == "enum" then
                return base_c_types.INT
            end
            return nil
        end
    end

    if type(exp[1]) == "string"
       and type(exp.postfix) == "table"
       and exp.postfix.args then
        for key in pairs(exp.postfix) do
            if key ~= "args" then return nil end
        end
        local builtin = floating_builtin_type(exp)
        if builtin then return builtin end
        local fn = lst[exp[1]]
        if not fn or not fn.ret then
            return nil -- unknown function, or not a function
        end
        local r = fn.ret.type
        return table.move(r, 1, #r, 1, {}) -- shallow_copy(r)
    end

    local unary =
        exp.unop or (exp.op and exp[2] == nil and exp.op)
    if unary == "*" then
        local etype = get_type_of_exp(exp[1], lst)
        if not etype or etype[#etype] ~= "*" then return nil end
        -- Primitive and parsed declaration tokens are shared read-only. Only
        -- this derived pointee spelling needs a new array.
        return table.move(etype, 1, #etype - 1, 1, {})
    elseif unary == "-" then
        return get_type_of_exp(exp[1], lst)
    elseif exp.op == "?" then
        local e1 = get_type_of_exp(exp[2], lst)
        local e2 = get_type_of_exp(exp[3], lst)
        if e1 and e2 and (e1[1] == "float" or e1[#e1] == "double"
                         or e2[1] == "float" or e2[#e2] == "double") then
            return get_binop_type(e1, e2)
        end
        return e1
    elseif exp.op == "," then
        return get_type_of_exp(exp[#exp], lst)
    elseif binop_set[exp.op] then
        local e1 = get_type_of_exp(exp[1], lst)
        if not e1 then
            return nil
        end
        -- some binops are also unops (e.g. - and *)
        if exp[2] then
            local e2 = get_type_of_exp(exp[2], lst)
            if not e2 then
                return nil
            end
            return get_binop_type(e1, e2)
        else
            return e1
        end
    elseif relop_set[exp.op] then
        return base_c_types.INT
    elseif bitop_set[exp.op] then
        return get_type_of_exp(exp[1], lst) -- ...or should it be int?
    end
    return nil
end)

local function bare_identifier(exp)
    if exp.op or exp.postfix or #exp ~= 1 or type(exp[1]) ~= "string"
       or not exp[1]:match("^[_%a][_%w]*$") then
        return nil
    end
    return exp[1]
end

-- Recognize only a member-projection replacement made entirely from ordinary
-- identifiers and dots. The public macro spelling remains the field emitted
-- by generated C; this path is checker metadata for determining the leaf type.
-- Arrow, call, index, increment, and operator expressions stay outside this
-- bounded feature.
local function dotted_identifier_path(exp)
    if exp.op or #exp ~= 1 or type(exp[1]) ~= "string"
       or not exp[1]:match("^[_%a][_%w]*$")
       or type(exp.postfix) ~= "table" then
        return nil
    end

    for key in pairs(exp) do
        if key ~= 1 and key ~= "postfix" then return nil end
    end

    local path = { exp[1] }
    local suffix = exp.postfix
    while suffix do
        if type(suffix.dot) ~= "string"
           or not suffix.dot:match("^[_%a][_%w]*$") then
            return nil
        end
        path[#path + 1] = suffix.dot

        local next_suffix
        for key, value in pairs(suffix) do
            if key == 1 then
                if type(value) ~= "table" or next_suffix then return nil end
                next_suffix = value
            elseif key ~= "dot" then
                return nil
            end
        end
        suffix = next_suffix
    end

    return #path > 1 and path or nil
end

-- Classify one field token against a cumulative raw macro environment.
-- Object-like macros always participate in preprocessing when used after `.`
-- or `->`: a supported pure dotted expansion supplies projection metadata,
-- while any other active object-like expansion must remain terminal instead
-- of falling back to a physical field that generated C cannot name. A
-- function-like macro does not expand on a plain field token and is therefore
-- outside this object-macro classifier.
function cdefines.classify_expanded_field_macro(name, text)
    local exp = c99.match_language_expression_grammar(text .. " ")
    local path = exp and dotted_identifier_path(exp)
    if path then
        return {
            name = name,
            path = path,
            replacement = text,
        }
    end
    return {
        name = name,
        replacement = text,
        unsupported = true,
    }
end

function cdefines.classify_field_macro(name, define_set)
    local definition = define_set and define_set[name]
    if not definition or definition.args then return nil end
    local ok, text = pcall(cpp.expand_macro, name, define_set)
    if not ok or type(text) ~= "string" then
        return { name = name, replacement = "<macro expansion failed>", unsupported = true }
    end
    return cdefines.classify_expanded_field_macro(name, text)
end

local function identifier_alias_declaration(lst, name, exp)
    local target_name = bare_identifier(exp)
    if not target_name then return nil end
    local target = lst[target_name]
    if not target or (target.type ~= "function"
       and target.type ~= "functionptr"
       and type(target.type) ~= "table") then
        return nil
    end

    -- The replacement declaration is authoritative for objects as well as
    -- functions: copying only its token type loses qualifiers, array bounds,
    -- callback signatures and declaration origins. Keep nested declaration
    -- objects shared read-only.
    -- Self-referential macros must not replace or duplicate the declaration.
    if target_name == name then
        return target
    end
    local alias = {}
    for key, value in pairs(target) do
        alias[key] = value
    end
    alias.name = name
    return alias
end

function cdefines.register_define(lst, name, text, _)
    -- Parse with the header's explicit typedef scope first. Besides recognizing
    -- ordinary `(T) value` spelling, this disambiguates `(T)(value)` from a
    -- call through an ordinary identifier. A cast marker can survive when the
    -- parser attaches a later call/index/member postfix to that cast table, so
    -- accept it only when the cast itself is the complete root expression.
    local cast =
        c99.match_typed_language_expression_grammar(
            text .. " ", lst.typedef_names or {})
    if cast and cast.cast_type and not cast.op and not cast.postfix then
        local declaration =
            ctypes.declaration_from_type_name(
                lst, name, cast.cast_type)
        if declaration then
            declaration._macro_cast = {
                expression = cast,
                operand = cast.cast_operand,
                replacement = text,
            }
            add_type(lst, name, declaration)
        end
        return
    end

    -- The ordinary expression grammar deliberately needs no typedef context.
    -- Retain its historical best-effort typing for non-cast macro constants.
    local exp, _, _, _ = c99.match_language_expression_grammar(text .. " ")
    if not exp then return end

    local path = dotted_identifier_path(exp)
    if path then
        lst.field_macro_paths = lst.field_macro_paths or {}
        lst.field_macro_paths[name] = {
            name = name,
            path = path,
            replacement = text,
        }
        return
    end

    local identifier_alias =
        identifier_alias_declaration(lst, name, exp)
    if identifier_alias then
        if lst[name] ~= identifier_alias then
            add_type(lst, name, identifier_alias)
        end
        return
    end
    local identifier = bare_identifier(exp)
    if identifier then
        local target = lst[identifier]
        if not target then
            -- A bare C identifier has no intrinsic `int` type. In particular,
            -- command-line symbol-renaming macros are visible while processing
            -- unrelated headers, where the renamed declaration is absent.
            -- Defer publication until an import that actually declares the
            -- target can register the alias with its authoritative type.
            return
        elseif target.type == "typedef" then
            -- Compiler headers use temporary object-like macros whose
            -- replacement is a C type name (Clang's stdint.h
            -- `__int_least*_t` aliases are a common example). A macro-only
            -- type alias remains unsupported, but when the macro shadows a
            -- real typedef of the same name, every generated use of that
            -- spelling expands to the replacement typedef. Publish a shallow
            -- declaration under the public spelling so checker semantics and
            -- generated C agree. A self-referential macro leaves the original
            -- declaration unchanged.
            local existing = lst[name]
            if existing and existing.type == "typedef"
               and identifier ~= name then
                local alias = {}
                for key, value in pairs(target) do
                    alias[key] = value
                end
                alias.name = name
                add_type(lst, name, alias)
            end
            return
        end
    end
    local typ = get_type_of_exp(exp, lst)
    if typ then
        local literals, floating = annotate_integer_literals(exp)
        add_type(lst, name, {
            type = typ,
            -- Floating expressions are emitted under their public C spelling;
            -- only integer-only expressions enter the exact target evaluator.
            macro_expression = not floating and exp or nil,
            integer_literals = not floating and literals or nil,
        })
    end
end

function cdefines.register_defines(lst, define_set)
    -- The final preprocessor definition set is a map and no longer carries
    -- source order. Fresh Lua processes randomize table traversal, so walking
    -- it directly would make the TypeList, declaration-redeclaration batches,
    -- and their exact probe C change across otherwise identical builds.
    local names = {}
    for name in pairs(define_set) do names[#names + 1] = name end
    table.sort(names, util.bytewise_less)

    lst.field_macro_classes = {}
    for _, name in ipairs(names) do
        local def = define_set[name]
        if def.args then
            goto continue
        end
        local text = cpp.expand_macro(name, define_set)
        -- All active object macros affect a field token, including empty and
        -- unsupported replacements. The final translation-unit environment
        -- is fixed here, after real ordered preprocessing and macro rescans.
        lst.field_macro_classes[name] = cdefines.classify_expanded_field_macro(name, text)
        if #def > 0 then cdefines.register_define(lst, name, text, define_set) end
        ::continue::
    end
end

return cdefines
