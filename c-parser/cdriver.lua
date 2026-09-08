local _, module_loader_path = ...

local cdriver = {}

local cpp = require("c-parser.cpp")
local c99 = require("c-parser.c99")
local ctypes = require("c-parser.ctypes")
local cdefines = require("c-parser.cdefines")
local compiler_io = require("titan-compiler.io")
local sha256 = require("titan-compiler.sha256")
local cacheadapter = require("titan-compiler.cacheadapter")

cdriver.HEADER_CACHE_VERSION = 1
local HEADER_CACHE_KIND = "c-header-v1"

local SEP = package.config:sub(1, 1)
local default_io = compiler_io.new_sync()

-- Capture the compiler module's physical lookup root once, before an ordinary
-- titanc caller can change cwd. Lua's file searcher passes the selected path as
-- the chunk's second argument; prefer an absolute debug or loader path because
-- that is the normal language-server configuration and needs no cwd I/O.
--
-- A checkout-relative package.path has no recoverable load-time anchor after a
-- later chdir. In that fallback only, ask the synchronous standalone provider
-- for cwd now. Keep a failed capture as a deferred discovery error so requiring
-- cdriver still works for callers which always pass explicit include roots.
local module_source = debug.getinfo(1, "S").source
local debug_module_path = module_source:sub(1, 1) == "@"
    and module_source:sub(2) or nil
local function absolute_module_path(path)
    return type(path) == "string" and path:match("^/") ~= nil
end
local module_path
if absolute_module_path(debug_module_path) then
    module_path = debug_module_path
elseif absolute_module_path(module_loader_path) then
    module_path = module_loader_path
else
    module_path = debug_module_path or
        (type(module_loader_path) == "string" and module_loader_path or nil)
end
local module_dir_error
if module_path and not absolute_module_path(module_path) then
    local called, load_root, cwd_error = pcall(default_io.cwd, default_io)
    if called and load_root then
        module_path = load_root .. SEP .. module_path
    else
        module_dir_error =
            "failed capturing compiler module cwd while loading cdriver: " ..
            tostring(called and cwd_error or load_root)
        module_path = nil
    end
elseif not module_path then
    module_dir_error = "cdriver module loader did not provide a file path"
end
local module_dir = module_path and
    (module_path:match("^(.*)[/\\][^/\\]+$") or ".") or nil

local compiler_include_dirs = setmetatable({}, { __mode = "k" })

-- A language-server compiler instance owns one long-lived I/O strategy while
-- constructing many short-lived resolver contexts. Keep completed header
-- interpretation with that provider, not with a resolver. This cache serves a
-- developer tool whose repeated preprocessing cost matters more than a small
-- resident-memory bound, so production retention lasts for the provider's
-- lifetime. Focused tests can still install finite limits below.
local PROCESS_CACHE_LIMIT = math.maxinteger
-- Approximate the complete graphs actually cloned into retained entries,
-- including unique string bytes and the preprocessor's token-provenance side
-- tables. These constants track ordinary 64-bit Lua object and slot costs
-- closely enough to report retained size and exercise finite test limits
-- without allocator APIs.
local PROCESS_CACHE_WEIGHT_LIMIT = math.maxinteger
-- Charge the cache.entries hash slot separately from the entry graph. The
-- graph estimator uses the same ordinary 64-bit Lua hash-slot approximation.
local PROCESS_CACHE_MAP_SLOT_WEIGHT = 32
local configured_process_cache_limit = PROCESS_CACHE_LIMIT
local configured_process_cache_weight_limit = PROCESS_CACHE_WEIGHT_LIMIT
local configured_process_cache_tracks_weight = false
local process_caches = setmetatable({}, { __mode = "k" })
local process_analysis_mt = {}

-- An analysis is an explicit narrow C reuse authority. Long-lived compiler
-- clients create one for a coherent analysis with final publication-time
-- header validation; it owns completed header graphs and semantic C-probe
-- verdict tables. Ordinary cdriver callers omit it and retain clone-per-call
-- isolation.
function cdriver.new_process_analysis()
    return setmetatable({
        providers = setmetatable({}, { __mode = "k" }),
    }, process_analysis_mt)
end

local function process_analysis_provider(analysis, strategy)
    if type(analysis) ~= "table"
       or getmetatable(analysis) ~= process_analysis_mt then
        return false, "process_analysis is not a cdriver analysis"
    end
    local provider = analysis.providers[strategy]
    if not provider then
        provider = {
            process_entries = {},
            probe_results = {},
        }
        analysis.providers[strategy] = provider
    end
    return provider
end

local function process_analysis_entries(options, strategy)
    local analysis = options and options.process_analysis
    if analysis == nil then return nil end
    local provider, err = process_analysis_provider(analysis, strategy)
    if provider == false then return false, err end
    return provider.process_entries
end

-- Probe results are keyed only by source digest. An analysis shares one
-- table per I/O provider; toolchain and header state do not partition it.
function cdriver.process_analysis_probe_cache(analysis, strategy)
    local valid, validation_error = pcall(compiler_io.validate, strategy, 3)
    if not valid then
        return nil, "invalid compiler I/O strategy: " ..
            tostring(validation_error)
    end
    local provider, err = process_analysis_provider(analysis, strategy)
    if provider == false then return nil, err end
    return provider.probe_results
end

