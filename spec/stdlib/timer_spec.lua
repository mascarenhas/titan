local async_stdlib = require "spec.support.async_stdlib"

local TIMER_CASES = [[
    local async = import "async"
    local stream = import "io"
    local timer = import "timer"

    function schedule_four_ticks(): async.Task
      return async.run(function (): value
        local ticker = timer.ticker(1)
        local count = 0
        for i = 1, 4 do
          if ticker:tick() then
            count = count + 1
          end
        end
        ticker:close()
        ticker:close()
        if ticker:tick() then
          raise "closed Ticker produced another tick"
        end
        return count
      end)
    end

    function schedule_close_waiter(): async.Task
      return async.run(function (): value
        local ticker = timer.ticker(1000)
        local waiter = async.run(function (): value
          return ticker:tick()
        end)
        timer.yield()
        ticker:close()
        ticker:close()
        return waiter:join()
      end)
    end

    function schedule_dropped_ticks(): async.Task
      return async.run(function (): value
        local ticker = timer.ticker(1)
        -- Let several callbacks fire with no waiter. Empty ticks must be dropped.
        timer.sleep(12)
        local phase = 0
        local target = async.run(function (): value
          phase = 1
          local got = ticker:tick()
          phase = 3
          return got
        end)
        local observer = async.run(function (): value
          while phase == 0 do
            timer.yield()
          end
          if phase ~= 1 or target:status() ~= "waiting" then
            raise "an empty Ticker tick was buffered"
          end
          phase = 2
          return nil
        end)
        observer:join()
        local got = target:join() as boolean
        ticker:close()
        if not got or phase ~= 3 then
          raise "Ticker did not resume on a later callback"
        end
        return "dropped-empty-ticks"
      end)
    end

    function schedule_zero_turns(): async.Task
      return async.run(function (): value
        local phase = 0
        local sleep_task = async.run(function (): value
          phase = 1
          timer.sleep(0)
          if phase ~= 2 then
            raise "sleep(0) did not cede a turn"
          end
          phase = 3
          return nil
        end)
        local observer = async.run(function (): value
          while phase == 0 do timer.yield() end
          phase = 2
          timer.yield()
          if phase ~= 3 then
            raise "yield() did not cede a turn"
          end
          return nil
        end)
        sleep_task:join()
        observer:join()
        return "zero-turns-ok"
      end)
    end

    function schedule_second_waiter_rejected(): async.Task
      return async.run(function (): value
        local ticker = timer.ticker(10000)
        local first = async.run(function (): value
          return ticker:tick()
        end)
        while first:status() == "ready" do
          timer.yield()
        end
        if first:status() ~= "waiting" then
          raise "first Ticker waiter did not suspend"
        end

        local second = async.run(function (): value
          return ticker:tick()
        end)
        local rejected = false
        do
          second:join()
        catch
          rejected = true
        end
        if not rejected then
          raise "Ticker accepted a second waiter"
        end

        ticker:close()
        if first:join() as boolean then
          raise "closed Ticker resumed its first waiter with true"
        end
        return "second-waiter-rejected"
      end)
    end

    function schedule_interface_close(): async.Task
      return async.run(function (): value
        local ticker = timer.ticker(10000)
        local waiter = async.run(function (): value
          return ticker:tick()
        end)
        while waiter:status() == "ready" do timer.yield() end
        local closer: stream.Closer = ticker
        closer:close()
        closer:close()
        if waiter:join() as boolean then
          raise "io.Closer resumed a Ticker waiter with true"
        end
        if ticker:tick() then
          raise "Ticker was not closed through incidental io.Closer"
        end
        return "interface-close-ok"
      end)
    end
]]

describe("timer recurring handles", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("timer")
        async_stdlib.write_source(workspace, "timer_recurring_cases", TIMER_CASES)
        async_stdlib.compile(workspace, "timer_recurring_cases")
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    local function run(source)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end

    it("cycles four times and makes close immediate and idempotent", function()
        run([[
            local async = require "titan.async"
            local cases = require "timer_recurring_cases"
            local task = cases.schedule_four_ticks()
            async.loop()
            assert(task:join() == 4)
        ]])
    end)

    it("closes a pending tick waiter with false", function()
        run([[
            local async = require "titan.async"
            local cases = require "timer_recurring_cases"
            local task = cases.schedule_close_waiter()
            async.loop()
            assert(task:join() == false)
        ]])
    end)

    it("drops ticks that fire without a waiter", function()
        run([[
            local async = require "titan.async"
            local cases = require "timer_recurring_cases"
            local task = cases.schedule_dropped_ticks()
            async.loop()
            assert(task:join() == "dropped-empty-ticks")
        ]])
    end)

    it("cedes a turn for sleep(0) and yield()", function()
        run([[
            local async = require "titan.async"
            local cases = require "timer_recurring_cases"
            local task = cases.schedule_zero_turns()
            async.loop()
            assert(task:join() == "zero-turns-ok")
        ]])
    end)

    it("rejects nonpositive periods and a second tick waiter", function()
        run([[
            local async = require "titan.async"
            local timer = require "titan.timer"
            local cases = require "timer_recurring_cases"
            local ok, err = pcall(timer.ticker, 0)
            assert(not ok and tostring(err):find("positive", 1, true))
            local task = cases.schedule_second_waiter_rejected()
            async.loop()
            assert(task:join() == "second-waiter-rejected")
        ]])
    end)

    it("dispatches incidental Ticker close through io.Closer", function()
        run([[
            local async = require "titan.async"
            local cases = require "timer_recurring_cases"
            local task = cases.schedule_interface_close()
            async.loop()
            assert(task:join() == "interface-close-ok")
        ]])
    end)
end)
