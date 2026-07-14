local root = assert(arg[1], "missing late-FS callback temp directory")
local uv = require "titan.uv"
local cases = require "uv_late_fs_callback_cases"

local cross_generation = cases.schedule_cross_generation_graph(root)
uv.loop()
assert(cross_generation:join() == "cross-generation-graph-ok")

local late_fs = cases.schedule_late_fs_cancellation(root)
uv.loop()
assert(late_fs:join() == "late-fs-cancellation-ok")

local late_open_path = root .. "/late-cancelled-open.dat"
local late_open = cases.schedule_late_open_cancellation(late_open_path)
uv.loop()
assert(late_open:join() == "late-successful-open-cancellation-ok")
assert(os.remove(late_open_path))

-- A fresh public session proves the cancelled-open File and request roots were
-- fully retired without inspecting private Runtime lists.
local next_session = uv.run(function()
    return "next-session-ok"
end)
uv.loop()
assert(next_session:join() == "next-session-ok")

print("RESULT uv late filesystem callbacks and rooting passed")
