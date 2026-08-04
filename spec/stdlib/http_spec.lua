local async_stdlib = require "spec.support.async_stdlib"

local HTTP_CASES = ([==[
local async = import "async"
local fs = import "fs"
local http = import "http"
local net = import "net"
local ssl = import "ssl"
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
  return not task:status():has_finished()
end

local function read_exact(connection: net.Connection,
                          length: integer): string
  local builder = str.writer()
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
  local builder = str.writer()
  for chunk in response:read do builder:write(chunk) end
  return builder:drain()
end

local function raw_listen(first_port: integer): (net.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      return net.listen("127.0.0.1", port, 8), port
    catch
      if error is async.OperationError and
         (error as async.OperationError).name == "EADDRINUSE" then
        port = port + 1
      else
        raise error
      end
    end
  end
  raise "could not find an available loopback port"
end

local function http_listen(first_port: integer,
                           handler: http.Handler,
                           idle_timeout: integer?): (http.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      if idle_timeout == nil then
        return http.listen("127.0.0.1", handler, port), port
      end
      return http.listen("127.0.0.1", handler, port, nil,
                         idle_timeout), port
    catch
      if error is async.OperationError and
         (error as async.OperationError).name == "EADDRINUSE" then
        port = port + 1
      else
        raise error
      end
    end
  end
  raise "could not find an available HTTP loopback port"
end

local function https_listen(first_port: integer, handler: http.Handler,
                            idle_timeout: integer):
    (http.Server, integer)
  local port = first_port
  for _ = 1, 100 do
    do
      return http.listen_tls("127.0.0.1", CERTIFICATE, handler,
                             PRIVATE_KEY, port, nil, idle_timeout), port
    catch
      if error is async.OperationError and
         (error as async.OperationError).name == "EADDRINUSE" then
        port = port + 1
      else
        raise error
      end
    end
  end
  raise "could not find an available HTTPS loopback port"
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
    local remaining = str.writer()
    for chunk in response:read do remaining:write(chunk) end
    check(remaining:drain() == "trail",
          "HTTP client did not decode the second chunk")
    check(response.headers:get("X-Trailer") == "done",
          "HTTP client did not retain a trailer")
    while active(peer) do timer.yield() end
    check(peer:status():has_succeeded(), "raw HTTP peer failed")
    outcome = "client-ok"
    return nil
  end)
end

local function expect_client_url_rejected(source_url: string,
                                          authority: string,
                                          expected_kind: string)
  local expected_url?, expected_error? =
    url.parse_request("http", authority, "/")
  check(expected_url == nil and expected_error ~= nil,
        "URL request parser accepted invalid Host: " .. authority)
  local expected_diagnostic = expected_error as url.Error
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
    check(diagnostic.kind == expected_kind and
          diagnostic.kind == expected_diagnostic.kind,
          "HTTP client URL error kind was " .. diagnostic.kind ..
          ", expected " .. expected_kind)
    check(diagnostic.position == expected_diagnostic.position and
          diagnostic.message == expected_diagnostic.message,
          "HTTP client changed the URL parser's Host diagnostic")
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
    check(peer:status():has_succeeded(), "Host validation peer failed")

    expect_client_url_rejected(source_url, "", "host")
    expect_client_url_rejected(source_url, "user@example.com", "userinfo")
    expect_client_url_rejected(
      source_url, "example.com/path", "authority_tail")
    expect_client_url_rejected(
      source_url, "example.com?query", "authority_tail")
    expect_client_url_rejected(
      source_url, "example.com#fragment", "authority_tail")
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

local function expect_header_rejected(name: string, contents: string,
                                      expected: string)
  local rejected = false
  do
    local values = http.headers(nil)
    values:add(name, contents)
  catch
    check(error is string,
          "HTTP header validation raised a non-string error")
    local message = error as string
    check(contains(message, expected),
          "HTTP header validation failed for the wrong reason: " .. message)
    rejected = true
  end
  check(rejected, "HTTP headers accepted invalid input")
end

local function expect_length_rejected(contents: string, expected: string)
  local supplied = http.headers(nil)
  supplied:add("Content-Length", contents)
  local rejected = false
  do
    local response = http.request(
      "POST", "http://127.0.0.1:1/", supplied, "body", nil)
    response:close()
  catch
    check(error is string,
          "HTTP Content-Length validation reached the network")
    local message = error as string
    check(contains(message, expected),
          "HTTP Content-Length failed for the wrong reason: " .. message)
    rejected = true
  end
  check(rejected, "HTTP client accepted an invalid Content-Length")
end

function start_header_validation(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local valid_name =
      "!#$" .. str.char(37) .. "&'*+-.^_`|~09AZaz"
    local valid_contents = str.char(9, 32, 126, 128, 255)
    local accepted = http.headers(nil)
    accepted:add(valid_name, valid_contents)
    check(accepted:get(
            "!#$" .. str.char(37) .. "&'*+-.^_`|~09azaz") ==
          valid_contents,
          "HTTP header token or ASCII case folding changed valid bytes")

    expect_header_rejected("", "value", "must not be empty")
    local invalid_names = {
      "bad:name", "bad name", "bad" .. str.char(0),
      "bad" .. str.char(9), "bad" .. str.char(31),
      "bad" .. str.char(127), "bad" .. str.char(128),
    }
    for index = 1, #invalid_names do
      expect_header_rejected(
        invalid_names[index], "value", "invalid byte")
    end

    local forbidden_values = {0, 8, 10, 13, 31, 127}
    for index = 1, #forbidden_values do
      expect_header_rejected(
        "X-Invalid-Value", "ok" .. str.char(forbidden_values[index]),
        "forbidden byte")
    end

    local method_rejected = false
    do
      local response = http.request(
        "BAD METHOD", "http://127.0.0.1:1/", nil, nil, nil)
      response:close()
    catch
      check(error is string and
            contains(error as string, "HTTP method contains an invalid byte"),
            "HTTP method validation failed for the wrong reason")
      method_rejected = true
    end
    check(method_rejected, "HTTP client accepted an invalid method token")

    expect_length_rejected("", "must not be empty")
    expect_length_rejected("12x", "only decimal digits")
    expect_length_rejected(str.rep("9", 100, nil), "too large")

    -- llhttp validates status-code framing but deliberately treats the reason
    -- phrase as an opaque span. The high-level client still enforces the same
    -- field-value byte repertoire that the server uses for outbound reasons.
    local forbidden_reasons = {1, 127}
    local server, port = raw_listen(first_port)
    local peer = async.run(function (): value
      defer server:close()
      for index = 1, #forbidden_reasons do
        local connection = server:accept()
        local preamble = connection:read_until("\r\n\r\n", false)
        if not preamble then raise "reason-validation peer saw no request" end
        if index == 1 then
          connection:write(
            "HTTP/1.1 103 bad" .. str.char(forbidden_reasons[index]) ..
            "\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n" ..
            "Connection: close\r\n\r\n")
        else
          connection:write(
            "HTTP/1.1 200 bad" .. str.char(forbidden_reasons[index]) ..
            "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        end
        connection:close()
      end
      return nil
    end)
    for index = 1, #forbidden_reasons do
      local reason_rejected = false
      do
        local response = http.get(
          "http://127.0.0.1:" .. str.tostring(port) .. "/", nil, nil)
        response:close()
      catch
        check(error is string and
              contains(error as string,
                       "reason phrase contains a forbidden"),
              "HTTP client rejected an invalid reason for the wrong reason")
        reason_rejected = true
      end
      check(reason_rejected,
            "HTTP client accepted a forbidden reason-phrase byte")
    end
    while active(peer) do timer.yield() end
    check(peer:status():has_succeeded(),
          "reason-validation peer failed")

    outcome = "header-validation-ok"
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
    local body = str.writer()
    for chunk in client:read do body:write(chunk) end
    check(body:drain() ==
          "5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n",
          "HTTP server sent the wrong chunked body")
    client:close()
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(), "HTTP serve Task failed")
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
      local body = str.writer()
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
    local final = str.writer()
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
      local refusal = str.writer()
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
    watchdog:cancel(async.CancellationReason.simple(
      "Expect matrix completed"))
    check(not timed_out, "HTTP Expect matrix timed out")
    server:close()
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(), "HTTP Expect serve Task failed")
    outcome = "expect-ok"
    return nil
  end)
end

function start_buffered_next_requests(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      outcome = "buffered-handler-" .. str.tostring(handled)
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
      outcome = "buffered-timeout-after-" .. outcome
      client:close()
      server:close()
      return nil
    end)
    client:write(
      "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n" ..
      "GET /two HTTP/1.1\r\nHost: localhost\r\n" ..
      "Connection: close\r\n\r\n")
    outcome = "buffered-reading"
    local all = str.writer()
    for chunk in client:read do all:write(chunk) end
    server:close()
    watchdog:cancel(async.CancellationReason.simple(
      "buffered requests completed"))
    check(not watchdog_fired,
          "buffered HTTP requests required the watchdog: " .. outcome)
    local responses = all:drain()
    local first: integer? = str.find(responses, "HTTP/1.1 200 OK")
    local second: integer? = nil
    if first then
      second = str.find(responses, "HTTP/1.1 200 OK",
                        (first as integer) + 1)
    end
    check(first ~= nil and second ~= nil and handled == 2,
          "HTTP server lost a buffered next-request suffix")
    check(contains(responses, "Content-Length: 1\r\n\r\n1") and
          contains(responses,
                   "Content-Length: 1\r\nConnection: close\r\n\r\n2"),
          "serial HTTP responses were not ordered or framed")
    client:close()
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(),
          "buffered-request HTTP serve Task failed")
    outcome = "buffered-suffix-ok"
    return nil
  end)
end

local function start_keep_alive_eof(first_port: integer,
                                    buffered_suffix: string,
                                    suffix: string, result: string,
                                    test_immediate: boolean): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      check(request.target == "/first",
            "keep-alive EOF reached an unexpected handler")
      response:set_header("Content-Length", "0")
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
      outcome = "keep-alive-eof-timeout-after-" .. outcome
      if current then
        do (current as net.Connection):close() catch end
      end
      do server:close() catch end
      return nil
    end)

    if test_immediate then
      -- Closing before request 1 and after a completed keep-alive request are
      -- both idle parser EOFs, not malformed messages.
      outcome = "keep-alive-immediate-eof"
      local immediate = net.connect("127.0.0.1", port)
      current = immediate
      immediate:shutdown()
      check(immediate:read() == nil,
            "HTTP server did not close an idle initial connection")
      immediate:close()
      current = nil
    end

    local client = net.connect("127.0.0.1", port)
    current = client
    client:write(
      "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n" ..
      buffered_suffix)
    local response? = client:read_until("\r\n\r\n", false)
    check(response ~= nil and
          contains(response as string, "Content-Length: 0\r\n") and
          not contains(response as string, "Connection: close\r\n"),
          "HTTP server did not leave the first response reusable")
    if #suffix > 0 then client:write(suffix) end
    outcome = "keep-alive-client-shutdown"
    client:shutdown()
    check(client:read() == nil,
          "HTTP server did not close after the keep-alive peer EOF")
    client:close()
    current = nil

    server:close()
    watchdog:cancel(async.CancellationReason.simple(
      "keep-alive EOF completed"))
    check(not timed_out, "HTTP keep-alive EOF matrix timed out")
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(),
          "HTTP listener failed during keep-alive EOF handling")
    check(handled == 1,
          "HTTP server dispatched an incomplete second request")
    outcome = result
    return nil
  end)
