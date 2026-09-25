local core = require "titan-compiler.checker.core"
local _ENV = core

-- The compiler driver installs the exact C toolchain configuration used for
-- generated code. Keeping this small hook in the checker makes every foreign
-- import use the same compiler, language mode, and already parsed CPP flags,
-- while checker-only embeddings supply their own explicit SDK include roots.
foreign_c_options = {}

foreign_c_config_error = nil

function checker.configure_foreign_c(options, config_error)
    foreign_c_options = options or {}
    foreign_c_config_error = config_error
end

function new_direct_probe_service()
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
    local io_strategy = foreign_c_options.io or toolchain.io
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
                io = io_strategy,
            })
        if not inputs then return nil, input_error end
        local profile, profile_error =
            csemantics.build_profile(inputs)
        if not profile then return nil, profile_error end
        configured.profile = profile
        configured.profile_identity = profile.identity
        toolchain = configured
    end
    local service_options = {
        io = io_strategy,
        toolchain = toolchain,
        verbose = foreign_c_options.verbose == true,
        cache_directory = foreign_c_options.probe_cache_directory,
    }
    -- Ordinary compiler/checker use must retain the compiler I/O strategy as
    -- the runner authority so asynchronous ownership remains with the caller.
    if foreign_c_options.probe_runner ~= nil then
        service_options.runner = foreign_c_options.probe_runner
    end
    return cprobe.new_service(service_options)
end

-- Numeric metadata and contextual primitive type syntax need the target's
-- exact scalar model, but do not themselves perform a native C operation.
-- A resolver may supply its validated analysis-only build profile here.
function ensure_c_profile(st)
    if st.c_profile then return st.c_profile end
    if st.c_profile_error then return nil, st.c_profile_error end
    if not st.target_profile_provider then
        local service, err = ensure_probe_service(st)
        if not service then return nil, err end
        return st.c_profile
    end
    local profile, err = st.target_profile_provider()
    local identity
    if profile then identity, err = csemantics.profile_identity(profile) end
    if not identity then
        st.c_profile_error = err or "target C profile is unavailable"
        return nil, st.c_profile_error
    end
    st.c_profile = types.clone_graph(profile)
    st.c_profile.identity = identity
    return st.c_profile
end

function ensure_probe_service(st)
    if st.probe_service then return st.probe_service end
    if st.probe_service_error then
        return nil, st.probe_service_error
    end
    if st.target_profile_provider then
        local profile, profile_error = ensure_c_profile(st)
        if not profile then
            st.probe_service_error = profile_error
            return nil, profile_error
        end
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
    if st.c_profile then
        local live_identity, profile_error =
            csemantics.profile_identity(service.profile)
        if not live_identity or live_identity ~= st.c_profile.identity then
            st.probe_service_error = profile_error or
                "native C target profile disagrees with semantic target profile"
            if st.owns_probe_service and type(service.close) == "function" then
                pcall(service.close, service)
            end
            st.owns_probe_service = false
            return nil, st.probe_service_error
        end
    end
    st.probe_service = service
    -- C conversion completes canonical tag graphs in place. Give each checker
    -- its own target-profile leaves so source provenance never mutates the
    -- service profile shared by nested or later module checks.
    st.c_profile = types.clone_graph(service.profile)
    return service
end

-- Header parsing owns these dependency identities. Keep the immutable input
-- closure for source importers and language-server invalidation independently
-- of the compile-only probe cache.
function collect_foreign_header_inputs(includes, supplemental_includes)
    local result, seen = {}, {}
    for _, group in ipairs({ includes or {}, supplemental_includes or {} }) do
        for _, include in ipairs(group) do
            for _, inputs in ipairs({
                include.c_header_dependencies or {},
                include.c_header_search_inputs or {},
            }) do
                for _, input in ipairs(inputs) do
                    if input.restat ~= false then
                        local key = input.kind .. "\0" .. input.path
                        local previous = seen[key]
                        if previous and previous ~= input.identity then
                            return nil,
                                "conflicting C header input identity for '" ..
                                input.path .. "'"
                        elseif not previous then
                            seen[key] = input.identity
                            result[#result + 1] = {
                                kind = input.kind,
                                path = input.path,
                                identity = input.identity,
                                observation = cdriver.copy_header_observation(input.observation),
                            }
                        end
                    end
                end
            end
        end
    end
    return result
end

