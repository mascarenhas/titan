-- Raises inside the real timer_dispatch close branch. No C protected call.
local titan = require "titan"
local uv = require "titan.uv"
local timer = require "titan.timer"

uv.__test_fail_next_close_bookkeeping()
local task = uv.run(function() return "closed-before-retire" end)
local ok, err = pcall(uv.loop)
assert(not ok)
assert(tostring(err):find("injected close-bookkeeping failure", 1, true))
assert(task:status() == "succeeded")
assert(task:join() == "closed-before-retire")
local trace = titan.backtrace()
assert(type(trace) == "string" and
       trace:find("in uv.timer_dispatch", 1, true), trace)
assert(uv.__test_retired_closed_owners() >= 1)

-- The fatal session closed completely; a fresh session still works.
local later = uv.run(function()
    timer.yield()
    return 29
end)
uv.loop()
assert(later:join() == 29)
print("RESULT dispatcher trailing catch and owner retirement passed")
