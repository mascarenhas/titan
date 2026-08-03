local async_stdlib = require "spec.support.async_stdlib"

local SSL_CASES = ([==[
local async = import "async"
local stream = import "io"
local net = import "net"
local ssl = import "titan.ssl"
local str = import "string"
local timer = import "timer"

local CERTIFICATE = %q
local WRONG_CERTIFICATE = %q
local PRIVATE_KEY = %q
local TRUST_ROOT = %q
local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function active(task: async.Task): boolean
  local status = task:status()
  return status == "ready" or status == "running" or status == "waiting"
end

local function listen_available(first_port: integer,
                                certificate: string): (ssl.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      return ssl.listen("127.0.0.1", port, 8,
                        certificate, PRIVATE_KEY), port
    catch
      if error is async.Error then
        local failure = error as async.Error
        if failure.name == "EADDRINUSE" then
          port = port + 1
          if port > 60999 then port = 20000 end
        else
          raise "ssl.listen failed with " .. failure.name .. ": " ..
            failure.message
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
    local server, port = listen_available(first_port, CERTIFICATE)
    local peer = async.run(function (): value
      local connection = server:accept()
      local channel: stream.ReaderWriterCloser = connection
      local prefix = channel:read_until("\0END", true)
      check(prefix == str.rep("x", 40000),
            "TLS binary delimiter read returned the wrong prefix")
      check(channel:read() == "tail",
            "TLS delimiter read did not retain excess")
      channel:write("reply\0\nrest")
      connection:shutdown()
      connection:shutdown()
      check(not connection:read(),
            "TLS peer did not remain readable through half-close")
      channel:close()
      channel:close()
      return nil
    end)

    local connection = ssl.connect(
      "127.0.0.1", port, TRUST_ROOT, nil)
    local channel: stream.ReaderWriterCloser = connection
    channel:write(str.rep("x", 40000) .. "\0ENDtail")
    check(channel:read_until("\n", true) == "reply\0",
          "TLS response delimiter changed binary bytes")
    check(channel:read() == "rest",
          "TLS response delimiter lost excess")
    check(not channel:read(), "TLS peer close_notify was not clean EOF")
    channel:close()
    channel:close()
    check(not channel:read() and not channel:read_until("missing"),
          "closed TLS connection did not stay at EOF")

    while active(peer) do timer.yield() end
    check(peer:status() == "succeeded", "TLS peer Task failed")
    server:close()
    server:close()
    outcome = "exchange-ok"
    return nil
  end)
end

function start_lazy_accept(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = listen_available(first_port, CERTIFICATE)
    local stalled = net.connect("127.0.0.1", port)
    local first = server:accept()

    local second_peer = async.run(function (): value
      local connection = server:accept()
      connection:write("second")
      connection:close()
      return nil
    end)
    local second = ssl.connect("127.0.0.1", port, TRUST_ROOT, nil)
    check(second:read() == "second",
          "a stalled ClientHello blocked the next accept")
    check(not second:read(), "second TLS connection did not close cleanly")
    second:close()
    first:close()
    stalled:close()
    while active(second_peer) do timer.yield() end
    check(second_peer:status() == "succeeded",
          "second accepted TLS connection failed")
    server:close()
    outcome = "lazy-ok"
    return nil
  end)
end

function start_verification_failure(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = listen_available(first_port, WRONG_CERTIFICATE)
    local peer_failed = false
    local peer = async.run(function (): value
      local connection = server:accept()
      do
        connection:read()
      catch
        peer_failed = true
      end
      connection:close()
      return nil
    end)
    local failed = false
    do
      ssl.connect("localhost", port, TRUST_ROOT, nil)
    catch
      check(error is ssl.Error, "verification raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.name == "CERTIFICATE_VERIFY_FAILED",
            "verification reported " .. failure.name)
      failed = true
    end
    check(failed, "wrong DNS identity was accepted")
    while active(peer) do timer.yield() end
    check(peer:status() == "succeeded" and peer_failed,
          "server did not retire the rejected TLS handshake")
    server:close()
    outcome = "verify-ok"
    return nil
  end)
end

function start_truncated_eof(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = listen_available(first_port, CERTIFICATE)
    local accepted: ssl.Connection? = nil
    local handshake_done = false
    local peer = async.run(function (): value
      local connection = server:accept()
      accepted = connection
      connection:handshake()
      handshake_done = true
      -- This read is deliberately cancelled below. Cancellation terminalizes
      -- the TLS connection without fabricating a native peer or rewriting the
      -- SSL source; the captured public Connection can then close its TCP
      -- transport without a close_notify.
      connection:read()
      return nil
    end)
    local client = ssl.connect("127.0.0.1", port, TRUST_ROOT, nil)
    while not handshake_done do timer.yield() end
    peer:cancel("intentional abrupt TLS peer")
    -- TCP read cancellation is physical only when its own callback arrives.
    -- One application record supplies that callback without changing the TLS
    -- truncation boundary being tested.
    client:write("wake-cancelled-peer")
    while active(peer) do timer.yield() end
    check(peer:status() == "cancelled",
          "abrupt TLS peer did not finish through cancellation")
    if accepted == nil then raise "TLS server never accepted the client" end
    local server_connection = accepted as ssl.Connection
    server_connection:close()

    local truncated = false
    do
      client:read()
    catch
      check(error is ssl.Error,
            "truncated TLS transport raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.name == "TLS_TRUNCATED_EOF",
            "truncated TLS transport reported " .. failure.name)
      truncated = true
    end
    check(truncated, "bare TCP EOF was accepted as clean TLS EOF")
    client:close()
    server:close()
    outcome = "truncated-ok"
    return nil
  end)
end
]==]):format(
    async_stdlib.repo .. "/spec/fixtures/ssl/server.pem",
    async_stdlib.repo .. "/spec/fixtures/ssl/wrong-server.pem",
    async_stdlib.repo .. "/spec/fixtures/ssl/server-key.pem",
    async_stdlib.repo .. "/spec/fixtures/ssl/ca.pem")

describe("SSL standard library", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("ssl-runtime")
        async_stdlib.write_source(workspace, "ssl_cases", SSL_CASES)
        async_stdlib.compile(workspace, "ssl_cases")
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
local cases = require "ssl_cases"
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

    it("verifies a peer and exchanges binary data across TLS records",
    function()
        run("start_exchange", "exchange", "exchange-ok")
    end)

    it("does not let a stalled ClientHello serialize server accepts",
    function()
        run("start_lazy_accept", "lazy", "lazy-ok")
    end)

    it("rejects a trusted certificate with the wrong DNS identity",
    function()
        run("start_verification_failure", "verify", "verify-ok")
    end)

    it("distinguishes a cancelled peer's truncated transport from clean EOF",
    function()
        run("start_truncated_eof", "truncated", "truncated-ok")
    end)
end)
