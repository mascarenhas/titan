# SSL and HTTP(S) implementation plan

This plan refines `ssl-and-http.md`. The original draft remains the product
brief; this file records the repository-specific implementation and acceptance
decisions.

## Architectural boundary

- `titan.uv` is fixed language-level infrastructure for this feature. Do not
  edit `titan/uv/`, `titan-runtime/titan_uv.*`, or add SSL/HTTP operations to
  the private `uv` module.
- `titan.ssl` is an ordinary high-level standard-library module that wraps only
  public `titan.net` `Connection` and `Server` values. It drives OpenSSL memory
  BIOs through `net.Connection:read`, `write`, `shutdown`, and `close`.
- `titan.http` is an ordinary high-level standard-library module above
  `titan.net`, `titan.ssl`, `titan.io`, and `titan.async`.
- `titan.url` is an ordinary synchronous standard-library module above
  `titan.peg` and `titan.string`. It owns the reusable URL grammar and
  normalization; HTTP imports it instead of exporting an HTTP-private parser.
- `ssl`, `url`, and `http` are standard-library short imports, like `net` and
  `fs`: applications write `import "ssl"`, `import "url"`, and
  `import "http"`, while the compiler resolves those spellings to the logical
  module identities `titan.ssl`, `titan.url`, and `titan.http`. Their
  implementations use the same short spellings for standard-module
  dependencies.
- OpenSSL is used directly through Titan's C FFI. There is no SSL convenience
  shim: Titan spells function-like OpenSSL macros through their exported
  control functions and keeps all TLS policy and state-machine work in
  `titan.ssl`.
- `titan.ssl` imports `openssl/ssl.h`, `openssl/err.h`,
  `openssl/x509v3.h`, and `openssl/pem.h` directly. There is no `titan/ssl/`
  header folder. The FFI checker recognizes a re-extracted
  physical declaration and validates the final ordered include context. A
  same-kind file-scope tag reuses one module-wide canonical owner regardless
  of which header exposed it; genuinely distinct tag objects, including
  prototype-local tags, remain nominally distinct. It batches
  independent declaration-pair compatibility checks into dependency-safe
  compiler waves on the successful path, isolates every pair's C tag scope,
  preserves sequential composite-type dependencies between waves, and bisects
  only a rejected batch to retain exact diagnostics. This fixes the former
  thousands-of-process performance bug without an aggregation header or a
  weaker FFI type relation. The successful direct-OpenSSL-header extraction
  must remain within roughly three times the single umbrella-header baseline;
  the final un-cached benchmark is 9.30 seconds with one baseline plus three
  dependency-safe waves of 714, 657, and 1,798 declaration pairs, versus the
  approximately 3.98-second umbrella baseline (about 2.34 times).
- The one native adapter is private to `titan.http` and contains only llhttp
  callback ABI trampolines. Each trampoline recovers the Lua state, callback
  closure/module, and exact Titan native entry point, invokes it synchronously,
  and restores its temporary root. Titan owns the GC-traced `{Event}` Array,
  copies borrowed callback spans into Titan strings, and performs all event
  policy.
  A non-callback C trampoline is allowed only for a boundary Titan cannot
  express (notably a required function-like macro), and every such exception
  must have an immediately preceding C comment naming and justifying the gap.
- A common server interface is intentionally not introduced: Titan does not
  lift concrete-to-interface conversion through an `accept` result. HTTP
  branches over concrete `net.Server` and `ssl.Server` owners, then converts
  each accepted connection to `io.ReaderWriterCloser`.

## Public behavior

### TLS

- Client connections verify peers by default, validate DNS/IP identity during
  the handshake, and send SNI for DNS names.
