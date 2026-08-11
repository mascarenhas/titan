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
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
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
        for _, method in ipairs(typ.methods or {}) do
            checktype(method, loc, errors, seen)
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
    -- Resolving a transparent type-only alias is not an enum value use. The
    -- eventual type use revalidates the resolved graph in its own full or
    -- spelling-only context.
    local target = typefromnode(node.type, st, errors, true)
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
        -- Every supported Option uses the TValue descriptor. Check the base
        -- here as a defensive mirror of TypeOption validation so programmatic
        -- types cannot reach the coder with an unboxable C aggregate/function.
        return types.has_tvalue_representation(t.base)
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
    elseif tag == "Type.Function" then
        foreign_redeclaration_batch.collect_reads(
            typ._c_function, reads, seen)
        for _, param in ipairs(typ.params or {}) do
            foreign_redeclaration_batch.collect_reads(param, reads, seen)
        end
        for _, ret in ipairs(typ.rettypes or {}) do
            foreign_redeclaration_batch.collect_reads(ret, reads, seen)
        end
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
    elseif tag == "Type.Function" then
        writes[typ] = true
        foreign_redeclaration_batch.collect_writes(
            typ._c_function, writes, seen)
        for _, param in ipairs(typ.params or {}) do
            foreign_redeclaration_batch.collect_writes(
                param, writes, seen)
        end
        for _, ret in ipairs(typ.rettypes or {}) do
            foreign_redeclaration_batch.collect_writes(
                ret, writes, seen)
        end
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

local function c_function_as_function_type(cfunc)
    local ret = c_resolve(cfunc.ret)
    local rettypes = ret._tag == "Type.CVoid" and {} or { cfunc.ret }
    local converted =
        types.Function(cfunc.params, rettypes, cfunc.vararg, false, false)
    converted._c_function = cfunc
    converted._c_return_type = cfunc.ret
    converted._paramstyle = cfunc._paramstyle
    converted._return_declaration_qualifiers =
        cfunc._return_declaration_qualifiers
    return converted
end

local function c_function_pointer_accepts_function(target, ftype)
    local expected = c_function_pointer_type(target)
    if not expected or ftype._tag ~= "Type.Function"
       or #ftype.rettypes > 1
       or ftype.varargtype or ftype.flexrettype then
        return false
    end
    local actual = ftype._c_function
    if not actual then
        local ret = ftype.rettypes[1] or types.CVoid()
        actual = types.CFunction(
            ftype.params, ret, ftype.vararg, false)
        actual._paramstyle = ftype._paramstyle
        actual._return_declaration_qualifiers =
            ftype._return_declaration_qualifiers
    end
    return types.c_function_types_equal(expected, actual)
end

local function is_foreign_function_var(var)
    return var and var._tag == "Ast.VarDot"
        and var.exp and var.exp._type
        and var.exp._type._tag == "Type.CModule"
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

local function automatic_c_layout_error(typ, st, seen)
    typ = c_resolve(typ)
    if not typ or typ._tag == "Type.Invalid" then return nil end
    seen = seen or {}
    if seen[typ] then return nil end
    seen[typ] = true

    if typ._tag == "Type.CStruct" or typ._tag == "Type.CUnion" then
        if not st:foreign_definition_visible(typ) then
            return string.format(
                "automatic C object type '%s' is incomplete or not yet visible",
                types.tostring(typ))
        elseif typ._tag == "Type.CStruct" and typ.has_fam then
            return string.format(
                "automatic C object type '%s' has a flexible array member",
                types.tostring(typ))
        end
    elseif typ._tag == "Type.CArray" then
        if math.type(typ.len) ~= "integer" or typ.len <= 0 then
            return string.format(
                "automatic C array type '%s' requires a positive "
                .. "compile-time integer literal extent",
                types.tostring(typ))
        end
        local elem = c_resolve(typ.elem)
        if not elem or elem._tag == "Type.Invalid" then
            return nil
        elseif elem._tag == "Type.CVoid" then
            return "an automatic C array cannot have void elements"
        elseif elem._tag == "Type.CFunction" then
            return "an automatic C array cannot have function elements"
        elseif elem._tag == "Type.CArray"
            or elem._tag == "Type.CStruct"
            or elem._tag == "Type.CUnion" then
            return automatic_c_layout_error(elem, st, seen)
        elseif elem._tag ~= "Type.CInteger"
           and elem._tag ~= "Type.CFloat"
           and elem._tag ~= "Type.CPointer" then
            return string.format(
                "type '%s' is not a complete C object type usable as an "
                .. "automatic C array element",
                types.tostring(typ.elem))
        end
    end
