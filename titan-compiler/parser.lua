local parser = {}

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

-- Parse-time guardrail on the length of parameter/expression lists (not a
-- runtime bound; runtime vararg counts have their own cap, TITAN_VARARG_MAX).
local LIST_LIMIT = 100

--
-- Functions used by the PEG grammar
--

local defs = {}

for tokname, tokpat in pairs(lexer) do
    defs[tokname] = tokpat
end

for tag, cons in pairs(ast) do
    defs[tag] = cons
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
}

function defs.importdecl(loc, localname, modname)
    return ast.TopLevelImport(
        loc, localname, standard_imports[modname] or modname)
end

function defs.get_loc(s, pos)
    return true, location.from_pos(THIS_FILENAME, s, pos)
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

function defs.nil_exp(pos--[[, s ]])
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
    return ast.ExpVar(pos, ast.VarName(pos, name))
end

function defs.adjust_exp(pos, exp)
    if exp._tag == "Ast.ExpCall" then
        return ast.ExpAdjust(pos, exp)
    else
        return exp
    end
end

-- A `block` with optional `(catch …)? (finally …)?` trailers. When neither is
-- present the block is the plain `StatBlock` (the common case, so no wrapper
-- node is introduced); when either is present we wrap it in a `StatTry` whose
-- `catchblock`/`finallyblock` are the clause bodies (false when absent).
function defs.trywrap(pos, block, catchblock, finallyblock)
    if not catchblock and not finallyblock then
        return block
    end
    return ast.StatTry(pos, block, catchblock, finallyblock)
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
-- plain StatBlock or the StatTry produced when its block has catch/finally
-- trailers. Its diagnostic location is the `do` keyword rather than the first
-- token in the block, so filesystem assembly can reject the construct in a
-- contributor without guessing from the statement tag.
function defs.moduleinit(pos, block)
    block.loc = pos
    block._module_initializer = true
    return block
end

function defs.cptrtype(pos, subtype)
    return ast.TypeCPointer(pos, subtype, false)
end

function defs.constcptrtype(pos, subtype)
    return ast.TypeCPointer(pos, subtype, true)
end

function defs.cownedscalartype(pos, subtype)
    return ast.TypeCOwned(pos, subtype, false)
end

function defs.cownedarraytype(pos, subtype)
    return ast.TypeCOwned(pos, subtype, true)
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

function defs.automaticlocal(pos, decl)
    return ast.StatDecl(pos, { decl }, {})
end

function defs.ifstat(pos, exp, block, thens, elseopt)
    table.insert(thens, 1, ast.Then(pos, exp, block))
    return ast.StatIf(pos, thens, elseopt)
end

function defs.fornum_rest(_, start, finish, inc, block)
    return function(pos, decl)
        return ast.StatFor(pos, decl, start, finish, inc, block)
    end
end

function defs.forin_rest(_, decls, exps, block)
    return function(pos, decl)
        table.insert(decls, 1, decl)
        return ast.StatForIn(pos, decls, exps, block)
    end
end

function defs.forin_rest0(_, exps, block)
    return function(pos, decl)
        return ast.StatForIn(pos, { decl }, exps, block)
    end
end

function defs.forstat(pos, decl, rest)
    return rest(pos, decl)
end

function defs.fold_binop_left(pos, matches)
    local lhs = matches[1]
    for i = 2, #matches, 2 do
        local op  = matches[i]
        local rhs = matches[i+1]
        lhs = ast.ExpBinop(pos, lhs, op, rhs)
    end
    return lhs
end

