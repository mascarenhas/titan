local core = require "titan-compiler.checker.core"
local _ENV = core

-- The typechecker first collects top-level declarations in dependency order,
-- while preserving the AST's source order for initialization and codegen, and
-- then checks callable bodies. All typechecked nodes that have a type get a
-- "_type" field with the type. The types themselves are in "types.lua".
typefromnode = nil

checkdecl = nil

checkstat = nil

checkexp = nil

checkvar = nil

checkfuncbody = nil

-- Some syntax-directed consumers inspect an ExpVar through its Var child so
-- they can preserve direct-call/foreign-call behavior.  A dependent VarDot or
-- VarBracket must still register the surrounding expression as its one AST
-- operation owner; otherwise its postorder finalizer refreshes only the Var and
-- leaves the delivered ExpVar carrying provisional inference parameters.
function generic_checkvar_for_expression(
        exp, st, errors, context, mode)
    assert(exp and exp._tag == "Ast.ExpVar")
    local prior_owner = st.generic_inference_expression_owner
    st.generic_inference_expression_owner = exp
    local result = table.pack(checkvar(exp.var, st, errors, context, mode))
    st.generic_inference_expression_owner = prior_owner
    return table.unpack(result, 1, result.n)
end

-- Eligibility probes sometimes need the resolved Var before the ordinary
-- ExpVar consumer can apply its contextual first-class/value rules. The probe
-- owns the one descent through a computed VarDot/VarBracket, using any expected
-- context already closed for context-sensitive C references, and transfers that
-- completed child check to the later consumer instead of redispatching it.
function generic_precheckvar_for_expression(
        exp, st, errors, context, mode)
    assert(exp and exp._tag == "Ast.ExpVar")
    if exp._generic_var_prechecked then return end
    generic_checkvar_for_expression(exp, st, errors, context, mode)
    exp._generic_var_prechecked = true
end

annotate_call_results = nil

check_generic_result_limit = nil

-- nesting depth of enclosing loops, so `break` can be rejected outside a loop
loop_depth = 0

-- One frame per enclosing loop. Besides making the target of `break`
-- explicit, the frame records whether a reachable break can leave that loop.
-- The statement-list checker stops visiting a dead tail after a proven
-- terminator, so every legal break that reaches this bookkeeping is reachable
-- under the checker's conservative branch analysis.
loop_frames = {}

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
catch_depth = 0

in_finally = 0

finally_loop_floor = 0

-- Stack of enclosing-function frames, used for closure capture analysis. Each
-- frame is { depth, captures = {}, capture_set = {} }. A top-level function body
-- is at depth 1; a lambda nested inside it is at depth 2; and so on. Reset
-- explicitly at the top of `checker.check` (unlike `loop_depth`, which is never
-- reset).
func_stack = {}

active_check_state = nil

checker._foreign_function_depth = 0

function checker.typeerror(errors, loc, fmt, ...)
    local errmsg = location.format_error(loc, "type error: "..fmt, ...)
    table.insert(errors, errmsg)
end

