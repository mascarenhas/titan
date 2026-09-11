local cdriver = {}

local cpp = require("c-parser.cpp")
local c99 = require("c-parser.c99")
local ctypes = require("c-parser.ctypes")
local cdefines = require("c-parser.cdefines")
local compiler_io = require("titan-compiler.io")
local sha256 = require("titan-compiler.sha256")
local cacheadapter = require("titan-compiler.cacheadapter")
local version = require "titan-compiler.version"
local definitions = require "titan-compiler.cdefinitioncache"
local csemantics = require "titan-compiler.csemantics"

cdriver.HEADER_CACHE_VERSION = 3
local HEADER_CACHE_KIND = "c-header-v3"

local SEP = package.config:sub(1, 1)
local default_io = compiler_io.new_sync()

-- A language-server compiler instance owns one long-lived I/O strategy while
-- constructing many short-lived resolver contexts. Keep completed header
-- interpretation with that provider, not with a resolver. This cache serves a
-- developer tool whose repeated preprocessing cost matters more than a small
-- resident-memory bound, so production retention lasts for the provider's
-- lifetime. Focused tests can still install finite limits below.
local PROCESS_CACHE_LIMIT = math.maxinteger
-- Approximate the complete graphs retained in entries,
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
-- header validation; it records validated header entries and semantic C-probe
-- verdict tables. Parsed C graphs are read-only and shared by all callers.
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
-- evict before retaining a miss, preserving the embedding policy mechanism and
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
    cpp.clear_header_input_stats(strategy)
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
    local function with_inputs(result)
        for name, value in pairs(cpp.header_input_stats(strategy)) do result[name] = value end
        return result
    end
    if not cache then
        return with_inputs({
            size = 0, lookups = 0, hits = 0, misses = 0,
            invalidations = 0, stores = 0, evictions = 0, oversized = 0,
            weight = 0, entry_limit = configured_process_cache_limit,
            weight_limit = configured_process_cache_weight_limit,
            tracks_weight = configured_process_cache_tracks_weight,
        })
    end
    return with_inputs({
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
    })
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

local function file_contents_identity(path, contents, strategy, read_state)
    return cpp.header_file_identity(contents, path, strategy, read_state)
end

-- Public, side-effect-free identity helper used by long-lived compiler
-- clients to revalidate only the exact header paths and include candidates
-- observed by cdriver. A search identity deliberately distinguishes a broken
-- symlink from a symlink whose target is now a usable regular file.
function cdriver.header_input_identity(kind, path, strategy)
    return cpp.header_input_identity(kind, path, strategy or default_io)
end

cdriver.revalidate_header_input = cpp.revalidate_header_input
cdriver.copy_header_observation = cpp.copy_header_observation
cdriver.same_header_observation = cpp.same_header_observation
cdriver.header_observation_index = cpp.header_observation_index

local function file_exists(filename, strategy)
    return strategy:readable(filename)
end

-- Resolve the fixed Titan/Lua SDK roots once and return an owned ordered copy.
-- Passing nil requests checkout/installed-module discovery; an explicit empty
-- array remains empty. This distinction lets direct checker embeddings share
-- the exact roots later installed in their probe service instead of
-- accidentally converting "discover" into "no fixed headers".
function cdriver.resolve_compiler_include_dirs(value, strategy)
    strategy = strategy or default_io
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
        return { source_dir = options, compiler_include_dirs = {} }
    end
    if type(options) == "table" then
        if options.compiler_include_dirs == nil then
            options.compiler_include_dirs = {}
        end
        return options
    end
    return { compiler_include_dirs = {} }
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
        cache_adapter = options.cache_adapter,
        header_observations = options.header_observations or cpp.header_observation_index(options.header_inputs),
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
            observation = cpp.copy_header_observation(input.observation),
        }
    end
    return copy
end

local graph_weight = cpp.graph_weight

