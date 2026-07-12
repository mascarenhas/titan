local module_path = assert(arg[1], "missing process fault module")
local scenario = assert(arg[2], "missing process fault scenario")
local child = assert(arg[3], "missing owned process child")
local cases = assert(package.loadlib(
    module_path, "luaopen_phase6_process_faults"))()
local uv = require "titan.uv"

local function counter(name)
    return uv.__test_phase6_process_counter(name)
end

local function assert_drained(stage)
    assert(not uv.__test_phase6_process_fault_pending(),
        stage .. " left a one-shot fault pending")
    assert(uv.__test_phase6_process_resources() == 0,
        stage .. " retained a ProcessControl")
    assert(uv.__test_phase6_process_requests() == 0,
        stage .. " retained a process request owner")
    assert(not uv.__test_phase6_has_active_runtime(),
        stage .. " retained its Runtime")
    assert(counter("close-before-exit") == 0,
        stage .. " closed a published live Process")
end

local function run_success(name, expected, ...)
    local task = assert(cases[name](...))
    uv.loop()
    assert(task:status() == "succeeded", task:status())
    assert(task:join() == expected)
    assert_drained(name)
end

if scenario == "setup" then
    local stages = {
        { "stdio", "process.stdio", 0, 0, 0, 0, 0, 0, 0 },
        { "stdin-init", "process.stdin.init", 1, 0, 0, 0, 0, 0, 0 },
        { "stdout-init", "process.stdout.init", 2, 1, 0, 0, 0, 0, 1 },
        { "stderr-init", "process.stderr.init", 3, 2, 0, 0, 0, 0, 2 },
        { "stdin-open", "process.stdin.open", 3, 3, 1, 0, 0, 0, 3 },
        { "stdout-open", "process.stdout.open", 3, 3, 2, 1, 0, 0, 3 },
        { "stderr-open", "process.stderr.open", 3, 3, 3, 2, 0, 0, 3 },
        { "spawn", "process.spawn", 3, 3, 3, 3, 0, 0, 3 },
        { "raw-close", "process.stdio.close", 3, 3, 3, 3, 1, 1, 3 },
    }
    for _, item in ipairs(stages) do
        uv.__test_phase6_reset_process_state()
        local task = assert(cases.schedule_setup_failure(child, item[1]))
        uv.loop()
        assert(task:status() == "succeeded", item[1] .. ": " .. task:status())
        assert(task:join() == item[2], item[1] .. " reported wrong operation")
        assert(counter("stdio-attempts") == 1)
        assert(counter("stdio-native") == 1)
        assert(counter("init-attempts") == item[3])
        assert(counter("init-native") == item[4])
        assert(counter("open-attempts") == item[5])
        assert(counter("open-native") == item[6])
        assert(counter("spawn-native") == item[7])
        assert(counter("native-initialized") == item[8])
        assert(counter("pipe-close-callbacks") == item[9])
        if item[1] == "raw-close" then
            assert(counter("spawn-attempts") == 1)
            assert(counter("exit-callbacks") == 1)
            assert(counter("process-close-callbacks") == 1)
        elseif item[1] == "spawn" then
            assert(counter("spawn-attempts") == 1)
            assert(counter("process-close-callbacks") == 0)
            assert(counter("exit-callbacks") == 0)
        else
            assert(counter("spawn-attempts") == 0)
            assert(counter("process-close-callbacks") == 0)
            assert(counter("exit-callbacks") == 0)
        end
        assert_drained("setup " .. item[1])
    end
    print("RESULT phase6 process setup faults passed")
elseif scenario == "missing" then
    uv.__test_phase6_reset_process_state()
    run_success("schedule_missing_executable",
        "missing-executable-cleaned", child)
    assert(counter("spawn-native") == 1)
    assert(counter("native-initialized") == 1)
    assert(counter("exit-callbacks") == 0,
        "failed spawn unexpectedly received an exit callback")
    assert(counter("process-close-callbacks") == 1,
        "initialized failed-spawn handle did not close")
    assert(counter("pipe-close-callbacks") == 3,
        "failed spawn did not drain all initialized pipes")
    print("RESULT phase6 failed spawn lifecycle passed")
