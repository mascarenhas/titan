-- Run with the selected installed Lua after setting arg[1] to an inherited
-- environment name and arg[2] to its exact UTF-8 value (including Unicode).
local platform = require "titan-compiler.platform"
local uv = require "luv"
assert(platform.windows, "this probe requires native Windows Lua")
assert(type(platform.getenv) == "function", "compiler environment fix is absent")
local inherited_name = assert(arg[1], "expected an inherited environment name")
local inherited_value = assert(arg[2], "expected its exact UTF-8 value")
assert(platform.getenv(inherited_name) == inherited_value,
    "compiler did not preserve the inherited Unicode environment value")

local name = "TITAN_COMPILER_ENV_PROBE_" .. uv.os_getpid() .. "_" .. os.time()
local original = platform.getenv(name)
local original_crt = os.getenv(name)
local ok, failure = xpcall(function()
    assert(uv.os_setenv(name, "initial"))
    assert(platform.getenv(name) == "initial")
    assert(uv.os_setenv(name, "updated 雪 Ω % !"))
    assert(platform.getenv(name) == "updated 雪 Ω % !")
    assert(os.getenv(name) == original_crt,
        "probe did not retain the independent CRT environment snapshot")
    assert(uv.os_setenv(name, ""))
    assert(platform.getenv(name) == "", "empty environment value became absent")
    assert(uv.os_unsetenv(name))
    assert(platform.getenv(name) == nil)
    assert(select("#", platform.getenv(name)) == 1)
end, debug.traceback)
if original == nil then assert(uv.os_unsetenv(name))
else assert(uv.os_setenv(name, original)) end
assert(platform.getenv(name) == original, "probe did not restore its process environment")
assert(platform.getenv(inherited_name) == inherited_value,
    "probe changed the inherited variable")
assert(ok, failure)
print("compiler Windows environment probe passed")