-- Recursively checks that every nominal type in a resolved declaration exists.
function checktype(typ, loc, errors, seen)
    if type(typ) ~= "table" or not typ._tag then return end
    seen = seen or {}
    if seen[typ] then return end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Nominal" then
        if not types.registry[typ.fqtn] then
            checker.typeerror(errors, loc,
                "invalid type '%s' in type declaration", typ.fqtn)
        end
        for _, argument in ipairs(typ.args or {}) do
            checktype(argument, loc, errors, seen)
        end
    elseif tag == "Type.Parameter" then
        if typ.erased_constraint ~= false then
            checktype(typ.erased_constraint, loc, errors, seen)
        end
    elseif tag == "Type.TypeParameter" then
        if typ.constraint ~= false then
            checktype(typ.constraint, loc, errors, seen)
        end
    elseif tag == "Type.FunctionScheme" then
        for _, typeparam in ipairs(typ.typeparams or {}) do
            checktype(typeparam, loc, errors, seen)
        end
        checktype(typ.signature, loc, errors, seen)
    elseif tag == "Type.GenericAlias" then
        local owner = types.registry[typ.target_owner_fqtn]
        if not owner then
            checker.typeerror(errors, loc,
                "invalid type '%s' in type declaration",
                typ.target_owner_fqtn)
        end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            checktype(typeparam, loc, errors, seen)
        end
    elseif tag == "Type.Array" then
        checktype(typ.elem, loc, errors, seen)
    elseif tag == "Type.Map" then
        checktype(typ.keys, loc, errors, seen)
        checktype(typ.values, loc, errors, seen)
    elseif tag == "Type.Option" then
        checktype(typ.base, loc, errors, seen)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        for _, typeparam in ipairs(typ.typeparams or {}) do
            checktype(typeparam, loc, errors, seen)
        end
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
    elseif tag == "Type.Interface" then
        for _, typeparam in ipairs(typ.typeparams or {}) do
            checktype(typeparam, loc, errors, seen)
        end
        for _, field in ipairs(typ.fields or {}) do
            checktype(field.type, loc, errors, seen)
        end
        for _, method in ipairs(typ.methods or {}) do
            checktype(method, loc, errors, seen)
        end
    end
end

-- Resolve a Titan alias to the RHS type object itself. The state lives on the
-- declaration so every use shares one pointer and a forward alias chain is
-- resolved only once. Encountering a declaration already being resolved marks
-- the cycle invalid before unwinding, preventing both recursion and cascades.
resolve_type_alias = nil

-- An exact bare owner on an alias RHS is an owner-scheme context, not the
-- ordinary scalar all-value application. Resolve only that constructor shape
-- here; every other RHS still follows the normal type visitor.
function generic_bare_forwarding_alias_target(node, st, errors)
    if node._tag == "Ast.TypeName" then
        local alias = st:find_type_alias(node.name)
        if alias then
            node._decl = alias
            local target = resolve_type_alias(alias, st, errors)
            if target._tag == "Type.GenericAlias" then
                local owner = types.registry[target.target_owner_fqtn]
                local target_alias_fqtn = false
                if not target.locality then
                    target_alias_fqtn = target.module .. "." .. target.name
                end
                return owner, target_alias_fqtn, true
            end
            return nil, false, false
        end
        local declaration = st:find_symbol(node.name)
        if declaration and (declaration._tag == "Ast.TopLevelRecord"
                or declaration._tag == "Ast.TopLevelUnion") then
            node._decl = declaration
        elseif st.interface_declarations
           and st.interface_declarations[node.name] then
            node._decl = st.interface_declarations[node.name]
        end
        local owner = generic_resolve_local_owner(node.name, st)
        return owner, false, owner ~= nil
    elseif node._tag == "Ast.TypeQualName" then
        local declaration = st:find_symbol(node.module)
        if declaration then node._module_decl = declaration end
        local module = declaration and declaration._type
        if not module or module._tag ~= "Type.Module" then
            return nil, false, false
        end
        local include_source = declaration._source_import == true
        local member, member_islocal = types.module_type_member(
            module, node.name, include_source)
        if member and member._tag == "Type.GenericAlias" then
            node._decl = {
                _tag = "Checker.TypeMember",
                modname = module.name,
                name = node.name,
                type = member,
                islocal = member_islocal,
            }
            local owner = types.registry[member.target_owner_fqtn]
            local target_alias_fqtn = false
            if not member.locality then
                target_alias_fqtn = member.module .. "." .. member.name
            end
            return owner, target_alias_fqtn, true
        elseif member and member._tag == "Type.Interface" then
            node._decl = {
                _tag = "Checker.TypeMember",
                modname = module.name,
                name = node.name,
                type = member,
                islocal = member_islocal,
            }
            return member, false, true
        end
        local nominal = types.module_member(
            module, node.name, include_source)
        local owner = nominal and nominal.type
        if owner and (owner._tag == "Type.Record"
                or owner._tag == "Type.Union") then
            node._decl = {
                _tag = "Checker.TypeMember",
                modname = module.name,
                name = node.name,
                type = nominal,
                islocal = nominal.islocal and true or false,
            }
            return owner, false, true
        end
    end
    return nil, false, false
