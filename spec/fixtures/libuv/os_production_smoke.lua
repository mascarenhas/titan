local mode = assert(arg[1], "expected libuv mode label")
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
local host, executable = system.hostname(), system.exepath()
assert(type(home) == "string" and #home > 0)
assert(type(temporary) == "string" and #temporary > 0)
assert(type(host) == "string" and #host > 0)
assert(type(executable) == "string" and #executable > 0)
assert(system.pid() > 0)
assert(system.ppid() > 0)

print("RESULT os production smoke " .. mode .. " passed")
