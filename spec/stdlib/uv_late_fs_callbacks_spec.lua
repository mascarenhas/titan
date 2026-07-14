local async_stdlib = require "spec.support.async_stdlib"
local fs_support = require "spec.support.fs_test_support"

-- This is the one isolated source variant retained for late filesystem
-- callbacks whose timing cannot be controlled through the public API.
describe("uv late filesystem callbacks", function()
    local workspace
    local root

    setup(function()
        workspace, root = fs_support.variant_workspace(
            "spec/support/make_delayed_fs_callback_variant.lua")
        async_stdlib.copy_source(workspace,
            "spec/fixtures/stdlib/uv/late_fs_callbacks/cases.titan",
            "uv_late_fs_callback_cases")
        local compile_options = {
            stdlib = workspace .. "/titan",
        }
        fs_support.compile(workspace, "uv_late_fs_callback_cases",
            compile_options)
    end)

    teardown(function()
        fs_support.cleanup(workspace)
    end)

    it("covers late cancellation/open disposal and cross-generation roots",
    function()
        local command = fs_support.variant_lua_command(workspace,
            fs_support.repo ..
                "/spec/fixtures/stdlib/uv/late_fs_callbacks/runtime.lua",
            root)
        local ok, status, output = fs_support.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT uv late filesystem callbacks and rooting passed",
            output, 1, true)
    end)
end)
