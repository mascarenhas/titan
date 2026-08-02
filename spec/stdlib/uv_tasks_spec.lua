local async_stdlib = require "spec.support.async_stdlib"

local TASK_CASES = [[
    local async = import "async"
    local fs = import "fs"
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
    local cancellation_returned_while_waiting = false

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
      cancellation_returned_while_waiting = false

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
        (self_cancelled_task as async.Task):cancel("self cancellation")
        -- Sticky cancellation is injected at this boundary without
        -- submitting the long timer operation.
        timer.sleep(60000)
        self_cancelled_body_finished = true
        return nil
      end)

      async.run(function (): value
        -- Let the target reach its callback-taking sleep before cancelling it.
        local target = cancelled_task as async.Task
        while target:status() == "ready" do timer.yield() end
        waiting_observed = target:status() == "waiting"
        target:cancel("first reason")
        target:cancel("ignored second reason")
        cancellation_returned_while_waiting =
          target:status() == "waiting"
        return nil
      end)
    end

    function chain_status(): string
      return (chain_task as async.Task):status()
    end

    function cancelled_status(): string
      return (cancelled_task as async.Task):status()
    end

    function failed_status(): string
      return (failed_task as async.Task):status()
    end

    function self_cancelled_status(): string
      return (self_cancelled_task as async.Task):status()
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

    function cancellation_was_deferred(): boolean
      return cancellation_returned_while_waiting
    end

    function schedule_failure_only(): async.Task
      return async.run(function (): value
        timer.yield()
        raise "last-task-boom"
        return nil
      end)
    end
]]

describe("async Task callback continuations", function()
    local workspace

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
            assert(behavior.failed_status() == "failed")
            assert(behavior.self_cancelled_status() == "cancelled")
            assert(behavior.chain_result() ==
                "timer>write>read>callback-payload>turn")
            assert(behavior.cancellation_entered())
            assert(not behavior.cancellation_passed_boundary())
            assert(not behavior.self_cancellation_passed_boundary())
            assert(behavior.saw_waiting_status())
            assert(behavior.cancellation_was_deferred())
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
            assert(task:status() == "failed")
        ]])

        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("last-task-boom", output, 1, true)
        assert.match("stack traceback:", output, 1, true)
    end)
end)
