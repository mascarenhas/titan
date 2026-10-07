local parser = {}
local lpeg = require "lpeglabel"
local re = require "relabel"
local inspect = require "inspect"
local ast = require "titan-compiler.ast"
local lexer = require "titan-compiler.lexer"
local location = require "titan-compiler.location"
local syntax_errors = require "titan-compiler.syntax_errors"
local documentation = require "titan-compiler.documentation"

-- Source locations are immutable and interned for a single non-reentrant parse.
local THIS_FILENAME, SOURCE_LOCATIONS, SOURCE_TEXT
-- Written parameters, expression lists, and generic binders/applications retain
-- their existing width limit. Function type/result capacities are checker-owned.
local LIST_LIMIT = 100
-- Ordinary capture validation avoids retaining dynamic results on LPeg's Lua
-- stack. Only this private exception is translated to the public syntax error.
local SYNTAX_FAILURE = {}
local function syntax_failure(label, loc)
    error({ _parser_error = SYNTAX_FAILURE, label = label, loc = loc }, 0)
end
local defs = {}
local with_name_loc, with_end_loc
for name, pattern in pairs(lexer) do defs[name] = pattern end
for name, constructor in pairs(ast) do defs[name] = constructor end
local identifier_rest = lpeg.P"_" + lpeg.R("AZ", "az", "09")
for token, word in pairs({
    CBOOL="bool", CCHAR="char", CDOUBLE="double", CINT="int", CLONG="long",
    CSHORT="short", CSIGNED="signed", CUNSIGNED="unsigned", CVOID="void",
    CFLOAT="float",
}) do
    defs[token] = lpeg.C(lpeg.P(word)) * -identifier_rest
end

-- FIRST(expression) must not lex a complete string or numeral speculatively:
-- predicates suppress a token's labeled lexical failure. Inspect its opening
-- byte instead, leaving validation and captures to the consuming expression.
defs.STRINGSTART = lpeg.S("\"'") + lpeg.P("[") * lpeg.S("[=")
defs.LITERALSTART = lpeg.S("\"'[") + lpeg.R("09") + lpeg.P(".") * lpeg.R("09")

defs.EXPSTART = lpeg.S("({'\"[#~-") + lpeg.R("09") +
    lpeg.P(".") * lpeg.R("09") + lexer.DOTS + lexer.NAME +
    lexer.NIL + lexer.TRUE + lexer.FALSE + lexer.FUNCTION + lexer.FOREIGN + lexer.NOT

-- Qualified standard-library module identities do not collide with Lua's
-- libraries. Normalize convenient short source imports before resolution.
local standard_imports = {
    coroutine = "titan.coroutine",
    uv = "titan.uv",
    async = "titan.async",
    timer = "titan.timer",
    io = "titan.io",
    fs = "titan.fs",
    path = "titan.path",
    net = "titan.net",
    ssl = "titan.ssl",
    url = "titan.url",
    http = "titan.http",
    websocket = "titan.websocket",
    os = "titan.os",
    peg = "titan.peg",
    string = "titan.string",
    test = "titan.test",
    lua = "titan.lua",
    math = "titan.math",
    gc = "titan.gc",
    iteration = "titan.iteration",
    reflect = "titan.reflect",
    sqlite3 = "titan.sqlite3",
    json = "titan.json",
}


function parser.normalize_import(modname)
    local source_required = modname:sub(-6) == ".titan"
    if source_required then
        modname = modname:sub(1, -7)
    end
    return standard_imports[modname] or modname, source_required
end

function defs.importdecl(loc, name_loc, localname, modname)
    local normalized, source_required = parser.normalize_import(modname)
    return with_name_loc(
        ast.TopLevelImport(loc, localname, normalized, source_required),
        name_loc)
end

function defs.get_loc(pos)
    local locations = assert(SOURCE_LOCATIONS)
    local loc = locations[pos]
    if not loc then
        loc = location.from_pos(THIS_FILENAME, SOURCE_TEXT, pos)
        locations[pos] = loc
    end
    return loc
end

with_name_loc = function(node, name_loc)
    node._name_loc = name_loc
    return node
end

with_end_loc = function(node, end_loc)
    node._end_loc = end_loc
    return node
end

function defs.totrue()
    return true
end

function defs.tofalse()
    return false
end

function defs.tonil()
    return nil
end

function defs.rettypeopt(_, x)
    if not x then
        -- No return annotation means a zero-return `function(...): ()`, as
        -- in Lua where `function f() end` returns nothing. `return` (bare) is
        -- the only legal return; `: nil` is the explicit one-`nil` form.
        return {}, nil
    else
        return x.rettypes, x.flexrettype
    end
end

function defs.lambdarettypeopt(_, x)
    if not x then
        -- No return annotation on a lambda means "infer the return type" — a
        -- distinct case from an explicit `: ()` (which is a zero-return `{}`).
        -- We return `nil` so the checker can tell the two apart.
        return nil, nil
    else
        return x.rettypes, x.flexrettype
    end
end

function defs.typeopt(t, isopt)
    if not isopt or isopt == "" then
        return t
    else
        return ast.TypeOption(t.loc, t)
    end
end

function defs.opt(x)
    if x == "" then
        return nil
    else
        return x
    end
end

function defs.listopt(x)
    if x == "" then
        return {}
    else
        return x
    end
end

function defs.boolopt(x)
    return x ~= ""
end

function defs.nil_exp(pos --[[, s ]])
    -- We can't call ast.ExpNil directly in the parser because we
    -- need to drop the string capture that comes in the second argument.
    return ast.ExpNil(pos)
end

function defs.number_exp(pos, n)
    if math.type(n) == "integer" then
        return ast.ExpInteger(pos, n)
    elseif math.type(n) == "float" then
        return ast.ExpFloat(pos, n)
    else
        error("impossible")
    end
end

function defs.name_exp(pos, name)
    return ast.ExpVar(pos, with_name_loc(ast.VarName(pos, name), pos))
end

function defs.adjust_exp(pos, exp)
    if exp._tag == "Ast.ExpCall" or exp._tag == "Ast.ExpDots" or
        exp._tag == "Ast.ExpSpread" or exp._tag == "Ast.ExpSubset" then
        exp = ast.ExpAdjust(pos, exp)
    end
    exp._parenthesized = true
    return exp
end

function defs.dots_len_exp(pos)
    return ast.ExpDotsLen(pos)
end

function defs.trywrap(pos, block, catchblock)
    if not catchblock then
        return block
    end
    return ast.StatTry(pos, block, catchblock, nil)
end

function defs.deferstat(pos, stat)
    return {
        _tag = "Parser.Defer",
        loc = pos,
        stat = stat
    }
end

