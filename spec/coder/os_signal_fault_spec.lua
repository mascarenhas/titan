local phase6 = require "spec.support.phase6"

local function transform_only()
    local output = os.tmpname() .. "-titan-phase6-transform.titan"
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

describe("os Phase 6 signal transition faults", function()
    local workspace

    it("composes Phase 5 and inserts fail-closed signal controls", function()
        local production = phase6.read("stdlib/uv.titan")
        assert.falsy(production:find("__test_phase6_", 1, true))
        local variant = transform_only()
        assert.match("__test_phase5_reset_counters", variant, 1, true)
        for _, hook in ipairs({
            "__test_phase6_send_signal",
            "__test_phase6_force_signal_rejection",
            "__test_phase6_fail_next_signal_callback",
            "__test_phase6_fail_next_signal_close_callback",
            "__test_phase6_signal_resources",
        }) do
            assert.match(hook, variant, 1, true)
        end
        assert.match("libuv.uv_kill%(libuv.uv_os_getpid%(%)", variant)
        assert.falsy(variant:find("posix.kill", 1, true))
        assert.falsy(variant:find("os.execute", 1, true))
        assert.falsy(variant:find("lpeg", 1, true))
    end)

    describe("native callback and rejection scenarios", function()
        setup(function()
            workspace = phase6.workspace()
            phase6.copy_fixture(workspace, "signal_faults.titan",
                "phase6_signal_faults")
            phase6.compile(workspace, "phase6_signal_faults", {
                stdlib = workspace,
            })
        end)

        teardown(function()
            phase6.cleanup(workspace)
        end)

        for _, scenario in ipairs({
            "init", "start", "callback", "close", "shutdown",
        }) do
            it("drains the " .. scenario .. " signal transition", function()
                local script = phase6.repo ..
                    "/spec/fixtures/uv/phase6/signal_fault_runtime.lua"
                local command = phase6.variant_lua_command(
                    workspace, script, scenario)
                local ok, status, output = phase6.run(command, workspace)
                assert.truthy(ok,
                    "exit " .. tostring(status) .. "\n" .. output)
                assert.equals(0, status, output)
                assert.match("RESULT phase6 signal fault passed: " ..
                    scenario, output, 1, true)
            end)
        end
    end)
end)
