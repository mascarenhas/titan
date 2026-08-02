local async_stdlib = require "spec.support.async_stdlib"

local SOURCES = {
    async_main = [[
        local timer = import "timer"

        function main(args: {string}): integer
          timer.sleep(0)
          timer.yield()
          return 17
        end
    ]],

    sync_main = [[
        function main(args: {string}): integer
          return 19
        end
    ]],

    bootstrap_args = [[
        -- A transitive timer import is enough to install the async bootstrap.
        local timer = import "timer"

        function main(args: {string}): integer
          timer.sleep(0)
          if args[0] or args[-1] then return 30 end
          if #args == 0 then return 0 end
          if #args ~= 2 then return 31 end
          if args[1] ~= "one" or args[2] ~= "two" then return 32 end
          return 0
        end
    ]],

    isolated_failure = [[
        local async = import "async"
        local fs = import "fs"
        local timer = import "timer"

        local function unhandled_origin(): value
          timer.sleep(0)
          raise "isolated-child-boom"
          return nil
        end

        function main(args: {string}): integer
          local marker = args[1]
          async.run(unhandled_origin)
          async.run(function (): value
            -- This must still run after both main and its failing sibling end.
            timer.sleep(10)
            fs.write_file(marker, "healthy-sibling-finished")
            return nil
          end)
          return 0
        end
    ]],

    main_failure = [[
        local async = import "async"
        local fs = import "fs"
        local timer = import "timer"

        local function main_origin(): integer
          timer.sleep(0)
          raise "main-task-boom"
          return 99
        end

        function main(args: {string}): integer
          local marker = args[1]
          async.run(function (): value
            timer.sleep(10)
            fs.write_file(marker, "healthy-child-after-main-failure")
            return nil
          end)
          return main_origin()
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

    it("drives an async main while preserving the synchronous entry path",
    function()
        local _, async_status, async_output =
            async_stdlib.run_app(workspace, "async_main")
        assert.equals(17, async_status, async_output)

        local _, sync_status, sync_output =
            async_stdlib.run_app(workspace, "sync_main")
        assert.equals(19, sync_status, sync_output)
    end)

    it("passes only positive program arguments through a transitive bootstrap",
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

    it("logs an uncaught child error without stopping healthy Tasks", function()
        local marker = workspace .. "/healthy.marker"
        local ok, status, output =
            async_stdlib.run_app(workspace, "isolated_failure", marker)

        assert.truthy(ok, output)
        assert.equals(0, status, output)
        assert.match("uncaught error in async Task:", output, 1, true)
        assert.match("isolated-child-boom", output, 1, true)
        assert.match("stack traceback:", output, 1, true)
        assert.match("in isolated_failure.unhandled_origin", output, 1, true)
        assert.equals("healthy-sibling-finished", async_stdlib.read(marker))
    end)

    it("finishes healthy children before a failed main returns status one",
    function()
        local marker = workspace .. "/main-failure.marker"
        local ok, status, output =
            async_stdlib.run_app(workspace, "main_failure", marker)

        assert.falsy(ok)
        assert.equals(1, status, output)
        assert.match("main-task-boom", output, 1, true)
        assert.match("stack traceback:", output, 1, true)
        assert.match("in main_failure.main_origin", output, 1, true)
        assert.equals("healthy-child-after-main-failure",
            async_stdlib.read(marker))
    end)
end)
