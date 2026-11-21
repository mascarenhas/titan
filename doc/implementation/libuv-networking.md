# DNS and TCP implementation

`titan/net.native.titan` implements the [TCP API](../language/standard-library-net.md)
with ordinary imports of public `uv`, `async`, and `string`. It has no C FFI
import or source-private UV dependency. The
[UV binding](../language/standard-library-uv.md) owns native storage, callback
frames, and native registration lifetimes; [async](libuv-runtime.md) owns
Tasks, waits, delivery, cancellation, and subscriptions. Net owns socket
policy, DNS result selection, buffering, delimiter parsing, and
application-visible errors. TLS composes over the public net records and never
reaches their low-level owner ([TLS implementation](ssl-library.md)).

## Records

| Record | Fields |
| --- | --- |
| `Address` | Public `const` scalar fields `ip: string`, `port: integer`, `ipv6: boolean`, and `scope_id: integer`. |
| `Connection` | Private `handle` (`uv.tcp_t`) with cached `handle_view` and `stream` views, owning `loop`, delimiter `excess`, `input` (a buffered subscription of strings), `start_read`, the read flags `started`, `read_ahead_enabled` and `read_started`, the scratch `read_buffer`, `phase`, `input_listeners`, `pending_outputs`, and lazy cached `local_addr` / `peer_addr` (`Address?`). |
| `Server` | Private `handle` with cached views, `loop`, `clients` (a buffered subscription of accepted Connections), the saved `failure` (nil until the listener fails), `start_listen`, and lazy cached `local_addr` (`Address?`). |

The views are cached once at construction; operations still query current
native initialization, closing, and writability. `phase` is one of
`CONNECTION_UNCONNECTED`, `CONNECTION_CONNECTING`, `CONNECTION_CONNECTED`, or
`CONNECTION_FAILED`. `Connection` deliberately stores no cached `no_delay`
boolean field: libuv provides `uv_tcp_nodelay` without `uv_tcp_get_nodelay`, so
a write-only setter avoids stale Titan-side state diverging from the OS socket
across transfer.

`Connection:has_pending_input()` is a pure snapshot. It returns true when the
connection is not connected, its handle is closed, `excess` is nonempty, or the
subscription's `has_pending()` is true. It adds no receive counter, waiter, or
native poll. False does not mean the kernel socket is empty; HTTP checks it
again immediately before sending on an idle lease.

`Connection:add_input_listener` appends a registration to the ordered
`input_listeners` Array. After the receive callback publishes bytes or a
terminal state, `notify_input` calls the live listeners without consuming
input. Removal marks a registration dead and replaces the Array with a
filtered copy, so an in-progress notification keeps a stable order. If
listeners raise, `notify_input` keeps the first error and its traceback in an
`async.Error`, runs the remaining listeners, and then raises it with
`Error:raise`. Explicit close clears the registrations. Registering a listener
creates no read watcher or Task.

## One-shot requests

