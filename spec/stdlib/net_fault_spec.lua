local phase5 = require "spec.support.phase5"

describe("net Phase 5 transitions and faults", function()
    local workspace

    setup(function()
        workspace = phase5.variant_workspace(
            "spec/support/make_phase5_test_variant.lua")
        phase5.copy_fixture(workspace, "net_faults.titan",
            "phase5_net_faults")
        phase5.compile(workspace, "phase5_net_faults", {
            stdlib = workspace .. "/titan",
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

    local function quote(value)
        return "'" .. value:gsub("'", "'\\''") .. "'"
    end

    local function run_dispatch_scenario(name)
        local script = phase5.repo ..
            "/spec/fixtures/uv/phase5/net_dispatch_fault_runtime.lua"
        local application = phase5.variant_lua_command(workspace, script,
            workspace .. "/phase5_net_faults.so", name)
        local watchdog = application ..
            " & pid=$!; " ..
            "(sleep 15; kill -TERM $pid 2>/dev/null) " ..
            "</dev/null >/dev/null 2>&1 & guard=$!; " ..
            "wait $pid; status=$?; kill $guard 2>/dev/null; exit $status"
        return phase5.run("sh -c " .. quote(watchdog), workspace)
    end

    it("keeps deterministic DNS race controls isolated and fail-closed",
       function()
        local production = phase5.read("titan/uv.titan")
        local variant = phase5.read(workspace .. "/titan/uv.titan")
        for _, hook in ipairs({
            "__test_phase5_cancel_next_dns_inflight",
            "__test_phase5_delay_next_dns_callback",
            "__test_phase5_dns_cancel_calls",
            "__test_phase5_dns_cancel_status",
            "__test_phase5_dns_nonnull_results",
            "__test_phase5_runtime_active",
            "__test_phase5_fail_next_dispatch",
            "__test_phase5_dispatch_fault_hits",
            "__test_phase5_net_retires",
            "__test_phase5_tcp_unlinks",
        }) do
            assert.falsy(production:find(hook, 1, true))
            assert.truthy(variant:find("function " .. hook, 1, true))
        end
        assert.truthy(variant:find(
            "shim.titan_uvshim_getaddrinfo_cancel(dns.handle)", 1, true))
    end)

    for _, case in ipairs({
        { "schedule_dispatch_dns_after_free",
          "repairs DNS after borrowed-result release" },
        { "schedule_dispatch_unpublished_connect",
          "repairs an unpublished connect callback" },
        { "schedule_dispatch_published_write",
          "repairs a published stream write callback" },
        { "schedule_dispatch_tcp_read",
          "repairs a TCP read after buffer-root release" },
        { "schedule_dispatch_tcp_close",
          "repairs a terminal TCP close callback" },
    }) do
        it(case[2], function()
            local ok, status, output = run_dispatch_scenario(case[1])
            assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
            assert.equals(0, status, output)
            assert.match("RESULT Phase 5 dispatcher repair passed", output,
                1, true)
        end)
    end

    for _, case in ipairs({
        { "schedule_dns_failure_and_cleanup", "DNS result cleanup" },
        { "schedule_inflight_dns_cancel_success",
          "successful in-flight DNS cancellation" },
        { "schedule_late_dns_cancel_failure",
          "too-late DNS cancellation and addrinfo cleanup" },
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