end

local function automatic_c_object_error(typ, st)
    local resolved = c_resolve(typ)
    if not resolved or resolved._tag == "Type.Invalid" then return nil end
    if resolved._tag ~= "Type.CStruct"
       and resolved._tag ~= "Type.CUnion"
       and resolved._tag ~= "Type.CArray" then
        return string.format(
            "initializer-less local declarations require a complete C "
            .. "struct, union, or fixed array, not '%s'",
            types.tostring(typ))
    end

    local bearing, offender = types.c_automatic_gc_bearing(typ)
    if bearing then
        return string.format(
            "automatic C object type '%s' transitively contains "
            .. "GC-bearing FFI storage '%s', which automatic C objects do "
            .. "not trace",
            types.tostring(typ), types.tostring(offender))
    end
    return automatic_c_layout_error(typ, st)
end

local function c_pseudo_member(typ, name, st)
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

local function c_allocation_error(typ, st)
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
        owner = types.registry[typ.fqtn]
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
            and types.registry[source.fqtn] or nil
        local interface = target._tag == "Type.Nominal"
            and types.registry[target.fqtn] or nil
        if not concrete
           or (concrete._tag ~= "Type.Record"
               and concrete._tag ~= "Type.Union")
           or not interface
           or interface._tag ~= "Type.Interface"
           or not is_nominal_visible_from(st, source.fqtn) then
            return false
        end

        local implementation, failure =
            types.interface_implementation(
                concrete, interface, received)
        policy.interface_failure = failure or false
        return implementation and implementation.methods or false
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
        raw.exact == types.equals(source, target),
        "callable exactness marker is wrong")
    interface_adapter_assert(
        not (source.vararg or target.vararg) or raw.exact,
        "non-exact untyped C vararg adjustment")
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
    local concrete = types.registry[wrapper.source.fqtn]
    local interface = types.registry[wrapper.target.fqtn]
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

