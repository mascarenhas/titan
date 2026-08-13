local checker = {}

local location = require "titan-compiler.location"
local symtab = require "titan-compiler.symtab"
local types = require "titan-compiler.types"
local ast = require "titan-compiler.ast"
local util = require "titan-compiler.util"
local foreigntypes = require "titan-compiler.foreigntypes"
local cdriver = require("c-parser.cdriver")
local cdefines = require("c-parser.cdefines")
local cprobe = require "titan-compiler.cprobe"
local csemantics = require "titan-compiler.csemantics"
local cdeclarator = require "titan-compiler.cdeclarator"

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

local function new_direct_probe_service()
    local toolchain = foreign_c_options.toolchain
    if not toolchain then
        local compile_flags = foreign_c_options.compile_flags or {}
        toolchain = {
            compiler = foreign_c_options.compiler or
                os.getenv("CC") or "cc",
            compile_flags = compile_flags,
            language_mode = foreign_c_options.language_mode or "c99",
            language_flag = foreign_c_options.language_flag,
            cppflags = foreign_c_options.cppflags or {},
            cflags = {},
            include_dirs =
                foreign_c_options.compiler_include_dirs,
        }
        if foreign_c_options.language_flag == nil
           and #compile_flags > 0 then
            toolchain.language_flag = false
        end
    end
    if not toolchain.profile then
        local configured = {}
        for key, value in pairs(toolchain) do configured[key] = value end

        -- Checker-only embeddings do not load the compiler driver and
        -- therefore have no process-global target profile to borrow. Acquire
        -- it from the exact compiler/flags/include context that will perform
        -- the probes, just as the public driver does.
        local inputs, input_error =
            cdriver.target_profile_inputs({
                compiler = toolchain.compiler_argv
                    or toolchain.compiler,
                compile_flags = toolchain.compile_flags,
                language_mode = toolchain.language_mode,
                language_flag = toolchain.language_flag,
                cppflags = toolchain.cppflags,
                compiler_include_dirs = toolchain.include_dirs,
            })
        if not inputs then return nil, input_error end
        local profile, profile_error =
            csemantics.build_profile(inputs)
        if not profile then return nil, profile_error end
        configured.profile = profile
        configured.profile_identity = profile.identity
        toolchain = configured
    end
    return cprobe.new_service({
        toolchain = toolchain,
        runner = foreign_c_options.probe_runner or
            cdriver.capture_command,
        verbose = foreign_c_options.verbose == true,
    })
end

local function ensure_probe_service(st)
    if st.probe_service then return st.probe_service end
    if st.probe_service_error then
        return nil, st.probe_service_error
    end
    local service, err
    if st.probe_service_provider then
        service, err = st.probe_service_provider()
    else
        service, err = new_direct_probe_service()
        if service then st.owns_probe_service = true end
    end
    if not service then
        st.probe_service_error = err or
            "could not create the C probe service"
        return nil, st.probe_service_error
    elseif type(service.profile) ~= "table" then
        st.probe_service_error =
            "the C probe service has no authoritative target profile"
        if st.owns_probe_service and type(service.close) == "function" then
            pcall(service.close, service)
        end
        st.owns_probe_service = false
        return nil, st.probe_service_error
    end
    st.probe_service = service
    -- C conversion completes canonical tag graphs in place. Give each checker
    -- its own target-profile leaves so source provenance never mutates the
    -- service profile shared by nested or later module checks.
    st.c_profile = types.clone_graph(service.profile)
    return service
end

local function ensure_module_probe(st)
    local includes_version = st.foreign_includes_version or 0
    if st.module_probe
       and st.module_probe_includes_version == includes_version then
        return st.module_probe
    end
    if st.module_probe_error
       and st.module_probe_error_includes_version == includes_version then
        return nil, st.module_probe_error
    end
    -- A probe context owns an immutable ordered include preamble. Never let a
    -- context built for an earlier import prefix survive another include.
    st.module_probe = nil
    st.module_probe_error = nil
    st.module_probe_includes_version = nil
    st.module_probe_error_includes_version = nil

    local service, err = ensure_probe_service(st)
    if not service then
        st.module_probe_error = err
        st.module_probe_error_includes_version = includes_version
        return nil, st.module_probe_error
    end

    local module_probe
    module_probe, err = service:module_context({
        source_dir = st.source_dir or ".",
        includes = st.foreign_includes or {},
    })
    if not module_probe then
        st.module_probe_error = err or
            "could not create the module C probe context"
        st.module_probe_error_includes_version = includes_version
        return nil, st.module_probe_error
    end
    st.module_probe = module_probe
    st.module_probe_includes_version = includes_version
    return module_probe
end

checker._enum_carrier_names = {
    "char", "signed char", "unsigned char",
    "short", "unsigned short",
    "int", "unsigned int",
    "long", "unsigned long",
    "long long", "unsigned long long",
}

-- Build a use-specific probe preamble from this module's written foreign
-- imports plus only the origin headers needed to spell the probed C types.
-- Source-import authority is not propagated here: the types themselves carry
-- the normalized header origins established by their trusted producer.
function checker._probe_for_c_types(st, probed_types)
    local direct_keys = {}
    for _, include in ipairs(st.foreign_includes or {}) do
        direct_keys[assert(include.rendered,
            "direct C include has no normalized spelling")] = true
    end

    local supplemental = {}
    for _, typ in ipairs(probed_types or {}) do
        for _, include in ipairs(types.c_ffi_includes(typ)) do
            local key = assert(include.rendered,
                "C origin include has no normalized spelling")
            if not direct_keys[key] then supplemental[key] = include end
        end
    end
    local keys = {}
    for key in pairs(supplemental) do keys[#keys + 1] = key end
    if #keys == 0 then return ensure_module_probe(st) end
    table.sort(keys)

    local includes_version = st.foreign_includes_version or 0
    local cache_key = tostring(includes_version) .. "\0" ..
        table.concat(keys, "\0")
    st.c_type_probes = st.c_type_probes or {}
    if st.c_type_probes[cache_key] then
        return st.c_type_probes[cache_key]
    end

    local service, err = ensure_probe_service(st)
    if not service then return nil, err end
    local includes = {}
    for _, include in ipairs(st.foreign_includes or {}) do
        includes[#includes + 1] = include
    end
    for _, key in ipairs(keys) do
        includes[#includes + 1] = supplemental[key]
    end
    local probe
    probe, err = service:module_context({
        source_dir = st.source_dir or ".",
        includes = includes,
    })
    if not probe then return nil, err end
    st.c_type_probes[cache_key] = probe
    return probe
end

function checker._ensure_c_enum_supported(
        st, typ, loc, errors, seen, spelling_only)
    if type(typ) ~= "table" then return true end
    seen = seen or { full = {}, spelling = {} }
    local visited = spelling_only and seen.spelling or seen.full
    if visited[typ] then return true end
    visited[typ] = true

    local tag = typ._tag
    -- A retained typedef is itself a complete declarator spelling. Looking
    -- through it while checking only spellability would incorrectly expose an
    -- inner tag to a later macro and defeats the typedef's C semantics.
    if spelling_only and tag == "Type.CTypedef" then return true end

    local resolved = types.resolve_c_typedef(typ)
    if resolved and resolved._tag == "Type.CInteger"
       and resolved._c_enum_identity then
        -- A typedef can provide a stable spelling for an otherwise anonymous
        -- enum. Without that outer spelling, a prototype/anonymous enum cannot
        -- be reconstructed in a generated standalone declarator.
        if resolved._c_enum_unspellable and tag ~= "Type.CTypedef" then
            checker.typeerror(errors, loc,
                "C enum type '%s' has no usable declaration spelling",
                types.tostring(typ))
            return false
        end
        if spelling_only then return true end

        local probe, probe_error = checker._probe_for_c_types(st, { typ })
        if not probe then
            checker.typeerror(errors, loc,
                "cannot validate C enum type '%s' with the configured "
                .. "compiler: %s", types.tostring(typ), probe_error)
            return false
        end

        local profile = assert(st.c_profile,
            "C enum validation requires the configured target profile")
        local lua_entry = assert(profile.integers[profile.lua_integer],
            "target profile lacks lua_Integer")
        -- Probe the exact surface selected by this use. In particular, retain
        -- an outer typedef rather than resolving it back to a macro-sensitive
        -- tag. Direct anonymous objects use an unqualified value-expression
        -- spelling solely for this compatibility query.
        local declaration_type = typ
        if typ == resolved and resolved._c_enum_probe_spelling then
            declaration_type = {}
            for key, value in pairs(resolved) do
                declaration_type[key] = value
            end
            declaration_type._c_declaration_spelling =
                resolved._c_enum_probe_spelling
        end

        local candidates, entries = {}, {}
        for _, name in ipairs(checker._enum_carrier_names) do
            local entry = profile.integers[name]
            if entry then
                local fits, range_error = csemantics.integer_range_contains(
                    lua_entry.type._c_numeric, entry.type._c_numeric)
                assert(fits ~= nil, range_error)
                if fits or resolved._c_enum_enumerator then
                    candidates[#candidates + 1] = {
                        left_type = declaration_type,
                        right_type = entry.type,
                    }
                    entries[#entries + 1] = entry
                end
            end
        end

        local results = probe:validate_declaration_compatibilities(candidates)
        local selected
        for index, result in ipairs(results) do
            if result.accepted then
                if selected then
                    checker.typeerror(errors, loc,
                        "configured C compiler reported multiple carriers "
                        .. "for enum type '%s'", types.tostring(typ))
                    return false
                end
                selected = entries[index]
            elseif result.status == "infrastructure_failure" then
                checker.typeerror(errors, loc,
                    "cannot validate C enum type '%s' with the configured "
                    .. "compiler: %s", types.tostring(typ),
                    result.message or result.summary or result.status)
                return false
            end
        end
        if not selected then
            if resolved._c_enum_enumerator then
                checker.typeerror(errors, loc,
                    "C enumerator '%s' has no ordinary compiler-selected "
                    .. "integer carrier", resolved._c_enum_enumerator)
            else
                checker.typeerror(errors, loc,
                    "C enum type '%s' has no compiler-selected carrier whose "
                    .. "full range fits in lua_Integer", types.tostring(typ))
            end
            return false
        end

        if resolved._c_enum_enumerator then
            local carrier_fits, range_error =
                csemantics.integer_range_contains(
                    lua_entry.type._c_numeric,
                    selected.type._c_numeric)
            assert(carrier_fits ~= nil, range_error)
            if not carrier_fits then
                local name = resolved._c_enum_enumerator
                local lua_numeric = lua_entry.type._c_numeric
                local maximum = assert(lua_numeric.maximum)
                local fit_expression
                if selected.type.signed then
                    local lua_spelling = lua_entry.type.spelling
                    fit_expression = string.format(
                        "(((%s) >= (-((%s)%sULL) - 1)) " ..
                            "&& ((%s) <= ((%s)%sULL)))",
                        name, lua_spelling, maximum,
                        name, lua_spelling, maximum)
                else
                    fit_expression = string.format(
                        "((unsigned long long)(%s) <= %sULL)",
                        name, maximum)
                end
                local fit_type = types.CArray(
                    lua_entry.type,
                    "(" .. fit_expression .. ") ? 1 : -1")
                local fit_result =
                    probe:validate_declaration_compatibilities({ {
                        left_type = fit_type,
                        right_type = fit_type,
                    } })[1]
                if fit_result.status == "infrastructure_failure" then
                    checker.typeerror(errors, loc,
                        "cannot validate C enumerator '%s' with the " ..
                        "configured compiler: %s", name,
                        fit_result.message or fit_result.summary
                            or fit_result.status)
                    return false
                elseif not fit_result.accepted then
                    checker.typeerror(errors, loc,
                        "C enumerator '%s' is outside the range of " ..
                        "lua_Integer", name)
                    return false
                end
            end
        end

        -- Preserve the selected expression/object carrier through later C
        -- operators. Titan-boundary coercions perform their own range check;
        -- normalizing here would change unsigned promotions and wraparound.
        local carrier = selected.type
        resolved.spelling = carrier.spelling
        resolved.signed = carrier.signed
        resolved.rank = carrier.rank
        resolved.bits = carrier.bits
        resolved._c_numeric = carrier._c_numeric
        resolved._c_numeric_carriers = carrier._c_numeric_carriers
        return true
    end

    local children = {}
    local child_spelling_only = spelling_only
    if tag == "Type.CStruct" or tag == "Type.CUnion"
       or tag == "Type.COwned" or tag == "Type.Pointer" then
        return true
    elseif tag == "Type.CPointer" then
        children[1] = typ.pointee
        child_spelling_only = true
    elseif tag == "Type.CArray" then
        children[1] = typ.elem
        child_spelling_only = true
    elseif tag == "Type.CTypedef" then
        children[1] = typ.target
    elseif tag == "Type.CFunction" then
        for _, param in ipairs(typ.params or {}) do
            children[#children + 1] = param
        end
        children[#children + 1] = typ.ret
    elseif tag == "Type.Function" then
        for _, param in ipairs(typ.params or {}) do
            children[#children + 1] = param
        end
        for _, ret in ipairs(typ.rettypes or {}) do
            children[#children + 1] = ret
        end
        children[#children + 1] = typ.varargtype
        children[#children + 1] = typ.flexrettype
    elseif tag == "Type.Array" then
        children[1] = typ.elem
    elseif tag == "Type.Map" then
        children[1] = typ.keys
        children[2] = typ.values
    elseif tag == "Type.Option" then
        children[1] = typ.base
    end
    local ok = true
    for _, child in ipairs(children) do
        if not checker._ensure_c_enum_supported(
                st, child, loc, errors, seen, child_spelling_only) then
            ok = false
        end
    end
    return ok
end


-- The typechecker first collects top-level declarations in dependency order,
-- while preserving the AST's source order for initialization and codegen, and
-- then checks callable bodies. All typechecked nodes that have a type get a
-- "_type" field with the type. The types themselves are in "types.lua".
local typefromnode

local checkdecl
local checkstat
local checkexp
local checkvar
local checkfuncbody
checker._generic = {}
local annotate_call_results
local check_generic_result_limit

-- nesting depth of enclosing loops, so `break` can be rejected outside a loop
local loop_depth = 0

-- One frame per enclosing loop. Besides making the target of `break`
-- explicit, the frame records whether a reachable break can leave that loop.
-- The statement-list checker stops visiting a dead tail after a proven
-- terminator, so every legal break that reaches this bookkeeping is reachable
-- under the checker's conservative branch analysis.
local loop_frames = {}

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
local active_check_state
checker._foreign_function_depth = 0

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
        for _, method in ipairs(typ.methods or {}) do
            checktype(method, loc, errors, seen)
        end
    end
end

-- Resolve a Titan alias to the RHS type object itself. The state lives on the
-- declaration so every use shares one pointer and a forward alias chain is
-- resolved only once. Encountering a declaration already being resolved marks
-- the cycle invalid before unwinding, preventing both recursion and cascades.
local resolve_type_alias

-- An exact bare owner on an alias RHS is an owner-scheme context, not the
-- ordinary scalar all-value application. Resolve only that constructor shape
-- here; every other RHS still follows the normal type visitor.
function checker._generic.bare_forwarding_alias_target(node, st, errors)
    if node._tag == "Ast.TypeName" then
        local alias = st:find_type_alias(node.name)
        if alias then
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
        local owner = checker._generic.resolve_local_owner(node.name, st)
        return owner, false, owner ~= nil
    elseif node._tag == "Ast.TypeQualName" then
        local declaration = st:find_symbol(node.module)
        local module = declaration and declaration._type
        if not module or module._tag ~= "Type.Module" then
            return nil, false, false
        end
        local include_source = declaration._source_import == true
        local member = types.module_type_member(
            module, node.name, include_source)
        if member and member._tag == "Type.GenericAlias" then
            local owner = types.registry[member.target_owner_fqtn]
            local target_alias_fqtn = false
            if not member.locality then
                target_alias_fqtn = member.module .. "." .. member.name
            end
            return owner, target_alias_fqtn, true
        elseif member and member._tag == "Type.Interface" then
            return member, false, true
        end
        local nominal = types.module_member(
            module, node.name, include_source)
        local owner = nominal and nominal.type
        if owner and (owner._tag == "Type.Record"
                or owner._tag == "Type.Union") then
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
            checker._generic.bare_forwarding_alias_target(
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
local function checkmatch(term, expected, exp, errors, loc, adjustment,
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

local function check_exact_match(term, expected, exp, errors, loc)
    if not types.equals(exp._type, expected) then
        checker.typeerror(errors, loc,
            "types in %s do not match, expected %s but found %s",
            term, types.tostring(expected), types.tostring(exp._type))
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

-- The native input-vararg and flexible-result ABIs share the TitanVargX
-- descriptor inventory. Generic reconstruction and metadata validation use the
-- same type-layer query, so an application cannot manufacture a tail shape that
-- the written declaration would reject.
local function has_varg_representation(t)
    return types.valid_varg_element(t)
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

local function flexible_return_type(
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

-- Foreign imports are extracted independently, so two import closures can
-- contain the same physical declaration even though the generated ordered
-- includes emit it only once through an include guard or `#pragma once`.
-- Source identity is useful only for recognizing that repeated extraction;
-- the declaration graphs must additionally differ only by explicitly marked
-- prototype-local tag objects. The final ordered-header compiler baseline
-- still decides whether the declaration is actually emitted compatibly in the
-- translation unit.
local function same_foreign_declaration_source(left, right)
    local lsource = left and left.provenance
    local rsource = right and right.provenance
    local left_has_identity = lsource ~= nil
       and lsource.device ~= nil
       and lsource.inode ~= nil
    local right_has_identity = rsource ~= nil
       and rsource.device ~= nil
       and rsource.inode ~= nil
    local same_file = left_has_identity and right_has_identity
       and lsource.device == rsource.device
       and lsource.inode == rsource.inode
       or (not left_has_identity or not right_has_identity)
          and lsource ~= nil
          and rsource ~= nil
          and lsource.file ~= nil
          and lsource.file == rsource.file
    return lsource ~= nil
       and rsource ~= nil
       and lsource.line ~= nil
       and lsource.column ~= nil
       and same_file
       and lsource.line == rsource.line
       and lsource.column == rsource.column
end

local function queue_foreign_redeclaration(
        st, node, name, previous, current, compatibility)
    local queue = st.pending_foreign_redeclarations
    queue[#queue + 1] = {
        node = node,
        name = name,
        header = node.headername,
        previous = previous,
        current = current.type,
        current_entry = current,
        declaration = current.declaration,
        compatibility = compatibility,
    }
    return queue[#queue]
end

local function bind_pending_foreign_slot(
        pending, members, type_members, is_type)
    if not pending then return end
    if is_type then
        pending.type_members = type_members
    else
        pending.member = members[pending.name]
    end
end

local function copy_foreign_paramnames(names)
    if names == false then return false end
    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = name
    end
    return out
end

local function same_foreign_paramnames(left, right)
    if #left ~= #right then return false end
    for i = 1, #left do
        if left[i] ~= right[i] then return false end
    end
    return true
end

-- Parameter spellings are declaration metadata rather than C type identity.
-- Merge them only after the declaration pair probe accepts the redeclaration,
-- then rewrite every accepted import occurrence to the same consensus.
local function merge_foreign_paramnames(previous, current)
    local previous_state = previous.paramnames_state
    local current_state = current.paramnames_state
    if not previous_state or not current_state then return end

    local state
    local names = false
    if previous_state == "conflicting"
       or current_state == "conflicting" then
        state = "conflicting"
    elseif previous_state == "complete"
       and current_state == "complete" then
        if same_foreign_paramnames(
                previous.paramnames, current.paramnames) then
            state = "complete"
            names = previous.paramnames
        else
            state = "conflicting"
        end
    elseif previous_state == "complete" then
        state = "complete"
        names = previous.paramnames
    elseif current_state == "complete" then
        state = "complete"
        names = current.paramnames
    else
        state = "unknown"
    end

    local members = {}
    local seen = {}
    for _, entry in ipairs({ previous, current }) do
        for _, member in ipairs(entry.paramname_members or {}) do
            if not seen[member] then
                seen[member] = true
                members[#members + 1] = member
            end
        end
    end

    previous.paramnames_state = state
    previous.paramnames = copy_foreign_paramnames(names)
    previous.paramname_members = members
    current.paramnames_state = state
    current.paramnames = copy_foreign_paramnames(names)
    current.paramname_members = members
    for _, member in ipairs(members) do
        member.paramnames = copy_foreign_paramnames(names)
    end
end

local function rewrite_foreign_type_history(
        st, name, current, canonical)
    if st.foreign_types[name] == current then
        st.foreign_types[name] = canonical
    end
    for _, entry in ipairs(st.foreign_type_history[name] or {}) do
        if entry.decl == current then entry.decl = canonical end
    end
end

local function canonicalize_foreign_redeclaration(st, pending)
    local previous = pending.previous
    local current = pending.current
    local canonical = foreigntypes.merge_declaration_composite(
        previous.type, current)

    -- A separately parsed occurrence of one accepted typedef can be retained
    -- by declarations unique to that header snapshot. Point its private alias
    -- object at the canonical target before replacing public slots, so those
    -- transitive references also follow the accepted canonical declaration.
    if current._tag == "Type.CTypedef"
       and previous.type._tag == "Type.CTypedef" then
        current.target = previous.type.target
    end

    if pending.type_members then
        pending.type_members[pending.name] = canonical
        rewrite_foreign_type_history(
            st, pending.name, current, canonical)
    elseif pending.member then
        pending.member.type = canonical
    end
    merge_foreign_paramnames(previous, pending.current_entry)
    st.foreign_names[pending.name] = previous
end

local function report_foreign_redeclaration_failure(
        pending, errors, result)
    local summary = result and (result.message or result.summary
        or result.diagnostic) or
        "the final ordered C header validation returned no result"
    if result and result.status == "rejected" then
        checker.typeerror(errors, pending.node.loc,
            "conflicting C declaration for '%s' in foreign import '%s'; "
            .. "previous declaration from '%s' has type %s, "
            .. "new declaration has type %s; %s",
            pending.name, pending.header, pending.previous.header,
            types.tostring(pending.previous.type),
            types.tostring(pending.current), summary)
    else
        checker.typeerror(errors, pending.node.loc,
            "cannot validate potentially compatible C declaration for "
            .. "'%s' in foreign import '%s' against the previous "
            .. "declaration from '%s': %s",
            pending.name, pending.header, pending.previous.header, summary)
    end
end

local function report_foreign_header_context_failure(st, errors, result)
    local node = st.last_foreign_import_node
    local loc = node and node.loc
    local summary = result and (result.message or result.summary
        or result.diagnostic) or
        "the final ordered C header validation returned no result"
    if result and result.status == "rejected" then
        checker.typeerror(errors, loc,
            "final ordered C header context is invalid: %s", summary)
    else
        checker.typeerror(errors, loc,
            "cannot validate the final ordered C header context: %s",
            summary)
    end
end

local function restore_rejected_foreign_type_registries(st, pending)
    local rejected, names = {}, {}
    for _, declaration in ipairs(pending) do
        if declaration.type_members then
            rejected[declaration.current] = true
            names[declaration.name] = declaration.previous.type
        end
    end
    for name, canonical in pairs(names) do
        local history = st.foreign_type_history[name] or {}
        local retained = {}
        for _, entry in ipairs(history) do
            if not rejected[entry.decl] then
                retained[#retained + 1] = entry
            end
        end
        st.foreign_type_history[name] = retained
        st.foreign_types[name] =
            retained[#retained] and retained[#retained].decl or canonical
    end
end

-- A successful redeclaration can complete an unknown array bound or upgrade
-- an old-style function inside the first declaration-owned type graph. Later
-- probes must see those mutations exactly as the former sequential loop did.
-- Track every type node whose spelling a later probe may read, and every node
-- an earlier composite merge may write, so independently named declarations
-- can still share one safe probe wave without assuming their graphs are
-- disjoint.
local foreign_redeclaration_batch = {}

function foreign_redeclaration_batch.collect_reads(typ, reads, seen)
    if type(typ) ~= "table" or seen[typ] then return end
    seen[typ] = true
    reads[typ] = true

    local tag = typ._tag
    if tag == "Type.CTypedef" then
        -- Ordinary aliases retain their typedef spelling. A declaration-owned
        -- array view is deliberately expanded by cprobe so a completed bound
        -- is visible to the next wave; follow only that private target.
        if typ._declaration_array_view then
            foreign_redeclaration_batch.collect_reads(
                typ.target, reads, seen)
        end
        return
    elseif tag == "Type.CPointer" then
        foreign_redeclaration_batch.collect_reads(typ.pointee, reads, seen)
    elseif tag == "Type.CArray" then
        foreign_redeclaration_batch.collect_reads(typ.elem, reads, seen)
    elseif tag == "Type.CFunction" then
        for _, param in ipairs(typ.params or {}) do
            foreign_redeclaration_batch.collect_reads(param, reads, seen)
        end
        foreign_redeclaration_batch.collect_reads(typ.ret, reads, seen)
    elseif tag == "Type.Pointer" then
        foreign_redeclaration_batch.collect_reads(typ.type, reads, seen)
    end
end

function foreign_redeclaration_batch.collect_writes(typ, writes, seen)
    if type(typ) ~= "table" or seen[typ] then return end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.CTypedef" then
        if typ._declaration_array_view then
            foreign_redeclaration_batch.collect_writes(
                typ.target, writes, seen)
        end
    elseif tag == "Type.CPointer" then
        foreign_redeclaration_batch.collect_writes(
            typ.pointee, writes, seen)
    elseif tag == "Type.CArray" then
        writes[typ] = true
        foreign_redeclaration_batch.collect_writes(typ.elem, writes, seen)
    elseif tag == "Type.CFunction" then
        writes[typ] = true
        for _, param in ipairs(typ.params or {}) do
            foreign_redeclaration_batch.collect_writes(
                param, writes, seen)
        end
        foreign_redeclaration_batch.collect_writes(typ.ret, writes, seen)
    end
end

function foreign_redeclaration_batch.reads_prior_write(
        declaration, prior_writes)
    local reads = {}
    foreign_redeclaration_batch.collect_reads(
        declaration.previous.type, reads, {})
    foreign_redeclaration_batch.collect_reads(
        declaration.current, reads, {})
    for node in pairs(reads) do
        if prior_writes[node] then return true end
    end
    return false
end

function foreign_redeclaration_batch.add_writes(declaration, writes)
    foreign_redeclaration_batch.collect_writes(
        declaration.previous.type, writes, {})
    -- Canonicalizing two typedef declarations redirects the later private
    -- alias object to the accepted first target. A distinct ordinary name in
    -- that header can retain this exact alias root, so keep it behind the
    -- typedef's wave even though its eventual C spelling remains the alias.
    if declaration.current._tag == "Type.CTypedef"
       and declaration.previous.type._tag == "Type.CTypedef" then
        writes[declaration.current] = true
    end
end

function foreign_redeclaration_batch.validate_candidates(
        module_probe, candidates)
    local compatibilities = {}
    if #candidates == 0 then return compatibilities end

    if type(module_probe.validate_declaration_compatibilities)
        == "function" then
        local ok, validated = pcall(
            module_probe.validate_declaration_compatibilities,
            module_probe, candidates)
        if ok and type(validated) == "table" then
            for index = 1, #candidates do
                compatibilities[index] =
                    type(validated[index]) == "table"
                    and validated[index] or {
                        status = "infrastructure_failure",
                        message =
                            "the C declaration compatibility batch "
                            .. "returned no result for a candidate",
                    }
            end
        else
            local message = ok
                and "the C declaration compatibility batch returned "
                    .. "no result"
                or "C declaration compatibility batch validation "
                    .. "failed: " .. tostring(validated)
            for index = 1, #candidates do
                compatibilities[index] = {
                    status = "infrastructure_failure",
                    message = message,
                }
            end
        end
        return compatibilities
    end

    -- Keep compatibility with injected probe implementations that predate
    -- batching. Production cprobe exposes the plural method.
    for index, candidate in ipairs(candidates) do
        if type(module_probe.validate_declaration_compatibility)
            ~= "function" then
            compatibilities[index] = {
                status = "infrastructure_failure",
                message =
                    "the C probe service cannot validate a declaration pair",
            }
        else
            local ok, validated = pcall(
                module_probe.validate_declaration_compatibility,
                module_probe,
                candidate.left_type, candidate.right_type,
                candidate.left_declaration,
                candidate.right_declaration)
            if ok and type(validated) == "table" then
                compatibilities[index] = validated
            else
                compatibilities[index] = {
                    status = "infrastructure_failure",
                    message = ok
                        and "the C declaration compatibility probe "
                            .. "returned no result"
                        or "C declaration compatibility validation "
                            .. "failed: " .. tostring(validated),
                }
            end
        end
    end
    return compatibilities
end

local function finalize_foreign_redeclarations(st, errors)
    local pending = st.pending_foreign_redeclarations
    -- Independent parsing supplies each import's member graph, but only the C
    -- compiler can validate the macro/tag/declaration state produced by their
    -- exact cumulative order. Validate every nonempty preamble: the
    -- best-effort isolated parser may collapse an invalid repeated declaration
    -- within one header before it reaches the converted declaration registry.
    -- The one final compiler baseline is therefore the authoritative
    -- translation-unit check for both one-header and multi-header modules.
    if #st.foreign_includes == 0 then return end

    local module_probe, probe_error = ensure_module_probe(st)
    local result
    if not module_probe then
        result = {
            status = "infrastructure_failure",
            message = probe_error or
                "could not create the final ordered C header context",
        }
    elseif type(module_probe.validate_baseline) ~= "function" then
        result = {
            status = "infrastructure_failure",
            message =
                "the C probe service cannot validate an ordered header baseline",
        }
    else
        local ok, validated = pcall(
            module_probe.validate_baseline, module_probe)
        if ok and type(validated) == "table" then
            result = validated
        else
            result = {
                status = "infrastructure_failure",
                message = ok
                    and "the ordered header baseline returned no result"
                    or "ordered header baseline validation failed: "
                        .. tostring(validated),
            }
        end
    end

    if result.status == "success" then
        local compatibilities = {}
        local completed = {}
        local remaining = #pending

        while remaining > 0 do
            local wave = {}
            local seen_names = {}
            local prior_writes = {}

            -- Select the largest safe wave in source order. Only the first
            -- remaining occurrence of one ordinary name is eligible. The
            -- graph barrier additionally protects future or injected cases
            -- where two names retain one mutable declaration-owned node.
            for pending_index, declaration in ipairs(pending) do
                if not completed[pending_index] then
                    local first_for_name = not seen_names[declaration.name]
                    seen_names[declaration.name] = true
                    if first_for_name
                       and not foreign_redeclaration_batch.reads_prior_write(
                            declaration, prior_writes) then
                        wave[#wave + 1] = {
                            pending_index = pending_index,
                            declaration = declaration,
                        }
                    end
                    -- Include writes from skipped earlier declarations too:
                    -- selecting a later reader ahead of such a declaration
                    -- would also invert the former sequential semantics.
                    foreign_redeclaration_batch.add_writes(
                        declaration, prior_writes)
                end
            end

            assert(#wave > 0,
                "foreign redeclaration probe wave made no progress")
            local candidates = {}
            local candidate_wave_indexes = {}
            for wave_index, item in ipairs(wave) do
                local declaration = item.declaration
                if declaration.compatibility == "source-repeat" then
                    -- Rendering two synthetic declarations would invent two
                    -- prototype scopes for a prototype-local tag, even when
                    -- the ordered headers emitted this one physical
                    -- declaration only once. The successful baseline above
                    -- is the authoritative proof for an exact source repeat.
                    compatibilities[item.pending_index] = {
                        status = "success",
                    }
                else
                    candidates[#candidates + 1] = {
                        left_type = declaration.previous.type,
                        right_type = declaration.current,
                        left_declaration =
                            declaration.previous.declaration,
                        right_declaration = declaration.declaration,
                    }
                    candidate_wave_indexes[#candidates] = wave_index
                end
            end

            local validated =
                foreign_redeclaration_batch.validate_candidates(
                module_probe, candidates)
            for candidate_index, wave_index in
                ipairs(candidate_wave_indexes) do
                compatibilities[wave[wave_index].pending_index] =
                    validated[candidate_index]
            end

            -- Form accepted composites before constructing the next wave.
            -- This preserves the historical []/[3] then [3]/[4] probe chain
            -- instead of speculatively rendering both against [].
            for _, item in ipairs(wave) do
                local pending_index = item.pending_index
                local compatibility = compatibilities[pending_index]
                completed[pending_index] = true
                remaining = remaining - 1
                if compatibility.status == "success" then
                    canonicalize_foreign_redeclaration(
                        st, item.declaration)
                end
            end
        end

        local rejected = {}
        for pending_index, declaration in ipairs(pending) do
            local compatibility = compatibilities[pending_index]
            if compatibility.status ~= "success" then
                rejected[#rejected + 1] = declaration
                report_foreign_redeclaration_failure(
                    declaration, errors, compatibility)
            end
        end
        restore_rejected_foreign_type_registries(st, rejected)
    else
        restore_rejected_foreign_type_registries(st, pending)
        report_foreign_header_context_failure(st, errors, result)
        if result.status == "rejected" then
            for _, declaration in ipairs(pending) do
                if declaration.compatibility == "conditional"
                   or declaration.compatibility == "source-repeat" then
                    report_foreign_redeclaration_failure(
                        declaration, errors, result)
                end
            end
        end
    end
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

-- Calls share one checker-local signature view without converting declaration
-- types into value types. Type.Function/Method/StaticMethod describe Titan/Lua
-- callable values and declarations; Type.CFunction remains the authoritative C
-- signature, with C void projected only into the call's visible zero-result
-- list. The view never enters the type algebra or code generator.
local function call_signature(callable)
    if callable and callable._tag == "Checker.CallSignature" then
        return callable
    end
    if type(callable) ~= "table" then return nil end

    local tag = callable._tag
    if tag == "Type.FunctionScheme" then
        callable = callable.signature
        tag = callable._tag
    end
    if tag == "Type.CFunction" then
        local ret = c_resolve(callable.ret)
        return {
            _tag = "Checker.CallSignature",
            kind = "c",
            callable = callable,
            params = callable.params,
            rettypes = ret._tag == "Type.CVoid" and {} or { callable.ret },
            varargtype = false,
            flexrettype = false,
            c_vararg = callable.vararg and true or false,
        }
    elseif tag == "Checker.CPseudoNew" then
        return {
            _tag = "Checker.CallSignature",
            kind = "pseudo",
            callable = callable,
            params = callable.params,
            rettypes = callable.rettypes,
            varargtype = false,
            flexrettype = false,
            c_vararg = false,
            description = callable.name == "new_array"
                and "C allocation pseudo-function (integer)"
                or "C allocation pseudo-function ()",
        }
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        if tag == "Type.Function" then
            assert(callable.vararg == false,
                "Type.Function reserved vararg field must be false")
        end
        return {
            _tag = "Checker.CallSignature",
            kind = "titan",
            callable = callable,
            params = callable.params,
            rettypes = callable.rettypes,
            varargtype = callable.varargtype or false,
            flexrettype = callable.flexrettype or false,
            c_vararg = false,
        }
    end
end

local function c_function_pointer_accepts_declaration(target, cfunc)
    local expected = c_function_pointer_type(target)
    return expected ~= nil
       and cfunc ~= nil
       and cfunc._tag == "Type.CFunction"
       and types.c_function_types_equal(expected, cfunc)
end

function checker._foreign_function_reference(var)
    if not var or not var._decl then return nil end
    local decl = var._decl
    if decl._tag == "Ast.TopLevelForeignFunc" then
        return {
            source = true,
            module = assert(decl._foreign_module),
            name = decl.name,
        }
    elseif decl._tag == "Type.ModuleMember"
           and decl.type and c_resolve(decl.type)._tag == "Type.CFunction"
           and var._tag == "Ast.VarDot" and var.exp and var.exp._type then
        if var.exp._type._tag == "Type.CModule" then
            return { name = var.name }
        elseif var.exp._type._tag == "Type.Module"
               and decl._foreign_source then
            return {
                source = true,
                module = decl.modname,
                name = decl.name,
            }
        end
    end
end

local function incomplete_c_object_error(typ, st, subject, seen)
    -- TValue is an intrinsic compiler/runtime boundary whose concrete Lua
    -- 5.5 layout is supplied by the configured internal headers even when the
    -- best-effort C registrar retains only its forward tag. Existing value
    -- lowering, sizeof/alignof, and spill slots depend on that exact SDK type.
    if types.is_c_tvalue(typ) then return nil end
    typ = c_resolve(typ)
    if not typ then return nil end
    seen = seen or {}
    if seen[typ] then return nil end
    seen[typ] = true

    if typ._tag == "Type.CStruct" or typ._tag == "Type.CUnion" then
        if not st:foreign_definition_visible(typ) then
            return string.format(
                "%s requires complete C %s type '%s', but its definition is "
                .. "incomplete or not yet visible",
                subject,
                typ._tag == "Type.CStruct" and "struct" or "union",
                types.tostring(typ))
        end
    elseif typ._tag == "Type.CArray" then
        if typ.len == nil or typ.len == false or typ.len == "" then
            return string.format(
                "%s requires a complete C array type, but '%s' has no "
                .. "known extent",
                subject, types.tostring(typ))
        end
        return incomplete_c_object_error(typ.elem, st,
            subject .. " array element", seen)
    end
end

local function report_incomplete_c_object(typ, st, subject, loc, errors)
    local err = incomplete_c_object_error(typ, st, subject)
    if err then
        checker.typeerror(errors, loc, err)
        return false
    end
    return true
end


-- C allocation pseudo-members are syntax-bound checker declarations, not
-- boxed callable values. The singleton context lets VarDot expose their narrow
-- call signature only while it is the direct callee of an ExpCall; every other
-- value use is rejected before the descriptor can enter the type algebra.
local c_pseudo_callee_context = {}

local function c_pseudo_member(typ, name, st)
    local resolved = c_resolve(typ)
    local has_fam = resolved and resolved._tag == "Type.CStruct"
        and resolved.has_fam == true
    if name == "new" then
        return {
            _tag = "Checker.CPseudoNew",
            ctype = typ,
            name = name,
            fam = has_fam,
            params = has_fam and { types.Integer() } or {},
            rettypes = { c_owned_type(typ, false) },
        }
    elseif name == "new_array" then
        if has_fam then
            return nil, string.format(
                "C pseudo-member '.new_array' is unavailable for struct type '%s' because it has a flexible array member",
                types.tostring(typ))
        end
        return {
            _tag = "Checker.CPseudoNew",
            ctype = typ,
            name = name,
            array = true,
            params = { types.Integer() },
            rettypes = { c_owned_type(typ, true) },
        }
    elseif name == "sizeof" or name == "alignof" then
        local err = incomplete_c_object_error(typ, st,
            "C pseudo-member '." .. name .. "'")
        if err then return nil, err end
        local size_entry = st.c_profile
            and st.c_profile.integers
            and st.c_profile.integers[st.c_profile.size_t]
        if not size_entry or not size_entry.type then
            return nil, "cannot determine C pseudo-member '." .. name
                .. "' result because the configured target profile has no "
                .. "authoritative size_t type"
        end
        return {
            _tag = "Type.CPseudoSize",
            ctype = typ,
            name = name,
            type = types.Integer(),
            result_source = size_entry.type,
        }
    end
end

local function is_c_pseudo_member_name(name)
    return name == "new" or name == "new_array"
        or name == "sizeof" or name == "alignof"
end

local function field_macro_path_spelling(path)
    local parts = {}
    for _, segment in ipairs(path or {}) do
        if type(segment) ~= "string" or segment == "" then
            return "<invalid>"
        end
        parts[#parts + 1] = segment
    end
    return #parts > 0 and table.concat(parts, ".") or "<invalid>"
end

local function field_macro_error(root, name, projection, reason)
    return string.format(
        "C field macro '%s' expands to '%s', which is not a valid physical "
        .. "field path in C type '%s': %s",
        name, field_macro_path_spelling(projection and projection.path),
        types.tostring(root), reason)
end

local function projected_c_field(root, name, projection, st)
    local path = projection and projection.path
    if type(path) ~= "table" or #path == 0 then
        return nil, field_macro_error(
            root, name, projection, "the recorded path is empty or malformed")
    end

    local owner = root
    for index, segment in ipairs(path) do
        if type(segment) ~= "string" or segment == "" then
            return nil, field_macro_error(
                root, name, projection,
                "the recorded path contains a non-identifier segment")
        end

        owner = c_resolve(owner)
        if owner._tag ~= "Type.CStruct"
           and owner._tag ~= "Type.CUnion" then
            return nil, field_macro_error(
                root, name, projection,
                string.format(
                    "segment '%s' follows non-aggregate C type '%s'",
                    segment, types.tostring(owner)))
        elseif not st:foreign_definition_visible(owner) then
            return nil, field_macro_error(
                root, name, projection,
                string.format(
                    "C type '%s' is incomplete or not yet visible before "
                    .. "segment '%s'",
                    types.tostring(owner), segment))
        end

        -- Resolve the fully expanded path through physical fields only. In
        -- particular, glibc's sa_handler replacement ends in another token
        -- named sa_handler; that token is not recursively expanded while the
        -- outer macro is disabled during its own replacement rescan.
        local field = owner.fields and owner.fields[segment]
        if not field then
            return nil, field_macro_error(
                root, name, projection,
                string.format(
                    "physical field '%s' is not present in C type '%s'",
                    segment, types.tostring(owner)))
        end

        if index == #path then
            local projected = types.CField(
                root, name, field.type,
                field.bitfield, field.flexible_array)
            projected._macro_projection = projection
            return projected
        end
        owner = field.type
    end
end

local function active_field_macro(name, st)
    local cached, known =
        st:find_cached_foreign_field_macro(name)
    if known then return cached end

    local definition, initialized =
        st:find_foreign_macro_definition(name)
    if not initialized or not definition or definition.args then
        st:cache_foreign_field_macro(name, nil)
        return nil
    end

    local macro = cdefines.classify_field_macro(
        name, st:foreign_macro_environment())
    st:cache_foreign_field_macro(name, macro)
    return macro
end

local function c_field_decl(typ, name, st)
    typ = c_resolve(typ)
    if typ._tag == "Type.CPointer" then
        typ = c_resolve(typ.pointee)
    elseif typ._tag == "Type.COwned" then
        typ = c_resolve(typ.pointee)
    end
    if typ._tag == "Type.CStruct" or typ._tag == "Type.CUnion" then
        -- A source-imported C type keeps its producer-owned descriptor, while
        -- this translation unit may complete the same file-scope tag in a
        -- later direct header. C has one file-scope tag namespace, so field
        -- lookup uses that visible completion without mutating the producer.
        if typ._c_tag_scope == "file" and typ.tagname then
            local kind = typ._tag == "Type.CStruct" and "struct" or "union"
            local record = st:find_c_file_tag(typ.tagname, kind)
            if record and record.canonical and record.canonical.complete then
                typ = record.canonical
            end
        end
        local err = incomplete_c_object_error(typ, st,
            "C field access '" .. name .. "'")
        if err then
            return nil, string.format(
                "field '%s' not found in C type '%s' because its definition "
                .. "is incomplete or not yet visible",
                name, types.tostring(typ))
        end
        local macro = active_field_macro(name, st)
        if macro and macro.unsupported then
            return nil, string.format(
                "C field token '%s' is an active object-like macro whose "
                .. "final expansion '%s' is not a supported pure dotted "
                .. "field projection in C type '%s'",
                name, macro.replacement or "<unknown>",
                types.tostring(typ))
        elseif macro then
            -- Preprocessing happens before C member lookup. A live projection
            -- therefore wins even when the aggregate has a physical field with
            -- the same public spelling; a bad expansion is terminal rather
            -- than falling back to the field C itself cannot name here.
            return projected_c_field(typ, name, macro, st)
        end
        if typ.fields and typ.fields[name] then
            return typ.fields[name]
        end
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

-- C field/index assignment ultimately mutates storage rather than a by-value
-- aggregate result. Pointer and COwned expressions identify persistent storage
-- regardless of how their values were produced. A CStruct/CUnion/CArray,
-- however, must itself be an addressable local/imported object or a subobject
-- reached through another persistent C base. Keep this predicate aligned with
-- the coder's recursive prepared-lvalue lowering: a call, cast, or other
-- by-value aggregate expression cannot safely be retained by taking the
-- address of a temporary.
local c_assignment_base_has_storage

local function c_aggregate_storage_expression(exp)
    if not exp or exp._tag ~= "Ast.ExpVar" then
        return false, exp
    end

    local var = exp.var
    if var._tag == "Ast.VarName" then
        local decl = var._decl
        if decl and decl._tag == "Ast.Decl" then
            return true
        end
    elseif var._tag == "Ast.VarDot" then
        if var.exp and var.exp._type
           and var.exp._type._tag == "Type.CModule"
           and var._decl and var._decl._tag == "Type.ModuleMember" then
            return true
        elseif var._decl and var._decl._tag == "Type.CField"
               and var.exp and var.exp._type
               and types.is_direct_c(var.exp._type) then
            return c_assignment_base_has_storage(var.exp)
        end
    elseif var._tag == "Ast.VarBracket"
           and var.exp1 and var.exp1._type
           and types.is_direct_c(var.exp1._type) then
        return c_assignment_base_has_storage(var.exp1)
    end

    return false, exp
end

c_assignment_base_has_storage = function(exp)
    local typ = exp and exp._type and c_resolve(exp._type)
    if not typ or typ._tag == "Type.Invalid" then
        -- The ordinary expression/type diagnostic is already authoritative.
        return true
    elseif typ._tag == "Type.CPointer" or typ._tag == "Type.COwned" then
        return true
    elseif typ._tag == "Type.CStruct" or typ._tag == "Type.CUnion"
           or typ._tag == "Type.CArray" then
        return c_aggregate_storage_expression(exp)
    end
    return true
end

local function check_c_assignment_storage(var, errors)
    local base
    if var._tag == "Ast.VarDot" and var._decl
       and var._decl._tag == "Type.CField" then
        base = var.exp
    elseif var._tag == "Ast.VarBracket" and var.exp1
           and var.exp1._type and types.is_direct_c(var.exp1._type) then
        base = var.exp1
    else
        return
    end

    local ok, culprit = c_assignment_base_has_storage(base)
    if not ok then
        culprit = culprit or base
        checker.typeerror(errors, culprit.loc or var.loc,
            "C assignment receiver must have persistent storage; "
            .. "expression of type '%s' is a by-value C aggregate",
            types.tostring(culprit._type or base._type))
    end
end

local function has_c_length(typ)
    typ = c_resolve(typ)
    return typ._tag == "Type.CArray"
        and type(typ.len) == "number"
        or (typ._tag == "Type.COwned" and typ.count)
end

local function c_allocation_error(typ, st, allow_automatic_array)
    local rtyp = c_resolve(typ)
    if not rtyp or rtyp._tag == "Type.Invalid" then
        return nil
    elseif rtyp._tag == "Type.CModule" or not types.is_direct_c(typ) then
        return string.format(
            "C allocation requires a C FFI object type, not '%s'",
            types.tostring(typ))
    elseif rtyp._tag == "Type.COwned" then
        return string.format(
            "cannot nest owned C storage inside owned C storage ('%s')",
            types.tostring(typ))
    elseif rtyp._tag == "Type.CVoid" then
        return "cannot allocate C void type in this FFI version"
    elseif rtyp._tag == "Type.CFunction" then
        return string.format(
            "cannot allocate C function type '%s' in this FFI version",
            types.tostring(typ))
    end

    local layout_error = incomplete_c_object_error(
        rtyp, st, "C allocation")
    if layout_error then
        if rtyp._tag == "Type.CStruct"
           or rtyp._tag == "Type.CUnion" then
            return string.format(
                "cannot allocate incomplete C %s type '%s' in this FFI "
                .. "version because its definition is incomplete or not "
                .. "yet visible",
                rtyp._tag == "Type.CStruct" and "struct" or "union",
                types.tostring(rtyp))
        end
        return layout_error
    elseif rtyp._tag == "Type.CArray" and not allow_automatic_array then
        return "cannot allocate C array typedefs as owned storage in this FFI version"
    end
end

function checker._c_flexible_array_member(typ)
    local resolved = c_resolve(typ)
    if not resolved or resolved._tag ~= "Type.CStruct"
       or not resolved.has_fam then
        return nil
    end
    for _, field in ipairs(resolved.fields or {}) do
        if field.flexible_array then return field end
    end
    error("C struct has_fam metadata lacks its flexible-array field")
end

function checker._validate_automatic_fam_extent(plan, st, loc, errors)
    local field = assert(plan.fam_field)
    local array = assert(c_resolve(field.type))
    assert(array._tag == "Type.CArray")
    local count = assert(plan.fam_count_literal)
    local probe, probe_error = checker._probe_for_c_types(
        st, { plan.payload_type, array.elem })
    local qualified = types.tostring(plan.payload_type) .. "." .. field.name
    if not probe then
        checker.typeerror(errors, loc,
            "cannot validate automatic C allocation extent for flexible-array "
            .. "field '%s' against the configured target: %s",
            qualified, tostring(probe_error))
        return
    end

    local predicate = string.format(
        "(%s <= ((((size_t)-1) - offsetof(%s, %s)) / sizeof(%s)))",
        tostring(count), cdeclarator.render_type_name(plan.payload_type),
        field.name, cdeclarator.render_type_name(array.elem))
    local sentinel = types.CArray(array.elem, predicate .. " ? 1 : -1")
    local result = probe:validate_declaration_compatibilities({ {
        left_type = sentinel,
        right_type = sentinel,
    } })[1]
    if not result or result.status == "infrastructure_failure" then
        checker.typeerror(errors, loc,
            "cannot validate automatic C allocation extent for flexible-array "
            .. "field '%s' against the configured target: %s",
            qualified, result and (result.message or result.summary
                or result.status) or "the C probe returned no result")
    elseif not result.accepted then
        checker.typeerror(errors, loc,
            "automatic C allocation extent for flexible-array field '%s' "
            .. "with count %s exceeds SIZE_MAX on the configured target",
            qualified, tostring(count))
    end
end

function checker._allocation_integer_literal(exp)
    while exp and (exp._tag == "Ast.ExpCast"
                   or exp._tag == "Ast.ExpAdjust") do
        exp = exp.exp
    end
    if exp and exp._tag == "Ast.ExpInteger"
       and math.type(exp.value) == "integer" then
        return exp.value
    end
end

function checker._numeric_literal_is_zero(exp)
    if not exp then return false end
    local tag = exp._tag
    if tag == "Ast.ExpCast" or tag == "Ast.ExpAdjust"
       or (tag == "Ast.ExpUnop" and exp.op == "-") then
        return checker._numeric_literal_is_zero(exp.exp)
    end
    return (tag == "Ast.ExpInteger" or tag == "Ast.ExpFloat")
        and exp.value == 0
end

function checker._automatic_allocation_error(typ, st, allow_fam)
    local resolved = c_resolve(typ)
    if not resolved or resolved._tag == "Type.Invalid" then return nil end
    if resolved._tag ~= "Type.CStruct"
       and resolved._tag ~= "Type.CUnion" then
        return string.format(
            "automatic allocation requires a C struct or union, not '%s'",
            types.tostring(typ))
    end
    if not st:foreign_definition_visible(resolved) then
        return string.format("automatic C object type '%s' is incomplete or not yet visible",
            types.tostring(typ))
    end
    if resolved._tag == "Type.CStruct" and resolved.has_fam
       and not allow_fam then
        return string.format(
            "automatic C object type '%s' has a flexible array member",
            types.tostring(typ))
    end
    local bearing, offender = types.c_automatic_gc_bearing(typ)
    if bearing then
        return string.format(
            "automatic C object type '%s' transitively contains GC-bearing FFI storage '%s', which automatic C objects do not trace",
            types.tostring(typ), types.tostring(offender))
    end
end

function checker._pointer_to_allocation_payload(target, payload)
    local resolved = c_resolve(target)
    return resolved and resolved._tag == "Type.CPointer"
       and types.equals(resolved.pointee, payload)
end

function checker._plan_c_allocation(node, pseudo, demand, st, errors)
    local decl = demand and demand.allocation_decl
    local payload = pseudo.ctype
    local resolved_payload = c_resolve(payload)
    local target = decl and decl._type or nil
    local plan = {
        kind = "c_allocation",
        payload_type = payload,
        array = pseudo.array == true,
        fam = pseudo.fam == true,
        storage = "owned",
        result_type = pseudo.rettypes[1],
    }

    if pseudo.array then
        local count = checker._allocation_integer_literal(node.args.args[1])
        plan.array_count_literal = count
        if target and target._tag == "Type.COwned" then
            -- An explicit owner always wins over literal-driven inference.
        elseif target and target._tag == "Type.CArray" then
            plan.storage = "automatic_array"
            plan.result_type = target
            if math.type(target.len) ~= "integer" or target.len <= 0 then
                checker.typeerror(errors, decl.loc,
                    "constructor-initialized fixed C array '%s' requires a positive extent",
                    decl.name)
            elseif count == nil then
                checker.typeerror(errors, node.loc,
                    "fixed C array local '%s' requires a compile-time integer literal allocation count",
                    decl.name)
            elseif count ~= target.len then
                checker.typeerror(errors, node.loc,
                    "fixed C array local '%s' has extent %d but '.new_array' allocates %d element(s)",
                    decl.name, target.len, count)
            else
                plan.array_count_literal = count
            end
        elseif target and checker._pointer_to_allocation_payload(target, payload) then
            plan.storage = count and count > 0
                and "automatic_array_borrow" or "owned_borrow"
            plan.result_type = target
        elseif decl and not target and count and count > 0 then
            plan.storage = "automatic_array"
            plan.result_type = types.CArray(payload, count)
        end
    elseif resolved_payload
           and (resolved_payload._tag == "Type.CStruct"
                or resolved_payload._tag == "Type.CUnion") then
        local fam_count = pseudo.fam
            and checker._allocation_integer_literal(node.args.args[1]) or nil
        plan.fam_count_literal = fam_count
        local explicit_owner = target and target._tag == "Type.COwned"
        local pointer_target = target
            and checker._pointer_to_allocation_payload(target, payload)
        local can_automatic = decl ~= nil
            and not explicit_owner and not pointer_target
            and (not target or types.equals(target, payload))
            and (not pseudo.fam or (fam_count and fam_count >= 0))
        if can_automatic then
            local alloc_err = checker._automatic_allocation_error(
                payload, st, pseudo.fam)
            if alloc_err then
                checker.typeerror(errors, node.loc, "%s", alloc_err)
            else
                plan.storage = pseudo.fam
                    and "automatic_fam" or "automatic_object"
                plan.result_type = payload
                plan.fam_field = pseudo.fam
                    and checker._c_flexible_array_member(payload) or nil
            end
        elseif pointer_target then
            plan.storage = "owned_borrow"
            plan.result_type = target
        end
    end

    if resolved_payload and resolved_payload._tag == "Type.CArray"
       and not plan.storage:match("^automatic") then
        checker.typeerror(errors, node.loc,
            "cannot allocate C array typedefs as owned storage in this FFI version")
    end

    if plan.storage == "automatic_array"
       or plan.storage == "automatic_array_borrow" then
        local bearing, offender = types.c_automatic_gc_bearing(payload)
        if bearing then
            checker.typeerror(errors, node.loc,
                "automatic C array element type '%s' transitively contains GC-bearing FFI storage '%s', which automatic C objects do not trace",
                types.tostring(payload), types.tostring(offender))
        end
    end

    if pseudo.fam then
        plan.fam_field = checker._c_flexible_array_member(payload)
    end
    if plan.storage == "automatic_fam" then
        checker._validate_automatic_fam_extent(plan, st, node.loc, errors)
    end
    pseudo.rettypes = { plan.result_type }
    node._c_allocation_plan = plan
    if decl and plan.storage:match("^automatic") then
        decl._c_allocation_plan = plan
        decl._c_automatic_object = true
        node._c_automatic_allocation = true
    elseif decl and plan.storage == "owned_borrow" then
        decl._c_allocation_plan = plan
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

local function nominal_module(fqtn)
    return fqtn:match("^(.*)%.[^.]+$")
end

local function is_nominal_visible_from(st, fqtn)
    local nominal = types.registry[fqtn]
    local owner = nominal_module(fqtn)
    return nominal
        and (not nominal.islocal
             or owner == st.modname
             or st:source_import_visible(owner))
end

local function is_nominal_member_visible_from(st, member)
    local owner = nominal_module(member.fqtn)
    return not member.islocal
        or owner == st.modname
        or st:source_import_visible(owner)
end

-- A type alias remains type-only as a value, but an alias whose transparent
-- target is a record or union may serve as that nominal's static namespace.
-- Return the canonical owner descriptor so selector lookup keeps the original
-- nominal identity, visibility, native symbols, and module userdata.
local function alias_namespace_type(typ, st)
    local owner = typ
    if typ and typ._tag == "Type.Nominal" then
        -- A concrete alias pre-closes the owner's binders. Its constructor and
        -- statics retain that application rather than reopening the raw owner
        -- scheme and accepting a second, contradictory argument list.
        owner = checker._generic.applied_owner_view(typ)
    elseif typ and typ._tag == "Type.GenericAlias" then
        owner = types.registry[typ.target_owner_fqtn]
    end
    if not owner
       or (owner._tag ~= "Type.Record" and owner._tag ~= "Type.Union")
       or not is_nominal_visible_from(st, owner.name) then
        return nil
    end
    return owner
end

local function visible_record_fields(record, st)
    local out = {}
    for _, field in ipairs(record.fields) do
        if is_nominal_member_visible_from(st, field) then
            table.insert(out, field)
        end
    end
    return out
end

-- Interface implementation is deliberately authorized only at a concrete
-- scalar cast site. The generic type relations know about nominal identities
-- but do not resolve descriptors or decide member visibility; this policy
-- callback supplies those checker-owned facts for one assignment/cast query.
local function interface_relation_policy(st, options)
    local policy = {}
    for key, value in pairs(options or {}) do
        policy[key] = value
    end
    policy.visibility = st.modname
    policy.method_visible = function(method)
        return is_nominal_member_visible_from(st, method)
    end
    policy.interface_coercion = function(source, target, received)
        policy.interface_failure = false
        local concrete = source._tag == "Type.Nominal"
            and checker._generic.applied_owner_view(source) or nil
        local interface = target._tag == "Type.Nominal"
            and checker._generic.applied_owner_view(target) or nil
        if not concrete
           or (concrete._tag ~= "Type.Record"
               and concrete._tag ~= "Type.Union")
           or not interface
           or interface._tag ~= "Type.Interface"
           or not is_nominal_visible_from(st, source.fqtn) then
            return false
        end

        local implementation, failure =
            checker._generic.interface_implementation(
                concrete, interface, received)
        policy.interface_failure = failure or false
        if implementation then
            implementation.methods._surface_concrete = concrete
            implementation.methods._surface_interface = interface
            return implementation.methods
        end
        return false
    end
    return policy
end

local function find_interface_wrapper(plan)
    if type(plan) ~= "table" then return nil end
    if plan.op == "interface_wrapper" then return plan end
    return find_interface_wrapper(plan.coercion)
        or find_interface_wrapper(plan.inner)
end

local interface_adapters = (function()

local function interface_adapter_assert(condition, message)
    if not condition then
        error("invalid checker Interface adapter plan: " .. message, 2)
    end
end

-- Copy one gradual guard into the checker-owned adapter graph. Keeping this
-- graph independent from the relation result lets coder consume a closed,
-- typed decision without consulting `types.gradual_guard` again.
local function freeze_interface_guard(plan, target, seen)
    interface_adapter_assert(
        type(plan) == "table"
            and plan.kind == "gradual_guard",
        "component lacks a gradual guard")
    interface_adapter_assert(
        plan.target and types.equals(plan.target, target),
        "gradual guard target does not match its component")

    seen = seen or {}
    local prior = seen[plan]
    if prior then
        interface_adapter_assert(
            not prior.active,
            "recursive gradual-guard cycle")
        return prior.frozen
    end

    local frozen = {
        kind = "gradual_guard",
        op = plan.op,
        target = target,
    }
    seen[plan] = { active = true, frozen = frozen }

    local tag = target._tag
    if tag == "Type.Array" then
        interface_adapter_assert(
            plan.op == "array" and plan.element,
            "Array guard has the wrong shape")
        frozen.element = freeze_interface_guard(
            plan.element, target.elem, seen)
    elseif tag == "Type.Map" then
        interface_adapter_assert(
            plan.op == "map" and plan.key and plan.value,
            "Map guard has the wrong shape")
        frozen.key = freeze_interface_guard(
            plan.key, target.keys, seen)
        frozen.value = freeze_interface_guard(
            plan.value, target.values, seen)
    elseif tag == "Type.Option" then
        interface_adapter_assert(
            plan.op == "option" and plan.inner,
            "Option guard has the wrong shape")
        frozen.inner = freeze_interface_guard(
            plan.inner, target.base, seen)
    elseif tag == "Type.Nominal"
        or tag == "Type.Record"
        or tag == "Type.Union" then
        local name = target.fqtn or target.name
        interface_adapter_assert(
            plan.op == "nominal" and plan.name == name,
            "nominal guard has the wrong identity")
        frozen.name = name
    else
        local leaf_ops = {
            ["Type.Integer"] = "integer",
            ["Type.Float"] = "float",
            ["Type.Boolean"] = "boolean",
            ["Type.Nil"] = "nil",
            ["Type.String"] = "string",
            ["Type.Value"] = "value",
            ["Type.Function"] = "callable",
            ["Type.COwned"] = "c_owned",
            ["Type.CInteger"] = "c_integer",
            ["Type.CFloat"] = "c_float",
        }
        local expected = leaf_ops[tag]
        if types.is_c_tvalue(target) then
            expected = "c_tvalue"
        end
        interface_adapter_assert(
            expected and plan.op == expected,
            "guard has unsupported leaf " .. tostring(tag))
    end

    seen[plan].active = false
    return frozen
end

local freeze_callable_actions
local freeze_callable_adapter_plan

local function interface_adapter_is_gc(typ)
    local normalized = types.normalize(typ)
    return normalized and types.is_gc(normalized) or false
end

local function interface_injection_may_relocate(typ)
    typ = types.normalize(typ)
    if not typ then return false end
    if typ._tag == "Type.Array" then return true end
    if typ._tag == "Type.Option" then
        return interface_injection_may_relocate(typ.base)
    end
    return false
end

-- Normalize a callable component edge into the only operations an Interface
-- adapter may execute. Ordinary coercions and representation-changing nested
-- Interface construction are intentionally absent.
local function freeze_callable_component(
        adjustment, source, target, context)
    local normalized_source = types.normalize(source)
    local normalized_target = types.normalize(target)
    interface_adapter_assert(
        type(adjustment) == "table",
        "callable component lacks an adjustment")
    interface_adapter_assert(
        normalized_source and normalized_target
            and adjustment.source and adjustment.target
            and types.equals(
                adjustment.source, normalized_source)
            and types.equals(
                adjustment.target, normalized_target),
        "callable component endpoints do not match")
    interface_adapter_assert(
        not adjustment.interface_conversion,
        "nested concrete-to-Interface conversion")

    if adjustment.kind == "identity" then
        return {
            kind = "identity",
            source = normalized_source,
            target = normalized_target,
            declared_source = source,
            declared_target = target,
            timing = "immediate",
            may_raise = false,
            may_relocate = false,
        }
    elseif adjustment.kind == "gradual_view" then
        if adjustment.op == "inject" then
            local may_relocate =
                interface_injection_may_relocate(
                    normalized_source)
            interface_adapter_assert(
                normalized_target._tag == "Type.Value"
                    and adjustment.guard == nil,
                "malformed gradual injection")
            return {
                kind = "gradual_inject",
                source = normalized_source,
                target = normalized_target,
                declared_source = source,
                declared_target = target,
                timing = "immediate",
                may_raise = may_relocate,
                may_relocate = may_relocate,
            }
        end

        interface_adapter_assert(
            adjustment.op == "project"
                or adjustment.op == "structural",
            "unsupported gradual operation "
                .. tostring(adjustment.op))
        local delayed = adjustment.op == "structural"
            and normalized_target._tag ~= "Type.Option"
        return {
            kind = "gradual_guard",
            mode = adjustment.op,
            source = normalized_source,
            target = normalized_target,
            declared_source = source,
            declared_target = target,
            guard = freeze_interface_guard(
                adjustment.guard, normalized_target, {}),
            timing = delayed and "delayed_observation"
                or "immediate",
            may_raise = not delayed,
            -- Conservatively require a rebase after an immediate guard. A
            -- particular leaf check may not allocate, but its checked helper
            -- is allowed to do so without invalidating adapter stack aliases.
            may_relocate = not delayed,
        }
    elseif adjustment.kind == "callable" then
        return {
            kind = "callable_view",
            source = normalized_source,
            target = normalized_target,
            declared_source = source,
            declared_target = target,
            timing = "immediate",
            may_raise = true,
            -- Direct luaF_newCclosure construction performs no stack API call
            -- or ordinary GC poll, so successful construction cannot relocate
            -- the Lua stack. Its allocation may still raise.
            may_relocate = false,
            adapter = freeze_callable_adapter_plan(
                adjustment, normalized_source,
                normalized_target, context.location, context),
        }
    end

    interface_adapter_assert(
        adjustment.kind ~= "direct_coercion",
        "ordinary component coercion is forbidden")
    interface_adapter_assert(false,
        "unknown component operation "
            .. tostring(adjustment.kind))
end

-- Fill the compatibility alias only after constructing the complete nested
-- plan. Existing Interface consumers read `callable`; closure consumers use
-- the full `adapter` including roots, rebases, location, and strict plans.
local function finish_callable_component(operation)
    if operation.kind == "callable_view" then
        operation.callable = operation.adapter.callable
    end
    return operation
end

local function adapter_action(kind, order, fields)
    fields = fields or {}
    fields.kind = kind
    fields.order = order
    fields.id = fields.phase .. ":" .. tostring(order)
    return fields
end

local function component_action(
        raw, kind, order, phase, source, target, context, fields)
    fields = fields or {}
    fields.phase = phase
    fields.source_type = source
    fields.target_type = target
    fields.source_gc = interface_adapter_is_gc(source)
    fields.destination_gc =
        interface_adapter_is_gc(target)
    fields.operation = finish_callable_component(
        freeze_callable_component(
            raw.adjustment, source, target, context))
    fields.rebase_after = fields.operation.may_relocate
    return adapter_action(kind, order, fields)
end

local function callable_dense_count(list, name)
    interface_adapter_assert(type(list) == "table", name .. " is not a table")
    local maximum, count = 0, 0
    for key in pairs(list) do
        interface_adapter_assert(
            type(key) == "number" and key >= 1
                and key == math.floor(key),
            name .. " has a non-array key")
        if key > maximum then maximum = key end
        count = count + 1
    end
    interface_adapter_assert(count == maximum,
        name .. " is not dense")
    for index = 1, maximum do
        interface_adapter_assert(list[index] ~= nil,
            name .. " has a hole at " .. tostring(index))
    end
    return maximum
end

-- Freeze one directional callable plan while preserving every action index and
-- offset. This is structural elaboration only: it never asks any relation to
-- prove a new edge.
freeze_callable_actions = function(raw, source, target, context)
    interface_adapter_assert(
        type(raw) == "table" and raw.kind == "callable",
        "method adjustment is not callable")
    interface_adapter_assert(
        source._tag == "Type.Function"
            and target._tag == "Type.Function"
            and raw.source and raw.target
            and types.equals(raw.source, source)
            and types.equals(raw.target, target),
        "callable plan has mismatched signatures")
    interface_adapter_assert(
        source.vararg == false and target.vararg == false,
        "callable plan has a non-false reserved Function slot")
    interface_adapter_assert(
        raw.exact == types.equals(source, target),
        "callable exactness marker is wrong")
    interface_adapter_assert(
        type(raw.arguments) == "table"
            and type(raw.results) == "table",
        "callable plan lacks ordered action lists")
    local raw_argument_count = callable_dense_count(
        raw.arguments, "callable argument actions")
    local raw_result_count = callable_dense_count(
        raw.results, "callable result actions")

    interface_adapter_assert(
        type(context) == "table",
        "callable freezer lacks its context")

    local frozen = {
        kind = "interface_callable_actions",
        source = source,
        target = target,
        exact = raw.exact,
        arguments = {},
        results = {},
    }
    local argument_index = 0
    local function argument(kind)
        argument_index = argument_index + 1
        local action = raw.arguments[argument_index]
        interface_adapter_assert(
            action and action.kind == kind,
            "expected argument action " .. kind
                .. " at " .. tostring(argument_index))
        return action, argument_index
    end

    local shared = math.min(#source.params, #target.params)
    for index = 1, shared do
        local action, order = argument("argument")
        interface_adapter_assert(
            action.expected_index == index
                and action.actual_index == index,
            "shared argument indexes are not canonical")
        frozen.arguments[order] = component_action(
            action, "argument", order, "argument",
            target.params[index], source.params[index], context, {
                expected_index = index,
                actual_index = index,
                source_kind = "interface_fixed",
                destination_kind = "concrete_fixed",
            })
    end

    for index = #target.params + 1, #source.params do
        if target.varargtype then
            local action, order =
                argument("tail_or_nil_to_argument")
            interface_adapter_assert(
                action.actual_index == index
                    and action.expected_tail_offset
                        == index - #target.params,
                "tail-to-fixed argument indexes are not canonical")
            frozen.arguments[order] = component_action(
                action, "tail_or_nil_to_argument", order, "argument",
                target.varargtype, source.params[index], context, {
                    actual_index = index,
                    expected_tail_offset =
                        index - #target.params,
                    source_kind = "interface_tail",
                    source_open = true,
                    destination_kind = "concrete_fixed",
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = source.params[index],
                    },
                    present_arm = "operation",
                })
        else
            local action, order = argument("nil_fill")
            interface_adapter_assert(
                action.actual_index == index
                    and action.adjustment == nil,
                "nil-fill argument is malformed")
            frozen.arguments[order] = adapter_action(
                "nil_fill", order, {
                    phase = "argument",
                    actual_index = index,
                    source_kind = "constant_nil",
                    destination_kind = "concrete_fixed",
                    source_type = types.Nil(),
                    target_type = source.params[index],
                    source_gc = false,
                    destination_gc =
                        interface_adapter_is_gc(
                            source.params[index]),
                    admissible = true,
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = source.params[index],
                    },
                    rebase_after = false,
                })
        end
    end

    for index = #source.params + 1, #target.params do
        if source.varargtype then
            local action, order = argument("argument_to_tail")
            interface_adapter_assert(
                action.expected_index == index,
                "fixed-to-tail argument index is not canonical")
            frozen.arguments[order] = component_action(
                action, "argument_to_tail", order, "argument",
                target.params[index], source.varargtype, context, {
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "concrete_tail",
                    destination_open = true,
                })
        else
            local action, order = argument("ignore_argument")
            interface_adapter_assert(
                action.expected_index == index
                    and action.adjustment == nil,
                "ignored argument is malformed")
            frozen.arguments[order] = adapter_action(
                "ignore_argument", order, {
                    phase = "argument",
                    expected_index = index,
                    source_kind = "interface_fixed",
                    destination_kind = "discard",
                    source_type = target.params[index],
                    target_type = false,
                    source_gc =
                        interface_adapter_is_gc(
                            target.params[index]),
                    destination_gc = false,
                    effect = "evaluate_and_discard",
                    rebase_after = false,
                })
        end
    end

    if source.varargtype and target.varargtype then
        local action, order = argument("tail_to_tail")
        local consumed =
            math.max(0, #source.params - #target.params)
        interface_adapter_assert(
            action.expected_tail_consumed == consumed,
            "input tail offset is not canonical")
        frozen.arguments[order] = component_action(
            action, "tail_to_tail", order, "argument",
            target.varargtype, source.varargtype, context, {
                expected_tail_consumed = consumed,
                source_kind = "interface_tail",
                source_open = true,
                destination_kind = "concrete_tail",
                destination_open = true,
            })
    elseif source.varargtype then
        local action, order = argument("empty_tail")
        interface_adapter_assert(
            action.adjustment == nil,
            "empty-tail action has an adjustment")
        frozen.arguments[order] = adapter_action(
            "empty_tail", order, {
                phase = "argument",
                source_kind = "empty",
                destination_kind = "concrete_tail",
                source_type = false,
                target_type = source.varargtype,
                source_gc = false,
                destination_gc =
                    interface_adapter_is_gc(
                        source.varargtype),
                destination_open = true,
                count = 0,
                rebase_after = false,
            })
    elseif target.varargtype then
        local action, order = argument("ignore_tail")
        local consumed =
            math.max(0, #source.params - #target.params)
        interface_adapter_assert(
            action.expected_tail_consumed == consumed
                and action.adjustment == nil,
            "ignored-tail action is malformed")
        frozen.arguments[order] = adapter_action(
            "ignore_tail", order, {
                phase = "argument",
                expected_tail_consumed = consumed,
                source_kind = "interface_tail",
                source_open = true,
                destination_kind = "discard",
                source_type = target.varargtype,
                target_type = false,
                source_gc =
                    interface_adapter_is_gc(
                        target.varargtype),
                destination_gc = false,
                effect = "evaluate_run_and_discard",
                rebase_after = false,
            })
    end
    interface_adapter_assert(
        argument_index == raw_argument_count,
        "callable plan has extra argument actions")

    local result_index = 0
    local function result(kind)
        result_index = result_index + 1
        local action = raw.results[result_index]
        interface_adapter_assert(
            action and action.kind == kind,
            "expected result action " .. kind
                .. " at " .. tostring(result_index))
        return action, result_index
    end

    for index, expected in ipairs(target.rettypes) do
        local actual = source.rettypes[index]
        if actual then
            local action, order = result("result")
            interface_adapter_assert(
                action.actual_index == index
                    and action.expected_index == index,
                "fixed result indexes are not canonical")
            frozen.results[order] = component_action(
                action, "result", order, "result",
                actual, expected, context, {
                    actual_index = index,
                    expected_index = index,
                    source_kind = "concrete_fixed",
                    destination_kind = "interface_fixed",
                })
        elseif source.flexrettype then
            local optional = expected._tag == "Type.Option"
            local kind = optional
                and "flex_to_optional_result"
                or "flex_to_result"
            local action, order = result(kind)
            local offset = index - #source.rettypes
            interface_adapter_assert(
                action.expected_index == index
                    and action.actual_flex_offset == offset,
                "flexible result indexes are not canonical")
            interface_adapter_assert(
                optional
                    and (action.wrap_present == nil
                         or action.wrap_present == true)
                    or (not optional
                        and action.wrap_present == nil),
                "flexible result has invalid Option metadata")
            local wraps = action.wrap_present == true
            local operation_target =
                wraps and expected.base or expected
            local frozen_action = component_action(
                action, kind, order, "result",
                source.flexrettype, operation_target, context, {
                    expected_index = index,
                    actual_flex_offset = offset,
                    source_kind = "concrete_flex",
                    source_open = true,
                    destination_kind = "interface_fixed",
                    target_type = expected,
                    operation_target_type = operation_target,
                    destination_gc =
                        interface_adapter_is_gc(expected),
                    missing_arm = {
                        kind = optional and "nil_fill"
                            or "raise_missing_result",
                        target_type = expected,
                    },
                    present_arm = {
                        kind = "operation",
                        wrap_present = wraps,
                        target_type = operation_target,
                    },
                    wrap_present = wraps,
                })
            -- The operation may target the Option base, but the adapter slot
            -- and its destination root always carry the complete expected
            -- result type.
            frozen_action.target_type = expected
            frozen_action.destination_gc =
                interface_adapter_is_gc(expected)
            frozen.results[order] = frozen_action
        else
            local action, order = result("nil_fill_result")
            interface_adapter_assert(
                action.expected_index == index
                    and action.expected_type
                    and types.equals(action.expected_type, expected)
                    and action.adjustment == nil,
                "missing-result nil fill is malformed")
            frozen.results[order] = adapter_action(
                "nil_fill_result", order, {
                    phase = "result",
                    expected_index = index,
                    expected_type = expected,
                    source_kind = "constant_nil",
                    destination_kind = "interface_fixed",
                    source_type = types.Nil(),
                    target_type = expected,
                    source_gc = false,
                    destination_gc =
                        interface_adapter_is_gc(expected),
                    admissible = true,
                    effect = "synthesize_nil",
                    missing_arm = {
                        kind = "nil_fill",
                        admissible = true,
                        target_type = expected,
                    },
                    rebase_after = false,
                })
        end
    end

    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype then
            local action, order = result("result_to_flex")
            local offset = index - #target.rettypes
            interface_adapter_assert(
                action.actual_index == index
                    and action.expected_flex_offset == offset,
                "fixed-to-flex result indexes are not canonical")
            frozen.results[order] = component_action(
                action, "result_to_flex", order, "result",
                source.rettypes[index], target.flexrettype, context, {
                    actual_index = index,
                    expected_flex_offset = offset,
                    source_kind = "concrete_fixed",
                    destination_kind = "interface_flex",
                    destination_open = true,
                })
        else
            local action, order = result("hide_result")
            interface_adapter_assert(
                action.actual_index == index
                    and action.adjustment == nil,
                "hidden result is malformed")
            frozen.results[order] = adapter_action(
                "hide_result", order, {
                    phase = "result",
                    actual_index = index,
                    source_kind = "concrete_fixed",
                    destination_kind = "discard",
                    source_type = source.rettypes[index],
                    target_type = false,
                    source_gc =
                        interface_adapter_is_gc(
                            source.rettypes[index]),
                    destination_gc = false,
                    effect = "discard",
                    rebase_after = false,
                })
        end
    end

    if source.flexrettype and target.flexrettype then
        local action, order = result("flex_to_flex")
        local consumed =
            math.max(0, #target.rettypes - #source.rettypes)
        interface_adapter_assert(
            action.actual_flex_consumed == consumed,
            "output flex offset is not canonical")
        frozen.results[order] = component_action(
            action, "flex_to_flex", order, "result",
            source.flexrettype, target.flexrettype, context, {
                actual_flex_consumed = consumed,
                source_kind = "concrete_flex",
                source_open = true,
                destination_kind = "interface_flex",
                destination_open = true,
            })
    elseif source.flexrettype then
        local action, order = result("hide_flex")
        local consumed =
            math.max(0, #target.rettypes - #source.rettypes)
        interface_adapter_assert(
            action.actual_flex_consumed == consumed
                and action.adjustment == nil,
            "hidden flex result is malformed")
        frozen.results[order] = adapter_action(
            "hide_flex", order, {
                phase = "result",
                actual_flex_consumed = consumed,
                source_kind = "concrete_flex",
                source_open = true,
                destination_kind = "discard",
                source_type = source.flexrettype,
                target_type = false,
                source_gc =
                    interface_adapter_is_gc(
                        source.flexrettype),
                destination_gc = false,
                effect = "discard_run",
                rebase_after = false,
            })
    elseif target.flexrettype then
        local action, order = result("end_flex")
        interface_adapter_assert(
            action.adjustment == nil,
            "end-flex action has an adjustment")
        frozen.results[order] = adapter_action(
            "end_flex", order, {
                phase = "result",
                source_kind = "empty",
                destination_kind = "interface_flex",
                source_type = false,
                target_type = target.flexrettype,
                source_gc = false,
                destination_gc =
                    interface_adapter_is_gc(
                        target.flexrettype),
                destination_open = true,
                count = 0,
                rebase_after = false,
            })
    end
    interface_adapter_assert(
        result_index == raw_result_count,
        "callable plan has extra result actions")

    return frozen
end

local function adapter_root_range(
        id, phase, side, element_type, lifetime, traced)
    local present = element_type ~= nil
        and element_type ~= false
    local gc_bearing =
        present and interface_adapter_is_gc(
            element_type) or false
    traced = gc_bearing and traced == true
    return {
        kind = "open_root_range",
        id = id,
        phase = phase,
        side = side,
        present = present,
        element_type = element_type or false,
        gc_bearing = gc_bearing,
        traced = traced,
        storage = traced and "parallel_lua_stack_range" or false,
        dynamic_start = present and "run_start" or false,
        dynamic_count = present and "run_count" or false,
        retain_until = lifetime,
        raw_storage_is_root = false,
    }
end

local function adapter_operation_allocates(action)
    return action.operation ~= nil
        and action.operation.kind == "callable_view"
end

local function adapter_has_open_source(actions)
    for _, action in ipairs(actions) do
        if action.operation and action.source_open then return true end
    end
    return false
end

local function adapter_has_open_allocating_destination(actions)
    for _, action in ipairs(actions) do
        if adapter_operation_allocates(action)
           and action.destination_open then
            return true
        end
    end
    return false
end

local function adapter_fixed_allocation_roots(actions, lifetime)
    local roots = {}
    for _, action in ipairs(actions) do
        if adapter_operation_allocates(action)
           and action.destination_gc
           and not action.destination_open then
            roots[#roots + 1] = {
                action = action.id,
                type = action.target_type,
                storage = "lua_stack_slot",
                retain_until = lifetime,
            }
        end
    end
    return roots
end

local function adapter_fixed_result_source_roots(actions, lifetime)
    local roots = {}
    for _, action in ipairs(actions) do
        if action.operation and action.source_gc
           and not action.source_open then
            roots[#roots + 1] = {
                action = action.id,
                type = action.source_type,
                storage = "lua_stack_slot",
                retain_until = lifetime,
            }
        end
    end
    return roots
end

local function adapter_rooting(source, target, actions, lifetimes, construction)
    return {
        raw_descriptors_are_roots = false,
        raw_buffers_are_roots = false,
        construction = construction,
        fixed = {
            -- Native inputs remain C arguments and acquire no tracing-only
            -- source roots. Only a freshly allocated nested wrapper needs an
            -- immediate destination root.
            argument_source = {},
            argument_destination = adapter_fixed_allocation_roots(
                actions.arguments, lifetimes.argument_destination),
            -- Every live GC-bearing native result is rooted immediately after
            -- return. Fresh converted wrappers separately root their allocation.
            result_source = adapter_fixed_result_source_roots(
                actions.results, lifetimes.result_source),
            result_destination = adapter_fixed_allocation_roots(
                actions.results, lifetimes.result_destination),
        },
        ranges = {
            argument_source = adapter_root_range(
                "argument_source", "argument", "source",
                target.varargtype, lifetimes.argument_source, false),
            argument_destination = adapter_root_range(
                "argument_destination", "argument", "destination",
                source.varargtype, lifetimes.argument_destination,
                adapter_has_open_allocating_destination(actions.arguments)),
            result_source = adapter_root_range(
                "result_source", "result", "source",
                source.flexrettype, lifetimes.result_source,
                adapter_has_open_source(actions.results)),
            result_destination = adapter_root_range(
                "result_destination", "result", "destination",
                target.flexrettype, lifetimes.result_destination,
                adapter_has_open_allocating_destination(actions.results)),
        },
    }
end

local CALLABLE_ADAPTER_VARARG_CAP = 200

local function callable_adapter_location(loc)
    interface_adapter_assert(
        type(loc) == "table"
            and type(loc.filename) == "string"
            and type(loc.line) == "number"
            and loc.line >= 1 and loc.line == math.floor(loc.line)
            and type(loc.col) == "number"
            and loc.col >= 1 and loc.col == math.floor(loc.col),
        "callable adapter lacks a real source location")
    return {
        filename = loc.filename,
        line = loc.line,
        col = loc.col,
    }
end

local function same_adapter_location(left, right)
    return left and right
        and left.filename == right.filename
        and left.line == right.line
        and left.col == right.col
end

local function freeze_strict_guard_slot(typ, index)
    local normalized = types.normalize(typ)
    interface_adapter_assert(normalized,
        "strict relay has an unnormalizable boundary type")
    local guard = types.gradual_guard(normalized)
    return {
        index = index,
        type = normalized,
        guard = guard
            and freeze_interface_guard(guard, normalized, {})
            or false,
    }
end

local function freeze_strict_relay(target)
    local relay = {
        kind = "callable_strict_relay",
        parameters = {},
        vararg = false,
        results = {},
        flexible_result = false,
    }
    for index, typ in ipairs(target.params) do
        relay.parameters[index] = freeze_strict_guard_slot(typ, index)
    end
    if target.varargtype then
        relay.vararg = freeze_strict_guard_slot(
            target.varargtype, "vararg")
    end
    for index, typ in ipairs(target.rettypes) do
        relay.results[index] = freeze_strict_guard_slot(typ, index)
    end
    if target.flexrettype then
        relay.flexible_result = freeze_strict_guard_slot(
            target.flexrettype, "flexible_result")
    end
    return relay
end

local function callable_adapter_rooting(source, target, actions)
    return adapter_rooting(source, target, actions, {
        argument_source = "all_arguments_converted",
        argument_destination = "source_native_call_returns",
        result_source = "all_results_converted",
        result_destination = "target_caller_handoff",
    }, {
        result = {
            type = target,
            gc_bearing = true,
            traced = true,
            storage = "conditional_lua_stack_slot",
            condition = "eligible_exact_titan_clone",
            retain_until = "target_caller_handoff",
        },
    })
end

local function callable_action_rebase_reason(action)
    interface_adapter_assert(
        action.operation
            and action.operation.timing == "immediate"
            and action.operation.may_relocate == true
            and action.operation.kind ~= "callable_view",
        "callable adapter has a rebase for a non-relocating action")
    return "immediate_gradual_guard"
end

local function callable_adapter_rebases(actions)
    local points = {}
    for _, action in ipairs(actions.arguments) do
        if action.rebase_after then
            points[#points + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    points[#points + 1] = {
        kind = "after_native_call",
        backend = "immediate_source_closure",
        reason = "source_call_may_relocate_stack",
    }
    for _, action in ipairs(actions.results) do
        if action.rebase_after then
            points[#points + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    return points
end

local function freeze_flexible_result_demand(source, target)
    local consumed = math.max(
        0, #target.rettypes - #source.rettypes)
    local fixed_surplus = math.max(
        0, #source.rettypes - #target.rettypes)
    local source_has_flex = source.flexrettype ~= nil
        and source.flexrettype ~= false
    local target_has_flex = target.flexrettype ~= nil
        and target.flexrettype ~= false
    return {
        kind = "callable_flexible_result_demand",
        abi_cap = CALLABLE_ADAPTER_VARARG_CAP,
        source_has_flex = source_has_flex,
        target_has_flex = target_has_flex,
        fixed_source_flex_consumed = consumed,
        fixed_source_surplus = fixed_surplus,
        remaining_source_capacity =
            CALLABLE_ADAPTER_VARARG_CAP - consumed,
        within_abi_cap = consumed <= CALLABLE_ADAPTER_VARARG_CAP,
        mode = not source_has_flex and "none"
            or (target_has_flex and "forward_target_demand"
                or "fixed_prefix"),
        target_demand_parameter = target_has_flex
            and "_flexwant" or false,
        unlimited_demand = target_has_flex
            and "LUA_MULTRET" or false,
    }
end

freeze_callable_adapter_plan = function(raw, source, target, loc, context)
    source = types.normalize(source)
    target = types.normalize(target)
    interface_adapter_assert(
        source and target
            and source._tag == "Type.Function"
            and target._tag == "Type.Function",
        "callable adapter endpoints are not functions")
    local frozen_location = callable_adapter_location(loc)

    context = context or {}
    context.adapters = context.adapters or {}
    context.location = context.location or frozen_location
    local prior = context.adapters[raw]
    if prior then
        interface_adapter_assert(not prior.active,
            "recursive callable-plan cycle")
        return prior.frozen
    end

    local attached = raw._callable_adapter
    if attached then
        interface_adapter_assert(
            attached.source and attached.target
                and types.equals(attached.source, source)
                and types.equals(attached.target, target)
                and same_adapter_location(
                    attached.location, frozen_location),
            "callable plan already has a different frozen adapter")
        return attached
    end

    local frozen = {
        kind = "callable_adapter_plan",
        source = source,
        target = target,
        exact = raw.exact,
        location = frozen_location,
        trace_name = string.format(
            "[callable adapter %s -> %s at %s:%d:%d]",
            types.tostring(source), types.tostring(target),
            frozen_location.filename, frozen_location.line,
            frozen_location.col),
        callable = false,
        arguments = false,
        results = false,
        dense = false,
        strict_relay = false,
        rooting = false,
        rebase_points = false,
        flexible_result_demand = false,
        relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true,
    }
    context.adapters[raw] = { active = true, frozen = frozen }

    local previous_location = context.location
    context.location = frozen_location
    local actions = freeze_callable_actions(raw, source, target, context)
    context.location = previous_location
    frozen.callable = actions
    frozen.arguments = actions.arguments
    frozen.results = actions.results
    frozen.dense = {
        argument_count = #actions.arguments,
        result_count = #actions.results,
    }
    frozen.strict_relay = freeze_strict_relay(target)
    frozen.rooting = callable_adapter_rooting(source, target, actions)
    frozen.rebase_points = callable_adapter_rebases(actions)
    frozen.flexible_result_demand =
        freeze_flexible_result_demand(source, target)

    context.adapters[raw].active = false
    raw._callable_adapter = frozen
    return frozen
end

local function make_interface_adapter(
        concrete, interface, mapping)
    interface_adapter_assert(
        mapping and mapping.required and mapping.concrete,
        "method mapping lacks descriptors")
    interface_adapter_assert(
        mapping.index >= 0
            and interface.methods[mapping.index + 1]
                == mapping.required
            and mapping.required.name == mapping.name
            and mapping.concrete.fqtn == concrete.name,
        "method mapping does not match its Interface slot")
    interface_adapter_assert(
        mapping.source and mapping.target
            and mapping.source._tag == "Type.Function"
            and mapping.target._tag == "Type.Function",
        "method mapping lacks projected signatures")
    interface_adapter_assert(
        mapping.exact == types.equals(
            mapping.source, mapping.target),
        "method mapping exactness is inconsistent")

    if mapping.exact then
        mapping.slot_kind = "exact"
        mapping.interface_adapter = nil
        return nil
    end

    local trace_name = string.format(
        "%s:%s [adapter for %s:%s]",
        interface.name, mapping.name,
        concrete.name, mapping.name)
    local shared = freeze_callable_adapter_plan(
        mapping.adjustment, mapping.source, mapping.target,
        location.new(trace_name .. ".titan", 1, 1), nil)
    local actions = shared.callable
    local owner_module = nominal_module(concrete.name)
    local adapter = {
        kind = "interface_method_adapter",
        slot = mapping.index,
        slot_kind = "adapter",
        name = mapping.name,
        symbol_key = string.format(
            "%s->%s#%d:%s",
            concrete.name, interface.name,
            mapping.index, mapping.name),
        trace_name = trace_name,
        concrete_owner = concrete,
        concrete_owner_module = owner_module,
        concrete_method = mapping.concrete,
        concrete_signature = mapping.source,
        interface = interface,
        interface_method = mapping.required,
        -- The native adapter ABI is the Interface Method descriptor (hidden
        -- L/module/closure/self included by function_sig). Its self-removed
        -- callable projection is recorded separately.
        native_signature = mapping.required,
        interface_signature = mapping.target,
        hidden_operands = {
            concrete_owner_module = {
                parameter = "_mod",
                provenance = "interface_wrapper_uservalue_0",
                owner = concrete,
                module = owner_module,
                forwards_unchanged = true,
                emitter_module_is_forbidden = true,
            },
            closure = {
                parameter = "_fn",
                adapter_value = "NULL",
                concrete_call_value = "NULL",
            },
            self = {
                provenance = "interface_wrapper_uservalue_1",
                type = types.Nominal(concrete.name),
                forwards_unchanged = true,
            },
        },
        arguments = actions.arguments,
        results = actions.results,
        callable = actions,
        callable_adapter = shared,
        relation_free = true,
        no_nested_interface_conversions = true,
        uses_base_off = true,
    }

    adapter.rooting = adapter_rooting(
        mapping.source, mapping.target, actions, {
            argument_source = "all_arguments_converted",
            argument_destination = "concrete_call_returns",
            result_source = "all_results_converted",
            result_destination = "interface_caller_handoff",
        }, nil)

    local argument_rebases, result_rebases = {}, {}
    for _, action in ipairs(adapter.arguments) do
        if action.rebase_after then
            argument_rebases[#argument_rebases + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    for _, action in ipairs(adapter.results) do
        if action.rebase_after then
            result_rebases[#result_rebases + 1] = {
                kind = "after_action",
                action = action.id,
                reason = callable_action_rebase_reason(action),
            }
        end
    end
    adapter.rebase_points = {}
    for _, point in ipairs(argument_rebases) do
        adapter.rebase_points[#adapter.rebase_points + 1] = point
    end
    adapter.rebase_points[#adapter.rebase_points + 1] = {
        kind = "after_native_call",
        method = mapping.concrete,
        reason = "concrete_call_may_relocate_stack",
    }
    for _, point in ipairs(result_rebases) do
        adapter.rebase_points[#adapter.rebase_points + 1] = point
    end

    mapping.slot_kind = "adapter"
    mapping.interface_adapter = adapter
    return adapter
end

return {
    make = make_interface_adapter,
    freeze = freeze_callable_adapter_plan,
}

end)()

-- Freeze a checker-authorized Function-to-Function edge into the closed action,
-- rooting, rebase, strict-boundary, and demand graph consumed by codegen. This
-- is elaboration only: it never asks an assignment/callable relation again.
function checker.freeze_callable_adapter(
        raw, source, target, loc)
    return interface_adapters.freeze(raw, source, target, loc, nil)
end

local function make_interface_conversion(source, target, adjustment)
    local wrapper = find_interface_wrapper(adjustment)
    if not wrapper then return nil end
    local concrete = wrapper.methods._surface_concrete
        or types.registry[wrapper.source.fqtn]
    local interface = wrapper.methods._surface_interface
        or types.registry[wrapper.target.fqtn]
    local exact = true
    for _, mapping in ipairs(wrapper.methods or {}) do
        interface_adapters.make(concrete, interface, mapping)
        exact = exact and mapping.exact
    end
    local root = adjustment.coercion or adjustment
    return {
        kind = "interface_conversion",
        source = source,
        target = target,
        concrete = concrete,
        interface = interface,
        concrete_type = wrapper.source,
        interface_type = wrapper.target,
        methods = wrapper.methods,
        exact = exact,
        option = root.op or "interface_wrapper",
        source_optional = source._tag == "Type.Option",
        target_optional = target._tag == "Type.Option",
        nil_propagates = root.op == "option_map",
        forces_source = root.op == "option_force",
        wraps_present = root.op == "option_wrap",
    }
end

function checker._generic.rigid_parameter_carrier(parameter)
    if not parameter or parameter._tag ~= "Type.Parameter" then return nil end
    return parameter.erased_constraint ~= false
        and parameter.erased_constraint or types.Value()
end

-- Surface generic types have not reached the erased-core pass yet.  Whenever
-- an existing checker annotation needs the eventual runtime carrier, erase a
-- detached Type view rather than weakening the rigid surface type itself.
function checker._generic.runtime_carrier(typ)
    if types.contains_generic(typ) then return types.erase(typ) end
    return typ
end

-- Ordinary nominal identity is intentionally the shared run-time owner, but
-- applied generic nominals remain distinct static types.  Preserve the one
-- sanctioned shallow consistency edge pointwise: an argument may move to or
-- from its binder's erased carrier, never directly to another precise
-- application merely because both values share one metatable.
function checker._generic.surface_argument_consistent(
        left, right, typeparam, owner, left_args, right_args, st)
    left, right = types.normalize(left), types.normalize(right)
    if not left or not right then return false end
    if types.equals(left, right) then return true end
    if not typeparam then return false end

    -- Shallow generic consistency is narrower than ordinary structural
    -- consistency. One side must be this owner binder's exact erased carrier;
    -- recursively consistent arguments such as {integer} and {value} do not
    -- turn G<{integer}> and G<{value}> into the same application view.
    if typeparam.constraint == false then
        return left._tag == "Type.Value" or right._tag == "Type.Value"
    end

    local left_constraint = checker._generic.generic_substitute(
        typeparam.constraint, owner.scope, left_args)
    local right_constraint = checker._generic.generic_substitute(
        typeparam.constraint, owner.scope, right_args)
    if not left_constraint or not right_constraint then return false end
    return (types.equals(right, right_constraint)
            and checker._generic.generic_constraint_satisfied(
                left, left_constraint, st) == true)
        or (types.equals(left, left_constraint)
            and checker._generic.generic_constraint_satisfied(
                right, right_constraint, st) == true)
end

function checker._generic.applied_nominal_adjustment(source, target, st)
    source, target = types.normalize(source), types.normalize(target)
    if not source or not target
       or source._tag ~= "Type.Nominal"
       or target._tag ~= "Type.Nominal"
       or source.fqtn ~= target.fqtn then
        return false, nil
    end

    local source_args, target_args = source.args or {}, target.args or {}
    if #source_args == 0 and #target_args == 0 then return false, nil end
    if #source_args ~= #target_args then return true, false end
    if types.equals(source, target) then return false, nil end

    local owner = types.registry[source.fqtn]
    for index = 1, #source_args do
        local typeparam = owner and owner.typeparams
            and owner.typeparams[index] or nil
        local consistent = checker._generic.surface_argument_consistent(
            source_args[index], target_args[index], typeparam, owner,
            source_args, target_args, st)
        if not consistent then return true, false end
    end

    return true, {
        kind = "identity",
        source = source,
        target = target,
    }
end

local function checker_assignment_adjustment(source, target, st, options)
    st = st or active_check_state
    local applied, application_plan =
        checker._generic.applied_nominal_adjustment(source, target, st)
    if applied then return application_plan, nil, nil end
    if source._tag == "Type.Option" or target._tag == "Type.Option" then
        local source_base = source._tag == "Type.Option" and source.base or source
        local target_base = target._tag == "Type.Option" and target.base or target
        local inner_applied, inner_plan =
            checker._generic.applied_nominal_adjustment(
                source_base, target_base, st)
        if inner_applied then
            if not inner_plan then return nil, nil, nil end
            return checker_assignment_adjustment(
                types.erase(source), types.erase(target), st, options)
        end
    end

    -- Rigid transport to or from the binder's own erased constraint is a
    -- representation identity at the generic surface. Distinct parameters do
    -- not become assignable merely because their carriers happen to match.
    local source_carrier = checker._generic.rigid_parameter_carrier(source)
    local target_carrier = checker._generic.rigid_parameter_carrier(target)
    if source_carrier and not target_carrier
       and types.equals(source_carrier, target) then
        return { kind = "identity", source = source, target = target }, nil, nil
    elseif target_carrier and not source_carrier
       and types.equals(source, target_carrier) then
        return { kind = "identity", source = source, target = target }, nil, nil
    elseif target_carrier and not source_carrier
       and (source._tag == "Type.Value" or types.is_c_tvalue(source)) then
        return checker_assignment_adjustment(
            source, target_carrier, st, options)
    elseif source_carrier and not target_carrier
       and (target._tag == "Type.Value" or types.is_c_tvalue(target)) then
        return checker_assignment_adjustment(
            source_carrier, target, st, options)
    elseif types.contains_generic(source)
       and (target._tag == "Type.Value" or types.is_c_tvalue(target)) then
        return checker_assignment_adjustment(
            types.erase(source), target, st, options)
    elseif types.contains_generic(target)
       and (source._tag == "Type.Value" or types.is_c_tvalue(source)) then
        return checker_assignment_adjustment(
            source, types.erase(target), st, options)
    end
    if not st then
        return types.assignment_adjustment(source, target, options),
            nil, nil
    end
    local policy = interface_relation_policy(st, options)
    local adjustment =
        types.assignment_adjustment(source, target, policy)
    local conversion = adjustment
        and make_interface_conversion(
            source, target, adjustment)
        or nil
    if conversion then
        adjustment.interface_conversion = conversion
    end
    return adjustment, conversion,
        policy.interface_failure or nil
end

local function report_interface_failure(errors, loc, failure)
    if not failure then return false end
    local concrete = failure.concrete
    local interface = failure.interface
    if not concrete or not interface then return false end
    local concrete_kind = concrete._tag == "Type.Union"
        and "union" or "record"
    local prefix = string.format(
        "%s '%s' does not implement interface '%s'",
        concrete_kind, concrete.name, interface.name)
    if failure.reason == "missing" then
        checker.typeerror(errors, loc,
            "%s: method '%s' is missing",
            prefix, failure.name)
    elseif failure.reason == "not_method" then
        checker.typeerror(errors, loc,
            "%s: member '%s' is not a method",
            prefix, failure.name)
    elseif failure.reason == "inaccessible" then
        checker.typeerror(errors, loc,
            "%s: method '%s' is local to module '%s'",
            prefix, failure.name,
            nominal_module(failure.member.fqtn))
    elseif failure.reason == "incompatible" then
        checker.typeerror(errors, loc,
            "%s: method '%s' has incompatible type '%s'; expected '%s'",
            prefix, failure.name,
            types.tostring(failure.concrete_type),
            types.tostring(failure.required_type))
    else
        checker.typeerror(errors, loc,
            "%s: interface implementation could not be validated",
            prefix)
    end
    return true
end

local function interface_method_index(interface, name)
    for index, method in ipairs(interface.methods or {}) do
        if method.name == name then return index - 1 end
    end
    return nil
end

-- Generic applications are surface-only checker types. The owner registry keeps
-- one declaration descriptor; an application substitutes its immutable binder
-- scope into a fresh view for field, variant, and method lookup.
function checker._generic.generic_owner_type(typ)
    if not typ then return nil end
    if typ._tag == "Type.Nominal" then
        return types.registry[typ.fqtn]
    elseif typ._tag == "Type.Record" or typ._tag == "Type.Union"
        or typ._tag == "Type.Interface" then
        return typ
    end
end

function checker._generic.generic_parameter_arguments(owner)
    local arguments = {}
    if owner and owner.scope ~= false then
        for index, typeparam in ipairs(owner.typeparams or {}) do
            arguments[index] = owner._generic_parameters
                and owner._generic_parameters[index]
                or types.Parameter(owner.scope, index, typeparam.name, false)
        end
    end
    return arguments
end

function checker._generic.generic_substitute(typ, scope, arguments, errors, loc, subject)
    local ok, result = pcall(types.substitute, typ, scope, arguments)
    if ok then return result end
    checker.typeerror(errors, loc, "%s: %s", subject, tostring(result))
    return nil
end

function checker._generic.applied_owner_view(nominal, errors, loc)
    local owner = checker._generic.generic_owner_type(nominal)
    if not owner or owner.scope == false then return owner end
    local arguments = nominal.args or {}
    if #arguments ~= #(owner.typeparams or {}) then return owner end
    local ok, view = pcall(types.substitute, owner, owner.scope, arguments)
    if ok then return view end
    if errors and loc then
        checker.typeerror(errors, loc,
            "cannot form applied type '%s': %s",
            types.tostring(nominal), tostring(view))
    end
    return owner
end

function checker._generic.interface_implementation(
        concrete, interface, policy)
    return types.generic_interface_implementation(concrete, interface, policy)
end

function checker._generic.generic_constraint_satisfied(
        argument, constraint, st, policy)
    if argument._tag == "Type.Parameter" then
        local binders = st and st.generic_scope_bindings
            and st.generic_scope_bindings[argument.scope]
        local declared = binders and binders[argument.index]
        if not declared and policy then
            local binding = checker._generic.recovered_scope_binding(
                policy, argument.scope)
            declared = binding and binding.typeparams[argument.index]
        end
        return declared and declared.constraint ~= false
            and types.alpha_equals(declared.constraint, constraint)
    elseif argument._tag ~= "Type.Nominal" then
        return false
    elseif types.equals(argument, constraint) then
        return true
    end

    local concrete = checker._generic.generic_owner_type(argument)
    local interface = checker._generic.generic_owner_type(constraint)
    if not concrete or not interface
        or (concrete._tag ~= "Type.Record" and concrete._tag ~= "Type.Union")
        or interface._tag ~= "Type.Interface" then
        return false
    end
    if concrete._generic_header or interface._generic_header
       or (st and st.generic_signatures_incomplete) then
        return nil -- method sets are not complete yet; validate after signatures
    end
    concrete = checker._generic.applied_owner_view(argument)
    interface = checker._generic.applied_owner_view(constraint)
    if not policy then
        policy = {
            visibility = st.modname,
            method_visible = function(method)
                return is_nominal_member_visible_from(st, method)
            end,
        }
    end
    local implementation = checker._generic.interface_implementation(
        concrete, interface, policy)
    return implementation ~= false
end

function checker._generic.defer_constraint_application(
        scope, typeparams, arguments, st, loc, subject)
    st.pending_generic_constraints = st.pending_generic_constraints or {}
    st.pending_generic_constraints[#st.pending_generic_constraints + 1] = {
        scope = scope,
        typeparams = typeparams,
        arguments = arguments,
        loc = loc,
        subject = subject,
    }
end

function checker._generic.validate_binder_arguments(scope, typeparams, arguments,
                                         st, errors, loc, subject,
                                         allow_defer)
    local valid, argument_error =
        types.validate_type_arguments(typeparams or {}, arguments or {})
    if not valid then
        checker.typeerror(errors, loc, "%s %s", subject, argument_error)
        return false
    end

    -- Owner headers share their dense type-parameter list with the later
    -- completed descriptor. While those headers' constraints are being
    -- resolved, even a currently unconstrained entry may acquire its real
    -- constraint later in the same reservation pass. Queue the whole
    -- application once and validate it only after all declarations and method
    -- sets are complete.
    if allow_defer and st.resolving_generic_owner_constraints
       and #(typeparams or {}) > 0 then
        checker._generic.defer_constraint_application(
            scope, typeparams, arguments, st, loc, subject)
        return true
    end

    local ok = true
    local deferred = false
    for index, typeparam in ipairs(typeparams or {}) do
        if typeparam.constraint ~= false then
            local constraint = typeparam.constraint
            if scope ~= false then
                constraint = checker._generic.generic_substitute(
                    constraint, scope, arguments, errors, loc, subject)
                    or constraint
            end
            local satisfied = checker._generic.generic_constraint_satisfied(
                arguments[index], constraint, st)
            if satisfied == nil and allow_defer then
                deferred = true
            elseif not satisfied then
                checker.typeerror(errors, loc,
                    "type argument %d ('%s') for %s does not satisfy constraint '%s'",
                    index, types.tostring(arguments[index]), subject,
                    types.tostring(constraint))
                ok = false
            end
        end
    end
    if deferred then
        checker._generic.defer_constraint_application(
            scope, typeparams, arguments, st, loc, subject)
    end
    return ok
end

function checker._generic.resolve_type_argument_nodes(nodes, st, errors)
    local arguments = {}
    for index, typenode in ipairs(nodes or {}) do
        arguments[index] = typefromnode(typenode, st, errors)
    end
    return arguments
end

function checker._generic.validate_owner_reconstruction(
        owner, arguments, st, errors, loc, subject, allow_defer)
    if owner.scope == false then return true end
    if allow_defer and (owner._generic_header
            or (st and st.generic_signatures_incomplete)) then
        st.pending_generic_reconstructions =
            st.pending_generic_reconstructions or {}
        st.pending_generic_reconstructions[
            #st.pending_generic_reconstructions + 1] = {
                fqtn = owner.name,
                arguments = arguments,
                loc = loc,
                subject = subject,
            }
        return true
    end
    local closed = checker._generic.generic_substitute(
        owner, owner.scope, arguments, errors, loc,
        "cannot form " .. subject)
    return closed ~= nil
end

function checker._generic.application_arguments(
        typearg_nodes, count, st, errors)
    if #(typearg_nodes or {}) == 0 and count > 0 then
        local arguments = {}
        for index = 1, count do arguments[index] = types.Value() end
        return arguments
    end
    return checker._generic.resolve_type_argument_nodes(
        typearg_nodes, st, errors)
end

function checker._generic.apply_named_owner(
        owner, typearg_nodes, st, errors, loc, subject)
    local count = #(owner.typeparams or {})
    local arguments = checker._generic.application_arguments(
        typearg_nodes, count, st, errors)

    if #arguments ~= count then
        checker.typeerror(errors, loc,
            "%s expected %d type arguments but found %d",
            subject, count, #arguments)
        return types.Nominal(owner.name, arguments)
    end
    local valid = checker._generic.validate_binder_arguments(
        owner.scope, owner.typeparams, arguments,
        st, errors, loc, subject, true)
    if valid then
        checker._generic.validate_owner_reconstruction(
            owner, arguments, st, errors, loc, subject, true)
    end
    return types.Nominal(owner.name, arguments)
end

function checker._generic.apply_generic_alias(
        alias, typearg_nodes, st, errors, loc, subject)
    local owner = types.registry[alias.target_owner_fqtn]
    if not owner or (owner._tag ~= "Type.Record"
            and owner._tag ~= "Type.Union"
            and owner._tag ~= "Type.Interface") then
        return invalid(errors, loc,
            "%s does not have a recoverable nominal owner", subject)
    end

    local count = #(owner.typeparams or {})
    local arguments = checker._generic.application_arguments(
        typearg_nodes, count, st, errors)
    if #arguments ~= count then
        return invalid(errors, loc,
            "%s expected %d type arguments but found %d",
            subject, count, #arguments)
    end
    local valid = checker._generic.validate_binder_arguments(
        owner.scope, owner.typeparams, arguments,
        st, errors, loc, subject, true)
    if valid then
        checker._generic.validate_owner_reconstruction(
            owner, arguments, st, errors, loc, subject, true)
    end
    return types.Nominal(owner.name, arguments)
end

function checker._generic.resolve_local_owner(name, st)
    local declaration = st:find_symbol(name)
    if declaration and (declaration._tag == "Ast.TopLevelRecord"
            or declaration._tag == "Ast.TopLevelUnion") then
        return declaration._type
    end
    local interface = st.interface_declarations
        and st.interface_declarations[name]
    if interface then return interface._type end
    return types.registry[st.modname .. "." .. name]
end

function checker._foreign_signature_component(
        typenode, st, errors, subject, allow_void)
    local typ = typefromnode(typenode, st, errors, true)
    local resolved = c_resolve(typ)
    if typ._tag == "Type.Invalid" then return typ end
    if not types.is_direct_c(typ) or not resolved
       or resolved._tag == "Type.CModule"
       or resolved._tag == "Type.COwned"
       or resolved._tag == "Type.CFunction"
       or resolved._tag == "Type.CArray"
       or (resolved._tag == "Type.CVoid" and not allow_void) then
        return invalid(errors, typenode.loc,
            "%s must be a direct C FFI type%s, not '%s'",
            subject, allow_void and "" or " other than void",
            types.tostring(typ))
    end
    return typ
end

function checker._foreign_function_signature(
        argnodes, rettypenodes, varargtype, flexrettype,
        st, errors, subject)
    local params = {}
    for index, typenode in ipairs(argnodes) do
        params[index] = checker._foreign_signature_component(
            typenode, st, errors,
            string.format("parameter %d of %s", index, subject), false)
    end

    if varargtype then
        checker.typeerror(errors, varargtype.loc,
            "%s cannot have variadic parameters", subject)
    end
    if flexrettype then
        checker.typeerror(errors, flexrettype.loc,
            "%s cannot have flexible returns", subject)
    end
    if #rettypenodes > 1 then
        checker.typeerror(errors, rettypenodes[2].loc,
            "%s can return at most one value", subject)
    end

    local ret = types.CVoid()
    if rettypenodes[1] then
        ret = checker._foreign_signature_component(
            rettypenodes[1], st, errors,
            "return type of " .. subject, false)
    end
    return types.CFunction(params, ret, false, false)
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

    ["Ast.TypeName"] = function(node, st, errors,
                                    defer_c_enum_carrier)
        local parameter = st:find_type_parameter(node.name)
        if parameter then
            if #(node.typeargs or {}) > 0 then
                return invalid(errors, node.loc,
                    "type parameter '%s' cannot be applied to type arguments",
                    node.name)
            end
            return parameter
        end

        local alias = st:find_type_alias(node.name)
        if alias then
            local typ = resolve_type_alias(alias, st, errors)
            if typ._tag == "Type.GenericAlias" then
                return checker._generic.apply_generic_alias(
                    typ, node.typeargs, st, errors, node.loc,
                    "type alias '" .. node.name .. "'")
            elseif #(node.typeargs or {}) > 0 then
                return invalid(errors, node.loc,
                    "type alias '%s' is not a generic type constructor",
                    node.name)
            end
            if checker._ensure_c_enum_supported(
                    st, typ, node.loc, errors, nil,
                    defer_c_enum_carrier and true or false) then
                return typ
            end
            return types.Invalid()
        end

        local owner = checker._generic.resolve_local_owner(node.name, st)
        if owner and (owner._tag == "Type.Record"
                or owner._tag == "Type.Union"
                or owner._tag == "Type.Interface") then
            return checker._generic.apply_named_owner(owner, node.typeargs, st, errors,
                node.loc, "type '" .. node.name .. "'")
        end
        if #(node.typeargs or {}) > 0 then
            return invalid(errors, node.loc,
                "type '%s' is not a generic nominal or interface", node.name)
        end
        return types.Nominal(st.modname .. "." .. node.name)
    end,

    ["Ast.TypeQualName"] = function(node, st, errors,
                                        defer_c_enum_carrier)
        local mod = st:find_symbol(node.module)
        if node._contextual_c_name and mod and mod._type
           and mod._type._tag ~= "Type.CModule" then
            return invalid(errors, node.loc,
                "Titan keyword '%s' is only contextual for a C type",
                node.name)
        end
        if mod and mod._type and mod._type._tag == "Type.Module" then
            local type_member = types.module_type_member(
                mod._type, node.name, mod._source_import)
            local subject = "type '" .. mod._type.name .. "." ..
                node.name .. "'"
            if type_member and type_member._tag == "Type.GenericAlias" then
                local owner = types.registry[type_member.target_owner_fqtn]
                if owner and not is_nominal_visible_from(st, owner.name) then
                    return invalid(errors, node.loc,
                        "nominal type '%s' is local to module '%s'",
                        owner.name, mod._type.name)
                end
                return checker._generic.apply_generic_alias(
                    type_member, node.typeargs, st, errors,
                    node.loc, subject)
            elseif type_member and type_member._tag == "Type.Interface" then
                if not is_nominal_visible_from(st, type_member.name) then
                    return invalid(errors, node.loc,
                        "interface type '%s' is local to module '%s'",
                        node.name, mod._type.name)
                end
                return checker._generic.apply_named_owner(
                    type_member, node.typeargs, st, errors,
                    node.loc, subject)
            elseif type_member then
                -- A non-GenericAlias type member is a concrete transparent
                -- alias. It has zero constructor arity even when its Nominal
                -- target is an applied generic owner.
                if #(node.typeargs or {}) > 0 then
                    return invalid(errors, node.loc,
                        "type alias '%s.%s' is not a generic type constructor",
                        node.module, node.name)
                elseif type_member._tag == "Type.Nominal"
                   and not is_nominal_visible_from(st, type_member.fqtn) then
                    return invalid(errors, node.loc,
                        "nominal type '%s' is local to module '%s'",
                        type_member.fqtn, mod._type.name)
                end
                if checker._ensure_c_enum_supported(
                        st, type_member, node.loc, errors, nil,
                        defer_c_enum_carrier and true or false) then
                    return type_member
                end
                return types.Invalid()
            end

            local fqtn = mod._type.name .. "." .. node.name
            local member = types.module_member(
                mod._type, node.name, mod._source_import)
            if not member then
                return invalid(errors, node.loc,
                    "type '%s' not found inside module '%s'",
                    node.name, mod._type.name)
            elseif member.type._tag ~= "Type.Record"
               and member.type._tag ~= "Type.Union" then
                return invalid(errors, node.loc,
                    "member '%s' inside module '%s' is not a nominal type",
                    node.name, mod._type.name)
            elseif not is_nominal_visible_from(st, fqtn) then
                return invalid(errors, node.loc,
                    "%s type '%s' is local to module '%s'",
                    member.type._tag == "Type.Record" and "record" or "union",
                    node.name, mod._type.name)
            end
            return checker._generic.apply_named_owner(member.type, node.typeargs,
                st, errors, node.loc, "type '" .. fqtn .. "'")
        elseif mod and mod._type and mod._type._tag == "Type.CModule" then
            local typ = mod._type.type_members
                and mod._type.type_members[node.name]
            if typ then
                if #(node.typeargs or {}) > 0 then
                    return invalid(errors, node.loc,
                        "C type '%s' cannot be applied to type arguments",
                        node.name)
                end
                if checker._ensure_c_enum_supported(
                        st, typ, node.loc, errors, nil,
                        defer_c_enum_carrier and true or false) then
                    return typ
                end
                return types.Invalid()
            end
            return invalid(errors, node.loc,
                "C type '%s' not found inside foreign module '%s'",
                node.name, mod._type.name)
        elseif mod and mod._type and mod._type._tag == "Type.Union" then
            local member = mod._type.variants[node.name]
                or mod._type.functions[node.name]
                or mod._type.methods[node.name]
            if member then
                return invalid(errors, node.loc,
                    "union member '%s.%s' is not a type; use union type '%s' "
                    .. "or a case statement",
                    node.module, node.name, node.module)
            end
        end
        return invalid(errors, node.loc,
            "module '%s' referenced by type not found", node.module)
    end,

    ["Ast.TypeCPointer"] = function(node, st, errors)
        -- Forming a pointer needs only an exact pointee spelling. It does not
        -- carry an enum value and therefore must not force a wide-enum carrier.
        local pointee = typefromnode(node.subtype, st, errors, true)
        local resolved = c_resolve(pointee)
        if not types.is_direct_c(pointee)
           or (resolved and resolved._tag == "Type.COwned") then
            return invalid(errors, node.loc,
                "C pointer type can only point to a C FFI type, not '%s'",
                types.tostring(pointee))
        end
        return types.CPointer(pointee, node.const and { "const" } or {})
    end,

    ["Ast.TypeCArray"] = function(node, st, errors)
        -- Exact C array storage needs element spelling, not a numeric carrier.
        local elem = typefromnode(node.base, st, errors, true)
        local resolved = c_resolve(elem)
        if not types.is_direct_c(elem)
           or (resolved and resolved._tag == "Type.COwned") then
            elem = invalid(errors, node.base.loc or node.loc,
                "fixed C array element type must be a C FFI type, not '%s'",
                types.tostring(elem))
        end
        local len = node.length and node.length.value
        return types.CArray(elem, len)
    end,

    ["Ast.TypeCOwned"] = function(node, st, errors)
        -- Owned storage renders/allocates the exact payload but does not box an
        -- enum value until a later payload access.
        local payload = typefromnode(node.subtype, st, errors, true)
        if payload._tag == "Type.Invalid" then
            return payload
        end
        local alloc_err = c_allocation_error(payload, st)
        if alloc_err then
            return invalid(errors, node.loc, alloc_err)
        end
        return types.COwned(payload, node.count and true or false)
    end,

    ["Ast.TypeArray"] = function(node, st, errors,
                                     defer_c_enum_carrier)
        return types.Array(deoptionize(typefromnode(
            node.subtype, st, errors, defer_c_enum_carrier)))
    end,

    ["Ast.TypeMap"] = function(node, st, errors,
                                   defer_c_enum_carrier)
        local key = typefromnode(
            node.keystype, st, errors, defer_c_enum_carrier)
        if key._tag == "Type.Nil" then
            checker.typeerror(errors, node.loc, "type of map key cannot be nil", node.module)
            key = types.Invalid()
        elseif key._tag == "Type.Option" then
            checker.typeerror(errors, node.loc, "type of map key cannot be option type", node.module)
            key = deoptionize(key)
        end
        return types.Map(key,
            deoptionize(typefromnode(
                node.valuestype, st, errors, defer_c_enum_carrier)))
    end,

    ["Ast.TypeForeignFunction"] = function(node, st, errors)
        local cfunction = checker._foreign_function_signature(
            node.argtypes, node.rettypes, node.varargtype,
            node.flexrettype, st, errors, "foreign function type")
        return types.CPointer(cfunction, {})
    end,

    ["Ast.TypeFunction"] = function(node, st, errors,
                                        defer_c_enum_carrier)
        -- First-class function type `(P...) -> (R...)`. argtypes and rettypes
        -- are lists of type nodes; a nested arrow (`a -> b -> c`, right
        -- associative) shows up as a TypeFunction inside rettypes and recurses.
        local ptypes = {}
        for _, pt in ipairs(node.argtypes) do
            table.insert(ptypes, typefromnode(
                pt, st, errors, defer_c_enum_carrier))
        end
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(
                rt, st, errors, defer_c_enum_carrier))
        end
        -- A first-class variadic function type `(P..., ...: t) -> (R...)` carries
        -- its element type node on `node.varargtype` (false when absent); set
        -- the resulting Type.Function's `varargtype` slot accordingly.
        local varargtype = node.varargtype
            and check_varg_elem(typefromnode(
                node.varargtype, st, errors, defer_c_enum_carrier),
                                node.varargtype.loc, errors, "parameter")
            or false
        local flexrettype = flexible_return_type(
            node, st, errors, defer_c_enum_carrier)
        return types.Function(ptypes, rettypes, false, varargtype, flexrettype)
    end,

    ["Ast.TypeOption"] = function(node, st, errors,
                                      defer_c_enum_carrier)
        local typ = optionize(typefromnode(
            node.basetype, st, errors, defer_c_enum_carrier))
        if typ._tag == "Type.Option"
           and not types.has_tvalue_representation(typ.base) then
            return invalid(errors, node.loc,
                "option type cannot contain '%s' because it has no TValue representation",
                types.tostring(typ.base))
        end
        return typ
    end
})

function checker._generic.generic_scope_for_node(node, st, owner)
    local owner_fqtn = owner and owner._type and owner._type.name or false
    local tag = node._tag
    local role, kind
    if tag == "Ast.TopLevelRecord" then
        role, kind, owner_fqtn = "owner", "record", st.modname .. "." .. node.name
    elseif tag == "Ast.TopLevelUnion" then
        role, kind, owner_fqtn = "owner", "union", st.modname .. "." .. node.name
    elseif tag == "Ast.TopLevelInterface" then
        role, kind, owner_fqtn = "owner", "interface", st.modname .. "." .. node.name
    elseif tag == "Ast.TopLevelMethod" then
        role, kind = "method", "method"
    elseif tag == "Ast.TopLevelStatic" then
        role, kind = "static", "static"
    elseif tag == "Ast.InterfaceMethod" then
        role, kind = "method", "method"
    else
        role, kind, owner_fqtn = "function", "function", false
    end
    local callable_name = false
    if role ~= "owner" then callable_name = node.name end
    return types.GenericScope(st.modname, owner_fqtn,
        callable_name, role, kind)
end

function checker._generic.reserve_generic_binders(node, scope, st, errors)
    if node._generic_bindings then return end
    node._generic_scope = scope
    node._generic_bindings = {}
    node._generic_parameters = {}
    node._generic_typeparams = {}

    local active_names = {}
    for index, typeparam in ipairs(node.typeparams or {}) do
        local name = typeparam.name
        local active = st:find_type_parameter(name)
        if active then
            checker.typeerror(errors, typeparam.loc,
                "type parameter '%s' cannot shadow an active owner type parameter",
                name)
        elseif active_names[name] then
            checker.typeerror(errors, typeparam.loc,
                "duplicate type parameter '%s' in declaration '%s'",
                name, tostring(node.name))
        else
            active_names[name] = true
        end
        local parameter = types.Parameter(scope, index, name, false)
        node._generic_parameters[index] = parameter
        if not node._generic_bindings[name] then
            node._generic_bindings[name] = parameter
        end
        node._generic_typeparams[index] = types.TypeParameter(name, false)
        typeparam._type = parameter
    end
    st.generic_scope_bindings[scope] = node._generic_typeparams
end

function checker._generic.collect_local_constraint_parameters(
        typ, scope, found, seen)
    if type(typ) ~= "table" or not typ._tag then return end
    seen = seen or {}
    if seen[typ] then return end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Parameter" then
        if types.same_generic_scope(typ.scope, scope) then
            found[typ.index] = true
        end
        -- The referenced binder's own constraint is a graph edge handled by
        -- the caller, not a structural child of this occurrence.
    elseif tag == "Type.Nominal" then
        for _, argument in ipairs(typ.args or {}) do
            checker._generic.collect_local_constraint_parameters(
                argument, scope, found, seen)
        end
    elseif tag == "Type.Option" then
        checker._generic.collect_local_constraint_parameters(
            typ.base, scope, found, seen)
    elseif tag == "Type.Array" then
        checker._generic.collect_local_constraint_parameters(
            typ.elem, scope, found, seen)
    elseif tag == "Type.Map" then
        checker._generic.collect_local_constraint_parameters(
            typ.keys, scope, found, seen)
        checker._generic.collect_local_constraint_parameters(
            typ.values, scope, found, seen)
    elseif tag == "Type.Function" then
        for _, parameter in ipairs(typ.params or {}) do
            checker._generic.collect_local_constraint_parameters(
                parameter, scope, found, seen)
        end
        for _, result in ipairs(typ.rettypes or {}) do
            checker._generic.collect_local_constraint_parameters(
                result, scope, found, seen)
        end
        if typ.varargtype then
            checker._generic.collect_local_constraint_parameters(
                typ.varargtype, scope, found, seen)
        end
        if typ.flexrettype then
            checker._generic.collect_local_constraint_parameters(
                typ.flexrettype, scope, found, seen)
        end
    elseif tag == "Type.Typedef" then
        checker._generic.collect_local_constraint_parameters(
            typ._type, scope, found, seen)
    elseif tag == "Type.CTypedef" then
        checker._generic.collect_local_constraint_parameters(
            typ.target, scope, found, seen)
    end
end

function checker._generic.reject_constraint_cycles(node, errors)
    local count = #(node._generic_typeparams or {})
    if count == 0 or node._generic_scope == false then return end

    local edges = {}
    for index, typeparam in ipairs(node._generic_typeparams) do
        edges[index] = {}
        if typeparam.constraint ~= false then
            checker._generic.collect_local_constraint_parameters(
                typeparam.constraint, node._generic_scope, edges[index])
        end
    end

    local state, stack, position, cyclic = {}, {}, {}, {}
    local function visit(index)
        state[index] = 1
        stack[#stack + 1] = index
        position[index] = #stack
        for target = 1, count do
            if edges[index][target] then
                if state[target] == nil then
                    visit(target)
                elseif state[target] == 1 then
                    for slot = position[target], #stack do
                        cyclic[stack[slot]] = true
                    end
                end
            end
        end
        position[index] = nil
        stack[#stack] = nil
        state[index] = 2
    end
    for index = 1, count do
        if state[index] == nil then visit(index) end
    end

    local names, first_loc = {}, nil
    for index = 1, count do
        if cyclic[index] then
            local syntax = node.typeparams[index]
            names[#names + 1] = "'" .. syntax.name .. "'"
            first_loc = first_loc
                or (syntax.constraint and syntax.constraint.loc)
                or syntax.loc
            -- Recover as an unconstrained binder after the declaration error;
            -- this breaks the carrier cycle for later graph walks.
            node._generic_typeparams[index] =
                types.TypeParameter(syntax.name, false)
            node._generic_parameters[index].erased_constraint = false
        end
    end
    if #names > 0 then
        checker.typeerror(errors, first_loc or node.loc,
            "cyclic type parameter constraints involving %s",
            table.concat(names, ", "))
    end
end

function checker._generic.resolve_generic_constraints(node, st, errors)
    if node._generic_constraints_resolved then return end
    node._generic_constraints_resolved = true
    st:push_generic_type_scope(node._generic_bindings)
    for index, syntax in ipairs(node.typeparams or {}) do
        local constraint = false
        if syntax.constraint then
            local resolved = typefromnode(syntax.constraint, st, errors)
            local owner = checker._generic.generic_owner_type(resolved)
            if resolved._tag ~= "Type.Nominal" or not owner
               or owner._tag ~= "Type.Interface" then
                checker.typeerror(errors, syntax.constraint.loc or syntax.loc,
                    "constraint of type parameter '%s' must be an Interface application, found '%s'",
                    syntax.name, types.tostring(resolved))
            else
                constraint = resolved
            end
        end
        node._generic_typeparams[index] =
            types.TypeParameter(syntax.name, constraint)
    end
    checker._generic.reject_constraint_cycles(node, errors)
    -- Every same-scope binder is reserved before constraints resolve, so a
    -- forward acyclic constraint may depend on a later binder's carrier.
    -- Iterate the finite dependency DAG after cycle recovery until every
    -- recursively erased Interface application is stable.
    for _ = 1, math.max(1, #(node.typeparams or {})) do
        local changed = false
        for index, typeparam in ipairs(node._generic_typeparams) do
            local carrier = typeparam.constraint == false and false
                or types.erase_constraint(typeparam.constraint)
            local previous = node._generic_parameters[index].erased_constraint
            if (previous == false) ~= (carrier == false)
               or (carrier ~= false
                   and not types.equals(previous, carrier)) then
                node._generic_parameters[index].erased_constraint = carrier
                changed = true
            end
        end
        if not changed then break end
    end
    st:pop_generic_type_scope()
end

function checker._generic.prepare_generic_binders(node, st, errors, owner)
    if #(node.typeparams or {}) == 0 then
        node._generic_scope = false
        node._generic_bindings = node._generic_bindings or {}
        node._generic_parameters = node._generic_parameters or {}
        node._generic_typeparams = node._generic_typeparams or {}
        node._generic_constraints_resolved = true
        return
    end
    local scope = node._generic_scope or checker._generic.generic_scope_for_node(node, st, owner)
    checker._generic.reserve_generic_binders(node, scope, st, errors)
    checker._generic.resolve_generic_constraints(node, st, errors)
end

function checker._generic.with_generic_binding_map(st, bindings, body, ...)
    if not bindings or next(bindings) == nil then
        return body(...)
    end
    st:push_generic_type_scope(bindings)
    local results = table.pack(body(...))
    st:pop_generic_type_scope()
    return table.unpack(results, 1, results.n)
end

function checker._generic.with_owner_bindings(owner, st, body, ...)
    return checker._generic.with_generic_binding_map(
        st, owner and owner._generic_bindings, body, ...)
end

function checker._generic.with_declaration_bindings(node, st, body, ...)
    local owner = node._nominal_owner
    local function with_local(...)
        return checker._generic.with_generic_binding_map(
            st, node._generic_bindings, body, ...)
    end
    return checker._generic.with_owner_bindings(owner, st, with_local, ...)
end

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
        and types.is_direct_c(source._type)
end

local function mark_mutable_c_address_source(source)
    if source._tag == "Ast.ExpVar" and source.var._tag == "Ast.VarName"
       and source.var._decl then
        source.var._decl._assigned = true
        source.var._decl._c_address_taken = source.loc
    end
end

local function c_pointer_is_const(target)
    target = types.resolve_c_typedef(target)
    if not target or target._tag ~= "Type.CPointer" then return false end
    return types.c_pointer_has_qual(target, "const")
end

local function failed_c_adjustment(source, target)
    local n = ast.ExpCast(source.loc, source, target)
    n._implicit_coercion = true
    n._c_conversion_failed = true
    n._type = target
    return n
end

local function pointer_category_diagnostic(
        source_pointer, target, errors, loc, use)
    local source_category = types.c_pointer_category(source_pointer)
    local target_category = types.c_pointer_category(target)
    if not source_category or not target_category
       or source_category == target_category then
        return false
    end
    if (source_category == "object" and target_category == "function")
       or (source_category == "function"
           and target_category == "object") then
        checker.typeerror(errors, loc,
            "cannot convert %s pointer '%s' to %s pointer '%s'%s",
            source_category, types.tostring(source_pointer),
            target_category, types.tostring(target),
            use and (" in " .. use) or "")
        return true
    end
    return false
end

-- Validate one contextual or explicit object-pointer reinterpretation. Returns
-- a conversion annotation on success, nil when this is not an unsafe pointer
-- relation, and false after emitting a definitive diagnostic.
function checker._unsafe_c_pointer_conversion(
        source, target, errors, use)
    if types.equals(types.resolve_c_typedef(source._type),
                    types.resolve_c_typedef(target)) then
        return nil
    end

    local source_pointer = source._type
    local conversion_kind = "unsafe_object_pointer"
    local address_source = false
    local source_res = types.resolve_c_typedef(source._type)

    -- An array expression always reaches a pointer conversion through ordinary
    -- C decay, regardless of whether it names a local or an imported object.
    -- Keep it distinct from struct/union local-address adjustment: codegen casts
    -- the decayed expression and must never synthesize `&array`.
    if source_res and source_res._tag == "Type.CArray" then
        source_pointer = assert(types.c_local_address_pointer(source._type))
    end

    local candidate = types.c_unsafe_object_pointer_candidate(
        source_pointer, target)
    if not candidate and source_res
       and source_res._tag ~= "Type.CArray"
       and is_mutable_c_address_source(source) then
        local natural_pointer =
            types.c_local_address_pointer(source._type)
        if natural_pointer then
            source_pointer = natural_pointer
            candidate = types.c_unsafe_object_pointer_candidate(
                source_pointer, target)
            if candidate then
                conversion_kind =
                    "address_then_unsafe_object_pointer"
                address_source = true
            end
        end
    end

    local discarded =
        types.c_discarded_pointer_qualifier(source_pointer, target)
    if discarded then
        checker.typeerror(errors, source.loc,
            "unsafe C conversion from '%s' to '%s' would discard %s%s",
            types.tostring(source_pointer), types.tostring(target),
            discarded, use and (" in " .. use) or "")
        return false
    end

    if not candidate then
        if pointer_category_diagnostic(
                source_pointer, target, errors, source.loc, use) then
            return false
        end
        return nil
    end

    local st = active_check_state
    local module_probe, probe_error
    if st then
        module_probe, probe_error = checker._probe_for_c_types(
            st, { source_pointer, target })
    else
        probe_error = "no active checker context"
    end
    if not module_probe then
        checker.typeerror(errors, source.loc,
            "cannot validate C conversion because the probe service " ..
            "could not be configured%s: %s",
            use and (" for " .. use) or "", tostring(probe_error))
        return false
    end

    local result = module_probe:probe_unsafe_object_pointer(
        source_pointer, target)
    if result.status ~= "success" then
        checker.typeerror(errors, source.loc, "%s%s",
            result.message or
                "cannot validate the unsafe C object-pointer conversion",
            use and (" in " .. use) or "")
        return false
    end

    if address_source then
        mark_mutable_c_address_source(source)
    end
    return {
        kind = conversion_kind,
        source = source_pointer,
        target = target,
        probe_key = result.key,
    }
end

local function adjust_unsafe_c_pointer(source, target, errors, use)
    local conversion = checker._unsafe_c_pointer_conversion(
        source, target, errors, use)
    if not conversion then
        return conversion == false
            and failed_c_adjustment(source, target) or source
    end
    local n = ast.ExpCast(source.loc, source, target)
    n._implicit_coercion = true
    n._c_conversion = conversion
    n._type = target
    return n
end

local function trycoerce(source, target, errors, use,
                         precomputed_adjustment)
    if is_mutable_c_address_source(source)
       and types.c_mutable_address_coerceable(source._type, target)
       and not types.c_address_coerceable(source._type, target) then
        mark_mutable_c_address_source(source)
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = {
            kind = "direct_coercion",
            source = source._type,
            target = target,
            coercion = {
                kind = "coercion",
                op = "mutable_c_address",
                source = source._type,
                target = target,
            },
        }
        n._type = target
        return n, n._adjustment
    end

    local adjustment = precomputed_adjustment
    local interface_conversion =
        adjustment and adjustment.interface_conversion or nil
    local interface_failure
    if adjustment == nil then
        adjustment, interface_conversion, interface_failure =
            checker_assignment_adjustment(
                source._type, target, active_check_state)
    end
    if not adjustment then
        if report_interface_failure(
                errors, source.loc, interface_failure) then
            return source, false, true
        end
        -- A raw `value` cannot implicitly establish a C pointee type. Keep the
        -- old unsafe C-object probe for actual C address expressions only.
        if source._type._tag == "Type.Value" then
            return source, false, false
        end
        local adjusted =
            adjust_unsafe_c_pointer(source, target, errors, use)
        if adjusted._c_conversion then
            return adjusted, adjusted._c_conversion, false
        elseif adjusted._c_conversion_failed then
            return adjusted, false, true
        else
            return adjusted, false, false
        end
    elseif adjustment.kind == "identity" then
        return source, adjustment
    elseif adjustment.kind == "callable" then
        -- A non-exact callable edge is an allocating semantic operation even
        -- though both endpoints use TValue representation. Reify the one
        -- already-classified plan as the existing cast node; the child keeps
        -- its actual type and no metadata copy is left to trigger a second
        -- lowering pass.
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = adjustment
        n._callable_adapter = checker.freeze_callable_adapter(
            adjustment, source._type, target, source.loc)
        n._type = target
        return n, adjustment
    elseif adjustment.kind == "gradual_view"
        and adjustment.op == "structural" then
        -- Structural Array/Map views retain their producer type and carry the
        -- complete checker decision on the expression delivered to the sink.
        source._assignment_adjustment = adjustment
        return source, adjustment
    elseif adjustment.kind == "gradual_view" then
        assert(adjustment.op == "inject" or adjustment.op == "project",
            "unknown gradual assignment view")
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = adjustment
        n._interface_conversion = interface_conversion
        n._type = target
        return n, adjustment
    elseif adjustment.kind == "direct_coercion" then
        -- Keep one node for the one checker decision. Option force/wrap/map
        -- plans already carry their inner operation; the coder lowers that
        -- recorded plan without asking the relation again.
        local n = ast.ExpCast(source.loc, source, target)
        n._implicit_coercion = true
        n._adjustment = adjustment
        n._interface_conversion = interface_conversion
        n._type = target
        return n, adjustment
    else
        error("unknown assignment adjustment kind " ..
            tostring(adjustment.kind))
    end
end

local function coerce_and_check(source, target, term, errors, loc,
                                precomputed_adjustment)
    local exp, adjustment, precise_error = trycoerce(
        source, target, errors, term, precomputed_adjustment)
    if adjustment and adjustment.kind ~= "identity" then
        local stored = exp._adjustment
            or exp._assignment_adjustment
            or exp._c_conversion
        assert(stored == adjustment,
            "accepted nonidentity sink lost its checker decision")
    end
    checkmatch(term, target, exp, errors, loc or exp.loc, adjustment,
        precise_error)
    return exp
end

-- force option if present
--    node: expression node
--    returns node wrapped in a coercion, or original node
local function tryforce(node)
    if node._type._tag == "Type.Option" then
        local n = ast.ExpCast(node.loc, node, node._type.base)
        n._implicit_coercion = true
        n._adjustment = assert(types.assignment_adjustment(
            node._type, node._type.base),
            "automatic Option projection lacks an assignment plan")
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
        n._implicit_coercion = true
        n._operator_conversion = {
            kind = "operator_conversion",
            op = "number_to_string",
            source = source,
            target = types.String(),
        }
        n._type = types.String()
        return n
    else
        return node
    end
end

local function nil_can_adjust_to(typ)
    return typ and types.assignment_adjustment(types.Nil(), typ) ~= false
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
    exp = coerce_and_check(exp, target, term, errors, exp.loc)
    if source._missing_value then exp._missing_value = true end
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
        open_adjustment = false,
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


    -- A deferred open consumer has not selected its final element type yet.
    -- In particular, inferred positional constructors deoptionize the
    -- producer type below. Do not classify a provisional edge and then
    -- overwrite its plan: the eventual sink must own exactly one
    -- assignment_adjustment call and one stored plan.
    local allow_open_coercion = adjusted.open_source
        and not demand.defer_open_check
        and (adjusted.open_source._tag ~= "Ast.ExpDots"
             or demand.open_coerce)
    local open_adjustment, open_interface_conversion,
        open_interface_failure
    if adjusted.open_source and not demand.defer_open_check then
        open_adjustment, open_interface_conversion,
            open_interface_failure =
            checker_assignment_adjustment(
                adjusted.open_type, adjusted.open_target, st, {
                -- Flexible call results are converted element-wise by their
                -- sink. Preserve the input-`...` contract: forwarding a whole
                -- descriptor does not silently lift a scalar coercion.
                allow_coercion = allow_open_coercion and true or false,
            })
    end
    adjusted.open_adjustment = open_adjustment or false
    adjusted.open_callable_adapter = open_adjustment
        and open_adjustment.kind == "callable"
        and checker.freeze_callable_adapter(
            open_adjustment, adjusted.open_type,
            adjusted.open_target, adjusted.open_source.loc)
        or false
    adjusted.open_interface_conversion =
        open_interface_conversion or false
    if adjusted.open_source and not demand.defer_open_check then
        local open = adjusted.open_source._tag == "Ast.ExpDots"
            and adjusted.open_source._open_dots
            or adjusted.open_source._open_results
        if open then
            open.adjustment = adjusted.open_adjustment
            open.callable_adapter = adjusted.open_callable_adapter
        end
    end
    if adjusted.open_source and not demand.defer_open_check
       and adjusted.open_type._tag ~= "Type.Invalid"
       and adjusted.open_target._tag ~= "Type.Invalid"
       and not open_adjustment then
        if report_interface_failure(
                errors, adjusted.open_source.loc,
                open_interface_failure) then
            -- The ordered implementation matcher already described the first
            -- failing Interface method.
        elseif adjusted.open_source._tag == "Ast.ExpDots" then
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

local function constructor_field_kind(field)
    -- Parser-built positional fields use false; synthesized fields may use nil.
    if not field.name then
        return "positional"
    elseif type(field.name) == "table" then
        return "computed"
    else
        return "named"
    end
end

-- Classify an initializer before checking any of its expressions. This keeps a
-- positional field away from the computed-Map key path (where a nil key used to
-- reach checkexp), and makes every mixed ordering fail in the same deliberate
-- way. A bare `...` is positional, but it must be the sole trailing open
-- producer.
local function classify_constructor_fields(node, errors)
    local seen, kinds = {}, {}
    local dots_field
    local invalid_dots = false

    for i, field in ipairs(node.fields) do
        local kind = constructor_field_kind(field)
        if not seen[kind] then
            seen[kind] = true
            table.insert(kinds, kind)
        end
        if kind == "positional" and field.exp._tag == "Ast.ExpDots" then
            if dots_field then
                checker.typeerror(errors, field.loc,
                    "'...' can appear only once in a positional constructor")
                invalid_dots = true
            else
                dots_field = field
            end
            if i ~= #node.fields then
                checker.typeerror(errors, field.loc,
                    "'...' must be the last field in a positional constructor")
                invalid_dots = true
            end
        end
    end

    if #kinds == 0 then
        return "empty", kinds, dots_field, invalid_dots
    elseif #kinds == 1 then
        return kinds[1], kinds, dots_field, invalid_dots
    else
        return "mixed", kinds, dots_field, invalid_dots
    end
end

-- Check every written expression of a constructor that has already been
-- rejected for its field shape. This preserves scope/name diagnostics without
-- routing a bare trailing `...` through its scalar-only checkexp arm.
local function check_rejected_constructor_fields(node, st, errors, context)
    local value_context
    local key_context
    if context and context._tag == "Type.Array" then
        value_context = context.elem
    elseif context and context._tag == "Type.Map" then
        key_context = context.keys
        value_context = context.values
    end

    for _, field in ipairs(node.fields) do
        local kind = constructor_field_kind(field)
        if kind == "positional" and field.exp._tag == "Ast.ExpDots" then
            check_dots_marker(field.exp, st, errors)
        else
            if kind == "computed" then
                checkexp(field.name, st, errors, key_context)
            end
            checkexp(field.exp, st, errors, value_context)
        end
    end
end

local function positional_initializer_term(container_tag)
    if container_tag == "Type.Array" then
        return "array initializer"
    else
        return "positional map initializer"
    end
end

-- Freeze the construction-time Lua writer policy after contextual element
-- adjustment has selected the Array's final type.  The coder consumes these
-- annotations verbatim; it must not re-run a semantic relation from the
-- emitted Array type.  Raw C pointers (and compound types containing one)
-- deliberately have no DynamicCoercionPlan, so an Array that would need such
-- a writer is rejected at its construction site.
local function annotate_array_writer(node, elem, errors)
    local normalized = types.normalize(elem)
    if not normalized then
        node._array_element_type = types.Invalid()
        node._array_writer_plan = false
        return
    end
    node._array_element_type = normalized
    local writer_type = checker._generic.runtime_carrier(normalized)
    node._array_writer_plan = types.dynamic_coercion(writer_type) or false
    if writer_type ~= normalized then
        node._generic_array_writer_type = writer_type
    end
    if node._array_writer_plan == false
       and normalized._tag ~= "Type.Invalid" then
        checker.typeerror(errors, node.loc,
            "cannot construct an array with element type %s because genuine "
            .. "Lua writes have no sound dynamic coercion for that type",
            types.tostring(normalized))
    end
end

-- Arrays and positional integer-keyed Maps are the same kind of open
-- expression-list consumer. The checker elaboration is intentionally
-- representation-neutral; code generation decides whether the sink is a
-- private Array backing or an ordinary Map Table.
local function check_positional_constructor(node, st, errors, container_tag,
                                              keytype, elem_context)
    local exps = {}
    for _, field in ipairs(node.fields) do
        assert(constructor_field_kind(field) == "positional")
        table.insert(exps, field.exp)
    end

    local term = positional_initializer_term(container_tag)
    local adjusted = adjust_explist(exps,
        result_demand({}, elem_context or INFER_OPEN, {
            term = term,
            loc = node.loc,
            missing = "error",
            explicit_surplus = "discard",
            open_coerce = true,
            defer_open_check = true,
        }), st, errors)
    local etype = elem_context
        or (adjusted.open_type
            and adjusted.open_type._tag ~= "Type.Invalid"
            and deoptionize(adjusted.open_type))
        or (adjusted.tail_scalars[1]
            and deoptionize(adjusted.tail_scalars[1]._type))
        or types.Integer()

    if container_tag == "Type.Array" then
        node._type = types.Array(etype)
        annotate_array_writer(node, etype, errors)
    else
        node._type = types.Map(assert(keytype), etype)
    end

    -- A contextual sink was already coerced and checked by adjust_explist.
    -- Inference has no target during that pass, so apply its newly selected
    -- element type here exactly once.
    if not elem_context then
        for i, exp in ipairs(adjusted.tail_scalars) do
            local old = exp
            exp = coerce_and_check(exp, etype,
                term .. " at position " .. i, errors, exp.loc)
            replace_adjusted_value(adjusted, old, exp)
        end
    end

    if adjusted.open_source then
        local source = adjusted.open_type
        local container_name = container_tag == "Type.Array"
            and "array" or "positional map"
        local open_adjustment, open_interface_conversion,
            open_interface_failure =
            checker_assignment_adjustment(source, etype, st)
        if source._tag ~= "Type.Invalid"
           and not open_adjustment then
            if report_interface_failure(
                    errors, adjusted.open_source.loc,
                    open_interface_failure) then
                -- The matcher emitted the source-level Interface failure.
            elseif adjusted.open_source._tag == "Ast.ExpDots" then
                checker.typeerror(errors, adjusted.open_source.loc,
                    "'...' element type %s is not coerceable to %s element type %s",
                    types.tostring(source), container_name,
                    types.tostring(etype))
            else
                checker.typeerror(errors, adjusted.open_source.loc,
                    "open result element type %s is not coerceable to %s element type %s",
                    types.tostring(source), container_name,
                    types.tostring(etype))
            end
        end
        adjusted.open_target = etype
        adjusted.open_adjustment = open_adjustment or false
        adjusted.open_callable_adapter = open_adjustment
            and open_adjustment.kind == "callable"
            and checker.freeze_callable_adapter(
                open_adjustment, source, etype,
                adjusted.open_source.loc)
            or false
        adjusted.open_interface_conversion =
            open_interface_conversion or false
        if adjusted.open_source._tag == "Ast.ExpCall"
           and adjusted.open_source._open_results then
            adjusted.open_source._open_results.target_type = etype
            adjusted.open_source._open_results.adjustment =
                adjusted.open_adjustment
            adjusted.open_source._open_results.callable_adapter =
                adjusted.open_callable_adapter
        elseif adjusted.open_source._tag == "Ast.ExpDots"
               and adjusted.open_source._open_dots then
            adjusted.open_source._open_dots.target_type = etype
            adjusted.open_source._open_dots.adjustment =
                adjusted.open_adjustment
            adjusted.open_source._open_dots.callable_adapter =
                adjusted.open_callable_adapter
        end
    end

    node.fields = {}
    for _, exp in ipairs(adjusted.exps) do
        table.insert(node.fields, ast.Field(exp.loc, nil, exp))
    end
    node._positional_adjustment = adjusted
end

local function check_computed_map_constructor(node, st, errors, context)
    local kcontext = context and context.keys
    local vcontext = context and context.values
    local ktypes, vtypes = {}, {}

    for _, field in ipairs(node.fields) do
        assert(constructor_field_kind(field) == "computed")
        checkexp(field.name, st, errors, kcontext)
        table.insert(ktypes, field.name._type)
        checkexp(field.exp, st, errors, vcontext)
        table.insert(vtypes, field.exp._type)
    end

    -- Empty constructors reach this helper only with a Map context; a
    -- no-context empty constructor is the default empty Array.
    local ktype = kcontext
        or (ktypes[1] and deoptionize(ktypes[1]))
        or types.Integer()
    local vtype = vcontext
        or (vtypes[1] and deoptionize(vtypes[1]))
        or types.Integer()
    node._type = types.Map(ktype, vtype)

    for i, field in ipairs(node.fields) do
        field.name = coerce_and_check(field.name, ktype,
            "map key initializer at position " .. i,
            errors, field.name.loc)

        field.exp = coerce_and_check(field.exp, vtype,
            "map value initializer at position " .. i,
            errors, field.exp.loc)
    end
end

--
-- Decl
--

checkdecl = function(node, st, errors)
    node._type = node._type or typefromnode(node.type, st, errors)
    checktype(node._type, node.loc, errors)
    report_incomplete_c_object(node._type, st,
        "declaration of local variable '" .. tostring(node.name) .. "'",
        node.loc, errors)
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
--   returns whether the statement cannot fall through (always false here)
local function checkcondition(node, st, errors)
    if checker._foreign_function_depth == 0 then
        checkexp(node, st, errors, types.Boolean())
        if node._type._tag == "Type.Parameter" then
            checker.typeerror(errors, node.loc,
                "rigid type parameter '%s' cannot be used as a condition",
                node._type.diagnostic_name)
        end
        return
    end

    checkexp(node, st, errors)
    local typ = c_resolve(node._type)
    if not typ or (typ._tag ~= "Type.CInteger"
                   and typ._tag ~= "Type.CFloat"
                   and typ._tag ~= "Type.CPointer"
                   and typ._tag ~= "Type.CArray"
                   and typ._tag ~= "Type.Boolean") then
        checker.typeerror(errors, node.loc,
            "a foreign function condition must have a C scalar type, found %s",
            types.tostring(node._type))
    else
        node._foreign_condition = true
    end
end

local function checkrepeat(node, st, errors)
    for _, stat in ipairs(node.block.stats) do
        checkstat(stat, st, errors)
    end
    checkcondition(node.condition, st, errors)
    return false
end

-- Typechecks a for loop statement
--   node: StatFor AST node
--   st: symbol table
--   errors: list of compile-time errors
--   returns whether the statement cannot fall through (always false here)
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
    local resolved_control = c_resolve(node.decl._type)
    if checker._foreign_function_depth > 0
       and resolved_control
       and (resolved_control._tag == "Type.CInteger"
            or resolved_control._tag == "Type.CFloat") then
        loop_type_is_valid = true
        if not node.inc then
            node.inc = resolved_control._tag == "Type.CInteger"
                and ast.ExpInteger(node.finish.loc, 1)
                or ast.ExpFloat(node.finish.loc, 1.0)
            node.inc._type = node.decl._type
            node.inc._foreign_literal = true
        end
        for _, bound in ipairs({ node.start, node.finish, node.inc }) do
            if bound._foreign_literal then bound._type = node.decl._type end
        end
        if checker._numeric_literal_is_zero(node.inc) then
            checker.typeerror(errors, node.inc.loc,
                "a numeric for loop inside a foreign function requires a nonzero step")
        end
    elseif node.decl._type._tag == "Type.Integer" then
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
        -- Numeric-for bounds share the exact control representation. They do
        -- not form assignment sinks and therefore neither coerce nor create a
        -- gradual view of the control type.
        check_exact_match("'for' start expression",
            node.decl._type, node.start, errors, node.start.loc)
        check_exact_match("'for' finish expression",
            node.decl._type, node.finish, errors, node.finish.loc)
        check_exact_match("'for' step expression",
            node.decl._type, node.inc, errors, node.inc.loc)
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
    local callable = exps[1] and exps[1]._type
    local cfunc = callable and c_function_pointer_type(callable)
    local signature = call_signature(cfunc or callable)
    if signature then
        limit = math.max(prefix + 1,
            1 + math.min(#signature.params, 2))
        if limit > 4 then limit = 4 end
    end
    return limit
end

local function check_forin_decl_init(decl, exp, st, errors)
    local term = "generic for variable " .. decl.name
    if decl.type then
        checkdecl(decl, st, errors)
        exp = coerce_and_check(
            exp, decl._type, term, errors, decl.loc)
    elseif decl.option then
        decl._type = optionize(exp._type)
        checkdecl(decl, st, errors)
        exp = coerce_and_check(
            exp, decl._type, term, errors, decl.loc)
    else
        exp = tryforce(exp)
        decl._type = exp._type
        checkdecl(decl, st, errors)
    end
    return exp
end

local function forin_signature_from_slot_type(typ)
    local cfunc = c_function_pointer_type(typ)
    if cfunc then
        return call_signature(cfunc), cfunc
    elseif typ._tag == "Type.Function" then
        return call_signature(typ), nil
    end
end

local function check_forin_callable_exp(exp, st, errors, context, demand)
    if exp._tag == "Ast.ExpVar" and exp.var._tag == "Ast.VarDot" then
        checkvar(exp.var, st, errors)
        if exp.var._decl then exp.var._decl._used = true end
        local ftype = exp.var._type
        local cfunc = c_resolve(ftype)
        if exp.var.exp and exp.var.exp._type
           and exp.var.exp._type._tag == "Type.CModule"
           and cfunc and cfunc._tag == "Type.CFunction" then
            exp._type = types.CPointer(cfunc, {})
            exp._foreign_function_pointer = exp.var.name
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
        ast.ArgsFunc(loc, args), {})
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

function checker._generic.infer_forin_scheme(
        exp, scheme, node, st, errors)
    local subject = "generic for iterator"
    local context = checker._generic.new_inference_context(subject, {
        checker._generic.inference_scope_entry(
            scheme.scope, scheme.typeparams),
    }, st, errors, exp.loc)
    local signature = scheme.signature

    for index, parameter in ipairs(signature.params) do
        local actual = node.exps[index + 1]
        if actual and actual._type then
            checker._generic.unify_inference(context, parameter,
                actual._type, "generic for hidden argument " .. index,
                actual.loc)
        end
    end
    for index, decl in ipairs(node.decls) do
        if decl.type then
            decl._type = decl._type or typefromnode(decl.type, st, errors)
            local expected = index == 1
                and optionize(decl._type) or decl._type
            local pattern = signature.rettypes[index]
            if not pattern and signature.flexrettype then
                pattern = optionize(signature.flexrettype)
            end
            if pattern then
                checker._generic.unify_inference(context, pattern,
                    expected, "generic for variable " .. decl.name,
                    decl.loc)
            end
        end
    end

    checker._generic.close_inference_context(context)
    local closed = checker._generic.substitute_inference(
        context, signature, true)
    exp._generic_scheme = scheme
    exp._generic_type_arguments =
        checker._generic.inference_type_arguments(context)
    exp._type = closed
    return closed
end

local function checkforin(node, st, errors)
    local generic_prechecked = {}
    local iterator = node.exps[1]
    if iterator
       and checker._generic.is_generic_first_class_expression(
            iterator, st, errors)
       and iterator._type._tag == "Type.FunctionScheme" then
        -- Hidden iterator arguments are ordinary inference evidence. Check the
        -- direct state/control expressions first, then close the iterator once
        -- from those inputs and any annotated loop-result slots.
        for index = 2, math.min(#node.exps, 3) do
            local exp = node.exps[index]
            if exp._tag ~= "Ast.ExpDots" then
                checkexp(exp, st, errors, nil,
                    result_demand({ UNKNOWN_SLOT }, false, {
                        term = "generic for inference argument",
                    }))
                generic_prechecked[exp] = true
            end
        end
        checker._generic.infer_forin_scheme(
            iterator, iterator._type, node, st, errors)
        generic_prechecked[iterator] = true
    end

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
                if generic_prechecked[exp] then return end
                if sink_index == 4
                   and checker._generic.is_generic_first_class_expression(
                        exp, est, eerrors) then
                    local params = {}
                    local state = node.exps[2]
                    if state and state._type
                       and state._type._tag ~= "Type.Nil" then
                        params[1] = state._type
                    end
                    local expected = types.Function(
                        params, {}, false, false, false)
                    checkexp(exp, est, eerrors, expected,
                        result_demand({ expected }, false, {
                            term = "generic for close function",
                        }))
                elseif sink_index == 1 or sink_index == 4 then
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
        ftype = call_signature(exps[1]._type)
    else
        ftype, iter_cfunc = forin_signature_from_slot_type(ftype)
    end
    if not ftype then
        checker.typeerror(errors, exps[1].loc,
            "generic for iterator must be a function, value, or C function pointer but found %s",
            types.tostring(exps[1]._type))
        ftype = call_signature(
            types.Function({}, { types.Invalid() }, false, false, false))
    end

    if ftype.c_vararg or ftype.varargtype then
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
        ftype = call_signature(types.Function(
            ftype.params, { types.Invalid() }, false, false, false))
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
        exps[2] = coerce_and_check(exps[2], ftype.params[1],
            "generic for iterator state", errors, exps[2].loc)
        replace_adjusted_value(tuple_adjustment, old, exps[2])
    end
    if ftype.params[2] then
        local old = exps[3]
        exps[3] = coerce_and_check(exps[3], ftype.params[2],
            "generic for iterator initial control", errors, exps[3].loc)
        replace_adjusted_value(tuple_adjustment, old, exps[3])
    end

    local close_type = exps[4]._type
    local close_ftype
    local close_cfunc
    -- A close slot whose static type is `value` can hold nil at run time. Keep
    -- the synthesized callable type for non-nil values, but tell codegen that
    -- nil means the optional close slot is absent rather than a call target.
    local runtime_optional_close = close_type._tag == "Type.Value"
    if close_type._tag == "Type.Nil" then
        node._has_close = false
    else
        if close_type._tag == "Type.Value" then
            close_ftype = synthesize_forin_close_type(exps)
            local old = exps[4]
            exps[4] = trycoerce(exps[4], close_ftype, errors)
            replace_adjusted_value(tuple_adjustment, old, exps[4])
            close_type = exps[4]._type
            close_ftype = call_signature(close_ftype)
        else
            close_ftype, close_cfunc =
                forin_signature_from_slot_type(close_type)
        end
    end
    if close_ftype then
        local close_ok = true
        if close_ftype.c_vararg or close_ftype.varargtype
           or #close_ftype.params > 1 then
            checker.typeerror(errors, exps[4].loc,
                "generic for close function must accept zero or one state argument")
            close_ok = false
        elseif close_ftype.params[1] then
            local state_for_close = exps[2]
            state_for_close = coerce_and_check(
                state_for_close, close_ftype.params[1],
                "generic for close argument", errors, exps[2].loc)
        end
        node._has_close = close_ok
    elseif close_type._tag ~= "Type.Nil" and close_type._tag ~= "Type.Invalid" then
        checker.typeerror(errors, exps[4].loc,
            "generic for close value must be nil, a function, value, or C function pointer but found %s",
            types.tostring(close_type))
        node._has_close = false
    end
    node._runtime_optional_close = node._has_close
        and runtime_optional_close or false

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
        ctrlarg = coerce_and_check(ctrlarg, ftype.params[2],
            "generic for iterator control argument", errors, node.loc)
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
                exp = coerce_and_check(nil_exp(node.loc), decl._type,
                    "generic for variable " .. decl.name,
                    errors, decl.loc)
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
--   returns whether the block cannot fall through to its following statement
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
--   returns whether the statement cannot fall through
local checkstat_visitor = util.make_visitor({
    ["Ast.StatDecl"] = function(node, st, errors)
        if #node.exps == 0 then
            checker.typeerror(errors, node.loc,
                "a local declaration requires an initializer")
            for _, decl in ipairs(node.decls) do
                decl._type = decl.type
                    and typefromnode(decl.type, st, errors)
                    or types.Invalid()
                declare(decl, st, errors)
            end
            return
        end

        local fixed = {}
        for i, decl in ipairs(node.decls) do
            if decl.type then
                if decl.type._tag == "Ast.TypeCArray"
                   and not decl.type.length then
                    local written = typefromnode(decl.type, st, errors)
                    decl._written_c_array_view = written
                    decl._type = types.CPointer(written.elem, {})
                    checktype(decl._type, decl.loc, errors)
                else
                    checkdecl(decl, st, errors)
                end
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
                check_expression = function(exp, est, eerrors, context,
                                             subdemand, sink_index)
                    subdemand.allocation_decl = node.decls[sink_index]
                    checkexp(exp, est, eerrors, context, subdemand)
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
                if types.is_c_array(decl._type)
                   and not (decl._c_allocation_plan
                            and decl._c_allocation_plan.storage == "automatic_array") then
                    checker.typeerror(errors, decl.loc,
                        "cannot initialize a local by copying a whole C array")
                end
                exp = coerce_and_check(exp, decl._type,
                    "declaration of local variable " .. decl.name,
                    errors, decl.loc)
                replace_adjusted_value(adjusted, old, exp)
            end
            if exp and decl.type and types.is_c_array(decl._type)
               and not (decl._c_allocation_plan
                        and decl._c_allocation_plan.storage == "automatic_array") then
                checker.typeerror(errors, decl.loc,
                    "cannot initialize a local by copying a whole C array")
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
        checkcondition(node.condition, st, errors)
        local frame = { has_break = false }
        loop_depth = loop_depth + 1
        table.insert(loop_frames, frame)
        st:with_block(checkstat, node.block, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1

        -- A literal-true while cannot fall through unless a reachable break
        -- targets it. Errors still compose soundly: a surrounding StatTry
        -- requires its catch to be non-fallthrough too.
        return node.condition._tag == "Ast.ExpBool"
            and node.condition.value == true
            and not frame.has_break
    end,

    ["Ast.StatRepeat"] = function(node, st, errors)
        loop_depth = loop_depth + 1
        table.insert(loop_frames, { has_break = false })
        st:with_block(checkrepeat, node, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1
        return false
    end,

    ["Ast.StatFor"] = function(node, st, errors)
        local frame = { has_break = false }
        loop_depth = loop_depth + 1
        table.insert(loop_frames, frame)
        st:with_block(checkfor, node, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatForIn"] = function(node, st, errors)
        local frame = { has_break = false }
        loop_depth = loop_depth + 1
        table.insert(loop_frames, frame)
        st:with_block(checkforin, node, st, errors)
        table.remove(loop_frames)
        loop_depth = loop_depth - 1
    end,

    ["Ast.StatBreak"] = function(node, _, errors)
        local valid = true
        if loop_depth == 0 then
            checker.typeerror(errors, node.loc,
                "'break' outside a loop")
            valid = false
        elseif in_finally > 0 and loop_depth <= finally_loop_floor then
            -- Inside a finally with no loop opened *inside* it: the target loop
            -- encloses the finally, so this `break` would escape it (forbidden).
            -- A `break` to a loop written inside the finally (loop_depth above
            -- the floor) is contained and legal.
            checker.typeerror(errors, node.loc,
                "'break' cannot escape a finally block")
            valid = false
        end
        if valid then
            local frame = loop_frames[#loop_frames]
            if frame then
                frame.has_break = true
            end
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
            node.exp = coerce_and_check(
                node.exp, types.Value(), "raise", errors, node.loc)
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
            local saved_catch = catch_depth
            catch_depth = 0
            local saved_floor = finally_loop_floor
            finally_loop_floor = loop_depth
            fret = checkstat(node.finallyblock, st, errors)
            finally_loop_floor = saved_floor
            catch_depth = saved_catch
            in_finally = in_finally - 1
            st:close_block()
        end

        if saved_body_block then
            st.blocks[saved_block_index] = saved_body_block
        end

        -- Non-fallthrough (B.2): the construct cannot reach its successor iff
        -- the finally cannot fall through, OR the body cannot fall through and
        -- (there is no catch, or the catch also cannot fall through). `raise`
        -- counts as a terminator, so an unconditional finally raise satisfies
        -- `fret`.
        return (node.finallyblock and fret)
            or (bret and (not node.catchblock or cret))
    end,

    ["Ast.StatAssign"] = function(node, st, errors)
        for _, var in ipairs(node.vars) do
            -- The outer lvalue is not an observation. In particular, a typed
            -- Array/Map write may store a raw C pointer even though reading
            -- that same slot type cannot establish its pointee identity.
            -- Nested receivers (as in a[i][j]) are still checked normally
            -- when the outer VarBracket checks its exp1.
            checkvar(var, st, errors, nil, "write")
            check_c_assignment_storage(var, errors)
            if var._type and types.is_c_array(var._type) then
                checker.typeerror(errors, var.loc,
                    "cannot assign to a whole C array; assign its elements "
                    .. "or retain a pointer instead")
            end
        end
        local fixed = {}
        for i, var in ipairs(node.vars) do
            -- Module values are never assignable and have no ordinary value
            -- coercion/tostring path; preserve the dedicated diagnostic below
            -- while still reserving their finite expression-list slot.
            local decl = var._decl
            local function_decl =
                (var._type._tag == "Type.Function"
                 or var._type._tag == "Type.CFunction")
                and decl
                and (decl._tag == "Ast.TopLevelFunc"
                     or decl._tag == "Ast.TopLevelForeignFunc"
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
                elseif (texp._tag == "Type.Function"
                        or texp._tag == "Type.CFunction") and var._decl
                       and (var._decl._tag == "Ast.TopLevelFunc"
                            or var._decl._tag == "Ast.TopLevelForeignFunc"
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
                    exp = coerce_and_check(
                        exp, var._type, "assignment", errors, var.loc)
                    replace_adjusted_value(adjusted, old, exp)
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
        local signature = assert(call_signature(ftype),
            "return statement lacks a callable signature")
        if #node.exps == 0 and #signature.rettypes == 1
           and signature.rettypes[1]._tag == "Type.Nil" then
            -- A bare `return` in a nil-returning function means `return nil`.
            local nilexp = ast.ExpNil(node.loc)
            nilexp._type = types.Nil()
            table.insert(node.exps, nilexp)
        end

        local fixed = {}
        for i, typ in ipairs(signature.rettypes) do fixed[i] = typ end
        local adjusted = adjust_explist(node.exps,
            result_demand(fixed, signature.flexrettype, {
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

    ["Ast.StatCase"] = function(node, st, errors)
        checkexp(node.exp, st, errors)
        node.exp = tryforce(node.exp)

        local union
        local scrutinee_type = node.exp._type
        if scrutinee_type._tag ~= "Type.Nominal" then
            checker.typeerror(errors, node.exp.loc,
                "case expression must have a union type, but found '%s'",
                types.tostring(scrutinee_type))
        else
            local owner = checker._generic.applied_owner_view(
                scrutinee_type, errors, node.exp.loc)
            if not owner then
                checker.typeerror(errors, node.exp.loc,
                    "union type '%s' in case expression does not exist",
                    scrutinee_type.fqtn)
            elseif owner._tag ~= "Type.Union" then
                checker.typeerror(errors, node.exp.loc,
                    "case expression must have a union type, but found '%s'",
                    types.tostring(scrutinee_type))
            elseif not is_nominal_visible_from(st, scrutinee_type.fqtn) then
                checker.typeerror(errors, node.exp.loc,
                    "union type '%s' is local to module '%s'",
                    scrutinee_type.fqtn,
                    nominal_module(scrutinee_type.fqtn))
            else
                union = owner
                node._union = owner
            end
        end

        local seen_variants = {}
        local covered_variants = 0
        local all_arms_return = true
        for _, arm in ipairs(node.arms) do
            st:open_block()
            local variant = union and union.variants[arm.name] or nil
            if variant
               and not is_nominal_member_visible_from(st, variant) then
                variant = nil
            end
            if not variant then
                checker.typeerror(errors, arm.loc,
                    "variant '%s' not found in union '%s'",
                    arm.name,
                    union and union.name or types.tostring(scrutinee_type))
            else
                local previous = seen_variants[variant]
                if previous then
                    checker.typeerror(errors, arm.loc,
                        "duplicate case arm for variant '%s', previous one at %s",
                        arm.name, location.format(previous.loc))
                else
                    seen_variants[variant] = arm
                    covered_variants = covered_variants + 1
                end
                arm._variant = variant
                arm._variant_index = variant.index
            end

            if arm.binding then
                if not variant then
                    arm.binding._type = types.Invalid()
                elseif variant.payload == false then
                    arm.binding._type = types.Invalid()
                    checker.typeerror(errors, arm.binding.loc,
                        "empty variant '%s.%s' has no payload to bind",
                        union.name, variant.name)
                else
                    arm.binding._type = variant.payload
                end
                declare(arm.binding, st, errors)
            end

            local arm_returns = checkstat(arm.block, st, errors)
            if not arm_returns then all_arms_return = false end
            st:close_block()
        end

        local else_returns = false
        if node.elseblock then
            else_returns = checkstat(node.elseblock, st, errors)
        end
        local variants_exhausted = union ~= nil
            and covered_variants == union.nvariants
        return all_arms_return and (variants_exhausted or else_returns)
    end,

    ["Ast.StatIf"] = function(node, st, errors)
        local ret = true
        for _, thn in ipairs(node.thens) do
            checkcondition(thn.condition, st, errors)
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

-- Preserve the existing reachability result on every checked statement.
-- Compound coders need the same fact even when checkblock short-circuits after
-- an earlier non-fallthrough child. `_always_returns` is the historical field
-- name for this generalized fact.
checkstat = function(node, st, errors)
    local ret = checkstat_visitor(node, st, errors)
    node._always_returns = ret and true or false
    return ret
end

--
-- Var
--

-- Typechecks an variable node
--   node: Var_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   mode: "write" only for the outer variable of an assignment target
--   annotates the node with its type in a "_type" field
checkvar = util.make_visitor({
    ["Ast.VarName"] = function(node, st, errors, _)
        local decl = st:find_symbol(node.name)
        if not decl then
            local alias = st:find_type_alias(node.name)
            local resolved_alias = alias
                and resolve_type_alias(alias, st, errors) or nil
            local namespace = resolved_alias
                and alias_namespace_type(resolved_alias, st)
            local interface = st.interface_declarations
                and st.interface_declarations[node.name]
            if namespace then
                node._alias_namespace = true
                node._alias_decl = alias
                node._type = namespace
            elseif resolved_alias and types.is_direct_c(resolved_alias) then
                node._ctype_namespace = true
                node._alias_decl = alias
                node._type = resolved_alias
            elseif interface then
                node._type = invalid(errors, node.loc,
                    "interface '%s' is a type and has no runtime value",
                    node.name)
            else
                node._type = invalid(errors, node.loc,
                    "variable '%s' not declared", node.name)
            end
        else
            node._decl = decl
            node._type = decl._type
            if checker._foreign_function_depth > 0 then
                local tag = decl._tag
                local allowed = tag == "Ast.Decl"
                    or tag == "Ast.TopLevelForeignFunc"
                    or tag == "Ast.TopLevelForeignImport"
                    or (tag == "Ast.TopLevelImport" and decl._source_import)
                if not allowed then
                    node._type = invalid(errors, node.loc,
                        "ordinary Titan declaration '%s' is not visible inside a foreign function",
                        node.name)
                end
            end
            -- Capture detection (single chokepoint). A local/param (`Ast.Decl`,
            -- which excludes top-level functions/vars and module members) used
            -- from a function nested deeper than where it was declared is
            -- captured by every intervening lambda, INCLUSIVE of the current
            -- (innermost) one.
            if decl._tag == "Ast.Decl" and decl._funcdepth
               and decl._funcdepth < #func_stack then
                if types.is_c_aggregate(decl._type) then
                    checker.typeerror(errors, node.loc,
                        "cannot capture C aggregate variable '%s'; capture "
                        .. "an explicit pointer to its automatic storage "
                        .. "instead",
                        node.name)
                elseif decl._c_address_taken then
                    checker.typeerror(errors, node.loc,
                        "cannot capture variable '%s' after taking its mutable C address",
                        node.name)
                else
                    decl._captured = true
                    -- A variable only *written* (never read) by a nested
                    -- function would otherwise miss StatDecl's `_used` gate
                    -- and never get a box allocated; force it used here.
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
        end
    end,

    ["Ast.VarDot"] = function(node, st, errors, context)
        if node.exp._tag == "Ast.ExpVar" then
            checkvar(node.exp.var, st, errors)
            if node.exp.var._decl then node.exp.var._decl._used = true end
            node.exp._type = node.exp.var._type
        else
            checkexp(node.exp, st, errors)
        end
        node.exp = tryforce(node.exp)
        local ltype = node.exp._type
        if node._contextual_c_name
           and ltype._tag ~= "Type.CModule"
           and not types.is_direct_c(ltype)
           and not is_c_type_namespace(node.exp) then
            node._type = invalid(errors, node.loc,
                "Titan keyword '%s' is only contextual for a C member",
                node.name)
            return
        end
        if ltype._tag == "Type.Module" or ltype._tag == "Type.CModule" then
            local mod = ltype
            local import_decl = node.exp._tag == "Ast.ExpVar"
                and node.exp.var and node.exp.var._decl
            local include_source = import_decl
                and import_decl._tag == "Ast.TopLevelImport"
                and import_decl._source_import == true
            local module_member = ltype._tag == "Type.Module"
                and types.module_member(mod, node.name, include_source)
                or mod.members[node.name]
            if module_member then
                node._decl = module_member
                node._type = node._decl.type
                if ltype._tag == "Type.CModule" and mod.type_members
                   and mod.type_members[node.name] then
                    node._c_type_collision = mod.type_members[node.name]
                end
            elseif ltype._tag == "Type.CModule" and mod.type_members
                   and mod.type_members[node.name] then
                node._decl = {
                    _tag = "Type.CTypeNamespace",
                    name = node.name,
                    type = mod.type_members[node.name],
                }
                node._type = node._decl.type
                node._ctype_namespace = true
            elseif ltype._tag == "Type.Module"
                   and types.module_type_member(
                       mod, node.name, include_source) then
                local member = types.module_type_member(
                    mod, node.name, include_source)
                local namespace = alias_namespace_type(member, st)
                if namespace then
                    node._alias_namespace = true
                    node._alias_type = member
                    node._type = namespace
                elseif member._tag == "Type.Interface" then
                    node._type = invalid(errors, node.loc,
                        "interface '%s' is a type and has no runtime value",
                        node.name)
                else
                    node._type = invalid(errors, node.loc,
                        "member '%s' not found inside module '%s'",
                        node.name, mod.name)
                end
            elseif not module_member then
                node._type = invalid(errors, node.loc,
                    "member '%s' not found inside module '%s'",
                    node.name, mod.name)
            end
        elseif ltype._tag == "Type.Record"
           or ltype._tag == "Type.Union" then
            local decl = ltype.functions[node.name]
            if decl then
                if not is_nominal_member_visible_from(st, decl) then
                    local kind = ltype._tag == "Type.Record"
                        and "record" or "union"
                    node._type = invalid(errors, node.loc,
                        "%s function '%s.%s' is local to module '%s'",
                        kind, ltype.name, node.name,
                        nominal_module(ltype.name))
                else
                    node._decl = decl
                    node._type = types.Function(decl.params, decl.rettypes, false,
                        decl.varargtype, decl.flexrettype)
                    -- The selected namespace is authoritative even when a
                    -- concrete alias has already closed every owner binder.
                    -- Falling back to the registry would reopen the raw owner
                    -- scheme and demand or accept a contradictory application.
                    node._generic_owner = ltype
                    if decl._owner_scope or decl.scope or ltype.scope then
                        node._generic_declaration = decl
                    end
                    -- Preserve the physical imported-module userdata that owns
                    -- a qualified namespace (`m.Rec.static` / `m.U.variant`).
                    -- Direct calls already recover this through the nested
                    -- VarDot shape; first-class selector reads need an explicit
                    -- stable decoration once checking has resolved the static.
                    local namespace = node.exp._tag == "Ast.ExpVar"
                        and node.exp.var or nil
                    if namespace and namespace._alias_namespace then
                        node._alias_namespace = true
                    end
                    local import_var = namespace
                        and namespace._tag == "Ast.VarDot"
                        and namespace.exp
                        and namespace.exp._tag == "Ast.ExpVar"
                        and namespace.exp.var or nil
                    if import_var and import_var._decl
                       and import_var._decl._tag == "Ast.TopLevelImport" then
                        node._import_decl = import_var._decl
                    end
                end
            else
                local kind = ltype._tag == "Type.Record"
                    and "record" or "union"
                node._type = invalid(errors, node.loc,
                    "trying to access invalid %s function '%s'",
                    kind, node.name)
            end
        elseif ltype._tag == "Type.Nominal" then
            local type = checker._generic.applied_owner_view(ltype, errors, node.loc)
            if not type then
                node._type = invalid(errors, node.loc,
                    "type '%s' not found", ltype.fqtn)
            elseif not is_nominal_visible_from(st, ltype.fqtn) then
                node._type = invalid(errors, node.loc,
                    "record type '%s' is local to module '%s'",
                    ltype.fqtn, nominal_module(ltype.fqtn))
            elseif type._tag == "Type.Union" then
                node._type = invalid(errors, node.loc,
                    "union value of type '%s' has no fields; use a case statement",
                    ltype.fqtn)
            elseif type._tag == "Type.Interface" then
                node._type = invalid(errors, node.loc,
                    "interface value of type '%s' has no fields; use an interface method",
                    ltype.fqtn)
            elseif type._tag ~= "Type.Record" then
                node._type = invalid(errors, node.loc,
                    "trying to access field '%s' of type '%s' that is not a record but '%s'",
                    node.name, ltype.fqtn, type._tag)
            else
                for _, field in ipairs(type.fields) do
                    if field.name == node.name
                       and is_nominal_member_visible_from(st, field) then
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
        elseif node.exp._tag == "Ast.ExpVar"
               and node.exp.var
               and node.exp.var._c_type_collision
               and is_c_pseudo_member_name(node.name) then
            -- The ordinary C identifier wins a value lookup, but a following
            -- pseudo-member spelling is otherwise liable to fall through to
            -- generic C field lookup (and produce the misleading "field not
            -- found" diagnostic). Preserve real aggregate fields named
            -- `new`/`sizeof`/...; only diagnose the hidden type namespace when
            -- the ordinary value has no such field.
            local field_error
            node._decl, field_error =
                c_field_decl(ltype, node.name, st)
            if node._decl then
                node._type = node._decl.type
            else
                node._type = invalid(errors, node.loc,
                    "C type pseudo-member '%s.%s' is unavailable because "
                    .. "foreign module '%s' also has an ordinary member named '%s'",
                    node.exp.var.name, node.name,
                    node.exp.var.exp._type.name, node.exp.var.name)
            end
        elseif types.is_direct_c(ltype) or is_c_type_namespace(node.exp) then
            if is_c_type_namespace(node.exp) then
                local pseudo_error
                node._decl, pseudo_error =
                    c_pseudo_member(ltype, node.name, st)
                if node._decl
                   and node._decl._tag == "Checker.CPseudoNew" then
                    if context == c_pseudo_callee_context then
                        -- This syntax-bound declaration has no value type. The
                        -- enclosing ExpCall consumes `_decl` before ordinary
                        -- invalid-callee recovery.
                        node._type = types.Invalid()
                    else
                        node._type = invalid(errors, node.loc,
                            "C allocation pseudo-member '%s' can only be called directly",
                            node.name)
                    end
                elseif node._decl then
                    node._type = node._decl.type
                elseif pseudo_error then
                    node._type = invalid(errors, node.loc,
                        pseudo_error)
                else
                    node._type = invalid(errors, node.loc,
                        "C type '%s' has no pseudo-member '%s'",
                        types.tostring(ltype), node.name)
                end
            else
                local field_error
                node._decl, field_error =
                    c_field_decl(ltype, node.name, st)
                if node._decl then
                    node._type = node._decl.type
                elseif field_error then
                    node._type = invalid(errors, node.loc,
                        field_error)
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
        if node._decl and node._decl._tag == "Type.CField"
           and node._decl.flexible_array then
            local resolved_base = c_resolve(ltype)
            if resolved_base._tag == "Type.COwned"
               and not resolved_base.count then
                local owner = c_resolve(resolved_base.pointee)
                if owner._tag == "Type.CStruct" and owner.has_fam then
                    node._c_fam_access = {
                        kind = "owned",
                        field = node._decl,
                    }
                end
            elseif node.exp._tag == "Ast.ExpVar"
                   and node.exp.var._tag == "Ast.VarName" then
                local root = node.exp.var._decl
                local plan = root and root._c_allocation_plan
                if plan and plan.storage == "automatic_fam" then
                    node._c_fam_access = {
                        kind = "automatic",
                        field = node._decl,
                        count = plan.fam_count_literal,
                        root = root,
                    }
                end
            end
        end
        if checker._foreign_function_depth > 0 and ltype._tag == "Type.Module"
           and not checker._foreign_function_reference(node) then
            node._type = invalid(errors, node.loc,
                "ordinary Titan member '%s.%s' is not visible inside a foreign function",
                ltype.name, node.name)
        end
        if node._type and node._type._tag ~= "Type.Invalid" then
            local spelling_only = context
                and node.exp._type._tag == "Type.CModule"
                and node._type._tag == "Type.CFunction"
                and c_function_pointer_type(context) ~= nil
            if not checker._ensure_c_enum_supported(
                    st, node._type, node.loc, errors, nil,
                    spelling_only and true or false) then
                node._type = types.Invalid()
            end
        end
    end,

    ["Ast.VarBracket"] = function(node, st, errors, _, mode)
        checkexp(node.exp1, st, errors)
        node.exp1 = tryforce(node.exp1)
        local keystype, term
        local fam_access = node.exp1._c_fam_access
        local celem, cterm, cerr
        if fam_access then
            local array = c_resolve(fam_access.field.type)
            celem, cterm = c_resolve(array.elem),
                "flexible C array member indexing"
            node._c_fam_access = fam_access
        else
            celem, cterm, cerr = c_index_elem_type(node.exp1._type)
        end
        if node.exp1._type._tag == "Type.Array" then
            local elem = node.exp1._type.elem
            node._type = optionize(elem)
            local read_type = checker._generic.runtime_carrier(node._type)
            node._read_guard = types.gradual_guard(read_type) or false
            if read_type ~= node._type then
                node._generic_read_type = node._type
            end
            if mode ~= "write" and not node._read_guard then
                checker.typeerror(errors, node.loc,
                    "cannot read array elements of type '%s' because the type has no sound runtime guard",
                    types.tostring(elem))
            end
            keystype = types.Integer()
            term = "array indexing"
        elseif node.exp1._type._tag == "Type.Map" then
            local values = node.exp1._type.values
            node._type = optionize(values)
            local read_type = checker._generic.runtime_carrier(node._type)
            node._read_guard = types.gradual_guard(read_type) or false
            if read_type ~= node._type then
                node._generic_read_type = node._type
            end
            if mode ~= "write" and not node._read_guard then
                checker.typeerror(errors, node.loc,
                    "cannot read map values of type '%s' because the type has no sound runtime guard",
                    types.tostring(values))
            end
            keystype = node.exp1._type.keys
            term = "map indexing"
        elseif celem then
            node._type, term = celem, cterm
            if checker._foreign_function_depth > 0 then
                local spelling = st.c_profile and st.c_profile.int or "int"
                keystype = st.c_profile and st.c_profile.integers
                    and st.c_profile.integers[spelling]
                    and st.c_profile.integers[spelling].type
                    or types.CInteger("int", true, 3, 32)
            else
                keystype = types.Integer()
            end
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
        node.exp2 = coerce_and_check(
            node.exp2, keystype, term, errors, node.exp2.loc)
        if node._type and node._type._tag ~= "Type.Invalid"
           and not checker._ensure_c_enum_supported(
               st, node._type, node.loc, errors) then
            node._type = types.Invalid()
        end
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
local function checkargs(callable, args, loc, fname, st, errors,
                         allow_missing)
    local signature = assert(call_signature(callable),
        "call checking requires a callable signature")
    if allow_missing == nil then allow_missing = true end
    local strict_arity = not allow_missing
    local fixed = {}
    for i, ptype in ipairs(signature.params) do fixed[i] = ptype end
    local tail = signature.varargtype
        or (signature.c_vararg and INFER_OPEN) or false
    local original_count = #args
    local adjusted = adjust_explist(args,
        result_demand(fixed, tail, {
            term = "call to " .. fname,
            open_term = fname,
            loc = loc,
            missing = strict_arity and "ignore" or "nil",
            explicit_surplus = strict_arity and "error" or "discard",
            slot_term = function(i)
                return "argument " .. i .. " of call to " .. fname
            end,
        }), st, errors)

    -- A runtime-sized Titan run has no C vararg promotion/ABI contract. Keep
    -- ordinary explicit C varargs, but never pass `...` or a flexible-result
    -- run through that boundary.
    if signature.c_vararg and adjusted.open_source then
        checker.typeerror(errors, adjusted.open_source.loc,
            "cannot pass a runtime-open Titan result sequence to a foreign (C) variadic function")
    end

    if strict_arity and (adjusted.missing or adjusted.explicit_surplus) then
        local supplied = adjusted.explicit_surplus and original_count
            or (#signature.params - adjusted.missing)
        checker.typeerror(errors, loc,
            "%s called with %d arguments but expects %d.\n%s",
            fname, supplied, #signature.params,
            signature.description or types.tostring(signature.callable))
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
        adjustment = adjusted.open_adjustment,
    } or false
end

-- Return the direct automatic object whose address/decay is passed to a
-- mutable C parameter. Pointer-valued aliases intentionally do not qualify:
-- after their creation the checker cannot know which object a pointer denotes.
local function mutable_c_call_argument_decl(exp, target)
    if not target or c_pointer_is_const(target) then return nil end

    local adjusted = exp
    local unsafe_array_decay = false
    local direct_address_source = false
    while exp and exp._tag == "Ast.ExpCast" do
        local conversion = exp._c_conversion
        if conversion and conversion.kind == "unsafe_object_pointer" then
            unsafe_array_decay = true
        elseif conversion and conversion.kind ==
               "address_then_unsafe_object_pointer" then
            direct_address_source = exp.exp
        elseif is_mutable_c_address_source(exp.exp)
           and types.c_mutable_address_coerceable(
               exp.exp._type, exp._type) then
            -- An inner explicit cast may take the exact local address before
            -- an outer unsafe pointer reinterpretation reaches the parameter.
            direct_address_source = exp.exp
        end
        exp = exp.exp
    end
    exp = direct_address_source or exp
    if not is_mutable_c_address_source(exp) then return nil end

    if direct_address_source then
        return exp.var._decl, exp
    end

    if types.c_mutable_address_coerceable(exp._type, target) then
        return exp.var._decl, exp
    end

    local source = types.resolve_c_typedef(exp._type)
    local planned_conversion = adjusted._adjustment
        or adjusted._assignment_adjustment
        or adjusted._written_cast
        or adjusted._c_conversion
    if source and source._tag == "Type.CArray"
       and (unsafe_array_decay
            or (planned_conversion
                and adjusted._type
                and types.equals(adjusted._type, target))) then
        return exp.var._decl, exp
    end
    return nil
end

-- A C variadic tail has no formal parameter type, but an explicit pointer cast
-- still describes the exact argument type passed across the ABI. Direct arrays
-- likewise undergo the ordinary C call-site decay. Recover only those two
-- pointer-bearing shapes here; a struct/union passed by value and an already
-- stored pointer alias intentionally do not become tracked automatic roots.
local function c_variadic_mutation_target(exp)
    local resolved = exp and types.resolve_c_typedef(exp._type)
    if not resolved then
        return nil
    elseif resolved._tag == "Type.CPointer" then
        return exp._type
    elseif resolved._tag == "Type.CArray" then
        return types.CPointer(resolved.elem, resolved.quals or {})
    end
    return nil
end

local function annotate_c_call_mutations(node, cfunc)
    assert(cfunc and cfunc._tag == "Type.CFunction",
        "C call mutation analysis requires a C function declaration")
    local mutated, seen = {}, {}
    for i, arg in ipairs(node.args.args) do
        local target = (cfunc.params or {})[i]
        if not target and cfunc.vararg then
            target = c_variadic_mutation_target(arg)
        end
        if target then
            local decl, source =
                mutable_c_call_argument_decl(arg, target)
            if decl and not seen[decl] then
                seen[decl] = true
                mark_mutable_c_address_source(source)
                table.insert(mutated, decl)
            end
        end
    end
    node._c_mutated_decls = #mutated > 0 and mutated or false
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
annotate_call_results = function(node, callable, demand, errors)
    demand = demand or default_call_result_demand(node)
    local signature = assert(call_signature(callable),
        "result checking requires a callable signature")
    node._callee_type = signature.callable
    node._types = signature.rettypes
    node._flexrettype = signature.flexrettype or false
    node._visible_types = {}
    node._result_sources = {}
    -- A function value may turn out to be an ordinary Lua callable at run
    -- time.  Record the target-directed conversion for every result that such
    -- a callable can place into a Titan result slot.  `false` is deliberate:
    -- it means this result type has no sound dynamic conversion (notably a raw
    -- C pointer), so the generated Lua-callable branch must reject rather than
    -- rediscovering a permissive category check.
    node._lua_result_dynamic_plans = {}
    node._strict_result_guard_plans = {}
    node._open_results = false
    node._finite_flex_prefix = 0

    local nfixed = #signature.rettypes
    local ndemand = #demand.fixed
    local function add(typ, source)
        table.insert(node._visible_types, typ)
        table.insert(node._result_sources, source)
        table.insert(node._lua_result_dynamic_plans,
            types.dynamic_coercion(typ) or false)
        table.insert(node._strict_result_guard_plans,
            types.gradual_guard(typ) or false)
    end

    for i = 1, math.min(ndemand, nfixed) do
        add(signature.rettypes[i], { kind = "fixed", index = i })
    end
    if signature.flexrettype and ndemand > nfixed then
        local count = ndemand - nfixed
        if count > TITAN_VARARG_MAX and not demand.suppress_flex_cap then
            checker.typeerror(errors, node.loc,
                "finite flexible-result demand is %d value(s), maximum is %d",
                count, TITAN_VARARG_MAX)
        end
        node._finite_flex_prefix = count
        for i = 1, count do
            add(optionize(signature.flexrettype), {
                kind = "flex", index = i, may_absent = true,
            })
        end
    end

    if demand.tail then
        for i = ndemand + 1, nfixed do
            add(signature.rettypes[i], { kind = "fixed", index = i })
        end
        if signature.flexrettype then
            local start = math.max(ndemand - nfixed, 0) + 1
            local target = expected_type(demand.tail) or signature.flexrettype
            node._open_results = {
                source = node,
                source_type = signature.flexrettype,
                target_type = target,
                start = start,
            }
            node._lua_open_result_dynamic_plan =
                types.dynamic_coercion(signature.flexrettype) or false
            node._strict_open_result_guard_plan =
                types.gradual_guard(signature.flexrettype) or false
            node._flex_result_demand = "open"
        end
    elseif signature.flexrettype then
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
    elseif decl._tag == "Ast.TopLevelForeignFunc" then
        return decl._paramnames, "foreign", true
    elseif decl._tag == "Type.StaticMethod" then
        return decl.paramnames, "titan", false
    elseif decl._tag == "Type.ModuleMember" and decl.type then
        local foreign = checker._foreign_function_reference(var) ~= nil
        if decl.type._tag == "Type.Function"
           or decl.type._tag == "Type.FunctionScheme" then
            return decl.paramnames, "titan", false
        elseif foreign and decl.type._tag == "Type.CFunction" then
            return decl.paramnames, "foreign", true
        end
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
local function check_named_args(callable, paramnames, fields, loc, fname, st, errors)
    local signature = assert(call_signature(callable),
        "named-call checking requires a callable signature")
    assert(type(paramnames) == "table")
    assert(#paramnames == #signature.params,
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
            local ptype = signature.params[index]
            checkexp(field.exp, st, errors, ptype)
            local term =
                "named argument '" .. field.name .. "' of " .. fname
            local exp = coerce_and_check(
                field.exp, ptype, term, errors, field.loc)
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
            local ptype = signature.params[i]
            local exp = ast.ExpNil(loc)
            exp._type = types.Nil()
            local adjustment =
                types.assignment_adjustment(exp._type, ptype)
            if adjustment then
                exp = coerce_and_check(exp, ptype,
                    "omitted named argument '" .. name .. "' of " .. fname,
                    errors, loc, adjustment)
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

local function is_direct_c_bitfield_expression(exp)
    return exp
       and exp._tag == "Ast.ExpVar"
       and exp.var
       and exp.var._decl
       and exp.var._decl._tag == "Type.CField"
       and exp.var._decl.bitfield ~= false
end

local function reject_direct_c_bitfield(node, operands, errors)
    for _, operand in ipairs(operands) do
        if is_direct_c_bitfield_expression(operand) then
            checker.typeerror(errors, operand.loc or node.loc,
                "C operator '%s' cannot be applied directly to bit-field "
                .. "'%s'; cast the bit-field to an ordinary C or Titan "
                .. "integer type first",
                node.op, operand.var._decl.name)
            node._type = types.Invalid()
            return true
        end
    end
    return false
end

local function c_operator_pointer_type(typ)
    local value = csemantics.decay_array(typ)
    value = types.resolve_c_typedef(value)
    return value and value._tag == "Type.CPointer"
        and value or nil
end

local function c_operator_integer_type(typ)
    typ = types.resolve_c_typedef(typ)
    return typ and (typ._tag == "Type.Integer"
        or typ._tag == "Type.CInteger") or false
end

local function reject_invisible_c_operator_pointee(
        node, st, errors, operand, subject)
    local pointer = c_operator_pointer_type(operand._type)
    if not pointer then return false end
    local err = incomplete_c_object_error(
        pointer.pointee, st, subject)
    if not err then return false end
    checker.typeerror(errors, operand.loc or node.loc, "%s", err)
    node._type = types.Invalid()
    return true
end

local function reject_invisible_c_operator_object(node, st, errors)
    if node._tag ~= "Ast.ExpBinop"
       or (node.op ~= "+" and node.op ~= "-") then
        return false
    end

    local lhs_pointer = c_operator_pointer_type(node.lhs._type)
    local rhs_pointer = c_operator_pointer_type(node.rhs._type)
    local lhs_integer = c_operator_integer_type(node.lhs._type)
    local rhs_integer = c_operator_integer_type(node.rhs._type)
    if node.op == "+"
       and lhs_pointer and rhs_integer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.lhs,
            "C operator '+' pointer arithmetic")
    elseif node.op == "+"
       and lhs_integer and rhs_pointer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.rhs,
            "C operator '+' pointer arithmetic")
    elseif node.op == "-"
       and lhs_pointer and rhs_integer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.lhs,
            "C operator '-' pointer arithmetic")
    elseif node.op == "-"
       and lhs_pointer and rhs_pointer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.lhs,
            "C operator '-' pointer subtraction")
            or reject_invisible_c_operator_pointee(
                node, st, errors, node.rhs,
                "C operator '-' pointer subtraction")
    end
    return false
end

local function finish_c_operator(node, st, errors, decide, operands)
    if reject_direct_c_bitfield(node, operands, errors) then
        return true
    end
    for _, operand in ipairs(operands) do
        if operand._type._tag == "Type.Invalid" then
            node._type = types.Invalid()
            return true
        end
    end
    if reject_invisible_c_operator_object(node, st, errors) then
        return true
    end

    local trait, decision_error = decide(st.c_profile)
    if not trait and decision_error
       and decision_error:match("target profile") then
        local _, profile_error = ensure_probe_service(st)
        if not st.c_profile then
            checker.typeerror(errors, node.loc,
                "cannot determine C operator '%s' semantics because the "
                .. "configured C probe service is unavailable: %s",
                node.op, tostring(profile_error))
            node._type = types.Invalid()
            return true
        end
        trait, decision_error = decide(st.c_profile)
    end
    if not trait then
        checker.typeerror(errors, node.loc, "%s",
            decision_error or
                ("unsupported C operator '" .. tostring(node.op) .. "'"))
        node._type = types.Invalid()
        return true
    end

    local module_probe, probe_error = checker._probe_for_c_types(st, {
        trait.lhs_source, trait.lhs_target,
        trait.rhs_source, trait.rhs_target,
    })
    if not module_probe then
        checker.typeerror(errors, node.loc,
            "cannot validate C operator '%s' because the configured "
            .. "C probe service is unavailable: %s",
            node.op, tostring(probe_error))
        node._type = types.Invalid()
        return true
    end

    local probe = module_probe:probe_operator(trait)
    if not probe or probe.status ~= "success" then
        checker.typeerror(errors, node.loc, "%s",
            probe and probe.message or
                "cannot validate C operator because the probe returned no result")
        node._type = types.Invalid()
        return true
    end

    trait.probe_key = probe.key
    node._c_operator = trait
    node._type = trait.result
    return true
end

local function check_c_unary_operator(node, st, errors)
    if not csemantics.is_unary_operator_candidate(
            node.op, node.exp._type) then
        return false
    end
    return finish_c_operator(node, st, errors, function(profile)
        return csemantics.decide_unary_operator(
            profile, node.op, node.exp._type)
    end, {node.exp})
end

local function check_c_binary_operator(node, st, errors)
    if not csemantics.is_binary_operator_candidate(
            node.op, node.lhs._type, node.rhs._type) then
        return false
    end
    return finish_c_operator(node, st, errors, function(profile)
        return csemantics.decide_binary_operator(
            profile, node.op, node.lhs._type, node.rhs._type)
    end, {node.lhs, node.rhs})
end

local function interface_downcast_plan(source, target, st)
    local source_nominal = source
    local source_optional = false
    if source_nominal._tag == "Type.Option" then
        source_optional = true
        source_nominal = source_nominal.base
    end
    if source_nominal._tag ~= "Type.Nominal"
       or target._tag ~= "Type.Nominal" then
        return nil
    end
    local interface = types.registry[source_nominal.fqtn]
    local concrete = types.registry[target.fqtn]
    if not interface or interface._tag ~= "Type.Interface"
       or not concrete
       or (concrete._tag ~= "Type.Record"
           and concrete._tag ~= "Type.Union")
       or not is_nominal_visible_from(st, target.fqtn) then
        return nil
    end
    return {
        kind = "interface_downcast",
        source = source,
        target = target,
        interface = interface,
        concrete = concrete,
        source_optional = source_optional,
    }
end

-- Check the source/target relation shared by a written `as` cast and its
-- non-raising `is` predicate. Both constructs contextualize and check the
-- operand exactly once, admit the same explicit C conversions, and carry the
-- same pointer-conversion annotation into code generation. Their result types
-- differ in the expression visitor below.
local function check_explicit_cast_relation(node, st, errors)
    node.target = typefromnode(node.target, st, errors)
    report_incomplete_c_object(node.target, st,
        "by-value C cast target", node.loc, errors)
    checkexp(node.exp, st, errors, node.target)
    local source = node.exp._type
    local target = node.target
    if source._tag == "Type.Invalid" or target._tag == "Type.Invalid" then
        node._written_cast_failed = true
        node._written_cast = false
        return target
    end
    local cast_plan
    local applied_application, application_plan =
        checker._generic.applied_nominal_adjustment(source, target, st)
    if not applied_application
       and (source._tag == "Type.Option" or target._tag == "Type.Option") then
        local source_base = source._tag == "Type.Option" and source.base or source
        local target_base = target._tag == "Type.Option" and target.base or target
        local inner_applied, inner_plan =
            checker._generic.applied_nominal_adjustment(
                source_base, target_base, st)
        if inner_applied then
            applied_application = true
            application_plan = inner_plan and types.written_cast(
                types.erase(source), types.erase(target)) or false
        end
    end
    local rigid_source = checker._generic.rigid_parameter_carrier(source)
    local rigid_target = checker._generic.rigid_parameter_carrier(target)
    if applied_application then
        if application_plan then
            if application_plan.kind == "written_cast" then
                cast_plan = application_plan
            else
                cast_plan = {
                    kind = "written_cast",
                    op = "identity",
                    source = source,
                    target = target,
                    generic_view = application_plan,
                }
            end
        end
    elseif rigid_source or rigid_target then
        local effective_source = rigid_source or source
        local effective_target = rigid_target or target
        local carrier_plan = types.written_cast(
            effective_source, effective_target)
        if carrier_plan then
            cast_plan = {
                kind = "written_cast",
                op = "rigid_carrier",
                source = source,
                target = target,
                carrier_source = effective_source,
                carrier_target = effective_target,
                carrier = carrier_plan,
            }
        end
    else
        cast_plan = types.written_cast(source, target)
    end
    local interface_failure

    -- Written concrete-to-Interface casts authorize only the direct scalar
    -- pair. In particular, do not pass this policy to the first general query:
    -- doing so would silently admit source/target Option lifting that Titan's
    -- written cast table deliberately excludes.
    if not cast_plan
       and source._tag == "Type.Nominal"
       and target._tag == "Type.Nominal" then
        local concrete = types.registry[source.fqtn]
        local interface = types.registry[target.fqtn]
        if concrete
           and (concrete._tag == "Type.Record"
                or concrete._tag == "Type.Union")
           and interface and interface._tag == "Type.Interface" then
            local policy = interface_relation_policy(st)
            cast_plan = types.written_cast(source, target, policy)
            interface_failure = policy.interface_failure or nil
            if cast_plan then
                local conversion = make_interface_conversion(
                    source, target, cast_plan)
                cast_plan.interface_conversion = conversion
                node._interface_conversion = conversion
                if node._tag == "Ast.ExpIs" then
                    node._interface_test = {
                        kind = "interface_implementation_test",
                        conversion = conversion,
                        allocation_free = true,
                    }
                end
            end
        end
    end

    if not cast_plan then
        local downcast = interface_downcast_plan(source, target, st)
        if downcast then
            node._interface_downcast = downcast
            cast_plan = {
                kind = "written_cast",
                op = "interface_downcast",
                source = source,
                target = target,
                interface = downcast.interface,
                concrete = downcast.concrete,
                source_optional = downcast.source_optional,
                downcast = downcast,
            }
            if node._tag == "Ast.ExpIs" then
                node._interface_test = {
                    kind = "interface_downcast_test",
                    downcast = downcast,
                    allocation_free = true,
                }
            end
        end
    end

    if is_mutable_c_address_source(node.exp)
       and types.c_mutable_address_coerceable(source, target)
       and not types.c_address_coerceable(source, target) then
        mark_mutable_c_address_source(node.exp)
        assert(not cast_plan,
            "mutable C-address cast unexpectedly has a type-only plan")
        cast_plan = {
            kind = "written_cast",
            op = "coercion",
            source = source,
            target = target,
            coercion = {
                kind = "coercion",
                op = "mutable_c_address",
                source = source,
                target = target,
            },
        }
    elseif types.c_mutable_address_coerceable(source, target) then
        checker.typeerror(errors, node.exp.loc,
            "cannot take a mutable C address of non-addressable "
            .. "expression of type '%s'",
            types.tostring(source))
        node._written_cast_failed = true
        return target
    elseif not cast_plan then
        if report_interface_failure(
                errors, node.loc, interface_failure) then
            node._written_cast_failed = true
            node._written_cast = false
            return target
        end
        -- Unsafe object-pointer reinterpretation and mutable local address
        -- taking depend on expression shape and, for the former, the active C
        -- toolchain. They are deliberately absent from the type-only written
        -- relation and become complete plans only here.
        local conversion = checker._unsafe_c_pointer_conversion(
            node.exp, target, errors, "explicit C cast")
        if conversion then
            node._c_conversion = conversion
            cast_plan = {
                kind = "written_cast",
                op = "explicit",
                source = source,
                target = target,
                conversion = conversion,
            }
        elseif conversion == false then
            -- The conversion helper already emitted the more precise
            -- category/qualifier/probe diagnostic.
            node._written_cast_failed = true
            return target
        end
    end
    node._written_cast = cast_plan or false
    if node._tag == "Ast.ExpCast"
       and cast_plan and cast_plan.op == "callable" then
        node._callable_adapter = checker.freeze_callable_adapter(
            cast_plan.callable, source, target, node.loc)
    end
    if not cast_plan then
        checker.typeerror(errors, node.loc, "cannot cast '%s' to '%s'",
            types.tostring(source), types.tostring(target))
    end
    return target
end

function checker._generic.recover_complete_type_arguments(
        typearg_nodes, count, st, errors, loc, subject)
    local arguments = checker._generic.resolve_type_argument_nodes(
        typearg_nodes, st, errors)
    local written = #arguments
    local valid = written == count
    if written == 0 and count > 0 then
        checker.typeerror(errors, loc,
            "%s is generic and requires an explicit complete type argument list in this checker phase",
            subject)
    elseif written ~= count then
        checker.typeerror(errors, loc,
            "%s expected %d type arguments but found %d",
            subject, count, written)
    end

    -- Keep substitution total after an error, but never silently turn an
    -- ineligible written argument into `value`: emit the admission diagnostic
    -- before installing that recovery carrier.
    local recovered = {}
    for index = 1, count do
        local argument = arguments[index]
        if argument and types.transient_roundtrip(argument) then
            recovered[index] = argument
        else
            if argument and argument._tag ~= "Type.Invalid" then
                checker.typeerror(errors, loc,
                    "%s type argument %d ('%s') has no sound transient round trip",
                    subject, index, types.tostring(argument))
            end
            recovered[index] = types.Value()
            valid = false
        end
    end
    return recovered, valid
end

function checker._generic.callable_function_type(callable)
    return types.Function(callable.params, callable.rettypes, false,
        callable.varargtype or false, callable.flexrettype or false)
end


function checker._generic.inference_scope_entry(scope, typeparams, parameters)
    local entry = {
        scope = scope,
        typeparams = typeparams or {},
        parameters = parameters or {},
        cells = {},
    }
    for index, typeparam in ipairs(entry.typeparams) do
        local parameter = entry.parameters[index]
        if not parameter then
            parameter = types.Parameter(scope, index, typeparam.name,
                typeparam.constraint == false and false
                    or types.erase_constraint(typeparam.constraint))
        end
        entry.parameters[index] = parameter
        entry.cells[index] = {
            name = typeparam.name,
            parameter = parameter,
            binding = false,
            evidence = false,
            invalid = false,
            conflicts = {},
        }
    end
    return entry
end

function checker._generic.new_inference_context(subject, scopes, st, errors, loc)
    return {
        subject = subject,
        scopes = scopes,
        st = st,
        errors = errors,
        loc = loc,
        closed = false,
    }
end

function checker._generic.inference_cell(context, parameter)
    if not parameter or parameter._tag ~= "Type.Parameter" then return nil end
    for _, entry in ipairs(context.scopes) do
        if types.same_generic_scope(entry.scope, parameter.scope) then
            return entry.cells[parameter.index]
        end
    end
    return nil
end

function checker._generic.inference_evidence_name(evidence)
    return evidence or "type context"
end

function checker._generic.bind_inference_cell(context, cell, candidate,
                                               evidence, loc)
    candidate = types.normalize(candidate) or candidate
    if not candidate or candidate._tag == "Type.Invalid" then return false end
    if not cell.binding then
        cell.binding = candidate
        cell.evidence = checker._generic.inference_evidence_name(evidence)
        cell.loc = loc
        return true
    end
    if types.equals(cell.binding, candidate) then return true end

    local key = types.tostring(candidate)
    if not cell.conflicts[key] then
        cell.conflicts[key] = true
        checker.typeerror(context.errors, loc or context.loc,
            "conflicting type evidence for type parameter '%s' in %s: "
            .. "inferred '%s' from %s but found '%s' from %s",
            cell.name, context.subject, types.tostring(cell.binding),
            cell.evidence, key, checker._generic.inference_evidence_name(evidence))
    end
    cell.invalid = true
    return false
end

-- Inference is deliberately invariant. It decomposes only the structural
-- shapes promised by generics v1 and never asks the ordinary coercion or
-- consistency relations to choose a binding.
function checker._generic.unify_inference(context, pattern, evidence,
                                          term, loc, seen)
    if not pattern or not evidence then return false end
    pattern, evidence = types.normalize(pattern), types.normalize(evidence)
    if not pattern or not evidence
       or pattern._tag == "Type.Invalid"
       or evidence._tag == "Type.Invalid" then
        return false
    end

    local cell = checker._generic.inference_cell(context, pattern)
    if cell then
        return checker._generic.bind_inference_cell(
            context, cell, evidence, term, loc)
    end
    if types.equals(pattern, evidence) then return true end

    seen = seen or {}
    local pair_key = pattern
    local evidence_seen = seen[pair_key]
    if evidence_seen and evidence_seen[evidence] then return true end
    evidence_seen = evidence_seen or {}
    seen[pair_key] = evidence_seen
    evidence_seen[evidence] = true

    local ptag, etag = pattern._tag, evidence._tag
    if ptag == "Type.Option" and etag == "Type.Option" then
        return checker._generic.unify_inference(context,
            pattern.base, evidence.base, term, loc, seen)
    elseif ptag == "Type.Option" and etag == "Type.Value" then
        -- Option(value) canonicalizes to value. This is reconstruction of the
        -- same invariant application, not a lifted gradual conversion.
        return checker._generic.unify_inference(context,
            pattern.base, evidence, term, loc, seen)
    elseif ptag == "Type.Array" and etag == "Type.Array" then
        return checker._generic.unify_inference(context,
            pattern.elem, evidence.elem, term, loc, seen)
    elseif ptag == "Type.Map" and etag == "Type.Map" then
        local keys = checker._generic.unify_inference(context,
            pattern.keys, evidence.keys, term, loc, seen)
        local values = checker._generic.unify_inference(context,
            pattern.values, evidence.values, term, loc, seen)
        return keys and values
    elseif ptag == "Type.Nominal" and etag == "Type.Nominal"
       and pattern.fqtn == evidence.fqtn
       and #(pattern.args or {}) == #(evidence.args or {}) then
        local ok = true
        for index, argument in ipairs(pattern.args or {}) do
            ok = checker._generic.unify_inference(context, argument,
                evidence.args[index], term, loc, seen) and ok
        end
        return ok
    elseif ptag == "Type.Function" and etag == "Type.Function"
       and #pattern.params == #evidence.params
       and #pattern.rettypes == #evidence.rettypes
       and (pattern.varargtype == false) == (evidence.varargtype == false)
       and (pattern.flexrettype == false) == (evidence.flexrettype == false) then
        local ok = true
        for index, parameter in ipairs(pattern.params) do
            ok = checker._generic.unify_inference(context, parameter,
                evidence.params[index], term, loc, seen) and ok
        end
        for index, result in ipairs(pattern.rettypes) do
            ok = checker._generic.unify_inference(context, result,
                evidence.rettypes[index], term, loc, seen) and ok
        end
        if pattern.varargtype ~= false then
            ok = checker._generic.unify_inference(context,
                pattern.varargtype, evidence.varargtype,
                term, loc, seen) and ok
        end
        if pattern.flexrettype ~= false then
            ok = checker._generic.unify_inference(context,
                pattern.flexrettype, evidence.flexrettype,
                term, loc, seen) and ok
        end
        return ok
    end
    return false
end

function checker._generic.inference_arguments(entry, recover)
    local arguments = {}
    for index, cell in ipairs(entry.cells) do
        arguments[index] = cell.binding
            or (recover and types.Value())
            or entry.parameters[index]
    end
    return arguments
end

function checker._generic.substitute_inference(context, typ, recover)
    local out = typ
    for _, entry in ipairs(context.scopes) do
        out = checker._generic.generic_substitute(out, entry.scope,
            checker._generic.inference_arguments(entry, recover), context.errors,
            context.loc, "cannot close " .. context.subject) or out
    end
    return out
end

function checker._generic.inference_type_has_unresolved(context, typ, seen)
    if typ == false or typ == nil or type(typ) ~= "table" then return false end
    seen = seen or {}
    if seen[typ] then return false end
    seen[typ] = true

    if typ._tag == "Type.Parameter" then
        local cell = checker._generic.inference_cell(context, typ)
        return cell ~= nil and not cell.binding
    end
    for key, value in pairs(typ) do
        if key ~= "scope" and type(value) == "table" then
            if value._tag then
                if checker._generic.inference_type_has_unresolved(context, value, seen) then
                    return true
                end
            else
                for _, item in pairs(value) do
                    if checker._generic.inference_type_has_unresolved(context, item, seen) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function checker._generic.closed_inference_pattern(context, typ)
    local substituted = checker._generic.substitute_inference(
        context, typ, false)
    if checker._generic.inference_type_has_unresolved(context, substituted) then return nil end
    return substituted
end

function checker._generic.inference_type_arguments(context)
    local arguments = {}
    for _, entry in ipairs(context.scopes) do
        for _, cell in ipairs(entry.cells) do
            arguments[#arguments + 1] = cell.binding or types.Value()
        end
    end
    return arguments
end

function checker._generic.propagate_inference_constraint_evidence(context)
    local cell_count = 0
    for _, entry in ipairs(context.scopes) do
        cell_count = cell_count + #entry.cells
    end
    for _ = 1, math.max(1, cell_count) do
        local before = 0
        for _, entry in ipairs(context.scopes) do
            for _, cell in ipairs(entry.cells) do
                if cell.binding then before = before + 1 end
            end
        end
        for _, entry in ipairs(context.scopes) do
            for index, typeparam in ipairs(entry.typeparams) do
                local cell = entry.cells[index]
                local argument = cell and cell.binding
                if argument and argument._tag == "Type.Parameter"
                   and typeparam.constraint ~= false then
                    local binders = context.st.generic_scope_bindings
                        and context.st.generic_scope_bindings[argument.scope]
                    local declared = binders and binders[argument.index]
                    if declared and declared.constraint ~= false then
                        local required = checker._generic.substitute_inference(
                            context, typeparam.constraint, false)
                        checker._generic.unify_inference(context,
                            required, declared.constraint,
                            "declared constraint of rigid argument '" ..
                                tostring(argument.name or argument.index) .. "'",
                            cell.loc or context.loc)
                    end
                end
            end
        end
        local after = 0
        for _, entry in ipairs(context.scopes) do
            for _, cell in ipairs(entry.cells) do
                if cell.binding then after = after + 1 end
            end
        end
        if after == before then break end
    end
end

function checker._generic.close_inference_context(context)
    if context.closed then return context.valid end
    checker._generic.propagate_inference_constraint_evidence(context)
    context.closed = true
    local valid = true

    for _, entry in ipairs(context.scopes) do
        for _, cell in ipairs(entry.cells) do
            if not cell.binding then
                checker.typeerror(context.errors, context.loc,
                    "cannot infer type argument '%s' for %s; provide a complete explicit type argument list",
                    cell.name, context.subject)
                cell.binding = types.Value()
                cell.invalid = true
                valid = false
            elseif not types.transient_roundtrip(cell.binding) then
                checker.typeerror(context.errors, cell.loc or context.loc,
                    "%s inferred type argument '%s' for '%s', which has no sound transient round trip",
                    context.subject, types.tostring(cell.binding), cell.name)
                cell.binding = types.Value()
                cell.invalid = true
                valid = false
            elseif cell.invalid then
                valid = false
            end
        end
    end

    -- Constraints may mention owner and callable-local binders. Substitute the
    -- complete fresh application through every scope before checking each one.
    for _, entry in ipairs(context.scopes) do
        for index, typeparam in ipairs(entry.typeparams) do
            local cell = entry.cells[index]
            if not cell.invalid and typeparam.constraint ~= false then
                local constraint = checker._generic.substitute_inference(
                    context, typeparam.constraint, true)
                local satisfied = checker._generic.generic_constraint_satisfied(
                    cell.binding, constraint, context.st)
                if not satisfied then
                    checker.typeerror(context.errors, cell.loc or context.loc,
                        "type argument %d ('%s') for %s does not satisfy constraint '%s'",
                        index, types.tostring(cell.binding), context.subject,
                        types.tostring(constraint))
                    valid = false
                end
            end
        end
    end
    context.valid = valid
    return valid
end

function checker._generic.infer_result_evidence(context, signature, demand)
    for index, target in ipairs(demand.fixed or {}) do
        target = expected_type(target)
        if target then
            local pattern = signature.rettypes[index]
            if not pattern and signature.flexrettype then
                pattern = optionize(signature.flexrettype)
            end
            if pattern then
                checker._generic.unify_inference(context, pattern, target,
                    "expected result " .. index, demand.loc or context.loc)
            end
        end
    end
    local tail = expected_type(demand.tail)
    if tail then
        for index = #(demand.fixed or {}) + 1, #signature.rettypes do
            checker._generic.unify_inference(context,
                signature.rettypes[index], tail,
                "expected open result", demand.loc or context.loc)
        end
        if signature.flexrettype then
            checker._generic.unify_inference(context,
                signature.flexrettype, tail,
                "expected open result", demand.loc or context.loc)
        end
    end
end

function checker._generic.generic_lambda_full_explicit_type(node)
    local nparams = #node.params
    local vararg = node.params[nparams]
    local has_vararg = vararg and vararg.name == false
    local nfixed = has_vararg and nparams - 1 or nparams
    local params = {}
    for index = 1, nfixed do
        local typ = node.params[index]._generic_inference_type
        if not typ then return nil end
        params[index] = typ
    end
    local varargtype = false
    if has_vararg then
        varargtype = vararg._generic_inference_type
        if not varargtype then return nil end
    end
    if type(node.rettypes) ~= "table"
       or node._generic_inference_rettypes == nil then
        return nil
    end
    return types.Function(params, node._generic_inference_rettypes,
        false, varargtype, node._generic_inference_flexrettype)
end

function checker._generic.prepare_lambda_inference(node, pattern,
                                                   context, st, errors)
    local nparams = #node.params
    local vararg = node.params[nparams]
    local has_vararg = vararg and vararg.name == false
    local nfixed = has_vararg and nparams - 1 or nparams
    for index = 1, nfixed do
        local parameter = node.params[index]
        if parameter.type and not parameter._generic_inference_type then
            parameter._generic_inference_type =
                typefromnode(parameter.type, st, errors)
        end
    end
    if has_vararg and vararg.type and not vararg._generic_inference_type then
        vararg._generic_inference_type = check_varg_elem(
            typefromnode(vararg.type, st, errors), vararg.loc,
            errors, "parameter")
    end
    if type(node.rettypes) == "table"
       and node._generic_inference_rettypes == nil then
        node._generic_inference_rettypes = {}
        for index, typenode in ipairs(node.rettypes) do
            node._generic_inference_rettypes[index] =
                typefromnode(typenode, st, errors)
        end
        node._generic_inference_flexrettype = node.flexrettype
            and check_varg_elem(typefromnode(node.flexrettype, st, errors),
                node.flexrettype.loc or node.loc, errors, "return")
            or false
    end

    local current = checker._generic.substitute_inference(
        context, pattern, false)
    local cell = current._tag == "Type.Parameter"
        and checker._generic.inference_cell(context, current) or nil
    if cell then
        local explicit = checker._generic.generic_lambda_full_explicit_type(node)
        if explicit then
            checker._generic.bind_inference_cell(context, cell, explicit,
                "explicit lambda signature", node.loc)
        end
        return
    end
    if current._tag ~= "Type.Function" or #current.params ~= nfixed then
        return
    end

    for index = 1, nfixed do
        local actual = node.params[index]._generic_inference_type
        if actual then
            checker._generic.unify_inference(context,
                current.params[index], actual,
                "lambda parameter " .. index, node.params[index].loc)
        end
    end
    if has_vararg and vararg._generic_inference_type
       and current.varargtype ~= false then
        checker._generic.unify_inference(context,
            current.varargtype, vararg._generic_inference_type,
            "lambda variadic parameter", vararg.loc)
    end
    if node._generic_inference_rettypes
       and #node._generic_inference_rettypes == #current.rettypes then
        for index, actual in ipairs(node._generic_inference_rettypes) do
            checker._generic.unify_inference(context,
                current.rettypes[index], actual,
                "lambda result " .. index, node.loc)
        end
        if node._generic_inference_flexrettype ~= false
           and current.flexrettype ~= false then
            checker._generic.unify_inference(context,
                current.flexrettype, node._generic_inference_flexrettype,
                "lambda flexible result", node.loc)
        end
    end
end

function checker._generic.generic_formal_pattern(signature, index)
    return signature.params[index] or signature.varargtype or nil
end

function checker._generic.generic_expression_result_types(exp)
    if exp._tag == "Ast.ExpCall" then
        return exp._visible_types or exp._types or {},
            exp._open_results and exp._open_results.source_type or false
    end
    return { exp._type }, false
end

function checker._generic.generic_unify_expression_results(context, signature, exp,
                                                first, term)
    local results, open = checker._generic.generic_expression_result_types(exp)
    local index = first
    for _, actual in ipairs(results) do
        local pattern = checker._generic.generic_formal_pattern(signature, index)
        if pattern then
            checker._generic.unify_inference(context, pattern, actual,
                term .. " " .. index, exp.loc)
        end
        index = index + 1
    end
    if open and signature.varargtype then
        checker._generic.unify_inference(context,
            signature.varargtype, open, term .. " open tail", exp.loc)
    end
end

function checker._generic.generic_discovery_demand(context, signature, first, original)
    local fixed = {}
    for offset = 1, #(original.fixed or {}) do
        local pattern = checker._generic.generic_formal_pattern(signature, first + offset - 1)
        fixed[offset] = pattern
            and checker._generic.closed_inference_pattern(context, pattern)
            or UNKNOWN_SLOT
    end
    local tail = false
    if original.tail then
        tail = signature.varargtype
            and checker._generic.closed_inference_pattern(
                context, signature.varargtype)
            or INFER_OPEN
    end
    return result_demand(fixed, tail, {
        term = original.term,
        loc = original.loc,
        suppress_flex_cap = original.suppress_flex_cap,
    })
end

function checker._generic.finish_generic_open_arguments(adjusted, target, st, errors,
                                             term)
    if not adjusted.open_source then return end
    adjusted.open_target = target
    local allow = adjusted.open_source._tag ~= "Ast.ExpDots"
    local adjustment, interface_conversion, interface_failure =
        checker_assignment_adjustment(adjusted.open_type, target, st, {
            allow_coercion = allow,
        })
    adjusted.open_adjustment = adjustment or false
    adjusted.open_callable_adapter = adjustment
        and adjustment.kind == "callable"
        and checker.freeze_callable_adapter(adjustment,
            adjusted.open_type, target, adjusted.open_source.loc)
        or false
    adjusted.open_interface_conversion = interface_conversion or false
    local open = adjusted.open_source._tag == "Ast.ExpDots"
        and adjusted.open_source._open_dots
        or adjusted.open_source._open_results
    if open then
        open.target_type = target
        open.adjustment = adjusted.open_adjustment
        open.callable_adapter = adjusted.open_callable_adapter
    end
    if not adjustment
       and adjusted.open_type._tag ~= "Type.Invalid"
       and target._tag ~= "Type.Invalid" then
        if not report_interface_failure(
                errors, adjusted.open_source.loc, interface_failure) then
            checker.typeerror(errors, adjusted.open_source.loc,
                "open argument element type %s is not compatible with %s element type %s",
                types.tostring(adjusted.open_type), term,
                types.tostring(target))
        end
    end
end

function checker._generic.close_generic_adjusted_arguments(adjusted, args, signature,
                                                st, errors, term)
    for index, exp in pairs(adjusted.fixed) do
        local target = signature.params[index]
        if target then
            local replacement = coerce_and_check(exp, target,
                "argument " .. index .. " of " .. term,
                errors, exp.loc)
            replace_adjusted_value(adjusted, exp, replacement)
        end
    end
    if signature.varargtype then
        for _, exp in ipairs({ table.unpack(adjusted.tail_scalars) }) do
            local replacement = coerce_and_check(exp, signature.varargtype,
                "variadic argument of " .. term, errors, exp.loc)
            replace_adjusted_value(adjusted, exp, replacement)
        end
        checker._generic.finish_generic_open_arguments(adjusted, signature.varargtype,
            st, errors, term)
    end
    for index = #args, 1, -1 do args[index] = nil end
    for _, exp in ipairs(adjusted.exps) do args[#args + 1] = exp end
end

function checker._generic.is_generic_first_class_expression(
        exp, st, errors)
    if exp._tag ~= "Ast.ExpVar" then return false end
    if exp.var._tag == "Ast.VarName" then
        local declaration = st:find_symbol(exp.var.name)
        local declared = declaration and declaration._type
        if not declared or declared._tag ~= "Type.FunctionScheme" then
            return false
        end
    end
    checkvar(exp.var, st, errors)
    if exp.var._decl then exp.var._decl._used = true end
    exp._type = exp.var._type
    local generic = exp._type._tag == "Type.FunctionScheme"
        or (exp._type._tag == "Type.Function"
            and exp.var._generic_declaration ~= nil)
    exp._generic_var_prechecked = generic and true or nil
    return generic
end

function checker._generic.infer_positional_call(context, signature, args,
                                                st, errors, term)
    local deferred, deferred_by_exp = {}, {}
    for index, exp in ipairs(args) do
        local pattern = checker._generic.generic_formal_pattern(
            signature, index)
        if pattern and (exp._tag == "Ast.ExpFunction"
                or checker._generic.is_generic_first_class_expression(
                    exp, st, errors)) then
            if exp._tag == "Ast.ExpFunction" then
                checker._generic.prepare_lambda_inference(
                    exp, pattern, context, st, errors)
            end
            local item = { exp = exp, pattern = pattern }
            deferred[#deferred + 1] = item
            deferred_by_exp[exp] = item
        end
    end

    local fixed = {}
    for index = 1, #signature.params do fixed[index] = UNKNOWN_SLOT end
    local adjusted = adjust_explist(args,
        result_demand(fixed,
            signature.varargtype and INFER_OPEN or false, {
            term = term,
            open_term = term,
            loc = context.loc,
            missing = "nil",
            explicit_surplus = "discard",
            defer_open_check = true,
            check_expression = function(exp, est, eerrors, _, subdemand,
                                        sink_index)
                local pattern = checker._generic.generic_formal_pattern(
                    signature, sink_index)
                if deferred_by_exp[exp] then
                    exp._type = checker._generic.closed_inference_pattern(
                        context, pattern) or types.Invalid()
                    return
                end
                local demand = checker._generic.generic_discovery_demand(
                    context, signature, sink_index, subdemand)
                local expected = pattern and
                    checker._generic.closed_inference_pattern(
                        context, pattern) or nil
                checkexp(exp, est, eerrors, expected, demand)
                checker._generic.generic_unify_expression_results(
                    context, signature, exp, sink_index, "argument")
            end,
        }), st, errors)

    for index, exp in pairs(adjusted.fixed) do
        local pattern = checker._generic.generic_formal_pattern(
            signature, index)
        if pattern and not deferred_by_exp[exp] then
            checker._generic.unify_inference(context, pattern,
                exp._type, "argument " .. index, exp.loc)
        end
    end
    for _, exp in ipairs(adjusted.tail_scalars) do
        if signature.varargtype and not deferred_by_exp[exp] then
            checker._generic.unify_inference(context,
                signature.varargtype, exp._type,
                "variadic argument", exp.loc)
        end
    end
    if adjusted.open_source and signature.varargtype then
        checker._generic.unify_inference(context,
            signature.varargtype, adjusted.open_type,
            "open variadic argument", adjusted.open_source.loc)
    end

    checker._generic.close_inference_context(context)
    local closed = checker._generic.substitute_inference(
        context, signature, true)
    for _, item in ipairs(deferred) do
        local expected = checker._generic.substitute_inference(
            context, item.pattern, true)
        checkexp(item.exp, st, errors, expected,
            result_demand({ expected }, false, {
                term = "contextual generic argument",
            }))
    end
    checker._generic.close_generic_adjusted_arguments(
        adjusted, args, closed, st, errors, term)
    return closed, adjusted
end

function checker._generic.generic_decl_paramnames(node)
    local variable = node.exp._tag == "Ast.ExpVar" and node.exp.var or nil
    local declaration = variable and variable._decl or nil
    if not declaration then return nil end
    if declaration._tag == "Ast.TopLevelFunc" then
        return declaration._paramnames
    elseif declaration._tag == "Type.StaticMethod"
        or declaration._tag == "Type.Method" then
        return declaration.paramnames
    elseif declaration._tag == "Type.ModuleMember" then
        return declaration.paramnames
    end
end

function checker._generic.infer_named_call(context, signature, fields,
                                           paramnames, st, errors, term)
    if type(paramnames) ~= "table" then
        for _, field in ipairs(fields) do checkexp(field.exp, st, errors) end
        checker._generic.close_inference_context(context)
        return checker._generic.substitute_inference(
            context, signature, true), nil, nil
    end
    local byname = {}
    for index, name in ipairs(paramnames) do byname[name] = index end
    local deferred, supplied, checked = {}, {}, {}

    for _, field in ipairs(fields) do
        local index = byname[field.name]
        if not index then
            checker.typeerror(errors, field.loc,
                "%s has no parameter named '%s'%s", term, field.name,
                #paramnames > 0 and
                    ("; available parameters are " .. table.concat(paramnames, ", "))
                    or "")
            checkexp(field.exp, st, errors)
        else
            local pattern = signature.params[index]
            if field.exp._tag == "Ast.ExpFunction"
               or checker._generic.is_generic_first_class_expression(
                    field.exp, st, errors) then
                if field.exp._tag == "Ast.ExpFunction" then
                    checker._generic.prepare_lambda_inference(
                        field.exp, pattern, context, st, errors)
                end
                deferred[#deferred + 1] = {
                    exp = field.exp,
                    pattern = pattern,
                }
            else
                local expected = checker._generic.closed_inference_pattern(
                    context, pattern)
                checkexp(field.exp, st, errors, expected,
                    result_demand({ expected or UNKNOWN_SLOT }, false, {
                        term = "named generic argument",
                    }))
                checker._generic.unify_inference(context, pattern,
                    field.exp._type, "named argument '" .. field.name .. "'",
                    field.loc)
            end
            checked[field] = index
            if supplied[index] then
                checker.typeerror(errors, field.loc,
                    "named argument '%s' is supplied more than once", field.name)
            else
                supplied[index] = field
            end
        end
    end
    for index, name in ipairs(paramnames) do
        if not supplied[index] then
            checker._generic.unify_inference(context,
                signature.params[index], types.Nil(),
                "omitted named argument '" .. name .. "'", context.loc)
        end
    end

    checker._generic.close_inference_context(context)
    local closed = checker._generic.substitute_inference(
        context, signature, true)
    for _, item in ipairs(deferred) do
        local expected = checker._generic.substitute_inference(
            context, item.pattern, true)
        checkexp(item.exp, st, errors, expected,
            result_demand({ expected }, false, {
                term = "contextual generic argument",
            }))
    end

    local dense, order = {}, {}
    for _, field in ipairs(fields) do
        local index = checked[field]
        if index then
            local replacement = coerce_and_check(field.exp,
                closed.params[index],
                "named argument '" .. field.name .. "' of " .. term,
                errors, field.loc)
            if supplied[index] == field then
                dense[index] = replacement
                order[#order + 1] = index
            end
        end
    end
    for index, name in ipairs(paramnames) do
        if not dense[index] then
            local exp = ast.ExpNil(context.loc)
            exp._type = types.Nil()
            exp._missing_value = true
            exp = coerce_and_check(exp, closed.params[index],
                "omitted named argument '" .. name .. "' of " .. term,
                errors, context.loc)
            exp._named_omitted = true
            dense[index] = exp
        end
    end
    return closed, dense, order
end

function checker._generic.infer_call_application(context, signature, node,
                                                  demand, st, errors, term,
                                                  paramnames)
    checker._generic.infer_result_evidence(context, signature, demand)
    local closed, adjusted, dense, order
    local named = node.args._tag == "Ast.ArgsNamedFunc"
        or node.args._tag == "Ast.ArgsNamedMethod"
    if named then
        closed, dense, order = checker._generic.infer_named_call(
            context, signature, node.args.fields,
            paramnames or checker._generic.generic_decl_paramnames(node),
            st, errors, term)
        node._generic_named_dense = dense
        node._generic_named_order = order
    else
        closed, adjusted = checker._generic.infer_positional_call(
            context, signature, node.args.args, st, errors, term)
        node._generic_arg_adjustment = adjusted
    end
    return closed
end

function checker._generic.infer_first_class_application(
        subject, scopes, signature, expected, st, errors, loc)
    local context = checker._generic.new_inference_context(
        subject, scopes, st, errors, loc)
    checker._generic.unify_inference(context, signature, expected,
        "expected first-class function type", loc)
    checker._generic.close_inference_context(context)
    return checker._generic.substitute_inference(
        context, signature, true),
        checker._generic.inference_type_arguments(context), context
end


function checker._generic.instantiate_first_class_variable(
        node, variable, declared, expected, st, errors)
    if expected and expected._tag == "Type.Option"
       and expected.base._tag == "Type.Function" then
        expected = expected.base
    end
    if not expected or expected._tag ~= "Type.Function" then return nil end

    local subject = "generic declaration '" .. variable.name .. "'"
    local scopes, signature, declaration = {}, nil, nil
    if declared._tag == "Type.FunctionScheme" then
        scopes[1] = checker._generic.inference_scope_entry(
            declared.scope, declared.typeparams)
        signature = declared.signature
    elseif declared._tag == "Type.Function" then
        declaration = variable._generic_declaration or variable._decl
        if not declaration or declaration._tag ~= "Type.StaticMethod" then
            return nil
        end
        local owner = variable._generic_owner
            or types.registry[declaration.fqtn]
        if owner and #(owner.typeparams or {}) > 0 then
            scopes[#scopes + 1] = checker._generic.inference_scope_entry(
                owner.scope, owner.typeparams, owner._generic_parameters)
        end
        if #(declaration.typeparams or {}) > 0 then
            scopes[#scopes + 1] = checker._generic.inference_scope_entry(
                declaration.scope, declaration.typeparams)
        end
        if #scopes == 0 then return nil end
        signature = checker._generic.callable_function_type(declaration)
    else
        return nil
    end

    local closed, arguments, context =
        checker._generic.infer_first_class_application(
            subject, scopes, signature, expected,
            st, errors, node.loc)
    node._generic_type_arguments = arguments
    if declared._tag == "Type.FunctionScheme" then
        node._generic_scheme = declared
    else
        node._generic_declaration = declaration
        node._closed_generic_declaration =
            checker._generic.substitute_inference(
                context, declaration, true)
    end
    return closed
end

function checker._generic.instantiate_function_scheme(
        scheme, typearg_nodes, st, errors, loc, subject)
    local count = #(scheme.typeparams or {})
    local arguments, valid =
        checker._generic.recover_complete_type_arguments(
            typearg_nodes, count, st, errors, loc, subject)
    if valid then
        checker._generic.validate_binder_arguments(scheme.scope,
            scheme.typeparams, arguments, st, errors, loc, subject, false)
    end
    local closed = checker._generic.generic_substitute(
        scheme.signature, scheme.scope, arguments,
        errors, loc, "cannot instantiate " .. subject)
    return closed or scheme.signature, arguments
end

function checker._generic.instantiate_static_declaration(
        declaration, owner, typearg_nodes, st, errors, loc, subject)
    local owner_count = owner and #(owner.typeparams or {}) or 0
    local local_count = #(declaration.typeparams or {})
    local total = owner_count + local_count
    local arguments, valid =
        checker._generic.recover_complete_type_arguments(
            typearg_nodes, total, st, errors, loc, subject)
    local owner_arguments, local_arguments = {}, {}
    for index = 1, owner_count do
        owner_arguments[index] = arguments[index]
    end
    for index = 1, local_count do
        local_arguments[index] = arguments[owner_count + index]
    end

    local closed = declaration
    if owner_count > 0 then
        if valid then
            local owner_valid = checker._generic.validate_binder_arguments(
                owner.scope, owner.typeparams, owner_arguments,
                st, errors, loc, subject, false)
            if owner_valid then
                checker._generic.validate_owner_reconstruction(
                    owner, owner_arguments, st, errors, loc, subject, false)
            end
        end
        closed = checker._generic.generic_substitute(closed, owner.scope, owner_arguments,
            errors, loc, "cannot instantiate " .. subject) or closed
    end
    if local_count > 0 then
        -- Owner substitution also specializes constraints that mention owner
        -- binders, so validate against the fresh method/static view.
        if valid then
            checker._generic.validate_binder_arguments(closed.scope,
                closed.typeparams, local_arguments,
                st, errors, loc, subject, false)
        end
        closed = checker._generic.generic_substitute(closed, closed.scope, local_arguments,
            errors, loc, "cannot instantiate " .. subject) or closed
    end
    return checker._generic.callable_function_type(closed), arguments, closed
end

function checker._generic.instantiate_direct_call(
        node, ftype, st, errors, demand)
    local subject = "call to '" .. expname(node.exp) .. "'"
    if ftype._tag == "Type.FunctionScheme" then
        local closed, arguments
        if #(node.typeargs or {}) > 0 then
            closed, arguments = checker._generic.instantiate_function_scheme(
                ftype, node.typeargs, st, errors, node.loc, subject)
        else
            local context = checker._generic.new_inference_context(subject, {
                checker._generic.inference_scope_entry(ftype.scope, ftype.typeparams),
            }, st, errors, node.loc)
            closed = checker._generic.infer_call_application(
                context, ftype.signature, node, demand, st, errors, subject)
            arguments = checker._generic.inference_type_arguments(context)
        end
        node._generic_scheme = ftype
        node._generic_type_arguments = arguments
        node.exp._type = closed
        return closed
    end

    local variable = node.exp._tag == "Ast.ExpVar" and node.exp.var or nil
    local declaration = variable and variable._decl or nil
    if declaration and declaration._tag == "Type.StaticMethod" then
        local owner = variable._generic_owner
            or types.registry[declaration.fqtn]
        local owner_count = owner and #(owner.typeparams or {}) or 0
        local local_count = #(declaration.typeparams or {})
        local count = owner_count + local_count
        if count > 0 then
            local closed, arguments, closed_declaration
            if #(node.typeargs or {}) > 0 then
                closed, arguments, closed_declaration =
                    checker._generic.instantiate_static_declaration(
                        declaration, owner, node.typeargs, st, errors,
                        node.loc, subject)
            else
                local scopes = {}
                if owner_count > 0 then
                    scopes[#scopes + 1] = checker._generic.inference_scope_entry(
                        owner.scope, owner.typeparams,
                        owner._generic_parameters)
                end
                if local_count > 0 then
                    scopes[#scopes + 1] = checker._generic.inference_scope_entry(
                        declaration.scope, declaration.typeparams)
                end
                local context = checker._generic.new_inference_context(
                    subject, scopes, st, errors, node.loc)
                local signature = checker._generic.callable_function_type(
                    declaration)
                closed = checker._generic.infer_call_application(
                    context, signature, node, demand, st, errors, subject,
                    declaration.paramnames)
                arguments = checker._generic.inference_type_arguments(context)
                closed_declaration = checker._generic.substitute_inference(
                    context, declaration, true)
            end
            node._generic_declaration = declaration
            node._generic_type_arguments = arguments
            node._closed_generic_declaration = closed_declaration
            node.exp._type = closed
            return closed
        end
    end

    if #(node.typeargs or {}) > 0 then
        checker.typeerror(errors, node.loc,
            "%s is not generic and cannot receive type arguments", subject)
    end
    return ftype
end

function checker._generic.instantiate_method_declaration(
        node, method, st, errors, owner_name, demand)
    local count = #(method.typeparams or {})
    local subject = "call to method '" .. owner_name .. ":"
        .. node.args.method .. "'"
    if count == 0 then
        if #(node.typeargs or {}) > 0 then
            checker.typeerror(errors, node.loc,
                "%s is not generic and cannot receive type arguments", subject)
        end
        return method
    end

    local closed, arguments
    if #(node.typeargs or {}) > 0 then
        local valid
        arguments, valid =
            checker._generic.recover_complete_type_arguments(
                node.typeargs, count, st, errors, node.loc, subject)
        if valid then
            checker._generic.validate_binder_arguments(method.scope,
                method.typeparams, arguments,
                st, errors, node.loc, subject, false)
        end
        closed = checker._generic.generic_substitute(
            method, method.scope, arguments, errors, node.loc,
            "cannot instantiate " .. subject) or method
    else
        local context = checker._generic.new_inference_context(subject, {
            checker._generic.inference_scope_entry(method.scope, method.typeparams),
        }, st, errors, node.loc)
        checker._generic.infer_call_application(context,
            checker._generic.callable_function_type(method), node,
            demand, st, errors, subject, method.paramnames)
        arguments = checker._generic.inference_type_arguments(context)
        closed = checker._generic.substitute_inference(
            context, method, true)
    end
    node._generic_declaration = method
    node._generic_type_arguments = arguments
    return closed
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

    ["Ast.ExpBool"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            node._type = st.c_profile and st.c_profile.integers
                and st.c_profile.integers._Bool
                and st.c_profile.integers._Bool.type
                or types.CInteger("_Bool", false, 0, 8)
            node._foreign_literal = true
        else
            node._type = types.Boolean()
        end
    end,

    ["Ast.ExpInteger"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            local spelling = st.c_profile and st.c_profile.int or "int"
            node._type = st.c_profile and st.c_profile.integers
                and st.c_profile.integers[spelling]
                and st.c_profile.integers[spelling].type
                or types.CInteger("int", true, 3, 32)
            node._foreign_literal = true
        else
            node._type = types.Integer()
        end
    end,

    ["Ast.ExpFloat"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            node._type = st.c_profile and st.c_profile.floats
                and st.c_profile.floats.double
                and st.c_profile.floats.double.type
                or types.CFloat("double")
            node._foreign_literal = true
        else
            node._type = types.Float()
        end
    end,

    ["Ast.ExpString"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            local char = st.c_profile and st.c_profile.integers
                and st.c_profile.integers.char
                and st.c_profile.integers.char.type
                or types.CInteger("char", true, 1, 8)
            node._type = types.CPointer(char, { "const" })
            node._foreign_string_literal = true
        else
            node._type = types.String()
        end
    end,

    ["Ast.ExpUnionInit"] = function(node, st, errors, _)
        local owner_node = st:find_symbol(node.owner)
        local union = owner_node and owner_node._type
        local variant = node.variant and node.variant._type
        if not owner_node or owner_node._tag ~= "Ast.TopLevelUnion"
           or not union or union._tag ~= "Type.Union" then
            node._type = invalid(errors, node.loc,
                "invalid synthesized union constructor owner '%s'",
                tostring(node.owner))
            if node.value then checkexp(node.value, st, errors) end
            return
        elseif not variant or variant._tag ~= "Type.Variant"
           or variant.fqtn ~= union.name
           or union.variants[variant.name] ~= variant then
            node._type = invalid(errors, node.loc,
                "invalid synthesized variant constructor for union '%s'",
                union.name)
            if node.value then checkexp(node.value, st, errors) end
            return
        end

        node._union = union
        node._variant = variant
        if variant.payload == false then
            if node.value then
                checkexp(node.value, st, errors)
                checker.typeerror(errors, node.loc,
                    "empty variant '%s.%s' cannot receive a payload",
                    union.name, variant.name)
            end
        elseif not node.value then
            checker.typeerror(errors, node.loc,
                "payload variant '%s.%s' is missing its synthesized value",
                union.name, variant.name)
        else
            checkexp(node.value, st, errors, variant.payload)
            node.value = coerce_and_check(
                node.value, variant.payload,
                "payload of variant " .. variant.name,
                errors, node.loc)
        end
        node._type = types.Nominal(
            union.name, checker._generic.generic_parameter_arguments(union))
    end,

    ["Ast.ExpInitList"] = function(node, st, errors, context)
        context = context and deoptionize(context)
        local shape, kinds, dots_field, invalid_dots =
            classify_constructor_fields(node, errors)

        if invalid_dots or shape == "mixed" then
            if shape == "mixed" then
                checker.typeerror(errors, node.loc,
                    "cannot mix %s fields in a constructor",
                    table.concat(kinds, ", "))
            end
            check_rejected_constructor_fields(node, st, errors, context)
            node._type = context or types.Invalid()
            return
        end

        local expected = context and context._tag
        if expected ~= "Type.Array"
           and expected ~= "Type.Map"
           and expected ~= "Type.Nominal" then
            if shape == "computed" then
                expected = "Type.Map"
            elseif shape == "named" then
                expected = "Type.Nominal"
            else
                -- Empty and positional constructors default to Array without a
                -- useful structural context.
                expected = "Type.Array"
            end
            context = nil
        end

        if dots_field and expected == "Type.Nominal" then
            checker.typeerror(errors, dots_field.loc,
                "'...' can only appear in an all-positional array or integer-keyed map constructor")
            check_rejected_constructor_fields(node, st, errors, context)
            node._type = context or types.Invalid()
            return
        end

        if expected == "Type.Array" then
            if shape == "empty" or shape == "positional" then
                check_positional_constructor(node, st, errors, expected, nil,
                    context and context.elem)
            else
                for _, field in ipairs(node.fields) do
                    if shape == "named" then
                        checker.typeerror(errors, field.loc,
                            "initializing field '%s' when expecting array",
                            field.name)
                    else
                        checker.typeerror(errors, field.loc,
                            "initializing a computed field when expecting array")
                    end
                end
                check_rejected_constructor_fields(node, st, errors)
                node._type = context or types.Array(types.Integer())
            end
        elseif expected == "Type.Map" then
            if shape == "computed" then
                check_computed_map_constructor(node, st, errors, context)
            elseif shape == "empty" then
                assert(context)
                check_computed_map_constructor(node, st, errors, context)
            elseif shape == "positional" then
                assert(context)
                if types.equals(context.keys, types.Integer()) then
                    check_positional_constructor(node, st, errors, expected,
                        context.keys, context.values)
                else
                    checker.typeerror(errors, node.loc,
                        "positional fields require an integer-keyed map, but found key type %s",
                        types.tostring(context.keys))
                    check_rejected_constructor_fields(node, st, errors, context)
                    node._type = context
                end
            else
                assert(context)
                for _, field in ipairs(node.fields) do
                    checker.typeerror(errors, field.loc,
                        "initializing field '%s' when expecting map", field.name)
                end
                check_rejected_constructor_fields(node, st, errors)
                node._type = context
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
                local record = checker._generic.applied_owner_view(context, errors, node.loc)
                if record._tag == "Type.Union" then
                    node._type = invalid(errors, node.loc,
                        "union type '%s' cannot be constructed with a record "
                        .. "initializer; call one of its variant constructors",
                        context.fqtn)
                    for _, field in ipairs(node.fields) do
                        checkexp(field.exp, st, errors)
                    end
                    return
                elseif record._tag ~= "Type.Record" then
                    node._type = invalid(errors, node.loc,
                        "nominal type '%s' is not a record type",
                        context.fqtn)
                    for _, field in ipairs(node.fields) do
                        checkexp(field.exp, st, errors)
                    end
                    return
                end
                if record.islocal
                   and not is_nominal_visible_from(st, context.fqtn) then
                    node._type = invalid(errors, node.loc,
                        "record type '%s' is local to module '%s'",
                        context.fqtn, nominal_module(context.fqtn))
                    for _, field in ipairs(node.fields) do
                        checkexp(field.exp, st, errors)
                    end
                    return
                end
                local visible_fields = visible_record_fields(record, st)
                if (record.nfields or #record.fields) > #visible_fields then
                    node._type = invalid(errors, node.loc,
                        "cannot construct record type '%s' outside module '%s' because it has local fields",
                        context.fqtn, nominal_module(context.fqtn))
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
                        cfield.exp = coerce_and_check(
                            cfield.exp, found.type,
                            "field " .. cfield.name,
                            errors, cfield.loc)
                        cfield._field = found
                        supplied[found.name] = true
                    end
                end
                for _, rfield in ipairs(visible_fields) do
                    if not supplied[rfield.name] then
                        local exp = ast.ExpNil(node.loc)
                        exp._type = types.Nil()
                        local adjustment = types.assignment_adjustment(
                            exp._type, rfield.type)
                        if adjustment then
                            exp = coerce_and_check(
                                exp, rfield.type,
                                "omitted field " .. rfield.name,
                                errors, node.loc, adjustment)
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
                node._type = context
            end
        end
    end,

    ["Ast.ExpVar"] = function(node, st, errors, context)
        if not node._generic_var_prechecked then
            checkvar(node.var, st, errors, context)
        end
        if node.var._decl then node.var._decl._used = true end
        local texp = node.var._type
        if texp._tag == "Type.Module" or texp._tag == "Type.CModule" then
            node._type = invalid(errors, node.loc,
                "trying to access module '%s' as a first-class value",
                node.var.name)
        elseif c_resolve(texp)
               and c_resolve(texp)._tag == "Type.CFunction" then
            -- A direct C declaration is not a value. Its only value-producing
            -- context is decay to an exactly compatible C function pointer;
            -- there is no Titan closure or Lua-callable representation.
            local cfunc = c_resolve(texp)
            local var = node.var
            local reference = checker._foreign_function_reference(var)
            if reference
               and c_function_pointer_accepts_declaration(context, cfunc) then
                node._type = context
                node._foreign_function_reference = reference
                if not reference.source then
                    node._foreign_function_pointer = reference.name
                end
            else
                node._type = invalid(errors, node.loc,
                    "a foreign (C) function cannot be used as a first-class value")
            end
        elseif texp._tag == "Type.FunctionScheme"
           or (texp._tag == "Type.Function"
               and node.var._generic_declaration) then
            local closed = checker._generic.instantiate_first_class_variable(
                node, node.var, texp, context, st, errors)
            if closed then
                node._type = closed
                local decl = node.var._decl
                if decl and decl._tag == "Ast.TopLevelFunc" then
                    decl._valref = true
                end
            else
                node._type = invalid(errors, node.loc,
                    "generic declaration '%s' requires a monomorphic expected function type when used as a first-class value",
                    node.var.name)
            end
        elseif texp._tag == "Type.Function" then
            -- Every Type.Function is a first-class Titan/Lua callable value.
            node._type = texp
            -- Mark a referenced *local* function declaration so the coder
            -- builds its canonical closure (exported functions and statics
            -- always get one; a function-typed local is already a value).
            local decl = node.var._decl
            if decl and decl._tag == "Ast.TopLevelFunc" then
                decl._valref = true
            end
        elseif texp._tag == "Type.Record" or texp._tag == "Type.Union" then
            local kind = texp._tag == "Type.Record" and "record" or "union"
            node._type = invalid(errors, node.loc,
                "trying to access %s type '%s' as a first-class value",
                kind, texp.name)
        else
            node._type = texp
        end
        if node.var._c_fam_access then
            node._c_fam_access = node.var._c_fam_access
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
        if check_c_unary_operator(node, st, errors) then
            return
        end
        local texp = node.exp._type
        local loc = node.loc
        if texp._tag == "Type.Parameter" then
            checker.typeerror(errors, loc,
                "operator '%s' is not available for rigid type parameter '%s'",
                op, texp.diagnostic_name)
            node._type = (op == "not" or op == "#")
                and (op == "not" and types.Boolean() or types.Integer())
                or types.Invalid()
            return
        end
        if op == "#" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            if texp._tag == "Type.Map"
               and not types.equals(texp.keys, types.Integer()) then
                checker.typeerror(errors, loc,
                    "trying to take the length of a map with key type %s instead of an integer-keyed map",
                    types.tostring(texp.keys))
            elseif texp._tag ~= "Type.Array"
               and texp._tag ~= "Type.Map"
               and texp._tag ~= "Type.String"
               and not node.exp._c_fam_access
               and not has_c_length(texp) then
                checker.typeerror(errors, loc,
                    "trying to take the length of a %s instead of an array, integer-keyed map, string, C array, or counted owned C array",
                    types.tostring(texp))
            end
            if node.exp._c_fam_access then
                node._c_fam_access = node.exp._c_fam_access
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
        if check_c_binary_operator(node, st, errors) then
            return
        end
        local loc = node.loc
        if op ~= "==" and op ~= "~="
           and (tlhs._tag == "Type.Parameter"
                or trhs._tag == "Type.Parameter") then
            local parameter = tlhs._tag == "Type.Parameter" and tlhs or trhs
            checker.typeerror(errors, loc,
                "operator '%s' is not available for rigid type parameter '%s'",
                op, parameter.diagnostic_name)
            node._type = (op == "<" or op == ">"
                or op == "<=" or op == ">=")
                and types.Boolean() or types.Invalid()
            return
        end
        if op == "==" or op == "~=" then
            if tlhs._tag == "Type.Option"
               and trhs._tag == "Type.Nil" then
                node.rhs = trycoerce(node.rhs, tlhs, errors)
                trhs = node.rhs._type
            elseif trhs._tag == "Type.Option"
               and tlhs._tag == "Type.Nil" then
                node.lhs = trycoerce(node.lhs, trhs, errors)
                tlhs = node.lhs._type
            elseif tlhs._tag == "Type.Option"
               or trhs._tag == "Type.Option" then
                node.lhs = trycoerce(node.lhs, optionize(tlhs), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, optionize(trhs), errors)
                trhs = node.rhs._type
            end
            local comparison = types.comparable(tlhs, trhs)
            if not comparison then
                local lcarrier = checker._generic.rigid_parameter_carrier(tlhs)
                local rcarrier = checker._generic.rigid_parameter_carrier(trhs)
                if (lcarrier and not rcarrier and types.equals(lcarrier, trhs))
                   or (rcarrier and not lcarrier and types.equals(tlhs, rcarrier)) then
                    comparison = {
                        kind = "comparison",
                        op = "rigid_carrier",
                        left = tlhs,
                        right = trhs,
                    }
                end
            end
            node._comparison = comparison or false
            if comparison then
                local function apply_comparison_adjustment(exp, adjustment)
                    if not adjustment then return exp end
                    local adjusted, consumed = trycoerce(
                        exp, adjustment.target, errors,
                        "equality operand", adjustment)
                    assert(consumed == adjustment,
                        "equality operand lost its ComparisonPlan adjustment")
                    return adjusted
                end
                node.lhs = apply_comparison_adjustment(
                    node.lhs, comparison.left_adjustment)
                node.rhs = apply_comparison_adjustment(
                    node.rhs, comparison.right_adjustment)
            else
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
            checkvar(var, st, errors, c_pseudo_callee_context)
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
            local ftype = checker._generic.instantiate_direct_call(
                node, node.exp._type, st, errors, demand)
            local fname = expname(node.exp)
            local pseudo_new = node.exp._tag == "Ast.ExpVar"
                and node.exp.var._decl
                and node.exp.var._decl._tag == "Checker.CPseudoNew"
                and node.exp.var._decl or nil
            if pseudo_new then
                if named then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local allocation_decl = demand and demand.allocation_decl
                local allocation_target = allocation_decl
                    and allocation_decl._type or nil
                local resolved_payload = c_resolve(pseudo_new.ctype)
                local literal_count = pseudo_new.array
                    and checker._allocation_integer_literal(
                        node.args.args[1]) or nil
                local allow_automatic_array = pseudo_new.array
                    and resolved_payload
                    and resolved_payload._tag == "Type.CArray"
                    and allocation_decl ~= nil
                    and literal_count and literal_count > 0
                    and (allocation_target == nil
                         or allocation_target._tag == "Type.CArray"
                         or checker._pointer_to_allocation_payload(
                             allocation_target, pseudo_new.ctype))
                local alloc_err = c_allocation_error(
                    pseudo_new.ctype, st, allow_automatic_array)
                if alloc_err then
                    node._type = invalid(errors, node.loc, alloc_err)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                annotate_call_arguments(node,
                    checkargs(pseudo_new, node.args.args, node.loc,
                        "function '" .. fname .. "'", st, errors, false))
                checker._plan_c_allocation(
                    node, pseudo_new, demand, st, errors)
                annotate_call_results(node, pseudo_new, demand, errors)
                return
            end
            if ftype._tag == "Type.Invalid" then
                node._type = ftype
                check_call_argument_expressions(node.args, st, errors)
                return
            end

            local direct_foreign_reference = node.exp._tag == "Ast.ExpVar"
                and checker._foreign_function_reference(node.exp.var) or nil
            local direct_cfunc = direct_foreign_reference
                and c_resolve(ftype) or nil
            if direct_cfunc
               and direct_cfunc._tag == "Type.CFunction" then
                node._direct_foreign_reference = direct_foreign_reference
                if not checker._ensure_c_enum_supported(
                        st, direct_cfunc, node.loc, errors) then
                    node._type = types.Invalid()
                    check_call_argument_expressions(node.args, st, errors)
                    return
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
                    elseif not recognized_ffi or lowering ~= "foreign"
                           or type(paramnames) ~= "table" then
                        node._type = types.Invalid()
                        named_target_error(errors, node.loc)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    elseif direct_cfunc.vararg then
                        node._type = invalid(errors, node.loc,
                            "named arguments are not supported for variadic function '%s'",
                            fname)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    end
                    local dense, order = check_named_args(
                        direct_cfunc, paramnames, node.args.fields, node.loc,
                        "function '" .. fname .. "'", st, errors)
                    if dense then
                        node.args = ast.ArgsFunc(node.args.loc, dense)
                        node._named_arg_order = order
                        node._named_call_kind = "foreign"
                    end
                else
                    annotate_call_arguments(node,
                        checkargs(direct_cfunc, node.args.args, node.loc,
                            "function '" .. fname .. "'", st, errors,
                            false))
                end
                annotate_c_call_mutations(node, direct_cfunc)
                annotate_call_results(node, direct_cfunc, demand, errors)
                if node._type._tag == "Type.Void" and not node._voidok
                   and not demand.tail then
                    node._type = invalid(errors, node.loc,
                        "a function returning no values cannot be used as a value")
                end
                return
            end

            local cfunc = c_function_pointer_type(ftype)
            if cfunc then
                if named then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                if not checker._ensure_c_enum_supported(
                        st, cfunc, node.loc, errors) then
                    node._type = types.Invalid()
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                node._c_pointer_call = cfunc
                annotate_call_arguments(node,
                    checkargs(cfunc, node.args.args, node.loc,
                        "function pointer '" .. fname .. "'", st, errors,
                        false))
                annotate_c_call_mutations(node, cfunc)
                annotate_call_results(node, cfunc, demand, errors)
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
                if node.exp == original then
                    -- Error recovery: an invalid synthesized component (or an
                    -- unreifiable raw-pointer tail) has already been diagnosed.
                    -- Retain the contextual call shape without claiming that
                    -- an assignment plan exists, so later checker passes can
                    -- continue and report each source error exactly once.
                    node.exp = ast.ExpCast(
                        original.loc, original, synthesized)
                    node.exp._type = synthesized
                    node.exp._implicit_coercion = true
                    node.exp._adjustment_failed = true
                end
                assert(node.exp._tag == "Ast.ExpCast")
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
                node.exp = tryforce(node.exp)
                ftype = ftype.base
            end
            if ftype._tag ~= "Type.Function" then
                node._type = invalid(errors, node.loc,
                    "'%s' is not a function but %s",
                    fname, types.tostring(ftype))
                check_call_argument_expressions(node.args, st, errors)
                return
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
                elseif ftype.varargtype then
                    node._type = invalid(errors, node.loc,
                        "named arguments are not supported for variadic function '%s'",
                        fname)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local dense, order
                if node._generic_named_dense then
                    dense, order = node._generic_named_dense,
                        node._generic_named_order
                else
                    dense, order = check_named_args(ftype, paramnames,
                        node.args.fields, node.loc,
                        "function '" .. fname .. "'", st, errors)
                end
                if dense then
                    node.args = ast.ArgsFunc(node.args.loc, dense)
                    node._named_arg_order = order
                    node._named_call_kind = lowering
                end
            else
                if contextual_args then
                    annotate_call_arguments(node, contextual_args)
                elseif node._generic_arg_adjustment then
                    annotate_call_arguments(node,
                        node._generic_arg_adjustment)
                else
                    annotate_call_arguments(node,
                        checkargs(ftype, node.args.args, node.loc,
                            "function '" .. fname .. "'", st, errors))
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
                node.exp = tryforce(node.exp)
                otype = otype.base
            end
            if otype._tag == "Type.Parameter"
               and otype.erased_constraint ~= false then
                node._rigid_receiver_type = otype
                otype = otype.erased_constraint
            end
            if otype._tag == "Type.Nominal" and
               types.registry[otype.fqtn] and
               (types.registry[otype.fqtn]._tag == "Type.Record"
                or types.registry[otype.fqtn]._tag == "Type.Union"
                or types.registry[otype.fqtn]._tag == "Type.Interface") then
                local class = checker._generic.applied_owner_view(
                    otype, errors, node.loc)
                local owner_kind = class._tag == "Type.Record"
                    and "record"
                    or (class._tag == "Type.Union"
                        and "union" or "interface")
                local method_name_text = node.args.method
                if not is_nominal_visible_from(st, otype.fqtn) then
                    node._type = invalid(errors, node.loc,
                        "%s type '%s' is local to module '%s'",
                        owner_kind, otype.fqtn, nominal_module(otype.fqtn))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                elseif not class.methods[method_name_text] then
                    node._type = invalid(errors, node.loc,
                        "method '%s' not found in %s '%s'",
                        method_name_text, owner_kind, types.tostring(otype))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local ftype = class.methods[method_name_text]
                if not is_nominal_member_visible_from(st, ftype) then
                    node._type = invalid(errors, node.loc,
                        "method '%s:%s' is local to module '%s'",
                        class.name, method_name_text, nominal_module(class.name))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                ftype = checker._generic.instantiate_method_declaration(
                    node, ftype, st, errors, class.name, demand)
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
                    local dense, order
                    if node._generic_named_dense then
                        dense, order = node._generic_named_dense,
                            node._generic_named_order
                    else
                        dense, order = check_named_args(
                            ftype, ftype.paramnames, node.args.fields,
                            node.loc, desc, st, errors)
                    end
                    if dense then
                        node.args = ast.ArgsMethod(node.args.loc, method_name_text, dense)
                        node._named_arg_order = order
                        node._named_call_kind = "titan"
                    end
                else
                    if node._generic_arg_adjustment then
                        annotate_call_arguments(node,
                            node._generic_arg_adjustment)
                    else
                        annotate_call_arguments(node,
                            checkargs(ftype, node.args.args, node.loc,
                                "method '" .. class.name .. ":" .. method_name_text .. "'",
                                st, errors))
                    end
                end
                node._method = ftype
                if class._tag == "Type.Interface" then
                    node._interface = class
                    node._interface_method = ftype
                    node._interface_method_index =
                        assert(interface_method_index(
                            class, method_name_text))
                end
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
        node._type = check_explicit_cast_relation(node, st, errors)
    end,

    ["Ast.ExpIs"] = function(node, st, errors, _)
        check_explicit_cast_relation(node, st, errors)
        node._type = types.Boolean()
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
                varargdecl._type = varargdecl._generic_inference_type
                    or typefromnode(varargdecl.type, st, errors)
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
                param._type = param._generic_inference_type
                    or typefromnode(param.type, st, errors)
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
        if type(node.rettypes) == "table" then
            -- Explicit annotation, including `: ()` (an empty list).
            if node._generic_inference_rettypes ~= nil then
                rettypes = node._generic_inference_rettypes
                flexrettype = node._generic_inference_flexrettype
            else
                rettypes = {}
                for _, rt in ipairs(node.rettypes) do
                    table.insert(rettypes, typefromnode(rt, st, errors))
                end
                flexrettype = flexible_return_type(node, st, errors)
            end
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
        -- Lua closures allow at most 255 upvalues. Titan reserves the first
        -- four for module/tag/native/brand and the final one for the strict
        -- stack entry, leaving 250 source-level captures.
        if #node._captures > 250 then
            checker.typeerror(errors, node.loc,
                "function captures too many variables (%d, max 250)",
                #node._captures)
        end

        return node._type
    end,

    -- Bound method reference `obj:m` (no call): yields a function value, the
    -- method's type with the implicit `self` removed and the receiver captured.
    -- Mirrors the method-resolution of the ArgsMethod arm of ExpCall.
    ["Ast.ExpMethodRef"] = function(node, st, errors, context)
        checkexp(node.exp, st, errors)
        local otype = node.exp._type
        -- auto-unwrap an option receiver, like a method call does, so `p:m` on a
        -- Point? unwraps to the underlying record (the cast codegen nil-checks).
        if otype._tag == "Type.Option" and otype.base._tag == "Type.Nominal" then
            node.exp = tryforce(node.exp)
            otype = otype.base
        end
        if otype._tag == "Type.Parameter"
           and otype.erased_constraint ~= false then
            node._rigid_receiver_type = otype
            otype = otype.erased_constraint
        end
        if otype._tag == "Type.CModule" then
            node._type = invalid(errors, node.loc,
                "a foreign (C) method cannot be used as a first-class value")
        elseif otype._tag == "Type.Nominal" and
           types.registry[otype.fqtn] and
           (types.registry[otype.fqtn]._tag == "Type.Record"
            or types.registry[otype.fqtn]._tag == "Type.Union"
            or types.registry[otype.fqtn]._tag == "Type.Interface") then
            local class = checker._generic.applied_owner_view(
                otype, errors, node.loc)
            local owner_kind = class._tag == "Type.Record"
                and "record"
                or (class._tag == "Type.Union"
                    and "union" or "interface")
            local mtype = class.methods[node.name]
            if not is_nominal_visible_from(st, otype.fqtn) then
                node._type = invalid(errors, node.loc,
                    "%s type '%s' is local to module '%s'",
                    owner_kind, otype.fqtn, nominal_module(otype.fqtn))
            elseif not mtype then
                node._type = invalid(errors, node.loc,
                    "method '%s' not found in %s '%s'",
                    node.name, owner_kind, types.tostring(otype))
            elseif not is_nominal_member_visible_from(st, mtype) then
                node._type = invalid(errors, node.loc,
                    "method '%s:%s' is local to module '%s'",
                    class.name, node.name, nominal_module(class.name))
            elseif mtype.scope ~= false then
                local expected = context
                if expected and expected._tag == "Type.Option"
                   and expected.base._tag == "Type.Function" then
                    expected = expected.base
                end
                if not expected or expected._tag ~= "Type.Function" then
                    node._type = invalid(errors, node.loc,
                        "generic method '%s:%s' requires a monomorphic expected function type when used as a bound value",
                        class.name, node.name)
                else
                    local subject = "generic bound method '" .. class.name
                        .. ":" .. node.name .. "'"
                    local closed, arguments, inference =
                        checker._generic.infer_first_class_application(
                            subject, { checker._generic.inference_scope_entry(
                                mtype.scope, mtype.typeparams) },
                            types.method_function_type(mtype), expected,
                            st, errors, node.loc)
                    local closed_method =
                        checker._generic.substitute_inference(
                            inference, mtype, true)
                    node._generic_declaration = mtype
                    node._generic_type_arguments = arguments
                    node._method = closed_method
                    node._type = closed
                    if class._tag == "Type.Interface" then
                        node._interface = class
                        node._interface_method = closed_method
                        node._interface_method_index =
                            assert(interface_method_index(class, node.name))
                        node._interface_bound = true
                    end
                end
            else
                node._method = mtype
                node._type = types.method_function_type(mtype)
                if class._tag == "Type.Interface" then
                    node._interface = class
                    node._interface_method = mtype
                    node._interface_method_index =
                        assert(interface_method_index(class, node.name))
                    node._interface_bound = true
                end
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
    -- positional Array/integer-Map constructor, where the consuming loop
    -- intercepts it as a marker or rewrites it into `ExpDotsIndex` reads BEFORE
    -- reaching this arm.
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
                .. "or a positional array/integer-keyed map constructor")
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
        node.exp = coerce_and_check(node.exp, types.Integer(),
            "variadic index", errors, node.exp.loc)
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
-- the body, and enforces the cannot-fall-off-the-end rule. The caller is
-- responsible
-- for having an open block and (for methods) declaring `self` before calling.
--   node: a node carrying `_type` (Function), `params`, `block`, and (for the
--         duplicate-parameter message) `name`. For lambdas, `node.rettypes` may
--         be `false`/a list; `node._type.rettypes` is authoritative here.
--   opts (optional): { self_decl = Decl }. Returns (ret, frame): `ret` is
--         whether the body cannot fall through; `frame` carries `captures`.
local function annotate_lua_function_boundary(node)
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
    local frame = { depth = #func_stack + 1, captures = {}, capture_set = {} }
    table.insert(func_stack, frame)
    if not opts.foreign then
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
    -- A zero-return `() -> ()` function (empty rettypes) may fall off the end,
    -- exactly like a `nil`-returning one; only a function whose first declared
    -- return type is some non-`nil` value must not fall off the end.
    local firstret = signature.rettypes[1]
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
    return checker._generic.with_declaration_bindings(node, st,
        checkfuncbody, node, st, errors)
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
    return checker._generic.with_declaration_bindings(node, st, function()
        local owner = node._nominal_owner._type
        local self = ast.Decl(node.loc, "self",
            ast.TypeName(node.loc, node._nominal_owner.name, {}), false)
        node._self = self
        self._type = types.Nominal(owner.name,
            checker._generic.generic_parameter_arguments(owner))
        -- `self` is declared into this method's own frame (inside
        -- checkfuncbody), so a nested lambda captures it like any parameter.
        checkfuncbody(node, st, errors, { self_decl = self })
    end)
end

local function check_user_value_slot_type(
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
local function checkbodies(ast, st, errors)
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

local function validate_union_source_projections(ast, errors)
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

local function isconstructor(node)
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
local function toplevel_name(node)
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
local toplevel_visitor = util.make_visitor({
    ["Ast.TopLevelImport"] = function(node, st, errors, loader)
        local modtype, errs, import_info =
            checker.checkimport(node.modname, loader)
        if modtype then
            node._type = modtype
            -- Source visibility is trusted loader provenance, never a field a
            -- binary provider can place in evaluated metadata.
            node._source_import = import_info
                and import_info.kind == "source"
                and modtype._source == true
            if node._source_import then
                for _, member in ipairs(modtype.source_members or {}) do
                    if member._foreign_source then
                        node._foreign_header = import_info.foreign_header
                        node._foreign_header_for_check =
                            import_info.foreign_header_for_check == true
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
        if foreign_c_config_error then
            err = foreign_c_config_error
        else
            local service
            service, err = ensure_probe_service(st)
            if service then
                local options
                options, err = service:cdriver_process_options()
                if options then
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
        if node.decl.type then
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
        return checker._generic.with_owner_bindings(node, st, function()
            local fqtn = st.modname .. "." .. node.name
            local methods = {}
            local method_names = {}
            if #node.methods == 0 then
                checker.typeerror(errors, node.loc,
                    "interface '%s' must declare at least one method", node.name)
                node._type = types.Invalid()
                return
            end

            for _, method in ipairs(node.methods) do
                if method_names[method.name] then
                    checker.typeerror(errors, method.loc,
                        "redeclaration of method '%s' in interface '%s'",
                        method.name, node.name)
                    method._ignore = true
                else
                    method_names[method.name] = method
                    checker._generic.prepare_generic_binders(method, st, errors, node)
                    checker._generic.with_generic_binding_map(st, method._generic_bindings,
                        function()
                            local ptypes, varargtype, paramnames =
                                param_types(method.params, st, errors)
                            local fixed_index = 1
                            local param_names = {}
                            for _, param in ipairs(method.params) do
                                if param.name == false then
                                    param._type = varargtype
                                else
                                    param._type = ptypes[fixed_index]
                                    fixed_index = fixed_index + 1
                                    if param_names[param.name] then
                                        checker.typeerror(errors, param.loc,
                                            "duplicate parameter '%s' in interface method '%s:%s'",
                                            param.name, node.name, method.name)
                                    else
                                        param_names[param.name] = true
                                    end
                                end
                            end

                            local rettypes = {}
                            for _, rettype in ipairs(method.rettypes) do
                                rettypes[#rettypes + 1] =
                                    typefromnode(rettype, st, errors)
                            end
                            local flexrettype =
                                flexible_return_type(method, st, errors)
                            method._type = types.Method(
                                fqtn, method.name, ptypes, rettypes,
                                varargtype, flexrettype, paramnames,
                                method._generic_scope,
                                method._generic_typeparams)
                        end)
                    annotate_lua_function_boundary(method)
                    methods[#methods + 1] = method._type
                end
            end

            node._type = types.Interface(fqtn, methods,
                node._generic_scope, node._generic_typeparams)
            node._type._generic_parameters = node._generic_parameters
            node._type._source_complete = true
            types.registry[fqtn] = node._type
        end)
    end,

    ["Ast.TopLevelFunc"] = function(node, st, errors)
        checker._generic.prepare_generic_binders(node, st, errors)
        return checker._generic.with_generic_binding_map(st, node._generic_bindings, function()
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
        return checker._generic.with_owner_bindings(node, st, function()
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
                        fqtn, field.name, ftype, i - 1)
                    tfield.islocal = field.islocal and true or false
                    tfield.dynamic_plan =
                        types.dynamic_coercion(ftype) or false
                    field._dynamic_plan = tfield.dynamic_plan
                    fields[#fields + 1] = tfield
                end
            end
            node._type = types.Record(fqtn, fields, {}, {}, #fields,
                node._generic_scope, node._generic_typeparams)
            node._type._generic_parameters = node._generic_parameters
            node._type.islocal = node.islocal and true or false
            node._type._source_complete = true
            node._dynamic_receiver_plan = assert(types.dynamic_coercion(
                types.Nominal(fqtn, checker._generic.generic_parameter_arguments(node._type))),
                "record nominal lacks its dynamic receiver plan")
            types.registry[fqtn] = node._type
        end)
    end,

    ["Ast.TopLevelUnion"] = function(node, st, errors)
        return checker._generic.with_owner_bindings(node, st, function()
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
                    variants[#variants + 1] = tvariant
                end
            end
            node._type = types.Union(fqtn, variants, {}, {}, #node.variants,
                node._generic_scope, node._generic_typeparams)
            node._type._generic_parameters = node._generic_parameters
            node._type.islocal = node.islocal and true or false
            node._type._source_complete = true
            node._dynamic_receiver_plan = assert(types.dynamic_coercion(
                types.Nominal(fqtn, checker._generic.generic_parameter_arguments(node._type))),
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
        checker._generic.with_owner_bindings(owner, st, function()
            checker._generic.prepare_generic_binders(node, st, errors, owner)
            checker._generic.with_generic_binding_map(st, node._generic_bindings, function()
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
        checker._generic.with_owner_bindings(owner, st, function()
            checker._generic.prepare_generic_binders(node, st, errors, owner)
            checker._generic.with_generic_binding_map(st, node._generic_bindings, function()
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
        ownertype.methods[node.name] = node._type
    end,
})

-- Collect type-only declarations before the signature pass so aliases may be
-- used by earlier functions, variables, nominals, Interfaces, and other
-- aliases. Records and unions own both the type and value namespaces, so they
-- remain authoritative over a conflicting alias or Interface regardless of
-- source order. Interfaces and aliases otherwise use first-declaration-wins in
-- their shared type-only namespace.
local function collect_type_aliases(ast, st, errors)
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
local function mark_toplevel_duplicates(ast, errors)
    local first = {}
    for index, node in ipairs(ast) do
        node._toplevel_order = index
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

local function reserve_toplevel_names(ast, st)
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
function checker._generic.reserve_generic_owner_headers(ast, st, errors)
    local owners = {}
    for _, node in ipairs(ast) do
        if not node._ignore and (node._tag == "Ast.TopLevelRecord"
                or node._tag == "Ast.TopLevelUnion"
                or node._tag == "Ast.TopLevelInterface") then
            if #(node.typeparams or {}) > 0 then
                local scope = checker._generic.generic_scope_for_node(node, st)
                checker._generic.reserve_generic_binders(node, scope, st, errors)
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
                placeholder.methods = {}
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
            checker._generic.resolve_generic_constraints(node, st, errors)
        end
    end
    st.resolving_generic_owner_constraints = false
end

function checker._generic.validate_pending_generic_constraints(st, errors)
    local pending = st.pending_generic_constraints or {}
    st.pending_generic_constraints = {}
    for _, application in ipairs(pending) do
        checker._generic.validate_binder_arguments(application.scope,
            application.typeparams, application.arguments,
            st, errors, application.loc, application.subject, false)
    end

    local reconstructions = st.pending_generic_reconstructions or {}
    st.pending_generic_reconstructions = {}
    for _, application in ipairs(reconstructions) do
        local owner = types.registry[application.fqtn]
        if owner then
            checker._generic.validate_owner_reconstruction(
                owner, application.arguments, st, errors,
                application.loc, application.subject, false)
        end
    end
end

local function collect_nominal_constructors(ast)
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

local function apply_source_foreign_headers(ast, st, errors)
    local seen = {}
    for _, node in ipairs(ast) do
        local filename = node._tag == "Ast.TopLevelImport"
            and node._source_import and node._foreign_header_for_check
            and node._foreign_header or nil
        if filename and not seen[filename] then
            seen[filename] = true
            local service, err = ensure_probe_service(st)
            local ftypes, include
            if service then
                local options
                options, err = service:cdriver_process_options()
                if options then
                    options.source_dir = st.source_dir
                    ftypes, err, include =
                        cdriver.process_file(filename, options)
                end
            end
            if ftypes then
                local normalized
                normalized, err = cprobe.normalize_include_descriptor(include, {
                    source_dir = st.source_dir,
                })
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

local function visit_toplevel(node, st, errors, loader)
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
local function checktoplevel(ast, st, errors, loader)
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
    checker._generic.reserve_generic_owner_headers(ast, st, errors)

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
    checker._generic.validate_pending_generic_constraints(st, errors)

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

-- Walk a recovered interface type and, for every Nominal or forwarding
-- GenericAlias that names another module, recover that module before
-- reconciling generic arity and canonical binder projections. This preserves
-- the existing nominal-owner/exposer provenance path; it does not introduce a
-- second registry or another provider identity mechanism.
function checker._recovered_nominal_owner(module, fqtn)
    if type(module) ~= "table" then return nil end
    for _, member in ipairs(module.members or {}) do
        local typ = member.type or member
        if type(typ) == "table" and typ.name == fqtn
           and (typ._tag == "Type.Record" or typ._tag == "Type.Union") then
            return typ
        end
    end
    local name = fqtn:match("([^.]+)$")
    local typ = name and module.type_members and module.type_members[name]
    if type(typ) == "table" and typ.name == fqtn
       and typ._tag == "Type.Interface" then
        return typ
    end
end

function checker._recovered_generic_alias(module, fqtn)
    if type(module) ~= "table" then return nil end
    local name = fqtn:match("([^.]+)$")
    local alias = name and module.type_members and module.type_members[name]
    if type(alias) == "table" and alias._tag == "Type.GenericAlias"
       and alias.module .. "." .. alias.name == fqtn then
        return alias
    end
end

function checker._recovered_typeparams_equal(left, right)
    left, right = left or {}, right or {}
    if #left ~= #right then return false end
    for index = 1, #left do
        if not types.alpha_equals(left[index], right[index]) then
            return false
        end
    end
    return true
end

function checker._recover_referenced_module(
        modname, loader, seen, exposing_module, interface_seen)
    local module_key = "\0module-interface:" .. modname
    if seen[module_key] then return seen[module_key] end

    local memo = { pending = true }
    seen[module_key] = memo
    local request = {
        kind = "nominal-owner",
        exposer = exposing_module,
        interface_seen = interface_seen,
        reference_seen = seen,
    }
    local called, module, err = pcall(
        checker.checkimport, modname, loader, request)
    memo.pending = nil
    if called and module then
        memo.module = module
    elseif called then
        memo.error = err
    else
        memo.error = tostring(module)
    end
    return memo
end

function checker._recover_referenced_owner(
        fqtn, loader, seen, exposing_module, interface_seen)
    local modname = fqtn:match("^(.*)%.[^.]+$")
    if not modname or modname == "" then return nil, nil end
    local memo = checker._recover_referenced_module(
        modname, loader, seen, exposing_module, interface_seen)
    local owner = checker._recovered_nominal_owner(memo.module, fqtn)
    if memo.module then
        if not owner then
            return nil, "recovered module '" .. modname ..
                "' does not publish nominal owner '" .. fqtn .. "'"
        end
    else
        owner = types.registry[fqtn]
    end
    return owner, memo.error
end

function checker._generic.recovered_scope_binding(policy, scope)
    for _, binding in ipairs(policy and policy.generic_scope_bindings or {}) do
        if types.same_generic_scope(binding.scope, scope) then
            return binding
        end
    end
end

function checker._generic.validate_recovered_application(
        nominal, owner, policy)
    local arguments = nominal.args or {}
    for index, argument in ipairs(arguments) do
        if not types.transient_roundtrip(argument) then
            return nil, "recovered nominal '" .. nominal.fqtn ..
                "' type argument " .. index ..
                " has no sound transient round trip"
        end
    end

    if owner.scope ~= false then
        local reconstructed, reconstruction_error = pcall(
            types.substitute, owner, owner.scope, arguments)
        if not reconstructed then
            return nil, "recovered nominal '" .. nominal.fqtn ..
                "' is not a canonical application: " ..
                tostring(reconstruction_error)
        end
    end
    for index, typeparam in ipairs(owner.typeparams or {}) do
        if typeparam.constraint ~= false then
            local closed, constraint = pcall(
                types.substitute, typeparam.constraint,
                owner.scope, arguments)
            if not closed then
                return nil, "recovered nominal '" .. nominal.fqtn ..
                    "' constraint " .. index ..
                    " could not be reconstructed: " .. tostring(constraint)
            end
            if checker._generic.generic_constraint_satisfied(
                    arguments[index], constraint, nil, policy) ~= true then
                return nil, "recovered nominal '" .. nominal.fqtn ..
                    "' type argument " .. index .. " ('" ..
                    types.tostring(arguments[index]) ..
                    "') does not satisfy constraint '" ..
                    types.tostring(constraint) .. "'"
            end
        end
    end
    return true
end

local function register_referenced_nominals(
        t, loader, seen, exposing_module, interface_seen, position,
        constraint_policy)
    if type(t) ~= "table" or not t._tag then return true end
    local tag = t._tag
    constraint_policy = constraint_policy or {
        visibility = exposing_module and tostring(exposing_module)
            or "<recovered-interface>",
        method_visible = function(method) return not method.islocal end,
        generic_scope_bindings = {},
    }
    constraint_policy.generic_scope_bindings =
        constraint_policy.generic_scope_bindings or {}
    local function register_scope(scope, typeparams)
        if scope ~= false and #(typeparams or {}) > 0 then
            constraint_policy.generic_scope_bindings[
                #constraint_policy.generic_scope_bindings + 1] = {
                    scope = scope,
                    typeparams = typeparams,
                }
        end
    end
    local alias_key
    local context_key = "\0generic-visit:" .. tostring(t) .. ":" ..
        tostring(position or "value")
    if tag == "Type.GenericAlias" then
        alias_key = t.module .. "." .. t.name
        local resolving_key = "\0generic-alias-resolving:" .. alias_key
        if seen[resolving_key] then
            return nil, "recovered GenericAlias chain is cyclic at '" ..
                alias_key .. "'"
        elseif seen[context_key] then
            return true
        end
        seen[resolving_key] = true
    elseif seen[context_key] then
        return true
    end
    seen[context_key] = true

    local function visit(child, child_position)
        return register_referenced_nominals(
            child, loader, seen, exposing_module, interface_seen,
            child_position, constraint_policy)
    end
    local function visit_list(list, child_position)
        for _, child in ipairs(list or {}) do
            local ok, err = visit(child, child_position)
            if not ok then return nil, err end
        end
        return true
    end
    local function visit_binders(typeparams)
        for _, typeparam in ipairs(typeparams or {}) do
            if typeparam.constraint ~= false then
                local ok, err = visit(typeparam.constraint, "constraint")
                if not ok then return nil, err end
            end
        end
        return true
    end

    local ok, err = true, nil
    if tag == "Type.Nominal" then
        local owner, recovery_error = checker._recover_referenced_owner(
            t.fqtn, loader, seen, exposing_module, interface_seen)
        if owner then
            local expected = #(owner.typeparams or {})
            if #(t.args or {}) ~= expected then
                ok, err = nil, "recovered nominal '" .. t.fqtn ..
                    "' expects " .. expected .. " type arguments but found " ..
                    #(t.args or {})
            elseif position == "constraint"
               and owner._tag ~= "Type.Interface" then
                ok, err = nil, "generic constraint '" .. t.fqtn ..
                    "' does not name an Interface"
            end
        elseif recovery_error then
            -- Preserve the historical best-effort nominal recovery boundary:
            -- an unavailable owner stays unresolved and the ordinary checker
            -- reports it at its use. Successfully recovered owners, however,
            -- must reconcile before the import can be trusted.
        end
        if ok then ok, err = visit_list(t.args) end
        if ok and owner then
            ok, err = checker._generic.validate_recovered_application(
                t, owner, constraint_policy)
        end
    elseif tag == "Type.GenericAlias" then
        local owner, owner_error = checker._recover_referenced_owner(
            t.target_owner_fqtn, loader, seen,
            exposing_module, interface_seen)
        if not owner then
            ok, err = nil, owner_error or
                ("could not recover GenericAlias owner '" ..
                    t.target_owner_fqtn .. "'")
        elseif not types.same_generic_scope(t.target_scope, owner.scope)
           or not checker._recovered_typeparams_equal(
                t.typeparams, owner.typeparams) then
            ok, err = nil,
                "recovered GenericAlias projection does not match owner '" ..
                    t.target_owner_fqtn .. "'"
        end
        if ok and t.target_alias_fqtn ~= false then
            local target_module_name =
                t.target_alias_fqtn:match("^(.*)%.[^.]+$")
            local memo = checker._recover_referenced_module(
                target_module_name, loader, seen,
                exposing_module, interface_seen)
            local target = checker._recovered_generic_alias(
                memo.module, t.target_alias_fqtn)
            if not target then
                ok, err = nil, memo.error or
                    ("could not recover target GenericAlias '" ..
                        t.target_alias_fqtn .. "'")
            elseif target.target_owner_fqtn ~= t.target_owner_fqtn
               or not types.same_generic_scope(
                    target.target_scope, t.target_scope)
               or not checker._recovered_typeparams_equal(
                    target.typeparams, t.typeparams) then
                ok, err = nil,
                    "recovered GenericAlias projection does not match alias '" ..
                        t.target_alias_fqtn .. "'"
            else
                ok, err = visit(target)
            end
        end
        if ok then ok, err = visit_binders(t.typeparams) end
    elseif tag == "Type.Parameter" then
        if t.erased_constraint ~= false then
            ok, err = visit(t.erased_constraint, "erased-constraint")
        end
    elseif tag == "Type.TypeParameter" then
        if t.constraint ~= false then
            ok, err = visit(t.constraint, "constraint")
        end
    elseif tag == "Type.FunctionScheme" then
        register_scope(t.scope, t.typeparams)
        ok, err = visit_binders(t.typeparams)
        if ok then ok, err = visit(t.signature) end
    elseif tag == "Type.Array" then
        ok, err = visit(t.elem)
    elseif tag == "Type.Map" then
        ok, err = visit(t.keys)
        if ok then ok, err = visit(t.values) end
    elseif tag == "Type.Option" then
        ok, err = visit(t.base)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable" then
        ok, err = visit(t.type)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        register_scope(t.scope, t.typeparams)
        ok, err = visit_binders(t.typeparams)
        if ok then ok, err = visit_list(t.params) end
        if ok then ok, err = visit_list(t.rettypes) end
        if ok and t.varargtype then ok, err = visit(t.varargtype) end
        if ok and t.flexrettype then ok, err = visit(t.flexrettype) end
    elseif tag == "Type.Record" then
        register_scope(t.scope, t.typeparams)
        ok, err = visit_binders(t.typeparams)
        if ok then
            for _, field in ipairs(t.fields or {}) do
                if not field.islocal then
                    ok, err = visit(field.type)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, fn in pairs(t.functions or {}) do
                if not fn.islocal then
                    ok, err = visit(fn)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, method in pairs(t.methods or {}) do
                if not method.islocal then
                    ok, err = visit(method)
                    if not ok then break end
                end
            end
        end
    elseif tag == "Type.Union" then
        register_scope(t.scope, t.typeparams)
        ok, err = visit_binders(t.typeparams)
        if ok then
            for _, variant in ipairs(t.variants or {}) do
                if not variant.islocal and variant.payload ~= false then
                    ok, err = visit(variant.payload)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, fn in pairs(t.functions or {}) do
                if not fn.islocal then
                    ok, err = visit(fn)
                    if not ok then break end
                end
            end
        end
        if ok then
            for _, method in pairs(t.methods or {}) do
                if not method.islocal then
                    ok, err = visit(method)
                    if not ok then break end
                end
            end
        end
    elseif tag == "Type.Interface" then
        register_scope(t.scope, t.typeparams)
        ok, err = visit_binders(t.typeparams)
        if ok then ok, err = visit_list(t.methods) end
    end

    if alias_key then
        seen["\0generic-alias-resolving:" .. alias_key] = nil
    end
    return ok, err
end

local function first_local_nominal_type(typ, seen)
    if type(typ) ~= "table" or not typ._tag then return nil end
    seen = seen or {}
    if seen[typ] then return nil end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Nominal" then
        local nominal = types.registry[typ.fqtn]
        if nominal and nominal.islocal then return typ end
        for _, argument in ipairs(typ.args or {}) do
            local found = first_local_nominal_type(argument, seen)
            if found then return found end
        end
        for _, argument in ipairs(typ.args or {}) do
            local found = first_local_nominal_type(argument, seen)
            if found then return found end
        end
    elseif tag == "Type.Parameter" then
        if typ.erased_constraint ~= false then
            return first_local_nominal_type(
                typ.erased_constraint, seen)
        end
    elseif tag == "Type.TypeParameter" then
        if typ.constraint ~= false then
            return first_local_nominal_type(typ.constraint, seen)
        end
    elseif tag == "Type.FunctionScheme" then
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        return first_local_nominal_type(typ.signature, seen)
    elseif tag == "Type.GenericAlias" then
        local owner = types.registry[typ.target_owner_fqtn]
        if owner and owner.islocal then
            return types.Nominal(typ.target_owner_fqtn)
        end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
    elseif tag == "Type.Record" then
        if typ.islocal then return typ end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, field in ipairs(typ.fields or {}) do
            if not field.islocal then
                local found = first_local_nominal_type(field.type, seen)
                if found then return found end
            end
        end
        for _, func in pairs(typ.functions or {}) do
            if not func.islocal then
                local found = first_local_nominal_type(func, seen)
                if found then return found end
            end
        end
        for _, method in pairs(typ.methods or {}) do
            if not method.islocal then
                local found = first_local_nominal_type(method, seen)
                if found then return found end
            end
        end
    elseif tag == "Type.Union" then
        if typ.islocal then return typ end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, variant in ipairs(typ.variants or {}) do
            if not variant.islocal and variant.payload ~= false then
                local found =
                    first_local_nominal_type(variant.payload, seen)
                if found then return found end
            end
        end
        for _, func in pairs(typ.functions or {}) do
            if not func.islocal then
                local found = first_local_nominal_type(func, seen)
                if found then return found end
            end
        end
        for _, method in pairs(typ.methods or {}) do
            if not method.islocal then
                local found = first_local_nominal_type(method, seen)
                if found then return found end
            end
        end
    elseif tag == "Type.Interface" then
        if typ.islocal then return typ end
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, method in ipairs(typ.methods or {}) do
            local found = first_local_nominal_type(method, seen)
            if found then return found end
        end
    elseif tag == "Type.Array" then
        return first_local_nominal_type(typ.elem, seen)
    elseif tag == "Type.Map" then
        return first_local_nominal_type(typ.keys, seen)
            or first_local_nominal_type(typ.values, seen)
    elseif tag == "Type.Option" then
        return first_local_nominal_type(typ.base, seen)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable"
           or tag == "Type.Field" then
        return first_local_nominal_type(typ.type, seen)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        for _, typeparam in ipairs(typ.typeparams or {}) do
            local found = first_local_nominal_type(typeparam, seen)
            if found then return found end
        end
        for _, p in ipairs(typ.params or {}) do
            local found = first_local_nominal_type(p, seen)
            if found then return found end
        end
        for _, r in ipairs(typ.rettypes or {}) do
            local found = first_local_nominal_type(r, seen)
            if found then return found end
        end
        if typ.varargtype then
            local found = first_local_nominal_type(typ.varargtype, seen)
            if found then return found end
        end
        if typ.flexrettype then
            return first_local_nominal_type(typ.flexrettype, seen)
        end
    end
end

-- A process may encounter the same owner through both a trusted source edge
-- and a compiled facade. Keep the complete source descriptor canonical in the
-- process-global nominal registry; visibility checks still require a direct
-- source import, so retaining the richer descriptor grants no permission by
-- itself. Unknown `_source_complete` fields are never serialized.
function checker._register_nominal_descriptor(typ, trusted_source)
    local current = types.registry[typ.name]
    if trusted_source then typ._source_complete = true end
    if not current or trusted_source or not current._source_complete then
        -- A metadata expression cannot self-assert this compiler-only marker.
        if not trusted_source then typ._source_complete = nil end
        types.registry[typ.name] = typ
    end
end

function checker.register_module_interface(
        modname, type_or_error, loader, exposer, interface_seen,
        trusted_source, reference_seen)
    exposer = exposer or modname
    interface_seen = interface_seen or {}
    local exposer_key
    if type(exposer) == "table" then
        exposer_key = exposer.static_archive or exposer.filename or
            exposer.name or tostring(exposer)
    else
        exposer_key = tostring(exposer)
    end
    local interface_key = exposer_key .. "\0" .. modname
    if interface_seen[interface_key] then return true end
    interface_seen[interface_key] = true

    local seen = reference_seen or {}
    local module_key = "\0module-interface:" .. modname
    local module_memo = seen[module_key]
    if not module_memo then
        module_memo = {}
        seen[module_key] = module_memo
    end
    module_memo.module = type_or_error

    -- Type-only re-exports do not copy a nominal's static closures into the
    -- facade module. Stamp the canonical descriptors with their deterministic
    -- owner-userdata prefix slots while the complete owner interface is in
    -- hand, so first-class static references through direct or chained aliases
    -- can recover the closure from that owner after initialization.
    for slot, entry in ipairs(
            types.public_module_prefix_layout(type_or_error)) do
        local index = slot - 1
        if entry.kind == "variable" then
            entry.value._upvalue = index
        else
            entry.value._closure_upvalue = index
        end
    end

    -- Interfaces are type-only module entries. Register every direct
    -- descriptor before traversing any signature so mutually referring
    -- Interfaces have their complete nominal environment available. A source
    -- interface has an additional non-serialized local view; a binary one has
    -- only the ordinary public collections.
    local type_views = { type_or_error.type_members or {} }
    if trusted_source then
        type_views[#type_views + 1] =
            type_or_error.source_type_members or {}
    end
    for _, view in ipairs(type_views) do
        for _, t in pairs(view) do
            if t and t._tag == "Type.Interface" then
                checker._register_nominal_descriptor(t, trusted_source)
            end
        end
    end

    local member_views = { type_or_error.members or {} }
    if trusted_source then
        member_views[#member_views + 1] =
            type_or_error.source_members or {}
    end
    for _, view in ipairs(member_views) do
        for _, member in ipairs(view) do
            -- Nominals arrive wrapped in a Type.ModuleMember. The source view
            -- additionally registers local owners for direct source importers.
            local t = member.type or member
            if t and (t._tag == "Type.Record"
                      or t._tag == "Type.Union") then
                checker._register_nominal_descriptor(t, trusted_source)
            end
        end
    end

    for view_index, view in ipairs(member_views) do
        local policy = { visibility = modname }
        if view_index == 1 then
            policy.method_visible = function(method)
                return not method.islocal
            end
        end
        for _, member in ipairs(view) do
            local registered, register_error = register_referenced_nominals(
                member.type or member, loader, seen,
                exposer, interface_seen, nil, policy)
            if not registered then return nil, register_error end
        end
    end
    for view_index, view in ipairs(type_views) do
        local policy = { visibility = modname }
        if view_index == 1 then
            policy.method_visible = function(method)
                return not method.islocal
            end
        end
        for _, member in pairs(view) do
            local registered, register_error = register_referenced_nominals(
                member, loader, seen, exposer, interface_seen,
                nil, policy)
            if not registered then return nil, register_error end
        end
    end
    return true
end

function checker.checkimport(modname, loader, request)
    local ok, type_or_error, errors, import_info = loader(modname, request)
    if not ok then return nil, type_or_error end
    local registered, register_error = checker.register_module_interface(
        modname, type_or_error, loader, request and request.exposer,
        request and request.interface_seen,
        import_info and import_info.kind == "source"
            and type_or_error._source == true,
        request and request.reference_seen)
    if not registered then return nil, register_error end
    return type_or_error, errors, import_info
end

-- Builds a type for the module from the types of its public members
--   modast: AST for the module
--   returns "Type.Module" type
local function makemoduletype(modname, modast, st)
    local members = {}
    local type_members = {}
    local source_members = {}
    local source_type_members = {}

    local function add_source_member(member)
        member.islocal = true
        source_members[#source_members + 1] = member
        source_members[member.name] = member
    end

    for _, tlnode in ipairs(modast) do
        if not tlnode._ignore then
            local tag = tlnode._tag
            if tag == "Ast.TopLevelImport"
               or tag == "Ast.TopLevelForeignImport" then
                -- Imports are compile-time declarations, not module members.
            elseif tag == "Ast.TopLevelVar" then
                local member = types.ModuleVariable(
                    modname, tlnode.decl.name, tlnode._type)
                if tlnode.islocal then
                    add_source_member(member)
                else
                    members[#members + 1] = member
                end
            elseif tag == "Ast.TopLevelFunc" then
                local member = types.ModuleMember(modname, tlnode.name,
                    tlnode._type, tlnode._paramnames)
                if tlnode.islocal then
                    add_source_member(member)
                else
                    members[#members + 1] = member
                end
            elseif tag == "Ast.TopLevelForeignFunc" then
                local member = types.ModuleMember(modname, tlnode.name,
                    tlnode._type, tlnode._paramnames)
                member._foreign_source = true
                add_source_member(member)
            elseif tag == "Ast.TopLevelRecord"
                   or tag == "Ast.TopLevelUnion" then
                local member = types.ModuleMember(
                    modname, tlnode.name, tlnode._type, false)
                if tlnode.islocal then
                    add_source_member(member)
                else
                    members[#members + 1] = member
                end
            elseif tag == "Ast.TopLevelTypeAlias" then
                if tlnode.islocal then
                    source_type_members[tlnode.name] = tlnode._type
                else
                    type_members[tlnode.name] = tlnode._type
                end
            elseif tag == "Ast.TopLevelInterface" then
                type_members[tlnode.name] = tlnode._type
            end
        end
    end

    local modtype = types.Module(modname, members, type_members)
    modtype._source = true
    modtype.source_members = source_members
    modtype.source_type_members = source_type_members
    return modtype
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
            elseif tag == "Ast.TopLevelInterface" then
                reject_exported_c_ffi_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelRecord" and not node.islocal then
                for i, field in ipairs(node._type.fields) do
                    if not field.islocal then
                        local loc = node.fields[i] and node.fields[i].loc or node.loc
                        reject_exported_c_ffi_type(modname, errors, loc, field.type)
                    end
                end
            elseif tag == "Ast.TopLevelUnion" and not node.islocal then
                for _, variant in ipairs(node.variants) do
                    if variant._type and not variant._type.islocal
                       and variant._type.payload ~= false then
                        reject_exported_c_ffi_type(
                            modname, errors,
                            variant.payload.loc or variant.loc,
                            variant._type.payload)
                    end
                end
            elseif (tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic")
                   and not node.islocal then
                reject_exported_c_ffi_type(modname, errors, node.loc, node._type)
            end
        end
    end
end

local function reject_exported_local_nominal_type(modname, errors, loc, typ)
    local local_nominal = first_local_nominal_type(typ)
    if local_nominal then
        local name = local_nominal.fqtn or local_nominal.name
        local owner = types.registry[name]
        local kind = owner and owner._tag == "Type.Union"
            and "union" or "record"
        checker.typeerror(errors, loc,
            "cannot export local %s type '%s' from Titan module '%s'",
            kind, name, modname)
    end
end

local function reject_exported_local_nominal_types(modname, modast, errors)
    for _, node in ipairs(modast) do
        if not node._ignore then
            local tag = node._tag
            if tag == "Ast.TopLevelVar" and not node.islocal then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelFunc" and not node.islocal then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelTypeAlias" and not node.islocal then
                reject_exported_local_nominal_type(modname, errors,
                    node.type.loc or node.loc, node._type)
            elseif tag == "Ast.TopLevelInterface" then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            elseif tag == "Ast.TopLevelRecord" and not node.islocal then
                for i, field in ipairs(node._type.fields) do
                    if not field.islocal then
                        local loc = node.fields[i] and node.fields[i].loc or node.loc
                        reject_exported_local_nominal_type(
                            modname, errors, loc, field.type)
                    end
                end
            elseif tag == "Ast.TopLevelUnion" and not node.islocal then
                for _, variant in ipairs(node.variants) do
                    if variant._type and not variant._type.islocal
                       and variant._type.payload ~= false then
                        reject_exported_local_nominal_type(
                            modname, errors,
                            variant.payload.loc or variant.loc,
                            variant._type.payload)
                    end
                end
            elseif (tag == "Ast.TopLevelMethod" or tag == "Ast.TopLevelStatic")
                   and not node.islocal then
                reject_exported_local_nominal_type(
                    modname, errors, node.loc, node._type)
            end
        end
    end
end


-- Generic declarations are checked against their precise surface schemes, but
-- code generation consumes one ordinary constraint-erased body.  Keep the
-- lowering here, after every body and exported-surface validation has
-- completed, so it cannot participate in inference or silently become a
-- second type checker.
function checker._generic.erased_module_view(module)
    local erased = types.erase(module)
    if module._source then
        erased._source = true
        erased.source_members = {}
        for index, member in ipairs(module.source_members or {}) do
            local item = types.erase(member)
            erased.source_members[index] = item
            erased.source_members[item.name] = item
        end
        erased.source_type_members = {}
        for name, typ in pairs(module.source_type_members or {}) do
            erased.source_type_members[name] = types.erase(typ)
        end
    end
    return erased
end

function checker._generic.prepare_erased_registry(surface_registry)
    local erased = {}
    for fqtn, owner in pairs(surface_registry) do
        local lowered = types.erase(owner)
        lowered._generic_header = nil
        lowered._generic_parameters = nil
        lowered._source_complete = owner._source_complete
        lowered.islocal = owner.islocal
        if lowered._tag == "Type.Record" then
            for index, field in ipairs(lowered.fields) do
                local source = owner.fields[index]
                field.islocal = source and source.islocal or nil
                field.dynamic_plan = types.dynamic_coercion(field.type) or false
            end
        elseif lowered._tag == "Type.Union" then
            for index, variant in ipairs(lowered.variants) do
                local source = owner.variants[index]
                variant.islocal = source and source.islocal or nil
            end
        end
        erased[fqtn] = lowered
    end
    return erased
end

function checker._generic.erased_descriptor(typ, state)
    if type(typ) ~= "table" or type(typ._tag) ~= "string" then return typ end
    local cached = state.erased_descriptors[typ]
    if cached then return cached end
    local tag = typ._tag
    if not types.contains_generic(typ)
       and tag ~= "Type.Record" and tag ~= "Type.Union"
       and tag ~= "Type.Interface" and tag ~= "Type.Field"
       and tag ~= "Type.Variant" and tag ~= "Type.StaticMethod"
       and tag ~= "Type.Method" and tag ~= "Type.Module" then
        state.erased_descriptors[typ] = typ
        return typ
    end
    local erased
    if tag == "Type.Record" or tag == "Type.Union"
       or tag == "Type.Interface" then
        erased = state.erased_registry[typ.name] or types.erase(typ)
    elseif tag == "Type.Field" then
        local owner = state.erased_registry[typ.fqtn]
        erased = owner and owner.fields and owner.fields[typ.index + 1]
            or types.erase(typ)
    elseif tag == "Type.Variant" then
        local owner = state.erased_registry[typ.fqtn]
        erased = owner and owner.variants and owner.variants[typ.index + 1]
            or types.erase(typ)
    elseif tag == "Type.StaticMethod" then
        local owner = state.erased_registry[typ.fqtn]
        erased = owner and owner.functions and owner.functions[typ.name]
            or types.erase(typ)
    elseif tag == "Type.Method" then
        local owner = state.erased_registry[typ.fqtn]
        if owner and owner.methods then
            if owner._tag == "Type.Interface" then
                for _, method in ipairs(owner.methods) do
                    if method.name == typ.name then erased = method break end
                end
            else
                erased = owner.methods[typ.name]
            end
        end
        erased = erased or types.erase(typ)
    elseif tag == "Type.Module" then
        erased = checker._generic.erased_module_view(typ)
    else
        erased = types.erase(typ)
    end
    state.erased_descriptors[typ] = erased
    return erased
end

function checker._generic.ordinary_assignment(source, target, state)
    local adjustment, conversion = checker_assignment_adjustment(
        source, target, state.st)
    return adjustment, conversion
end

function checker._generic.interface_downcast_expression(
        exp, source, target, state, subject)
    local downcast = interface_downcast_plan(source, target, state.st)
    if not downcast then return nil end
    local node = ast.ExpCast(exp.loc, exp, target)
    node._type = target
    node._implicit_coercion = true
    node._interface_downcast = downcast
    node._written_cast = {
        kind = "written_cast",
        op = "interface_downcast",
        source = source,
        target = target,
        interface = downcast.interface,
        concrete = downcast.concrete,
        source_optional = downcast.source_optional,
        downcast = downcast,
        _erased_boundary = subject,
    }
    return node
end

function checker._generic.erased_boundary_expression(
        exp, target, state, subject)
    local source = types.erase(exp._type)
    target = types.erase(target)
    exp._type = source
    exp._assignment_adjustment = nil
    if types.equals(source, target) then return exp end

    local adjustment = checker._generic.ordinary_assignment(
        source, target, state)
    if not adjustment then
        local downcast = checker._generic.interface_downcast_expression(
            exp, source, target, state, subject)
        if downcast then return downcast end
        error(string.format(
            "generic erased boundary for %s has no ordinary adjustment from %s to %s",
            subject, types.tostring(source), types.tostring(target)), 0)
    end
    local lowered, accepted = trycoerce(
        exp, target, state.errors, subject, adjustment)
    if not accepted then
        error("generic erased boundary lost its ordinary adjustment for "
            .. subject, 0)
    end
    return lowered
end

function checker._generic.surface_callable_for_call(node, state)
    if node._generic_scheme then
        return node._generic_scheme.signature, node._generic_scheme
    elseif node._generic_declaration then
        return checker._generic.callable_function_type(
            node._generic_declaration), node._generic_declaration
    end

    local method = node._method or node._interface_method
    if method and method.fqtn then
        local owner = state.surface_registry[method.fqtn]
        local canonical
        if owner and owner._tag == "Type.Interface" then
            for _, candidate in ipairs(owner.methods or {}) do
                if candidate.name == method.name then canonical = candidate break end
            end
        elseif owner and owner.methods then
            canonical = owner.methods[method.name]
        end
        if canonical and types.contains_generic(canonical) then
            return checker._generic.callable_function_type(canonical), canonical
        end
    end
    return nil
end

function checker._generic.replace_argument_reference(node, old, new)
    if old == new then return end
    local args = node.args
    local values = args.args
    if values then
        for index, value in ipairs(values) do
            if value == old then values[index] = new end
        end
    elseif args.fields then
        for _, field in ipairs(args.fields) do
            if field.exp == old then field.exp = new end
        end
    end
    if node._arg_adjustment then
        replace_adjusted_value(node._arg_adjustment, old, new)
    end
end

function checker._generic.peel_generic_ingress(exp, surface_target)
    surface_target = types.normalize(surface_target)
    if not surface_target or surface_target._tag ~= "Type.Parameter" then
        return exp
    end
    -- Surface checking validates the closed application before erasure.  A
    -- direct rigid leaf is the one intentional exception to retaining that
    -- projection: literal `value` enters its real constraint carrier raw (or
    -- through the ordinary value-to-Interface boundary) and is checked only
    -- when a precise closed consumer later eliminates it.
    local current = exp
    if current._tag == "Ast.ExpCast" and current._implicit_coercion
       and current.exp and current.exp._type
       and current.exp._type._tag == "Type.Value" then
        local plan = current._adjustment
        if plan and plan.kind == "gradual_view"
           and plan.op == "project" then
            current = current.exp
            current._assignment_adjustment = nil
        end
    end
    return current
end

function checker._generic.lower_call_arguments(
        node, signature, surface_signature, state)
    local adjusted = node._arg_adjustment
    if adjusted then
        for index, exp in pairs(adjusted.fixed) do
            local target = signature.params[index]
            if target then
                local ingress = checker._generic.peel_generic_ingress(
                    exp, surface_signature.params[index])
                if ingress ~= exp then
                    checker._generic.replace_argument_reference(
                        node, exp, ingress)
                    exp = ingress
                end
                local lowered = checker._generic.erased_boundary_expression(
                    exp, target, state,
                    "argument " .. index .. " of erased generic call")
                checker._generic.replace_argument_reference(
                    node, exp, lowered)
            end
        end
        if signature.varargtype then
            local copy = {}
            for index, exp in ipairs(adjusted.tail_scalars) do copy[index] = exp end
            for _, exp in ipairs(copy) do
                local ingress = checker._generic.peel_generic_ingress(
                    exp, surface_signature.varargtype)
                if ingress ~= exp then
                    checker._generic.replace_argument_reference(
                        node, exp, ingress)
                    exp = ingress
                end
                local lowered = checker._generic.erased_boundary_expression(
                    exp, signature.varargtype, state,
                    "variadic argument of erased generic call")
                checker._generic.replace_argument_reference(
                    node, exp, lowered)
            end
            if adjusted.open_source then
                local open = adjusted.open_source._tag == "Ast.ExpDots"
                    and adjusted.open_source._open_dots
                    or adjusted.open_source._open_results
                local source = open and open.source_type
                    or types.erase(adjusted.open_type)
                local target = signature.varargtype
                source, target = types.erase(source), types.erase(target)
                local plan = checker._generic.ordinary_assignment(
                    source, target, state)
                if not plan then
                    error(string.format(
                        "generic open argument has no ordinary adjustment from %s to %s",
                        types.tostring(source), types.tostring(target)), 0)
                end
                adjusted.open_type = source
                adjusted.open_target = target
                adjusted.open_adjustment = plan
                adjusted.open_callable_adapter = plan.kind == "callable"
                    and checker.freeze_callable_adapter(
                        plan, source, target, adjusted.open_source.loc)
                    or false
                adjusted.open_interface_conversion =
                    plan.interface_conversion or false
                if open then
                    open.target_type = target
                    open.adjustment = plan
                    open.callable_adapter = adjusted.open_callable_adapter
                end
            end
        end
    else
        local values = node.args.args or {}
        local fixed = math.min(#signature.params, #values)
        for index = 1, fixed do
            values[index] = checker._generic.peel_generic_ingress(
                values[index], surface_signature.params[index])
            values[index] = checker._generic.erased_boundary_expression(
                values[index], signature.params[index], state,
                "argument " .. index .. " of erased generic call")
        end
        if signature.varargtype then
            for index = #signature.params + 1, #values do
                if values[index]._tag ~= "Ast.ExpDots" then
                    values[index] = checker._generic.erased_boundary_expression(
                        values[index], signature.varargtype, state,
                        "variadic argument of erased generic call")
                end
            end
        end
    end
end

function checker._generic.lower_call_in_place(node, state)
    local prior = state.calls[node]
    if prior then return prior end

    -- Install a pending entry before descending because ExpExtra nodes share
    -- their producer call by identity.
    local info = { pending = true, generic = false }
    state.calls[node] = info

    node.exp = checker._generic.lower_expression(node.exp, state)
    local values = node.args.args
    if values then
        for index, exp in ipairs(values) do
            local lowered = checker._generic.lower_expression(exp, state)
            checker._generic.replace_argument_reference(
                node, exp, lowered)
            values[index] = lowered
        end
    elseif node.args.fields then
        for _, field in ipairs(node.args.fields) do
            local old = field.exp
            local lowered = checker._generic.lower_expression(old, state)
            checker._generic.replace_argument_reference(node, old, lowered)
            field.exp = lowered
        end
    end

    local surface_signature, declaration =
        checker._generic.surface_callable_for_call(node, state)
    if not surface_signature then
        info.pending = nil
        return info
    end

    local erased_declaration = checker._generic.erased_descriptor(
        declaration, state)
    local signature
    if erased_declaration._tag == "Type.Function" then
        signature = erased_declaration
    else
        signature = checker._generic.callable_function_type(erased_declaration)
    end
    types.assert_erased(signature)

    info.generic = true
    info.declaration = declaration
    info.primary_sink = node._assignment_adjustment
        and node._assignment_adjustment.target or false
    info.surface_visible = {}
    for index, typ in ipairs(node._visible_types or node._types or {}) do
        info.surface_visible[index] = typ
    end
    info.surface_flex = node._flexrettype or false

    checker._generic.lower_call_arguments(
        node, signature, surface_signature, state)

    if node.args._tag == "Ast.ArgsMethod" then
        node._method = erased_declaration
        if node._interface_method then
            node._interface_method = erased_declaration
            node._interface = state.erased_registry[erased_declaration.fqtn]
        end
    else
        node.exp._type = signature
        if node.exp._tag == "Ast.ExpVar" and node.exp.var then
            node.exp.var._type = signature
            if node.exp.var._decl
               and node.exp.var._decl._tag ~= "Ast.TopLevelFunc" then
                node.exp.var._decl = checker._generic.erased_descriptor(
                    node.exp.var._decl, state)
            end
        end
    end

    node._callee_type = signature
    node._types = signature.rettypes
    node._flexrettype = signature.flexrettype or false
    node._visible_types = {}
    node._lua_result_dynamic_plans = {}
    node._strict_result_guard_plans = {}
    local sources = node._result_sources or {}
    for index, source in ipairs(sources) do
        local carrier
        if source.kind == "fixed" then
            carrier = signature.rettypes[source.index]
        else
            carrier = optionize(assert(signature.flexrettype,
                "generic finite flexible result lost its erased tail"))
        end
        node._visible_types[index] = carrier
        node._lua_result_dynamic_plans[index] =
            types.dynamic_coercion(carrier) or false
        node._strict_result_guard_plans[index] =
            types.gradual_guard(carrier) or false
    end
    node._type = node._visible_types[1] or types.Void()
    if node._open_results then
        node._open_results.source_type = assert(signature.flexrettype,
            "generic open result lost its erased flexible tail")
        node._open_results.target_type = node._open_results.source_type
        node._lua_open_result_dynamic_plan =
            types.dynamic_coercion(signature.flexrettype) or false
        node._strict_open_result_guard_plan =
            types.gradual_guard(signature.flexrettype) or false
    end
    node._assignment_adjustment = nil
    info.pending = nil
    return info
end

function checker._generic.canonical_surface_method(node, state)
    local method = node._method
    if not method or not method.fqtn then return nil end
    local owner = state.surface_registry[method.fqtn]
    if not owner or not owner.methods then return nil end
    if owner._tag == "Type.Interface" then
        for _, candidate in ipairs(owner.methods) do
            if candidate.name == method.name then return candidate end
        end
        return nil
    end
    return owner.methods[method.name]
end

function checker._generic.lower_method_reference(node, state)
    node.exp = checker._generic.lower_expression(node.exp, state)
    local canonical = node._generic_declaration
        or checker._generic.canonical_surface_method(node, state)
    if not canonical or not types.contains_generic(canonical) then return node end

    local surface = node._type
    local erased_method = checker._generic.erased_descriptor(canonical, state)
    local carrier = checker._generic.callable_function_type(erased_method)
    node._method = erased_method
    node._type = carrier
    node._assignment_adjustment = nil
    local projected = checker._generic.erased_boundary_expression(
        node, types.erase(surface), state,
        "first-class erased generic method")
    if projected ~= node then state.reverse_wrappers[projected] = node end
    return projected
end

function checker._generic.lower_first_class_declaration(node, state)
    local declaration = node._generic_scheme or node._generic_declaration
    if not declaration then return node end
    local surface = node._type
    local erased = checker._generic.erased_descriptor(declaration, state)
    local carrier = erased._tag == "Type.Function"
        and erased or checker._generic.callable_function_type(erased)
    node._type = carrier
    node._assignment_adjustment = nil
    if node.var then
        node.var._type = carrier
        if node.var._decl and node.var._decl._tag ~= "Ast.TopLevelFunc" then
            node.var._decl = checker._generic.erased_descriptor(
                node.var._decl, state)
        end
    end
    local projected = checker._generic.erased_boundary_expression(
        node, types.erase(surface), state,
        "first-class erased generic declaration")
    if projected ~= node then state.reverse_wrappers[projected] = node end
    return projected
end

function checker._generic.generic_field_pair(field, state)
    if not field or field._tag ~= "Type.Field" then return nil end
    local owner = state.surface_registry[field.fqtn]
    if not owner or owner._tag ~= "Type.Record" or owner.scope == false then
        return nil
    end
    local canonical = owner.fields[field.index + 1]
    if not canonical or not types.contains_generic(canonical.type) then
        return nil
    end
    local erased_owner = state.erased_registry[field.fqtn]
    return canonical, erased_owner.fields[field.index + 1]
end

function checker._generic.lower_field_read(node, state)
    local var = node.var
    if not var or var._tag ~= "Ast.VarDot" then return node end
    local _, carrier = checker._generic.generic_field_pair(var._decl, state)
    if not carrier then return node end
    local surface = node._type
    var._decl = carrier
    var._type = carrier.type
    node._type = carrier.type
    node._assignment_adjustment = nil
    local projected = checker._generic.erased_boundary_expression(
        node, types.erase(surface), state,
        "projection from erased generic field '" .. carrier.name .. "'")
    if projected ~= node then state.reverse_wrappers[projected] = node end
    return projected
end

function checker._generic.lower_field_write(var, exp, state)
    local surface, carrier = checker._generic.generic_field_pair(
        var._decl, state)
    if not carrier then return exp end
    exp = checker._generic.peel_generic_ingress(exp, surface.type)
    var._decl = carrier
    var._type = carrier.type
    return checker._generic.erased_boundary_expression(
        exp, carrier.type, state,
        "write to erased generic field '" .. carrier.name .. "'")
end

function checker._generic.lower_init_fields(node, state)
    for _, field in ipairs(node.fields or {}) do
        field.exp = checker._generic.lower_expression(field.exp, state)
        local surface, carrier = checker._generic.generic_field_pair(
            field._field, state)
        if carrier then
            field.exp = checker._generic.peel_generic_ingress(
                field.exp, surface.type)
            field._field = carrier
            field.exp = checker._generic.erased_boundary_expression(
                field.exp, carrier.type, state,
                "construction of erased generic field '" .. carrier.name .. "'")
        elseif field._field then
            field._field = checker._generic.erased_descriptor(
                field._field, state)
        end
    end
end

function checker._generic.lower_union_init(node, state)
    if node.value and node.value ~= false then
        node.value = checker._generic.lower_expression(node.value, state)
    end
    local surface = node._variant
    if not surface or surface._tag ~= "Type.Variant" then return end
    local owner = state.surface_registry[surface.fqtn]
    local erased_owner = state.erased_registry[surface.fqtn]
    local canonical = owner and owner.variants[surface.index + 1]
    local carrier = erased_owner and erased_owner.variants[surface.index + 1]
    if not carrier then return end
    node._union = erased_owner
    node._variant = carrier
    if canonical and canonical.payload ~= false
       and types.contains_generic(canonical.payload) then
        node.value = checker._generic.peel_generic_ingress(
            node.value, canonical.payload)
        node.value = checker._generic.erased_boundary_expression(
            node.value, carrier.payload, state,
            "construction of erased generic union payload")
    end
end

function checker._generic.reclassify_assignment(node, state)
    local plan = node._assignment_adjustment
    if not plan or not types.contains_generic(plan) then return end
    local source = types.erase(node._type)
    local target = types.erase(plan.target)
    node._type = source
    node._assignment_adjustment = nil
    local adjustment = checker._generic.ordinary_assignment(
        source, target, state)
    if not adjustment then
        error(string.format(
            "generic assignment annotation has no erased adjustment from %s to %s",
            types.tostring(source), types.tostring(target)), 0)
    end
    if adjustment.kind ~= "identity" then
        node._assignment_adjustment = adjustment
    end
end

function checker._generic.ordinary_written_plan(node, source, target, state)
    local plan = types.written_cast(source, target)
    node._interface_conversion = nil
    node._interface_downcast = nil
    node._interface_test = nil
    node._callable_adapter = nil
    if not plan and source._tag == "Type.Nominal"
       and target._tag == "Type.Nominal" then
        local concrete = types.registry[source.fqtn]
        local interface = types.registry[target.fqtn]
        if concrete
           and (concrete._tag == "Type.Record"
                or concrete._tag == "Type.Union")
           and interface and interface._tag == "Type.Interface" then
            local policy = interface_relation_policy(state.st)
            plan = types.written_cast(source, target, policy)
            if plan then
                local conversion = make_interface_conversion(
                    source, target, plan)
                plan.interface_conversion = conversion
                node._interface_conversion = conversion
                if node._tag == "Ast.ExpIs" then
                    node._interface_test = {
                        kind = "interface_implementation_test",
                        conversion = conversion,
                        allocation_free = true,
                    }
                end
            end
        end
    end
    if not plan then
        local downcast = interface_downcast_plan(source, target, state.st)
        if downcast then
            node._interface_downcast = downcast
            plan = {
                kind = "written_cast",
                op = "interface_downcast",
                source = source,
                target = target,
                interface = downcast.interface,
                concrete = downcast.concrete,
                source_optional = downcast.source_optional,
                downcast = downcast,
            }
            if node._tag == "Ast.ExpIs" then
                node._interface_test = {
                    kind = "interface_downcast_test",
                    downcast = downcast,
                    allocation_free = true,
                }
            end
        end
    end
    if plan and plan.op == "callable" and node._tag == "Ast.ExpCast" then
        node._callable_adapter = checker.freeze_callable_adapter(
            plan.callable, source, target, node.loc)
    end
    return plan
end

function checker._generic.reclassify_written_expression(
        node, lowered, surface_target, state)
    local source = types.erase(lowered._type)
    local target = types.erase(surface_target)
    lowered._type = source
    if node._tag == "Ast.ExpCast" and types.equals(source, target) then
        return lowered
    end
    local plan = checker._generic.ordinary_written_plan(
        node, source, target, state)
    if not plan then
        error(string.format(
            "generic written boundary has no ordinary cast from %s to %s",
            types.tostring(source), types.tostring(target)), 0)
    end
    node.exp = lowered
    node.target = target
    node._written_cast = plan
    node._adjustment = nil
    node._type = node._tag == "Ast.ExpIs" and types.Boolean() or target
    return node
end

function checker._generic.lower_expression(node, state)
    if type(node) ~= "table" or type(node._tag) ~= "string" then return node end
    local tag = node._tag
    if tag == "Ast.ExpCall" then
        local info = checker._generic.lower_call_in_place(node, state)
        if not info.generic or not info.surface_visible[1] then return node end
        if not info.primary then
            local target = info.surface_visible[1]
            if info.primary_sink
               and types.equals(types.erase(info.primary_sink), node._type) then
                target = info.primary_sink
            end
            info.primary = checker._generic.erased_boundary_expression(
                node, types.erase(target), state,
                "result of erased generic call")
            if info.primary ~= node then
                state.reverse_wrappers[info.primary] = node
            end
        end
        return info.primary
    elseif tag == "Ast.ExpExtra" then
        local producer = node.exp
        while producer and producer._tag == "Ast.ExpCast" do
            producer = producer.exp
        end
        local info = producer and producer._tag == "Ast.ExpCall"
            and checker._generic.lower_call_in_place(producer, state) or nil
        if info and info.generic and info.surface_visible[node.index] then
            node.exp = producer
            local source = producer._visible_types[node.index]
            local sink = node._assignment_adjustment
                and node._assignment_adjustment.target or false
            node._type = source
            node._assignment_adjustment = nil
            local target = info.surface_visible[node.index]
            if sink and types.equals(types.erase(sink), source) then
                target = sink
            end
            local projected = checker._generic.erased_boundary_expression(
                node, types.erase(target), state,
                "extra result of erased generic call")
            if projected ~= node then
                state.reverse_wrappers[projected] = node
            end
            return projected
        end
        if node.exp then node.exp = checker._generic.lower_expression(node.exp, state) end
    elseif tag == "Ast.ExpCast" then
        local surface_target = node._type
        local generic_adjustment = node._adjustment
            and types.contains_generic(node._adjustment)
        local generic_written = node._written_cast
            and types.contains_generic(node._written_cast)
        local lowered = checker._generic.lower_expression(node.exp, state)
        local carrier = state.reverse_wrappers[lowered]
        if carrier and types.equals(
                types.erase(surface_target), types.erase(carrier._type)) then
            return carrier
        end
        if generic_written then
            return checker._generic.reclassify_written_expression(
                node, lowered, surface_target, state)
        end
        if generic_adjustment then
            return checker._generic.erased_boundary_expression(
                lowered, types.erase(surface_target), state,
                "erased generic implicit cast")
        end
        node.exp = lowered
        if node.target and type(node.target) == "table"
           and node.target._tag and node.target._tag:match("^Type%.") then
            node.target = checker._generic.erased_descriptor(
                node.target, state)
        end
    elseif tag == "Ast.ExpIs" then
        local surface_target = node.target
        local generic_written = node._written_cast
            and types.contains_generic(node._written_cast)
        local lowered = checker._generic.lower_expression(node.exp, state)
        if generic_written then
            return checker._generic.reclassify_written_expression(
                node, lowered, surface_target, state)
        end
        node.exp = lowered
        if node.target and type(node.target) == "table"
           and node.target._tag and node.target._tag:match("^Type%.") then
            node.target = checker._generic.erased_descriptor(
                node.target, state)
        end
    elseif tag == "Ast.ExpMethodRef" then
        return checker._generic.lower_method_reference(node, state)
    elseif tag == "Ast.ExpVar" then
        if node.var._tag == "Ast.VarDot" then
            node.var.exp = checker._generic.lower_expression(
                node.var.exp, state)
        elseif node.var._tag == "Ast.VarBracket" then
            node.var.exp1 = checker._generic.lower_expression(
                node.var.exp1, state)
            node.var.exp2 = checker._generic.lower_expression(
                node.var.exp2, state)
        end
        local first_class = checker._generic.lower_first_class_declaration(
            node, state)
        if first_class ~= node then return first_class end
        return checker._generic.lower_field_read(node, state)
    elseif tag == "Ast.ExpInitList" then
        checker._generic.lower_init_fields(node, state)
    elseif tag == "Ast.ExpUnionInit" then
        checker._generic.lower_union_init(node, state)
    else
        -- Public AST edges are acyclic.  Type syntax and resolved Type graphs
        -- are metadata rather than executable children and are erased later.
        for key, value in pairs(node) do
            if type(key) == "string" and key:sub(1, 1) ~= "_"
               and key ~= "loc" and key ~= "target"
               and key ~= "type" and key ~= "rettypes"
               and key ~= "flexrettype" and key ~= "typeparams"
               and key ~= "typeargs" and type(value) == "table" then
                if value._tag and value._tag:match("^Ast%.Exp") then
                    node[key] = checker._generic.lower_expression(value, state)
                elseif value._tag then
                    checker._generic.lower_node(value, state)
                else
                    for index, child in ipairs(value) do
                        if type(child) == "table" and child._tag
                           and child._tag:match("^Ast%.Exp") then
                            value[index] = checker._generic.lower_expression(
                                child, state)
                        elseif type(child) == "table" then
                            checker._generic.lower_node(child, state)
                        end
                    end
                end
            end
        end
    end
    checker._generic.reclassify_assignment(node, state)
    return node
end

function checker._generic.lower_case(node, state)
    node.exp = checker._generic.lower_expression(node.exp, state)
    if node._union then
        node._union = checker._generic.erased_descriptor(node._union, state)
    end
    for _, arm in ipairs(node.arms or {}) do
        local surface_variant = arm._variant
        local carrier = surface_variant
            and checker._generic.erased_descriptor(surface_variant, state)
            or nil
        if carrier then arm._variant = carrier end
        if arm.binding and surface_variant and carrier
           and surface_variant.payload ~= false then
            local target = types.erase(arm.binding._type)
            local source = carrier.payload
            if not types.equals(source, target) then
                state.hidden_case = state.hidden_case + 1
                local original = arm.binding
                local hidden = hidden_decl(arm.loc,
                    "__generic_case_payload_" .. state.hidden_case, source)
                arm.binding = hidden
                local value = hidden_exp(arm.loc, hidden)
                local projection = checker._generic.erased_boundary_expression(
                    value, target, state,
                    "projection from erased generic union payload")
                original._type = target
                local declaration = ast.StatDecl(
                    arm.loc, { original }, { projection })
                table.insert(arm.block.stats, 1, declaration)
            else
                arm.binding._type = source
            end
        end
        checker._generic.lower_node(arm.block, state)
    end
    if node.elseblock then checker._generic.lower_node(node.elseblock, state) end
end

function checker._generic.lower_assignment(node, state)
    for _, var in ipairs(node.vars or {}) do
        if var._tag == "Ast.VarDot" then
            var.exp = checker._generic.lower_expression(var.exp, state)
        elseif var._tag == "Ast.VarBracket" then
            var.exp1 = checker._generic.lower_expression(var.exp1, state)
            var.exp2 = checker._generic.lower_expression(var.exp2, state)
        end
    end
    for index, exp in ipairs(node.exps or {}) do
        local old = exp
        local lowered = checker._generic.lower_expression(exp, state)
        local var = node.vars[index]
        if var and var._tag == "Ast.VarDot" then
            lowered = checker._generic.lower_field_write(var, lowered, state)
        end
        node.exps[index] = lowered
        if node._result_adjustment then
            replace_adjusted_value(node._result_adjustment, old, lowered)
        end
    end
end

function checker._generic.lower_node(node, state)
    if type(node) ~= "table" or type(node._tag) ~= "string" then return end
    local tag = node._tag
    if tag:match("^Ast%.Exp") then
        return checker._generic.lower_expression(node, state)
    elseif tag == "Ast.StatAssign" then
        checker._generic.lower_assignment(node, state)
        return
    elseif tag == "Ast.StatCase" then
        checker._generic.lower_case(node, state)
        return
    end

    if node.exps then
        for index, exp in ipairs(node.exps) do
            local lowered = checker._generic.lower_expression(exp, state)
            node.exps[index] = lowered
            if node._result_adjustment then
                replace_adjusted_value(
                    node._result_adjustment, exp, lowered)
            end
        end
    end

    for key, value in pairs(node) do
        if type(key) == "string" and key:sub(1, 1) ~= "_"
           and key ~= "loc" and key ~= "type" and key ~= "rettypes"
           and key ~= "flexrettype" and key ~= "typeparams"
           and key ~= "typeargs" and key ~= "target"
           and key ~= "exps"
           and type(value) == "table" then
            if value._tag and value._tag:match("^Ast%.Exp") then
                node[key] = checker._generic.lower_expression(value, state)
            elseif value._tag then
                checker._generic.lower_node(value, state)
            else
                for index, child in ipairs(value) do
                    if type(child) == "table" and child._tag
                       and child._tag:match("^Ast%.Exp") then
                        value[index] = checker._generic.lower_expression(
                            child, state)
                    elseif type(child) == "table" then
                        checker._generic.lower_node(child, state)
                    end
                end
            end
        end
    end
end

function checker._generic.sanitize_erased_graph(root, state)
    local seen = {}
    local function visit(value, is_root)
        if type(value) ~= "table" or seen[value] then return value end
        if type(value._tag) == "string"
           and value._tag:match("^Type%.") then
            return checker._generic.erased_descriptor(value, state)
        end
        seen[value] = true
        if type(value._tag) == "string" and value._tag:match("^Ast%.") then
            if value.typeparams ~= nil then value.typeparams = {} end
            if value.typeargs ~= nil then value.typeargs = {} end
        end
        local changes = {}
        for key, child in pairs(value) do
            if key ~= "_declared_type" then
                if type(key) == "string"
                   and (key:match("^_generic")
                        or key == "_closed_generic_declaration"
                        or key == "_rigid_receiver_type") then
                    changes[#changes + 1] = { key = key, remove = true }
                elseif type(child) == "table" then
                    local replacement = visit(child, false)
                    if replacement ~= child then
                        changes[#changes + 1] = {
                            key = key, value = replacement,
                        }
                    end
                end
            end
        end
        for _, change in ipairs(changes) do
            if change.remove then value[change.key] = nil
            else value[change.key] = change.value end
        end
        return value
    end
    return visit(root, true)
end

function checker._generic.refresh_erased_annotations(node)
    local seen = {}
    local function visit(value)
        if type(value) ~= "table" or seen[value] then return end
        seen[value] = true
        local tag = value._tag
        if tag == "Ast.TopLevelFunc" or tag == "Ast.TopLevelStatic"
           or tag == "Ast.TopLevelMethod" or tag == "Ast.ExpFunction"
           or tag == "Ast.InterfaceMethod" then
            annotate_lua_function_boundary(value)
        elseif tag == "Ast.TopLevelVar" then
            value._lua_write_dynamic_plan =
                types.dynamic_coercion(value._type) or false
        elseif tag == "Ast.TopLevelRecord" or tag == "Ast.TopLevelUnion" then
            value._dynamic_receiver_plan = types.dynamic_coercion(
                types.Nominal(value._type.name)) or false
        elseif tag == "Ast.VarBracket" then
            value._read_guard = types.gradual_guard(value._type) or false
        end
        for key, child in pairs(value) do
            if key ~= "_declared_type" and type(child) == "table"
               and not (type(child._tag) == "string"
                        and child._tag:match("^Type%.")) then
                visit(child)
            end
        end
    end
    visit(node)
end

function checker._generic.freeze_declared_annotations(root, clone_memo)
    local seen = {}
    local function visit(node)
        if type(node) ~= "table" or seen[node] then return end
        seen[node] = true
        local tag = node._tag
        if type(tag) == "string" and tag:match("^Ast%.") then
            if node._type and (tag:match("^Ast%.TopLevel")
                    or tag == "Ast.Decl"
                    or tag == "Ast.InterfaceMethod"
                    or tag == "Ast.UnionVariant") then
                node._declared_type = clone_memo[node._type]
                    or types.clone_graph(node._type, clone_memo)
            end
            for key, child in pairs(node) do
                if type(key) == "number" or (type(key) == "string"
                        and (key:sub(1, 1) ~= "_"
                            or key == "_self"
                            or key == "_result_decls")) then
                    if type(child) == "table" then
                        if child._tag then
                            visit(child)
                        else
                            for _, item in ipairs(child) do visit(item) end
                        end
                    end
                end
            end
        elseif tag == nil then
            for _, item in ipairs(node) do visit(item) end
        end
    end
    visit(root)
end

function checker._generic.lower_erased_core(modname, tree, st, errors)
    local clone_memo = {}
    local declared = types.clone_graph(assert(tree._type,
        "generic erasure requires the declared module graph"), clone_memo)
    tree._declared_type = declared
    checker._generic.freeze_declared_annotations(tree, clone_memo)

    local surface_registry = types.registry
    local erased_registry = checker._generic.prepare_erased_registry(
        surface_registry)
    local state = {
        st = st,
        errors = errors,
        surface_registry = surface_registry,
        erased_registry = erased_registry,
        erased_descriptors = {},
        calls = {},
        reverse_wrappers = {},
        hidden_case = 0,
    }
    types.registry = erased_registry

    for _, node in ipairs(tree) do checker._generic.lower_node(node, state) end
    checker._generic.sanitize_erased_graph(tree, state)

    -- Rebind every top-level declaration to the canonical erased owner member
    -- when it has one.  This keeps module-slot enumeration, nominal methods,
    -- field layouts, and source-private entries on one detached ordinary graph.
    for _, node in ipairs(tree) do
        if node._type then
            node._type = checker._generic.erased_descriptor(node._type, state)
        end
        if node._tag == "Ast.TopLevelRecord"
           or node._tag == "Ast.TopLevelUnion"
           or node._tag == "Ast.TopLevelInterface" then
            node._type = erased_registry[modname .. "." .. node.name]
        elseif node._tag == "Ast.TopLevelStatic" and node._nominal_owner then
            local owner = erased_registry[modname .. "." .. node.class]
            if owner and owner.functions then node._type = owner.functions[node.name] end
        elseif node._tag == "Ast.TopLevelMethod" and node._nominal_owner then
            local owner = erased_registry[modname .. "." .. node.class]
            if owner and owner.methods then node._type = owner.methods[node.name] end
        end
    end

    tree._type = makemoduletype(modname, tree, st)
    checker._generic.refresh_erased_annotations(tree)
    types.assert_erased(tree._type)
    for _, owner in pairs(erased_registry) do types.assert_erased(owner) end
    return declared, surface_registry
end


-- Entry point for the typechecker
--   ast: AST for the whole module
--   subject: the string that generated the AST
--   filename: the file name that contains the subject
--   loader: the module loader, a function from module name to its AST, code,
--   and filename or nil and an error
--
--   returns the module type and a list of type errors found
--   annotates the AST with the types of its terms in "_type" fields
--   annotates duplicate top-level declarations with a "_ignore" boolean field
function checker.check(modname, ast, subject, filename, loader, options)
    options = options or {}
    loader = loader or function ()
        return nil, "you must pass a loader to import modules"
    end
    func_stack = {}
    checker._foreign_function_depth = 0
    catch_depth = 0
    in_finally = 0
    finally_loop_floor = 0
    loop_depth = 0
    loop_frames = {}
    local st = symtab.new(modname)
    local previous_check_state = active_check_state
    active_check_state = st
    st.c_profile = nil
    st.foreign_includes = {}
    st.foreign_includes_version = 0
    st.pending_foreign_redeclarations = {}
    st.probe_service_provider = options.probe_service_provider
    if filename then
        st.source_dir = filename:match("^(.*)/[^/]*$")
        if not st.source_dir or st.source_dir == "" then
            st.source_dir = "."
        end
    end
    local errors = {subject = subject, filename = filename}
    local function run_check()
        mark_toplevel_duplicates(ast, errors)
        collect_type_aliases(ast, st, errors)
        checktoplevel(ast, st, errors, loader)
        checkbodies(ast, st, errors)
        if #errors == 0 then
            validate_union_source_projections(ast, errors)
        end
        reject_exported_c_ffi_types(modname, ast, errors)
        reject_exported_local_nominal_types(modname, ast, errors)
        ast._type = makemoduletype(modname, ast, st)
        local result_type = ast._type
        if #errors == 0 then
            -- Prove the source module's public graph through the same canonical
            -- owner-recovery path used by importers. Public applications may
            -- not rely on source-private methods omitted by serialization.
            local registered, registration_error =
                checker.register_module_interface(
                    modname, ast._type, loader, modname, {}, true, {})
            if not registered then
                checker.typeerror(errors,
                    (ast[1] and ast[1].loc) or { line = 1, column = 1 },
                    "public module interface is not recoverable: %s",
                    tostring(registration_error))
            end
        end
        if #errors == 0 then
            result_type, st._surface_registry =
                checker._generic.lower_erased_core(
                    modname, ast, st, errors)
        end
        return result_type, errors
    end

    -- Foreign conversion probing is lazily owned by this checker invocation.
    -- Checker internals are allowed to throw on violated invariants, so both
    -- the active nested-check context and an owned compiler service need the
    -- same finally-style cleanup as the ordinary diagnostic-return path.
    local checked, result_or_error, result_errors =
        xpcall(run_check, function(err) return err end)
    local close_call_ok, closed, close_err = true, true
    if st.owns_probe_service and st.probe_service then
        close_call_ok, closed, close_err =
            pcall(st.probe_service.close, st.probe_service)
        if checked and close_call_ok and not closed then
            table.insert(errors,
                "cannot clean the C probe service: " .. tostring(close_err))
        end
    end
    -- A nested source check returns its frozen declared interface to the
    -- importer, which still has surface declarations left to check.  Restore
    -- that outer surface registry now; the outermost successful check installs
    -- the complete erased registry for all later coder invocations.
    if st._surface_registry and (previous_check_state or not checked) then
        types.registry = st._surface_registry
    end
    active_check_state = previous_check_state
    if not checked then
        error(result_or_error, 0)
    elseif not close_call_ok then
        error(closed, 0)
    end
    return result_or_error, result_errors
end

return checker
