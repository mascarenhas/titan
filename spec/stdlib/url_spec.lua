local async_stdlib = require "spec.support.async_stdlib"

-- The valid cases below adapt the HTTP-relevant URI normalization examples
-- from daurnimator/lpeg_patterns' spec/uri_spec.lua at commit
-- 0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7. The public parser is
-- deliberately narrower: it requires an absolute http(s) URL and rejects
-- user information and fragments.
local URL_CASES = [==[
local str = import "string"
local url = import "url"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function error_detail(kind: string): string
  if kind == "scheme" then return "expected an HTTP or HTTPS scheme"
  elseif kind == "scheme_separator" then
    return "expected ':' after the scheme"
  elseif kind == "authority_separator" then
    return "expected '//' before the authority"
  elseif kind == "userinfo" then
    return "user information is unsupported"
  elseif kind == "ipv6_brackets" then
    return "IPv6 addresses must use brackets"
  elseif kind == "ip_literal" then
    return "expected an IPv6 or IPvFuture address"
  elseif kind == "ipv6_close" then
    return "expected ']' after the IP literal"
  elseif kind == "zone" then
    return "expected a nonempty zone identifier after '%25'"
  elseif kind == "host" then return "expected a nonempty host"
  elseif kind == "port" then
    return "expected a decimal port in the range 1..65535"
  elseif kind == "percent_escape" then
    return "expected two hexadecimal digits after '%'"
  elseif kind == "authority_tail" then
    return "unexpected byte in the authority"
  elseif kind == "fragment" then return "fragments are unsupported"
  elseif kind == "url_tail" then
    return "unexpected byte in the path or query"
  end
  return "invalid absolute HTTP URL"
end

local function expected_message(kind: string, position: integer): string
  return "URL parse error [" .. kind .. "] at byte " ..
    str.tostring(position) .. ": " .. error_detail(kind)
end

local function parse_valid(source: string): url.Url
  local parsed?, parse_error? = url.parse(source)
  check(parsed ~= nil, "valid URL was rejected: " .. source)
  check(parse_error == nil,
        "valid URL returned both a result and an error: " .. source)
  return parsed as url.Url
end

local function expect_error(source: string, kind: string,
                            position: integer)
  -- Invalid input is an ordinary `(nil, Error)` result, not a raised value.
  local parsed?, parse_error? = url.parse(source)
  check(parsed == nil,
        "invalid URL returned both a result and an error: " .. source)
  check(parse_error ~= nil, "invalid URL was accepted: " .. source)
  local diagnostic = parse_error as url.Error
  check(diagnostic.kind == kind,
        "URL diagnostic kind was " .. diagnostic.kind ..
        ", expected " .. kind)
  check(diagnostic.position == position,
        "URL diagnostic position was " ..
        str.tostring(diagnostic.position) .. ", expected " ..
        str.tostring(position))
  check(diagnostic.message == expected_message(kind, position),
        "URL diagnostic message was incomplete: " .. diagnostic.message)
end

local function expect_rejected(source: string)
  local parsed?, parse_error? = url.parse(source)
  check(parsed == nil,
        "invalid URL returned both a result and an error: " .. source)
  check(parse_error ~= nil, "invalid URL was accepted: " .. source)
  local diagnostic = parse_error as url.Error
  check(#diagnostic.kind > 0, "URL diagnostic kind was empty")
  check(diagnostic.position >= 1 and
        diagnostic.position <= #source + 1,
        "URL diagnostic position was not one-based")
  check(diagnostic.message ==
        expected_message(diagnostic.kind, diagnostic.position),
        "URL diagnostic message was incomplete: " .. diagnostic.message)
end

function run(): string
  local full = parse_valid(
    "http://Example.COM:8080/path/to?q=one")
  check(full.scheme == "http" and full.host == "example.com" and
        full.port == 8080 and full.path == "/path/to" and
        full.query == "q=one" and full.target == "/path/to?q=one" and
        full.authority == "example.com:8080" and
        full:host_header() == full.authority,
        "full absolute HTTP URL was parsed incorrectly")

  local secure = parse_valid("HtTpS://LOCALHOST")
  check(secure.scheme == "https" and secure.host == "localhost" and
        secure.port == 443 and secure.path == "/" and
        not secure.query and secure.target == "/" and
        secure.authority == "localhost" and
        secure:host_header() == secure.authority,
        "HTTPS scheme, localhost, or default path normalization failed")

  local empty_query = parse_valid("http://localhost?")
  check(empty_query.path == "/" and empty_query.query == "" and
        empty_query.target == "/?",
        "empty path or present empty query was lost")

  local explicit_default = parse_valid("https://localhost:00443/")
  check(explicit_default.port == 443 and
        explicit_default.authority == "localhost:443",
        "explicit default port was not retained and canonicalized")

  local numeric_reg_name =
    parse_valid("http://1.2.3.4.example/numeric-name")
  check(numeric_reg_name.host == "1.2.3.4.example" and
        numeric_reg_name.path == "/numeric-name",
        "an IPv4-shaped registered-name prefix captured the host")

  local ipv6 = parse_valid("http://[::1]:80")
  check(ipv6.host == "::1" and ipv6.port == 80 and
        ipv6.authority == "[::1]:80",
        "bracketed IPv6 URL was parsed incorrectly")

  local future = parse_valid("http://[V4.2]:81/future")
  check(future.host == "v4.2" and future.port == 81 and
        future.path == "/future" and
        future.authority == "[v4.2]:81",
        "IPvFuture URL was parsed incorrectly")

  local zoned = parse_valid("http://[::1%25eth0]/zone")
  check(zoned.host == "::1%eth0" and zoned.path == "/zone" and
        zoned.authority == "[::1%25eth0]",
        "IPv6 zone identifier was parsed incorrectly")

  -- These are the HTTP-authority forms of the valid address matrix in
  -- lpeg_patterns' spec/IPv6_spec.lua. The public URL value deliberately
  -- preserves compression and group spelling while lowercasing hex digits.
  local valid_ipv6 = {
    "::", "::0.0.0.0", "::0:0.0.0.0", "0::0.0.0.0", "::1",
    "ff02::1", "2001:0db8:85a3:0042:1000:8a2e:0370:7334",
    "::FFFF:204.152.189.116",
  }
  for index = 1, #valid_ipv6 do
    local literal = valid_ipv6[index]
    local parsed = parse_valid("http://[" .. literal .. "]/address")
    local normalized = str.lower(literal)
    check(parsed.host == normalized and
          parsed.authority == "[" .. normalized .. "]",
          "valid IPv6 authority was not preserved: " .. literal)
  end

  -- And the corresponding invalid upstream matrix, specialized to a
  -- bracketed HTTP authority. Every rejection has structured error fields.
  local invalid_ipv6 = {
    "", "not an ip", "::x", "x::", ":::", ":1::",
    "1234::5678::", "::FFFF:0.0.0", "::FFFF:0.999.0.0",
    "::01.02.03.04",
  }
  for index = 1, #invalid_ipv6 do
    expect_rejected("http://[" .. invalid_ipv6[index] .. "]/")
  end

  local escaped = parse_valid(
    "https://l%4FcAlH%6fSt/under%73core%5fcharacter/" ..
    "%00/kept%2fslash?query%26with%5fescapes")
  check(escaped.host == "localhost" and
        escaped.path == "/underscore_character/%00/kept%2Fslash" and
        escaped.query == "query%26with_escapes" and
        escaped.target ==
          "/underscore_character/%00/kept%2Fslash?query%26with_escapes",
        "percent escapes were not normalized without ambiguity")

  expect_error("ftp://example.com/", "scheme", 1)
  expect_error("//localhost/path", "scheme", 1)
  expect_error("http//example.com/", "scheme_separator", 5)
  expect_error("http:/example.com/", "authority_separator", 7)
  expect_error("http://user@example.com/", "userinfo", 8)
  expect_error("http://example.com/path#fragment", "fragment", 24)
  expect_error("http://example.com:oops/", "port", 20)
  expect_error("http://example.com:0/", "port", 20)
  expect_error("http://example.com:65536/", "port", 20)
  expect_error("http://example.com/path\\tail", "url_tail", 24)
  expect_error("http:///path", "host", 8)
  expect_error("http://::1/", "ipv6_brackets", 8)
  expect_error("http://[v.2]/", "ip_literal", 9)
  expect_error("http://[::%25]/", "zone", 14)
  expect_error("http://host/bad%x0percent", "percent_escape", 17)
  expect_error("http://host/%s", "percent_escape", 14)
  return "url-parser-ok"
end
]==]

describe("URL standard library", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("url-runtime")
        async_stdlib.write_source(workspace, "url_cases", URL_CASES)
        async_stdlib.compile(workspace, "url_cases")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("normalizes HTTP URLs and returns structured parse errors", function()
        local source = [==[
local cases = require "url_cases"
local url = require "titan.url"

local valid = table.pack(url.parse("http://example.com/path"))
assert(valid.n == 2 and valid[1] and valid[2] == nil)
local invalid = table.pack(url.parse("http://example.com:65536/"))
assert(invalid.n == 2 and invalid[1] == nil and invalid[2])
assert(invalid[2].kind == "port" and invalid[2].position == 20)
assert(invalid[2].message ==
       "URL parse error [port] at byte 20: expected a decimal port " ..
       "in the range 1..65535")
assert(cases.run() == "url-parser-ok")
]==]
        local ok, status, output =
            async_stdlib.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)
