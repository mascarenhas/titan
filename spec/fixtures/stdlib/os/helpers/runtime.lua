local temp = assert(arg[1], "missing OS-helper temporary directory")
local envname = assert(arg[2], "missing OS-helper environment name")
local lfs = require "lfs"
local lua_os = os
local cases = require "os_helper_cases"

local original_cwd = lfs.currentdir()
local original_env = lua_os.getenv(envname)
local alternate_cwd = temp .. "/cwd"
assert(lfs.mkdir(alternate_cwd))

assert(cases.exercise_environment(envname) == "environment-helpers-ok")
assert(cases.exercise_nul_rejections(envname, temp) ==
    "os-nul-rejections-ok")
assert(cases.exercise_paths_and_identity(alternate_cwd) ==
    "path-and-identity-helpers-ok")
assert(lfs.currentdir() == original_cwd)
assert(lua_os.getenv(envname) == original_env)

print("RESULT os synchronous helpers passed")
