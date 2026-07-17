# TCP networking

The `net` standard module provides asynchronous DNS and TCP with direct-style
Titan methods. Titan source imports it as:

```titan
local net = import "net"
```

Lua loads the same canonical module identity with:

```lua
local net = require "titan.net"
```

Network operations must run inside a Task started by `async.run`, or inside a
standalone program whose imports installed the automatic async bootstrap. They
suspend only the current Task. Callbacks and continuations run serially on the
loop thread; CPU-bound code still blocks other I/O until it yields.

## API

```titan
record Connection
record Server

function connect(host: string, port: integer): Connection
function listen(host: string, port: integer,
                backlog: integer): Server

function Connection:read(): string?
function Connection:read_until(delimiter: string,
                               chop: boolean?): string?
function Connection:write(data: string)
function Connection:shutdown()
function Connection:close()

function Server:accept(): Connection
function Server:close()
```

`Connection` and `Server` are opaque nominal records. Applications cannot
construct them or inspect their native handles.

## Connecting and listening

`connect` resolves `host` asynchronously, considers IPv4 and IPv6 TCP
addresses in resolver order, and closes each failed candidate before trying
the next. It accepts ports `1..65535`.

`listen` resolves and binds `host`, then starts a TCP listener. Its port may be
`0` to request an ephemeral operating-system port, although this initial API
does not expose the selected address or port. `backlog` must be positive and
also sets the maximum number of already accepted Connections retained in the
library's user-space accept queue.

Hosts are text and cannot contain an embedded NUL. Socket payloads are binary
and may contain any byte, including NUL.

## Reading

A Connection starts its libuv read watcher as part of successful connection or
accept initialization. It keeps reading and retaining GC-owned chunks even
when no Task is waiting. This avoids leaving peer data in the kernel merely
because application code is temporarily busy, but the retained application
buffer has no size limit: a peer that produces data faster than the program
drains it can make memory use grow.

`read()` returns the facade's oldest retained excess first. Otherwise it
returns all native chunks already queued when the low-level call is serviced,
or waits for the next positive callback and returns that callback's nonempty
binary string. Batch boundaries are therefore timing-dependent. It returns
`nil` only at EOF. EOF is sticky: every later read also returns `nil`. A reset
or other read error is sticky as well; after already completed chunks have
been drained, every later read raises the same or an equivalent `async.Error`.
A non-EOF read error also initiates physical Connection close.

`read_until(delimiter, chop)` requires a nonempty delimiter. It consumes
through the first delimiter, which may span native chunks, and retains bytes
after it for the next call. With `chop` absent or false, the returned string
includes an actual delimiter. With `chop == true`, the delimiter is omitted;
if it occurs at the start, `""` is a valid result distinct from EOF `nil`.

EOF after a nonempty unterminated tail returns that tail unchanged, then later
calls return sticky `nil`. A read error after such a tail likewise returns the
tail unchanged, then the stored error is raised by every later read. No
delimiter is invented for a terminal tail. With no tail, EOF returns `nil` and
an error raises immediately.

`read` and `read_until` share one per-Connection reader lock. A second Task
cannot enter either method while another reader owns that lock. Cancelling a
waiting reader detaches only that waiter; it does not stop the physical read or
close the shared Connection, and another Task may read afterward. Bytes
accumulated by a cancelled delimiter read remain retained for the replacement
reader.

## Writing, shutdown, and close

Writes are FIFO per Connection. `write` returns only after libuv's callback,
and the complete binary input remains rooted until then. An empty write still
checks that the Connection and its write side are usable.

`shutdown` is ordered after earlier writes. Requesting it immediately rejects
later writes. The first call is cleanup-shielded until the physical
`uv_shutdown` callback, then leaves the read side open until EOF, error, or
`close`. Repeated shutdown calls are idempotent and do not enqueue another
native request.

`close` closes both directions and is idempotent. Concurrent callers wait for
the same terminal close transition. For a Connection, it stops the continuous
read and rejects new output or blocking read waits, but already completed read
chunks remain ahead of the closed-stream error. Submitted and queued FIFO
writes/shutdown keep their order; the native handle closes only after that
output drains. Close waits for the required request and handle callbacks and
returns only when the handle is safe to reclaim. A Connection or Server
retained from an earlier completed loop session cannot be used in a later
session.

Cancellation is logical first. A cancelled queued write is removed before
submission. Cancelling an active write does not close a potentially shared
Connection; its eventual callback only cleans storage and the Task receives
the provider-owned cancellation record whose type-only facade name is
`async.Cancelled`. Close and the first shutdown are shielded through their
terminal native callbacks before sticky cancellation is delivered.

## Accepting

`accept` waits for the next Connection or takes the oldest already accepted
Connection from the bounded queue. Only one Task may wait in `accept` at a
time. Cancelling that waiter leaves the Server listening.

Every incoming notification is accepted into a fresh GC-owned TCP handle. If
no Task is waiting and the bounded queue is full, the new client is immediately
closed; the Server stays active. `Server:close` closes queued clients and wakes
an accept waiter with an error.

## Errors

Immediate and asynchronous libuv failures raise the same provider-owned error
record, re-exported under the type-only facade name `async.Error`. Its fields
are `code: integer`, `name: string`, `message: string`, `operation: string`,
and `subject: string?`; the alias is not a constructible `async.Error` runtime
namespace.

DNS errors use libuv's `EAI_*` names. EOF is normal for both `read` and
`read_until`; an unterminated final batch is returned before sticky EOF.

## Example

```titan
local net = import "net"
local async = import "async"

function client(): value
  local connection = net.connect("127.0.0.1", 8080)
  defer connection:close()
  connection:write("hello\0world\n")
  connection:shutdown()
  return connection:read_until("\n", false)
end

function main(args: {string}): integer
  local task = async.run(client)
  task:join()
  return 0
end
```

## Availability

Linux and macOS are supported. The default build downloads, verifies, and
statically links the pinned libuv release:

```sh
make libuv
"$PREFIX/bin/luarocks" make
```

For a system development package, install libuv and `pkg-config`, then use:

```sh
LIBUV_MODE=system make libuv
LIBUV_MODE=system "$PREFIX/bin/luarocks" make
```

Typical packages are `libuv1-dev pkg-config` on Debian/Ubuntu,
`libuv-devel pkgconf-pkg-config` on Fedora, and `libuv pkgconf` through
Homebrew on macOS. Applications importing the installed binary `net` module do
not need libuv headers at compile time; all libuv and callback-shim linkage
remains in the combined standard-library provider
`$ROCKS_TREE/lib/titan/0.16/titan.so`. The supported installation currently
sets `ROCKS_TREE == PREFIX`; the former owns Titan's SDK/stdlib while the latter
owns Lua and LuaRocks. Repository contributors can still use
`make stdlib` for an in-checkout standard-library build.

UDP, Unix-domain/named pipes, socket options, and endpoint-inspection APIs are
follow-ups.
