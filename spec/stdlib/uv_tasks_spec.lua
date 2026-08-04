local async_stdlib = require "spec.support.async_stdlib"

local TASK_CASES = [[
    local async = import "async"
    local coroutine = import "coroutine"
    local fs = import "fs"
    local net = import "net"
    local timer = import "timer"

    local chain_task: async.Task? = nil
    local cancelled_task: async.Task? = nil
    local self_cancelled_task: async.Task? = nil
    local failed_task: async.Task? = nil
    local chain = ""
    local cancelled_body_started = false
    local cancelled_body_finished = false
    local self_cancelled_body_finished = false
    local waiting_observed = false
    local cancellation_kept_waiting_status = false
    local nested_result = "not-run"
    local explicitly_suspended_task: async.Task? = nil
    local explicit_resume_trace = ""
    local close_before_resume_task: async.Task? = nil
    local close_before_resume_trace = ""
    local cleanup_first: fs.File? = nil
    local cleanup_second: fs.File? = nil
    local cleanup_progress = 0
    local close_started = false
    local close_finished = false

    local function simple_cancellation_reason(task: async.Task): string
      local cancelled, reason? = task:status():has_cancelled()
      if not cancelled or reason == nil then
        raise "cancelled Task has no cancellation reason"
      end
      case reason as async.CancellationReason
      when simple: message then return message
      else raise "cancelled Task has a complex cancellation reason"
      end
    end

    -- Public net does not expose an ephemeral listener's selected port. Retry
    -- only address-use collisions from other concurrent test processes.
    local function listen_available(first_port: integer): (net.Server, integer)
      local port = first_port
      for _ = 1, 100 do
        do
          local server = net.listen("127.0.0.1", port)
          return server, port
        catch
          if error is async.OperationError then
            local failure = error as async.OperationError
            if failure.name == "EADDRINUSE" then
              port = port + 1
              if port > 60999 then port = 20000 end
            else
              raise "unexpected listen failure: " .. failure.operation ..
                    ":" .. failure.name .. ": " .. failure.message
            end
          else
            raise error
          end
        end
      end
      raise "could not find an available loopback port"
    end

    local function failed_origin(): value
      timer.yield()
      raise "task-status-boom"
      return nil
    end

    function schedule(path: string)
      chain = ""
      cancelled_body_started = false
      cancelled_body_finished = false
      self_cancelled_body_finished = false
      waiting_observed = false
      cancellation_kept_waiting_status = false

      chain_task = async.run(function (): value
        chain = "timer"
        timer.sleep(0)
        chain = chain .. ">write"
        fs.write_file(path, "callback-payload")
        chain = chain .. ">read"
        local contents = fs.read_file(path)
        chain = chain .. ">" .. contents
        timer.yield()
        chain = chain .. ">turn"
        return nil
      end)

      cancelled_task = async.run(function (): value
        cancelled_body_started = true
        timer.sleep(60000)
        cancelled_body_finished = true
        return nil
      end)

      failed_task = async.run(failed_origin)

      self_cancelled_task = async.run(function (): value
        (self_cancelled_task as async.Task):cancel(
          async.CancellationReason.simple("self cancellation"))
        -- The requested cancellation is injected at this boundary without
        -- submitting the long timer operation.
        timer.sleep(60000)
        self_cancelled_body_finished = true
        return nil
      end)

      async.run(function (): value
        -- Let the target reach its callback-taking sleep before cancelling it.
        local target = cancelled_task as async.Task
        while target:status():as_string() == "ready" do timer.yield() end
        waiting_observed = target:status():as_string() == "waiting"
        target:cancel(async.CancellationReason.simple("first reason"))
        target:cancel(async.CancellationReason.simple(
          "ignored second reason"))
        cancellation_kept_waiting_status =
          target:status():as_string() == "waiting" and
          not target:status():has_finished()
        return nil
      end)
    end

    function chain_status(): string
      return (chain_task as async.Task):status():as_string()
    end

    function cancelled_status(): string
      return (cancelled_task as async.Task):status():as_string()
    end

    function cancelled_reason(): string
      return simple_cancellation_reason(cancelled_task as async.Task)
    end

    function failed_status(): string
      return (failed_task as async.Task):status():as_string()
    end

    function self_cancelled_status(): string
      return (self_cancelled_task as async.Task):status():as_string()
    end

    function chain_result(): string
      return chain
    end

    function cancellation_entered(): boolean
      return cancelled_body_started
    end

    function cancellation_passed_boundary(): boolean
      return cancelled_body_finished
    end

    function self_cancellation_passed_boundary(): boolean
      return self_cancelled_body_finished
    end

    function saw_waiting_status(): boolean
      return waiting_observed
    end

    function cancellation_kept_waiting(): boolean
      return cancellation_kept_waiting_status
    end

    function schedule_failure_only(): async.Task
      return async.run(function (): value
        timer.yield()
        raise "last-task-boom"
        return nil
      end)
    end

    function schedule_nested_timer(): async.Task
      nested_result = "running"
      return async.run(function (): value
        local child = coroutine.create(function (_arg: value): value
          timer.sleep(0)
          return "nested-timer-ok"
        end, "child")
        nested_result = child:resume(nil) as string
        return nil
      end)
    end

    function nested_timer_result(): string
      return nested_result
    end

    function schedule_explicit_resume(): async.Task
      explicit_resume_trace = ""
      explicitly_suspended_task = async.run(function (): value
        explicit_resume_trace = explicit_resume_trace .. "suspend>"
        async.suspend()
        explicit_resume_trace = explicit_resume_trace .. "target-woke"
        return nil
      end)

      return async.run(function (): value
        local target = explicitly_suspended_task as async.Task
        while target:status():as_string() == "ready" do timer.yield() end
        if target:status():as_string() ~= "waiting" then
          raise "target did not explicitly suspend"
        end
        explicit_resume_trace = explicit_resume_trace .. "resume>"
        target:resume()
        if target:status():as_string() ~= "waiting" then
          raise "Task:resume resumed its target synchronously"
        end
        explicit_resume_trace = explicit_resume_trace .. "caller-returned>"
        return nil
      end)
    end

    function explicitly_suspended_status(): string
      return (explicitly_suspended_task as async.Task):status():as_string()
    end

    function explicit_resume_result(): string
      return explicit_resume_trace
    end

    function schedule_close_before_resume(first_port: integer): async.Task
      close_before_resume_trace = ""
      close_before_resume_task = nil
      return async.run(function (): value
        local server, port = listen_available(first_port)
        local accepted: net.Connection? = nil
        local accepter = async.run(function (): value
          accepted = server:accept()
          return nil
        end)
        local client = net.connect("127.0.0.1", port)
        while not accepter:status():has_finished() do timer.yield() end
        if accepter:status():as_string() ~= "succeeded" or not accepted then
          raise "loopback accept failed"
        end
        local peer = accepted as net.Connection

        close_before_resume_task = async.run(function (): value
          async.suspend()
          close_before_resume_trace = close_before_resume_trace .. "target"
          return nil
        end)
        local target = close_before_resume_task as async.Task
        while target:status():as_string() == "ready" do timer.yield() end
        if target:status():as_string() ~= "waiting" then
          raise "close-order target did not explicitly suspend"
        end

        -- peer:read resumes this Task from the poll phase. Its reply write
        -- completion therefore runs in libuv's post-poll pending phase. Start
        -- the target's zero timer and the client read from that callback: the
        -- timer fires in the trailing timer phase, while the already-written
        -- reply cannot be delivered until the next poll. A timer_cb resume
        -- would produce target>read; close_cb resumption produces read>target.
        client:write("signal")
        if peer:read() ~= "signal" then raise "loopback signal changed" end
        peer:write("reply")
        target:resume()
        if client:read() ~= "reply" then raise "loopback reply changed" end
        close_before_resume_trace = close_before_resume_trace .. "read>"

        peer:close()
        client:close()
        server:close()
        if target:status():as_string() ~= "succeeded" then
          raise "close-order target did not finish"
        end
        return nil
      end)
    end

    function close_before_resume_status(): string
      return (close_before_resume_task as async.Task):status():as_string()
    end

    function close_before_resume_result(): string
      return close_before_resume_trace
    end

    function schedule_caught_cancellations(): async.Task
      return async.run(function (): value
        local returned = async.run(function (): value
          do
            timer.sleep(60000)
          catch
            return "caught cancellation"
          end
          return "unexpected return"
        end)
        local replaced = async.run(function (): value
          do
            timer.sleep(60000)
          catch
            raise "replacement failure"
          end
          return "unexpected return"
        end)

        while returned:status():as_string() == "ready" or
              replaced:status():as_string() == "ready" do
          timer.yield()
        end
        returned:cancel(async.CancellationReason.simple(
          "return path cancellation"))
        replaced:cancel(async.CancellationReason.simple(
          "raise path cancellation"))
        while not returned:status():has_finished() or
              not replaced:status():has_finished() do
          timer.yield()
        end
        if simple_cancellation_reason(returned) ~=
             "return path cancellation" then
          raise "caught return replaced the cancellation reason"
        end
        if simple_cancellation_reason(replaced) ~=
             "raise path cancellation" then
          raise "caught raise replaced the cancellation reason"
        end
        return nil
      end)
    end

    function schedule_cancelled_file_cleanup(first_path: string,
                                               second_path: string): async.Task
      cleanup_first = nil
      cleanup_second = nil
      cleanup_progress = 0
      local task: async.Task? = nil
      task = async.run(function (): value
        local first = fs.open(first_path, "w")
        local second = fs.open(second_path, "w")
        cleanup_first = first
        cleanup_second = second
        defer do
          first:close()
          cleanup_progress = 1
          second:close()
          cleanup_progress = 2
        end

        (task as async.Task):cancel(
          async.CancellationReason.simple("cleanup cancellation"))
        -- This cancellation-sensitive Call must not be submitted. Unwinding
        -- still dispatches both cancellation-insensitive closes above.
        first:write("cancelled write was submitted")
        return nil
      end)
      return task as async.Task
    end

    function cancelled_cleanup_progress(): integer
      return cleanup_progress
    end

    function cancelled_cleanup_closed(): boolean
      return cleanup_first ~= nil and cleanup_second ~= nil and
        (cleanup_first as fs.File):is_closed() and
        (cleanup_second as fs.File):is_closed()
    end

    function schedule_cancel_during_close(): async.Task
      close_started = false
      close_finished = false
      local target: async.Task? = nil
      target = async.run(function (): value
        local ticker = timer.ticker(60000)
        close_started = true
        ticker:close()
        close_finished = true
        return nil
      end)
      async.run(function (): value
        while not close_started do timer.yield() end
        (target as async.Task):cancel(
          async.CancellationReason.simple("close callback cancellation"))
        return nil
      end)
      return target as async.Task
    end

    function cancellation_crossed_close_callback(): boolean
      return close_finished
    end
]]

