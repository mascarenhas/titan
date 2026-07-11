local phase3 = require "spec.support.phase3"

describe("fs Phase 3 runtime", function()
    local workspace
    local root

    setup(function()
        workspace, root = phase3.workspace("runtime")
        phase3.copy_fixture(workspace, "fs_cases.titan", "phase3_fs_cases")
        phase3.compile(workspace, "phase3_fs_cases")
    end)

    teardown(function()
        phase3.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = phase3.repo .. "/spec/fixtures/uv/phase3/fs_runtime.lua"
        return phase3.run(phase3.lua_command(workspace, script, name, root),
            workspace)
    end

    it("covers modes, binary/NUL data, EOF/short reads, stat symlinks, " ..
       "permission errors, and paths",
    function()
        local ok, status, output = run_scenario("core")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase3 fs core passed", output, 1, true)
    end)

    it("serializes each File FIFO and makes close immediate and idempotent",
    function()
        local ok, status, output = run_scenario("fifo")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase3 fs fifo passed", output, 1, true)
    end)

    it("roots pending files, releases closed owners, and resets sessions",
    function()
        local ok, status, output = run_scenario("gc-sequential")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase3 fs GC and sequential sessions passed",
            output, 1, true)
    end)
end)
