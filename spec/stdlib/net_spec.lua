local async_stdlib = require "spec.support.async_stdlib"

local NET_CASES = [==[
local net = import "net"
local timer = import "timer"
local uv = import "uv"

local retained_connection: net.Connection? = nil
local retained_server: net.Server? = nil

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function expect_failure(func: () -> value, message: string)
  local failed = false
  do
    func()
  catch
    failed = true
  end
  check(failed, message)
end

local function expect_cancelled(task: uv.Task, reason: string)
  local caught = false
  do
    task:join()
  catch
    local cancelled = error as uv.Cancelled
    check(cancelled.reason == reason, "cancellation reason changed")
    caught = true
  end
  check(caught and task:status() == "cancelled",
        "Task did not finish cancelled")
end

local function wait_until_started(task: uv.Task)
  while task:status() == "ready" do timer.yield() end
end

local function read_all(connection: net.Connection): string
  local result = ""
  local chunk: string? = connection:read()
  while chunk do
    local bytes = chunk as string
    check(#bytes > 0, "Connection returned an empty non-EOF chunk")
    result = result .. bytes
    chunk = connection:read()
  end
  return result
end

-- Tests use explicit ports so every endpoint remains expressible through the
-- public net API. The Lua harness derives a per-workspace starting point, and
-- this retry loop handles collisions with other processes running in parallel.
local function listen_available(host: string, first_port: integer,
                                backlog: integer): (net.Server, integer)
  local port = first_port
  local attempts = 0
  while attempts < 1024 do
    do
      local server = net.listen(host, port, backlog)
      return server, port
    catch
      local failure = error as uv.Error
      if failure.name ~= "EADDRINUSE" then raise error end
    end
    attempts = attempts + 1
    port = port + 1
    if port > 60999 then port = 20000 end
  end
  raise "could not find an available loopback port"
end

function schedule_ipv4_core(first_port: integer): uv.Task
  return uv.run(function (): value
    expect_failure(function (): value
      net.connect("localhost\0ignored", 1)
      return nil
    end, "NUL-containing DNS host reached libuv")
    expect_failure(function (): value
      net.listen("127.0.0.1\0ignored", 1, 8)
      return nil
    end, "NUL-containing listen host reached libuv")
    expect_failure(function (): value
      net.listen("127.0.0.1", 0, 4294967297)
      return nil
    end, "oversized listen backlog was truncated to a C int")

    local server, port = listen_available("127.0.0.1", first_port, 8)

    local peer = uv.run(function (): value
      local connection = server:accept()
      check(connection:read_until("\r\n") ==
            "alpha\0beta\r\n", "read_until changed binary data")
      check(read_all(connection) == "EXCESS",
            "read_until did not retain excess bytes")
      check(not connection:read(),
            "peer did not observe client write shutdown")
      connection:write("reply\0tail")
      connection:shutdown()
      connection:shutdown()
      expect_failure(function (): value
        connection:write("late")
        return nil
      end, "write after shutdown succeeded")
      connection:close()
      connection:close()
      return "peer-ok"
    end)

    local connection = net.connect("127.0.0.1", port)
    connection:write("alpha\0beta\r\nEXCESS")
    connection:shutdown()
    check(read_all(connection) == "reply\0tail",
          "binary response changed")
    check(not connection:read(), "client did not observe sticky peer EOF")
    connection:close()
    connection:close()
    check(peer:join() == "peer-ok", "peer Task returned the wrong result")
    server:close()
    server:close()
    return "ipv4-core-ok"
  end)
end

function schedule_partial_and_excess(first_port: integer): uv.Task
  return uv.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 8)
    local peer = uv.run(function (): value
      local first = server:accept()
      first:write("left\r")
      timer.yield()
      first:write("\nright")
      first:shutdown()

      local second = server:accept()
      second:write("\nalpha\nbeta")
      second:shutdown()

      local third = server:accept()
      third:write("ab")
      timer.yield()
      third:write("cd")
      third:shutdown()

      first:close()
      second:close()
      third:close()
      return "partial-peer-ok"
    end)

    local first = net.connect("127.0.0.1", port)
    check(first:read_until("\r\n") == "left\r\n",
          "delimiter split across callbacks was not found")
    check(read_all(first) == "right",
          "cross-callback delimiter excess was lost")
    check(not first:read(), "first peer EOF was not sticky")
    first:close()

    local second = net.connect("127.0.0.1", port)
    local empty: string? = second:read_until("\n", true)
    check(empty and #(empty as string) == 0,
          "a chopped leading delimiter was confused with EOF")
    check(second:read_until("\n", false) == "alpha\n",
          "read_until false chop omitted the delimiter")
    check(second:read_until("\n", true) == "beta",
          "read_until changed an unterminated EOF tail")
    check(not second:read_until("\n") and not second:read(),
          "EOF after multiple delimiter records was not sticky")
    second:close()

    local third = net.connect("127.0.0.1", port)
    check(third:read_until("\n") == "abcd",
          "unterminated data was not returned as the EOF tail")
    check(not third:read_until("\n") and not third:read_until("\n", true),
          "terminal EOF after an unterminated tail was not sticky")
    third:close()

    check(peer:join() == "partial-peer-ok",
          "partial peer Task returned the wrong result")
    server:close()
    return "partial-excess-ok"
  end)
end

function schedule_fifo_and_shutdown(first_port: integer): uv.Task
  return uv.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 8)
    local reader = uv.run(function (): value
      local peer = server:accept()
      local payload = read_all(peer)
      check(payload == "first-second-third",
            "Connection writes were not FIFO")
      check(not peer:read(), "shutdown did not preserve read-side EOF")
      peer:close()
      return payload
    end)

    local connection = net.connect("127.0.0.1", port)
    local issued = 0
    local first = uv.run(function (): value
      issued = 1
      connection:write("first")
      return "first"
    end)
    local second = uv.run(function (): value
      while issued < 1 do timer.yield() end
      issued = 2
      connection:write("-second")
      return "second"
    end)
    local third = uv.run(function (): value
      while issued < 2 do timer.yield() end
      issued = 3
      connection:write("-third")
      return "third"
    end)
    while issued < 3 do timer.yield() end
    check(first:join() == "first" and second:join() == "second" and
          third:join() == "third", "FIFO writers failed")

    local shutdown_first = uv.run(function (): value
      connection:shutdown()
      return "shutdown-first"
    end)
    local shutdown_second = uv.run(function (): value
      connection:shutdown()
      return "shutdown-second"
    end)
    check(shutdown_first:join() == "shutdown-first" and
          shutdown_second:join() == "shutdown-second",
          "concurrent shutdown callers did not complete")
    connection:shutdown()
    expect_failure(function (): value
      connection:write("")
      return nil
    end, "empty write bypassed shutdown state validation")
    check(reader:join() == "first-second-third", "reader returned wrong data")

    local close_first = uv.run(function (): value
      connection:close()
      return "close-first"
    end)
    local close_second = uv.run(function (): value
      connection:close()
      return "close-second"
    end)
    check(close_first:join() == "close-first" and
          close_second:join() == "close-second",
          "concurrent close callers did not complete")
    connection:close()
    server:close()
    return "fifo-shutdown-ok"
  end)
