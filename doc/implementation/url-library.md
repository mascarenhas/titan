# URL-library implementation

The public API and normalization contract are documented in the
[URL standard-library chapter](../language/standard-library-url.md). This
chapter describes the one-time PEG construction, labeled failure boundary,
and byte normalization in `titan.url`.

## Module boundary

`titan/url.titan` is one flat logical standard module. It imports the public
short `peg` and `string` modules. Byte access uses the public `string.byte`
operation; there is no foreign import, URL-specific C source, callback, queue,
or native parser.

HTTP imports `url` and consumes its public `Url` and `Error` records. The HTTP
folder module does not own, duplicate, or re-export the URL grammar. This keeps
URL parsing synchronous and reusable while the HTTP client and server remain
high-level wrappers over `net` and `ssl`.

## Grammar construction and labels

The RFC 3986 productions are a Titan translation, in `titan.peg`'s Relabel
source syntax, of daurnimator/lpeg_patterns at commit
`0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`. The derivative uses the upstream
MIT license recorded in `THIRD_PARTY_NOTICES.md` and
`LICENSES/lpeg-patterns-LICENSE`.

The module initializer calls four private grammar constructors once and stores
the resulting `peg.Pattern` values. `http_url_pattern` is the complete absolute
URL grammar. `request_scheme_pattern` accepts exactly case-insensitive `http`
or `https`, so delimiters in that separately supplied component cannot consume
the authority. `request_authority_pattern` recognizes `[^/?#]*` followed by
the end of the separately received authority and labels a delimiter or other
tail as `authority_tail`. It deliberately permits `@`: the complete grammar
then recognizes user information and preserves its more specific `userinfo`
error. `request_origin_pattern` requires the separately received request
target to begin with `/` and labels other target forms as `origin_form`. Calls
match the stored patterns directly; parsing never rebuilds or recompiles a PEG.

The absolute grammar captures component text and the starting byte positions
required for semantic failures. It requires an authority and nonempty host,
labels unsupported user information and fragments, requires brackets around
IP literals, labels a `%25` zone separator without a following zone identifier,
and constrains an explicit port syntactically to digits. Titan code then accepts
only `http` and `https` and checks the numeric port range `1..65535`.

A committed Relabel failure produces a stable label and one-based byte
position. Semantic scheme and port failures use their captured component
positions. `url_parse_error` converts either form into the public `Error`
record and its rendered `URL parse error [kind] at byte N: detail` message.
`parse` returns that value in the second tuple slot instead of raising. The
success and failure tuple positions remain mutually exclusive on every path.

`parse_request` first matches the scheme, authority, and origin-form boundary
patterns. Authority and target failure positions are offset into the virtual
source `scheme .. "://" .. authority .. target`, which is also the public
coordinate space for every returned `Error.position`; a scheme-boundary
failure is at byte 1. Once all three boundaries hold, it passes that exact
concatenation to `parse`; the absolute grammar remains the only component
parser and the normalization and semantic checks therefore stay identical
between the two entry points.

## Normalization

`normalize_component` walks immutable Titan strings through `string.byte`. It
decodes percent-encoded RFC 3986 unreserved bytes, uppercases the hexadecimal
digits of every retained escape, and optionally applies ASCII lowercase to a
scheme or registered-name host. A synchronous `string.writer()` accumulates
each result without introducing an asynchronous yield into the parse.
Host normalization caches its first-byte tests instead of repeating byte
lookups.

`normalize_host` distinguishes registered names, IPv4, IPv6, IPvFuture, and
RFC 6874 zones. Connection identity omits URI brackets and decodes a zone's
`%25` separator to `%`; the public authority keeps brackets and the encoded
separator for an HTTP Host field. Default ports are assigned only when absent,
while an explicit port is rendered from its parsed integer. An empty path
becomes `/`, and the normalized path plus optional normalized query forms
`Url.target`.

## HTTP consumption and provider composition

The HTTP client connects with `Url.host` and `Url.port`, generates a missing
Host field from `Url.authority`, and sends `Url.target`. The server calls
`parse_request` with its scheme, received Host authority, and origin-form
target. HTTP operations raise the returned `url.Error` when they cannot
proceed; both standalone URL entry points remain nonthrowing.

The URL root adds one logical protocol, archive metadata key, generated shim,
and `luaopen_titan_url` entry to the coordinated provider. Together with the
new SSL and HTTP modules, the current image has seventeen logical modules and
shims and eighteen DSO openers including bare `luaopen_titan`. ABI 0.22
publishes that complete image in its own namespace; it does not migrate or
clean up the preserved ABI-0.21 provider.

The non-LuaCov URL suite carries the accepted and rejected URI matrix,
normalization cases, tuple exclusivity, exact `Error` fields, and the separate
authority/origin-form boundary matrix. HTTP tests separately prove client
propagation of the structured failure value plus server consumption of
normalized URLs and rejection of malformed Host authorities.
