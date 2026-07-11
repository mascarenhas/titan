-- Exercise destruction of a suspended tagged handler and its stacked child.
-- Under the sanitizer gate this runs with use-after-return and leak detection
-- enabled, so stale ASan fake-stack tokens become a deterministic failure.
local coroutine = require "titan.coroutine"
local tag_main = {}
local tag_child = {}
local stacked

do
    local handler = coroutine.create(function()
        local child = coroutine.create(function()
            return coroutine.yield("from-child", tag_main)
        end, tag_child)
        stacked = child
        return child:resume(nil, tag_child)
    end, tag_main)

    assert(handler:resume(nil, tag_main) == "from-child")
    assert(handler:status() == "suspended")
    assert(stacked:status() == "stacked")
    handler = nil
end

for _ = 1, 4 do collectgarbage("collect") end
assert(stacked:status() == "dead")
local ok, err = pcall(stacked.resume, stacked, nil, tag_child)
assert(not ok and tostring(err):find("Coroutine not suspended", 1, true),
    tostring(err))
stacked = nil
for _ = 1, 4 do collectgarbage("collect") end

print("RESULT phase4 stacked coroutine destruction passed")
