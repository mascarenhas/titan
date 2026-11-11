local core = require "titan-compiler.checker.core"
local documentation = require "titan-compiler.documentation"
local _ENV = core

--
-- TopLevel
--

-- Shared body-check for top-level functions, methods, and lambdas. Pushes a
-- function frame (so captures of enclosing locals are detected), declares the
-- parameters (stamping their nesting depth at this function's own depth), checks
-- the body, and enforces the cannot-fall-off-the-end rule. The caller is
-- responsible
-- for having an open block and (for methods) declaring `self` before calling.
--   node: a node carrying `_type` (Function), `params`, `block`, and (for the
--         duplicate-parameter message) `name`. For lambdas, `node.rettypes` may
--         be `nil`/a list; `node._type.rettypes` is authoritative here.
--   opts (optional): { self_decl = Decl }. Returns (ret, frame): `ret` is
--         whether the body cannot fall through; `frame` carries `captures`.
function annotate_lua_function_boundary(node)
    local targets = {}
    local signature = assert(call_signature(node._type),
        "Lua boundary lacks a callable signature")
    if node._type._tag == "Type.Method" then
        targets[1] = types.Nominal(node._type.fqtn)
    end
    for _, typ in ipairs(signature.params) do
        targets[#targets + 1] = typ
    end

    node._lua_dynamic_plans = {}
    node._strict_guard_plans = {}
    for index, typ in ipairs(targets) do
        -- `none` is a checked policy decision, not a missing annotation.  A
        -- raw-pointer parameter remains usable by exact Titan native calls,
        -- while invocation through the genuine Lua entry rejects it.
        node._lua_dynamic_plans[index] =
            maybe3.from_optional(types.dynamic_coercion(typ))
        node._strict_guard_plans[index] =
            maybe3.from_optional(types.gradual_guard(typ))
    end
    if signature.varargtype then
        node._lua_vararg_dynamic_plan =
            maybe3.from_optional(types.dynamic_coercion(signature.varargtype))
        node._strict_vararg_guard_plan =
            maybe3.from_optional(types.gradual_guard(signature.varargtype))
    else
        node._lua_vararg_dynamic_plan = maybe3.none()
        node._strict_vararg_guard_plan = maybe3.none()
    end

    if node._type._tag == "Type.Method" then
        node._bound_strict_guard_plans = {}
        for index, typ in ipairs(signature.params) do
            node._bound_strict_guard_plans[index] =
                maybe3.from_optional(types.gradual_guard(typ))
        end
        node._bound_strict_vararg_guard_plan =
            signature.varargtype
                and maybe3.from_optional(types.gradual_guard(signature.varargtype))
                or maybe3.none()
    end
end

function annotate_closure_transfer_captures(node)
    node._capture_dynamic_plans = {}
    for index, decl in ipairs(node._captures or {}) do
        node._capture_dynamic_plans[index] =
            maybe3.from_optional(types.dynamic_coercion(decl._type))
    end
end

function checkfuncbody(node, st, errors, opts)
    opts = opts or {}
    st:add_symbol("$function", node) -- for return type
    local signature = assert(call_signature(node._type),
        "function body lacks a callable signature")
    local frame = {
        depth = #func_stack + 1,
        captures = {},
        capture_set = {},
        node = node,
        module_initializer = opts.module_initializer and st.modname or nil,
    }
    table.insert(func_stack, frame)
    -- Synthesized constructors contain only member initializers, so they have
    -- no source body that can refer to the L/M builtins. Their parameter names
    -- are member names, which may legitimately be L or M.
    if not opts.foreign and not node._record_constructor
       and not node._union_constructor then
        local ldecl = ast.Decl(node.loc, "L", nil, false, false)
        ldecl._type = lua_state_pointer_type(st)
        ldecl._funcdepth = #func_stack
        ldecl._cvar = "L"
        ldecl._readonly = true
        st:add_symbol("L", ldecl)
        local mdecl = ast.Decl(node.loc, "M", nil, false, false)
        mdecl._type = types.Module(st.modname, {}, {})
        mdecl._type._current_module = true
        mdecl._current_module = true
        mdecl._funcdepth = #func_stack
        mdecl._cvar = "_mod"
        mdecl._readonly = true
        st:add_symbol("M", mdecl)
    end
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
    if signature.varargtype then
        st:add_symbol("$vararg",
            { elem = signature.varargtype, funcdepth = #func_stack })
    end
    local ptypes = signature.params
    local pnames = {}
    for i, rettype in ipairs(signature.rettypes) do
        -- Report an invalid return type at the precise return-type node when one
        -- exists (top-level functions/methods); a lambda's `node.rettypes` may be
        -- `nil` (inferred) or shorter, so fall back to the function location.
        local rloc = (node.rettypes and node.rettypes[i] and node.rettypes[i].loc)
            or node.loc
        checktype(rettype, rloc, errors)
        report_incomplete_c_object(rettype, st,
            "return type " .. i .. " of function '"
            .. tostring(node.name or "<anonymous>") .. "'",
            rloc, errors)
        if types.is_c_array(rettype) then
            checker.typeerror(errors, rloc,
                "a whole C array cannot be returned by value; return a "
                .. "pointer to its storage instead")
        end
    end
    if signature.flexrettype then
        -- An explicit tail reports at its annotation; an inferred lambda tail
        -- reports at the lambda itself because the expected Type.Function no
        -- longer carries an AST source location.
        local floc = (node.flexrettype and node.flexrettype.loc) or node.loc
        checktype(signature.flexrettype, floc, errors)
        local checked = check_varg_elem(
            signature.flexrettype, floc, errors, "return")
        if node._type._tag == "Type.Function" then
            node._type.flexrettype = checked
        end
    end
    -- A lambda (Ast.ExpFunction) has no `name`; describe it generically in the
    -- duplicate-parameter diagnostic instead of printing "function 'nil'".
    local fdesc = node.name and ("declaration of function '" .. node.name .. "'")
        or "anonymous function"
    for i, param in ipairs(node.params) do
        -- The trailing vararg marker (`name == nil`) is not a real parameter:
        -- it carries no name to declare and its type already lives on
        -- `node._type.varargtype`; skip it so `ptypes`/`node.params` stay aligned.
        if param.name ~= nil then
            param._type = ptypes[i]
            param._funcdepth = #func_stack
            local builtin = st:find_symbol(param.name)
            if builtin and builtin._readonly and not builtin._builtin then
                checker.typeerror(errors, param.loc,
                    "cannot declare parameter '%s' because it shadows a built-in local",
                    param.name)
            end
            st:add_symbol(param.name, param)
            checktype(param._type, param.loc, errors)
            report_incomplete_c_object(param._type, st,
                "parameter '" .. tostring(param.name) .. "' of function '"
                .. tostring(node.name or "<anonymous>") .. "'",
                param.loc, errors)
            if pnames[param.name] then
                checker.typeerror(errors, node.loc,
                    "duplicate parameter '%s' in %s", param.name, fdesc)
            else
                pnames[param.name] = true
            end
        end
    end
    if not opts.foreign then annotate_lua_function_boundary(node) end
    -- The error-handling context counters do not cross a function boundary: a
    -- lambda body starts fresh (a bare `raise`/`return`/`break` inside it is the
    -- lambda's own, not the enclosing catch/finally's). Save and reset to 0
    -- around the body, restoring on the way out so the enclosing context is
    -- unaffected. (`loop_depth` predates this; `break` already cannot target a
    -- loop across a function boundary, so it is reset here too for consistency.)
    local saved_catch, saved_in_finally, saved_floor, saved_loop,
          saved_loop_frames =
        catch_depth, in_finally, finally_loop_floor, loop_depth, loop_frames
    catch_depth, in_finally, finally_loop_floor, loop_depth = 0, 0, 0, 0
    loop_frames = {}
    if opts.foreign then checker._foreign_function_depth = checker._foreign_function_depth + 1 end
    local ret = st:with_block(checkstat, node.block, st, errors)
    if opts.foreign then checker._foreign_function_depth = checker._foreign_function_depth - 1 end
    catch_depth, in_finally, finally_loop_floor, loop_depth =
        saved_catch, saved_in_finally, saved_floor, saved_loop
    loop_frames = saved_loop_frames
    -- A zero-return `() -> ()` function may fall off the end. Otherwise only
    -- the one-fixed-nil shape may synthesize its missing result; a flexible tail
    -- on either shape is independently empty.
    if not ret and #signature.rettypes > 0
       and not checker._accepts_implicit_nil_result(signature) then
        if #signature.rettypes == 1 then
            checker.typeerror(errors, node.loc,
                "function can return nil but return type is not nil")
        else
            checker.typeerror(errors, node.loc,
                "function can fall through but return type requires %d fixed values",
                #signature.rettypes)
        end
    end
    if #errors == 0 and (node._tag == "Ast.TopLevelFunc" or node._tag == "Ast.TopLevelMethod" or node._tag == "Ast.TopLevelStatic") then
        annotate_linear_function_returns(node)
    end
    table.remove(func_stack)
    return ret, frame
end

-- Typechecks a function body
--   node: TopLevelFunc AST node
--   st: symbol table
--   errors: list of compile-time errors
function checkfunc(node, st, errors)
    return generic_with_declaration_bindings(node, st,
        checkfuncbody, node, st, errors)
end

function checkinitializer(node, st, errors)
    local init = {
        loc = node.loc,
        name = "$module_initializer",
        params = {},
        rettypes = {},
        flexrettype = nil,
        block = node,
        _type = node._type,
    }
    st:open_block(node)
    checkfuncbody(init, st, errors, { module_initializer = true })
    st:close_block()
end

-- Typechecks a method body, binding self to the first parameter
--   node: TopLevelMethod AST node
--   st: symbol table
--   errors: list of compile-time errors
function checkmethod(node, st, errors)
    return generic_with_declaration_bindings(node, st, function()
        local owner = node._nominal_owner._type
        local self = ast.Decl(node.loc, "self",
            ast.TypeName(node.loc, node._nominal_owner.name, {}), false,
            false)
        node._self = self
        self._type = types.Nominal(owner.name,
            generic_parameter_arguments(owner))
        -- `self` is declared into this method's own frame (inside
        -- checkfuncbody), so a nested lambda captures it like any parameter.
        checkfuncbody(node, st, errors, { self_decl = self })
    end)
end

function check_user_value_slot_type(
        owner_kind, owner_name, member_kind, member_name, typ, loc, errors)
    checktype(typ, loc, errors)
    if not types.has_tvalue_representation(typ) then
        checker.typeerror(errors, loc,
            "%s %s '%s' in %s '%s' cannot have type '%s' because it has no TValue representation",
            owner_kind, member_kind, member_name, owner_kind, owner_name,
            types.tostring(typ))
    end
end

function check_nominal_storage_type(
        owner_kind, owner_name, member_kind, member_name, typ, loc, st, errors)
    checktype(typ, loc, errors)
    local err = checker._nominal_storage_error(typ, st)
    if err then
        checker.typeerror(errors, loc,
            "%s %s '%s' in %s '%s': %s",
            owner_kind, member_kind, member_name, owner_kind, owner_name, err)
    end
end

checker._foreign_forbidden_statements = {
    ["Ast.StatForIn"] = "generic for loops",
    ["Ast.StatCase"] = "case statements",
    ["Ast.StatRaise"] = "raise statements",
}

checker._foreign_forbidden_expressions = {
    ["Ast.ExpInitList"] = "Titan constructors",
    ["Ast.ExpFunction"] = "anonymous functions",
    ["Ast.ExpMethodRef"] = "bound methods",
    ["Ast.ExpUnionInit"] = "Titan union constructors",
    ["Ast.ExpDots"] = "variadic expressions",
    ["Ast.ExpDotsIndex"] = "variadic expressions",
    ["Ast.ExpDotsLen"] = "variadic expressions",
    ["Ast.ExpSubset"] = "spread expressions",
    ["Ast.ExpSpread"] = "spread expressions",
    ["Ast.ExpSpreadIndex"] = "spread expressions",
    ["Ast.ExpConcat"] = "string concatenation",
    ["Ast.ExpIs"] = "Titan type tests",
}

function checker._valid_foreign_local_type(typ)
    local resolved = c_resolve(typ)
    return typ and typ._tag ~= "Type.Invalid"
       and types.is_direct_c(typ)
       and resolved and resolved._tag ~= "Type.COwned"
       and resolved._tag ~= "Type.CFunction"
       and resolved._tag ~= "Type.CModule"
       and resolved._tag ~= "Type.CVoid"
end

-- Why an allocation plan other than automatic storage cannot appear in a
-- foreign body: each one needs an object that Lua owns and the frame roots.
local function foreign_allocation_error(plan)
    local name = plan.local_sink
    if not name then
        return "a C allocation inside a foreign function must be the initializer of a local ('local x = foreign T.new()'); any other use needs a Lua-owned object, which a foreign function cannot allocate or root"
    elseif plan.storage == "owned_borrow" and plan.array then
        return string.format(
            "pointer local '%s' needs a positive constant '.new_array' count inside a foreign function; a dynamic or zero count needs a Lua-owned array, which a foreign function cannot allocate or root",
            name)
    elseif plan.storage == "owned_borrow" then
        return string.format(
            "pointer local '%s' cannot be initialized with '.new()' inside a foreign function, because its pointee would be a Lua-owned object; declare the local by value ('local %s = foreign T.new()') and pass it where a pointer is expected",
            name, name)
    end
    return string.format(
        "the C allocation for local '%s' needs a Lua-owned object, which a foreign function cannot allocate or root; only '.new()' of a struct or union and '.new_array(N)' with a positive constant N give a zeroed automatic local",
        name)
end

-- Implementation notes: doc/implementation/foreign-functions.md#one-checker-a-restricted-context
function checker._validate_foreign_body_node(node, errors, seen)
    if type(node) ~= "table" or seen[node] then return end
    seen[node] = true
    local tag = node._tag
    if type(tag) == "string" and tag:match("^Ast%.") then
        local forbidden = checker._foreign_forbidden_statements[tag]
            or checker._foreign_forbidden_expressions[tag]
        if tag == "Ast.StatTry" then
            forbidden = node._defer_tail and "defer statements"
                or "catch/finally blocks"
        end
        if forbidden then
            checker.typeerror(errors, node.loc,
                "%s are not available inside a foreign function", forbidden)
        elseif tag == "Ast.StatDecl" then
            if #node.exps == 0 then
                checker.typeerror(errors, node.loc,
                    "a local declaration inside a foreign function requires an initializer")
            end
            for _, decl in ipairs(node.decls) do
                if decl._type and decl._type._tag ~= "Type.Invalid"
                   and not checker._valid_foreign_local_type(decl._type) then
                    checker.typeerror(errors, decl.loc,
                        "local variable '%s' inside a foreign function must have a direct C FFI type, not '%s'",
                        decl.name, types.tostring(decl._type))
                end
            end
        elseif tag == "Ast.StatReturn" and #node.exps > 1 then
            checker.typeerror(errors, node.loc,
                "a foreign function return statement can return at most one value")
        elseif tag == "Ast.ExpCall" and node.exp and node.exp.var
               and node.exp.var._decl
               and node.exp.var._decl._tag == "Checker.CPseudoNew" then
            -- A call without a plan already has its own diagnostic. The
            -- count is a compile-time constant of the plan, not a body
            -- expression, so the walk stops here.
            local plan = node._c_allocation_plan
            if plan and not plan.storage:match("^automatic") then
                checker.typeerror(errors, node.loc, "%s",
                    foreign_allocation_error(plan))
            end
            return
        elseif tag == "Ast.ExpBinop"
               and (node.op == ".." or node.op == "and" or node.op == "or") then
            checker.typeerror(errors, node.loc,
                "Titan operator '%s' is not available inside a foreign function",
                node.op)
        elseif tag == "Ast.ExpUnop" and node.op == "not" then
            checker.typeerror(errors, node.loc,
                "Titan operator 'not' is not available inside a foreign function")
        elseif tag == "Ast.ExpCast" then
            local source = node.exp and node.exp._type
            local target = node._type
            local literal = node.exp and (node.exp._tag == "Ast.ExpInteger"
                or node.exp._tag == "Ast.ExpFloat"
                or node.exp._tag == "Ast.ExpString"
                or node.exp._tag == "Ast.ExpNil")
            local nil_pointer = source and source._tag == "Type.Nil"
                and target and c_resolve(target)
                and c_resolve(target)._tag == "Type.CPointer"
            if not (types.is_direct_c(source) and types.is_direct_c(target))
               and not literal and not nil_pointer then
                checker.typeerror(errors, node.loc,
                    "casts between Titan values and C FFI values are not available inside a foreign function")
            end
        end
    end
    for key, value in pairs(node) do
        if type(key) ~= "string" or key:sub(1, 1) ~= "_" then
            if type(value) == "table" then
                if value._tag then
                    checker._validate_foreign_body_node(value, errors, seen)
                else
                    for _, child in ipairs(value) do
                        checker._validate_foreign_body_node(child, errors, seen)
                    end
                end
            end
        end
    end
end

function checker._checkforeignfunc(node, st, errors)
    checkfuncbody(node, st, errors, { foreign = true })
    checker._validate_foreign_body_node(node.block, errors, {})
end

-- Checks function bodies
--   ast: AST for the whole module
--   st: symbol table
--   errors: list of compile-time errors
function checkbodies(ast, st, errors)
    for _, node in ipairs(ast) do
        if not node._ignore then
            if node._tag == "Ast.TopLevelFunc" then
                st:with_block(checkfunc, node, st, errors)
            elseif node._tag == "Ast.TopLevelForeignFunc" then
                st:with_block(checker._checkforeignfunc, node, st, errors)
            elseif node._tag == "Ast.TopLevelMethod" then
                st:with_block(checkmethod, node, st, errors)
            elseif node._tag == "Ast.TopLevelStatic" then
                st:with_block(checkfunc, node, st, errors)
            elseif node._module_initializer or
                   node._tag == "Ast.StatBlock" then
                checkinitializer(node, st, errors)
            elseif node._tag == "Ast.TopLevelRecord" then
                for _, field in ipairs(node.fields) do
                    if field._type then
                        check_nominal_storage_type(
                            "record", node.name, "field", field.name,
                            field._type, field.loc, st, errors)
                    end
                end
            elseif node._tag == "Ast.TopLevelUnion" then
                for _, variant in ipairs(node.variants) do
                    if variant._type then
                        for i, part in ipairs(variant._type.parts) do
                            check_nominal_storage_type(
                                "union", node.name, "variant", variant.name,
                                part.type, variant.parts[i].loc, st, errors)
                        end
                    end
                end
            elseif node._tag == "Ast.TopLevelInterface" then
                for _, field in ipairs(node.fields) do
                    if field._type and not field._ignore then
                        check_user_value_slot_type(
                            "interface", node.name, "field", field.name,
                            field._type, field.loc, errors)
                    end
                end
                for _, method in ipairs(node.methods) do
                    if method._type and not method._ignore then
                        checktype(method._type, method.loc, errors)
                    end
                end
            elseif node._tag == "Ast.TopLevelTypeAlias" then
                checktype(node._type, node.type.loc or node.loc, errors)
            end
        end
    end
end

function validate_union_source_projections(ast, errors)
    for _, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelUnion" and not node._ignore then
            local projection, err =
                types.validate_union_source_projection(node._type)
            if not projection then
                checker.typeerror(errors, node.loc,
                    "invalid public projection for union '%s': %s",
                    node.name, err)
            end
        end
    end
end

function isconstructor(node)
    local decl = node.var and node.var._decl
    if not decl then
        return false
    end
    if decl._tag == "Checker.CPseudoNew" then
        return true
    end
    if decl._tag ~= "Type.StaticMethod"
       or decl.varargtype or decl.flexrettype
       or #decl.rettypes ~= 1
       or decl.rettypes[1]._tag ~= "Type.Nominal"
       or decl.rettypes[1].fqtn ~= decl.fqtn then
        return false
    end

    local owner = types.registry[decl.fqtn]
    if not owner or owner.functions[decl.name] ~= decl then
        return false
    elseif owner._tag == "Type.Record" then
        if owner.custom_constructor or decl.name ~= "new"
           or #decl.params ~= #owner.fields then
            return false
        end
        for index, field in ipairs(owner.fields) do
            if not types.equals(decl.params[index], field.type) then
                return false
            end
        end
        return true
    elseif owner._tag == "Type.Union" then
        local variant = owner.variants[decl.name]
        if not variant or #decl.params ~= #variant.parts then return false end
        for index, part in ipairs(variant.parts) do
            if not types.equals(decl.params[index], part.type) then
                return false
            end
        end
        return true
    end
    return false
end

local function initializer_own_declaration(decl, modname)
    if not decl or decl._foreign_namespace then return false end
    local tag = decl._tag
    if tag == "Ast.TopLevelVar" or tag == "Ast.TopLevelFunc"
       or tag == "Ast.TopLevelForeignFunc"
       or tag == "Ast.TopLevelStatic" or tag == "Ast.TopLevelMethod" then
        return true
    elseif tag == "Type.ModuleVariable" or tag == "Type.ModuleMember" then
        return decl.modname == modname
    elseif tag == "Type.StaticMethod" or tag == "Type.Method" then
        local owner = types.registry[decl.fqtn]
        return nominal_module(decl.fqtn) == modname
            and not (tag == "Type.Method" and owner
                and owner._tag == "Type.Interface")
    end
    return false
end

-- Initialization safety is a dependency rule, not constant folding. Follow the
-- existing expression/variable shapes without entering declaration backrefs.
function initializer_error(root, modname)
    local dependency =
        "module variable initializer cannot reference this module's variables, functions, or methods"
    local seen_nodes, seen_exposed_nodes, plan_callables = {}, {}, {}
    local nominal_callables = {}
    local function own_nominal_callable(typ)
        if not typ or typ._tag ~= "Type.Nominal" then return false end
        local owner = types.registry[typ.fqtn]
        if not owner or (owner._tag ~= "Type.Record"
                and owner._tag ~= "Type.Union") then
            return false
        end
        local known = nominal_callables[owner]
        if known == nil then
            known = false
            for _, method in pairs(owner.methods) do
                if initializer_own_declaration(method, modname) then
                    known = true
                    break
                end
            end
            nominal_callables[owner] = known
        end
        return known
    end
    local function visit_plan(plan, seen)
        if type(plan) ~= "table" or plan._tag or seen[plan] then return false end
        seen[plan] = true
        if plan.kind == "interface_implementation" then
            for _, mapping in ipairs(plan.methods) do
                if initializer_own_declaration(mapping.concrete, modname) then
                    return true
                end
            end
        end
        for _, child in pairs(plan) do
            if visit_plan(child, seen) then return true end
        end
        return false
    end
    local function own_plan_callable(plan)
        if type(plan) ~= "table" or plan._tag then return false end
        local known = plan_callables[plan]
        if known == nil then
            -- Cache a complete root query, not an unfinished child in a
            -- recursive conversion graph. The fact is exposure-independent.
            known = visit_plan(plan, {})
            plan_callables[plan] = known
        end
        return known
    end

    local fixed_origins = {}
    local function fixed_metatable_origin(node)
        if not node then return false end
        local known = fixed_origins[node]
        if known ~= nil then return known end
        local tag = node._tag
        local result = node._type and node._type._tag
        if result == "Type.Nil" or result == "Type.Boolean"
           or result == "Type.Integer" or result == "Type.Float"
           or result == "Type.String" then
            known = true
        elseif tag == "Ast.ExpInitList" or tag == "Ast.ExpFunction"
           or tag == "Ast.ExpMethodRef" or tag == "Ast.ExpUnionInit" then
            -- Fresh Maps have no metatable; the other constructors create
            -- primitive values or objects with compiler-owned metatables.
            known = true
        elseif tag == "Ast.ExpCast" or tag == "Ast.ExpAdjust" then
            known = fixed_metatable_origin(node.exp)
        elseif tag == "Ast.ExpCall" then
            known = isconstructor(node.exp)
        elseif tag == "Ast.ExpBinop"
           and (node.op == "and" or node.op == "or") then
            known = fixed_metatable_origin(node.lhs)
                and fixed_metatable_origin(node.rhs)
        else
            known = false
        end
        fixed_origins[node] = known
        return known
    end
    local function map_receiver_exposed(node)
        return node and node._type and node._type._tag == "Type.Map"
            and not fixed_metatable_origin(node)
    end
    local function map_equality_exposed(node)
        if node._c_operator or (node.op ~= "==" and node.op ~= "~=") then
            return false
        end
        local comparison = maybe3.get_checked(node._comparison, "comparison")
        if not comparison then return false end
        -- Match codebinaryop's original ComparisonPlan types: gradual
        -- injection can already have changed both operand AST types to value.
        local left = types.normalize(comparison.left)
        local right = types.normalize(comparison.right)
        local leftmap, rightmap = left._tag == "Type.Map", right._tag == "Type.Map"
        local dispatch = (leftmap and rightmap)
            or (leftmap and right._tag == "Type.Value")
            or (rightmap and left._tag == "Type.Value")
        return dispatch and not (fixed_metatable_origin(node.lhs)
            and fixed_metatable_origin(node.rhs))
    end

    local visit
    local function visit_list(exps, call_exposed)
        local has_callable = false
        for _, exp in ipairs(exps) do
            local err, child_callable = visit(exp, call_exposed)
            if err then return err end
            has_callable = has_callable or child_callable
        end
        return nil, has_callable
    end
    visit = function(node, call_exposed, constructor)
        if not node then return nil, false end
        -- Shared projections must retain both exposure and stored-callable
        -- facts. Only completed visits are memoized; errors are never cached
        -- as success, and the direct-callee exemption is not a value use.
        local seen = call_exposed and seen_exposed_nodes or seen_nodes
        if not constructor and seen[node] ~= nil then
            return nil, seen[node]
        end
        -- A bare own nominal can reach a concrete method through a dynamic
        -- Interface witness published by another (even unexecuted) body.
        local has_callable = own_nominal_callable(node._type)
        -- Use binary_collect_usage's selective plan convention. AST argument
        -- expressions are mirrored in the ordinary children, not followed
        -- through plan backrefs. An `is` proof constructs no wrapper.
        if node._tag ~= "Ast.ExpIs" then
            for key, child in pairs(node) do
                if type(key) == "string" and key:sub(1, 1) == "_"
                   and key ~= "_arg_adjustment" and key ~= "_generic_arg_adjustment"
                   and (key:match("adjustment$") or key:match("conversion$")
                        or key:match("adapter$")) then
                    has_callable = own_plan_callable(child) or has_callable
                end
            end
        end
        if call_exposed and has_callable then return dependency end

        local tag = node._tag
        local err, child_callable = nil, false
        if tag == "Ast.ExpNil" or tag == "Ast.ExpBool"
           or tag == "Ast.ExpInteger" or tag == "Ast.ExpFloat"
           or tag == "Ast.ExpString" or tag == "Ast.ExpForeignType" then
            -- No evaluated children.

        elseif tag == "Ast.ExpInitList" then
            for _, field in ipairs(node.fields) do
                if type(field.name) == "table" then
                    err, child_callable = visit(field.name, call_exposed)
                    if err then return err end
                    has_callable = has_callable or child_callable
                end
                err, child_callable = visit(field.exp, call_exposed)
                if err then return err end
                has_callable = has_callable or child_callable
            end

        elseif tag == "Ast.ExpCall" then
            if initializer_own_declaration(node._method, modname)
               or initializer_own_declaration(node.args._decl, modname) then
                return dependency
            end
            local generated = isconstructor(node.exp)
            local expose_args = call_exposed or not generated
            local argument_callable = own_plan_callable(node._arg_adjustment)
            if expose_args and argument_callable then return dependency end
            -- The callee expression (including an Interface receiver) is an
            -- invoking position independently of the result's destination.
            err = visit(node.exp, true, generated)
            if err then return err end
            -- Every written expression still evaluates, including discarded
            -- surplus and setup carriers. Only delivered formal values are
            -- stored by a generated constructor and justify its literal proof.
            err = visit_list(call_argument_expressions(node.args), expose_args)
            if err then return err end
            if generated then
                local nominal = node._nominal_constructor
                argument_callable = false
                if nominal then
                    local fixed = node._arg_adjustment
                        and node._arg_adjustment.fixed
                        or call_argument_expressions(node.args)
                    for index = 1, #nominal.slots do
                        err, child_callable = visit(fixed[index], expose_args)
                        if err then return err end
                        argument_callable = argument_callable or child_callable
                    end
                    if argument_callable and nominal.kind == "record"
                       and nominal_module(nominal.owner.name) ~= modname then
                        node._binary_initializer_constructor = true
                    end
                end
                has_callable = has_callable or argument_callable
            end

        elseif tag == "Ast.ExpVar" then
            local var = node.var
            if not constructor
               and initializer_own_declaration(var._decl, modname) then
                return dependency
            elseif var._tag == "Ast.VarDot" then
                err, child_callable = visit(var.exp, call_exposed)
            elseif var._tag == "Ast.VarBracket" then
                local exposed = call_exposed or map_receiver_exposed(var.exp1)
                err, child_callable = visit(var.exp1, exposed)
                if err then return err end
                has_callable = has_callable or child_callable
                err, child_callable = visit(var.exp2, exposed)
            else
                assert(var._tag == "Ast.VarName")
            end
            has_callable = has_callable or child_callable

        elseif tag == "Ast.ExpConcat" then
            err, child_callable = visit_list(node.exps, call_exposed)
            has_callable = has_callable or child_callable

        elseif tag == "Ast.ExpBinop" then
            local exposed = call_exposed or map_equality_exposed(node)
            err, child_callable = visit(node.lhs, exposed)
            if err then return err end
            has_callable = has_callable or child_callable
            err, child_callable = visit(node.rhs, exposed)
            has_callable = has_callable or child_callable

        elseif tag == "Ast.ExpAdjust" and node._adjusted_spread then
            err = visit(node._adjusted_spread, call_exposed)
            if err then return err end
            err, child_callable = visit(node.exp, call_exposed)
            has_callable = has_callable or child_callable

        elseif tag == "Ast.ExpUnop" then
            local exposed = call_exposed
                or (node.op == "#" and not node._c_operator
                    and map_receiver_exposed(node.exp))
            err, child_callable = visit(node.exp, exposed)
            has_callable = has_callable or child_callable

        elseif tag == "Ast.ExpCast" or tag == "Ast.ExpIs" or tag == "Ast.ExpAdjust"
               or tag == "Ast.ExpExtra" or tag == "Ast.ExpDotsIndex" then
            err, child_callable = visit(node.exp, call_exposed)
            if err then return err end
            has_callable = has_callable or child_callable
            if node.length then
                err, child_callable = visit(node.length, call_exposed)
                has_callable = has_callable or child_callable
            end

        elseif tag == "Ast.ExpFunction" then
            if call_exposed then
                return "module variable initializer cannot expose an anonymous function to a call"
            end
            has_callable = true

        elseif tag == "Ast.ExpMethodRef" then
            has_callable = initializer_own_declaration(node._decl, modname)
                or initializer_own_declaration(node._method, modname)
                or has_callable
            if call_exposed and has_callable then return dependency end
            err, child_callable = visit(node.exp, call_exposed)
            has_callable = has_callable or child_callable

        elseif tag == "Ast.ExpSubset" or tag == "Ast.ExpSpread" then
            local exposed = call_exposed
                or (node._spread_kind == "map" and map_receiver_exposed(node.exp))
            err, child_callable = visit(node.exp, exposed)
            if err then return err end
            has_callable = has_callable or child_callable
            err = visit(node.first, call_exposed)
            if err then return err end
            err = visit(node.last, call_exposed)

        elseif tag == "Ast.ExpSpreadIndex" then
            err, child_callable = visit(node.spread, call_exposed)
            has_callable = has_callable or child_callable

        elseif tag == "Ast.ExpUnionInit" then
            err, child_callable = visit_list(node.values, call_exposed)
            has_callable = has_callable or child_callable

        elseif tag ~= "Ast.ExpDots" and tag ~= "Ast.ExpDotsLen" then
            error("invalid module initializer expression " .. tostring(tag))
        end
        if err then return err end
        -- Operators or projections producing scalar values cannot carry a
        -- callback to a constructor, even if their operands stored one.
        local result = node._type
        while result and result._tag == "Type.Option" do result = result.base end
        local result_tag = result and result._tag
        if tag ~= "Ast.ExpSpread"
           and (result_tag == "Type.Nil" or result_tag == "Type.Boolean"
                or result_tag == "Type.Integer" or result_tag == "Type.Float"
                or result_tag == "Type.String") then
            has_callable = false
        end
        if not constructor then seen[node] = has_callable and true or false end
        return nil, has_callable
    end
    local err = visit(root, false)
    return err
end

-- Return the name given the toplevel node
function toplevel_name(node)
    if node._module_initializer then return nil end
    local tag = node._tag
    if tag == "Ast.TopLevelImport" then
        return node.localname
    elseif tag == "Ast.TopLevelForeignImport" then
        return nil
    elseif tag == "Ast.TopLevelVar" then
        return node.decl.name
    elseif tag == "Ast.TopLevelTypeAlias"
           or tag == "Ast.TopLevelForeignTypeAlias"
           or tag == "Ast.TopLevelInterface" then
        -- Type aliases occupy a separate namespace and are deliberately absent
        -- from the ordinary top-level duplicate/value-symbol machinery.
        -- Interfaces are likewise type-only declarations.
        return nil
    elseif tag == "Ast.TopLevelFunc" or
           tag == "Ast.TopLevelForeignFunc" or
           tag == "Ast.TopLevelRecord" or
           tag == "Ast.TopLevelUnion" then
        return node.name
    elseif tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic" then
        return nil
    elseif tag == "Ast.StatBlock" then
        return nil
    else
        error("tag not found " .. tag)
    end
end

-- One namespace is established from the real ordered module header. Foreign
-- directives carry include metadata only; they do not bind ordinary symbols.
function check_foreign_environment(module_ast, st, errors)
    local namespace = st.ffi_namespace or {
        _tag = "Checker.ForeignNamespace", name = "ffi", _builtin = true,
        _readonly = true,
        _type = types.CModule("ffi", {}, {}),
    }
    st.ffi_namespace, module_ast._ffi_namespace = namespace, namespace
    if not st:find_symbol("ffi") then st:add_symbol("ffi", namespace) end
    local nodes, names, has_source = {}, {}, false
    st._native_record_fields_enabled = false
    for _, node in ipairs(module_ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignImport" then
            nodes[#nodes + 1], names[#names + 1] = node, node.headername
            if node.headername == "titan/ffi.h" then
                st._native_record_fields_enabled = true
            end
        elseif not node._ignore and node._tag == "Ast.TopLevelImport"
               and node._source_import then
            has_source = true
        end
    end
    local loc = nodes[1] and nodes[1].loc or module_ast[1] and module_ast[1].loc
        or { filename = st.filename, line = 1, col = 1 }
    local service, options, err
    if #nodes > 0 or has_source or next(st.foreign_aliases) then
        if foreign_c_config_error then err = foreign_c_config_error
        else
            service, err = ensure_probe_service(st)
            if service then options, err = service:cdriver_process_options() end
        end
        if options then
            options.source_dir = st.source_dir
            local includes
            includes, err = cdriver.resolve_includes(names, options)
            if includes then
                for index, node in ipairs(nodes) do
                    node._include, err = cprobe.normalize_include_descriptor(includes[index], {
                        source_dir = st.source_dir, io = options.io,
                    })
                    if not node._include then break end
                end
            end
        end
        if err then checker.typeerror(errors, loc, "%s", err); return end
    end

    local header
    if st.prepare_ffi_header then
        header, err = st.prepare_ffi_header(module_ast)
    elseif options then
        st.ffi_header_owner = st.ffi_header_owner or { io = options.io }
        header, err = ffiheaders.prepare(st.ffi_header_owner, st.modname,
            module_ast, st.filename or (st.modname:gsub("[.]", "/") .. ".titan"))
    end
    if err then checker.typeerror(errors, loc, "%s", err); return end
    if not options then return end
    if not header then
        checker.typeerror(errors, loc, "cannot prepare the module C environment")
        return
    end
    module_ast._ffi_header = header
    local ftypes, include
    ftypes, err, include = cdriver.process_module(header, options)
    if not ftypes then checker.typeerror(errors, loc, "%s", err); return end
    include, err = cprobe.normalize_include_descriptor(include, {
        source_dir = st.source_dir, io = options.io,
    })
    if not include then checker.typeerror(errors, loc, "%s", err); return end
    namespace._include = include
    st.last_foreign_import_node = { loc = loc, headername = "ffi" }
    st.foreign_includes = { include }
    st.foreign_includes_version = (st.foreign_includes_version or 0) + 1
    -- A digest-only adapter has no storage: neither key nor graph is built.
    local conversion_key = cacheadapter.can_get(st.cache_adapter) and
        foreigncache.key(st, namespace)
    if conversion_key and foreigncache.restore(st, namespace, conversion_key) then
        cdriver.emit_process_phase(options, "ffi", include,
            "downstream_ffi_conversion", "cache_hit", cdriver.process_phase_clock(options))
    else
        local started = cdriver.process_phase_clock(options)
        -- The one real module header has already established final macro
        -- visibility. Field lookup results have explicit analysis states, so their map must
        -- belong to this checker rather than the shared immutable header graph.
        st.foreign_field_macro_cache = {}
        for name, classification in pairs(ftypes.field_macro_classes) do
            st.foreign_field_macro_cache[name] =
                maybe3.from_optional(classification or nil)
        end
        local members, type_members = {}, {}
        for _, item in ipairs(ftypes) do
            local name, ftype = item.name, item.type
            local decl, conversion_error, declaration = foreigntypes.convert(st, ftype, name, include)
            if decl then
                types.mark_c_ffi_include(decl, include)
                if is_foreign_type_declaration(ftype) then
                    type_members[name] = decl
                    st:add_foreign_type(name, decl)
                else
                    local paramnames = ftype.type == "function"
                        and copy_foreign_paramnames(ftype.paramnames) or nil
                    local member = types.ModuleMember("ffi", name, decl, paramnames)
                    member._foreign_namespace = true
                    member._c_origin_header = declaration and declaration.origin_header or include
                    member._c_integer_constant = declaration and declaration.integer_constant
                    members[name] = member
                end
                if is_foreign_ordinary_identifier(name, ftype) then
                    st:add_foreign_name(name, {
                        header = "ffi", type = decl, declaration = declaration,
                        import_node = namespace,
                    })
                end
            elseif conversion_error and conversion_error:match("^conflicting C tag kinds") then
                checker.typeerror(errors, loc, "%s", conversion_error)
            end
        end
        for name, metadata in pairs(ftypes.file_scope_tags or {}) do
            if (metadata.kind == "struct" or metadata.kind == "union")
               and not (ftypes.typedef_names and ftypes.typedef_names[name]) then
                type_members[name] = st:find_foreign_type(metadata.raw_key)
            end
        end
        namespace._type = types.CModule("ffi", members, type_members)
        cdriver.emit_process_phase(options, "ffi", include,
            "downstream_ffi_conversion", "complete", started)
        if conversion_key and #errors == 0 and cacheadapter.can_put(st.cache_adapter) then
            foreigncache.store(st, conversion_key,
                foreigncache.encode(st, namespace, conversion_key), namespace)
        end
    end
    validate_foreign_environment(st, errors)
end

-- Typecheck the toplevel node
toplevel_visitor = util.make_visitor({
    ["Ast.TopLevelImport"] = function(node, st, errors, loader)
        local request = node.source_required and {
            kind = "source-import",
        } or nil
        local modtype, errs, import_info =
            checker._checkimport_for(st, node.modname, loader, request)
        if modtype then
            node._type = modtype
            -- The syntax explicitly requests the collaboration view, while
            -- trusted loader provenance proves that source was actually
            -- selected. Neither half alone grants private visibility.
            node._source_import = node.source_required and import_info
                and import_info.kind == "source"
                and modtype._source == true
            if node._source_import then
                node._ffi_header_descriptor = import_info.ffi_header_descriptor
                node._ffi_header = import_info.checking_ffi_header or import_info.ffi_header
                node._ffi_header_probe_identity = import_info.ffi_header
                node._foreign_header = import_info.foreign_header
                node._foreign_header_for_check = import_info.foreign_header_for_check == true
                node._foreign_header_probe_identity = import_info.foreign_header_probe_identity
                -- Titan private visibility remains direct; only C header edges
                -- inherit transitively through the generated environment.
                st.source_imports[node.modname] =
                    st.source_imports[node.modname] or node
            end
            for _, err in ipairs(errs) do
                table.insert(errors, err)
            end
        else
            node._type = invalid(errors, node.loc,
                "problem loading module '%s': %s",
                node.modname, errs)
        end
    end,

    ["Ast.TopLevelForeignImport"] = function()
        -- Unbound directives are collected by check_foreign_environment.
    end,

    ["Ast.TopLevelVar"] = function(node, st, errors)
        node._module_name = st.modname
        if node.value == nil then
            node._initializerless_const = node.isconst and true or nil
            local subject = (node.isconst and "const " or "") .. "module variable"
            local value = ast.ExpNil(node.decl.loc)
            if not node.decl.type then
                checker.typeerror(errors, node.decl.loc,
                    "%s '%s' without an initializer requires an explicit type",
                    subject, node.decl.name)
                node._type = types.Invalid()
                value._type = node._type
            else
                node._type = typefromnode(node.decl.type, st, errors)
                checktype(node._type,
                    node.decl.type.loc or node.loc, errors)
                report_incomplete_c_object(node._type, st,
                    "declaration of module variable '" ..
                        node.decl.name .. "'",
                    node.decl.type.loc or node.loc, errors)
                if not types.accepts_missing_nil(node._type) then
                    checker.typeerror(errors, node.decl.loc,
                        "%s '%s' cannot be initialized with nil because type '%s' does not accept nil",
                        subject, node.decl.name, types.tostring(node._type))
                    value._type = types.Invalid()
                else
                    checkexp(value, st, errors, node._type)
                    value = coerce_and_check(
                        value, node._type,
                        "nil initialization of " .. subject .. " " ..
                            node.decl.name,
                        errors, node.loc)
                end
            end
            node.value = value
        elseif node.decl.type then
            node._type = typefromnode(node.decl.type, st, errors)
            checktype(node._type, node.decl.type.loc or node.loc, errors)
            report_incomplete_c_object(node._type, st,
                "declaration of module variable '" .. node.decl.name .. "'",
                node.decl.type.loc or node.loc, errors)
            checkexp(node.value, st, errors, node._type)
            node.value = coerce_and_check(
                node.value, node._type,
                "declaration of module variable " .. node.decl.name,
                errors, node.loc)
        elseif node.decl.option then
            checkexp(node.value, st, errors)
            node._type = optionize(node.value._type)
            node.value = trycoerce(node.value, node._type, errors)
        else
            checkexp(node.value, st, errors)
            node.value = tryforce(node.value)
            node._type = node.value._type
        end
        node.decl._type = node._type
        check_user_value_slot_type(
            "module", st.modname, "variable", node.decl.name,
            node._type, node.decl.type and node.decl.type.loc or node.loc,
            errors)
        -- The public module `__newindex` path is a genuine Lua boundary.  Keep
        -- an explicit unavailable marker for non-reifiable targets so its
        -- generated setter rejects every attempted Lua write.
        node._lua_write_dynamic_plan =
            maybe3.from_optional(types.dynamic_coercion(node._type))
        local err = initializer_error(node.value, st.modname)
        if err then
            checker.typeerror(errors, node.value.loc, "%s", err)
        end
    end,

    ["Ast.TopLevelTypeAlias"] = function(node, st, errors)
        resolve_type_alias(node, st, errors)
    end,

    ["Ast.TopLevelForeignTypeAlias"] = function(node, st, errors)
        resolve_foreign_type_alias(node, st, errors)
    end,

    -- Implementation notes: doc/implementation/interfaces.md#declaration-staging-and-publication
    ["Ast.TopLevelInterface"] = function(node, st, errors)
        return generic_with_owner_bindings(node, st, function()
            local fqtn = st.modname .. "." .. node.name
            local fields = {}
            local methods = {}
            local member_names = {}
            if #(node.members or {}) == 0 then
                checker.typeerror(errors, node.loc,
                    "interface '%s' must declare at least one field or method",
                    node.name)
                node._type = types.Invalid()
                return
            end
            if #node.fields > 65533 then
                checker.typeerror(errors, node.loc,
                    "interface '%s' declares %d fields but at most 65533 are supported",
                    node.name, #node.fields)
            end

            for _, member in ipairs(node.members) do
                local previous = member_names[member.name]
                if previous then
                    local kind = member._tag == "Ast.InterfaceMethod"
                        and "method" or "field"
                    local previous_kind =
                        previous._tag == "Ast.InterfaceMethod"
                            and "method" or "field"
                    if kind == previous_kind then
                        checker.typeerror(errors, member.loc,
                            "redeclaration of %s '%s' in interface '%s'",
                            kind, member.name, node.name)
                    else
                        checker.typeerror(errors, member.loc,
                            "member '%s' in interface '%s' is declared as both a %s and a %s",
                            member.name, node.name, previous_kind, kind)
                    end
                    member._ignore = true
                elseif member._tag == "Ast.Decl" then
                    member_names[member.name] = member
                    local ftype = typefromnode(member.type, st, errors)
                    member._type = ftype
                    local tfield = types.Field(
                        fqtn, member.name, ftype, #fields, true)
                    tfield.dynamic_plan =
                        maybe3.from_optional(types.dynamic_coercion(ftype))
                    member._field = tfield
                    member._decl = tfield
                    member._dynamic_plan = tfield.dynamic_plan
                    fields[#fields + 1] = tfield
                else
                    assert(member._tag == "Ast.InterfaceMethod")
                    member_names[member.name] = member
                    generic_prepare_generic_binders(member, st, errors, node)
                    generic_with_generic_binding_map(st, member._generic_bindings,
                        function()
                            local ptypes, varargtype, paramnames =
                                param_types(member.params, st, errors)
                            local fixed_index = 1
                            local param_names = {}
                            for _, param in ipairs(member.params) do
                                if param.name == nil then
                                    param._type = varargtype
                                else
                                    param._type = ptypes[fixed_index]
                                    fixed_index = fixed_index + 1
                                    if param_names[param.name] then
                                        checker.typeerror(errors, param.loc,
                                            "duplicate parameter '%s' in interface method '%s:%s'",
                                            param.name, node.name, member.name)
                                    else
                                        param_names[param.name] = true
                                    end
                                end
                            end

                            local rettypes = {}
                            for _, rettype in ipairs(member.rettypes) do
                                rettypes[#rettypes + 1] =
                                    typefromnode(rettype, st, errors)
                            end
                            local flexrettype =
                                flexible_return_type(member, st, errors)
                            member._type = types.Method(
                                fqtn, member.name, ptypes, rettypes,
                                varargtype, flexrettype, paramnames,
                                member._generic_scope,
                                member._generic_typeparams)
                            member._decl = member._type
                            bind_callable_parameter_declarations(
                                member, member._type, "member", fqtn,
                                member.islocal)
                        end)
                    annotate_lua_function_boundary(member)
                    methods[#methods + 1] = member._type
                end
            end

            node._type = types.Interface(fqtn, fields, methods,
                node._generic_scope, node._generic_typeparams)
            node._type._generic_parameters = node._generic_parameters
            node._type._source_complete = true
            node._dynamic_receiver_plan = assert(types.dynamic_coercion(
                types.Nominal(fqtn,
                    generic_parameter_arguments(node._type))),
                "Interface nominal lacks its dynamic receiver plan")
            types.registry[fqtn] = node._type
        end)
    end,

    ["Ast.TopLevelFunc"] = function(node, st, errors)
        generic_prepare_generic_binders(node, st, errors)
        return generic_with_generic_binding_map(st, node._generic_bindings, function()
            local ptypes, varargtype, paramnames =
                param_types(node.params, st, errors)
            local rettypes = {}
            for _, rt in ipairs(node.rettypes) do
                rettypes[#rettypes + 1] = typefromnode(rt, st, errors)
            end
            local flexrettype = flexible_return_type(node, st, errors)
            local signature = types.Function(ptypes, rettypes, false,
                varargtype, flexrettype)
            node._signature = signature
            if node._generic_scope ~= nil then
                node._type = types.FunctionScheme(node._generic_scope,
                    node._generic_typeparams, signature)
            else
                node._type = signature
            end
            node._paramnames = paramnames
            bind_callable_parameter_declarations(
                node, node._type, "module", st.modname, node.islocal)
        end)
    end,

    ["Ast.TopLevelForeignFunc"] = function(node, st, errors)
        local argnodes = {}
        local paramnames = {}
        local varargtype = nil
        for _, param in ipairs(node.params) do
            if param.name == nil then
                varargtype = param.type or { loc = param.loc }
            else
                argnodes[#argnodes + 1] = param.type
                paramnames[#paramnames + 1] = param.name
            end
        end
        node._type = checker._foreign_function_signature(
            argnodes, node.rettypes, varargtype, node.flexrettype,
            st, errors, "foreign function '" .. node.name .. "'")
        node._foreign_module = st.modname
        node._paramnames = paramnames
        for index, param in ipairs(node.params) do
            if param.name ~= nil then
                param._type = node._type.params[index]
            end
        end
    end,

    ["Ast.StatBlock"] = function(node)
        node._type = types.Function({}, {}, false, nil, nil)
    end,

    ["Ast.StatTry"] = function(node)
        assert(node._module_initializer)
        node._type = types.Function({}, {}, false, nil, nil)
    end,

    ["Ast.TopLevelRecord"] = function(node, st, errors)
        return generic_with_owner_bindings(node, st, function()
            local fields = {}
            local nameset = {}
            local fqtn = st.modname .. "." .. node.name
            for i, field in ipairs(node.fields) do
                if nameset[field.name] then
                    checker.typeerror(errors, field.loc,
                        "redeclaration of field '%s' in record '%s'",
                        field.name, node.name)
                else
                    nameset[field.name] = true
                    local ftype, array_view = checker._nominal_member_type(
                        field.type, typefromnode(field.type, st, errors))
                    field._type = ftype
                    local tfield = types.Field(
                        fqtn, field.name, ftype, i - 1,
                        field.isconst and true or false)
                    tfield.islocal = field.islocal and true or false
                    field._nominal_storage =
                        checker._nominal_storage_plan(ftype, array_view)
                    tfield._nominal_storage = field._nominal_storage
                    tfield.dynamic_plan =
                        maybe3.from_optional(types.dynamic_coercion(ftype))
                    field._dynamic_plan = tfield.dynamic_plan
                    field._field = tfield
                    field._decl = tfield
                    fields[#fields + 1] = tfield
                end
            end
            node._type = types.Record(fqtn, fields, {}, {}, #fields,
                node._generic_scope, node._generic_typeparams,
                node._custom_constructor and true or false)
            node._type._generic_parameters = node._generic_parameters
            node._type.islocal = node.islocal and true or false
            node._type._source_complete = true
            node._dynamic_receiver_plan = assert(types.dynamic_coercion(
                types.Nominal(fqtn, generic_parameter_arguments(node._type))),
                "record nominal lacks its dynamic receiver plan")
            types.registry[fqtn] = node._type
        end)
    end,

    -- Implementation notes: doc/implementation/unions.md#declaration-checking-and-visibility
    ["Ast.TopLevelUnion"] = function(node, st, errors)
        return generic_with_owner_bindings(node, st, function()
            local variants = {}
            local nameset = {}
            local fqtn = st.modname .. "." .. node.name
            if #node.variants == 0 then
                checker.typeerror(errors, node.loc,
                    "union '%s' must declare at least one variant", node.name)
            end
            local public_count = 0
            for _, variant in ipairs(node.variants) do
                if not (node.islocal or variant.islocal) then
                    public_count = public_count + 1
                end
            end
            local public_tag, private_tag = 0, public_count
            for _, variant in ipairs(node.variants) do
                if nameset[variant.name] then
                    checker.typeerror(errors, variant.loc,
                        "redeclaration of variant '%s' in union '%s'",
                        variant.name, node.name)
                    variant._ignore = true
                else
                    nameset[variant.name] = variant
                    local parts, partnames = {}, {}
                    if #variant.parts > 65534 then
                        checker.typeerror(errors, variant.loc,
                            "variant '%s.%s' declares %d payload parts but at most 65534 are supported",
                            node.name, variant.name, #variant.parts)
                    end
                    for part_index, part in ipairs(variant.parts) do
                        if partnames[part.name] then
                            checker.typeerror(errors, part.loc,
                                "redeclaration of payload part '%s' in variant '%s.%s'",
                                part.name, node.name, variant.name)
                        end
                        partnames[part.name] = true
                        local ptype, array_view = checker._nominal_member_type(
                            part.type, typefromnode(part.type, st, errors))
                        local tpart = types.Field(
                            fqtn, part.name, ptype, part_index, false)
                        tpart.dynamic_plan =
                            maybe3.from_optional(types.dynamic_coercion(ptype))
                        part._type, part._decl = ptype, tpart
                        part._nominal_storage =
                            checker._nominal_storage_plan(ptype, array_view)
                        tpart._nominal_storage = part._nominal_storage
                        parts[part_index] = tpart
                    end
                    local islocal = (node.islocal or variant.islocal) and true or false
                    local tag = islocal and private_tag or public_tag
                    if islocal then private_tag = private_tag + 1
                    else public_tag = public_tag + 1 end
                    local tvariant = types.Variant(
                        fqtn, variant.name, parts, tag)
                    tvariant.islocal =
                        islocal
                    variant._type = tvariant
                    variant._decl = tvariant
                    variants[#variants + 1] = tvariant
                end
            end
            node._type = types.Union(fqtn, variants, {}, {}, #node.variants,
                node._generic_scope, node._generic_typeparams)
            node._type._generic_parameters = node._generic_parameters
            node._type.islocal = node.islocal and true or false
            node._type._source_complete = true
            node._dynamic_receiver_plan = assert(types.dynamic_coercion(
                types.Nominal(fqtn, generic_parameter_arguments(node._type))),
                "union nominal lacks its dynamic receiver plan")
            types.registry[fqtn] = node._type
        end)
    end,

    ["Ast.TopLevelStatic"] = function(node, st, errors)
        local owner = st:find_symbol(node.class)
        if not owner then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "record referenced by record function declaration '%s.%s' does not exist",
                node.class, node.name)
            return
        end
        if owner._tag ~= "Ast.TopLevelRecord"
           and owner._tag ~= "Ast.TopLevelUnion" then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "member referenced by record function declaration '%s.%s' is not a record",
                node.class, node.name)
            return
        end
        local ownertype = owner._type
        local owner_kind = ownertype._tag == "Type.Record"
            and "record" or "union"
        if ownertype._tag == "Type.Record" then
            for _, field in ipairs(ownertype.fields) do
                if field.name == node.name then
                    node._ignore = true
                    checker.typeerror(errors, node.loc,
                    "cannot declare record function '%s.%s' as field '%s' exists in record '%s'",
                        node.class, node.name, field.name, node.class)
                    return
                end
            end
        end
        if ownertype.methods[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "cannot declare %s function '%s.%s' as method '%s:%s' exists in %s '%s'",
                    owner_kind, node.class, node.name, node.class, node.name,
                    owner_kind, node.class)
            return
        end
        if ownertype.functions[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "redeclaration of %s function '%s.%s'",
                owner_kind, node.class, node.name)
            return
        end
        if node._union_constructor then
            local variant = node._union_variant
            if not variant or variant._ignore or not variant._type
               or ownertype._tag ~= "Type.Union"
               or ownertype.variants[node.name] ~= variant._type then
                node._ignore = true
                return
            end
        end
        if owner.islocal then node.islocal = true end
        node._nominal_owner = owner
        node._owner_decl = owner
        generic_with_owner_bindings(owner, st, function()
            generic_prepare_generic_binders(node, st, errors, owner)
            generic_with_generic_binding_map(st, node._generic_bindings, function()
                local ptypes, varargtype, paramnames =
                    param_types(node.params, st, errors)
                local constructor_slots = node._record_constructor
                    and ownertype.fields or node._union_constructor
                    and node._union_variant._type.parts
                if constructor_slots then
                    for index, slot in ipairs(constructor_slots) do
                        ptypes[index] = slot.type
                        node.params[index]._nominal_storage =
                            slot._nominal_storage
                    end
                end
                local rettypes = {}
                for _, rt in ipairs(node.rettypes) do
                    rettypes[#rettypes + 1] =
                        typefromnode(rt, st, errors)
                end
                local flexrettype = flexible_return_type(node, st, errors)
                node._type = types.StaticMethod(
                    ownertype.name, node.name, ptypes, rettypes,
                    varargtype, flexrettype, paramnames,
                    node._generic_scope, node._generic_typeparams)
            end)
        end)
        node._type.islocal = node.islocal and true or false
        node._type._owner_scope = ownertype.scope
        node._type._owner_typeparams = ownertype.typeparams
        node._type._owner_parameters = ownertype._generic_parameters
        node._decl = node._type
        if node._record_constructor then
            bind_callable_parameter_declarations(
                node, node._type, "member", ownertype.name, node.islocal,
                ownertype.fields)
        else
            bind_callable_parameter_declarations(
                node, node._type, "member", ownertype.name, node.islocal)
        end
        ownertype.functions[node.name] = node._type
    end,

    ["Ast.TopLevelMethod"] = function(node, st, errors)
        local owner = st:find_symbol(node.class)
        if not owner then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "record referenced by method declaration '%s:%s' does not exist",
                node.class, node.name)
            return
        end
        if owner._tag ~= "Ast.TopLevelRecord"
           and owner._tag ~= "Ast.TopLevelUnion" then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "member referenced by method declaration '%s:%s' is not a record",
                node.class, node.name)
            return
        end
        local ownertype = owner._type
        local owner_kind = ownertype._tag == "Type.Record"
            and "record" or "union"
        if ownertype._tag == "Type.Record" then
            for _, field in ipairs(ownertype.fields) do
                if field.name == node.name then
                    node._ignore = true
                    checker.typeerror(errors, node.loc,
                    "cannot declare method '%s:%s' as field '%s' exists in record '%s'",
                        node.class, node.name, field.name, node.class)
                    return
                end
            end
        end
        if ownertype.functions[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "cannot declare method '%s:%s' as %s function '%s.%s' exists in %s '%s'",
                    node.class, node.name, owner_kind, node.class, node.name,
                    owner_kind, node.class)
            return
        end
        if ownertype.methods[node.name] then
            node._ignore = true
            checker.typeerror(errors, node.loc,
                "redeclaration of method '%s:%s'", node.class, node.name)
            return
        end
        if owner.islocal then node.islocal = true end
        node._nominal_owner = owner
        node._owner_decl = owner
        generic_with_owner_bindings(owner, st, function()
            generic_prepare_generic_binders(node, st, errors, owner)
            generic_with_generic_binding_map(st, node._generic_bindings, function()
                local ptypes, varargtype, paramnames =
                    param_types(node.params, st, errors)
                local rettypes = {}
                for _, rt in ipairs(node.rettypes) do
                    rettypes[#rettypes + 1] =
                        typefromnode(rt, st, errors)
                end
                local flexrettype = flexible_return_type(node, st, errors)
                node._type = types.Method(
                    ownertype.name, node.name, ptypes, rettypes,
                    varargtype, flexrettype, paramnames,
                    node._generic_scope, node._generic_typeparams)
            end)
        end)
        node._type.islocal = node.islocal and true or false
        node._type._owner_scope = ownertype.scope
        node._type._owner_typeparams = ownertype.typeparams
        node._decl = node._type
        bind_callable_parameter_declarations(
            node, node._type, "member", ownertype.name, node.islocal)
        ownertype.methods[node.name] = node._type
    end,
})

-- Collect type-only declarations before the signature pass so aliases may be
-- used by earlier functions, variables, nominals, Interfaces, and other
-- aliases. Records and unions own both the type and value namespaces, so they
-- remain authoritative over a conflicting alias or Interface regardless of
-- source order. Interfaces and aliases otherwise use first-declaration-wins in
-- their shared type-only namespace.
function collect_type_aliases(ast, st, errors)
    st.foreign_alias_order = {}
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelForeignTypeAlias" then
            local previous = st:find_foreign_alias(node.name)
            if previous then
                checker.typeerror(errors, node.loc,
                    "duplicate foreign type alias for %s, previous one at %s",
                    node.name, location.format(previous.loc))
                node._ignore = true
            else
                st:add_foreign_alias(node.name, node)
            end
        end
    end
    local nominals = {}
    for _, node in ipairs(ast) do
        if not node._ignore
           and (node._tag == "Ast.TopLevelRecord"
                or node._tag == "Ast.TopLevelUnion") then
            if not nominals[node.name] then
                nominals[node.name] = node
            end
        end
    end

    st.interface_declarations = {}
    local type_only = {}
    for _, node in ipairs(ast) do
        if not node._ignore
           and (node._tag == "Ast.TopLevelTypeAlias"
                or node._tag == "Ast.TopLevelInterface") then
            local nominal = nominals[node.name]
            local previous = type_only[node.name]
            if nominal then
                local kind = nominal._tag == "Ast.TopLevelRecord"
                    and "record" or "union"
                local subject = node._tag == "Ast.TopLevelInterface"
                    and "interface" or "type alias"
                checker.typeerror(errors, node.loc,
                    "%s '%s' conflicts with %s declared at %s",
                    subject, node.name, kind, location.format(nominal.loc))
                node._ignore = true
            elseif previous then
                if node._tag == "Ast.TopLevelTypeAlias"
                   and previous._tag == "Ast.TopLevelTypeAlias" then
                    checker.typeerror(errors, node.loc,
                        "duplicate type alias for %s, previous one at %s",
                        node.name, location.format(previous.loc))
                elseif node._tag == "Ast.TopLevelInterface"
                       and previous._tag == "Ast.TopLevelInterface" then
                    checker.typeerror(errors, node.loc,
                        "duplicate interface '%s', previous one at %s",
                        node.name, location.format(previous.loc))
                else
                    local subject = node._tag == "Ast.TopLevelInterface"
                        and "interface" or "type alias"
                    local previous_kind =
                        previous._tag == "Ast.TopLevelInterface"
                        and "interface" or "type alias"
                    checker.typeerror(errors, node.loc,
                        "%s '%s' conflicts with %s declared at %s",
                        subject, node.name, previous_kind,
                        location.format(previous.loc))
                end
                node._ignore = true
            else
                type_only[node.name] = node
                if node._tag == "Ast.TopLevelTypeAlias" then
                    st:add_type_alias(node.name, node)
                else
                    st.interface_declarations[node.name] = node
                end
            end
        end
        ::continue_type_only::
    end
end

-- Mark duplicate ordinary top-level declarations before signature collection.
-- Records and all named declarations are then safe to reserve up front without
-- changing the existing "first declaration wins" rule.
function mark_toplevel_duplicates(ast, errors)
    local first = {}
    for index, node in ipairs(ast) do
        node._toplevel_order = index
        if node._tag:sub(1, 12) == "Ast.TopLevel" then
            node._decl = node
            if node._tag == "Ast.TopLevelVar" then
                node.decl._decl = node
            end
        end
        local name = toplevel_name(node)
        if name then
            local previous = first[name]
            if previous then
                checker.typeerror(errors, node.loc,
                    "duplicate declaration for %s, previous one at %s",
                    name, location.format(previous.loc))
                node._ignore = true
            else
                first[name] = node
            end
        end
    end
end

function reserve_toplevel_names(ast, st)
    for _, node in ipairs(ast) do
        if not node._ignore then
            local name = toplevel_name(node)
            if name then st:add_symbol(name, node) end
        end
    end
end

-- The parser emits each nominal's marked synthesized constructor(s)
-- immediately after its declaration. Treat them as part of the nominal
-- declaration pass: an earlier module variable or explicit member can then use
-- the complete namespace even when the written declaration appears later.
function generic_reserve_generic_owner_headers(ast, st, errors)
    local owners = {}
    for _, node in ipairs(ast) do
        if not node._ignore and (node._tag == "Ast.TopLevelRecord"
                or node._tag == "Ast.TopLevelUnion"
                or node._tag == "Ast.TopLevelInterface") then
            if #(node.typeparams or {}) > 0 then
                local scope = generic_scope_for_node(node, st)
                generic_reserve_generic_binders(node, scope, st, errors)
            else
                node._generic_scope = nil
                node._generic_bindings = {}
                node._generic_parameters = {}
                node._generic_typeparams = {}
                node._generic_constraints_resolved = true
            end
            local fqtn = st.modname .. "." .. node.name
            local tag = node._tag == "Ast.TopLevelRecord" and "Type.Record"
                or (node._tag == "Ast.TopLevelUnion" and "Type.Union"
                    or "Type.Interface")
            local placeholder = {
                _tag = tag,
                name = fqtn,
                scope = node._generic_scope,
                typeparams = node._generic_typeparams,
                _generic_parameters = node._generic_parameters,
                _generic_header = true,
                islocal = node.islocal and true or false,
            }
            if tag == "Type.Record" then
                placeholder.fields, placeholder.functions,
                    placeholder.methods, placeholder.nfields = {}, {}, {}, 0
            elseif tag == "Type.Union" then
                placeholder.variants, placeholder.functions,
                    placeholder.methods, placeholder.nvariants = {}, {}, {}, 0
            else
                placeholder.fields, placeholder.methods = {}, {}
            end
            node._type = placeholder
            types.registry[fqtn] = placeholder
            owners[#owners + 1] = node
        end
    end

    -- Every owner and every binder spelling is reserved before the first
    -- constraint is resolved, so forward Interface constraints and mutually
    -- referring parameters see the complete declaration namespace. Constraint
    -- applications are queued during this pass because a forward header's
    -- shared binder list may not contain its constraints yet.
    st.resolving_generic_owner_constraints = true
    for _, node in ipairs(owners) do
        if not node._generic_constraints_resolved then
            generic_resolve_generic_constraints(node, st, errors)
        end
    end
    st.resolving_generic_owner_constraints = false
end

function generic_validate_pending_generic_constraints(st, errors)
    local pending = st.pending_generic_constraints or {}
    st.pending_generic_constraints = {}
    for _, application in ipairs(pending) do
        generic_validate_binder_arguments(application.scope,
            application.typeparams, application.arguments,
            st, errors, application.loc, application.subject, false)
    end

    local reconstructions = st.pending_generic_reconstructions or {}
    st.pending_generic_reconstructions = {}
    for _, application in ipairs(reconstructions) do
        local owner = types.registry[application.fqtn]
        if owner then
            generic_validate_owner_reconstruction(
                owner, application.arguments, st, errors,
                application.loc, application.subject, false)
        end
    end
end

-- Implementation notes: doc/implementation/record-constructors.md#declaration-staging-and-call-lowering
function collect_nominal_constructors(ast)
    local constructors = {}
    local custom_records = {}
    local superseded = {}
    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelStatic"
           and node.name == "new" and not node._record_constructor
           and not node._union_constructor then
            custom_records[node.class] = true
        end
    end
    for index, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelRecord" then
            local constructor = ast[index + 1]
            if constructor and constructor._tag == "Ast.TopLevelStatic"
               and constructor._record_constructor then
                assert(constructor.class == node.name and
                       constructor.name == "new")
                node._custom_constructor = custom_records[node.name]
                if node._custom_constructor then
                    superseded[#superseded + 1] = index + 1
                elseif node._ignore then
                    constructor._ignore = true
                else
                    constructors[#constructors + 1] = constructor
                end
            end
        elseif node._tag == "Ast.TopLevelUnion" then
            local offset = 1
            while true do
                local constructor = ast[index + offset]
                if not constructor
                   or constructor._tag ~= "Ast.TopLevelStatic"
                   or not constructor._union_constructor
                   or not constructor._union_variant then
                    break
                end
                assert(constructor.class == node.name)
                if node._ignore then constructor._ignore = true end
                constructors[#constructors + 1] = constructor
                offset = offset + 1
            end
        end
    end
    -- A successful checked AST contains only real callable declarations.
    -- `_ignore` is error recovery, not a second hidden constructor lifetime.
    for index = #superseded, 1, -1 do
        table.remove(ast, superseded[index])
    end
    return constructors
end

function visit_toplevel(node, st, errors, loader)
    st.current_toplevel_order = node._toplevel_order
    toplevel_visitor(node, st, errors, loader)
    documentation.bind_declaration(node)
    st.current_toplevel_order = nil
end

-- Binary interfaces carry C declaration identity and checked field shapes,
-- never header inheritance. The importing translation unit must have the same
-- real declaration before generated public payloads can name or embed it.
function check_imported_c_declarations(module_ast, st, errors)
    local reported = {}
    for _, node in ipairs(module_ast) do
        if not node._ignore and node._tag == "Ast.TopLevelImport"
           and node._type and node._type._tag == "Type.Module" then
            local seen = {}
            local function visit(typ)
                if type(typ) ~= "table" or seen[typ] or typ.islocal then return end
                seen[typ] = true
                local tag = typ._tag
                if tag == "Type.Nominal" then
                    visit(types.registry[typ.fqtn])
                elseif tag == "Type.CTypedef" or tag == "Type.CStruct"
                       or tag == "Type.CUnion" then
                    if types.is_c_lua_state(typ) then return end
                    local visible
                    if tag == "Type.CTypedef" then
                        visible = st.ffi_namespace._type.type_members[typ.name]
                    elseif typ.tagname then
                        local declaration = st:find_c_file_tag(typ.tagname,
                            tag == "Type.CStruct" and "struct" or "union")
                        visible = declaration and declaration.canonical
                    elseif typ.typedef then
                        visible = types.resolve_c_typedef(
                            st.ffi_namespace._type.type_members[typ.typedef])
                    end
                    local matches = visible and types.equals(typ, visible)
                    if matches and tag == "Type.CTypedef" then
                        matches = types.equals(typ.target, visible.target)
                    end
                    if not matches then
                        local key = types.c_reference_key(typ) or tostring(typ)
                        if not reported[key] then
                            reported[key] = true
                            checker.typeerror(errors, node.loc,
                                "imported C declaration '%s' from module '%s' is not visible " ..
                                "with its original identity and layout; foreign import its " ..
                                "declaring header or use an explicit .titan source import",
                                types.tostring(typ), node.modname)
                        end
                        return
                    end
                end
                for key, child in pairs(typ) do
                    if type(key) ~= "string" or (key:sub(1, 1) ~= "_"
                       and key ~= "owner" and key ~= "source_members"
                       and key ~= "source_type_members" and key ~= "dynamic_plan") then
                        visit(child)
                    end
                end
            end
            visit(node._type)
        end
    end
end

-- Collect top-level declarations in dependency order while retaining the AST's
-- logical source order for interfaces and code generation. Imports establish
-- the type environment; records and their constructors come next; other
-- callable signatures follow; module variables are checked last, one by one.
-- During that last pass the symbol table hides later imports and the current or
-- later module variables, preserving the only sequential declaration boundary.
-- Implementation notes: doc/implementation/checker.md#staged-top-level-collection-and-body-checking
function checktoplevel(ast, st, errors, loader)
    reserve_toplevel_names(ast, st)
    local constructors = collect_nominal_constructors(ast)

    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelImport" then
            visit_toplevel(node, st, errors, loader)
        end
    end
    checker._finish_import_phase(st)
    check_foreign_environment(ast, st, errors)
    if next(st.foreign_aliases) then
        local before = #errors
        for _, node in ipairs(ast) do
            if not node._ignore and node._tag == "Ast.TopLevelForeignTypeAlias" then
                resolve_foreign_type_alias(node, st, errors)
            end
        end
        if #errors == before then
            ast._foreign_typedefs = {}
            for _, node in ipairs(st.foreign_alias_order) do
                ast._foreign_typedefs[#ast._foreign_typedefs + 1] = node._c_typedef
            end
            st:reset_foreign_environment()
            check_foreign_environment(ast, st, errors)
            for _, node in ipairs(st.foreign_alias_order) do
                local declared = st.ffi_namespace._type.type_members[node.name]
                if declared and declared._tag == "Type.CTypedef" then
                    node._type = declared
                elseif #errors == before then
                    -- Some C compilers merely warn for `typedef long int;`.
                    -- Success must establish the exact requested typedef, not
                    -- just accept a declaration with no declarator name.
                    checker.typeerror(errors, node.loc,
                        "foreign type alias '%s' does not declare a valid C typedef name",
                        node.name)
                    node._type = types.Invalid()
                end
            end
        end
    end
    check_imported_c_declarations(ast, st, errors)
    -- Structural constraints cannot be decided until every nominal method
    -- signature has populated its canonical owner descriptor. Keep every
    -- signature-time application deferrable across aliases, owners, top-level
    -- functions, methods, and statics, independent of declaration order.
    st.generic_signatures_incomplete = true
    generic_reserve_generic_owner_headers(ast, st, errors)

    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelTypeAlias" then
            visit_toplevel(node, st, errors, loader)
        end
    end

    for _, node in ipairs(ast) do
        if not node._ignore
           and (node._tag == "Ast.TopLevelRecord"
                or node._tag == "Ast.TopLevelUnion") then
            visit_toplevel(node, st, errors, loader)
        end
    end

    for _, node in ipairs(ast) do
        if not node._ignore
           and node._tag == "Ast.TopLevelInterface" then
            visit_toplevel(node, st, errors, loader)
        end
    end

    for _, node in ipairs(constructors) do
        if not node._ignore then visit_toplevel(node, st, errors, loader) end
    end

    for _, node in ipairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelFunc"
               or tag == "Ast.TopLevelForeignFunc"
               or node._module_initializer
               or tag == "Ast.StatBlock" or tag == "Ast.StatTry" then
                visit_toplevel(node, st, errors, loader)
            end
        end
    end

    for _, node in ipairs(ast) do
        if not node._ignore then
            local tag = node._tag
            if (tag == "Ast.TopLevelMethod" or
                tag == "Ast.TopLevelStatic") and
               not node._record_constructor
               and not node._union_constructor then
                visit_toplevel(node, st, errors, loader)
            end
        end
    end

    st.generic_signatures_incomplete = false
    generic_validate_pending_generic_constraints(st, errors)

    for _, node in ipairs(ast) do
        if not node._ignore and node._tag == "Ast.TopLevelVar" then
            st.initializer_order = node._toplevel_order
            visit_toplevel(node, st, errors, loader)
            st.initializer_order = nil
        end
    end
end

function checker.has_main(ast)
    for _, node in ipairs(ast) do
        local name = toplevel_name(node)
        if name == "main"
           and node._tag == "Ast.TopLevelFunc"
           and node._type._tag == "Type.Function"
           and not node._type.varargtype
           and #node.params == 1
           and node.params[1]._type._tag == "Type.Array"
           and node.params[1]._type.isconst.tag == "no"
           and node.params[1]._type.elem._tag == "Type.String"
           and #node._type.rettypes == 1
           and not node._type.flexrettype
           and node._type.rettypes[1]._tag == "Type.Integer" then
            return true
        end
    end
    return false
end

return core.checker
