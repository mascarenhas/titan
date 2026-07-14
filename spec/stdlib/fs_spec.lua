local fs_support = require "spec.support.fs_test_support"

describe("fs runtime", function()
    local workspace
    local root

    setup(function()
        workspace, root = fs_support.workspace("runtime")
        fs_support.copy_fixture(workspace, "cases.titan", "fs_cases")
        fs_support.compile(workspace, "fs_cases")
    end)

    teardown(function()
        fs_support.cleanup(workspace)
    end)

    local function run_scenario(name)
        local script = fs_support.repo ..
            "/spec/fixtures/stdlib/fs/runtime.lua"
        return fs_support.run(fs_support.lua_command(workspace, script, name, root),
            workspace)
    end

    it("covers modes, binary/NUL data, EOF/short reads, stat symlinks, " ..
       "permission errors, and paths",
    function()
        local ok, status, output = run_scenario("core")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT fs core passed", output, 1, true)
    end)

    it("serializes each File FIFO and makes close immediate and idempotent",
    function()
        local ok, status, output = run_scenario("fifo")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT fs FIFO passed", output, 1, true)
    end)

    it("roots pending files, releases closed owners, and resets sessions",
    function()
        local ok, status, output = run_scenario("gc-sequential")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT fs GC and sequential sessions passed",
            output, 1, true)
    end)
end)
