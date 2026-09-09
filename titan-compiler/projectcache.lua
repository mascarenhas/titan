-- Complete checked project entries remain compiler-owned opaque graph data.
-- Dependency validation belongs to the loader; this transport preserves the
-- current compiler's graph while omitting resolver-owned physical paths.
local cpp = require "c-parser.cpp"
local graphcodec = require "titan-compiler.graphcodec"
local version = require "titan-compiler.version"

local projectcache = { VERSION = 2 }

local function persistent_field(node, key)
    if key == "filename" or key == "bundle_root" then
        -- Generated header descriptors have one stable logical identity and a
        -- separate resolver-owned location. Ordinary source filenames stay.
        return rawget(node, "logical_name") == nil or rawget(node, "modname") == nil
    elseif key == "checking_foreign_header" or key == "checking_ffi_header"
        or key == "_cached_source_entry" then
        return rawget(node, "kind") ~= "source" or rawget(node, "ast") == nil
    elseif key == "_foreign_header" or key == "_foreign_header_for_check"
        or key == "_ffi_header" then
        return rawget(node, "_tag") ~= "Ast.TopLevelImport"
    end
    return true
end

function projectcache.encode(entry, options)
    local projected = {}
    for key, value in pairs(options or {}) do projected[key] = value end
    projected.filter = persistent_field
    -- The codec owns the source-node directory throughout traversal, keeping
    -- aliases, weak-table entries and CPP sidecars alive without a graph copy.
    return cpp.encode_graph({
        kind = "titan-project-entry",
        version = projectcache.VERSION,
        graph_version = graphcodec.VERSION,
        titan_version = version.TITAN_VERSION,
        library_version = version.TITAN_LIBRARY_VERSION,
        abi = version.TITAN_ABI_VERSION,
        entry = entry,
    }, projected)
end

function projectcache.decode(payload, options)
    options = options or {}
    if options.header_inputs then
        local work = graphcodec.work(options)
        local observations = {}
        for _, input in ipairs(options.header_inputs) do
            work()
            if input.kind == "file" and input.observation then
                observations[input.path .. "\0" .. input.identity] = input.observation
            end
        end
        local restored = {}
        for key, value in pairs(options) do restored[key] = value end
        -- Overlay current filesystem observations while the decoder already
        -- visits each completed node. Cached bytes and live entries stay intact.
        restored.restore_node = function(node)
            if node.kind == "file" and node.path and node.identity then
                local observation = observations[node.path .. "\0" .. node.identity]
                if observation then node.observation = cpp.copy_header_observation(observation) end
            end
        end
        options = restored
    end
    local envelope, err = cpp.decode_graph(payload, options)
    if not envelope then return nil, err end
    if type(envelope) ~= "table" or envelope.kind ~= "titan-project-entry"
       or envelope.version ~= projectcache.VERSION
       or envelope.graph_version ~= graphcodec.VERSION
       or envelope.titan_version ~= version.TITAN_VERSION
       or envelope.library_version ~= version.TITAN_LIBRARY_VERSION
       or envelope.abi ~= version.TITAN_ABI_VERSION then
        return nil, "incompatible project snapshot"
    end
    return envelope.entry
end

function projectcache.registry(entries, options)
    local work = graphcodec.work(options)
    local names, registry = {}, {}
    for name in pairs(entries) do
        work()
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        for fqtn, owner in pairs(entries[name].ast._declared_registry or {}) do
            work()
            local declaring = fqtn:match("^(.*)%.")
            -- Checked and decoded entries are compiler-owned. The current
            -- project's own entry wins over an imported owner view.
            if declaring == name or not entries[declaring] then
                if not registry[fqtn] or declaring == name then registry[fqtn] = owner end
            end
        end
    end
    return registry
end

return projectcache
