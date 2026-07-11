local uv = require "titan.uv"
local cases = require "phase6_signal_cases"

local function run(task, expected)
    uv.loop()
    assert(task:status() == "succeeded")
    assert(task:join() == expected)
    assert(uv.__test_phase6_signal_resources() == 0)
end

-- Two independent Runtime generations prove that the module-local tag and
-- counters survive while every session-local owner is released.
uv.__test_phase6_reset_signal_state()
run(cases.schedule_one_shot("usr1"), "usr1")
assert(uv.__test_phase6_signal_arms() == 1)
assert(uv.__test_phase6_signal_callbacks() == 1)
assert(uv.__test_phase6_signal_closes() == 1)
assert(uv.__test_phase6_signal_sends() == 1)

uv.__test_phase6_reset_signal_state()
run(cases.schedule_one_shot("usr2"), "usr2")
assert(uv.__test_phase6_signal_arms() == 1)
assert(uv.__test_phase6_signal_callbacks() == 1)
assert(uv.__test_phase6_signal_closes() == 1)

uv.__test_phase6_reset_signal_state()
run(cases.schedule_cancelled_wait(), "cancelled-signal-wait-ok")
assert(uv.__test_phase6_signal_arms() == 2)
assert(uv.__test_phase6_signal_callbacks() == 1)
assert(uv.__test_phase6_signal_closes() == 2)
assert(uv.__test_phase6_signal_sends() == 1)

uv.__test_phase6_reset_signal_state()
run(cases.schedule_sent_then_cancelled_wait(),
    "sent-then-cancelled-signal-wait-ok")
assert(uv.__test_phase6_signal_arms() == 1)
assert(uv.__test_phase6_signal_sends() == 1)
assert(uv.__test_phase6_signal_callbacks() <= 1)
assert(uv.__test_phase6_signal_closes() == 1)

uv.__test_phase6_reset_signal_state()
run(cases.schedule_generational_gc(), "signal-generational-gc-ok")
assert(uv.__test_phase6_signal_callbacks() == 1)
assert(uv.__test_phase6_signal_closes() == 1)

uv.__test_phase6_reset_signal_state()
run(cases.schedule_validation_rejections(),
    "signal-validation-rejections-ok")
assert(uv.__test_phase6_signal_init_attempts() == 0)
assert(uv.__test_phase6_signal_callbacks() == 0)
assert(uv.__test_phase6_signal_closes() == 0)

print("RESULT phase6 signal runtime passed")
