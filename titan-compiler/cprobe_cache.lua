-- Binary codec for persistent semantic C-probe results.
--
-- Filesystem policy belongs to cprobe. This module only turns one completed
-- semantic result into a checksummed byte string and validates that byte
-- string against the digest of the key under which it was found.
local cprobe_cache = {}

local sha256 = require "titan-compiler.sha256"

local DOMAIN = "titan-cprobe-result-record-v1"
local CHECKSUM_SIZE = 32
local KEY_DIGEST_SIZE = 64
local DIAGNOSTIC_LENGTH_SIZE = 4
local MAX_DIAGNOSTIC_BYTES = 1024 * 1024

local OUTCOME_TO_CODE = {
    success = "S",
    compiler_rejection = "R",
}

local CODE_TO_OUTCOME = {
    S = "success",
    R = "compiler_rejection",
}

cprobe_cache.DOMAIN = DOMAIN
cprobe_cache.MAX_DIAGNOSTIC_BYTES = MAX_DIAGNOSTIC_BYTES

local function valid_key_digest(digest)
    return type(digest) == "string" and #digest == KEY_DIGEST_SIZE and
        digest:match("^[0-9a-f]+$") ~= nil
end

local function valid_exit_status(status)
    return type(status) == "number" and status == status and
        status >= 0 and status <= 255 and status % 1 == 0
end

local function validate_semantics(outcome, status)
    if outcome == "success" then
        if status ~= 0 then
            return nil, "successful C-probe cache result must have exit status 0"
        end
    elseif outcome == "compiler_rejection" then
        if status == 0 then
            return nil, "rejected C-probe cache result must have a nonzero exit status"
        elseif status == 126 or status == 127 then
            return nil, "C-probe cache result cannot encode an unavailable-command exit status"
        end
    else
        return nil, "unknown C-probe cache outcome"
    end
    return true
end

local function checked_record(record)
    if type(record) ~= "table" then
        return nil, "C-probe cache result must be a table"
    elseif not valid_key_digest(record.key_digest) then
        return nil, "C-probe cache key digest must be 64 lowercase hexadecimal bytes"
    elseif OUTCOME_TO_CODE[record.outcome] == nil then
        return nil, "unknown C-probe cache outcome"
    elseif not valid_exit_status(record.exit_status) then
        return nil, "C-probe cache exit status must be an integer from 0 through 255"
    elseif type(record.diagnostic) ~= "string" then
        return nil, "C-probe cache diagnostic must be a string"
    elseif #record.diagnostic > MAX_DIAGNOSTIC_BYTES then
        return nil, "C-probe cache diagnostic is too large"
    end
    return validate_semantics(record.outcome, record.exit_status)
end

function cprobe_cache.encode(record)
    local valid, err = checked_record(record)
    if not valid then return nil, err end

    local payload = string.pack(
        ">s1c64c1I1I4",
        DOMAIN,
        record.key_digest,
        OUTCOME_TO_CODE[record.outcome],
        record.exit_status,
        #record.diagnostic) .. record.diagnostic
    return payload .. sha256.binary(payload)
end

local function read_header(encoded)
    local minimum = 1 + #DOMAIN + KEY_DIGEST_SIZE + 1 + 1 +
        DIAGNOSTIC_LENGTH_SIZE + CHECKSUM_SIZE
    if #encoded < minimum then
        return nil, "truncated C-probe cache record"
    end

    local domain_length = encoded:byte(1)
    if domain_length ~= #DOMAIN then
        return nil, "unknown C-probe cache record domain"
    end
    local domain_end = 1 + domain_length
    if encoded:sub(2, domain_end) ~= DOMAIN then
        return nil, "unknown C-probe cache record domain"
    end

    local key_start = domain_end + 1
    local key_end = key_start + KEY_DIGEST_SIZE - 1
    local key_digest = encoded:sub(key_start, key_end)
    local outcome_code = encoded:sub(key_end + 1, key_end + 1)
    local exit_status = encoded:byte(key_end + 2)
    local diagnostic_length = string.unpack(">I4", encoded, key_end + 3)
    local diagnostic_start = key_end + 7

    return {
        key_digest = key_digest,
        outcome_code = outcome_code,
        exit_status = exit_status,
        diagnostic_length = diagnostic_length,
        diagnostic_start = diagnostic_start,
    }
end

function cprobe_cache.decode(encoded, expected_key_digest)
    if type(encoded) ~= "string" then
        return nil, "C-probe cache record must be a string"
    elseif not valid_key_digest(expected_key_digest) then
        return nil, "expected C-probe cache key digest must be 64 lowercase hexadecimal bytes"
    end

    local header, err = read_header(encoded)
    if not header then return nil, err end

    local payload_length = header.diagnostic_start - 1 +
        header.diagnostic_length
    local expected_length = payload_length + CHECKSUM_SIZE
    if #encoded < expected_length then
        return nil, "truncated C-probe cache record"
    elseif #encoded > expected_length then
        return nil, "trailing bytes after C-probe cache record"
    end

    local payload = encoded:sub(1, payload_length)
    local checksum = encoded:sub(payload_length + 1)
    if checksum ~= sha256.binary(payload) then
        return nil, "C-probe cache payload checksum mismatch"
    elseif not valid_key_digest(header.key_digest) then
        return nil, "C-probe cache record contains an invalid key digest"
    elseif header.key_digest ~= expected_key_digest then
        return nil, "C-probe cache key digest mismatch"
    end

    local outcome = CODE_TO_OUTCOME[header.outcome_code]
    local valid, semantic_error = validate_semantics(
        outcome, header.exit_status)
    if not valid then return nil, semantic_error end

    return {
        key_digest = header.key_digest,
        outcome = outcome,
        exit_status = header.exit_status,
        diagnostic = encoded:sub(
            header.diagnostic_start,
            payload_length),
    }
end

return cprobe_cache
