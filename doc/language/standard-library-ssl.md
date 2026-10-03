# TLS standard library

The `ssl` standard module provides verified TLS clients and TLS servers over
the public [TCP networking](standard-library-net.md) API. Titan source uses
its short import:

```titan
local ssl = import "ssl"
```

The parser resolves that spelling to the canonical `titan.ssl` module
identity. Lua loads that identity directly with:

```lua
local ssl = require "titan.ssl"
```

TLS is an ordinary high-level standard-library layer, not an addition to
Titan's private libuv binding. Its operations call `net.Connection` methods
and therefore must run inside an async Task, under the same loop-driving rules
as `net`.

## API

```text
record Error
    code: integer
    name: string
    message: string
    operation: string
end

record Connection
record Server

function connect(host: string, port: integer,
                 ca_file: string?): Connection

function listen(host: string, port: integer,
                certificate_file: string,
                private_key_file: string?,
                backlog: integer?): Server

function Connection:handshake()
function Connection:read(): string?
function Connection:read_until(delimiter: string,
                               chop: boolean?): string?
function Connection:write(data: string)
function Connection:shutdown()
function Connection:close()

function Server:accept(): Connection
function Server:close()
```

`Connection` and `Server` are opaque nominal records. A `Connection` has the
exact method shapes required by all seven [`io` Interfaces](standard-library-io.md).
`Server` satisfies `io.Closer` through its exact `close()` method. These are
ordinary structural conversions at a statically known conversion site; the
records do not share a base class with their `net` counterparts.

The optional trailing arguments may be omitted. In `listen`, an omitted
`private_key_file` uses `certificate_file` as a combined PEM certificate/key
bundle, while an omitted `backlog` defaults to 128. A listener port must be in
`0..65535`, where 0 requests an ephemeral port, and a supplied backlog must be
in `1..2147483647`. Strings used as hostnames, certificate paths, or trust
paths are text and may not contain an embedded NUL. Application payloads and
read delimiters are binary strings.

## Verified client connections

`connect` selects trust, establishes a `net.Connection`, configures a client
TLS state machine, and completes its handshake before returning. It requires
TLS 1.2 or newer and verifies the peer certificate by default. There is no
insecure client mode.

The requested `host` is also the certificate identity. A DNS name is checked
against the certificate's DNS identity with partial wildcards disabled and is
sent as Server Name Indication (SNI). A textual IPv4 or IPv6 address is checked
as an IP address and is not sent as SNI. Successful cryptographic negotiation
does not override a failed chain or identity check: verification failure aborts
the connection.

For a scoped IPv6 address such as `fe80::1%eth0`, the complete spelling remains
the TCP destination so the zone selects the local interface. The `%zone` suffix
is not part of an X.509 IP identity, so it is removed only for certificate
matching. The connection still follows the IP-address branch and sends no SNI.

The optional trust argument selects one of two modes:

- without `ca_file`, connections share the module's default client context,
  initialized once from OpenSSL's compiled default verify paths and the
  environment overrides OpenSSL recognizes; its native context is held by a
  private owner record and released during Lua-state shutdown by a finalizer
  whose parameter is that exact owner type, not a dynamically cast `value`; or
- `ca_file` selects an explicit PEM certificate bundle for that connection.

An explicit file replaces the default roots; it is not added after them. Titan
reads that path through the high-level asynchronous `fs` module, then parses
and installs every certificate from the in-memory PEM data before opening the
TCP connection. An empty file, a file with no certificate, or malformed PEM is
rejected. This API has no explicit CA-directory argument.

The no-file case is **not** a portable abstraction over every operating
system's native trust store. A bundled OpenSSL build still uses OpenSSL's
compiled filesystem defaults. Default hashed certificate directories are
looked up lazily by OpenSSL. Module initialization may synchronously load the
default CA file once, and the first verification that needs a hashed-directory
entry may perform another synchronous filesystem read. Reusing the one default
context caches and amortizes those default-path costs across later connections.
Programs that need deployment-independent trust selection should pass an
explicit CA file.

To override default trust with `SSL_CERT_FILE` (a PEM bundle) or `SSL_CERT_DIR`
(an OpenSSL subject-hash certificate directory), set the environment before
starting the program. Default-context initialization happens when `titan.ssl`
first loads; later environment changes do not reinitialize it. Start a fresh
process when testing another default trust configuration. Successful module or
TLS-context initialization alone does not prove any usable CA roots were loaded:
OpenSSL can accept missing default locations and report the trust failure during
peer verification instead.

The experimental Windows SDK ships no CA bundle or other usable default roots
and does not automatically use the Windows ROOT store. Its compiled filesystem
CA paths retain the original build prefix after SDK relocation. Use the existing
`ca_file` argument or explicitly configured environment overrides as described
above; certificate-chain and hostname/IP verification remain enabled.

The underlying `net.connect` contract supplies DNS resolution, address-order
fallback, port validation, cancellation, and TCP errors.

## Server connections and handshakes

