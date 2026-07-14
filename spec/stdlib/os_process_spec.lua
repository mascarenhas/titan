local os_support = require "spec.support.os_test_support"

describe("os child processes", function()
    local workspace
    local child
    local envname

    setup(function()
        workspace = os_support.workspace("process")
        child = os_support.process_child(workspace)
        envname = ("TITAN_OS_PROCESS_" .. workspace):
            gsub("[^A-Za-z0-9_]", "_")
        os_support.copy_fixture(workspace, "process/cases.titan",
            "os_process_cases")
        os_support.compile(workspace, "os_process_cases")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = os_support.repo ..
            "/spec/fixtures/stdlib/os/process/runtime.lua"
        local command = os_support.lua_command(
            workspace, script, workspace .. "/os_process_cases.so",
            name, child, envname)
        return os_support.run(command, workspace)
    end

    it("preserves argv/environment/cwd and retained exit status", function()
        local ok, status, output = run_scenario("spawn-status")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os process spawn and status passed",
            output, 1, true)
    end)

    it("keeps binary stdio FIFO across GC and queued cancellation", function()
        local ok, status, output = run_scenario("stdio")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os process stdio passed", output, 1, true)
    end)

    it("cancels replaceable wait and read waiters", function()
        local ok, status, output = run_scenario("wait-read")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os process wait and read passed",
            output, 1, true)
    end)

    it("communicates concurrently without large-pipe deadlock", function()
        local ok, status, output = run_scenario("communicate")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os process communicate passed",
            output, 1, true)
    end)

    it("observes helper errors and drains cancellation before rethrow",
    function()
        local ok, status, output = run_scenario("communicate-failure")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match(
            "RESULT os process communicate failure and cancellation passed",
            output, 1, true)
    end)

    it("terminates, reaps, and closes a leaked TERM-resistant child",
    function()
        local ok, status, output = run_scenario("shutdown")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os forced process shutdown passed",
            output, 1, true)
    end)
end)
