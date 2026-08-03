# URL standard library

The `url` standard module parses and normalizes absolute HTTP and HTTPS URLs.
It is synchronous and performs no network I/O: callers can use the parsed
value for HTTP, routing, validation, logging, or another layer that consumes
HTTP(S) endpoint identifiers. Titan source uses the short import:

```titan
local url = import "url"
```

The parser resolves that spelling to the canonical `titan.url` module
identity. Lua loads the same module with `require "titan.url"`.

## API

```titan
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
function Url:host_header(): string
```

`parse` is a recoverable boundary. A valid input returns the parsed `Url` and
nil. Invalid input returns nil and an `Error`; malformed input never raises.
The two positions are mutually exclusive:

```titan
local url = import "url"

function endpoint(source: string): string?
  local parsed?, problem? = url.parse(source)
  if problem then
    local exact = problem as url.Error
    print(exact.message)
    return nil
  end
  local exact = parsed as url.Url
  return exact.host .. ":" .. exact.port
end
```

The `Error` field is named `kind`, rather than `type`, because `type` is a
Titan keyword. `position` is the one-based byte position at which parsing or a
semantic URL policy check failed. The stable `kind` values and corresponding
message details are:

| `kind` | Detail |
| --- | --- |
| `scheme` | `expected an HTTP or HTTPS scheme` |
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
| `fragment` | `fragments are unsupported` |
| `url_tail` | `unexpected byte in the path or query` |
| `url` | `invalid absolute HTTP URL` |

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

## Accepted URLs

This iteration accepts an absolute `http://` or `https://` URL with an
authority and nonempty host. User information and fragments are deliberately
unsupported. The host grammar accepts RFC 3986 registered names, IPv4
addresses, bracketed IPv6 addresses, and bracketed IPvFuture literals. IPv6
zone identifiers use the RFC 6874 `%25` separator and require a nonempty zone
component. An unbracketed IPv6 authority is invalid.

The returned fields are normalized:

- `scheme` is lowercase;
- `host` is the connection and TLS-identity spelling, without URI brackets;
- `port` is the explicit port or the effective default, 80 for HTTP and 443
  for HTTPS;
- `path` is `/` when the source path is empty;
- `query` distinguishes an absent query from a present empty query;
- `target` is the origin-form path plus the optional `?query`; and
- `authority` is the normalized Host-header spelling, including brackets for
  an IP literal and an explicitly supplied canonical decimal port.

An explicit port must contain decimal digits and have value `1..65535`. Its
presence is preserved in `authority` even when it equals the scheme's default.
`host_header()` returns `authority`.

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
