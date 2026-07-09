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

-- Error-handling context counters (B.2), mirroring `loop_depth`: each is bumped
-- only while checking the relevant block and is saved/reset to 0 across every
-- nested function body (see `checkfuncbody`) and at `checker.check` entry, so a
-- `raise`/`return`/`break` in a lambda is governed by the lambda, not by an
-- enclosing catch/finally.
--   catch_depth         -- > 0 while inside a `catch` block (bare-`raise` legality)
--   in_finally          -- > 0 while inside a `finally` block (no `return`/escaping
--                          `break` may leave it)
--   finally_loop_floor  -- the `loop_depth` on entry to the innermost finally; a
--                          `break` is finally-escaping iff `loop_depth` has not
--                          risen above it (no loop opened inside the finally)
local catch_depth = 0
local in_finally = 0
local finally_loop_floor = 0

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
    local ok
    if types.is_c(expected) or types.is_c(found) then
        ok = types.equals(types.resolve_c_typedef(expected),
            types.resolve_c_typedef(found))
    else
        ok = types.compatible(expected, found)
    end
    if types.coerceable(found, expected) or not ok then
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

-- Validate a variadic parameter / function-type element type `t` (the type of
-- each `...` element). Bans a `nil` element (a typed `...: t` cannot hold nil) and
-- a foreign (C FFI) pointer element (no `TitanVarg*` struct exists for it, §2.F).
-- Returns the original type when legal, or `types.Invalid()` after reporting.
local function check_vararg_elem(t, loc, errors)
    if t._tag == "Type.Nil" then
        checker.typeerror(errors, loc,
            "a variadic parameter cannot have type nil")
        return types.Invalid()
    elseif t._tag == "Type.Pointer"
           or types.resolve_c_typedef(t)._tag == "Type.CPointer" then
        checker.typeerror(errors, loc,
            "a variadic parameter cannot have a foreign pointer type")
        return types.Invalid()
    end
    return t
end

-- Resolve the fixed parameter types of a function/method/static/lambda and, if
-- the last `Ast.Decl` is the trailing vararg marker (`name == false`), drop it
-- from the fixed list and return its (validated) element type as the second
-- value. `params` is the AST param list; this is the single place the signature
-- pass + lambda checker turn the parser's vararg encoding into a `varargtype`.
--   returns (ptypes, varargtype) where varargtype is a type or false.
local function param_types(params, st, errors)
    local ptypes = {}
    local varargtype = false
    local n = #params
    for i, pdecl in ipairs(params) do
        if i == n and pdecl.name == false then
            varargtype = check_vararg_elem(
                typefromnode(pdecl.type, st, errors), pdecl.loc, errors)
        else
            table.insert(ptypes, typefromnode(pdecl.type, st, errors))
        end
    end
    return ptypes, varargtype
end

-- Resolve the in-scope `...` for a `...`/`#...`/`...[e]` use. Returns the
-- element type `t`, or `types.Invalid()` after reporting. Enforces both that the
-- enclosing function is variadic and scope rule 4: `$vararg` is depth-stamped, so
-- a use from an inner lambda (a deeper `#func_stack`) finds the symbol but is
-- rejected — `...` is invisible across a function boundary, unlike ordinary
-- lexical scoping.
local function resolve_vararg(st, loc, errors)
    local vararg = st:find_symbol("$vararg")
    if not vararg then
        return invalid(errors, loc,
            "'...' can only be used inside a variadic function")
    elseif vararg.funcdepth ~= #func_stack then
        return invalid(errors, loc,
            "'...' is not visible inside an inner function")
    end
    return vararg.elem
end

-- Resolve `$vararg` for a trailing `Ast.ExpDots` that a consuming explist loop
-- (§4.6) or array constructor (§4.7) is about to expand, stamping its element
-- type on `_vararg_elem`. Unlike the `ExpDots` checkexp arm, this does NOT report
-- the "bare `...`" error — the node IS in a legal trailing position here.
local function check_dots_marker(node, st, errors)
    node._vararg_elem = resolve_vararg(st, node.loc, errors)
    node._type = node._vararg_elem
end

local function is_foreign_type_declaration(ftype)
    return ftype.type == "typedef" or
           ftype.type == "struct" or
           ftype.type == "union"
end

local function is_foreign_ordinary_identifier(name, ftype)
    if ftype.type == "enum" then
        return not name:match("^enum@")
    end
    return ftype.type == "typedef"
        or not (ftype.type == "struct"
                or ftype.type == "union"
                or ftype.type == "enum")
end

local function c_resolve(t)
    return types.resolve_c_typedef(t)
end

local function is_c_type_namespace(exp)
    return exp._tag == "Ast.ExpVar"
        and exp.var
        and exp.var._ctype_namespace
end

local function c_owned_type(typ, has_count)
    return types.COwned(typ, has_count and true or false)
end

local function c_function_pointer_type(typ)
    typ = c_resolve(typ)
    if typ and typ._tag == "Type.CPointer" then
        local pointee = c_resolve(typ.pointee)
        if pointee._tag == "Type.CFunction" then
            return pointee
        end
    end
end

local function c_function_as_function_type(cfunc)
    local ret = c_resolve(cfunc.ret)
    local rettypes = ret._tag == "Type.CVoid" and {} or { cfunc.ret }
    return types.Function(cfunc.params, rettypes, cfunc.vararg, false)
end

local function c_function_pointer_accepts_function(target, ftype)
    local cfunc = c_function_pointer_type(target)
    return cfunc and types.equals(c_function_as_function_type(cfunc), ftype)
end

local function is_foreign_function_var(var)
    return var and var._tag == "Ast.VarDot"
        and var.exp and var.exp._type
        and var.exp._type._tag == "Type.CModule"
end

local function c_pseudo_member(typ, name)
    if name == "new" then
        return {
            _tag = "Type.CPseudoNew",
            ctype = typ,
            name = name,
            type = types.Function({}, { c_owned_type(typ, false) }, false, false),
        }
    elseif name == "new_array" then
        return {
            _tag = "Type.CPseudoNew",
            ctype = typ,
            name = name,
            array = true,
            type = types.Function({ types.Integer() },
                { c_owned_type(typ, true) }, false, false),
        }
    elseif name == "sizeof" or name == "alignof" then
        return {
            _tag = "Type.CPseudoSize",
            ctype = typ,
            name = name,
            type = types.Integer(),
        }
    end
end

local function c_field_decl(typ, name)
    typ = c_resolve(typ)
    if typ._tag == "Type.CPointer" then
        typ = c_resolve(typ.pointee)
    elseif typ._tag == "Type.COwned" then
        typ = c_resolve(typ.pointee)
    end
    if (typ._tag == "Type.CStruct" or typ._tag == "Type.CUnion")
       and typ.fields and typ.fields[name] then
        return typ.fields[name]
    end
end

local function c_index_elem_type(typ)
    typ = c_resolve(typ)
    if typ._tag == "Type.CPointer" then
        return c_resolve(typ.pointee), "C pointer indexing"
    elseif typ._tag == "Type.CArray" then
        if type(typ.len) ~= "number" then
            return nil, nil,
                "cannot index C array with unknown length in this FFI version"
        end
        return c_resolve(typ.elem), "C array indexing"
    elseif typ._tag == "Type.COwned" and typ.count then
        return c_resolve(typ.pointee), "owned C array indexing"
    end
end

local function has_c_length(typ)
    typ = c_resolve(typ)
    return typ._tag == "Type.CArray"
        and type(typ.len) == "number"
        or (typ._tag == "Type.COwned" and typ.count)
end

local function c_allocation_error(typ)
    local rtyp = c_resolve(typ)
    if rtyp._tag == "Type.CVoid" then
        return "cannot allocate C void type in this FFI version"
    elseif rtyp._tag == "Type.CStruct" and not rtyp.complete then
        return string.format(
            "cannot allocate incomplete C struct type '%s' in this FFI version",
            types.tostring(rtyp))
    elseif rtyp._tag == "Type.CUnion" and not rtyp.complete then
        return string.format(
            "cannot allocate incomplete C union type '%s' in this FFI version",
            types.tostring(rtyp))
    elseif rtyp._tag == "Type.CStruct" and rtyp.has_fam then
        return string.format(
            "cannot allocate C struct type '%s' with a flexible array member in this FFI version",
            types.tostring(rtyp))
    elseif rtyp._tag == "Type.CArray" then
        return "cannot allocate C array typedefs in this FFI version"
    end
end

local function lua_state_pointer_type(st)
    local lua_state = st:find_foreign_type("lua_State")
        or st:find_foreign_type("struct@lua_State")
        or types.CTypedef("lua_State",
            types.CStruct(nil, "lua_State", nil, {}, false, false))
    return types.CPointer(
        lua_state,
        {})
end

local function module_udata_pointer_type(st)
    local udata = st:find_foreign_type("Udata")
        or st:find_foreign_type("struct@Udata")
        or types.CTypedef("Udata",
            types.CStruct(nil, "Udata", nil, {}, false, false))
    return types.CPointer(
        udata,
        {})
end

local function record_module(fqtn)
    return fqtn:match("^(.*)%.[^.]+$")
end

local function is_record_visible_from(st, fqtn)
    local record = types.registry[fqtn]
    return record and (not record.islocal or record_module(fqtn) == st.modname)
end

local function is_record_member_visible_from(st, member)
    return not member.islocal or record_module(member.fqtn) == st.modname
end

