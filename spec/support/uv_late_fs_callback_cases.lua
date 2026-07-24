local LATE_FS_CASES = [[
    -- Runs only against the generated delayed-FS callback uv variant.
    local lua = foreign import "lua.h"
    local fs = import "fs"
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
      return uv._run(function (): value
        return file:write(payload)
      end)
    end

    function loop()
      uv._loop()
    end

    function schedule_next_session(): uv.Task
      return uv._run(function (): value
        return "next-session-ok"
      end)
    end

    function schedule_cross_generation_graph(root: string): uv.Task
      return uv._run(function (): value
        local file = fs.open(root .. "/cross-generation.dat", "w")
        local ticker = uv._ticker(1000)
        local old_error_task = uv._run(function (): value
          uv._sleep(80)
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

        while old_error_task:status() == "ready" do uv._yield() end
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
          uv._yield()
        end
        lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
        check((writer:join() as integer) == expected_length,
              "young shared-tag writer returned the wrong byte count")
        check(old_error_task:join() == "young-error-ok",
              "old Task did not retain its young uv.Error")

        uv._ticker_close(ticker)
        file:close()
        return "cross-generation-graph-ok"
      end)
    end

    function schedule_late_fs_cancellation(path: string): uv.Task
      fs_result_delivered = false
      uv.__test_delay_next_fs_callback(40)

      local target = uv._run(function (): value
        fs.stat(path)
        fs_result_delivered = true
        return "late-result-must-not-win"
      end)

      local canceller = uv._run(function (): value
        while not uv.__test_fs_callback_is_delayed() do
          uv._yield()
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

      return uv._run(function (): value
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

        uv._sleep(50)
        check(not fs_result_delivered,
              "late filesystem result resumed a cancelled Task")
        return "late-fs-cancellation-ok"
      end)
    end

    function schedule_late_open_cancellation(path: string): uv.Task
      fs_open_result_delivered = false
      uv.__test_delay_next_fs_callback(40)

      local target = uv._run(function (): value
        local file = fs.open(path, "w")
        fs_open_result_delivered = true
        file:close()
        return "late-open-result-must-not-win"
      end)

      local canceller = uv._run(function (): value
        while not uv.__test_fs_callback_is_delayed() do
          uv._yield()
        end
        target:cancel("late-successful-open-cancel")
        return nil
      end)

      return uv._run(function (): value
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

        -- Keep the Runtime alive long enough to drain the delayed open and its
        -- asynchronous descriptor disposal.
        uv._sleep(50)
        check(not fs_open_result_delivered,
              "cancelled successful open published a File")
        return "late-successful-open-cancellation-ok"
      end)
    end
]]

return LATE_FS_CASES
