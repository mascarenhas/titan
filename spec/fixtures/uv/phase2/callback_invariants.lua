local uv = require "titan.uv"
local timer = require "titan.timer"

uv.__test_reset_callback_counters()
local child_started = false
local parent = uv.run(function()
    local child = uv.run(function()
        child_started = true
        timer.yield()
        return 7
    end)
    assert(not child_started)
    timer.yield()
    return child:join()
end)
uv.loop()

assert(parent:join() == 7)
assert(child_started)
assert(uv.__test_callback_depth() == 0)
assert(uv.__test_max_callback_depth() == 1)
assert(uv.__test_uv_run_depth() == 0)
assert(uv.__test_max_uv_run_depth() == 1)
assert(uv.__test_non_main_dispatches() == 0)
assert(uv.__test_native_dispatches() >= 6)
print("RESULT native callbacks and outer uv_run stayed flat on main L")
