local async_stdlib = require "spec.support.async_stdlib"

local TASK_CASES = [[
    local async = import "async"
    local timer = import "timer"
    local coroutine = import "coroutine"

    local OTHER_TAG: value = {}
    local nonblocking_started = false
    local nested_child_started = false

    local function fail_origin(): value
      raise "uv-task-observed-boom"
      return nil
    end

    local function join_propagation(child: async.Task): value
      do
        child:join()
      catch
        return traceback
      end
      return "missing failure"
    end

    local function other_tag_body(_arg: value): value
      timer.yield()
      return "crossed-and-restored"
    end

    function reset()
      nonblocking_started = false
      nested_child_started = false
    end

    function did_start(): boolean
      return nonblocking_started
    end

    function nested_did_start(): boolean
      return nested_child_started
    end

    function schedule_nonblocking(): async.Task
      return async.run(function (): value
        nonblocking_started = true
        return "nonblocking-ok"
      end)
    end

    function schedule_nested_run(): async.Task
      return async.run(function (): value
        local child = async.run(function (): value
          nested_child_started = true
          timer.yield()
          return "nested-child-ok"
        end)
        if nested_child_started then
          raise "nested async.run resumed its child inline"
        end
        return child:join()
      end)
    end

    function schedule_shared_tag(): async.Task
      return async.run(function (): value
        local nested = coroutine.create(other_tag_body, OTHER_TAG)
        local result = nested:resume(nil, OTHER_TAG)
        if nested:status() ~= "dead" then
          raise "differently tagged coroutine chain was not restored"
        end
        return result
      end)
    end

    function schedule_callback_chain(): async.Task
      return async.run(function (): value
        local trace = "A"
        timer.yield()
        trace = trace .. "B"
        return trace
      end)
    end

    function schedule_out_of_order(): async.Task
      return async.run(function (): value
        local order: {integer} = {}
        local slow = async.run(function (): value
          timer.sleep(20)
          order[#order + 1] = 1
          return 1
        end)
        local fast = async.run(function (): value
          timer.sleep(0)
          order[#order + 1] = 2
          return 2
        end)
        local fast_result = fast:join() as integer
        local slow_result = slow:join() as integer
        if fast_result ~= 2 or slow_result ~= 1 or #order ~= 2 or
            order[1] ~= 2 or order[2] ~= 1 then
          raise "out-of-order timers resumed the wrong Task"
        end
        return "out-of-order-ok"
      end)
    end

    function schedule_observed_trace(): async.Task
      local child = async.run(fail_origin)
      return async.run(function (): value
        return join_propagation(child)
      end)
    end

    function schedule_next_turn_observer(): async.Task
      local child = async.run(fail_origin)
      return async.run(function (): value
        do
          child:join()
        catch
          if error ~= "uv-task-observed-boom" then
            raise "observer received the wrong error value"
          end
          timer.yield()
          return "observed-before-promotion"
        end
        return "observer missed failure"
      end)
    end

    function schedule_loop_rejection(): async.Task
      return async.run(function (): value
        do
          async.loop()
        catch
          local child = async.run(function (): value
            return "nested-run-on-child-state"
          end)
          return child:join()
        end
        raise "async.loop accepted a UV child-state caller"
        return nil
      end)
    end

    function schedule_self_join(): async.Task
      local self_task: async.Task? = nil
      self_task = async.run(function (): value
        local task = self_task as async.Task
        do
          task:join()
        catch
          if error ~= "a Task cannot join itself" then
            raise "self-join reported the wrong error"
          end
          return "self-join-rejected"
        end
        raise "a Task joined itself"
        return nil
      end)
      return self_task as async.Task
    end

    function schedule_multiple_joiners(): async.Task
      local deliveries = 0
      local target = async.run(function (): value
        timer.sleep(5)
        return 17
      end)
      local first = async.run(function (): value
        local result = target:join() as integer
        deliveries = deliveries + 1
        return result
      end)
      local second = async.run(function (): value
        local result = target:join() as integer
        deliveries = deliveries + 1
        return result + 1
      end)
      return async.run(function (): value
        if (first:join() as integer) ~= 17 or
            (second:join() as integer) ~= 18 or deliveries ~= 2 then
          raise "multiple Task joiners were not each resumed exactly once"
        end
        return "multiple-joiners-ok"
      end)
    end

    function schedule_lookalike_cancelled(): async.Task
      local target = async.run(function (): value
        local lookalike: async.Cancelled = { reason = "not-requested" }
        raise lookalike
        return nil
      end)
      return async.run(function (): value
        do
          target:join()
        catch
          local lookalike = error as async.Cancelled
          if lookalike.reason ~= "not-requested" or
              target:status() ~= "failed" then
            raise "unrequested Cancelled value was not an ordinary failure"
          end
          return "lookalike-cancelled-failed"
        end
        raise "lookalike Cancelled value unexpectedly succeeded"
        return nil
      end)
    end

    function schedule_join_cycle()
      local first: async.Task? = nil
      local second: async.Task? = nil
      first = async.run(function (): value
        return (second as async.Task):join()
      end)
      second = async.run(function (): value
        return (first as async.Task):join()
      end)
    end

    local sticky_catches = 0

    function catches(): integer
      return sticky_catches
    end

    function schedule_sticky(): async.Task
      sticky_catches = 0
      local target = async.run(function (): value
        do
          timer.sleep(1000)
        catch
          local cancelled = error as async.Cancelled
          if cancelled.reason ~= "first-reason" then
            raise "first cancellation reason changed"
          end
          sticky_catches = sticky_catches + 1
        end
        do
          timer.yield()
        catch
          local cancelled = error as async.Cancelled
          if cancelled.reason ~= "first-reason" then
            raise "sticky cancellation reason changed"
          end
          sticky_catches = sticky_catches + 1
        end
        return "must-not-win-over-cancellation"
      end)

      async.run(function (): value
        timer.yield()
        target:cancel("first-reason")
        target:cancel("second-reason")
        return nil
      end)

      return async.run(function (): value
        do
          target:join()
        catch
          local cancelled = error as async.Cancelled
          if cancelled.reason ~= "first-reason" then
            raise "terminal cancellation reason changed"
          end
          if target:status() ~= "cancelled" then
            raise "cancelled Task has the wrong terminal status"
          end
          return cancelled
        end
        raise "cancelled Task joined successfully"
        return nil
      end)
    end

    function schedule_cancel_before_start(): async.Task
      local entered = false
      local target = async.run(function (): value
        entered = true
        return nil
      end)
      target:cancel("before-start")
      return async.run(function (): value
        do
          target:join()
        catch
          local cancelled = error as async.Cancelled
          if entered then
            raise "cancel-before-start entered the Task body"
          end
          return cancelled
        end
        raise "cancel-before-start joined successfully"
        return nil
      end)
    end
]]

describe("async Task scheduling and lifecycle", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("uv-tasks")
        async_stdlib.write_source(workspace, "uv_task_cases", TASK_CASES)
        async_stdlib.compile(workspace, "uv_task_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    local function run(source)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end

    it("starts roots on a later turn and restricts loop driving to main L",
    function()
        run([[
            local lua_coroutine = require "coroutine"
            local async = require "titan.async"
            local behavior = require "uv_task_cases"
            assert(require "coroutine" == lua_coroutine)

            local before_runtime = lua_coroutine.create(function()
                return pcall(async.loop)
            end)
            local resumed, loop_ok, loop_err =
                lua_coroutine.resume(before_runtime)
            assert(resumed and not loop_ok)
            assert(tostring(loop_err):find("main thread", 1, true),
                tostring(loop_err))
            assert(async.loop() == nil)

            behavior.reset()
            local nonblocking = behavior.schedule_nonblocking()
            assert(not behavior.did_start())
            assert(nonblocking:status() == "ready")

            local ordinary = lua_coroutine.create(function()
                return pcall(async.loop)
            end)
            resumed, loop_ok, loop_err = lua_coroutine.resume(ordinary)
            assert(resumed and not loop_ok)
            assert(tostring(loop_err):find("main thread", 1, true))

            async.loop()
            assert(nonblocking:join() == "nonblocking-ok")
            assert(behavior.did_start())
        ]])
    end)

    it("supports nested runs, tagged nesting, and callback handoff", function()
        run([[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"
            behavior.reset()
            local nested = behavior.schedule_nested_run()
            local tagged = behavior.schedule_shared_tag()
            local chain = behavior.schedule_callback_chain()
            async.loop()
            assert(nested:join() == "nested-child-ok")
            assert(behavior.nested_did_start())
            assert(tagged:join() == "crossed-and-restored")
            assert(chain:join() == "AB")
        ]])
    end)

    it("resumes out-of-order timer completions on the right Tasks", function()
        run([[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"
            local ordered = behavior.schedule_out_of_order()
            async.loop()
            assert(ordered:join() == "out-of-order-ok")
        ]])
    end)

    it("observes failures before promotion and preserves propagation traces",
    function()
        run([[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"
            local traced = behavior.schedule_observed_trace()
            local observed = behavior.schedule_next_turn_observer()
            async.loop()
            assert(observed:join() == "observed-before-promotion")
            local trace = traced:join()
            assert(type(trace) == "string" and #trace > 0)
            local origin = assert(trace:find(
                "in uv_task_cases.fail_origin", 1, true), trace)
            local propagation = assert(trace:find(
                "in uv_task_cases.join_propagation", 1, true), trace)
            assert(origin < propagation, trace)
        ]])
    end)

    it("rejects loop driving from a Task but permits a nested run", function()
        run([[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"
            local task = behavior.schedule_loop_rejection()
            async.loop()
            assert(task:join() == "nested-run-on-child-state")
        ]])
    end)

    it("handles self-join, multiple joiners, and Cancelled lookalikes", function()
        run([[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"
            local self_join = behavior.schedule_self_join()
            local multiple_joiners = behavior.schedule_multiple_joiners()
            local lookalike = behavior.schedule_lookalike_cancelled()
            async.loop()
            assert(self_join:join() == "self-join-rejected")
            assert(multiple_joiners:join() == "multiple-joiners-ok")
            assert(lookalike:join() == "lookalike-cancelled-failed")
        ]])
    end)

    it("keeps the first cancellation reason and cancels before entry", function()
        run([[
            local async = require "titan.async"
            local cancellation = require "uv_task_cases"
            local sticky = cancellation.schedule_sticky()
            local before = cancellation.schedule_cancel_before_start()
            async.loop()
            local cancelled = sticky:join()
            assert(cancelled.reason == "first-reason")
            assert(cancellation.catches() == 2)
            assert(sticky:status() == "succeeded")
            local early = before:join()
            assert(early.reason == "before-start")
        ]])
    end)

    it("reports cyclic Task joins as an idle-loop deadlock", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local async = require "titan.async"
            local behavior = require "uv_task_cases"
            behavior.schedule_join_cycle()
            async.loop()
            error("cyclic Task joins unexpectedly completed")
        ]])
        assert.falsy(ok, output)
        assert.not_equals(0, status)
        assert.match("libuv loop became idle while Tasks were waiting", output,
            1, true)
    end)

    it("roots dropped Tasks through GC and closes sequential sessions", function()
        run([[
            local async = require "titan.async"
            local timer = require "titan.timer"
            collectgarbage("collect")
            collectgarbage("generational")
            local weak = setmetatable({}, { __mode = "v" })
            local sentinel = { marker = "pending-root" }
            weak.sentinel = sentinel
            local function schedule_with_capture(captured)
                return async.run(function()
                    timer.yield()
                    assert(weak.sentinel and
                        weak.sentinel.marker == "pending-root")
                    return captured
                end)
            end
            local task = schedule_with_capture(sentinel)
            weak.task = task
            sentinel = nil
            task = nil
            collectgarbage("collect")
            assert(weak.task ~= nil and weak.sentinel ~= nil)
            async.loop()

            for _ = 1, 4 do collectgarbage("collect") end
            assert(weak.task == nil, "completed Task retained after loop close")
            assert(weak.sentinel == nil,
                "captured result retained after loop close")

            local old_ticker
            local first = async.run(function()
                old_ticker = timer.ticker(1)
                assert(old_ticker:tick())
                return 11
            end)
            async.loop()
            assert(first:join() == 11)
            assert(old_ticker:tick() == false)

            local second_started = false
            local second = async.run(function()
                second_started = true
                timer.yield()
                return 23
            end)
            assert(not second_started and second:status() == "ready")
            async.loop()
            assert(second_started and second:join() == 23)
        ]])
    end)
end)
