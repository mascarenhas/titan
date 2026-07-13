local temp = assert(arg[1], "missing Phase 6 temporary directory")
local envname = assert(arg[2], "missing Phase 6 environment name")
local lfs = require "lfs"
local lua_os = os
local uv = require "titan.uv"
local cases = require "phase6_os_helper_cases"

local original_cwd = lfs.currentdir()
local original_env = lua_os.getenv(envname)

assert(not uv.__test_phase6_has_active_runtime())
assert(cases.exercise_environment(envname) == "environment-helpers-ok")
assert(cases.exercise_nul_rejections(envname, temp) ==
    "os-nul-rejections-ok")
assert(cases.exercise_paths_and_identity(temp .. "/titan") ==
    "path-and-identity-helpers-ok")
assert(not uv.__test_phase6_has_active_runtime(),
    "synchronous OS helper created a Runtime")
assert(lfs.currentdir() == original_cwd)
assert(lua_os.getenv(envname) == original_env)

uv.__test_phase6_reset_signal_state()
local signal = cases.schedule_signal_roundtrip()
uv.loop()
assert(signal:join() == "signal-between-os-helper-sessions-ok")
assert(uv.__test_phase6_signal_resources() == 0)
assert(not uv.__test_phase6_has_active_runtime())

-- The same synchronous functions remain usable after a complete asynchronous
-- Runtime generation has been created and torn down.
assert(cases.exercise_environment(envname) == "environment-helpers-ok")
assert(cases.exercise_paths_and_identity(temp .. "/titan") ==
    "path-and-identity-helpers-ok")
assert(not uv.__test_phase6_has_active_runtime())
assert(lfs.currentdir() == original_cwd)
assert(lua_os.getenv(envname) == original_env)

print("RESULT phase6 synchronous OS helpers passed")
