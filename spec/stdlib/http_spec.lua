local async_stdlib = require "spec.support.async_stdlib"

local HTTP_CASES = ([==[
local async = import "async"
local fs = import "fs"
local http = import "http"
local net = import "net"
local str = import "string"
local timer = import "timer"
local url = import "url"

local CERTIFICATE = %q
local PRIVATE_KEY = %q
local TRUST_ROOT = %q
local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function contains(subject: string, needle: string): boolean
  local first: integer? = str.find(subject, needle)
  if first then return true end
  return false
end

local function active(task: async.Task): boolean
  local status = task:status()
  return status == "ready" or status == "running" or status == "waiting"
end

local function read_exact(connection: net.Connection,
                          length: integer): string
  local builder = str.writer(false)
  local received = 0
  while received < length do
    local chunk? = connection:read()
    if not chunk then raise "HTTP peer saw truncated request body" end
    local bytes = chunk as string
    received = received + #bytes
    if received > length then
      raise "HTTP peer received bytes beyond the request body"
    end
    builder:write(bytes)
  end
  return builder:drain()
end

local function read_response(response: http.ClientResponse): string
  local builder = str.writer(false)
  for chunk in response:read do builder:write(chunk) end
  return builder:drain()
end

local function raw_listen(first_port: integer): (net.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      return net.listen("127.0.0.1", port, 8), port
    catch
      if error is async.Error and
         (error as async.Error).name == "EADDRINUSE" then
        port = port + 1
      else
        raise error
      end
    end
  end
  raise "could not find an available loopback port"
end

local function http_listen(first_port: integer,
                           handler: http.Handler): (http.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      return http.listen("127.0.0.1", handler, port), port
    catch
      if error is async.Error and
         (error as async.Error).name == "EADDRINUSE" then
        port = port + 1
      else
        raise error
      end
    end
  end
  raise "could not find an available HTTP loopback port"
end

function result(): string
  return outcome
end

function start_client(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = raw_listen(first_port)
    local peer = async.run(function (): value
      local connection = server:accept()
      defer connection:close()
      defer server:close()
      outcome = "peer-reading-request"
      local preamble = connection:read_until("\r\n\r\n", false)
      if not preamble then raise "HTTP client sent no request" end
      local request_text = preamble as string
      check(contains(request_text, "POST /path?q=one HTTP/1.1\r\n"),
            "HTTP client sent the wrong request target")
      check(contains(request_text, "Host: 127.0.0.1:" ..
                     str.tostring(port) .. "\r\n"),
            "HTTP client sent the wrong Host header")
      check(contains(request_text, "Connection: close\r\n"),
            "HTTP client did not request connection close")
      check(read_exact(connection, 12) == "request\0body",
            "HTTP client changed the request body")
      outcome = "peer-writing-response"

      local response =
        "HTTP/1.1 302 Found\r\n" ..
        "X-Duplicate: one\r\n" ..
        "x-duplicate: two\r\n" ..
        "Transfer-Encoding: chunked\r\n" ..
        "Content-Encoding: gzip\r\n" ..
        "Connection: close\r\n\r\n" ..
        "4;kind=test\r\na\0b\n\r\n" ..
        "5\r\ntrail\r\n" ..
        "0\r\nX-Trailer: done\r\n\r\n"
      local index = 1
      while index <= #response do
        connection:write(str.sub(response, index, index))
        index = index + 1
      end
      connection:close()
      server:close()
      outcome = "peer-done"
      return nil
    end)

    local request_headers = http.headers(nil)
    request_headers:add("X-Request", "present")
    outcome = "client-requesting"
    local response = http.request(
      "POST", "http://127.0.0.1:" .. str.tostring(port) ..
      "/path?q=one", request_headers, "request\0body", nil)
    outcome = "client-reading-response"
    check(response.status == 302 and response.reason == "Found",
          "HTTP client did not return the redirect response")
    local duplicates = response.headers:values("x-duplicate")
    check(#duplicates == 2 and duplicates[1] == "one" and
          duplicates[2] == "two",
          "HTTP headers lost spelling-independent duplicates")
    check(response.headers:get("Content-Encoding") == "gzip",
          "HTTP client removed content encoding")
    check(response:read_until("\n", true) == "a\0b",
          "HTTP client did not decode the first chunk")
    local remaining = str.writer(false)
    for chunk in response:read do remaining:write(chunk) end
    check(remaining:drain() == "trail",
          "HTTP client did not decode the second chunk")
    check(response.headers:get("X-Trailer") == "done",
          "HTTP client did not retain a trailer")
    while active(peer) do timer.yield() end
    check(peer:status() == "succeeded", "raw HTTP peer failed")
    outcome = "client-ok"
    return nil
  end)
end

local function expect_client_host_rejected(source_url: string,
                                           authority: string,
                                           expected: string)
  local request_headers = http.headers(nil)
  request_headers:add("Host", authority)
  local rejected = false
  do
    local response = http.get(source_url, request_headers, nil)
    response:close()
  catch
    local message = error as string
    check(contains(message, expected),
          "HTTP client rejected Host for the wrong reason: " .. message)
    rejected = true
  end
  check(rejected, "HTTP client accepted invalid Host: " .. authority)
end

local function expect_client_url_rejected(source_url: string,
                                          authority: string,
                                          expected_kind: string)
  local request_headers = http.headers(nil)
  request_headers:add("Host", authority)
  local rejected = false
  do
    local response = http.get(source_url, request_headers, nil)
    response:close()
  catch
    check(error is url.Error,
          "HTTP client did not raise the URL parser's error record")
    local diagnostic = error as url.Error
    check(diagnostic.kind == expected_kind,
          "HTTP client URL error kind was " .. diagnostic.kind ..
          ", expected " .. expected_kind)
    check(diagnostic.position >= 1 and #diagnostic.message > 0,
          "HTTP client URL error lost its position or message")
    rejected = true
  end
  check(rejected, "HTTP client accepted invalid Host: " .. authority)
end

function start_client_host_validation(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = raw_listen(first_port)
    local peer = async.run(function (): value
      local connection = server:accept()
      defer connection:close()
      defer server:close()
      local preamble = connection:read_until("\r\n\r\n", false)
      if not preamble then raise "HTTP client sent no Host test request" end
      check(contains(preamble as string,
                     "Host: [2001:db8::1]:8443\r\n"),
            "HTTP client changed a valid supplied IP-literal Host")
      connection:write(
        "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
      return nil
    end)

    local request_headers = http.headers(nil)
    request_headers:add("Host", "[2001:db8::1]:8443")
    local source_url =
      "http://127.0.0.1:" .. str.tostring(port) .. "/host-check"
    local response = http.get(source_url, request_headers, nil)
    check(response.status == 204,
          "HTTP client did not accept a valid supplied IP-literal Host")
    response:close()
    while active(peer) do timer.yield() end
    check(peer:status() == "succeeded", "Host validation peer failed")

    expect_client_url_rejected(source_url, "", "host")
    expect_client_host_rejected(
      source_url, "user@example.com", "non-authority delimiter")
    expect_client_host_rejected(
      source_url, "example.com/path", "non-authority delimiter")
    expect_client_host_rejected(
      source_url, "example.com?query", "non-authority delimiter")
    expect_client_host_rejected(
      source_url, "example.com#fragment", "non-authority delimiter")
    expect_client_url_rejected(source_url, "::1", "ipv6_brackets")
    expect_client_url_rejected(source_url, "[::1", "ipv6_close")
    expect_client_url_rejected(source_url, "[::1]:0", "port")
    expect_client_url_rejected(source_url, "[::1]:65536", "port")
    expect_client_url_rejected(source_url, "example.com:oops", "port")

    local duplicate_headers = http.headers(nil)
    duplicate_headers:add("Host", "example.com")
    duplicate_headers:add("host", "example.net")
    local duplicate_rejected = false
    do
      local duplicate_response =
        http.get(source_url, duplicate_headers, nil)
      duplicate_response:close()
    catch
      local message = error as string
      check(contains(message, "more than one Host header"),
            "HTTP client rejected duplicate Host for the wrong reason")
      duplicate_rejected = true
    end
    check(duplicate_rejected,
          "HTTP client accepted more than one supplied Host field")

    local expect_headers = http.headers(nil)
    expect_headers:add("Expect", "100-continue")
    local expect_rejected = false
    do
      local expect_response = http.request(
        "POST", source_url, expect_headers, "body", nil)
      expect_response:close()
    catch
      local message = error as string
      check(contains(message, "do not support Expect"),
            "HTTP client rejected Expect for the wrong reason")
      expect_rejected = true
    end
    check(expect_rejected,
          "HTTP client emitted an Expect field without withholding the body")

    outcome = "client-host-validation-ok"
    return nil
  end)
end

function start_server_streaming(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handler_started = false
    local server_value: http.Server? = nil
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handler_started = true
      check(request.method == "POST" and request.url.path == "/upload",
            "HTTP server parsed the wrong request line")
      check(request.url.query == "part=1",
            "HTTP server parsed the wrong query")
      check(request.headers:get("X-Test") == "one",
            "HTTP server parsed the wrong header")
      check(request:read_until("END", true) == "body\0",
            "HTTP Request Reader did not decode the body")
      local tail: string? = request:read()
      check(tail == nil, "HTTP Request Reader did not end")

      local header_control_rejected = false
      do
        response:add_header("X-Bad", "control" .. str.char(1))
      catch
        header_control_rejected = true
      end
      check(header_control_rejected,
            "HTTP response admitted a forbidden field-value control")

      local reason_control_rejected = false
      do
        response:set_status(200, "bad" .. str.char(127))
      catch
        reason_control_rejected = true
      end
      check(reason_control_rejected,
            "HTTP response admitted DEL in the reason phrase")

      response:set_status(201, nil)
      response:add_header("X-Reply", "yes")
      response:write("first")
      response:write("second")
      do (server_value as http.Server):close() end
    end
    local server, port = http_listen(first_port, handler)
    server_value = server
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)
    local client = net.connect("127.0.0.1", port)
    client:write(
      "POST /upload?part=1 HTTP/1.1\r\n" ..
      "Host: 127.0.0.1\r\n" ..
      "X-Test: one\r\n" ..
      "Content-Length: 8\r\n" ..
      "Connection: close\r\n\r\n")
    local turns = 0
    while not handler_started and turns < 100 do
      timer.yield()
      turns = turns + 1
    end
    check(handler_started,
          "HTTP handler did not start after headers were complete")
    client:write("body\0END")
    local response = client:read_until("\r\n\r\n", true)
    if not response then raise "HTTP server sent no response" end
    local response_text = response as string
    check(contains(response_text, "HTTP/1.1 201 Created\r\n") and
          contains(response_text, "Transfer-Encoding: chunked\r\n"),
          "HTTP server sent the wrong response headers")
    local body = str.writer(false)
    for chunk in client:read do body:write(chunk) end
    check(body:drain() ==
          "5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n",
          "HTTP server sent the wrong chunked body")
    client:close()
    while active(serving) do timer.yield() end
    check(serving:status() == "succeeded", "HTTP serve Task failed")
    outcome = "server-streaming-ok"
    return nil
  end)
end

function start_expect_continue(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      check(request.target == "/continue",
            "HTTP Expect request reached the wrong handler path")
      local body = str.writer(false)
      for chunk in request:read do body:write(chunk) end
      check(body:drain() == "body",
            "HTTP Expect request body was not delivered after 100 Continue")
      response:set_header("Content-Length", "2")
      response:write("ok")
    end

    local server, port = http_listen(first_port, handler)
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)
    local current: net.Connection? = nil
    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      outcome = "expect-timeout-after-" .. outcome
      if current then
        do (current as net.Connection):close() catch end
      end
      do server:close() catch end
      return nil
    end)

    outcome = "expect-waiting-for-continue"
    local client = net.connect("127.0.0.1", port)
    current = client
    client:write(
      "POST /continue HTTP/1.1\r\n" ..
      "Host: 127.0.0.1\r\n" ..
      "Content-Length: 4\r\n" ..
      "Expect: 100-CoNtInUe\r\n" ..
      "Connection: close\r\n\r\n")
    -- Deliberately withhold the body until the server acknowledges it. This
    -- would deadlock if the handler entered Request:read before the interim
    -- response was written.
    local interim? = client:read_until("\r\n\r\n", false)
    if not interim then raise "HTTP server sent no interim response" end
    check((interim as string) == "HTTP/1.1 100 Continue\r\n\r\n",
          "HTTP server did not acknowledge 100-continue before the body")
    outcome = "expect-sending-body"
    client:write("body")
    local final = str.writer(false)
    for chunk in client:read do final:write(chunk) end
    local final_text = final:drain()
    check(contains(final_text, "HTTP/1.1 200 OK\r\n") and
          contains(final_text, "Content-Length: 2\r\n") and
          str.sub(final_text, #final_text - 1) == "ok",
          "HTTP server did not complete the continued request")
    client:close()
    current = nil

    local rejected = {
      "Expect: unsupported\r\n",
      "Expect: 100-continue, 100-continue\r\n",
      "Expect: 100-continue\r\nExpect: 100-continue\r\n",
    }
    for index = 1, #rejected do
      outcome = "expect-rejecting-" .. str.tostring(index)
      local rejected_client = net.connect("127.0.0.1", port)
      current = rejected_client
      rejected_client:write(
        "POST /never HTTP/1.1\r\n" ..
        "Host: 127.0.0.1\r\n" ..
        "Content-Length: 4\r\n" .. rejected[index] .. "\r\n")
      -- No body follows. A final 417 must arrive and close the connection
      -- without entering the handler or trying to drain the declared body.
      local refusal = str.writer(false)
      for chunk in rejected_client:read do refusal:write(chunk) end
      check(refusal:drain() ==
              "HTTP/1.1 417 Expectation Failed\r\n" ..
              "Content-Length: 0\r\nConnection: close\r\n\r\n",
            "HTTP server did not reject an unsupported expectation")
      rejected_client:close()
      current = nil
    end

    check(handled == 1,
          "HTTP server dispatched a rejected expectation to the handler")
    watchdog:cancel("Expect matrix completed")
    check(not timed_out, "HTTP Expect matrix timed out")
    server:close()
    while active(serving) do timer.yield() end
    check(serving:status() == "succeeded", "HTTP Expect serve Task failed")
    outcome = "expect-ok"
    return nil
  end)
end

function start_pipelining(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      outcome = "pipeline-handler-" .. str.tostring(handled)
      response:set_header("Content-Length", "1")
      response:write(str.tostring(handled))
    end
    local server, port = http_listen(first_port, handler)
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)
    local client = net.connect("127.0.0.1", port)
    local watchdog_fired = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      watchdog_fired = true
      outcome = "pipeline-timeout-after-" .. outcome
      client:close()
      server:close()
      return nil
    end)
    client:write(
      "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n" ..
      "GET /two HTTP/1.1\r\nHost: localhost\r\n" ..
      "Connection: close\r\n\r\n")
    outcome = "pipeline-reading"
    local all = str.writer(false)
    for chunk in client:read do all:write(chunk) end
    server:close()
    watchdog:cancel("pipeline completed")
    check(not watchdog_fired,
          "HTTP pipeline required the watchdog: " .. outcome)
    local responses = all:drain()
    local first: integer? = str.find(responses, "HTTP/1.1 200 OK")
    local second: integer? = nil
    if first then
      second = str.find(responses, "HTTP/1.1 200 OK",
                        (first as integer) + 1)
    end
    check(first ~= nil and second ~= nil and handled == 2,
          "HTTP server lost a pipelined request")
    check(contains(responses, "Content-Length: 1\r\n\r\n1") and
          contains(responses,
                   "Content-Length: 1\r\nConnection: close\r\n\r\n2"),
          "HTTP pipelined responses were not ordered or framed")
    client:close()
    while active(serving) do timer.yield() end
    check(serving:status() == "succeeded",
          "pipelined HTTP serve Task failed")
    outcome = "pipeline-ok"
    return nil
  end)
end

function start_client_framing(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = raw_listen(first_port)
    local current: net.Connection? = nil
    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      outcome = "client-framing-timeout-after-" .. outcome
      if current then
        do (current as net.Connection):close() catch end
      end
      do server:close() catch end
      return nil
    end)
    local peer = async.run(function (): value
      defer server:close()
      for index = 1, 5 do
        do
          local connection = server:accept()
          current = connection
          defer connection:close()
          local preamble? = connection:read_until("\r\n\r\n", false)
          if not preamble then raise "HTTP client sent no request" end
          local request_text = preamble as string
          if index == 1 then
            check(contains(request_text, "GET /fixed HTTP/1.1\r\n"),
                  "fixed-length client case sent the wrong request")
            connection:write(
              "HTTP/1.1 100 Continue\r\nX-Info: interim\r\n\r\n" ..
              "HTTP/1.1 206 Partial Content\r\n" ..
              "Content-Length: 5\r\nConnection: close\r\n\r\nfixed")
          elseif index == 2 then
            check(contains(request_text, "HEAD /head HTTP/1.1\r\n"),
                  "HEAD client case sent the wrong method")
            connection:write(
              "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n" ..
              "Connection: close\r\n\r\n")
          elseif index == 3 then
            check(contains(request_text, "GET /eof HTTP/1.1\r\n"),
                  "EOF-delimited client case sent the wrong request")
            connection:write(
              "HTTP/1.1 200 OK\r\nX-Mode: eof\r\n\r\neof-body")
          elseif index == 4 then
            check(contains(request_text, "GET /truncated HTTP/1.1\r\n"),
                  "truncated client case sent the wrong request")
            connection:write(
              "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n" ..
              "Connection: close\r\n\r\nabc")
          else
            check(contains(request_text, "GET /malformed HTTP/1.1\r\n"),
                  "malformed client case sent the wrong request")
            connection:write(
              "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n" ..
              "Transfer-Encoding: chunked\r\n" ..
              "Connection: close\r\n\r\n0\r\n\r\n")
          end
        end
        current = nil
      end
      return nil
    end)

    local base = "http://127.0.0.1:" .. str.tostring(port)
    outcome = "client-fixed"
    local fixed = http.get(base .. "/fixed", nil, nil)
    check(fixed.status == 206 and fixed.reason == "Partial Content",
          "HTTP client did not skip the informational response")
    check(fixed.headers:get("X-Info") == nil,
          "HTTP client retained informational response headers")
    check(read_response(fixed) == "fixed",
          "HTTP client did not read the fixed-length body")

    outcome = "client-head"
    local head = http.request(
      "HEAD", base .. "/head", nil, nil, nil)
    check(head.headers:get("Content-Length") == "5" and
          head:read() == nil,
          "HTTP client expected a body for a HEAD response")
    head:close()

    outcome = "client-eof"
    local eof_response = http.get(base .. "/eof", nil, nil)
    check(read_response(eof_response) == "eof-body",
          "HTTP client did not read the EOF-delimited body")

    outcome = "client-truncated"
    local truncated = http.get(base .. "/truncated", nil, nil)
    local truncated_failed = false
    do
      read_response(truncated)
    catch
      truncated_failed = true
    end
    check(truncated_failed,
          "HTTP client accepted a truncated Content-Length body")

    outcome = "client-malformed"
    local malformed_failed = false
    do
      local malformed = http.get(base .. "/malformed", nil, nil)
      malformed:close()
    catch
      malformed_failed = true
    end
    check(malformed_failed,
          "HTTP client accepted conflicting response framing")

    while active(peer) do timer.yield() end
    watchdog:cancel("client framing completed")
    check(not timed_out, "HTTP client framing matrix timed out")
    check(peer:status() == "succeeded", "raw framing peer failed")
    outcome = "client-framing-ok"
    return nil
  end)
end

function start_unread_request_drain(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local targets: {string} = {}
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      targets[handled] = request.target
      -- The first two bodies are intentionally unread. The connection Task
      -- must drain both fixed and chunked framing before advancing to the
      -- already-buffered pipelined suffix.
      response:set_header("Content-Length", "1")
      response:write(str.char(64 + handled))
    end
    local server, port = http_listen(first_port, handler)
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)
    local client = net.connect("127.0.0.1", port)
    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      outcome = "request-drain-timeout-after-" .. outcome
      do client:close() catch end
      do server:close() catch end
      return nil
    end)
    client:write(
      "POST /fixed HTTP/1.1\r\nHost: localhost\r\n" ..
      "Content-Length: 4\r\n\r\nskip" ..
      "POST /chunked HTTP/1.1\r\nHost: localhost\r\n" ..
      "Transfer-Encoding: chunked\r\n\r\n" ..
      "3\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: done\r\n\r\n" ..
      "GET /last HTTP/1.1\r\nHost: localhost\r\n" ..
      "Connection: close\r\n\r\n")
    outcome = "request-drain-reading"
    local all = str.writer(false)
    for chunk in client:read do all:write(chunk) end
    client:close()
    server:close()
    watchdog:cancel("request drain completed")
    check(not timed_out, "HTTP unread-body drain matrix timed out")
    check(handled == 3 and targets[1] == "/fixed" and
          targets[2] == "/chunked" and targets[3] == "/last",
          "HTTP server lost ordering while draining unread bodies")
    local responses = all:drain()
    check(contains(responses, "Content-Length: 1\r\n\r\nA") and
          contains(responses, "Content-Length: 1\r\n\r\nB") and
          contains(responses,
                   "Content-Length: 1\r\nConnection: close\r\n\r\nC"),
          "HTTP server framed unread-body responses incorrectly")
    while active(serving) do timer.yield() end
    check(serving:status() == "succeeded",
          "unread-body HTTP serve Task failed")
    outcome = "request-drain-ok"
    return nil
  end)
