local uv = require "titan.uv"
local net = require "titan.net"
local timer = require "titan.timer"

assert(type(uv) == "userdata")
assert(type(net) == "userdata")

local mode = arg[1] or "unknown"
local payload = mode .. "\0titan.net"
local first_port = mode == "system" and 45000 or 45032
local last_port = first_port + 31

local main = uv.run(function()
    local server
    local port
    local last_error

    -- The public Server API intentionally exposes no bound-port test hook.
    -- Try a bounded fixed range so this exercises only the production facade.
    for candidate = first_port, last_port do
        local ok, result = pcall(net.listen, "127.0.0.1", candidate, 4)
        if ok then
            server = result
            port = candidate
            break
        end
        last_error = result
    end
    assert(server, "could not bind the loopback smoke range: " ..
        tostring(last_error))

    local peer_task = uv.run(function()
        local peer = server:accept()
        local request = peer:read_exactly(#payload)
        assert(request == payload)
        peer:write(request)
        peer:shutdown()
        peer:close()
        return request
    end)

    local client = net.connect("127.0.0.1", port)
    client:write(payload)
    local response = client:read_exactly(#payload)
    assert(response == payload)
    client:shutdown()
    client:close()

    assert(peer_task:join() == payload)

    if mode == "sanitizer" then
        local seed = "owned-write\0buffer:"
        local repetitions = 512 * 1024
        local payload_size = #seed * repetitions
        local followup = "write-after-cancel\0ok"
        local slow_peer = uv.run(function()
            local peer = server:accept()
            timer.sleep(100)
            local received = peer:read_exactly(payload_size)
            assert(received == string.rep(seed, repetitions))
            peer:write("ready")
            assert(peer:read_exactly(#followup) == followup)
            peer:write(followup)
            peer:shutdown()
            peer:close()
            return true
        end)

        local stress_client = net.connect("127.0.0.1", port)
        collectgarbage("generational")
        local owned_payload = string.rep(seed, repetitions)
        local writer = uv.run(function()
            stress_client:write(owned_payload)
            return "cancelled write result must not win"
        end)
        local turns = 0
        while writer:status() == "ready" and turns < 100 do
            timer.yield()
            turns = turns + 1
        end
        assert(writer:status() == "waiting",
            "large write did not remain physically pending")
        owned_payload = nil
        writer:cancel("sanitizer-inflight-write")
        collectgarbage("collect")
        local joined = pcall(function() return writer:join() end)
        assert(not joined and writer:status() == "cancelled")

        assert(stress_client:read_exactly(5) == "ready")
        stress_client:write(followup)
        assert(stress_client:read_exactly(#followup) == followup)
        stress_client:shutdown()
        stress_client:close()
        assert(slow_peer:join())
        print("RESULT net production cancelled-write smoke sanitizer passed")
    end

    server:close()
    return response
end)

uv.loop()
assert(main:join() == payload)
