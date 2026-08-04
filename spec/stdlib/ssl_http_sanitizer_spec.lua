local async_stdlib = require "spec.support.async_stdlib"

local function source(cert, key)
    return ([==[
local async = import "async"
local http = import "http"
local ssl = import "ssl"
local str = import "string"
local timer = import "timer"

local CERTIFICATE = %q
local PRIVATE_KEY = %q
local outcome = "not-run"

local function active(task: async.Task): boolean
  return not task:status():has_finished()
end

local function contains(subject: string, needle: string): boolean
  local first: integer? = str.find(subject, needle)
  if first then return true end
  return false
end

function result(): string return outcome end

function start(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server_value: http.Server? = nil
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      if request.target == "/idle-before-fragmented" then
        response:set_header("Content-Length", "0")
      else
        response:set_header("Content-Length", "7")
        response:write("safe\0ok")
        do (server_value as http.Server):close() end
      end
    end
    local port = first_port
    local server: http.Server? = nil
    for _ = 1, 100 do
      do
        server = http.listen_tls("127.0.0.1",
                                 CERTIFICATE, handler, PRIVATE_KEY, port,
                                 nil, 500)
        break
      catch
        if error is async.OperationError then
          local failure = error as async.OperationError
          if failure.name == "EADDRINUSE" then
            port = port + 1
          else
            raise "http.listen_tls failed with " .. failure.name .. ": " ..
              failure.message
          end
        else
          raise error
        end
      end
    end
    if server == nil then raise "could not find an HTTPS loopback port" end
    local exact_server = server as http.Server
    server_value = exact_server
    defer exact_server:close()
    local serving = async.run(function (): value
      exact_server:serve()
      return nil
    end)

    -- SSL_CERT_FILE points the module-initialized default context at the
    -- checked-in test CA. This exercises the shared context and its process-
    -- exit finalizer without adding a second sanitizer test process.
    -- First keep one verified connection idle after a successful request. Its
    -- bounded reader proves that timeout-driven SSL cancellation, HTTP's
    -- reader join, the TLS engine teardown, and the peer's truncated-EOF path
    -- are all sanitizer-clean while the listener remains active.
    local idle = ssl.connect("127.0.0.1", port, nil)
    idle:write(
      "GET /idle-before-fragmented HTTP/1.1\r\n" ..
      "Host: localhost\r\n\r\n")
    local idle_response? = idle:read_until("\r\n\r\n", false)
    if not idle_response or
       not contains(idle_response as string, "HTTP/1.1 200 OK\r\n") then
      raise "HTTPS idle-timeout prelude received the wrong response"
    end

    local observed = "not-read"
    local idle_reader = async.run(function (): value
      do
        local chunk? = idle:read()
        if chunk then
          observed = "unexpected TLS data"
        else
          observed = "authenticated TLS EOF"
        end
      catch
        if error is ssl.Error then
          observed = (error as ssl.Error).name
        else
          raise error
        end
      end
      return nil
    end)
    local watchdog_fired = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      watchdog_fired = true
      idle_reader:cancel(async.CancellationReason.simple(
        "sanitizer HTTPS idle timeout stalled"))
      return nil
    end)
    local idle_status = async.join(idle_reader)
    watchdog:cancel(async.CancellationReason.simple(
      "sanitizer HTTPS idle timeout completed"))
    async.join(watchdog)
    if watchdog_fired then
      raise "HTTPS idle timeout needed the sanitizer watchdog"
    end
    if not idle_status:has_succeeded() then
      raise "HTTPS idle-timeout peer reader did not succeed"
    end
    if observed ~= "TLS_TRUNCATED_EOF" then
      raise "HTTPS idle timeout reported " .. observed
    end
    idle:close()

    if exact_server:idle_timeout(0) ~= 500 then
      raise "HTTPS idle timeout did not retain its configured value"
    end

    local connection = ssl.connect("127.0.0.1", port, nil)
    defer connection:close()
    local request =
      "GET /fragmented HTTP/1.1\r\n" ..
      "Host: localhost\r\nConnection: close\r\n\r\n"
    local index = 1
    while index <= #request do
      connection:write(str.sub(request, index, index))
      index = index + 1
    end
    local response = str.writer()
    for chunk in connection:read do response:write(chunk) end
    local rendered = response:drain()
    if not contains(rendered, "HTTP/1.1 200 OK\r\n") or
       not contains(rendered, "\r\n\r\nsafe\0ok") then
      raise "fragmented HTTPS response was wrong"
    end
    connection:close()
    while active(serving) do timer.yield() end
    if serving:status():as_string() ~= "succeeded" then
      raise "HTTPS serve Task failed"
    end
    outcome = "ok"
    return nil
  end)
end
]==]):format(cert, key)
end

describe("SSL and HTTP sanitizer boundary", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("ssl-http-sanitizer")
        async_stdlib.write_source(workspace, "ssl_http_sanitizer_case",
            source(
                async_stdlib.repo .. "/spec/fixtures/ssl/server.pem",
                async_stdlib.repo .. "/spec/fixtures/ssl/server-key.pem"))
        async_stdlib.compile(workspace, "ssl_http_sanitizer_case")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("cancels an idle read, then streams a fragmented HTTPS request " ..
       "through TLS and llhttp",
    function()
        local hash = 0
        for index = 1, #workspace do
            hash = (hash * 33 + workspace:byte(index)) % 30000
        end
        local port = 20000 + hash
        local command = ([==[
local async = require "titan.async"
local case = require "ssl_http_sanitizer_case"
local task = assert(case.start(%d))
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(case.result() == "ok", case.result())
]==]):format(port)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, command, {
                exec_prefix = {
                    "SSL_CERT_FILE=" .. async_stdlib.repo ..
                        "/spec/fixtures/ssl/ca.pem",
                },
            })
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)
