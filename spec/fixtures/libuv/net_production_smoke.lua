local uv = require "titan.uv"
local net = require "titan.net"

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
    server:close()
    return response
end)

uv.loop()
assert(main:join() == payload)
