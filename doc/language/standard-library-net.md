# TCP networking

The `net` module provides asynchronous DNS resolution and direct-style TCP client and server streams over libuv. Import it in Titan with `local net = import "net"` or load it in Lua with `require "titan.net"`.

**Target availability:** Native only (unavailable on the browser target).

## Example

This module implements a concurrent line-oriented TCP echo server and matching client:

```titan
local async = import "async"
local net = import "net"

local function handle_client(conn: net.Connection)
  defer conn:close()
  while true do
    local line? = conn:read_until("\n")
    if line == nil then break end
    conn:write(line)
  end
end

function run_echo_server(host: string, port: integer)
  local server = net.listen(host, port)
  defer server:close()
  while true do
    local client = server:accept()
    async.run(function (): nil
      handle_client(client)
      return nil
    end)
  end
end

function send_echo(host: string, port: integer, message: string): string?
  local conn = net.connect(host, port)
  defer conn:close()
  conn:write(message .. "\n")
  conn:shutdown()
  return conn:read_until("\n", true)
end
```

## Core concepts

All network calls must execute inside an [`async.Task`](async-io.md#scheduling-and-driving-tasks) (or a standalone program whose imports install the automatic async bootstrap). Operations suspend only the current Task while other Tasks on the event loop keep running.

`Connection` and `Server` are opaque nominal records: `Connection` satisfies all seven [`io` Interfaces](standard-library-io.md) (`Reader`, `Writer`, `Closer`, `ReaderWriter`, `ReaderCloser`, `WriterCloser`, `ReaderWriterCloser`), and `Server` satisfies `io.Closer`. Pair acquisition immediately with `defer conn:close()` or `defer server:close()`.

Hosts are text strings that may not contain embedded NUL bytes; socket payloads and delimiters are arbitrary binary strings. A connected socket supplied by an inetd-style launcher on descriptors 0–2 is accessed through `os.stdin`/`os.stdout`/`os.stderr` rather than `net.Connection` (see [TCP-backed parent streams](standard-library-os.md#tcp-backed-parent-streams)).

## Connecting and listening

```text
record Connection
record Server

function resolve(host: string, port: integer): {uv.sockaddr_t}
function Connection.new(): Connection
function Connection:connect_address(address: uv.sockaddr_t)
function connect(host: string, port: integer): Connection
function listen(host: string, port: integer,
                backlog: integer?, reuse_port: boolean?): Server
```

- **`resolve(host, port)`** resolves `host` (nonempty, no NUL) and `port` (`1..65535`) asynchronously and returns copied, owned IPv4/IPv6 TCP `uv.sockaddr_t` values in resolver order. Cancelling a pending resolve requests native cancellation and still waits for its callback to complete.
- **`Connection()` / `Connection:connect_address(address)`** splits socket creation from dialing so a supervisor holds an abortable `Connection` before dialing. Create `local conn = net.Connection()`, immediately `defer conn:close()`, and call `conn:connect_address(addr)` with a complete IPv4/IPv6 address and nonzero port (performing no second DNS query). Before dialing begins, `connect_address`, `set_no_delay`, `close`, and `has_pending_input` are valid (while dialing is in progress, `set_no_delay` is rejected); a failed dial leaves the endpoint unusable until closed.
- **`connect(host, port)`** resolves `host` (`port` in `1..65535`) and dials IPv4/IPv6 candidates in resolver order, closing failed candidates asynchronously before trying the next.
- **`listen(host, port, backlog?, reuse_port?)`** binds and starts a TCP listener (`Server` has no public constructor). `port` may be `0` for an ephemeral OS port; call `Server:local_address()` to inspect the OS-assigned endpoint. `backlog` defaults to `128` (range `1..2147483647`). `reuse_port` defaults to `false`; when `true`, it sets `UV_TCP_REUSEPORT` so independent listeners (such as across separate processes or Lua states) can share a local address and port. Linux supports `reuse_port`; macOS and Windows raise `async.OperationError` with `name == "ENOTSUP"`.

## Socket addresses

```text
record Address
  const ip: string
  const port: integer
  const ipv6: boolean
  const scope_id: integer
end
function Address.new(ip: string, port: integer,
                     ipv6: boolean, scope_id: integer): Address

function Server:local_address(): Address
function Connection:local_address(): Address
function Connection:peer_address(): Address
```

- **`Address`** is an immutable numeric IPv4 or IPv6 socket endpoint snapshot: `ip` is the numeric IPv4 or IPv6 presentation text without brackets or scope suffix, `port` is the TCP port in host byte order (`0..65535`), `ipv6` is `true` for IPv6 and `false` for IPv4, and `scope_id` is the numeric IPv6 scope identifier (`0` for IPv4 and unscoped IPv6). Because `Address` has only scalar `const` fields and its default public constructor, `reflect`, `json`, `protobuf`, and `transfer.TransferValue` support it directly.
- **`Server:local_address()`** returns the bound local endpoint snapshot of an open listener, including the OS-assigned port when `listen` was called with `port` `0`.
- **`Connection:local_address()`** and **`Connection:peer_address()`** return the local and remote endpoint snapshots of an open, connected `Connection`.
- **Live-endpoint rules and snapshots:** All three queries require an active Task on the owning `async` Runtime and reject closed or transferred-from source endpoints; `Connection:local_address()` and `Connection:peer_address()` also reject unconnected, connecting, or failed `Connection`s. An `Address` returned while the endpoint is open is an immutable snapshot that remains readable after the `Server` or `Connection` is closed. If the remote peer resets or disconnects before the first `peer_address()` call and the OS rejects the lookup, `peer_address()` raises `async.OperationError` with `operation == "net.peer_address"`. After connection transfer, `local_address()` and `peer_address()` query the adopted live socket on demand on the destination Runtime.

## Reading

```text
function Connection:read(): string?
function Connection:read_until(delimiter: string, chop: boolean?): string?
function Connection:read_ahead(enabled: boolean?): boolean
function Connection:has_pending_input(): boolean
function Connection:add_input_listener(listener: function (): ()): function (): ()
```

A `Connection` starts its libuv read watcher lazily on the first `read` or `read_until`.

- **`read_ahead(enabled?)`** returns the previous setting (default `true`; omit the argument to query). It may be changed only before the first native read starts. With `true`, the watcher keeps reading and queuing immutable chunks even when no Task is reading (with no application-level queue cap). With `false`, each positive or terminal callback stops the watcher before delivering its chunk and rearms it only when buffered input runs out, without changing kernel buffering or message boundaries.
- **`read()`** returns retained delimiter excess first, then the oldest queued chunk, or suspends until the next nonempty binary chunk arrives. Each returned string is an immutable copy. At EOF or after explicit `close()`, `read()` returns sticky `nil`. A read error (such as connection reset) stops the watcher and is raised on subsequent reads after earlier buffered chunks drain, until `close()`.
- **`read_until(delimiter, chop?)`** requires a nonempty delimiter, matches across chunk boundaries, and saves trailing bytes for later reads. When `chop` is `true`, the delimiter is omitted (`""` is a valid empty match distinct from EOF `nil`). A nonempty unterminated final tail before EOF is returned once, followed by sticky `nil`. Errors and cancellation propagate without rolling consumed bytes back into the stream.
- **Single reader:** At most one Task may wait in `read` or `read_until` at a time; a second concurrent reader raises. Cancelling a waiting reader detaches only that waiter and leaves the `Connection` usable by another Task.
- **`has_pending_input()`** synchronously reports whether retained delimiter bytes, queued chunks, EOF/error/close, or an unconnected state are already observed (without starting reads, polling the socket, reserving a reader, or checking cancellation).
- **`add_input_listener(listener)`** registers a non-consuming observer from a Task on a connected endpoint and returns an idempotent remover. It does not start the lazy read watcher or replay already buffered data. Listeners run outside Task execution in registration order when new input, EOF, or error is buffered and must not yield or block. Removing a later listener during notification skips it; explicit `close()` clears listeners without firing them.

## Writing, shutdown, and close

```text
function Connection:write(data: string)
function Connection:set_no_delay(enabled: boolean)
function Connection:shutdown()
function Connection:close()
```

- **`write(data)`** submits an ordered native write for `data` and suspends until its callback completes, retaining the immutable string for the full duration of the write (even if the calling Task is cancelled). Overlapping writes keep independent requests and payloads; an empty write validates that the write side is open.
- **`TCP_NODELAY` default and `set_no_delay(enabled)`:** Dialed (`Connection()`, `connect`) and accepted (`Server:accept`) `Connection`s enable `TCP_NODELAY` (`true`) by default, disabling Nagle buffering in the local TCP stack so multi-write protocols do not stall on delayed ACKs. Call `set_no_delay(false)` to enable Nagle coalescing or `set_no_delay(true)` to disable it again. `set_no_delay` requires an active Task on the owning `async` Runtime, is valid before dialing begins (`Connection()` prior to `connect_address`) and on a connected `Connection` (before or after reads, writes, or `shutdown()`), and raises on closed, transferred-from, failed, or currently connecting endpoints (surfacing OS errors as `async.OperationError` with `operation == "net.set_no_delay"`).
- **`shutdown()`** half-closes the write direction after earlier writes complete, leaving the read side open until peer EOF, error, or `close()`. Repeated calls are idempotent.
- **`close()`** idempotently closes both directions, stops reading, discards buffered input, wakes any waiting reader with `nil`, and rejects subsequent output. Runtime shutdown closes any `Connection` or `Server` left open.

## Accepting

```text
function Server:accept(): Connection
function Server:close()
```

`Server:accept()` returns the oldest buffered accepted `Connection` or suspends until the next client connects. Every `Connection` returned by `accept()` has `TCP_NODELAY` enabled; if configuring `TCP_NODELAY` on a newly accepted child socket fails at the OS level, that child socket is closed and discarded without failing the `Server` listener. At most one Task may wait in `accept()` at a time; cancelling that waiter leaves the `Server` listening. Incoming connections arriving with no waiting Task remain buffered up to the listen backlog. `Server:close()` closes the listener and any buffered unaccepted clients, waking a waiting `accept()` with an error.

## Errors

Libuv failures raise [`async.OperationError`](async-io.md#errors-and-cancellation) (`code`, `name`, `message`, `operation`), using `EAI_*` names for DNS failures. Clean EOF returns `nil` from `read` and `read_until`.

## Transferring connections

```text
function Connection:to_transfer_payload(): string
function Connection.from_transfer_payload(payload: string): Connection
function Connection.discard_transfer_payload(payload: string): integer
```

An idle connected `Connection` can move between independent Lua states in the same process via `async.TransferValue.from_value(conn)` and `packet:to_value()` (or the hooks directly). Both hooks are synchronous, require an active non-closing Runtime (no running Task), and preserve unread delimiter excess, buffered input, the `read_ahead` setting, and the underlying socket's `TCP_NODELAY` option (`true` by default, or `false` if disabled before transfer). On the destination Runtime, `local_address()`, `peer_address()`, and `set_no_delay(enabled)` operate on the adopted live socket.

- **Eligibility:** Transfer rejects unconnected, closed, or half-closed sockets, active readers/writers/shutdowns, registered input listeners, and pending native requests (leaving the source usable). On Windows, a persistent read watcher normally keeps an overlapped read pending even when idle, raising `EBUSY`: call `conn:read_ahead(false)` before the first read, and call `async.yield()` after `connect` or the last I/O operation so native callbacks retire before encoding.
- **Ownership and recovery:** Encoding detaches the source before delivery (making source aliases behave as closed). If serializing an enclosing composite fails after detachment, the hook closes the detached endpoint. Follow the [shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules): adopt the payload exactly once or recover it locally. `Connection.discard_transfer_payload(payload)` closes an unadopted payload without needing a Runtime and returns the native close status, consuming ownership even on error.

For UDP, Unix-domain/named pipes, or other low-level socket options, use the low-level [`uv`](standard-library-uv.md) module directly. For TLS over `net`, see [`ssl`](standard-library-ssl.md).
