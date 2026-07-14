local uv = require "titan.uv"
local timer = require "titan.timer"
local cases = require "timer_recurring_cases"

local ticks = cases.schedule_four_ticks()
local close = cases.schedule_close_waiter()
local dropped = cases.schedule_dropped_ticks()
local turns = cases.schedule_zero_turns()
local second_waiter = cases.schedule_second_waiter_rejected()
local ok, err = pcall(timer.ticker, 0)
assert(not ok and tostring(err):find("positive", 1, true))

uv.loop()
assert(ticks:join() == 4)
assert(close:join() == false)
assert(dropped:join() == "dropped-empty-ticks")
assert(turns:join() == "zero-turns-ok")
assert(second_waiter:join() == "second-waiter-rejected")
print("RESULT timer recurring handles passed")
