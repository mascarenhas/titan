local module_path = assert(arg[1], "missing process cases module")
local scenario = assert(arg[2], "missing process scenario")
local child = assert(arg[3], "missing owned process child")
local envname = assert(arg[4], "missing process environment name")
local cases = assert(package.loadlib(
    module_path, "luaopen_phase6_process_cases"))()
local uv = require "titan.uv"

local function run(name, expected, ...)
    local task = assert(cases[name](...))
    uv.loop()
    assert(task:status() == "succeeded", task:status())
    assert(task:join() == expected)
    assert(not uv.__test_phase6_has_active_runtime(),
        "process scenario retained its Runtime")
end

if scenario == "spawn-status" then
    run("schedule_spawn_and_metadata", "spawn-metadata-ok",
        child, envname)
    run("schedule_exit_statuses", "exit-statuses-ok", child)
    print("RESULT phase6 process spawn and status passed")
elseif scenario == "stdio" then
    run("schedule_binary_fifo", "binary-fifo-ok", child)
    run("schedule_queued_write_cancellation",
        "queued-write-cancellation-ok", child)
    print("RESULT phase6 process stdio passed")
elseif scenario == "wait-read" then
    run("schedule_wait_and_read_cancellation",
        "wait-read-cancellation-ok", child)
    print("RESULT phase6 process wait and read passed")
elseif scenario == "communicate" then
    run("schedule_communicate_success", "communicate-success-ok", child)
    print("RESULT phase6 communicate success passed")
elseif scenario == "communicate-failure" then
    run("schedule_communicate_failure", "communicate-failure-ok", child)
    run("schedule_communicate_cancellation",
        "communicate-cancellation-ok", child)
    print("RESULT phase6 communicate failure and cancellation passed")
elseif scenario == "shutdown" then
    run("schedule_forced_runtime_shutdown",
        "forced-runtime-shutdown-ready", child)
    run("schedule_stale_process_rejection",
        "stale-process-rejected", child)
    print("RESULT phase6 forced process shutdown passed")
else
    error("unknown process scenario " .. scenario)
end
