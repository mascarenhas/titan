# Libuv DNS and TCP implementation

The public API and semantics are documented in the [TCP networking standard
library](../language/standard-library-net.md).

The `net` facade contains no C FFI types. Each `Connection` or `Server` holds
one local `uv.uv_tcp_t` record; the `uv` module alone can unwrap its local
`*uv_tcp_t` field. Repeated calls therefore read the native pointer directly
without allocating pointer-boxing userdata.

## Ownership graph

An active Runtime adds a pending networking-owner list and a TCP resource list
to its existing task, timer, and filesystem graph. Request and handle storage
is allocated as Lua userdata using the imported libuv type's `.sizeof`, then
kept alive by one exact Titan owner record. Libuv `data` points to that owner
record, never to the separate storage userdata.

Persistent `uv_tcp_t` owners and private DNS, connect, write, and shutdown
owners keep the fixed callback layout used by `titan_uv.c`. Native callbacks
recover the module-cached main thread and fixed dispatcher closure, obtain the
module Udata from that closure, and call the dispatcher's Titan-native entry.
They do not use a generated Lua entry or a second protected-call layer.

## DNS extraction

Host text has an operation-owned NUL-terminated copy. `tcp.titan` formats the
validated port in a zeroed six-byte automatic C array and builds a zeroed
`addrinfo` hint with `AF_UNSPEC`, `SOCK_STREAM`, `IPPROTO_TCP`, and
`AI_NUMERICSERV`. It roots and publishes the request owner, installs its data,
then calls public `uv_getaddrinfo` with the native callback trampoline. Libuv
copies the automatic node, service, and hints inputs during that call.

The result walker uses the complete named `addrinfo`, `sockaddr`, and
`sockaddr_storage` tags imported from the host `uv.h` closure. It accepts only
IPv4/IPv6 entries with a non-null address whose length fits the host's exact
`sockaddr_storage`, then copies them in resolver order into a typed, zeroed,
GC-owned array of opaque `titan_uvshim_address` cells. The operation roots that
owned array before the borrowed chain is released. Static assertions in the
native runtime guarantee that each opaque cell is large and aligned enough;
Titan never interprets its bytes.

The C callback passes libuv's borrowed `addrinfo` pointer directly to the
trusted Titan dispatcher. The dispatcher first copies usable addresses, then
calls public `uv_freeaddrinfo` directly before it drives a Task or starts a
socket attempt. Its trailing emergency catch performs the same direct release
when needed. No continuation observes or retains the borrowed pointer, and
each non-null result has one release path.

Connect and listen allocate a fresh TCP handle for every address attempt. A
failed initialized candidate is closed and drained before the next attempt.
Cancellation closes an unpublished candidate and waits for both request and
close callbacks; late success is never published. While the owned address
array remains rooted, Titan derives the selected cell, explicitly converts its
bytes to `const struct sockaddr *`, and calls public `uv_tcp_bind` or
`uv_tcp_connect`. Connect computes that pointer before publishing its request
owner, installs request data, and then submits with the native connect callback.

## Stream callbacks

An outgoing Connection calls `uv_read_start` after connect succeeds and before
it is published. An accepted Connection starts reading after `uv_accept` and
before it is delivered to a waiter or placed in the accepted-client queue; a
queue-full candidate is closed without starting. A synchronous start failure
closes the unpublished Connection and fails the connect or accept operation.
Once initialized, the read watcher remains active with or without a waiter.

The C allocation callback is a thin native-Titan dispatch. It initializes
libuv's supplied `uv_buf_t` to `{ NULL, 0 }`, then the Titan dispatcher creates
a fresh `ffi.titan_ffi_char.new_array(suggested_size)`, roots that full userdata
as the Connection's current allocation, and writes its raw pointer and size to
the descriptor. The descriptor belongs to libuv; it is not the bytes' owner.
On supported Unix libuv pairs each allocation with its read callback before
requesting another for that stream, although one watcher dispatch can repeat
that pair. A POLLHUP-only EOF callback can have no preceding allocation, so
terminal handling accepts an empty current-allocation slot.

Without a waiter, a positive read callback moves the current userdata into the
Connection's `{Bytes}` queue; `Bytes.storage` is the GC edge for its raw pointer
and queued buffers are not reused. With a waiter, the callback instead converts
the current allocation directly to one binary string. It snapshots and clears
the waiter and epoch before `drive_task`, clears the current root only after the
bytes are queued or converted, and passes the string directly to the yielded
read. The resumed Task may install a replacement waiter before the callback
returns. A zero-length callback clears the current allocation and delivers
nothing.

