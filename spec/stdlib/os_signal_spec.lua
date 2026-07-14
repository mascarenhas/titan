local os_support = require "spec.support.os_test_support"

describe("os one-shot signals", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("signal")
        os_support.copy_fixture(workspace, "signals/cases.titan",
            "os_signal_cases")
        os_support.compile(workspace, "os_signal_cases", {
            cppflags = os_support.libuv_cppflags(),
        })
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    it("waits before public-libuv self delivery and drains each session", function()
        local script = os_support.repo ..
            "/spec/fixtures/stdlib/os/signals/runtime.lua"
        local command = os_support.lua_command(workspace, script)
        local ok, status, output = os_support.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os signal runtime passed", output, 1, true)
    end)
end)
