local async_stdlib = require "spec.support.async_stdlib"

local SOURCE = [[
    local uv = import "titan.uv"

    function find(haystack: string, needle: string): integer
      return uv._bytes_find(haystack, needle)
    end

    function slice(data: string, offset: integer,
                   length: integer): string
      return uv._bytes_slice(data, offset, length)
    end
]]

describe("uv byte helpers", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("uv-bytes")
        async_stdlib.write_source(workspace, "uv_bytes_probe", SOURCE)
        async_stdlib.compile(workspace, "uv_bytes_probe")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("preserves binary search and slicing edge behavior", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local bytes = require "uv_bytes_probe"

            assert(bytes.find("", "") == 0)
            assert(bytes.find("abc", "") == 0)
            assert(bytes.find("ab", "abc") == -1)
            assert(bytes.find("a\0bc\0d", "\0b") == 1)
            assert(bytes.find("a\0bc\0d", "\0d") == 4)
            assert(bytes.find("abcdef", "cd") == 2)
            assert(bytes.find("abcdef", "zz") == -1)

            assert(bytes.slice("a\0bc\0d", 1, 4) == "\0bc\0")
            assert(bytes.slice("abc", 0, 0) == "")
            assert(bytes.slice("abc", 3, 0) == "")
            assert(bytes.slice("abc", 0, 3) == "abc")

            local invalid = {
                function() return bytes.slice("abc", -1, 1) end,
                function() return bytes.slice("abc", 0, -1) end,
                function() return bytes.slice("abc", 4, 0) end,
                function() return bytes.slice("abc", 2, 2) end,
            }
            for _, attempt in ipairs(invalid) do
                local accepted, err = pcall(attempt)
                assert(not accepted)
                assert(tostring(err):find("byte slice is out of range",
                    1, true))
            end
        ]])
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)