local function process_cache_for(strategy)
    local cache = process_caches[strategy]
    if not cache then
        cache = {
            entries = {},
            size = 0,
            weight = 0,
            clock = 0,
            lookups = 0,
            hits = 0,
            misses = 0,
            invalidations = 0,
            stores = 0,
            evictions = 0,
            oversized = 0,
            entry_limit = configured_process_cache_limit,
            weight_limit = configured_process_cache_weight_limit,
            tracks_weight = configured_process_cache_tracks_weight,
        }
        process_caches[strategy] = cache
    end
    return cache
end

local function touch_cache_entry(cache, entry)
    cache.clock = cache.clock + 1
    entry.last_used = cache.clock
end

local function remove_cache_entry(cache, key, invalidated, expected)
    local entry = cache.entries[key]
    if entry == nil or (expected ~= nil and entry ~= expected) then
        return false
    end
    cache.entries[key] = nil
    cache.size = cache.size - 1
    cache.weight = cache.weight - entry.weight
    if invalidated then
        cache.invalidations = cache.invalidations + 1
    end
    return true
end

local function oldest_cache_key(cache)
    local oldest_key
    local oldest_use
    for candidate_key, candidate in pairs(cache.entries) do
        if oldest_use == nil or candidate.last_used < oldest_use then
            oldest_key = candidate_key
            oldest_use = candidate.last_used
        end
    end
    return oldest_key
end

-- Production limits are practically unbounded. Finite test configurations
-- evict before cloning a miss, preserving the embedding policy mechanism and
-- exercising count, retained-weight, and oversized-entry behavior.
local function make_cache_room(cache, key, weight)
    if weight > cache.weight_limit then
        cache.oversized = cache.oversized + 1
        return false
    end
    -- I/O methods may yield into another Titan Task. If that Task completed
    -- the same miss while this caller was preprocessing, keep its entry rather
    -- than replacing a result which may have observed newer input state.
    if cache.entries[key] ~= nil then return false end
    while cache.size >= cache.entry_limit
      or cache.weight + weight > cache.weight_limit do
        local oldest_key = oldest_cache_key(cache)
        if not oldest_key then return false end
        remove_cache_entry(cache, oldest_key, false)
        cache.evictions = cache.evictions + 1
    end
    return true
end

local function store_cache_entry(cache, key, entry)
    assert(cache.entries[key] == nil)
    assert(cache.size < cache.entry_limit)
    assert(cache.weight + entry.weight <= cache.weight_limit)
    cache.size = cache.size + 1
    cache.entries[key] = entry
    cache.weight = cache.weight + entry.weight
    touch_cache_entry(cache, entry)
    cache.stores = cache.stores + 1
end

-- Test and embedding hooks. Clearing without a strategy drops every
-- provider-owned cache; statistics without one address the synchronous
-- standalone cdriver provider.
function cdriver.clear_process_cache(strategy)
    if strategy == nil then
        process_caches = setmetatable({}, { __mode = "k" })
    else
        process_caches[strategy] = nil
    end
end

-- Keep production constants immutable while allowing focused tests to drive
-- count/weight eviction and oversized-entry rejection without allocating tens
-- of MiB. Calling with no limits restores provider-lifetime production
-- retention. Each cache captures its limits at creation so accounting cannot
-- change under a live cache.
function cdriver._set_process_cache_limits_for_test(entry_limit, weight_limit)
    if entry_limit == nil and weight_limit == nil then
        configured_process_cache_limit = PROCESS_CACHE_LIMIT
        configured_process_cache_weight_limit = PROCESS_CACHE_WEIGHT_LIMIT
        configured_process_cache_tracks_weight = false
    else
        assert(type(entry_limit) == "number"
            and entry_limit > 0
            and entry_limit == math.floor(entry_limit),
            "process-cache entry limit must be a positive integer")
        assert(type(weight_limit) == "number"
            and weight_limit > 0
            and weight_limit == math.floor(weight_limit),
            "process-cache weight limit must be a positive integer")
        configured_process_cache_limit = entry_limit
        configured_process_cache_weight_limit = weight_limit
        configured_process_cache_tracks_weight = true
    end
    cdriver.clear_process_cache()
end

-- The weight field is meaningful only when tracks_weight is true. Production
-- caches deliberately return zero and leave it untracked so serving ordinary
-- compiler calls never walks a retained graph solely for observability.
function cdriver.process_cache_stats(strategy)
    strategy = strategy or default_io
    local cache = process_caches[strategy]
    if not cache then
        return {
            size = 0, lookups = 0, hits = 0, misses = 0,
            invalidations = 0, stores = 0, evictions = 0, oversized = 0,
            weight = 0, entry_limit = configured_process_cache_limit,
            weight_limit = configured_process_cache_weight_limit,
            tracks_weight = configured_process_cache_tracks_weight,
        }
    end
    return {
        size = cache.size,
        lookups = cache.lookups,
        hits = cache.hits,
        misses = cache.misses,
        invalidations = cache.invalidations,
        stores = cache.stores,
        evictions = cache.evictions,
        oversized = cache.oversized,
        weight = cache.weight,
        entry_limit = cache.entry_limit,
        weight_limit = cache.weight_limit,
        tracks_weight = cache.tracks_weight,
    }
end

local function io_for(options)
    return options and options.io or default_io
end

local function is_absolute_path(filename)
    return filename:match("^/") ~= nil
