local envname = assert(arg[1], "missing Phase 6 environment name")
local lfs = require "lfs"
local lua_os = os
local uv = require "titan.uv"
local cases = require "phase6_os_helper_faults"

local original_cwd = lfs.currentdir()
local original_env = lua_os.getenv(envname)
assert(not uv.__test_phase6_has_active_runtime())

assert(cases.exercise_exepath_saturation() ==
    "exepath-saturation-retry-ok")
assert(cases.exercise_non_growing_enobufs(envname) ==
    "non-growing-enobufs-doubling-ok")
assert(cases.exercise_required_overflow() ==
    "required-size-overflow-ok")
assert(cases.exercise_allocation_overflow() ==
    "allocation-payload-overflow-ok")
assert(cases.exercise_retry_exhaustion() ==
    "os-buffer-retry-exhaustion-ok")

assert(not uv.__test_phase6_has_active_runtime(),
    "OS resize fault created a Runtime")
assert(lfs.currentdir() == original_cwd)
assert(lua_os.getenv(envname) == original_env)
print("RESULT phase6 OS helper faults passed")
