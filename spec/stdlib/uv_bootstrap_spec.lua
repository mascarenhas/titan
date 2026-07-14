local async_stdlib = require "spec.support.async_stdlib"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local host_pipe = assert(io.popen("uname -s"))
local host = assert(host_pipe:read("*l"))
assert(host_pipe:close())

describe("uv standalone bootstrap", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("bootstrap")
        for _, fixture in ipairs({
            "async_bootstrap", "sync_main", "unobserved_failure",
            "unobserved_cancel", "cancelled_observer",
            "timer_only_bootstrap", "main_child",
        }) do
            async_stdlib.copy_fixture(workspace,
                "uv/bootstrap/" .. fixture .. ".titan", fixture)
            async_stdlib.compile(workspace, fixture)
        end
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("selects async bootstrap while retaining the synchronous direct path",
    function()
        local _, async_status, async_output = async_stdlib.run(
            async_stdlib.app_command(workspace, "async_bootstrap"), workspace)
        assert.equals(17, async_status, async_output)

        local _, sync_status, sync_output = async_stdlib.run(
            async_stdlib.app_command(workspace, "sync_main"), workspace)
        assert.equals(19, sync_status, sync_output)
    end)

    it("promotes an unobserved failure with its task/propagation trace", function()
        local ok, status, output = async_stdlib.run(
            async_stdlib.app_command(workspace, "unobserved_failure"), workspace)
        assert.falsy(ok)
        assert.equals(1, status)
        assert.match("uv%-task%-unobserved%-boom", output)
        assert.match("stack traceback:", output, 1, true)
        assert.match("in unobserved_failure.unobserved_origin", output, 1, true)
        if host == "Darwin" then
            -- LuaRocks installs the stdlib Mach-O images but not their companion
            -- dSYM bundles.  When an earlier spec has removed the build-tree
            -- images, libbacktrace still preserves the exact task trace but the
            -- outer installed uv frame can only be rendered as a C frame.
            assert.truthy(output:find("in titan.uv.bootstrap", 1, true) or
                          output:find("[C]: in ?", 1, true), output)
        else
            assert.match("in titan.uv.bootstrap", output, 1, true)
        end
    end)

    it("does not promote an unjoined cancelled non-main Task", function()
        local ok, status, output = async_stdlib.run(
            async_stdlib.app_command(workspace, "unobserved_cancel"), workspace)
        assert.truthy(ok, output)
        assert.equals(0, status)
    end)

    it("installs the bootstrap through a transitive timer-only import",
    function()
        local ok, status, output = async_stdlib.run(
            async_stdlib.app_command(workspace, "timer_only_bootstrap"), workspace)
        assert.truthy(ok, output)
        assert.equals(0, status)
    end)

    it("drives an independent child after standalone main returns", function()
        local marker = workspace .. "/main-child.marker"
        local command = async_stdlib.app_command(workspace, "main_child") ..
            " " .. quote(marker)
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, output)
        assert.equals(0, status, output)
        assert.equals("independent-child-finished", async_stdlib.read(marker))
    end)

    it("revokes observation when a joining Task is cancelled", function()
        local ok, status, output = async_stdlib.run(
            async_stdlib.app_command(workspace, "cancelled_observer"), workspace)
        assert.falsy(ok)
        assert.equals(1, status)
        assert.match("failure%-after%-observer%-cancel", output)
        assert.match("stack traceback:", output, 1, true)
    end)
end)
