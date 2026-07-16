local checker = {}

local location = require "titan-compiler.location"
local symtab = require "titan-compiler.symtab"
local types = require "titan-compiler.types"
local ast = require "titan-compiler.ast"
local util = require "titan-compiler.util"
local foreigntypes = require "titan-compiler.foreigntypes"
local cdriver = require("c-parser.cdriver")

-- The compiler driver installs the exact C toolchain configuration used for
-- generated code. Keeping this small hook in the checker makes every foreign
-- import use the same compiler, language mode, and already parsed CPP flags,
-- while checker-only embeddings retain cdriver's environment-based defaults.
local foreign_c_options = {}
local foreign_c_config_error

function checker.configure_foreign_c(options, config_error)
    foreign_c_options = options or {}
    foreign_c_config_error = config_error
end


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
local annotate_call_results
local check_generic_result_limit

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

-- Recursively checks that every nominal type in a resolved declaration exists.
local function checktype(typ, loc, errors, seen)
    if type(typ) ~= "table" or not typ._tag then return end
    seen = seen or {}
    if seen[typ] then return end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Nominal" and not types.registry[typ.fqtn] then
        checker.typeerror(errors, loc,
            "invalid type '%s' in type declaration", typ.fqtn)
    elseif tag == "Type.Array" then
        checktype(typ.elem, loc, errors, seen)
    elseif tag == "Type.Map" then
        checktype(typ.keys, loc, errors, seen)
        checktype(typ.values, loc, errors, seen)
    elseif tag == "Type.Option" then
        checktype(typ.base, loc, errors, seen)
    elseif tag == "Type.Function" then
        for _, param in ipairs(typ.params) do
            checktype(param, loc, errors, seen)
        end
        for _, rettype in ipairs(typ.rettypes) do
            checktype(rettype, loc, errors, seen)
        end
        if typ.varargtype then
            checktype(typ.varargtype, loc, errors, seen)
        end
        if typ.flexrettype then
            checktype(typ.flexrettype, loc, errors, seen)
        end
    end
end

-- Resolve a Titan alias to the RHS type object itself. The state lives on the
-- declaration so every use shares one pointer and a forward alias chain is
-- resolved only once. Encountering a declaration already being resolved marks
-- the cycle invalid before unwinding, preventing both recursion and cascades.
local function resolve_type_alias(node, st, errors)
    if node._alias_state == "resolved" then
        return node._type
    elseif node._alias_state == "resolving" then
        checker.typeerror(errors, node.type.loc or node.loc,
            "cyclic type alias involving '%s'", node.name)
        node._type = types.Invalid()
        node._alias_state = "resolved"
        return node._type
    end

    node._alias_state = "resolving"
    local target = typefromnode(node.type, st, errors)
    -- A recursive visit marks this declaration resolved/invalid. Preserve that
    -- result instead of wrapping it back in the structural RHS on unwind.
    if node._alias_state == "resolved" then
        return node._type
    end
    node._type = target
    node._alias_state = "resolved"
    return target
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

-- The native input-vararg and flexible-result ABIs share the seven
-- `TitanVargX` descriptor representations. Keep the checker-side inventory
-- explicit so unsupported source types are rejected before the coder would
-- need to choose a descriptor.
local function has_varg_representation(t)
    if types.is_c_tvalue(t) then
        -- The coder deliberately maps Lua's by-value TValue FFI spelling to
        -- TitanVargValue, the same descriptor used by Titan `value`.
        return true
    end
    local tag = t._tag
    if tag == "Type.Invalid" then
        return true -- avoid cascading after an earlier type error
    elseif tag == "Type.Integer" or tag == "Type.Float"
        or tag == "Type.Boolean" or tag == "Type.String"
        or tag == "Type.Array" or tag == "Type.Map"
        or tag == "Type.Value" or tag == "Type.Nominal"
        or tag == "Type.Function" or tag == "Type.COwned" then
        return true
    elseif tag == "Type.Option" then
        -- Option values use the TValue descriptor, unless their tree contains
        -- a C FFI type that `ctype` would route through foreign C lowering.
        return not types.is_c(t)
    elseif tag == "Type.Typedef" then
        return has_varg_representation(t._type)
    end
    return false
end

-- Validate the element type shared by an input variadic parameter and a
-- flexible return tail. `role` is either "parameter" or "return", solely to
-- keep diagnostics precise at the source construct.
local function check_varg_elem(t, loc, errors, role)
    local subject = role == "return"
        and "a flexible return" or "a variadic parameter"
    if t._tag == "Type.Nil" then
        checker.typeerror(errors, loc,
            "%s cannot have type nil", subject)
        return types.Invalid()
    elseif t._tag == "Type.Pointer"
           or types.resolve_c_typedef(t)._tag == "Type.CPointer" then
        checker.typeerror(errors, loc,
            "%s cannot have a foreign pointer type", subject)
        return types.Invalid()
    elseif not has_varg_representation(t) then
        checker.typeerror(errors, loc,
            "%s cannot use type %s because it has no supported variadic-value representation",
            subject, types.tostring(t))
        return types.Invalid()
    end
    return t
end

-- Resolve the fixed parameter types of a function/method/static/lambda and, if
-- the last `Ast.Decl` is the trailing vararg marker (`name == false`), drop it
-- from the fixed list and return its (validated) element type as the second
-- value. `params` is the AST param list; this is the single place the signature
-- pass + lambda checker turn the parser's vararg encoding into a `varargtype`.
--   returns (ptypes, varargtype, paramnames) where varargtype is a type or
--   false and paramnames is the dense list of fixed declaration names.
local function param_types(params, st, errors)
    local ptypes = {}
    local paramnames = {}
    local varargtype = false
    local n = #params
    for i, pdecl in ipairs(params) do
        if i == n and pdecl.name == false then
            varargtype = check_varg_elem(
                typefromnode(pdecl.type, st, errors), pdecl.loc, errors,
                "parameter")
        else
            table.insert(ptypes, typefromnode(pdecl.type, st, errors))
            table.insert(paramnames, pdecl.name)
        end
    end
    return ptypes, varargtype, paramnames
end