end

local function join_path(dir, filename)
    if dir:sub(-1) == SEP then
        return dir .. filename
    end
    return dir .. SEP .. filename
end

local function absolute_lookup_path(path, cwd)
    return cpp.absolute_lookup_path(path, cwd)
end

local function search_candidate_identity(path, openable, strategy)
    return cpp.header_search_identity(path, openable, strategy)
end

local function file_contents_identity(path, contents, strategy)
    return cpp.header_file_identity(contents, path, strategy)
end

-- Public, side-effect-free identity helper used by long-lived compiler
-- clients to revalidate only the exact header paths and include candidates
-- observed by cdriver. A search identity deliberately distinguishes a broken
-- symlink from a symlink whose target is now a usable regular file.
function cdriver.header_input_identity(kind, path, strategy)
    return cpp.header_input_identity(kind, path, strategy or default_io)
end

local function file_exists(filename, strategy)
    return strategy:readable(filename)
end

local function parent_dir(dir)
    local parent = dir:match("^(.*)[/\\][^/\\]+$")
    if parent == "" or parent == dir then
        return nil
    end
    return parent
end

local function find_runtime_dir(start_dir, strategy)
    local dir = start_dir
    while dir do
        local runtime = join_path(dir, "titan-runtime")
        if file_exists(join_path(runtime, "titan/ffi.h"), strategy) then
            return runtime
        end
        dir = parent_dir(dir)
    end
end

local function find_sdk_include_dir(start_dir, strategy)
    local dir = start_dir
    while dir do
        local include = join_path(dir, "include")
        if file_exists(join_path(include, "titan/ffi.h"), strategy) then
            return include
        end
        dir = parent_dir(dir)
    end
end

local function find_lua_source_dir(start_dir, strategy)
    local dir = start_dir
    while dir do
        local lua_source = join_path(join_path(dir, "lua-5.5.1"), "src")
        if file_exists(join_path(lua_source, "lua.h"), strategy) then
            return lua_source
        end
        lua_source = join_path(join_path(dir, "src"), "lua-5.5.1")
        if file_exists(join_path(lua_source, "lua.h"), strategy) then
            return lua_source
        end
        dir = parent_dir(dir)
    end
end

local function default_compiler_include_dirs(strategy)
    if compiler_include_dirs[strategy] then
        return compiler_include_dirs[strategy]
    end

    if not module_dir then return nil, module_dir_error end
    local resolved = {
        find_runtime_dir(module_dir, strategy) or
            find_sdk_include_dir(module_dir, strategy)
            or "titan-runtime",
    }
    local lua_source = find_lua_source_dir(module_dir, strategy)
    if lua_source then
        table.insert(resolved, lua_source)
    end
    compiler_include_dirs[strategy] = resolved
    return resolved
end

-- Resolve the fixed Titan/Lua SDK roots once and return an owned ordered copy.
-- Passing nil requests checkout/installed-module discovery; an explicit empty
-- array remains empty. This distinction lets direct checker embeddings share
-- the exact roots later installed in their probe service instead of
-- accidentally converting "discover" into "no fixed headers".
function cdriver.resolve_compiler_include_dirs(value, strategy)
    strategy = strategy or default_io
    if value == nil then
        local discovery_error
        value, discovery_error = default_compiler_include_dirs(strategy)
        if not value then return nil, discovery_error end
    end
    if type(value) ~= "table" then
        return nil, "compiler include dirs must be an ordered array"
    end
    local copy = {}
    for index = 1, #value do
        local directory = value[index]
        if type(directory) ~= "string" or directory == "" then
            return nil, "compiler include dir " .. index ..
                " must be a nonempty string"
        elseif directory:find("\0", 1, true) then
            return nil, "compiler include dir " .. index ..
                " contains a NUL byte"
        end
        copy[index] = directory
    end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value
        or key % 1 ~= 0 then
            return nil, "compiler include dirs must be a dense ordered array"
        end
    end
    return copy
end

local function find_header(filename, incdirs, observe, strategy)
    for _, incdir in ipairs(incdirs or {}) do
        local candidate = join_path(incdir, filename)
        local exists = file_exists(candidate, strategy)
        if observe then
            local ok, err = observe(candidate, exists)
            if not ok then return nil, err end
        end
        if exists then
            return candidate
        end
    end
end

local function normalize_options(options)
    if type(options) == "string" then
        return { source_dir = options }
    end
    if type(options) == "table" then
        return options
    end
    return {}
end

-- Internal compiler-client telemetry. The language server supplies a
-- non-yielding sink only at trace log level; ordinary compiler calls pay no
-- clock or allocation cost. Telemetry is best-effort and can never change a
-- parse result.
function cdriver.process_phase_clock(options)
    options = normalize_options(options)
    if type(options.process_trace) ~= "function" then return nil end
    return os.clock()
end

function cdriver.emit_process_phase(
        options, filename, include, phase, outcome, started)
    options = normalize_options(options)
    local sink = options.process_trace
    if type(sink) ~= "function" or started == nil then return end
    local resolved = type(include) == "table"
        and tostring(include.resolved or "") or ""
    local identity = options.process_trace_identity
    if type(identity) ~= "string" or identity == "" then
        identity = resolved ~= "" and resolved or tostring(filename)
    end
    pcall(sink, tostring(filename), resolved, tostring(phase),
        tostring(outcome or ""), (os.clock() - started) * 1000,
        identity)
