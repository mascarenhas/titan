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

-- The Runtime correctly retains an unknown live handle rather than freeing its
-- loop storage. Close this test-owned handle through public libuv, let the
-- outer driver finish the retained loop, then release the userdata root so the
-- sanitizer case proves the diagnostic without intentionally leaking memory.
uv.__test_close_untracked_timer()
local cleanup_ok, cleanup_err = pcall(uv.loop)
assert(not cleanup_ok)
assert(cleanup_err == err)
uv.__test_release_untracked_timer()
collectgarbage("collect")

print("RESULT untracked timer produced a bounded UV_EBUSY diagnostic")
