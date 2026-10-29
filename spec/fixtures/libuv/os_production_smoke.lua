local mode = assert(arg[1], "expected libuv mode label")
local process_child = arg[2]
-- The support module installs the Titan searcher in this plain Lua host.
require "titan"
local builtin = require "os"
local system = require "titan.os"

assert(type(builtin) == "table")
assert(type(system) == "userdata")
assert(require "os" == builtin)
assert(package.loaded.os == builtin)
assert(package.loaded["titan.os"] == system)

local key = "TITAN_OS_PRODUCTION_SMOKE_" .. tostring(system.pid())
local old = system.getenv(key)
system.setenv(key, "")
assert(system.getenv(key) == "")
local resized = string.rep(mode .. "-libuv", 1024)
system.setenv(key, resized)
assert(system.getenv(key) == resized)
if old == nil then
    system.unsetenv(key)
    assert(system.getenv(key) == nil)
else
    system.setenv(key, old)
    assert(system.getenv(key) == old)
end

local current = system.cwd()
assert(type(current) == "string" and #current > 0)
system.chdir(current)
assert(system.cwd() == current)
local home, temporary = system.homedir(), system.tmpdir()
local host = system.hostname()
assert(type(home) == "string" and #home > 0)
assert(type(temporary) == "string" and #temporary > 0)
assert(type(host) == "string" and #host > 0)
local exepath_ok, exepath_error = pcall(system.exepath)
assert(not exepath_ok)
assert(exepath_error ==
    "os.exepath is only available in a compiled Titan program")
assert(system.pid() > 0)
assert(system.ppid() > 0)

if process_child then
    local async = require "titan.async"
    local fs = require "titan.fs"
    local payload = mode .. "\0titan.os.process"
    for _ = 1, 14 do payload = payload .. payload end

    local function check_parent_stream(stream)
        assert(type(stream:is_tty()) == "boolean")
    end

    local main_result
    local main = async.run(function()
        check_parent_stream(system.stdin)
        check_parent_stream(system.stdout)
        check_parent_stream(system.stderr)

        local merged = system.popen(
            "printf '" .. mode .. "-stdout'; " ..
            "printf '" .. mode .. "-stderr' >&2")
        local merged_chunks = {}
        while true do
            local chunk = merged:read()
            if chunk == nil then break end
            merged_chunks[#merged_chunks + 1] = chunk
        end
        assert(table.concat(merged_chunks) ==
            mode .. "-stdout" .. mode .. "-stderr")
        local merged_status = merged:wait()
        assert(merged_status.code == 0)
        assert(merged_status.signal == nil)
        assert(merged_status.signal_number == 0)
        merged:close()

        -- Plain Lua tables are Maps, not Arrays. fs.list supplies a canonical
        -- {string} proxy that ordinary indexing can clear and refill.
        local process_args = fs.list(".")
        assert(type(process_args) == "userdata")
        for index = #process_args, 1, -1 do
            process_args[index] = nil
        end
        assert(#process_args == 0)

        process_args[1] = "echo"
        local detached = system.spawn(
            process_child, process_args,
            system.with_stdin, system.with_stdout,
            system.with_stderr)
        assert(detached:is_running())
        local writer = assert(detached.stdin)
        local reader = assert(detached.stdout)
        local error_reader = assert(detached.stderr)
        local weak = setmetatable({ process = detached }, { __mode = "v" })
        detached = nil
        collectgarbage("collect")
        collectgarbage("collect")
        assert(weak.process == nil)
        writer:write(payload)
        writer:close()
        assert(reader:read_until(payload) == payload)
        assert(reader:read() == nil)
        assert(error_reader:read() == nil)

        process_args[1] = "exit"
        process_args[2] = "29"
        local exited = system.spawn(process_child, process_args)
        assert(exited.stdin):close()
        assert(assert(exited.stdout):read() == nil)
        assert(assert(exited.stderr):read() == nil)
        local exit_status = exited:wait()
        assert(exit_status.code == 29)
        assert(exit_status.signal == nil)
        assert(exit_status.signal_number == 0)
        assert(not exited:is_running())

        process_args[1] = "ready-wait"
        process_args[2] = nil
        local signalled = system.spawn(process_child, process_args)
        assert(signalled.stdin):close()
        local signal_stdout = assert(signalled.stdout)
        local signal_stderr = assert(signalled.stderr)
        assert(signal_stdout:read_until("\n") == "READY\n")
        assert(signalled:is_running())
        signalled:kill("term")
        local signal_status = signalled:wait()
        assert(signal_status.code == 0)
        assert(signal_status.signal == "term")
        assert(signal_status.signal_number > 0)
        assert(not signalled:is_running())
        assert(signal_stdout:read() == nil)
        assert(signal_stderr:read() == nil)
        main_result = payload
    end)

    async.loop()
    assert(main:status():as_string() == "succeeded")
    assert(main_result == payload)
    assert(require "os" == builtin)
    assert(package.loaded.os == builtin)
    assert(package.loaded["titan.os"] == system)
    print("RESULT os production process smoke " .. mode .. " passed")
end

print("RESULT os production smoke " .. mode .. " passed")
