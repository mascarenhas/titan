local async_stdlib = require "spec.support.async_stdlib"

local host_pipe = assert(io.popen("uname -s"))
local host = assert(host_pipe:read("*l"))
assert(host_pipe:close())

local SOURCES = {
    async_bootstrap = [[
        local async = import "async"
        local timer = import "timer"

        function main(args: {string}): integer
          local child = async.run(function (): value
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
        local async = import "async"

        local function unobserved_origin(): value
          raise "uv-task-unobserved-boom"
          return nil
        end

        function main(args: {string}): integer
          async.run(unobserved_origin)
          return 0
        end
    ]],
    unobserved_cancel = [[
        local async = import "async"
        local timer = import "timer"

        function main(args: {string}): integer
          local task = async.run(function (): value
            timer.sleep(1000)
            return nil
          end)
          task:cancel("not-session-fatal")
          return 0
        end
    ]],
    cancelled_observer = [[
        local async = import "async"
        local timer = import "timer"

        function main(args: {string}): integer
          local target = async.run(function (): value
            timer.sleep(8)
            raise "failure-after-observer-cancel"
            return nil
          end)
          local observer = async.run(function (): value
            do target:join() catch return nil end
            return nil
          end)
          async.run(function (): value
            timer.sleep(1)
            observer:cancel("observer-left")
            return nil
          end)
          return 0
        end
    ]],
    timer_only_bootstrap = [[
        -- Transitive bootstrap proof: this application never directly imports async.
        local timer = import "timer"

        function main(args: {string}): integer
          timer.sleep(0)
          return 0
        end
    ]],
    bootstrap_args = [[
        local timer = import "timer"

        function main(args: {string}): integer
          timer.sleep(0)
          if args[0] then return 30 end
          if args[-1] then return 31 end
          if #args == 0 then return 0 end
          if #args ~= 2 then return 32 end
          if args[1] ~= "one" then return 33 end
          if args[2] ~= "two" then return 34 end
          return 0
        end
    ]],
    main_child = [[
        local fs = import "fs"
        local timer = import "timer"
        local async = import "async"

        function main(args: {string}): integer
          local marker = args[1]
          async.run(function (): value
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

describe("async standalone bootstrap", function()
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

    it("passes only positive arguments through the bootstrap boundary",
    function()
        local empty_ok, empty_status, empty_output =
            async_stdlib.run_app(workspace, "bootstrap_args")
        assert.truthy(empty_ok, empty_output)
        assert.equals(0, empty_status, empty_output)

        local ok, status, output =
            async_stdlib.run_app(workspace, "bootstrap_args", "one", "two")
        assert.truthy(ok, output)
        assert.equals(0, status, output)
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
