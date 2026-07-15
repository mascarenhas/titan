local async_stdlib = require "spec.support.async_stdlib"

local host_pipe = assert(io.popen("uname -s"))
local host = assert(host_pipe:read("*l"))
assert(host_pipe:close())

local SOURCES = {
    async_bootstrap = [[
        local uv = import "uv"
        local timer = import "timer"

        function main(args: {string}): integer
          local child = uv.run(function (): value
            timer.sleep(0)
            return 17
          end)
          return child:join() as integer
        end
    ]],
    sync_main = [[
        function main(args: {string}): integer
          return 19
        end
    ]],
    unobserved_failure = [[
        local uv = import "uv"

        local function unobserved_origin(): value
          raise "uv-task-unobserved-boom"
          return nil
        end

        function main(args: {string}): integer
          uv.run(unobserved_origin)
          return 0
        end
    ]],
    unobserved_cancel = [[
        local uv = import "uv"
        local timer = import "timer"

        function main(args: {string}): integer
          local task = uv.run(function (): value
            timer.sleep(1000)
            return nil
          end)
          task:cancel("not-session-fatal")
          return 0
        end
    ]],
    cancelled_observer = [[
        local uv = import "uv"
        local timer = import "timer"

        function main(args: {string}): integer
          local target = uv.run(function (): value
            timer.sleep(8)
            raise "failure-after-observer-cancel"
            return nil
          end)
          local observer = uv.run(function (): value
            do target:join() catch return nil end
            return nil
          end)
          uv.run(function (): value
            timer.sleep(1)
            observer:cancel("observer-left")
            return nil
          end)
          return 0
        end
    ]],
    timer_only_bootstrap = [[
        -- Transitive bootstrap proof: this application never directly imports uv.
        local timer = import "timer"

        function main(args: {string}): integer
          timer.sleep(0)
          return 0
        end
    ]],
    main_child = [[
        local fs = import "fs"
        local timer = import "timer"
        local uv = import "uv"

        function main(args: {string}): integer
          local marker = args[1]
          uv.run(function (): value
            timer.sleep(10)
            fs.write_file(marker, "independent-child-finished")
            return nil
          end)
          -- The async bootstrap must keep driving the independent child even
          -- though its main Task has already returned this result.
          return 0
        end
    ]],
}

describe("uv standalone bootstrap", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("bootstrap")
        for modname, source in pairs(SOURCES) do
            async_stdlib.write_source(workspace, modname, source)
            async_stdlib.compile(workspace, modname)
        end
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("selects async bootstrap while retaining the synchronous direct path",
    function()
        local _, async_status, async_output =
            async_stdlib.run_app(workspace, "async_bootstrap")
        assert.equals(17, async_status, async_output)

        local _, sync_status, sync_output =
            async_stdlib.run_app(workspace, "sync_main")
        assert.equals(19, sync_status, sync_output)
    end)

    it("promotes an unobserved failure with its task/propagation trace", function()
        local ok, status, output =
            async_stdlib.run_app(workspace, "unobserved_failure")
        assert.falsy(ok)
        assert.equals(1, status)
        assert.match("uv%-task%-unobserved%-boom", output)
        assert.match("stack traceback:", output, 1, true)
        assert.match("in unobserved_failure.unobserved_origin", output, 1, true)
        if host == "Darwin" then
            -- LuaRocks installs the stdlib Mach-O images but not their companion
            -- dSYM bundles. When an earlier spec has removed the build-tree
            -- images, libbacktrace still preserves the exact task trace but the
            -- outer installed uv frame can only be rendered as a C frame.
            assert.truthy(output:find("in titan.uv.bootstrap", 1, true) or
                          output:find("[C]: in ?", 1, true), output)
        else
            assert.match("in titan.uv.bootstrap", output, 1, true)
        end
    end)

    it("does not promote an unjoined cancelled non-main Task", function()
        local ok, status, output =
            async_stdlib.run_app(workspace, "unobserved_cancel")
        assert.truthy(ok, output)
        assert.equals(0, status)
    end)

    it("installs the bootstrap through a transitive timer-only import",
    function()
        local ok, status, output =
            async_stdlib.run_app(workspace, "timer_only_bootstrap")
        assert.truthy(ok, output)
        assert.equals(0, status)
    end)

    it("drives an independent child after standalone main returns", function()
        local marker = workspace .. "/main-child.marker"
        local ok, status, output =
            async_stdlib.run_app(workspace, "main_child", marker)
        assert.truthy(ok, output)
        assert.equals(0, status, output)
        assert.equals("independent-child-finished", async_stdlib.read(marker))
    end)

    it("revokes observation when a joining Task is cancelled", function()
        local ok, status, output =
            async_stdlib.run_app(workspace, "cancelled_observer")
        assert.falsy(ok)
        assert.equals(1, status)
        assert.match("failure%-after%-observer%-cancel", output)
        assert.match("stack traceback:", output, 1, true)
    end)
end)