local function checker_assignment_adjustment(source, target, st, options)
    st = st or active_check_state
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
        local alias = st:find_type_alias(node.name)
        if alias then
            local typ = resolve_type_alias(alias, st, errors)
            if checker._ensure_c_enum_supported(
                    st, typ, node.loc, errors, nil,
                    defer_c_enum_carrier and true or false) then
                return typ
            end
            return types.Invalid()
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
            local type_member =
                types.module_type_member(
                    mod._type, node.name, mod._source_import)
            if type_member then
                if type_member._tag == "Type.Interface" then
                    return types.Nominal(type_member.name)
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
            return types.Nominal(fqtn)
        elseif mod and mod._type and mod._type._tag == "Type.CModule" then
            local typ = mod._type.type_members and mod._type.type_members[node.name]
            if typ then
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
        return invalid(errors, node.loc, "module '%s' referenced by type not found", node.module)
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
    node._array_writer_plan = types.dynamic_coercion(normalized) or false
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
    local cfunc = ftype._c_function
    if not cfunc then
        local ret = ftype._c_return_type
            or ftype.rettypes[1] or types.CVoid()
        cfunc =
            types.CFunction(ftype.params, ret, ftype.vararg, false)
        cfunc._paramstyle = ftype._paramstyle
        cfunc._return_declaration_qualifiers =
            ftype._return_declaration_qualifiers
    end
    return types.CPointer(cfunc, {})
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
        -- The parser reserves an empty RHS for the one-declaration automatic
        -- C-object form. It is not an arity-adjusted expression list: the
        -- declaration itself owns deterministic C zero initialization.
        if #node.exps == 0 then
            if #node.decls ~= 1 or not node.decls[1].type then
                checker.typeerror(errors, node.loc,
                    "an initializer-less local must declare exactly one "
                    .. "explicitly typed automatic C object")
                for _, decl in ipairs(node.decls) do
                    decl._type = decl.type
                        and typefromnode(decl.type, st, errors)
                        or types.Invalid()
                    declare(decl, st, errors)
                end
                return
            end

            local decl = node.decls[1]
            decl._type = typefromnode(decl.type, st, errors)
            checktype(decl._type, decl.loc, errors)
            local automatic_error =
                automatic_c_object_error(decl._type, st)
            if automatic_error then
                local errloc = decl.loc
                if decl.type._tag == "Ast.TypeCArray"
                   and (math.type(decl.type.length.value) ~= "integer"
                        or decl.type.length.value <= 0) then
                    errloc = decl.type.length.loc or errloc
                end
                checker.typeerror(errors, errloc, "%s", automatic_error)
            else
                decl._c_zero_init = true
                decl._c_automatic_object = true
                node._c_zero_init = true
            end
            declare(decl, st, errors)
            return
        end

        local fixed = {}
        for i, decl in ipairs(node.decls) do
            if decl.type then
                checkdecl(decl, st, errors)
                fixed[i] = decl._type
                if types.is_c_array(decl._type) then
                    checker.typeerror(errors, decl.loc,
                        "cannot initialize a local by copying a whole C array")
                end
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
                if types.is_c_array(decl._type) then
                    checker.typeerror(errors, decl.loc,
                        "cannot initialize a local by copying a whole C array")
                end
                exp = coerce_and_check(exp, decl._type,
                    "declaration of local variable " .. decl.name,
                    errors, decl.loc)
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
            local owner = types.registry[scrutinee_type.fqtn]
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
            local namespace = alias and alias_namespace_type(
                resolve_type_alias(alias, st, errors), st)
            local interface = st.interface_declarations
                and st.interface_declarations[node.name]
            if namespace then
                node._alias_namespace = true
                node._alias_decl = alias
                node._type = namespace
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
            local type = types.registry[ltype.fqtn]
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
                if node._decl then
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
        if node._type and node._type._tag ~= "Type.Invalid" then
            local spelling_only = context
                and node.exp._type._tag == "Type.CModule"
                and node._type._tag == "Type.Function"
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
        local celem, cterm, cerr = c_index_elem_type(node.exp1._type)
        if node.exp1._type._tag == "Type.Array" then
            local elem = node.exp1._type.elem
            node._type = optionize(elem)
            node._read_guard = types.gradual_guard(node._type) or false
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
            node._read_guard = types.gradual_guard(node._type) or false
            if mode ~= "write" and not node._read_guard then
                checker.typeerror(errors, node.loc,
                    "cannot read map values of type '%s' because the type has no sound runtime guard",
                    types.tostring(values))
            end
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

