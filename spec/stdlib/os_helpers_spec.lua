local phase6 = require "spec.support.phase6"

describe("os Phase 6 synchronous helpers", function()
    local workspace
    local envname

    setup(function()
        workspace = phase6.workspace("helpers")
        envname = ("TITAN_PHASE6_HELPERS_" .. workspace):
            gsub("[^A-Za-z0-9_]", "_")
        phase6.copy_fixture(workspace, "os_helper_cases.titan",
            "phase6_os_helper_cases")
        phase6.compile(workspace, "phase6_os_helper_cases")
    end)

    teardown(function()
        phase6.cleanup(workspace)
    end)

    it("preserves environment and cwd while resizing real values",
    function()
        local script = phase6.repo ..
            "/spec/fixtures/uv/phase6/os_helper_runtime.lua"
        local command = phase6.lua_command(
            workspace, script, workspace, envname)
        local ok, status, output = phase6.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 synchronous OS helpers passed",
            output, 1, true)
    end)
end)
