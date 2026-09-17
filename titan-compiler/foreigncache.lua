-- One converted C graph belongs to one module-wide ffi namespace. Generated
-- header descriptors are current input authority and never serialized paths.
local cpp = require "c-parser.cpp"
local sha256 = require "titan-compiler.sha256"
local cacheadapter = require "titan-compiler.cacheadapter"
local version = require "titan-compiler.version"
local definitions = require "titan-compiler.cdefinitioncache"
local graphcodec = require "titan-compiler.graphcodec"

local foreigncache = { VERSION = 6, KIND = "ffi-conversion-v6" }
local statistics = setmetatable({}, { __mode = "k" })

local function counters(st)
    local strategy = st.probe_service and st.probe_service.io
    if not strategy then return nil end
    local stats = statistics[strategy]
    if not stats then
        stats = { lookups = 0, hits = 0, misses = 0, stores = 0 }
        statistics[strategy] = stats
    end
    return stats
end

function foreigncache.stats(strategy)
    local stats = statistics[strategy] or {}
    return {
        lookups = stats.lookups or 0, hits = stats.hits or 0,
        misses = stats.misses or 0, stores = stats.stores or 0,
    }
end

local function collect_inputs(namespace)
    local include = namespace._include
    local inputs, seen = {}, {}
    for _, name in ipairs({ "c_header_dependencies", "c_header_search_inputs" }) do
        for _, input in ipairs(include[name] or {}) do
            local key = input.kind .. "\0" .. input.path
            if not seen[key] then
                seen[key] = true
                inputs[#inputs + 1] = {
                    kind = input.kind, path = input.path, identity = input.identity,
                    observation = cpp.copy_header_observation(input.observation),
                }
            end
        end
    end
    return inputs
end

function foreigncache.key(st, namespace)
    local include = namespace._include
    if not include or not st.probe_service or not st.probe_service.profile_identity
       or not include.c_header_graph_key then return nil end
    local pieces = {}
    local function add(value)
        if type(value) ~= "string" then return false end
        pieces[#pieces + 1] = #value .. ":" .. value
        return true
    end
    add(foreigncache.KIND)
    add(st.modname)
    add(st.source_dir or "")
    add(st.probe_service.profile_identity)
    add(include.c_header_graph_key)
    for _, input in ipairs(collect_inputs(namespace)) do
        add(input.kind); add(input.path); add(input.identity)
    end
    return foreigncache.KIND .. ":sha256:" .. sha256.hex(table.concat(pieces))
end

local function references(namespace)
    local external, current = {}, {}
    local function add(value, key)
        if type(value) == "table" then external[value], current[key] = key, value end
    end
    add(namespace._include, "ffi-include")
    local visited = {}
    local function add_header(header)
        if not header or visited[header] then return end
        visited[header] = true
        add(header, "ffi-header:" .. header.logical_name)
        for _, dependency in ipairs(header.dependencies or {}) do add_header(dependency) end
    end
    add_header(namespace._include.generated_header)
    return external, current
end

function foreigncache.encode(st, namespace, key)
    local snapshot = {
        version = foreigncache.VERSION, key = key,
        abi = version.TITAN_ABI_VERSION,
        namespace_type = namespace._type,
        foreign_types = st.foreign_types,
        field_macros = st.foreign_field_macro_cache,
        file_tags = st.c_file_tags,
        profile = st.c_profile,
    }
    local external = references(namespace)
    local options = {
        external = external,
        sha256_binary = st.cache_adapter and st.cache_adapter.sha256_binary,
        yield = st.cache_adapter and st.cache_adapter.yield,
    }
    return cpp.encode_graph(definitions.foreign(snapshot, options), options)
end

local function prepare_snapshot(snapshot, key, inputs, saved_inputs)
    if type(snapshot) ~= "table" or snapshot.version ~= foreigncache.VERSION
       or snapshot.abi ~= version.TITAN_ABI_VERSION or snapshot.key ~= key then return false end
    local previous = {}
    for _, input in ipairs(saved_inputs or {}) do
        previous[input.kind .. "\0" .. input.path] = input
    end
    local observations_changed = false
    for _, input in ipairs(inputs) do
        local old = previous[input.kind .. "\0" .. input.path]
        if old and old.identity == input.identity then
            observations_changed = observations_changed or not cpp.same_header_observation(
                cpp.copy_header_observation(old.observation), input.observation)
        end
    end
    return true, observations_changed
end

function foreigncache.restore(st, namespace, key)
    local stats = counters(st)
    if stats then stats.lookups = stats.lookups + 1 end
    local payload, saved_inputs = cacheadapter.get(st.cache_adapter, foreigncache.KIND, key)
    local external, current = references(namespace)
    local decoded, snapshot = pcall(cpp.decode_graph, payload, {
        references = current,
        sha256_binary = st.cache_adapter and st.cache_adapter.sha256_binary,
        yield = st.cache_adapter and st.cache_adapter.yield,
    })
    if not decoded and type(snapshot) ~= "string" then error(snapshot, 0) end
    if not decoded then
        if stats then stats.misses = stats.misses + 1 end
        return false
    end
    local inputs = collect_inputs(namespace)
    local checked, valid, observations_changed = pcall(
        prepare_snapshot, snapshot, key, inputs, saved_inputs)
    if not checked and type(valid) ~= "string" then error(valid, 0) end
    if not checked or not valid then
        if stats then stats.misses = stats.misses + 1 end
        return false
    end
    -- One reconstruction traversal establishes the closed semantic contract.
    -- Raw CType conversion memos and prior declaration histories are not
    -- needed after the final module-wide namespace has been converted.
    local reconstructed, compact = pcall(definitions.foreign, snapshot, {
        strict = true, external = external,
        yield = st.cache_adapter and st.cache_adapter.yield,
    })
    if not reconstructed then
        if type(compact) ~= "string" then error(compact, 0) end
        if stats then stats.misses = stats.misses + 1 end
        return false
    end
    snapshot = compact
    local history = {}
    local work = graphcodec.work({ yield = st.cache_adapter and st.cache_adapter.yield })
    for name, declaration in pairs(snapshot.foreign_types) do
        work()
        history[name] = { { order = 0, decl = declaration } }
    end
    st.foreign_types = snapshot.foreign_types
    st.foreign_type_history = history
    st.foreign_field_macro_cache = snapshot.field_macros
    st.c_file_tags = snapshot.file_tags
    st.c_profile = snapshot.profile
    namespace._type = snapshot.namespace_type
    if not st:find_symbol("ffi") then st:add_symbol("ffi", namespace) end
    if observations_changed then
        local refreshed = cacheadapter.refresh_inputs(st.cache_adapter, foreigncache.KIND, key, inputs)
        if refreshed == nil and st.cache_adapter.put then
            local updated = foreigncache.encode(st, namespace, key)
            if updated then cacheadapter.put(st.cache_adapter, foreigncache.KIND, key, updated, inputs) end
        end
    end
    if stats then stats.hits = stats.hits + 1 end
    return true
end

function foreigncache.store(st, key, payload, namespace)
    if payload and cacheadapter.put(st.cache_adapter, foreigncache.KIND, key,
            payload, collect_inputs(namespace)) then
        local stats = counters(st)
        if stats then stats.stores = stats.stores + 1 end
    end
end

return foreigncache