end

function start_idle_keep_alive_eof(first_port: integer): async.Task
  return start_keep_alive_eof(
    first_port, "", "", "idle-keep-alive-eof-ok", true)
end

function start_buffered_empty_lines_eof(
    first_port: integer): async.Task
  return start_keep_alive_eof(
    first_port, "\r\n\r\n", "",
    "buffered-empty-lines-eof-ok", false)
end

function start_partial_keep_alive_eof(first_port: integer): async.Task
  return start_keep_alive_eof(
    first_port, "G", "", "partial-keep-alive-eof-ok", false)
end

function start_partial_empty_line_eof(first_port: integer): async.Task
  return start_keep_alive_eof(
    first_port, "", "\r", "partial-empty-line-eof-ok", false)
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
      for index = 1, 7 do
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
            check(contains(request_text,
                           "head /lowercase-head HTTP/1.1\r\n"),
                  "lowercase method client case changed the method")
            connection:write(
              "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n" ..
              "Connection: close\r\n\r\nbody")
          elseif index == 4 then
            check(contains(request_text, "GET /eof HTTP/1.1\r\n"),
                  "EOF-delimited client case sent the wrong request")
            connection:write(
              "HTTP/1.1 200 OK\r\nX-Mode: eof\r\n\r\neof-body")
          elseif index == 5 then
            check(contains(request_text, "GET /truncated HTTP/1.1\r\n"),
                  "truncated client case sent the wrong request")
            connection:write(
              "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n" ..
              "Connection: close\r\n\r\nabc")
          elseif index == 6 then
            check(contains(request_text, "GET /malformed HTTP/1.1\r\n"),
                  "malformed client case sent the wrong request")
            connection:write(
              "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n" ..
              "Transfer-Encoding: chunked\r\n" ..
              "Connection: close\r\n\r\n0\r\n\r\n")
          else
            check(contains(request_text,
                           "GET /informational-eof HTTP/1.1\r\n"),
                  "informational EOF case sent the wrong request")
            connection:write(
              "HTTP/1.1 103 Early Hints\r\nX-Info: only\r\n\r\n")
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

    outcome = "client-lowercase-head"
    local lowercase_head = http.request(
      "head", base .. "/lowercase-head", nil, nil, nil)
    check(read_response(lowercase_head) == "body",
          "HTTP client treated a case-distinct method as HEAD")

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

    outcome = "client-informational-eof"
    local informational_failed = false
    do
      local informational = http.get(
        base .. "/informational-eof", nil, nil)
      informational:close()
    catch
      check(error is string and
            contains(error as string,
                     "HTTP message ended before it was complete"),
            "HTTP client reported the wrong informational EOF error")
      informational_failed = true
    end
    check(informational_failed,
          "HTTP client accepted EOF after only an informational response")

    while active(peer) do timer.yield() end
    watchdog:cancel(async.CancellationReason.simple(
      "client framing completed"))
    check(not timed_out, "HTTP client framing matrix timed out")
    check(peer:status():has_succeeded(), "raw framing peer failed")
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
      -- already-buffered next-request suffix.
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
    local all = str.writer()
    for chunk in client:read do all:write(chunk) end
    client:close()
    server:close()
    watchdog:cancel(async.CancellationReason.simple(
      "request drain completed"))
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
    check(serving:status():has_succeeded(),
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
      local received = str.writer()
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

    local non_origin_lines = {
      "OPTIONS * HTTP/1.1\r\n",
      "GET http://other.example/path HTTP/1.1\r\n",
      "GET example.com:443 HTTP/1.1\r\n",
      "CONNECT example.com:443 HTTP/1.1\r\n",
    }
    for index = 1, #non_origin_lines do
      outcome = "server-rejecting-non-origin-target-" ..
        str.tostring(index)
      local non_origin = exchange(
        non_origin_lines[index] .. "Host: " .. authority .. "\r\n" ..
        "Connection: close\r\n\r\n")
      check(#non_origin == 0 and handled == 1,
            "HTTP server admitted a non-origin-form request target")
    end

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
    watchdog:cancel(async.CancellationReason.simple(
      "server failure matrix completed"))
    check(not timed_out, "HTTP server failure matrix timed out")
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(),
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
    while serving:status():as_string() == "ready" do timer.yield() end
    check(serving:status():as_string() == "waiting",
          "HTTP serve Task did not suspend in accept")

    local closer: async.Task? = nil
    local close_returned = false
    closer = async.run(function (): value
      (closer as async.Task):cancel(async.CancellationReason.simple(
        "cancel before HTTP listener transport close"))
      server:close()
      close_returned = true
      return nil
    end)
    local close_task = closer as async.Task
    while active(close_task) do timer.yield() end
    check(close_task:status():has_cancelled() and close_returned,
          "Task cancellation interrupted HTTP Server close")

    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      serving:cancel(async.CancellationReason.simple(
        "cancelled HTTP Server close timed out"))
      return nil
    end)
    while active(serving) do timer.yield() end
    watchdog:cancel(async.CancellationReason.simple(
      "cancelled HTTP Server close completed"))
    check(not timed_out, "cancelled HTTP Server close left accept stranded")
    check(serving:status():has_succeeded(),
          "cancelled HTTP Server close did not stop serve cleanly")
    server:close()
    outcome = "server-close-cancel-ok"
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
      (closer as async.Task):cancel(async.CancellationReason.simple(
        "cancel before HTTP client transport close"))
      response:close()
      close_returned = true
      return nil
    end)
    local close_task = closer as async.Task
    while active(close_task) do timer.yield() end
    check(close_task:status():has_cancelled() and close_returned,
          "Task cancellation interrupted HTTP response close")
    check(response:read() == nil,
          "logically closed HTTP response remained readable")

    local timed_out = false
    local watchdog = async.run(function (): value
      timer.sleep(5000)
      timed_out = true
      peer:cancel(async.CancellationReason.simple(
        "cancelled HTTP response close timed out"))
      return nil
    end)
    while active(peer) do timer.yield() end
    watchdog:cancel(async.CancellationReason.simple(
      "cancelled HTTP response close completed"))
    check(not timed_out,
          "cancelled HTTP response close left its peer stranded")
    check(peer:status():has_succeeded() and peer_saw_eof,
          "cancelled HTTP response close did not close its transport")
    response:close()
    outcome = "client-close-cancel-ok"
    return nil
  end)
