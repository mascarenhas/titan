local core = require "titan-compiler.checker.core"
local platform = require "titan-compiler.platform"
local _ENV = core

local function check_pass(modname, ast, subject, filename, loader, options,
                          speculation)
    ast._analysis_only = options.analysis_only == true or nil
    func_stack = {}
    checker._foreign_function_depth = 0
    catch_depth = 0
    in_finally = 0
    finally_loop_floor = 0
    loop_depth = 0
    loop_frames = {}
    local st = symtab.new(modname)
    st.binary_usage, st.binary_modules = {}, {}
    st.completion_request = options.completion
    st.cache_adapter = options.cache_adapter
    st.prepare_ffi_header = options.prepare_ffi_header
    st.filename = filename
    st.probe_speculation = speculation
    local previous_check_state = active_check_state
    active_check_state = st
    st.c_profile = nil
    st.foreign_includes = {}
    st.foreign_includes_version = 0
    st.supplemental_foreign_includes = {}
    st.target_profile_provider = options.target_profile_provider
    st.probe_service_provider = options.probe_service_provider
    if filename then
        st.source_dir = platform.parent(filename)
        if not st.source_dir or st.source_dir == "" then
            st.source_dir = "."
        end
    end
    local errors = {subject = subject, filename = filename}
    local function run_check()
        mark_toplevel_duplicates(ast, errors)
        collect_type_aliases(ast, st, errors)
        checktoplevel(ast, st, errors, loader)
        if speculation and speculation.imports then
            speculation.deferring = true
            if speculation.batch then speculation.batch.deferring = true end
        end
        checkbodies(ast, st, errors)
        -- The speculative barrier: nothing below may publish a fact derived
        -- from an assumed probe verdict.
        if speculation and speculation.imports then
            speculation.deferring = false
            local batch = speculation.batch
            if batch and not batch:flush() then
                speculation.rejected = true
                speculation.answers = batch.outcomes
                return nil, errors
            end
        end
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
                    modname, ast._type, loader, modname, {}, true, {},
                    st.source_imports)
            if not registered then
                checker.typeerror(errors,
                    (ast[1] and ast[1].loc) or { line = 1, column = 1 },
                    "public module interface is not recoverable: %s",
                    tostring(registration_error))
            end
        end
        if #errors == 0 then
            binary_collect_usage(ast, st, types.registry)
            if options.analysis_only then
                -- Semantic clients need the checked source terms, including
                -- applied call signatures and original case binders. Publish
                -- the same detached declarations without runtime erasure.
                local clone_memo
                result_type, clone_memo = generic_freeze_declared_core(ast)
                generic_freeze_declared_registry(ast, types.registry, clone_memo)
            else
                result_type, st._surface_registry =
                    generic_lower_erased_core(
                        modname, ast, st, errors)
                binary_collect_usage(ast, st, ast._erased_registry)
            end
        end
        ast._binary_usage = st.binary_usage
        ast._binary_modules = st.binary_modules
        completion_finish(st, ast, errors)
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

-- A top-level import during a speculative pass is recorded as one unit: the
-- returned module type, errors and provenance, plus the importer-side facts
-- the unit added to this checker state. The authoritative recheck replays the
-- units in order instead of calling the loader again, so nested checks,
-- driver import-cache entries, dependency frames and registry writes made by
-- the loader happen exactly once, as on the synchronous path.
-- Implementation notes: doc/implementation/checker.md#speculative-probe-barrier-and-authoritative-recheck
function checker._checkimport_for(st, modname, loader, request)
    local speculation = st.probe_speculation
    local kind = request and request.kind
    local replay = speculation and speculation.replay
    if replay then
        speculation.position = speculation.position + 1
        local unit = replay[speculation.position]
        if not unit or unit.modname ~= modname or unit.kind ~= kind then
            error("internal compiler error: the authoritative recheck of " ..
                "module '" .. st.modname .. "' diverged from its speculative " ..
                "import of '" .. modname .. "'", 0)
        end
        for name, module in pairs(unit.binary_modules) do
            st.binary_modules[name] = module
        end
        if unit.c_profile then ensure_c_profile(st) end
        return unit.module, unit.errors, unit.info
    end
    local units = speculation and speculation.imports
    if not units then return checker.checkimport(modname, loader, request) end
    local known_modules = {}
    for name, module in pairs(st.binary_modules) do known_modules[name] = module end
    local had_profile = st.c_profile ~= nil or st.c_profile_error ~= nil
    local module, errors, info = checker.checkimport(modname, loader, request)
    local added = {}
    for name, value in pairs(st.binary_modules) do
        if known_modules[name] ~= value then added[name] = value end
    end
    units[#units + 1] = {
        modname = modname, kind = kind,
        module = module, errors = errors, info = info,
        binary_modules = added,
        c_profile = not had_profile and
            (st.c_profile ~= nil or st.c_profile_error ~= nil),
    }
    return module, errors, info
