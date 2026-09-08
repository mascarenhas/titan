local codec = require "titan-compiler.graphcodec"
local sha256 = require "titan-compiler.sha256"

describe("literal compiler graph codec", function()
    it("preserves cycles, table-key aliases and literal metatables", function()
        local key, child = {}, { value = "shared" }
        local root = { key = key, left = child, right = child }
        root[root], root[key], child.parent = child, child, root
        root.weak = setmetatable({ [key] = child }, { __mode = "k" })
        local copy = assert(codec.decode(assert(codec.encode(root))))
        assert.not_equal(root, copy)
        assert.equal(copy.left, copy.right)
        assert.equal(copy.left, copy[copy])
        assert.equal(copy.left, copy[copy.key])
        assert.equal(copy, copy.left.parent)
        assert.equal(copy.left, copy.weak[copy.key])
        assert.equal("k", getmetatable(copy.weak).__mode)
        copy.left.value = "changed"
        assert.equal("shared", child.value)
    end)

    it("round trips binary strings and exact Lua numeric representations", function()
        local original = {
            binary = "\0\255\192text\0",
            minimum = math.mininteger, maximum = math.maxinteger,
            fraction = 0.125, negative_zero = -0.0,
            infinity = math.huge, nan = 0/0, false_value = false,
        }
        local copy = assert(codec.decode(assert(codec.encode(original))))
        assert.equal(original.binary, copy.binary)
        assert.equal(math.mininteger, copy.minimum)
        assert.equal(math.maxinteger, copy.maximum)
        assert.equal("integer", math.type(copy.maximum))
        assert.equal("float", math.type(copy.fraction))
        assert.equal(0.125, copy.fraction)
        assert.equal(-math.huge, 1 / copy.negative_zero)
        assert.equal(math.huge, copy.infinity)
        assert.is_true(copy.nan ~= copy.nan)
        assert.is_false(copy.false_value)
    end)

    it("rebinds explicit external references without copying caller state", function()
        local old, current = { old = true }, { current = true }
        local payload = assert(codec.encode({ node = old, [old] = "key" }, {
            external = { [old] = "import:1" },
        }))
        local copy = assert(codec.decode(payload, {
            references = { ["import:1"] = current },
        }))
        assert.equal(current, copy.node)
        assert.equal("key", copy[current])
        assert.is_nil(copy.node.old)
        assert.is_nil(codec.decode(payload))
    end)

    it("rejects executable values and bounded oversized graphs", function()
        assert.is_nil(codec.encode({ fn = function() end }))
        assert.is_nil(codec.encode({ value = coroutine.create(function() end) }))
        assert.is_nil(codec.encode(setmetatable({}, { __metatable = "private" })))
        assert.is_nil(codec.encode({ {}, {} }, { max_nodes = 2 }))
        assert.is_nil(codec.encode({ first = 1, second = 2 }, { max_entries = 1 }))
        assert.is_nil(codec.encode({ text = "too long" }, { max_string_bytes = 3 }))
        assert.is_nil(codec.encode({ string.rep("a", 100) }, { max_bytes = 50 }))
    end)

    it("rejects corruption, truncation and incompatible graph versions", function()
        local payload = assert(codec.encode({ answer = 42 }))
        assert.is_nil(codec.decode(payload:sub(1, -2)))
        assert.is_nil(codec.decode(payload .. "trailing"))
        assert.is_nil(codec.decode("unknown" .. payload))
        assert.is_nil(codec.decode(payload:sub(1, -2) .. "x"))
        assert.is_nil(codec.decode(payload, { max_bytes = 8 }))
    end)

    it("keeps callback and fallback checksums byte-compatible for binary graphs", function()
        local root = { empty = "", binary = "a\0b\255\192", long = string.rep("abc", 200) }
        root.self = root
        local bodies = {}
        local options = { sha256_binary = function(body)
            bodies[#bodies + 1] = body
            return sha256.binary(body)
        end }
        local payload = assert(codec.encode(root, options))
        assert.equal(1, #bodies)
        assert.equal(payload, assert(codec.encode(root)))
        assert.equal(payload:sub(#"TITAN-GRAPH\0\1" + 33), bodies[1])
        assert.truthy(bodies[1]:find(root.binary, 1, true))
        local fallback = assert(codec.decode(payload))
        local callback = assert(codec.decode(payload, options))
        assert.equal(fallback, fallback.self)
        assert.equal(callback, callback.self)
        assert.equal(root.binary, callback.binary)
        assert.equal(2, #bodies)
        assert.equal(bodies[1], bodies[2])
        local corrupt = payload:sub(1, -2) .. string.char(payload:byte(-1) ~ 1)
        local restored, err = codec.decode(corrupt, options)
        assert.is_nil(restored)
        assert.matches("checksum mismatch", err, 1, true)
    end)

    it("rejects invalid checksum callbacks and preserves cancellation identity", function()
        local root = { answer = 42 }
        local payload = assert(codec.encode(root))
        for _, invalid in ipairs({ false, 1, "not a function" }) do
            assert.is_nil(codec.encode(root, { sha256_binary = invalid }))
            assert.is_nil(codec.decode(payload, { sha256_binary = invalid }))
        end
        for _, invalid in ipairs({ false, 1, "", string.rep("a", 31), string.rep("a", 64) }) do
            local options = { sha256_binary = function() return invalid end }
            assert.is_nil(codec.encode(root, options))
            assert.is_nil(codec.decode(payload, options))
        end
        local failed = { sha256_binary = function() error("hash unavailable") end }
        assert.is_nil(codec.encode(root, failed))
        assert.is_nil(codec.decode(payload, failed))
        local cancelled = {}
        local options = { sha256_binary = function() error(cancelled, 0) end }
        local ok, err = pcall(codec.encode, root, options)
        assert.is_false(ok)
        assert.equal(cancelled, err)
        ok, err = pcall(codec.decode, payload, options)
        assert.is_false(ok)
        assert.equal(cancelled, err)
    end)

    it("validates node directories and references before hydration", function()
        local function record(body)
            return "TITAN-GRAPH\0\1" .. sha256.binary(body) .. body
        end
        assert.is_nil(codec.decode(record(string.pack(">I4", 1000000) .. "n")))
        assert.is_nil(codec.decode(record(string.pack(">I4", 1) ..
            "r" .. string.pack(">I4", 2) .. string.pack(">I4", 0) .. "nn")))
        local root = string.pack(">I4", 1) .. "r" .. string.pack(">I4", 1)
        assert.is_nil(codec.decode(record(root .. string.pack(">I4", 1) .. "nnnt")))
        assert.is_nil(codec.decode(record(root .. string.pack(">I4", 2) .. "nntftt")))
    end)
end)
