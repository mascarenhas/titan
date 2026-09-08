-- Converted foreign declarations form one ordered compilation-unit graph.
-- Later headers may complete owners reached from earlier imports, so replay
-- all C symbol/tag/history roots together, never unrelated per-header blobs.
local cpp = require "c-parser.cpp"
local sha256 = require "titan-compiler.sha256"
local cacheadapter = require "titan-compiler.cacheadapter"

local foreigncache = { VERSION = 1, KIND = "ffi-conversion-v1" }
local roots = {
    "foreign_types", "foreign_type_history", "foreign_names",
    "foreign_name_history", "foreign_macro_definitions", "foreign_macro_changes",
    "foreign_field_macro_cache", "c_file_tags", "c_prototype_tags",
    "pending_foreign_redeclarations", "foreign_includes", "c_profile",
}
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

function foreigncache.key(st, imports, prepared)
    if #imports == 0 or not st.probe_service then return nil end
    local pieces = {}
    local function add(value)
        if type(value) ~= "string" then return false end
        pieces[#pieces + 1] = #value .. ":" .. value
        return true
    end
    add("titan-ffi-conversion-v1")
    add(st.modname)
    add(st.source_dir or "")
    -- Each parsed include's graph key below already binds the exact compiler
    -- argv, effective flags, language mode, include roots and forced headers.
    -- Converted types additionally depend on the target profile; compiled
    -- probe-cache metadata is neither an owner nor an input of this graph.
    if not add(st.probe_service.profile_identity) then return nil end
    for _, node in ipairs(imports) do
        local item = prepared[node]
        local include = item and item.ftypes and item.include
        if not include or not add(include.c_header_graph_key) then return nil end
        add(tostring(node._toplevel_order))
        add(node.headername)
        add(include.rendered)
        for _, name in ipairs({ "c_header_dependencies", "c_header_search_inputs" }) do
            local inputs = include[name]
            if type(inputs) ~= "table" then return nil end
            add(tostring(#inputs))
            for _, input in ipairs(inputs) do
                if not add(input.kind) or not add(input.path)
                   or not add(input.identity) then return nil end
            end
        end
    end
    return "titan-ffi-conversion-v1:sha256:" .. sha256.hex(table.concat(pieces))
end

local function references(imports)
    local external, restored = {}, {}
    for index, node in ipairs(imports) do
        local key = "foreign-import:" .. index
        external[node], restored[key] = key, node
    end
    return external, restored
end

function foreigncache.encode(st, imports, key)
    local snapshot = {
        version = foreigncache.VERSION, key = key, roots = {},
        node_types = {}, node_includes = {},
        foreign_includes_version = st.foreign_includes_version,
        last_foreign_import_node = st.last_foreign_import_node,
        converted_enums = st._converted_c_enums,
    }
    for _, name in ipairs(roots) do snapshot.roots[name] = st[name] end
    for index, node in ipairs(imports) do
        snapshot.node_types[index], snapshot.node_includes[index] =
            node._type, node._include
    end
    local external = references(imports)
    return cpp.encode_graph(snapshot, {
        external = external,
        sha256_binary = st.cache_adapter and st.cache_adapter.sha256_binary,
        yield = st.cache_adapter and st.cache_adapter.yield,
    })
end

local function valid_snapshot(snapshot, imports, key)
    local valid = type(snapshot) == "table" and snapshot.key == key
        and snapshot.version == foreigncache.VERSION
        and type(snapshot.roots) == "table"
        and type(snapshot.node_types) == "table"
        and type(snapshot.node_includes) == "table"
        and #snapshot.node_types == #imports
        and #snapshot.node_includes == #imports
        and snapshot.foreign_includes_version == #imports
        and snapshot.last_foreign_import_node == imports[#imports]
        and (snapshot.converted_enums == nil or type(snapshot.converted_enums) == "table")
    if valid then
        for _, name in ipairs(roots) do
            if type(snapshot.roots[name]) ~= "table" then valid = false; break end
        end
    end
    if valid then
        for index, node in ipairs(imports) do
            local typ = snapshot.node_types[index]
            local include = snapshot.node_includes[index]
            if type(typ) ~= "table" or typ._tag ~= "Type.CModule"
               or typ.name ~= node.headername
               or type(typ.members) ~= "table" or type(typ.type_members) ~= "table"
               or type(include) ~= "table" or type(include.rendered) ~= "string" then
                valid = false
                break
            end
        end
    end
    return valid
end

local function collect_inputs(imports)
    local inputs, seen = {}, {}
    for _, node in ipairs(imports) do
        for _, name in ipairs({ "c_header_dependencies", "c_header_search_inputs" }) do
            for _, input in ipairs(node._include[name]) do
                local identity = input.kind .. "\0" .. input.path
                if not seen[identity] then
                    seen[identity] = true
                    inputs[#inputs + 1] = {
                        kind = input.kind, path = input.path, identity = input.identity,
                        observation = cpp.copy_header_observation(input.observation),
                    }
                end
            end
        end
    end
    return inputs
end


local function prepare_snapshot(snapshot, imports, key, st, saved_inputs)
    if not valid_snapshot(snapshot, imports, key) then return false end
    -- Current prepared headers have already passed the shared file validator.
    -- A reused converted graph keeps that fresh observation metadata, never
    -- the older timestamps embedded in its otherwise unchanged semantic blob.
    local saved = {}
    if type(saved_inputs) == "table" then
        for _, input in ipairs(saved_inputs) do
            if type(input) == "table" and type(input.kind) == "string"
               and type(input.path) == "string" then
                saved[input.kind .. "\0" .. input.path] = input
            end
        end
    end
    local observations_changed = false
    for index, node in ipairs(imports) do
        local prepared = st.prepared_foreign_imports and st.prepared_foreign_imports[node]
        local current_include = prepared and prepared.include
        if not current_include then return false end
        for _, name in ipairs({ "c_header_dependencies", "c_header_search_inputs" }) do
            local inputs, current_inputs = snapshot.node_includes[index][name], current_include[name]
            if type(inputs) ~= "table" or type(current_inputs) ~= "table"
               or #inputs ~= #current_inputs then return false end
            for ordinal, input in ipairs(inputs) do
                local current_input = current_inputs[ordinal]
                if type(input) ~= "table" or input.kind ~= current_input.kind
                   or input.path ~= current_input.path or input.identity ~= current_input.identity then return false end
                local metadata = saved[input.kind .. "\0" .. input.path]
                local previous = metadata and metadata.identity == input.identity
                    and metadata.observation or input.observation
                observations_changed = observations_changed or not cpp.same_header_observation(
                    cpp.copy_header_observation(previous), current_input.observation)
                input.observation = cpp.copy_header_observation(current_input.observation)
            end
        end
    end
    return true, observations_changed
end

function foreigncache.restore(st, imports, key)
    local stats = counters(st)
    if stats then stats.lookups = stats.lookups + 1 end
    local payload, saved_inputs = cacheadapter.get(st.cache_adapter, foreigncache.KIND, key)
    local _, current = references(imports)
    local snapshot = payload and cpp.decode_graph(payload, {
        references = current,
        sha256_binary = st.cache_adapter and st.cache_adapter.sha256_binary,
        yield = st.cache_adapter and st.cache_adapter.yield,
    })
    local checked, valid, observations_changed = pcall(
        prepare_snapshot, snapshot, imports, key, st, saved_inputs)
    if not checked and type(valid) ~= "string" then error(valid, 0) end
    valid = checked and valid
    if not valid then
        if stats then stats.misses = stats.misses + 1 end
        return false
    end
    -- Decode and validate every root before mutating the current checker.
    for _, name in ipairs(roots) do st[name] = snapshot.roots[name] end
    st._converted_c_enums = snapshot.converted_enums
    st.foreign_includes_version = snapshot.foreign_includes_version
    st.last_foreign_import_node = snapshot.last_foreign_import_node
    for index, node in ipairs(imports) do
        node._type, node._include = snapshot.node_types[index], snapshot.node_includes[index]
        st:add_symbol(node.localname, node)
    end
    if observations_changed then
        local inputs = collect_inputs(imports)
        local refreshed = cacheadapter.refresh_inputs(st.cache_adapter, foreigncache.KIND, key, inputs)
        if refreshed == nil and st.cache_adapter.put then
            local updated = foreigncache.encode(st, imports, key)
            if updated then cacheadapter.put(st.cache_adapter, foreigncache.KIND, key, updated, inputs) end
        end
    end
    if stats then stats.hits = stats.hits + 1 end
    return true
end


function foreigncache.store(st, key, payload, imports)
    if cacheadapter.put(st.cache_adapter, foreigncache.KIND, key, payload, collect_inputs(imports)) then
        local stats = counters(st)
        if stats then stats.stores = stats.stores + 1 end
    end
end

return foreigncache
