local LATE_FS_CASES = [[
    -- Runs only against the generated delayed-FS callback uv variant.
    local lua = foreign import "lua.h"
    local fs = import "fs"
    local timer = import "timer"
    local uv = import "uv"
    local async = import "async"

    record YoungReason
      marker: string
    end

    local fs_result_delivered = false
    local fs_open_result_delivered = false

    local function check(condition: boolean, message: string)
      if not condition then raise message end
    end

    local function schedule_buffer_write(file: fs.File,
                                         payload: string): async.Task
      return async.run(function (): value
        return file:write(payload)
      end)
    end

    function schedule_cross_generation_graph(root: string): async.Task
      return async.run(function (): value
        local file = fs.open(root .. "/cross-generation.dat", "w")
        local ticker = timer.ticker(1000)
        local old_error_task = async.run(function (): value
          timer.sleep(80)
          do
            fs.stat(root .. "/missing-cross-generation-target")
          catch
            local failure = error as async.Error
            check(failure.operation == "fs.stat" and failure.code < 0,
                  "old Task received the wrong young async.Error")
            lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
            check(failure.operation == "fs.stat" and failure.code < 0,
                  "young async.Error was lost across a minor collection")
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
              "old Task did not retain its young async.Error")

        ticker:close()
        file:close()
        return "cross-generation-graph-ok"
      end)
    end

    function schedule_late_fs_cancellation(path: string): async.Task
      fs_result_delivered = false
      uv.__test_delay_next_fs_callback(40)

      local target = async.run(function (): value
        fs.stat(path)
        fs_result_delivered = true
        return "late-result-must-not-win"
      end)

      local canceller = async.run(function (): value
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

      return async.run(function (): value
        canceller:join()
        local caught = false
        do
          target:join()
        catch
          local cancelled = error as async.Cancelled
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

    function schedule_late_open_cancellation(path: string): async.Task
      fs_open_result_delivered = false
      uv.__test_delay_next_fs_callback(40)

      local target = async.run(function (): value
        local file = fs.open(path, "w")
        fs_open_result_delivered = true
        file:close()
        return "late-open-result-must-not-win"
      end)

      local canceller = async.run(function (): value
        while not uv.__test_fs_callback_is_delayed() do
          timer.yield()
        end
        target:cancel("late-successful-open-cancel")
        return nil
      end)

      return async.run(function (): value
        canceller:join()
        local caught = false
        do
          target:join()
        catch
          local cancelled = error as async.Cancelled
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

return LATE_FS_CASES
