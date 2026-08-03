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
- Applications import the new module identities as `titan.ssl` and
  `titan.http`; adding those names to the parser's short standard-import list
  would be a language change and is out of scope. Their implementations keep
  the established short spellings for existing standard-module dependencies.
- OpenSSL is used directly through Titan's C FFI. There is no SSL convenience
  shim: Titan spells function-like OpenSSL macros through their exported
  control functions and keeps all TLS policy and state-machine work in
  `titan.ssl`.
- `titan.ssl` has one source-only integration header containing exactly the
  `openssl/ssl.h`, `openssl/err.h`, and `openssl/x509v3.h` includes. It has no
  declaration, definition, object, or provider payload. The FFI checker now
  correctly accepts those three headers as separate imports: it recognizes a
  re-extracted physical declaration, validates the final ordered include
  context, and does not collapse same-spelled tags from distinct declarations.
  The aggregator remains a compilation-time choice because independently
  extracting the three large overlapping OpenSSL closures and probing their
  hundreds of repeats takes minutes instead of seconds.
- The one native adapter is private to `titan.http` and contains only llhttp
  callback ABI trampolines. Each trampoline recovers the Lua state, callback
  closure/module, and exact Titan native entry point, invokes it synchronously,
  and restores its temporary root. Titan owns the `{Event}` queue, copies
  borrowed callback spans into Titan strings, and performs all event policy.
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
- Client configuration accepts optional CA file and CA directory overrides.
  Without them OpenSSL's compiled default paths and its documented environment
  overrides are used; this is not described as a portable OS trust-store
  abstraction.
- Server listeners load one PEM certificate chain and private key and do not
  support mTLS in this iteration.
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

- URL parsing is a module-initialized `titan.peg` relabel-source translation of
  RFC 3986 URI grammar from `daurnimator/lpeg_patterns` at pinned commit
  `0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7`. The HTTP boundary accepts only
  absolute `http`/`https` authority URLs, preserves the upstream percent
  normalization rules, and converts committed PEG labels into stable
  one-based byte diagnostics. The relevant upstream URI cases are ported into
  the non-LuaCov HTTP suite.
- The client supports `http` and verified `https`, streams a parsed response as
  an `io.ReaderCloser`, sends `Connection: close`, and neither follows redirects
  nor decompresses content encodings.
- Header storage preserves insertion order, original spelling, and duplicate
  values; lookup is ASCII case-insensitive.
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
- HTTP/1.1 keep-alive and pipelined suffix preservation are supported, but this
  iteration does not manufacture an internal idle timeout. The public async API
  has task creation/cancellation and timers but no current-task/join/race/deadline
  primitive; a timeout implemented solely here would require a connection-local
  watchdog and generation-fencing protocol. This is a high-level composition
  blocker to call out, not grounds for changing `uv` in this feature.

## Build and publication

- Pin and checksum OpenSSL 3.5.7 LTS. Support `OPENSSL_MODE=bundled|system`;
  bundled mode statically carries `libssl.a` then `libcrypto.a`, while system
  mode uses `pkg-config openssl >= 3.0.0` and leaves those libraries as final
  consumer inputs.
- Pin and checksum llhttp 9.4.3 and always build its three generated C sources
  into a private deterministic archive.
- Carry the private HTTP adapter separately. Neither dependency archive, the
  HTTP callback header, nor the source-only SSL integration header is installed
  in Titan's runtime SDK, and `libtitan.a` retains its exact existing members.
- Add `ssl` and `http` to the coordinated standard provider, producing sixteen
  logical modules/shims/archive keys and seventeen `luaopen_*` entries.
- Preserve recoverable publication and explicitly test upgrade/rollback from a
  valid fourteen-module ABI-0.20 predecessor.
- Attribute and ship the OpenSSL, llhttp, and derivative lpeg_patterns
  licenses/notices.

## Tests and documentation

- Add non-LuaCov loopback TLS/HTTP suites with checked-in local CA fixtures:
  verification and hostname failure, binary/fragmented I/O, WANT_READ,
  clean/truncated close, strict/fractional HTTP parsing, fixed/chunked/EOF
  bodies, streaming handlers, pipelining, keep-alive, HTTPS, and the
  HTTP-relevant lpeg_patterns URI normalization/error matrix. Review the
  same-payload WANT_WRITE retry path directly: dynamic memory BIOs have no
  capacity control and TLS 1.3 has no renegotiation API with which a portable
  public loopback test can force that OpenSSL result.
- Add focused build/package tests for pins, checksums, exact archive members,
  native-symbol privacy, bundled/system OpenSSL, source-rock inventory,
  provider counts, migration, rollback, and static consumers.
- Update Linux CI caches, dependency preparation, module snapshots, production
  smokes, and one sanitizer TLS/HTTP boundary. Do not dispatch macOS CI for this
  PR.
- Add language chapters for the two public modules and implementation chapters
  for memory-BIO ownership/retries and llhttp event ownership/pause/resume.
  Link both manual indexes and update every exact fourteen/fifteen-module claim.
- Before publication, run focused tests, `make test`, adversarial code/docs/API
  reviews, exact-head Linux CI, and then commit both this plan and the original
  draft with the implementation.
