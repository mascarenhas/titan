local core = require "titan-compiler.checker.core"
local _ENV = core

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
    st.cache_adapter = options.cache_adapter
    st.prepare_ffi_header = options.prepare_ffi_header
    st.filename = filename
    local previous_check_state = active_check_state
    active_check_state = st
    st.c_profile = nil
    st.foreign_includes = {}
    st.foreign_includes_version = 0
    st.supplemental_foreign_includes = {}
    st.target_profile_provider = options.target_profile_provider
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
        local header_inputs, header_error =
            collect_foreign_header_inputs(
                st.foreign_includes, st.supplemental_foreign_includes)
        if header_inputs then
            -- Language-server clients retain this small immutable closure on
            -- both project and metadata-only external source entries. It has
            -- no compiler types or AST nodes: each item is an exact physical
            -- header byte identity or an include-search candidate state.
            ast._c_header_dependencies = header_inputs
        else
            checker.typeerror(errors,
                (ast[1] and ast[1].loc) or { line = 1, column = 1 },
                "cannot establish stable C header dependencies: %s",
                tostring(header_error))
        end
        if #errors == 0 then
            select_linear_array_freezes(ast)
        end
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
                generic_lower_erased_core(
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
    if st.ffi_header_owner then
        local ok, header_closed, header_error = pcall(ffiheaders.close, st.ffi_header_owner)
        if checked and ok and not header_closed then
            table.insert(errors, "cannot clean the C header bundle: " .. tostring(header_error))
        elseif not ok and close_call_ok then
            close_call_ok, closed = false, header_closed
        end
    end
    -- Every source check returns its frozen declared interface to a resolver
    -- that may still have independent roots left to check. Keep that shared
    -- declaration registry active between checks; each erased AST carries the
    -- detached ordinary registry that its coder invocation will install.
    if st._surface_registry then
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

return core.checker
