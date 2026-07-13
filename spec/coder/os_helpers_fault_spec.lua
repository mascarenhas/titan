local phase6 = require "spec.support.phase6"

describe("os Phase 6 checked buffer faults", function()
    local workspace
    local envname

    setup(function()
        workspace = phase6.workspace()
        envname = ("TITAN_PHASE6_HELPER_FAULTS_" .. workspace):
            gsub("[^A-Za-z0-9_]", "_")
        phase6.copy_fixture(workspace, "os_helper_faults.titan",
            "phase6_os_helper_faults")
        phase6.compile(workspace, "phase6_os_helper_faults", {
            stdlib = workspace .. "/titan",
        })
    end)

    teardown(function()
        phase6.cleanup(workspace)
    end)

    it("keeps deterministic resize controls isolated and public-libuv-only",
    function()
        local production = phase6.read("stdlib/uv.titan")
        assert.falsy(production:find("__test_phase6_os_buffer_fault",
            1, true))
        local variant = phase6.read(workspace .. "/stdlib/uv.titan")
        for _, hook in ipairs({
            "__test_phase6_os_initial_capacity",
            "__test_phase6_os_buffer_fault",
            "__test_phase6_os_allocations",
            "__test_phase6_os_result_attempts",
            "__test_phase6_os_last_grow_from",
            "__test_phase6_has_active_runtime",
        }) do
            assert.match(hook, variant, 1, true)
        end
        assert.match("status = libuv.uv_cwd%(bytes.data, sizes%)", variant)
        assert.match("titan_uvshim_error_enosys", variant, 1, true)
        assert.falsy(variant:find("getcwd(", 1, true))
        assert.falsy(variant:find("lpeg", 1, true))
    end)

    it("retries saturation and rejects invalid growth or unsupported results",
    function()
        local script = phase6.repo ..
            "/spec/fixtures/uv/phase6/os_helper_fault_runtime.lua"
        local command = phase6.variant_lua_command(
            workspace, script, envname)
        local ok, status, output = phase6.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase6 OS helper faults passed",
            output, 1, true)
    end)
end)
