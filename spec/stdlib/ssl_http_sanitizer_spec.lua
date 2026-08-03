local async_stdlib = require "spec.support.async_stdlib"

local function source(cert, key, ca)
    return ([==[
local async = import "async"
local http = import "titan.http"
local ssl = import "titan.ssl"
local str = import "string"
local timer = import "timer"

local CERTIFICATE = %q
local PRIVATE_KEY = %q
local TRUST_ROOT = %q
local outcome = "not-run"

local function active(task: async.Task): boolean
  local status = task:status()
  return status == "ready" or status == "running" or status == "waiting"
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
    local handler: http.Handler = function (_request: http.Request,
                                            response: http.Response)
      response:set_header("Content-Length", "7")
      response:write("safe\0ok")
      do (server_value as http.Server):close() end
    end
    local port = first_port
    local server: http.Server? = nil
    for _ = 1, 100 do
      do
        server = http.listen_tls("127.0.0.1", port, 8,
                                 CERTIFICATE, PRIVATE_KEY, handler)
        break
      catch
        if error is async.Error then
          local failure = error as async.Error
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

    local connection = ssl.connect("127.0.0.1", port, TRUST_ROOT, nil)
    defer connection:close()
    local request =
      "GET /fragmented HTTP/1.1\r\n" ..
      "Host: localhost\r\nConnection: close\r\n\r\n"
    local index = 1
    while index <= #request do
      connection:write(str.sub(request, index, index))
      index = index + 1
    end
    local response = str.writer(false)
    for chunk in connection:read do response:write(chunk) end
    local rendered = response:drain()
    if not contains(rendered, "HTTP/1.1 200 OK\r\n") or
       not contains(rendered, "\r\n\r\nsafe\0ok") then
      raise "fragmented HTTPS response was wrong"
    end
    connection:close()
    while active(serving) do timer.yield() end
    if serving:status() ~= "succeeded" then
      raise "HTTPS serve Task failed"
    end
    outcome = "ok"
    return nil
  end)
end
]==]):format(cert, key, ca)
end

describe("SSL and HTTP sanitizer boundary", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("ssl-http-sanitizer")
        async_stdlib.write_source(workspace, "ssl_http_sanitizer_case",
            source(
                async_stdlib.repo .. "/spec/fixtures/ssl/server.pem",
                async_stdlib.repo .. "/spec/fixtures/ssl/server-key.pem",
                async_stdlib.repo .. "/spec/fixtures/ssl/ca.pem"))
        async_stdlib.compile(workspace, "ssl_http_sanitizer_case")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("streams a fragmented HTTPS request through TLS and llhttp",
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
assert(task:status() == "succeeded", task:status())
assert(case.result() == "ok", case.result())
]==]):format(port)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, command)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)
