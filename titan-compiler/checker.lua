local checker = {}

local location = require "titan-compiler.location"
local symtab = require "titan-compiler.symtab"
local types = require "titan-compiler.types"
local ast = require "titan-compiler.ast"
local util = require "titan-compiler.util"
local foreigntypes = require "titan-compiler.foreigntypes"
local cdriver = require("c-parser.cdriver")


-- The typechecker works in two passes, the first one just
-- collects type information for top-level functions and variables
-- (and detects duplicate definitions in the top level), while the
-- second pass does the actual typechecking. All typechecked nodes
-- that have a type get a "_type" field with the type. The types
-- themselves are in "types.lua".
local typefromnode

local checkdecl
local checkstat
local checkexp
local checkvar
local checkfuncbody

-- nesting depth of enclosing loops, so `break` can be rejected outside a loop
local loop_depth = 0

-- Stack of enclosing-function frames, used for closure capture analysis. Each
-- frame is { depth, captures = {}, capture_set = {} }. A top-level function body
-- is at depth 1; a lambda nested inside it is at depth 2; and so on. Reset
-- explicitly at the top of `checker.check` (unlike `loop_depth`, which is never
-- reset).
local func_stack = {}

function checker.typeerror(errors, loc, fmt, ...)
    local errmsg = location.format_error(loc, "type error: "..fmt, ...)
    table.insert(errors, errmsg)
end

-- Checks if a nominal type 'type' is valid
local function checktype(type, loc, errors)
    if type._tag == "Type.Nominal" and
        not types.registry[type.fqtn] then
        checker.typeerror(errors, loc,
            "invalid type '%s' in type declaration", type.fqtn)
    end
end

-- Checks if two types are the same, and logs an error message otherwise
--   term: string describing what is being compared
--   expected: type that is expected
--   found: type that was actually present
--   errors: list of compile-time errors
--   loc: location of the term that is being compared
local function checkmatch(term, expected, found, errors, loc)
    if types.coerceable(found, expected) or not types.compatible(expected, found) then
        local msg = "types in %s do not match, expected %s but found %s"
        msg = string.format(msg, term, types.tostring(expected), types.tostring(found))
        checker.typeerror(errors, loc, msg)
    end
end

local function invalid(errors, loc, ...)
    checker.typeerror(errors, loc, ...)
    return types.Invalid()
end

local function optionize(t)
    if t._tag == "Type.Option" or t._tag == "Type.Value" then
        return t
    else
        return types.Option(t)
    end
end

local function deoptionize(t)
    if t._tag == "Type.Option" then
        assert(t.base._tag ~= "Type.Option")
        return t.base
    else
        return t
    end
end

-- Converts an AST type declaration into a typechecker type
--   node: AST node
--   errors: list of compile-time errors
--   returns a type (from types.lua)
typefromnode = util.make_visitor({
    ["Ast.TypeNil"] = function(_, _, _)
        return types.Nil()
    end,

    ["Ast.TypeBoolean"] = function(_, _, _)
        return types.Boolean()
    end,

    ["Ast.TypeInteger"] = function(_, _, _)
        return types.Integer()
    end,

    ["Ast.TypeFloat"] = function(_, _, _)
        return types.Float()
    end,

    ["Ast.TypeString"] = function(_, _, _)
        return types.String()
    end,

    ["Ast.TypeValue"] = function(_, _, _)
        return types.Value()
    end,

    ["Ast.TypeName"] = function(node, st, _)
        return types.Nominal(st.modname .. "." .. node.name)
    end,

    ["Ast.TypeQualName"] = function(node, st, errors)
        local mod = st:find_symbol(node.module)
        if mod and mod._type._tag == "Type.Module" then
            local fqtn = mod._type.name .. "." .. node.name
            return types.Nominal(fqtn)
        end
        return invalid(errors, node.loc, "module '%s' referenced by type not found", node.module)
    end,

    ["Ast.TypeArray"] = function(node, st, errors)
        return types.Array(deoptionize(typefromnode(node.subtype, st, errors)))
    end,

    ["Ast.TypeMap"] = function(node, st, errors)
        local key = typefromnode(node.keystype, st, errors)
        if key._tag == "Type.Nil" then
            checker.typeerror(errors, node.loc, "type of map key cannot be nil", node.module)
            key = types.Invalid()
        elseif key._tag == "Type.Option" then
            checker.typeerror(errors, node.loc, "type of map key cannot be option type", node.module)
            key = deoptionize(key)
        end
        return types.Map(key,
                         deoptionize(typefromnode(node.valuestype, st, errors)))
    end,

    ["Ast.TypeFunction"] = function(node, st, errors)
        -- First-class function type `(P...) -> (R...)`. argtypes and rettypes
        -- are lists of type nodes; a nested arrow (`a -> b -> c`, right
        -- associative) shows up as a TypeFunction inside rettypes and recurses.
        local ptypes = {}
        for _, pt in ipairs(node.argtypes) do
            table.insert(ptypes, typefromnode(pt, st, errors))
        end
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        return types.Function(ptypes, rettypes, false)
    end,

    ["Ast.TypeOption"] = function(node, st, errors)
        return optionize(typefromnode(node.basetype, st, errors))
    end
})

-- tries to coerce node to target type
--    node: expression node
--    target: target type
--    returns node wrapped in a coercion, or original node
local function trycoerce(source, target, errors)
    if types.coerceable(source._type, target) then
        local n
        if source._type._tag == "Type.Option" and target._tag == "Type.Option" then
            -- t1? -> t2?: a single cast that propagates nil and converts a
            -- present value (the coder emits the nil-check + base conversion);
            -- do NOT unwrap, which would raise on nil.
            n = ast.ExpCast(source.loc, source, target)
        elseif source._type._tag == "Type.Option" and
           target._tag ~= "Type.Boolean" and
           target._tag ~= "Type.Value" then
            local inner = ast.ExpCast(source.loc, source, source._type.base)
            inner._type = source._type.base
            n = trycoerce(inner, target, errors)
        elseif target._tag == "Type.Option" then
            if source._type._tag == "Type.Nil" then
                -- nil -> T?: emit the cast directly so the coder's Nil->Option
                -- path runs (setnilvalue). Recursing through target.base would
                -- coerce nil to the base first (e.g. nil -> boolean = false),
                -- destroying the nil/false distinction that is the point of T?.
                n = ast.ExpCast(source.loc, source, target)
            else
                n = ast.ExpCast(source.loc, trycoerce(source, target.base, errors), target)
            end
        else
            n = ast.ExpCast(source.loc, source, target)
        end
        n._type = target
        return n
    else
        return source
    end
end

-- force option if present
--    node: expression node
--    returns node wrapped in a coercion, or original node
local function tryforce(node)
    if node._type._tag == "Type.Option" then
        local n = ast.ExpCast(node.loc, node, node._type.base)
        n._type = node._type.base
        return n
    else
        return node
    end
end

local function trytostr(node)
    local source = node._type
    if source._tag == "Type.Integer" or
       source._tag == "Type.Float" then
        local n = ast.ExpCast(node.loc, node, types.String())
        n._type = types.String()
        return n
    else
        return node
    end
end

--
-- Decl
--

checkdecl = function(node, st, errors)
    node._type = node._type or typefromnode(node.type, st, errors)
    checktype(node._type, node.loc, errors)
end

local function declare(node, st)
    -- Stamp the function-nesting depth at which this local was declared, so the
    -- VarName visitor can tell a capture (use from a deeper function) apart from
    -- a same-function reference.
    node._funcdepth = #func_stack
    st:add_symbol(node.name, node)
end

--
-- Stat
--

-- Typechecks a repeat/until statement
--   node: StatRepeat AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for repeat/until)
local function checkrepeat(node, st, errors)
    for _, stat in ipairs(node.block.stats) do
        checkstat(stat, st, errors)
    end
    checkexp(node.condition, st, errors, types.Boolean())
    return false
end

