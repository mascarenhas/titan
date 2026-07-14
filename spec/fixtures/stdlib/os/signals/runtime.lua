local uv = require "titan.uv"
local cases = require "os_signal_cases"

local function run(task, expected)
    uv.loop()
    assert(task:join() == expected)
end

-- Independent Runtime generations exercise one-shot delivery, cancellation,
-- GC, validation, and complete public shutdown with no private counters.
run(cases.schedule_one_shot("usr1"), "usr1")
run(cases.schedule_one_shot("usr2"), "usr2")
run(cases.schedule_cancelled_wait(), "cancelled-signal-wait-ok")
run(cases.schedule_sent_then_cancelled_wait(),
    "sent-then-cancelled-signal-wait-ok")
run(cases.schedule_generational_gc(), "signal-generational-gc-ok")
run(cases.schedule_validation_rejections(),
    "signal-validation-rejections-ok")

print("RESULT os signal runtime passed")
