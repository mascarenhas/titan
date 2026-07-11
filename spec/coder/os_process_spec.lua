local phase6 = require "spec.support.phase6"

describe("os Phase 6 child processes", function()
    local workspace
    local child
    local envname

    setup(function()
        workspace = phase6.workspace()
        child = phase6.process_child(workspace)
        envname = ("TITAN_PHASE6_PROCESS_" .. workspace):
            gsub("[^A-Za-z0-9_]", "_")
        phase6.copy_fixture(workspace, "process_core_cases.titan",
            "phase6_process_cases")
        phase6.compile(workspace, "phase6_process_cases", {
            stdlib = workspace,
        })
    end)

    teardown(function()
        phase6.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = phase6.repo ..
            "/spec/fixtures/uv/phase6/process_runtime.lua"
        local command = phase6.variant_lua_command(
            workspace, script, workspace .. "/phase6_process_cases.so",
            name, child, envname)
        return phase6.run(command, workspace)
    end

    it("preserves argv/environment/cwd and retained exit status", function()
        local ok, status, output = run_scenario("spawn-status")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 process spawn and status passed",
            output, 1, true)
    end)

    it("keeps binary stdio FIFO across GC and queued cancellation", function()
        local ok, status, output = run_scenario("stdio")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 process stdio passed", output, 1, true)
    end)

    it("cancels replaceable wait and read waiters", function()
        local ok, status, output = run_scenario("wait-read")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 process wait and read passed",
            output, 1, true)
    end)

    it("communicates concurrently without large-pipe deadlock", function()
        local ok, status, output = run_scenario("communicate")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 communicate success passed",
            output, 1, true)
    end)

    it("observes helper errors and drains cancellation before rethrow",
    function()
        local ok, status, output = run_scenario("communicate-failure")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match(
            "RESULT phase6 communicate failure and cancellation passed",
            output, 1, true)
    end)

    it("terminates, reaps, and closes a leaked TERM-resistant child",
    function()
        local ok, status, output = run_scenario("shutdown")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 forced process shutdown passed",
            output, 1, true)
    end)
end)
