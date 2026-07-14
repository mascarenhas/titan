local async_stdlib = require "spec.support.async_stdlib"

describe("uv Task scheduling and lifecycle", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("uv-tasks")
        async_stdlib.copy_fixture(workspace, "uv/tasks/cases.titan",
            "uv_task_cases")
        async_stdlib.copy_fixture(workspace,
            "uv/tasks/cancellation_cases.titan",
            "uv_task_cancellation_cases")
        async_stdlib.compile(workspace, "uv_task_cases")
        async_stdlib.compile(workspace, "uv_task_cancellation_cases")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run_scenario(name)
        local command = async_stdlib.lua_command(workspace,
            async_stdlib.repo ..
                "/spec/fixtures/stdlib/uv/tasks/runtime.lua", name)
        return async_stdlib.run(command, workspace)
    end

    it("runs nonblocking/nested roots, shared-tag nesting, A-to-B handoff, " ..
       "out-of-order timers, observation, and child-loop rejection", function()
        local ok, status, output = run_scenario("scheduler")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT uv task scheduling passed", output, 1, true)
    end)

    it("preserves a first, sticky cancellation reason", function()
        local ok, status, output = run_scenario("cancellation")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT uv task cancellation passed", output, 1, true)
    end)

    it("reports a cyclic Task join as an idle-loop deadlock", function()
        local ok, status, output = run_scenario("join-cycle")
        assert.falsy(ok, output)
        assert.not_equals(0, status)
        assert.match("libuv loop became idle while Tasks were waiting", output,
            1, true)
    end)

    it("roots dropped Tasks through generational GC and closes sequential loops",
    function()
        local ok, status, output = run_scenario("sequential-gc")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT uv task GC and sequential sessions passed",
            output, 1, true)
    end)

end)
