# TLS standard library

The `ssl` module provides verified TLS 1.2+ client and server streams layered over [`net`](standard-library-net.md) using OpenSSL. Import it in Titan with `local ssl = import "ssl"` or load it in Lua with `require "titan.ssl"`.

**Target availability:** Native only (unavailable on the browser target).

## Example

This module opens a verified HTTPS connection, sends a `HEAD` request, and reads the response header block:

```titan
local ssl = import "ssl"

function fetch_head(host: string, port: integer, ca_file: string?): string?
  local conn = ssl.connect(host, port, ca_file)
  defer conn:close()
  conn:write(
    "HEAD / HTTP/1.1\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
  return conn:read_until("\r\n\r\n", false)
end
```

## Core concepts

All TLS operations call `net.Connection` methods and must execute inside an [`async.Task`](async-io.md#scheduling-and-driving-tasks). `Connection` and `Server` are opaque nominal records: `Connection` satisfies all seven [`io` Interfaces](standard-library-io.md) and `Server` satisfies `io.Closer`.

TLS 1.2 or newer and strict peer certificate-chain and hostname/IP verification are always enabled for clients; there is no insecure client mode. Hostnames and filesystem paths are NUL-free text strings, while payloads and delimiters are arbitrary binary strings.

## Verified client connections

```text
record Connection

function client(transport: net.Connection, host: string,
                ca_file: string?): Connection
function connect(host: string, port: integer,
                 ca_file: string?): Connection
```

- **`client(transport, host, ca_file?)`** adopts an already connected `net.Connection` and configures verified TLS without running the handshake yet (call `handshake()` explicitly or let the first read/write run it). `host` sets SNI and certificate identity even if TCP dialed a numeric IP. Empty hosts or invalid text arguments fail before ownership transfers; once accepted, `ssl` owns closing `transport` on any subsequent failure (use `Connection:abort()` afterward).
- **`connect(host, port, ca_file?)`** loads trust, dials via `net.connect(host, port)` (inheriting DNS, address fallback, and port `1..65535` rules), and completes the verified TLS handshake before returning.
- **Identity verification:** DNS names are sent as SNI and matched against the certificate's DNS identity with partial wildcards disabled. IPv4 and IPv6 literals are matched as IP identities without SNI (for scoped IPv6 addresses like `fe80::1%eth0`, the full spelling dials TCP while `%zone` is stripped for X.509 IP matching). Verification failures abort the connection.
- **Trust roots:**
  - Passing **`ca_file`** reads that PEM bundle asynchronously via `fs` and **replaces** the default trust roots for that connection (empty or invalid PEM raises).
  - Omitting **`ca_file`** (`nil`) shares a module-level default OpenSSL client context initialized once when `ssl` loads from OpenSSL's compiled default paths and `SSL_CERT_FILE` / `SSL_CERT_DIR` (set those variables before process startup). OpenSSL's default paths are filesystem-based rather than OS-native trust stores; on Windows the SDK ships no default CA bundle and does not query the Windows ROOT store, so pass `ca_file` or configure `SSL_CERT_FILE` / `SSL_CERT_DIR` explicitly for portable trust.

## Server connections and handshakes

```text
record Server

function listen(host: string, port: integer,
                certificate_file: string,
                private_key_file: string?,
                backlog: integer?, reuse_port: boolean?): Server

function Connection:handshake()
function Server:accept(): Connection
function Server:close()
```

- **`listen(host, port, certificate_file, private_key_file?, backlog?, reuse_port?)`** reads the PEM certificate chain (leaf first) and unencrypted PEM private key asynchronously via `fs`, then opens a `net.Server`. Omitting `private_key_file` reads the private key from `certificate_file`. `port` accepts `0..65535` (`0` for ephemeral), `backlog` defaults to `128` (`1..2147483647`), and `reuse_port` forwards to [`net.listen`](standard-library-net.md#connecting-and-listening) (each TLS listener keeps its own certificate context). Listeners require TLS 1.2+ and do not perform mutual TLS client-certificate verification.
- **`Server:accept()`** accepts TCP immediately without waiting for `ClientHello`; the server TLS handshake runs lazily on `handshake()` or the first `read`, `read_until`, or `write`, preventing slow peers from blocking the accept loop.
- **`Connection:handshake()`** explicitly drives a pending handshake and is a safe no-op on an already negotiated connection.
- **`Server:close()`** idempotently stops the listener and releases its certificate context without affecting connections already returned by `accept()`.

## Reading and writing

```text
function Connection:read(): string?
function Connection:read_until(delimiter: string, chop: boolean?): string?
function Connection:write(data: string)
function Connection:read_ahead(enabled: boolean?): boolean
function Connection:has_pending_input(): boolean
function Connection:add_input_listener(listener: function (): ()): function (): ()
```

- **`read()`** returns the next nonempty plaintext chunk, or `nil` after an authenticated TLS `close_notify` EOF. Record and TCP chunk boundaries are not preserved.
- **`read_until(delimiter, chop?)`** matches a nonempty literal delimiter across record/chunk boundaries, retains trailing bytes, omits the delimiter when `chop` is `true`, and returns an unterminated final tail before authenticated EOF.
- **`write(data)`** encrypts and writes all bytes of `data` as one ordered operation (splitting large inputs into TLS records internally).
- **Concurrency and cancellation:** A `Connection` allows **one concurrent reader (`read`/`read_until`) and one concurrent writer (`write`)**. A second concurrent call in the same direction raises without disturbing the active operation. Explicit `handshake`, `shutdown`, and `close` require an idle connection and exclude I/O until they complete. When first I/O triggers a lazy handshake, one direction drives it while the other waits for the same result. Cancelling an admitted operation closes the transport and terminalizes the TLS connection (unlike `net`, a cancelled TLS read cannot be resumed on the same connection).
- **`read_ahead(enabled?)`** forwards to the underlying `net.Connection:read_ahead` (configure `false` before the first handshake or I/O for portable connection handoff).
- **`has_pending_input()`** synchronously checks retained plaintext, OpenSSL buffered/BIO bytes, underlying TCP input, or non-open TLS state without driving handshakes or consuming records (buffered bytes may be partial or control records).
- **`add_input_listener(listener)`** delegates receive observation to the underlying TCP connection (non-yielding, idempotent remover; events may be partial or control records without application plaintext).

## TLS shutdown and EOF

```text
function Connection:shutdown()
function Connection:close()
function Connection:abort()
```

- **`shutdown()`** idempotently sends TLS `close_notify`, flushes encrypted bytes, and half-closes TCP write while leaving reads open to observe the peer's `close_notify`.
- **Clean EOF vs truncation:** Receiving `close_notify` closes new write admission (letting an in-flight writer finish its pieces), sends a reciprocal alert if not yet sent, and ends `read`/`read_until` with `nil`. A bare TCP EOF or `ECONNRESET` while waiting for protected input without `close_notify` raises `ssl.Error` named `TLS_TRUNCATED_EOF` so unauthenticated truncation is never mistaken for EOF.
- **`close()`** idempotently attempts a best-effort `close_notify` when negotiated, frees the TLS engine, and closes the wrapped `net.Connection` (treating peer `ENOTCONN` after writing the alert as completed cleanup). Any TLS, transport, or cancellation error terminalizes the connection and best-effort closes its transport.
- **`abort()`** stops admission immediately without sending `close_notify`, closes TCP, frees the TLS engine once, and waits for internal I/O Tasks to retire (idempotent and safe under pending cancellation). Interrupted sibling operations raise `ssl.Error` named `TLS_INTERRUPTED`.

### Closing the Lua state

Closing the Lua state frees the OpenSSL engine of every open `Connection` and the context of every open `Server`, while the [abandoned Runtime](async-io.md#closing-a-lua-state-with-an-active-runtime) closes their TCP sockets without sending `close_notify`. During state close, `close()` and `abort()` complete synchronously so `defer conn:close()` releases resources cleanly without raising. Applications needing graceful `close_notify` must perform it [before state close](coroutines.md#cleanup-that-needs-asynchronous-io). (Note that while underlying TLS engines under HTTP and WebSocket sessions are freed by finalizers at state close, `websocket.Connection:close()` still requires a Task and emits a cleanup warning if called during an abandoned unwind.)

## Errors

```text
record Error
  code: integer
  name: string
  message: string
  operation: string
end
function Error.new(code: integer, name: string,
                   message: string, operation: string): Error
```

TLS and certificate failures raise `ssl.Error` (`CERTIFICATE_VERIFY_FAILED`, `TLS_TRUNCATED_EOF`, `TLS_INTERRUPTED`, OpenSSL `SSL_ERROR_*`, etc.), with `code` carrying the OpenSSL or verification code when applicable. Argument and state errors may raise strings. Filesystem and TCP failures preserve their `async.OperationError` identity and original traceback through cleanup (except TCP `ECONNRESET` during TLS reads, which normalizes to `TLS_TRUNCATED_EOF`).

## Transferring connections

```text
function Connection:to_transfer_payload(): string
function Connection.from_transfer_payload(payload: string): Connection
function Connection.discard_transfer_payload(payload: string): integer
```

An idle `ssl.Connection` (including a lazy client or accepted connection before its first handshake) moves between independent Lua states in the same process via `async.TransferValue.from_value(conn)` and `packet:to_value()`, preserving verified peer identity, negotiated engine state, unread plaintext, encrypted BIO buffers, and `read_ahead`.

- Transfer rejects active read, write, handshake, shutdown, retry, or cleanup operations, as well as all [TCP transfer restrictions](standard-library-net.md#transferring-connections) (configure `read_ahead(false)` before first handshake/I/O and call `async.yield()` before encoding on Windows). Rejected transfer leaves the source usable.
- Encoding detaches the source before delivery; if enclosing serialization fails after detachment, the hook frees the engine and closes the transport. Follow the [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules). `Connection.discard_transfer_payload(payload)` frees the engine and closes the transport without a Runtime, returning the native close status and consuming ownership even on error.

## Linking and scope

When linking a standalone executable with `--static` against a system-OpenSSL Titan provider, pass the system OpenSSL flags at final link (bundled OpenSSL providers include OpenSSL objects in `titan.a` automatically):

```sh
TITAN_EXTRA_CPPFLAGS="$(pkg-config --cflags openssl)" \
TITAN_EXTRA_LDFLAGS="$(pkg-config --libs openssl)" \
  titanc --static -o out app.main
```

`ssl` does not expose mutual TLS, ALPN selection, certificate callbacks, session-cache or cipher configuration, key logging, or direct access to the wrapped `net.Connection`.