local function flexible_return_type(node, st, errors)
    if not node.flexrettype then
        return false
    end
    return check_varg_elem(
        typefromnode(node.flexrettype, st, errors),
        node.flexrettype.loc or node.loc, errors, "return")
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
    return types.Function(cfunc.params, rettypes, cfunc.vararg, false, false)
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
            type = types.Function({}, { c_owned_type(typ, false) }, false,
                false, false),
        }
    elseif name == "new_array" then
        return {
            _tag = "Type.CPseudoNew",
            ctype = typ,
            name = name,
            array = true,
            type = types.Function({ types.Integer() },
                { c_owned_type(typ, true) }, false, false, false),
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

    ["Ast.TypeName"] = function(node, st, errors)
        local alias = st:find_type_alias(node.name)
        if alias then
            return resolve_type_alias(alias, st, errors)
        end
        return types.Nominal(st.modname .. "." .. node.name)
    end,

    ["Ast.TypeQualName"] = function(node, st, errors)
        local mod = st:find_symbol(node.module)
        if mod and mod._type._tag == "Type.Module" then
            local alias = mod._type.type_members
                and mod._type.type_members[node.name]
            if alias then
                return alias
            end
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
            and check_varg_elem(typefromnode(node.varargtype, st, errors),
                                node.varargtype.loc, errors, "parameter")
            or false
        local flexrettype = flexible_return_type(node, st, errors)
        return types.Function(ptypes, rettypes, false, varargtype, flexrettype)
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
        n._implicit_coercion = true
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
            inner._implicit_coercion = true
            inner._type = source._type.base
            n = trycoerce(inner, target, errors)
        elseif target._tag == "Type.Option" then
            if source._type._tag == "Type.Nil"
               or source._type._tag == "Type.Value" then
                -- nil/value -> T?: emit the cast directly so nil remains nil.
                -- Recursing through target.base would first coerce nil (or a
                -- value holding nil) to the non-option base, either changing
                -- its meaning (nil -> boolean = false) or raising before the
                -- option has a chance to preserve it.
                n = ast.ExpCast(source.loc, source, target)
            else
                n = ast.ExpCast(source.loc, trycoerce(source, target.base, errors), target)
            end
        else
            n = ast.ExpCast(source.loc, source, target)
        end
        n._implicit_coercion = true
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

local function nil_can_adjust_to(typ)
    return typ and (types.coerceable(types.Nil(), typ)
        or types.compatible(typ, types.Nil()))
end

-- Expression-list demand.  `fixed` is always dense: UNKNOWN_SLOT represents a
-- position whose type is not known yet (notably an inferred local).  `tail` is
-- false for a finite consumer, a Type.* value for an open typed consumer, or
-- INFER_OPEN for an open consumer whose element type is inferred from its
-- inputs.  Keeping the sentinels as real table values is important: using nil
-- for an unknown slot would make Lua's length operator collapse the demand.
local UNKNOWN_SLOT = {}
local INFER_OPEN = {}
local TITAN_VARARG_MAX = 200
-- Lua 5.5 stores a finite VM result request in the current CallInfo's
-- CIST_NRESULTS field.  `MAXRESULTS` is therefore an independent boundary from
-- Titan's 200-element flexible descriptor: a finite generic function-value
-- call may not ask the VM for more results than this. Statically open generic
-- calls use LUA_MULTRET and do not cross the finite-result encoding boundary.
local LUA_VM_MAX_RESULTS = 250

local function result_demand(fixed, tail, opts)
    opts = opts or {}
    return {
        fixed = fixed or {},
        tail = tail or false,
        missing = opts.missing or "error",
        explicit_surplus = opts.explicit_surplus or "discard",
        term = opts.term or "expression list",
        slot_term = opts.slot_term,
        loc = opts.loc,
        open_term = opts.open_term,
        return_arity = opts.return_arity,
        open_coerce = opts.open_coerce,
        check_expression = opts.check_expression,
        dots_limit = opts.dots_limit,
        dots_nilfill = opts.dots_nilfill,
        defer_open_check = opts.defer_open_check,
        suppress_flex_cap = opts.suppress_flex_cap,
    }
end

local function expected_type(typ)
    if typ == UNKNOWN_SLOT or typ == INFER_OPEN then
        return nil
    end
    return typ
end

-- Build a structural function result shape from the same demand vocabulary
-- used by expression-list adjustment. Unknown finite/open slots become
-- `value`; a typed open slot is validated as a flexible-return descriptor at
-- the sink location. Generic-for and ordinary calls through `value` share this
-- constructor so their contextual function types cannot drift apart.
local function synthesize_function_type(params, varargtype, demand, loc,
                                        errors)
    local rettypes = {}
    for i, target in ipairs(demand.fixed) do
        rettypes[i] = expected_type(target) or types.Value()
    end

    local flexrettype = false
    if demand.tail then
        flexrettype = expected_type(demand.tail) or types.Value()
        flexrettype = check_varg_elem(flexrettype,
            demand.loc or loc, errors, "return")
    end

    return types.Function(params, rettypes, false, varargtype or false,
        flexrettype)
end

local function demand_term(demand, index)
    if demand.slot_term then
        return demand.slot_term(index)
    end
    return demand.term
end

local function mark_discarded(exp)
    exp._discard_results = true
    if exp._tag == "Ast.ExpCall" then
        exp._voidok = true
    end
end

local function coerce_demanded_value(exp, target, term, errors)
    target = expected_type(target)
    if not target then return exp end
    local source = exp
    exp = trycoerce(exp, target, errors)
    if source._missing_value then exp._missing_value = true end
    checkmatch(term, target, exp._type, errors, exp.loc)
    return exp
end

local function remaining_demand(demand, first)
    local fixed = {}
    for i = first, #demand.fixed do
        table.insert(fixed, demand.fixed[i])
    end
    return result_demand(fixed, demand.tail, {
        missing = demand.missing,
        explicit_surplus = demand.explicit_surplus,
        term = demand.term,
        slot_term = demand.slot_term and function(i)
            return demand.slot_term(first + i - 1)
        end or nil,
        loc = demand.loc,
        open_term = demand.open_term,
        return_arity = demand.return_arity,
        open_coerce = demand.open_coerce,
        check_expression = demand.check_expression,
        dots_limit = demand.dots_limit,
        dots_nilfill = demand.dots_nilfill,
        defer_open_check = demand.defer_open_check,
        suppress_flex_cap = demand.suppress_flex_cap,
    })
end

-- Return the finite values made visible by checking `exp` under its demand.
-- Calls publish a consumer-visible projection separately from their declared
-- ABI result list; every other expression is scalar.
local function finite_result_expressions(exp)
    if exp._tag ~= "Ast.ExpCall" then
        return { exp }
    end

    local visible = exp._visible_types or exp._types or {}
    local out = {}
    for i, typ in ipairs(visible) do
        local value
        if i == 1 then
            value = exp
        else
            value = ast.ExpExtra(exp.loc, exp, i, typ)
        end
        local source = exp._result_sources and exp._result_sources[i]
        if source then
            value._result_source = source
            if source.kind == "flex" then
                value._from_flex = true
                value._possibly_absent = source.may_absent and true or false
            end
        end
        table.insert(out, value)
    end
    return out
end

-- Check and elaborate one expression list under a finite/open demand.  The
-- returned `exps` preserves every written expression in lexical order; extra
-- fixed projections are synthesized after the trailing producer, while
-- explicit surplus expressions remain present and are marked for effect-only
-- lowering.  `fixed` and `tail_scalars` describe the values delivered to the
-- sink, and `open_source` identifies the sole possible runtime-sized final run.
local function adjust_explist(exps, demand, st, errors)
    local adjusted = {
        exps = {},
        fixed = {},
        tail_scalars = {},
        discards = {},
        open_source = false,
        open_type = false,
        open_target = false,
        open_start = false,
    }
    local next_fixed = 1

    local function current_target()
        if next_fixed <= #demand.fixed then
            return demand.fixed[next_fixed], false
        elseif demand.tail then
            return demand.tail, true
        end
        return nil, false
    end

    local function accept(exp, target, intail)
        local index = next_fixed
        local term = intail and demand.term or demand_term(demand, index)
        exp = coerce_demanded_value(exp, target, term, errors)
        if intail then
            exp._demand_tail = true
            table.insert(adjusted.tail_scalars, exp)
        else
            exp._demand_slot = index
            adjusted.fixed[index] = exp
            next_fixed = next_fixed + 1
        end
        return exp
    end

    local function discard(exp, explicit)
        mark_discarded(exp)
        table.insert(adjusted.discards, exp)
        if explicit and demand.explicit_surplus == "error" then
            adjusted.explicit_surplus = (adjusted.explicit_surplus or 0) + 1
        end
        return exp
    end

    local n = #exps
    local last = exps[n]
    local has_dots = last and last._tag == "Ast.ExpDots"

    local function check_expression(exp, context, subdemand, sink_index)
        if demand.check_expression then
            demand.check_expression(exp, st, errors, context, subdemand,
                sink_index)
        else
            checkexp(exp, st, errors, context, subdemand)
        end
    end

    -- Every non-final expression is scalar.  Once the finite prefix is full it
    -- contributes one tail scalar, or is retained under a zero-result demand.
    for i = 1, math.max(n - 1, 0) do
        local exp = exps[i]
        local target, intail = current_target()
        local subdemand
        if target then
            subdemand = result_demand({ target }, false, {
                term = demand_term(demand, next_fixed),
            })
        else
            subdemand = result_demand({}, false, { term = demand.term })
            mark_discarded(exp)
        end
        check_expression(exp, expected_type(target), subdemand, next_fixed)
        if target then
            exp = accept(exp, target, intail)
        else
            exp = discard(exp, true)
        end
        table.insert(adjusted.exps, exp)
    end

    if has_dots then
        check_dots_marker(last, st, errors)
        local elem = last._vararg_elem
        local projection = 1
        -- Some structured finite consumers deliberately use fewer elements of
        -- a trailing `...` than their padded storage width. Generic `for`, for
        -- example, borrows only the iterator's state/control inputs unless the
        -- source explicitly reaches the optional close slot; its fourth tuple
        -- position is then synthesized as nil. The callback runs after every
        -- written prefix expression has been checked, so it can inspect the
        -- iterator's resolved function type without a separate checking pass.
        local dots_limit = demand.dots_limit
            and demand.dots_limit(exps) or #demand.fixed
        while next_fixed <= #demand.fixed and next_fixed <= dots_limit do
            local target = demand.fixed[next_fixed]
            local target_type = expected_type(target)
            local index = ast.ExpInteger(last.loc, projection)
            index._type = types.Integer()
            local exp = ast.ExpDotsIndex(last.loc, index)
            local forced_nilfill = demand.dots_nilfill
            if type(forced_nilfill) == "function" then
                forced_nilfill = forced_nilfill(next_fixed, target_type)
            end
            local nilfill = forced_nilfill
                or (target_type and nil_can_adjust_to(target_type))
            exp._nilfill = nilfill and true or false
            exp._type = nilfill and optionize(elem) or elem
            exp._from_dots = true
            exp._dots_index = projection
            exp = accept(exp, target, false)
            table.insert(adjusted.exps, exp)
            projection = projection + 1
        end
        if demand.tail then
            last._open_dots = {
                source_type = elem,
                target_type = expected_type(demand.tail) or elem,
                start = projection,
            }
            adjusted.open_source = last
            adjusted.open_type = elem
            adjusted.open_target = expected_type(demand.tail) or elem
            adjusted.open_start = projection
            table.insert(adjusted.exps, last)
        elseif projection == 1 then
            discard(last, true)
        end
    elseif last then
        local target = current_target()
        local subdemand = remaining_demand(demand, next_fixed)
        if not target and not demand.tail then
            mark_discarded(last)
        end
        check_expression(last, expected_type(target), subdemand, next_fixed)
        table.insert(adjusted.exps, last)

        local values = finite_result_expressions(last)
        if #values == 0 then
            -- A flex-only producer has no finite scalar but its dynamic run is
            -- the value consumed by an open sink. Do not simultaneously mark
            -- that same call as effect-only/discarded. A statically zero-result
            -- fixed producer has no open run and remains an effect-only entry.
            if not last._open_results then
                discard(last, target == nil and not demand.tail)
            end
        else
            for i, exp in ipairs(values) do
                local value_target, intail = current_target()
                if value_target then
                    exp = accept(exp, value_target, intail)
                    if i == 1 then
                        adjusted.exps[#adjusted.exps] = exp
                    else
                        table.insert(adjusted.exps, exp)
                    end
                elseif i == 1 then
                    adjusted.exps[#adjusted.exps] = discard(exp, true)
                end
            end
        end

        if last._open_results then
            adjusted.open_source = last
            adjusted.open_type = last._open_results.source_type
            adjusted.open_target = last._open_results.target_type
            adjusted.open_start = last._open_results.start
        end
    end

    if next_fixed <= #demand.fixed then
        adjusted.missing = #demand.fixed - next_fixed + 1
        if demand.missing == "nil" then
            while next_fixed <= #demand.fixed do
                local exp = ast.ExpNil(last and last.loc or demand.loc)
                exp._type = types.Nil()
                exp._missing_value = true
                exp = accept(exp, demand.fixed[next_fixed], false)
                table.insert(adjusted.exps, exp)
            end
        elseif demand.missing ~= "ignore" then
            if demand.return_arity then
                checker.typeerror(errors, last and last.loc or demand.loc,
                    "returned %d value(s) but function expected %d",
                    next_fixed - 1, #demand.fixed)
            else
                checker.typeerror(errors, last and last.loc or demand.loc,
                    "%s expects %d value(s) but the expression list produces %d",
                    demand.term, #demand.fixed, next_fixed - 1)
            end
        end
    end


    local open_compatible = adjusted.open_source
        and (types.equals(adjusted.open_type, adjusted.open_target)
             or types.compatible(adjusted.open_target, adjusted.open_type)
             -- Flexible call results are converted element-wise by their sink.
             -- Preserve the older input-`...` contract: forwarding a whole
             -- vararg descriptor requires compatibility, not merely a scalar
             -- coercion such as integer -> float.
             or ((adjusted.open_source._tag ~= "Ast.ExpDots"
                  or demand.open_coerce)
                 and types.coerceable(adjusted.open_type,
                                      adjusted.open_target)))
    if adjusted.open_source and not demand.defer_open_check
       and adjusted.open_type._tag ~= "Type.Invalid"
       and adjusted.open_target._tag ~= "Type.Invalid"
       and not open_compatible then
        if adjusted.open_source._tag == "Ast.ExpDots" then
            checker.typeerror(errors, adjusted.open_source.loc,
                "'...' element type %s is not compatible with the '...' element type %s of %s",
                types.tostring(adjusted.open_type),
                types.tostring(adjusted.open_target),
                demand.open_term or demand.term)
        else
            checker.typeerror(errors, adjusted.open_source.loc,
                "open result element type %s is not compatible with %s element type %s",
                types.tostring(adjusted.open_type), demand.term,
                types.tostring(adjusted.open_target))
        end
    end

    return adjusted
end

local function replace_adjusted_value(adjusted, old, new)
    if old == new then return end
    for i, exp in ipairs(adjusted.exps) do
        if exp == old then
            adjusted.exps[i] = new
            break
        end
    end
    for i, exp in pairs(adjusted.fixed) do
        if exp == old then adjusted.fixed[i] = new end
    end
    for i, exp in ipairs(adjusted.tail_scalars) do
        if exp == old then adjusted.tail_scalars[i] = new end
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

-- A trailing `...` in the generic-for setup tuple supplies the iterator plus
-- only the fixed state/control inputs that iterator can consume. The tuple's
-- fourth storage slot is the optional close callable; it must remain the
-- ordinary synthesized nil unless the written prefix actually reaches it.
-- This preserves the pre-demand-elaboration generic-for contract while still
-- routing the projections through `adjust_explist`.
local function forin_dots_limit(exps)
    local prefix = #exps - 1
    local limit = 4
    local ftype = exps[1] and exps[1]._type
    local cfunc = ftype and c_function_pointer_type(ftype)
    if cfunc then
        ftype = c_function_as_function_type(cfunc)
    end
    if ftype and ftype._tag == "Type.Function" then
        limit = math.max(prefix + 1, 1 + math.min(#ftype.params, 2))
        if limit > 4 then limit = 4 end
    end
    return limit
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
    if #ftype.rettypes > 1 or ftype.varargtype or ftype.flexrettype then
        return nil
    end
    local ret = ftype.rettypes[1] or types.CVoid()
    return types.CPointer(types.CFunction(ftype.params, ret, ftype.vararg, false), {})
end

local function check_forin_callable_exp(exp, st, errors, context, demand)
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
    checkexp(exp, st, errors, context, demand)
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
    return synthesize_function_type(params, false,
        result_demand(rettypes, false, { loc = node.loc }), node.loc, errors)
end

local function synthesize_forin_close_type(exps)
    local params = {}
    if exps[2]._type._tag ~= "Type.Nil" then
        table.insert(params, exps[2]._type)
    end
    return types.Function(params, {}, false, false, false)
end

local function forin_nil_capable_control(typ)
    local rtyp = c_resolve(typ)
    return typ._tag == "Type.Option"
        or typ._tag == "Type.Value"
        or typ._tag == "Type.Invalid"
        or types.is_c_tvalue(typ)
        or (rtyp and rtyp._tag == "Type.CPointer")
end

local function forin_effective_results(ftype, count)
    local results = {}
    for i = 1, count do
        if ftype.rettypes[i] then
            results[i] = ftype.rettypes[i]
        elseif ftype.flexrettype then
            results[i] = optionize(ftype.flexrettype)
        else
            break
        end
    end
    return results
end

local function make_forin_call(loc, iter_decl, args, ftype, nresults, cfunc,
                               errors, report_result_limit)
    local call = ast.ExpCall(loc, hidden_exp(loc, iter_decl),
        ast.ArgsFunc(loc, args))
    call._c_pointer_call = cfunc
    local fixed = {}
    for i = 1, nresults do fixed[i] = UNKNOWN_SLOT end
    local demand = result_demand(fixed, false, {
        term = "generic for iterator results",
        loc = loc,
        suppress_flex_cap = true,
    })
    annotate_call_results(call, ftype, demand, errors)
    if not cfunc then
        check_generic_result_limit(call, errors, report_result_limit)
    end
    call._arg_adjustment = {
        exps = args,
        fixed = args,
        tail_scalars = {},
        discards = {},
        open_source = false,
    }
    call._npassed_args = #args
    call._open_args = false
    return call
end

local function checkforin(node, st, errors)
    local tuple_fixed = {
        UNKNOWN_SLOT, UNKNOWN_SLOT, UNKNOWN_SLOT, UNKNOWN_SLOT,
    }
    local tuple_adjustment = adjust_explist(node.exps,
        result_demand(tuple_fixed, false, {
            term = "generic for iterator tuple",
            loc = node.loc,
            missing = "nil",
            explicit_surplus = "discard",
            dots_limit = forin_dots_limit,
            -- Lua's generic-for setup tuple adjusts missing state/control
            -- values upward with nil. A close callable projected into slot 4
            -- retains the established typed/raising `...` read: the current
            -- lowering has a statically present close call and therefore must
            -- not turn its type into an option merely because the backing run
            -- can be short.
            dots_nilfill = function(slot)
                return slot < 4
            end,
            check_expression = function(exp, est, eerrors, context, demand,
                                        sink_index)
                if sink_index == 1 or sink_index == 4 then
                    check_forin_callable_exp(exp, est, eerrors, context,
                        demand)
                else
                    checkexp(exp, est, eerrors, context, demand)
                end
            end,
        }), st, errors)
    node._tuple_adjustment = tuple_adjustment
    local exps = {}
    for i = 1, 4 do exps[i] = tuple_adjustment.fixed[i] end
    -- Keep the four lowered tuple values in the legacy field for current
    -- generic-for codegen. Every written surplus expression remains owned by
    -- `_tuple_adjustment.exps` with discard metadata for the demand-aware coder.
    node.exps = exps

    -- The iterator slot is required. A finite projection from a flexible tuple
    -- is optional, so use the ordinary runtime unwrap before callable
    -- resolution; an absent iterator fails at the same force boundary as any
    -- other optional callable used as a value.
    local raw_iter = exps[1]
    exps[1] = tryforce(exps[1])
    replace_adjusted_value(tuple_adjustment, raw_iter, exps[1])
    node.exps[1] = exps[1]

    local ftype = exps[1]._type
    local iter_cfunc
    if ftype._tag == "Type.Value" then
        ftype = synthesize_forin_iterator_type(node, st, errors)
        local old = exps[1]
        exps[1] = trycoerce(exps[1], ftype, errors)
        replace_adjusted_value(tuple_adjustment, old, exps[1])
        ftype = exps[1]._type
    else
        ftype, iter_cfunc = forin_ftype_from_slot_type(ftype)
    end
    if not ftype then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator must be a function, value, or C function pointer but found %s",
            types.tostring(exps[1]._type))
        ftype = types.Function({}, { types.Invalid() }, false, false, false)
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
    local effective_count = math.max(#node.decls, 1)
    if ftype.flexrettype then
        local flex_count = math.max(effective_count - #ftype.rettypes, 0)
        if flex_count > TITAN_VARARG_MAX then
            checker.typeerror(errors, exps[1].loc,
                "finite flexible-result demand is %d value(s), maximum is %d",
                flex_count, TITAN_VARARG_MAX)
        end
    end
    local effective_results = forin_effective_results(ftype, effective_count)
    if #effective_results == 0 then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator must return at least one value")
        ftype = types.Function(ftype.params, { types.Invalid() }, false, false,
            false)
        effective_results = { types.Invalid() }
    else
        local ctrltype = effective_results[1]
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
        local old = exps[2]
        exps[2] = trycoerce(exps[2], ftype.params[1], errors)
        replace_adjusted_value(tuple_adjustment, old, exps[2])
        checkmatch("generic for iterator state",
            ftype.params[1], exps[2]._type, errors, exps[2].loc)
    end
    if ftype.params[2] then
        local old = exps[3]
        exps[3] = trycoerce(exps[3], ftype.params[2], errors)
        replace_adjusted_value(tuple_adjustment, old, exps[3])
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
            local old = exps[4]
            exps[4] = trycoerce(exps[4], close_ftype, errors)
            replace_adjusted_value(tuple_adjustment, old, exps[4])
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
    for i, rtype in ipairs(effective_results) do
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
        init_args, ftype, #effective_results, iter_cfunc, errors, true)

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
        next_args, ftype, #effective_results, iter_cfunc, errors, false)

    if node._has_close then
        local close_args = {}
        if close_ftype.params[1] then
            local close_arg = hidden_exp(node.loc, node._tuple_decls[2])
            close_arg = trycoerce(close_arg, close_ftype.params[1], errors)
            table.insert(close_args, close_arg)
        end
        node._close_call = make_forin_call(node.loc, node._tuple_decls[4],
            close_args, close_ftype, 0, close_cfunc, errors, false)
        node._close_call._voidok = true
    end

    local visible_exps = {}
    for i, decl in ipairs(node.decls) do
        local exp
        if effective_results[i] then
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
        local fixed = {}
        for i, decl in ipairs(node.decls) do
            if decl.type then
                checkdecl(decl, st, errors)
                fixed[i] = decl._type
            else
                fixed[i] = UNKNOWN_SLOT
            end
        end

        local adjusted = adjust_explist(node.exps,
            result_demand(fixed, false, {
                term = "left-hand side",
                loc = node.loc,
                missing = "error",
                explicit_surplus = "discard",
                slot_term = function(i)
                    local decl = node.decls[i]
                    return decl and
                        ("declaration of local variable " .. decl.name)
                        or "local declaration"
                end,
            }), st, errors)
        node.exps = adjusted.exps
        node._result_adjustment = adjusted

        for i, decl in ipairs(node.decls) do
            local exp = adjusted.fixed[i]
            if exp and not decl.type then
                local old = exp
                if decl.option then
                    decl._type = optionize(exp._type)
                else
                    exp = tryforce(exp) -- never infer an option type
                    decl._type = exp._type
                end
                checkdecl(decl, st, errors)
                exp = trycoerce(exp, decl._type, errors)
                checkmatch("declaration of local variable " .. decl.name,
                    decl._type, exp._type, errors, decl.loc)
                replace_adjusted_value(adjusted, old, exp)
            end
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
        node.exps = adjusted.exps
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
        local fixed = {}
        for i, var in ipairs(node.vars) do
            -- Module values are never assignable and have no ordinary value
            -- coercion/tostring path; preserve the dedicated diagnostic below
            -- while still reserving their finite expression-list slot.
            local decl = var._decl
            local function_decl = var._type._tag == "Type.Function" and decl
                and (decl._tag == "Ast.TopLevelFunc"
                     or decl._tag == "Type.ModuleMember"
                     or decl._tag == "Type.StaticMethod")
            fixed[i] = (var._type._tag == "Type.Module" or function_decl)
                and UNKNOWN_SLOT or var._type
        end
        local adjusted = adjust_explist(node.exps,
            result_demand(fixed, false, {
                term = "left-hand side",
                loc = node.loc,
                missing = "error",
                explicit_surplus = "discard",
                slot_term = function() return "assignment" end,
            }), st, errors)
        node.exps = adjusted.exps
        node._result_adjustment = adjusted

        for i, var in ipairs(node.vars) do
            local exp = adjusted.fixed[i]
            if exp then
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
                    local old = exp
                    exp = trycoerce(exp, var._type, errors)
                    replace_adjusted_value(adjusted, old, exp)
                    checkmatch("assignment", var._type, exp._type, errors, var.loc)
                end
            end
        end
        node.exps = adjusted.exps
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
        if #node.exps == 0 and #ftype.rettypes == 1
           and ftype.rettypes[1]._tag == "Type.Nil" then
            -- A bare `return` in a nil-returning function means `return nil`.
            local nilexp = ast.ExpNil(node.loc)
            nilexp._type = types.Nil()
            table.insert(node.exps, nilexp)
        end

        local fixed = {}
        for i, typ in ipairs(ftype.rettypes) do fixed[i] = typ end
        local adjusted = adjust_explist(node.exps,
            result_demand(fixed, ftype.flexrettype, {
                term = "return",
                loc = node.loc,
                missing = "error",
                explicit_surplus = "discard",
                return_arity = true,
                open_coerce = true,
                slot_term = function() return "return" end,
            }), st, errors)
        node.exps = adjusted.exps
        node._result_adjustment = adjusted
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
                        decl.varargtype, decl.flexrettype)
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

-- Mirror the lowering distinction that matters to the checker: declarations
-- with a statically named native entry never need Lua's finite-result request,
-- while calls through locals, fields, casts, lambdas, bound methods, and other
-- function values retain a generic VM branch.  C calls are handled before this
-- predicate is consulted.
local function uses_generic_callable_boundary(node)
    if node.args._tag ~= "Ast.ArgsFunc" then return false end
    if node.exp._tag ~= "Ast.ExpVar" then return true end
    local decl = node.exp.var._decl
    return not (decl and (decl._tag == "Ast.TopLevelFunc"
        or decl._tag == "Type.ModuleMember"
        or decl._tag == "Type.StaticMethod"))
end

check_generic_result_limit = function(node, errors, report_error)
    if not uses_generic_callable_boundary(node) then return end
    -- Every statically open generic producer uses LUA_MULTRET. Its actual count
    -- is measured from the restored stack top and adjusted by Titan afterward,
    -- so only genuinely finite calls use CallInfo's bounded result field.
    if node._open_results then return end

    local requested = #(node._visible_types or {})
    if requested and requested > LUA_VM_MAX_RESULTS
       and report_error ~= false then
        checker.typeerror(errors, node.loc,
            "function-value call can require %d finite VM results, but "
            .. "Lua 5.5 supports at most %d; reduce the result demand or "
            .. "use a direct Titan call",
            requested, LUA_VM_MAX_RESULTS)
    end
end

-- Typecheck a positional argument list through the shared expression-list
-- demand. Titan calls nil-pad missing fixed positions and retain explicit
-- surplus expressions for effects; strict C calls neither pad nor relax their
-- ABI shape. `allow_missing == false` is the existing call-site signal for a C
-- function pointer/direct FFI/pseudo-constructor.
local function checkargs(ftype, args, loc, fname, st, errors, allow_missing)
    if allow_missing == nil then allow_missing = true end
    local strict_c = not allow_missing
    local fixed = {}
    for i, ptype in ipairs(ftype.params) do fixed[i] = ptype end
    local tail = ftype.varargtype or (ftype.vararg and INFER_OPEN) or false
    local original_count = #args
    local adjusted = adjust_explist(args,
        result_demand(fixed, tail, {
            term = "call to " .. fname,
            open_term = fname,
            loc = loc,
            missing = strict_c and "ignore" or "nil",
            explicit_surplus = strict_c and "error" or "discard",
            slot_term = function(i)
                return "argument " .. i .. " of call to " .. fname
            end,
        }), st, errors)

    -- A runtime-sized Titan run has no C vararg promotion/ABI contract. Keep
    -- ordinary explicit C varargs, but never pass `...` or a flexible-result
    -- run through that boundary.
    if ftype.vararg and adjusted.open_source then
        checker.typeerror(errors, adjusted.open_source.loc,
            "cannot pass a runtime-open Titan result sequence to a foreign (C) variadic function")
    end

    if strict_c and (adjusted.missing or adjusted.explicit_surplus) then
        local supplied = adjusted.explicit_surplus and original_count
            or (#ftype.params - adjusted.missing)
        checker.typeerror(errors, loc,
            "%s called with %d arguments but expects %d.\n%s",
            fname, supplied, #ftype.params, types.tostring(ftype))
    end

    for i = #args, 1, -1 do args[i] = nil end
    for _, exp in ipairs(adjusted.exps) do table.insert(args, exp) end
    return adjusted
end

local function annotate_call_arguments(node, adjusted)
    node._arg_adjustment = adjusted
    node._npassed_args = 0
    for _, _ in pairs(adjusted.fixed) do
        node._npassed_args = node._npassed_args + 1
    end
    node._npassed_args = node._npassed_args + #adjusted.tail_scalars
    node._open_args = adjusted.open_source and {
        source = adjusted.open_source,
        source_type = adjusted.open_type,
        target_type = adjusted.open_target,
        start = adjusted.open_start,
    } or false
end

-- Return the expressions carried by either positional or named call syntax.
-- Named calls are normalized only after eligibility and per-name checking, so
-- every error-recovery path must understand both payload shapes.
local function call_argument_expressions(args)
    if args._tag == "Ast.ArgsFunc" or args._tag == "Ast.ArgsMethod" then
        return args.args
    end
    assert(args._tag == "Ast.ArgsNamedFunc"
        or args._tag == "Ast.ArgsNamedMethod")
    local exps = {}
    for _, field in ipairs(args.fields) do
        table.insert(exps, field.exp)
    end
    return exps
end

local function check_call_argument_expressions(args, st, errors)
    for _, exp in ipairs(call_argument_expressions(args)) do
        checkexp(exp, st, errors)
    end
end

local function default_call_result_demand(node, context)
    if node._voidok then
        return result_demand({}, false, { term = "discarded call" })
    end
    return result_demand({ context or UNKNOWN_SLOT }, false, {
        term = "call expression",
    })
end

-- Discover the complete statically visible positional input shape of a call
-- through `value`. The discovery demand is open and untyped, so it checks each
-- written argument exactly once, preserves all fixed results of the trailing
-- producer, and retains at most one runtime-open final run. Those statically
-- visible scalars then become the synthesized function's fixed parameters;
-- only the dynamic run remains its input vararg.
local function synthesize_value_call_inputs(args, loc, st, errors)
    local adjusted = adjust_explist(args,
        result_demand({}, INFER_OPEN, {
            term = "contextual value-call arguments",
            open_term = "contextual value call",
            loc = loc,
            missing = "error",
            explicit_surplus = "discard",
        }), st, errors)

    local params = {}
    local fixed = {}
    for i, exp in ipairs(adjusted.tail_scalars) do
        params[i] = exp._type
        fixed[i] = exp
        exp._demand_tail = nil
        exp._demand_slot = i
    end
    adjusted.fixed = fixed
    adjusted.tail_scalars = {}

    for i = #args, 1, -1 do args[i] = nil end
    for _, exp in ipairs(adjusted.exps) do
        table.insert(args, exp)
    end

    return params, adjusted.open_source and adjusted.open_type or false,
        adjusted
end

local function synthesize_value_call_type(node, demand, st, errors)
    local params, varargtype, adjusted = synthesize_value_call_inputs(
        node.args.args, node.loc, st, errors)

    return synthesize_function_type(params, varargtype, demand, node.loc,
        errors), adjusted
end

-- Record both result shapes of a checked call. `_types` remains the callable's
-- declared fixed ABI prefix for the existing coder; `_visible_types` and
-- `_result_sources` describe only what this consumer observes. A finite flex
-- projection is optional because its runtime slot may be absent. An open run
-- exists only when both the sink is open and the static callable type declares
-- a flexible tail.
annotate_call_results = function(node, ftype, demand, errors)
    demand = demand or default_call_result_demand(node)
    node._callee_type = ftype
    node._types = ftype.rettypes
    node._flexrettype = ftype.flexrettype or false
    node._visible_types = {}
    node._result_sources = {}
    node._open_results = false
    node._finite_flex_prefix = 0

    local nfixed = #ftype.rettypes
    local ndemand = #demand.fixed
    local function add(typ, source)
        table.insert(node._visible_types, typ)
        table.insert(node._result_sources, source)
    end

    for i = 1, math.min(ndemand, nfixed) do
        add(ftype.rettypes[i], { kind = "fixed", index = i })
    end
    if ftype.flexrettype and ndemand > nfixed then
        local count = ndemand - nfixed
        if count > TITAN_VARARG_MAX and not demand.suppress_flex_cap then
            checker.typeerror(errors, node.loc,
                "finite flexible-result demand is %d value(s), maximum is %d",
                count, TITAN_VARARG_MAX)
        end
        node._finite_flex_prefix = count
        for i = 1, count do
            add(optionize(ftype.flexrettype), {
                kind = "flex", index = i, may_absent = true,
            })
        end
    end

    if demand.tail then
        for i = ndemand + 1, nfixed do
            add(ftype.rettypes[i], { kind = "fixed", index = i })
        end
        if ftype.flexrettype then
            local start = math.max(ndemand - nfixed, 0) + 1
            local target = expected_type(demand.tail) or ftype.flexrettype
            node._open_results = {
                source = node,
                source_type = ftype.flexrettype,
                target_type = target,
                start = start,
            }
            node._flex_result_demand = "open"
        end
    elseif ftype.flexrettype then
        node._flex_result_demand = node._finite_flex_prefix
    else
        node._flex_result_demand = nil
    end

    node._type = node._visible_types[1] or types.Void()
end

-- Named syntax is deliberately declaration-only. Structural function values
-- do not carry parameter labels, so provenance -- not merely Type.Function --
-- decides eligibility. Returns (paramnames, lowering_kind, recognized_ffi),
-- where lowering_kind is "titan" or "foreign" and paramnames may be false for
-- a direct foreign declaration whose prototypes did not publish one complete,
-- unambiguous list.
local function named_function_metadata(node)
    if node.exp._tag ~= "Ast.ExpVar" then
        return nil
    end
    local var = node.exp.var
    local decl = var._decl
    if not decl then
        return nil
    elseif decl._tag == "Ast.TopLevelFunc" then
        return decl._paramnames, "titan", false
    elseif decl._tag == "Type.StaticMethod" then
        return decl.paramnames, "titan", false
    elseif decl._tag == "Type.ModuleMember"
           and decl.type and decl.type._tag == "Type.Function" then
        local foreign = var._tag == "Ast.VarDot"
            and var.exp and var.exp._type
            and var.exp._type._tag == "Type.CModule"
        return decl.paramnames, foreign and "foreign" or "titan", foreign
    end
    return nil
end

local function named_target_error(errors, loc)
    checker.typeerror(errors, loc,
        "named arguments require a direct Titan module function, "
        .. "record function, method, or fixed-arity FFI function")
end

-- Check a named list in lexical order, then produce the positional dense list
-- consumed by the existing native/direct-C lowering. The separate order map is
-- retained so codegen can evaluate explicit expressions in source order before
-- assembling operands in formal order.
local function check_named_args(ftype, paramnames, fields, loc, fname, st, errors)
    assert(type(paramnames) == "table")
    assert(#paramnames == #ftype.params,
        "declaration parameter-name metadata does not match its fixed arity")

    local byname = {}
    for i, name in ipairs(paramnames) do
        assert(type(name) == "string")
        if byname[name] then
            -- Duplicate parameter declarations are diagnosed while checking
            -- the callee body, but all signatures are published first. A later
            -- body may therefore try a named call before the invalid program is
            -- rejected. Keep that recovery path diagnostic-only: the spelling
            -- cannot identify one unambiguous formal position.
            checker.typeerror(errors, loc,
                "%s has duplicate parameter name '%s'; named arguments are unavailable",
                fname, name)
            for _, field in ipairs(fields) do
                checkexp(field.exp, st, errors)
            end
            return nil
        end
        byname[name] = i
    end

    local dense = {}
    local supplied = {}
    local order = {}
    for _, field in ipairs(fields) do
        local index = byname[field.name]
        if not index then
            checker.typeerror(errors, field.loc,
                "%s has no parameter named '%s'%s",
                fname, field.name,
                #paramnames > 0 and
                    ("; available parameters are " .. table.concat(paramnames, ", "))
                    or "")
            checkexp(field.exp, st, errors)
        else
            local ptype = ftype.params[index]
            checkexp(field.exp, st, errors, ptype)
            local exp = trycoerce(field.exp, ptype, errors)
            checkmatch("named argument '" .. field.name .. "' of " .. fname,
                ptype, exp._type, errors, field.loc)
            if supplied[index] then
                checker.typeerror(errors, field.loc,
                    "named argument '%s' is supplied more than once", field.name)
            else
                supplied[index] = true
                dense[index] = exp
                table.insert(order, index)
            end
        end
    end

    for i, name in ipairs(paramnames) do
        if not supplied[i] then
            local ptype = ftype.params[i]
            local exp = ast.ExpNil(loc)
            exp._type = types.Nil()
            if nil_can_adjust_to(ptype) then
                exp = trycoerce(exp, ptype, errors)
                checkmatch("omitted named argument '" .. name .. "' of " .. fname,
                    ptype, exp._type, errors, loc)
            else
                checker.typeerror(errors, loc,
                    "parameter '%s' of type %s cannot be omitted because it does not accept nil",
                    name, types.tostring(ptype))
            end
            exp._named_omitted = true
            dense[i] = exp
        end
    end
    return dense, order
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
            local exps = {}
            local invalid_named = false
            for _, field in ipairs(node.fields) do
                if field.name then
                    invalid_named = true
                    checker.typeerror(errors, field.loc,
                        "initializing field '%s' when expecting array", field.name)
                    checkexp(field.exp, st, errors)
                else
                    table.insert(exps, field.exp)
                end
            end
            if invalid_named then
                node._type = types.Array(econtext or types.Integer())
                return
            end

            local adjusted = adjust_explist(exps,
                result_demand({}, econtext or INFER_OPEN, {
                    term = "array initializer",
                    loc = node.loc,
                    missing = "error",
                    explicit_surplus = "discard",
                    open_coerce = true,
                    defer_open_check = true,
                }), st, errors)
            local etype = econtext
                or (adjusted.open_type
                    and adjusted.open_type._tag ~= "Type.Invalid"
                    and deoptionize(adjusted.open_type))
                or (adjusted.tail_scalars[1]
                    and deoptionize(adjusted.tail_scalars[1]._type))
                or types.Integer()
            node._type = types.Array(etype)

            for i, exp in ipairs(adjusted.tail_scalars) do
                local old = exp
                exp = trycoerce(exp, etype, errors)
                checkmatch("array initializer at position " .. i, etype,
                    exp._type, errors, exp.loc)
                replace_adjusted_value(adjusted, old, exp)
            end

            if adjusted.open_source then
                local source = adjusted.open_type
                if source._tag ~= "Type.Invalid"
                   and not types.equals(source, etype)
                   and not types.compatible(etype, source)
                   and not types.coerceable(source, etype) then
                    if adjusted.open_source._tag == "Ast.ExpDots" then
                        checker.typeerror(errors, adjusted.open_source.loc,
                            "'...' element type %s is not coerceable to array element type %s",
                            types.tostring(source), types.tostring(etype))
                    else
                        checker.typeerror(errors, adjusted.open_source.loc,
                            "open result element type %s is not coerceable to array element type %s",
                            types.tostring(source), types.tostring(etype))
                    end
                end
                adjusted.open_target = etype
                if adjusted.open_source._tag == "Ast.ExpCall"
                   and adjusted.open_source._open_results then
                    adjusted.open_source._open_results.target_type = etype
                elseif adjusted.open_source._tag == "Ast.ExpDots"
                       and adjusted.open_source._open_dots then
                    adjusted.open_source._open_dots.target_type = etype
                end
            end

            node.fields = {}
            for _, exp in ipairs(adjusted.exps) do
                table.insert(node.fields, ast.Field(exp.loc, nil, exp))
            end
            node._array_adjustment = adjusted
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
                local supplied = {}
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
                        supplied[found.name] = true
                    end
                end
                for _, rfield in ipairs(visible_fields) do
                    if not supplied[rfield.name] then
                        if nil_can_adjust_to(rfield.type) then
                            local exp = ast.ExpNil(node.loc)
                            exp._type = types.Nil()
                            exp = trycoerce(exp, rfield.type, errors)
                            checkmatch("omitted field " .. rfield.name,
                                rfield.type, exp._type, errors, node.loc)
                            exp._named_omitted = true
                            local cfield = ast.Field(node.loc, rfield.name, exp)
                            cfield._field = rfield
                            table.insert(node.fields, cfield)
                        else
                            checker.typeerror(errors, node.loc,
                                "field '%s' of record '%s' cannot be omitted because its type %s does not accept nil",
                                rfield.name, types.tostring(context),
                                types.tostring(rfield.type))
                        end
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

    ["Ast.ExpCall"] = function(node, st, errors, context, demand)
        demand = demand or default_call_result_demand(node, context)
        if node.exp._tag == "Ast.ExpVar" then
            local var = node.exp.var
            checkvar(var, st, errors)
            if var._decl then var._decl._used = true end
            node.exp._type = var._type
        else
            checkexp(node.exp, st, errors)
        end

        local argtag = node.args._tag
        local named = argtag == "Ast.ArgsNamedFunc"
            or argtag == "Ast.ArgsNamedMethod"
        local method = argtag == "Ast.ArgsMethod"
            or argtag == "Ast.ArgsNamedMethod"
        assert(argtag == "Ast.ArgsFunc" or argtag == "Ast.ArgsMethod"
            or argtag == "Ast.ArgsNamedFunc"
            or argtag == "Ast.ArgsNamedMethod")

        if not method then
            local ftype = node.exp._type
            if ftype._tag == "Type.Invalid" then
                node._type = ftype
                check_call_argument_expressions(node.args, st, errors)
                return
            end
            local fname = expname(node.exp)
            local cfunc = c_function_pointer_type(ftype)
            if cfunc then
                if named then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local cftype = c_function_as_function_type(cfunc)
                node._c_pointer_call = cfunc
                annotate_call_arguments(node,
                    checkargs(cftype, node.args.args, node.loc,
                        "function pointer '" .. fname .. "'", st, errors,
                        false))
                annotate_call_results(node, cftype, demand, errors)
                if node._type._tag == "Type.Void" and not node._voidok
                   and not demand.tail then
                    node._type = invalid(errors, node.loc,
                        "a function returning no values cannot be used as a value")
                end
                return
            end
            local contextual_args
            if ftype._tag == "Type.Value" then
                if named then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end

                local synthesized
                synthesized, contextual_args = synthesize_value_call_type(
                    node, demand, st, errors)
                local original = node.exp
                node.exp = trycoerce(original, synthesized, errors)
                assert(node.exp ~= original
                    and node.exp._tag == "Ast.ExpCast")
                -- This cast target is already a resolved Type.Function. It is
                -- deliberately not redispatched through the ExpCast visitor:
                -- the callee and every argument were checked exactly once.
                node.exp._contextual_value_cast = true
                node._contextual_value_call = true
                node._contextual_function_type = synthesized
                ftype = synthesized
            end
            -- Auto-unwrap an option-of-function callee (e.g. an array element
            -- `arr[i]`, which has type `T?`): cast to the underlying function
            -- type. Named syntax remains unavailable because the callee is a
            -- structural value, not a direct declaration.
            if ftype._tag == "Type.Option" and ftype.base._tag == "Type.Function" then
                local cast = ast.ExpCast(node.exp.loc, node.exp, ftype.base)
                cast._type = ftype.base
                node.exp = cast
                ftype = ftype.base
            end
            if ftype._tag ~= "Type.Function" then
                node._type = invalid(errors, node.loc,
                    "'%s' is not a function but %s",
                    fname, types.tostring(ftype))
                check_call_argument_expressions(node.args, st, errors)
                return
            end

            local pseudo_new = node.exp._tag == "Ast.ExpVar"
                and node.exp.var._decl
                and node.exp.var._decl._tag == "Type.CPseudoNew"
            if named and pseudo_new then
                node._type = types.Invalid()
                named_target_error(errors, node.loc)
                check_call_argument_expressions(node.args, st, errors)
                return
            elseif pseudo_new then
                local alloc_err = c_allocation_error(node.exp.var._decl.ctype)
                if alloc_err then
                    node._type = invalid(errors, node.loc, alloc_err)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
            end

            if named then
                local paramnames, lowering, recognized_ffi =
                    named_function_metadata(node)
                if recognized_ffi and paramnames == false then
                    node._type = invalid(errors, node.loc,
                        "parameter names are unavailable for foreign function '%s' "
                        .. "because its prototypes do not provide one complete unambiguous list",
                        fname)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                elseif not lowering or type(paramnames) ~= "table" then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                elseif ftype.vararg or ftype.varargtype then
                    node._type = invalid(errors, node.loc,
                        "named arguments are not supported for variadic function '%s'",
                        fname)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local dense, order = check_named_args(ftype, paramnames,
                    node.args.fields, node.loc, "function '" .. fname .. "'",
                    st, errors)
                if dense then
                    node.args = ast.ArgsFunc(node.args.loc, dense)
                    node._named_arg_order = order
                    node._named_call_kind = lowering
                end
            else
                if contextual_args then
                    annotate_call_arguments(node, contextual_args)
                else
                    annotate_call_arguments(node,
                        checkargs(ftype, node.args.args, node.loc,
                            "function '" .. fname .. "'", st, errors,
                            not (node.exp._tag == "Ast.ExpVar"
                                 and (is_foreign_function_var(node.exp.var)
                                      or (node.exp.var._decl
                                          and node.exp.var._decl._tag == "Type.CPseudoNew")))))
                end
            end
            annotate_call_results(node, ftype, demand, errors)
            check_generic_result_limit(node, errors)
            if node._type._tag == "Type.Void" and not node._voidok
               and not demand.tail then
                node._type = invalid(errors, node.loc,
                    "a function returning no values cannot be used as a value")
            end
        else
            local otype = node.exp._type
            if otype._tag == "Type.Invalid" then
                node._type = otype
                check_call_argument_expressions(node.args, st, errors)
                return
            end
            -- Auto-unwrap an option receiver before resolving the method. The
            -- receiver is still generated once, before any named expressions.
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
                local method_name_text = node.args.method
                if not is_record_visible_from(st, otype.fqtn) then
                    node._type = invalid(errors, node.loc,
                        "record type '%s' is local to module '%s'",
                        otype.fqtn, record_module(otype.fqtn))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                elseif not class.methods[method_name_text] then
                    node._type = invalid(errors, node.loc,
                        "method '%s' not found in record '%s'",
                        method_name_text, types.tostring(otype))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local ftype = class.methods[method_name_text]
                if not is_record_member_visible_from(st, ftype) then
                    node._type = invalid(errors, node.loc,
                        "method '%s:%s' is local to module '%s'",
                        class.name, method_name_text, record_module(class.name))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                if named then
                    if ftype.varargtype then
                        node._type = invalid(errors, node.loc,
                            "named arguments are not supported for variadic method '%s:%s'",
                            class.name, method_name_text)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    elseif type(ftype.paramnames) ~= "table" then
                        node._type = types.Invalid()
                        named_target_error(errors, node.loc)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    end
                    local desc = "method '" .. class.name .. ":" .. method_name_text .. "'"
                    local dense, order = check_named_args(ftype, ftype.paramnames,
                        node.args.fields, node.loc, desc, st, errors)
                    if dense then
                        node.args = ast.ArgsMethod(node.args.loc, method_name_text, dense)
                        node._named_arg_order = order
                        node._named_call_kind = "titan"
                    end
                else
                    annotate_call_arguments(node,
                        checkargs(ftype, node.args.args, node.loc,
                            "method '" .. class.name .. ":" .. method_name_text .. "'",
                            st, errors))
                end
                node._method = ftype
                annotate_call_results(node, ftype, demand, errors)
                if node._type._tag == "Type.Void" and not node._voidok
                   and not demand.tail then
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
                check_call_argument_expressions(node.args, st, errors)
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
        -- Parentheses force exactly one result even though `_voidok` permits a
        -- genuinely zero-return call (which is adjusted upward to nil below).
        -- Pass the demand explicitly so `_voidok` is not mistaken for a
        -- statement/discard context.
        checkexp(node.exp, st, errors, context,
            result_demand({ context or UNKNOWN_SLOT }, false, {
                term = "parenthesized expression",
                loc = node.loc,
            }))
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
            varargtype = check_varg_elem(
                varargdecl._type, varargdecl.loc, errors, "parameter")
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
        local flexrettype
        if node.rettypes then
            -- Explicit annotation, including `: ()` (an empty list).
            rettypes = {}
            for _, rt in ipairs(node.rettypes) do
                table.insert(rettypes, typefromnode(rt, st, errors))
            end
            flexrettype = flexible_return_type(node, st, errors)
        elseif expected then
            -- Checking mode: take both fixed and flexible results from the
            -- context. This is deliberately distinct from an explicit `: ()`,
            -- whose parser shape is an empty fixed list plus `flexrettype =
            -- false` and must not inherit the context's tail.
            rettypes = expected.rettypes
            flexrettype = expected.flexrettype
        else
            -- No annotation, no usable context: default to zero-return `()`,
            -- exactly like an unannotated top-level function.
            rettypes = {}
            flexrettype = false
        end

        node._type = types.Function(paramtypes, rettypes, false, varargtype,
            flexrettype)

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
                    mtype.varargtype, mtype.flexrettype)
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
    if node._type.flexrettype then
        -- An explicit tail reports at its annotation; an inferred lambda tail
        -- reports at the lambda itself because the expected Type.Function no
        -- longer carries an AST source location.
        local floc = (node.flexrettype and node.flexrettype.loc) or node.loc
        checktype(node._type.flexrettype, floc, errors)
        node._type.flexrettype = check_varg_elem(
            node._type.flexrettype, floc, errors, "return")
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
        flexrettype = false,
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
            elseif node._tag == "Ast.TopLevelTypeAlias" then
                checktype(node._type, node.type.loc or node.loc, errors)
            end
        end
    end
end

local function isconstructor(node)
    local decl = node.var and node.var._decl
    if not decl then
        return false
    end
    if decl._tag == "Type.CPseudoNew" then
        return true
    end
    return decl._tag == "Type.StaticMethod"
        and #decl.rettypes == 1
        and not decl.flexrettype
        and decl.rettypes[1]._tag == "Type.Nominal"
        and decl.rettypes[1].fqtn == decl.fqtn
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
            if type(field.name) == "table" then
                const = const and isconst(field.name)
            end
            const = const and isconst(field.exp)
        end
        return const

    elseif tag == "Ast.ExpCall" then
        if isconstructor(node.exp) then
            local const = true
            for _, arg in ipairs(call_argument_expressions(node.args)) do
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

    elseif tag == "Ast.ExpAdjust" then
        -- Parenthesizing a call adds an adjustment node that keeps only its
        -- first result. It does not change whether evaluating the expression
        -- reads module state during initialization.
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
    elseif tag == "Ast.TopLevelTypeAlias" then
        -- Type aliases occupy a separate namespace and are deliberately absent
        -- from the ordinary top-level duplicate/value-symbol machinery.
        return nil
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
        local options = {
            source_dir = st.source_dir,
            compiler = foreign_c_options.compiler,
            language_mode = foreign_c_options.language_mode,
            cppflags = foreign_c_options.cppflags,
            compiler_include_dirs = foreign_c_options.compiler_include_dirs,
        }
        local ftypes, err, include
        if foreign_c_config_error then
            err = foreign_c_config_error
        else
            ftypes, err, include = cdriver.process_file(name, options)
        end
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
                        local paramnames = ftype.type == "function"
                            and ftype.paramnames or false
                        members[fname] = types.ModuleMember(name, fname, decl,
                            paramnames)
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

    ["Ast.TopLevelTypeAlias"] = function(node, st, errors)
        resolve_type_alias(node, st, errors)
    end,

    ["Ast.TopLevelFunc"] = function(node, st, errors)
        local ptypes, varargtype, paramnames = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        local flexrettype = flexible_return_type(node, st, errors)
        node._type = types.Function(ptypes, rettypes, false, varargtype,
            flexrettype)
        node._paramnames = paramnames
    end,

    ["Ast.StatBlock"] = function(node)
        node._type = types.Function({}, {}, false, false, false)
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
        local ptypes, varargtype, paramnames = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        local flexrettype = flexible_return_type(node, st, errors)
        node._type = types.StaticMethod(rectype.name, node.name, ptypes, rettypes,
            varargtype, flexrettype, paramnames)
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
        local ptypes, varargtype, paramnames = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        local flexrettype = flexible_return_type(node, st, errors)
        node._type = types.Method(rectype.name, node.name, ptypes, rettypes,
            varargtype, flexrettype, paramnames)
        node._type.islocal = node.islocal and true or false
        rectype.methods[node.name] = node._type
    end,
})

-- Collect aliases before the signature pass so aliases may be used by earlier
-- functions, variables, records, and other aliases. Record declarations share
-- the type namespace, so an alias with a record's name is rejected; the record
-- remains authoritative because it also owns a run-time namespace and a
-- synthesized constructor.
local function collect_type_aliases(ast, st, errors)
    local records = {}
    for _, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelRecord" and not records[node.name] then
            records[node.name] = node
        end
    end

    for _, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelTypeAlias" then
            local record = records[node.name]
            local previous = st:find_type_alias(node.name)
            if record then
                checker.typeerror(errors, node.loc,
                    "type alias '%s' conflicts with record declared at line %d",
                    node.name, record.loc.line)
                node._ignore = true
            elseif previous then
                checker.typeerror(errors, node.loc,
                    "duplicate type alias for %s, previous one at line %d",
                    node.name, previous.loc.line)
                node._ignore = true
            else
                st:add_type_alias(node.name, node)
            end
        end
    end
end

-- Colect type information of toplevel nodes
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
--   annotates the top-level nodes with their types in a "_type" field
--   annotates whether a top-level declaration is duplicated with a "_ignore"
--   field
local function checktoplevel(ast, st, errors, loader)
    for _, node in ipairs(ast) do
        if not node._ignore then
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
end

function checker.has_main(ast)
    for _, node in ipairs(ast) do
        local name = toplevel_name(node)
        if name == "main"
           and node._tag == "Ast.TopLevelFunc"
           and not node._type.varargtype
           and #node.params == 1
           and node.params[1]._type._tag == "Type.Array"
           and node.params[1]._type.elem._tag == "Type.String"
           and #node._type.rettypes == 1
           and not node._type.flexrettype
           and node._type.rettypes[1]._tag == "Type.Integer" then
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
        if t.flexrettype then
            register_referenced_records(t.flexrettype, loader, seen)
        end
    elseif tag == "Type.Record" then
        for _, f in ipairs(t.fields or {}) do
            if not f.islocal then
                register_referenced_records(f.type, loader, seen)
            end
        end
        for _, fn in pairs(t.functions or {}) do
            if not fn.islocal then
                register_referenced_records(fn, loader, seen)
            end
        end
        for _, method in pairs(t.methods or {}) do
            if not method.islocal then
                register_referenced_records(method, loader, seen)
            end
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
            local found = first_local_record_type(typ.varargtype, seen)
            if found then return found end
        end
        if typ.flexrettype then
            return first_local_record_type(typ.flexrettype, seen)
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
    for _, member in pairs(type_or_error.type_members or {}) do
        register_referenced_records(member, loader, seen)
    end
    return type_or_error, errors
end

-- Builds a type for the module from the types of its public members
--   modast: AST for the module
--   returns "Type.Module" type
local function makemoduletype(modname, modast)
    local members = {}
    local type_members = {}
    for _, tlnode in ipairs(modast) do
        if tlnode._tag ~= "Ast.TopLevelImport" and not tlnode.islocal and not tlnode._ignore then
            local tag = tlnode._tag
            if tag == "Ast.TopLevelVar" then
                table.insert(members, types.ModuleVariable(modname, tlnode.decl.name, tlnode._type))
            elseif tag == "Ast.TopLevelFunc" then
                table.insert(members, types.ModuleMember(modname, tlnode.name,
                    tlnode._type, tlnode._paramnames))
            elseif tag == "Ast.TopLevelRecord" then
                table.insert(members, types.ModuleMember(modname, tlnode.name,
                    tlnode._type, false))
            elseif tag == "Ast.TopLevelTypeAlias" then
                type_members[tlnode.name] = tlnode._type
            end
        end
    end
    return types.Module(modname, members, type_members)
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
            elseif tag == "Ast.TopLevelTypeAlias" and not node.islocal then
                reject_exported_c_ffi_type(modname, errors,
                    node.type.loc or node.loc, node._type)
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
            elseif tag == "Ast.TopLevelTypeAlias" and not node.islocal then
                reject_exported_local_record_type(modname, errors,
                    node.type.loc or node.loc, node._type)
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
    collect_type_aliases(ast, st, errors)
    checktoplevel(ast, st, errors, loader)
    checkbodies(ast, st, errors)
    reject_exported_c_ffi_types(modname, ast, errors)
    reject_exported_local_record_types(modname, ast, errors)
    ast._type = makemoduletype(modname, ast)
    return ast._type, errors
end

return checker
