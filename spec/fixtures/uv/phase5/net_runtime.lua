local module_path, scenario = assert(arg[1]), assert(arg[2])
local cases = assert(package.loadlib(module_path, "luaopen_phase5_net_cases"))()
local uv = require "titan.uv"

local function run(name)
    local task = assert(cases[name]())
    uv.loop()
    return task:join()
end

if scenario == "core" then
    assert(run("schedule_ipv4_core") == "ipv4-core-ok")
    assert(run("schedule_partial_and_excess") == "partial-excess-ok")
    assert(run("schedule_fifo_and_shutdown") == "fifo-shutdown-ok")
    print("RESULT phase5 net core passed")
elseif scenario == "waiters" then
    assert(run("schedule_accept_and_read_cancellation") ==
        "waiter-cancellation-ok")
    assert(run("schedule_bounded_accept_queue") == "bounded-accept-ok")
    print("RESULT phase5 net waiters passed")
elseif scenario == "dns-ipv6" then
    assert(run("schedule_localhost_retry") == "localhost-retry-ok")
    local ipv6 = run("schedule_ipv6_optional")
    assert(ipv6 == "ipv6-ok" or ipv6:match("^ipv6%-unavailable:"), ipv6)
    print("RESULT phase5 net DNS and IPv6 passed: " .. ipv6)
elseif scenario == "gc-sequential" then
    local leaked = run("schedule_leaked_connection")
    local weak = setmetatable({
        connection = leaked,
        server = cases.retained_server_value(),
    }, { __mode = "v" })
    leaked = nil
    assert(run("schedule_stale_rejection") == "stale-rejected")
    cases.drop_retained()
    collectgarbage("collect")
    collectgarbage("collect")
    assert(weak.connection == nil,
        "closed old-generation Connection stayed rooted")
    assert(weak.server == nil,
        "closed old-generation Server stayed rooted")
    print("RESULT phase5 net GC and sequential sessions passed")
else
    error("unknown scenario " .. scenario)
end
