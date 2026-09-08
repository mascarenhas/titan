local cache = require "titan-compiler.cprobe_cache"

describe("C-probe version 1 result codec", function()
    it("round-trips successes, rejections, and exact diagnostic bytes", function()
        for _, status in ipairs({ 0, 1, 2, 125, 255 }) do
            local result = {
                outcome = status == 0 and "success" or "compiler_rejection",
                exit_status = status,
                diagnostic = "first\r\nsecond\nembedded\0binary\255tail",
            }
            local encoded = assert(cache.encode(result))
            assert.matches("^titan%-cprobe%-1\n", encoded)
            assert.same(result, assert(cache.decode(encoded)))
            assert.equal(encoded, assert(cache.encode(result)))
        end
    end)

    it("rejects incomplete records, extra bytes, invalid headers and statuses", function()
        local encoded = assert(cache.encode({
            outcome = "compiler_rejection", exit_status = 1,
            diagnostic = "multi\nline\0diagnostic",
        }))
        for length = 0, #encoded - 1 do
            assert.is_nil(cache.decode(encoded:sub(1, length)))
        end
        assert.is_nil(cache.decode(encoded .. "x"))
        for _, text in ipairs({ "", "titan-cprobe-2\n0\n0\n",
            "titan-cprobe-1\n126\n0\n", "titan-cprobe-1\n127\n0\n",
            "titan-cprobe-1\n256\n0\n", "titan-cprobe-1\n-1\n0\n",
            "titan-cprobe-1\n0\n99999999999999999999\n",
            "titan-cprobe-1\n0\n1\n" }) do
            assert.is_nil(cache.decode(text))
        end
        assert.is_nil(cache.decode(false))
    end)

    it("bounds diagnostics and encodes only completed semantic outcomes", function()
        for _, status in ipairs({ -1, 1.5, 126, 127, 256, math.huge }) do
            assert.is_nil(cache.encode({
                outcome = "compiler_rejection", exit_status = status, diagnostic = "",
            }))
        end
        assert.is_nil(cache.encode({ outcome = "infrastructure_failure",
            exit_status = 1, diagnostic = "missing compiler" }))
        assert.is_nil(cache.encode({ outcome = "success", exit_status = 1,
            diagnostic = "" }))
        assert.is_nil(cache.encode({ outcome = "success", exit_status = 0,
            diagnostic = false }))
        local result = { outcome = "success", exit_status = 0,
            diagnostic = string.rep("x", cache.MAX_DIAGNOSTIC_BYTES) }
        assert.same(result, assert(cache.decode(assert(cache.encode(result)))))
        result.diagnostic = result.diagnostic .. "x"
        assert.is_nil(cache.encode(result))
    end)
end)
