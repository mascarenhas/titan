local async_stdlib = require "spec.support.async_stdlib"

local RESOURCE_CASES = [[
    local async = import "async"
    local fs = import "fs"
    local timer = import "timer"

    local retained_file: fs.File? = nil
    local retained_ticker: timer.Ticker? = nil

    function schedule(file_path: string)
      async.run(function (): value
        retained_file = fs.open(file_path, "w")
        local file = retained_file as fs.File
        file:write("left-open-for-host-teardown")

        -- A File owns an OS descriptor, not a loop handle. Keeping the wrapper
        -- reachable proves Runtime cleanup does not turn it terminal.

        -- A ticker is a plain uv handle, so it is intentionally left for the
        -- Runtime's uv_walk shutdown pass rather than a Titan-side registry.
        retained_ticker = timer.ticker(60000)
        return nil
      end)
    end

    function file_was_closed(): boolean
      local file = retained_file as fs.File
      return file:is_closed()
    end

    function close_outside_runtime(): string
      local file = retained_file as fs.File
      do
        file:close()
      catch
        return traceback
      end
      return ""
    end

    function finish_file_in_later_runtime()
      async.run(function (): value
        local file = retained_file as fs.File
        file:write("-second-runtime")
        file:close()
        return nil
      end)
    end
]]

describe("async Runtime native-resource shutdown", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("uv-shutdown")
        async_stdlib.write_source(workspace, "uv_resource_cases",
            RESOURCE_CASES)
        async_stdlib.compile(workspace, "uv_resource_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("keeps an open file descriptor usable in a later Runtime", function()
        local file_path = workspace .. "/cross-runtime-file.txt"
        local source = ([=[
            local async = require "titan.async"
            local resources = require "uv_resource_cases"

            resources.schedule(%q)
            async.loop()
            assert(not resources.file_was_closed())

            local traceback = resources.close_outside_runtime()
            assert(traceback:match(
                "file%%.titan:%%d+: in titan%%.uv%%.fs_close"),
                traceback)
            assert(not resources.file_was_closed())

            resources.finish_file_in_later_runtime()
            async.loop()
            assert(resources.file_was_closed())
        ]=]):format(file_path)

        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals("left-open-for-host-teardown-second-runtime",
            async_stdlib.read(file_path))
    end)
end)
