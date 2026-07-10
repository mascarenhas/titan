local uv = require "titan.uv"

local task = uv.run(function()
    uv.__test_init_untracked_timer()
    return "untracked-timer-initialized"
end)

local ok, err = pcall(uv.loop)
assert(not ok)
assert(type(err) == "userdata")
assert(err.name == "EBUSY")
assert(err.operation == "loop.close")
assert(err.subject == "remaining handles=1, first=timer", tostring(err.subject))
assert(task:join() == "untracked-timer-initialized")
print("RESULT untracked timer produced a bounded UV_EBUSY diagnostic")
