local os_support = require "spec.support.os_test_support"

describe("os Lua-host boundary", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("lua-host")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    it("rejects executable-path lookup without standalone arguments", function()
        local ok, status, output = os_support.run_lua_source(workspace, [[
local system = require "titan.os"
local succeeded, failure = pcall(system.exepath)
assert(not succeeded)
assert(failure ==
    "os.exepath is only available in a compiled Titan program", failure)
]])
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)
