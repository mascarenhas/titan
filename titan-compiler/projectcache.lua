-- Analysis retains declared module interfaces, never the checked source AST.
-- This schema is closed: a new compiler annotation must not silently make
-- syntax, lowering plans or CPP graphs persistent again.
local cpp = require "c-parser.cpp"
local types = require "titan-compiler.types"
local graphcodec = require "titan-compiler.graphcodec"
local version = require "titan-compiler.version"
local staticmetadata = require "titan-compiler.staticmetadata"
local ffiheaders = require "titan-compiler.ffiheaders"
local completion = require "titan-compiler.completion"

local projectcache = { VERSION = 5 }

local schemas = require "titan-compiler.declarationschemas"

local function fail(message)
    error("invalid project manifest: " .. message, 0)
end

local function attempt(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then
        if type(value) ~= "string" then error(value, 0) end
        return nil, value
    end
    return value
end

local function valid_entry(entry, options, declarations_only)
    if type(entry) ~= "table" or entry.kind ~= "source"
        or type(entry.type) ~= "table" or entry.type._tag ~= "Type.Module"
        or entry.type._source ~= true or not staticmetadata.valid_module_name(entry.type.name)
        or type(entry.filename) ~= "string" or entry.filename == ""
        or type(entry.source_files) ~= "table" or entry.source_files[1] ~= entry.filename
        or type(entry.deps) ~= "table" then fail("entry is not a complete checked source module") end
    if not declarations_only and (type(entry.source_manifest) ~= "string"
        or entry.source_manifest == "") then fail("entry is not a complete checked source module") end
    if options and options.module_name and options.module_name ~= entry.type.name then
        fail("entry belongs to another module")
    end
end

-- Iterative projection preserves recursive/shared declarations without using
-- the host Lua stack. A strong memo remains alive across cooperative GC.
local function project(entry, options, strict, declarations_only)
    options = options or {}
    valid_entry(entry, options, declarations_only)
    local work = graphcodec.work(options)
    work(0, true)
    local memo, roles, queue, headers, types_seen = {}, {}, {}, {}, {}
    local declared = entry.declared_registry or entry.ast and entry.ast._declared_registry or {}
    local registry, observations = {}, {}
    for _, input in ipairs(options.header_inputs or {}) do
        work()
        if input.kind == "file" and input.observation then
            observations[input.path .. "\0" .. input.identity] = input.observation
        end
    end
    local copy
    copy = function(value, kind)
        work()
        if kind:sub(-1) == "?" then
            if value == nil then return nil end
            kind = kind:sub(1, -2)
        end
        if kind == "array_constness" then
            if not types.valid_array_constness(value) then
                fail("invalid Array const qualifier")
            end
            return { tag = value.tag }
        elseif kind == "c_name" then
            kind = type(value) == "table" and "names" or "string"
        end
        if kind == "string" or kind == "boolean" or kind == "integer" or kind == "atom" then
            local actual = type(value)
            if kind == "atom" then
                if actual ~= "string" and actual ~= "boolean" and actual ~= "number" then
                    fail("expected scalar declaration field")
                end
            elseif kind == "integer" then
                if math.type(value) ~= "integer" then fail("expected integer declaration field") end
            elseif actual ~= kind then fail("expected " .. kind .. " declaration field") end
            if actual == "number" and (value ~= value or value == math.huge or value == -math.huge) then
                fail("non-finite declaration number")
            end
            return value
        elseif kind == "extent" and type(value) ~= "table" then
            if type(value) ~= "string" and type(value) ~= "number" then
                fail("expected C extent expression")
            end
            return copy(value, "atom")
        end
        if type(value) ~= "table" then fail("expected " .. kind .. " declaration table") end
        if getmetatable(value) ~= nil then fail("declaration table has a metatable") end
        if kind == "type" then
            kind = value._tag
            if not schemas[kind] or not kind:match("^Type%.") then
                fail("unsupported declared type " .. tostring(kind))
            end
        end
        if value._tag ~= nil and not kind:match("^Type%.") then
            fail("unexpected tagged declaration table " .. tostring(value._tag))
        end
        if memo[value] then
            if roles[value] ~= kind then fail("declaration table has incompatible roles") end
            return memo[value]
        end
        local result = {}
        memo[value], roles[value] = result, kind
        queue[#queue + 1] = { source = value, target = result, kind = kind }
        return result
    end
    local result = {
        kind = "source",
        filename = copy(entry.filename, "string"), source_files = copy(entry.source_files, "names"),
        deps = copy(entry.deps, "dependencies"), source_imports = {},
        type = copy(entry.type, "type"),
        c_header_dependencies = copy(entry.c_header_dependencies or {}, "inputs"), declared_registry = registry,
    }
    if not declarations_only then
        if strict and type(entry.completion_facts) ~= "table" then
            fail("missing completion facts")
        end
        result.completion_facts = copy(entry.completion_facts or
            completion.describe(entry).candidates, "completion_facts")
        result._analysis_manifest = true
        result.source_manifest = copy(entry.source_manifest, "string")
    end
    if strict then
        local fields = { kind = true, _analysis_manifest = true, filename = true, source_files = true,
            deps = true, source_imports = true, source_manifest = true, type = true,
            c_header_dependencies = true, declared_registry = true, ffi_header_descriptor = true,
            completion_facts = true }
        if entry._analysis_manifest ~= true then fail("missing analysis capability") end
        if getmetatable(entry) ~= nil then fail("entry has a metatable") end
        for key in pairs(entry) do
            work()
            if not fields[key] then fail("unexpected entry field " .. tostring(key)) end
        end
    end
    if entry.ast then
        for _, node in ipairs(entry.ast) do
            work()
            if not node._ignore and node._tag == "Ast.TopLevelImport" and node._source_import then
                result.source_imports[#result.source_imports + 1] = node.modname
            end
        end
    else result.source_imports = copy(entry.source_imports or {}, "names") end
    local header = entry.ffi_header_descriptor or entry.ast and entry.ast._ffi_header
    if header then result.ffi_header_descriptor = copy(header, "header") end

    local function keep_owner(name)
        local owner = declared[name]
        if owner and not registry[name] then registry[name] = copy(owner, "type") end
    end
    -- The process-wide registry can contain unrelated earlier modules. Keep
    -- this module's declarations and owners reached from its surface only.
    for name in pairs(declared) do
        work()
        if type(name) ~= "string" then fail("invalid declared owner name") end
        if name:match("^(.*)%.") == entry.type.name then keep_owner(name) end
    end
    local index = 1
    while queue[index] do
        work()
        local item = queue[index]
        local source, target, kind = item.source, item.target, item.kind
        local schema = schemas[kind]
        if schema then
            local is_type = kind:match("^Type%.") ~= nil
            if is_type then target._tag = kind; types_seen[#types_seen + 1] = target end
            for key, field_kind in pairs(schema) do
                work()
                target[key] = copy(source[key], field_kind)
            end
            if kind == "extent" then
                for key, value in pairs(source) do
                    work()
                    if type(key) == "number" then
                        if math.type(key) ~= "integer" or key < 1 then fail("invalid extent index") end
                        target[key] = copy(value, "extent")
                    elseif strict and not schema[key] then fail("unexpected C extent field " .. tostring(key)) end
                end
            elseif strict then
                for key in pairs(source) do
                    work()
                    if not schema[key] and not (is_type and key == "_tag") then
                        fail("unexpected " .. kind .. " field " .. tostring(key))
                    end
                end
            end
            if kind == "Type.Nominal" then keep_owner(source.fqtn)
            elseif kind == "Type.GenericAlias" then keep_owner(source.target_owner_fqtn)
            elseif kind == "header" then headers[#headers + 1] = target
            elseif kind == "input" then
                if target.kind ~= "file" and target.kind ~= "search" then fail("invalid header input kind") end
                if target.path:sub(1, 1) ~= "/" or target.path:find("\0", 1, true) or target.identity == "" then
                    fail("invalid header input identity")
                end
                local current = observations[target.path .. "\0" .. target.identity]
                if current then target.observation = cpp.copy_header_observation(current) end
            end
        elseif kind == "type_map" or kind == "dependencies" then
            for key, value in pairs(source) do
                work()
                if type(key) ~= "string" then fail("invalid declaration map key") end
                if kind == "dependencies" then
                    if not staticmetadata.valid_module_name(key) or value ~= true then fail("invalid dependency") end
                    target[key] = true
                else target[key] = copy(value, "type") end
            end
        else
            local element = ({ names = "string", types = "type", members = "type", inputs = "input", headers = "header", completion_facts = "completion_fact" })[kind]
            if not element then fail("unknown declaration role " .. tostring(kind)) end
            local count, maximum = 0, 0
            for key in pairs(source) do
                work()
                if type(key) == "number" then
                    if math.type(key) ~= "integer" or key < 1 then fail("invalid declaration list index") end
                    count, maximum = count + 1, math.max(maximum, key)
                elseif kind ~= "members" or type(key) ~= "string" then fail("invalid declaration list key") end
            end
            if count ~= maximum then fail("sparse declaration list") end
            local names = {}
            for i = 1, count do
                work()
                target[i] = copy(source[i], element)
                if kind == "members" then
                    local name = source[i].name
                    if type(name) ~= "string" or names[name] then fail("invalid or duplicate member name") end
                    names[name], target[name] = true, target[i]
                    if strict and source[name] ~= source[i] then fail("noncanonical member lookup") end
                end
            end
            if strict and kind == "members" then
                for key in pairs(source) do
                    work()
                    if type(key) == "string" and not names[key] then fail("extra member lookup") end
                end
            end
        end
        index = index + 1
    end
    for _, plan in ipairs(headers) do work(); ffiheaders.validate_plan(plan) end
    -- Reject cycles before the resolver's filesystem lifecycle can recurse.
    local visiting, completed = {}, {}
    for _, plan in ipairs(headers) do
        local stack = { { plan = plan, index = 0 } }
        while #stack > 0 do
            work()
            local frame = stack[#stack]
            if completed[frame.plan] then table.remove(stack)
            elseif frame.index == 0 then visiting[frame.plan] = true; frame.index = 1
            else
                local dependency = frame.plan.dependencies[frame.index]
                frame.index = frame.index + 1
                if dependency then
                    if visiting[dependency] then fail("cyclic generated FFI environment") end
                    if not completed[dependency] then stack[#stack + 1] = { plan = dependency, index = 0 } end
                else visiting[frame.plan], completed[frame.plan] = nil, true; table.remove(stack) end
            end
        end
    end
    for _, typ in ipairs(types_seen) do
        work()
        if typ._tag == "Type.Module" then
            if typ.name ~= entry.type.name or typ._source ~= true
                or typ.prefix ~= typ.name:gsub("[%-.]", "_") .. "_"
                or typ.file ~= typ.name:gsub("[.]", "/") .. ".so" then fail("noncanonical module") end
        elseif typ._tag == "Type.Array" then
            if not types.valid_array_constness(typ.isconst) then fail("invalid Array const qualifier") end
        elseif typ._tag == "Type.Function" and typ.vararg ~= false then fail("invalid Titan variadic sentinel")
        elseif typ._tag == "Type.Parameter" and typ.index < 1 then fail("invalid generic binder index") end
    end
    if strict then
        for name in pairs(declared) do
            work()
            if not registry[name] then fail("unreferenced declared owner " .. name) end
        end
    end
    for _, name in ipairs(result.source_imports) do
        work()
        if not result.deps[name] then fail("source import is absent from dependencies") end
    end
    for _, filename in ipairs(result.source_files) do
        work()
        if filename == "" then fail("empty source filename") end
    end
    if result.ffi_header_descriptor and result.ffi_header_descriptor.modname ~= result.type.name then
        fail("FFI environment belongs to another module")
    end
    local dependencies = result.ffi_header_descriptor and result.ffi_header_descriptor.dependencies or {}
    if #dependencies ~= #result.source_imports then fail("source imports disagree with the FFI environment") end
    for index, name in ipairs(result.source_imports) do
        work()
        if dependencies[index].modname ~= name then fail("source import order disagrees with the FFI environment") end
    end
    work(0, true)
    return result
end

function projectcache.compact(entry, options)
    return attempt(project, entry, options, false)
end

-- Native object metadata shares this declaration projection, but not the
-- analysis-only capability or its equality-only source interface manifest.
-- The object loader supplies the accompanying machine code and native facts.
function projectcache.project_declarations(entry, options)
    return attempt(project, entry, options, false, true)
end

function projectcache.encode(entry, options)
    local compact, err = projectcache.compact(entry, options)
    if not compact then return nil, err end
    return graphcodec.encode({
        kind = "titan-project-manifest", version = projectcache.VERSION,
        graph_version = graphcodec.VERSION, titan_version = version.TITAN_VERSION,
        library_version = version.TITAN_LIBRARY_VERSION, abi = version.TITAN_ABI_VERSION,
        entry = compact,
    }, options)
end

function projectcache.decode(payload, options)
    local envelope, err = graphcodec.decode(payload, options)
    if not envelope then return nil, err end
    if type(envelope) ~= "table" or envelope.kind ~= "titan-project-manifest"
        or envelope.version ~= projectcache.VERSION or envelope.graph_version ~= graphcodec.VERSION
        or envelope.titan_version ~= version.TITAN_VERSION or envelope.library_version ~= version.TITAN_LIBRARY_VERSION
        or envelope.abi ~= version.TITAN_ABI_VERSION then return nil, "incompatible project manifest" end
    return attempt(project, envelope.entry, options, true)
end

function projectcache.registry(entries, options)
    local work = graphcodec.work(options)
    local names, registry = {}, {}
    for name in pairs(entries) do work(); names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local entry = entries[name]
        local declared = entry.declared_registry or entry.ast and entry.ast._declared_registry or {}
        for fqtn, owner in pairs(declared) do
            work()
            local declaring = fqtn:match("^(.*)%.")
            -- Each project's own declaration wins over an imported owner view.
            if declaring == name or not entries[declaring] then
                if not registry[fqtn] or declaring == name then registry[fqtn] = owner end
            end
        end
    end
    if #names > 0 then work(0, true) end
    return registry
end

return projectcache
