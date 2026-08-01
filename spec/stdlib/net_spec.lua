local async_stdlib = require "spec.support.async_stdlib"

local NET_CASES = [==[
local net = import "net"
local stream = import "io"
local timer = import "timer"
local async = import "async"

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

local function expect_cancelled(task: async.Task, reason: string)
  local caught = false
  do
    task:join()
  catch
    local cancelled = error as async.Cancelled
    check(cancelled.reason == reason, "cancellation reason changed")
    caught = true
  end
  check(caught and task:status() == "cancelled",
        "Task did not finish cancelled")
end

local function wait_until_started(task: async.Task)
  while task:status() == "ready" do timer.yield() end
end

local function read_all(connection: net.Connection): string
  local result = ""
  for chunk in connection:read do
    result = result .. chunk
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
      local failure = error as async.Error
      if failure.name ~= "EADDRINUSE" then raise error end
    end
    attempts = attempts + 1
    port = port + 1
    if port > 60999 then port = 20000 end
  end
  raise "could not find an available loopback port"
end

function schedule_interface_matrix(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 8)
    local peer = async.run(function (): value
      local connection = server:accept()
      connection:write("reader\n")
      connection:shutdown()
      check(read_all(connection) == "", "Reader client sent bytes")
      connection:close()

      connection = server:accept()
      check(read_all(connection) == "writer",
            "Writer Interface changed bytes")
      connection:close()

      connection = server:accept()
      check(read_all(connection) == "",
            "Closer Interface did not close its connection")
      connection:close()

      connection = server:accept()
      connection:write("reader-writer\n")
      connection:shutdown()
      check(read_all(connection) == "reader-writer-out",
            "ReaderWriter Interface changed bytes")
      connection:close()

      connection = server:accept()
      connection:write("reader-closer\n")
      connection:shutdown()
      check(read_all(connection) == "",
            "ReaderCloser Interface did not close its connection")
      connection:close()

      connection = server:accept()
      check(read_all(connection) == "writer-closer-out",
            "WriterCloser Interface changed bytes")
      connection:close()

      connection = server:accept()
      connection:write("composite\n")
      connection:shutdown()
      check(read_all(connection) == "composite-out",
            "ReaderWriterCloser Interface changed bytes")
      connection:close()
      return "interface-peer-ok"
    end)

    local concrete = net.connect("127.0.0.1", port)
    local reader: stream.Reader = concrete
    check(reader:read_until { delimiter = "\n", chop = true } == "reader",
          "named Reader.read_until Interface call failed")
    concrete:close()

    concrete = net.connect("127.0.0.1", port)
    local writer: stream.Writer = concrete
    writer:write("writer")
    concrete:shutdown()
    concrete:close()

    concrete = net.connect("127.0.0.1", port)
    local closer: stream.Closer = concrete
    closer:close()

    concrete = net.connect("127.0.0.1", port)
    local reader_writer: stream.ReaderWriter = concrete
    check(reader_writer:read_until("\n", true) == "reader-writer",
          "ReaderWriter read dispatch failed")
    reader_writer:write("reader-writer-out")
    concrete:shutdown()
    concrete:close()

    concrete = net.connect("127.0.0.1", port)
    local reader_closer: stream.ReaderCloser = concrete
    check(reader_closer:read_until("\n", true) == "reader-closer",
          "ReaderCloser read dispatch failed")
    reader_closer:close()

    concrete = net.connect("127.0.0.1", port)
    local writer_closer: stream.WriterCloser = concrete
    writer_closer:write("writer-closer-out")
    writer_closer:close()

    concrete = net.connect("127.0.0.1", port)
    local composite: stream.ReaderWriterCloser = concrete
    check(composite:read_until("\n", true) == "composite",
          "ReaderWriterCloser read dispatch failed")
    local send: (string) -> () = composite:write
    send("composite-out")
    composite:close()

    check(peer:join() == "interface-peer-ok",
          "Interface matrix peer failed")
    local server_closer: stream.Closer = server
    server_closer:close()
    return "interface-matrix-ok"
  end)
end

function schedule_ipv4_core(first_port: integer): async.Task
  return async.run(function (): value
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

    local peer = async.run(function (): value
      local connection = server:accept()
      check(connection:read_until("\0beta\r\n") ==
            "alpha\0beta\r\n",
            "read_until changed a NUL-containing delimiter or binary data")
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

function schedule_partial_and_excess(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 8)
    local peer = async.run(function (): value
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

      local fourth = server:accept()
      fourth:write("kept\nDISCARDED")
      fourth:shutdown()

      first:close()
      second:close()
      third:close()
      fourth:close()
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

    local fourth = net.connect("127.0.0.1", port)
    check(fourth:read_until("\n", true) == "kept",
          "pre-close delimiter read returned the wrong record")
    fourth:close()
    check(not fourth:read() and not fourth:read_until("\n"),
          "closed Connection did not expose sticky EOF")
    expect_failure(function (): value
      fourth:write("after-close")
      return nil
    end, "closed Connection accepted a write")
    expect_failure(function (): value
      fourth:shutdown()
      return nil
    end, "closed Connection accepted shutdown")

    check(peer:join() == "partial-peer-ok",
          "partial peer Task returned the wrong result")
    server:close()
    return "partial-excess-ok"
  end)
end

function schedule_fifo_and_shutdown(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 8)
    local reader = async.run(function (): value
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
    local first = async.run(function (): value
      issued = 1
      connection:write("first")
      return "first"
    end)
    local second = async.run(function (): value
      while issued < 1 do timer.yield() end
      issued = 2
      connection:write("-second")
      return "second"
    end)
    local third = async.run(function (): value
      while issued < 2 do timer.yield() end
      issued = 3
      connection:write("-third")
      return "third"
    end)
    while issued < 3 do timer.yield() end
    check(first:join() == "first" and second:join() == "second" and
          third:join() == "third", "FIFO writers failed")

    local shutdown_first = async.run(function (): value
      connection:shutdown()
      return "shutdown-first"
    end)
    local shutdown_second = async.run(function (): value
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

    local close_first = async.run(function (): value
      connection:close()
      return "close-first"
    end)
    local close_second = async.run(function (): value
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

function schedule_accept_and_read_cancellation(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 2)
    local accept_waiter = async.run(function (): value
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
    local read_waiter = async.run(function (): value
      return peer:read_until("\n", true)
    end)
    -- The continuously drained prefix is already queued. Its non-yielding
    -- append is synchronous, then the following native read waits for more
    -- bytes. Cancellation there must restore the accumulated builder.
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

    local closing_client = net.connect("127.0.0.1", port)
    local closing_peer = server:accept()
    local close_reader = async.run(function (): value
      return closing_peer:read()
    end)
    wait_until_started(close_reader)
    closing_peer:close()
    local close_result: string? = close_reader:join()
    check(not close_result,
          "Connection close did not wake its reader with EOF")
    check(not closing_peer:read_until(""),
          "closed Connection validated a delimiter instead of returning EOF")
    closing_client:close()

    local building_client = net.connect("127.0.0.1", port)
    local building_peer = server:accept()
    building_client:write("discarded-builder-prefix")
    for _ = 1, 20 do timer.yield() end
    local building_reader = async.run(function (): value
      return building_peer:read_until("\n")
    end)
    wait_until_started(building_reader)
    building_peer:close()
    local building_result: string? = building_reader:join()
    check(not building_result,
          "Connection close published an in-flight delimiter tail")
    building_client:close()

    local close_waiter = async.run(function (): value
      server:accept()
      return "accepted"
    end)
    wait_until_started(close_waiter)
    local waiter_observer = async.run(function (): value
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
    local close_first = async.run(function (): value
      server:close()
      return "server-close-first"
    end)
    local close_second = async.run(function (): value
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

function schedule_bounded_accept_queue(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 2)
    local clients: {net.Connection} = {}
    local connectors: {async.Task} = {}
    for i = 1, 4 do
      connectors[i] = async.run(function (): value
        return net.connect("127.0.0.1", port)
      end)
    end
    for i = 1, 4 do
      clients[i] = connectors[i]:join() as net.Connection
    end
    -- Let all four server-side connection notifications run before consuming
    -- the public accept queue. With backlog two, exactly two can remain queued;
    -- the overflow peers are closed by the implementation.
    for _ = 1, 20 do timer.yield() end

    local first = server:accept()
    local second = server:accept()
    local third = async.run(function (): value
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
    for i = 1, 4 do clients[i]:close() end
    server:close()
    return "bounded-accept-ok"
  end)
end

function schedule_localhost_retry(first_port: integer): async.Task
  return async.run(function (): value
    local resolve_failed = false
    do
      net.connect("not/a/host", first_port)
    catch
      local failure = error as async.Error
      check(failure.operation == "net.resolve" and failure.code < 0,
            "invalid host failed outside DNS resolution")
      resolve_failed = true
    end
    check(resolve_failed, "invalid host unexpectedly resolved")

    -- The same Runtime must remain usable after an ordinary DNS failure.
    local server, port = listen_available("127.0.0.1", first_port, 4)
    local accept = async.run(function (): value
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

function schedule_ipv6_optional(first_port: integer): async.Task
  return async.run(function (): value
    local server: net.Server? = nil
    local port = 0
    do
      server, port = listen_available("::1", first_port, 4)
    catch
      local failure = error as async.Error
      if failure.name == "EAFNOSUPPORT" or
          failure.name == "EADDRNOTAVAIL" or
          failure.name == "EAI_ADDRFAMILY" or
          failure.name == "EAI_FAMILY" then
        return "ipv6-unavailable:" .. failure.name
      end
      raise error
    end
    local listener = server as net.Server
    local peer_task = async.run(function (): value
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

function schedule_leaked_connection(first_port: integer): async.Task
  return async.run(function (): value
    local server, port = listen_available("127.0.0.1", first_port, 2)
    retained_server = server
    local connector = async.run(function (): value
      return net.connect("127.0.0.1", port)
    end)
    retained_connection = connector:join() as net.Connection
    -- The final Task returns with passive resources live. Session cleanup must
    -- close both without relying on loop liveness.
    return retained_connection
  end)
end

function schedule_stale_rejection(_first_port: integer): async.Task
  return async.run(function (): value
    local connection = retained_connection as net.Connection
    local server = retained_server as net.Server
    -- Runtime shutdown already completed both native close transitions.
    -- Closer idempotence keeps those terminal calls harmless in a later
    -- generation. ReaderCloser EOF is likewise answerable from monotonic
    -- terminal state without consulting the stale Runtime.
    do
      connection:close()
      connection:close()
    catch
      raise "old-generation Connection repeat close raised"
    end
    do
      server:close()
      server:close()
    catch
      raise "old-generation Server repeat close raised"
    end
    check(not connection:read() and not connection:read_until("\n"),
          "old-generation closed Connection did not expose sticky EOF")
    expect_failure(function (): value
      connection:write("stale")
      return nil
    end, "old-generation Connection was accepted")
    expect_failure(function (): value
      connection:shutdown()
      return nil
    end, "old-generation Connection shutdown was accepted")
    expect_failure(function (): value
      server:accept()
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
local async = require "titan.async"

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
    async.loop()
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

    it("dispatches every stream Interface and incidental Server Closer",
    function()
        run_lua(port_prelude("interfaces") .. [==[
assert(run("schedule_interface_matrix") == "interface-matrix-ok")
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