local function annotate_c_call_mutations(node, ftype)
    local mutated, seen = {}, {}
    for i, arg in ipairs(node.args.args) do
        local target = (ftype.params or {})[i]
        if not target and ftype.vararg then
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
annotate_call_results = function(node, ftype, demand, errors)
    demand = demand or default_call_result_demand(node)
    node._callee_type = ftype
    node._types = ftype.rettypes
    node._flexrettype = ftype.flexrettype or false
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

    local nfixed = #ftype.rettypes
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
            node._lua_open_result_dynamic_plan =
                types.dynamic_coercion(ftype.flexrettype) or false
            node._strict_open_result_guard_plan =
                types.gradual_guard(ftype.flexrettype) or false
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
            local ptype = ftype.params[i]
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
    local cast_plan = types.written_cast(source, target)
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
        node._type = types.Nominal(union.name)
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
                local record = types.registry[context.fqtn]
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
                node._type = types.Nominal(context.fqtn)
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
        elseif texp._tag == "Type.Record" or texp._tag == "Type.Union" then
            local kind = texp._tag == "Type.Record" and "record" or "union"
            node._type = invalid(errors, node.loc,
                "trying to access %s type '%s' as a first-class value",
                kind, texp.name)
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
        if check_c_unary_operator(node, st, errors) then
            return
        end
        local texp = node.exp._type
        local loc = node.loc
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
               and not has_c_length(texp) then
                checker.typeerror(errors, loc,
                    "trying to take the length of a %s instead of an array, integer-keyed map, string, C array, or counted owned C array",
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
        if check_c_binary_operator(node, st, errors) then
            return
        end
        local loc = node.loc
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
                if not checker._ensure_c_enum_supported(
                        st, cfunc, node.loc, errors) then
                    node._type = types.Invalid()
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local cftype = c_function_as_function_type(cfunc)
                node._c_pointer_call = cfunc
                annotate_call_arguments(node,
                    checkargs(cftype, node.args.args, node.loc,
                        "function pointer '" .. fname .. "'", st, errors,
                        false))
                annotate_c_call_mutations(node, cftype)
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

            local pseudo_new = node.exp._tag == "Ast.ExpVar"
                and node.exp.var._decl
                and node.exp.var._decl._tag == "Type.CPseudoNew"
            if named and pseudo_new then
                node._type = types.Invalid()
                named_target_error(errors, node.loc)
                check_call_argument_expressions(node.args, st, errors)
                return
            elseif pseudo_new then
                local alloc_err = c_allocation_error(
                    node.exp.var._decl.ctype, st)
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
            if not pseudo_new and node.exp._tag == "Ast.ExpVar"
               and is_foreign_function_var(node.exp.var) then
                annotate_c_call_mutations(node, ftype)
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
            if otype._tag == "Type.Nominal" and
               types.registry[otype.fqtn] and
               (types.registry[otype.fqtn]._tag == "Type.Record"
                or types.registry[otype.fqtn]._tag == "Type.Union"
                or types.registry[otype.fqtn]._tag == "Type.Interface") then
                local class = types.registry[otype.fqtn]
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
    ["Ast.ExpMethodRef"] = function(node, st, errors, _)
        checkexp(node.exp, st, errors)
        local otype = node.exp._type
        -- auto-unwrap an option receiver, like a method call does, so `p:m` on a
        -- Point? unwraps to the underlying record (the cast codegen nil-checks).
        if otype._tag == "Type.Option" and otype.base._tag == "Type.Nominal" then
            node.exp = tryforce(node.exp)
            otype = otype.base
        end
        if otype._tag == "Type.CModule" then
            node._type = invalid(errors, node.loc,
                "a foreign (C) method cannot be used as a first-class value")
        elseif otype._tag == "Type.Nominal" and
           types.registry[otype.fqtn] and
           (types.registry[otype.fqtn]._tag == "Type.Record"
            or types.registry[otype.fqtn]._tag == "Type.Union"
            or types.registry[otype.fqtn]._tag == "Type.Interface") then
            local class = types.registry[otype.fqtn]
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
    if node._type._tag == "Type.Method" then
        targets[1] = types.Nominal(node._type.fqtn)
    end
    for _, typ in ipairs(node._type.params) do
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
    if node._type.varargtype then
        node._lua_vararg_dynamic_plan =
            types.dynamic_coercion(node._type.varargtype) or false
        node._strict_vararg_guard_plan =
            types.gradual_guard(node._type.varargtype) or false
    else
        node._lua_vararg_dynamic_plan = false
        node._strict_vararg_guard_plan = false
    end

    if node._type._tag == "Type.Method" then
        node._bound_strict_guard_plans = {}
        for index, typ in ipairs(node._type.params) do
            node._bound_strict_guard_plans[index] =
                types.gradual_guard(typ) or false
        end
        node._bound_strict_vararg_guard_plan =
            node._type.varargtype
                and (types.gradual_guard(node._type.varargtype) or false)
                or false
    end
end

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
    annotate_lua_function_boundary(node)
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
    local ret = st:with_block(checkstat, node.block, st, errors)
    catch_depth, in_finally, finally_loop_floor, loop_depth =
        saved_catch, saved_in_finally, saved_floor, saved_loop
    loop_frames = saved_loop_frames
    -- A zero-return `() -> ()` function (empty rettypes) may fall off the end,
    -- exactly like a `nil`-returning one; only a function whose first declared
    -- return type is some non-`nil` value must not fall off the end.
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
    local self = ast.Decl(node.loc, "self",
        ast.TypeName(node.loc, node._nominal_owner.name), false)
    node._self = self
    self._type = typefromnode(self.type, st, errors)
    -- `self` is declared into this method's own frame (inside checkfuncbody), so
    -- a lambda nested in the method body captures it like any parameter.
    checkfuncbody(node, st, errors, { self_decl = self })
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
    if decl._tag == "Type.CPseudoNew" then
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
                    table.insert(rettypes,
                        typefromnode(rettype, st, errors))
                end
                local flexrettype =
                    flexible_return_type(method, st, errors)
                method._type = types.Method(
                    fqtn, method.name, ptypes, rettypes,
                    varargtype, flexrettype, paramnames)
                annotate_lua_function_boundary(method)
                table.insert(methods, method._type)
            end
        end

        node._type = types.Interface(fqtn, methods)
        node._type._source_complete = true
        types.registry[fqtn] = node._type
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

    ["Ast.StatTry"] = function(node)
        assert(node._module_initializer)
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
                field._type = ftype
                -- 0-based field index: a record instance is a Udata whose
                -- user values hold the fields directly (uv[0..N-1]); Lua never
                -- sees these indices, so there is no reserved uv[0].
                local tfield = types.Field(fqtn, field.name, ftype, i - 1)
                tfield.islocal = field.islocal and true or false
                -- Public record writes are genuine Lua-to-Titan boundaries.
                -- Preserve an explicit false for targets whose dynamic
                -- conversion is unavailable so code generation emits a
                -- rejecting setter instead of accepting a representation
                -- category on its own.
                tfield.dynamic_plan =
                    types.dynamic_coercion(ftype) or false
                field._dynamic_plan = tfield.dynamic_plan
                table.insert(fields, tfield)
            end
        end
        node._type = types.Record(fqtn, fields, {}, {}, #fields)
        node._type.islocal = node.islocal and true or false
        node._type._source_complete = true
        node._dynamic_receiver_plan =
            assert(types.dynamic_coercion(types.Nominal(fqtn)),
                "record nominal lacks its dynamic receiver plan")
        types.registry[fqtn] = node._type
    end,

    ["Ast.TopLevelUnion"] = function(node, st, errors)
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
                table.insert(variants, tvariant)
            end
        end
        node._type = types.Union(
            fqtn, variants, {}, {}, #node.variants)
        node._type.islocal = node.islocal and true or false
        node._type._source_complete = true
        node._dynamic_receiver_plan =
            assert(types.dynamic_coercion(types.Nominal(fqtn)),
                "union nominal lacks its dynamic receiver plan")
        types.registry[fqtn] = node._type
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
        local ptypes, varargtype, paramnames = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        local flexrettype = flexible_return_type(node, st, errors)
        local published_paramnames = paramnames
        if node._union_constructor then
            published_paramnames = false
        end
        node._type = types.StaticMethod(
            ownertype.name, node.name, ptypes, rettypes,
            varargtype, flexrettype,
            published_paramnames)
        node._type.islocal = node.islocal and true or false
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
        local ptypes, varargtype, paramnames = param_types(node.params, st, errors)
        local rettypes = {}
        for _, rt in ipairs(node.rettypes) do
            table.insert(rettypes, typefromnode(rt, st, errors))
        end
        local flexrettype = flexible_return_type(node, st, errors)
        node._type = types.Method(ownertype.name, node.name, ptypes, rettypes,
            varargtype, flexrettype, paramnames)
        node._type.islocal = node.islocal and true or false
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
    finalize_foreign_redeclarations(st, errors)

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
            if tag == "Ast.TopLevelFunc" or node._module_initializer or
               tag == "Ast.StatBlock" or tag == "Ast.StatTry" then
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

-- Walk a recovered interface type and, for every Nominal that names a nominal
-- of *another* module, recover that module so its definition and its own
-- referenced nominals register too. This makes nominal types resolve
-- transitively across compiled-only imports (a module's interface may
-- return/accept a record defined in a module it imported but that this
-- importer does not import directly). `seen` guards one interface's type
-- graph; `interface_seen` guards the recursive module graph while preserving
-- the original physical exposer. Load failures are ignored — the nominal
-- simply stays unresolved, exactly as before this pass existed.
local function register_referenced_nominals(
        t, loader, seen, exposing_module, interface_seen)
    if type(t) ~= "table" or not t._tag or seen[t] then return end
    seen[t] = true
    local tag = t._tag
    if tag == "Type.Nominal" then
        local mod = t.fqtn:match("^(.*)%.[^.]+$")
        if mod and mod ~= "" then
            -- One recovered interface can mention several distinct records
            -- from the same owner. Native provenance is an owner/exposer
            -- relation, so recovering it more than once only repeats loader
            -- work and can produce duplicate observable loads for callers.
            local owner_key = "\0nominal-owner:" .. mod
            if not seen[owner_key] then
                seen[owner_key] = true
                local request = {
                    kind = "nominal-owner",
                    exposer = exposing_module,
                    interface_seen = interface_seen,
                }
                -- A previously registered nominal still needs its complete
                -- interface replayed for this exposer. `interface_seen`
                -- terminates cyclic nominal graphs without dropping nested
                -- native-provenance edges.
                pcall(checker.checkimport, mod, loader, request)
            end
        end
    elseif tag == "Type.Array" then
        register_referenced_nominals(
            t.elem, loader, seen, exposing_module, interface_seen)
    elseif tag == "Type.Map" then
        register_referenced_nominals(
            t.keys, loader, seen, exposing_module, interface_seen)
        register_referenced_nominals(
            t.values, loader, seen, exposing_module, interface_seen)
    elseif tag == "Type.Option" then
        register_referenced_nominals(
            t.base, loader, seen, exposing_module, interface_seen)
    elseif tag == "Type.ModuleMember" or tag == "Type.ModuleVariable" then
        register_referenced_nominals(
            t.type, loader, seen, exposing_module, interface_seen)
    elseif tag == "Type.Function" or tag == "Type.Method"
           or tag == "Type.StaticMethod" then
        for _, p in ipairs(t.params or {}) do
            register_referenced_nominals(
                p, loader, seen, exposing_module, interface_seen)
        end
        for _, r in ipairs(t.rettypes or {}) do
            register_referenced_nominals(
                r, loader, seen, exposing_module, interface_seen)
        end
        if t.varargtype then
            register_referenced_nominals(
                t.varargtype, loader, seen, exposing_module, interface_seen)
        end
        if t.flexrettype then
            register_referenced_nominals(
                t.flexrettype, loader, seen, exposing_module, interface_seen)
        end
    elseif tag == "Type.Record" then
        for _, f in ipairs(t.fields or {}) do
            if not f.islocal then
                register_referenced_nominals(
                    f.type, loader, seen, exposing_module, interface_seen)
            end
        end
        for _, fn in pairs(t.functions or {}) do
            if not fn.islocal then
                register_referenced_nominals(
                    fn, loader, seen, exposing_module, interface_seen)
            end
        end
        for _, method in pairs(t.methods or {}) do
            if not method.islocal then
                register_referenced_nominals(
                    method, loader, seen, exposing_module, interface_seen)
            end
        end
    elseif tag == "Type.Union" then
        for _, variant in ipairs(t.variants or {}) do
            if not variant.islocal and variant.payload ~= false then
                register_referenced_nominals(
                    variant.payload, loader, seen,
                    exposing_module, interface_seen)
            end
        end
        for _, fn in pairs(t.functions or {}) do
            if not fn.islocal then
                register_referenced_nominals(
                    fn, loader, seen, exposing_module, interface_seen)
            end
        end
        for _, method in pairs(t.methods or {}) do
            if not method.islocal then
                register_referenced_nominals(
                    method, loader, seen, exposing_module, interface_seen)
            end
        end
    elseif tag == "Type.Interface" then
        for _, method in ipairs(t.methods or {}) do
            register_referenced_nominals(
                method, loader, seen, exposing_module, interface_seen)
        end
    end
end

local function first_local_nominal_type(typ, seen)
    if type(typ) ~= "table" or not typ._tag then return nil end
    seen = seen or {}
    if seen[typ] then return nil end
    seen[typ] = true

    local tag = typ._tag
    if tag == "Type.Nominal" then
        local nominal = types.registry[typ.fqtn]
        if nominal and nominal.islocal then
            return typ
        end
    elseif tag == "Type.Record" then
        if typ.islocal then return typ end
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
        trusted_source)
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
    if interface_seen[interface_key] then return end
    interface_seen[interface_key] = true

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

    local seen = {}
    for _, view in ipairs(member_views) do
        for _, member in ipairs(view) do
            register_referenced_nominals(
                member.type or member, loader, seen, exposer, interface_seen)
        end
    end
    for _, view in ipairs(type_views) do
        for _, member in pairs(view) do
            register_referenced_nominals(
                member, loader, seen, exposer, interface_seen)
        end
    end
end

function checker.checkimport(modname, loader, request)
    local ok, type_or_error, errors, import_info = loader(modname, request)
    if not ok then return nil, type_or_error end
    checker.register_module_interface(
        modname, type_or_error, loader, request and request.exposer,
        request and request.interface_seen,
        import_info and import_info.kind == "source"
            and type_or_error._source == true)
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
        return ast._type, errors
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
    active_check_state = previous_check_state
    if not checked then
        error(result_or_error, 0)
    elseif not close_call_ok then
        error(closed, 0)
    end
    return result_or_error, result_errors
end

return checker