end

local function resolve_include(filename, options, incdirs, observe)
    options = normalize_options(options)
    local strategy = io_for(options)

    if is_absolute_path(filename) then
        return {
            original = filename,
            resolved = filename,
            include_kind = "quote",
            include_name = filename,
        }
    end

    if options.source_dir then
        local source_relative = join_path(options.source_dir, filename)
        local exists = file_exists(source_relative, strategy)
        if observe then
            local ok, err = observe(source_relative, exists)
            if not ok then return nil, err end
        end
        if exists then
            return {
                original = filename,
                resolved = source_relative,
                include_kind = "quote",
                include_name = filename,
            }
        end
    end

    local quote_header, quote_err =
        find_header(filename, incdirs.quote, observe, strategy)
    if quote_err then return nil, quote_err end
    if quote_header then
        return {
            original = filename,
            resolved = quote_header,
            include_kind = "quote",
            include_name = filename,
        }
    end

    local system_header, system_err =
        find_header(filename, incdirs.system, observe, strategy)
    if system_err then return nil, system_err end
    return {
        original = filename,
        resolved = system_header or filename,
        include_kind = "angle",
        include_name = filename,
    }
end

local function preprocessor_options(options)
    local strategy = io_for(options)
    local own_dirs, dirs_error =
        cdriver.resolve_compiler_include_dirs(
            options.compiler_include_dirs, strategy)
    if not own_dirs then return nil, dirs_error end
    return {
        io = strategy,
        compiler = options.compiler,
        language_mode = options.language_mode,
        language_flag = options.language_flag,
        compile_flags = options.compile_flags,
        cppflags = options.cppflags,
        fixed_include_dirs = own_dirs,
    }
end

local function new_cpp_context(options)
    local config, err = preprocessor_options(options)
    if not config then return nil, err end
    return cpp.new_context(config)
end

-- Exact live compiler/preprocessor world for persistent semantic namespaces.
-- The context key includes argv, language mode, discovered include roots,
-- predefined macro tokens and the forced-header closure.
function cdriver.preprocessor_cache_identity(options)
    local context, err = new_cpp_context(normalize_options(options))
    if not context then return nil, err end
    return context.preprocessor_configuration_key
end

-- Collect forced-header dependencies even when no foreign import occurs.
-- These inputs belong to the parsed-header/analysis snapshot, not probe keys.
function cdriver.forced_header_inputs(options)
    options = normalize_options(options)
    local config, err = preprocessor_options(options)
    if not config then return nil, err end
    local inspected
    inspected, err = cpp.inspect_forced_headers(config)
    if not inspected then return nil, err end
    return {
        c_header_dependencies = inspected.dependencies,
        c_header_search_inputs = inspected.search_inputs,
        manifest = inspected.manifest,
    }
end

local function encode_sequence(values)
    local encoded = {}
    for index, value in ipairs(values) do
        value = tostring(value or "")
        encoded[index] = #value .. ":" .. value
    end
    return table.concat(encoded)
end

-- source_dir is intentionally absent. resolve_include has already observed
-- every source-relative candidate and the selected absolute header is in this
-- key. The cached parse tail contains only lookups made from that selected
-- header; a caller's own source-relative observations are reconstructed below.
local function process_cache_key(filename, include, ctx, cwd)
    local identity = encode_sequence({
        "titan-cdriver-process-v2",
        ctx.preprocessor_configuration_key,
        cwd,
        filename,
        include.original,
        include.resolved,
        include.include_kind,
        include.include_name,
    })
    -- The exact tuple above can include a complete compiler argv and forced
    -- header manifest. Retain a fixed-size collision-resistant identity rather
    -- than allowing those transient configuration strings to escape the byte
    -- bound as a cache-table key.
    return "titan-cdriver-process-v2:sha256:" .. sha256.hex(identity)
end

local function copy_input_tail(inputs, prefix_length)
    local copy = {}
    for index = prefix_length + 1, #inputs do
        local input = inputs[index]
        copy[#copy + 1] = {
            kind = input.kind,
            path = input.path,
            identity = input.identity,
        }
    end
    return copy
end

local clone_graph = cpp.clone_graph
local graph_weight = cpp.graph_weight

-- The fourth process_file result exists for target-profile acquisition. Its
-- semantic payload is the exact macro context which cdefines has already
-- attached to ffi_types. Reconstruct the I/O and observed-input conveniences
-- per caller instead of retaining flattened preprocessor output, origins,
-- include roots, current-directory stacks, or observer bookkeeping.
local function result_context(ffi_types, strategy, dependencies, search_inputs)
    return {
        defines = ffi_types.macro_definitions,
        io = strategy,
        c_header_dependencies = dependencies,
        c_header_search_inputs = search_inputs,
    }
end

local function input_tail_is_current(inputs, strategy)
    for _, input in ipairs(inputs) do
        local identity = cdriver.header_input_identity(
            input.kind, input.path, strategy)
        if identity ~= input.identity then return false end
    end
    return true
end

local function input_tail_matches_prefix(inputs, identities)
    for _, input in ipairs(inputs) do
        local present = identities[input.path]
        if present ~= nil and present ~= input.identity then return false end
    end
    return true
end