end

function schedule_accept_and_read_cancellation(first_port: integer): uv.Task
  return uv.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 2)
    local accept_waiter = uv.run(function (): value
      return server:accept()
    end)
    wait_until_started(accept_waiter)
    expect_failure(function (): value
      server:accept()
      return nil
    end, "Server admitted two concurrent accept waiters")
    accept_waiter:cancel("cancel-accept")
    expect_cancelled(accept_waiter, "cancel-accept")

    local client = net.connect("127.0.0.1", port)
    local peer = server:accept()
    client:write("prefix")
    for _ = 1, 20 do timer.yield() end
    local read_waiter = uv.run(function (): value
      return peer:read_until("\n", true)
    end)
    wait_until_started(read_waiter)
    expect_failure(function (): value
      peer:read()
      return nil
    end, "Connection admitted two concurrent readers")
    read_waiter:cancel("cancel-read")
    expect_cancelled(read_waiter, "cancel-read")

    client:write("replacement\n")
    check(peer:read_until("\n", true) == "prefixreplacement",
          "read cancellation did not restore bytes for its replacement")
    client:shutdown()
    check(not peer:read(), "replacement reader did not reach EOF")
    client:close()
    peer:close()

    local close_waiter = uv.run(function (): value
      server:accept()
      return "accepted"
    end)
    wait_until_started(close_waiter)
    local waiter_observer = uv.run(function (): value
      local failed = false
      do
        close_waiter:join()
      catch
        failed = true
      end
      check(failed, "Server close did not wake its accept waiter")
      return "accept-woke"
    end)
    wait_until_started(waiter_observer)
    local close_first = uv.run(function (): value
      server:close()
      return "server-close-first"
    end)
    local close_second = uv.run(function (): value
      server:close()
      return "server-close-second"
    end)
    check(close_first:join() == "server-close-first" and
          close_second:join() == "server-close-second",
          "concurrent Server close callers did not complete")
    check(waiter_observer:join() == "accept-woke",
          "accept waiter observer returned the wrong result")
    server:close()
    return "waiter-cancellation-ok"
  end)