- Client configuration accepts an optional PEM CA file, read through the
  high-level asynchronous `fs` module and parsed from an OpenSSL memory BIO.
  There is no per-connect CA-directory parameter. A module-initialized shared
  client context calls `SSL_CTX_set_default_verify_paths` once and supplies
  OpenSSL's compiled default paths and documented environment overrides to
  ordinary connections; this is not described as a portable OS trust-store
  abstraction. The one-time default-path setup may synchronously discover its
  configuration, but no OpenSSL file API runs on every ordinary connect. A
  module-rooted private Titan record owns the shared `SSL_CTX`; its record
  userdata retains the existing unique nominal metatable when
  `gc.finalizable` installs the callback. That callback clears its pointer
  field before freeing the context at Lua-state shutdown. The separately
  cached pointer is borrowed only.
- Server listeners read the certificate and private-key contents through the
  high-level asynchronous `fs` module and parse them from memory BIOs. The key
  path is optional and defaults to the certificate path, so a combined PEM
  bundle is the concise case while split files remain supported. Servers do
  not support mTLS in this iteration.
- Titan's extracted `pem.h` namespace does not expose the stack-returning
  `PEM_X509_INFO_read_bio` family. This is handled without a shim: Titan calls
  exported `PEM_read_bio`, classifies PEM blocks, decodes certificate/key DER
  through exported OpenSSL entry points, and releases each OpenSSL allocation
  through the primitive underlying `OPENSSL_free`. Encrypted private keys are
  outside this API iteration.
- Listener backlog is optional throughout `net`, `ssl`, and `http`, with a
  default of 128. HTTP listener ports are optional and default to 80 for HTTP
  and 443 for HTTPS.
- Accepted connections handshake lazily on explicit `handshake()` or the first
  read/write. Performing it inside the accept loop would let a slow ClientHello
  stall every later accept.
- Reads and writes handle both `SSL_ERROR_WANT_READ` and
  `SSL_ERROR_WANT_WRITE`; a retried `SSL_write` retains the exact payload.
- Clean `close_notify`, truncated transport EOF, verification failures, and
  other TLS failures remain distinct terminal outcomes. Close is idempotent.
- A connection supports one active operation at a time. Concurrent read/write
  attempts on the same TLS state machine are unsupported.

### HTTP/1.1

- URL parsing belongs to the standalone `titan.url` module. Its
  module-initialized `titan.peg` relabel-source grammar translates the RFC 3986
  URI grammar from `daurnimator/lpeg_patterns` at pinned commit
  `0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`. `url.parse` accepts the absolute
  `http`/`https` authority URLs supported by this iteration and returns
  `(Url?, Error?)`: a normalized public `Url` plus nil, or nil plus an `Error`
  record containing the one-based byte `position`, stable error `kind`, and
  rendered `message`. It never raises for malformed input. A second
  `url.parse_request` entry accepts scheme, authority, and origin-form target
  separately and fences all three components so none can consume another.
  HTTP converts either
  recoverable error to a raised boundary error where a request cannot proceed.
  The upstream URI cases live in the non-LuaCov URL suite.
- The client supports `http` and verified `https`, streams a parsed response as
  an `io.ReaderCloser`, sends `Connection: close`, and neither follows redirects
  nor decompresses content encodings.
- Header storage preserves insertion order, original spelling, and duplicate
  values; lookup is ASCII case-insensitive. High-level `string` matching owns
  outbound token/value/decimal validation; strict llhttp independently
  validates the inbound header and framing grammar. llhttp leaves received
  reason phrases opaque, so Titan applies the field-value byte repertoire
  before exposing them.
- Server requests expose a streaming body Reader with chunk framing removed.
  Responses expose status/header mutation before commit plus `write` and
  idempotent `close`; absent Content-Length uses chunked framing when a body is
  permitted.
- Strict llhttp parsing remains enabled. Upgrade/WebSocket requests, conflicting
  framing, malformed/truncated messages, and response-order violations close
  the connection.
- The server drains any unread request body before parsing the next keep-alive
  request. Handler return closes an unclosed response so framing is always
  completed.
