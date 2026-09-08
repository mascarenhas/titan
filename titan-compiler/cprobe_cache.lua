-- Version 1 stores one completed compiler exit status and its diagnostic.
-- The filename is SHA256(raw probe source); the record repeats no identity.
local cprobe_cache = {}

local PREFIX = "titan-cprobe-1\n"
local MAX_DIAGNOSTIC_BYTES = 1024 * 1024
cprobe_cache.MAX_DIAGNOSTIC_BYTES = MAX_DIAGNOSTIC_BYTES
cprobe_cache.MAX_RECORD_BYTES = MAX_DIAGNOSTIC_BYTES + 64

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
    return PREFIX .. record.exit_status .. "\n" ..
        #record.diagnostic .. "\n" .. record.diagnostic
end

function cprobe_cache.decode(encoded)
    if type(encoded) ~= "string" or #encoded > cprobe_cache.MAX_RECORD_BYTES or
       encoded:sub(1, #PREFIX) ~= PREFIX then
        return nil, "invalid C-probe cache record"
    end
    local status, length, start = encoded:match("^(%d+)\n(%d+)\n()", #PREFIX + 1)
    status, length = tonumber(status), tonumber(length)
    if not valid_status(status) or not length or
       length > MAX_DIAGNOSTIC_BYTES or #encoded - start + 1 ~= length then
        return nil, "invalid or incomplete C-probe cache record"
    end
    return {
        outcome = status == 0 and "success" or "compiler_rejection",
        exit_status = status,
        diagnostic = encoded:sub(start),
    }
end

return cprobe_cache
