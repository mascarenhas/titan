local phase2 = require "spec.support.phase2"

describe("timer Phase 2 recurring handles", function()
    local workspace

    setup(function()
        workspace = phase2.workspace("timer")
        phase2.copy_fixture(workspace, "ticker_cases.titan",
            "phase2_ticker_cases")
        phase2.compile(workspace, "phase2_ticker_cases")
    end)

    teardown(function() phase2.cleanup(workspace) end)

    it("cycles four times, drops empty ticks, cedes zero turns, and closes",
    function()
        local command = phase2.lua_command(workspace,
            phase2.repo .. "/spec/fixtures/uv/phase2/runtime.lua", "ticker")
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase2 ticker passed", output, 1, true)
    end)
end)
