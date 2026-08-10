local async_stdlib = require "spec.support.async_stdlib"

local TASK_CASES = [[
    local async = import "async"
    local timer = import "timer"

    function schedule_failure_only(): async.Task
      return async.run(function (): value
        timer.yield()
        raise "last-task-boom"
        return nil
      end)
    end
]]

describe("async Task callback continuations", function()
    local workspace

    local function port_seed(text)
        local hash = 0
        for index = 1, #text do
            hash = (hash * 33 + text:byte(index)) % 30000
        end
        return 20000 + hash
    end

    setup(function()
        workspace = async_stdlib.workspace("uv-tasks")
        async_stdlib.write_source(workspace, "uv_task_cases", TASK_CASES)
        async_stdlib.compile(workspace, "uv_task_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("starts Runtime cleanup when the last live Task fails", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            local task = behavior.schedule_failure_only()
            async.loop()
            assert(task:status():as_string() == "failed")
        ]])

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("last-task-boom", output, 1, true)
        assert.match("stack traceback:", output, 1, true)
    end)

end)
