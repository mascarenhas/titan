local scenario = assert(arg[1], "missing Phase 3 fs scenario")
local root = assert(arg[2], "missing Phase 3 temp directory")
local uv = require "titan.uv"
local timer = require "titan.timer"
local fs = require "titan.fs"
local cases = require "phase3_fs_cases"

assert(type(fs) == "userdata")

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function shell_success(command)
    local ok, _, status = os.execute(command)
    return ok == true or status == 0
end

local function chmod(path, mode)
    assert(shell_success("chmod " .. mode .. " " .. shell_quote(path)),
        "could not chmod filesystem test directory")
end

if scenario == "core" then
    local unit = "A\0B\255tail"
    local payload = unit:rep(32769) -- comfortably larger than one I/O chunk
    local symlink_target = root .. "/stat-target.dat"
    local symlink_path = root .. "/stat-link.dat"
    local target = assert(io.open(symlink_target, "wb"))
    assert(target:write("target"))
    assert(target:close())
    assert(shell_success("ln -s " .. shell_quote(symlink_target) .. " " ..
        shell_quote(symlink_path)),
        "could not create test symlink")
    local blocked_dir = root .. "/permission-denied"
    local blocked_path = blocked_dir .. "/target.dat"
    assert(shell_success("mkdir " .. shell_quote(blocked_dir)))
    local blocked = assert(io.open(blocked_path, "wb"))
    assert(blocked:write("blocked"))
    assert(blocked:close())
    chmod(blocked_dir, "000")
    -- A root-run test process can bypass mode checks. CI and supported normal
    -- developer runs exercise EACCES; privileged runs skip only this case.
    local permission_is_enforced = not shell_success(
        "test -e " .. shell_quote(blocked_path))
    local modes = cases.schedule_modes(root)
    local binary = cases.schedule_binary(root, payload)
    local paths = cases.schedule_paths(root)
    local symlink = cases.schedule_symlink_stat(symlink_target, symlink_path)
    local permission = permission_is_enforced and
        cases.schedule_permission_error(blocked_path) or nil
    local loop_ok, loop_error = pcall(uv.loop)
    chmod(blocked_dir, "700")
    assert(loop_ok, loop_error)
    assert(modes:join() == "modes-ok")
    assert(binary:join() == #payload)
    assert(paths:join() == "paths-ok")
    assert(symlink:join() == "symlink-stat-ok")
    if permission then
        assert(permission:join() == "permission-error-ok")
    end
    print("RESULT phase3 fs core passed")

elseif scenario == "fifo" then
    local task = cases.schedule_fifo_and_close(root)
    uv.loop()
    assert(task:join() == "fifo-close-ok")
    print("RESULT phase3 fs fifo passed")

elseif scenario == "gc-sequential" then
    collectgarbage("collect")
    collectgarbage("generational")
    local weak = setmetatable({}, { __mode = "v" })
    local holder = cases.schedule_retained_file(root)
    local observer = uv.run(function()
        while cases.retained() == nil do timer.yield() end
        weak.file = cases.retained()
        collectgarbage("collect")
        assert(weak.file ~= nil, "pending File was not rooted")
        return true
    end)
    uv.loop()
    assert(holder:join() == nil)
    assert(observer:join())
    holder, observer = nil, nil
    for _ = 1, 4 do collectgarbage("collect") end
    assert(weak.file == nil, "closed File was retained after session cleanup")

    local leaked_task = cases.schedule_leaked_file(root)
    uv.loop()
    local old_file = leaked_task:join()
    assert(old_file:is_closed(), "final-Task cleanup did not close idle File")
    old_file:close() -- idempotent after the Runtime generation is retired

    local stale = cases.schedule_stale_file(old_file)
    local second = cases.schedule_second_session(root)
    uv.loop()
    assert(stale:join() == "stale-file-rejected")
    assert(second:join() == "session-two")
    print("RESULT phase3 fs GC and sequential sessions passed")
else
    error("unknown Phase 3 fs scenario: " .. scenario)
end