-- Typechecks a for loop statement
--   node: StatFor AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for 'for' loop)
local function checkfor(node, st, errors)
    checkexp(node.start, st, errors)
    node.start = tryforce(node.start)
    checkexp(node.finish, st, errors)
    node.finish = tryforce(node.finish)
    if node.inc then
        checkexp(node.inc, st, errors)
        node.inc = tryforce(node.inc)
    end

    -- Add loop variable to symbol table only after checking expressions
    if not node.decl.type then
        node.decl._type = node.start._type
    end
    checkdecl(node.decl, st, errors)
    declare(node.decl, st)
    -- The numeric-for control variable is read-only (as in Lua 5.4+):
    -- assigning to it is a clean compile-time error, not a silent miscompile.
    node.decl._forcontrol = true

    local loop_type_is_valid
    if node.decl._type._tag == "Type.Integer" then
        loop_type_is_valid = true
        if not node.inc then
            node.inc = ast.ExpInteger(node.finish.loc, 1)
            node.inc._type = types.Integer()
        end
    elseif node.decl._type._tag == "Type.Float" then
        loop_type_is_valid = true
        if not node.inc then
            node.inc = ast.ExpFloat(node.finish.loc, 1.0)
            node.inc._type = types.Float()
        end
    else
        loop_type_is_valid = false
        checker.typeerror(errors, node.decl.loc,
            "type of for control variable %s must be integer or float",
            node.decl.name)
    end

    if loop_type_is_valid then
        checkmatch("'for' start expression",
            node.decl._type, node.start._type, errors, node.start.loc)
        checkmatch("'for' finish expression",
            node.decl._type, node.finish._type, errors, node.finish.loc)
        checkmatch("'for' step expression",
            node.decl._type, node.inc._type, errors, node.inc.loc)
    end

    checkstat(node.block, st, errors)

    return false
end

-- Typechecks a block statement
--   node: StatBlock AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether the block always returns from the containing function
local function checkblock(node, st, errors)
    local ret = false
    for _, stat in ipairs(node.stats) do
        ret = ret or checkstat(stat, st, errors)
    end
    return ret
end

