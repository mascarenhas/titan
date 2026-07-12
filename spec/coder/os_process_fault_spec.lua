local phase6 = require "spec.support.phase6"

local function transform_only()
    local output = os.tmpname() .. "-titan-phase6-process-transform.titan"
    local lua = phase6.repo .. "/.lua/bin/lua"
    local probe = io.open(lua, "rb")
    if probe then
        probe:close()
    else
        lua = phase6.repo .. "/lua"
    end
    local command = table.concat({
        "'" .. lua .. "'",
        "'" .. phase6.repo ..
            "/spec/support/make_phase6_test_variant.lua'",
        "'" .. phase6.repo .. "/stdlib/uv.titan'",
        "'" .. output .. "'",
    }, " ")
    local ok, _, message = phase6.run(command, phase6.repo)
    assert.truthy(ok, message)
    local source = phase6.read(output)
    os.remove(output)
    return source
end

describe("os Phase 6 process transition faults", function()
    local workspace
    local child

    it("keeps process fault controls isolated from production", function()
        local production = phase6.read("stdlib/uv.titan")
        assert.falsy(production:find("__test_phase6_process_", 1, true))
        local variant = transform_only()
        assert.match("__test_phase5_reset_counters", variant, 1, true)
        local hooks = {
            "__test_phase6_force_process_failure",
            "__test_phase6_fail_next_process_callback",
            "__test_phase6_track_next_process_write_inflight",
            "__test_phase6_inflight_process_write_observed",
            "__test_phase6_inflight_process_write_roots_alive",
            "__test_phase6_inflight_process_write_roots_released",
            "__test_phase6_process_counter",
            "__test_phase6_process_resources",
            "__test_phase6_process_requests",
            "__test_phase6_process_live_helpers",
        }
        for _, hook in ipairs(hooks) do
            assert.falsy(production:find(hook, 1, true))
            assert.match(hook, variant, 1, true)
        end
        local marker = assert(variant:find(
            "-- TITAN_UV_PHASE6_PROCESS_WRITE_SUBMIT", 1, true))
        local native = assert(variant:find(
            "status = shim.titan_uvshim_pipe_write_start(", marker, true))
        local observe = assert(variant:find(
            "test_phase6_weak_process_write_store(1, owner)", native, true))
        local observed = assert(variant:find(
            "test_phase6_inflight_write_observed = true", observe, true))
        local continuation = assert(variant:find(
            "if (status as integer) >= 0 then", observed, true))
        assert.is_true(marker < native and native < observe and
                       observe < observed and observed < continuation)
        assert.falsy(variant:sub(native, continuation):find(
            "request_cancel", 1, true))
        assert.falsy(variant:find("posix.", 1, true))
        assert.falsy(variant:find("os.execute", 1, true))
        assert.falsy(variant:find("lpeg", 1, true))
    end)

    describe("native lifecycle and callback scenarios", function()
        setup(function()
            workspace = phase6.workspace()
            child = phase6.process_child(workspace)
            phase6.copy_fixture(workspace, "process_faults.titan",
                "phase6_process_faults")
            phase6.compile(workspace, "phase6_process_faults", {
                stdlib = workspace,
            })
        end)

        teardown(function()
            phase6.cleanup(workspace)
        end)

        local scenarios = {
            { "setup", "staged stdio/init/open/spawn cleanup" },
            { "missing", "initialized failed-spawn close without exit" },
            { "ordering", "exit-before-close ordering for live children" },
            { "write", "callback-less write rejection" },
            { "inflight-write",
              "in-flight native write cancellation and GC" },
            { "close", "ordered stdin close transition failure" },
            { "callback-exit", "exit callback failure" },
            { "callback-process-close", "process close callback failure" },
            { "callback-pipe-close", "pipe close callback failure" },
            { "callback-pipe-read", "pipe read callback failure" },
            { "callback-write", "write callback failure" },
            { "callback-grace", "TERM grace callback failure" },
            { "communicate-helper", "observed communicate helper failure" },
            { "communicate-start", "observed helper-start failure" },
        }

        for _, item in ipairs(scenarios) do
            it("drains " .. item[2], function()
                local script = phase6.repo ..
                    "/spec/fixtures/uv/phase6/process_fault_runtime.lua"
                local command = phase6.variant_lua_command(
                    workspace, script,
                    workspace .. "/phase6_process_faults.so",
                    item[1], child)
                local ok, status, output = phase6.run(command, workspace)
                assert.truthy(ok,
                    "exit " .. tostring(status) .. "\n" .. output)
                assert.equals(0, status, output)
                assert.match("RESULT phase6", output, 1, true)
            end)
        end
    end)
end)