local function valid_cached_inputs(inputs, kind)
    if type(inputs) ~= "table" then return false end
    for index, input in ipairs(inputs) do
        if type(input) ~= "table" or input.kind ~= kind
           or type(input.path) ~= "string" or input.path:sub(1, 1) ~= "/"
           or type(input.identity) ~= "string" or input.identity == "" then
            return false
        end
    end
    for key in next, inputs do
        if math.type(key) ~= "integer" or key < 1 or key > #inputs then
            return false
        end
    end
    return true
end

local function decode_header_entry(payload, key, adapter)
    local entry = cpp.decode_graph(payload, { sha256_binary = adapter.sha256_binary })
    if type(entry) ~= "table" or entry.version ~= cdriver.HEADER_CACHE_VERSION
       or entry.key ~= key or type(entry.ffi_types) ~= "table"
       or type(entry.ffi_types.macro_definitions) ~= "table"
       or type(entry.ffi_types.macro_changes) ~= "table"
       or not valid_cached_inputs(entry.dependencies, "file")
       or not valid_cached_inputs(entry.search_inputs, "search") then
        return nil
    end
    for _, item in ipairs(entry.ffi_types) do
        if type(item) ~= "table" or type(item.name) ~= "string"
           or type(item.type) ~= "table" then return nil end
    end
    entry.version, entry.key = nil, nil
    entry.weight, entry.last_used = 0, 0
    return entry
end

local function encode_header_entry(entry, key, adapter)
    return cpp.encode_graph({
        version = cdriver.HEADER_CACHE_VERSION,
        key = key,
        ffi_types = entry.ffi_types,
        dependencies = entry.dependencies,
        search_inputs = entry.search_inputs,
    }, { sha256_binary = adapter.sha256_binary })
end