elseif scenario == "ordering" then
    uv.__test_phase6_reset_process_state()
    run_success("schedule_live_ordering", "live-ordering-cleaned", child)
    assert(counter("exit-callbacks") == 1)
    assert(counter("process-close-callbacks") == 1)
    assert(counter("pipe-close-callbacks") == 3)
    print("RESULT phase6 process callback ordering passed")
elseif scenario == "write" then
    uv.__test_phase6_reset_process_state()
    run_success("schedule_write_rejection",
        "write-rejection-cleaned", child)
    assert(counter("write-attempts") == 1)
    assert(counter("write-native") == 0)
    assert(counter("write-callbacks") == 0)
    assert(counter("stdin-close-transitions") == 1)
    print("RESULT phase6 process write rejection passed")
elseif scenario == "inflight-write" then
    uv.__test_phase6_reset_process_state()
    run_success("schedule_inflight_write_cancel_gc",
        "inflight-process-write-cancelled", child)
    assert(uv.__test_phase6_inflight_process_write_observed(),
        "post-submission owner observation did not run")
    collectgarbage("collect")
    collectgarbage("collect")
    assert(uv.__test_phase6_inflight_process_write_roots_released(),
        "terminal process write owner graph stayed reachable")
    assert(counter("write-attempts") == 2,
        "cancelled and follow-up writes were not both attempted")
    assert(counter("write-native") == 2,
        "cancelled and follow-up writes were not both submitted")
    assert(counter("write-callbacks") == 2,
        "each submitted process write did not consume one callback")
    assert(counter("stdin-close-transitions") == 1)
    assert(counter("exit-callbacks") == 1)
    assert(counter("process-close-callbacks") == 1)
    assert(counter("pipe-close-callbacks") == 3,
        "process pipes did not all drain after in-flight cancellation")
    print("RESULT phase6 in-flight process write cancellation passed")
elseif scenario == "close" then
    uv.__test_phase6_reset_process_state()
    run_success("schedule_close_transition_failure",
        "stdin-close-transition-cleaned", child)
    assert(counter("stdin-close-transitions") == 1)
    assert(counter("pipe-close-callbacks") == 3)
    print("RESULT phase6 ordered stdin close fault passed")
elseif scenario == "communicate-helper" then
    uv.__test_phase6_reset_process_state()
    run_success("schedule_communicate_helper_failure",
        "communicate-helper-cleaned", child)
    assert(counter("write-attempts") >= 2,
        "communicate did not submit its writer and follow-up writer")
    assert(counter("write-native") + 1 == counter("write-attempts"),
        "exactly one communicate write was not rejected")
    print("RESULT phase6 communicate helper fault passed")
elseif scenario == "communicate-start" then
    uv.__test_phase6_reset_process_state()
    run_success("schedule_communicate_start_failure",
        "communicate-start-cleaned", child)
    assert(counter("helper-starts") == 8,
        "both communicate calls did not start four helpers")
    assert(counter("helper-completions") == 8,
        "helper-start cleanup did not complete every helper")
    print("RESULT phase6 communicate helper-start fault passed")
elseif scenario:match("^callback%-") then
    local stage = scenario:sub(#"callback-" + 1)
    uv.__test_phase6_reset_process_state()
    local task = assert(cases.schedule_callback_failure(child, stage))
    local ok, failure = pcall(uv.loop)
    assert(not ok, stage .. " callback failure was not Runtime-fatal")
    local expected = stage == "process-close" and
        "phase6-forced-process-close-callback-failure" or
        "phase6-forced-process-" .. stage .. "-callback-failure"
    assert(tostring(failure):find(expected, 1, true), tostring(failure))
    assert(not uv.__test_phase6_process_fault_pending())
    assert_drained("callback " .. stage)
    if stage == "exit" then
        assert(counter("exit-callbacks") == 1)
    elseif stage == "process-close" then
        assert(counter("process-close-callbacks") == 1)
    elseif stage == "pipe-close" then
        assert(counter("pipe-close-callbacks") >= 1)
    elseif stage == "pipe-read" then
        assert(counter("pipe-read-callbacks") == 1)
    elseif stage == "write" then
        assert(counter("write-callbacks") == 1)
    elseif stage == "grace" then
        assert(counter("grace-callbacks") == 1)
    end
    assert(task:status() == "cancelled" or task:status() == "failed" or
           task:status() == "succeeded", task:status())
    print("RESULT phase6 process callback fault passed: " .. stage)
else
    error("unknown Phase 6 process fault scenario: " .. scenario)
end