end

function start_server_failure_isolation(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local reset_body_rejected = false
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      if request.target == "/bad-204" then
        response:set_status(204, nil)
        response:set_header("Content-Length", "1")
        -- This error deliberately escapes the connection Task. No response
        -- bytes may be committed, and the accept loop must remain live.
        response:send_headers()
      elseif request.target == "/fail" then
        raise "intentional HTTP handler failure"
      elseif request.target == "/reset" then
        response:set_status(205, nil)
        do
          response:write("forbidden")
        catch
          reset_body_rejected = true
        end
      else
        raise "unexpected HTTP failure-isolation target"
      end
    end

    local server, port = http_listen(first_port, handler)
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)
    local current: net.Connection? = nil
    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      outcome = "server-failure-timeout-after-" .. outcome
      if current then
        do (current as net.Connection):close() catch end
      end
      do server:close() catch end
      return nil
    end)

    local exchange: (string) -> string = function (
        request_text: string): string
      local connection = net.connect("127.0.0.1", port)
      current = connection
      connection:write(request_text)
      local received = str.writer(false)
      for chunk in connection:read do received:write(chunk) end
      connection:close()
      current = nil
      return received:drain()
    end

    local authority = "127.0.0.1:" .. str.tostring(port)
    outcome = "server-rejecting-204-length"
    local bad_204 = exchange(
      "GET /bad-204 HTTP/1.1\r\nHost: " .. authority .. "\r\n" ..
      "Connection: close\r\n\r\n")
    check(#bad_204 == 0 and handled == 1,
          "HTTP 204 response admitted Content-Length")

    -- These delimiters would reinterpret the separately received origin-form
    -- target if Host were accepted merely as a prefix of a combined URL.
    local malicious_hosts = {
      "localhost/path", "localhost?query", "localhost#fragment",
      "user@localhost",
    }
    for index = 1, #malicious_hosts do
      outcome = "server-rejecting-host-" .. str.tostring(index)
      local rejected = exchange(
        "GET /never HTTP/1.1\r\nHost: " .. malicious_hosts[index] ..
        "\r\nConnection: close\r\n\r\n")
      check(#rejected == 0 and handled == 1,
            "HTTP server admitted a non-authority Host delimiter")
    end

    outcome = "server-isolating-handler-failure"
    local failed = exchange(
      "GET /fail HTTP/1.1\r\nHost: " .. authority .. "\r\n" ..
      "Connection: close\r\n\r\n")
    check(#failed == 0 and handled == 2,
          "HTTP handler failure did not close only its connection")

    outcome = "server-returning-205"
    local reset = exchange(
      "GET /reset HTTP/1.1\r\nHost: " .. authority .. "\r\n" ..
      "Connection: close\r\n\r\n")
    check(handled == 3 and reset_body_rejected,
          "HTTP 205 response admitted a body")
    check(contains(reset, "HTTP/1.1 205 ") and
          contains(reset, "\r\nContent-Length: 0\r\n") and
          not contains(reset, "\r\nTransfer-Encoding:"),
          "HTTP 205 response did not use zero-length framing")
    local header_end? = str.find(reset, "\r\n\r\n")
    check(header_end ~= nil and
          str.sub(reset, (header_end as integer) + 4) == "",
          "HTTP 205 response emitted body bytes")

    server:close()
    watchdog:cancel("server failure matrix completed")
    check(not timed_out, "HTTP server failure matrix timed out")
    while active(serving) do timer.yield() end
    check(serving:status() == "succeeded",
          "HTTP listener failed with a connection Task")
    outcome = "server-failures-ok"
    return nil
  end)
