local async = require "titan.async"
local net = require "titan.net"
local timer = require "titan.timer"

assert(type(async) == "userdata")
assert(type(net) == "userdata")

local mode = arg[1] or "unknown"
local payload = mode .. "\0titan.net"
local first_port = mode == "system" and 45000 or 45032
local last_port = first_port + 31

local function active(task)
    return not task:status():has_finished()
end

local main_result
local main = async.run(function()
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

    local peer_result
    local peer_task = async.run(function()
        local peer = server:accept()
        local request = peer:read_until("\n", true)
        assert(request == payload)
        peer:write(request .. "\n")
        peer:shutdown()
        peer:close()
        peer_result = request
    end)

    local client = net.connect("127.0.0.1", port)
    client:write(payload .. "\n")
    local response = client:read_until("\n", true)
    assert(response == payload)
    client:shutdown()
    client:close()

    while active(peer_task) do timer.yield() end
    assert(peer_task:status():as_string() == "succeeded")
    assert(peer_result == payload)

    if mode == "sanitizer" then
        local seed = "owned-write\0buffer:"
        local repetitions = 512 * 1024
        local followup = "write-after-cancel\0ok"
        local slow_peer_finished = false
        local slow_peer = async.run(function()
            local peer = server:accept()
            timer.sleep(100)
            local received = peer:read_until("\n", true)
            assert(received == string.rep(seed, repetitions))
            peer:write("ready\n")
            assert(peer:read_until("\n", true) == followup)
            peer:write(followup .. "\n")
            peer:shutdown()
            peer:close()
            slow_peer_finished = true
        end)

        local stress_client = net.connect("127.0.0.1", port)
        collectgarbage("generational")
        local owned_payload = string.rep(seed, repetitions) .. "\n"
        local writer = async.run(function()
            stress_client:write(owned_payload)
            return "cancelled write result must not win"
        end)
        local turns = 0
        while writer:status():as_string() == "ready" and turns < 100 do
            timer.yield()
            turns = turns + 1
        end
        assert(writer:status():as_string() == "waiting",
            "large write did not remain physically pending")
        owned_payload = nil
        writer:cancel()
        assert(writer:status():as_string() == "waiting",
            "write cancellation abandoned its accepted callback")
        collectgarbage("collect")
        while active(writer) do timer.yield() end
        assert(writer:status():as_string() == "cancelled")

        assert(stress_client:read_until("\n", true) == "ready")
        stress_client:write(followup .. "\n")
        assert(stress_client:read_until("\n", true) == followup)
        stress_client:shutdown()
        stress_client:close()
        while active(slow_peer) do timer.yield() end
        assert(slow_peer:status():as_string() == "succeeded")
        assert(slow_peer_finished)
        print("RESULT net production cancelled-write smoke sanitizer passed")
    end

    server:close()
    main_result = response
end)

async.loop()
assert(main:status():as_string() == "succeeded")
assert(main_result == payload)