-- The fourth process_file result exists for target-profile acquisition. It
-- exposes only predefined macro facts consumed by csemantics. Reconstruct the
-- I/O and input conveniences per caller; no CPP context survives extraction.
local function result_context(ffi_types, strategy, dependencies, search_inputs)
    return {
        defines = ffi_types.profile_macros,
        io = strategy,
        c_header_dependencies = dependencies,
        c_header_search_inputs = search_inputs,
    }
end

local function input_tail_is_current(inputs, options)
    local observations_changed = false
    local refreshed = {}
    for index, input in ipairs(inputs) do
        local current, _, changed = cdriver.revalidate_header_input(input, options)
        if not current or changed then return false end
        observations_changed = observations_changed or
            not cpp.same_header_observation(input.observation, current.observation)
        refreshed[index] = current
    end
    -- Publish only a completely validated tail, never a partially updated one.
    for index, current in ipairs(refreshed) do inputs[index] = current end
    return true, observations_changed
end

local function input_tail_matches_prefix(inputs, identities)
    for _, input in ipairs(inputs) do
        local present = identities[input.path]
        if present ~= nil and present ~= input.identity then return false end
    end
    return true
end

local function decode_header_entry(payload, key, adapter)
    local entry = cpp.decode_graph(payload, { sha256_binary = adapter.sha256_binary, yield = adapter.yield })
    if type(entry) ~= "table" or entry.version ~= cdriver.HEADER_CACHE_VERSION
       or entry.abi ~= version.TITAN_ABI_VERSION or entry.key ~= key then
        return nil
    end
    return {
        ffi_types = definitions.header(entry.ffi_types, { strict = true, yield = adapter.yield }),
        dependencies = copy_input_tail(entry.dependencies, 0),
        search_inputs = copy_input_tail(entry.search_inputs, 0),
        weight = 0, last_used = 0,
    }
end

local function encode_header_entry(entry, key, adapter)
    return cpp.encode_graph({
        version = cdriver.HEADER_CACHE_VERSION,
        abi = version.TITAN_ABI_VERSION,
        key = key,
        ffi_types = entry.ffi_types,
        dependencies = entry.dependencies,
        search_inputs = entry.search_inputs,
    }, { sha256_binary = adapter.sha256_binary, yield = adapter.yield })
end

