local phase5 = require "spec.support.phase5"

describe("net Phase 5 transitions and faults", function()
    local workspace

    setup(function()
        workspace = phase5.variant_workspace(
            "spec/support/make_phase5_test_variant.lua")
        phase5.copy_fixture(workspace, "net_faults.titan",
            "phase5_net_faults")
        phase5.compile(workspace, "phase5_net_faults", {
            stdlib = workspace,
        })
    end)

    teardown(function()
        phase5.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = phase5.repo ..
            "/spec/fixtures/uv/phase5/net_fault_runtime.lua"
        return phase5.run(phase5.variant_lua_command(workspace, script,
            workspace .. "/phase5_net_faults.so", name), workspace)
    end

    for _, case in ipairs({
        { "schedule_dns_failure_and_cleanup", "DNS result cleanup" },
        { "schedule_refused_connect", "failed connect and candidate close" },
        { "schedule_cancelled_connect", "cancelled unpublished connect" },
        { "schedule_inflight_connect_cancel_gc",
          "in-flight connect cancellation and GC" },
        { "schedule_write_gc_and_cancel", "write buffer GC/cancellation" },
        { "schedule_inflight_write_cancel_gc",
          "in-flight write buffer cancellation and GC" },
        { "schedule_sync_setup_rejections",
          "callback-less synchronous setup rejection" },
        { "schedule_sync_stream_rejections",
          "callback-less synchronous stream rejection" },
        { "schedule_shutdown_cancel_after_queue",
          "cleanup-shielded shutdown cancellation" },
        { "schedule_reset_terminal_read", "permanent read error" },
    }) do
        it(case[2], function()
            local ok, status, output = run_scenario(case[1])
            assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
            assert.match("RESULT phase5 net fault passed", output, 1, true)
        end)
    end
end)