local function process_file_inner(filename, options)
    options = normalize_options(options)
    local cache_valid, cache_error = cacheadapter.validate(options.cache_adapter)
    if not cache_valid then return nil, cache_error end
    local strategy = io_for(options)
    local analysis_entries, analysis_error =
        process_analysis_entries(options, strategy)
    if analysis_entries == false then return nil, analysis_error end
    local ctx, err = new_cpp_context(options)
    if not ctx then
        return nil, "failed configuring C preprocessor: " .. err
    end

    local cwd, cwd_err = strategy:cwd()
    if not cwd then
        return nil, "failed determining cwd for C header identity: " ..
            tostring(cwd_err)
    end
    local dependencies = {}
    local dependency_identities = {}
    local search_inputs = {}
    local search_identities = {}
    local function record_dependency(path, identity)
        path = absolute_lookup_path(path, cwd)
        local previous = dependency_identities[path]
        if previous and previous ~= identity then
            return nil, "C header changed while it was being parsed: " .. path
        elseif not previous then
            dependency_identities[path] = identity
            dependencies[#dependencies + 1] = {
                kind = "file",
                path = path,
                identity = identity,
            }
        end
        return true
    end
    local function record_search(path, identity)
        path = absolute_lookup_path(path, cwd)
        local previous = search_identities[path]
        if previous and previous ~= identity then
            return nil, "C include candidate changed while it was searched: " ..
                path
        elseif not previous then
            search_identities[path] = identity
            search_inputs[#search_inputs + 1] = {
                kind = "search",
                path = path,
                identity = identity,
            }
        end
        return true
    end
    ctx.header_dependency_observer = function(path, contents)
        path = absolute_lookup_path(path, cwd)
        return record_dependency(
            path, file_contents_identity(path, contents, strategy))
    end
    ctx.include_search_observer = function(path, openable)
        path = absolute_lookup_path(path, cwd)
        return record_search(
            path, search_candidate_identity(path, openable, strategy))
    end

    for _, dependency in ipairs(
            ctx.forced_header_dependencies or {}) do
        local recorded, record_error = record_dependency(
            dependency.path, dependency.identity)
        if not recorded then
            return nil, "failed recording forced C header: " .. record_error
        end
    end
    for _, search in ipairs(ctx.forced_header_search_inputs or {}) do
        local recorded, record_error =
            record_search(search.path, search.identity)
        if not recorded then
            return nil, "failed recording forced C header search: " ..
                record_error
        end
    end

    local include
    include, err = resolve_include(
        filename, options, ctx.incdirs, ctx.include_search_observer)
    if not include then
        return nil, "failed resolving C header '" .. filename .. "': " .. err
    end
    if is_absolute_path(include.resolved) or
       file_exists(include.resolved, strategy) then
        include.resolved = absolute_lookup_path(include.resolved, cwd)
    end
    local parse_filename = file_exists(include.resolved, strategy)
        and include.resolved or filename

    -- Forced headers and this caller's top-level search have already been
    -- observed. A reusable entry owns only the subsequent parse tail, which
    -- makes the interpreted header independent of irrelevant source_dir
    -- misses while preserving the exact observations returned to each caller.
    local dependency_prefix_length = #dependencies
    local search_prefix_length = #search_inputs
    local cache = process_cache_for(strategy)
    local cache_key = process_cache_key(filename, include, ctx, cwd)
    include.c_header_graph_key = cache_key
    cache.lookups = cache.lookups + 1
    local restored_validated
    if not cache.entries[cache_key] and options.cache_adapter then
        local payload = cacheadapter.get(
            options.cache_adapter, HEADER_CACHE_KIND, cache_key)
        local decoded, restored = pcall(decode_header_entry,
            payload, cache_key, options.cache_adapter)
        if not decoded then
            if type(restored) ~= "string" then error(restored, 0) end
            restored = nil
        end
        -- The disk payload supplies data, never input authority. Hash/recheck
        -- the exact closure before inserting it into the live cache.
        if restored and not cache.entries[cache_key]
           and input_tail_matches_prefix(restored.dependencies, dependency_identities)
           and input_tail_matches_prefix(restored.search_inputs, search_identities)
           and input_tail_is_current(restored.dependencies, strategy)
           and input_tail_is_current(restored.search_inputs, strategy) then
            local weight = cache.tracks_weight and (graph_weight(restored)
                + graph_weight(cache_key) + PROCESS_CACHE_MAP_SLOT_WEIGHT) or 0
            if make_cache_room(cache, cache_key, weight) then
                restored.weight = weight
                store_cache_entry(cache, cache_key, restored)
                restored_validated = restored
            end
        end
    end
    while true do
        local cached = cache.entries[cache_key]
        if not cached then break end
        local analysis_entry = analysis_entries
            and analysis_entries[cache_key] or nil
        local analysis_reuse = analysis_entry ~= nil
            and analysis_entry.entry == cached
        local validation_started = cdriver.process_phase_clock(options)
        local prefix_compatible =
            input_tail_matches_prefix(
                cached.dependencies, dependency_identities)
            and input_tail_matches_prefix(
                cached.search_inputs, search_identities)
        local compatible = prefix_compatible
            and (analysis_reuse or cached == restored_validated
                or (input_tail_is_current(cached.dependencies, strategy)
                    and input_tail_is_current(
                        cached.search_inputs, strategy)))
        cdriver.emit_process_phase(options, filename, include,
            "hit_validation", compatible and
                (analysis_reuse and "analysis_reuse" or "current")
                or "changed",
            validation_started)
        -- Identity checks use the compiler I/O strategy and may yield. A
        -- concurrent Task can invalidate and replace this same key while the
        -- captured entry is being validated, so never publish or touch a
        -- detached result. Retry against the current entry instead.
        if cache.entries[cache_key] ~= cached then
            -- Retry without charging another logical lookup or miss.
        elseif compatible then
            local ffi_types
            if analysis_reuse then
                ffi_types = analysis_entry.ffi_types
                local reuse_started = cdriver.process_phase_clock(options)
                cdriver.emit_process_phase(options, filename, include,
                    "graph_clone", "analysis_reuse", reuse_started)
            else
                local clone_started = cdriver.process_phase_clock(options)
                ffi_types = clone_graph(cached.ffi_types)
                cdriver.emit_process_phase(options, filename, include,
                    "graph_clone", "hit", clone_started)
            end
            -- Identity checks may yield. The optional trace sink is required
            -- to be non-yielding, but it is arbitrary reentrant Lua and can
            -- still replace this key synchronously. Memoize or publish only
            -- while the exact validated entry object remains current.
            if cache.entries[cache_key] == cached then
                if analysis_entries and not analysis_reuse then
                    analysis_entries[cache_key] = {
                        entry = cached,
                        ffi_types = ffi_types,
                    }
                end
                for _, input in ipairs(cached.dependencies) do
                    assert(record_dependency(input.path, input.identity))
                end
                for _, input in ipairs(cached.search_inputs) do
                    assert(record_search(input.path, input.identity))
                end
                include.c_header_dependencies = dependencies
                include.c_header_search_inputs = search_inputs

                local context = result_context(
                    ffi_types, strategy, dependencies, search_inputs)
                cache.hits = cache.hits + 1
                touch_cache_entry(cache, cached)
                return ffi_types, nil, include, context
            end
        elseif remove_cache_entry(
                cache, cache_key, true, cached) then
            break
        end
    end
    cache.misses = cache.misses + 1

    local preprocessing_started = cdriver.process_phase_clock(options)
    ctx, err = cpp.parse_file(parse_filename, nil, ctx)
    cdriver.emit_process_phase(options, filename, include,
        "preprocessing", ctx and "complete" or "failed",
        preprocessing_started)
    if not ctx then
        return nil, "failed preprocessing '"..filename.."': " .. err
    end
    for _, input in ipairs(dependencies) do
        local current = assert(cdriver.header_input_identity(
            input.kind, input.path, strategy))
        if current ~= input.identity then
            return nil, "C header changed while preprocessing '" ..
                filename .. "': " .. input.path
        end
    end
    for _, input in ipairs(search_inputs) do
        local current = assert(cdriver.header_input_identity(
            input.kind, input.path, strategy))
        if current ~= input.identity then
            return nil, "C include candidate changed while preprocessing '" ..
                filename .. "': " .. input.path
        end
    end
    include.c_header_dependencies = dependencies
    include.c_header_search_inputs = search_inputs
    ctx.c_header_dependencies = dependencies
    ctx.c_header_search_inputs = search_inputs
    ctx.header_dependency_observer = nil
    ctx.include_search_observer = nil

    local srccode = table.concat(ctx.output, "\n").." $EOF$"

    local c_parse_started = cdriver.process_phase_clock(options)
    local res, err, line, col, fragment = c99.match_language_grammar(srccode)
    cdriver.emit_process_phase(options, filename, include,
        "c_parse", res and "complete" or "failed", c_parse_started)
    if not res then
        return nil, ("failed parsing: %s:%d:%d: %s\n%s"):format(filename, line, col, err, fragment)
    end

    -- Preserve source positions through the flattened preprocessor stream for
    -- declaration diagnostics and for recognizing one physical declaration
    -- repeated by independent header extraction. Source identity alone never
    -- proves that the declaration is valid in the cumulative include state;
    -- the final ordered-header compiler baseline remains authoritative.
    local line_starts = {}
    local next_start = 1
    for index, output_line in ipairs(ctx.output) do
        line_starts[index] = next_start
        next_start = next_start + #output_line + 1
    end
    local source_identities = {}
    local function source_identity(source_file)
        local cached = source_identities[source_file]
        if cached ~= nil then return cached end
        local metadata = strategy:stat(source_file)
        cached = metadata
            and metadata.device ~= nil
            and metadata.inode ~= nil
            and {
                -- The checker compares this opaque pair only for equality.
                -- Preserve physical identity across both symlink and hard-link
                -- spellings without retaining the complete strategy record.
                device = metadata.device,
                inode = metadata.inode,
            } or false
        source_identities[source_file] = cached
        return cached
    end
    local function source_origin(position)
        local low, high = 1, #line_starts
        local found = 1
        while low <= high do
            local middle = math.floor((low + high) / 2)
            if line_starts[middle] <= position then
                found = middle
                low = middle + 1
            else
                high = middle - 1
            end
        end
        local origin = ctx.output_origins
            and ctx.output_origins[found]
        if not origin then return nil end
        local identity = source_identity(origin.file)
        return {
            file = origin.file,
            line = origin.line,
            column = position - line_starts[found] + 1,
            device = identity and identity.device or nil,
            inode = identity and identity.inode or nil,
        }
    end
    for _, declaration in ipairs(res) do
        declaration._declaration_provenance =
            source_origin(declaration._source_position)
        declaration._source_position = nil
    end

    local type_conversion_started = cdriver.process_phase_clock(options)
    local ffi_types, err = ctypes.register_types(res, {
        header = filename,
        resolved_header = include.resolved,
    })
    cdriver.emit_process_phase(options, filename, include,
        "c_type_conversion", ffi_types and "complete" or "failed",
        type_conversion_started)
    if not ffi_types then
        return nil, err
    end

    local macro_conversion_started = cdriver.process_phase_clock(options)
    cdefines.register_defines(ffi_types, ctx.defines)
    ffi_types.macro_definitions = ctx.defines
    ffi_types.macro_changes = {}
    for name in pairs(ctx.macro_changes or {}) do
        ffi_types.macro_changes[name] = true
    end
    cdriver.emit_process_phase(options, filename, include,
        "macro_conversion", "complete", macro_conversion_started)

    -- The live result remains owned by this caller. Cache a separate complete
    -- graph so later checker mutation cannot leak into another resolver, then
    -- clone that private graph on every hit. Size and evict first so a large
    -- clone is never allocated alongside entries which cannot remain resident.
    local dependency_tail = copy_input_tail(
        dependencies, dependency_prefix_length)
    local search_tail = copy_input_tail(
        search_inputs, search_prefix_length)
    local entry = {
        ffi_types = ffi_types,
        dependencies = dependency_tail,
        search_inputs = search_tail,
        weight = 0,
        last_used = 0,
    }
    -- Production retention has no practical byte bound, so avoid traversing
    -- and allocating a proportional `seen` table solely to estimate weight.
    -- Finite test configurations still weigh the actual retained entry shape
    -- before cloning; the fixed-size key and cache hash slot are separate
    -- retained allocations which must also fit under their configured bound.
    local cache_weight = 0
    if cache.tracks_weight then
        cache_weight = graph_weight(entry)
            + graph_weight(cache_key)
            + PROCESS_CACHE_MAP_SLOT_WEIGHT
    end
    entry.weight = cache_weight
    if make_cache_room(cache, cache_key, cache_weight) then
        local retained_clone_started = cdriver.process_phase_clock(options)
        entry.ffi_types = clone_graph(ffi_types)
        store_cache_entry(cache, cache_key, entry)
        if analysis_entries then
            analysis_entries[cache_key] = {
                entry = entry,
                ffi_types = ffi_types,
            }
        end
        cdriver.emit_process_phase(options, filename, include,
            "graph_clone", "retained_store", retained_clone_started)
        if options.cache_adapter and options.cache_adapter.put then
            local payload = encode_header_entry(entry, cache_key, options.cache_adapter)
            if payload and cache.entries[cache_key] == entry then
                local inputs = {}
                for _, group in ipairs({ entry.dependencies, entry.search_inputs }) do
                    for _, input in ipairs(group) do
                        inputs[#inputs + 1] = {
                            kind = input.kind, path = input.path, identity = input.identity,
                        }
                    end
                end
                cacheadapter.put(options.cache_adapter,
                    HEADER_CACHE_KIND, cache_key, payload, inputs)
            end
        end
    end

    -- The fourth result is deliberately contextual rather than process-global:
    -- target-profile acquisition needs the exact macro context that parsed the
    -- configured Lua headers, while ordinary callers retain the historical
    -- first three results.
    return ffi_types, nil, include,
        result_context(ffi_types, strategy, dependencies, search_inputs)
