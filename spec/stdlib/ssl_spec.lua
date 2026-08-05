local async_stdlib = require "spec.support.async_stdlib"

local SSL_CASES = ([==[
local async = import "async"
local fs = import "fs"
local stream = import "io"
local net = import "net"
local ssl = import "ssl"
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
  return not task:status():has_finished()
end

local function listen_available(first_port: integer,
                                certificate: string,
                                private_key: string?): (ssl.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      if not private_key then
        return ssl.listen("127.0.0.1", port, certificate), port
      end
      return ssl.listen("127.0.0.1", port,
                        certificate, private_key as string), port
    catch
      if error is async.OperationError then
        local failure = error as async.OperationError
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
    local certificate_bundle = fs.tmpname()
    fs.write_file(certificate_bundle,
                  fs.read_file(CERTIFICATE) .. "\n" ..
                  fs.read_file(TRUST_ROOT) .. "\n" ..
                  fs.read_file(PRIVATE_KEY))
    defer fs.unlink(certificate_bundle)
    local server, port =
      listen_available(first_port, certificate_bundle, nil)
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

    local connection = ssl.connect("127.0.0.1", port, TRUST_ROOT)
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
    check(peer:status():as_string() == "succeeded", "TLS peer Task failed")
    server:close()
    server:close()
    outcome = "exchange-ok"
    return nil
  end)
end

function start_lazy_accept(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port =
      listen_available(first_port, CERTIFICATE, PRIVATE_KEY)
    local stalled = net.connect("127.0.0.1", port)
    local first = server:accept()

    local second_peer = async.run(function (): value
      local connection = server:accept()
      connection:write("second")
      connection:close()
      return nil
    end)
    local second = ssl.connect("127.0.0.1", port, TRUST_ROOT)
    check(second:read() == "second",
          "a stalled ClientHello blocked the next accept")
    check(not second:read(), "second TLS connection did not close cleanly")
    second:close()
    first:close()
    stalled:close()
    while active(second_peer) do timer.yield() end
    check(second_peer:status():as_string() == "succeeded",
          "second accepted TLS connection failed")
    server:close()
    outcome = "lazy-ok"
    return nil
  end)
end

function start_verification_failure(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port =
      listen_available(first_port, WRONG_CERTIFICATE, PRIVATE_KEY)
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
      ssl.connect("localhost", port, TRUST_ROOT)
    catch
      check(error is ssl.Error, "verification raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.name == "CERTIFICATE_VERIFY_FAILED",
            "verification reported " .. failure.name)
      failed = true
    end
    check(failed, "wrong DNS identity was accepted")
    while active(peer) do timer.yield() end
    check(peer:status():as_string() == "succeeded" and peer_failed,
          "server did not retire the rejected TLS handshake")
    server:close()
    outcome = "verify-ok"
    return nil
  end)
end

function start_truncated_eof(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port =
      listen_available(first_port, CERTIFICATE, PRIVATE_KEY)
    local accepted: ssl.Connection? = nil
    local handshake_done = false
    local peer = async.run(function (): value
      local connection = server:accept()
      accepted = connection
      connection:handshake()
      handshake_done = true
      -- This read is deliberately cancelled below. Cancellation terminalizes
      -- the TLS connection and closes its TCP transport without fabricating a
      -- native peer or rewriting the SSL source. The captured public
      -- Connection later proves that close remains idempotent.
      connection:read()
      return nil
    end)
    local client = ssl.connect("127.0.0.1", port, TRUST_ROOT)
    while not handshake_done do timer.yield() end
    peer:cancel(async.CancellationReason.simple(
      "intentional abrupt TLS peer"))
    -- Cancellation detaches the pending TCP reader and schedules its Task
    -- wake. Keep one application record in flight while that peer closes:
    -- kernels may expose the unauthenticated termination as FIN or RST, and
    -- the TLS layer must normalize both to the same truncation boundary.
    client:write("wake-cancelled-peer")
    while active(peer) do timer.yield() end
    check(peer:status():as_string() == "cancelled",
          "abrupt TLS peer did not finish through cancellation")
    if accepted == nil then raise "TLS server never accepted the client" end
    local server_connection = accepted as ssl.Connection
    server_connection:close()

    local truncated = false
    do
      client:read()
    catch
      local detail = str.tostring(error)
      if error is async.OperationError then
        local transport_failure = error as async.OperationError
        detail = transport_failure.name .. " from " ..
          transport_failure.operation
      end
      check(error is ssl.Error,
            "truncated TLS transport raised a non-TLS error: " .. detail)
      local failure = error as ssl.Error
      check(failure.name == "TLS_TRUNCATED_EOF" and
            failure.message ==
              "TLS transport closed without close_notify" and
            failure.operation == "ssl.read",
            "truncated TLS transport reported " .. failure.name ..
              " from " .. failure.operation)
      truncated = true
    end
    check(truncated,
          "unauthenticated TCP termination was accepted as clean TLS EOF")
    client:close()
    server:close()
    outcome = "truncated-ok"
    return nil
  end)
end

function start_loading_failures(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local missing = fs.tmpname()
    fs.unlink(missing)

    local missing_ca = false
    do
      ssl.connect("127.0.0.1", first_port, missing)
    catch
      check(error is async.OperationError,
            "missing CA path raised a non-filesystem error")
      local failure = error as async.OperationError
      check(failure.name == "ENOENT" and failure.operation == "fs.open",
            "missing CA path did not fail through fs.open")
      missing_ca = true
    end
    check(missing_ca, "missing CA path was accepted")

    local missing_certificate = false
    do
      ssl.listen("127.0.0.1", first_port, missing, PRIVATE_KEY)
    catch
      check(error is async.OperationError,
            "missing certificate path raised a non-filesystem error")
      local failure = error as async.OperationError
      check(failure.name == "ENOENT" and failure.operation == "fs.open",
            "missing certificate path did not fail through fs.open")
      missing_certificate = true
    end
    check(missing_certificate, "missing certificate path was accepted")

    local missing_key = false
    do
      ssl.listen("127.0.0.1", first_port, CERTIFICATE, missing)
    catch
      check(error is async.OperationError,
            "missing private-key path raised a non-filesystem error")
      local failure = error as async.OperationError
      check(failure.name == "ENOENT" and failure.operation == "fs.open",
            "missing private-key path did not fail through fs.open")
      missing_key = true
    end
    check(missing_key, "missing private-key path was accepted")

    local empty = fs.tmpname()
    defer fs.unlink(empty)
    local empty_ca = false
    do
      ssl.connect("127.0.0.1", first_port, empty)
    catch
      check(error is ssl.Error, "empty CA PEM raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.operation == "ssl.client.trust",
            "empty CA PEM reported " .. failure.operation)
      empty_ca = true
    end
    check(empty_ca, "empty CA PEM was accepted")

    local empty_certificate = false
    do
      ssl.listen("127.0.0.1", first_port, empty, PRIVATE_KEY)
    catch
      check(error is ssl.Error,
            "empty certificate PEM raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.operation == "ssl.server.certificate",
            "empty certificate PEM reported " .. failure.operation)
      empty_certificate = true
    end
    check(empty_certificate, "empty certificate PEM was accepted")

    local empty_key = false
    do
      ssl.listen("127.0.0.1", first_port, CERTIFICATE, empty)
    catch
      check(error is ssl.Error,
            "empty private-key PEM raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.operation == "ssl.server.private-key",
            "empty private-key PEM reported " .. failure.operation)
      empty_key = true
    end
    check(empty_key, "empty private-key PEM was accepted")

    local malformed = fs.tmpname()
    fs.write_file(malformed,
                  fs.read_file(TRUST_ROOT) .. "\n" ..
                  "-----BEGIN CERTIFICATE-----\n" ..
                  "not-base64\n" ..
                  "-----END CERTIFICATE-----\n")
    defer fs.unlink(malformed)
    local malformed_ca = false
    do
      ssl.connect("127.0.0.1", first_port, malformed)
    catch
      check(error is ssl.Error,
            "malformed trailing CA PEM raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.operation == "ssl.client.trust",
            "malformed trailing CA PEM reported " .. failure.operation)
      malformed_ca = true
    end
    check(malformed_ca, "malformed trailing CA PEM was accepted")

    local malformed_key = fs.tmpname()
    fs.write_file(malformed_key,
                  fs.read_file(PRIVATE_KEY) .. "\n" ..
                  "-----BEGIN PRIVATE KEY-----\n" ..
                  "not-base64\n" ..
                  "-----END PRIVATE KEY-----\n")
    defer fs.unlink(malformed_key)
    local malformed_private_key = false
    do
      ssl.listen("127.0.0.1", first_port, CERTIFICATE, malformed_key)
    catch
      check(error is ssl.Error,
            "malformed trailing private-key PEM raised a non-TLS error")
      local failure = error as ssl.Error
      check(failure.operation == "ssl.server.private-key",
            "malformed trailing private-key PEM reported " ..
              failure.operation)
      malformed_private_key = true
    end
    check(malformed_private_key,
          "malformed trailing private-key PEM was accepted")

    outcome = "loading-ok"
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
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, first_port, expected)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("loads a combined full-chain/key PEM and exchanges TLS records",
    function()
        run("start_exchange", "exchange", "exchange-ok")
    end)

    it("loads split server PEM files without serializing accepts",
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

    it("rejects missing, empty, or malformed in-memory PEM inputs",
    function()
        run("start_loading_failures", "loading", "loading-ok")
    end)
end)
