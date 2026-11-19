# URL standard library

The `url` module synchronously parses and normalizes absolute `http`, `https`, `ws`, and `wss` URLs without performing network I/O, including URLs assembled from separate scheme, authority, and request-target components. Import it in Titan with `local url = import "url"` or load it in Lua with `require "titan.url"`.

**Target availability:** Native & Browser (full API on both targets).

## Example

This program parses both a valid URL (showing case, port, and percent-escape normalization) and a malformed URL (showing the error `kind`, 1-based byte `position`, and formatted `message`):

```titan
local io = import "io"
local url = import "url"

local function inspect(source: string): string
  local parsed?, problem? = url.parse(source)
  if problem then
    return "error [" .. problem.kind .. "] at byte "
      .. problem.position .. ": " .. problem.message
  end
  return parsed.scheme .. "://" .. parsed:host_header() .. parsed.target
end

function main(args: {string}): integer
  io.print(inspect("HTTPS://Example.COM/items%5f1?page=2"))
  io.print(inspect("http://[::%25]/"))
  return 0
end
```

## API

```text
record Url
  scheme: string
  host: string
  port: integer
  path: string
  query: string?
  target: string
  authority: string
end
function Url.new(scheme: string, host: string, port: integer,
                 path: string, query: string?, target: string,
                 authority: string): Url

record Error
  position: integer
  kind: string
  message: string
end
function Error.new(position: integer, kind: string, message: string): Error

function parse(source: string): (Url?, Error?)
function parse_request(scheme: string, authority: string,
                       target: string): (Url?, Error?)
function Url:host_header(): string
```

`parse` and `parse_request` never raise on malformed input. They return `(Url, nil)` on success and `(nil, Error)` on failure; the two tuple positions are mutually exclusive. Because field access automatically unwraps Options, handle `problem` first and access `parsed` fields directly without `as` casts.

### Accepted URLs and normalization

`url` accepts absolute `http://`, `https://`, `ws://`, and `wss://` URLs with a nonempty host and no userinfo (`user@`) or `#fragment`. Hosts may be RFC 3986 registered names, IPv4 addresses, bracketed IPv6 addresses (including RFC 6874 `%25` zone identifiers with a nonempty zone), or bracketed IPvFuture literals. Explicit ports must be decimal integers in `1..65535`.

Normalized fields on `Url`:

- **`scheme`**: lowercased (`"http"`, `"https"`, `"ws"`, or `"wss"`); `ws`/`wss` are preserved rather than converted to `http`/`https`.
- **`host`**: host formatted for DNS, TCP, and TLS identity checks, **without** URI brackets (for example `[fe80::1%25eth0]` becomes `"fe80::1%eth0"`). Registered names, IPv6 hex digits, and IPvFuture version prefixes are lowercased.
- **`port`**: explicit port, or the scheme default (`80` for `http`/`ws`, `443` for `https`/`wss`).
- **`path`**: normalized path (`"/"` when omitted in the source).
- **`query`**: normalized query string without `?`, distinguishing absent (`nil`) from present empty (`""`).
- **`target`**: origin-form `path` plus optional `"?" .. query`.
- **`authority`** (and **`Url:host_header()`**): normalized `Host`-header spelling, retaining brackets for IP literals and retaining an explicitly supplied port even when it equals the default.

In `host`, `path`, `query`, and zone identifiers, percent-encoded unreserved bytes are decoded (such as `%5f` -> `_`) while retained escapes use uppercase hexadecimal digits (such as `%2F`). All strings and byte positions are byte-oriented; `url` performs no Unicode IDNA conversion, DNS resolution, or redirect logic.

### Structured errors

`Error.position` is the 1-based byte offset where parsing or policy validation failed. `Error.message` formats `kind`, `position`, and detail (for example `URL parse error [zone] at byte 14: expected a nonempty zone identifier after '%25'`). Branch on `kind` programmatically:

| `kind` | Detail |
| --- | --- |
| `scheme` | `expected an HTTP, HTTPS, WS or WSS scheme` |
| `scheme_separator` | `expected ':' after the scheme` |
| `authority_separator` | `expected '//' before the authority` |
| `userinfo` | `user information is unsupported` |
| `ipv6_brackets` | `IPv6 addresses must use brackets` |
| `ip_literal` | `expected an IPv6 or IPvFuture address` |
| `ipv6_close` | `expected ']' after the IP literal` |
| `zone` | `expected a nonempty zone identifier after '%25'` |
| `host` | `expected a nonempty host` |
| `port` | `expected a decimal port in the range 1..65535` |
| `percent_escape` | `expected two hexadecimal digits after '%'` |
| `authority_tail` | `unexpected byte in the authority` |
| `origin_form` | `expected an origin-form request target beginning with '/'` |
| `fragment` | `fragments are unsupported` |
| `url_tail` | `unexpected byte in the path or query` |
| `url` | `invalid absolute HTTP or WebSocket URL` |

## Separately received request components

`parse_request(scheme, authority, target)` constructs the same normalized `Url` from the three components an HTTP server receives separately:

- **`scheme`** must be `http`, `https`, `ws`, or `wss` (ASCII case-insensitive); invalid values report `scheme` at byte `1`.
- **`authority`** must be a single complete authority: unescaped `/`, `?`, or `#` reports `authority_tail` rather than bleeding into `target`, and `@` reports `userinfo`.
- **`target`** must be origin-form starting with `/` (empty, absolute-form, authority-form, and `*` targets report `origin_form`).

Once component boundaries pass, the combined virtual URL `scheme .. "://" .. authority .. target` is parsed and normalized by the same grammar as `parse`, and `Error.position` always indexes into that virtual URL.

## Grammar provenance

The parser is a `titan.peg` relabel-source translation of the RFC 3986 URI grammar from `daurnimator/lpeg_patterns` (commit `0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`), specialized with labeled failures. See `LICENSES/lpeg-patterns-LICENSE` and `THIRD_PARTY_NOTICES.md`.
