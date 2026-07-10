-- Exact run_internal(..., true) path used by bootstrap, exposed only by the
-- isolated variant.
local uv = require "titan.uv"
local timer = require "titan.timer"

local started = false
local main_task = uv.__test_run_main(function()
    started = true
    timer.sleep(1000)
    return "must-not-complete"
end)
uv.run(function()
    while not started do timer.yield() end
    uv.__test_cancel_main("main-cancelled")
end)

local ok, err = pcall(uv.loop)
assert(not ok)
assert(main_task:status() == "cancelled")
assert(err.reason == "main-cancelled")
local joined, joined_err = pcall(main_task.join, main_task)
assert(not joined and joined_err.reason == "main-cancelled")
print("RESULT main Task cancellation was reported")
