local scenario = assert(arg[1], "missing Phase 2 runtime scenario")
local lua_coroutine = require "coroutine"
local uv = require "titan.uv"
local timer = require "titan.timer"

assert(require "coroutine" == lua_coroutine)

if scenario == "scheduler" then
    -- A Lua child cannot drive the main-state loop even before a Runtime
    -- exists.  The same call on the main thread remains a harmless no-op.
    local before_runtime = lua_coroutine.create(function()
        return pcall(uv.loop)
    end)
    local resumed, loop_ok, loop_err =
        lua_coroutine.resume(before_runtime)
    assert(resumed and not loop_ok)
    assert(tostring(loop_err):find("main thread", 1, true),
        tostring(loop_err))
    assert(uv.loop() == nil)

    local behavior = require "phase2_behavior"
    behavior.reset()

    local nonblocking = behavior.schedule_nonblocking()
    assert(not behavior.did_start())
    assert(nonblocking:status() == "ready")

    local nested = behavior.schedule_nested_run()
    local tagged = behavior.schedule_shared_tag()
    local chain = behavior.schedule_callback_chain()
    local ordered = behavior.schedule_out_of_order()
    local traced = behavior.schedule_observed_trace()
    local observed = behavior.schedule_next_turn_observer()
    local child_loop = behavior.schedule_loop_rejection()
    local self_join = behavior.schedule_self_join()
    local multiple_joiners = behavior.schedule_multiple_joiners()
    local lookalike_cancelled = behavior.schedule_lookalike_cancelled()

    -- A non-UV Lua child is also forbidden from driving the main-state loop.
    local ordinary = lua_coroutine.create(function()
        return pcall(uv.loop)
    end)
    resumed, loop_ok, loop_err = lua_coroutine.resume(ordinary)
    assert(resumed and not loop_ok)
    assert(tostring(loop_err):find("main thread", 1, true))

    uv.loop()

    assert(nonblocking:join() == "nonblocking-ok")
    assert(behavior.did_start())
    assert(nested:join() == "nested-child-ok")
    assert(behavior.nested_did_start())
    assert(tagged:join() == "crossed-and-restored")
    assert(chain:join() == "AB")
    assert(ordered:join() == "out-of-order-ok")
    assert(observed:join() == "observed-before-promotion")
    assert(child_loop:join() == "nested-run-on-child-state")
    assert(self_join:join() == "self-join-rejected")
    assert(multiple_joiners:join() == "multiple-joiners-ok")
    assert(lookalike_cancelled:join() == "lookalike-cancelled-failed")

    local trace = traced:join()
    assert(type(trace) == "string" and #trace > 0)
    local origin = assert(trace:find("in phase2_behavior.fail_origin", 1, true),
        trace)
    local propagation = assert(trace:find(
        "in phase2_behavior.join_propagation", 1, true), trace)
    assert(origin < propagation, trace)
    print("RESULT phase2 scheduler passed")

elseif scenario == "cancellation" then
    local cancellation = require "phase2_cancellation"
    local sticky = cancellation.schedule_sticky()
    local before = cancellation.schedule_cancel_before_start()
    uv.loop()

    local cancelled = sticky:join()
    assert(cancelled.reason == "first-reason")
    assert(cancellation.catches() == 2)
    assert(sticky:status() == "succeeded") -- observer Task succeeded
    local early = before:join()
    assert(early.reason == "before-start")
    print("RESULT phase2 cancellation passed")

elseif scenario == "ticker" then
    local cases = require "phase2_ticker_cases"
    local ticks = cases.schedule_four_ticks()
    local close = cases.schedule_close_waiter()
    local dropped = cases.schedule_dropped_ticks()
    local turns = cases.schedule_zero_turns()
    local second_waiter = cases.schedule_second_waiter_rejected()
    local ok, err = pcall(timer.ticker, 0)
    assert(not ok and tostring(err):find("positive", 1, true))

    uv.loop()
    assert(ticks:join() == 4)
    assert(close:join() == false)
    assert(dropped:join() == "dropped-empty-ticks")
    assert(turns:join() == "zero-turns-ok")
    assert(second_waiter:join() == "second-waiter-rejected")
    print("RESULT phase2 ticker passed")

elseif scenario == "sequential-gc" then
    collectgarbage("collect")
    collectgarbage("generational")
    local weak = setmetatable({}, { __mode = "v" })
    local sentinel = { marker = "pending-root" }
    weak.sentinel = sentinel
    local function schedule_with_capture(captured)
        return uv.run(function()
            timer.yield()
            assert(weak.sentinel and
                weak.sentinel.marker == "pending-root")
            return captured
        end)
    end
    local task = schedule_with_capture(sentinel)
    weak.task = task
    sentinel = nil
    task = nil
    collectgarbage("collect")
    assert(weak.task ~= nil and weak.sentinel ~= nil)
    uv.loop()

    for _ = 1, 4 do collectgarbage("collect") end
    assert(weak.task == nil, "completed Task retained after loop close")
    assert(weak.sentinel == nil, "captured result retained after loop close")

    local old_ticker
    local first = uv.run(function()
        old_ticker = timer.ticker(1)
        assert(old_ticker:tick())
        return 11
    end)
    uv.loop()
    assert(first:join() == 11)
    assert(old_ticker:tick() == false)

    local second_started = false
    local second = uv.run(function()
        second_started = true
        timer.yield()
        return 23
    end)
    assert(not second_started and second:status() == "ready")
    uv.loop()
    assert(second_started and second:join() == 23)
    print("RESULT phase2 sequential GC sessions passed")
elseif scenario == "join-cycle" then
    local behavior = require "phase2_behavior"
    behavior.schedule_join_cycle()
    uv.loop()
    error("cyclic Task joins unexpectedly completed")
else
    error("unknown Phase 2 runtime scenario: " .. scenario)
end