`listen` reads one PEM certificate chain and matching PEM private key through
the high-level asynchronous `fs` module, parses them from memory, then creates
a `net.Server`. The first certificate is the server leaf and later
certificates form its transmitted chain. The private key may occupy the same
PEM file or a separate file, but must be unencrypted because this API has no
password input. The listener requires TLS 1.2 or newer. This version does not
request or verify client certificates, so mutual TLS is unsupported.

`Server:accept()` returns after accepting TCP; it does **not** wait for a
ClientHello. The accepted connection's server handshake is lazy and runs on
an explicit `handshake()` or its first `read`, `read_until`, or `write`.
Keeping the handshake out of the accept loop prevents one slow TLS peer from
serializing acceptance of later TCP connections.

`Connection:handshake()` is safe to call on an already negotiated connection.
Applications may use it when they want handshake failure to occur at an
explicit point before their first application read or write.

`Server:close()` stops the wrapped TCP listener and releases the Server's
context reference. It is idempotent. Connections already returned by
`accept()` retain their own TLS state and remain usable; a close does not reach
back into them.

## Reading and writing

`read()` returns the next nonempty plaintext chunk, or `nil` after an
authenticated TLS end-of-stream. TLS record and underlying TCP chunk
boundaries are not preserved as application message boundaries.

`read_until(delimiter, chop)` has the same byte-stream contract as the `net`
method: the delimiter must be nonempty, may span encrypted or plaintext chunk
boundaries, and bytes after the first match are retained for the next read.
The result includes the delimiter unless `chop` is true. A nonempty final tail
is returned once before EOF.

`write(data)` accepts an arbitrary binary string and returns after all of its
plaintext has been accepted by the TLS state machine and the resulting
encrypted output has been written through `net.Connection`. Large inputs may
be split into TLS-sized pieces internally, but one call remains one ordered
high-level operation. OpenSSL retry conditions never change the bytes or
length of the piece being retried.

A `Connection` permits only one active TLS operation at a time. Concurrent
reads, concurrent writes, or a read and write from separate Tasks on the same
connection are rejected. This is stricter than plain `net.Connection`: one
OpenSSL state machine and its two memory BIOs are advanced serially.

## TLS shutdown and EOF

`shutdown()` sends TLS `close_notify`, drains its encrypted bytes through the
network connection, and shuts down the TCP write side. It is idempotent. The
read side remains available so the peer's authenticated shutdown can still be
observed; output after shutdown is rejected.

A received `close_notify` is normal EOF, so `read` and `read_until` eventually
return `nil`. A bare transport EOF without `close_notify` is instead a
`TLS_TRUNCATED_EOF` error. A TCP reset observed while TLS is waiting for more
protected input is normalized to the same error: FIN and RST are different
transport presentations of the same unauthenticated TLS truncation. The
distinction from clean TLS EOF prevents either form from silently truncating a
protected byte stream.

`close()` best-effort sends shutdown when the negotiated state permits it,
frees the TLS engine, and closes the wrapped `net.Connection`. It is
idempotent after reaching the closed state. If the alert bytes were written
but the peer closes before the redundant TCP half-close, `close` treats the
resulting `ENOTCONN` as completed cleanup; an explicit `shutdown()` still
reports that error. A TLS, transport, or cancellation failure terminalizes
the TLS connection and best-effort closes its transport; later I/O cannot
resume the failed state machine.

## Errors

TLS and certificate failures raise `ssl.Error`, whose `operation` names the
failed layer and whose `name` distinguishes such outcomes as
`CERTIFICATE_VERIFY_FAILED`, `TLS_TRUNCATED_EOF`, and OpenSSL's `SSL_ERROR_*`
conditions. `code` is the corresponding OpenSSL error or verification code
when one exists. Argument/state errors may remain strings. Errors while reading
explicit CA, certificate, or key paths and errors from the wrapped TCP
connection retain the [`async.OperationError`](async-io.md) value supplied by
`fs` or `net`, except that `ECONNRESET` from a TLS input read is normalized to
`TLS_TRUNCATED_EOF` as described above.

## Example

```titan
local async = import "async"
local ssl = import "ssl"

function fetch_head(): value
  local connection = ssl.connect("example.com", 443, nil)
  defer connection:close()
  connection:write(
    "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
  return connection:read_until("\r\n\r\n", false)
end

function main(args: {string}): integer
  async.run<|value, value|>(fetch_head)
  return 0
end
```

## Availability and limits

Linux and macOS are supported. The default build uses system OpenSSL 3.0 or
newer; see the repository build instructions for its development package and
`pkg-config` setup. `OPENSSL_MODE=bundled` instead downloads, verifies, and
statically carries the pinned OpenSSL 3.5.7 release in the coordinated
standard-library provider.

This initial module has no mTLS, ALPN selection API, certificate callbacks,
session-cache controls, cipher configuration, key logging, or access to the
underlying `net.Connection`. It intentionally leaves the private `titan.uv`
module unchanged.
