# URL standard library

The `url` standard module parses and normalizes absolute HTTP, HTTPS, WS and WSS URLs,
including URLs supplied as separate scheme, authority, and request-target
components. It is synchronous and performs no network I/O: callers can use
the parsed value for HTTP, routing, validation, logging, or another layer that
consumes HTTP(S) or WebSocket endpoint identifiers. Titan source uses the short import:

```titan
local url = import "url"
```

The parser resolves that spelling to the canonical `titan.url` module
identity. Lua loads the same module with `require "titan.url"`.

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

record Error
    position: integer
    kind: string
    message: string
end

function parse(source: string): (Url?, Error?)
function parse_request(
  scheme: string,
  authority: string,
  target: string
): (Url?, Error?)
function Url:host_header(): string
```

`parse` and `parse_request` are recoverable boundaries. A valid input returns
the parsed `Url` and nil. Invalid input returns nil and an `Error`; malformed
input never raises. The two positions are mutually exclusive:

```titan
local url = import "url"

function endpoint(source: string): (string?, string?)
  local parsed?, problem? = url.parse(source)
  if problem then
    return nil, problem.message
  end
  return parsed.host .. ":" .. parsed.port, nil
end
```

The condition does not flow-narrow either option. Field access is already a
bare-value context, so Titan inserts the checked option force for `problem` and
`parsed`; explicit `as url.Error`/`as url.Url` casts would only restate that
ordinary conversion.

The `Error` field is named `kind`, rather than `type`, because `type` is a
Titan keyword. `position` is the one-based byte position at which parsing or a
semantic URL policy check failed. For `parse_request`, positions refer to the
virtual absolute URL `scheme .. "://" .. authority .. target`, even when an
authority or origin-form boundary check fails before those components are
joined. The stable `kind` values and corresponding message details are:

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

`message` combines that identifier and position with its detail:

```text
URL parse error [port] at byte 20: expected a decimal port in the range 1..65535
```

Callers should branch on `kind` when behavior depends on the failure and use
`message` for display.

For example, `http://[::%25]/` returns kind `zone` at byte 14 with message:

```text
URL parse error [zone] at byte 14: expected a nonempty zone identifier after '%25'
```

## Separately received request components

`parse_request(scheme, authority, target)` builds the same normalized `Url`
from the three components which an HTTP server receives independently. The
scheme must be exactly `http`, `https`, `ws` or `wss`, compared case-insensitively; an
invalid separate scheme reports `scheme` at byte 1. The authority must be one
complete authority: an unescaped `/`, `?`, or `#` is an
`authority_tail` error instead of being allowed to consume part of `target`.
Raw `@` remains part of the absolute grammar's user-information check and
therefore reports `userinfo`.

The target must be origin-form and begin with `/`. Empty, absolute-form,
authority-form, and asterisk-form targets report `origin_form`. Once these
component boundaries are established, the exact concatenation is parsed by the
same absolute grammar as `parse`, so host, IP-literal, port, path, query,
percent-escape, normalization, and structured-error behavior stay identical.

## Accepted URLs

This iteration accepts an absolute `http://`, `https://`, `ws://` or `wss://` URL with an
authority and nonempty host. User information and fragments are deliberately
unsupported. The host grammar accepts RFC 3986 registered names, IPv4
addresses, bracketed IPv6 addresses, and bracketed IPvFuture literals. IPv6
zone identifiers use the RFC 6874 `%25` separator and require a nonempty zone
component. An unbracketed IPv6 authority is invalid.

The returned fields are normalized:

- `scheme` is lowercase;
- `host` is the connection and TLS-identity spelling, without URI brackets;
- `port` is the explicit port or the effective default, 80 for HTTP/WS and 443
  for HTTPS/WSS;
- `path` is `/` when the source path is empty;
- `query` distinguishes an absent query from a present empty query;
- `target` is the origin-form path plus the optional `?query`; and
- `authority` is the normalized Host-header spelling, including brackets for
  an IP literal and an explicitly supplied canonical decimal port.

An explicit port must contain decimal digits and have value `1..65535`. Its
presence is preserved in `authority` even when it equals the scheme's default.
`host_header()` returns `authority`.

The scheme is preserved after normalization: parsing `wss://` does not turn
it into `https://`. The WebSocket client derives its HTTP opening target from
this value. Ordinary HTTP entry points accept only HTTP/HTTPS and reject WS/WSS
before acquiring a transport.

For an IP literal, `host` omits brackets because it is suitable for DNS/TCP
and TLS identity handling, while `authority` preserves them. A zoned address
such as `[fe80::1%25eth0]` therefore has `host == "fe80::1%eth0"` and keeps
`[fe80::1%25eth0]` in `authority`.

Normalization lowercases a registered-name host. In the host, path, query,
and zone identifier, a percent-encoded unreserved byte is decoded; every
retained escape keeps its meaning but uses uppercase hexadecimal digits. Thus
`%5f` becomes `_`, while encoded `/` remains `%2F`. IPv6 hexadecimal and the
IPvFuture version prefix are lowercase; an IPvFuture suffix and
zone-identifier letters otherwise retain their case.

Strings and positions are byte-oriented. The module does not perform Unicode
host-name conversion, resolve names, open connections, follow redirects, or
attach meaning to paths and queries.

## Grammar provenance

The parser is a Titan `peg` relabel-source translation of the RFC 3986 URI
grammar from `daurnimator/lpeg_patterns` at commit
`0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`. Titan specializes that grammar at
the public boundary described above and uses labeled failures for precise
errors. The derivative is covered by the upstream MIT license recorded in
`LICENSES/lpeg-patterns-LICENSE` and `THIRD_PARTY_NOTICES.md`.
