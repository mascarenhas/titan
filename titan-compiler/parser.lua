local parser = {}

local lpeg = require "lpeglabel"
local re = require "relabel"
local inspect = require "inspect"

local ast = require "titan-compiler.ast"
local lexer = require "titan-compiler.lexer"
local location = require "titan-compiler.location"
local syntax_errors = require "titan-compiler.syntax_errors"

-- File name of the file that is currently being parsed.
-- Since this is a global the parser is not reentrant but we couldn't think of
-- a better way yet. (If only lpeg.re had Carg...)
local THIS_FILENAME = nil

-- Top-level declarations are consumed by a match-time capture as soon as each
-- declaration has been parsed. This keeps LPeg's pending capture result stack
-- bounded for large modules. The parser is already deliberately non-reentrant
-- (see THIS_FILENAME), so the per-parse accumulator follows the same contract.
local PROGRAM_NODES = nil

-- Source positions recur throughout the grammar, both on successful paths and
-- in bounded lookaheads. Locations are immutable compiler metadata, so intern
-- them for one parse instead of repeating the newline search and allocation.
-- The cache follows the parser's existing non-reentrant lifetime.
local SOURCE_LOCATIONS = nil

-- Byte positions where a raw, balanced angle sequence has a call/member
-- delimiter after its matching close. This is only a conservative guard for
-- the authoritative PEG type probe: false positives are harmless, while the
-- guard prevents a failed nested generic-looking comparison from recursively
-- probing every remaining suffix.
local GENERIC_CALL_CANDIDATES = nil

-- Parse-time guardrail on the length of parameter, expression, and generic
-- lists (not a runtime bound; runtime vararg counts have their own cap,
-- TITAN_VARARG_MAX).
local LIST_LIMIT = 100

-- Stay below LPegLabel's default backtrack-stack failure point for a nested
-- sequence of failed generic-call probes.
local GENERIC_PROBE_SCAN_LIMIT = 32

--
-- Functions used by the PEG grammar
--

local defs = {}
local with_name_loc
local with_end_loc

for tokname, tokpat in pairs(lexer) do
    defs[tokname] = tokpat
end

for tag, cons in pairs(ast) do
    defs[tag] = cons
end

-- C99 primitive names are contextual type words rather than reserved Titan
-- keywords. Keep exact-word patterns beside the grammar instead of adding
-- them to the lexer's keyword table: ordinary value declarations named
-- `char`, `long`, and so on must continue to lex as NAME.
local contextual_identifier_rest =
    lpeg.P("_") + lpeg.R("AZ", "az", "09")
local function contextual_type_word(word)
    return lpeg.C(lpeg.P(word)) * -contextual_identifier_rest
end
for token, word in pairs({
    CBOOL = "bool",
    CCHAR = "char",
    CDOUBLE = "double",
    CINT = "int",
    CLONG = "long",
    CSHORT = "short",
    CSIGNED = "signed",
    CUNSIGNED = "unsigned",
    CVOID = "void",
}) do
    defs[token] = contextual_type_word(word)
end

-- Relabel definitions may include ordinary LPegLabel patterns. Keep one parsed
-- statement candidate in a named capture, then classify it through a back
-- capture without traversing the expression again.
defs.STATEMENT_CANDIDATE = lpeg.Cb("statement_candidate")
defs.EXPLIST_ITEM = lpeg.Cb("explist_item")
defs.EXPLIST_ITEMS = lpeg.Cb("explist_items")
defs.FIELD_ITEM = lpeg.Cb("field_item")
defs.TYPE_OPERANDS = lpeg.Cb("type_operands")
defs.RESULT_SHAPE = lpeg.Cb("result_shape")

defs.GENERIC_CALL_START = #lexer.LT * lpeg.Cmt(lpeg.Cp(),
    function(_, position, start)
        assert(GENERIC_CALL_CANDIDATES ~= nil)
        if GENERIC_CALL_CANDIDATES == false or
            GENERIC_CALL_CANDIDATES[start]
        then
            return position
        end
        return false
    end)

local function long_bracket_end(source, position)
    if source:sub(position, position) ~= "[" then return nil end
    local cursor = position + 1
    while source:sub(cursor, cursor) == "=" do cursor = cursor + 1 end
    if source:sub(cursor, cursor) ~= "[" then return nil end
    local level = cursor - position - 1
    local closing = "]" .. string.rep("=", level) .. "]"
    local _, last = source:find(closing, cursor + 1, true)
    if last then return last + 1 end
    return #source + 1
end

local long_bracket_open = lpeg.P("[") * lpeg.P("=") ^ 0 * lpeg.P("[")
local safe_long_bracket = lpeg.Cmt(
    #long_bracket_open * lpeg.P("[") * lpeg.Cp(),
    function(source, _, start)
        return long_bracket_end(source, start - 1)
    end)
local escaped_string_byte = lpeg.P("\\") *
    (lpeg.P("z") * lpeg.S(" \t\n\v\f\r") ^ 0 +
        lpeg.P("\r\n") + lpeg.P("\n\r") + lpeg.P(1))
local safe_single_string = lpeg.P("'") *
    (escaped_string_byte + (lpeg.P(1) - lpeg.S("'\r\n"))) ^ 0 * lpeg.P("'") ^ -1
local safe_double_string = lpeg.P("\"") *
    (escaped_string_byte + (lpeg.P(1) - lpeg.S("\"\r\n"))) ^ 0 * lpeg.P("\"") ^ -1
local safe_short_string = safe_single_string + safe_double_string
local safe_comment = lpeg.P("--") *
    (safe_long_bracket + (lpeg.P(1) - lpeg.P("\n")) ^ 0 * lpeg.P("\n") ^ -1)
local angle_capture = lpeg.Cp() * lpeg.C(lpeg.S("<>"))
local ordinary_scan_bytes = (lpeg.P(1) - lpeg.S("-'\"[<>")) ^ 1
local generic_angle_scan = lpeg.Ct((
    safe_comment + safe_short_string + safe_long_bracket +
    lpeg.P("->") + lpeg.P("<=") + lpeg.P("<<") + lpeg.P(">=") +
    angle_capture + ordinary_scan_bytes + lpeg.P(1)
) ^ 0)