local function remember_forced_foreign_headers(st, service)
    if st.forced_foreign_headers then return true end
    local options, err = service:cdriver_process_options()
    if not options then return nil, err end
    local inputs
    inputs, err = cdriver.forced_header_inputs(options)
    if not inputs then return nil, err end

    -- A module using only contextual C types may have no parsed foreign
    -- include. Explicit -include/-imacros files still belong to its source
    -- dependency snapshot, independently of any compiled-probe cache entry.
    local include = {
        c_header_dependencies = inputs.c_header_dependencies,
        c_header_search_inputs = inputs.c_header_search_inputs,
    }
    st.forced_foreign_headers = include
    st.supplemental_foreign_includes[
        #st.supplemental_foreign_includes + 1] = include
    return true
end

function ensure_module_probe(st)
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

    local remembered
    remembered, err = remember_forced_foreign_headers(st, service)
    if not remembered then
        st.module_probe_error = err
        st.module_probe_error_includes_version = includes_version
        return nil, err
    end
    local module_probe
    module_probe, err = service:module_context({
        module = st.modname,
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

checker._enum_carrier_names = cprobe.enum_carrier_names

-- Every actual C use sees the one module environment, including explicit
-- source dependencies. Rendering a type does not reconstruct another set of
-- header origins or another preprocessor ordering.
function checker._probe_for_c_types(st)
    return ensure_module_probe(st)
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

        local eligible_ids, entries = {}, {}
        for id, name in ipairs(checker._enum_carrier_names) do
            local entry = profile.integers[name]
            if entry then
                local fits, range_error = csemantics.integer_range_contains(
                    lua_entry.type._c_numeric, entry.type._c_numeric)
                assert(fits ~= nil, range_error)
                if fits or resolved._c_enum_enumerator then
                    eligible_ids[#eligible_ids + 1] = id
                    entries[id] = entry
                end
            end
        end

        local result = probe:select_enum_carrier(declaration_type, eligible_ids)
        if not result.accepted then
            checker.typeerror(errors, loc,
                "cannot validate C enum type '%s' with the configured "
                .. "compiler: %s", types.tostring(typ),
                result.message or result.summary or result.status)
            return false
        end
        local selection = assert(result.selection,
            "successful enum query has no selection")
        if selection.match_count > 1 then
            checker.typeerror(errors, loc,
                "configured C compiler reported multiple carriers "
                .. "for enum type '%s'", types.tostring(typ))
            return false
        end
        local selected = selection.match_count == 1 and
            assert(entries[selection.carrier_id], "selected enum carrier is ineligible")
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
        resolved._c_enum_validated = true
        return true
    end

    local children = {}
    local child_spelling_only = spelling_only
    if tag == "Type.CStruct" or tag == "Type.CUnion"
       or tag == "Type.COwned" then
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

function is_foreign_type_declaration(ftype)
    return ftype.type == "typedef" or
           ftype.type == "struct" or
           ftype.type == "union"
end

function is_foreign_ordinary_identifier(name, ftype)
    if ftype.type == "enum" then
        return not name:match("^enum@")
    end
    return ftype.type == "typedef"
        or not (ftype.type == "struct"
                or ftype.type == "union"
                or ftype.type == "enum")
end

function copy_foreign_paramnames(names)
    if names == false then return false end
    local out = {}
    for _, name in ipairs(names) do
        out[#out + 1] = name
    end
    return out
end

function report_foreign_header_context_failure(st, errors, result)
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

-- Production probe methods can cross the compiler I/O strategy and suspend a
-- Titan Task. Invoke those methods directly so a cancellation raised while
-- resuming through Lua is not mistaken for an ordinary probe failure. Keep
-- the protected boundary only for injected probe implementations.
local function invoke_module_probe(module_probe, method, ...)
    if getmetatable(module_probe) == cprobe.ModuleContext then
        return true, method(module_probe, ...)
    end
    return pcall(method, module_probe, ...)
end

function validate_foreign_environment(st, errors)
    -- Keep one native baseline for analysis-only diagnostics. The combined
    -- parser owns declaration identity; no per-name pair questions remain.
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
        local ok, validated = invoke_module_probe(
            module_probe, module_probe.validate_baseline)
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

    if result.status ~= "success" then
        report_foreign_header_context_failure(st, errors, result)
    end
end

function c_resolve(t)
    return types.resolve_c_typedef(t)
end

function is_c_type_namespace(exp)
    return exp._tag == "Ast.ExpForeignType"
end

c_type_namespace_context = {}
current_module_cast_context = {}

function c_owned_type(typ, has_count)
    return types.COwned(typ, has_count and true or false)
end

function c_function_pointer_type(typ)
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
function call_signature(callable)
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

function c_function_pointer_accepts_declaration(target, cfunc)
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

function incomplete_c_object_error(typ, st, subject, seen)
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

function report_incomplete_c_object(typ, st, subject, loc, errors)
    local err = incomplete_c_object_error(typ, st, subject)
    if err then
        checker.typeerror(errors, loc, err)
        return false
    end
    return true
end

-- A nominal member owns fixed C bytes, but observing those bytes borrows an
-- interior address. Keep this separate from TValue representation: admitting
-- an embedded aggregate must not make it boxable in containers or calls.
function checker._nominal_storage_plan(typ, written_array_view)
    local projection = typ
    local kind = written_array_view and "borrowed_array_view" or "value"
    if types.is_c_aggregate(typ) and not types.is_c_tvalue(typ) then
        local resolved = c_resolve(typ)
        kind = "fixed_aggregate"
        if resolved._tag == "Type.CArray" then
            projection = types.CPointer(
                resolved.elem, types.c_type_qualifiers(typ))
        else
            -- Retaining the declared pointee also retains typedef qualifiers;
            -- the Titan member's binding constness never adds C qualifiers.
            projection = types.CPointer(typ, {})
        end
    end
    return {
        kind = kind,
        storage_type = typ,
        projection_type = projection,
    }
end

function checker._nominal_member_type(written, typ)
    if written and written._tag == "Ast.TypeCArray"
       and not written.length then
        local resolved = c_resolve(typ)
        if resolved and resolved._tag == "Type.CArray" then
            return types.CPointer(
                resolved.elem, types.c_type_qualifiers(typ)), true
        end
    end
    return typ, false
end

local function nominal_embedded_object_error(typ, st, seen)
    typ = c_resolve(typ)
    if not typ or seen[typ] then return nil end
    seen[typ] = true
    local incomplete = incomplete_c_object_error(
        typ, st, "embedded nominal storage")
    if incomplete then return incomplete end
    if typ._tag == "Type.CStruct" or typ._tag == "Type.CUnion" then
        if typ.has_fam then
            return string.format(
                "embedded nominal storage cannot contain C type '%s' with a flexible array member",
                types.tostring(typ))
        end
        for _, field in ipairs(typ.fields or {}) do
            local err = nominal_embedded_object_error(field.type, st, seen)
            if err then return err end
        end
    elseif typ._tag == "Type.CArray" then
        return nominal_embedded_object_error(typ.elem, st, seen)
    end
end

function checker._nominal_storage_error(typ, st)
    if types.has_tvalue_representation(typ) then return nil end
    if not types.is_c_aggregate(typ) then
        return string.format(
            "type '%s' has no nominal storage representation",
            types.tostring(typ))
    end
    local err = nominal_embedded_object_error(typ, st, {})
    if err then return err end
    local bearing, offender = types.c_automatic_gc_bearing(typ)
    if bearing then
        return string.format(
            "embedded nominal storage of type '%s' transitively contains GC-bearing FFI storage '%s', which payload bytes do not trace",
            types.tostring(typ), types.tostring(offender))
    end
end

-- C allocation pseudo-members are syntax-bound checker declarations, not
-- boxed callable values. The singleton context lets VarDot expose their narrow
-- call signature only while it is the direct callee of an ExpCall; every other
-- value use is rejected before the descriptor can enter the type algebra.
c_pseudo_callee_context = {}

function c_pseudo_member(typ, name, st)
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
            type = checker._foreign_function_depth > 0
                and size_entry.type or types.Integer(),
            result_source = size_entry.type,
        }
    end
end

function field_macro_path_spelling(path)
    local parts = {}
    for _, segment in ipairs(path or {}) do
        if type(segment) ~= "string" or segment == "" then
            return "<invalid>"
        end
        parts[#parts + 1] = segment
    end
    return #parts > 0 and table.concat(parts, ".") or "<invalid>"
end

function field_macro_error(root, name, projection, reason)
    return string.format(
        "C field macro '%s' expands to '%s', which is not a valid physical "
        .. "field path in C type '%s': %s",
        name, field_macro_path_spelling(projection and projection.path),
        types.tostring(root), reason)
end

function projected_c_field(root, name, projection, st)
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

function active_field_macro(name, st)
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

function c_field_decl(typ, name, st)
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

function c_index_elem_type(typ)
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
c_assignment_base_has_storage = nil

function c_aggregate_storage_expression(exp)
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

-- Return the originating const local when an lvalue descends only through
-- inline C aggregate storage. Pointer/owned dereferences deliberately stop the
-- walk: binding constness is shallow and does not freeze an independent
-- pointee.
function const_inline_c_storage_decl(exp)
    if not exp then return nil end
    local value_type = exp._type and c_resolve(exp._type)
    if value_type and (value_type._tag == "Type.CPointer"
                       or value_type._tag == "Type.COwned") then
        return nil
    end
    if exp._tag == "Ast.ExpVar" then exp = exp.var end

    if exp._tag == "Ast.VarName" then
        local decl = exp._decl
        local typ = decl and decl._type and c_resolve(decl._type)
        if decl and decl._tag == "Ast.Decl" and decl.isconst and typ
           and (typ._tag == "Type.CStruct"
                or typ._tag == "Type.CUnion"
                or typ._tag == "Type.CArray") then
            return decl
        end
        return nil
    elseif exp._tag == "Ast.VarDot" and exp._decl
           and exp._decl._tag == "Type.CField" then
        local owner = exp.exp and exp.exp._type
            and c_resolve(exp.exp._type)
        if owner and (owner._tag == "Type.CStruct"
                      or owner._tag == "Type.CUnion"
                      or owner._tag == "Type.CArray") then
            return const_inline_c_storage_decl(exp.exp)
        end
    elseif exp._tag == "Ast.VarBracket" and exp.exp1 then
        local owner = exp.exp1._type and c_resolve(exp.exp1._type)
        if owner and owner._tag == "Type.CArray" then
            return const_inline_c_storage_decl(exp.exp1)
        end
    end
    return nil
end

function check_c_assignment_storage(var, errors)
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

    local const_decl = const_inline_c_storage_decl(base)
    if const_decl then
        checker.typeerror(errors, var.loc,
            "cannot mutate inline C storage of const local '%s'",
            const_decl.name)
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

function has_c_length(typ)
    typ = c_resolve(typ)
    return typ._tag == "Type.CArray"
        and type(typ.len) == "number"
        or (typ._tag == "Type.COwned" and typ.count)
end

function c_allocation_error(typ, st, allow_automatic_array)
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

function checker._allocation_integer_literal(exp, st)
    while exp and (exp._tag == "Ast.ExpCast"
                   or exp._tag == "Ast.ExpAdjust") do
        if exp._tag == "Ast.ExpCast" and not exp._implicit_coercion then
            local identity = exp._written_cast
                and exp._written_cast.op == "identity"
            local integer_target = exp.target and
                (exp.target._tag == "Type.Integer"
                 or exp.target._tag == "Ast.TypeInteger")
            -- A written C cast may truncate the macro's value. Only peel an
            -- identity or checked Titan-integer conversion; other expressions
            -- keep the normal dynamically counted allocation path.
            if not identity and not integer_target then return nil end
        end
        exp = exp.exp
    end
    if exp and exp._tag == "Ast.ExpInteger"
       and math.type(exp.value) == "integer" then
        return exp.value
    end
    if not st or not exp or exp._tag ~= "Ast.ExpVar"
       or exp.var._tag ~= "Ast.VarDot" then return nil end
    local var = exp.var
    local receiver = var.exp
    if receiver._tag ~= "Ast.ExpVar"
       or receiver.var._tag ~= "Ast.VarName" then return nil end
    local namespace = st:find_symbol(receiver.var.name)
    if not namespace or namespace._tag ~= "Checker.ForeignNamespace" then
        return nil
    end
    local member = namespace._type.members[var.name]
    local decimal = member and member._c_integer_constant
    if not decimal then return nil end
    -- Macro evaluation uses the configured C target. Only carry its exact
    -- decimal result into the host AST when both integer carriers can hold it.
    local value = tonumber(decimal)
    if math.type(value) ~= "integer" or tostring(value) ~= decimal then return nil end
    local carrier = st.c_profile and st.c_profile.integers[st.c_profile.lua_integer]
    if not carrier then return nil end
    local minimum, maximum = tonumber(carrier.minimum), tonumber(carrier.maximum)
    if not minimum or not maximum or value < minimum or value > maximum then
        return nil
    end
    return value
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

local function nominal_fixed_array_extent(target, payload, count, st, loc, errors)
    if not count or count <= 0 then
        checker.typeerror(errors, loc,
            "fixed nominal C array initialization requires a positive compile-time allocation count")
        return false
    end
    local resolved = c_resolve(target)
    if type(resolved.len) == "number" then
        if resolved.len ~= count then
            checker.typeerror(errors, loc,
                "fixed nominal C array has extent %d but '.new_array' allocates %d element(s)",
                resolved.len, count)
            return false
        end
        return true
    end
    -- Header extents can be C integer constant expressions. The target
    -- compiler proves their extent; evaluating that expression in Lua would
    -- silently substitute host arithmetic and macro context.
    local probe, probe_error = checker._probe_for_c_types(st)
    if not probe then
        checker.typeerror(errors, loc,
            "cannot validate fixed nominal C array extent: %s", tostring(probe_error))
        return false
    end
    local result = probe:validate_declaration_compatibilities({ {
        left_type = target,
        right_type = types.CArray(payload, count),
    } })[1]
    if not result or result.status == "infrastructure_failure" then
        checker.typeerror(errors, loc,
            "cannot validate fixed nominal C array extent: %s",
            result and (result.message or result.summary or result.status)
                or "the C probe returned no result")
        return false
    elseif not result.accepted then
        checker.typeerror(errors, loc,
            "fixed nominal C array extent does not match '.new_array' count %d", count)
        return false
    end
    return true
end

local function plan_nominal_c_allocation(node, pseudo, demand, plan, st, errors)
    local constructor = demand and demand.nominal_constructor
    local index = demand and demand.nominal_slot_index
    local slot = constructor and constructor.slots[index]
    if not slot then return false end
    local target, payload = slot.type, pseudo.ctype
    local resolved_target = c_resolve(target)
    local fixed = types.is_c_aggregate(target)
        and not types.is_c_tvalue(target)
    local initialize_fixed = fixed and not pseudo.fam
        and not pseudo.array and types.equals(target, payload)
    local initialize_array = fixed and pseudo.array
        and resolved_target._tag == "Type.CArray"
        and types.equals(resolved_target.elem, payload)
    local tail = (constructor.kind == "union" or slot.isconst)
        and (pseudo.array or pseudo.fam)
        and checker._pointer_to_allocation_payload(target, payload)
    if not initialize_fixed and not initialize_array and not tail then return false end

    if tail then
        local bearing, offender = types.c_automatic_gc_bearing(payload)
        if bearing then
            checker.typeerror(errors, node.loc,
                "fused nominal tail of type '%s' transitively contains GC-bearing FFI storage '%s', which payload bytes do not trace",
                types.tostring(payload), types.tostring(offender))
        elseif pseudo.array then
            local err = checker._nominal_storage_error(payload, st)
            if err then checker.typeerror(errors, node.loc, "%s", err) end
        end
        plan.storage = "nominal_tail"
    else
        local err = checker._nominal_storage_error(target, st)
        if err then checker.typeerror(errors, node.loc, "%s", err) end
        if initialize_array then
            nominal_fixed_array_extent(target, payload,
                plan.array_count_literal, st, node.loc, errors)
        end
        plan.storage = "nominal_fixed"
    end
    plan.result_type = target
    plan.nominal_slot_index = index
    constructor.allocation_plans[index] = plan
    return true
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
    local count_argument = node._arg_adjustment
        and node._arg_adjustment.fixed[1] or node.args.args[1]
    plan.count_expression = count_argument
    plan.array_count_literal = pseudo.array
        and checker._allocation_integer_literal(count_argument, st) or nil
    plan.fam_count_literal = pseudo.fam
        and checker._allocation_integer_literal(count_argument, st) or nil

    if plan_nominal_c_allocation(node, pseudo, demand, plan, st, errors) then
        -- The direct nominal constructor owns these bytes. Retain the checked
        -- C allocation at its lexical argument position until nominal lowering
        -- consumes it; ordinary function parameter passing would lose this.
    elseif pseudo.array then
        local count = checker._allocation_integer_literal(count_argument, st)
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
            and checker._allocation_integer_literal(count_argument, st) or nil
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
       and not plan.storage:match("^automatic")
       and plan.storage ~= "nominal_fixed" then
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

function lua_state_pointer_type(st)
    local lua_state = st:find_foreign_type("lua_State")
        or st:find_foreign_type("struct@lua_State")
        or types.CStruct(nil, "lua_State", nil, {}, false, false)
    return types.CPointer(
        lua_state,
        {})
end

function module_udata_pointer_type(st)
    local udata = st:find_foreign_type("Udata")
        or st:find_foreign_type("struct@Udata")
        or types.CTypedef("Udata",
            types.CStruct(nil, "Udata", nil, {}, false, false))
    return types.CPointer(
        udata,
        {})
end

function nominal_module(fqtn)
    return fqtn:match("^(.*)%.[^.]+$")
end

function is_nominal_visible_from(st, fqtn)
    local nominal = types.registry[fqtn]
    local owner = nominal_module(fqtn)
    return nominal
        and (not nominal.islocal
             or owner == st.modname
             or st:source_import_visible(owner))
end

function is_nominal_member_visible_from(st, member)
    local owner = nominal_module(member.fqtn)
    return not member.islocal
        or owner == st.modname
        or st:source_import_visible(owner)
end

return core.checker
