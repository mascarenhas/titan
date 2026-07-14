local module_path = assert(arg[1], "missing process cases module")
local scenario = assert(arg[2], "missing process scenario")
local child = assert(arg[3], "missing owned process child")
local envname = assert(arg[4], "missing process environment name")
local cases = assert(package.loadlib(
    module_path, "luaopen_os_process_cases"))()
local uv = require "titan.uv"

local function run(name, expected, ...)
    local task = assert(cases[name](...))
    uv.loop()
    assert(task:join() == expected)
end

if scenario == "spawn-status" then
    run("schedule_spawn_and_metadata", "spawn-metadata-ok",
        child, envname)
    run("schedule_exit_statuses", "exit-statuses-ok", child)
    print("RESULT os process spawn and status passed")
elseif scenario == "stdio" then
    run("schedule_binary_fifo", "binary-fifo-ok", child)
    run("schedule_queued_write_cancellation",
        "queued-write-cancellation-ok", child)
    print("RESULT os process stdio passed")
elseif scenario == "wait-read" then
    run("schedule_wait_and_read_cancellation",
        "wait-read-cancellation-ok", child)
    print("RESULT os process wait and read passed")
elseif scenario == "communicate" then
    run("schedule_communicate_success", "communicate-success-ok", child)
    print("RESULT os process communicate passed")
elseif scenario == "communicate-failure" then
    run("schedule_communicate_failure", "communicate-failure-ok", child)
    run("schedule_communicate_cancellation",
        "communicate-cancellation-ok", child)
    print("RESULT os process communicate failure and cancellation passed")
elseif scenario == "shutdown" then
    local pid_path = module_path .. ".shutdown.pid"
    run("schedule_forced_runtime_shutdown",
        "forced-runtime-shutdown-ready", child, pid_path)
    local pid_file = assert(io.open(pid_path, "rb"))
    local pid = assert(tonumber(assert(pid_file:read("*l"))))
    assert(pid_file:close())
    -- This host-side probe is intentionally POSIX-only: Linux and macOS are
    -- the supported stdlib platforms. Exit 1 means the reaped PID no longer
    -- exists; shell lookup/execution failures (126/127) must not false-pass.
    local alive, kind, status = os.execute("kill -0 " .. pid ..
        " >/dev/null 2>&1")
    assert(alive == nil and kind == "exit" and status == 1,
        "forced-shutdown child was live/unreaped or kill probe failed: " ..
        tostring(alive) .. "/" .. tostring(kind) .. "/" .. tostring(status))
    assert(os.remove(pid_path))
    local weak = setmetatable({
        process = cases.retained_process_value(),
    }, { __mode = "v" })
    run("schedule_stale_process_rejection",
        "stale-process-rejected", child)
    collectgarbage("collect")
    collectgarbage("collect")
    assert(weak.process == nil,
        "closed old-generation Process stayed rooted")
    print("RESULT os forced process shutdown passed")
else
    error("unknown process scenario " .. scenario)
end
