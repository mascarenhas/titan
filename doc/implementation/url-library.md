# URL-library implementation

The public API and normalization contract are documented in the
[URL standard-library chapter](../language/standard-library-url.md). This
chapter is the canonical home of URL parsing: the one-time PEG construction,
the labeled failure boundary, and byte normalization in `titan/url.titan`.

## Module boundary

`titan.url` is one flat logical standard module. It imports the public short
`peg` and `string` modules and reads bytes through `string.byte`. It has no
foreign import, C source, callback, queue, or native parser, so parsing is
synchronous and never yields.

HTTP imports `url` and consumes its public `Url` and `Error` records; it does
not own, duplicate, or re-export the grammar. How HTTP uses the parsed fields,
raises `url.Error`, and restricts its own entry points to `http`/`https` is in
[HTTP URL consumption](http-library.md#headers-url-consumption-and-framing).

## Grammar construction and labels

The RFC 3986 productions are a Titan translation, in `titan.peg`'s Relabel
source syntax, of daurnimator/lpeg_patterns at commit
`0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`, under the upstream MIT license
(`LICENSES/lpeg-patterns-LICENSE`, `THIRD_PARTY_NOTICES.md`).

The module initializer calls four private constructors once and stores their
`peg.Pattern` results; parsing never rebuilds or recompiles a PEG:

| Stored pattern | Constructor | Recognizes |
| --- | --- | --- |
| `http_url_pattern` | `url_pattern` | The complete absolute URL grammar. |
| `request_scheme_pattern` | `scheme_pattern` | Exactly case-insensitive `http`, `https`, `ws` or `wss`, so delimiters in the separately supplied scheme cannot consume the authority. |
| `request_authority_pattern` | `authority_pattern` | `[^/?#]*` followed by the end of the received authority; any tail is labeled `authority_tail`. `@` is allowed here so the complete grammar can report its more specific `userinfo` error. |
| `request_origin_pattern` | `origin_pattern` | A target beginning with `/`; other target forms are labeled `origin_form`. |

The absolute grammar captures component text and the starting byte positions
needed for semantic failures. It requires an authority and a nonempty host,
labels unsupported user information and fragments, requires brackets around IP
literals, labels a `%25` zone separator with no following zone identifier, and
restricts an explicit port syntactically to digits. `parse` then accepts only
the schemes `http` and `ws` (default port 80) and `https` and `wss` (default
port 443), and `parse_port` enforces the numeric range `1..65535`. `scheme`
keeps the normalized original protocol.

A committed Relabel failure yields a stable label and a one-based byte
position; semantic scheme and port failures use their captured component
positions. `url_parse_error` converts either into the public `Error` record
with the message `URL parse error [kind] at byte N: detail`. `parse` returns
that value in the second tuple slot instead of raising, and the success and
failure positions are mutually exclusive on every path.

## Request components

`parse_request` first matches the scheme, authority, and origin-form boundary
patterns. Authority and target failure positions are offset into the virtual
source `scheme .. "://" .. authority .. target`, which is the coordinate space
for every `Error.position` it returns; a scheme-boundary failure is at byte 1.
Once all three boundaries hold, it passes that exact concatenation to `parse`.
The absolute grammar therefore remains the only component parser, and
normalization and semantic checks are identical between the two entry points.

## Normalization

`normalize_component` walks the string through `string.byte`. It decodes
percent-encoded RFC 3986 unreserved bytes, uppercases the hexadecimal digits of
every retained escape, and optionally lowercases ASCII in a scheme or
registered-name host. A synchronous `string.writer()` accumulates the result.

`normalize_host` distinguishes registered names, IPv4, IPv6, IPvFuture, and
RFC 6874 zones, and returns two spellings. The connection host (`Url.host`)
omits URI brackets and decodes a zone's `%25` separator to `%`; the authority
host keeps the brackets and the encoded separator, for use in an HTTP Host
field. Default ports are assigned only when the port is absent, and an explicit
port is rendered from its parsed integer. An empty path becomes `/`, and the
normalized path plus the optional normalized query form `Url.target`.

## Tests

The non-LuaCov native suite `spec/stdlib/titan/url/tests.titan` carries the
accepted and rejected URI matrix, normalization cases, tuple exclusivity, exact
`Error` fields, and the separate authority/origin-form boundary matrix. HTTP's
own tests cover propagation of the structured failure and server use of
normalized URLs.
