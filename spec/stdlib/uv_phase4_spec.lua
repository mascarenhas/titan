local phase2 = require "spec.support.phase2"
local phase3 = require "spec.support.phase3"

-- This is the one isolated source variant retained for late filesystem
-- callbacks whose timing cannot be controlled through the public API.
describe("uv Phase 4 late filesystem callbacks", function()
    local workspace
    local root

    setup(function()
        workspace, root = phase3.variant_workspace(
            "spec/support/make_phase4_test_variant.lua")
        phase2.copy_source(workspace,
            "spec/fixtures/uv/phase4/race_cases.titan",
            "phase4_race_cases")
        local compile_options = {
            stdlib = workspace .. "/titan",
        }
        phase3.compile(workspace, "phase4_race_cases", compile_options)
    end)

    teardown(function()
        phase3.cleanup(workspace)
    end)

    it("covers late cancellation/open disposal and cross-generation roots",
    function()
        local command = phase3.variant_lua_command(workspace,
            phase3.repo .. "/spec/fixtures/uv/phase4/runtime.lua", root)
        local ok, status, output = phase3.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase4 late-FS and GC races passed",
            output, 1, true)
    end)
end)
