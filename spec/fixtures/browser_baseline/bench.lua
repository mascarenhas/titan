-- Lua micro-benchmarks for the #329 baseline, run by the fork's browser
-- interpreter (`lua-5.5.1/src/browser/lua.js`) under Node.
--
-- The fork interpreter is a separate scale measurement; its optimization is
-- the fork build's, not Titan's O1/O2 profile choice.
local function measure(name, action)
    local before = os.clock()
    action()
    io.write(name, "=", os.clock() - before, "\n")
end

local function increment(value) return value + 1 end

measure("lua.calls", function()
    local value = 0
    for _ = 1, 200000 do value = increment(value) end
    assert(value == 200000)
end)

measure("lua.closures", function()
    local function make_adder(base)
        return function(value) return value + base end
    end
    local total = 0
    for index = 1, 50000 do
        local add = make_adder(index)
        total = add(total)
    end
    assert(total > 0)
end)

measure("lua.arrays", function()
    local values = {}
    for _ = 1, 100 do
        for index = 1, 1000 do values[#values + 1] = index end
    end
    assert(#values == 100000)
end)

measure("lua.strings", function()
    local text = ""
    for _ = 1, 5000 do text = text .. "x" end
    assert(#text == 5000)
end)

measure("lua.coroutine_switch", function()
    local child = coroutine.create(function()
        for _ = 1, 20000 do coroutine.yield("tick") end
        return "done"
    end)
    for _ = 1, 20000 do assert(coroutine.resume(child) ~= nil) end
end)

io.write("lua.done=1\n")
-- The interpreter image keeps stdio buffered after main returns, so the host
-- sees nothing without an explicit flush.
io.flush()
