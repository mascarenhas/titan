-- A compiler cache is a best-effort byte transport, never a storage dependency.
-- Callbacks are dot functions. Non-string exceptions retain cancellation and
-- foreign exception identity; ordinary transport errors become cache misses.
local cacheadapter = {}

function cacheadapter.validate(adapter)
    if adapter == nil then return true end
    if type(adapter) ~= "table" or type(adapter.get) ~= "function"
       or (adapter.put ~= nil and type(adapter.put) ~= "function")
       or (adapter.sha256_binary ~= nil and type(adapter.sha256_binary) ~= "function")
       or (adapter.yield ~= nil and type(adapter.yield) ~= "function")
       or (adapter.refresh_inputs ~= nil and type(adapter.refresh_inputs) ~= "function") then
        return nil, "cache_adapter requires get and optional put/sha256_binary/yield/refresh_inputs functions"
    end
    return true
end

function cacheadapter.get(adapter, kind, key)
    if not adapter then return nil end
    local ok, payload, inputs = pcall(adapter.get, kind, key)
    if not ok then
        if type(payload) ~= "string" then error(payload, 0) end
        return nil
    end
    return type(payload) == "string" and payload or nil,
        type(inputs) == "table" and inputs or nil
end

function cacheadapter.put(adapter, kind, key, payload, inputs)
    if not adapter or not adapter.put then return false end
    local ok, stored = pcall(adapter.put, kind, key, payload, inputs)
    if not ok then
        if type(stored) ~= "string" then error(stored, 0) end
        return false
    end
    return stored ~= false and stored ~= nil
end

-- Observation metadata can be refreshed without serializing a semantic graph.
-- Nil means unsupported; an implemented transport failure remains best effort.
function cacheadapter.refresh_inputs(adapter, kind, key, inputs)
    if not adapter or not adapter.refresh_inputs then return nil end
    local ok, stored = pcall(adapter.refresh_inputs, kind, key, inputs)
    if not ok then
        if type(stored) ~= "string" then error(stored, 0) end
        return false
    end
    return stored ~= false and stored ~= nil
end

return cacheadapter
