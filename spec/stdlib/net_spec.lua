local async_stdlib = require "spec.support.async_stdlib"

describe("net standard library", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("net-runtime")
        async_stdlib.copy_source(workspace,
            "spec/fixtures/stdlib/net/cases.titan", "net_cases")
        async_stdlib.compile(workspace, "net_cases")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = async_stdlib.repo ..
            "/spec/fixtures/stdlib/net/runtime.lua"
        return async_stdlib.run(async_stdlib.lua_command(workspace, script,
            workspace .. "/net_cases.so", name), workspace)
    end

    it("covers binary IPv4, excess, exact/until, FIFO, shutdown, and EOF",
    function()
        local ok, status, output = run_scenario("core")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT net core passed", output, 1, true)
    end)

    it("rejects concurrent waiters and bounds the accepted-client queue",
    function()
        local ok, status, output = run_scenario("waiters")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT net waiters passed", output, 1, true)
    end)

    it("tries DNS addresses in order and exercises IPv6 when available",
    function()
        local ok, status, output = run_scenario("dns-ipv6")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT net DNS and IPv6 passed", output, 1, true)
    end)

    it("closes leaked handles, releases roots, and rejects stale sessions",
    function()
        local ok, status, output = run_scenario("gc-sequential")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT net GC and sequential sessions passed",
            output, 1, true)
    end)
end)
