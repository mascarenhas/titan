-- Runs only against the generated __test_* uv variant.
local uv = require "titan.uv"
local timer = require "titan.timer"

local mainish = uv.__test_run_main(function()
    timer.yield()
    error("main-terminal-first")
end)
uv.run(function() pcall(mainish.join, mainish) end)
uv.__test_fail_next_join_wake()
local ok, err = pcall(uv.loop)
assert(not ok)
assert(tostring(err):find("main-terminal-first", 1, true))
print("RESULT main terminal failure kept first-error precedence")
