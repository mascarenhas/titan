local lua_coroutine = require "coroutine"
local uv = require "titan.uv"

local child = lua_coroutine.create(function()
    return pcall(uv.loop)
end)
local resumed, ok, err = lua_coroutine.resume(child)
assert(resumed)
assert(not ok)
assert(tostring(err):find("main thread", 1, true), tostring(err))

-- The main-thread no-Runtime case remains a harmless no-op.
assert(uv.loop() == nil)
print("RESULT pre-Runtime child loop was rejected")
