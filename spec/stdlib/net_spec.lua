local phase5 = require "spec.support.phase5"

describe("net Phase 5 runtime", function()
    local workspace

    setup(function()
        workspace = phase5.workspace("runtime")
        phase5.copy_fixture(workspace, "net_cases.titan", "phase5_net_cases")
        phase5.compile(workspace, "phase5_net_cases")
    end)

    teardown(function()
        phase5.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = phase5.repo ..
            "/spec/fixtures/uv/phase5/net_runtime.lua"
        return phase5.run(phase5.lua_command(workspace, script,
            workspace .. "/phase5_net_cases.so", name), workspace)
    end

    it("covers binary IPv4, excess, exact/until, FIFO, shutdown, and EOF",
    function()
        local ok, status, output = run_scenario("core")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase5 net core passed", output, 1, true)
    end)

    it("rejects concurrent waiters and bounds the accepted-client queue",
    function()
        local ok, status, output = run_scenario("waiters")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase5 net waiters passed", output, 1, true)
    end)

    it("tries DNS addresses in order and exercises IPv6 when available",
    function()
        local ok, status, output = run_scenario("dns-ipv6")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase5 net DNS and IPv6 passed", output, 1, true)
    end)

    it("closes leaked handles, releases roots, and rejects stale sessions",
    function()
        local ok, status, output = run_scenario("gc-sequential")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase5 net GC and sequential sessions passed",
            output, 1, true)
    end)
end)
