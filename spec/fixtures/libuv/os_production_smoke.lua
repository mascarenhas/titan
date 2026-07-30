local mode = assert(arg[1], "expected libuv mode label")
local process_child = arg[2]
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

    local main = async.run(function()
        -- Plain Lua tables are Maps, not Arrays. fs.list supplies a canonical
        -- {string} proxy that ordinary indexing can clear and refill.
        local process_args = fs.list(".")
        assert(type(process_args) == "userdata")
        for index = #process_args, 1, -1 do
            process_args[index] = nil
        end
        assert(#process_args == 0)

        process_args[1] = "echo"
        local output, diagnostics, status =
            system.communicate(process_child, process_args, payload)
        assert(output == payload)
        assert(diagnostics == "")
        assert(status.code == 0)
        assert(status.signal == nil)
        assert(status.signal_number == 0)

        process_args[1] = "exit"
        process_args[2] = "29"
        local exited = system.spawn(process_child, process_args)
        exited.stdin:close()
        assert(exited.stdout:read() == nil)
        assert(exited.stderr:read() == nil)
        local exit_status = exited:wait()
        assert(exit_status.code == 29)
        assert(exit_status.signal == nil)
        assert(exit_status.signal_number == 0)

        process_args[1] = "ready-wait"
        process_args[2] = nil
        local signalled = system.spawn(process_child, process_args)
        signalled.stdin:close()
        assert(signalled.stdout:read_until("\n") == "READY\n")
        signalled:kill("term")
        local signal_status = signalled:wait()
        assert(signal_status.code == 0)
        assert(signal_status.signal == "term")
        assert(signal_status.signal_number > 0)
        assert(signalled.stdout:read() == nil)
        assert(signalled.stderr:read() == nil)
        return output
    end)

    async.loop()
    assert(main:join() == payload)
    assert(require "os" == builtin)
    assert(package.loaded.os == builtin)
    assert(package.loaded["titan.os"] == system)
    print("RESULT os production process smoke " .. mode .. " passed")
end

print("RESULT os production smoke " .. mode .. " passed")
