-- Version 2 stores a completed compiler result and optional typed selection.
-- The filename is SHA256(raw probe source); the record repeats no identity.
local cprobe_cache = {}

local PREFIX = "titan-cprobe-2\n"
cprobe_cache.VERSION = 2
local MAX_DIAGNOSTIC_BYTES = 1024 * 1024
cprobe_cache.MAX_DIAGNOSTIC_BYTES = MAX_DIAGNOSTIC_BYTES
cprobe_cache.MAX_RECORD_BYTES = MAX_DIAGNOSTIC_BYTES + 96

function cprobe_cache.valid_selection(selection)
    if type(selection) ~= "table" or selection.kind ~= "enum_carrier" then
        return false
    end
    local count, id = selection.match_count, selection.carrier_id
    if math.type(count) ~= "integer" or count < 0 or count > 11 or
       math.type(id) ~= "integer" then return false end
    -- IDs are distinct members of the stable 1..11 carrier list. For a given
    -- count every sum between these extrema is attainable.
    return id >= count * (count + 1) // 2 and
        id <= count * (23 - count) // 2
end

local function valid_status(status)
    return type(status) == "number" and status >= 0 and status <= 255
        and status % 1 == 0 and status ~= 126 and status ~= 127
end

function cprobe_cache.encode(record)
    if type(record) ~= "table" or not valid_status(record.exit_status) then
        return nil, "invalid C-probe cache exit status"
    end
    local outcome = record.exit_status == 0 and "success" or "compiler_rejection"
    if record.outcome ~= outcome then
        return nil, "inconsistent C-probe cache outcome"
    end
    if type(record.diagnostic) ~= "string" or
       #record.diagnostic > MAX_DIAGNOSTIC_BYTES then
        return nil, "invalid C-probe cache diagnostic"
    end
    local selection = record.selection
    local payload = "acceptance\n"
    if selection ~= nil then
        if record.exit_status ~= 0 or
           not cprobe_cache.valid_selection(selection) then
            return nil, "invalid C-probe enum selection"
        end
        payload = "enum_carrier\n" .. selection.match_count .. "\n" ..
            selection.carrier_id .. "\n"
    end
    return PREFIX .. record.exit_status .. "\n" .. payload ..
        #record.diagnostic .. "\n" .. record.diagnostic
end

function cprobe_cache.decode(encoded)
    if type(encoded) ~= "string" or #encoded > cprobe_cache.MAX_RECORD_BYTES or
       encoded:sub(1, #PREFIX) ~= PREFIX then
        return nil, "invalid C-probe cache record"
    end
    local status, kind, cursor = encoded:match(
        "^(%d+)\n([a-z_]+)\n()", #PREFIX + 1)
    local selection
    if kind == "enum_carrier" then
        local count, id, next_cursor = encoded:match(
            "^(%d+)\n(%d+)\n()", cursor)
        selection = { kind = kind, match_count = tonumber(count),
            carrier_id = tonumber(id) }
        if status ~= "0" or not cprobe_cache.valid_selection(selection) then
            return nil, "invalid C-probe enum selection"
        end
        cursor = next_cursor
    elseif kind ~= "acceptance" then
        return nil, "invalid C-probe result kind"
    end
    local length, start = encoded:match("^(%d+)\n()", cursor)
    status, length = tonumber(status), tonumber(length)
    if not valid_status(status) or not length or
       length > MAX_DIAGNOSTIC_BYTES or #encoded - start + 1 ~= length then
        return nil, "invalid or incomplete C-probe cache record"
    end
    return {
        outcome = status == 0 and "success" or "compiler_rejection",
        exit_status = status,
        diagnostic = encoded:sub(start),
        selection = selection,
    }
end

return cprobe_cache