end

function start_idle_timeout_api(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handler: http.Handler = function (_request: http.Request,
                                            _response: http.Response)
    end

    -- A negative timeout wins over a listener error, proving that validation
    -- happens before the socket is opened.
    local occupied, occupied_port = raw_listen(first_port)
    local plain_rejected = false
    do
      http.listen("127.0.0.1", handler, occupied_port, nil, -1)
    catch
      plain_rejected =
        str.tostring(error) == "HTTP idle timeout must be non-negative"
    end
    occupied:close()
    check(plain_rejected,
          "HTTP plain listener did not validate idle timeout first")

    -- TLS must likewise reject before attempting synchronous PEM input.
    local tls_rejected = false
    do
      http.listen_tls("127.0.0.1",
                      "/definitely/missing/http-idle-timeout.pem",
                      handler, nil, nil, nil, -1)
    catch
      tls_rejected =
        str.tostring(error) == "HTTP idle timeout must be non-negative"
    end
    check(tls_rejected,
          "HTTPS listener read PEM input before timeout validation")

    local default_server, _default_port =
      http_listen(first_port + 101, handler, nil)
    check(default_server:idle_timeout(nil) == 0,
          "HTTP Server default idle timeout was not zero")
    check(default_server:idle_timeout(75) == 0 and
          default_server:idle_timeout(nil) == 75,
          "HTTP Server idle-timeout setter did not return the previous value")
    check(default_server:idle_timeout(0) == 75 and
          default_server:idle_timeout(nil) == 0,
          "HTTP Server idle-timeout setter did not accept zero")
    local setter_rejected = false
    do
      default_server:idle_timeout(-2)
    catch
      setter_rejected =
        str.tostring(error) == "HTTP idle timeout must be non-negative"
    end
    check(setter_rejected and default_server:idle_timeout(nil) == 0,
          "HTTP Server mutated its timeout after rejecting a value")
    default_server:close()

    local configured, _configured_port =
      http_listen(first_port + 202, handler, 43)
    check(configured:idle_timeout(nil) == 43,
          "HTTP listener did not retain its configured idle timeout")
    configured:close()
    outcome = "idle-timeout-api-ok"
    return nil
  end)