end

resolve_type_alias = function(node, st, errors)
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
    local rhs_is_bare_name = (node.type._tag == "Ast.TypeName"
            or node.type._tag == "Ast.TypeQualName")
        and #(node.type.typeargs or {}) == 0
    local target
    if rhs_is_bare_name then
        local owner, target_alias_fqtn, recognized =
            generic_bare_forwarding_alias_target(
                node.type, st, errors)
        if recognized and owner and owner.scope ~= false
           and #(owner.typeparams or {}) > 0 then
            target = types.GenericAlias(
                st.modname, node.name, node.islocal and true or false,
                owner.name, target_alias_fqtn, owner.scope,
                owner.typeparams)
        end
    end
    if not target then
        -- Resolving a transparent type-only alias is not an enum value use. The
        -- eventual type use revalidates the resolved graph in its own full or
        -- spelling-only context.
        target = typefromnode(node.type, st, errors, true)
    end

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
--   exp: expression that was actually present
--   errors: list of compile-time errors
--   loc: location of the term that is being compared
--   adjustment: result already obtained by `trycoerce`
--   precise_error: a target-specific diagnostic was already emitted
function checkmatch(term, expected, exp, errors, loc, adjustment,
                          precise_error)
    assert(adjustment ~= nil,
        "checkmatch requires the checker decision for this sink")
    local found = exp._type

    -- Identity and every representation-changing adjustment must already have
    -- left the expression at the target type. Structural gradual views retain
    -- the producer type and carry their plan on the same expression. A
    -- non-exact callable adjustment is an explicit target-typed ExpCast, even
    -- though both endpoint values use TValue representation.
    local same_representation = adjustment
        and (adjustment.kind == "identity"
            or (adjustment.kind == "gradual_view"
                and adjustment.op == "structural"))
    if adjustment == false then
        if precise_error then return end
        local msg = "types in %s do not match, expected %s but found %s"
        msg = string.format(msg, term, types.tostring(expected), types.tostring(found))
        checker.typeerror(errors, loc, msg)
    elseif not types.equals(found, expected) and not same_representation then
        error("checker adjustment was not elaborated to its target type")
    elseif same_representation then
        exp._assignment_adjustment = adjustment
    end
end

function check_exact_match(term, expected, exp, errors, loc)
    if not types.equals(exp._type, expected) then
        checker.typeerror(errors, loc,
            "types in %s do not match, expected %s but found %s",
            term, types.tostring(expected), types.tostring(exp._type))
    end
end

function invalid(errors, loc, ...)
    checker.typeerror(errors, loc, ...)
    return types.Invalid()
end

function optionize(t)
    if t._tag == "Type.Option" or t._tag == "Type.Value" then
        return t
    else
        return types.Option(t)
    end
end

function deoptionize(t)
    if t._tag == "Type.Option" then
        assert(t.base._tag ~= "Type.Option")
        return t.base
    else
        return t
    end
end

-- The native input-vararg and flexible-result ABIs share the TitanVargX
-- descriptor inventory. Generic reconstruction and metadata validation use the
-- same type-layer query, so an application cannot manufacture a tail shape that
-- the written declaration would reject.
function has_varg_representation(t)
    return types.valid_varg_element(t)
end

-- Validate the element type shared by an input variadic parameter and a
-- flexible return tail. `role` is either "parameter" or "return", solely to
-- keep diagnostics precise at the source construct.
function check_varg_elem(t, loc, errors, role)
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
function param_types(params, st, errors)
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