end

-- Trace the complete top-level header request in addition to its component
-- phases. Language-server profiling uses this terminal duration to separate
-- header work from the source module which requested it; recursive C includes
-- remain part of the selected header's own preprocessing request. Ordinary
-- parse failures return through this wrapper. A thrown invariant/cancellation
-- aborts its analysis and may omit terminal best-effort telemetry.
function cdriver.process_file(filename, options)
    options = normalize_options(options)
    if type(options.process_trace) ~= "function" then
        return process_file_inner(filename, options)
    end

    local started = os.clock()
    local processed, process_error, include, context =
        process_file_inner(filename, options)
    cdriver.emit_process_phase(
        options, filename, include, "process_total",
        processed and "complete" or "failed", started)
    return processed, process_error, include, context
end

local function primitive_typedef_spelling(ffi_types, name)
    local item = ffi_types[name]
    local declaration = item and item.type == "typedef" and item
        or item and item.type
    local definition = declaration and declaration.def
    if type(definition) ~= "table" or definition.type ~= nil then
        return nil, "configured '" .. name ..
            "' is not a primitive C typedef"
    end

    local tokens = {}
    for index = 1, #definition do
        if type(definition[index]) ~= "string" then
            return nil, "configured '" .. name ..
                "' has a non-primitive C spelling"
        end
        tokens[#tokens + 1] = definition[index]
    end
    if #tokens == 0 then
        return nil, "configured '" .. name .. "' has an empty C spelling"
    end
    return table.concat(tokens, " ")
end

local signed_minimum_macros = {
    ["signed char"] = "SCHAR_MIN",
    ["short"] = "SHRT_MIN",
    ["int"] = "INT_MIN",
    ["long"] = "LONG_MIN",
    ["long long"] = "LLONG_MIN",
}

local function collect_signed_minima(ffi_types)
    local minima = {}
    for spelling, name in pairs(signed_minimum_macros) do
        local item = ffi_types[name]
        if not item or not item.macro_expression then
            return nil
        end
        minima[spelling] = item.macro_expression
    end
    return minima
end

-- Acquire the pure target-profile inputs under the same compiler argv,
-- target-selecting flags, and installed luaconf.h used for generated code.
-- csemantics owns interpretation; this layer only exposes parser facts.
function cdriver.target_profile_inputs(options)
    options = normalize_options(options)
    local strategy = io_for(options)
    local fixed_include_dirs, dirs_error =
        cdriver.resolve_compiler_include_dirs(
            options.compiler_include_dirs, strategy)
    if not fixed_include_dirs then return nil, dirs_error end
    local ffi_types, err, include, ctx =
        cdriver.process_file("lua.h", options)
    if not ffi_types then
        return nil, "failed acquiring configured Lua numeric types: " .. err
    end

    local lua_integer
    lua_integer, err = primitive_typedef_spelling(ffi_types, "lua_Integer")
    if not lua_integer then return nil, err end
    local lua_number
    lua_number, err = primitive_typedef_spelling(ffi_types, "lua_Number")
    if not lua_number then return nil, err end

    -- `sizeof`/`_Alignof` and pointer subtraction enter Titan through size_t
    -- and ptrdiff_t respectively. Resolve their actual typedef spellings from
    -- the configured target headers rather than assuming the compiler host's
    -- data model. lua.h normally includes <stddef.h>; retain an explicit
    -- fallback for deliberately minimal alternate Lua-header fixtures.
    local standard_types = ffi_types
    local size_t = primitive_typedef_spelling(standard_types, "size_t")
    local ptrdiff_t = primitive_typedef_spelling(standard_types, "ptrdiff_t")
    if not size_t or not ptrdiff_t then
        standard_types, err = cdriver.process_file("stddef.h", options)
        if not standard_types then
            return nil, "failed acquiring configured C carrier types: " .. err
        end
        size_t, err = primitive_typedef_spelling(standard_types, "size_t")
        if not size_t then return nil, err end
        ptrdiff_t, err =
            primitive_typedef_spelling(standard_types, "ptrdiff_t")
        if not ptrdiff_t then return nil, err end
    end

    -- Exact signed minima are needed to prove the supported two's-complement
    -- target invariant. The Lua headers normally expose <limits.h>; as above,
    -- parse the standard header explicitly when an alternate lua.h does not.
    local signed_minima = collect_signed_minima(ffi_types)
    if not signed_minima then
        local limits_types
        limits_types, err = cdriver.process_file("limits.h", options)
        if not limits_types then
            return nil, "failed acquiring configured C signed minima: " .. err
        end
        signed_minima = collect_signed_minima(limits_types)
        if not signed_minima then
            return nil, "configured <limits.h> does not expose the signed "
                .. "integer minima required by Titan"
        end
    end

    return {
        macros = ctx.defines,
        lua_integer = lua_integer,
        lua_number = lua_number,
        size_t = size_t,
        ptrdiff_t = ptrdiff_t,
        signed_minima = signed_minima,
        lua_header = include,
        fixed_include_dirs = fixed_include_dirs,
    }
end

-- Shared argument handling for driver/checker integration. CPPFLAGS must be
-- split once and passed to process_file as an array; never reconstruct words
-- by splitting on whitespace at the call site.
cdriver.split_shell_words = cpp.split_shell_words
cdriver.shell_quote = cpp.shell_quote
cdriver.capture_command = cpp.capture_command

return cdriver
