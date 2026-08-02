local async_stdlib = require "spec.support.async_stdlib"

local TIMER_CASES = [==[
local async = import "async"
local stream = import "io"
local timer = import "timer"

local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function active(task: async.Task): boolean
  local status = task:status()
  return status == "ready" or status == "running" or status == "waiting"
end

function result(): string
  return outcome
end

function start_turns(): async.Task
  outcome = "running"
  return async.run(function (): value
    timer.yield()
    timer.sleep(0)
    timer.sleep(2)
    local rejected = false
    do
      timer.sleep(-1)
    catch
      local failure = error as async.Error
      check(failure.operation == "timer.sleep",
            "negative sleep reported the wrong operation")
      rejected = true
    end
    check(rejected, "negative sleep was accepted")
    outcome = "turns-ok"
    return nil
  end)
end

function start_ticker(): async.Task
  outcome = "running"
  return async.run(function (): value
    local ticker = timer.ticker(1)
    local count = 0
    for _ = 1, 3 do
      if ticker:tick() then count = count + 1 end
    end
    check(count == 3, "Ticker lost a waited tick")

    -- A recurring timer retains only the fact that it fired while there was
    -- no waiter. Consuming that fact must not require another native tick.
    timer.sleep(8)
    check(ticker:tick(), "Ticker did not retain its latest unwaited tick")

    local closer: stream.Closer = ticker
    closer:close()
    closer:close()
    check(not ticker:tick(), "closed Ticker produced another tick")
    outcome = "ticker-ok"
    return nil
  end)
end

function start_pending_close(): async.Task
  outcome = "running"
  return async.run(function (): value
    local ticker = timer.ticker(10000)
    local ticked = true
    local waiter = async.run(function (): value
      ticked = ticker:tick()
      return nil
    end)

    while waiter:status() == "ready" do timer.yield() end
    check(waiter:status() == "waiting",
          "Ticker waiter did not suspend")
    local competing_waiter_rejected = false
    do
      ticker:tick()
    catch
      competing_waiter_rejected = true
    end
    check(competing_waiter_rejected,
          "Ticker accepted a second waiting Task")
    ticker:close()
    while active(waiter) do timer.yield() end
    check(waiter:status() == "succeeded",
          "closing Ticker failed its waiter")
    check(not ticked, "closing Ticker resumed its waiter with true")

    local invalid = false
    do
      timer.ticker(0)
    catch
      invalid = true
    end
    check(invalid, "Ticker accepted a nonpositive interval")
    outcome = "pending-close-ok"
    return nil
  end)
end
]==]

describe("timer standard library", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("timer")
        async_stdlib.write_source(workspace, "timer_cases", TIMER_CASES)
        async_stdlib.compile(workspace, "timer_cases")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run(function_name, expected)
        local source = ([==[
local async = require "titan.async"
local cases = require "timer_cases"
local task = assert(cases.%s())
async.loop()
assert(task:status() == "succeeded", task:status())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, expected)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("runs yield, zero sleep, and timed sleep continuations", function()
        run("start_turns", "turns-ok")
    end)

    it("delivers waited ticks and retains one unwaited tick", function()
        run("start_ticker", "ticker-ok")
    end)

    it("closes a pending waiter and rejects invalid periods", function()
        run("start_pending_close", "pending-close-ok")
    end)
end)