-- Named-call labels are references to declaration parameters, not record
-- initializer fields. Keep a small source-only descriptor which can be
-- reconstructed from a separately compiled callable's published parameter
-- names. The descriptor deliberately lives outside `types.lua`: it is semantic
-- tooling metadata, not part of a Titan callable's serialized type or ABI.
local function callable_parameter_descriptor(
        owner_kind, owner_name, callable_name, index, name, islocal)
    return {
        _tag = "Checker.Parameter",
        owner_kind = owner_kind,
        owner_name = owner_name,
        callable_name = callable_name,
        index = index,
        name = name,
        islocal = islocal and true or false,
    }
end

-- Bind each written fixed parameter to the canonical descriptor used by named
-- argument labels. Store the same private list on the source declaration and
-- its callable descriptor so calls resolved without serialization can retain
-- pointer identity as well as the reconstructible semantic identity.
function bind_callable_parameter_declarations(
        node, callable, owner_kind, owner_name, islocal, declarations)
    local bound = {}
    local fixed_index = 0
    for _, parameter in ipairs(node.params or {}) do
        if parameter.name ~= false then
            fixed_index = fixed_index + 1
            local declaration = declarations and declarations[fixed_index]
                or callable_parameter_descriptor(
                    owner_kind, owner_name, node.name, fixed_index,
                    parameter.name, islocal)
            parameter._decl = declaration
            bound[fixed_index] = declaration
        end
    end
    node._parameter_decls = bound
    if callable then callable._parameter_decls = bound end
    return bound
end

local function record_constructor_parameter(declaration, index, name)
    if declaration._tag ~= "Type.StaticMethod" or declaration.name ~= "new"
       then return nil end
    local owner = types.registry[declaration.fqtn]
    if not owner or owner._tag ~= "Type.Record" then return nil end
    local field = owner.fields[index]
    if field and field.name == name then return field end
    for _, candidate in ipairs(owner.fields or {}) do
        if candidate.name == name then return candidate end
    end
end

-- Recover the parameter declaration represented by one named label. Raw
-- source callables retain the exact descriptor table; compiled interfaces can
-- reconstruct an equivalent Checker.Parameter from their ABI-stable owner,
-- callable name, fixed position, and published parameter spelling.
function named_parameter_declaration(declaration, index, name)
    if type(declaration) ~= "table" then return nil end
    local retained = declaration._parameter_decls
    if retained and retained[index] then return retained[index] end

    local tag = declaration._tag
    if tag == "Ast.TopLevelFunc" then
        local parameter = declaration.params and declaration.params[index]
        return parameter and (parameter._decl or parameter) or nil
    elseif tag == "Type.ModuleMember" then
        return callable_parameter_descriptor(
            "module", declaration.modname, declaration.name, index, name,
            declaration.islocal)
    elseif tag == "Type.Method" or tag == "Type.StaticMethod" then
        local field = record_constructor_parameter(declaration, index, name)
        if field then return field end
        return callable_parameter_descriptor(
            "member", declaration.fqtn, declaration.name, index, name,
            declaration.islocal)
    end
end

function flexible_return_type(
        node, st, errors, defer_c_enum_carrier)
    if not node.flexrettype then
        return false
    end
    return check_varg_elem(
        typefromnode(node.flexrettype, st, errors,
            defer_c_enum_carrier),
        node.flexrettype.loc or node.loc, errors, "return")
end

-- Resolve the in-scope `...` for a `...`/`#...`/`...[e]` use. Returns the
-- element type `t`, or `types.Invalid()` after reporting. Enforces both that the
-- enclosing function is variadic and scope rule 4: `$vararg` is depth-stamped, so
-- a use from an inner lambda (a deeper `#func_stack`) finds the symbol but is
-- rejected — `...` is invisible across a function boundary, unlike ordinary
-- lexical scoping.
function resolve_vararg(st, loc, errors)
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
function check_dots_marker(node, st, errors)
    node._vararg_elem = resolve_vararg(st, node.loc, errors)
    node._type = node._vararg_elem
end

return core.checker