EOF and non-EOF read errors clear any current allocation, stop reading, and
record a sticky terminal before driving arbitrary code. EOF directly resumes a
waiter with `nil` but leaves the TCP write side open. Another error stores the
uv-owned `Error` record (publicly `async.Error`), raises it directly in a
waiter, and initiates physical close. A
later low-level read first joins and drains the entire completed queue, then
returns sticky `nil` or repeatedly raises the stored error. With no data or
terminal it only installs one waiter; it never starts or stops libuv. Explicit
close stops the physical read, and Runtime teardown may discard queued chunks.

The `net` facade serializes both `read` and `read_until` through one reader
lock. It keeps delimiter excess in stream order, implements optional delimiter
chopping and terminal-tail delivery, and preserves accumulated bytes across
cancellation. A narrow low-level identity predicate lets it recognize only the
stream's stored sticky read error when returning a nonempty terminal tail;
Task cancellation and unrelated exceptions are re-raised. There is no maximum
or high-water mark: an unread peer can grow the GC-owned queue without bound.

Writes and shutdown use a per-Connection FIFO with one submitted request.
Every write request owns its copied bytes through the callback. The first
shutdown marks the source-level write side closed when queued, is submitted
only after earlier writes, and remains cleanup-shielded through its callback;
repeated calls are idempotent. Explicit close stops reads and rejects new
output, but preserves the submitted request and queued FIFO work. It calls
`uv_close` once only after that output drains, then waits until the close
callback has released the handle root.

Servers keep one accept waiter and a FIFO of already accepted Connections
bounded by the listen backlog. Every incoming callback performs one
`uv_accept`. A full queue closes that new client and keeps the listener active.
If an accepted client's read watcher cannot start, the candidate is closed and
the failure is delivered to the accept waiter or retained through the server's
terminal accept-error path.

## Cancellation and shutdown

Task cancellation increments the existing operation epoch synchronously. DNS
uses `uv_cancel` but retains its request until callback. Connect closes its
unpublished handle. Read cancellation clears only the matching waiter and
epoch; continuous reading and buffering remain active. A queued write is
unlinked, while cancellation of an active write is logical because libuv
cannot cancel it and a shared Connection must remain open. The first shutdown
and every explicit close waiter are cleanup-shielded through their terminal
callbacks.

Runtime shutdown first cancels DNS and unpublished acquisitions, then stops
reads and retires queued operations, then closes Servers, accepted queues, and
Connections. This forced teardown is distinct from explicit close, which
preserves FIFO output. The Runtime does not release a request before its
completion callback or a handle before its close callback. Both networking
root lists must be empty before `uv_loop_close`.

## Portable shim boundary

The owning Titan contributors call public libuv base-handle and base-request
APIs directly; the C FFI emits host-validated conversions from concrete libuv
pointers. The native runtime retains only the fixed owner dispatcher and
plain-C callback trampolines. The shared header describes the fixed owner
protocol and deliberately overprovisioned opaque address storage consumed by
both sides. DNS submission, result filtering/copying/release, address
selection, bind, connect, stream operations, close, and the narrow inherited
`SIGPIPE` policy all run directly from Titan through public host/libuv
declarations. There is no POSIX socket, read, write, or poll fallback.

The callback dispatcher adds one opaque pointer argument for the DNS callback's
temporary `addrinfo` payload. The pointer is never converted to a Titan
`value`; it is converted once to a typed borrowed pointer and stored in the
request control before any allocating callback body runs. Callbacks without a
pointer payload pass NULL. Host address-family, socket, protocol, and resolver
constants come from the same production `uv.h` import as the corresponding
fields.

## Verification

Compiler tests cover the language mechanisms used by the opaque wrappers;
standard-library behavior is tested separately without compiler coverage.
Loopback tests probe a bounded range of explicit ports through the public
listen API. They cover IPv4, optional IPv6, resolver fallback, binary and NUL
data, split delimiters, excess restoration,
FIFO writes, repeated and concurrent shutdown/close, bounded accepts,
exclusive waiters, continuous background buffering, cancellation that leaves
the watcher active, sticky EOF, delimiter terminal tails, leaked-resource
shutdown, and sequential Runtime generations.

The isolated DNS source variant delays logical delivery after capturing a
successful borrowed result, injects a copy failure, observes the decimal
formatter, optionally prefixes one invalid opaque candidate, and counts the
direct `uv_freeaddrinfo` call. It deterministically covers cancellation,
shutdown, exactly-once release, no stale resume, generational/full GC, and the
failed-candidate close-before-retry window without putting a timing hook in the
installed module. Generated-source and archive-symbol checks keep callback
references and result release on their direct native boundaries. Regular Linux
and the one pre-merge macOS run exercise that variant. The focused Linux
ASan/UBSan gate instead uses the
production DNS/TCP smoke, including a delayed reader that keeps a large
`uv_write_t` pending across Task cancellation, coroutine unwind, forced GC,
exact binary delivery, and a follow-up write. Manual macOS CI also repeats the
normal linkage checks.