end

function start_idle_timeout_plain(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local body_read_started = false
    local handler: http.Handler = function (request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      if request.target == "/boundary" then
        -- Header deadlines do not cover handler work or response writes.
        timer.sleep(90)
        response:set_header("Content-Length", "1")
        response:write("B")
      elseif request.target == "/body-read" then
        -- The header deadline is gone before the handler starts reading the
        -- body. A delayed body therefore remains an application-level wait.
        body_read_started = true
        local body? = request:read()
        check(body == "x",
              "handler-side body read received the wrong contents")
        response:set_header("Content-Length", "1")
        response:write("R")
      else
        response:set_header("Content-Length", "0")
      end
    end

    -- Zero preserves the original indefinite header wait.
    local zero_server, zero_port = http_listen(first_port, handler, nil)
    local zero_serving = async.run(function (): value
      zero_server:serve()
      return nil
    end)
    local delayed = net.connect("127.0.0.1", zero_port)
    timer.sleep(75)
    delayed:write(
      "GET /zero HTTP/1.1\r\nHost: localhost\r\n" ..
      "Connection: close\r\n\r\n")
    local delayed_response? = delayed:read_until("\r\n\r\n", false)
    check(delayed_response ~= nil,
          "zero idle timeout closed a delayed request")
    check(delayed:read() == nil,
          "zero-timeout response did not close with its request")
    delayed:close()
    zero_server:close()
    while active(zero_serving) do timer.yield() end
    check(zero_serving:status():has_succeeded(),
          "zero-timeout HTTP listener failed")
    check(handled == 1, "zero-timeout request did not reach its handler")

    local server, port = http_listen(first_port + 101, handler, 30)
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)

    -- Read immediately instead of sleeping before the assertion. The distant
    -- watchdog is deliberately the only later timer: if the deadline's
    -- reader cancellation or join waits for unrelated live work, it records
    -- the delay before providing that later wakeup. Sending a complete request
    -- also bounds the failure mode where the timeout never closes the peer.
    local prompt = net.connect("127.0.0.1", port)
    local prompt_watchdog_fired = false
    local prompt_watchdog = async.run(function (): value
      timer.sleep(1000)
      prompt_watchdog_fired = true
      do
        prompt:write(
          "GET /late-idle HTTP/1.1\r\nHost: localhost\r\n" ..
          "Connection: close\r\n\r\n")
      catch
      end
      return nil
    end)
    check(prompt:read() == nil,
          "positive idle timeout left an initial request open")
    prompt_watchdog:cancel(async.CancellationReason.simple(
      "HTTP idle timeout completed promptly"))
    async.join(prompt_watchdog)
    check(not prompt_watchdog_fired,
          "HTTP idle timeout needed unrelated live work to complete")
    prompt:close()

    -- Exercise repeated reader/check/timer loser cleanup. None of these idle
    -- connections may dispatch a handler.
    for _ = 1, 2 do
      local idle = net.connect("127.0.0.1", port)
      timer.sleep(90)
      check(idle:read() == nil,
            "positive idle timeout left an initial request open")
      idle:close()
    end
    check(handled == 1,
          "initial idle timeout dispatched an HTTP handler")

    -- Prove that this is one absolute acquisition deadline, not an inactivity
    -- timer. The periodic fragments arrive before 200 ms, but completing the
    -- headers is delayed until after that original deadline. A reset-on-byte
    -- implementation would dispatch the deliberately late request instead.
    check(server:idle_timeout(200) == 30,
          "HTTP Server did not expose the previous timeout")
    local partial = net.connect("127.0.0.1", port)
    partial:write("GET /partial HTTP/1.1\r\nHost: local")
    local partial_feeder = async.run(function (): value
      timer.sleep(70)
      do partial:write("h") catch end
      timer.sleep(70)
      do partial:write("o") catch end
      return nil
    end)
    local partial_late = false
    local partial_watchdog = async.run(function (): value
      timer.sleep(250)
      partial_late = true
      do
        partial:write("st\r\nConnection: close\r\n\r\n")
      catch
      end
      return nil
    end)
    check(partial:read() == nil,
          "idle timeout reset or ignored a partial header deadline")
    partial_watchdog:cancel(async.CancellationReason.simple(
      "absolute HTTP header deadline completed"))
    async.join_two(partial_feeder, partial_watchdog)
    check(not partial_late,
          "partial bytes reset the absolute HTTP header deadline")
    partial:close()
    check(server:idle_timeout(30) == 200,
          "HTTP Server did not restore the focused timeout")
    check(handled == 1,
          "partial timed-out headers dispatched an HTTP handler")

    -- A parser failure belongs to the reader child. The connection Task joins
    -- that child and closes the peer without raising the same failure again.
    -- The Lua-side assertion for this scenario requires exactly one uncaught
    -- Task report, catching either suppression or duplicate reporting.
    local malformed = net.connect("127.0.0.1", port)
    malformed:write(
      "GET /malformed HTTP/1.1\r\nBad Header: value\r\n\r\n")
    check(malformed:read() == nil,
          "malformed positive-timeout request remained open")
    malformed:close()
    check(handled == 1,
          "malformed positive-timeout request reached its handler")

    -- A next request already buffered behind the first is acquired before
    -- the timer even though each request gets its own absolute deadline.
    local buffered = net.connect("127.0.0.1", port)
    buffered:write(
      "GET /buffered-one HTTP/1.1\r\nHost: localhost\r\n\r\n" ..
      "GET /buffered-two HTTP/1.1\r\nHost: localhost\r\n" ..
      "Connection: close\r\n\r\n")
    local buffered_output = str.writer()
    for chunk in buffered:read do buffered_output:write(chunk) end
    local rendered = buffered_output:drain()
    local first_response? = str.find(rendered, "HTTP/1.1 200 OK")
    local second_response: integer? = nil
    if first_response then
      second_response = str.find(
        rendered, "HTTP/1.1 200 OK", (first_response as integer) + 1)
    end
    check(first_response ~= nil and second_response ~= nil,
          "idle timeout lost a buffered next request")
    buffered:close()
    check(handled == 3,
          "buffered requests did not each reach the handler")

    -- A handler-side body read is also outside the header deadline. Delay the
    -- sole body byte for three complete timeout intervals before allowing the
    -- handler and response to finish.
    local body_read = net.connect("127.0.0.1", port)
    body_read:write(
      "POST /body-read HTTP/1.1\r\nHost: localhost\r\n" ..
      "Content-Length: 1\r\nConnection: close\r\n\r\n")
    while not body_read_started do timer.yield() end
    timer.sleep(90)
    body_read:write("x")
    local body_headers? = body_read:read_until("\r\n\r\n", false)
    check(body_headers ~= nil and read_exact(body_read, 1) == "R",
          "idle timeout covered a handler-side request-body read")
    check(body_read:read() == nil,
          "handler-side body-read response did not close")
    body_read:close()
    check(handled == 4,
          "handler-side body read did not reach its handler")

    -- The handler may outlive the idle deadline, and automatic request-body
    -- draining remains application-controlled rather than deadline-bound.
    local boundary = net.connect("127.0.0.1", port)
    boundary:write(
      "POST /boundary HTTP/1.1\r\nHost: localhost\r\n" ..
      "Content-Length: 1\r\n\r\n")
    local boundary_headers? = boundary:read_until("\r\n\r\n", false)
    check(boundary_headers ~= nil and read_exact(boundary, 1) == "B",
          "idle timeout covered handler or response work")
    timer.sleep(90)
    boundary:write(
      "xGET /after-drain HTTP/1.1\r\nHost: localhost\r\n" ..
      "Connection: close\r\n\r\n")
    local after_drain? = boundary:read_until("\r\n\r\n", false)
    check(after_drain ~= nil,
          "idle timeout covered automatic request-body draining")
    check(boundary:read() == nil,
          "post-drain HTTP response did not close")
    boundary:close()
    check(handled == 6,
          "body-drain boundary did not preserve the next request")

    server:close()
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(),
          "positive-timeout HTTP listener failed")

    -- A setter change does not rewrite the deadline of a read already in
    -- progress; it becomes visible on the following keep-alive iteration.
    local snapshot_server, snapshot_port =
      http_listen(first_port + 202, handler, nil)
    local snapshot_serving = async.run(function (): value
      snapshot_server:serve()
      return nil
    end)
    local snapshot = net.connect("127.0.0.1", snapshot_port)
    timer.sleep(10)
    check(snapshot_server:idle_timeout(30) == 0,
          "HTTP Server setter did not expose the prior snapshot")
    timer.sleep(90)
    snapshot:write("GET /snapshot HTTP/1.1\r\nHost: localhost\r\n\r\n")
    check(snapshot:read_until("\r\n\r\n", false) ~= nil,
          "timeout setter changed an in-flight header read")
    timer.sleep(90)
    check(snapshot:read() == nil,
          "timeout setter did not affect the next keep-alive read")
    snapshot:close()
    snapshot_server:close()
    while active(snapshot_serving) do timer.yield() end
    check(snapshot_serving:status():has_succeeded(),
          "snapshot-timeout HTTP listener failed")
    check(handled == 7,
          "snapshot timeout dispatched an unexpected handler")

    outcome = "idle-timeout-plain-ok"
    return nil
  end)