local function visible_record_fields(record, st)
    local out = {}
    for _, field in ipairs(record.fields) do
        if is_record_member_visible_from(st, field) then
            table.insert(out, field)
        end
    end
    return out
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
            local member = mod._type.members[node.name]
            if not member then
                return invalid(errors, node.loc,
                    "type '%s' not found inside module '%s'",
                    node.name, mod._type.name)
            elseif member.type._tag ~= "Type.Record" then
                return invalid(errors, node.loc,
                    "member '%s' inside module '%s' is not a record type",
                    node.name, mod._type.name)
            elseif not is_record_visible_from(st, fqtn) then
                return invalid(errors, node.loc,
                    "record type '%s' is local to module '%s'",
                    node.name, mod._type.name)
            end
            return types.Nominal(fqtn)
        elseif mod and mod._type._tag == "Type.CModule" then
            local typ = mod._type.type_members and mod._type.type_members[node.name]
            if typ then
                return typ
            end
            return invalid(errors, node.loc,
                "C type '%s' not found inside foreign module '%s'",
                node.name, mod._type.name)
        end
        return invalid(errors, node.loc, "module '%s' referenced by type not found", node.module)
    end,

    ["Ast.TypeCPointer"] = function(node, st, errors)
        local pointee = typefromnode(node.subtype, st, errors)
        if not types.is_c(pointee) then
            return invalid(errors, node.loc,
                "C pointer type can only point to a C FFI type, not '%s'",
                types.tostring(pointee))
        end
        return types.CPointer(pointee, node.const and { "const" } or {})
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
        -- A first-class variadic function type `(P..., ...: t) -> (R...)` carries
        -- its element type node on `node.varargtype` (false when absent); set
        -- the resulting Type.Function's `varargtype` slot accordingly.
        local varargtype = node.varargtype
            and check_vararg_elem(typefromnode(node.varargtype, st, errors),
                                  node.varargtype.loc, errors)
            or false
        return types.Function(ptypes, rettypes, false, varargtype)
    end,

    ["Ast.TypeOption"] = function(node, st, errors)
        return optionize(typefromnode(node.basetype, st, errors))
    end
})

-- tries to coerce node to target type
--    node: expression node
--    target: target type
--    returns node wrapped in a coercion, or original node
local function is_mutable_c_address_source(source)
    if source._tag ~= "Ast.ExpVar" or source.var._tag ~= "Ast.VarName" then
        return false
    end
    local decl = source.var._decl
    return decl and decl._tag == "Ast.Decl"
        and not decl._captured
        and types.is_c(source._type)
end

local function mark_mutable_c_address_source(source)
    if source._tag == "Ast.ExpVar" and source.var._tag == "Ast.VarName"
       and source.var._decl then
        source.var._decl._assigned = true
        source.var._decl._c_address_taken = source.loc
    end
end

local function trycoerce(source, target, errors)
    if is_mutable_c_address_source(source)
       and types.c_mutable_address_coerceable(source._type, target)
       and not types.c_address_coerceable(source._type, target) then
        mark_mutable_c_address_source(source)
        local n = ast.ExpCast(source.loc, source, target)
        n._type = target
        return n
    elseif types.coerceable(source._type, target) then
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

-- Adjust-up expansion of a trailing `...` into a fixed-arity context (a `local`,
-- an assignment, a `return`, or a call to a NON-variadic callee). `exps` is the
-- expression list, already with the trailing `Ast.ExpDots` at its end and every
-- entry already `checkexp`'d. `nslots` is the number of target positions;
-- `slottype(i)` returns the declared type of slot `i` (or nil when a slot's type
-- is unknown — e.g. an inferred `local`, where the element type is used). The
-- trailing `...` is replaced in place by `deficit = nslots - (#exps - 1)`
-- synthesized `Ast.ExpDotsIndex` nodes reading `...[1..deficit]`, with per-element
-- out-of-range mode following the slot's optionality:
--   optional `s?`     -> _nilfill = true,  _type = s? (out-of-range nil-fills);
--   non-optional `t`  -> _nilfill = false, _type = t  (out-of-range raises).
-- The synthesized nodes carry their `_type`/`_nilfill`; the caller's existing
-- coerce/checkmatch loop then coerces each against its slot exactly like any
-- other expression. `deficit < 0` is a compile error (too many values for the
-- slots); `deficit == 0` is a legal no-op (the `...` is simply dropped). `term`
-- names the context for the over-supply diagnostic.
local function expand_dots_adjustup(exps, nslots, slottype, term, errors, nilfill_slot)
    local dotsnode = table.remove(exps) -- pop the trailing ExpDots
    local elem = dotsnode._vararg_elem
    local nstatic = #exps
    local deficit = nslots - nstatic
    if deficit < 0 then
        checker.typeerror(errors, dotsnode.loc,
            "%s expects %d value(s) but the expression list (with '...') "
            .. "already supplies %d", term, nslots, nstatic)
        return
    end
    for k = 1, deficit do
        local slotidx = nstatic + k
        local stype = slottype(slotidx)
        local idxexp = ast.ExpInteger(dotsnode.loc, k)
        idxexp._type = types.Integer()
        local node = ast.ExpDotsIndex(dotsnode.loc, idxexp)
        local nilfill = nilfill_slot and nilfill_slot(stype)
            or (stype and stype._tag == "Type.Option")
        if nilfill then
            -- Nil-fill out-of-range. Type the read as the REAL element wrapped
            -- (`optionize(elem)`), NOT the slot type, so the caller's
            -- trycoerce/checkmatch inserts the genuine element->base conversion
            -- (e.g. integer? -> float?) and rejects an incompatible element
            -- (e.g. integer into a string? slot). Force-setting the slot type
            -- here would make trycoerce a no-op and bit-reinterpret the element
            -- in codegen.
            node._nilfill = true
            node._type = optionize(elem)
        else
            node._nilfill = false
            node._type = elem
        end
        table.insert(exps, node)
    end
end

local function nil_can_adjust_to(typ)
    return typ and (types.coerceable(types.Nil(), typ)
        or types.compatible(typ, types.Nil()))
end

local function append_missing_nil_args(args, nparams, loc, fname, errors, ftype)
    for i = #args + 1, nparams do
        local ptype = ftype.params[i]
        local exp = ast.ExpNil(loc)
        exp._type = types.Nil()
        exp = trycoerce(exp, ptype, errors)
        table.insert(args, exp)
        checkmatch("argument " .. i .. " of call to " .. fname,
            ptype, exp._type, errors, loc)
    end
end

-- Find a `...` field in an `ExpInitList` (a key-less field whose expression is a
-- bare `Ast.ExpDots`). Returns (field, index) or nil. Reports an error and
-- returns nil if a `...` field exists but is not the last field (`{..., 1}`):
-- `...` consumes the whole runtime tail, so nothing may follow it.
local function find_dots_field(node, errors)
    for i, field in ipairs(node.fields) do
        if not field.name and field.exp._tag == "Ast.ExpDots" then
            if i ~= #node.fields then
                checker.typeerror(errors, field.loc,
                    "'...' must be the last field in an array constructor")
                return nil
            end
            return field, i
        end
    end
    return nil
end

--
-- Decl
--

checkdecl = function(node, st, errors)
    node._type = node._type or typefromnode(node.type, st, errors)
    checktype(node._type, node.loc, errors)
end

local function declare(node, st, errors)
    local builtin = st:find_symbol(node.name)
    if builtin and builtin._readonly then
        checker.typeerror(errors, node.loc,
            "cannot declare local '%s' because it shadows a built-in local",
            node.name)
    end
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
    declare(node.decl, st, errors)
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

local function hidden_decl(loc, name, typ)
    local decl = ast.Decl(loc, name, false, false)
    decl._type = typ
    decl._used = true
    return decl
end

local function hidden_exp(loc, decl)
    local var = ast.VarName(loc, decl.name)
    var._decl = decl
    var._type = decl._type
    local exp = ast.ExpVar(loc, var)
    exp._type = decl._type
    return exp
end

local function nil_exp(loc)
    local exp = ast.ExpNil(loc)
    exp._type = types.Nil()
    return exp
end

