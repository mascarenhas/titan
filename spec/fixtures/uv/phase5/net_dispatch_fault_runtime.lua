-- Runs deterministic invariant failures inside the isolated Phase 5 native
-- dispatchers. Each case must return through libuv, drain the fatal Runtime,
-- and preserve the original Titan traceback before a fresh Runtime is used.
local module_path, scenario = assert(arg[1]), assert(arg[2])
local cases = assert(package.loadlib(module_path,
    "luaopen_phase5_net_faults"))()
local titan = require "titan"
local uv = require "titan.uv"

local expected = {
    schedule_dispatch_dns_after_free = {
        stage = "dns-after-free", dispatch = "uv.dns_dispatch",
        dns = 1, connect = 0, write = 0, output = 0,
        closes = 0, dns_result = true,
    },
    schedule_dispatch_unpublished_connect = {
        stage = "connect-before-publish", dispatch = "uv.connect_dispatch",
        dns = 1, connect = 1, write = 0, output = 0,
        closes = 1, unpublished = true,
    },
    schedule_dispatch_published_write = {
        stage = "write-before-unlink", dispatch = "uv.write_dispatch",
        dns = 0, connect = 0, write = 1, output = 1,
        closes = 2, write_callback = true,
    },
    schedule_dispatch_tcp_read = {
        stage = "tcp-read-after-root-clear", dispatch = "uv.tcp_dispatch",
        dns = 0, connect = 0, write = 1, output = 1,
        closes = 2, read_callback = true,
    },
    schedule_dispatch_tcp_close = {
        stage = "tcp-close-after-terminal", dispatch = "uv.tcp_dispatch",
        dns = 0, connect = 0, write = 0, output = 0,
        closes = 1, close_fault = true,
    },
}

local want = assert(expected[scenario], "unknown net dispatcher fault case")
local task = assert(cases[scenario]())
local ok, failure = pcall(uv.loop)
assert(not ok, want.stage .. " did not become Runtime-fatal")
local message = "phase5-forced-net-" .. want.stage ..
    "-dispatcher-failure"
assert(tostring(failure):find(message, 1, true), tostring(failure))
local trace = titan.backtrace()
assert(type(trace) == "string" and
       trace:find("in " .. want.dispatch, 1, true), tostring(trace))

assert(not uv.__test_phase5_dispatch_fault_pending(),
    "one-shot dispatcher fault remained armed")
assert(uv.__test_phase5_dispatch_fault_hits() == 1,
    "dispatcher fault did not fire exactly once")
assert(uv.__test_phase5_net_retires("dns") == want.dns,
    "DNS request retirement count changed")
assert(uv.__test_phase5_net_retires("connect") == want.connect,
    "connect request retirement count changed")
assert(uv.__test_phase5_net_retires("write") == want.write,
    "write request retirement count changed")
assert(uv.__test_phase5_net_retires("shutdown") == 0,
    "unexpected shutdown request was retired")
assert(uv.__test_phase5_output_unlinks() == want.output,
    "network output operation was not unlinked exactly once")
assert(uv.__test_phase5_tcp_close_starts() == want.closes,
    "each initialized TCP handle was not closed exactly once")
assert(uv.__test_phase5_tcp_close_callbacks() == want.closes,
    "each TCP close did not consume exactly one callback")
assert(uv.__test_phase5_tcp_unlinks() == want.closes,
    "each TCP owner was not unlinked exactly once")

if want.dns_result then
    assert(uv.__test_phase5_dns_callbacks() == 1)
    assert(uv.__test_phase5_dns_nonnull_results() == 1,
        "DNS fault did not capture a borrowed addrinfo result")
    assert(uv.__test_phase5_dns_release_calls() == 1,
        "borrowed addrinfo result was not freed exactly once")
elseif want.unpublished then
    assert(uv.__test_phase5_dns_callbacks() == 1)
    assert(uv.__test_phase5_connect_callbacks() == 1)
    assert(uv.__test_phase5_connect_publications() == 0,
        "faulted connect published its private TCP handle")
elseif want.write_callback then
    assert(uv.__test_phase5_write_callbacks() == 1,
        "faulted write did not consume one native callback")
elseif want.read_callback then
    assert(uv.__test_phase5_tcp_read_callbacks() == 1,
        "faulted read did not consume one native callback")
    assert(uv.__test_phase5_write_callbacks() == 1,
        "read trigger write did not consume one native callback")
elseif want.close_fault then
    assert(uv.__test_phase5_tcp_close_callbacks() == 1,
        "faulted terminal close callback ran more than once")
end

assert(task:status() ~= "new" and task:status() ~= "ready" and
       task:status() ~= "waiting", "faulted Task remained suspended")
local pending, resources = cases.counters()
assert(pending == 0, "fatal Runtime retained request owners: " .. pending)
assert(resources == 0, "fatal Runtime retained TCP owners: " .. resources)
assert(not cases.runtime_active(), "fatal Runtime remained active")

local fresh = assert(uv.run(function() return "fresh-runtime-ok" end))
uv.loop()
assert(fresh:join() == "fresh-runtime-ok")
pending, resources = cases.counters()
assert(pending == 0 and resources == 0,
    "fresh Runtime retained network owners")
assert(not cases.runtime_active(), "fresh Runtime remained active")
print("RESULT Phase 5 dispatcher repair passed: " .. want.stage)