- `ClientResponse` and `Server` become logically closed before their wrapped
  transport/listener close can suspend. If sticky Task cancellation prevents
  that call from recording completion, the next `close()` idempotently retries
  only the transport/listener cleanup.
- HTTP/1.1 keep-alive and ordered request pipelining are supported. A peer may
  send later requests before reading the current response, but each connection
  dispatches handlers strictly one at a time: the current handler returns, its
  response finishes, and any unread request body is drained before the next
  handler runs. The parser preserves bytes already read beyond the current
  message for that next iteration. Responses remain in request order and never
  interleave; there is no concurrent per-connection handler scheduler. EOF
  before the reset request parser receives any bytes is a normal disconnect,
  while EOF after empty lines, a dangling CR, or any other partial next request
  remains a parse error.
- This iteration does not manufacture an internal idle timeout. The public
  async API has task creation/cancellation and timers but no
  current-task/join/race/deadline primitive; a timeout implemented solely here
  would require a connection-local watchdog and generation-fencing protocol.
  This is a high-level composition blocker to call out, not grounds for
  changing `uv` in this feature.

## Build and publication

- Pin and checksum OpenSSL 3.5.7 LTS. Support `OPENSSL_MODE=bundled|system`;
  bundled mode statically carries `libssl.a` then `libcrypto.a`, while system
  mode uses `pkg-config openssl >= 3.0.0` and leaves those libraries as final
  consumer inputs.
- Pin and checksum llhttp 9.4.3 and always build its three generated C sources
  into a private deterministic archive.
- Carry the private HTTP adapter separately. Neither dependency archive nor the
  HTTP callback header is installed in Titan's runtime SDK, and
  `lib/titan/<library-version>/libtitan.a` retains its exact existing members.
- Add `ssl`, `url`, and `http` to the coordinated standard provider, producing
  seventeen logical modules/shims/archive keys and eighteen `luaopen_*`
  entries.
- Preserve recoverable publication and explicitly test rollback from a valid
  fourteen-module predecessor.
- Attribute and ship the OpenSSL, llhttp, and derivative lpeg_patterns
  licenses/notices.

## Tests and documentation

- Add non-LuaCov URL and loopback TLS/HTTP suites with checked-in local CA fixtures:
  verification and hostname failure, binary/fragmented I/O, WANT_READ,
  clean/truncated close, strict/fragmented HTTP parsing, fixed/chunked/EOF
  bodies, token/value byte boundaries, decimal overflow, informational/final
  opaque reason rejection, case-distinct method framing, structured Host
  diagnostics, rejected non-origin targets, clean byte-idle, buffered empty
  lines, and dangling/other partial keep-alive EOF,
  streaming handlers, ordered pipelined requests, keep-alive, HTTPS, and the
  lpeg_patterns URI normalization/error matrix. Review the
  same-payload WANT_WRITE retry path directly: dynamic memory BIOs have no
  capacity control and TLS 1.3 has no renegotiation API with which a portable
  public loopback test can force that OpenSSL result.
- Add focused build/package tests for pins, checksums, exact archive members,
  native-symbol privacy, bundled/system OpenSSL, source-rock inventory,
  provider counts, migration, rollback, static consumers, direct OpenSSL
  imports, and batched FFI compatibility probes.
- Update Linux CI caches, dependency preparation, module snapshots, production
  smokes, and one sanitizer TLS/HTTP boundary. Do not dispatch macOS CI for this
  PR.
- Add language and implementation chapters for all three public modules:
  URL grammar/error ownership, TLS memory-BIO ownership/retries, and HTTP
  llhttp event ownership/pause/resume. Link both manual indexes and update
  every exact standard-provider count while preserving the historical
  fourteen-module predecessor description.
- Before publication, run focused tests, `make test`, adversarial code/docs/API
  reviews, exact-head Linux CI, and then commit both this plan and the original
  draft with the implementation.
