local core = require "titan-compiler.checker.core"
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
--         be `false`/a list; `node._type.rettypes` is authoritative here.
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
        -- `false` is a checked policy decision, not a missing annotation.  A
        -- raw-pointer parameter remains usable by exact Titan native calls,
        -- while invocation through the genuine Lua entry rejects it.
        node._lua_dynamic_plans[index] =
            types.dynamic_coercion(typ) or false
        node._strict_guard_plans[index] =
            types.gradual_guard(typ) or false
    end
    if signature.varargtype then
        node._lua_vararg_dynamic_plan =
            types.dynamic_coercion(signature.varargtype) or false
        node._strict_vararg_guard_plan =
            types.gradual_guard(signature.varargtype) or false
    else
        node._lua_vararg_dynamic_plan = false
        node._strict_vararg_guard_plan = false
    end

    if node._type._tag == "Type.Method" then
        node._bound_strict_guard_plans = {}
        for index, typ in ipairs(signature.params) do
            node._bound_strict_guard_plans[index] =
                types.gradual_guard(typ) or false
        end
        node._bound_strict_vararg_guard_plan =
            signature.varargtype
                and (types.gradual_guard(signature.varargtype) or false)
                or false
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
        module_initializer = opts.module_initializer and st.modname or false,
    }
    table.insert(func_stack, frame)
    if not opts.foreign then
        local ldecl = ast.Decl(node.loc, "L", false, false, false)
        ldecl._type = lua_state_pointer_type(st)
        ldecl._funcdepth = #func_stack
        ldecl._cvar = "L"
        ldecl._readonly = true
        st:add_symbol("L", ldecl)
        local mdecl = ast.Decl(node.loc, "M", false, false, false)
        mdecl._type = module_udata_pointer_type(st)
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
        -- `false` (inferred) or shorter, so fall back to the function location.
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
        flexrettype = false,
        block = node,
        _type = node._type,
    }
    st:open_block()
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
            checker.typeerror(errors, node.loc,
                "C allocation pseudo-functions are not available inside a foreign function")
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
                        check_user_value_slot_type(
                            "record", node.name, "field", field.name,
                            field._type, field.loc, errors)
                    end
                end
            elseif node._tag == "Ast.TopLevelUnion" then
                for _, variant in ipairs(node.variants) do
                    if variant._type and variant._type.payload ~= false then
                        check_user_value_slot_type(
                            "union", node.name, "variant", variant.name,
                            variant._type.payload,
                            variant.payload.loc or variant.loc, errors)
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
        if decl.name ~= "new" or #decl.params ~= #owner.fields then
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
        if not variant or decl.paramnames ~= false then return false end
        if variant.payload == false then
            return #decl.params == 0
        end
        return #decl.params == 1
            and types.equals(decl.params[1], variant.payload)
    end
    return false
end

-- Verify if an expression is constant
function isconst(node)
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
        return node.var and node.var._decl
            and node.var._decl._tag == "Type.CPseudoSize"

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

    elseif tag == "Ast.ExpCast" or tag == "Ast.ExpIs" then
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
function toplevel_name(node)
    if node._module_initializer then return nil end
    local tag = node._tag
    if tag == "Ast.TopLevelImport" then
        return node.localname
    elseif tag == "Ast.TopLevelForeignImport" then
        return node.localname
    elseif tag == "Ast.TopLevelVar" then
        return node.decl.name
    elseif tag == "Ast.TopLevelTypeAlias"
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

