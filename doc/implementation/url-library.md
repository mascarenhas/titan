# URL-library implementation

The public API and normalization contract are documented in the
[URL standard-library chapter](../language/standard-library-url.md). This
chapter describes the one-time PEG construction, labeled failure boundary,
and byte normalization in `titan.url`.

## Module boundary

`titan/url.titan` is one flat logical standard module. It imports the public
short `peg` and `string` modules. Its only foreign import is the audited
`titan/ffi.h` byte-pointer vocabulary used to inspect immutable Titan strings;
there is no URL-specific C source, callback, queue, or native parser.

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

The module initializer calls the private grammar constructor once and stores
the resulting `peg.Pattern` in `http_url_pattern`. Every `parse` call matches
that stored pattern directly; parsing does not rebuild or recompile the PEG.
The grammar captures component text and the starting byte positions required
for semantic failures. It requires an absolute authority URL and nonempty
host, labels unsupported user information and fragments, requires brackets
around IP literals, labels a `%25` zone separator without a following zone
identifier, and constrains an explicit port syntactically to digits. Titan code
then accepts only `http` and `https` and checks the numeric port range
`1..65535`.

A committed Relabel failure produces a stable label and one-based byte
position. Semantic scheme and port failures use their captured component
positions. `url_parse_error` converts either form into the public `Error`
record and its rendered `URL parse error [kind] at byte N: detail` message.
`parse` returns that value in the second tuple slot instead of raising. The
success and failure tuple positions remain mutually exclusive on every path.

## Normalization

`normalize_component` walks immutable Titan strings as unsigned bytes. It
decodes percent-encoded RFC 3986 unreserved bytes, uppercases the hexadecimal
digits of every retained escape, and optionally applies ASCII lowercase to a
scheme or registered-name host. A `string.writer(false)` accumulates each
result without introducing an asynchronous yield into the synchronous parse.

`normalize_host` distinguishes registered names, IPv4, IPv6, IPvFuture, and
RFC 6874 zones. Connection identity omits URI brackets and decodes a zone's
`%25` separator to `%`; the public authority keeps brackets and the encoded
separator for an HTTP Host field. Default ports are assigned only when absent,
while an explicit port is rendered from its parsed integer. An empty path
becomes `/`, and the normalized path plus optional normalized query forms
`Url.target`.

## HTTP consumption and provider composition

The HTTP client connects with `Url.host` and `Url.port`, generates a missing
Host field from `Url.authority`, and sends `Url.target`. The server parses
`scheme://` plus the received Host authority and origin-form target after
rejecting authority delimiters that could consume the independently parsed
target. Both boundaries raise the returned `url.Error` when an HTTP operation
cannot proceed; the standalone parser itself remains nonthrowing.

The URL root adds one logical protocol, archive metadata key, generated shim,
and `luaopen_titan_url` entry to the coordinated provider. Together with the
new SSL and HTTP modules, the current image has seventeen logical modules and
shims and eighteen DSO openers including bare `luaopen_titan`. The historical
fourteen-module ABI-0.20 image remains the publication predecessor for this
unreleased feature set.

The non-LuaCov URL suite carries the accepted and rejected URI matrix,
normalization cases, tuple exclusivity, and exact `Error` fields. HTTP tests
separately prove client propagation of the structured failure value plus
server consumption of normalized URLs and rejection of malformed Host
authorities.