end

function start_cancelled_server_close(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handler: http.Handler = function (_request: http.Request,
                                            _response: http.Response)
      raise "cancelled-close server unexpectedly accepted a request"
    end
    local server, _port = http_listen(first_port, handler)
    defer server:close()
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)
    while serving:status() == "ready" do timer.yield() end
    check(serving:status() == "waiting",
          "HTTP serve Task did not suspend in accept")

    local closer: async.Task? = nil
    local close_returned = false
    closer = async.run(function (): value
      (closer as async.Task):cancel(
        "cancel before HTTP listener transport close")
      server:close()
      close_returned = true
      return nil
    end)
    local close_task = closer as async.Task
    while active(close_task) do timer.yield() end
    check(close_task:status() == "cancelled" and not close_returned,
          "cancelled HTTP Server close crossed its suspension boundary")
    check(active(serving),
          "skipped listener close unexpectedly released accept")

    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      serving:cancel("HTTP Server close retry timed out")
      return nil
    end)
    server:close()
    while active(serving) do timer.yield() end
    watchdog:cancel("HTTP Server close retry completed")
    check(not timed_out, "HTTP Server close retry left accept stranded")
    check(serving:status() == "succeeded",
          "HTTP Server close retry did not stop serve cleanly")
    server:close()
    outcome = "server-close-retry-ok"
    return nil
  end)
