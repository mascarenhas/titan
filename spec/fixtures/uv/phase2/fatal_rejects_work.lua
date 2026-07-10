local uv = require "titan.uv"
local timer = require "titan.timer"

local nested_started = false
local victim = uv.run(function()
    timer.sleep(1000)
    return "victim-finished"
end)

local actor = uv.run(function()
    uv.__test_fail_next_cancel_timer()
    victim:cancel("inject-infrastructure-fatal")
    local owner_starts = uv.__test_owner_starts()

    local run_ok, run_err = pcall(uv.run, function()
        nested_started = true
        return nil
    end)
    assert(not run_ok)
    assert(tostring(run_err):find("shutting down", 1, true), tostring(run_err))
    assert(uv.__test_owner_starts() == owner_starts)

    local yield_ok, yield_err = pcall(timer.yield)
    assert(not yield_ok)
    assert(tostring(yield_err):find("shutting down", 1, true),
        tostring(yield_err))
    assert(uv.__test_owner_starts() == owner_starts)
    return "fatal-rejections-observed"
end)

local ok, err = pcall(uv.loop)
assert(not ok)
assert(err.operation == "task.cancel.injected")
assert(not nested_started)
assert(actor:join() == "fatal-rejections-observed")
print("RESULT fatal callback remainder could not arm ordinary work")