describe("async Task callback continuations", function()
    local workspace

    local function port_seed(text)
        local hash = 0
        for index = 1, #text do
            hash = (hash * 33 + text:byte(index)) % 30000
        end
        return 20000 + hash
    end

    setup(function()
        workspace = async_stdlib.workspace("uv-tasks")
        async_stdlib.write_source(workspace, "uv_task_cases", TASK_CASES)
        async_stdlib.compile(workspace, "uv_task_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("routes each completed operation to the Task's next operation", function()
        local path = workspace .. "/continuation.txt"
        local ok, status, output = async_stdlib.run_lua_source(workspace, ([=[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            behavior.schedule(%q)
            assert(behavior.chain_status() == "ready")
            assert(behavior.cancelled_status() == "ready")
            assert(behavior.failed_status() == "ready")
            assert(behavior.self_cancelled_status() == "ready")

            async.loop()
            assert(behavior.chain_status() == "succeeded")
            assert(behavior.cancelled_status() == "cancelled")
            assert(behavior.cancelled_reason() == "first reason")
            assert(behavior.failed_status() == "failed")
            assert(behavior.self_cancelled_status() == "cancelled")
            assert(behavior.chain_result() ==
                "timer>write>read>callback-payload>turn")
            assert(behavior.cancellation_entered())
            assert(not behavior.cancellation_passed_boundary())
            assert(not behavior.self_cancellation_passed_boundary())
            assert(behavior.saw_waiting_status())
            assert(behavior.cancellation_kept_waiting())
        ]=]):format(path))

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("task-status-boom", output, 1, true)
        assert.match("stack traceback:", output, 1, true)
        assert.match("in uv_task_cases.failed_origin", output, 1, true)
        assert.equals("callback-payload", async_stdlib.read(path))
    end)

    it("starts Runtime cleanup when the last live Task fails", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            local task = behavior.schedule_failure_only()
            async.loop()
            assert(task:status():as_string() == "failed")
        ]])

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("last-task-boom", output, 1, true)
        assert.match("stack traceback:", output, 1, true)
    end)

    it("routes the single uv tag through a nested user coroutine", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            local task = behavior.schedule_nested_timer()
            async.loop()
            assert(task:status():as_string() == "succeeded", task:status():as_string())
            assert(behavior.nested_timer_result() == "nested-timer-ok")
        ]])

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("schedules an explicitly suspended Task after its resumer returns", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            local resumer = behavior.schedule_explicit_resume()
            async.loop()
            assert(resumer:status():as_string() == "succeeded")
            assert(behavior.explicitly_suspended_status() == "succeeded")
            assert(behavior.explicit_resume_result() ==
                "suspend>resume>caller-returned>target-woke")
        ]])

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("resumes a suspended Task only after its zero timer closes", function()
        local first_port = port_seed(workspace .. ":close-before-resume")
        local ok, status, output = async_stdlib.run_lua_source(workspace,
            ([=[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            local controller = behavior.schedule_close_before_resume(%d)
            async.loop()
            assert(controller:status():as_string() == "succeeded",
                controller:status():as_string())
            assert(behavior.close_before_resume_status() == "succeeded",
                behavior.close_before_resume_status())
            assert(behavior.close_before_resume_result() == "read>target",
                behavior.close_before_resume_result())
        ]=]):format(first_port))

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("keeps cancellation authoritative after caught return or raise", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            local task = behavior.schedule_caught_cancellations()
            async.loop()
            assert(task:status():as_string() == "succeeded")
        ]])

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.falsy(output:find("uncaught error in async Task:", 1, true),
            output)
        assert.falsy(output:find("replacement failure", 1, true), output)
    end)

    it("shields ownership-retiring Calls while cancellation stays pending", function()
        local first = workspace .. "/cancelled-first.txt"
        local second = workspace .. "/cancelled-second.txt"
        local ok, status, output = async_stdlib.run_lua_source(workspace, ([=[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"

            local cleanup = behavior.schedule_cancelled_file_cleanup(%q, %q)
            async.loop()
            assert(cleanup:status():as_string() == "cancelled")
            assert(behavior.cancelled_cleanup_progress() == 2)
            assert(behavior.cancelled_cleanup_closed())

            local closing = behavior.schedule_cancel_during_close()
            async.loop()
            assert(closing:status():as_string() == "cancelled")
            assert(behavior.cancellation_crossed_close_callback())
        ]=]):format(first, second))

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.equals("", async_stdlib.read(first))
        assert.equals("", async_stdlib.read(second))
        assert.falsy(output:find("uncaught error in async Task:", 1, true),
            output)
    end)
end)
