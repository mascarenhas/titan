local os_support = require "spec.support.os_test_support"

describe("os synchronous helpers", function()
    local workspace
    local envname

    setup(function()
        workspace = os_support.workspace("helpers")
        envname = ("TITAN_OS_HELPERS_" .. workspace):
            gsub("[^A-Za-z0-9_]", "_")
        os_support.copy_fixture(workspace, "helpers/cases.titan",
            "os_helper_cases")
        os_support.compile(workspace, "os_helper_cases")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    it("preserves environment and cwd while resizing real values",
    function()
        local script = os_support.repo ..
            "/spec/fixtures/stdlib/os/helpers/runtime.lua"
        local command = os_support.lua_command(
            workspace, script, workspace, envname)
        local ok, status, output = os_support.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os synchronous helpers passed",
            output, 1, true)
    end)
end)
