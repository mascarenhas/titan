local cprobe_cache = require "titan-compiler.cprobe_cache"
local sha256 = require "titan-compiler.sha256"

local KEY_A = string.rep("a", 64)
local KEY_B = string.rep("b", 64)
local CHECKSUM_SIZE = 32

local function replace_byte(text, position, byte)
    return text:sub(1, position - 1) .. string.char(byte) ..
        text:sub(position + 1)
end

local function flip_byte(text, position)
    return replace_byte(text, position, text:byte(position) ~ 0xff)
end

local function with_valid_checksum(record, mutate)
    local payload = record:sub(1, -CHECKSUM_SIZE - 1)
    payload = mutate(payload)
    return payload .. sha256.binary(payload)
end

local function assert_rejected(record, expected_key)
    local decoded, err = cprobe_cache.decode(record, expected_key or KEY_A)
    assert.is_nil(decoded)
    assert.is_string(err)
end

describe("C-probe persistent result record codec", function()
    it("round-trips completed semantic results and exact diagnostic bytes",
    function()
        local cases = {
            {
                key_digest = KEY_A,
                outcome = "success",
                exit_status = 0,
                diagnostic = "accepted with warning\nsecond line\0\255",
            },
            {
                key_digest = KEY_B,
                outcome = "compiler_rejection",
                exit_status = 1,
                diagnostic = "first\r\nsecond\nembedded\0binary\255tail",
            },
        }
        for _, expected in ipairs(cases) do
            local encoded = assert(cprobe_cache.encode(expected))
            local repeated = assert(cprobe_cache.encode(expected))
            assert.equal(encoded, repeated)
            assert.equal(cprobe_cache.DOMAIN, "titan-cprobe-result-record-v1")
            assert.same(expected, assert(cprobe_cache.decode(
                encoded, expected.key_digest)))
        end
    end)

    it("rejects invalid values before encoding", function()
        local valid = {
            key_digest = KEY_A,
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }
        local invalid = {
            false,
            { key_digest = "a", outcome = "success",
              exit_status = 0, diagnostic = "" },
            { key_digest = string.rep("A", 64), outcome = "success",
              exit_status = 0, diagnostic = "" },
            { key_digest = KEY_A, outcome = "rejected",
              exit_status = 1, diagnostic = "" },
            { key_digest = KEY_A, outcome = "success",
              exit_status = 1, diagnostic = "" },
            { key_digest = KEY_A, outcome = "compiler_rejection",
              exit_status = 0, diagnostic = "" },
            { key_digest = KEY_A, outcome = "compiler_rejection",
              exit_status = 126, diagnostic = "" },
            { key_digest = KEY_A, outcome = "compiler_rejection",
              exit_status = 127, diagnostic = "" },
            { key_digest = KEY_A, outcome = "compiler_rejection",
              exit_status = -1, diagnostic = "" },
            { key_digest = KEY_A, outcome = "compiler_rejection",
              exit_status = 1.5, diagnostic = "" },
            { key_digest = KEY_A, outcome = "success",
              exit_status = 0, diagnostic = false },
        }
        assert.is_string(assert(cprobe_cache.encode(valid)))
        for _, record in ipairs(invalid) do
            local encoded, err = cprobe_cache.encode(record)
            assert.is_nil(encoded)
            assert.is_string(err)
        end

        local encoded, err = cprobe_cache.encode({
            key_digest = KEY_A,
            outcome = "success",
            exit_status = 0,
            diagnostic = string.rep(
                "x", cprobe_cache.MAX_DIAGNOSTIC_BYTES + 1),
        })
        assert.is_nil(encoded)
        assert.equal("C-probe cache diagnostic is too large", err)
    end)

    it("rejects every truncation and any trailing bytes", function()
        local encoded = assert(cprobe_cache.encode({
            key_digest = KEY_A,
            outcome = "compiler_rejection",
            exit_status = 2,
            diagnostic = "multi\nline\0diagnostic",
        }))
        for length = 0, #encoded - 1 do
            assert_rejected(encoded:sub(1, length))
        end
        assert_rejected(encoded .. "x")
        assert_rejected(encoded .. string.rep("\0", CHECKSUM_SIZE))
    end)

    it("rejects corruption and a valid record stored under another key",
    function()
        local encoded = assert(cprobe_cache.encode({
            key_digest = KEY_A,
            outcome = "compiler_rejection",
            exit_status = 1,
            diagnostic = "diagnostic payload",
        }))
        assert_rejected(flip_byte(encoded, #encoded - CHECKSUM_SIZE))
        assert_rejected(flip_byte(encoded, #encoded))

        local swapped = assert(cprobe_cache.encode({
            key_digest = KEY_B,
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }))
        assert_rejected(swapped, KEY_A)
    end)

    it("rejects unknown domains, outcomes, invalid keys, and statuses",
    function()
        local encoded = assert(cprobe_cache.encode({
            key_digest = KEY_A,
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }))
        local domain_position = 2
        local domain_length_position = 1
        local key_position = 2 + #cprobe_cache.DOMAIN
        local outcome_position = key_position + 64
        local status_position = outcome_position + 1

        assert_rejected(with_valid_checksum(encoded, function(payload)
            return replace_byte(
                payload, domain_length_position, #cprobe_cache.DOMAIN - 1)
        end))
        assert_rejected(with_valid_checksum(encoded, function(payload)
            return replace_byte(payload, domain_position, string.byte("X"))
        end))
        assert_rejected(with_valid_checksum(encoded, function(payload)
            return replace_byte(payload, key_position, string.byte("g"))
        end))
        assert_rejected(with_valid_checksum(encoded, function(payload)
            return replace_byte(payload, outcome_position, string.byte("?"))
        end))
        assert_rejected(with_valid_checksum(encoded, function(payload)
            return replace_byte(payload, status_position, 1)
        end))

        local rejection = assert(cprobe_cache.encode({
            key_digest = KEY_A,
            outcome = "compiler_rejection",
            exit_status = 1,
            diagnostic = "",
        }))
        assert_rejected(with_valid_checksum(rejection, function(payload)
            return replace_byte(payload, status_position, 0)
        end))
        assert_rejected(with_valid_checksum(rejection, function(payload)
            return replace_byte(payload, status_position, 126)
        end))
        assert_rejected(with_valid_checksum(rejection, function(payload)
            return replace_byte(payload, status_position, 127)
        end))
    end)

    it("rejects invalid decoder inputs", function()
        local encoded = assert(cprobe_cache.encode({
            key_digest = KEY_A,
            outcome = "success",
            exit_status = 0,
            diagnostic = "",
        }))
        local decoded, err = cprobe_cache.decode(false, KEY_A)
        assert.is_nil(decoded)
        assert.is_string(err)
        decoded, err = cprobe_cache.decode(encoded, "not-a-digest")
        assert.is_nil(decoded)
        assert.is_string(err)
    end)
end)