-- Typechecks a statement or declaration
--   node: A DeclDecl or Stat_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether statement always returns from its function (always false for repeat/until)
checkstat = util.make_visitor({
    ["Ast.StatDecl"] = function(node, st, errors)
        local nlastexp = #node.exps
        local lastexp = node.exps[nlastexp]
        for i = 1, #node.exps do
            local decl = node.decls[i]
            local exp = node.exps[i]
            if decl then
                if decl.type then
                    checkdecl(decl, st, errors)
                    checkexp(exp, st, errors, decl._type)
                else
                    checkexp(exp, st, errors)
                    if not decl.option then
                        exp = tryforce(exp) -- never infer option type
                        decl._type = exp._type
                    else
                        decl._type = optionize(exp._type)
                    end
                    checkdecl(decl, st, errors)
                end
                exp = trycoerce(exp, decl._type, errors)
                node.exps[i] = exp
                checkmatch("declaration of local variable " .. decl.name,
                    decl._type, exp._type, errors, decl.loc)
            end
        end
        if lastexp._types then -- multiple return values
            for i = 2, #lastexp._types do
                local decl = node.decls[nlastexp + i - 1]
                local exp = ast.ExpExtra(lastexp.loc, lastexp, i, lastexp._types[i])
                if decl then
                    if decl.type then
                        checkdecl(decl, st, errors)
                        exp = trycoerce(exp, decl._type, errors)
                    elseif decl.option then
                        decl._type = optionize(exp._type)
                        exp = trycoerce(exp, decl._type, errors)
                    else
                        exp = tryforce(exp) -- never infer option type
                        decl._type = exp._type
                    end
                    checkmatch("declaration of local variable " .. decl.name,
                        decl._type, exp._type, errors, decl.loc)
                end
                table.insert(node.exps, exp)
            end
        end
        if #node.decls ~= #node.exps then
            checker.typeerror(errors, node.loc, "left-hand side expects %d value(s) but right-hand side produces %d value(s)", #node.decls, #node.exps)
        end
        for _, decl in ipairs(node.decls) do
            if not decl._type then
                -- no initializer reached this declaration (too few values on
                -- the right-hand side, e.g. `local a, b = (f())`): the arity
                -- error above is already reported; recover the type so later
                -- uses of this variable don't crash the checker with a nil type
                if decl.type then
                    checkdecl(decl, st, errors)
                else
                    decl._type = types.Invalid()
                end
            end
            declare(decl, st)
        end
    end,

    ["Ast.StatBlock"] = function(node, st, errors)
        return st:with_block(checkblock, node, st, errors)
    end,

    ["Ast.StatWhile"] = function(node, st, errors)
        checkexp(node.condition, st, errors, types.Boolean())
        loop_depth = loop_depth + 1
        st:with_block(checkstat, node.block, st, errors)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatRepeat"] = function(node, st, errors)
        loop_depth = loop_depth + 1
        st:with_block(checkrepeat, node, st, errors)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatFor"] = function(node, st, errors)
        loop_depth = loop_depth + 1
        st:with_block(checkfor, node, st, errors)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatBreak"] = function(node, _, errors)
        if loop_depth == 0 then
            checker.typeerror(errors, node.loc,
                "'break' outside a loop")
        end
        return false
    end,

    ["Ast.StatAssign"] = function(node, st, errors)
        for _, var in ipairs(node.vars) do
            checkvar(var, st, errors)
        end
        for i, exp in ipairs(node.exps) do
            checkexp(exp, st, errors, node.vars[i] and node.vars[i]._type)
        end
        local nexps = #node.exps
        local lastexp = node.exps[nexps]
        if lastexp._types and #lastexp._types > 1 then
            for i = 2, #lastexp._types do
                table.insert(node.exps, ast.ExpExtra(lastexp.loc, lastexp, i, lastexp._types[i]))
            end
        end
        if #node.vars ~= #node.exps then
            checker.typeerror(errors, node.loc, "left-hand side expects %d value(s) but right-hand side produces %d value(s)", #node.vars, #node.exps)
        end
        for i, exp in ipairs(node.exps) do
            local var = node.vars[i]
            if var then
                local texp = var._type
                if texp._tag == "Type.Module" then
                    checker.typeerror(errors, var.loc, "trying to assign to a module")
                elseif texp._tag == "Type.Function" and var._decl
                       and (var._decl._tag == "Ast.TopLevelFunc"
                            or var._decl._tag == "Type.ModuleMember"
                            or var._decl._tag == "Type.StaticMethod") then
                    -- Cannot rebind a function *declaration* (top-level
                    -- function, imported module function, or record static).
                    -- Assigning a value *into* a function-typed local, param
                    -- or field is fine and falls through to the normal path.
                    checker.typeerror(errors, var.loc, "trying to assign to a function")
                elseif var._tag == "Ast.VarDot" and var._decl
                       and var._decl._tag == "Type.ModuleMember" then
                    checker.typeerror(errors, var.loc, "cannot assign to foreign variable '%s'", var.name)
                else
                    -- mark this declared variable as assigned to
                    if var._tag == "Ast.VarName" and var._decl then
                        if var._decl._forcontrol then
                            checker.typeerror(errors, var.loc,
                                "cannot assign to 'for' control variable '%s'",
                                var._decl.name)
                        end
                        var._decl._assigned = true
                    end
                    exp = trycoerce(exp, var._type, errors)
                    node.exps[i] = exp
                    checkmatch("assignment", var._type, exp._type, errors, var.loc)
                end
            end
        end
    end,

    ["Ast.StatCall"] = function(node, st, errors)
        -- A call in statement position may discard its result, including a
        -- zero-return `() -> ()` call that produces no value at all.
        node.callexp._voidok = true
        checkexp(node.callexp, st, errors)
    end,

    ["Ast.StatReturn"] = function(node, st, errors)
        local ftype = st:find_symbol("$function")._type
        for i, exp in ipairs(node.exps) do
            checkexp(exp, st, errors, ftype.rettypes[i])
        end
        if #node.exps == 0 and #ftype.rettypes == 1
           and ftype.rettypes[1]._tag == "Type.Nil" then
            -- A bare `return` in a nil-returning function means `return nil`.
            local nilexp = ast.ExpNil(node.loc)
            nilexp._type = types.Nil()
            table.insert(node.exps, nilexp)
        end
        local lastexp = node.exps[#node.exps]
        if lastexp and lastexp._types and #lastexp._types > 1 then
            for i = 2, #lastexp._types do
                table.insert(node.exps, ast.ExpExtra(lastexp.loc, lastexp, i, lastexp._types[i]))
            end
        end
        if #ftype.rettypes ~= #node.exps then
            checker.typeerror(errors, node.loc, "returned %d value(s) but function expected %d", #node.exps, #ftype.rettypes)
        end
        for i, tret in ipairs(ftype.rettypes) do
            local exp = node.exps[i]
            if exp then
                exp = trycoerce(exp, tret, errors)
                node.exps[i] = exp
                checkmatch("return", tret, exp._type, errors, exp.loc)
            end
        end
        return true
    end,

    ["Ast.StatIf"] = function(node, st, errors)
        local ret = true
        for _, thn in ipairs(node.thens) do
            checkexp(thn.condition, st, errors, types.Boolean())
            ret = checkstat(thn.block, st, errors) and ret
        end
        if node.elsestat then
            ret = checkstat(node.elsestat, st, errors) and ret
        else
            ret = false
        end
        return ret
    end,
})

--
-- Var
--

-- Typechecks an variable node
--   node: Var_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   annotates the node with its type in a "_type" field
checkvar = util.make_visitor({
    ["Ast.VarName"] = function(node, st, errors, _)
        local decl = st:find_symbol(node.name)
        if not decl then
            node._type = invalid(errors, node.loc,
                "variable '%s' not declared", node.name)
        else
            node._decl = decl
            node._type = decl._type
            -- Capture detection (single chokepoint). A local/param (`Ast.Decl`,
            -- which excludes top-level functions/vars and module members) used
            -- from a function nested deeper than where it was declared is
            -- captured by every intervening lambda, INCLUSIVE of the current
            -- (innermost) one.
            if decl._tag == "Ast.Decl" and decl._funcdepth
               and decl._funcdepth < #func_stack then
                decl._captured = true
                -- A variable only *written* (never read) by a nested function
                -- would otherwise miss StatDecl's `_used` gate and never get a
                -- box allocated; force it used here.
                decl._used = true
                for d = decl._funcdepth + 1, #func_stack do
                    local frame = func_stack[d]
                    if not frame.capture_set[decl] then
                        frame.capture_set[decl] = true
                        table.insert(frame.captures, decl)
                    end
                end
            end
        end
    end,

    ["Ast.VarDot"] = function(node, st, errors, _)
        if node.exp._tag == "Ast.ExpVar" then
            checkvar(node.exp.var, st, errors)
            if node.exp.var._decl then node.exp.var._decl._used = true end
            node.exp._type = node.exp.var._type
        else
            checkexp(node.exp, st, errors)
        end
        node.exp = tryforce(node.exp)
        local ltype = node.exp._type
        if ltype._tag == "Type.Module" or ltype._tag == "Type.ForeignModule" then
            local mod = ltype
            if not mod.members[node.name] then
                node._type = invalid(errors, node.loc,
                    "member '%s' not found inside module '%s'",
                    node.name, mod.name)
            else
                node._decl = mod.members[node.name]
                node._type = node._decl.type
            end
        elseif ltype._tag == "Type.Record" then
            local decl = ltype.functions[node.name]
            if decl then
                node._decl = decl
                node._type = types.Function(decl.params, decl.rettypes, false)
            else
                node._type = invalid(errors, node.loc,
                    "trying to access invalid record function '%s'", node.name)
            end
        elseif ltype._tag == "Type.Nominal" then
            local type = types.registry[ltype.fqtn]
            if not type then
                node._type = invalid(errors, node.loc,
                    "type '%s' not found", ltype.fqtn)
            elseif type._tag ~= "Type.Record" then
                node._type = invalid(errors, node.loc,
                    "trying to access field '%s' of type '%s' that is not a record but '%s'",
                    node.name, ltype.fqtn, type._tag)
            else
                for _, field in ipairs(type.fields) do
                    if field.name == node.name then
                        node._decl = field
                        node._type = field.type
                        break
                    end
                end
                if not node._type then
                    node._type = invalid(errors, node.loc,
                        "field '%s' not found in record '%s'",
                        node.name, ltype.fqtn)
                end
            end
        else
            node._type = invalid(errors, node.loc,
                "trying to access a member of value of type '%s'",
                types.tostring(ltype))
        end
    end,

    ["Ast.VarBracket"] = function(node, st, errors, _)
        checkexp(node.exp1, st, errors)
        node.exp1 = tryforce(node.exp1)
        local keystype, term
        if node.exp1._type._tag == "Type.Array" then
            node._type = optionize(node.exp1._type.elem)
            keystype = types.Integer()
            term = "array indexing"
        elseif node.exp1._type._tag == "Type.Map" then
            node._type = optionize(node.exp1._type.values)
            keystype = node.exp1._type.keys
            term = "map indexing"
        else
            node._type = invalid(errors, node.exp1.loc,
                "expression in indexing is not an array or map but %s",
                types.tostring(node.exp1._type))
            return
        end

        checkexp(node.exp2, st, errors, keystype)
        -- always try to coerce index key to key type
        node.exp2 = trycoerce(node.exp2, keystype, errors)
        checkmatch(term, keystype, node.exp2._type, errors, node.exp2.loc)
    end,
})

--
-- Exp
--

-- Returns best guess of expression name
local function expname(node)
    if node._tag == "Ast.ExpVar" then
        if node.var._tag == "Ast.VarName" then
            return node.var.name
        elseif node.var._tag == "Ast.VarDot" then
            return expname(node.var.exp) .. "." .. node.var.name
        else
            return "(expression)"
        end
    else
        return "(expression)"
    end
end

-- Typechecks and argument list for a function or method call
local function checkargs(ftype, args, loc, fname, st, errors)
    local nparams = #ftype.params
    local nargs = #args
    local lastarg = args[nargs]
    for i = 1, nargs do
        local arg = args[i]
        local ptype = ftype.params[i]
        checkexp(arg, st, errors, ptype)
        ptype = ptype or arg._type
        args[i] = trycoerce(args[i], ptype, errors)
        local atype = args[i]._type
        checkmatch("argument " .. i .. " of call to " .. fname, ptype, atype, errors, arg.loc)
    end
    if lastarg and lastarg._types then
        for i = 2, #lastarg._types do
            local pidx = nargs + i - 1
            local ptype = ftype.params[pidx]
            local exp = ast.ExpExtra(lastarg.loc, lastarg, i, lastarg._types[i])
            ptype = ptype or exp._type
            exp = trycoerce(exp, ptype, errors)
            table.insert(args, exp)
            checkmatch("argument " .. pidx .. " of call to " .. fname, ptype, exp._type, errors, exp.loc)
        end
    end
    if not (#args == nparams or (ftype.vararg and #args > nparams)) then
        checker.typeerror(errors, loc,
            "%s called with %d arguments but expects %d.\n%s",
            fname, #args, nparams, types.tostring(ftype))
    end
end

-- Typechecks an expression
--   node: Exp_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   annotates the node with its type in a "_type" field
checkexp = util.make_visitor({
    ["Ast.ExpNil"] = function(node)
        node._type = types.Nil()
    end,

    ["Ast.ExpBool"] = function(node)
        node._type = types.Boolean()
    end,

    ["Ast.ExpInteger"] = function(node)
        node._type = types.Integer()
    end,

    ["Ast.ExpFloat"] = function(node)
        node._type = types.Float()
    end,

    ["Ast.ExpString"] = function(node)
        node._type = types.String()
    end,

    ["Ast.ExpInitList"] = function(node, st, errors, context)
        context = context and deoptionize(context)
        local expected = context and context._tag
        if not expected then
            -- try to detect from contents
            local elem = node.fields[1]
            if elem then
                if elem.name and type(elem.name) == "table" then
                    expected = "Type.Map"
                elseif elem.name and type(elem.name) == "string" then
                    expected = "Type.Nominal"
                end
            end
            -- fall back to array if not detected otherwise
            if not expected then
                expected = "Type.Array"
            end
        end

        if expected == "Type.Array" then
            local econtext = context and context.elem
            local etypes = {}
            for _, field in ipairs(node.fields) do
                if field.name then
                    checker.typeerror(errors, field.loc,
                        "initializing field '%s' when expecting array", field.name)
                    checkexp(field.exp, st, errors)
                else
                    local exp = field.exp
                    checkexp(exp, st, errors, econtext)
                    table.insert(etypes, exp._type)
                end
            end

            -- adjust last entry if it's a function call that expands to multiple values
            -- e.g. { 1, 2, f() }
            local lastfield = node.fields[#node.fields]
            if lastfield and not lastfield.name and lastfield.exp._types and #lastfield.exp._types > 1 then
                for i = 2, #lastfield.exp._types do
                    table.insert(node.fields,
                        ast.Field(lastfield.loc, nil,
                            ast.ExpExtra(lastfield.loc, lastfield.exp,
                                i, lastfield.exp._types[i])))
                end
            end

            local etype = econtext or (etypes[1] and deoptionize(etypes[1])) or types.Integer()
            node._type = types.Array(etype)
            for i, field in ipairs(node.fields) do
                if not field.name then
                    field.exp = trycoerce(field.exp, etype, errors)
                    local exp = field.exp
                    checkmatch("array initializer at position " .. i, etype,
                               exp._type, errors, exp.loc)
                end
            end
        elseif expected == "Type.Map" then
            local kcontext = context and context.keys
            local vcontext = context and context.values
            local ktypes = {}
            local vtypes = {}
            for _, field in ipairs(node.fields) do
                if type(field.name) == "string" then
                    checker.typeerror(errors, field.loc,
                        "initializing field '%s' when expecting map", field.name)
                    checkexp(field.exp, st, errors)
                else
                    local kexp = field.name
                    checkexp(kexp, st, errors, kcontext)
                    table.insert(ktypes, kexp._type)

                    local vexp = field.exp
                    checkexp(vexp, st, errors, vcontext)
                    table.insert(vtypes, vexp._type)
                end
            end

            local ktype = kcontext or deoptionize(ktypes[1])
            local vtype = vcontext or deoptionize(vtypes[1])
            node._type = types.Map(ktype, vtype)
            for i, field in ipairs(node.fields) do
                if not field.name then
                    field.name = trycoerce(field.name, ktype, errors)
                    local kexp = field.name
                    checkmatch("map key initializer at position " .. i, ktype,
                               kexp._type, errors, kexp.loc)

                    field.exp = trycoerce(field.exp, vtype, errors)
                    local vexp = field.exp
                    checkmatch("map value initializer at position " .. i, vtype,
                               vexp._type, errors, vexp.loc)
                end
            end
        elseif expected == "Type.Nominal" then
            if not context then
                node._type = invalid(errors, node.loc,
                    "no context to provide type for record constructor")
                for _, field in ipairs(node.fields) do
                    checkexp(field.exp, st, errors)
                end
            elseif not types.registry[context.fqtn] then
                node._type = invalid(errors, node.loc,
                    "record type '%s' in context of record constructor does not exist",
                    types.tostring(context))
                for _, field in ipairs(node.fields) do
                    checkexp(field.exp, st, errors)
                end
            else
                local record = types.registry[context.fqtn]
                for _, cfield in ipairs(node.fields) do
                    local found
                    for _, rfield in ipairs(record.fields) do
                        if rfield.name == cfield.name then
                            found = rfield
                        end
                    end
                    if not found then
                        if cfield.name then
                            checker.typeerror(errors, cfield.loc,
                                "field '%s' not found in record type '%s'",
                                cfield.name, types.tostring(context))
                        else
                            checker.typeerror(errors, cfield.loc,
                                "missing field in initializer for record type '%s'",
                                types.tostring(context))
                        end
                        checkexp(cfield.exp, st, errors)
                    else
                        checkexp(cfield.exp, st, errors, found.type)
                        cfield.exp = trycoerce(cfield.exp, found.type, errors)
                        checkmatch("field " .. cfield.name,
                            found.type, cfield.exp._type, errors, cfield.loc)
                        cfield._field = found
                    end
                end
                for _, rfield in ipairs(record.fields) do
                    local found
                    for _, cfield in ipairs(node.fields) do
                        if rfield.name == cfield.name then
                            found = cfield
                        end
                    end
                    if not found then
                        checker.typeerror(errors, node.loc,
                            "field '%s' from record type '%s' missing in constructor",
                            rfield.name, types.tostring(context))
                    end
                end
                node._type = types.Nominal(context.fqtn)
            end
        else
            local isarray = true
            local ismap = false
            local ktype
            local vtype
            for i, field in ipairs(node.fields) do
                checkexp(field.exp, st, errors)
                vtype = vtype or deoptionize(field.exp._type)
                field.exp = trycoerce(field.exp, vtype, errors)
                checkmatch("value expression no. " .. tostring(i),
                    vtype, field.exp._type, errors, field.loc)
                isarray = isarray and not field.name
                if type(field.name) == "table" then
                    checkexp(field.name, st, errors)
                    ktype = ktype or deoptionize(field.name._type)
                    field.name = trycoerce(field.name, ktype, errors)
                    checkmatch("key expression no. " .. tostring(i),
                        ktype, field.name._type, errors, field.loc)
                    ismap = true
                end
            end
            if ismap then
                node._type = types.Map(ktype, vtype or types.Integer())
            elseif isarray then
                node._type = types.Array(vtype or types.Integer())
            else
                node._type = invalid(errors, node.loc,
                    "no context to provide type for record constructor")
            end
        end
    end,

    ["Ast.ExpVar"] = function(node, st, errors, context)
        checkvar(node.var, st, errors, context)
        if node.var._decl then node.var._decl._used = true end
        local texp = node.var._type
        if texp._tag == "Type.Module" then
            node._type = invalid(errors, node.loc,
                "trying to access module '%s' as a first-class value",
                node.var.name)
        elseif texp._tag == "Type.Function" then
            -- First-class function value. Foreign (C FFI) functions cannot be
            -- taken as values; every other function (Titan top-level function,
            -- record static, imported module function, or a function-typed
            -- local/param/field that already holds a value) is allowed.
            local var = node.var
            if var._tag == "Ast.VarDot" and var.exp._type
               and var.exp._type._tag == "Type.ForeignModule" then
                node._type = invalid(errors, node.loc,
                    "a foreign (C) function cannot be used as a first-class value")
            else
                node._type = texp
                -- Mark a referenced *local* function declaration so the coder
                -- builds its canonical closure (exported functions and statics
                -- always get one; a function-typed local is already a value).
                local decl = var._decl
                if decl and decl._tag == "Ast.TopLevelFunc" then
                    decl._valref = true
                end
            end
        elseif texp._tag == "Type.Record" then
            node._type = invalid(errors, node.loc,
                "trying to access record type '%s' as a first-class value",
                texp.name)
        else
            node._type = texp
        end
    end,

    ["Ast.ExpUnop"] = function(node, st, errors, _)
        local op = node.op
        checkexp(node.exp, st, errors)
        local texp = node.exp._type
        local loc = node.loc
        if op == "#" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            if texp._tag ~= "Type.Array" and texp._tag ~= "Type.String" then
                checker.typeerror(errors, loc,
                    "trying to take the length of a %s instead of an array or string",
                    types.tostring(texp))
            end
            node._type = types.Integer()
        elseif op == "-" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            if texp._tag ~= "Type.Integer" and texp._tag ~= "Type.Float" then
                checker.typeerror(errors, loc,
                    "trying to negate a %s instead of a number",
                    types.tostring(texp))
            end
            node._type = texp
        elseif op == "~" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            -- always tries to coerce floats to integer
            node.exp = node.exp._type._tag == "Type.Float" and trycoerce(node.exp, types.Integer(), errors) or node.exp
            texp = node.exp._type
            if texp._tag ~= "Type.Integer" then
                checker.typeerror(errors, loc,
                    "trying to bitwise negate a %s instead of an integer",
                    types.tostring(texp))
            end
            node._type = types.Integer()
        elseif op == "not" then
            -- always coerces other values to a boolean
            node.exp = trycoerce(node.exp, types.Boolean(), errors)
            node._type = types.Boolean()
        else
            error("invalid unary operation " .. op)
        end
    end,

    ["Ast.ExpConcat"] = function(node, st, errors, _)
        for i, exp in ipairs(node.exps) do
            checkexp(exp, st, errors, types.String())
            exp = tryforce(exp)
            -- always tries to coerce numbers to string
            exp = trytostr(exp)
            node.exps[i] = exp
            local texp = exp._type
            if texp._tag == "Type.Value" then
                checker.typeerror(errors, exp.loc,
                    "cannot concatenate with value of type 'value'")
            elseif texp._tag ~= "Type.String" then
                checker.typeerror(errors, exp.loc,
                    "cannot concatenate with %s value", types.tostring(texp))
            end
        end
        node._type = types.String()
    end,

    ["Ast.ExpBinop"] = function(node, st, errors, context)
        local op = node.op
        checkexp(node.lhs, st, errors)
        local tlhs = node.lhs._type
        checkexp(node.rhs, st, errors)
        local trhs = node.rhs._type
        local loc = node.loc
        if op == "==" or op == "~=" then
            -- tries to coerce to value if either side is value
            if tlhs._tag == "Type.Value" or trhs._tag == "Type.Value" then
                node.lhs = trycoerce(node.lhs, types.Value(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Value(), errors)
                trhs = node.rhs._type
            end
            if tlhs._tag == "Type.Option" or trhs._tag == "Type.Option" then
                node.lhs = trycoerce(node.lhs, optionize(tlhs), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, optionize(trhs), errors)
                trhs = node.rhs._type
            end
            -- tries to coerce to float if either side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if (tlhs._tag ~= "Type.Option" or trhs._tag ~= "Type.Option" or
                ((tlhs.base._tag ~= "Type.Integer" or trhs.base._tag ~= "Type.Float") and
                 (tlhs.base._tag ~= "Type.Float" or trhs.base._tag ~= "Type.Integer"))) and
               not types.compatible(tlhs, trhs) then
                checker.typeerror(errors, loc,
                    "trying to compare values of incomparable types: %s and %s",
                    types.tostring(tlhs), types.tostring(trhs))
            end
            node._type = types.Boolean()
        elseif op == "<" or op == ">" or op == "<=" or op == ">=" then
            node.lhs = tryforce(node.lhs)
            tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs)
            trhs = node.rhs._type
            -- tries to coerce to float if either side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if not types.equals(tlhs, trhs) then
                if tlhs._tag ~= "Type.Integer" and tlhs._tag ~= "Type.Float" and trhs._tag == "Type.Integer" or trhs._tag == "Type.Float" then
                    checker.typeerror(errors, loc,
                        "left hand side of relational expression is a %s instead of a number",
                        types.tostring(tlhs))
                elseif trhs._tag ~= "Type.Integer" and trhs._tag ~= "Type.Float" and tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float" then
                    checker.typeerror(errors, loc,
                        "right hand side of relational expression is a %s instead of a number",
                        types.tostring(trhs))
                elseif tlhs._tag ~= "Type.String" and trhs._tag == "Type.String" then
                    checker.typeerror(errors, loc,
                        "left hand side of relational expression is a %s instead of a string",
                        types.tostring(tlhs))
                elseif trhs._tag ~= "Type.String" and tlhs._tag == "Type.String" then
                    checker.typeerror(errors, loc,
                        "right hand side of relational expression is a %s instead of a string",
                        types.tostring(trhs))
                else
                    checker.typeerror(errors, loc,
                        "trying to use relational expression with %s and %s",
                         types.tostring(tlhs), types.tostring(trhs))
                end
            else
                if tlhs._tag ~= "Type.Integer" and tlhs._tag ~= "Type.Float" and tlhs._tag ~= "Type.String" then
                    checker.typeerror(errors, loc,
                        "trying to use relational expression with two %s values",
                        types.tostring(tlhs))
                end
            end
            node._type = types.Boolean()
        elseif op == "+" or op == "-" or op == "*" or op == "%" or op == "//" then
            node.lhs = tryforce(node.lhs)
            tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs)
            trhs = node.rhs._type
            if not (tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float") then
                checker.typeerror(errors, loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(tlhs))
            end
            if not (trhs._tag == "Type.Integer" or trhs._tag == "Type.Float") then
                checker.typeerror(errors, loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(trhs))
            end
            -- tries to coerce to float if either side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if tlhs._tag == "Type.Float" and trhs._tag == "Type.Float" then
                node._type = types.Float()
            elseif tlhs._tag == "Type.Integer" and trhs._tag == "Type.Integer" then
                node._type = types.Integer()
            else
                -- error
                node._type = invalid(errors, loc, "invalid types in arithmetic expression")
            end
        elseif op == "/" or op == "^" then
            node.lhs = tryforce(node.lhs)
            tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs)
            trhs = node.rhs._type
            if tlhs._tag == "Type.Integer" then
                -- always tries to coerce to float
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
            end
            if trhs._tag == "Type.Integer" then
                -- always tries to coerce to float
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if tlhs._tag ~= "Type.Float" then
                checker.typeerror(errors, loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(tlhs))
            end
            if trhs._tag ~= "Type.Float" then
                checker.typeerror(errors, loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(trhs))
            end
            node._type = types.Float()
        elseif op == "and" then
            if context and context._tag == "Type.Boolean" then
                -- convert everything to boolean if used in boolean context
                node.lhs = trycoerce(node.lhs, types.Boolean(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Boolean(), errors)
                trhs = node.rhs._type
                node._type = context
            elseif types.is_truthy(tlhs) then
                node._type = trhs
            elseif types.is_falsy(tlhs) then
                node._type = tlhs
            else
                node.rhs = trycoerce(node.rhs, optionize(trhs), errors)
                trhs = node.rhs._type
                node._type = trhs
            end
        elseif op == "or" then
            if context and context._tag == "Type.Boolean" then
                -- convert everything to boolean if used in boolean context
                node.lhs = trycoerce(node.lhs, types.Boolean(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Boolean(), errors)
                trhs = node.rhs._type
                node._type = context
            elseif tlhs._tag == "Type.Boolean" or trhs._tag == "Type.Boolean" then
                -- tries to coerce to boolean if other side is boolean
                node.lhs = trycoerce(node.lhs, types.Boolean(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Boolean(), errors)
                trhs = node.rhs._type
                node._type = types.Boolean()
            elseif types.is_truthy(tlhs) then
                node._type = tlhs
            elseif types.is_falsy(tlhs) then
                node._type = trhs
            elseif tlhs._tag == "Type.Option" and types.equals(tlhs.base, trhs) then
                node._type = trhs
            elseif tlhs._tag == "Type.Option" and trhs._tag == "Type.Value" then
                node.lhs = trycoerce(node.lhs, types.Value(), errors)
                tlhs = node.lhs._type
                node._type = types.Value()
            elseif tlhs._tag == "Type.Value" then
                node.rhs = trycoerce(node.rhs, types.Value(), errors)
                trhs = node.rhs._type
                node._type = types.Value()
            else
                checker.typeerror(errors, loc,
                    "left hand side of 'or' is a %s but right hand side is a %s",
                    types.tostring(tlhs), types.tostring(trhs))
                node._type = types.Invalid()
            end
        elseif op == "|" or op == "&" or op == "~" or op == "<<" or op == ">>" then
            node.lhs = tryforce(node.lhs)
            tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs)
            trhs = node.rhs._type
            -- always tries to coerce floats to integer
            node.lhs = node.lhs._type._tag == "Type.Float" and trycoerce(node.lhs, types.Integer(), errors) or node.lhs
            tlhs = node.lhs._type
            -- always tries to coerce floats to integer
            node.rhs = node.rhs._type._tag == "Type.Float" and trycoerce(node.rhs, types.Integer(), errors) or node.rhs
            trhs = node.rhs._type
            if tlhs._tag ~= "Type.Integer" then
                checker.typeerror(errors, loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(tlhs))
            end
            if trhs._tag ~= "Type.Integer" then
                checker.typeerror(errors, loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(trhs))
            end
            node._type = types.Integer()
        else
            error("invalid binary operation " .. op)
        end
    end,

    ["Ast.ExpCall"] = function(node, st, errors, _)
        if node.exp._tag == "Ast.ExpVar" then
            local var = node.exp.var
            checkvar(var, st, errors)
            if var._decl then var._decl._used = true end
            node.exp._type = var._type
        else
            checkexp(node.exp, st, errors)
        end
        if node.args._tag == "Ast.ArgsFunc" then
            local ftype = node.exp._type
            if ftype._tag == "Type.Invalid" then
                node._type = ftype
                return
            end
            local fname = expname(node.exp)
            -- Auto-unwrap an option-of-function callee (e.g. an array element
            -- `arr[i]`, which has type `T?`): cast to the underlying function
            -- type. The cast codegen inserts a runtime nil-check, so calling
            -- through a nil option raises cleanly. Mirrors the option-receiver
            -- unwrap for method calls below.
            if ftype._tag == "Type.Option" and ftype.base._tag == "Type.Function" then
                local cast = ast.ExpCast(node.exp.loc, node.exp, ftype.base)
                cast._type = ftype.base
                node.exp = cast
                ftype = ftype.base
            end
            -- A callee may be a statically-known function (top-level function,
            -- record static, imported module function) or any function-typed
            -- value (a local/param, a returned function, ...). The coder tells
            -- the two apart; here we only require the callee to be a function.
            if ftype._tag ~= "Type.Function" then
                node._type = invalid(errors, node.loc,
                    "'%s' is not a function but %s",
                    fname, types.tostring(ftype))
                for _, arg in ipairs(node.args.args) do
                    checkexp(arg, st, errors)
                end
                return
            end
            checkargs(ftype, node.args.args, node.loc,
                "function '" .. fname .. "'", st, errors)
            node._types = ftype.rettypes
            -- A zero-return `() -> ()` callee produces no value; its result is
            -- `Type.Void`, which is only legal in statement position or inside
            -- an explicit `(f())` adjust (see Ast.ExpAdjust / Ast.StatCall).
            node._type = ftype.rettypes[1] or types.Void()
            if node._type._tag == "Type.Void" and not node._voidok then
                node._type = invalid(errors, node.loc,
                    "a function returning no values cannot be used as a value")
            end
        else
            assert(node.args._tag == "Ast.ArgsMethod")
            local otype = node.exp._type
            -- auto-unwrap an option receiver: p:m() on a Point? unwraps to the
            -- underlying record. The cast codegen inserts a runtime nil-check,
            -- so calling a method through a nil option raises a clean error.
            if otype._tag == "Type.Option" and otype.base._tag == "Type.Nominal" then
                local cast = ast.ExpCast(node.exp.loc, node.exp, otype.base)
                cast._type = otype.base
                node.exp = cast
                otype = otype.base
            end
            if otype._tag == "Type.Nominal" and
               types.registry[otype.fqtn] and
               types.registry[otype.fqtn]._tag == "Type.Record" then
                local class = types.registry[otype.fqtn]
                if not class.methods[node.args.method] then
                    node._type = invalid(errors, node.loc,
                        "method '%s' not found in record '%s'",
                        node.args.method, types.tostring(otype))
                    for _, arg in ipairs(node.args.args) do
                        checkexp(arg, st, errors)
                    end
                    return
                end
                local ftype = class.methods[node.args.method]
                checkargs(ftype, node.args.args, node.loc,
                    "method '" .. class.name .. ":" .. node.args.method .. "'", st, errors)
                node._method = ftype
                node._types = ftype.rettypes
                node._type = ftype.rettypes[1] or types.Void()
                if node._type._tag == "Type.Void" and not node._voidok then
                    node._type = invalid(errors, node.loc,
                        "a function returning no values cannot be used as a value")
                end
            else
                if otype._tag ~= "Type.Nominal" then
                    checker.typeerror(errors, node.loc,
                        "expected record in receiver of method call but found '%s'",
                        types.tostring(otype))
                elseif not types.registry[otype.fqtn] then
                    checker.typeerror(errors, node.loc,
                        "record type '%s' in receiver of method call does not exist",
                        types.tostring(otype))
                elseif types.registry[otype.fqtn]._tag ~= "Type.Record" then
                    checker.typeerror(errors, node.loc,
                        "expected record in receiver of method call but found '%s'",
                        types.tostring(types.registry[otype.fqtn]))
                end
                for _, arg in ipairs(node.args.args) do
                    checkexp(arg, st, errors)
                end
                node._type = invalid(errors, node.loc, "expected a record type")
            end
        end
    end,

    ["Ast.ExpCast"] = function(node, st, errors, _)
        node.target = typefromnode(node.target, st, errors)
        checkexp(node.exp, st, errors, node.target)
        local source = node.exp._type
        local target = node.target
        local ok
        if source._tag == "Type.Option" and types.equals(source.base, target) then
            -- explicit unwrap of an option to its base type; the cast codegen
            -- emits a runtime nil-check that raises if the value is nil
            ok = true
        else
            ok = (types.explicitly_coerceable(source, target) or
                  types.coerceable(source, target))
                 and types.compatible(source, target)
        end
        if not ok then
            checker.typeerror(errors, node.loc, "cannot cast '%s' to '%s'",
                types.tostring(source), types.tostring(target))
        end
        node._type = node.target
    end,

    ["Ast.ExpAdjust"] = function(node, st, errors, context)
        node.exp._voidok = true
        checkexp(node.exp, st, errors, context)
        if node.exp._type._tag == "Type.Void" then
            -- `(f())` on a zero-return call adjusts up to a single `nil`,
            -- mirroring Lua's parenthesized-call adjustment.
            node._type = types.Nil()
            node._adjustvoid = true
        else
            node._type = node.exp._type
        end
    end,

    -- Anonymous function expression (lambda). Both parameter and return types
    -- may be inferred from the expected function type (`context`): an unannotated
    -- parameter takes its type from the context, and a missing return annotation
    -- is likewise taken from the context. With no usable context the return type
    -- defaults to zero-return `()`, exactly like an unannotated top-level
    -- function.
    ["Ast.ExpFunction"] = function(node, st, errors, context)
        -- Checking mode iff the context is a function type whose arity matches.
        local expected = (context and context._tag == "Type.Function"
            and #context.params == #node.params) and context or nil

        -- Resolve parameter types.
        local paramtypes = {}
        for i, param in ipairs(node.params) do
            if param.type then
                param._type = typefromnode(param.type, st, errors)
            elseif expected then
                param._type = expected.params[i]
            else
                param._type = invalid(errors, param.loc,
                    "cannot infer type of parameter '%s'; annotate it or use "
                    .. "the lambda where its type is known", param.name)
            end
            paramtypes[i] = param._type
        end

        -- Resolve / set up return types. Like parameters, the return type comes
        -- only from the expected function type (`context`); it is never inferred
        -- from the body's `return`s.
        local rettypes
        if node.rettypes then
            -- Explicit annotation, including `: ()` (an empty list).
            rettypes = {}
            for _, rt in ipairs(node.rettypes) do
                table.insert(rettypes, typefromnode(rt, st, errors))
            end
        elseif expected then
            -- Checking mode: take the return types from the context.
            rettypes = expected.rettypes
        else
            -- No annotation, no usable context: default to zero-return `()`,
            -- exactly like an unannotated top-level function.
            rettypes = {}
        end

        node._type = types.Function(paramtypes, rettypes, false)

        -- Open the lambda's own block so `$function`/params do not leak into the
        -- enclosing scope (mirrors checkbodies+checkfunc). `with_block` keeps
        -- only the first return value, so open/close the block by hand to also
        -- recover the frame.
        st:open_block()
        local _, frame = checkfuncbody(node, st, errors)
        st:close_block()

        -- Save the ordered list of enclosing decls this lambda captures, for
        -- codegen (closure-creation pushes + lambda-body upvalue indexing).
        node._captures = frame.captures

        return node._type
    end,

    -- Bound method reference `obj:m` (no call): yields a function value, the
    -- method's type with the implicit `self` removed and the receiver captured.
    -- Mirrors the method-resolution of the ArgsMethod arm of ExpCall.
    ["Ast.ExpMethodRef"] = function(node, st, errors, _)
        checkexp(node.exp, st, errors)
        local otype = node.exp._type
        -- auto-unwrap an option receiver, like a method call does, so `p:m` on a
        -- Point? unwraps to the underlying record (the cast codegen nil-checks).
        if otype._tag == "Type.Option" and otype.base._tag == "Type.Nominal" then
            local cast = ast.ExpCast(node.exp.loc, node.exp, otype.base)
            cast._type = otype.base
            node.exp = cast
            otype = otype.base
        end
        if otype._tag == "Type.ForeignModule" then
            node._type = invalid(errors, node.loc,
                "a foreign (C) method cannot be used as a first-class value")
        elseif otype._tag == "Type.Nominal" and
           types.registry[otype.fqtn] and
           types.registry[otype.fqtn]._tag == "Type.Record" then
            local class = types.registry[otype.fqtn]
            local mtype = class.methods[node.name]
            if not mtype then
                node._type = invalid(errors, node.loc,
                    "method '%s' not found in record '%s'",
                    node.name, types.tostring(otype))
            else
                node._method = mtype
                node._type = types.Function(mtype.params, mtype.rettypes, false)
            end
        elseif otype._tag ~= "Type.Nominal" then
            node._type = invalid(errors, node.loc,
                "expected record in receiver of method reference but found '%s'",
                types.tostring(otype))
        elseif not types.registry[otype.fqtn] then
            node._type = invalid(errors, node.loc,
                "record type '%s' in receiver of method reference does not exist",
                types.tostring(otype))
        else
            node._type = invalid(errors, node.loc,
                "expected record in receiver of method reference but found '%s'",
                types.tostring(types.registry[otype.fqtn]))
        end
        return node._type
    end
})

--
-- TopLevel
--

-- Shared body-check for top-level functions, methods, and lambdas. Pushes a
-- function frame (so captures of enclosing locals are detected), declares the
-- parameters (stamping their nesting depth at this function's own depth), checks
-- the body, and enforces the all-paths-return rule. The caller is responsible
-- for having an open block and (for methods) declaring `self` before calling.
--   node: a node carrying `_type` (Function), `params`, `block`, and (for the
--         duplicate-parameter message) `name`. For lambdas, `node.rettypes` may
--         be `false`/a list; `node._type.rettypes` is authoritative here.
--   opts (optional): { self_decl = Decl }. Returns (ret, frame): `ret` is
--         whether the body always returns; `frame` carries `captures`.
function checkfuncbody(node, st, errors, opts)
    opts = opts or {}
    st:add_symbol("$function", node) -- for return type
    local frame = { depth = #func_stack + 1, captures = {}, capture_set = {} }
    table.insert(func_stack, frame)
    if opts.self_decl then
        -- `self` belongs to this function's own depth, so a lambda nested in a
        -- method captures it just like any other parameter.
        opts.self_decl._funcdepth = #func_stack
        st:add_symbol("self", opts.self_decl)
    end
    local ptypes = node._type.params
    local pnames = {}
    for i, rettype in ipairs(node._type.rettypes) do
        -- Report an invalid return type at the precise return-type node when one
        -- exists (top-level functions/methods); a lambda's `node.rettypes` may be
        -- `false` (inferred) or shorter, so fall back to the function location.
        local rloc = (node.rettypes and node.rettypes[i] and node.rettypes[i].loc)
            or node.loc
        checktype(rettype, rloc, errors)
    end
    -- A lambda (Ast.ExpFunction) has no `name`; describe it generically in the
    -- duplicate-parameter diagnostic instead of printing "function 'nil'".
    local fdesc = node.name and ("declaration of function '" .. node.name .. "'")
        or "anonymous function"
    for i, param in ipairs(node.params) do
        param._type = ptypes[i]
        param._funcdepth = #func_stack
        st:add_symbol(param.name, param)
        checktype(param._type, param.loc, errors)
        if pnames[param.name] then
            checker.typeerror(errors, node.loc,
                "duplicate parameter '%s' in %s", param.name, fdesc)
        else
            pnames[param.name] = true
        end
    end
    local ret = st:with_block(checkstat, node.block, st, errors)
    -- A zero-return `() -> ()` function (empty rettypes) may fall off the end,
    -- exactly like a `nil`-returning one; only a function whose first declared
    -- return type is some non-`nil` value must return on every path.
    local firstret = node._type.rettypes[1]
    if not ret and firstret and firstret._tag ~= "Type.Nil" then
        checker.typeerror(errors, node.loc,
            "function can return nil but return type is not nil")
    end
    table.remove(func_stack)
    return ret, frame
end

-- Typechecks a function body
--   node: TopLevelFunc AST node
--   st: symbol table
--   errors: list of compile-time errors
local function checkfunc(node, st, errors)
    checkfuncbody(node, st, errors)
end

-- Typechecks a method body, binding self to the first parameter
--   node: TopLevelMethod AST node
--   st: symbol table
--   errors: list of compile-time errors
local function checkmethod(node, st, errors)
    local self = ast.Decl(node.loc, "self", ast.TypeName(node.loc, node._record.name), false)
    node._self = self
    self._type = typefromnode(self.type, st, errors)
    -- `self` is declared into this method's own frame (inside checkfuncbody), so
    -- a lambda nested in the method body captures it like any parameter.
    checkfuncbody(node, st, errors, { self_decl = self })
end

-- Checks function bodies
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
local function checkbodies(ast, st, errors)
    for _, node in ipairs(ast) do
        if not node._ignore then
            if node._tag == "Ast.TopLevelFunc" then
                st:with_block(checkfunc, node, st, errors)
            elseif node._tag == "Ast.TopLevelMethod" then
                st:with_block(checkmethod, node, st, errors)
            elseif node._tag == "Ast.TopLevelStatic" then
                st:with_block(checkfunc, node, st, errors)
            elseif node._tag == "Ast.TopLevelRecord" then
                local fields = node._type.fields
                for i, field in ipairs(fields) do
                    local ftype = field.type
                    checktype(ftype, node.fields[i].loc, errors)
                end
            end
        end
    end
end

local function isconstructor(node)
    return node.var and node.var._decl and node.var._decl._tag == "Type.StaticMethod"
        and #node.var._decl.rettypes == 1
        and node.var._decl.rettypes[1]._tag == "Type.Nominal"
        and node.var._decl.rettypes[1].fqtn == node.var._decl.fqtn
end

-- Verify if an expression is constant
local function isconst(node)
    local tag = node._tag
    if tag == "Ast.ExpNil" or
       tag == "Ast.ExpBool" or
       tag == "Ast.ExpInteger" or
       tag == "Ast.ExpFloat" or
       tag == "Ast.ExpString" then
        return true

    elseif tag == "Ast.ExpInitList" then
        local const = true
        for _, field in ipairs(node.fields) do
            const = const and isconst(field.exp)
        end
        return const

    elseif tag == "Ast.ExpCall" then
        if isconstructor(node.exp) then
            local const = true
            for _, arg in ipairs(node.args) do
                const = const and isconst(arg)
            end
            return const
        else
            return false
        end

    elseif tag == "Ast.ExpVar" then
        return false

    elseif tag == "Ast.ExpConcat" then
        local const = true
        for _, exp in ipairs(node.exps) do
            const = const and isconst(exp)
        end
        return const

    elseif tag == "Ast.ExpUnop" then
        return isconst(node.exp)

    elseif tag == "Ast.ExpBinop" then
        return isconst(node.lhs) and isconst(node.rhs)

    elseif tag == "Ast.ExpCast" then
        return isconst(node.exp)

    elseif tag == "Ast.ExpFunction" then
        -- `isconst` here gates top-level (module) variable initializers, whose
        -- real requirement is soundness: an initializer runs during module init
        -- in declaration order, so it must not read a not-yet-initialized module
        -- variable's value. Constructing a lambda reads no module variable's
        -- value — the body executes only when the closure is later called — so a
        -- lambda is always a sound top-level initializer. (This also enables a
        -- module-level `local f = function ... end`: a module *variable* holding
        -- a function, so calls to `f` go through the first-class value-call path
        -- and `f` can be reassigned at runtime — a runtime-replaceable module
        -- function, at the cost of static dispatch.)
        return true

    elseif tag == "Ast.ExpMethodRef" then
        -- Binding `obj:method` evaluates the receiver `obj` now (at init time) to
        -- capture self, so it is a sound top-level initializer exactly when
        -- reading the receiver is sound.
        return isconst(node.exp)

    else
        error("impossible")
    end
end

-- Return the name given the toplevel node
local function toplevel_name(node)
    local tag = node._tag
    if tag == "Ast.TopLevelImport" then
        return node.localname
    elseif tag == "Ast.TopLevelForeignImport" then
        return node.localname
    elseif tag == "Ast.TopLevelVar" then
        return node.decl.name
    elseif tag == "Ast.TopLevelFunc" or
           tag == "Ast.TopLevelRecord" then
        return node.name
    elseif tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic" then
        return nil
    else
        error("tag not found " .. tag)
    end
end

-- Typecheck the toplevel node
local toplevel_visitor = util.make_visitor({
    ["Ast.TopLevelImport"] = function(node, _, errors, loader)
        local modtype, errs = checker.checkimport(node.modname, loader)
        if modtype then
            node._type = modtype
            for _, err in ipairs(errs) do
                table.insert(errors, err)
            end
        else
            node._type = invalid(errors, node.loc,
                "problem loading module '%s': %s",
                node.modname, errs)
        end
    end,

    ["Ast.TopLevelForeignImport"] = function(node, st, errors)
        local name = node.headername
        local ftypes, defines = cdriver.process_file(name)
        if ftypes then
            local members = {}
            for _, item in ipairs(ftypes) do
                local fname = item.name
                local ftype = item.type
                local decl = foreigntypes.convert(st, ftype)
                if decl then
                    members[fname] = types.ModuleMember(name, fname, decl)
                    st:add_foreign_type(fname, decl)
                end
                -- else: the member uses an unsupported C type; skip it so the
                -- rest of the header still imports. Referencing a skipped
                -- member is then a clean "not a member" error, never a crash.
            end
            local modtype = types.ForeignModule(name, members)
            node._type = modtype
        else
            node._type = types.Nil()
            checker.typeerror(errors, node.loc, defines)
        end
        st:add_symbol(node.localname, node)
    end,

    ["Ast.TopLevelVar"] = function(node, st, errors)
        if node.decl.type then
            node._type = typefromnode(node.decl.type, st, errors)
            checkexp(node.value, st, errors, node._type)
            node.value = trycoerce(node.value, node._type, errors)
            checkmatch("declaration of module variable " .. node.decl.name,
                       node._type, node.value._type, errors, node.loc)
        elseif node.decl.option then
            checkexp(node.value, st, errors)
            node._type = optionize(node.value._type)
            node.value = trycoerce(node.value, node._type, errors)
        else
            checkexp(node.value, st, errors)
            node.value = tryforce(node.value)
            node._type = node.value._type
        end
        if not isconst(node.value) then
            checker.typeerror(errors, node.value.loc,
                "top level variable initialization must be constant")
        end
    end,

    ["Ast.TopLevelFunc"] = function(node, st, errors)
        local ptypes = {}
        for _, pdecl in ipairs(node.params) do
            table.insert(ptypes, typefromnode(pdecl.type, st, errors))
        end
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        node._type = types.Function(ptypes, rettypes, false)
    end,

    ["Ast.TopLevelRecord"] = function(node, st, errors)
        local fields = {}
        local nameset = {}
        local fqtn = st.modname .. "." .. node.name
        local ftypes = {}
        for i, field in ipairs(node.fields) do
            if nameset[field.name] then
                checker.typeerror(errors, field.loc,
                "redeclaration of field '%s' in record '%s'",
                field.name, node.name)
            else
                nameset[field.name] = true
                local ftype = typefromnode(field.type, st, errors)
                table.insert(ftypes, ftype)
                -- 0-based field index: a record instance is a Udata whose
                -- user values hold the fields directly (uv[0..N-1]); Lua never
                -- sees these indices, so there is no reserved uv[0].
                table.insert(fields,
                    types.Field(fqtn, field.name, ftype, i - 1))
            end
        end
        node._type = types.Record(fqtn, fields, {}, {})
        types.registry[fqtn] = node._type
    end,

    ["Ast.TopLevelStatic"] = function(node, st, errors)
        local record = st:find_symbol(node.class)
        if not record then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "record referenced by static method declaration '%s.%s' does not exist",
                node.class, node.name)
            return
        end
        if record._tag ~= "Ast.TopLevelRecord" then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "member referenced by static method declaration '%s.%s' is not a record",
                node.class, node.name)
            return
        end
        local rectype = record._type
        for _, field in ipairs(rectype.fields) do
            if field.name == node.name then
                node._ignore = true
                checker.typeerror(errors, node.loc,
                "cannot declare static method '%s.%s' as field '%s' exists in record '%s'",
                    node.class, node.name, field.name, node.class)
                return
            end
        end
        if rectype.methods[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "cannot declare static method '%s.%s' as method '%s:%s' exists in record '%s'",
                    node.class, node.name, node.class, node.name, node.class)
            return
        end
        if rectype.functions[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "redeclaration of static method '%s.%s'", node.class, node.name)
            return
        end
        node._record = record
        local ptypes = {}
        for _, pdecl in ipairs(node.params) do
            table.insert(ptypes, typefromnode(pdecl.type, st, errors))
        end
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        node._type = types.StaticMethod(rectype.name, node.name, ptypes, rettypes)
        rectype.functions[node.name] = node._type
    end,

    ["Ast.TopLevelMethod"] = function(node, st, errors)
        local record = st:find_symbol(node.class)
        if not record then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "record referenced by method declaration '%s:%s' does not exist",
                node.class, node.name)
            return
        end
        if record._tag ~= "Ast.TopLevelRecord" then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "member referenced by method declaration '%s:%s' is not a record",
                node.class, node.name)
            return
        end
        local rectype = record._type
        for _, field in ipairs(rectype.fields) do
            if field.name == node.name then
                node._ignore = true
                checker.typeerror(errors, node.loc,
                "cannot declare method '%s:%s' as field '%s' exists in record '%s'",
                    node.class, node.name, field.name, node.class)
                return
            end
        end
        if rectype.functions[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "cannot declare method '%s:%s' as static method '%s.%s' exists in record '%s'",
                    node.class, node.name, node.class, node.name, node.class)
            return
        end
        if rectype.methods[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "redeclaration of method '%s:%s'", node.class, node.name)
            return
        end
        node._record = record
        local ptypes = {}
        for _, pdecl in ipairs(node.params) do
            table.insert(ptypes, typefromnode(pdecl.type, st, errors))
        end
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        node._type = types.Method(rectype.name, node.name, ptypes, rettypes)
        rectype.methods[node.name] = node._type
    end,
})

-- Colect type information of toplevel nodes
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
--   annotates the top-level nodes with their types in a "_type" field
--   annotates whether a top-level declaration is duplicated with a "_ignore"
--   field
local function checktoplevel(ast, st, errors, loader)
    for _, node in ipairs(ast) do
        local name = toplevel_name(node)
        local dup = name and st:find_dup(name)
        if dup then
            checker.typeerror(errors, node.loc,
                "duplicate declaration for %s, previous one at line %d",
                name, dup.loc.line)
            node._ignore = true
        else
            toplevel_visitor(node, st, errors, loader)
            if name and not node._ignore then
                st:add_symbol(name, node)
            end
        end
    end
end

function checker.has_main(ast)
    for _, node in ipairs(ast) do
        local name = toplevel_name(node)
        if name == "main"
           and node._tag == "Ast.TopLevelFunc"
           and #node.params == 1
           and node.params[1]._type._tag == "Type.Array"
           and node.params[1]._type.elem._tag == "Type.String"
           and #node.rettypes == 1
           and node.rettypes[1]._tag == "Ast.TypeInteger" then
            return true
        end
    end
    return false
end

-- Walk a recovered interface type and, for every Nominal that names a record of
-- *another* module which is not yet registered, recover that module so its
-- record definition registers too. This makes record types resolve transitively
-- across `.so`-only imports (a module's interface may return/accept a record
-- defined in a module it imported but that this importer does not import
-- directly). `seen` guards against revisiting a type and against cycles; the
-- registry itself is the cross-call memo. Load failures are ignored — the
-- nominal simply stays unresolved, exactly as before this pass existed.
local function register_referenced_records(t, loader, seen)
    if type(t) ~= "table" or not t._tag or seen[t] then return end
    seen[t] = true
    local tag = t._tag
    if tag == "Type.Nominal" then
        if not types.registry[t.fqtn] then
            local mod = t.fqtn:match("^(.*)%.[^.]+$")
            if mod and mod ~= "" then
                pcall(checker.checkimport, mod, loader)
            end
        end
    elseif tag == "Type.Array" then
        register_referenced_records(t.elem, loader, seen)
    elseif tag == "Type.Map" then
        register_referenced_records(t.keys, loader, seen)
        register_referenced_records(t.values, loader, seen)
    elseif tag == "Type.Option" then
        register_referenced_records(t.base, loader, seen)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable" then
        register_referenced_records(t.type, loader, seen)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        for _, p in ipairs(t.params or {}) do
            register_referenced_records(p, loader, seen)
        end
        for _, r in ipairs(t.rettypes or {}) do
            register_referenced_records(r, loader, seen)
        end
    elseif tag == "Type.Record" then
        for _, f in ipairs(t.fields or {}) do
            register_referenced_records(f.type, loader, seen)
        end
    end
end

function checker.checkimport(modname, loader)
    local ok, type_or_error, errors = loader(modname)
    if not ok then return nil, type_or_error end
    for _, member in ipairs(type_or_error.members) do
        -- Exported records arrive wrapped in a Type.ModuleMember; unwrap so
        -- the record's nominal type is registered for `.so`-only imports too
        -- (the source-import path registers it as a side effect of checking).
        local t = member.type or member
        if t and (t._tag == "Type.Record" or t._tag == "Type.Interface") then
            types.registry[t.name] = t
        end
    end
    local seen = {}
    for _, member in ipairs(type_or_error.members) do
        register_referenced_records(member.type or member, loader, seen)
    end
    return type_or_error, errors
end

-- Builds a type for the module from the types of its public members
--   modast: AST for the module
--   returns "Type.Module" type
local function makemoduletype(modname, modast)
    local members = {}
    for _, tlnode in ipairs(modast) do
        if tlnode._tag ~= "Ast.TopLevelImport" and not tlnode.islocal and not tlnode._ignore then
            local tag = tlnode._tag
            if tag == "Ast.TopLevelVar" then
                table.insert(members, types.ModuleVariable(modname, tlnode.decl.name, tlnode._type))
            elseif tag == "Ast.TopLevelFunc" or tag == "Ast.TopLevelRecord" then
                table.insert(members, types.ModuleMember(modname, tlnode.name, tlnode._type))
            end
        end
    end
    return types.Module(modname, members)
end


-- Entry point for the typechecker
--   ast: AST for the whole module
--   subject: the string that generated the AST
--   filename: the file name that contains the subject
--   loader: the module loader, a function from module name to its AST, code,
--   and filename or nil and an error
--
--   returns true if typechecking succeeds, or false and a list of type errors
--   found
--   annotates the AST with the types of its terms in "_type" fields
--   annotates duplicate top-level declarations with a "_ignore" boolean field
function checker.check(modname, ast, subject, filename, loader)
    loader = loader or function ()
        return nil, "you must pass a loader to import modules"
    end
    func_stack = {}
    local st = symtab.new(modname)
    local errors = {subject = subject, filename = filename}
    checktoplevel(ast, st, errors, loader)
    checkbodies(ast, st, errors)
    ast._type = makemoduletype(modname, ast)
    return ast._type, errors
end

return checker
