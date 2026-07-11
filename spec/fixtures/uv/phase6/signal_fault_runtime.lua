local scenario = assert(arg[1], "missing Phase 6 signal fault scenario")
local uv = require "titan.uv"
local cases = require "phase6_signal_faults"

uv.__test_phase6_reset_signal_state()

if scenario == "init" then
    local task = cases.schedule_init_rejection()
    uv.loop()
    assert(task:join() == "signal-init-rejection-ok")
    assert(uv.__test_phase6_signal_init_attempts() == 1)
    assert(uv.__test_phase6_signal_native_inits() == 0)
    assert(uv.__test_phase6_signal_start_attempts() == 0)
    assert(uv.__test_phase6_signal_closes() == 0)
elseif scenario == "start" then
    local task = cases.schedule_start_rejection()
    uv.loop()
    assert(task:join() == "signal-start-rejection-ok")
    assert(uv.__test_phase6_signal_init_attempts() == 1)
    assert(uv.__test_phase6_signal_native_inits() == 1)
    assert(uv.__test_phase6_signal_start_attempts() == 1)
    assert(uv.__test_phase6_signal_native_starts() == 0)
    assert(uv.__test_phase6_signal_closes() == 1)
elseif scenario == "callback" then
    local task = cases.schedule_callback_failure()
    local ok, failure = pcall(uv.loop)
    assert(not ok)
    assert(tostring(failure):find(
        "phase6-forced-signal-callback-failure", 1, true))
    assert(task:status() == "cancelled" or task:status() == "failed")
    assert(uv.__test_phase6_signal_callbacks() == 1)
    assert(uv.__test_phase6_signal_closes() == 1)
elseif scenario == "close" then
    local task = cases.schedule_close_callback_failure()
    local ok, failure = pcall(uv.loop)
    assert(not ok)
    assert(tostring(failure):find(
        "phase6-forced-signal-close-callback-failure", 1, true))
    assert(task:status() == "succeeded")
    assert(task:join() == "usr2")
    assert(uv.__test_phase6_signal_callbacks() == 1)
    assert(uv.__test_phase6_signal_closes() == 1)
elseif scenario == "shutdown" then
    local task = cases.schedule_forced_shutdown()
    local ok, failure = pcall(uv.loop)
    assert(not ok)
    assert(tostring(failure):find(
        "phase6-forced-signal-runtime-shutdown", 1, true))
    assert(task:status() == "cancelled" or task:status() == "failed")
    assert(uv.__test_phase6_signal_callbacks() == 0)
    assert(uv.__test_phase6_signal_closes() == 1)
else
    error("unknown Phase 6 signal fault scenario: " .. scenario)
end

assert(uv.__test_phase6_signal_resources() == 0)
print("RESULT phase6 signal fault passed: " .. scenario)