DNS, connect, write, and shutdown follow the generic
[one-shot Task adapter](libuv-extension-guide.md#one-shot-task-adapter): a
private per-operation context, a named registrar, and a named terminal
callback that snapshots its Completion and operation number, clears the request
userdata before settlement, and reports unexpected failures through
`completion:fatal(number, error, traceback)` plus a bare rethrow. Net's
registrars are `start_resolve` (with `async.await_cancellable_with`) and
`start_connect`, `start_write`, and `start_shutdown` (with `async.await_with`);
their callbacks are `resolved`, `connected`, `written`, and `shut_down`.
Accepted requests keep their context and native inputs until terminal
completion; cancellation never releases borrowed buffers early.

**DNS.** `resolve_addresses` rejects host text containing NUL and submits
`uv.getaddrinfo` with `AF_UNSPEC`, `SOCK_STREAM`, `IPPROTO_TCP`, and
`AI_NUMERICSERV`. The binding copies native entries into owned
`uv.sockaddr_t` values; net selects IPv4 and IPv6 entries in resolver order and
frees the native result in the callback before settlement. A lexical `defer`
also frees any result the request still retains, which covers a failure inside
the binding's copy before net's callback runs. `start_resolve` returns the
request view, so cancellation can request native `uv.cancel`; running DNS can
still outlast an opening deadline while its callback retires. `net.resolve`
exposes the copied addresses.

**Writes.** Each write owns a fresh `uv.write_t` and submits its immutable
string through `uv.write_string`, which retains the string and embeds a scalar
native buffer descriptor, so no buffer view or descriptor Array is needed.
`uv.buf_check_length` runs before await admission, so the native-range error
takes precedence even for an already cancelled Task. The terminal callback
roots the old string before clearing request fields. Overlapping writes keep
independent requests and payloads. Libuv orders accepted writes, so net has no
writer queue.

**Shutdown** uses one `uv.shutdown_t`; a later shutdown is a no-op once the
native stream is no longer writable.

## Dialing and listening

`new_connection(loop, enable_no_delay)` initializes the `uv.tcp_t` handle.
`Connection.new` (after `async.checkpoint()`) and `net.connect` pass
`enable_no_delay = true`, calling `check_status(uv.tcp_nodelay(tcp, 1),
"net.set_no_delay")` immediately after `uv.tcp_init(loop, tcp)` while no OS
socket exists yet (`fd == -1` on Unix, `INVALID_SOCKET` on Windows). Libuv
records `UV_HANDLE_TCP_NODELAY` in `handle->flags` and applies
`setsockopt(..., IPPROTO_TCP, TCP_NODELAY, 1)` automatically when
`uv.tcp_connect` creates the socket; calling `set_no_delay(false)` before
`connect_address` clears `UV_HANDLE_TCP_NODELAY` before socket creation.
`connect_address` validates Runtime, address, port, and cancellation before
admitting the single attempt, then sets connecting before the native await.
Successful dials and accepted sockets enter connected; failed or cancelled dials
enter failed. Read, write, shutdown, and address queries require connected,
`set_no_delay` permits unconnected (pre-dial) and connected, and close retires
every phase. An independently runnable opening supervisor can therefore close a
known endpoint before it drains its pending connect child.

`net.connect` composes one resolution with the same one-address method,
trying the copied addresses in resolver order with a fresh TCP owner per
attempt. A candidate stays lexically owned until publication; a failed attempt
or a cancelled native success starts close on the unpublished socket, whose
native owner stays rooted until close completion.

`listen` uses backlog 128 when absent and validates the positive native range
before submission. `reuse_port` true passes `uv.TCP_REUSEPORT` as the
`uv.tcp_bind` flags; nil and false pass zero. Every candidate uses the same
flags, and bind failures go through the ordinary candidate-close and
`async.OperationError` path. There is no fallback that drops reuse when the
platform reports `UV_ENOTSUP`.

## Persistent reads

A connection builds its subscription and producer callbacks in
`wrap_connection`, before native TCP initialization, and calls
`uv.read_start` only when the first read needs native input. The allocation
callback lazily creates one writable `uv.buf_t` and reuses it, replacing it
only with a larger one. A suggestion outside `1..READ_BUFFER_IDLE_CAPACITY`
(64 KiB) selects that cap. Libuv normally suggests 64 KiB, so a connection
whose reader has been activated keeps about 64 KiB of scratch while idle,
until EOF, a read error, producer stop, close, or transfer drops the
`read_buffer` reference. The public binding separately retains each
allocation/read pair and carries allocation-callback failure across the native
boundary. Runtime teardown closes raw handles without calling Connection
methods, so a retained Connection can keep its scratch buffer afterwards; its
closed read and close paths clear the reference without native I/O.

A positive read copies the exact byte prefix into a fresh immutable string
before publishing it, so reusing the scratch buffer cannot change earlier
chunks. The scratch cap does not bound the subscription's queued strings.
Zero-byte notifications publish nothing. EOF or a negative status stops native
reading and ends or fails the subscription after any queued bytes. Net keeps
only delimiter excess outside the subscription; there is no second input queue
or reader lock. The literal delimiter search handles matches split across
chunks and keeps bytes after a match in `excess`.

The closed and excess fast paths run first. A read that needs the
subscription validates its Task and owning Runtime, then calls
`async.checkpoint()` before `input:has_waiter()`, so pending cancellation wins
over the `Connection already has a waiting reader` diagnostic. The
subscription's reservation is the authority
([persistent source adapter](libuv-extension-guide.md#persistent-source-adapter));
cancelling one reader leaves the shared native read source active.

## Demand-driven reads

`Connection:read_ahead(enabled?)` selects the read policy before the first
native arm; the default is persistent prefetch. `read_started` freezes the
policy even though demand mode clears `started` after each result. For a
nonzero callback, demand mode calls `uv.read_stop` and clears `started` before
publishing bytes or a terminal state; an empty callback leaves the read
pending. The next public read drains excess and queued results before arming
another native read.

Stopping before publication keeps the Windows callback from requeueing its
read. Its native pending-request count is retired only after that callback
returns, so a handoff must first `async.yield()` past the callback boundary.
This neither weakens `uv.stream_transfer_status` nor cancels an
already-posted persistent read.

## Accept delivery and unread sockets

A listener's connection callback creates each child with
`new_connection(loop, false)`—leaving `UV_HANDLE_TCP_NODELAY` unset before
`uv.accept`—and applies `uv.tcp_nodelay(client.handle, 1)` only after
`uv.accept` succeeds. Setting `UV_HANDLE_TCP_NODELAY` beforehand would cause
libuv's `uv__stream_open` inside `uv_accept` to propagate a child `setsockopt`
failure as an `uv_accept` error and trigger `fail_server`, closing the
listener. Instead, when post-accept `uv.tcp_nodelay(client.handle, 1)` returns
a negative status, the callback returns early so its lexical
`defer if client ~= nil then abandon(client) end` guard closes and discards
only that unconfigurable child without calling `fail_server`, without raising
from the UV callback, and without publishing an unconfigured `Connection`.
Otherwise the callback sets `client.phase = CONNECTION_CONNECTED` and owns
`client` lexically until `publish(client)` returns true, moving ownership into
the `clients` queue. Rejection or an exception closes the unpublished socket;
an exception also fails the server and is rethrown. Accepted connections start
their read watcher lazily.

Server failure takes precedence over unread accepted clients: it saves the
failure, drains and closes every queued socket, closes the listening handle,
and stops delivery. `accept` checks the saved failure before validation and
after waking; otherwise it runs the cancellation checkpoint before the
reservation check and keeps the duplicate-wait diagnostic. Closing a server
also drains and closes every unread connection, because a generic queue cannot
know its values own sockets.

## Socket addresses and `TCP_NODELAY`

Endpoint address queries and `TCP_NODELAY` configuration use existing public
`titan.uv` APIs (`uv.tcp_getsockname`, `uv.tcp_getpeername`, `uv.ip_name`,
`uv.AF_INET`, `uv.AF_INET6`, `uv.sockaddr_t` `is_complete`/`family`/`port`/
`scope_id`, and `uv.tcp_nodelay`) with zero `titan.uv` or C/FFI changes.

`Address` carries `ipv6: boolean` rather than exposing OS-specific `AF_INET6`
integer constants (`10` Linux, `30` macOS, `23` Windows). The private helper
`sockaddr_to_address(raw, operation)` verifies `raw ~= nil and
raw:is_complete()` (raising `uv.EINVAL`), checks `AF_INET` or `AF_INET6`
(raising `uv.EAFNOSUPPORT`), formats `ip` with `uv.ip_name(raw)`, and returns
`Address(text, raw:port(), family == uv.AF_INET6, raw:scope_id())`.

`Server.local_addr`, `Connection.local_addr`, and `Connection.peer_addr` start
as `nil` and populate lazily on the first query:

- `Server:local_address()` validates the handle and owning Runtime, populates
  `self.local_addr` via `uv.tcp_getsockname` (`"net.local_address"`) if `nil`,
  and returns the cached immutable `Address`.
- `Connection:local_address()` and `Connection:peer_address()` validate the
  handle and owning Runtime, require `self.phase == CONNECTION_CONNECTED`,
  populate `self.local_addr` (`uv.tcp_getsockname`, `"net.local_address"`) or
  `self.peer_addr` (`uv.tcp_getpeername`, `"net.peer_address"`) if `nil`, and
  return the cached `Address` with zero allocations or syscalls on repeated
  calls. If a peer disconnects before the first `peer_address()` query and the
  OS returns an error such as `ENOTCONN` or `EINVAL`, `check_status` surfaces
  it as `async.OperationError` with `operation == "net.peer_address"`.

`Server:close()`, `Connection:close()`, and source detachment in
`Connection:to_transfer_payload()` clear the cached `local_addr` / `peer_addr`
fields to `nil`; any `Address` already returned to callers remains an immutable
snapshot.

`Connection:set_no_delay(enabled)` calls `validate(self.handle_view, self.loop,
"configure no-delay on")` (requiring an active Task on `self.loop` and
rejecting closed or detached handles), rejects `CONNECTION_CONNECTING` and
`CONNECTION_FAILED`, permits both `CONNECTION_UNCONNECTED` (pre-dial) and
`CONNECTION_CONNECTED` (before or after reads, writes, or `shutdown()`), and
invokes `check_status(uv.tcp_nodelay(self.handle, flag), "net.set_no_delay")`.

## Connection transfer ownership

The generic rules are in
[manual resource handoff](transfer-library.md#manual-resource-handoff) and
[native socket and pipe handoff](libuv-extension-guide.md#native-socket-and-pipe-handoff).
`Connection:to_transfer_payload` is synchronous, needs no Task or cancellation
checkpoint, and can run in a transfer callback. Its gate requires the current
Runtime's loop, a Runtime that is not closing, an open connected handle, no
reserved reader, zero `pending_outputs`, and no input listeners, and then calls
`uv.stream_transfer_status(stream, true)`. Passing true permits a stoppable
persistent read watcher but never an outstanding native read request, so
Windows overlapped reads cause rejection instead of making every net read
demand-driven.

On Windows, libuv decrements a connect request's pending count after invoking
its callback, and completion can resume the waiting Task inside that callback.
Returning from `connect` therefore does not prove native retirement; the gate
rejects until the callback returns, and callers moving a fresh connection
yield once first.

The encoder snapshots `excess`, the queued bytes and the terminal state with
`snapshot_pending()` before stopping the watcher and calling the TCP handle
hook. If native detachment fails, it restarts a previously active watcher.
After detachment it clears `local_addr`, `peer_addr`, and the subscription,
callback, and scratch references; the source handle closes asynchronously
through its ordinary callback. The private `connection_transfer_fields` schema
holds the TCP child payload, the copied input bytes, the terminal kind and
optional `OperationError`, and the `started`, `read_ahead_enabled` and
`read_started` flags—with no address fields and no `no_delay` boolean. A
lexical guard discards the TCP payload if serialization raises.
`Connection.discard_transfer_payload` decodes the same schema and delegates to
`uv.tcp_t.discard_transfer_payload` without a Runtime.

On POSIX (`dup`) and Windows (`WSADuplicateSocketW` + `WSASocketW`), the
duplicated descriptor/socket shares the underlying kernel/Winsock socket state
and preserves its exact `TCP_NODELAY` option (`1` by default, or `0` if
disabled before transfer). `from_transfer_payload` validates the schema before
adopting the endpoint through `uv_tcp_open` on a fresh `uv_tcp_t` whose
`UV_HANDLE_TCP_NODELAY` flag is `0` (so libuv does not overwrite the inherited
kernel option), creates a fresh `Connection` and subscription on the
destination Runtime, restores unread bytes and the read policy, and restarts a
previously active reader only in read-ahead mode. On the destination Runtime,
`local_address()` and `peer_address()` populate lazily against the adopted
handle and `set_no_delay(enabled)` updates the live socket directly. No
source-state callback, Task or subscription is copied.

## Close and Runtime ownership

A native owner counts as closed when it is no longer initialized or libuv
reports it closing; checking initialization first avoids a native query outside
the handle's lifetime. Close methods are idempotent, while live I/O checks the
current Task and exact owning Runtime.

Connection close clears `local_addr`, `peer_addr`, and `excess` and closes its
subscription. The producer's stop action ends native reading; its close action
drains unread bytes and calls `close_handle`, which waits with
`async.await_cleanup_with` and the named callback `closed`. Server close clears
`local_addr`, uses the same pattern, and disposes queued connections. Cleanup
waits retire ownership even when the closing Task already
has sticky cancellation. Subscription close is not a join barrier for a second
concurrent caller: the first closer owns the cleanup work.

Runtime teardown belongs to async: after Tasks and accepted operations retire,
it walks and closes the remaining public handles before closing the loop. Net
has no Runtime networking registry, operation dispatcher, raw socket fallback,
or operation counter of its own.