local function expand_trailing_multireturn(exps)
    local lastexp = exps[#exps]
    if lastexp and lastexp._types and #lastexp._types > 1 then
        for i = 2, #lastexp._types do
            table.insert(exps, ast.ExpExtra(lastexp.loc, lastexp, i, lastexp._types[i]))
        end
    end
end

local function forin_dots_target(exps)
    local prefix = #exps - 1
    local target = 4
    local ftype = exps[1] and exps[1]._type
    local cfunc = ftype and c_function_pointer_type(ftype)
    if cfunc then
        ftype = c_function_as_function_type(cfunc)
    end
    if ftype and ftype._tag == "Type.Function" then
        target = math.max(prefix + 1, 1 + math.min(#ftype.params, 2))
        if target > 4 then target = 4 end
    end
    return target
end

local function forin_tuple_slottype(exps, i)
    local ftype = exps[1] and exps[1]._type
    local cfunc = ftype and c_function_pointer_type(ftype)
    if cfunc then
        ftype = c_function_as_function_type(cfunc)
    end
    if not (ftype and ftype._tag == "Type.Function") then
        return nil
    elseif i == 2 then
        return ftype.params[1] or types.Nil()
    elseif i == 3 then
        return ftype.params[2] or types.Nil()
    else
        return nil
    end
end

local function check_forin_decl_init(decl, exp, st, errors)
    if decl.type then
        checkdecl(decl, st, errors)
        exp = trycoerce(exp, decl._type, errors)
    elseif decl.option then
        decl._type = optionize(exp._type)
        checkdecl(decl, st, errors)
        exp = trycoerce(exp, decl._type, errors)
    else
        exp = tryforce(exp)
        decl._type = exp._type
        checkdecl(decl, st, errors)
    end
    checkmatch("generic for variable " .. decl.name,
        decl._type, exp._type, errors, decl.loc)
    return exp
end

local function forin_ftype_from_slot_type(typ)
    local cfunc = c_function_pointer_type(typ)
    if cfunc then
        return c_function_as_function_type(cfunc), cfunc
    elseif typ._tag == "Type.Function" then
        return typ, nil
    end
end

local function function_type_as_c_pointer(ftype)
    if #ftype.rettypes > 1 or ftype.varargtype then
        return nil
    end
    local ret = ftype.rettypes[1] or types.CVoid()
    return types.CPointer(types.CFunction(ftype.params, ret, ftype.vararg, false), {})
end

local function check_forin_callable_exp(exp, st, errors)
    if exp._tag == "Ast.ExpVar" and exp.var._tag == "Ast.VarDot" then
        checkvar(exp.var, st, errors)
        if exp.var._decl then exp.var._decl._used = true end
        local ftype = exp.var._type
        if exp.var.exp and exp.var.exp._type
           and exp.var.exp._type._tag == "Type.CModule"
           and ftype._tag == "Type.Function" then
            local target = function_type_as_c_pointer(ftype)
            if target then
                exp._type = target
                exp._foreign_function_pointer = exp.var.name
            else
                exp._type = invalid(errors, exp.loc,
                    "a foreign (C) function with this signature cannot be used as a generic for callable")
            end
            return
        end
    end
    checkexp(exp, st, errors)
end

local function forin_decl_return_type(decl, index, st, errors)
    local typ
    if decl.type then
        decl._type = decl._type or typefromnode(decl.type, st, errors)
        typ = decl._type
    else
        typ = types.Value()
    end
    if index == 1 then
        return optionize(typ)
    else
        return typ
    end
end

local function synthesize_forin_iterator_type(node, st, errors)
    local exps = node.exps
    local params = {}
    if exps[3]._type._tag ~= "Type.Nil" then
        table.insert(params, exps[2]._type)
        table.insert(params, exps[3]._type)
    elseif exps[2]._type._tag ~= "Type.Nil" then
        table.insert(params, exps[2]._type)
    end

    local rettypes = {}
    for i, decl in ipairs(node.decls) do
        table.insert(rettypes, forin_decl_return_type(decl, i, st, errors))
    end
    return types.Function(params, rettypes, false, false)
end

local function synthesize_forin_close_type(exps)
    local params = {}
    if exps[2]._type._tag ~= "Type.Nil" then
        table.insert(params, exps[2]._type)
    end
    return types.Function(params, {}, false, false)
end

local function forin_nil_capable_control(typ)
    local rtyp = c_resolve(typ)
    return typ._tag == "Type.Option"
        or typ._tag == "Type.Value"
        or typ._tag == "Type.Invalid"
        or types.is_c_tvalue(typ)
        or (rtyp and rtyp._tag == "Type.CPointer")
end

local function make_forin_call(loc, iter_decl, args, rettypes, cfunc)
    local call = ast.ExpCall(loc, hidden_exp(loc, iter_decl),
        ast.ArgsFunc(loc, args))
    call._types = rettypes
    call._type = rettypes[1] or types.Void()
    call._c_pointer_call = cfunc
    return call
end

local function checkforin(node, st, errors)
    local exps = node.exps
    local lastexp = exps[#exps]
    local dots = lastexp and lastexp._tag == "Ast.ExpDots"
    for i, exp in ipairs(exps) do
        if not (dots and i == #exps) then
            if i == 1 or i == 4 then
                check_forin_callable_exp(exp, st, errors)
            else
                checkexp(exp, st, errors)
            end
        end
    end
    if dots then
        check_dots_marker(lastexp, st, errors)
        expand_dots_adjustup(exps, forin_dots_target(exps),
            function(i) return forin_tuple_slottype(exps, i) end,
            "generic for iterator tuple", errors, nil_can_adjust_to)
    else
        expand_trailing_multireturn(exps)
    end
    if #exps > 4 then
        checker.typeerror(errors, node.loc,
            "generic for iterator tuple produces %d value(s) but expects at most 4",
            #exps)
    end
    while #exps < 4 do
        table.insert(exps, nil_exp(node.loc))
    end

    local ftype = exps[1]._type
    local iter_cfunc
    if ftype._tag == "Type.Value" then
        ftype = synthesize_forin_iterator_type(node, st, errors)
        exps[1] = trycoerce(exps[1], ftype, errors)
        ftype = exps[1]._type
    else
        ftype, iter_cfunc = forin_ftype_from_slot_type(ftype)
    end
    if not ftype then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator must be a function, value, or C function pointer but found %s",
            types.tostring(exps[1]._type))
        ftype = types.Function({}, { types.Invalid() }, false, false)
    end

    if ftype.vararg or ftype.varargtype then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator cannot be variadic")
    end
    if #ftype.params > 2 then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator expects at most 2 parameter(s) but found %d",
            #ftype.params)
    end
    if #ftype.rettypes == 0 then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator must return at least one value")
        ftype = types.Function(ftype.params, { types.Invalid() }, false, false)
    else
        local ctrltype = ftype.rettypes[1]
        if ctrltype._tag == "Type.Nil" then
            checker.typeerror(errors, exps[1].loc,
                "generic for iterator control result cannot be nil-only")
        elseif not forin_nil_capable_control(ctrltype) then
            checker.typeerror(errors, exps[1].loc,
                "generic for iterator control result must be optional, value, or a nullable C pointer but found %s",
                types.tostring(ctrltype))
        end
    end

    if ftype.params[1] then
        exps[2] = trycoerce(exps[2], ftype.params[1], errors)
        checkmatch("generic for iterator state",
            ftype.params[1], exps[2]._type, errors, exps[2].loc)
    end
    if ftype.params[2] then
        exps[3] = trycoerce(exps[3], ftype.params[2], errors)
        checkmatch("generic for iterator initial control",
            ftype.params[2], exps[3]._type, errors, exps[3].loc)
    end

    local close_type = exps[4]._type
    local close_ftype
    local close_cfunc
    if close_type._tag == "Type.Nil" then
        node._has_close = false
    else
        if close_type._tag == "Type.Value" then
            close_ftype = synthesize_forin_close_type(exps)
            exps[4] = trycoerce(exps[4], close_ftype, errors)
            close_type = exps[4]._type
        else
            close_ftype, close_cfunc = forin_ftype_from_slot_type(close_type)
        end
    end
    if close_ftype then
        local close_ok = true
        if close_ftype.vararg or close_ftype.varargtype or #close_ftype.params > 1 then
            checker.typeerror(errors, exps[4].loc,
                "generic for close function must accept zero or one state argument")
            close_ok = false
        elseif close_ftype.params[1] then
            local state_for_close = exps[2]
            state_for_close = trycoerce(state_for_close, close_ftype.params[1], errors)
            checkmatch("generic for close argument",
                close_ftype.params[1], state_for_close._type, errors, exps[2].loc)
        end
        node._has_close = close_ok
    elseif close_type._tag ~= "Type.Nil" and close_type._tag ~= "Type.Invalid" then
        checker.typeerror(errors, exps[4].loc,
            "generic for close value must be nil, a function, value, or C function pointer but found %s",
            types.tostring(close_type))
        node._has_close = false
    end

    node._tuple_decls = {
        hidden_decl(node.loc, "__forin_iter", exps[1]._type),
        hidden_decl(node.loc, "__forin_state", exps[2]._type),
        hidden_decl(node.loc, "__forin_init", exps[3]._type),
        hidden_decl(node.loc, "__forin_close", exps[4]._type),
    }
    node._result_decls = {}
    for i, rtype in ipairs(ftype.rettypes) do
        node._result_decls[i] = hidden_decl(node.loc,
            "__forin_result_" .. i, rtype)
    end

    local function arg_state()
        return hidden_exp(node.loc, node._tuple_decls[2])
    end
    local function arg_init()
        return hidden_exp(node.loc, node._tuple_decls[3])
    end
    local init_args = {}
    if ftype.params[1] then table.insert(init_args, arg_state()) end
    if ftype.params[2] then table.insert(init_args, arg_init()) end
    node._init_call = make_forin_call(node.loc, node._tuple_decls[1],
        init_args, ftype.rettypes, iter_cfunc)

    local next_args = {}
    if ftype.params[1] then table.insert(next_args, arg_state()) end
    if ftype.params[2] then
        local ctrlarg = hidden_exp(node.loc, node._result_decls[1])
        ctrlarg = tryforce(ctrlarg)
        ctrlarg = trycoerce(ctrlarg, ftype.params[2], errors)
        checkmatch("generic for iterator control argument",
            ftype.params[2], ctrlarg._type, errors, node.loc)
        table.insert(next_args, ctrlarg)
    end
    node._next_call = make_forin_call(node.loc, node._tuple_decls[1],
        next_args, ftype.rettypes, iter_cfunc)

    if node._has_close then
        local close_args = {}
        if close_ftype.params[1] then
            local close_arg = hidden_exp(node.loc, node._tuple_decls[2])
            close_arg = trycoerce(close_arg, close_ftype.params[1], errors)
            table.insert(close_args, close_arg)
        end
        node._close_call = make_forin_call(node.loc, node._tuple_decls[4],
            close_args,
            close_ftype.rettypes,
            close_cfunc)
        node._close_call._voidok = true
    end

    local visible_exps = {}
    for i, decl in ipairs(node.decls) do
        local exp
        if ftype.rettypes[i] then
            exp = hidden_exp(node.loc, node._result_decls[i])
            if i == 1 then
                exp = tryforce(exp)
            end
            exp = check_forin_decl_init(decl, exp, st, errors)
        else
            if decl.type then
                checkdecl(decl, st, errors)
                exp = trycoerce(nil_exp(node.loc), decl._type, errors)
                checkmatch("generic for variable " .. decl.name,
                    decl._type, exp._type, errors, decl.loc)
            else
                checker.typeerror(errors, decl.loc,
                    "cannot infer type of generic for variable '%s' from a missing iterator result",
                    decl.name)
                decl._type = types.Invalid()
                exp = nil_exp(node.loc)
            end
        end
        decl._forcontrol = true
        table.insert(visible_exps, exp)
    end
    node._visible_stat = ast.StatDecl(node.loc, node.decls, visible_exps)

    for _, decl in ipairs(node.decls) do
        declare(decl, st, errors)
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

local function copy_block(block)
    local copy = {}
    for name, decl in pairs(block) do
        copy[name] = decl
    end
    return copy
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
        if lastexp and lastexp._tag == "Ast.ExpDots" then
            -- `local a, b, ... = e1, ...` adjust-up: the trailing `...` fills the
            -- remaining declarations. Resolve `$vararg` (scope/error checks),
            -- check + coerce the static-prefix initializers, then synthesize one
            -- `...[k]` read per remaining decl with OOB mode by the decl's
            -- declared / option-ness, exactly like the non-dots multi-return path.
            check_dots_marker(lastexp, st, errors)
            local elem = lastexp._vararg_elem
            -- Static prefix (everything before the `...`).
            for i = 1, #node.exps - 1 do
                local decl = node.decls[i]
                local exp = node.exps[i]
                if decl then
                    if decl.type then
                        checkdecl(decl, st, errors)
                        checkexp(exp, st, errors, decl._type)
                    else
                        checkexp(exp, st, errors)
                        if not decl.option then
                            exp = tryforce(exp)
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
                else
                    checkexp(exp, st, errors)
                end
            end
            local nstatic = #node.exps - 1
            local deficit = #node.decls - nstatic
            if deficit < 0 then
                checker.typeerror(errors, lastexp.loc,
                    "left-hand side expects %d value(s) but the expression list "
                    .. "(with '...') already supplies %d", #node.decls, nstatic)
                table.remove(node.exps)
            else
                table.remove(node.exps) -- drop the ExpDots marker
                for k = 1, deficit do
                    local decl = node.decls[nstatic + k]
                    local idxexp = ast.ExpInteger(lastexp.loc, k)
                    idxexp._type = types.Integer()
                    local exp = ast.ExpDotsIndex(lastexp.loc, idxexp)
                    if decl.type then
                        checkdecl(decl, st, errors)
                        if decl._type._tag == "Type.Option" then
                            -- Type the nil-fill read as the REAL element wrapped
                            -- (`optionize(elem)`), not the slot type, so the
                            -- trycoerce below inserts the genuine element->base
                            -- conversion (e.g. integer? -> float?) and rejects an
                            -- incompatible element (e.g. integer into string?).
                            exp._nilfill = true
                            exp._type = optionize(elem)
                        else
                            exp._nilfill = false
                            exp._type = elem
                        end
                        exp = trycoerce(exp, decl._type, errors)
                    elseif decl.option then
                        decl._type = optionize(elem)
                        exp._nilfill = true
                        exp._type = decl._type
                    else
                        decl._type = elem
                        exp._nilfill = false
                        exp._type = elem
                    end
                    checkmatch("declaration of local variable " .. decl.name,
                        decl._type, exp._type, errors, decl.loc)
                    table.insert(node.exps, exp)
                end
            end
            for _, decl in ipairs(node.decls) do
                if not decl._type then
                    if decl.type then
                        checkdecl(decl, st, errors)
                    else
                        decl._type = types.Invalid()
                    end
                end
                declare(decl, st, errors)
            end
            return
        end
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
            declare(decl, st, errors)
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

    ["Ast.StatForIn"] = function(node, st, errors)
        loop_depth = loop_depth + 1
        st:with_block(checkforin, node, st, errors)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatBreak"] = function(node, _, errors)
        if loop_depth == 0 then
            checker.typeerror(errors, node.loc,
                "'break' outside a loop")
        elseif in_finally > 0 and loop_depth <= finally_loop_floor then
            -- Inside a finally with no loop opened *inside* it: the target loop
            -- encloses the finally, so this `break` would escape it (forbidden).
            -- A `break` to a loop written inside the finally (loop_depth above
            -- the floor) is contained and legal.
            checker.typeerror(errors, node.loc,
                "'break' cannot escape a finally block")
        end
        return false
    end,

    ["Ast.StatRaise"] = function(node, st, errors)
        if not node.exp then
            -- Bare `raise` (re-raise the in-flight error) is legal only lexically
            -- inside a catch block. `catch_depth` is reset across nested function
            -- bodies, so a bare `raise` in a lambda defined in a catch is still
            -- rejected (it has no in-flight error of its own).
            if catch_depth == 0 then
                checker.typeerror(errors, node.loc,
                    "bare 'raise' (a re-raise) is only valid inside a catch block")
            end
        else
            -- `raise <exp>`: the error object may be any value, so check the
            -- operand with `value` as the expected type (every value coerces to
            -- `value`) and materialize the coercion so the coder boxes it.
            checkexp(node.exp, st, errors, types.Value())
            node.exp = trycoerce(node.exp, types.Value(), errors)
            checkmatch("raise", types.Value(), node.exp._type, errors, node.loc)
        end
        -- `raise` is a terminator: control never falls through it.
        return true
    end,

    ["Ast.StatTry"] = function(node, st, errors)
        -- The protected body, the catch handler, and the finally cleanup are
        -- SIBLING scopes, not nested: a body local may be undeclared when the
        -- error fires, so it must not be visible in catch/finally. Check each in
        -- its own block, closing the previous one first.
        local saved_block_index, saved_body_block
        local bret
        if node._defer_tail then
            -- Parser-lowered `defer` protects the rest of the same simpleblock.
            -- A `repeat ... until` condition is scoped with its body, so locals
            -- declared in that tail must remain visible after the synthetic try.
            -- They must still be hidden from the cleanup itself, which is checked
            -- as the sibling `finally` below.
            saved_block_index = #st.blocks
            local before_body = copy_block(st.blocks[saved_block_index])
            bret = checkblock(node.block, st, errors)
            saved_body_block = st.blocks[saved_block_index]
            st.blocks[saved_block_index] = before_body
        else
            bret = st:with_block(checkstat, node.block, st, errors)
        end

        local cret = false
        if node.catchblock then
            -- The catch block binds two implicit locals: `error: value` (the
            -- raised value) and `traceback: string` (its captured trace). They
            -- live in a fresh sibling scope so the body's locals are out of
            -- view. Mark them `_used` so the unused-local analysis ignores them.
            st:open_block()
            local errdecl = ast.Decl(node.loc, "error", false, false)
            errdecl._type = types.Value()
            errdecl._used = true
            errdecl._catch_implicit = true
            declare(errdecl, st, errors)
            local tbdecl = ast.Decl(node.loc, "traceback", false, false)
            tbdecl._type = types.String()
            tbdecl._used = true
            tbdecl._catch_implicit = true
            declare(tbdecl, st, errors)
            node._error_decl = errdecl
            node._traceback_decl = tbdecl
            catch_depth = catch_depth + 1
            cret = checkstat(node.catchblock, st, errors)
            catch_depth = catch_depth - 1
            st:close_block()
        end

        local fret = false
        if node.finallyblock then
            -- A finally is straight-line: no `return` and no finally-escaping
            -- `break` may leave it (only a `raise` overrides). Bump `in_finally`
            -- and stamp `finally_loop_floor` to the current loop depth (so a
            -- `break` to a loop opened INSIDE the finally is still legal),
            -- saving/restoring the outer floor for nested constructs.
            st:open_block()
            in_finally = in_finally + 1
            local saved_floor = finally_loop_floor
            finally_loop_floor = loop_depth
            fret = checkstat(node.finallyblock, st, errors)
            finally_loop_floor = saved_floor
            in_finally = in_finally - 1
            st:close_block()
        end

        if saved_body_block then
            st.blocks[saved_block_index] = saved_body_block
        end

        -- Always-returns (B.2): the construct returns on every path iff the
        -- finally unconditionally returns, OR the body returns and (there is no
        -- catch, or the catch also returns). `raise` counts as a terminator, so
        -- a finally that unconditionally `raise`s satisfies `fret`.
        return (node.finallyblock and fret)
            or (bret and (not node.catchblock or cret))
    end,

    ["Ast.StatAssign"] = function(node, st, errors)
        for _, var in ipairs(node.vars) do
            checkvar(var, st, errors)
        end
        local nexps = #node.exps
        local lastexp = node.exps[nexps]
        local dots = lastexp._tag == "Ast.ExpDots"
        for i, exp in ipairs(node.exps) do
            -- A trailing `...` is a marker resolved below, not a value to check
            -- here (checking it as an expression reports the "bare `...`" error).
            if not (dots and i == nexps) then
                checkexp(exp, st, errors, node.vars[i] and node.vars[i]._type)
            end
        end
        if dots then
            -- `a, b, c = e1, ...` adjust-up into the LHS variables; OOB mode by
            -- each target variable's optionality. The final coerce/checkmatch
            -- loop below handles the synthesized `...[k]` reads uniformly.
            check_dots_marker(lastexp, st, errors)
            expand_dots_adjustup(node.exps, #node.vars,
                function(i) return node.vars[i] and node.vars[i]._type end,
                "assignment", errors)
        elseif lastexp._types and #lastexp._types > 1 then
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
                    -- function, imported module function, or record function).
                    -- Assigning a value *into* a function-typed local, param
                    -- or field is fine and falls through to the normal path.
                    checker.typeerror(errors, var.loc, "trying to assign to a function")
                elseif var._tag == "Ast.VarDot" and var._decl
                       and var._decl._tag == "Type.ModuleMember" then
                    checker.typeerror(errors, var.loc, "cannot assign to foreign variable '%s'", var.name)
                else
                    -- mark this declared variable as assigned to
                    if var._tag == "Ast.VarName" and var._decl then
                        if var._decl._readonly then
                            checker.typeerror(errors, var.loc,
                                "cannot assign to built-in local '%s'",
                                var._decl.name)
                        end
                        if var._decl._forcontrol then
                            checker.typeerror(errors, var.loc,
                                "cannot assign to 'for' control variable '%s'",
                                var._decl.name)
                        end
                        if var._decl._catch_implicit then
                            checker.typeerror(errors, var.loc,
                                "cannot assign to catch local '%s'",
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
        -- Nothing may statically leave a finally (only an unpreventable raise
        -- can): a `return` lexically inside a finally is a compile error.
        -- `in_finally` is reset across nested function bodies, so a `return` in a
        -- lambda DEFINED in a finally is the lambda's own and is legal.
        if in_finally > 0 then
            checker.typeerror(errors, node.loc,
                "cannot 'return' from inside a finally block")
        end
        local ftype = st:find_symbol("$function")._type
        local nexps = #node.exps
        local dots = nexps > 0 and node.exps[nexps]._tag == "Ast.ExpDots"
        for i, exp in ipairs(node.exps) do
            -- The trailing `...` is a marker, not a value to check here.
            if not (dots and i == nexps) then
                checkexp(exp, st, errors, ftype.rettypes[i])
            end
        end
        if #node.exps == 0 and #ftype.rettypes == 1
           and ftype.rettypes[1]._tag == "Type.Nil" then
            -- A bare `return` in a nil-returning function means `return nil`.
            local nilexp = ast.ExpNil(node.loc)
            nilexp._type = types.Nil()
            table.insert(node.exps, nilexp)
        end
        local lastexp = node.exps[#node.exps]
        if lastexp and lastexp._tag == "Ast.ExpDots" then
            -- `return ...` is adjust-up into the function's FIXED return arity
            -- (there is no runtime mechanism for a variable return count). A
            -- function returning no values cannot use `return ...` at all.
            check_dots_marker(lastexp, st, errors)
            if #ftype.rettypes == 0 then
                checker.typeerror(errors, lastexp.loc,
                    "cannot use '...' to return from a function that returns no values")
                table.remove(node.exps)
            else
                expand_dots_adjustup(node.exps, #ftype.rettypes,
                    function(i) return ftype.rettypes[i] end, "return", errors)
            end
        elseif lastexp and lastexp._types and #lastexp._types > 1 then
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
                if decl._c_address_taken then
                    checker.typeerror(errors, node.loc,
                        "cannot capture variable '%s' after taking its mutable C address",
                        node.name)
                end
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
        if ltype._tag == "Type.Module" or ltype._tag == "Type.CModule" then
            local mod = ltype
            if ltype._tag == "Type.CModule" and mod.type_members
               and mod.type_members[node.name] then
                node._decl = {
                    _tag = "Type.CTypeNamespace",
                    name = node.name,
                    type = mod.type_members[node.name],
                }
                node._type = node._decl.type
                node._ctype_namespace = true
            elseif not mod.members[node.name] then
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
                if not is_record_member_visible_from(st, decl) then
                    node._type = invalid(errors, node.loc,
                        "record function '%s.%s' is local to module '%s'",
                        ltype.name, node.name, record_module(ltype.name))
                else
                    node._decl = decl
                    node._type = types.Function(decl.params, decl.rettypes, false,
                        decl.varargtype)
                end
            else
                node._type = invalid(errors, node.loc,
                    "trying to access invalid record function '%s'", node.name)
            end
        elseif ltype._tag == "Type.Nominal" then
            local type = types.registry[ltype.fqtn]
            if not type then
                node._type = invalid(errors, node.loc,
                    "type '%s' not found", ltype.fqtn)
            elseif not is_record_visible_from(st, ltype.fqtn) then
                node._type = invalid(errors, node.loc,
                    "record type '%s' is local to module '%s'",
                    ltype.fqtn, record_module(ltype.fqtn))
            elseif type._tag ~= "Type.Record" then
                node._type = invalid(errors, node.loc,
                    "trying to access field '%s' of type '%s' that is not a record but '%s'",
                    node.name, ltype.fqtn, type._tag)
            else
                for _, field in ipairs(type.fields) do
                    if field.name == node.name and is_record_member_visible_from(st, field) then
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
        elseif types.is_c(ltype) or is_c_type_namespace(node.exp) then
            if is_c_type_namespace(node.exp) then
                node._decl = c_pseudo_member(ltype, node.name)
                if node._decl then
                    node._type = node._decl.type
                else
                    node._type = invalid(errors, node.loc,
                        "C type '%s' has no pseudo-member '%s'",
                        types.tostring(ltype), node.name)
                end
            else
                node._decl = c_field_decl(ltype, node.name)
                if node._decl then
                    node._type = node._decl.type
                else
                    node._type = invalid(errors, node.loc,
                        "field '%s' not found in C type '%s'",
                        node.name, types.tostring(ltype))
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
        local celem, cterm, cerr = c_index_elem_type(node.exp1._type)
        if node.exp1._type._tag == "Type.Array" then
            node._type = optionize(node.exp1._type.elem)
            keystype = types.Integer()
            term = "array indexing"
        elseif node.exp1._type._tag == "Type.Map" then
            node._type = optionize(node.exp1._type.values)
            keystype = node.exp1._type.keys
            term = "map indexing"
        elseif celem then
            node._type, term = celem, cterm
            keystype = types.Integer()
        elseif cerr then
            node._type = invalid(errors, node.exp1.loc, cerr)
            return
        else
            node._type = invalid(errors, node.exp1.loc,
                "expression in indexing is not an array, map, C pointer, C array, or owned C array but %s",
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

-- Typechecks and argument list for a function or method call. When
-- `allow_missing` is true, a fixed-parameter deficit is adjusted upward by
-- synthesizing explicit nil arguments; surplus arguments are still rejected
-- below for non-variadic callees.
local function checkargs(ftype, args, loc, fname, st, errors, allow_missing)
    if allow_missing == nil then allow_missing = true end
    local nparams = #ftype.params
    local nargs = #args
    local lastarg = args[nargs]

    -- A trailing `...` in the argument list. Dispatch on the CALLEE's vararg
    -- shape (read BEFORE the multi-return `_types` expansion below):
    --   * Titan-variadic callee (`ftype.varargtype`): WHOLE-TAIL. The `...` is
    --     kept as a marker for codegen; the caller's `...` element type must be
    --     `compatible` (gradual) with the callee's, and any over-supplied static
    --     args (beyond the fixed params) are coerced to the callee's element type.
    --   * C-FFI vararg callee (`ftype.vararg` boolean): forbidden — a Titan `...`
    --     cannot flow into a foreign function (no struct ABI for it).
    --   * non-variadic callee: ADJUST-UP into the fixed params.
    if lastarg and lastarg._tag == "Ast.ExpDots" then
        -- Check the static-prefix args (everything before the `...`).
        for i = 1, nargs - 1 do
            local arg = args[i]
            local ptype = ftype.params[i]
            checkexp(arg, st, errors, ptype)
            ptype = ptype or arg._type
            args[i] = trycoerce(args[i], ptype, errors)
            checkmatch("argument " .. i .. " of call to " .. fname,
                ptype, args[i]._type, errors, arg.loc)
        end
        check_dots_marker(lastarg, st, errors) -- resolve `$vararg`
        if ftype.varargtype then
            -- WHOLE-TAIL: keep the `...` marker; check element compatibility.
            local nstatic = nargs - 1
            local caller_elem = lastarg._vararg_elem
            if nstatic < nparams then
                -- START-ADJUST (§5.7 case 2): the static prefix fills only the
                -- first `nstatic` fixed params; the remaining `nparams - nstatic`
                -- fixed params are BORROWED from the caller's own `...`. Each
                -- borrowed fixed param type must accept or coerce the caller's
                -- `...` element type; if the runtime tail is too short, codegen
                -- nil-fills only the fixed params whose types can accept nil.
                if caller_elem and caller_elem._tag ~= "Type.Invalid" then
                    for i = nstatic + 1, nparams do
                        local ptype = ftype.params[i]
                        if not (types.compatible(ptype, caller_elem)
                                or types.coerceable(caller_elem, ptype)) then
                            checker.typeerror(errors, lastarg.loc,
                                "cannot borrow a '...' element of type %s for "
                                .. "fixed parameter %d (type %s) of %s",
                                types.tostring(caller_elem), i,
                                types.tostring(ptype), fname)
                        end
                    end
                end
            else
                -- Over-supplied static args (beyond the fixed params) are passed
                -- as leading vararg elements; coerce each to the element type.
                for i = nparams + 1, nstatic do
                    args[i] = trycoerce(args[i], ftype.varargtype, errors)
                    checkmatch("argument " .. i .. " of call to " .. fname,
                        ftype.varargtype, args[i]._type, errors, args[i].loc)
                end
            end
            if caller_elem and caller_elem._tag ~= "Type.Invalid"
               and not types.compatible(ftype.varargtype, caller_elem) then
                checker.typeerror(errors, lastarg.loc,
                    "'...' element type %s is not compatible with the '...' "
                    .. "element type %s of %s",
                    types.tostring(caller_elem),
                    types.tostring(ftype.varargtype), fname)
            end
        elseif ftype.vararg then
            checker.typeerror(errors, lastarg.loc,
                "cannot pass '...' to a foreign (C) variadic function")
            table.remove(args)
            return
        else
            -- ADJUST-UP into the fixed params.
            expand_dots_adjustup(args, nparams,
                function(i) return ftype.params[i] end,
                "call to " .. fname, errors, nil_can_adjust_to)
            for i = nargs, #args do
                local ptype = ftype.params[i]
                if ptype then
                    args[i] = trycoerce(args[i], ptype, errors)
                    checkmatch("argument " .. i .. " of call to " .. fname,
                        ptype, args[i]._type, errors, args[i].loc)
                end
            end
        end
        if ftype.varargtype then
            -- A whole-tail variadic call always satisfies the fixed-param arity
            -- (checked above); skip the static arity check below.
            return
        end
        if #args ~= nparams then
            checker.typeerror(errors, loc,
                "%s called with %d arguments but expects %d.\n%s",
                fname, #args, nparams, types.tostring(ftype))
        end
        return
    end

    for i = 1, nargs do
        local arg = args[i]
        -- A surplus arg (beyond the fixed params) to a Titan-variadic callee is
        -- typed against the vararg element type, so it is coerced/checked like a
        -- vararg element rather than left unchecked.
        local ptype = ftype.params[i] or ftype.varargtype
        checkexp(arg, st, errors, ptype)
        ptype = ptype or arg._type
        args[i] = trycoerce(args[i], ptype, errors)
        local atype = args[i]._type
        checkmatch("argument " .. i .. " of call to " .. fname, ptype, atype, errors, arg.loc)
    end
    if lastarg and lastarg._types then
        for i = 2, #lastarg._types do
            local pidx = nargs + i - 1
            local ptype = ftype.params[pidx] or ftype.varargtype
            local exp = ast.ExpExtra(lastarg.loc, lastarg, i, lastarg._types[i])
            ptype = ptype or exp._type
            exp = trycoerce(exp, ptype, errors)
            table.insert(args, exp)
            checkmatch("argument " .. pidx .. " of call to " .. fname, ptype, exp._type, errors, exp.loc)
        end
    end
    if allow_missing and #args < nparams then
        append_missing_nil_args(args, nparams, loc, fname, errors, ftype)
    end
    -- A Titan-variadic callee (`varargtype`) or a C-FFI variadic (`vararg`)
    -- accepts at least `nparams` arguments; a fixed callee needs exactly that.
    local variadic = ftype.vararg or (ftype.varargtype and true)
    if not (#args == nparams or (variadic and #args >= nparams)) then
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

        -- A trailing `...` field (`{e1, ..., ...}` / `{...}`) is array-shaped:
        -- it whole-tail-spreads the vararg into the array. It is only legal in an
        -- array constructor; in a map/record constructor it is an error.
        local dots_field = find_dots_field(node, errors)
        if dots_field and expected ~= "Type.Array" then
            checker.typeerror(errors, dots_field.loc,
                "'...' can only appear in an array constructor")
            -- Still resolve `$vararg` so scope diagnostics fire; drop the field
            -- so the map/record arm below does not choke on the bare `...`.
            check_dots_marker(dots_field.exp, st, errors)
            table.remove(node.fields)
            dots_field = nil
        end

        if expected == "Type.Array" then
            local econtext = context and context.elem
            local etypes = {}
            local dots_elem
            -- Location of the `...` field, for the coerceability diagnostic below.
            -- `dots_field` is nil when the `...` is not the last field
            -- (`find_dots_field` reported and dropped it), but the loop still
            -- visits that field and sets `dots_elem`, so we cannot rely on
            -- `dots_field.loc` there — capture the field's own loc instead.
            local dots_loc
            for _, field in ipairs(node.fields) do
                if field.name then
                    checker.typeerror(errors, field.loc,
                        "initializing field '%s' when expecting array", field.name)
                    checkexp(field.exp, st, errors)
                elseif field.exp._tag == "Ast.ExpDots" then
                    -- whole-tail `...`: kept as a marker for codegen; its element
                    -- type seeds (or is checked against) the array element type.
                    check_dots_marker(field.exp, st, errors)
                    dots_elem = field.exp._vararg_elem
                    dots_loc = field.loc
                else
                    local exp = field.exp
                    checkexp(exp, st, errors, econtext)
                    table.insert(etypes, exp._type)
                end
            end

            -- adjust last entry if it's a function call that expands to multiple values
            -- e.g. { 1, 2, f() }
            local lastfield = node.fields[#node.fields]
            if lastfield and not lastfield.name
               and lastfield.exp._tag ~= "Ast.ExpDots"
               and lastfield.exp._types and #lastfield.exp._types > 1 then
                for i = 2, #lastfield.exp._types do
                    table.insert(node.fields,
                        ast.Field(lastfield.loc, nil,
                            ast.ExpExtra(lastfield.loc, lastfield.exp,
                                i, lastfield.exp._types[i])))
                end
            end

            -- Seed the element type from the vararg element first (`{...}` is
            -- `{t}`, not `{t?}`), then a context, then the first static field.
            local etype = econtext
                or (dots_elem and dots_elem._tag ~= "Type.Invalid"
                    and deoptionize(dots_elem))
                or (etypes[1] and deoptionize(etypes[1])) or types.Integer()
            node._type = types.Array(etype)
            for i, field in ipairs(node.fields) do
                if not field.name and field.exp._tag ~= "Ast.ExpDots" then
                    field.exp = trycoerce(field.exp, etype, errors)
                    local exp = field.exp
                    checkmatch("array initializer at position " .. i, etype,
                               exp._type, errors, exp.loc)
                end
            end
            -- The whole-tail `...` element type must be coerceable to the array
            -- element type (the context may have overridden `etype` to something
            -- other than the vararg element, e.g. `{...integer}` in a `{float}`
            -- context). The codegen converts each element from the real vararg
            -- element to `etype`; reject an incompatible element here (e.g.
            -- `{...integer}` into `{string}`) instead of bit-reinterpreting it.
            if dots_elem and dots_elem._tag ~= "Type.Invalid"
               and not types.equals(dots_elem, etype)
               and not types.coerceable(dots_elem, etype) then
                checker.typeerror(errors, dots_loc,
                    "'...' element type %s is not coerceable to array element "
                    .. "type %s", types.tostring(dots_elem), types.tostring(etype))
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
                if record.islocal and record_module(context.fqtn) ~= st.modname then
                    node._type = invalid(errors, node.loc,
                        "record type '%s' is local to module '%s'",
                        context.fqtn, record_module(context.fqtn))
                    for _, field in ipairs(node.fields) do
                        checkexp(field.exp, st, errors)
                    end
                    return
                end
                local visible_fields = visible_record_fields(record, st)
                if (record.nfields or #record.fields) > #visible_fields then
                    node._type = invalid(errors, node.loc,
                        "cannot construct record type '%s' outside module '%s' because it has local fields",
                        context.fqtn, record_module(context.fqtn))
                    for _, field in ipairs(node.fields) do
                        checkexp(field.exp, st, errors)
                    end
                    return
                end
                for _, cfield in ipairs(node.fields) do
                    local found
                    for _, rfield in ipairs(visible_fields) do
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
                for _, rfield in ipairs(visible_fields) do
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
        if texp._tag == "Type.Module" or texp._tag == "Type.CModule" then
            node._type = invalid(errors, node.loc,
                "trying to access module '%s' as a first-class value",
                node.var.name)
        elseif texp._tag == "Type.Function" then
            -- First-class function value. Foreign (C FFI) functions cannot be
            -- taken as Titan closure values, but they can be converted to a
            -- compatible C function pointer when the surrounding context asks
            -- for one. Every other function (Titan top-level function, record
            -- static, imported module function, or a function-typed local/param/
            -- field that already holds a value) is allowed as before.
            local var = node.var
            if var._tag == "Ast.VarDot" and var.exp._type
               and var.exp._type._tag == "Type.CModule" then
                if c_function_pointer_accepts_function(context, texp) then
                    node._type = context
                    node._foreign_function_pointer = var.name
                else
                    node._type = invalid(errors, node.loc,
                        "a foreign (C) function cannot be used as a first-class value")
                end
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
        -- `#...` parses as `ExpUnop("#", ExpDots)` because the unop cascade takes
        -- `#` greedily. Rewrite it in place to an `ExpDotsLen` (which yields an
        -- integer) before the operand is checked, bypassing the array/string `#`
        -- path that cannot handle a bare `...` operand.
        if op == "#" and node.exp._tag == "Ast.ExpDots" then
            local lennode = ast.ExpDotsLen(node.loc)
            checkexp(lennode, st, errors)
            for k in pairs(node) do node[k] = nil end
            for k, v in pairs(lennode) do node[k] = v end
            return
        end
        checkexp(node.exp, st, errors)
        local texp = node.exp._type
        local loc = node.loc
        if op == "#" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            if texp._tag ~= "Type.Array" and texp._tag ~= "Type.String"
               and not has_c_length(texp) then
                checker.typeerror(errors, loc,
                    "trying to take the length of a %s instead of an array, string, C array, or counted owned C array",
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
            local mixed_numeric =
                (tlhs._tag == "Type.Integer" and trhs._tag == "Type.Float") or
                (tlhs._tag == "Type.Float"   and trhs._tag == "Type.Integer")
            if not mixed_numeric and
               (tlhs._tag ~= "Type.Option" or trhs._tag ~= "Type.Option" or
                ((tlhs.base._tag ~= "Type.Integer" or trhs.base._tag ~= "Type.Float") and
                 (tlhs.base._tag ~= "Type.Float" or trhs.base._tag ~= "Type.Integer"))) and
               not types.compatible(tlhs, trhs) then
                checker.typeerror(errors, loc,
                    "trying to compare values of incomparable types: %s and %s",
                    types.tostring(tlhs), types.tostring(trhs))
            end
            node._type = types.Boolean()
        elseif op == "<" or op == ">" or op == "<=" or op == ">=" then
            node.lhs = tryforce(node.lhs); tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs); trhs = node.rhs._type
            local lnum = tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float"
            local rnum = trhs._tag == "Type.Integer" or trhs._tag == "Type.Float"
            local lstr, rstr = tlhs._tag == "Type.String", trhs._tag == "Type.String"
            if (lnum and rnum) or (lstr and rstr) then
                -- ok: numbers compare to numbers (int vs float exactly), strings to strings
            elseif rnum and not lnum then
                checker.typeerror(errors, loc, "left hand side of relational expression is a %s instead of a number", types.tostring(tlhs))
            elseif lnum and not rnum then
                checker.typeerror(errors, loc, "right hand side of relational expression is a %s instead of a number", types.tostring(trhs))
            elseif rstr and not lstr then
                checker.typeerror(errors, loc, "left hand side of relational expression is a %s instead of a string", types.tostring(tlhs))
            elseif lstr and not rstr then
                checker.typeerror(errors, loc, "right hand side of relational expression is a %s instead of a string", types.tostring(trhs))
            elseif types.equals(tlhs, trhs) then
                checker.typeerror(errors, loc, "trying to use relational expression with two %s values", types.tostring(tlhs))
            else
                checker.typeerror(errors, loc, "trying to use relational expression with %s and %s", types.tostring(tlhs), types.tostring(trhs))
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
            local cfunc = c_function_pointer_type(ftype)
            if cfunc then
                local cftype = c_function_as_function_type(cfunc)
                node._c_pointer_call = cfunc
                checkargs(cftype, node.args.args, node.loc,
                    "function pointer '" .. fname .. "'", st, errors, false)
                node._types = cftype.rettypes
                node._type = cftype.rettypes[1] or types.Void()
                if node._type._tag == "Type.Void" and not node._voidok then
                    node._type = invalid(errors, node.loc,
                        "a function returning no values cannot be used as a value")
                end
                return
            end
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
            -- record function, imported module function) or any function-typed
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
            if node.exp._tag == "Ast.ExpVar"
               and node.exp.var._decl
               and node.exp.var._decl._tag == "Type.CPseudoNew" then
                local alloc_err = c_allocation_error(node.exp.var._decl.ctype)
                if alloc_err then
                    node._type = invalid(errors, node.loc, alloc_err)
                    for _, arg in ipairs(node.args.args) do
                        checkexp(arg, st, errors)
                    end
                    return
                end
            end
            checkargs(ftype, node.args.args, node.loc,
                "function '" .. fname .. "'", st, errors,
                not (node.exp._tag == "Ast.ExpVar"
                     and (is_foreign_function_var(node.exp.var)
                          or (node.exp.var._decl
                              and node.exp.var._decl._tag == "Type.CPseudoNew"))))
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
                if not is_record_visible_from(st, otype.fqtn) then
                    node._type = invalid(errors, node.loc,
                        "record type '%s' is local to module '%s'",
                        otype.fqtn, record_module(otype.fqtn))
                    for _, arg in ipairs(node.args.args) do
                        checkexp(arg, st, errors)
                    end
                    return
                elseif not class.methods[node.args.method] then
                    node._type = invalid(errors, node.loc,
                        "method '%s' not found in record '%s'",
                        node.args.method, types.tostring(otype))
                    for _, arg in ipairs(node.args.args) do
                        checkexp(arg, st, errors)
                    end
                    return
                end
                local ftype = class.methods[node.args.method]
                if not is_record_member_visible_from(st, ftype) then
                    node._type = invalid(errors, node.loc,
                        "method '%s:%s' is local to module '%s'",
                        class.name, node.args.method, record_module(class.name))
                    for _, arg in ipairs(node.args.args) do
                        checkexp(arg, st, errors)
                    end
                    return
                end
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
        if types.equals(source, target) then
            ok = true
        elseif source._tag == "Type.Option" and types.equals(source.base, target) then
            -- explicit unwrap of an option to its base type; the cast codegen
            -- emits a runtime nil-check that raises if the value is nil
            ok = true
        elseif is_mutable_c_address_source(node.exp)
           and types.c_mutable_address_coerceable(source, target)
           and not types.c_address_coerceable(source, target) then
            mark_mutable_c_address_source(node.exp)
            ok = true
        else
            ok = types.explicitly_coerceable(source, target) or
                 (types.coerceable(source, target) and
                  types.compatible(source, target))
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
        -- A trailing vararg `Decl` (`name == false`) is dropped from the fixed
        -- params; its element type is resolved separately below. A lambda vararg
        -- may be untyped (`type == false`), in which case the element type is
        -- inferred from context, exactly like an untyped lambda parameter.
        -- `nfixed` is the count compared against a context's arity.
        local nparams = #node.params
        local varargtype = false
        local varargdecl = node.params[nparams]
        local has_vararg = varargdecl and varargdecl.name == false
        local nfixed = has_vararg and nparams - 1 or nparams

        -- Checking mode iff the context is a function type whose fixed arity
        -- matches; element-type matching is not enforced for inference here.
        local expected = (context and context._tag == "Type.Function"
            and #context.params == nfixed) and context or nil

        -- Resolve the vararg element type (explicit annotation wins; otherwise
        -- infer from the expected function type's `varargtype`). An untyped `...`
        -- with a non-variadic context, or with no usable context at all, is an
        -- error — mirroring an uninferable untyped lambda parameter.
        if has_vararg then
            if varargdecl.type then
                varargdecl._type =
                    typefromnode(varargdecl.type, st, errors)
            elseif expected and expected.varargtype then
                varargdecl._type = expected.varargtype
            elseif expected then
                varargdecl._type = invalid(errors, varargdecl.loc,
                    "cannot infer the type of '...'; the lambda is variadic but "
                    .. "the expected type is not")
            else
                varargdecl._type = invalid(errors, varargdecl.loc,
                    "cannot infer the type of '...'; annotate it or use the "
                    .. "lambda where its type is known")
            end
            varargtype =
                check_vararg_elem(varargdecl._type, varargdecl.loc, errors)
        end

        -- Resolve fixed parameter types.
        local paramtypes = {}
        for i = 1, nfixed do
            local param = node.params[i]
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

        node._type = types.Function(paramtypes, rettypes, false, varargtype)

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
        if otype._tag == "Type.CModule" then
            node._type = invalid(errors, node.loc,
                "a foreign (C) method cannot be used as a first-class value")
        elseif otype._tag == "Type.Nominal" and
           types.registry[otype.fqtn] and
           types.registry[otype.fqtn]._tag == "Type.Record" then
            local class = types.registry[otype.fqtn]
            local mtype = class.methods[node.name]
            if not is_record_visible_from(st, otype.fqtn) then
                node._type = invalid(errors, node.loc,
                    "record type '%s' is local to module '%s'",
                    otype.fqtn, record_module(otype.fqtn))
            elseif not mtype then
                node._type = invalid(errors, node.loc,
                    "method '%s' not found in record '%s'",
                    node.name, types.tostring(otype))
            elseif not is_record_member_visible_from(st, mtype) then
                node._type = invalid(errors, node.loc,
                    "method '%s:%s' is local to module '%s'",
                    class.name, node.name, record_module(class.name))
            else
                node._method = mtype
                node._type = types.Function(mtype.params, mtype.rettypes, false,
                    mtype.varargtype)
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
    end,

    -- Bare `...` in a value position. `...` is only legal as the sole, trailing
    -- entry of an explist (a call argument, `return`, assignment/decl RHS) or an
    -- array constructor, where the consuming loop (§4.6/§4.7) intercepts it as a
    -- marker or rewrites it into `ExpDotsIndex` reads BEFORE reaching this arm.
    -- Reaching this arm therefore means `...` appeared where a single value is
    -- required (e.g. `1 + ...`, a non-trailing list position), which is an error.
    -- We still resolve `$vararg` so the scope / not-variadic diagnostics fire.
    ["Ast.ExpDots"] = function(node, st, errors, _)
        node._vararg_elem = resolve_vararg(st, node.loc, errors)
        node._type = node._vararg_elem
        if node._vararg_elem._tag ~= "Type.Invalid" then
            checker.typeerror(errors, node.loc,
                "'...' can only be used as the last item of an argument list, "
                .. "a return, an assignment, a generic for iterator tuple, "
                .. "or an array constructor")
        end
    end,

    ["Ast.ExpDotsLen"] = function(node, st, errors, _)
        resolve_vararg(st, node.loc, errors)
        node._type = types.Integer()
    end,

    -- `...[e]` (1-based). Type is the element type `t` (NOT `t?`): codegen
    -- bounds-checks and raises on out-of-range, so an in-range access is always a
    -- valid `t`. `_nilfill` defaults to false (raise); adjust-up synthesis (§4.6)
    -- sets `_nilfill = true` / `_type = s?` for an optional target slot.
    ["Ast.ExpDotsIndex"] = function(node, st, errors, _)
        local elem = resolve_vararg(st, node.loc, errors)
        checkexp(node.exp, st, errors, types.Integer())
        node.exp = trycoerce(node.exp, types.Integer(), errors)
        checkmatch("variadic index", types.Integer(), node.exp._type,
            errors, node.exp.loc)
        if node._nilfill == nil then node._nilfill = false end
        node._type = node._type or elem
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
    local ldecl = ast.Decl(node.loc, "L", false, false)
    ldecl._type = lua_state_pointer_type(st)
    ldecl._funcdepth = #func_stack
    ldecl._cvar = "L"
    ldecl._readonly = true
    st:add_symbol("L", ldecl)
    local mdecl = ast.Decl(node.loc, "M", false, false)
    mdecl._type = module_udata_pointer_type(st)
    mdecl._funcdepth = #func_stack
    mdecl._cvar = "_mod"
    mdecl._readonly = true
    st:add_symbol("M", mdecl)
    if opts.self_decl then
        -- `self` belongs to this function's own depth, so a lambda nested in a
        -- method captures it just like any other parameter.
        opts.self_decl._funcdepth = #func_stack
        st:add_symbol("self", opts.self_decl)
    end
    -- A variadic function makes its `...` visible to its own body only, via a
    -- depth-stamped `$vararg` symbol. The depth (`#func_stack`, the frame just
    -- pushed) enforces scope rule 4: an inner lambda walking the symbol table
    -- finds this `$vararg` but rejects it because its stamped depth differs.
    if node._type.varargtype then
        st:add_symbol("$vararg",
            { elem = node._type.varargtype, funcdepth = #func_stack })
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
        -- The trailing vararg marker (`name == false`) is not a real parameter:
        -- it carries no name to declare and its type already lives on
        -- `node._type.varargtype`; skip it so `ptypes`/`node.params` stay aligned.
        if param.name ~= false then
            param._type = ptypes[i]
            param._funcdepth = #func_stack
            local builtin = st:find_symbol(param.name)
            if builtin and builtin._readonly then
                checker.typeerror(errors, param.loc,
                    "cannot declare parameter '%s' because it shadows a built-in local",
                    param.name)
            end
            st:add_symbol(param.name, param)
            checktype(param._type, param.loc, errors)
            if pnames[param.name] then
                checker.typeerror(errors, node.loc,
                    "duplicate parameter '%s' in %s", param.name, fdesc)
            else
                pnames[param.name] = true
            end
        end
    end
    -- The error-handling context counters do not cross a function boundary: a
    -- lambda body starts fresh (a bare `raise`/`return`/`break` inside it is the
    -- lambda's own, not the enclosing catch/finally's). Save and reset to 0
    -- around the body, restoring on the way out so the enclosing context is
    -- unaffected. (`loop_depth` predates this; `break` already cannot target a
    -- loop across a function boundary, so it is reset here too for consistency.)
    local saved_catch, saved_in_finally, saved_floor, saved_loop =
        catch_depth, in_finally, finally_loop_floor, loop_depth
    catch_depth, in_finally, finally_loop_floor, loop_depth = 0, 0, 0, 0
    local ret = st:with_block(checkstat, node.block, st, errors)
    catch_depth, in_finally, finally_loop_floor, loop_depth =
        saved_catch, saved_in_finally, saved_floor, saved_loop
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

local function checkinitializer(node, st, errors)
    local init = {
        loc = node.loc,
        name = "$module_initializer",
        params = {},
        rettypes = {},
        block = node,
        _type = node._type,
    }
    st:open_block()
    checkfuncbody(init, st, errors)
    st:close_block()
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
            elseif node._tag == "Ast.StatBlock" then
                checkinitializer(node, st, errors)
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
    elseif tag == "Ast.StatBlock" then
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
        local ftypes, err, include = cdriver.process_file(name, {
            source_dir = st.source_dir
        })
        if ftypes then
            node._include = include
            local members = {}
            local type_members = {}
            for _, item in ipairs(ftypes) do
                local fname = item.name
                local ftype = item.type
                local decl = foreigntypes.convert(st, ftype)
                if decl then
                    if is_foreign_ordinary_identifier(fname, ftype) then
                        local previous = st:find_foreign_name(fname)
                        if previous and previous.header ~= name
                           and not types.equals(previous.type, decl) then
                            checker.typeerror(errors, node.loc,
                                "conflicting C declaration for '%s' in foreign import '%s'; "
                                .. "previous declaration from '%s' has type %s, new declaration has type %s",
                                fname, name, previous.header,
                                types.tostring(previous.type), types.tostring(decl))
                        elseif not previous then
                            st:add_foreign_name(fname, {
                                header = name,
                                type = decl,
                            })
                        end
                    end
                    if is_foreign_type_declaration(ftype) then
                        type_members[fname] = decl
                        st:add_foreign_type(fname, decl)
                    else
                        members[fname] = types.ModuleMember(name, fname, decl)
                    end
                end
                -- else: the member uses an unsupported C type; skip it so the
                -- rest of the header still imports. Referencing a skipped
                -- member is then a clean "not a member" error, never a crash.
            end
            local modtype = types.CModule(name, members)
            modtype.type_members = type_members
            node._type = modtype
        else
            node._type = types.Nil()
            checker.typeerror(errors, node.loc, err)
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
        local ptypes, varargtype = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        node._type = types.Function(ptypes, rettypes, false, varargtype)
    end,

    ["Ast.StatBlock"] = function(node)
        node._type = types.Function({}, {}, false, false)
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
                local tfield = types.Field(fqtn, field.name, ftype, i - 1)
                tfield.islocal = field.islocal and true or false
                table.insert(fields, tfield)
            end
        end
        node._type = types.Record(fqtn, fields, {}, {}, #fields)
        node._type.islocal = node.islocal and true or false
        types.registry[fqtn] = node._type
    end,

    ["Ast.TopLevelStatic"] = function(node, st, errors)
        local record = st:find_symbol(node.class)
        if not record then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "record referenced by record function declaration '%s.%s' does not exist",
                node.class, node.name)
            return
        end
        if record._tag ~= "Ast.TopLevelRecord" then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "member referenced by record function declaration '%s.%s' is not a record",
                node.class, node.name)
            return
        end
        local rectype = record._type
        for _, field in ipairs(rectype.fields) do
            if field.name == node.name then
                node._ignore = true
                checker.typeerror(errors, node.loc,
                "cannot declare record function '%s.%s' as field '%s' exists in record '%s'",
                    node.class, node.name, field.name, node.class)
                return
            end
        end
        if rectype.methods[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "cannot declare record function '%s.%s' as method '%s:%s' exists in record '%s'",
                    node.class, node.name, node.class, node.name, node.class)
            return
        end
        if rectype.functions[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "redeclaration of record function '%s.%s'", node.class, node.name)
            return
        end
        node._record = record
        local ptypes, varargtype = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        node._type = types.StaticMethod(rectype.name, node.name, ptypes, rettypes,
            varargtype)
        node._type.islocal = node.islocal and true or false
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
                "cannot declare method '%s:%s' as record function '%s.%s' exists in record '%s'",
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
        local ptypes, varargtype = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        node._type = types.Method(rectype.name, node.name, ptypes, rettypes,
            varargtype)
        node._type.islocal = node.islocal and true or false
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
        if t.varargtype then
            register_referenced_records(t.varargtype, loader, seen)
        end
    elseif tag == "Type.Record" then
        for _, f in ipairs(t.fields or {}) do
            register_referenced_records(f.type, loader, seen)
        end
    end
end

local function first_local_record_type(typ, seen)
    if type(typ) ~= "table" or not typ._tag then return nil end
    seen = seen or {}
    if seen[typ] then return nil end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Nominal" then
        local record = types.registry[typ.fqtn]
        if record and record.islocal then
            return typ
        end
    elseif tag == "Type.Record" then
        if typ.islocal then return typ end
        for _, field in ipairs(typ.fields or {}) do
            if not field.islocal then
                local found = first_local_record_type(field.type, seen)
                if found then return found end
            end
        end
        for _, func in pairs(typ.functions or {}) do
            if not func.islocal then
                local found = first_local_record_type(func, seen)
                if found then return found end
            end
        end
        for _, method in pairs(typ.methods or {}) do
            if not method.islocal then
                local found = first_local_record_type(method, seen)
                if found then return found end
            end
        end
    elseif tag == "Type.Array" then
        return first_local_record_type(typ.elem, seen)
    elseif tag == "Type.Map" then
        return first_local_record_type(typ.keys, seen)
            or first_local_record_type(typ.values, seen)
    elseif tag == "Type.Option" then
        return first_local_record_type(typ.base, seen)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable"
           or tag == "Type.Field" then
        return first_local_record_type(typ.type, seen)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        for _, p in ipairs(typ.params or {}) do
            local found = first_local_record_type(p, seen)
            if found then return found end
        end
        for _, r in ipairs(typ.rettypes or {}) do
            local found = first_local_record_type(r, seen)
            if found then return found end
        end
        if typ.varargtype then
            return first_local_record_type(typ.varargtype, seen)
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

local function reject_exported_c_ffi_type(modname, errors, loc, typ)
    local ctyp = types.first_c_ffi_type(typ)
    if ctyp then
        checker.typeerror(errors, loc,
            "cannot export C FFI type '%s' from Titan module '%s'; "
            .. "C FFI types are local to modules that import their headers",
            types.tostring(ctyp), modname)
    end
end

local function reject_exported_c_ffi_types(modname, modast, errors)
    for _, node in ipairs(modast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and not node.islocal then
                reject_exported_c_ffi_type(modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelFunc" and not node.islocal then
                reject_exported_c_ffi_type(modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelRecord" and not node.islocal then
                for i, field in ipairs(node._type.fields) do
                    if not field.islocal then
                        local loc = node.fields[i] and node.fields[i].loc or node.loc
                        reject_exported_c_ffi_type(modname, errors, loc, field.type)
                    end
                end
            elseif (tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic")
                   and not node.islocal then
                reject_exported_c_ffi_type(modname, errors, node.loc, node._type)
            end
        end
    end
end

local function reject_exported_local_record_type(modname, errors, loc, typ)
    local local_record = first_local_record_type(typ)
    if local_record then
        local name = local_record.fqtn or local_record.name
        checker.typeerror(errors, loc,
            "cannot export local record type '%s' from Titan module '%s'",
            name, modname)
    end
end

local function reject_exported_local_record_types(modname, modast, errors)
    for _, node in ipairs(modast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and not node.islocal then
                reject_exported_local_record_type(modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelFunc" and not node.islocal then
                reject_exported_local_record_type(modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelRecord" and not node.islocal then
                for i, field in ipairs(node._type.fields) do
                    if not field.islocal then
                        local loc = node.fields[i] and node.fields[i].loc or node.loc
                        reject_exported_local_record_type(modname, errors, loc, field.type)
                    end
                end
            elseif (tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic")
                   and not node.islocal then
                reject_exported_local_record_type(modname, errors, node.loc, node._type)
            end
        end
    end
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
    catch_depth = 0
    in_finally = 0
    finally_loop_floor = 0
    loop_depth = 0
    local st = symtab.new(modname)
    if filename then
        st.source_dir = filename:match("^(.*)/[^/]*$")
        if not st.source_dir or st.source_dir == "" then
            st.source_dir = "."
        end
    end
    local errors = {subject = subject, filename = filename}
    checktoplevel(ast, st, errors, loader)
    checkbodies(ast, st, errors)
    reject_exported_c_ffi_types(modname, ast, errors)
    reject_exported_local_record_types(modname, ast, errors)
    ast._type = makemoduletype(modname, ast)
    return ast._type, errors
end

return checker
