-- Run the ordinary multi-root compiler orchestration with the isolated paths
-- used by async standard-library specs. The parent sets CWD to the workspace,
-- so the grouped provider, archive, shims, and generated sources stay private.
local repo = assert(arg[1])
local source_root = assert(arg[2])
local runtime_root = assert(arg[3])
package.path = repo .. "/?.lua;" .. repo .. "/?/init.lua;" .. package.path

local driver = require "titan-compiler.driver"
driver.TITAN_SOURCE_PATH = source_root
driver.LUA_SOURCE_PATH = repo .. "/lua-5.5.1/src/"
driver.TITAN_RUNTIME_PATH = runtime_root .. "/"
driver.LIBBACKTRACE_PATH = repo .. "/libbacktrace"

local forwarded = {}
for index = 4, #arg do forwarded[#forwarded + 1] = arg[index] end
arg = forwarded
assert(loadfile(repo .. "/titanc"))()
