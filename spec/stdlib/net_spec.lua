local async_stdlib = require "spec.support.async_stdlib"

local NET_CASES = [==[
local async = import "async"
local net = import "net"
local stream = import "io"
local timer = import "timer"

local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function active(task: async.Task): boolean
  local status = task:status()
  return status == "ready" or status == "running" or status == "waiting"
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

-- Public net does not expose an ephemeral listener's selected port. Choose a
-- deterministic starting point per test process, retrying only address-use
-- collisions from other concurrent workers.
local function listen_available(first_port: integer): (net.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      local server = net.listen("127.0.0.1", port)
      return server, port
    catch
      if error is async.Error then
        local failure = error as async.Error
        if failure.name == "EADDRINUSE" then
          port = port + 1
          if port > 60999 then port = 20000 end
        else
          raise "unexpected listen failure: " .. failure.operation ..
                ":" .. failure.name .. ": " .. failure.message
        end
      else
        raise error
      end
    end
  end
  raise "could not find an available loopback port"
end

function result(): string
  return outcome
end

function start_exchange(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = listen_available(first_port)
    local peer = async.run(function (): value
      local connection = server:accept()
      check(connection:read_until("\0END", true) == "alpha",
            "binary delimiter read returned wrong prefix")
      check(connection:read() == "tail",
            "delimiter read did not retain excess")
      check(not connection:read(),
            "peer did not observe client write shutdown")

      connection:write("reply\0\nrest")
      connection:shutdown()
      connection:shutdown()
      expect_failure(function (): value
        connection:write("late")
        return nil
      end, "Connection accepted a write after shutdown")
      connection:close()
      connection:close()
      return nil
    end)

    local connection = net.connect("127.0.0.1", port)
    local concrete: stream.ReaderWriterCloser = connection
    concrete:write("alpha\0ENDtail")
    connection:shutdown()
    check(concrete:read_until("\n", true) == "reply\0",
          "binary response delimiter changed")
    check(concrete:read() == "rest",
          "response delimiter excess was lost")
    check(not concrete:read() and not concrete:read_until("missing"),
          "repeated Connection reads did not return EOF")
    concrete:close()
    concrete:close()
    check(not concrete:read() and not concrete:read_until("missing"),
          "closed Connection did not behave as Reader EOF")
    expect_failure(function (): value
      concrete:write("after-close")
      return nil
    end, "closed Connection accepted a write")

    while active(peer) do timer.yield() end
    check(peer:status() == "succeeded", "TCP peer Task failed")
    local closer: stream.Closer = server
    closer:close()
    closer:close()
    outcome = "exchange-ok"
    return nil
  end)
end

function start_validation(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    expect_failure(function (): value
      net.connect("", 1)
      return nil
    end, "connect accepted an empty host")
    expect_failure(function (): value
      net.connect("127.0.0.1", 0)
      return nil
    end, "connect accepted port zero")
    expect_failure(function (): value
      net.connect("127.0.0.1", 65536)
      return nil
    end, "connect accepted an oversized port")
    expect_failure(function (): value
      net.listen("", 1, 8)
      return nil
    end, "listen accepted an empty host")
    expect_failure(function (): value
      net.listen("127.0.0.1", -1, 8)
      return nil
    end, "listen accepted a negative port")
    expect_failure(function (): value
      net.listen("127.0.0.1", 1, 0)
      return nil
    end, "listen accepted a nonpositive backlog")
    expect_failure(function (): value
      net.listen("127.0.0.1", 1, 2147483648)
      return nil
    end, "listen accepted a backlog outside libuv's C-int range")
    expect_failure(function (): value
      net.listen("127.0.0.1\0ignored", 1, 8)
      return nil
    end, "listen accepted an embedded-NUL host")

    local server, _port = listen_available(first_port)
    local accept_failed = false
    local waiter = async.run(function (): value
      do
        server:accept()
      catch
        local failure = error as async.Error
        check(failure.operation == "net.accept",
              "closed accept reported the wrong operation")
        accept_failed = true
      end
      return nil
    end)
    while waiter:status() == "ready" do timer.yield() end
    check(waiter:status() == "waiting",
          "accept Task did not reach its callback wait")
    local competing_accept_rejected = false
    do
      server:accept()
    catch
      competing_accept_rejected = true
    end
    check(competing_accept_rejected,
          "Server accepted a second waiting Task")
    server:close()
    server:close()
    while active(waiter) do timer.yield() end
    check(waiter:status() == "succeeded" and accept_failed,
          "Server close did not fail its accept continuation")

    -- Connecting first lets the listener callback retain one accepted client
    -- until the owning Task asks for it; this is buffered multi-shot state,
    -- not a Titan operation queue. A hostname also exercises libuv address
    -- resolution and candidate fallback without assuming address order.
    local buffered_server, buffered_port = listen_available(first_port + 101)
    local buffered_client = net.connect("localhost", buffered_port)
    -- Leave a loop turn with no accept waiter so the listener callback must
    -- retain the client in the server's multi-shot buffer.
    timer.sleep(10)
    local buffered_peer = buffered_server:accept()
    buffered_client:write("buffered-client")
    buffered_client:shutdown()
    check(buffered_peer:read() == "buffered-client" and
          not buffered_peer:read(),
          "Server did not retain its unwaited accepted client")
    buffered_peer:close()
    buffered_client:close()
    buffered_server:close()
    outcome = "validation-ok"
    return nil
  end)
end
]==]

describe("net standard library", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("net-direct-runtime")
        async_stdlib.write_source(workspace, "net_cases", NET_CASES)
        async_stdlib.compile(workspace, "net_cases")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function port_seed(text)
        local hash = 0
        for index = 1, #text do
            hash = (hash * 33 + text:byte(index)) % 30000
        end
        return 20000 + hash
    end

    local function run(function_name, scenario, expected)
        local first_port = port_seed(workspace .. ":" .. scenario)
        local source = ([==[
local async = require "titan.async"
local cases = require "net_cases"
local task = assert(cases.%s(%d))
async.loop()
assert(task:status() == "succeeded", task:status())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, first_port, expected)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("exchanges binary streams through listen, connect, accept, and EOF",
    function()
        run("start_exchange", "exchange", "exchange-ok")
    end)

    it("validates endpoints and wakes a pending accept on close", function()
        run("start_validation", "validation", "validation-ok")
    end)
end)
