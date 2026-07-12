-- Runs only against the generated __test_* uv variant. Each scenario has a
-- fresh Lua state so observation policy and Runtime shutdown cannot leak
-- between lifecycle arms.
local scenario = assert(arg[1], "missing startup fault scenario")
local uv = require "titan.uv"

local user_code_ran = false
local function user_code()
    user_code_ran = true
    return "startup-user-code-ran"
end

local function assert_start_failure(task)
    assert(task:status() == "failed")
    assert(not user_code_ran)
    local joined, failure = pcall(task.join, task)
    assert(not joined)
    assert(failure.operation == "task.start")
    assert(failure.name == "ECANCELED")
end

if scenario == "loop-init" then
    uv.__test_fail_next_loop_init()
    local ok, failure = pcall(uv.run, user_code)
    assert(not ok)
    assert(failure.operation == "loop.init")
    assert(failure.name == "ECANCELED")
    assert(not user_code_ran)
    assert(uv.__test_loop_init_attempts() == 1)
    assert(uv.__test_loop_native_inits() == 0)
    assert(uv.__test_loop_init_releases() == 1)
    assert(uv.__test_task_creations() == 0)
    assert(uv.__test_owner_starts() == 0)
    assert(uv.__test_timer_init_attempts() == 0)
    assert(uv.__test_timer_resources() == 0)

    -- The failed allocation was not published as active_runtime; the one-shot
    -- fault can be followed immediately by an ordinary fresh session.
    local retry = uv.run(user_code)
    uv.loop()
    assert(retry:join() == "startup-user-code-ran")
elseif scenario == "timer-init" then
    uv.__test_fail_next_timer_init()
    local task = uv.run(user_code)

    -- The rejected OWNER_START was unlinked and released inline. The sole
    -- remaining resource is the ordinary unobserved-failure observation
    -- timer; no close callback is owed for a handle that never initialized.
    assert(task:status() == "failed")
    assert(not user_code_ran)
    assert(uv.__test_task_creations() == 1)
    assert(uv.__test_timer_init_attempts() == 2)
    assert(uv.__test_timer_native_inits() == 1)
    assert(uv.__test_timer_init_releases() == 1)
    assert(uv.__test_timer_start_attempts() == 1)
    assert(uv.__test_timer_native_starts() == 1)
    assert(uv.__test_timer_resources() == 1)
    assert(uv.__test_closing_timer_resources() == 0)
    assert(uv.__test_timer_close_callbacks() == 0)
    assert(uv.__test_start_owner_close_callbacks() == 0)

    collectgarbage("generational")
    collectgarbage("collect")
    assert(uv.__test_timer_resources() == 1)
    assert_start_failure(task)
    local ok, failure = pcall(uv.loop)
    assert(ok, tostring(failure))
    assert(uv.__test_timer_close_callbacks() == 1)
    assert(uv.__test_start_owner_close_callbacks() == 0)
    assert(uv.__test_timer_resources() == 0)
elseif scenario == "timer-start-observed" then
    uv.__test_fail_next_timer_start()
    local task = uv.run(user_code)

    -- uv_timer_init succeeded, so synchronous uv_timer_start rejection must
    -- retain a CLOSING owner until libuv delivers its close callback. The
    -- other linked owner is the observation deadline.
    assert(task:status() == "failed")
    assert(not user_code_ran)
    assert(uv.__test_task_creations() == 1)
    assert(uv.__test_timer_init_attempts() == 2)
    assert(uv.__test_timer_native_inits() == 2)
    assert(uv.__test_timer_init_releases() == 0)
    assert(uv.__test_timer_start_attempts() == 2)
    assert(uv.__test_timer_native_starts() == 1)
    assert(uv.__test_timer_resources() == 2)
    assert(uv.__test_closing_timer_resources() == 1)
    assert(uv.__test_timer_close_callbacks() == 0)

    collectgarbage("generational")
    collectgarbage("collect")
    assert(uv.__test_timer_resources() == 2)
    assert(uv.__test_closing_timer_resources() == 1)

    -- Joining before the observation turn permanently observes the failed
    -- Task, so loop shutdown only drains both rooted handles and succeeds.
    assert_start_failure(task)
    local ok, failure = pcall(uv.loop)
    assert(ok, tostring(failure))
    assert(uv.__test_timer_close_callbacks() == 2)
    assert(uv.__test_start_owner_close_callbacks() == 1)
    assert(uv.__test_timer_resources() == 0)
elseif scenario == "timer-start-unobserved" then
    uv.__test_fail_next_timer_start()
    local task = uv.run(user_code)
    assert(task:status() == "failed")
    assert(not user_code_ran)
    assert(uv.__test_timer_resources() == 2)
    assert(uv.__test_closing_timer_resources() == 1)

    collectgarbage("generational")
    collectgarbage("collect")
    assert(uv.__test_timer_resources() == 2)
    assert(uv.__test_closing_timer_resources() == 1)

    -- Merely retaining or inspecting a Task is not observation. Its next-turn
    -- deadline promotes the task.start Error, while shutdown still drains the
    -- initialized failed-start handle through the close callback.
    local ok, failure = pcall(uv.loop)
    assert(not ok)
    assert(failure.operation == "task.start")
    assert(failure.name == "ECANCELED")
    assert(not user_code_ran)
    assert(uv.__test_timer_close_callbacks() == 2)
    assert(uv.__test_start_owner_close_callbacks() == 1)
    assert(uv.__test_timer_resources() == 0)
else
    error("unknown startup fault scenario: " .. scenario)
end

print("RESULT startup fault passed: " .. scenario)
