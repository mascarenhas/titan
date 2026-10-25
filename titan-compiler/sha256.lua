-- Pure-Lua SHA-256 for compiler identities and cache keys. Keep this module
-- binary-safe and dependency-free: it is loaded while the compiler is still
-- establishing its native toolchain context. The titanc CLI supplies the
-- native digest through a cache adapter's `sha256_binary` (see hex_via).
local sha256 = {}

local MASK = 0xffffffff
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rotr(value, count)
    return ((value >> count) | (value << (32 - count))) & MASK
end

local function digest_words(message)
    local byte_length = #message
    local bit_length = byte_length * 8
    local high = math.floor(bit_length / 0x100000000)
    local low = bit_length & MASK
    local padding = (56 - ((byte_length + 1) % 64)) % 64
    message = message .. "\128" .. string.rep("\0", padding) ..
        string.pack(">I4I4", high, low)

    local hash = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }
    local words = {}
    for offset = 1, #message, 64 do
        for index = 0, 15 do
            words[index] = string.unpack(">I4", message,
                offset + index * 4)
        end
        for index = 16, 63 do
            local x = words[index - 15]
            local s0 = rotr(x, 7) ~ rotr(x, 18) ~ (x >> 3)
            x = words[index - 2]
            local s1 = rotr(x, 17) ~ rotr(x, 19) ~ (x >> 10)
            words[index] = (words[index - 16] + s0 +
                words[index - 7] + s1) & MASK
        end

        local a, b, c, d = hash[1], hash[2], hash[3], hash[4]
        local e, f, g, h = hash[5], hash[6], hash[7], hash[8]
        for index = 0, 63 do
            local sum1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
            local choose = (e & f) ~ ((~e) & g)
            local temp1 = (h + sum1 + choose + K[index + 1] +
                words[index]) & MASK
            local sum0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
            local majority = (a & b) ~ (a & c) ~ (b & c)
            local temp2 = (sum0 + majority) & MASK
            h, g, f, e = g, f, e, (d + temp1) & MASK
            d, c, b, a = c, b, a, (temp1 + temp2) & MASK
        end

        hash[1] = (hash[1] + a) & MASK
        hash[2] = (hash[2] + b) & MASK
        hash[3] = (hash[3] + c) & MASK
        hash[4] = (hash[4] + d) & MASK
        hash[5] = (hash[5] + e) & MASK
        hash[6] = (hash[6] + f) & MASK
        hash[7] = (hash[7] + g) & MASK
        hash[8] = (hash[8] + h) & MASK
    end
    return hash
end

function sha256.binary(message)
    assert(type(message) == "string", "SHA-256 input must be a string")
    return string.pack(">I4I4I4I4I4I4I4I4",
        table.unpack(digest_words(message)))
end

local function to_hex(digest)
    return (("%02x"):rep(#digest):format(digest:byte(1, -1)))
end

function sha256.hex(message)
    return to_hex(sha256.binary(message))
end

-- Hex digest through an optional adapter `sha256_binary` callback. A string
-- error or a result that is not a 32-byte string falls back to this module;
-- any other error (cancellation, a foreign exception) propagates unchanged.
function sha256.hex_via(callback, message)
    if callback then
        local ok, result = pcall(callback, message)
        if not ok and type(result) ~= "string" then error(result, 0) end
        if ok and type(result) == "string" and #result == 32 then
            return to_hex(result)
        end
    end
    return sha256.hex(message)
end

return sha256
