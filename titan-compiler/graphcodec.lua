-- Literal graph transport for disposable compiler caches. No cache byte is Lua
-- source. Table allocation precedes reference resolution, preserving cycles,
-- shared aliases, table keys and caller-owned sidecars without constructors.
local sha256 = require "titan-compiler.sha256"

local graphcodec = { VERSION = 1 }
local MAGIC = "TITAN-GRAPH\0\1"
local DEFAULTS = {
    max_bytes = 256 * 1024 * 1024,
    max_nodes = 1000000,
    max_entries = 4000000,
    max_string_bytes = 64 * 1024 * 1024,
}

local function limits(options)
    local result = {}
    for name, default in pairs(DEFAULTS) do
        local limit = options[name] or default
        assert(type(limit) == "number" and math.type(limit) == "integer"
            and limit > 0 and limit <= default, "invalid graph " .. name)
        result[name] = limit
    end
    return result
end

local function checksum(bytes, options)
    local digest = options.sha256_binary
    if digest == nil then digest = sha256.binary end
    assert(type(digest) == "function", "graph sha256_binary must be a function")
    local result = digest(bytes)
    assert(type(result) == "string" and #result == 32,
        "graph sha256_binary must return a 32-byte digest")
    return result
end

local function encode(root, options)
    local bound = limits(options)
    local nodes, ids, records = {}, {}, {}
    local external = options.external or {}
    local entry_count, byte_count = 0, 4
    local chunks = {}
    local function append(bytes)
        chunks[#chunks + 1] = bytes
    end
    local function charge(count)
        byte_count = byte_count + count
        assert(byte_count <= bound.max_bytes, "graph byte limit exceeded")
    end
    local function string_value(value)
        assert(#value <= bound.max_string_bytes, "graph string limit exceeded")
        return string.pack(">I4", #value) .. value
    end
    local function value(item)
        local kind = type(item)
        if kind == "nil" then charge(1); return "n"
        elseif kind == "boolean" then charge(1); return item and "t" or "f"
        elseif kind == "string" then
            charge(5 + #item)
            return "s" .. string_value(item)
        elseif kind == "number" then
            charge(9)
            return math.type(item) == "integer"
                and "i" .. string.pack(">i8", item)
                or "d" .. string.pack(">d", item)
        elseif kind ~= "table" then
            error("unsupported graph value: " .. kind, 0)
        end
        local key = external[item]
        if key ~= nil then
            assert(type(key) == "string", "invalid external graph key")
            charge(5 + #key)
            return "x" .. string_value(key)
        end
        local id = ids[item]
        if not id then
            assert(#nodes < bound.max_nodes, "graph node limit exceeded")
            id = #nodes + 1
            ids[item], nodes[id] = id, item
        end
        charge(5)
        return "r" .. string.pack(">I4", id)
    end
    local root_value = value(root)
    local index = 1
    while nodes[index] do
        local node, record = nodes[index], {}
        charge(4)
        local metatable = getmetatable(node)
        assert(metatable == nil or type(metatable) == "table",
            "protected graph metatable is unsupported")
        record.meta = value(metatable)
        local annotations = options.annotations and options.annotations(node)
        assert(annotations == nil or type(annotations) == "table",
            "invalid graph annotations")
        record.annotations = value(annotations)
        -- next/rawget deliberately do not invoke payload metamethods.
        for key, item in next, node do
            entry_count = entry_count + 1
            assert(entry_count <= bound.max_entries,
                "graph entry limit exceeded")
            record[#record + 1] = value(key) .. value(item)
        end
        records[index] = record
        index = index + 1
    end
    append(string.pack(">I4", #nodes))
    append(root_value)
    for _, record in ipairs(records) do
        append(string.pack(">I4", #record))
        append(record.meta)
        append(record.annotations)
        for _, entry in ipairs(record) do append(entry) end
    end
    local body = table.concat(chunks)
    return MAGIC .. checksum(body, options) .. body
end

local function decode(payload, options)
    local bound = limits(options)
    assert(type(payload) == "string", "graph payload must be a string")
    assert(#payload <= bound.max_bytes + #MAGIC + 32,
        "graph byte limit exceeded")
    assert(payload:sub(1, #MAGIC) == MAGIC, "incompatible graph codec")
    local body = payload:sub(#MAGIC + 33)
    assert(#body >= 5, "truncated graph payload")
    assert(checksum(body, options) == payload:sub(#MAGIC + 1, #MAGIC + 32),
        "graph checksum mismatch")
    local position, entry_count = 1, 0
    local function take(count)
        assert(count <= #body - position + 1, "truncated graph payload")
        local result = body:sub(position, position + count - 1)
        position = position + count
        return result
    end
    local function integer4()
        return string.unpack(">I4", take(4))
    end
    local function string_value()
        local count = integer4()
        assert(count <= bound.max_string_bytes, "graph string limit exceeded")
        return take(count)
    end
    local node_count = integer4()
    assert(node_count <= bound.max_nodes, "graph node limit exceeded")
    -- Even zero-entry nodes occupy at least six encoded bytes. Reject an
    -- impossible directory before allocating a payload-sized table vector.
    assert(node_count <= (#body - position) // 6,
        "truncated graph node directory")
    local nodes, records = {}, {}
    for index = 1, node_count do nodes[index] = {} end
    local function value()
        local tag = take(1)
        if tag == "n" then return nil
        elseif tag == "t" then return true
        elseif tag == "f" then return false
        elseif tag == "s" then return string_value()
        elseif tag == "i" then return string.unpack(">i8", take(8))
        elseif tag == "d" then return string.unpack(">d", take(8))
        elseif tag == "r" then
            local id = integer4()
            assert(id > 0 and id <= node_count, "invalid graph reference")
            return nodes[id]
        elseif tag == "x" then
            local key = string_value()
            local reference = options.references and options.references[key]
            assert(type(reference) == "table", "unresolved external graph reference")
            return reference
        end
        error("invalid graph value tag", 0)
    end
    local root = value()
    for index = 1, node_count do
        local count = integer4()
        entry_count = entry_count + count
        assert(entry_count <= bound.max_entries, "graph entry limit exceeded")
        assert(count <= (#body - position + 1) // 2,
            "truncated graph entries")
        local meta, annotations = value(), value()
        assert(meta == nil or type(meta) == "table", "invalid graph metatable")
        assert(annotations == nil or type(annotations) == "table",
            "invalid graph annotations")
        local node = nodes[index]
        for _ = 1, count do
            local key, item = value(), value()
            assert(key ~= nil and not (type(key) == "number" and key ~= key),
                "invalid graph table key")
            assert(item ~= nil, "nil graph table entry")
            assert(rawget(node, key) == nil, "duplicate graph table key")
            rawset(node, key, item)
        end
        records[index] = { meta = meta, annotations = annotations }
    end
    assert(position == #body + 1, "trailing graph payload bytes")
    -- Establish all ordinary references before weak-key metatables or sidecar
    -- publication. The node directory roots every object through this phase.
    for index, record in ipairs(records) do
        if record.meta then setmetatable(nodes[index], record.meta) end
    end
    for index, record in ipairs(records) do
        if record.annotations then
            assert(type(options.restore_annotations) == "function",
                "graph annotations have no owner")
            options.restore_annotations(nodes[index], record.annotations)
        end
    end
    return root
end

function graphcodec.encode(root, options)
    local ok, result = pcall(encode, root, options or {})
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        return nil, result
    end
    return result
end

function graphcodec.decode(payload, options)
    local ok, result = pcall(decode, payload, options or {})
    if not ok then
        if type(result) ~= "string" then error(result, 0) end
        return nil, result
    end
    return result
end

return graphcodec
