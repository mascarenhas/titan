local phase2 = require "spec.support.phase2"

describe("uv Phase 2 continuation pump", function()
    local workspace

    setup(function()
        workspace = phase2.workspace("uv")
        phase2.copy_fixture(workspace, "behavior.titan", "phase2_behavior")
        phase2.copy_fixture(workspace, "cancellation.titan",
            "phase2_cancellation")
        phase2.compile(workspace, "phase2_behavior")
        phase2.compile(workspace, "phase2_cancellation")
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    local function run_scenario(name)
        local command = phase2.lua_command(workspace,
            phase2.repo .. "/spec/fixtures/uv/phase2/runtime.lua", name)
        return phase2.run(command, workspace)
    end

    it("runs nonblocking/nested roots, shared-tag nesting, A-to-B handoff, " ..
       "out-of-order timers, observation, and child-loop rejection", function()
        local ok, status, output = run_scenario("scheduler")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase2 scheduler passed", output, 1, true)
    end)

    it("preserves a first, sticky cancellation reason", function()
        local ok, status, output = run_scenario("cancellation")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase2 cancellation passed", output, 1, true)
    end)

    it("reports a cyclic Task join as an idle-loop deadlock", function()
        local ok, status, output = run_scenario("join-cycle")
        assert.falsy(ok, output)
        assert.not_equals(0, status)
        assert.match("libuv loop became idle while Tasks were waiting", output,
            1, true)
    end)

    it("roots dropped Tasks through generational GC and closes sequential loops",
    function()
        local ok, status, output = run_scenario("sequential-gc")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase2 sequential GC sessions passed", output,
            1, true)
    end)

end)