-- Typecheck the toplevel node
toplevel_visitor = util.make_visitor({
    ["Ast.TopLevelImport"] = function(node, st, errors, loader)
        local request = node.source_required and {
            kind = "source-import",
        } or nil
        local modtype, errs, import_info =
            checker.checkimport(node.modname, loader, request)
        if modtype then
            node._type = modtype
            -- The syntax explicitly requests the collaboration view, while
            -- trusted loader provenance proves that source was actually
            -- selected. Neither half alone grants private visibility.
            node._source_import = node.source_required and import_info
                and import_info.kind == "source"
                and modtype._source == true
            if node._source_import then
                for _, member in ipairs(modtype.source_members or {}) do
                    if member._foreign_source then
                        node._foreign_header = import_info.foreign_header
                        node._foreign_header_for_check =
                            import_info.foreign_header_for_check == true
                        node._foreign_header_probe_identity =
                            import_info.foreign_header_probe_identity
                        break
                    end
                end
                -- Visibility is direct. C headers are not inherited as a
                -- context: each source-only C type retains its own origin
                -- header, and code generation adds that header only when it
                -- renders a declaration using the type.
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

    ["Ast.TopLevelForeignImport"] = function(node, st, errors)
        local name = node.headername
        local ftypes, err, include
        local strategy
        local process_options
        if foreign_c_config_error then
            err = foreign_c_config_error
        else
            local service
            service, err = ensure_probe_service(st)
            if service then
                local options
                options, err = service:cdriver_process_options()
                if options then
                    process_options = options
                    strategy = options.io
                    options.source_dir = st.source_dir
                    ftypes, err, include =
                        cdriver.process_file(name, options)
                end
            end
        end
        if ftypes then
            local normalized
            normalized, err = cprobe.normalize_include_descriptor(include, {
                source_dir = st.source_dir,
                io = strategy,
            })
            if normalized then
                include = normalized
            else
                ftypes = nil
            end
        end
        if ftypes then
            node._include = include
            st.last_foreign_import_node = node
            st.foreign_includes[#st.foreign_includes + 1] = include
            st.foreign_includes_version = st.foreign_includes_version + 1
            st.module_probe = nil
            st.module_probe_error = nil
            st.module_probe_includes_version = nil
            st.module_probe_error_includes_version = nil
            st:apply_foreign_macro_changes(
                ftypes.macro_changes, ftypes.macro_definitions)
            local members = {}
            local type_members = {}
            local ordinary_declarations = {}
            local ordinary_order = {}
            local conversion_started =
                cdriver.process_phase_clock(process_options)
            for _, item in ipairs(ftypes) do
                local fname = item.name
                local ftype = item.type
                local decl, conversion_error, declaration =
                    foreigntypes.convert(st, ftype, fname, include)
                if decl then
                    types.mark_c_ffi_scope(decl, st.modname)
                    types.mark_c_ffi_include(decl, include)
                    local ordinary
                    if is_foreign_ordinary_identifier(fname, ftype) then
                        ordinary = {
                            header = name,
                            type = decl,
                            declaration = declaration,
                            import_node = node,
                        }
                        if not ordinary_declarations[fname] then
                            ordinary_order[#ordinary_order + 1] = fname
                        end
                        ordinary_declarations[fname] = ordinary
                    end
                    local type_declaration =
                        is_foreign_type_declaration(ftype)
                    if type_declaration then
                        type_members[fname] = decl
                        st:add_foreign_type(fname, decl)
                    else
                        local paramnames = ftype.type == "function"
                            and copy_foreign_paramnames(ftype.paramnames)
                            or false
                        local member = types.ModuleMember(
                            name, fname, decl, paramnames)
                        member._c_origin_header = declaration
                            and declaration.origin_header or include
                        members[fname] = member
                        if ordinary and ftype.type == "function" then
                            ordinary.paramnames_state =
                                ftype.paramnames_state
                                or (ftype.paramnames == false
                                    and "unknown" or "complete")
                            ordinary.paramnames =
                                copy_foreign_paramnames(ftype.paramnames)
                            ordinary.paramname_members = { member }
                        end
                    end
                    if ordinary then
                        ordinary.type_declaration = type_declaration
                    end
                elseif conversion_error
                       and conversion_error:match(
                           "^conflicting C tag kinds") then
                    checker.typeerror(errors, node.loc,
                        "%s", conversion_error)
                end
                -- else: the member uses an unsupported C type; skip it so the
                -- rest of the header still imports. Referencing a skipped
                -- member is then a clean "not a member" error, never a crash.
            end
            cdriver.emit_process_phase(
                process_options, name, include,
                "downstream_ffi_conversion", "complete",
                conversion_started)
            -- The registrar can expose several source forms for one ordinary
            -- name within a single independently parsed header (notably stdio
            -- object declarations plus macro projections). Compare only the
            -- final member that this import publishes, and compare it with the
            -- final member from earlier import occurrences.
            for _, fname in ipairs(ordinary_order) do
                local current = ordinary_declarations[fname]
                local previous = st:find_foreign_name(fname)
                local pending
                if previous then
                    local isolated_compatibility =
                        foreigntypes.declaration_compatibility(
                            previous.type, current.type,
                            previous.declaration, current.declaration)
                    local compatibility = isolated_compatibility
                    if not isolated_compatibility
                       and same_foreign_declaration_source(
                            previous.declaration,
                            current.declaration)
                       and foreigntypes
                            .prototype_tag_reextraction_compatibility(
                                previous.type, current.type,
                                previous.declaration,
                                current.declaration) then
                        compatibility = "source-repeat"
                    end
                    if compatibility then
                        pending = queue_foreign_redeclaration(
                            st, node, fname, previous, current,
                            compatibility)
                    else
                        checker.typeerror(errors, node.loc,
                            "conflicting C declaration for '%s' in foreign import '%s'; "
                            .. "previous declaration from '%s' has type %s, new declaration has type %s",
                            fname, name, previous.header,
                            types.tostring(previous.type),
                            types.tostring(current.type))
                    end
                else
                    st:add_foreign_name(fname, current)
                end
                bind_pending_foreign_slot(
                    pending, members, type_members,
                    current.type_declaration)
            end
            -- Named file-scope struct/union tags are projected into this
            -- import's Titan type namespace under their base spelling only
            -- when no real syntactic typedef reserves that name. The alias is
            -- the canonical CStruct/CUnion itself: no fake C typedef or global
            -- bare foreign name is manufactured.
            for tagname, metadata in pairs(ftypes.file_scope_tags or {}) do
                if (metadata.kind == "struct"
                    or metadata.kind == "union")
                   and not (ftypes.typedef_names
                            and ftypes.typedef_names[tagname]) then
                    local tagtype =
                        st:find_foreign_type(metadata.raw_key)
                    if tagtype then
                        type_members[tagname] = tagtype
                    end
                end
            end

            local modtype = types.CModule(name, members, type_members)
            node._type = modtype
        else
            node._type = types.Nil()
            checker.typeerror(errors, node.loc, err)
        end
        st:add_symbol(node.localname, node)
    end,

    ["Ast.TopLevelVar"] = function(node, st, errors)
        node._module_name = st.modname
        if node.value == false then
            assert(node.isconst,
                "only const module variables may omit an initializer")
            node._initializerless_const = true
            local value = ast.ExpNil(node.decl.loc)
            if not node.decl.type then
                checker.typeerror(errors, node.decl.loc,
                    "const module variable '%s' without an initializer requires an explicit type",
                    node.decl.name)
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
                        "const module variable '%s' cannot be initialized with nil because type '%s' does not accept nil",
                        node.decl.name, types.tostring(node._type))
                    value._type = types.Invalid()
                else
                    checkexp(value, st, errors, node._type)
                    value = coerce_and_check(
                        value, node._type,
                        "nil initialization of const module variable " ..
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
        -- The public module `__newindex` path is a genuine Lua boundary.  Keep
        -- an explicit unavailable marker for non-reifiable targets so its
        -- generated setter rejects every attempted Lua write.
        node._lua_write_dynamic_plan =
            types.dynamic_coercion(node._type) or false
        if not isconst(node.value) then
            checker.typeerror(errors, node.value.loc,
                "top level variable initialization must be constant")
        end
    end,

    ["Ast.TopLevelTypeAlias"] = function(node, st, errors)
        resolve_type_alias(node, st, errors)
    end,

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
                        types.dynamic_coercion(ftype) or false
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
                                if param.name == false then
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
            if node._generic_scope ~= false then
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
        local varargtype = false
        for _, param in ipairs(node.params) do
            if param.name == false then
                varargtype = param.type
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
            if param.name ~= false then
                param._type = node._type.params[index]
            end
        end
    end,

    ["Ast.StatBlock"] = function(node)
        node._type = types.Function({}, {}, false, false, false)
    end,

    ["Ast.StatTry"] = function(node)
        assert(node._module_initializer)
        node._type = types.Function({}, {}, false, false, false)
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
                    local ftype = typefromnode(field.type, st, errors)
                    field._type = ftype
                    local tfield = types.Field(
                        fqtn, field.name, ftype, i - 1,
                        field.isconst and true or false)
                    tfield.islocal = field.islocal and true or false
                    tfield.dynamic_plan =
                        types.dynamic_coercion(ftype) or false
                    field._dynamic_plan = tfield.dynamic_plan
                    field._field = tfield
                    field._decl = tfield
                    fields[#fields + 1] = tfield
                end
            end
            node._type = types.Record(fqtn, fields, {}, {}, #fields,
                node._generic_scope, node._generic_typeparams)
            node._type._generic_parameters = node._generic_parameters
            node._type.islocal = node.islocal and true or false
            node._type._source_complete = true
            node._dynamic_receiver_plan = assert(types.dynamic_coercion(
                types.Nominal(fqtn, generic_parameter_arguments(node._type))),
                "record nominal lacks its dynamic receiver plan")
            types.registry[fqtn] = node._type
        end)
    end,

    ["Ast.TopLevelUnion"] = function(node, st, errors)
        return generic_with_owner_bindings(node, st, function()
            local variants = {}
            local nameset = {}
            local fqtn = st.modname .. "." .. node.name
            if #node.variants == 0 then
                checker.typeerror(errors, node.loc,
                    "union '%s' must declare at least one variant", node.name)
            end
            for index, variant in ipairs(node.variants) do
                if nameset[variant.name] then
                    checker.typeerror(errors, variant.loc,
                        "redeclaration of variant '%s' in union '%s'",
                        variant.name, node.name)
                    variant._ignore = true
                else
                    nameset[variant.name] = variant
                    local payload = variant.payload
                        and typefromnode(variant.payload, st, errors)
                        or false
                    local tvariant = types.Variant(
                        fqtn, variant.name, payload, index - 1)
                    tvariant.islocal =
                        (node.islocal or variant.islocal) and true or false
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
                local rettypes = {}
                for _, rt in ipairs(node.rettypes) do
                    rettypes[#rettypes + 1] =
                        typefromnode(rt, st, errors)
                end
                local flexrettype = flexible_return_type(node, st, errors)
                local published_paramnames = paramnames
                if node._union_constructor then
                    published_paramnames = false
                end
                node._type = types.StaticMethod(
                    ownertype.name, node.name, ptypes, rettypes,
                    varargtype, flexrettype, published_paramnames,
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
    local nominals = {}
    for _, node in ipairs(ast) do
        if not node._ignore
           and (node._tag == "Ast.TopLevelRecord"
                or node._tag == "Ast.TopLevelUnion")
           and not nominals[node.name] then
            nominals[node.name] = node
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
                node._generic_scope = false
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

function collect_nominal_constructors(ast)
    local constructors = {}
    for index, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelRecord" then
            local constructor = ast[index + 1]
            if constructor and constructor._tag == "Ast.TopLevelStatic"
               and constructor._record_constructor then
                assert(constructor.class == node.name and
                       constructor.name == "new")
                if node._ignore then constructor._ignore = true end
                constructors[#constructors + 1] = constructor
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
    return constructors
end

function apply_source_foreign_headers(ast, st, errors)
    local seen = {}
    for _, node in ipairs(ast) do
        local filename = node._tag == "Ast.TopLevelImport"
            and node._source_import and node._foreign_header_for_check
            and node._foreign_header or nil
        if filename and not seen[filename] then
            seen[filename] = true
            local service, err = ensure_probe_service(st)
            local ftypes, include
            local strategy
            if service then
                local options
                options, err = service:cdriver_process_options()
                if options then
                    strategy = options.io
                    options.source_dir = st.source_dir
                    ftypes, err, include =
                        cdriver.process_file(filename, options)
                end
            end
            if ftypes then
                local normalized
                normalized, err = cprobe.normalize_include_descriptor(include, {
                    source_dir = st.source_dir,
                    io = strategy,
                })
                if normalized and node._foreign_header_probe_identity then
                    normalized, err = cprobe.source_foreign_include_alias(
                        normalized, node.modname,
                        node._foreign_header_probe_identity)
                end
                if normalized then include = normalized else ftypes = nil end
            end
            if not ftypes then
                checker.typeerror(errors, node.loc,
                    "could not process source foreign header for module '%s': %s",
                    node.modname, tostring(err))
            else
                st.foreign_includes[#st.foreign_includes + 1] = include
                st.foreign_includes_version =
                    st.foreign_includes_version + 1
                st.module_probe = nil
                st.module_probe_error = nil
                st.module_probe_includes_version = nil
                st.module_probe_error_includes_version = nil
                st:apply_foreign_macro_changes(
                    ftypes.macro_changes, ftypes.macro_definitions)
            end
        end
    end
end

function visit_toplevel(node, st, errors, loader)
    st.current_toplevel_order = node._toplevel_order
    toplevel_visitor(node, st, errors, loader)
    st.current_toplevel_order = nil
end

-- Collect top-level declarations in dependency order while retaining the AST's
-- logical source order for interfaces and code generation. Imports establish
-- the type environment; records and their constructors come next; other
-- callable signatures follow; module variables are checked last, one by one.
-- During that last pass the symbol table hides later imports and the current or
-- later module variables, preserving the only sequential declaration boundary.
function checktoplevel(ast, st, errors, loader)
    reserve_toplevel_names(ast, st)
    local constructors = collect_nominal_constructors(ast)

    for _, node in ipairs(ast) do
        if not node._ignore and
           (node._tag == "Ast.TopLevelImport" or
            node._tag == "Ast.TopLevelForeignImport") then
            visit_toplevel(node, st, errors, loader)
        end
    end
    -- Generated C places direct-source foreign headers after this module's
    -- direct C imports. Replay those headers in the same order before checking
    -- aliases, declarations, initializers, or bodies so macro projections and
    -- contextual probes see exactly the environment the C compiler will see.
    apply_source_foreign_headers(ast, st, errors)
    finalize_foreign_redeclarations(st, errors)
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
