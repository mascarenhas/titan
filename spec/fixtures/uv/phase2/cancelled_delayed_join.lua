local uv = require "titan.uv"
local timer = require "titan.timer"

uv.__test_delay_next_join_wake(100)

local target = uv.run(function()
    timer.sleep(2)
    error("delayed-join-target-failure", 0)
end)

local observer = uv.run(function()
    return target:join()
end)

local canceller = uv.run(function()
    while target:status() ~= "failed" do timer.yield() end
    assert(observer:status() == "waiting")
    observer:cancel("delayed-observer-left")
    return "observer-cancelled-before-delivery"
end)

local ok, err = pcall(uv.loop)
assert(not ok)
assert(err == "delayed-join-target-failure", tostring(err))
assert(target:status() == "failed")
assert(observer:status() == "cancelled")
assert(canceller:join() == "observer-cancelled-before-delivery")
print("RESULT cancelled delayed join restored unobserved failure")
