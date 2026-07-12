local module_path, scenario = assert(arg[1]), assert(arg[2])
local cases = assert(package.loadlib(module_path,
    "luaopen_phase5_net_faults"))()
local uv = require "titan.uv"

local function describe(err)
    local parts = { "type=" .. type(err), "value=" .. tostring(err) }
    for _, key in ipairs({ "name", "code", "message", "operation",
                           "subject", "reason" }) do
        local ok, value = pcall(function() return err[key] end)
        if ok and value ~= nil then
            parts[#parts + 1] = key .. "=" .. tostring(value)
        end
    end
    return table.concat(parts, ", ")
end

local function checked(stage, func)
    local ok, result = pcall(func)
    if not ok then error(stage .. ": " .. describe(result), 0) end
    return result
end

local task = assert(cases[scenario]())
checked("uv.loop failed", uv.loop)
local result = checked("Task join failed", function() return task:join() end)
local pending, resources = cases.counters()
assert(pending == 0, "net request owners remained rooted: " .. pending)
assert(resources == 0, "TCP resources remained rooted: " .. resources)
assert(not cases.runtime_active(), "completed libuv Runtime remained active")

local fresh = assert(uv.run(function() return "fresh-runtime-ok" end))
checked("fresh uv.loop failed", uv.loop)
assert(checked("fresh Task join failed", function()
    return fresh:join()
end) == "fresh-runtime-ok", "fresh Runtime returned the wrong result")
pending, resources = cases.counters()
assert(pending == 0, "fresh Runtime retained net request owners: " .. pending)
assert(resources == 0, "fresh Runtime retained TCP resources: " .. resources)
assert(not cases.runtime_active(), "fresh libuv Runtime remained active")
print("RESULT phase5 net fault passed: " .. result)