end

-- Every deferral happens after the import phase, whose loader effects and
-- registry state are therefore exactly the synchronous path's. A speculative
-- pass snapshots `types.registry` here and starts its write journal; its
-- recheck asserts that it replayed every recorded unit and restores that
-- snapshot in place, discarding every registry entry of the abandoned pass.
function checker._finish_import_phase(st)
    local speculation = st.probe_speculation
    if not speculation then return end
    if speculation.replay then
        if speculation.position ~= #speculation.replay then
            error("internal compiler error: the authoritative recheck of " ..
                "module '" .. st.modname .. "' replayed " ..
                speculation.position .. " of " .. #speculation.replay ..
                " speculative imports", 0)
        end
        local snapshot = speculation.registry
        local registry = snapshot.object
        for name in pairs(registry) do
            if snapshot.entries[name] == nil then registry[name] = nil end
        end
        for name, owner in pairs(snapshot.entries) do registry[name] = owner end
        types.registry = registry
    elseif speculation.imports then
        local entries = {}
        for name, owner in pairs(types.registry) do entries[name] = owner end
        speculation.registry = { object = types.registry, entries = entries }
        speculation.journal = {}
    end
end

-- The in-place writes that a pass can make after its import phase to a type
-- object possibly owned by an imported module: an enum's compiler-selected
-- carrier (`checker._ensure_c_enum_supported`) and a C declaration's
-- fallback `_ffi_scope`. A speculative pass journals each written field's
-- value from before its first write; a rejected pass's recheck restores them
-- (`restore_journal`), so only authoritative writes survive. Implementation
-- notes: doc/implementation/checker.md#speculative-probe-barrier-and-authoritative-recheck
function checker._journal_write(st, object, field)
    local journal = st.probe_speculation and st.probe_speculation.journal
    if not journal then return end
    local fields = journal[object]
    if not fields then
        fields = {}
        journal[object] = fields
    end
    if fields[field] == nil then fields[field] = { object[field] } end
end

local function restore_journal(journal)
    for object, fields in pairs(journal or {}) do
        for field, prior in pairs(fields) do object[field] = prior[1] end
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
-- Implementation notes: doc/implementation/checker.md#entry-point-and-contract
function checker.check(modname, ast, subject, filename, loader, options)
    options = options or {}
    loader = loader or function ()
        return nil, "you must pass a loader to import modules"
    end
    -- Only a resolver-owned probe service that can batch, a driver-supplied
    -- fresh parse, and an ordinary (not analysis or completion) check may
    -- defer acceptance probes; everything else stays synchronous.
    if type(options.reparse) ~= "function"
       or options.probe_service_provider == nil
       or options.analysis_only or options.completion ~= nil then
        return check_pass(modname, ast, subject, filename, loader, options, nil)
    end
    local speculation = { imports = {} }
    local module_type, errors = check_pass(
        modname, ast, subject, filename, loader, options, speculation)
    if not speculation.rejected then return module_type, errors end

    -- A deferred probe failed: discard the speculative pass, undo its
    -- journaled writes to shared type objects, and check a fresh parse
    -- authoritatively. Refill the caller's root so its reference stays valid
    -- while every node is new.
    restore_journal(speculation.journal)
    local fresh, parse_error = options.reparse()
    if type(fresh) ~= "table" then
        error("internal compiler error: cannot reparse module '" .. modname ..
            "' for its authoritative recheck: " .. tostring(parse_error), 0)
    end
    for key in pairs(ast) do ast[key] = nil end
    for key, value in pairs(fresh) do ast[key] = value end
    return check_pass(modname, ast, subject, filename, loader, options, {
        replay = speculation.imports,
        position = 0,
        registry = speculation.registry,
        answers = speculation.answers,
    })
end

return core.checker