end

function schedule_bounded_accept_queue(first_port: integer): uv.Task
  return uv.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 2)
    local clients: {net.Connection} = {}
    local connectors: {uv.Task} = {}
    for i = 1, 4 do
      connectors[i] = uv.run(function (): value
        return net.connect("127.0.0.1", port)
      end)
    end
    for i = 1, 4 do
      clients[i] = (connectors[i] as uv.Task):join() as net.Connection
    end
    -- Let all four server-side connection notifications run before consuming
    -- the public accept queue. With backlog two, exactly two can remain queued;
    -- the overflow peers are closed by the implementation.
    for _ = 1, 20 do timer.yield() end

    local first = server:accept()
    local second = server:accept()
    local third = uv.run(function (): value
      return server:accept()
    end)
    wait_until_started(third)
    for _ = 1, 20 do timer.yield() end
    check(third:status() == "waiting",
          "Server retained more accepted clients than its backlog")
    third:cancel("bounded-accept")
    expect_cancelled(third, "bounded-accept")
    first:close()
    second:close()
    for i = 1, 4 do (clients[i] as net.Connection):close() end
    server:close()
    return "bounded-accept-ok"
  end)
end

function schedule_localhost_retry(first_port: integer): uv.Task
  return uv.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 4)
    local accept = uv.run(function (): value
      local peer = server:accept()
      check(read_all(peer) == "x", "localhost peer read failed")
      peer:close()
      return nil
    end)
    -- If localhost resolves ::1 before 127.0.0.1, connect must close the
    -- failed IPv6 candidate and continue to the compatible IPv4 result.
    local connection = net.connect("localhost", port)
    connection:write("x")
    connection:shutdown()
    connection:close()
    accept:join()
    server:close()
    return "localhost-retry-ok"
  end)
end