end

function start_idle_timeout_tls(first_port: integer): async.Task
  outcome = "running"
  return async.run(function (): value
    local handled = 0
    local handler: http.Handler = function (_request: http.Request,
                                            response: http.Response)
      handled = handled + 1
      response:set_header("Content-Length", "0")
    end
    local server, port = https_listen(first_port, handler, 30)
    defer server:close()
    check(server:idle_timeout(nil) == 30,
          "HTTPS listener did not retain its idle timeout")
    local serving = async.run(function (): value
      server:serve()
      return nil
    end)

    local expect_tls_timeout = function (connection: ssl.Connection,
                                         label: string)
      local observed = "not-read"
      local reader = async.run(function (): value
        do
          local chunk? = connection:read()
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
        timer.sleep(1000)
        watchdog_fired = true
        reader:cancel(async.CancellationReason.simple(
          label .. " watchdog expired"))
        return nil
      end)
      local reader_status = async.join(reader)
      watchdog:cancel(async.CancellationReason.simple(
        label .. " completed promptly"))
      async.join(watchdog)
      check(not watchdog_fired,
            label .. " needed unrelated live work to complete")
      check(reader_status:has_succeeded(),
            label .. " peer reader did not succeed")
      check(observed == "TLS_TRUNCATED_EOF",
            label .. " reported " .. observed)
    end

    local idle = ssl.connect("127.0.0.1", port, TRUST_ROOT)
    expect_tls_timeout(idle, "initial HTTPS idle timeout")
    idle:close()
    check(handled == 0,
          "HTTPS idle timeout dispatched a handler")

    -- Apply the same policy after one successful keep-alive request. Reading
    -- immediately leaves the listener as unrelated live I/O while the next
    -- request's deadline cancels and joins its SSL reader.
    local keep_alive = ssl.connect("127.0.0.1", port, TRUST_ROOT)
    keep_alive:write(
      "GET /secure-keep-alive HTTP/1.1\r\nHost: localhost\r\n\r\n")
    local keep_alive_response? = keep_alive:read_until("\r\n\r\n", false)
    check(keep_alive_response ~= nil,
          "HTTPS keep-alive request received no response")
    expect_tls_timeout(keep_alive, "HTTPS keep-alive idle timeout")
    keep_alive:close()
    check(handled == 1,
          "HTTPS keep-alive timeout dispatched an extra handler")

    -- Header bytes do not exempt TLS connections from the same deadline.
    local partial = ssl.connect("127.0.0.1", port, TRUST_ROOT)
    partial:write("GET /secure-partial HTTP/1.1\r\nHost: local")
    expect_tls_timeout(partial, "partial-header HTTPS idle timeout")
    partial:close()
    check(handled == 1,
          "partial HTTPS headers dispatched a handler")

    local immediate = ssl.connect("127.0.0.1", port, TRUST_ROOT)
    immediate:write(
      "GET /secure-timeout HTTP/1.1\r\nHost: localhost\r\n" ..
      "Connection: close\r\n\r\n")
    local response? = immediate:read_until("\r\n\r\n", false)
    check(response ~= nil,
          "HTTPS idle timeout rejected an immediate request")
    check(immediate:read() == nil,
          "HTTPS timeout response did not close")
    immediate:close()
    check(handled == 2,
          "HTTPS immediate request did not reach its handler")

    server:close()
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(),
          "HTTPS idle-timeout listener failed")
    outcome = "idle-timeout-tls-ok"
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
        if error is async.OperationError and
           (error as async.OperationError).name == "EADDRINUSE" then
          port = port + 1
        else
          raise error
        end
      end
    end
    if server == nil then raise "could not find an HTTPS loopback port" end
    local exact_server = server as http.Server
    check(exact_server:idle_timeout(nil) == 0,
          "HTTPS Server default idle timeout was not zero")
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
        if error is async.OperationError then
          local failure = error as async.OperationError
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
      requesting:cancel(async.CancellationReason.simple(
        "HTTPS public test timed out"))
      do exact_server:close() catch end
      return nil
    end)
    while active(requesting) do timer.yield() end
    watchdog:cancel(async.CancellationReason.simple(
      "HTTPS request completed"))
    check(not timed_out, "HTTPS public API case timed out")
    check(requesting:status():has_succeeded(),
          "HTTPS request Task did not succeed")
    check(#client_failure == 0,
          "HTTPS response read failed with " .. client_failure)
    check(response_status == 200 and body == "secure\0",
          "HTTPS client did not read the verified response")
    check(handled, "HTTPS handler did not run")
    exact_server:close()
    while active(serving) do timer.yield() end
    check(serving:status():has_succeeded(), "HTTPS serve Task failed")
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
assert(task:status():has_succeeded(),
       task:status():as_string() .. ":" .. cases.result())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, first_port, expected)
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        return output
    end

    it("parses fragmented chunked responses without redirect or decoding",
    function()
        run("start_client", "client", "client-ok")
    end)

    it("validates caller-supplied Host as one complete authority", function()
        run("start_client_host_validation", "client-host",
            "client-host-validation-ok")
    end)

    it("validates outbound fields and inbound reason phrases", function()
        run("start_header_validation", "header-validation",
            "header-validation-ok")
    end)

    it("starts handlers at headers and streams request and response bodies",
    function()
        run("start_server_streaming", "server", "server-streaming-ok")
    end)

    it("resolves 100-continue before waiting for a request body", function()
        run("start_expect_continue", "expect", "expect-ok")
    end)

    it("preserves buffered next requests across serial handlers", function()
        run("start_buffered_next_requests", "buffered-suffix",
            "buffered-suffix-ok")
    end)

    it("treats only idle keep-alive EOF as a clean disconnect", function()
        local marker = "uncaught error in async Task:"
        local clean = run(
            "start_idle_keep_alive_eof", "idle-keep-alive-eof",
            "idle-keep-alive-eof-ok")
        local _, clean_reports = clean:gsub(marker, "")
        assert.equals(0, clean_reports, clean)

        local buffered_empty_lines = run(
            "start_buffered_empty_lines_eof", "buffered-empty-lines-eof",
            "buffered-empty-lines-eof-ok")
        local _, buffered_empty_line_reports =
            buffered_empty_lines:gsub(marker, "")
        assert.equals(1, buffered_empty_line_reports, buffered_empty_lines)
        assert.truthy(buffered_empty_lines:find(
            "HTTP message ended before it was complete", 1, true),
            buffered_empty_lines)

        local partial = run(
            "start_partial_keep_alive_eof", "partial-keep-alive-eof",
            "partial-keep-alive-eof-ok")
        local _, partial_reports = partial:gsub(marker, "")
        assert.equals(1, partial_reports, partial)
        assert.truthy(partial:find(
            "HTTP parse error HPE_INVALID_EOF_STATE: Invalid EOF state",
            1, true), partial)

        local partial_empty_line = run(
            "start_partial_empty_line_eof", "partial-empty-line-eof",
            "partial-empty-line-eof-ok")
        local _, partial_empty_line_reports =
            partial_empty_line:gsub(marker, "")
        assert.equals(1, partial_empty_line_reports, partial_empty_line)
        assert.truthy(partial_empty_line:find(
            "HTTP message ended before it was complete", 1, true),
            partial_empty_line)
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

    it("completes a listener close despite Task cancellation", function()
        run("start_cancelled_server_close", "server-close-cancel",
            "server-close-cancel-ok")
    end)

    it("completes a client close despite Task cancellation", function()
        run("start_cancelled_client_close", "client-close-cancel",
            "client-close-cancel-ok")
    end)

    it("validates and updates the HTTP Server idle-timeout API", function()
        run("start_idle_timeout_api", "idle-timeout-api",
            "idle-timeout-api-ok")
    end)

    it("bounds only plain HTTP request-header acquisition", function()
        local output = run("start_idle_timeout_plain", "idle-timeout-plain",
            "idle-timeout-plain-ok")
        local _, reports = output:gsub("uncaught error in async Task:", "")
        assert.equals(1, reports, output)
        assert.truthy(output:find("HTTP parse error", 1, true), output)
    end)

    it("applies the same idle timeout to HTTPS connections", function()
        local output = run("start_idle_timeout_tls", "idle-timeout-tls",
            "idle-timeout-tls-ok")
        local _, reports = output:gsub("uncaught error in async Task:", "")
        assert.equals(0, reports, output)
    end)

    it("serves and requests verified HTTPS through the public API", function()
        run("start_https", "https", "https-ok")
    end)
end)
