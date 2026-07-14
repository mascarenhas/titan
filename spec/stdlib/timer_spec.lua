local async_stdlib = require "spec.support.async_stdlib"

describe("timer recurring handles", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("timer")
        async_stdlib.copy_fixture(workspace,
            "timer/recurring_cases.titan", "timer_recurring_cases")
        async_stdlib.compile(workspace, "timer_recurring_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("cycles four times, drops empty ticks, cedes zero turns, and closes",
    function()
        local command = async_stdlib.lua_command(workspace,
            async_stdlib.repo .. "/spec/fixtures/stdlib/timer/runtime.lua")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT timer recurring handles passed", output, 1, true)
    end)
end)
