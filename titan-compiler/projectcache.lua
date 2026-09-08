-- Complete checked project entries remain compiler-owned opaque graph data.
-- External source/provider ASTs are never made persistent through a project
-- type's navigation edges. Importing an entry does not register it or touch I/O.
local cpp = require "c-parser.cpp"
local graphcodec = require "titan-compiler.graphcodec"
local staticmetadata = require "titan-compiler.staticmetadata"
local version = require "titan-compiler.version"

local projectcache = { VERSION = 1 }

local function valid_entry(entry, options, work)
    work = work or graphcodec.work(options)
    local header_observations = {}
    if type(options.header_inputs) == "table" then
        for _, input in ipairs(options.header_inputs) do
            work()
            if type(input) == "table" and input.kind == "file"
               and type(input.path) == "string" and type(input.identity) == "string" then
                local observation = cpp.copy_header_observation(input.observation)
                if observation then
                    header_observations[input.kind .. "\0" .. input.path .. "\0" .. input.identity] = observation
                end
            end
        end
    end
    local modname = options.module_name or
        (type(entry) == "table" and type(entry.type) == "table" and entry.type.name)
    if not staticmetadata.valid_module_name(modname) or type(entry) ~= "table"
       or entry.kind ~= "source" or type(entry.ast) ~= "table"
       or type(entry.type) ~= "table" or entry.type._tag ~= "Type.Module"
       or entry.type.name ~= modname or entry.type._source ~= true
       or type(entry.type.source_members) ~= "table"
       or type(entry.type.source_type_members) ~= "table"
       or type(entry.filename) ~= "string" or entry.filename == ""
       or type(entry.source_files) ~= "table" or #entry.source_files == 0
       or entry.source_files[1] ~= entry.filename
       or type(entry.deps) ~= "table"
       or type(entry.source_manifest) ~= "string" or entry.source_manifest == "" then
        return nil, "project snapshot is not a complete checked source entry"
    end
    local files = {}
    for index, filename in ipairs(entry.source_files) do
        work()
        if type(filename) ~= "string" or filename == "" or files[filename] then
            return nil, "project snapshot has an invalid source file list"
        end
        files[filename] = true
        if options.project_files and not options.project_files[filename] then
            return nil, "project snapshot contains a non-project source file"
        end
    end
    for key in next, entry.source_files do
        work()
        if math.type(key) ~= "integer" or key < 1 or key > #entry.source_files then
            return nil, "project snapshot source file list must be dense"
        end
    end
    for name, present in next, entry.deps do
        work()
        if not staticmetadata.valid_module_name(name) or present ~= true then
            return nil, "project snapshot has an invalid dependency map"
        end
    end
    local allowed = options.project_files or files
    local seen, queue = {}, {entry}
    local index = 1
    while queue[index] do
        work()
        local node = queue[index]
        index = index + 1
        if not seen[node] then
            seen[node] = true
            if node.kind == "file" and type(node.path) == "string"
               and type(node.identity) == "string" then
                local observation = header_observations[node.kind .. "\0" .. node.path .. "\0" .. node.identity]
                if observation then node.observation = cpp.copy_header_observation(observation) end
            end
            if type(node._tag) == "string" and node._tag:sub(1, 4) == "Ast." then
                local filename = type(node.loc) == "table" and node.loc.filename
                if type(filename) ~= "string" or not allowed[filename] then
                    return nil, "project snapshot reaches an external source AST"
                end
            end
            for key, child in next, node do
                work()
                if type(key) == "table" then queue[#queue + 1] = key end
                if type(child) == "table" then queue[#queue + 1] = child end
            end
            local meta = getmetatable(node)
            if type(meta) == "table" then queue[#queue + 1] = meta end
        end
    end
    return true
end

function projectcache.encode(entry, options)
    options = options or {}
    local valid, err = valid_entry(entry, options)
    if not valid then return nil, err end
    -- A shallow root copy excludes resolver-owned paths; all semantic children
    -- are encoded together, preserving their existing sharing and cycles.
    local retained = {}
    for key, value in next, entry do
        if key ~= "checking_foreign_header" and key ~= "_cached_source_entry" then
            retained[key] = value
        end
    end
    return cpp.encode_graph({
        kind = "titan-project-entry",
        version = projectcache.VERSION,
        graph_version = graphcodec.VERSION,
        titan_version = version.TITAN_VERSION,
        library_version = version.TITAN_LIBRARY_VERSION,
        abi = version.TITAN_ABI_VERSION,
        entry = retained,
    }, options)
end

function projectcache.decode(payload, options)
    options = options or {}
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
    local valid
    valid, err = valid_entry(envelope.entry, options)
    if not valid then return nil, err end
    envelope.entry.checking_foreign_header = nil
    envelope.entry._cached_source_entry = nil
    return envelope.entry
end

function projectcache.registry(entries, options)
    options = options or {}
    local work = graphcodec.work(options)
    if type(entries) ~= "table" then return nil, "project entries must be a module map" end
    local names, registry = {}, {}
    for name, entry in pairs(entries) do
        work()
        local valid, err = valid_entry(entry, { module_name = name, yield = options.yield }, work)
        if not valid then return nil, err end
        if type(entry.ast._declared_registry) ~= "table" then
            return nil, "project entry has no declared owner registry"
        end
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        for fqtn, owner in pairs(entries[name].ast._declared_registry) do
            work()
            local declaring = type(fqtn) == "string" and fqtn:match("^(.*)%.")
            if not declaring or type(owner) ~= "table" or owner.name ~= fqtn
               or (owner._tag ~= "Type.Record" and owner._tag ~= "Type.Union"
                   and owner._tag ~= "Type.Interface") then
                return nil, "project entry has an invalid declared owner registry"
            end
            -- An entry may retain the owner view it imported. The current
            -- project's own checked entry is authoritative for that module;
            -- external owners remain interface graphs, never source ASTs.
            if declaring == name or not entries[declaring] then
                if not registry[fqtn] or declaring == name then registry[fqtn] = owner end
            end
        end
    end
    return registry
end

-- Semantic validation is also fallible for malformed literal metatables (for
-- example an __index cycle). No rejected payload can escape into publication.
for _, name in ipairs({ "encode", "decode", "registry" }) do
    local operation = projectcache[name]
    projectcache[name] = function(...)
        local ok, result, err = pcall(operation, ...)
        if not ok then
            if type(result) ~= "string" then error(result, 0) end
            return nil, result
        end
        return result, err
    end
end

return projectcache
