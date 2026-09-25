-- Trusted compiler-produced source records travel with their native objects.
-- Make owns freshness; this reader only loads the Lua record and checks ABI.
local projectcache = require "titan-compiler.projectcache"
local staticmetadata = require "titan-compiler.staticmetadata"
local util = require "titan-compiler.util"
local version = require "titan-compiler.version"

local objectmetadata = {}
local BANNER = "-- Titan object source metadata\n"
local SECTION = { elf = ".titan.source", macho_segment = "__TEXT",
    macho_section = "__titansrc" }

local function serialize(record)
    local tables, indices, assignments = {}, {}, {}
    local function value(item)
        local kind = type(item)
        if kind == "table" then
            local index = indices[item]
            if not index then
                index = #tables + 1
                tables[index], indices[item] = item, index
            end
            return "t[" .. index .. "]"
        elseif kind == "nil" or kind == "boolean" then
            return tostring(item)
        elseif kind == "string" or kind == "number" then
            return string.format("%q", item)
        end
        error("cannot serialize object metadata value of type " .. kind, 0)
    end
    local root = value(record)
    local index = 1
    while tables[index] do
        local node, keys = tables[index], {}
        -- Declaration projections and native facts have scalar lookup keys.
        -- Sort them before allocating children so unchanged records have an
        -- unchanged byte representation regardless of Lua table hash order.
        for key in pairs(node) do
            local kind = type(key)
            assert(kind == "string" or kind == "number" or kind == "boolean",
                "object metadata requires scalar table keys")
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            local left, right = type(a), type(b)
            if left ~= right then return left < right end
            if left == "string" then return util.bytewise_less(a, b) end
            if left == "boolean" then return not a and b end
            return a < b
        end)
        for _, key in ipairs(keys) do
            assignments[#assignments + 1] = "t[" .. index .. "][" .. value(key)
                .. "]=" .. value(node[key]) .. "\n"
        end
        index = index + 1
    end
    local output = { BANNER, "local t={}\n" }
    for i = 1, #tables do output[#output + 1] = "t[" .. i .. "]={}\n" end
    output[#output + 1] = table.concat(assignments)
    output[#output + 1] = "return " .. root .. "\n"
    return table.concat(output)
end

function objectmetadata.encode(entry, native)
    local projected, err = projectcache.project_declarations(entry)
    if not projected then return nil, err end
    projected.object_metadata = native
    local ok, payload = pcall(serialize, {
        abi = version.TITAN_ABI_VERSION,
        module = projected.type.name,
        entry = projected,
    })
    if not ok then return nil, tostring(payload) end
    return payload
end

function objectmetadata.decode(payload, origin, expected_abi)
    origin = origin or "<object source metadata>"
    expected_abi = expected_abi or version.TITAN_ABI_VERSION
    local chunk, err = load(payload, "@" .. origin, "t", {})
    if not chunk then return nil, err end
    -- A malformed or obsolete compiler record is a cache miss. Deliberately
    -- do not apply the persisted analysis graph's separate validation policy.
    local ok, entry, failure = pcall(function()
        local record = chunk()
        if record.abi ~= expected_abi then
            return nil, "object source metadata ABI mismatch: expected "
                .. tostring(expected_abi) .. " but found " .. tostring(record.abi)
        end
        local native = record.entry and record.entry.object_metadata
        if native and native.layouts ~= nil then
            local inventory, layout_error =
                require("titan-compiler.nominallayout").decode(
                    native.layouts, record.module)
            if not inventory then
                return nil, "invalid object nominal layout metadata: " ..
                    tostring(layout_error)
            end
            record.entry.layout_inventory = inventory
        end
        return record.entry
    end)
    if not ok then return nil, tostring(entry) end
    return entry, failure
end

function objectmetadata.render(payload, symbol)
    return staticmetadata.source_declaration(payload, symbol)
end

function objectmetadata.read(bytes, origin, expected_abi)
    local payload, err = staticmetadata.read_object_section(
        bytes, origin, SECTION, #bytes)
    if not payload then return nil, err end
    return objectmetadata.decode(payload, origin, expected_abi)
end

return objectmetadata
