local fs_support = require "spec.support.fs_test_support"

local LATE_FS_CASES = [[
    -- Runs only against the generated delayed-FS callback uv variant.
    local lua = foreign import "lua.h"
    local fs = import "fs"
    local timer = import "timer"
    local uv = import "uv"

    record YoungReason
      marker: string
    end

    local fs_result_delivered = false
    local fs_open_result_delivered = false

    local function check(condition: boolean, message: string)
      if not condition then raise message end
    end

    local function schedule_buffer_write(file: fs.File,
                                         payload: string): uv.Task
      return uv.run(function (): value
        return file:write(payload)
      end)
    end

    function schedule_cross_generation_graph(root: string): uv.Task
      return uv.run(function (): value
        local file = fs.open(root .. "/cross-generation.dat", "w")
        local ticker = timer.ticker(1000)
        local old_error_task = uv.run(function (): value
          timer.sleep(80)
          do
            fs.stat(root .. "/missing-cross-generation-target")
          catch
            local failure = error as uv.Error
            check(failure.operation == "fs.stat" and failure.code < 0,
                  "old Task received the wrong young uv.Error")
            lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
            check(failure.operation == "fs.stat" and failure.code < 0,
                  "young uv.Error was lost across a minor collection")
            return "young-error-ok"
          end
          raise "missing stat unexpectedly succeeded"
          return nil
        end)

        while old_error_task:status() == "ready" do timer.yield() end
        check(old_error_task:status() == "waiting",
              "error Task did not arm before Runtime aging")

        -- Age the Runtime, parent/error Tasks, recurring timer owner, File, and
        -- sleeping owner before attaching a young continuation and write buffer.
        lua.lua_gc(L, lua.LUA_GCGEN)
        lua.lua_gc(L, lua.LUA_GCCOLLECT)
        uv.__test_delay_next_fs_callback(30)

        local payload: string? =
            "young-buffer:" .. root .. ":shared-tag-continuation"
        local expected_length = #(payload as string)
        local writer = schedule_buffer_write(file, payload as string)
        payload = nil

        while not uv.__test_fs_callback_is_delayed() do
          timer.yield()
        end
        lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
        check((writer:join() as integer) == expected_length,
              "young shared-tag writer returned the wrong byte count")
        check(old_error_task:join() == "young-error-ok",
              "old Task did not retain its young uv.Error")

        ticker:close()
        file:close()
        return "cross-generation-graph-ok"
      end)
    end

    function schedule_late_fs_cancellation(path: string): uv.Task
      fs_result_delivered = false
      uv.__test_delay_next_fs_callback(40)

      local target = uv.run(function (): value
        fs.stat(path)
        fs_result_delivered = true
        return "late-result-must-not-win"
      end)

      local canceller = uv.run(function (): value
        while not uv.__test_fs_callback_is_delayed() do
          timer.yield()
        end

        -- Libuv completed the request, but logical callback delivery is delayed.
        -- Store a young cancellation reason through the old Task before delivery.
        lua.lua_gc(L, lua.LUA_GCGEN)
        lua.lua_gc(L, lua.LUA_GCCOLLECT)
        local reason: YoungReason? =
            YoungReason.new("young-cross-generation-cancel")
        target:cancel(reason)
        reason = nil
        lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
        return nil
      end)

      return uv.run(function (): value
        canceller:join()
        local caught = false
        do
          target:join()
        catch
          local cancelled = error as uv.Cancelled
          local reason = cancelled.reason as YoungReason
          check(reason.marker == "young-cross-generation-cancel",
                "young cancellation reason was not retained by the old Task")
          caught = true
        end
        check(caught and target:status() == "cancelled",
              "late filesystem cancellation did not win logically")

        timer.sleep(50)
        check(not fs_result_delivered,
              "late filesystem result resumed a cancelled Task")
        return "late-fs-cancellation-ok"
      end)
    end

    function schedule_late_open_cancellation(path: string): uv.Task
      fs_open_result_delivered = false
      uv.__test_delay_next_fs_callback(40)

      local target = uv.run(function (): value
        local file = fs.open(path, "w")
        fs_open_result_delivered = true
        file:close()
        return "late-open-result-must-not-win"
      end)

      local canceller = uv.run(function (): value
        while not uv.__test_fs_callback_is_delayed() do
          timer.yield()
        end
        target:cancel("late-successful-open-cancel")
        return nil
      end)

      return uv.run(function (): value
        canceller:join()
        local caught = false
        do
          target:join()
        catch
          local cancelled = error as uv.Cancelled
          check(cancelled.reason == "late-successful-open-cancel",
                "late successful-open cancellation reason changed")
          caught = true
        end
        check(caught and target:status() == "cancelled",
              "late successful-open cancellation did not win logically")

        -- Keep the public Runtime alive long enough to drain the delayed open
        -- and its asynchronous descriptor disposal.
        timer.sleep(50)
        check(not fs_open_result_delivered,
              "cancelled successful open published a File")
        return "late-successful-open-cancellation-ok"
      end)
    end
]]

-- This is the one isolated source variant retained for late filesystem
-- callbacks whose timing cannot be controlled through the public API.
describe("uv late filesystem callbacks", function()
    local workspace
    local root

    setup(function()
        workspace, root = fs_support.variant_workspace(
            "spec/support/make_delayed_fs_callback_variant.lua")
        fs_support.write_source(workspace, "uv_late_fs_callback_cases",
            LATE_FS_CASES)
        fs_support.compile(workspace, "uv_late_fs_callback_cases", {
            stdlib = workspace .. "/titan",
        })
    end)

    teardown(function() fs_support.cleanup(workspace) end)

    local function run(source)
        local ok, status, output = fs_support.run_lua_source(workspace, source, {
            stdlib = workspace .. "/titan",
        })
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("roots a cross-generation Runtime/File/Task/buffer/error graph", function()
        run(string.format([==[
            local root = %q
            local uv = require "titan.uv"
            local cases = require "uv_late_fs_callback_cases"
            local task = cases.schedule_cross_generation_graph(root)
            uv.loop()
            assert(task:join() == "cross-generation-graph-ok")
        ]==], root))
    end)

    it("lets cancellation win over a delayed filesystem result", function()
        run(string.format([==[
            local root = %q
            local uv = require "titan.uv"
            local cases = require "uv_late_fs_callback_cases"
            local task = cases.schedule_late_fs_cancellation(root)
            uv.loop()
            assert(task:join() == "late-fs-cancellation-ok")
        ]==], root))
    end)

    it("disposes a delayed successful open after cancellation", function()
        run(string.format([==[
            local root = %q
            local uv = require "titan.uv"
            local cases = require "uv_late_fs_callback_cases"
            local path = root .. "/late-cancelled-open.dat"
            local task = cases.schedule_late_open_cancellation(path)
            uv.loop()
            assert(task:join() == "late-successful-open-cancellation-ok")
            assert(os.remove(path))

            -- A fresh public session proves the cancelled-open File and request
            -- roots were fully retired without inspecting private Runtime lists.
            local next_session = uv.run(function()
                return "next-session-ok"
            end)
            uv.loop()
            assert(next_session:join() == "next-session-ok")
        ]==], root))
    end)
end)
