local root = assert(arg[1], "missing Phase 4 temp directory")
local uv = require "titan.uv"
local cases = require "phase4_race_cases"

-- A terminal Task is immutable: cancelling it after loop teardown must not
-- allocate another native owner or replace its result/status.
local completed = cases.schedule_completion()
uv.loop()
assert(completed:status() == "succeeded")
assert(completed:join() == "completion-wins")
local owner_count = uv.__test_phase4_owner_starts()
completed:cancel("too-late")
assert(uv.__test_phase4_owner_starts() == owner_count)
assert(completed:status() == "succeeded")
assert(completed:join() == "completion-wins")

local sticky = cases.schedule_sticky_zero_allocation()
uv.loop()
local sticky_ok, sticky_error = pcall(sticky.join, sticky)
assert(not sticky_ok and sticky_error.reason == "sticky-zero-allocation")
local catches, before, after = cases.sticky_metrics()
assert(catches == 2)
assert(before == after, "sticky await allocated a native owner")

local delayed = cases.schedule_delayed_ticker_cancellation()
uv.loop()
assert(delayed:join() == "delayed-ticker-cancellation-ok")

local concurrent = cases.schedule_concurrent_public_error()
uv.loop()
assert(concurrent:join() == "concurrent-public-error-ok")

local cross_generation = cases.schedule_cross_generation_graph(root)
uv.loop()
assert(cross_generation:join() == "cross-generation-graph-ok")

local late_fs = cases.schedule_late_fs_cancellation(root, false)
uv.loop()
assert(late_fs:join() == "late-fs-too-late-cancellation-ok")
assert(uv.__test_phase4_fs_physical_callbacks() == 1)
assert(uv.__test_phase4_fs_deliveries() == 1)
assert(uv.__test_phase4_fs_cancel_calls() == 1)
assert(uv.__test_phase4_fs_cancel_status() < 0)
assert(uv.__test_phase4_fs_cleanups() == 1)

local cancelled_fs = cases.schedule_late_fs_cancellation(root, true)
uv.loop()
assert(cancelled_fs:join() == "late-fs-success-cancellation-ok")
assert(uv.__test_phase4_fs_physical_callbacks() == 1)
assert(uv.__test_phase4_fs_deliveries() == 1)
assert(uv.__test_phase4_fs_cancel_calls() == 1)
assert(uv.__test_phase4_fs_cancel_status() == 0)
assert(uv.__test_phase4_fs_cleanups() == 1)

local late_open_path = root .. "/late-cancelled-open.dat"
local late_open = cases.schedule_late_open_cancellation(late_open_path)
uv.loop()
assert(late_open:join() == "late-successful-open-cancellation-ok")
assert(uv.__test_phase4_fs_open_successes() == 1)
assert(uv.__test_phase4_fs_open_publications() == 0)
assert(uv.__test_phase4_fs_internal_close_enqueues() == 1)
assert(uv.__test_phase4_fs_internal_close_callbacks() == 1)
assert(uv.__test_phase4_fs_cleanups() == 2)
assert(uv.__test_phase4_fs_pending_roots() == 0)
assert(uv.__test_phase4_file_roots() == 0)
assert(not uv.__test_phase4_runtime_active())
assert(os.remove(late_open_path))

print("RESULT phase4 race and GC cases passed")