end

function start_cancelled_client_close(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local server, port = raw_listen(first_port)
    local peer_connection: net.Connection? = nil
    defer do
      if peer_connection then
        do (peer_connection as net.Connection):close() catch end
      end
      do server:close() catch end
    end

    local peer_saw_eof = false
    local peer = async.run(function (): value
      local connection = server:accept()
      peer_connection = connection
      defer do
        peer_connection = nil
        connection:close()
        server:close()
      end
      local preamble? = connection:read_until("\r\n\r\n", false)
      if not preamble then raise "HTTP close peer saw no request" end
      connection:write(
        "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
      local trailing? = connection:read()
      check(trailing == nil,
            "HTTP client wrote data after receiving its response")
      peer_saw_eof = true
      return nil
    end)

    local response = http.get(
      "http://127.0.0.1:" .. str.tostring(port) .. "/close", nil, nil)
    defer response:close()
    local closer: async.Task? = nil
    local close_returned = false
    closer = async.run(function (): value
      (closer as async.Task):cancel(
        "cancel before HTTP client transport close")
      response:close()
      close_returned = true
      return nil
    end)
    local close_task = closer as async.Task
    while active(close_task) do timer.yield() end
    check(close_task:status() == "cancelled" and not close_returned,
          "cancelled HTTP response close crossed its suspension boundary")
    check(response:read() == nil,
          "logically closed HTTP response remained readable")

    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      peer:cancel("HTTP client close retry timed out")
      return nil
    end)
    response:close()
    while active(peer) do timer.yield() end
    watchdog:cancel("HTTP client close retry completed")
    check(not timed_out, "HTTP client close retry left its peer stranded")
    check(peer:status() == "succeeded" and peer_saw_eof,
          "HTTP client close retry did not close its transport")
    response:close()
    outcome = "client-close-retry-ok"
    return nil
  end)