-- Should this go on a separate constant propagation pass?
function defs.binop_concat(pos, lhs, op, rhs)
    if op then
        if rhs._tag == "Ast.ExpConcat" then
            table.insert(rhs.exps, 1, lhs)
            return rhs
        elseif (lhs._tag == "Ast.ExpString" or
            lhs._tag == "Ast.ExpInteger" or
            lhs._tag == "Ast.ExpFloat") and
            (rhs._tag == "Ast.ExpString" or
            rhs._tag == "Ast.ExpInteger" or
            rhs._tag == "Ast.ExpFloat") then
            return ast.ExpString(pos, lhs.value .. rhs.value)
        else
            return ast.ExpConcat(pos, { lhs, rhs })
        end
    else
        return lhs
    end
end

function defs.binop_right(pos, lhs, op, rhs)
    if op then
        return ast.ExpBinop(pos, lhs, op, rhs)
    else
        return lhs
    end
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

function defs.suffix_funccall(pos, args)
    return function(exp)
        return ast.ExpCall(pos, exp, ast.ArgsFunc(pos, args))
    end
end

function defs.suffix_namedfunccall(pos, fields)
    return function(exp)
        return ast.ExpCall(pos, exp, ast.ArgsNamedFunc(pos, fields))
    end
end

function defs.suffix_methodcall(pos, name, args)
    return function(exp)
        return ast.ExpCall(pos, exp, ast.ArgsMethod(pos, name, args))
    end
end

function defs.suffix_namedmethodcall(pos, name, fields)
    return function(exp)
        return ast.ExpCall(pos, exp,
            ast.ArgsNamedMethod(pos, name, fields))
    end
end

-- `obj:m` with no argument list is a bound-method reference: it evaluates to a
-- function value (the method with `self` captured), not a call. Tried after the
-- method-call form, so a real call (`obj:m(args)`) still parses as a call.
function defs.suffix_methodref(pos, name)
    return function(exp)
        return ast.ExpMethodRef(pos, exp, name)
    end
end

function defs.suffix_bracket(pos, index)
    return function(exp)
        return ast.ExpVar(pos, ast.VarBracket(pos, exp, index))
    end
end

local function unpack_membername(member)
    if type(member) == "table" then
        return member.name, true
    end
    return member, false
end

function defs.contextual_c_name(name)
    return { name = name }
end

function defs.suffix_dot(pos, member)
    return function(exp)
        local name, contextual = unpack_membername(member)
        local var = ast.VarDot(pos, exp, name)
        if contextual then
            var._contextual_c_name = true
        end
        return ast.ExpVar(pos, var)
    end
end

function defs.qualifiedtype(pos, module, member)
    local name, contextual = unpack_membername(member)
    local node = ast.TypeQualName(pos, module, name)
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

function defs.exp_is_call(_, pos, exp)
    if exp._tag == "Ast.ExpCall" then
        return pos, exp
    else
        return false
    end
end

function defs.methoddecl(pos, islocal, class, name, params, rettypes,
                         flexrettype, block)
    local node = ast.TopLevelMethod(pos, class, name, params, rettypes,
        flexrettype, block)
    node.islocal = islocal
    return node
end

function defs.staticdecl(pos, islocal, class, name, params, rettypes,
                         flexrettype, block)
    local node = ast.TopLevelStatic(pos, class, name, params, rettypes,
        flexrettype, block)
    node.islocal = islocal
    return node
end

local function has_local_field(fields)
    for _, field in ipairs(fields) do
        if field.islocal then return true end
    end
    return false
end

function defs.recorddecl(pos, islocal, name, fields)
    local params, initlist = {}, {}
    for _, field in ipairs(fields) do
        table.insert(params, ast.Decl(field.loc, field.name, field.type, false))
        table.insert(initlist, ast.Field(field.loc, field.name,
            ast.ExpVar(field.loc, ast.VarName(field.loc, field.name))))
    end
    local body = ast.StatBlock(pos, {
        ast.StatReturn(pos, {
            ast.ExpInitList(pos, initlist)
        })
    })
    local record = ast.TopLevelRecord(pos, name, fields)
    record.islocal = islocal
    local new = ast.TopLevelStatic(pos, name, "new", params,
        { ast.TypeName(pos, name) }, false, body)
    new.islocal = islocal or has_local_field(fields)
    new._record_constructor = true
    return record, new
