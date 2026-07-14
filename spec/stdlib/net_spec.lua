local phase2 = require "spec.support.phase2"

describe("net standard library", function()
    local workspace

    setup(function()
        workspace = phase2.workspace("net-runtime")
        phase2.copy_source(workspace,
            "spec/fixtures/uv/phase5/net_cases.titan", "net_cases")
        phase2.compile(workspace, "net_cases")
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = phase2.repo ..
            "/spec/fixtures/uv/phase5/net_runtime.lua"
        return phase2.run(phase2.lua_command(workspace, script,
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
