# TLS standard library

The qualified `titan.ssl` standard module provides verified TLS clients and
TLS servers over the public [TCP networking](standard-library-net.md) API.
Titan source imports it with its full name:

```titan
local ssl = import "titan.ssl"
```

Lua loads the same canonical module identity with:

```lua
local ssl = require "titan.ssl"
```

There is deliberately no short `import "ssl"` spelling. TLS is an ordinary
high-level standard-library layer, not an addition to Titan's private libuv
binding. Its operations call `net.Connection` methods and therefore must run
inside an async Task, under the same loop-driving rules as `net`.

## API

```titan
record Error
    code: integer
    name: string
    message: string
    operation: string
end

record Connection
record Server

function connect(host: string, port: integer,
                 ca_file: string?,
                 ca_directory: string?): Connection

function listen(host: string, port: integer, backlog: integer,
                certificate_file: string,
                private_key_file: string): Server

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

The optional trailing arguments may be omitted. Strings used as hostnames,
certificate paths, or trust paths are text and may not contain an embedded
NUL. Application payloads and read delimiters are binary strings.

## Verified client connections

`connect` first establishes a `net.Connection`, configures a client TLS state
machine, and completes its handshake before returning. It requires TLS 1.2 or
newer and verifies the peer certificate by default. There is no insecure
client mode.

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

The two trust arguments select OpenSSL's certificate-location mechanism:

- with neither argument, the context loads OpenSSL's compiled default verify
  paths, including the environment overrides OpenSSL recognizes;
- `ca_file` selects an explicit PEM bundle;
- `ca_directory` selects an explicit OpenSSL certificate directory; and
- both may be supplied together.

An explicit file or directory replaces the default-path call for that
connection; it is not added after the defaults. In particular, the no-argument
case is **not** a portable abstraction over every operating system's native
trust store. A bundled OpenSSL build still uses OpenSSL's compiled filesystem
defaults. Programs that need deployment-independent trust selection should
pass an explicit CA file or directory.

The underlying `net.connect` contract supplies DNS resolution, address-order
fallback, port validation, cancellation, and TCP errors.

## Server connections and handshakes

`listen` loads one PEM certificate chain and matching PEM private key, then
creates a `net.Server`. The listener requires TLS 1.2 or newer. This version
does not request or verify client certificates, so mutual TLS is unsupported.

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
`TLS_TRUNCATED_EOF` error. The distinction prevents an unauthenticated TCP
close from silently truncating a protected byte stream.

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
when one exists. Argument/state errors may remain strings, and errors from the
wrapped TCP connection retain the [`async.Error`](async-io.md) value supplied
by `net`.

## Example

```titan
local async = import "async"
local ssl = import "titan.ssl"

function fetch_head(): value
  local connection = ssl.connect("example.com", 443, nil, nil)
  defer connection:close()
  connection:write(
    "HEAD / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
  return connection:read_until("\r\n\r\n", false)
end

function main(args: {string}): integer
  async.run(fetch_head)
  return 0
end
```

## Availability and limits

Linux and macOS are supported. The default build downloads, verifies, and
statically carries the pinned OpenSSL 3.5.7 release in the coordinated
standard-library provider. A system OpenSSL 3.0 or newer may be selected with
`OPENSSL_MODE=system`; see the repository build instructions for the required
development package and `pkg-config` setup.

This initial module has no mTLS, ALPN selection API, certificate callbacks,
session-cache controls, cipher configuration, key logging, or access to the
underlying `net.Connection`. It intentionally leaves the private `titan.uv`
module unchanged.