end

function start_https(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = false
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = true
      check(request.method == "GET" and request.url.scheme == "https" and
            request.url.host == "localhost" and
            request.target == "/secure?value=1",
            "HTTPS server exposed the wrong request")
      response:set_header("Content-Length", "7")
      response:write("secure\0")
    end
    local certificate_bundle = fs.tmpname()
    fs.write_file(certificate_bundle,
                  fs.read_file(CERTIFICATE) .. "\n" ..
                  fs.read_file(PRIVATE_KEY))
    defer fs.unlink(certificate_bundle)
    local port = first_port
    local server: http.Server? = nil
    for _ = 1, 100 do
      do
        server = http.listen_tls("127.0.0.1",
                                 certificate_bundle, handler, nil, port)
        break
      catch
        if error is async.Error and
           (error as async.Error).name == "EADDRINUSE" then
          port = port + 1
        else
          raise error
        end
      end
    end
    if server == nil then raise "could not find an HTTPS loopback port" end
    local exact_server = server as http.Server
    defer exact_server:close()
    local serving = async.run(function (): value
      exact_server:serve()
      return nil
    end)

    local response_status = 0
    local body = ""
    local client_failure = ""
    local requesting = async.run(function (): value
      outcome = "https-requesting"
      do
        local response = http.get(
          "https://localhost:" .. str.tostring(port) ..
          "/secure?value=1", nil, TRUST_ROOT)
        response_status = response.status
        body = read_response(response)
      catch
        if error is async.Error then
          local failure = error as async.Error
          client_failure = failure.name .. ": " .. failure.message ..
            " (" .. failure.operation .. ")"
        else
          client_failure = str.tostring(error)
        end
      end
      return nil
    end)
    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      requesting:cancel("HTTPS public test timed out")
      do exact_server:close() catch end
      return nil
    end)
    while active(requesting) do timer.yield() end
    watchdog:cancel("HTTPS request completed")
    check(not timed_out, "HTTPS public API case timed out")
    check(requesting:status() == "succeeded",
          "HTTPS request Task did not succeed")
    check(#client_failure == 0,
          "HTTPS response read failed with " .. client_failure)
    check(response_status == 200 and body == "secure\0",
          "HTTPS client did not read the verified response")
    check(handled, "HTTPS handler did not run")
    exact_server:close()
    while active(serving) do timer.yield() end
    check(serving:status() == "succeeded", "HTTPS serve Task failed")
    outcome = "https-ok"
    return nil
  end)