local function header_entry_inputs(entry)
    local inputs = copy_input_tail(entry.dependencies, 0)
    for _, input in ipairs(copy_input_tail(entry.search_inputs, 0)) do
        inputs[#inputs + 1] = input
    end
    return inputs
end

local function overlay_header_inputs(entry, saved)
    if type(saved) ~= "table" then return end
    local inputs = header_entry_inputs(entry)
    if #saved ~= #inputs then return end
    for index, input in ipairs(inputs) do
        local observed = saved[index]
        if type(observed) ~= "table" or observed.kind ~= input.kind
           or observed.path ~= input.path or observed.identity ~= input.identity then return end
    end
    for index, input in ipairs(inputs) do
        local target = index <= #entry.dependencies and entry.dependencies[index]
            or entry.search_inputs[index - #entry.dependencies]
        target.observation = cpp.copy_header_observation(saved[index].observation) or target.observation
    end
end

local function header_entry_is_current(entry, options)
    local dependencies, dependency_touch = input_tail_is_current(entry.dependencies, options)
    if not dependencies then return false end
    local searches, search_touch = input_tail_is_current(entry.search_inputs, options)
    if not searches then return false end
    entry.observations_changed = entry.observations_changed or dependency_touch or search_touch
    return true
end

local function refresh_header_observations(entry, key, adapter)
    if not entry.observations_changed or not adapter then return end
    local inputs = header_entry_inputs(entry)
    local refreshed = cacheadapter.refresh_inputs(adapter, HEADER_CACHE_KIND, key, inputs)
    if refreshed == nil and adapter.put then
        local payload = encode_header_entry(entry, key, adapter)
        refreshed = payload and cacheadapter.put(adapter, HEADER_CACHE_KIND, key, payload, inputs)
    end
    if refreshed then entry.observations_changed = nil end
end

-- Resolve authored directives in one configured include-search context, without
-- preprocessing each header into an independent declaration graph. Keep the
-- original search candidates: the generated header uses absolute quoted paths.
function cdriver.resolve_includes(filenames, options)
    options = normalize_options(options)
    local strategy = io_for(options)
    local ctx, err = new_cpp_context(options)
    if not ctx then return nil, err end
    local cwd, cwd_err = strategy:cwd()
    if not cwd then return nil, cwd_err end
    local includes = {}
    for index, filename in ipairs(filenames) do
        local searches = {}
        local function observe(path, openable)
            path = absolute_lookup_path(path, cwd)
            searches[#searches + 1] = {
                kind = "search", path = path,
                identity = search_candidate_identity(path, openable, strategy),
            }
            return true
        end
        local include, include_err = resolve_include(filename, options, ctx.incdirs, observe)
        if not include then return nil, include_err end
        if is_absolute_path(include.resolved) or file_exists(include.resolved, strategy) then
            include.resolved = absolute_lookup_path(include.resolved, cwd)
        end
        include.c_header_search_inputs = searches
        includes[index] = include
    end
    return includes
end

local generated_header_cache = setmetatable({}, { __mode = "k" })

local function generated_lookup_path(header, path)
    local prefix = header.bundle_root .. "/"
    if path:sub(1, #prefix) ~= prefix then return nil end
    -- Only this owned directory tree is known to have no symbolic links.
    -- Preserve '..' in authored header observations, but resolve it here so
    -- nested generated includes cannot escape as persistent file inputs.
    local components = {}
    for component in path:sub(#prefix + 1):gmatch("[^/]+") do
        if component == ".." then
            if #components == 0 then return nil end
            components[#components] = nil
        elseif component ~= "." then
            components[#components + 1] = component
        end
    end
    return prefix .. table.concat(components, "/")
end

local function generated_header_inputs(header)
    local cached = generated_header_cache[header]
    if cached then return cached.files, cached.searches end
    -- The resolver owns these immutable plans and files until it closes.
    -- Authored headers and their lookup candidates are still revalidated by
    -- process_file; generated bytes are checked when the preprocessor reads
    -- them, without reopening the entire owned tree before every cache hit.
    local files, searches, visited = {}, {}, {}
    local function visit(item)
        if visited[item] then return end
        visited[item] = true
        files[item.filename] = item
        for _, input in ipairs(item.search_inputs or {}) do
            searches[#searches + 1] = input
        end
        for _, dependency in ipairs(item.dependencies) do
            visit(dependency)
        end
    end
    visit(header)
    generated_header_cache[header] = { files = files, searches = searches }
    return files, searches
end

local function process_file_inner(filename, options)
    options = normalize_options(options)
    local cache_valid, cache_error = cacheadapter.validate(options.cache_adapter)
    if not cache_valid then return nil, cache_error end
    local strategy = io_for(options)
    local generated = options.generated_header
    local generated_files, generated_searches
    if generated then
        generated_files, generated_searches = generated_header_inputs(generated)
    end
    local analysis_entries, analysis_error =
        process_analysis_entries(options, strategy)
    if analysis_entries == false then return nil, analysis_error end
    local validation_options = {
        io = strategy, header_validation = options.header_validation or {},
        cache_adapter = options.cache_adapter,
        header_observations = options.header_observations or cpp.header_observation_index(options.header_inputs),
    }
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
    local function record_dependency(path, identity, observation)
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
                observation = cpp.copy_header_observation(observation),
            }
        end
        return true
    end
    local function record_search(path, identity)
        path = absolute_lookup_path(path, cwd)
        -- Generated files are immutable inputs bound by the bundle digest.
        -- Their temporary location is neither a real-header dependency nor
        -- a persistent include-search observation.
        if generated and generated_lookup_path(generated, path) then return true end
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
    ctx.header_dependency_observer = function(path, contents, read_state)
        path = absolute_lookup_path(path, cwd)
        local input = generated_files and (generated_files[path]
            or generated_files[generated_lookup_path(generated, path)])
        if input then
            if input.contents ~= contents then
                return nil, "generated C environment changed during analysis: " .. input.identity
            end
            return true
        end
        return record_dependency(
            path, file_contents_identity(path, contents, strategy, read_state))
    end
    ctx.include_search_observer = function(path, openable)
        path = absolute_lookup_path(path, cwd)
        if generated and generated_lookup_path(generated, path) then return true end
        return record_search(
            path, search_candidate_identity(path, openable, strategy))
    end

    for _, dependency in ipairs(
            ctx.forced_header_dependencies or {}) do
        local recorded, record_error = record_dependency(
            dependency.path, dependency.identity, dependency.observation)
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

    for _, search in ipairs(generated_searches or {}) do
        local current, _, changed = cdriver.revalidate_header_input(search, validation_options)
        if not current or changed then
            return nil, "C include candidate changed after module header resolution: " .. search.path
        end
        local recorded, record_error = record_search(search.path, search.identity)
        if not recorded then return nil, record_error end
    end

    local include, parse_filename
    if generated then
        include = {
            original = generated.logical_name,
            resolved = generated.identity,
            include_kind = "quote",
            include_name = generated.logical_name,
            generated_header = generated,
        }
        parse_filename = generated.filename
    else
        include, err = resolve_include(
            filename, options, ctx.incdirs, ctx.include_search_observer)
        if not include then
            return nil, "failed resolving C header '" .. filename .. "': " .. err
        end
        if is_absolute_path(include.resolved) or file_exists(include.resolved, strategy) then
            include.resolved = absolute_lookup_path(include.resolved, cwd)
        end
        parse_filename = file_exists(include.resolved, strategy)
            and include.resolved or filename
    end

    -- Forced headers and this caller's top-level search have already been
    -- observed. A reusable entry owns only the subsequent parse tail, which
    -- makes the interpreted header independent of irrelevant source_dir
    -- misses while preserving the exact observations returned to each caller.
    local dependency_prefix_length = #dependencies
    local search_prefix_length = #search_inputs
    local cache = process_cache_for(strategy)
    local cache_key = process_cache_key(
        generated and generated.digest or filename, include, ctx, cwd)
    include.c_header_graph_key = cache_key
    cache.lookups = cache.lookups + 1
    local restored_validated
    if not cache.entries[cache_key] and options.cache_adapter then
        local payload, saved_inputs = cacheadapter.get(
            options.cache_adapter, HEADER_CACHE_KIND, cache_key)
        local decoded, restored = pcall(decode_header_entry,
            payload, cache_key, options.cache_adapter)
        if not decoded then
            if type(restored) ~= "string" then error(restored, 0) end
            restored = nil
        end
        if restored then overlay_header_inputs(restored, saved_inputs) end
        -- The disk payload supplies data, never input authority. Stat/recheck
        -- the exact closure before inserting it into the live cache.
        if restored and not cache.entries[cache_key]
           and input_tail_matches_prefix(restored.dependencies, dependency_identities)
           and input_tail_matches_prefix(restored.search_inputs, search_identities)
           and header_entry_is_current(restored, validation_options) then
            local weight = cache.tracks_weight and (graph_weight(restored)
                + graph_weight(cache_key) + PROCESS_CACHE_MAP_SLOT_WEIGHT) or 0
            if make_cache_room(cache, cache_key, weight) then
                restored.weight = weight
                store_cache_entry(cache, cache_key, restored)
                restored_validated = restored
            end
        end
    end
    local previous_cached
    while true do
        local cached = cache.entries[cache_key]
        if not cached then break end
        if previous_cached and cached ~= previous_cached then
            -- A completed replacement published while validation yielded.
            -- Restart observations as well as validation of the new graph.
            validation_options.header_validation = {}
        end
        previous_cached = cached
        local analysis_entry = analysis_entries
            and analysis_entries[cache_key] or nil
        local analysis_reuse = analysis_entry == cached
        local validation_started = cdriver.process_phase_clock(options)
        local prefix_compatible =
            input_tail_matches_prefix(
                cached.dependencies, dependency_identities)
            and input_tail_matches_prefix(
                cached.search_inputs, search_identities)
        local compatible = prefix_compatible
            and (analysis_reuse or cached == restored_validated
                or header_entry_is_current(cached, validation_options))
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
            refresh_header_observations(cached, cache_key, options.cache_adapter)
            local ffi_types = cached.ffi_types
            -- Identity checks may yield. The optional trace sink is required
            -- to be non-yielding, but it is arbitrary reentrant Lua and can
            -- still replace this key synchronously. Memoize or publish only
            -- while the exact validated entry object remains current.
            if cache.entries[cache_key] == cached then
                if analysis_entries and not analysis_reuse then
                    analysis_entries[cache_key] = cached
                end
                for _, input in ipairs(cached.dependencies) do
                    assert(record_dependency(input.path, input.identity, input.observation))
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
    -- Parsing is a fresh publication boundary, separate from any attempted
    -- reuse pass above. Matching observed mtime needs no second content read.
    local final_validation = { io = strategy, header_validation = {}, cache_adapter = options.cache_adapter,
        header_observations = validation_options.header_observations }
    for _, input in ipairs(dependencies) do
        local current, _, changed = cdriver.revalidate_header_input(input, final_validation)
        if not current or changed then
            return nil, "C header changed while preprocessing '" ..
                filename .. "': " .. input.path
        end
        input.observation = current.observation
    end
    for _, input in ipairs(search_inputs) do
        local current, _, changed = cdriver.revalidate_header_input(input, final_validation)
        if not current or changed then
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

    -- The real module-wide header already resolves declaration order and
    -- tag scope. Per-declaration physical-file identities were used only by
    -- the retired independent-header compatibility path; keep no such source
    -- map in the extracted declaration graph.

    local type_conversion_started = cdriver.process_phase_clock(options)
    local ffi_types, err = ctypes.register_types(res, {
        header = generated and generated.identity or filename,
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
    ffi_types.profile_macros = csemantics.profile_macro_facts(ctx.defines)
    ffi_types = definitions.header(ffi_types, { yield = options.cache_adapter and options.cache_adapter.yield })
    cdriver.emit_process_phase(options, filename, include,
        "macro_conversion", "complete", macro_conversion_started)

    -- Parsing publishes an immutable C graph. Checker conversion creates its
    -- own Titan types and keeps conversion memos in its symbol table, so every
    -- caller can share this parsed graph without a retention or hit copy.
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
    -- before retaining; the fixed-size key and cache hash slot are separate
    -- retained allocations which must also fit under their configured bound.
    local cache_weight = 0
    if cache.tracks_weight then
        cache_weight = graph_weight(entry)
            + graph_weight(cache_key)
            + PROCESS_CACHE_MAP_SLOT_WEIGHT
    end
    entry.weight = cache_weight
    if make_cache_room(cache, cache_key, cache_weight) then
        store_cache_entry(cache, cache_key, entry)
        if analysis_entries then
            analysis_entries[cache_key] = entry
        end
        if options.cache_adapter and options.cache_adapter.put then
            local payload = encode_header_entry(entry, cache_key, options.cache_adapter)
            if payload and cache.entries[cache_key] == entry then
                local inputs = header_entry_inputs(entry)
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

-- A module's generated header is one ordered preprocessor/parser input. The
-- actual files preserve C include semantics; only their stable generated
-- contents and origins, rather than their temporary paths, identify this graph.
function cdriver.process_module(header, options)
    local configured = {}
    for key, value in pairs(normalize_options(options)) do configured[key] = value end
    configured.generated_header = header
    local processed, process_error, include, context =
        cdriver.process_file(header.filename, configured)
    if not processed and type(process_error) == "string" then
        local pending, seen = { header }, {}
        while #pending > 0 do
            local current = table.remove(pending)
            if not seen[current] then
                seen[current] = true
                if type(current.filename) == "string" then
                    process_error = process_error:gsub(current.filename:gsub("(%W)", "%%%1"),
                        function() return current.identity end)
                end
                for _, dependency in ipairs(current.dependencies) do
                    pending[#pending + 1] = dependency
                end
            end
        end
    end
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
