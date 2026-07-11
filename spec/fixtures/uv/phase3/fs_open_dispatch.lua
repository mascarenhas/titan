-- Runs only against the generated __test_fs_* uv variant. A successful open
-- reaches the trusted dispatcher catch before the allocating body transfers
-- its descriptor into a public File. Outer repair must close it exactly once.
local root = assert(arg[1], "missing Phase 3 temp directory")
local titan = require "titan"
local fs = require "titan.fs"
local timer = require "titan.timer"
local uv = require "titan.uv"

local path = root .. "/dispatcher-open.dat"
uv.__test_fs_reset_counters()
uv.__test_fs_fail_next_submit("dispatch:fs.open")
uv.run(function()
    fs.open(path, "w")
    error("injected open dispatcher failure returned to user code")
end)

local ok, err = pcall(uv.loop)
assert(not ok)
assert(tostring(err):find(
    "injected filesystem dispatcher failure", 1, true), tostring(err))
local trace = titan.backtrace()
assert(type(trace) == "string" and
       trace:find("in uv.fs_dispatch", 1, true), trace)

-- One successful open plus exactly one outer-repair close. Both requests own
-- one cleanup, and the internal close has reached its terminal callback.
assert(uv.__test_fs_submission_count() == 2)
assert(uv.__test_fs_cleanup_count() == 2)
assert(uv.__test_fs_current_active() == 0)
assert(uv.__test_fs_max_active_per_file() == 1)

-- The fatal session drained completely, so the same module can create a fresh
-- Runtime instead of retaining the repaired descriptor/loop graph.
local later = uv.run(function()
    timer.yield()
    return 41
end)
uv.loop()
assert(later:join() == 41)
assert(os.remove(path))
print("RESULT aborted successful open closed exactly once")