local function collect_generic_call_candidates(source)
    -- Below this constant number of ambiguous starts, repeated probes are
    -- bounded work and the ordinary grammar avoids a whole-source prescan.
    -- Once the threshold is crossed, one linear scan makes every probe O(1).
    local next_angle = 1
    for _ = 1, GENERIC_PROBE_SCAN_LIMIT + 1 do
        next_angle = source:find("<", next_angle, true)
        if not next_angle then return false end
        next_angle = next_angle + 1
    end

    local candidates = {}
    local angles = {}

    local function has_call_delimiter(position)
        while true do
            position = source:find("%S", position)
            if not position then return false end
            if source:sub(position, position + 1) == "--" then
                local after = position + 2
                position = long_bracket_end(source, after) or
                    source:find("\n", after, true) or (#source + 1)
            else
                local byte = source:sub(position, position)
                if byte == "(" or byte == "{" or byte == "." or
                    byte == "\"" or byte == "'"
                then
                    return true
                end
                return byte == "[" and
                    long_bracket_end(source, position) ~= nil
            end
        end
    end

    local angles_found = assert(generic_angle_scan:match(source))
    for index = 1, #angles_found, 2 do
        local position = angles_found[index]
        local byte = angles_found[index + 1]
        if byte == "<" then
            angles[#angles + 1] = position
        elseif #angles > 0 then
            local start = angles[#angles]
            angles[#angles] = nil
            if has_call_delimiter(position + 1) then
                candidates[start] = true
            end
        end
    end

    return candidates
end

-- Titan's standard library has qualified module names so its Lua-facing names
-- do not collide with Lua's own libraries.  Keep Titan source convenient by
-- desugaring the short standard-library imports before module resolution sees
-- them.
local standard_imports = {
    coroutine = "titan.coroutine",
    uv = "titan.uv",
    async = "titan.async",
    timer = "titan.timer",
    io = "titan.io",
    fs = "titan.fs",
    net = "titan.net",
    ssl = "titan.ssl",
    url = "titan.url",
    http = "titan.http",
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

function defs.get_loc(s, pos)
    local locations = assert(SOURCE_LOCATIONS)
    local loc = locations[pos]
    if not loc then
        loc = location.from_pos(THIS_FILENAME, s, pos)
        locations[pos] = loc
    end
    return true, loc
end

-- Semantic tooling needs the exact selected identifier rather than the
-- declaration/expression diagnostic location, which often points at a leading
-- keyword, modifier, dot, or colon. Keep this source metadata private so the
-- ordinary AST constructor shapes and every existing compiler consumer remain
-- unchanged.
with_name_loc = function(node, name_loc)
    node._name_loc = name_loc
    return node
end

-- Likewise, structural folding needs the location of the closing keyword.
-- Record its start independently of the node's ordinary diagnostic location.
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

function defs.rettypeopt(_, x)
    if not x then
        -- No return annotation means a zero-return `(...) -> ()` function, as
        -- in Lua where `function f() end` returns nothing. `return` (bare) is
        -- the only legal return; `: nil` is the explicit one-`nil` form.
        return {}, false
    else
        return x.rettypes, x.flexrettype
    end
end

function defs.lambdarettypeopt(_, x)
    if not x then
        -- No return annotation on a lambda means "infer the return type" — a
        -- distinct case from an explicit `: ()` (which is a zero-return `{}`).
        -- We return `false` so the checker can tell the two apart.
        return false, false
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
        return false
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
    if exp._tag == "Ast.ExpCall" or exp._tag == "Ast.ExpDots" then
        return ast.ExpAdjust(pos, exp)
    else
        return exp
    end
end

function defs.dots_len_exp(pos)
    return ast.ExpDotsLen(pos)
end

-- A `block` with optional `(catch …)?` trailer. When not present the block is
-- the plain `StatBlock` (the common case, so no wrapper node is introduced);
-- when present we wrap it in a `StatTry` whose `catchblock` is the clause body.
function defs.trywrap(pos, block, catchblock)
    if not catchblock then
        return block
    end
    return ast.StatTry(pos, block, catchblock, false)
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
    for i, stat in ipairs(stats) do
        if stat._tag == "Parser.Defer" then
            local rest = {}
            for j = i + 1, #stats do
                table.insert(rest, stats[j])
            end
            local tail = ast.StatBlock(stat.loc, lower_defers(rest))
            tail._defer_tail = true
            local trynode = ast.StatTry(stat.loc,
                tail,
                false,
                ast.StatBlock(stat.stat.loc, { stat.stat }))
            trynode._defer_tail = true
            table.insert(lowered, trynode)
            break
        else
            table.insert(lowered, stat)
        end
    end
    return lowered
end

function defs.simpleblock(pos, stats)
    return ast.StatBlock(pos, lower_defers(stats))
end

-- Mark the parser-owned role explicitly: a root initializer may be either the
-- plain StatBlock or the StatTry produced by a catch trailer or defer lowering.
-- Its diagnostic location is the `do` keyword rather than the first
-- token in the block, so filesystem assembly can reject the construct in a
-- contributor without guessing from the statement tag.
function defs.moduleinit(pos, block, end_loc)
    block.loc = pos
    block._module_initializer = true
    return with_end_loc(block, end_loc)
end

function defs.cptrtype(pos, subtype)
    return ast.TypeCPointer(pos, subtype, false)
end

function defs.constcptrtype(pos, subtype)
    return ast.TypeCPointer(pos, subtype, true)
end

function defs.constarraytype(pos, subtype)
    return ast.TypeArray(pos, subtype, true)
end

function defs.maybeconstarraytype(pos, subtype)
    return ast.TypeArray(pos, subtype, "maybe")
end

-- The first `*` in `owned *T` is the scalar ownership marker, but in
-- `owned *T[]` it is part of the Array element type. Parse the payload once;
-- when an Array suffix follows, reconstruct that pointer layer at its original
-- source location.
function defs.owned_pointer_tail(star_loc, subtype, counted)
    if counted then
        subtype = ast.TypeCPointer(star_loc, subtype, false)
    end
    return { subtype = subtype, count = counted }
end

function defs.owned_array_tail(subtype)
    return { subtype = subtype, count = true }
end

function defs.finish_owned_type(pos, tail)
    return ast.TypeCOwned(pos, tail.subtype, tail.count)
end

function defs.cast_type_tail(target)
    return { kind = "as", target = target }
end

function defs.test_type_tail(target)
    return { kind = "is", target = target }
end

local function finish_casts_and_tests(loc, exp, tails)
    local i = 1
    while i <= #tails do
        local kind = tails[i].kind
        local last = i
        while last < #tails and tails[last + 1].kind == kind do
            last = last + 1
        end

        if kind == "as" then
            -- Each contiguous `as` chain associates to the right. Apply its
            -- last target closest to the operand, then wrap outward toward the
            -- first written target.
            for j = last, i, -1 do
                exp = ast.ExpCast(loc, exp, tails[j].target)
            end
        else
            -- Each contiguous `is` chain associates to the left. Later tests
            -- observe the boolean result of earlier tests; usefulness is a
            -- checker decision rather than a parser restriction.
            for j = i, last do
                exp = ast.ExpIs(loc, exp, tails[j].target)
            end
        end
        i = last + 1
    end
    return exp
end

function defs.finish_casts_and_tests(_, next_pos, loc, exp, tails)
    exp = finish_casts_and_tests(loc, exp, tails)
    return next_pos, exp
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
        return ast.TypeArray(pos, firsttype, false)
    end
end

local function carraylength(loc, n)
    if math.type(n) ~= "integer" then
        return false
    end
    return ast.ExpInteger(loc, n)
end

function defs.carraylength(_, _, loc, n)
    local length = carraylength(loc, n)
    if not length then
        return false
    end
    return true, length
end

function defs.negativecarraylength(_, _, loc, n)
    local length = carraylength(loc, n)
    if not length then
        return false
    end
    length.value = -length.value
    return true, length
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

function defs.forin_rest0(_, exps, block, end_loc)
    return function(pos, decl)
        return with_end_loc(
            ast.StatForIn(pos, { decl }, exps, block), end_loc)
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

function defs.fold_binop_left(pos, matches)
    local lhs = matches[1]
    for i = 2, #matches, 2 do
        local op  = matches[i]
        local rhs = matches[i + 1]
        lhs       = ast.ExpBinop(pos, lhs, op, rhs)
    end
    return lhs
end

function defs.empty_typelist()
    return {}, false
end

function defs.single_vararg_typelist(varargtype)
    return {}, varargtype
end

function defs.other_typelist(type, opt_or_rest, optvarargtype)
    optvarargtype = optvarargtype or false
    if opt_or_rest == "?" then
        return { defs.typeopt(type, opt_or_rest) }, false
    elseif opt_or_rest == nil or #opt_or_rest == 0 then
        return { type }, optvarargtype
    else
        return { type, table.unpack(opt_or_rest) }, optvarargtype
    end
end
local function is_concat_constant(exp)
    return exp._tag == "Ast.ExpString" or
        exp._tag == "Ast.ExpInteger" or
        exp._tag == "Ast.ExpFloat"
end

function defs.fold_binop_concat_right(_, next_pos, matches)
    local operand_count = #matches // 2
    if operand_count == 1 then
        return next_pos, matches[2]
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
            return next_pos, rhs
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
    return next_pos, ast.ExpConcat(concat.loc, exps)
end

-- A power operand needs two locations. Its unary operators use the position
-- before the first prefix, while a nested power node begins at the simple
-- expression after those prefixes. Keeping this parser-only carrier lets the
-- flat grammar reproduce the locations of the former recursive `e12` rule.
function defs.power_operand(unary_loc, unops, simple_loc, exp)
    return {
        unary_loc = unary_loc,
        unops = unops,
        simple_loc = simple_loc,
        exp = exp,
    }
end

function defs.power_tail(op, operand)
    operand.op = op
    return operand
end

function defs.fold_power(_, next_pos, pos, lhs, tails, casttesttails)
    if not tails then
        return next_pos, lhs
    end

    local last = tails[#tails]
    local rhs = defs.fold_unops(last.unary_loc, last.unops, last.exp)
    rhs = finish_casts_and_tests(last.unary_loc, rhs, casttesttails)

    -- `a ^ -b ^ -c` is `a ^ (-(b ^ (-c)))`: each unary prefix on a
    -- right-hand operand wraps the complete power suffix beginning there.
    for i = #tails - 1, 1, -1 do
        local operand = tails[i]
        rhs = ast.ExpBinop(
            operand.simple_loc, operand.exp, operand.op, rhs)
        rhs = defs.fold_unops(operand.unary_loc, operand.unops, rhs)
    end

    return next_pos, ast.ExpBinop(pos, lhs, tails[1].op, rhs)
end

function defs.fold_unops(pos, unops, exp)
    for i = #unops, 1, -1 do
        local op = unops[i]
        exp = ast.ExpUnop(pos, op, exp)
    end
    return exp
end

-- We represent the suffix of an expression by a function that receives the
-- base expression and returns a full expression including the suffix.

local function unpack_membername(member)
    if type(member) == "table" then
        return member.name, true
    end
    return member, false
end

-- `callexpsuffix` gives ordinary calls the same capture shape as explicit
-- generic calls. Keep a fresh empty list on every AST node: the checker owns
-- and may decorate each call independently.
function defs.ordinary_call(args, named)
    return {}, args, named
end

-- The aggregate-owner branch consumes `.member` together with the preceding
-- type arguments so the complete generic list is probed only once. This
-- parser-only carrier preserves both the dot location and contextual C-name
-- status until `suffix_anyfunccall` builds the existing AST shape.
function defs.nominal_member_selector(pos, name_loc, member)
    local name, contextual = unpack_membername(member)
    return {
        loc = pos,
        name_loc = name_loc,
        name = name,
        contextual = contextual,
    }
end

local function function_call_suffix(pos, typeargs, args, named)
    return function(exp)
        local callargs
        if named then
            callargs = ast.ArgsNamedFunc(pos, args)
        else
            callargs = ast.ArgsFunc(pos, args)
        end
        return ast.ExpCall(pos, exp, callargs, typeargs)
    end
end

-- Generic calls and aggregate-owner selections share the one factored suffix
-- production. A call always supplies the final boolean capture, including
-- `false` for positional arguments; its absence therefore identifies the
-- aggregate-owner selector without inspecting user AST data.
function defs.suffix_anyfunccall(pos, typeargs, args, named)
    if named ~= nil then
        return function_call_suffix(pos, typeargs, args, named)
    end

    local selector = args
    return function(exp)
        exp._nominal_typeargs = typeargs
        exp._nominal_typeargs_loc = pos

        local var = with_name_loc(
            ast.VarDot(selector.loc, exp, selector.name), selector.name_loc)
        if selector.contextual then
            var._contextual_c_name = true
        end
        return ast.ExpVar(selector.loc, var)
    end
end

function defs.method_reference_tail()
    return false
end

-- Parse `: NAME` once, then distinguish a call tail from the empty tail of a
-- bound-method reference. Calls retain the existing positional/named argument
-- nodes and explicit (possibly empty) type-argument list.
function defs.suffix_anymethod(pos, name_loc, name, typeargs, args, named)
    if not typeargs then
        return function(exp)
            return with_name_loc(ast.ExpMethodRef(pos, exp, name), name_loc)
        end
    end

    return function(exp)
        local callargs
        if named then
            callargs = ast.ArgsNamedMethod(pos, name, args)
        else
            callargs = ast.ArgsMethod(pos, name, args)
        end
        callargs._name_loc = name_loc
        return ast.ExpCall(pos, exp, callargs, typeargs)
    end
end

function defs.suffix_bracket(pos, index)
    return function(exp)
        return ast.ExpVar(pos, ast.VarBracket(pos, exp, index))
    end
end

-- Parse every bracket suffix body exactly once, then decide from the token
-- after its first expression whether it is an index (`[exp]`) or a subset
-- (`[exp, ...]`).  Keeping this parser-only descriptor separate from the AST
-- avoids the exponential retry that results from ordered
-- `subsetsuffix / indexsuffix` alternatives on nested indexes.
function defs.bracket_subset_tail(last)
    return { last = last }
end

function defs.bracket_subset_to_desc(pos, last)
    return {
        kind = "subset",
        loc = pos,
        first = false,
        last = last,
    }
end

function defs.bracket_from_first_desc(pos, first, tail)
    if not tail then
        return {
            kind = "index",
            loc = pos,
            first = first,
            last = false,
        }
    end
    return {
        kind = "subset",
        loc = pos,
        first = first,
        last = tail.last,
    }
end

function defs.suffix_bracket_desc(desc)
    if desc.kind == "index" then
        return defs.suffix_bracket(desc.loc, desc.first)
    end
    return defs.suffix_subset_from(
        desc.loc, desc.first, desc.last)
end

-- Comma-bearing brackets are slice/subset suffixes rather than ordinary
-- indexing. Keep them in the general suffix grammar so the checker can reject
-- an ExpSubset that is not the subject of a tail spread. Missing bounds use
-- false, matching the parser's other optional AST fields.
function defs.suffix_subset_to(pos, last)
    return function(exp)
        return ast.ExpSubset(pos, exp, false, last)
    end
end

function defs.suffix_subset_from(pos, first, last)
    return function(exp)
        return ast.ExpSubset(pos, exp, first, last)
    end
end

function defs.contextual_c_name(name)
    return { name = name }
end

function defs.suffix_dot(pos, name_loc, member)
    return function(exp)
        local name, contextual = unpack_membername(member)
        local var = with_name_loc(ast.VarDot(pos, exp, name), name_loc)
        if contextual then
            var._contextual_c_name = true
        end
        return ast.ExpVar(pos, var)
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

function defs.fold_suffixes(exp, suffixes)
    for i = 1, #suffixes do
        local suf = suffixes[i]
        exp = suf(exp)
    end
    return exp
end

function defs.spread_exp(pos, exp)
    return ast.ExpSpread(pos, exp, false, false)
end

local function dots_bracket_exp(pos, desc)
    if desc.kind == "index" then
        return ast.ExpDotsIndex(pos, desc.first)
    end
    return ast.ExpSubset(
        desc.loc, ast.ExpDots(pos), desc.first, desc.last)
end

function defs.dots_bracket_exp(pos, desc)
    return dots_bracket_exp(pos, desc)
end

-- A direct `...[...]` item is classified only after it has been parsed and
-- the following list delimiter is known.  In a tail position a subset becomes
-- a spread; in a non-tail position it remains an explicit subset expression
-- for the checker to diagnose.  An ordinary `...[index]` is scalar in either
-- position.  Parentheses go through `exp`, not this parser-only carrier, so
-- `(...[first, last])` remains explicitly scalar.
local function dots_bracket_item(pos, exp)
    return {
        _tag = "Parser.DotsBracketItem",
        loc = pos,
        exp = exp,
        is_subset = true,
    }
end

local function direct_dots_subset(exp)
    return exp._tag == "Ast.ExpSubset" and
        exp.exp._tag == "Ast.ExpDots"
end

-- DOTS-started scalar expressions must retain their complete binary, power,
-- cast, and suffix continuations. Parse that expression once and retain a
-- parser-only carrier only when the complete expression is the direct subset
-- spelling that a tail position promotes to a spread.
function defs.claim_dots_started_item(_, position, pos, exp)
    if direct_dots_subset(exp) then
        return position, dots_bracket_item(pos, exp)
    end
    return position, exp
end

function defs.claim_dots_started_field(_, position, pos, exp)
    if direct_dots_subset(exp) then
        return position, dots_bracket_item(pos, exp)
    end
    return position, ast.Field(pos, false, exp)
end

local function materialize_dots_bracket_item(item, is_tail)
    if item._tag ~= "Parser.DotsBracketItem" then
        return item
    end
    if is_tail and item.is_subset then
        return ast.ExpSpread(item.loc, item.exp, false, false)
    end
    return item.exp
end

local function is_open_explist_item(item)
    return item._tag == "Ast.ExpDots" or item._tag == "Ast.ExpSpread"
end

function defs.fixed_explist_item(_, position, item)
    item = materialize_dots_bracket_item(item, false)
    if item._tag == "Ast.ExpDots" then
        return false
    end
    return position, item
end

function defs.tail_explist_item(_, position, item)
    return position, {
        _tag = "Parser.TailExplistItem",
        exp = materialize_dots_bracket_item(item, true),
    }
end

function defs.check_explist_limit(_, _, list)
    local tail = list[#list]
    local is_tail = tail and tail._tag == "Parser.TailExplistItem"
    local final = is_tail and tail.exp or tail
    if #list <= LIST_LIMIT or
        (#list == LIST_LIMIT + 1 and is_tail
            and is_open_explist_item(final))
    then
        list[#list] = final
        return true, list
    end
    return false
end

local function materialize_field_item(item, is_tail)
    if item._tag == "Parser.DotsBracketItem" then
        return ast.Field(item.loc, false,
            materialize_dots_bracket_item(item, is_tail))
    end
    return item
end

function defs.fixed_field_item(_, position, item)
    item = materialize_field_item(item, false)
    if item.exp._tag == "Ast.ExpDots" then
        return false
    end
    return position, item
end

function defs.tail_field_item(_, position, item)
    return position, materialize_field_item(item, true)
end

function defs.statement_name_prefix(pos, name)
    return {
        exp = defs.name_exp(pos, name),
        bare_parenthesized = false,
    }
end

function defs.statement_parenthesized_prefix(pos, exp)
    return {
        exp = defs.adjust_exp(pos, exp),
        bare_parenthesized = true,
    }
end

function defs.fold_statement_candidate(prefix, suffixes)
    prefix.exp = defs.fold_suffixes(prefix.exp, suffixes)
    if #suffixes > 0 then
        prefix.bare_parenthesized = false
    end
    return prefix
end

function defs.statement_candidate_var(_, position, candidate)
    if candidate.bare_parenthesized or
        candidate.exp._tag ~= "Ast.ExpVar"
    then
        return false
    end
    return position, candidate.exp.var
end

function defs.statement_candidate_call(_, position, candidate)
    if candidate.exp._tag ~= "Ast.ExpCall" then
        return false
    end
    return position, candidate.exp
end

function defs.statement_assignment_tail(vars, exps)
    return { vars = vars, exps = exps }
end

function defs.statement_assignment_candidate(first, tail)
    local vars = { first }
    for i = 1, #tail.vars do
        vars[#vars + 1] = tail.vars[i]
    end
    return { assignment = true, vars = vars, exps = tail.exps }
end

function defs.statement_call_candidate(exp)
    return { assignment = false, exp = exp }
end

function defs.finish_assignment_or_call(pos, candidate)
    if candidate.assignment then
        return ast.StatAssign(pos, candidate.vars, candidate.exps)
    end
    return ast.StatCall(pos, candidate.exp)
end

function defs.exp2var(exp)
    return exp.var
end

function defs.exp_is_var(_, pos, exp)
    if exp._tag == "Ast.ExpVar" then
        return pos, exp
    else
        return false
    end
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

function defs.foreignimportdecl(pos, name_loc, localname, headername)
    return with_name_loc(
        ast.TopLevelForeignImport(pos, localname, headername), name_loc)
end

function defs.typename(pos, name, typeargs)
    return with_name_loc(ast.TypeName(pos, name, typeargs), pos)
end

function defs.surface_c_type(pos, ...)
    return with_name_loc(
        ast.TypeName(pos, table.concat({...}, " "), {}), pos)
end

function defs.surface_c_float_type(pos)
    return with_name_loc(ast.TypeName(pos, "foreign float", {}), pos)
end

function defs.surface_c_type_exp(typenode)
    local exp = defs.name_exp(typenode.loc, typenode.name)
    exp.var._surface_c_namespace = true
    return exp
end

function defs.typeparamdecl(pos, name, constraint)
    return with_name_loc(ast.TypeParam(pos, name, constraint), pos)
end

function defs.funcexp(pos, params, rettypes, flexrettype, block, end_loc)
    return with_end_loc(
        ast.ExpFunction(pos, params, rettypes, flexrettype, block), end_loc)
end

function defs.casearm(pos, name_loc, name, binding, block)
    return with_name_loc(
        ast.CaseArm(pos, name, binding, block), name_loc)
end

function defs.makefield(pos, name, exp)
    local node = ast.Field(pos, name, exp)
    if type(name) == "string" then node._name_loc = pos end
    return node
end

function defs.toplevelvardecl(pos, islocal, decl, value)
    return ast.TopLevelVar(pos, islocal, false, decl, value)
end

function defs.toplevelconstvardecl(pos, islocal, decl, value)
    decl.isconst = true
    return ast.TopLevelVar(pos, islocal, true, decl, value)
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
        { applied_owner_type(pos, name, typeparams) }, false, body, {})
    new.islocal = islocal or has_local_field(fields)
    new._record_constructor = true
    return record, new
end

function defs.unionvariantdecl(pos, name, payload)
    return with_name_loc(ast.UnionVariant(pos, name, payload), pos)
end

function defs.localunionvariantdecl(pos, name_loc, name, payload)
    local variant = with_name_loc(
        ast.UnionVariant(pos, name, payload), name_loc)
    variant.islocal = true
    return variant
end

function defs.uniondecl(pos, islocal, name_loc, name, typeparams, variants,
                        end_loc)
    local union = with_end_loc(with_name_loc(
        ast.TopLevelUnion(pos, name, variants, typeparams), name_loc), end_loc)
    union.islocal = islocal

    local nodes = { union }
    for _, variant in ipairs(variants) do
        local params = {}
        local value = false
        if variant.payload then
            local param = ast.Decl(
                variant.loc, "__union_payload", variant.payload, false, false)
            params[1] = param
            value = ast.ExpVar(
                variant.loc,
                ast.VarName(variant.loc, param.name))
        end

        local init = ast.ExpUnionInit(
            variant.loc, name, variant, value)
        local body = ast.StatBlock(variant.loc, {
            ast.StatReturn(variant.loc, { init }),
        })
        local constructor = ast.TopLevelStatic(
            variant.loc,
            name,
            variant.name,
            params,
            { applied_owner_type(pos, name, typeparams) },
            false,
            body,
            {})
        constructor.islocal = islocal or variant.islocal or false
        constructor._union_constructor = true
        constructor._union_variant = variant
        nodes[#nodes + 1] = constructor
    end

    return table.unpack(nodes)
end

function defs.recordfielddecl(pos, name_loc, name, type)
    return with_name_loc(
        ast.Decl(pos, name, type, false, false), name_loc)
end

function defs.localrecordfielddecl(pos, name_loc, name, type)
    local decl = with_name_loc(
        ast.Decl(pos, name, type, false, false), name_loc)
    decl.islocal = true
    return decl
end

function defs.optionrecordfielddecl(pos, name_loc, name, type)
    return with_name_loc(ast.Decl(
        pos, name, ast.TypeOption(type.loc, type), false, false), name_loc)
end

function defs.localoptionrecordfielddecl(pos, name_loc, name, type)
    local decl = defs.optionrecordfielddecl(pos, name_loc, name, type)
    decl.islocal = true
    return decl
end

function defs.constrecordfielddecl(pos, name_loc, name, type)
    return with_name_loc(
        ast.Decl(pos, name, type, false, true), name_loc)
end

function defs.localconstrecordfielddecl(pos, name_loc, name, type)
    local decl = defs.constrecordfielddecl(pos, name_loc, name, type)
    decl.islocal = true
    return decl
end

function defs.constoptionrecordfielddecl(pos, name_loc, name, type)
    return with_name_loc(ast.Decl(
        pos, name, ast.TypeOption(type.loc, type), false, true), name_loc)
end

function defs.localconstoptionrecordfielddecl(pos, name_loc, name, type)
    local decl = defs.constoptionrecordfielddecl(pos, name_loc, name, type)
    decl.islocal = true
    return decl
end

function defs.typeddecl(pos, name, type)
    return with_name_loc(ast.Decl(pos, name, type, false, false), pos)
end

function defs.optiondecl(pos, name, type)
    if type then
        return with_name_loc(ast.Decl(
            pos, name, ast.TypeOption(type.loc, type), false, false), pos)
    else
        return with_name_loc(ast.Decl(pos, name, false, true, false), pos)
    end
end

function defs.inferreddecl(pos, name)
    return with_name_loc(ast.Decl(pos, name, false, false, false), pos)
end

function defs.casebinding(pos, name)
    return with_name_loc(ast.Decl(pos, name, false, false, false), pos)
end

function defs.constlocalvardecl(pos, decls, exps)
    for _, decl in ipairs(decls) do
        decl.isconst = true
    end
    return ast.StatDecl(pos, decls, exps)
end

-- A variadic parameter `...: t` (or, for lambdas only, an untyped `...`):
-- encoded as a trailing Decl whose name is `false`. A typed vararg carries its
-- element type; an untyped lambda vararg has `type == false`, mirroring the
-- inferred-parameter encoding (name set / type false) but inverted (name false /
-- type false). Detect a variadic function with `params[#params].name == false`.
-- The `type` capture is absent (nil) for the untyped lambda form; normalise it
-- to `false`.
function defs.varargdecl(pos, type)
    return ast.Decl(pos, false, type or false, false, false)
end

-- A trailing `...` field in an array constructor: `{ a, ... }`. Encoded as a
-- key-less Field whose expression is a bare `ExpDots`.
function defs.dots_field(pos)
    return ast.Field(pos, false, ast.ExpDots(pos))
end

function defs.spread_field(pos, exp)
    return ast.Field(pos, false, exp)
end

-- Vararg element type for a function-type annotation `(t, ...: u) -> r`. Returns
-- the element type node (dropping the position capture).
function defs.varargtype(_, type)
    return type
end

-- A flexible return tail uses the same capture shape as a typed input vararg,
-- but it is parsed by a separate production so diagnostics can describe a
-- return rather than a parameter.
function defs.flexrettype(_, type)
    return type
end

-- `rettype` always returns this untagged carrier. Keeping the fixed dense list
-- separate from the optional flexible element type avoids inserting a sentinel
-- into `rettypes`, whose numeric indices are meaningful throughout the checker
-- and coder.
function defs.returnshape(rettypes, flexrettype)
    return { rettypes = rettypes, flexrettype = flexrettype }
end

function defs.singlereturn(type)
    return { rettypes = { type }, flexrettype = false }
end

-- Materialize a carrier before a named back-reference can observe it, and
-- close its capture scope before returning to an enclosing AST list. Both
-- boundaries matter: deferred captures replay nested constructors, while
-- unscoped named groups leak private keys into surrounding table captures.
function defs.type_capture(_, next_pos, value)
    return next_pos, value
end

function defs.optional_returnshape(_, next_pos, shape)
    if #shape.rettypes ~= 1 or shape.flexrettype then return false end
    return next_pos, defs.singlereturn(defs.typeopt(shape.rettypes[1], "?"))
end

function defs.simple_type_operand(type)
    return {
        kind = "simple",
        loc = type.loc,
        type = type,
    }
end

function defs.argument_type_operand(pos, types, varargtype)
    if #types == 1 and not varargtype then
        return defs.simple_type_operand(types[1])
    end
    return {
        kind = "arguments",
        loc = pos,
        types = types,
        tailtype = varargtype,
    }
end

function defs.result_type_operand(pos, shape)
    return {
        kind = "results",
        loc = pos,
        types = shape.rettypes,
        tailtype = shape.flexrettype,
    }
end

function defs.foreign_type_operand(pos, types, varargtype)
    return {
        kind = "foreign",
        loc = pos,
        types = types,
        tailtype = varargtype,
    }
end

local function operand_return_shape(operand)
    if operand.kind == "simple" then
        return defs.singlereturn(operand.type)
    end
    assert(operand.kind == "results")
    return {
        rettypes = operand.types,
        flexrettype = operand.tailtype,
    }
end

local function function_from_operand(operand, result)
    local argtypes
    local varargtype
    if operand.kind == "simple" then
        argtypes = { operand.type }
        varargtype = false
    else
        argtypes = operand.types
        varargtype = operand.tailtype
    end

    if operand.kind == "foreign" then
        return ast.TypeForeignFunction(operand.loc, argtypes,
            result.rettypes, varargtype, result.flexrettype)
    end
    return ast.TypeFunction(operand.loc, argtypes,
        result.rettypes, varargtype, result.flexrettype)
end

local function fold_type_operands(operands)
    if #operands == 1 then
        assert(operands[1].kind == "simple")
        return operands[1].type
    end

    local result = operand_return_shape(operands[#operands])
    for i = #operands - 1, 1, -1 do
        result = defs.singlereturn(
            function_from_operand(operands[i], result))
    end
    return result.rettypes[1]
end

function defs.fold_type_operands(_, next_pos, operands)
    if #operands == 1 and operands[1].kind ~= "simple" then return false end
    return next_pos, fold_type_operands(operands)
end

function defs.fold_rettype_operands(_, next_pos, operands)
    if #operands == 1 then
        return next_pos, operand_return_shape(operands[1])
    end
    return next_pos, defs.singlereturn(fold_type_operands(operands))
end

function defs.makeprogram(_, init)
    local nodes = assert(PROGRAM_NODES)
    if init then
        table.insert(nodes, init)
    end
    return nodes
end

function defs.appendprogram(_, pos, ...)
    local nodes = assert(PROGRAM_NODES)
    for i = 1, select("#", ...) do
        local node = select(i, ...)
        table.insert(nodes, node)
    end
    -- Consume the declaration captures instead of returning them to the
    -- enclosing program capture.
    return pos
end

-- Match-time guard against absurdly long parameter, expression, and generic
-- lists. Used as a `=>` predicate over a captured list: succeeds (re-yielding
-- the list capture)
-- when within LIST_LIMIT, fails when over so the grammar can throw
-- `%{ListTooLong}`. The list must be returned explicitly so the surrounding
-- production keeps it (a bare `true` discards the inner capture).
function defs.checklist(_, _, list)
    if #list > LIST_LIMIT then
        return false
    end
    return true, list
end

local grammar = re.compile([[

    program         <-  SKIP*
                        (P (( toplevelinterface
                              / method
                              / static
                              / foreignfunc
                              / toplevelfunc
                              / topleveltype
                              / toplevelconstvar
                              / toplevelvar
                              / toplevelrecord
                              / toplevelunion
                              / import
                              / foreign ) => appendprogram)*
                           ((moduleinit)? -> opt) !.) -> makeprogram

    method          <- (P  localopt FUNCTION P NAME COLON P NAME^NameMethod
                           typeparamsopt
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block P END^EndFunc)       -> methoddecl

    static          <- (P  localopt FUNCTION P NAME DOT P NAME^NameStatic
                           typeparamsopt
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block P END^EndFunc)       -> staticdecl

    toplevelfunc    <- (P  localopt FUNCTION P NAME^NameFunc
                           typeparamsopt
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block P END^EndFunc)       -> toplevelfuncdecl

    foreignfunc     <- (P  &(FOREIGN FUNCTION) FOREIGN FUNCTION P NAME^NameFunc
                           (LT %{GenericForeignFunc})?
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block P END^EndFunc)       -> foreignfuncdecl

    topleveltype    <- (P  localopt TYPE P NAME^NameTypeAlias
                           (LT %{GenericTypeAlias})?
                           ASSIGN^AssignTypeAlias
                           type^TypeTypeAlias)                   -> typealiasdecl

    toplevelconstvar
                    <- (P localopt CONST decl
                           ((ASSIGN exp^ExpVarDec)? -> opt))    -> toplevelconstvardecl

    toplevelvar     <- (P localopt decl ASSIGN^AssignVar
                           !(IMPORT / (FOREIGN IMPORT))
                           exp^ExpVarDec)                        -> toplevelvardecl

    toplevelrecord  <- (P  localopt RECORD P NAME^NameRecord
                           typeparamsopt
                           recordfields^FieldRecord
                           P END^EndRecord)                      -> recorddecl

    toplevelunion   <- (P  localopt UNION P NAME^NameUnion
                           typeparamsopt
                           unionvariants^VariantUnion
                           P END^EndUnion)                       -> uniondecl

    -- Interfaces are deliberately top-level and non-local. The local branch
    -- exists only to commit to the interface-specific diagnostic before the
    -- ordinary `local NAME = ...` alternatives get a chance to claim it.
    toplevelinterface
                    <- (P  (LOCAL INTERFACE %{LocalInterface} / INTERFACE)
                           P NAME^NameInterface
                           typeparamsopt
                           interfacemembers
                           (P END
                            / (!. %{EndInterface})
                            / %{MemberInterface}))               -> interfacedecl

    -- Unlike parameter and expression lists, the repeated member declaration
    -- list has no arbitrary source-level length limit.
    interfacemembers
                    <- {| interfacemember^InterfaceMember
                           interfacemember* |}

    interfacemember <- interfacemethod
                     / interfacefield
                     / (P  LOCAL %{LocalInterfaceField})

    interfacemethod <- (P  LOCAL FUNCTION %{LocalInterfaceMethod})
                     / (P  FUNCTION P NAME^NameInterfaceMethod
                           typeparamsopt
                           LPAREN^LParInterfaceMethod paramlist
                           RPAREN^RParInterfaceMethod
                           interfacerettypeopt)                  -> interfacemethoddecl

    interfacefield <- (P  NAME COLON^ColonInterfaceField
                           type^TypeInterfaceField SEMICOLON?)   -> interfacefielddecl

    localopt        <- (LOCAL)?                                  -> boolopt

    -- Declaration binders are nonempty, source ordered, and use the same
    -- parser guardrail as parameter and expression lists. Constraints are
    -- syntactically named Interface applications; semantic Interface and
    -- scope validation belongs to the checker.
    typeparamsopt   <- (typeparamlist? -> listopt)

    typeparamlist   <- LT
                       (({| typeparam^NameTypeParam
                            (COMMA typeparam^NameTypeParam)* |}
                          => checklist) / %{ListTooLong})
                       GENERICGT^RAngleTypeParams

    typeparam       <- (P  NAME
                           ((COLON namedtype^TypeParamConstraint)? -> opt))
                                                                  -> typeparamdecl

    import          <- (P  LOCAL P NAME^NameImport ASSIGN^AssignImport
                          !FOREIGN IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                          STRINGLIT^StringImport))               -> importdecl

    foreign         <- (P  LOCAL P NAME^NameImport ASSIGN^AssignImport
                           &(FOREIGN IMPORT) FOREIGN IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                           STRINGLIT^StringImport))              -> foreignimportdecl

    moduleinit      <- (P DO block P END^EndBlock) -> moduleinit -- marks StatBlock/StatTry

    rettypeopt      <- (P  (COLON rettype^TypeFunc)?)            -> rettypeopt

    interfacerettypeopt
                    <- (P  (COLON rettype^TypeInterfaceMethod)?)
                                                                  -> rettypeopt

    -- Lambda return-type: `false` when absent (infer), distinct from `: ()`.
    lambdarettypeopt<- (P  (COLON rettype^TypeFunc)?)            -> lambdarettypeopt

    -- A trailing, last-only typed variadic parameter `...: t` (no name). The
    -- element type is mandatory for top-level functions and methods (the `: t`
    -- declaration style, matching `name: type` everywhere else).
    varargparam     <- (P  DOTS COLON^VarargColon type^TypeDecl) -> varargdecl

    -- A lambda's trailing vararg `...` may OMIT the `: t` (the element type is
    -- then inferred from context, like an unannotated lambda parameter). There is
    -- no ambiguity: `function(...): T` is an untyped vararg whose `)` precedes the
    -- return-type `:`, while `function(...: T)` is a typed vararg.
    lambdavarargparam <- (P  DOTS (COLON type^TypeDecl)?)        -> varargdecl

    -- The fixed-param loop stops before a `, ...` (the `!DOTS` guard) so the
    -- optional trailing `varargparam` consumes that comma itself.
    paramlist       <- ({| (param (COMMA !DOTS param^DeclParList)*
                              (COMMA varargparam)? / varargparam)? |}
                        => checklist) / %{ListTooLong}           -- produces {Decl}

    param           <- (P  NAME COLON^ParamSemicolon
                           type^TypeDecl)                        -> typeddecl

    -- Lambda parameters: the type annotation is optional, and a trailing `...`
    -- vararg may likewise omit its element type (inferred from context).
    lambdaparamlist <- ({| (lambdaparam (COMMA !DOTS lambdaparam^DeclParList)*
                              (COMMA lambdavarargparam)? / lambdavarargparam)? |}
                        => checklist) / %{ListTooLong}           -- produces {Decl}

    lambdaparam     <- (P  NAME COLON type^TypeDecl)             -> typeddecl
                     / (P  NAME)                                 -> inferreddecl

    funcexp         <- (P  FUNCTION (LT %{GenericLambda})?
                           LPAREN^LParPList lambdaparamlist
                           RPAREN^RParPList lambdarettypeopt
                           block P END^EndFunc)                  -> funcexp

    decl            <- (P  NAME COLON type^TypeDecl)             -> typeddecl
                     / (P  NAME OPT COLON type^TypeDecl)         -> optiondecl
                     / (P  NAME OPT)                             -> optiondecl
                     / (P  NAME)                                 -> inferreddecl

    decllist        <- {| decl (COMMA decl^DeclParList)* |}      -- produces {Decl}

    -- Fixed and unknown-length C array spellings are declaration-target syntax
    -- for constructor-initialized locals. They do not enter the general type
    -- grammar: the checker lowers `T[]` to an uncounted borrowed pointer view.
    localcarrayextent
                     <- (((P  SUB NUMBER) => negativecarraylength)
                        / ((P  NUMBER) => carraylength))

    localcarraytype <- (P  (surfacecompoundtype / surfacesingletype /
                            qualifiedtype) LBRACKET
                            ((localcarrayextent)? -> opt)
                            RBRACKET^RBracketCArray)              -> TypeCArray

    localdecl       <- (P  NAME COLON
                            (localcarraytype / type)^TypeDecl)     -> typeddecl
                     / (P  NAME OPT COLON type^TypeDecl)          -> optiondecl
                     / (P  NAME OPT)                              -> optiondecl
                     / (P  NAME)                                  -> inferreddecl

    localdecllist   <- {| localdecl
                            (COMMA localdecl^DeclLocal)* |}

    membername      <- NAME
                     / (CNAME -> contextual_c_name)

    -- Named types are the only type form that accepts applications. The
    -- contextual close consumes one literal `>` at a time, so nested adjacent
    -- applications do not weaken the ordinary `>>` expression token.
    typeargsopt     <- (typearglist? -> listopt)

    typearglist     <- LT
                       (({| type^TypeArgument
                            (COMMA type^TypeArgument)* |}
                          => checklist) / %{ListTooLong})
                       GENERICGT^RAngleTypeArgs

    namedtype       <- qualifiedtype
                     / (P  NAME typeargsopt)                     -> typename

    qualifiedtype   <- (P  NAME DOT P membername^QualName
                           typeargsopt)                           -> qualifiedtype

    -- Only compound C99 primitive spellings need a dedicated contextual
    -- production. Single-word spellings remain ordinary NAME/namedtype nodes
    -- and are recognized by the checker after ordinary value/type lookup.
    -- Factor the compounds by their leading word so probing a normal NAME in
    -- a long expression remains constant bounded work.
    surfacecompoundtype
                    <- (P  (CUNSIGNED (CLONG CLONG / CCHAR / CSHORT /
                                      CINT / CLONG)
                            / CSIGNED CCHAR
                            / CLONG (CLONG / CDOUBLE)))          -> surface_c_type
                     / (P  FOREIGN FLOAT)                        -> surface_c_float_type

    -- A local fixed/unknown C array is the one type context that deliberately
    -- does not accept an arbitrary named type. Recognize the exact single-word
    -- surface primitives here without putting this alternative on the hot
    -- general-expression path.
    surfacesingletype
                    <- (P  (CVOID / CBOOL / CCHAR / CSHORT /
                            CINT / CLONG / CDOUBLE))              -> surface_c_type

    -- An owned payload is deliberately optionless: the sole trailing `?` in
    -- `simpletype` wraps the complete owner. `ownedtail` parses its recursive
    -- payload once. Its first `*` is the scalar ownership marker unless an
    -- Array suffix follows, in which case `owned_pointer_tail` restores it as
    -- part of the counted element type.
    cownedpayload   <- (P  NIL)                                  -> TypeNil
                     / (P  BOOLEAN)                              -> TypeBoolean
                     / (P  INTEGER)                              -> TypeInteger
                     / (P  FLOAT)                                -> TypeFloat
                     / (P  STRING)                               -> TypeString
                     / (P  VALUE)                                -> TypeValue
                     / (P  CONST MUL
                           cownedpayload^OwnedPayload)           -> constcptrtype
                     / (P  MUL
                           cownedpayload^OwnedPayload)           -> cptrtype
                     / surfacecompoundtype
                     / namedtype
                     / ownedtype
                     / groupedtype

    ownedtype       <- (P  OWNED ownedtail)                      -> finish_owned_type

    -- A non-star owner can begin with `const` only when that starts one or
    -- more pointer layers and eventually reaches a payload base. Reject a
    -- malformed regular pointer prefix at the outer owner before the labeled
    -- recursive payload rule turns the historical shape error into an
    -- OwnedPayload error. This bounded probe never traverses the payload.
    cownedbasehead  <- NIL / BOOLEAN / INTEGER / FLOAT / STRING / VALUE
                     / CVOID / CBOOL / CCHAR / CSHORT / CINT / CLONG
                     / CDOUBLE / CSIGNED / CUNSIGNED / FOREIGN / NAME / OWNED
                     / LPAREN

    badconstownedpayload
                    <- &(CONST MUL (CONST MUL / MUL)* !cownedbasehead)
                       %{COwnedShape}

    ownedtail       <- (P  MUL cownedpayload^OwnedPayload
                           ((LBRACKET RBRACKET^RBracketCOwned    -> totrue)
                            / (''                               -> tofalse)))
                                                               -> owned_pointer_tail
                     / badconstownedpayload
                     / (cownedpayload LBRACKET
                           RBRACKET^RBracketCOwned)              -> owned_array_tail
                     / %{COwnedShape}

    constarray      <- (P  CONST OPT LCURLY
                           type^TypeConstArray
                           (!COLON / %{ConstMap})
                           RCURLY^RCurlyType)                    -> maybeconstarraytype
                     / (P  CONST LCURLY
                           type^TypeConstArray
                           (!COLON / %{ConstMap})
                           RCURLY^RCurlyType)                    -> constarraytype

    -- Prefix constructors consume only this grouped payload, leaving a
    -- following arrow outside the pointer/owner. General type operands parse
    -- their parenthesized list once through `typelist` below.
    groupedtype     <- LPAREN type^LParenType RPAREN^RParenTypelist

    simpletype      <- ((((P  NIL)                               -> TypeNil
                     / (P  BOOLEAN)                              -> TypeBoolean
                     / (P  INTEGER)                              -> TypeInteger
                     / (P  FLOAT)                                -> TypeFloat
                     / (P  STRING)                               -> TypeString
                     / (P  VALUE)                                -> TypeValue
                     / ownedtype
                     / constarray
                     / (P  CONST MUL simpletype^TypeType)        -> constcptrtype
                     / (P  MUL simpletype^TypeType)              -> cptrtype
                     / surfacecompoundtype
                     / namedtype
                     / groupedtype
                     / (P  LCURLY type^TypeType
                           ((COLON type^TypeType
                                   RCURLY^RCurlyType)            -> map_type_tail
                            / RCURLY^RCurlyType                  -> array_type_tail))
                                                               -> finish_curly_type)
                                                  (OPT -> '?')?) -> typeopt)
                        (!LBRACKET / %{CArrayOnlyAutomatic})

    -- A trailing, last-only `...: t` in a function-type arg list. The element
    -- type is mandatory (the `: t` declaration style). Produces the element type
    -- node; `varargtypeopt` defaults to `false` when absent. Only consumed in the
    -- arrow (function-type) productions below, never in a bare `typelist` used as
    -- a return-type list.
    varargtypeann   <- (P  DOTS COLON^VarargColon type^TypeDecl) -> varargtype

    varargtypeopt   <- (COMMA varargtypeann)?  -> opt

    -- The fixed-type loop stops before a `, ...` so the optional trailing
    -- vararg (`varargtypeopt`) consumes that comma itself.
    typelist         <- ( LPAREN
                         (
                            (RPAREN) -> empty_typelist /
                            (varargtypeann RPAREN^RParenTypelist) -> single_vararg_typelist / 
                            (type^LParenType (
                                (RPAREN (OPT -> '?')) /
                                (RPAREN) /
                                ({| (COMMA !DOTS type^TypelistType)* |} varargtypeopt RPAREN^RParenTypelist)
                              )
                            ) -> other_typelist
                         )
                        )
        -- produces {Type}, varargtypeopt
        
    -- A flexible return tail is legal only as the final item of a parenthesized
    -- return list. Its labels deliberately do not reuse the input-vararg
    -- diagnostic, which calls the construct a variadic parameter.
    flexrettypeann  <- (P  DOTS COLON^FlexRetColon type^FlexRetType
                           (!COMMA / %{FlexRetLast}))             -> flexrettype

    -- A fixed prefix requires the separating comma; the comma-less form is
    -- reserved for a flex-only result list. Keeping these productions
    -- separate prevents `(integer ...: string)` from being accepted by the
    -- otherwise convenient optional-tail rule.
    flexrettypeafterfixed <- ((COMMA flexrettypeann)?) -> opt
    flexrettypeonlyopt    <- (flexrettypeann?)         -> opt

    resulttypelist  <- ({:result_shape: (( LPAREN
                         ( {| type (COMMA !DOTS type^TypelistType)* |}
                           flexrettypeafterfixed
                         / {| '' |} flexrettypeonlyopt )
                         RPAREN^RParenTypelist )                 -> returnshape)
                                                               => type_capture :}
                       ((OPT ((%RESULT_SHAPE => optional_returnshape)
                              / %{OptionTypeList}))
                        / %RESULT_SHAPE))                       => type_capture

    -- Function arrows form a flat operand chain which is folded from the
    -- right: `a -> b -> c` is `a -> (b -> c)`. In particular, matching an
    -- arrow commits to matching its following return operand instead of
    -- recursively retrying every prefix as a complete type.
    typefirstoperand
                    <- (P  FOREIGN !FLOAT typelist^ForeignFunctionNoTypes (&RARROW)^ForeignFunctionNoRet) -> foreign_type_operand
                     / (P  typelist)                -> argument_type_operand
                     / (simpletype                               -> simple_type_operand)

    rettypeoperand  <- (DOTS %{FlexRetParens})
                     / (P  FOREIGN !FLOAT typelist^ForeignFunctionNoTypes (&RARROW)^ForeignFunctionNoRet) -> foreign_type_operand
                     / (P  resulttypelist)                       -> result_type_operand
                     / (simpletype                               -> simple_type_operand)

    arrowrettypeoperand
                    <- RARROW rettypeoperand^TypeReturnTypes

    rettype         <- {| rettypeoperand arrowrettypeoperand* |}
                                                               => fold_rettype_operands

    type            <- ({:type_operands:
                           {| typefirstoperand arrowrettypeoperand* |}
                                                               => type_capture :}
                       ((%TYPE_OPERANDS => fold_type_operands)
                        / %{TypeFunctionNoRet}))                 => type_capture

    recordfields    <- {| recordfield* |}                        -- produces {Decl}

    recordfield     <- (P  LOCAL CONST P NAME OPT COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> localconstoptionrecordfielddecl
                     / (P  LOCAL CONST P NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> localconstrecordfielddecl
                     / (P  CONST P NAME OPT COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> constoptionrecordfielddecl
                     / (P  CONST P NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> constrecordfielddecl
                     / (P  LOCAL P NAME OPT COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> localoptionrecordfielddecl
                     / (P  LOCAL P NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> localrecordfielddecl
                     / (P  P NAME OPT COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> optionrecordfielddecl
                     / (P  P NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> recordfielddecl

    unionvariants   <- {| unionvariant^VariantUnion unionvariant* |}

    unionvariant    <- (P  LOCAL P NAME^NameUnionVariant
                           unionpayloadopt SEMICOLON?)           -> localunionvariantdecl
                     / (P  NAME unionpayloadopt SEMICOLON?)      -> unionvariantdecl

    unionpayloadopt <- ((COLON type^TypeUnionVariant)?)          -> opt

    -- A `block` may optionally absorb `(catch <block>)?` trailer.
    -- When present `trywrap` builds a `StatTry` wrapper; otherwise it returns
    -- the plain `StatBlock`.
    block           <- (P  simpleblock
                            ((CATCH simpleblock^CatchBlock)? -> opt)) -> trywrap

    simpleblock     <- (P  {| statement* returnstat? |})         -> simpleblock

    statement       <- (SEMICOLON)                               -- ignore
                     / (P  (LOCAL? INTERFACE) %{NestedInterface})
                     / (P  BREAK)                                -> StatBreak
                     / (P  RAISE (exp? -> opt))                  -> StatRaise
                     / deferstat
                     / doblock                                   -- produces StatBlock/StatTry
                     / (P  WHILE exp^ExpWhile DO^DoWhile
                                 block P END^EndWhile)           -> whilestat
                     / (P  REPEAT block P UNTIL^UntilRepeat
                                      exp^ExpRepeat)             -> repeatstat
                     / (P  IF exp^ExpIf THEN^ThenIf block
                           elseifstats elseopt P END^EndIf)      -> ifstat
                     / casestat
                     / forstat
                     / (P  (LOCAL? CONST) localdecllist^DeclLocal
                                 ASSIGN^AssignLocal
                                 explist^ExpLocal)                 -> constlocalvardecl
                     / (P  LOCAL localdecllist^DeclLocal
                                 ((ASSIGN explist^ExpLocal)? -> listopt))
                                                                  -> StatDecl
                     / (P  assignmentorcall)                    -> finish_assignment_or_call
                     / &(exp ASSIGN) %{AssignNotLValue}
	                     / &exp %{ExpStat}

    assignmentorcall
                    <- {:statement_candidate: statementcandidate :}
                       ((((%STATEMENT_CANDIDATE => statement_candidate_var)
                           (statementassignmenttail / %{AssignAssign}))
                                            -> statement_assignment_candidate)
                        / (((%STATEMENT_CANDIDATE => statement_candidate_call)
                             !(ASSIGN / expressioncontinuation))
                                            -> statement_call_candidate))

    statementcandidate
                    <- (((P NAME) -> statement_name_prefix
                         / (P LPAREN parenexp
                               RPAREN^RParSimpleExp)
                                             -> statement_parenthesized_prefix)
                        {| expsuffix* |}) -> fold_statement_candidate

    statementassignmenttail
                    <- ({| (COMMA var^ExpVarList)* |}
                         ASSIGN^AssignAssign explist^ExpAssign)
                                            -> statement_assignment_tail

    deferstat       <- (P  DEFER (!DEFER / %{DeferDefer})
                              (!SEMICOLON / %{DeferStatement})
                              statement^DeferStatement)          -> deferstat

	    forstat         <- (P  FOR decl^DeclFor forrest)          -> forstat

	    forrest         <- (P  IN explist^ExpForIn
	                            DO^DoForIn block P END^EndForIn) -> forin_rest0
	                     / (P  forindecls IN^InFor
	                             explist^ExpForIn
	                             DO^DoForIn block P END^EndForIn) -> forin_rest
	                     / (P  ASSIGN^AssignFor exp^Exp1For
	                             COMMA^CommaFor exp^Exp2For
	                             (COMMA exp^Exp3For)?             -> opt
	                             DO^DoFor block P END^EndFor)     -> fornum_rest
	                     / %{AssignFor}

	    forindecls      <- {| COMMA decl^DeclParList
	                           (COMMA decl^DeclParList)* |}       -- produces {Decl}

	    elseifstats     <- {| elseifstat* |}                         -- produces {Then}

    elseifstat      <- (P  ELSEIF exp^ExpElseIf
                           THEN^ThenElseIf block)                -> Then

    elseopt         <- (ELSE block)?                             -> opt

    casestat        <- (P  CASE exp^ExpCase
                           casearms^WhenCase
                           elseopt P END^EndCase)                -> casestat

    casearms        <- {| casearm^WhenCase casearm* |}

    casearm         <- (P  WHEN P NAME^NameCaseVariant
                           casebindingopt
                           THEN^ThenCase block)                  -> casearm

    casebindingopt  <- (((COLON P NAME^NameCaseBinding)
                                                        -> casebinding)?) -> opt

    returnstat      <- (P  RETURN (explist? -> listopt) SEMICOLON?)      -> StatReturn

    doblock         <- (P DO block P END^EndBlock) -> doblock    -- produces StatBlock/StatTry

    op1             <- ( OR -> 'or' )
    op2             <- ( AND -> 'and' )
    op3             <- ( EQ -> '==' / NE -> '~=' / LT -> '<' /
                         GT -> '>'  / LE -> '<=' / GE -> '>=' )
    op4             <- ( BOR -> '|' )
    op5             <- ( BXOR -> '~' )
    op6             <- ( BAND -> '&' )
    op7             <- ( SHL -> '<<' / SHR -> '>>' )
    op8             <- CONCAT
    op9             <- ( ADD -> '+' / SUB -> '-' )
    op10            <- ( MUL -> '*' / MOD -> '%%' / DIV -> '/' / IDIV -> '//' )
    -- `#...` is an explicit variadic expression, not a generic unary operator
    -- applied to a generally available bare `...` expression. Leave the final
    -- `#` for the dedicated simple-expression branch below; outer unary
    -- operators (for example `-#...` or `##...`) still fold normally.
    unop            <- ( NOT -> 'not' / (LEN !(DOTS !LBRACKET)) -> '#'
                         / NEG -> '-' / BNEG -> '~' )
    op12            <- ( POW -> '^' )

    -- A captured call is not yet a complete statement when a syntactically
    -- viable binary, cast, or type-test tail leads to an assignment. Let the
    -- diagnostic fallback parse that full expression so `f() + x = y`
    -- remains AssignNotLValue. The first lookahead is a bounded token check on
    -- valid calls; only this invalid-assignment path runs the quiet tail probe.
    expressionoperator
                    <- op1 / op2 / op3 / op4 / op5 / op6 / op7
                     / op8 / op9 / op10 / op12

    expressioncontinuation
                    <- &(expressionoperator / AS / IS)
                       &((op12 e11)?
                         (AS type / IS type)*
                         (op10 e11)* (op9 e10)* (op8 e9)*
                         (op7 e8)* (op6 e7)* (op5 e6)* (op4 e5)*
                         (op3 e4)* (op2 e3)* (op1 e2)*
                         !(expressionoperator / AS / IS)
                         ASSIGN)

    exp             <- e1
    e1              <- (P  {| e2  (op1  e2^OpExp)* |})           -> fold_binop_left
    e2              <- (P  {| e3  (op2  e3^OpExp)* |})           -> fold_binop_left
    e3              <- (P  {| e4  (op3  e4^OpExp)* |})           -> fold_binop_left
    e4              <- (P  {| e5  (op4  e5^OpExp)* |})           -> fold_binop_left
    e5              <- (P  {| e6  (op5  e6^OpExp)* |})           -> fold_binop_left
    e6              <- (P  {| e7  (op6  e7^OpExp)* |})           -> fold_binop_left
    e7              <- (P  {| e8  (op7  e8^OpExp)* |})           -> fold_binop_left
    e8              <- ({| P e9 (op8 P e9^OpExp)* |})
                                               => fold_binop_concat_right
    e9              <- (P  {| e10 (op9  e10^OpExp)* |})          -> fold_binop_left
    e10             <- (P  {| e11 (op10 e11^OpExp)* |})          -> fold_binop_left
    e11             <- castexp
    unopexp         <- (P  {| unop* |}  e12)                     -> fold_unops
    -- Power is right-associative, but its right operand admits unary prefixes
    -- and cast/type-test suffixes. Parse the whole operator chain once, then
    -- fold from the right. Once `^` is consumed the labeled operand commits,
    -- so a missing operand remains an `OpExp` error at the same boundary.
    poweroperand    <- (P {| unop* |} P simpleexp)               -> power_operand
    powertail       <- (op12 poweroperand^OpExp)                 -> power_tail
    casttesttail    <- (AS type^CastMissingType)                 -> cast_type_tail
                     / (IS type^IsMissingType)                   -> test_type_tail
    e12             <- (P simpleexp
                           ({| powertail+ |}
                            {| casttesttail* |})?)               => fold_power

    suffixedexp     <- (prefixexp {| expsuffix+ |})              -> fold_suffixes

    prefixorsuffixedexp
                    <- (prefixexp {| expsuffix* |})              -> fold_suffixes

    -- Parentheses and bare strings are positional call suffixes. Bare braces
    -- are always named calls; passing one constructor positionally therefore
    -- requires parentheses (`f({ ... })`). An angle list is claimed only when
    -- a complete type-argument list is followed by an existing call delimiter
    -- or by the dot of an aggregate-owner selection; otherwise `<` remains an
    -- ordinary comparison operator. Successful lists are deliberately parsed
    -- once in this noncommitting lookahead and once for their AST captures.
    genericcalltypeargprobe
                    <- %GENERIC_CALL_START
                       LT type (COMMA type)* GENERICGT

    genericcalltypeargs
                    <- &(genericcalltypeargprobe
                         (LPAREN / STRINGLIT / LCURLY))
                       typearglist

    genericsuffixtypeargs
                    <- &(genericcalltypeargprobe
                         (DOT / LPAREN / STRINGLIT / LCURLY))
                       typearglist

    -- Choose positional versus named arguments only after the optional generic
    -- prefix has been decided. The trailing boolean is a parser-only capture;
    -- the AST keeps its existing Args* tags and fields.
    callargs        <- funcargs ('' -> tofalse)
                     / namedargs ('' -> totrue)

    -- Consume the aggregate member selector in the same factored branch as a
    -- generic call, so `Owner<T>.member` does not add a second full type-list
    -- probe ahead of every ordinary expression suffix.
    nominalmemberselector
                    <- (&DOT P DOT P membername^NameDotExpSuf)
                                                               -> nominal_member_selector

    callexpsuffix   <- genericsuffixtypeargs
                         (nominalmemberselector / callargs)
                     / (callargs -> ordinary_call)

    -- A method name is parsed exactly once. If no complete call tail follows,
    -- the empty branch preserves the existing bound-method-reference syntax.
    methodtail      <- ((genericcalltypeargs? -> listopt) callargs)
                     / ('' -> method_reference_tail)

    -- Factor the common bracket body before choosing index versus subset.
    -- In particular, `[exp]` must not first parse `exp` speculatively as the
    -- prefix of `[exp, ...]`: nested indexes would otherwise double the work
    -- at every level.
    bracketbody     <- (P  LBRACKET COMMA
                                exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf)         -> bracket_subset_to_desc
                     / (P  LBRACKET exp^ExpExpSuf
                                ((COMMA (exp? -> opt)
                                  RBRACKET^RBracketExpSuf)       -> bracket_subset_tail
                                 / (RBRACKET^RBracketExpSuf
                                    ('' -> tofalse))))          -> bracket_from_first_desc

    expsuffix       <- (P  callexpsuffix)                        -> suffix_anyfunccall
                     / (P  COLON P NAME^NameColonExpSuf
                                 methodtail)                     -> suffix_anymethod
                     / bracketbody                              -> suffix_bracket_desc
                     / (P  DOT P membername^NameDotExpSuf)       -> suffix_dot

    -- Bare `...` is not a general expression. Parentheses are one of the
    -- explicit scalar forms, so recognize exactly `(...)` here; the lookahead
    -- keeps `(...[index])` on the ordinary-expression branch.
    parenexp        <- (((P DOTS) -> ExpDots) &RPAREN)
                     / exp^ExpSimpleExp

    prefixexp       <- (surfacecompoundtype)                    -> surface_c_type_exp
                     / (P  NAME)                                 -> name_exp
                     / (P  LPAREN parenexp
                               RPAREN^RParSimpleExp)             -> adjust_exp


    castexp         <- (P  unopexp
                           {| casttesttail* |})
                                               => finish_casts_and_tests

    simpleexp       <- (P  NIL)                                  -> nil_exp
                     / (P  FALSE -> tofalse)                     -> ExpBool
                     / (P  TRUE -> totrue)                       -> ExpBool
                     / (P  NUMBER)                               -> number_exp
                     / (P  STRINGLIT)                            -> ExpString
                     / initlist                                  -- produces Exp
                     / funcexp                                   -- produces Exp
                     / prefixorsuffixedexp                       -- produces Exp
                     / (P  LEN DOTS !LBRACKET)                   -> dots_len_exp
                     / (P  DOTS bracketbody)                     -> dots_bracket_exp

    var             <- (suffixedexp => exp_is_var)               -> exp2var
                     / (P  NAME !expsuffix)                      -> name_exp -> exp2var

    funcargs        <- (LPAREN (explist? -> listopt) RPAREN^RParFuncArgs)      -- produces {Exp}
                     / {| (P  STRINGLIT) -> ExpString |}         -- produces {Exp}

    -- Named calls accept only `identifier = expression` fields. NAMEDLABEL is
    -- deliberately keyword-inclusive, but is reachable only before `=` in
    -- this production. The !RCURLY guards preserve empty lists and trailing
    -- separators without weakening errors for positional/computed items.
    namedargs       <- (LCURLY
                         {| (!RCURLY namedarglist^NameNamedArg)? |}
                         RCURLY^RCurlyNamedArgs)                 -- produces {Field}

    namedarglist    <- (namedarg
                        (fieldsep
                         (!RCURLY &. namedarg^NameNamedArg))*
                        fieldsep?)                              -- produces Field...

    namedarg        <- (P  NAMEDLABEL
                           ASSIGN^AssignNamedArg
                           exp^ExpNamedArg)                     -> makefield

    -- A collection spread begins with `...` followed by a subject expression.
    -- A leading bracket belongs to the explicitly delimited vararg index/slice
    -- grammar. This production is reached only after a DOTS-started ordinary
    -- expression has failed, so it never probes a valid scalar expression
    -- twice. The subject may itself be an explicit DOTS-started scalar such as
    -- `...[index]`; a second bare `...` still cannot satisfy `exp`.
    spreadexp       <- (P  DOTS !LBRACKET exp)                  -> spread_exp

    -- Parse each written item once, then classify it from the following comma.
    -- A fixed-position classifier rejects only bare `...`; explicit collection
    -- spreads and direct `...[subset]` forms remain in the AST so the checker
    -- can diagnose their non-tail placement. A direct `...[subset]` is
    -- promoted to a spread only by the tail classifier. `...[index]` remains
    -- scalar in either position.
    --
    -- The bounded repetition captures at most LIST_LIMIT+1 items. The
    -- post-capture check accepts LIST_LIMIT ordinary written expressions, or
    -- one additional item only when it is the final-role open producer. This
    -- preserves the historical extra trailing open marker without reparsing
    -- any item and lets labeled failures inside expressions propagate.
    rawexplistitem  <- ((P &DOTS exp) => claim_dots_started_item)
                     / spreadexp
                     / ((P  DOTS !LBRACKET) -> ExpDots)
                     / exp

    explistitemrole <- ((&COMMA
                          (%EXPLIST_ITEM => fixed_explist_item))
                        / (!COMMA
                          (%EXPLIST_ITEM => tail_explist_item)))

    explistitem     <- {:explist_item: rawexplistitem :}
                       explistitemrole

    -- Once a comma has been consumed, failure to parse the next raw item owns
    -- the established ExpExpList diagnostic. A successfully parsed but
    -- role-invalid bare `...` still fails through the surrounding delimiter,
    -- rather than being relabeled as a missing expression.
    explistnextitem <- {:explist_item:
                           rawexplistitem^ExpExpList
                       :}
                       explistitemrole

    explist         <- {:explist_items:
                           {| explistitem
                                (COMMA explistnextitem)^-100 |}
                       :}
                       ((%EXPLIST_ITEMS => check_explist_limit)
                        / %{ListTooLong})                       -- produces {Exp}

    initlist        <- (P  LCURLY {| fieldlist? |}
                                  RCURLY^RCurlyInitList)         -> ExpInitList

    fieldlist       <- (fielditem
                        (fieldsep
                         (fielditem /
                          !RCURLY %{ExpFieldList}))*
                        fieldsep?)                          -- produces Field...

    rawfield        <- ((P &DOTS exp) => claim_dots_started_field)
                     / ((P spreadexp) -> spread_field)
                     / ((P  DOTS !LBRACKET) -> dots_field)
                     / (P  !DOTS
                           (key ASSIGN)? -> opt exp)             -> makefield

    fielditem       <- {:field_item: rawfield :}
                       ((&(fieldsep !RCURLY)
                          (%FIELD_ITEM => fixed_field_item))
                        / (!(fieldsep !RCURLY)
                          (%FIELD_ITEM => tail_field_item)))

    key             <- NAME
                     / LBRACKET exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf

    fieldsep        <- SEMICOLON / COMMA

    --
    -- Get current position
    --

    P <- {} => get_loc

    -- Create new rules for all our tokens, for the whitespace-skipping magic
    -- Currently done by hand but this is something that parser-gen should be
    -- able to do for us.

    SKIP            <- (%SPACE / %COMMENT)

    AND             <- %AND SKIP*
    BREAK           <- %BREAK SKIP*
    CASE            <- %CASE SKIP*
    CBOOL           <- %CBOOL SKIP*
    CCHAR           <- %CCHAR SKIP*
    CDOUBLE         <- %CDOUBLE SKIP*
    CINT            <- %CINT SKIP*
    CLONG           <- %CLONG SKIP*
    CSHORT          <- %CSHORT SKIP*
    CSIGNED         <- %CSIGNED SKIP*
    CUNSIGNED       <- %CUNSIGNED SKIP*
    CVOID           <- %CVOID SKIP*
    DEFER           <- %DEFER SKIP*
    DO              <- %DO SKIP*
    ELSE            <- %ELSE SKIP*
    ELSEIF          <- %ELSEIF SKIP*
    END             <- %END SKIP*
    FALSE           <- %FALSE SKIP*
    FOR             <- %FOR SKIP*
    FUNCTION        <- %FUNCTION SKIP*
    GOTO            <- %GOTO SKIP*
    IF              <- %IF SKIP*
    IN              <- %IN SKIP*
    INTERFACE       <- %INTERFACE SKIP*
    LOCAL           <- %LOCAL SKIP*
    NIL             <- %NIL SKIP*
    NOT             <- %NOT SKIP*
    OR              <- %OR SKIP*
    RECORD          <- %RECORD SKIP*
    REPEAT          <- %REPEAT SKIP*
    RETURN          <- %RETURN SKIP*
    THEN            <- %THEN SKIP*
    TYPE            <- %TYPE SKIP*
    TRUE            <- %TRUE SKIP*
    UNTIL           <- %UNTIL SKIP*
    WHILE           <- %WHILE SKIP*
    IMPORT          <- %IMPORT SKIP*
    AS              <- %AS SKIP*
    IS              <- %IS SKIP*
    FOREIGN         <- %FOREIGN SKIP*
    CATCH           <- %CATCH SKIP*
    FINALLY         <- %FINALLY SKIP*
    RAISE           <- %RAISE SKIP*
    CONST           <- %CONST SKIP*
    OWNED           <- %OWNED SKIP*
    UNION           <- %UNION SKIP*
    WHEN            <- %WHEN SKIP*

    BOOLEAN         <- %BOOLEAN SKIP*
    INTEGER         <- %INTEGER SKIP*
    FLOAT           <- %FLOAT SKIP*
    STRING          <- %STRING SKIP*
    VALUE           <- %VALUE SKIP*

    -- Generic lists close contextually one byte at a time. Keep %GT and
    -- %SHR unchanged for ordinary expressions and lexer consumers.
    GENERICGT       <- '>' SKIP*

    ADD             <- %ADD SKIP*
    SUB             <- %SUB SKIP*
    MUL             <- %MUL SKIP*
    MOD             <- %MOD SKIP*
    DIV             <- %DIV SKIP*
    IDIV            <- %IDIV SKIP*
    POW             <- %POW SKIP*
    LEN             <- %LEN SKIP*
    BAND            <- %BAND SKIP*
    BXOR            <- %BXOR SKIP*
    BOR             <- %BOR SKIP*
    SHL             <- %SHL SKIP*
    SHR             <- %SHR SKIP*
    CONCAT          <- %CONCAT SKIP*
    EQ              <- %EQ SKIP*
    LT              <- %LT SKIP*
    GT              <- %GT SKIP*
    NE              <- %NE SKIP*
    LE              <- %LE SKIP*
    GE              <- %GE SKIP*
    ASSIGN          <- %ASSIGN SKIP*
    LPAREN          <- %LPAREN SKIP*
    RPAREN          <- %RPAREN SKIP*
    LBRACKET        <- %LBRACKET SKIP*
    RBRACKET        <- %RBRACKET SKIP*
    LCURLY          <- %LCURLY SKIP*
    RCURLY          <- %RCURLY SKIP*
    SEMICOLON       <- %SEMICOLON SKIP*
    COMMA           <- %COMMA SKIP*
    DOT             <- %DOT SKIP*
    DOTS            <- %DOTS SKIP*
    DBLCOLON        <- %DBLCOLON SKIP*
    COLON           <- %COLON SKIP*
    RARROW          <- %RARROW SKIP*
    OPT             <- %OPT SKIP*

    NUMBER          <- %NUMBER SKIP*
    STRINGLIT       <- %STRINGLIT SKIP*
    NAME            <- %NAME SKIP*
    CNAME           <- %CNAME SKIP*
    NAMEDLABEL      <- %NAMEDLABEL SKIP*

    -- Synonyms

    NEG             <- SUB
    BNEG            <- BXOR

]], defs)

function parser.parse(filename, input)
    -- Abort if someone calls this non-reentrant parser recursively
    assert(type(filename) == "string")
    assert(THIS_FILENAME == nil)

    local generic_call_candidates = collect_generic_call_candidates(input)
    THIS_FILENAME = filename
    PROGRAM_NODES = {}
    SOURCE_LOCATIONS = {}
    GENERIC_CALL_CANDIDATES = generic_call_candidates
    local ok, ast, err, errpos = pcall(function()
        return grammar:match(input)
    end)
    GENERIC_CALL_CANDIDATES = nil
    SOURCE_LOCATIONS = nil
    PROGRAM_NODES = nil
    THIS_FILENAME = nil

    if not ok then
        error(ast, 0)
    end

    if ast then
        return ast
    else
        local loc = location.from_pos(filename, input, errpos)
        return false, { label = err, loc = loc }
    end
end

function parser.error_to_string(err)
    local errmsg = syntax_errors.errors[err.label]
    return location.format_error(err.loc, "syntax error: %s", errmsg)
end

function parser.pretty_print_ast(ast)
    return inspect(ast, {
        process = function(item, path)
            if path[#path] ~= inspect.METATABLE then
                return item
            end
        end
    })
end

return parser