end

function defs.unionvariantdecl(pos, name, payload)
    return ast.UnionVariant(pos, name, payload)
end

function defs.localunionvariantdecl(pos, name, payload)
    local variant = ast.UnionVariant(pos, name, payload)
    variant.islocal = true
    return variant
end

function defs.uniondecl(pos, islocal, name, variants)
    local union = ast.TopLevelUnion(pos, name, variants)
    union.islocal = islocal

    local nodes = { union }
    for _, variant in ipairs(variants) do
        local params = {}
        local value = false
        if variant.payload then
            local param = ast.Decl(
                variant.loc, "__union_payload", variant.payload, false)
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
            { ast.TypeName(pos, name) },
            false,
            body)
        constructor.islocal = islocal or variant.islocal or false
        constructor._union_constructor = true
        constructor._union_variant = variant
        nodes[#nodes + 1] = constructor
    end

    return table.unpack(nodes)
end

function defs.recordfielddecl(pos, name, type)
    local decl = ast.Decl(pos, name, type, false)
    return decl
end

function defs.localrecordfielddecl(pos, name, type)
    local decl = ast.Decl(pos, name, type, false)
    decl.islocal = true
    return decl
end

function defs.optionrecordfielddecl(pos, name, type)
    return ast.Decl(pos, name, ast.TypeOption(type.loc, type), false)
end

function defs.localoptionrecordfielddecl(pos, name, type)
    local decl = defs.optionrecordfielddecl(pos, name, type)
    decl.islocal = true
    return decl
end

function defs.typeddecl(pos, name, type)
    return ast.Decl(pos, name, type, false)
end

function defs.optiondecl(pos, name, type)
    if type then
        return ast.Decl(pos, name, ast.TypeOption(type.loc, type), false)
    else
        return ast.Decl(pos, name, false, true)
    end
end

function defs.inferreddecl(pos, name)
    return ast.Decl(pos, name, false, false)
end

function defs.casebinding(pos, name)
    return ast.Decl(pos, name, false, false)
end

-- A variadic parameter `...: t` (or, for lambdas only, an untyped `...`):
-- encoded as a trailing Decl whose name is `false`. A typed vararg carries its
-- element type; an untyped lambda vararg has `type == false`, mirroring the
-- inferred-parameter encoding (name set / type false) but inverted (name false /
-- type false). Detect a variadic function with `params[#params].name == false`.
-- The `type` capture is absent (nil) for the untyped lambda form; normalise it
-- to `false`.
function defs.varargdecl(pos, type)
    return ast.Decl(pos, false, type or false, false)
end

-- A trailing `...` field in an array constructor: `{ a, ... }`. Encoded as a
-- key-less Field whose expression is a bare `ExpDots`.
function defs.dots_field(pos)
    return ast.Field(pos, false, ast.ExpDots(pos))
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

-- A function type appearing as the sole return value of another function is a
-- fixed one-value result shape; the nested function's own flexible return tail
-- remains on its TypeFunction node.
function defs.functionreturnshape(pos, argtypes, varargtype, result)
    return {
        rettypes = {
            ast.TypeFunction(pos, argtypes, result.rettypes, varargtype,
                result.flexrettype),
        },
        flexrettype = false,
    }
end

-- Build a TypeFunction node, reordering the captures so both optional tails
-- land after their corresponding fixed lists.
function defs.typefunc(pos, argtypes, varargtype, result)
    return ast.TypeFunction(pos, argtypes, result.rettypes, varargtype,
        result.flexrettype)
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

-- Match-time guard against absurdly long parameter/expression lists. Used as a
-- `=>` predicate over a captured list: succeeds (re-yielding the list capture)
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
                              / toplevelfunc
                              / topleveltype
                              / toplevelvar
                              / toplevelrecord
                              / toplevelunion
                              / import
                              / foreign ) => appendprogram)*
                           ((moduleinit)? -> opt) !.) -> makeprogram

    method          <- (P  localopt FUNCTION NAME COLON NAME^NameMethod
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block END^EndFunc)         -> methoddecl

    static          <- (P  localopt FUNCTION NAME DOT NAME^NameStatic
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block END^EndFunc)         -> staticdecl

    toplevelfunc    <- (P  localopt FUNCTION NAME^NameFunc
                           LPAREN^LParPList paramlist RPAREN^RParPList
                           rettypeopt block END^EndFunc)         -> TopLevelFunc

    topleveltype    <- (P  localopt TYPE NAME^NameTypeAlias
                           ASSIGN^AssignTypeAlias
                           type^TypeTypeAlias)                   -> TopLevelTypeAlias

    toplevelvar     <- (P localopt decl ASSIGN^AssignVar
                           !(IMPORT / FOREIGN)
                           exp^ExpVarDec)                        -> TopLevelVar

    toplevelrecord  <- (P  localopt RECORD NAME^NameRecord
                           recordfields^FieldRecord
                           END^EndRecord)                        -> recorddecl

    toplevelunion   <- (P  localopt UNION NAME^NameUnion
                           unionvariants^VariantUnion
                           END^EndUnion)                         -> uniondecl

    -- Interfaces are deliberately top-level and non-local. The local branch
    -- exists only to commit to the interface-specific diagnostic before the
    -- ordinary `local NAME = ...` alternatives get a chance to claim it.
    toplevelinterface
                    <- (P  (LOCAL INTERFACE %{LocalInterface} / INTERFACE)
                           NAME^NameInterface
                           interfacemethods
                           (END
                            / (!. %{EndInterface})
                            / %{MemberInterface}))               -> TopLevelInterface

    -- Unlike parameter and expression lists, the repeated method declaration
    -- list has no arbitrary source-level length limit.
    interfacemethods
                    <- {| interfacemethod^MethodInterface
                           interfacemethod* |}

    interfacemethod <- (P  LOCAL FUNCTION %{LocalInterfaceMethod})
                     / (P  FUNCTION NAME^NameInterfaceMethod
                           LPAREN^LParInterfaceMethod paramlist
                           RPAREN^RParInterfaceMethod
                           interfacerettypeopt)                  -> InterfaceMethod

    localopt        <- (LOCAL)?                                  -> boolopt

    import          <- (P  LOCAL NAME^NameImport ASSIGN^AssignImport
                          !FOREIGN IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                          STRINGLIT^StringImport))               -> importdecl

    foreign         <- (P  LOCAL NAME^NameImport ASSIGN^AssignImport
                           FOREIGN IMPORT^ImportImport
                          (LPAREN STRINGLIT^StringLParImport RPAREN^RParImport /
                           STRINGLIT^StringImport))              -> TopLevelForeignImport

    moduleinit      <- (P DO block END^EndBlock) -> moduleinit   -- marks StatBlock/StatTry

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

    funcexp         <- (P  FUNCTION LPAREN^LParPList lambdaparamlist
                           RPAREN^RParPList lambdarettypeopt
                           block END^EndFunc)                    -> ExpFunction

    decl            <- (P  NAME COLON type^TypeDecl)             -> typeddecl
                     / (P  NAME OPT COLON type^TypeDecl)         -> optiondecl
                     / (P  NAME OPT)                             -> optiondecl
                     / (P  NAME)                                 -> inferreddecl

    decllist        <- {| decl (COMMA decl^DeclParList)* |}      -- produces {Decl}

    -- A source-written fixed C array is deliberately not part of the general
    -- type grammar. It is available only to the single, initializer-less
    -- automatic-local statement below. Its signed integer token is retained as
    -- an ExpInteger so the checker receives both the value and its source
    -- location when enforcing the positive-extent rule.
    membername      <- NAME
                     / (CNAME -> contextual_c_name)

    qualifiedtype   <- (P  NAME DOT membername^QualName)         -> qualifiedtype

    carraylength    <- (((P  SUB NUMBER) => negativecarraylength)
                       / ((P  NUMBER) => carraylength)
                       / %{CArrayExtent})

    automaticlocaltype
                    <- (P  qualifiedtype
                            LBRACKET carraylength
                            RBRACKET^RBracketCArray)             -> TypeCArray
                     / qualifiedtype

    automaticlocaldecl
                    <- (P  NAME COLON
                            automaticlocaltype)                  -> typeddecl

    -- An owned payload is deliberately optionless: the sole trailing `?` in
    -- `simpletype` wraps the complete owner. The array alternative is selected
    -- with lookahead before the scalar ownership marker is considered, so
    -- `owned *c.Item[]` is an array of C pointers while `owned *c.Item` owns
    -- one C Item object.
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
                     / qualifiedtype
                     / (P  NAME)                                 -> TypeName
                     / ownedtype

    ownedtype       <- (P  OWNED &(cownedpayload LBRACKET)
                           cownedpayload LBRACKET
                           RBRACKET^RBracketCOwned)              -> cownedarraytype
                     / (P  OWNED MUL
                           cownedpayload^OwnedPayload)           -> cownedscalartype
                     / (P  OWNED %{COwnedShape})

    simpletype      <- ((((P  NIL)                               -> TypeNil
                     / (P  BOOLEAN)                              -> TypeBoolean
                     / (P  INTEGER)                              -> TypeInteger
                     / (P  FLOAT)                                -> TypeFloat
                     / (P  STRING)                               -> TypeString
                     / (P  VALUE)                                -> TypeValue
                     / ownedtype
                     / (P  CONST MUL simpletype^TypeType)        -> constcptrtype
                     / (P  MUL simpletype^TypeType)              -> cptrtype
                     / qualifiedtype
                     / (P  NAME)                                 -> TypeName
                     / (P  LCURLY type^TypeType
                           COLON
                           type^TypeType
                           RCURLY^RCurlyType)                    -> TypeMap
                     / (P  LCURLY type^TypeType
                           RCURLY^RCurlyType)                    -> TypeArray)
                                                  (OPT -> '?')?) -> typeopt)
                        (!LBRACKET / %{CArrayOnlyAutomatic})

    -- A trailing, last-only `...: t` in a function-type arg list. The element
    -- type is mandatory (the `: t` declaration style). Produces the element type
    -- node; `varargtypeopt` defaults to `false` when absent. Only consumed in the
    -- arrow (function-type) productions below, never in a bare `typelist` used as
    -- a return-type list.
    varargtypeann   <- (P  DOTS COLON^VarargColon type^TypeDecl) -> varargtype

    varargtypeopt   <- ((COMMA varargtypeann / varargtypeann)?)  -> opt

    -- The fixed-type loop stops before a `, ...` so the optional trailing
    -- vararg (`varargtypeopt`) consumes that comma itself.
    arglist         <- ( LPAREN
                         {| (type (COMMA !DOTS type^TypelistType)*)? |}
                         varargtypeopt
                         RPAREN^RParenTypelist )                 -- produces {Type}, varargtypeopt

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

    resulttypelist  <- ( LPAREN
                         ( {| type (COMMA !DOTS type^TypelistType)* |}
                           flexrettypeafterfixed
                         / {| '' |} flexrettypeonlyopt )
                         RPAREN^RParenTypelist )                 -> returnshape

    -- Try a parenthesized result list first, but commit to it only when no
    -- arrow follows. This disambiguates `(...: T)` as a flexible result list
    -- from `(...: T) -> R` as a function type without running the input-vararg
    -- capture path and then backtracking through it.
    rettype         <- (resulttypelist !RARROW)
                     / (P  arglist RARROW
                            rettype^TypeReturnTypes)             -> functionreturnshape
                     / (P  {| simpletype |} (''->tofalse) RARROW
                             rettype^TypeReturnTypes)            -> functionreturnshape
                     / (simpletype                              -> singlereturn)
                     / (DOTS %{FlexRetParens})

    type            <- (P  arglist RARROW
                           rettype^TypeReturnTypes)              -> typefunc
                     / (P  {| simpletype |} (''->tofalse) RARROW
                           rettype^TypeReturnTypes)              -> typefunc
                     / simpletype

    recordfields    <- {| recordfield* |}                        -- produces {Decl}

    recordfield     <- (P  LOCAL NAME OPT COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> localoptionrecordfielddecl
                     / (P  LOCAL NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> localrecordfielddecl
                     / (P  NAME OPT COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> optionrecordfielddecl
                     / (P  NAME COLON^ColonRecordField
                           type^TypeRecordField SEMICOLON?)      -> recordfielddecl

    unionvariants   <- {| unionvariant^VariantUnion unionvariant* |}

    unionvariant    <- (P  LOCAL NAME^NameUnionVariant
                           unionpayloadopt SEMICOLON?)           -> localunionvariantdecl
                     / (P  NAME unionpayloadopt SEMICOLON?)      -> unionvariantdecl

    unionpayloadopt <- ((COLON type^TypeUnionVariant)?)          -> opt

    -- A `block` may optionally absorb `(catch <block>)? (finally <block>)?`
    -- trailers. When either is present `trywrap` builds a `StatTry` wrapper;
    -- otherwise it returns the plain `StatBlock`. Since every construct (function
    -- body, loop body, if branch, bare `do`) consumes `block`, catch/finally
    -- become available everywhere with no per-construct edits. The catch/finally
    -- clause bodies are `simpleblock`s (plain statement lists with no trailers),
    -- so an inner catch-block cannot greedily swallow the outer `finally`.
    block           <- (P  simpleblock
                            ((CATCH simpleblock^CatchBlock)? -> opt)
                            ((FINALLY simpleblock^FinallyBlock)? -> opt)) -> trywrap

    simpleblock     <- (P  {| statement* returnstat? |})         -> simpleblock

    statement       <- (SEMICOLON)                               -- ignore
                     / (P  (LOCAL? INTERFACE) %{NestedInterface})
                     / (P  BREAK)                                -> StatBreak
                     / (P  RAISE (exp? -> opt))                  -> StatRaise
                     / deferstat
                     / doblock                                   -- produces StatBlock/StatTry
                     / (P  WHILE exp^ExpWhile DO^DoWhile
                                 block END^EndWhile)             -> StatWhile
                     / (P  REPEAT block UNTIL^UntilRepeat
                                      exp^ExpRepeat)             -> StatRepeat
                     / (P  IF exp^ExpIf THEN^ThenIf block
                           elseifstats elseopt END^EndIf)        -> ifstat
                     / casestat
                     / forstat
                     / (P  LOCAL automaticlocaldecl
                                !ASSIGN !COMMA
                                !(OPT / LBRACKET))               -> automaticlocal
                     / (P  LOCAL decllist^DeclLocal ASSIGN^AssignLocal
                                 explist^ExpLocal)                   -> StatDecl
                     / (P  varlist ASSIGN^AssignAssign
                               explist^ExpAssign)                    -> StatAssign
                     / &(exp ASSIGN) %{AssignNotLValue}
	                     / (P  (suffixedexp => exp_is_call))         -> StatCall
	                     / &exp %{ExpStat}

    deferstat       <- (P  DEFER (!DEFER / %{DeferDefer})
                              (!SEMICOLON / %{DeferStatement})
                              statement^DeferStatement)          -> deferstat

	    forstat         <- (P  FOR decl^DeclFor forrest)          -> forstat

	    forrest         <- (P  IN explist^ExpForIn
	                            DO^DoForIn block END^EndForIn)   -> forin_rest0
	                     / (P  forindecls IN^InFor
	                             explist^ExpForIn
	                             DO^DoForIn block END^EndForIn)   -> forin_rest
	                     / (P  ASSIGN^AssignFor exp^Exp1For
	                             COMMA^CommaFor exp^Exp2For
	                             (COMMA exp^Exp3For)?             -> opt
	                             DO^DoFor block END^EndFor)       -> fornum_rest
	                     / %{AssignFor}

	    forindecls      <- {| COMMA decl^DeclParList
	                           (COMMA decl^DeclParList)* |}       -- produces {Decl}

	    elseifstats     <- {| elseifstat* |}                         -- produces {Then}

    elseifstat      <- (P  ELSEIF exp^ExpElseIf
                           THEN^ThenElseIf block)                -> Then

    elseopt         <- (ELSE block)?                             -> opt

    casestat        <- (P  CASE exp^ExpCase
                           casearms^WhenCase
                           elseopt END^EndCase)                  -> StatCase

    casearms        <- {| casearm^WhenCase casearm* |}

    casearm         <- (P  WHEN NAME^NameCaseVariant
                           casebindingopt
                           THEN^ThenCase block)                  -> CaseArm

    casebindingopt  <- (((COLON P NAME^NameCaseBinding)
                                                        -> casebinding)?) -> opt

    returnstat      <- (P  RETURN (explist? -> listopt) SEMICOLON?)      -> StatReturn

    doblock         <- (DO block END^EndBlock)                   -- produces StatBlock/StatTry

    op1             <- ( OR -> 'or' )
    op2             <- ( AND -> 'and' )
    op3             <- ( EQ -> '==' / NE -> '~=' / LT -> '<' /
                         GT -> '>'  / LE -> '<=' / GE -> '>=' )
    op4             <- ( BOR -> '|' )
    op5             <- ( BXOR -> '~' )
    op6             <- ( BAND -> '&' )
    op7             <- ( SHL -> '<<' / SHR -> '>>' )
    op8             <- ( CONCAT -> '..' )
    op9             <- ( ADD -> '+' / SUB -> '-' )
    op10            <- ( MUL -> '*' / MOD -> '%%' / DIV -> '/' / IDIV -> '//' )
    unop            <- ( NOT -> 'not' / LEN -> '#' / NEG -> '-' / BNEG -> '~' )
    op12            <- ( POW -> '^' )

    exp             <- e1
    e1              <- (P  {| e2  (op1  e2^OpExp)* |})           -> fold_binop_left
    e2              <- (P  {| e3  (op2  e3^OpExp)* |})           -> fold_binop_left
    e3              <- (P  {| e4  (op3  e4^OpExp)* |})           -> fold_binop_left
    e4              <- (P  {| e5  (op4  e5^OpExp)* |})           -> fold_binop_left
    e5              <- (P  {| e6  (op5  e6^OpExp)* |})           -> fold_binop_left
    e6              <- (P  {| e7  (op6  e7^OpExp)* |})           -> fold_binop_left
    e7              <- (P  {| e8  (op7  e8^OpExp)* |})           -> fold_binop_left
    e8              <- (P     e9  (op8  e8^OpExp)?)              -> binop_concat
    e9              <- (P  {| e10 (op9  e10^OpExp)* |})          -> fold_binop_left
    e10             <- (P  {| e11 (op10 e11^OpExp)* |})          -> fold_binop_left
    e11             <- castexp
    unopexp         <- (P  {| unop* |}  e12)                     -> fold_unops
    e12             <- (P  simpleexp (op12 e11^OpExp)?)          -> binop_right

    suffixedexp     <- (prefixexp {| expsuffix+ |})              -> fold_suffixes

    -- Parentheses and bare strings are positional call suffixes. Bare braces
    -- are always named calls; passing one constructor positionally therefore
    -- requires parentheses (`f({ ... })`). Keeping the paths distinct here
    -- preserves the delimiter choice in the Args node for checker lowering.
    expsuffix       <- (P  funcargs)                             -> suffix_funccall
                     / (P  namedargs)                           -> suffix_namedfunccall
                     / (P  COLON NAME^NameColonExpSuf
                                 funcargs)                       -> suffix_methodcall
                     / (P  COLON NAME^NameColonExpSuf
                                 namedargs)                      -> suffix_namedmethodcall
                     / (P  COLON NAME^NameColonExpSuf)           -> suffix_methodref
                     / (P  LBRACKET exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf)         -> suffix_bracket
                     / (P  DOT membername^NameDotExpSuf)         -> suffix_dot

    prefixexp       <- (P  NAME)                                 -> name_exp
                     / (P  LPAREN exp^ExpSimpleExp
                               RPAREN^RParSimpleExp)             -> adjust_exp


    castexp         <- (P  unopexp AS type^CastMissingType)      -> ExpCast
                     / (P  unopexp IS type^IsMissingType)        -> ExpIs
                     / unopexp                                   -- produces Exp

    simpleexp       <- (P  NIL)                                  -> nil_exp
                     / (P  FALSE -> tofalse)                     -> ExpBool
                     / (P  TRUE -> totrue)                       -> ExpBool
                     / (P  NUMBER)                               -> number_exp
                     / (P  STRINGLIT)                            -> ExpString
                     / (P  DOTS LBRACKET exp^ExpExpSuf
                                RBRACKET^RBracketExpSuf)         -> ExpDotsIndex
                     / (P  DOTS)                                 -> ExpDots
                     / initlist                                  -- produces Exp
                     / funcexp                                   -- produces Exp
                     / suffixedexp                               -- produces Exp
                     / prefixexp                                 -- produces Exp

    var             <- (suffixedexp => exp_is_var)               -> exp2var
                     / (P  NAME !expsuffix)                      -> name_exp -> exp2var

    varlist         <- {| var (COMMA var^ExpVarList)* |}            -- produces {Var}

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
                           exp^ExpNamedArg)                     -> Field

    -- A trailing `...` spread is allowed as the last item of an explist (call
    -- args, return, assignment/decl RHS). A bare `...` is a one-element list;
    -- the `!LBRACKET` guards against `...[e]`, which is an ordinary expression
    -- (an ExpDotsIndex) handled by the general alternative below.
    --
    -- The fixed-exp repetition is bounded to LIST_LIMIT elements (1 +
    -- LIST_LIMIT-1 trailing); a LIST_LIMIT+1-th expression makes the trailing
    -- `&(COMMA exp)` succeed and throw `%{ListTooLong}`. Bounding the
    -- repetition (rather than guarding the whole list with `&exp`) keeps a
    -- labeled failure thrown inside an expression — e.g. a malformed lambda
    -- parameter — propagating, since a positive lookahead would convert it to
    -- an ordinary failure and mask the real label.
    explist         <- {| ((P  DOTS !LBRACKET) -> ExpDots) |}
                     / {| exp (COMMA exp^ExpExpList)^-99
                           (COMMA ((P  DOTS) -> ExpDots))? |}
                       (&(COMMA exp) %{ListTooLong})?         -- produces {Exp}

    initlist        <- (P  LCURLY {| fieldlist? |}
                                  RCURLY^RCurlyInitList)         -> ExpInitList

    fieldlist       <- (field
                        (fieldsep
                         (field /
                          !RCURLY %{ExpFieldList}))*
                        fieldsep?)                          -- produces Field...

    field           <- (P  DOTS !LBRACKET)                 -> dots_field
                     / (P  (key ASSIGN)? -> opt exp)       -> Field

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

    THIS_FILENAME = filename
    PROGRAM_NODES = {}
    local ast, err, errpos = grammar:match(input)
    PROGRAM_NODES = nil
    THIS_FILENAME = nil

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
