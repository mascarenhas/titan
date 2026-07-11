local phase2 = require "spec.support.phase2"

local host_pipe = assert(io.popen("uname -s"))
local host = assert(host_pipe:read("*l"))
assert(host_pipe:close())

describe("uv Phase 2 standalone bootstrap", function()
    local workspace

    setup(function()
        workspace = phase2.workspace("bootstrap")
        for _, fixture in ipairs({
            "async_bootstrap", "sync_main", "unobserved_failure",
            "unobserved_cancel", "cancelled_observer",
            "timer_only_bootstrap",
        }) do
            phase2.copy_fixture(workspace, fixture .. ".titan", fixture)
            phase2.compile(workspace, fixture)
        end
    end)

    teardown(function() phase2.cleanup(workspace) end)

    it("selects async bootstrap while retaining the synchronous direct path",
    function()
        local _, async_status, async_output = phase2.run(
            phase2.app_command(workspace, "async_bootstrap"), workspace)
        assert.equals(17, async_status, async_output)

        local _, sync_status, sync_output = phase2.run(
            phase2.app_command(workspace, "sync_main"), workspace)
        assert.equals(19, sync_status, sync_output)
        local entry = phase2.read(workspace .. "/sync_main__entrypoint.c")
        assert.match("TITAN_MAIN_BOOTSTRAP_KEY", entry, 1, true)
        -- No uv import means the registry hook is absent and this branch calls
        -- the already retrieved main function directly.
        assert.match("lua_call%(L, 1, 1%)", entry)
    end)

    it("promotes an unobserved failure with its task/propagation trace", function()
        local ok, status, output = phase2.run(
            phase2.app_command(workspace, "unobserved_failure"), workspace)
        assert.falsy(ok)
        assert.equals(1, status)
        assert.match("phase2%-unobserved%-boom", output)
        assert.match("stack traceback:", output, 1, true)
        assert.match("in unobserved_failure.unobserved_origin", output, 1, true)
        if host == "Darwin" then
            -- LuaRocks installs the stdlib Mach-O images but not their companion
            -- dSYM bundles.  When an earlier spec has removed the build-tree
            -- images, libbacktrace still preserves the exact task trace but the
            -- outer installed uv frame can only be rendered as a C frame.
            assert.truthy(output:find("in uv.bootstrap", 1, true) or
                          output:find("[C]: in ?", 1, true), output)
        else
            assert.match("in uv.bootstrap", output, 1, true)
        end
    end)

    it("does not promote an unjoined cancelled non-main Task", function()
        local ok, status, output = phase2.run(
            phase2.app_command(workspace, "unobserved_cancel"), workspace)
        assert.truthy(ok, output)
        assert.equals(0, status)
    end)

    it("installs the bootstrap through a transitive timer-only import",
    function()
        local ok, status, output = phase2.run(
            phase2.app_command(workspace, "timer_only_bootstrap"), workspace)
        assert.truthy(ok, output)
        assert.equals(0, status)
        local entry = phase2.read(
            workspace .. "/timer_only_bootstrap__entrypoint.c")
        assert.match("TITAN_MAIN_BOOTSTRAP_KEY", entry, 1, true)
    end)

    it("revokes observation when a joining Task is cancelled", function()
        local ok, status, output = phase2.run(
            phase2.app_command(workspace, "cancelled_observer"), workspace)
        assert.falsy(ok)
        assert.equals(1, status)
        assert.match("failure%-after%-observer%-cancel", output)
        assert.match("stack traceback:", output, 1, true)
    end)
end)
