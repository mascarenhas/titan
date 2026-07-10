-- Runs only against the generated __test_* uv variant.
local uv = require "titan.uv"
local timer = require "titan.timer"

local started = false
local finally_ran = false
local target = uv.run(function()
    started = true
    local ok = pcall(timer.sleep, 1000)
    assert(not ok)
    finally_ran = true
end)
uv.run(function()
    while not started do timer.yield() end
    uv.__test_fail_next_cancel_timer()
    target:cancel("fallback-stop")
end)
local ok = pcall(uv.loop)
assert(not ok)
assert(finally_ran and target:status() == "cancelled")
assert(uv.__test_fallback_cancel_drives() == 1)
print("RESULT outer cancel fallback passed")