end
]==]):format(
    async_stdlib.repo .. "/spec/fixtures/ssl/server.pem",
    async_stdlib.repo .. "/spec/fixtures/ssl/server-key.pem",
    async_stdlib.repo .. "/spec/fixtures/ssl/ca.pem")

describe("HTTP standard library", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("http-runtime")
        async_stdlib.write_source(workspace, "http_cases", HTTP_CASES)
        async_stdlib.compile(workspace, "http_cases")
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
local cases = require "http_cases"
local task = assert(cases.%s(%d))
async.loop()
assert(task:status() == "succeeded",
       task:status() .. ":" .. cases.result())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, first_port, expected)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("parses fragmented chunked responses without redirect or decoding",
    function()
        run("start_client", "client", "client-ok")
    end)

    it("validates caller-supplied Host as one complete authority", function()
        run("start_client_host_validation", "client-host",
            "client-host-validation-ok")
    end)

    it("starts handlers at headers and streams request and response bodies",
    function()
        run("start_server_streaming", "server", "server-streaming-ok")
    end)

    it("resolves 100-continue before waiting for a request body", function()
        run("start_expect_continue", "expect", "expect-ok")
    end)

    it("preserves and orders pipelined HTTP/1.1 requests", function()
        run("start_pipelining", "pipeline", "pipeline-ok")
    end)

    it("handles informational, fixed, HEAD, EOF, and rejected bodies",
    function()
        run("start_client_framing", "client-framing", "client-framing-ok")
    end)

    it("drains unread fixed and chunked requests before keep-alive reuse",
    function()
        run("start_unread_request_drain", "request-drain", "request-drain-ok")
    end)

    it("isolates failed connections and enforces bodyless server framing",
    function()
        run("start_server_failure_isolation", "server-failures",
            "server-failures-ok")
    end)

    it("retries a listener close skipped by Task cancellation", function()
        run("start_cancelled_server_close", "server-close-retry",
            "server-close-retry-ok")
    end)

    it("retries a client close skipped by Task cancellation", function()
        run("start_cancelled_client_close", "client-close-retry",
            "client-close-retry-ok")
    end)

    it("serves and requests verified HTTPS through the public API", function()
        run("start_https", "https", "https-ok")
    end)
end)