local function lower_defers(stats)
    local lowered = {}
    local current = lowered
    for _, stat in ipairs(stats) do
        if stat._tag == "Parser.Defer" then
            local tail = ast.StatBlock(stat.loc, {})
            tail._defer_tail = true
            local trynode = ast.StatTry(stat.loc,
                tail,
                nil,
                ast.StatBlock(stat.stat.loc, { stat.stat }))
            trynode._defer_tail = true
            current[#current + 1] = trynode
            current = tail.stats
        else
            current[#current + 1] = stat
        end
    end
    return lowered
end

function defs.simpleblock(pos, stats)
    return ast.StatBlock(pos, lower_defers(stats))
end

function defs.moduleinit(pos, block, end_loc)
    block.loc = pos
    block._module_initializer = true
    return with_end_loc(block, end_loc)
end

function defs.cptrtype(pos, subtype)
    return ast.TypeCPointer(pos, subtype, false)
end



function defs.cast_type_tail(target)
    return { kind = "as", target = target }
end

function defs.test_type_tail(target)
    return { kind = "is", target = target }
end

function defs.map_type_tail(valuestype)
    return { kind = "map", valuestype = valuestype }
end

function defs.array_type_tail()
    return { kind = "array" }
end

function defs.finish_curly_type(pos, firsttype, tail)
    if tail.kind == "map" then
        return ast.TypeMap(pos, firsttype, tail.valuestype)
    else
        return ast.TypeArray(pos, firsttype, { tag = "no" })
    end
end

function defs.ifstat(pos, exp, block, thens, elseopt, end_loc)
    table.insert(thens, 1, ast.Then(pos, exp, block))
    return with_end_loc(ast.StatIf(pos, thens, elseopt), end_loc)
end

function defs.fornum_rest(_, start, finish, inc, block, end_loc)
    return function(pos, decl)
        return with_end_loc(
            ast.StatFor(pos, decl, start, finish, inc, block), end_loc)
    end
end

function defs.forin_rest(_, decls, exps, block, end_loc)
    return function(pos, decl)
        table.insert(decls, 1, decl)
        return with_end_loc(
            ast.StatForIn(pos, decls, exps, block), end_loc)
    end
end

function defs.whilestat(pos, exp, block, end_loc)
    return with_end_loc(ast.StatWhile(pos, exp, block), end_loc)
end

function defs.repeatstat(pos, block, end_loc, exp)
    return with_end_loc(ast.StatRepeat(pos, block, exp), end_loc)
end

function defs.casestat(pos, exp, arms, elseopt, end_loc)
    return with_end_loc(ast.StatCase(pos, exp, arms, elseopt), end_loc)
end

function defs.doblock(pos, block, end_loc)
    block._structure_loc = pos
    return with_end_loc(block, end_loc)
end

function defs.forstat(pos, decl, rest)
    return rest(pos, decl)
end

local function is_concat_constant(exp)
    return exp._tag == "Ast.ExpString" or
        exp._tag == "Ast.ExpInteger" or
        exp._tag == "Ast.ExpFloat"
end

function defs.fold_binop_concat_right(matches)
    local operand_count = #matches // 2
    if operand_count == 1 then
        return matches[2]
    end

    -- The historical right fold gives a pre-existing RHS ExpConcat priority,
    -- including one returned transparently through parentheses. Otherwise it
    -- folds only the maximal constant suffix, then creates the first concat
    -- node. Every earlier operand is prepended without further folding.
    local rhs = matches[2 * operand_count]
    local concat
    local prefix_end
    if rhs._tag == "Ast.ExpConcat" then
        concat = rhs
        prefix_end = operand_count - 1
    else
        local constant_start = operand_count + 1
        for operand = operand_count, 1, -1 do
            local exp = matches[2 * operand]
            if not is_concat_constant(exp) then break end
            constant_start = operand
        end

        local first_unfolded
        if constant_start < operand_count then
            local values = {}
            for operand = constant_start, operand_count do
                values[#values + 1] = matches[2 * operand].value
            end
            rhs = ast.ExpString(matches[2 * constant_start - 1],
                table.concat(values))
            first_unfolded = constant_start - 1
        else
            first_unfolded = operand_count - 1
        end

        if first_unfolded == 0 then
            return rhs
        end

        local lhs = matches[2 * first_unfolded]
        concat = ast.ExpConcat(
            matches[2 * first_unfolded - 1], { lhs, rhs })
        prefix_end = first_unfolded - 1
    end

    -- Build the flattened children once. Keep this match-time callback pure:
    -- it may run on a parse path that is later abandoned, so do not mutate a
    -- captured RHS node merely to reuse its table.
    local exps = {}
    for operand = 1, prefix_end do
        exps[operand] = matches[2 * operand]
    end
    for index = 1, #concat.exps do
        exps[prefix_end + index] = concat.exps[index]
    end
    return ast.ExpConcat(concat.loc, exps)
end

function defs.power_operand(unary_loc, unops, simple_loc, exp)
    return {
        unary_loc = unary_loc,
        unops = unops,
        simple_loc = simple_loc,
        exp = exp,
    }
end

function defs.fold_unops(pos, unops, exp)
    for i = #unops, 1, -1 do
        local op = unops[i]
        exp = ast.ExpUnop(pos, op, exp)
    end
    return exp
end

local function unpack_membername(member)
    if type(member) == "table" then
        return member.name, true
    end
    return member, false
end


function defs.bracket_subset_tail(last)
    return { last = last }
end


function defs.suffix_bracket_desc(desc)
    return function(exp)
        if desc.kind == "index" then
            if exp._tag == "Ast.ExpDots" and not exp._parenthesized then
                return ast.ExpDotsIndex(exp.loc, desc.first)
            end
            return ast.ExpVar(desc.loc, ast.VarBracket(desc.loc, exp, desc.first))
        end
        return ast.ExpSubset(desc.loc, exp, desc.first, desc.last)
    end
end

function defs.qualifiedtype(pos, module, name_loc, member, typeargs)
    local name, contextual = unpack_membername(member)
    local node = with_name_loc(
        ast.TypeQualName(pos, module, name, typeargs), name_loc)
    node._module_loc = pos
    if contextual then
        node._contextual_c_name = true
    end
    return node
end

function defs.methoddecl(pos, islocal, owner_loc, class, name_loc, name,
                         typeparams, params, rettypes, flexrettype, block,
                         end_loc)
    local node = with_name_loc(ast.TopLevelMethod(
        pos, class, name, params, rettypes,
        flexrettype, block, typeparams), name_loc)
    node.islocal = islocal
    node._owner_loc = owner_loc
    return with_end_loc(node, end_loc)
end

function defs.staticdecl(pos, islocal, owner_loc, class, name_loc, name,
                         typeparams, params, rettypes, flexrettype, block,
                         end_loc)
    local node = with_name_loc(ast.TopLevelStatic(
        pos, class, name, params, rettypes,
        flexrettype, block, typeparams), name_loc)
    node.islocal = islocal
    node._owner_loc = owner_loc
    return with_end_loc(node, end_loc)
end

function defs.toplevelfuncdecl(pos, islocal, name_loc, name, typeparams,
                               params, rettypes, flexrettype, block, end_loc)
    return with_end_loc(with_name_loc(
        ast.TopLevelFunc(pos, islocal, name, params, rettypes,
            flexrettype, block, typeparams), name_loc), end_loc)
end

function defs.foreignfuncdecl(pos, name_loc, name, params, rettypes,
                              flexrettype, block, end_loc)
    return with_end_loc(with_name_loc(
            ast.TopLevelForeignFunc(
                pos, name, params, rettypes, flexrettype, block), name_loc),
        end_loc)
end

function defs.typealiasdecl(pos, islocal, name_loc, name, type)
    return with_name_loc(
        ast.TopLevelTypeAlias(pos, islocal, name, type), name_loc)
end

function defs.foreignimportdecl(pos, header_loc, headername)
    local node = ast.TopLevelForeignImport(pos, headername)
    node._header_loc = header_loc
    return node
end

function defs.typename(pos, name, typeargs)
    return with_name_loc(ast.TypeName(pos, name, typeargs), pos)
end

function defs.typeparamdecl(pos, name, constraint)
    return with_name_loc(ast.TypeParam(pos, name, constraint), pos)
end

function defs.funcexp(pos, params, rettypes, flexrettype, block, end_loc)
    return with_end_loc(
        ast.ExpFunction(pos, params, rettypes, flexrettype, block), end_loc)
end

function defs.casearm(pos, name_loc, name, pattern, block)
    return with_name_loc(
        ast.CaseArm(pos, name, pattern.bindings, block, pattern.named), name_loc)
end

function defs.positionalcasebindings(bindings)
    return { bindings = bindings, named = false }
end

function defs.namedcasebindings(bindings)
    local seen = {}
    for _, binding in ipairs(bindings) do
        if seen[binding.part] then
            syntax_failure("DuplicateCasePart", binding._part_loc)
        end
        seen[binding.part] = true
    end
    return { bindings = bindings, named = true }
end

function defs.makefield(pos, name, exp)
    local node = ast.Field(pos, name, exp)
    if type(name) == "string" then node._name_loc = pos end
    return node
end

function defs.interfacedecl(pos, name_loc, name, typeparams, members, end_loc)
    local fields, methods = {}, {}
    for _, member in ipairs(members) do
        if member._tag == "Ast.InterfaceMethod" then
            methods[#methods + 1] = member
        else
            assert(member._tag == "Ast.Decl")
            fields[#fields + 1] = member
        end
    end
    return with_end_loc(with_name_loc(
        ast.TopLevelInterface(pos, name, members, fields, methods,
            typeparams), name_loc), end_loc)
end

function defs.interfacemethoddecl(pos, name_loc, name, typeparams, params,
                                  rettypes, flexrettype)
    return with_name_loc(
        ast.InterfaceMethod(pos, name, params, rettypes, flexrettype,
            typeparams), name_loc)
end

function defs.interfacefielddecl(pos, name, type)
    return with_name_loc(ast.Decl(pos, name, type, false, true), pos)
end

local function has_local_field(fields)
    for _, field in ipairs(fields) do
        if field.islocal then return true end
    end
    return false
end

local function applied_owner_type(pos, name, typeparams)
    local typeargs = {}
    for i, typeparam in ipairs(typeparams) do
        typeargs[i] = ast.TypeName(typeparam.loc, typeparam.name, {})
    end
    return ast.TypeName(pos, name, typeargs)
end

function defs.recorddecl(pos, islocal, name_loc, name, typeparams, fields,
                         end_loc)
    local params, initlist = {}, {}
    for _, field in ipairs(fields) do
        table.insert(params,
            ast.Decl(field.loc, field.name, field.type, false, false))
        table.insert(initlist, ast.Field(field.loc, field.name,
            ast.ExpVar(field.loc, ast.VarName(field.loc, field.name))))
    end
    local body = ast.StatBlock(pos, {
        ast.StatReturn(pos, {
            ast.ExpInitList(pos, initlist)
        })
    })
    local record = with_end_loc(with_name_loc(
        ast.TopLevelRecord(pos, name, fields, typeparams), name_loc), end_loc)
    record.islocal = islocal
    local new = ast.TopLevelStatic(pos, name, "new", params,
        { applied_owner_type(pos, name, typeparams) }, nil, body, {})
    new.islocal = islocal or has_local_field(fields)
    new._record_constructor = true
    return { _tag = "Parser.Declarations", nodes = {record, new} }
end

function defs.uniondecl(pos, islocal, name_loc, name, typeparams, variants,
                        end_loc)
    local union = with_end_loc(with_name_loc(
        ast.TopLevelUnion(pos, name, variants, typeparams), name_loc), end_loc)
    union.islocal = islocal

    local nodes = { union }
    for _, variant in ipairs(variants) do
        local params, values = {}, {}
        for i, part in ipairs(variant.parts) do
            params[i] = with_name_loc(ast.Decl(
                part.loc, part.name, part.type, false, false), part._name_loc)
            values[i] = ast.ExpVar(
                part.loc, ast.VarName(part.loc, part.name))
        end

        local init = ast.ExpUnionInit(
            variant.loc, name, variant, values)
        local body = ast.StatBlock(variant.loc, {
            ast.StatReturn(variant.loc, { init }),
        })
        local constructor = ast.TopLevelStatic(
            variant.loc,
            name,
            variant.name,
            params,
            { applied_owner_type(pos, name, typeparams) },
            nil,
            body,
            {})
        constructor.islocal = islocal or variant.islocal or false
        constructor._union_constructor = true
        constructor._union_variant = variant
        nodes[#nodes + 1] = constructor
    end

    -- A union can have arbitrarily many variants. Keep the constructor bundle
    -- in one capture; expanding it with table.unpack exhausts LPeg's result
    -- stack even when the enclosing declaration repetition is folded.
    return { _tag = "Parser.Declarations", nodes = nodes }
end

function defs.typeddecl(pos, name, type)
    return with_name_loc(ast.Decl(pos, name, type, false, false), pos)
end

function defs.casebinding(pos, name)
    return with_name_loc(ast.Decl(pos, name, nil, false, false), pos)
end

function defs.casepart(pos, name)
    return { loc = pos, name = name }
end

function defs.namedcasebinding(pos, name, part)
    local binding = defs.casebinding(pos, name)
    binding.part = part and part.name or name
    binding._part_loc = part and part.loc or pos
    return binding
end

function defs.constlocalvardecl(pos, decls, exps)
    for _, decl in ipairs(decls) do
        decl.isconst = true
    end
    return ast.StatDecl(pos, decls, exps)
end

function defs.varargdecl(pos, type)
    return ast.Decl(pos, nil, type or nil, false, false)
end

function defs.returnshape(rettypes, flexrettype)
    return { rettypes = rettypes, flexrettype = flexrettype }
end

function defs.singlereturn(type)
    return { rettypes = { type }, flexrettype = nil }
end

function defs.checklist(list, loc)
    if #list > LIST_LIMIT then syntax_failure("ListTooLong", loc) end
    return list
end

-- Fold callbacks receive one repetition at a time. `fresh` constructs a new
-- accumulator for each match; no list is a wide variadic callback argument.
function defs.append(list, ...)
    for i = 1, select("#", ...) do list[#list + 1] = select(i, ...) end
    return list
end

function defs.append_program(list, node)
    if node._tag == "Parser.Declarations" then
        for _, declaration in ipairs(node.nodes) do
            list[#list + 1] = declaration
        end
    else
        list[#list + 1] = node
    end
    return list
end


local binary_precedence = {
    ["or"]=1, ["and"]=2,
    ["=="]=3, ["~="]=3, ["<"]=3, [">"]=3, ["<="]=3, [">="]=3,
    ["|"]=4, ["~"]=5, ["&"]=6, ["<<"]=7, [">>"]=7,
    [".."]=8, ["+"]=9, ["-"]=9, ["*"]=10, ["/"]=10, ["//"]=10, ["%"]=10,
}

local function finish_concat(value)
    if value._tag ~= "Parser.Concat" then return value end
    local operands = {}
    while value._tag == "Parser.Concat" do
        operands[#operands + 1] = value.first.loc
        operands[#operands + 1] = value.first
        value = value.rest
    end
    operands[#operands + 1] = value.loc
    operands[#operands + 1] = value
    return defs.fold_binop_concat_right(operands)
end

local function reduce_binary(state)
    local values, operators = state.values, state.operators
    local operator = operators[#operators]
    operators[#operators] = nil
    local rhs = values[#values]
    values[#values] = nil
    local lhs = values[#values]
    if operator == ".." then
        -- A right-associated run is materialized once, not repeatedly copied
        -- as each earlier operand is folded into an ever larger concat table.
        values[#values] = { _tag="Parser.Concat", loc=lhs.loc, first=lhs, rest=rhs }
    else
        values[#values] = ast.ExpBinop(lhs.loc,
            finish_concat(lhs), operator, finish_concat(rhs))
    end
end

function defs.binary_start(exp)
    return { values = { exp }, operators = {} }
end

function defs.binary_step(state, operator, rhs)
    local precedence = assert(binary_precedence[operator])
    local operators = state.operators
    while #operators > 0 do
        local previous = binary_precedence[operators[#operators]]
        if previous < precedence or (previous == precedence and operator == "..") then
            break
        end
        reduce_binary(state)
    end
    operators[#operators + 1] = operator
    state.values[#state.values + 1] = rhs
    return state
end

function defs.binary_finish(state)
    while #state.operators > 0 do reduce_binary(state) end
    return finish_concat(state.values[1])
end

function defs.apply_suffix(exp, suffix)
    return suffix(exp)
end

function defs.finish_program(nodes, init)
    if init then nodes[#nodes + 1] = init end
    return nodes
end

function defs.declaration(pos, name, option, typ)
    typ = typ or nil
    if option and typ then typ = ast.TypeOption(typ.loc, typ) end
    return with_name_loc(ast.Decl(pos, name, typ, option and not typ, false), pos)
end

function defs.topvartype(typ, value)
    return { type = typ, value = value or nil }
end

function defs.topvarvalue(value)
    return { type = nil, value = value }
end

function defs.topvar(pos, islocal, isconst, name_loc, name, tail)
    local decl = with_name_loc(
        ast.Decl(name_loc, name, tail.type, false, isconst), name_loc)
    return ast.TopLevelVar(pos, islocal, isconst, decl, tail.value)
end

function defs.function_selector(kind, name_loc, name)
    return { kind = kind, name_loc = name_loc, name = name }
end

function defs.functiondecl(pos, islocal, name_loc, name, selector, typeparams,
                           params, rettypes, flexrettype, block, end_loc)
    if selector then
        local constructor = selector.kind == ":" and
            defs.methoddecl or defs.staticdecl
        return constructor(pos, islocal, name_loc, name,
            selector.name_loc, selector.name, typeparams, params,
            rettypes, flexrettype, block, end_loc)
    end
    return defs.toplevelfuncdecl(pos, islocal, name_loc, name, typeparams,
        params, rettypes, flexrettype, block, end_loc)
end

function defs.foreignalias(pos, name_loc, name, typ)
    return with_name_loc(ast.TopLevelForeignTypeAlias(pos, name, typ), name_loc)
end

function defs.foreignname(pos, ...)
    return with_name_loc(ast.TypeForeignName(pos, table.concat({...}, " ")), pos)
end

function defs.foreign_return(typ)
    return { typ }, nil
end

function defs.foreign_void(pos)
    return { ast.TypeForeignName(pos, "void") }, nil
end

function defs.foreign_array(pos, subtype, isconst)
    local node = ast.TypeCArray(pos, subtype, nil)
    node.const = isconst
    return node
end

function defs.foreign_base_tail(pos, subtype, array)
    if array then return defs.foreign_array(pos, subtype, false) end
    return subtype
end

function defs.foreign_const_tail(pos, subtype, pointer)
    if pointer then return ast.TypeCPointer(pos, subtype, true) end
    return defs.foreign_array(pos, subtype, true)
end

function defs.type_tail(typ)
    return { _type_tail = true, type = typ }
end

function defs.foreign_type_tail()
    return { _type_tail = true, type = true }
end

function defs.split_types(types)
    local last = types[#types]
    if last and last._type_tail then
        types[#types] = nil
        return types, last.type
    end
    return types, nil
end

function defs.functiontype(pos, argtypes, varargtype, rettypes, flexrettype)
    return ast.TypeFunction(pos, argtypes, rettypes, varargtype, flexrettype)
end

function defs.foreignfunctiontype(pos, argtypes, varargtype, rettype)
    return ast.TypeForeignFunction(pos, argtypes, { rettype }, varargtype, nil)
end

function defs.const_array(pos, maybe, subtype)
    return ast.TypeArray(pos, subtype, { tag = maybe and "maybe" or "yes" })
end

function defs.qualified_tail(name_loc, name, typeargs)
    return { name_loc = name_loc, name = name, typeargs = typeargs }
end

function defs.name_tail(typeargs)
    return { typeargs = typeargs }
end

function defs.named_type(pos, name, tail)
    if tail.name then
        return defs.qualifiedtype(pos, name, tail.name_loc, tail.name, tail.typeargs)
    end
    return defs.typename(pos, name, tail.typeargs)
end

function defs.parenthesized_returns(types, tail, option, loc)
    if option then
        if #types ~= 1 or tail then syntax_failure("OptionTypeList", loc) end
        types[1] = ast.TypeOption(types[1].loc, types[1])
    end
    return defs.returnshape(types, tail)
end

function defs.recordfield(pos, islocal, isconst, name_loc, name, typ)
    local decl = with_name_loc(ast.Decl(pos, name, typ, false, isconst), name_loc)
    if islocal then decl.islocal = true end
    return decl
end

function defs.unionvariant(pos, islocal, name_loc, name, parts)
    local variant = with_name_loc(ast.UnionVariant(pos, name, parts), name_loc)
    if islocal then variant.islocal = true end
    return variant
end

function defs.unionpayload(typ)
    return { ast.Decl(typ.loc, "value", typ, false, false) }
end

function defs.assignment_tail(vars, exps)
    return { vars = vars, exps = exps }
end

function defs.statement_candidate(pos, first, tail)
    if not tail then return ast.StatCall(pos, first) end
    table.insert(tail.vars, 1, first)
    local node = ast.StatAssign(pos, tail.vars, tail.exps)
    node._parsed_candidates = true
    return node
end

function defs.name_with_types(pos, name, typeargs)
    local node = defs.name_exp(pos, name)
    if #typeargs > 0 then
        node._nominal_typeargs = typeargs
        node._nominal_typeargs_loc = pos
    end
    return node
end

function defs.dot_with_types(pos, name_loc, name, typeargs)
    return function(exp)
        local var = with_name_loc(ast.VarDot(pos, exp, name), name_loc)
        local node = ast.ExpVar(pos, var)
        if #typeargs > 0 then
            node._nominal_typeargs = typeargs
            node._nominal_typeargs_loc = name_loc
        end
        return node
    end
end

function defs.method_with_types(pos, name_loc, name, typeargs)
    return function(exp)
        local node = with_name_loc(ast.ExpMethodRef(pos, exp, name), name_loc)
        node._nominal_typeargs = typeargs
        node._nominal_typeargs_loc = name_loc
        return node
    end
end

function defs.call_suffix(pos, args, named)
    return function(exp)
        local typeargs = exp._nominal_typeargs or {}
        exp._nominal_typeargs = nil
        exp._nominal_typeargs_loc = nil
        local callargs
        if exp._tag == "Ast.ExpMethodRef" and not exp._parenthesized then
            if named then
                callargs = ast.ArgsNamedMethod(pos, exp.name, args)
            else
                callargs = ast.ArgsMethod(pos, exp.name, args)
            end
            callargs._name_loc = exp._name_loc
            exp = exp.exp
        elseif named then
            callargs = ast.ArgsNamedFunc(pos, args)
        else
            callargs = ast.ArgsFunc(pos, args)
        end
        return ast.ExpCall(pos, exp, callargs, typeargs)
    end
end

function defs.dots_or_spread(pos, subject)
    if subject then return ast.ExpSpread(pos, subject, nil, nil) end
    return ast.ExpDots(pos)
end

function defs.power(pos, first, tails)
    if #tails == 0 then return first end
    local last = tails[#tails]
    local rhs = defs.fold_unops(last.unary_loc, last.unops, last.exp)
    for i = #tails - 1, 1, -1 do
        local operand = tails[i]
        rhs = ast.ExpBinop(operand.simple_loc, operand.exp, "^", rhs)
        rhs = defs.fold_unops(operand.unary_loc, operand.unops, rhs)
    end
    return ast.ExpBinop(pos, first, "^", rhs)
end

function defs.cast_or_test(exp, tail)
    if not tail then return exp end
    if tail.kind == "as" then return ast.ExpCast(exp.loc, exp, tail.target) end
    return ast.ExpIs(exp.loc, exp, tail.target)
end

function defs.check_expression_list(list, loc)
    local tail = list[#list]
    if #list <= LIST_LIMIT or (#list == LIST_LIMIT + 1 and tail and
        (tail._tag == "Ast.ExpDots" or tail._tag == "Ast.ExpSpread" or
         (tail._tag == "Ast.ExpSubset" and tail.exp._tag == "Ast.ExpDots"))) then
        return list
    end
    syntax_failure("ListTooLong", loc)
end

function defs.bracket_subset_to_desc_tail(last)
    return { kind = "subset", first = nil, last = last }
end

function defs.bracket_first_tail(first, tail)
    if tail then return { kind = "subset", first = first, last = tail.last } end
    return { kind = "index", first = first, last = nil }
end

function defs.bracket_finish(pos, desc)
    desc.loc = pos
    return desc
end

local grammar_source = [[
    program <- (SKIP* ((fresh (&tldeclstart tldecl^TopLevelDecl)*) ~> append_program)
                ((&DO moduleinit^EndBlock)? -> opt) !.) -> finish_program
    fresh <- {| '' |}
    tldeclstart <- SEMICOLON / variablehead / LOCAL / FUNCTION / FOREIGN
                 / TYPE / RECORD / UNION / INTERFACE
    tldecl <- SEMICOLON
            / &(LOCAL NAME ASSIGN FOREIGN IMPORT) boundimport
            / &(LOCAL NAME ASSIGN IMPORT) import^ImportImport
            / &variablehead topvar^AssignVar
            / &(LOCAL? FUNCTION) functiondecl^NameFunc
            / &(FOREIGN FUNCTION) foreignfunc^NameFunc
            / &(FOREIGN TYPE) foreigntypealias^NameTypeAlias
            / &(FOREIGN IMPORT) foreignimport
            / &(LOCAL? TYPE) typealias^NameTypeAlias
            / &(LOCAL? RECORD) recorddecl^NameRecord
            / &(LOCAL? UNION) uniondecl^NameUnion
            / &(LOCAL? INTERFACE) interfacedecl^NameInterface

    -- These head/modifier/import helpers expand to at most five terminals.
    -- Keyword-named variables are distinguished before modifier dispatch.
    import <- (P LOCAL P NAME ASSIGN IMPORT importname) -> importdecl
    boundimport <- LOCAL NAME ASSIGN FOREIGN IMPORT %{BoundForeignImport}
    importname <- LPAREN STRINGLIT^StringLParImport RPAREN^RParImport
                / STRINGLIT^StringImport
    foreignimport <- (P FOREIGN IMPORT (LPAREN P STRINGLIT^StringLParImport
                      RPAREN^RParImport / P STRINGLIT^StringImport)) -> foreignimportdecl
    variablehead <- ANYNAME (COLON / ASSIGN)
                  / LOCAL ANYNAME (COLON / ASSIGN)
                  / CONST ANYNAME (COLON / ASSIGN)
                  / LOCAL CONST ANYNAME (COLON / ASSIGN)
    localopt <- ((LOCAL !(COLON / ASSIGN)) -> totrue) / ('' -> tofalse)
    constopt <- ((CONST !(COLON / ASSIGN)) -> totrue) / ('' -> tofalse)
    topvar <- (P localopt constopt P ANYNAME
              ((COLON type^TypeDecl ((ASSIGN exp^ExpVarDec)? -> opt)) -> topvartype
              / (ASSIGN exp^ExpVarDec) -> topvarvalue)) -> topvar
    functiondecl <- (P localopt FUNCTION P ANYNAME^NameFunc
                    ((functionselector)? -> opt) typeparamsopt^NameTypeParam
                    LPAREN^LParPList paramlist^DeclParList RPAREN^RParPList
                    rettypeopt^TypeFunc block^Statement P END^EndFunc) -> functiondecl
    functionselector <- ((COLON -> ':') P ANYNAME^NameMethod
                        / (DOT -> '.') P ANYNAME^NameStatic) -> function_selector
    foreignfunc <- (P FOREIGN FUNCTION P ANYNAME^NameFunc
                    (TYPEOPEN %{GenericForeignFunc})?
                    LPAREN^LParPList foreignparamlist^DeclParList RPAREN^RParPList
                    foreignretopt^TypeFunc block^Statement P END^EndFunc) -> foreignfuncdecl
    foreignretopt <- (COLON foreigntype^TypeFunc) -> foreign_return / P -> foreign_void
    typealias <- (P localopt TYPE P ANYNAME^NameTypeAlias
                  (TYPEOPEN %{GenericTypeAlias})?
                  ASSIGN^AssignTypeAlias titantype^TypeTypeAlias) -> typealiasdecl
    foreigntypealias <- (P FOREIGN TYPE P ANYNAME^NameTypeAlias
                        ASSIGN^AssignTypeAlias foreigntype^TypeTypeAlias) -> foreignalias
    recorddecl <- (P localopt RECORD P ANYNAME^NameRecord typeparamsopt^NameTypeParam
                   recordfields^FieldRecord P END^EndRecord) -> recorddecl
    uniondecl <- (P localopt UNION P ANYNAME^NameUnion typeparamsopt^NameTypeParam
                  unionvariants^VariantUnion P END^EndUnion) -> uniondecl
    interfacedecl <- (P (LOCAL INTERFACE %{LocalInterface} / INTERFACE)
                      P ANYNAME^NameInterface typeparamsopt^NameTypeParam
                      interfacemembers^MemberInterface P END^EndInterface) -> interfacedecl
    moduleinit <- (P DO block^Statement P END^EndBlock) -> moduleinit

    typeparamsopt <- &TYPEOPEN typeparams^NameTypeParam / fresh
    typeparams <- TYPEOPEN ((((fresh typeparam^NameTypeParam
                  (COMMA typeparam^NameTypeParam)*) ~> append) P) -> checklist)
                  TYPECLOSE^RAngleTypeParams
    typeparam <- (P ANYNAME ((COLON namedtype^TypeParamConstraint)? -> opt)) -> typeparamdecl
    typeargsopt <- &TYPEOPEN typeargs^TypeArgument / fresh
    typeargs <- TYPEOPEN ((((fresh type^TypeArgument
                (COMMA type^TypeArgument)*) ~> append) P) -> checklist)
                TYPECLOSE^RAngleTypeArgs

    paramlist <- (((fresh (&NAME param^DeclParList (COMMA !DOTS param^DeclParList)*
                   (COMMA varargparam^DeclParList)? / &DOTS varargparam^DeclParList)?) ~> append) P) -> checklist
    param <- (P NAME COLON^ParamSemicolon type^TypeDecl) -> typeddecl
    varargparam <- (P DOTS COLON^VarargColon type^TypeDecl) -> varargdecl
    foreignparamlist <- (((fresh (&NAME foreignparam^DeclParList
                         (COMMA !DOTS foreignparam^DeclParList)*
                         (COMMA foreignvararg)? / foreignvararg)?) ~> append) P) -> checklist
    foreignparam <- (P NAME COLON^ParamSemicolon foreigntype^TypeDecl) -> typeddecl
    foreignvararg <- (P DOTS) -> varargdecl
    lambdaparamlist <- (((fresh (&NAME lambdaparam^DeclParList
                        (COMMA !DOTS lambdaparam^DeclParList)*
                        (COMMA lambdavararg^DeclParList)? / &DOTS lambdavararg^DeclParList)?) ~> append) P) -> checklist
    lambdaparam <- (P NAME ((COLON type^TypeDecl)? -> opt)) -> typeddecl
    lambdavararg <- (P DOTS ((COLON type^TypeDecl)? -> opt)) -> varargdecl
    lambda <- (P FUNCTION (TYPEOPEN %{GenericLambda})?
               LPAREN^LParPList lambdaparamlist^DeclParList RPAREN^RParPList
               lambdarettypeopt^TypeFunc block^Statement P END^EndFunc) -> funcexp
    rettypeopt <- (P (COLON rettype^TypeFunc)?) -> rettypeopt
    lambdarettypeopt <- (P (COLON rettype^TypeFunc)?) -> lambdarettypeopt
    decl <- (P NAME ((OPT)? -> boolopt) ((COLON type^TypeDecl)? -> opt)) -> declaration
    decllist <- (fresh decl^DeclLocal (COMMA decl^DeclParList)*) ~> append

    typestart <- ANYNAME / LCURLY / LPAREN
    foreignstart <- ANYNAME / LPAREN / MUL
    baseforeignstart <- ANYNAME / LPAREN
    type <- &typestart (FOREIGN foreigntype^TypeDecl / !FOREIGN titantype^TypeDecl)
    titantype <- &typestart (basetitan ((OPT)? -> boolopt)) -> typeopt
    basetitan <- &(ANYNAME DOT) namedtype^QualName
                / (P NIL) -> TypeNil / (P BOOLEAN) -> TypeBoolean
                / (P INTEGER) -> TypeInteger / (P FLOAT) -> TypeFloat
                / (P STRING) -> TypeString / (P VALUE) -> TypeValue
                / &(FUNCTION LPAREN) functiontype^TypeDecl
                / (P OWNED foreigntype^OwnedPayload) -> TypeOwned
                / &(CONST OPT? LCURLY) constarray^TypeConstArray
                / (P LCURLY type^TypeType
                   ((COLON type^TypeType RCURLY^RCurlyType) -> map_type_tail
                    / RCURLY^RCurlyType -> array_type_tail)) -> finish_curly_type
                / LPAREN type^LParenType RPAREN^RParenTypelist
                / &ANYNAME namedtype^TypeDecl
    constarray <- (P CONST ((OPT)? -> boolopt) LCURLY type^TypeConstArray
                   (!COLON / %{ConstMap}) RCURLY^RCurlyType) -> const_array
    namedtype <- (P ANYNAME
                  ((DOT P ANYNAME^QualName typeargsopt^TypeArgument) -> qualified_tail
                   / typeargsopt^TypeArgument -> name_tail)) -> named_type
    functiontype <- (P FUNCTION LPAREN typelist RPAREN^RParenTypelist
                     rettypeopt) -> functiontype
    typelist <- ((fresh (&typestart type^TypelistType (COMMA !DOTS type^TypelistType)*
                   (COMMA flextail^VarargColon)? / &DOTS flextail^VarargColon)?) ~> append) -> split_types
    flextail <- (DOTS COLON^VarargColon type^TypeDecl) -> type_tail
    resulttypes <- ((fresh (&typestart type^TypelistType (COMMA !DOTS type^TypelistType)*
                     (COMMA returntail^FlexRetColon)? / &DOTS returntail^FlexRetColon)?) ~> append) -> split_types
    returntail <- (DOTS COLON^FlexRetColon type^FlexRetType
                   (!COMMA / %{FlexRetLast})) -> type_tail
    rettype <- &(DOTS / typestart) (DOTS %{FlexRetParens}
              / (LPAREN resulttypes^TypeFunc RPAREN^RParenTypelist
                 ((OPT)? -> boolopt) P) -> parenthesized_returns
              / !LPAREN type^TypeFunc -> singlereturn)

    -- Each pointer constructor consumes a base, not another ungrouped pointer.
    foreigntype <- (P CONST
                   ((MUL baseforeign^TypeDecl ('' -> totrue))
                    / (baseforeign^TypeDecl LBRACKET^RBracketCArray
                       RBRACKET^RBracketCArray ('' -> tofalse)))) -> foreign_const_tail
                 / (P MUL baseforeign^TypeDecl) -> cptrtype
                 / &baseforeignstart (P baseforeign^TypeDecl
                    ((LBRACKET RBRACKET^RBracketCArray)? -> boolopt)) -> foreign_base_tail
    baseforeign <- &(FUNCTION LPAREN)
                   (P FUNCTION LPAREN foreigntypelist^TypeDecl RPAREN^RParenTypelist
                    COLON^ForeignReturnColon foreigntype^TypeFunc) -> foreignfunctiontype
                 / LPAREN foreigntype^LParenType RPAREN^RParenTypelist
                 / (P CUNSIGNED (CLONG CLONG? / CCHAR / CSHORT / CINT)) -> foreignname
                 / (P CSIGNED CCHAR^TypeDecl) -> foreignname
                 / (P CLONG (CLONG / CDOUBLE)?) -> foreignname
                 / (P ANYNAME) -> foreignname
    foreigntypelist <- ((fresh (&foreignstart foreigntype^TypeDecl
                        (COMMA !DOTS foreigntype^TypelistType)*
                        (COMMA foreignflextail)? / foreignflextail)?) ~> append) -> split_types
    foreignflextail <- DOTS -> foreign_type_tail

    fieldhead <- ANYNAME COLON / LOCAL ANYNAME COLON
                / CONST ANYNAME COLON / LOCAL CONST ANYNAME COLON
    recordfields <- (fresh (&fieldhead recordfield^FieldRecord)*) ~> append
    recordfield <- (P localopt constopt P ANYNAME COLON type^TypeRecordField
                    SEMICOLON?) -> recordfield
    varianthead <- !END ANYNAME / END LPAREN
    unionvariants <- (fresh (&varianthead unionvariant^NameUnionVariant)*) ~> append
    unionvariant <- (P ((LOCAL !LPAREN)? -> boolopt) P ANYNAME^NameUnionVariant
                     LPAREN^LParenVariant variantparts
                     SEMICOLON?) -> unionvariant
    variantparts <- RPAREN fresh
                  / &(ANYNAME COLON)
                    ((fresh variantpart (COMMA variantpart^NameVariantPayload)*) ~> append)
                    RPAREN^RParenVariant
                  / (type^TypeUnionVariant -> unionpayload) RPAREN^RParenVariantPayload
    variantpart <- (P ANYNAME^NameVariantPayload COLON^ColonVariantPayload
                    type^TypeUnionVariant) -> typeddecl
    interfacememberstart <- ANYNAME COLON / FUNCTION
    interfacemembers <- (fresh (&interfacememberstart interfacemember^MemberInterface)*) ~> append
    interfacemember <- &(ANYNAME COLON)
                      (P ANYNAME COLON type^TypeInterfaceField SEMICOLON?) -> interfacefielddecl
                    / (P FUNCTION P ANYNAME^NameInterfaceMethod typeparamsopt^NameTypeParam
                       LPAREN^LParInterfaceMethod paramlist^DeclParList RPAREN^RParInterfaceMethod
                       rettypeopt^TypeFunc SEMICOLON?) -> interfacemethoddecl

    block <- (P simpleblock^Statement ((CATCH simpleblock^CatchBlock)? -> opt)) -> trywrap
    simpleblock <- (P ((fresh (&statementstart statement^Statement)*
                      (&RETURN returnstat^ExpReturn)?) ~> append)) -> simpleblock
    statementstart <- SEMICOLON / DO / BREAK / RAISE / DEFER / WHILE / REPEAT
                    / IF / CASE / FOR / LOCAL / CONST / expstart
    statement <- SEMICOLON / &DO doblock^EndBlock
                / (P BREAK) -> StatBreak
                / (P RAISE ((&expstart exp^ExpSimpleExp)? -> opt)) -> StatRaise
                / (P DEFER (!DEFER / %{DeferDefer}) (!SEMICOLON / %{DeferStatement})
                   statement^DeferStatement) -> deferstat
                / (P WHILE exp^ExpWhile DO^DoWhile block^Statement P END^EndWhile) -> whilestat
                / (P REPEAT block^Statement P UNTIL^UntilRepeat exp^ExpRepeat) -> repeatstat
                / (P IF exp^ExpIf THEN^ThenIf block^Statement elseifstats^ExpElseIf
                   ((ELSE block^Statement)? -> opt) P END^EndIf) -> ifstat
                / &CASE casestat^ExpCase / &FOR forstat^DeclFor
                / (P LOCAL? CONST decllist^DeclLocal ASSIGN^AssignLocal
                   explist^ExpLocal) -> constlocalvardecl
                / (P LOCAL decllist^DeclLocal
                   ((ASSIGN explist^ExpLocal)? -> listopt)) -> StatDecl
                / &expstart assignmentorcall^ExpStat
    assignmentorcall <- (P prefixexp^ExpStat
                         ((&(COMMA / ASSIGN)
                            (((fresh (COMMA prefixexp^ExpVarList)*) ~> append)
                             ASSIGN^AssignAssign explist^ExpAssign) -> assignment_tail)
                          / ('' -> tofalse))) -> statement_candidate
    doblock <- (P DO block^Statement P END^EndBlock) -> doblock
    elseifstats <- (fresh (&ELSEIF elseifstat^ExpElseIf)*) ~> append
    elseifstat <- (P ELSEIF exp^ExpElseIf THEN^ThenElseIf block^Statement) -> Then
    casestat <- (P CASE exp^ExpCase ((fresh (&WHEN casearm^NameCaseVariant)*) ~> append)
                 ((ELSE block^Statement)? -> opt) P END^EndCase) -> casestat
    casearm <- (P WHEN P ANYNAME^NameCaseVariant casebindings^LParenCaseVariant
                THEN^ThenCase block^Statement) -> casearm
    casebindings <- (LPAREN
                     ((fresh (!RPAREN casebinding^NameCaseBinding
                       (COMMA casebinding^NameCaseBinding)*)?) ~> append)
                     RPAREN^RParenVariant) -> positionalcasebindings
                  / (LCURLY
                     ((fresh (&NAME namedcasebinding fieldsep?)*) ~> append)
                     RCURLY^RCurlyCaseVariant) -> namedcasebindings
    casebinding <- (P NAME) -> casebinding
    namedcasebinding <- (P NAME
                         ((ASSIGN (P ANYNAME^NameCasePart) -> casepart)? -> opt))
                        -> namedcasebinding
    forstat <- (P FOR decl^DeclFor forrest^InFor) -> forstat
    forrest <- (P ASSIGN exp^Exp1For COMMA^CommaFor exp^Exp2For
                ((COMMA exp^Exp3For)? -> opt)
                DO^DoFor block^Statement P END^EndFor) -> fornum_rest
              / (P ((fresh (COMMA decl^DeclParList)*) ~> append)
                 IN^InFor explist^ExpForIn DO^DoForIn block^Statement P END^EndForIn) -> forin_rest
    returnstat <- (P RETURN ((&expstart explist^ExpReturn)? -> listopt) SEMICOLON?) -> StatReturn

    -- A single incremental fold implements e1..e10 from the reference grammar.
    -- The table above controls precedence; concat and power fold to the right.
    exp <- &expstart (((e11^ExpSimpleExp -> binary_start)
                       {: binaryop e11^OpExp :}*) ~> binary_step) -> binary_finish
    binaryop <- OR -> 'or' / AND -> 'and' / compare
               / BOR -> '|' / BXOR -> '~' / BAND -> '&'
               / shift / CONCAT -> '..' / add / multiply
    e11 <- &expstart (e12^ExpSimpleExp
                     ((&(AS / IS) casttesttail^CastMissingType)? -> opt)) -> cast_or_test
    e12 <- (P ((fresh unop*) ~> append) e13^ExpSimpleExp) -> fold_unops
    e13 <- (P prefixexp^ExpSimpleExp ((fresh (POW poweroperand^OpExp)*) ~> append)) -> power
    poweroperand <- (P ((fresh unop*) ~> append) P prefixexp^OpExp) -> power_operand
    compare <- EQ -> '==' / NE -> '~=' / LT -> '<' / GT -> '>' / LE -> '<=' / GE -> '>='
    shift <- SHL -> '<<' / SHR -> '>>'
    add <- ADD -> '+' / SUB -> '-'
    multiply <- MUL -> '*' / IDIV -> '//' / DIV -> '/' / MOD -> '%%'
    unop <- NOT -> 'not' / (LEN !(DOTS !LBRACKET)) -> '#'
           / SUB -> '-' / BXOR -> '~'
    casttesttail <- (AS type^CastMissingType) -> cast_type_tail
                   / (IS type^IsMissingType) -> test_type_tail

    basestart <- NAME / NIL / TRUE / FALSE / FUNCTION / FOREIGN / LPAREN / LCURLY
                / DOTS / %LITERALSTART / (LEN DOTS !LBRACKET)
    prefixexp <- &basestart (baseexp^ExpSimpleExp (&suffixstart suffixexp^ExpSuffix)*) ~> apply_suffix
    baseexp <- (P NIL) -> nil_exp / (P FALSE -> tofalse) -> ExpBool
              / (P TRUE -> totrue) -> ExpBool / (P NUMBER) -> number_exp
              / (P STRINGLIT) -> ExpString / &LCURLY constructor^RCurlyInitList
              / &FUNCTION lambda^LParPList
              / (P LPAREN exp^ExpSimpleExp RPAREN^RParSimpleExp) -> adjust_exp
              / (P FOREIGN foreigntype^TypeDecl (&DOT)^ForeignTypeMember) -> ExpForeignType
              / (P NAME typeargsopt^TypeArgument) -> name_with_types
              / (P LEN DOTS !LBRACKET) -> dots_len_exp
              / (P DOTS ((!LBRACKET &expstart exp^ExpSimpleExp)? -> opt)) -> dots_or_spread
    -- Lexical start tests inspect only a token's opening, without swallowing
    -- its eventual malformed-number/string diagnostic in a predicate.
    expstart <- %EXPSTART
    callstart <- LPAREN / LCURLY / %STRINGSTART
    suffixstart <- DOT / COLON / LPAREN / LCURLY / %STRINGSTART / LBRACKET
    suffixexp <- (P DOT P ANYNAME^NameDotExpSuf typeargsopt^TypeArgument) -> dot_with_types
                / (P COLON P ANYNAME^NameColonExpSuf typeargsopt^TypeArgument) -> method_with_types
                / &callstart callsuffix^RParFuncArgs
                / &LBRACKET bracketbody^RBracketExpSuf -> suffix_bracket_desc
    callsuffix <- (P LPAREN ((&expstart explist^ExpExpList)? -> listopt) RPAREN^RParFuncArgs
                   ('' -> tofalse)) -> call_suffix
                 / (P LCURLY namedargs^NameNamedArg RCURLY^RCurlyNamedArgs
                    ('' -> totrue)) -> call_suffix
                 / (P {| (P STRINGLIT) -> ExpString |}
                    ('' -> tofalse)) -> call_suffix
    bracketbody <- (P LBRACKET
                    ((COMMA exp^ExpExpSuf RBRACKET^RBracketExpSuf) -> bracket_subset_to_desc_tail
                     / (exp^ExpExpSuf
                        ((COMMA ((&expstart exp^ExpExpSuf)? -> opt) RBRACKET^RBracketExpSuf) -> bracket_subset_tail
                         / (RBRACKET^RBracketExpSuf ('' -> tofalse)))) -> bracket_first_tail)) -> bracket_finish

    explist <- &expstart (((fresh exp^ExpExpList (COMMA exp^ExpExpList)*) ~> append) P) -> check_expression_list
    namedargs <- (fresh (!RCURLY namedarg^NameNamedArg
                  (fieldsep !RCURLY &. namedarg^NameNamedArg)* fieldsep?)?) ~> append
    namedarg <- (P ANYNAME^NameNamedArg ASSIGN^AssignNamedArg exp^ExpNamedArg) -> makefield
    constructor <- (P LCURLY fieldlist^ExpFieldList RCURLY^RCurlyInitList) -> ExpInitList
    fieldlist <- (fresh (!RCURLY &. field^ExpFieldList (fieldsep !RCURLY field^ExpFieldList)*
                  fieldsep?)?) ~> append
    field <- &(ANYNAME ASSIGN) (P ANYNAME ASSIGN exp^ExpFieldList) -> makefield
             / (P LBRACKET exp^ExpExpSuf RBRACKET^RBracketExpSuf
                ASSIGN^AssignField exp^ExpFieldList) -> makefield
             / &expstart (P ('' -> tonil) exp^ExpFieldList) -> makefield
    fieldsep <- COMMA / SEMICOLON

    P <- {} -> get_loc
    SKIP <- %SPACE / %COMMENT
]]
-- Token rules all share the same whitespace boundary. Only this fixed token
-- table is generated; grammar decisions remain in the readable grammar above.
for name, pattern in pairs(defs) do
    if type(pattern) ~= "function" and name:match("^[A-Z]+$") then
        grammar_source = grammar_source .. "\n" .. name .. " <- %" .. name .. " SKIP*"
    end
end
local grammar = re.compile(grammar_source, defs)

function parser.parse(filename, input)
    assert(type(filename) == "string")
    assert(THIS_FILENAME == nil, "the Titan parser is not reentrant")
    THIS_FILENAME, SOURCE_LOCATIONS, SOURCE_TEXT = filename, {}, input
    local ok, result, label, position = pcall(grammar.match, grammar, input)
    THIS_FILENAME, SOURCE_LOCATIONS, SOURCE_TEXT = nil, nil, nil
    if not ok then
        if type(result) == "table" and result._parser_error == SYNTAX_FAILURE then
            return false, { label = result.label, loc = result.loc }
        end
        error(result, 0)
    end
    if result then return documentation.attach(result, input) end
    return false, { label = label, loc = location.from_pos(filename, input, position) }
end

function parser.error_to_string(err)
    return location.format_error(err.loc, "syntax error: %s", syntax_errors.errors[err.label])
end

function parser.pretty_print_ast(node)
    return inspect(node, { process = function(item, path)
        if path[#path] ~= inspect.METATABLE then return item end
    end })
end

return parser