function schedule_ipv6_optional(first_port: integer): uv.Task
  return uv.run(function (): value
    local server: net.Server? = nil
    local port = 0
    do
      server, port = listen_available("::1", first_port, 4)
    catch
      local failure = error as uv.Error
      if failure.name == "EAFNOSUPPORT" or
          failure.name == "EADDRNOTAVAIL" or
          failure.name == "EAI_ADDRFAMILY" or
          failure.name == "EAI_FAMILY" then
        return "ipv6-unavailable:" .. failure.name
      end
      raise error
    end
    local listener = server as net.Server
    local peer_task = uv.run(function (): value
      local peer = listener:accept()
      check(read_all(peer) == "ipv6", "IPv6 payload changed")
      peer:close()
      return nil
    end)
    local connection = net.connect("::1", port)
    connection:write("ipv6")
    connection:shutdown()
    connection:close()
    peer_task:join()
    listener:close()
    return "ipv6-ok"
  end)
end

function schedule_leaked_connection(first_port: integer): uv.Task
  return uv.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 2)
    retained_server = server
    local connector = uv.run(function (): value
      return net.connect("127.0.0.1", port)
    end)
    retained_connection = connector:join() as net.Connection
    -- The final Task returns with passive resources live. Session cleanup must
    -- close both without relying on loop liveness.
    return retained_connection
  end)
end

function schedule_stale_rejection(_first_port: integer): uv.Task
  return uv.run(function (): value
    expect_failure(function (): value
      (retained_connection as net.Connection):write("stale")
      return nil
    end, "old-generation Connection was accepted")
    expect_failure(function (): value
      (retained_server as net.Server):accept()
      return nil
    end, "old-generation Server was accepted")
    retained_connection = nil
    retained_server = nil
    return "stale-rejected"
  end)
end

function retained_server_value(): net.Server?
  return retained_server
end
]==]

describe("net standard library", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("net-runtime")
        async_stdlib.write_source(workspace, "net_cases", NET_CASES)
        async_stdlib.compile(workspace, "net_cases")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run_lua(source)
        local ok, status, output = async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    local function port_prelude(scenario)
        return [==[
local cases = require "net_cases"
local uv = require "titan.uv"

local function port_seed(text)
    local hash = 0
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 30000
    end
    return 20000 + hash
end

local module_path = assert(package.searchpath("net_cases", package.cpath))
local first_port = port_seed(module_path .. ":]==] .. scenario .. [==[")
local function run(name)
    local task = assert(cases[name](first_port))
    uv.loop()
    return task:join()
end
]==]
    end

    it("covers binary IPv4, excess, delimiter reads, FIFO, shutdown, and EOF",
    function()
        run_lua(port_prelude("core") .. [==[
assert(run("schedule_ipv4_core") == "ipv4-core-ok")
assert(run("schedule_partial_and_excess") == "partial-excess-ok")
assert(run("schedule_fifo_and_shutdown") == "fifo-shutdown-ok")
]==])
    end)

    it("rejects concurrent waiters and bounds the accepted-client queue",
    function()
        run_lua(port_prelude("waiters") .. [==[
assert(run("schedule_accept_and_read_cancellation") ==
    "waiter-cancellation-ok")
assert(run("schedule_bounded_accept_queue") == "bounded-accept-ok")
]==])
    end)

    it("tries DNS addresses in order and exercises IPv6 when available",
    function()
        run_lua(port_prelude("dns-ipv6") .. [==[
assert(run("schedule_localhost_retry") == "localhost-retry-ok")
local ipv6 = run("schedule_ipv6_optional")
assert(ipv6 == "ipv6-ok" or ipv6:match("^ipv6%-unavailable:"), ipv6)
]==])
    end)

    it("closes leaked handles, releases roots, and rejects stale sessions",
    function()
        run_lua(port_prelude("gc-sequential") .. [==[
local leaked = run("schedule_leaked_connection")
local weak = setmetatable({
    connection = leaked,
    server = cases.retained_server_value(),
}, { __mode = "v" })
leaked = nil
assert(run("schedule_stale_rejection") == "stale-rejected")
collectgarbage("collect")
collectgarbage("collect")
assert(weak.connection == nil,
    "closed old-generation Connection stayed rooted")
assert(weak.server == nil,
    "closed old-generation Server stayed rooted")
]==])
    end)
end)
