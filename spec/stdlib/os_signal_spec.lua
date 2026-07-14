local phase6 = require "spec.support.phase6"

describe("os Phase 6 one-shot signals", function()
    local workspace

    setup(function()
        workspace = phase6.workspace("signal")
        phase6.copy_fixture(workspace, "signal_cases.titan",
            "phase6_signal_cases")
        phase6.compile(workspace, "phase6_signal_cases", {
            cppflags = phase6.libuv_cppflags(),
        })
    end)

    teardown(function()
        phase6.cleanup(workspace)
    end)

    it("waits before public-libuv self delivery and drains each session", function()
        local script = phase6.repo ..
            "/spec/fixtures/uv/phase6/signal_runtime.lua"
        local command = phase6.lua_command(workspace, script)
        local ok, status, output = phase6.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 signal runtime passed", output, 1, true)
    end)
end)
