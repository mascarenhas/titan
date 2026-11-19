# Low-level libuv standard library

`titan.uv` exposes libuv's event loop, handles, requests, buffers, addresses,
processes, threads, and system utilities as public Titan types without needing
a C `uv.h` import. Use the higher-level [`async`](async-io.md),
[`fs`](standard-library-fs.md), [`net`](standard-library-net.md),
[`timer`](standard-library-timer.md), and [`os`](standard-library-os.md)
modules for ordinary application code; use `uv` when building adapters or
calling native libuv operations they do not wrap.

- **Import:** `local uv = import "uv"` (Titan) · `require "titan.uv"` (Lua)
- **Targets:** Native only (bundles pinned libuv 1.53.0; `uv.has_api(name)` queries whether a canonical wrapper without the `uv_` prefix is exported, without probing kernel support)

## Start with an explicit loop

Construct a `loop_t` and initialize it with `uv.loop_init`. Creating a handle
allocates its Titan owner, while `*_init` begins its native lifetime; stopping
a handle does not end that lifetime. Close every initialized handle and drive
the loop to completion before calling `uv.loop_close`.

This complete [timer example](uv/examples/timer_example.titan) uses only public
`titan.uv` declarations:

```titan
local uv = import "uv"

function main(_args: {string}): integer
  local loop = uv.loop_t()
  if uv.loop_init(loop) < 0 then return 1 end
  local timer = uv.timer_t()
  if uv.timer_init(loop, timer) < 0 then
    uv.loop_close(loop)
    return 1
  end
  local calls = 0
  local status = uv.timer_start(timer,
    function(owner: uv.timer_t)
      calls = calls + 1
      uv.close(owner:as_handle_t(), nil)
    end, 1, 0)
  if status < 0 then
    -- A rejected start leaves the initialized handle needing close.
    uv.close(timer:as_handle_t(), nil)
    uv.run(loop, nil)
    uv.loop_close(loop)
    return 1
  end
  uv.run(loop, nil)
  if uv.loop_close(loop) < 0 then return 1 end
  if calls ~= 1 then return 1 end
  return 0
end
```

Build and run it from the repository root:

```sh
titanc -o out --tree doc/language/uv/examples timer_example
./out/timer_example
```

See the [runnable example guide](uv/examples/README.md) for eleven complete
programs covering all 28 libuv API families.

### Event-loop and thread boundaries

Importing `uv` alone does not install `titan.async`'s Task bootstrap, create a
default loop, or alter `SIGPIPE` handling, so `main` runs on the main Lua
thread and may call `uv.run` directly. Programs that import `async` (directly
or transitively) and also drive loops explicitly must build with
`--no-uv-bootstrap` and manage their own `async.run`/`async.loop` sessions.
Never call `uv.run` from an async Task, a native callback, or a `uv.walk`
callback.

`uv.run` and `uv.walk` require the owning main Lua thread and cannot reenter
any loop. Ordinary Titan wrappers execute Titan/Lua code and are never callable
from foreign OS threads. For cross-thread native code, use the explicit C-only
entries:

- **Synchronization primitives:** The
  [synchronization entry map](uv/supplemental.md#direct-synchronization-entry-map)
  lists the direct C-callable `native_*` synchronization entries. Keep any
  borrowed `mutex_t`/`rwlock_t`/`sem_t`/`cond_t`/`barrier_t`/`key_t`/`once_t`
  owner rooted until every native user is quiescent, then destroy it explicitly.
  `mutex_t.create_native()` allocates caller-owned heap storage released only
  by `native_mutex_destroy` (never pass `mutex_t:borrow()` to it). `once_t()`
  initializes its guard with no separate init/destroy, and TLS keys neither
  identify Tasks nor own their pointees. Never suspend an async Task while
  holding a blocking `uv` lock; use [`async`](async-io.md) or
  [`thread`](standard-library-thread.md) channels for cooperative coordination.
- **Heap thread tokens:** The
  [heap-thread-token helpers](uv/supplemental.md#create_native_thread)
  (`create_native_thread`, `native_thread_join`, `native_thread_detach`) manage
  process-heap thread tokens explicitly without retaining GC argument graphs;
  join or detach consumes the token on success.
- **Cross-thread wake bridge:** `external_wake_t` is a low-level identity wake
  bridge for waking a destination loop from foreign threads without touching
  destination GC objects. Follow the
  [ownership and teardown rules](uv/types.md#synchronization-and-native-carrier-ownership)
  and [worker boundary notes](uv/CONTRACT-NOTES.md#cancellation-and-worker-boundaries):
  normal close returns `EBUSY` if registrations are active, and native
  unregister is destination-loop-thread-only.

## Status, lifetime, and async composition

Native status values use `0` for success and negative libuv error codes for
failure (`uv.err_name` and `uv.strerror` return copied strings). Signed data
results such as byte counts, descriptors, timestamps, or `uv.run` liveness are
distinct from error status channels.

For asynchronous requests, the immediate return value reports whether
submission was accepted, while the callback reports the operation's outcome. A
negative submission status means no callback will fire, though cleanup can
nonetheless be required (for example `fs_req_cleanup` on `fs_t`). Accepted
requests retain their callbacks and borrowed owners through terminal
completion; `uv.cancel` attempts to shorten a request, and a cancelled request
delivers a completion callback. Native OS resources (file descriptors, directories, child
processes, dynamic libraries) require explicit closing rather than relying on
GC. See the [synchronous stat example](uv/examples/fs_stat_example.titan) and
[ownership contracts](uv/CONTRACT-NOTES.md).

Inside an [`async`](async-io.md) adapter, `async.current_loop()` returns the
borrowed Runtime loop driven by `async`. Submit one-shot `uv` requests from
`async.await` / `async.await_with` registrations and settle the completion from
the terminal callback; wrap persistent sources in `CoalescingSubscription` or
`BufferedSubscription` (see the complete
[async file adapter example](async-file-example.titan)).

## Reference directory

- [Types, records, unions, and constants](uv/types.md)
- [Callback timing, ownership, and thread affinity](uv/callbacks.md)
- [Supplemental APIs and `native_*` C entries](uv/supplemental.md)
- [Ownership and value contracts](uv/CONTRACT-NOTES.md)
- [Process spawn and pipe policy](uv/PROCESS-POLICY.md)
- [API coverage and deliberate omissions](uv/coverage.md)

| Family | Operations |
| --- | --- |
| [Loops](uv/functions/loop.md) | Construction, driving, time, backend queries, configuration, and handle walks. |
| [Handles](uv/functions/handle.md) | Close, active/reference state, public data, loop/type views, and socket buffer sizes. |
| [Requests](uv/functions/request.md) | Cancellation, public data, kind/size queries, and request views. |
| [Timers](uv/functions/timer.md) | One-shot and repeating callback timers, stop/rearm, repeat/due-time queries. |
| [Prepare](uv/functions/prepare.md), [check](uv/functions/check.md), [idle](uv/functions/idle.md) | Callbacks around the loop's polling phase. |
| [Async notifications](uv/functions/async.md) | Coalesced native-to-loop notifications, C-only send entries, and `external_wake_t`. |
| [Signals](uv/functions/signal.md) | Repeated and one-shot signal delivery. |
| [Descriptor polling](uv/functions/poll.md) | Readiness notifications for borrowed descriptors or sockets. |
| [Streams](uv/functions/stream.md) | Listen/accept, read allocation, writes, shutdown, and immediate writes. |
| [TCP](uv/functions/tcp.md) | Socket creation/adoption, addresses, connect, options, and reset close. |
| [Pipes](uv/functions/pipe.md) | Anonymous/named pipes, IPC transfer, names, and process stdio. |
| [TTY](uv/functions/tty.md) | Terminal handles, input modes, window size, and virtual-terminal state. |
| [UDP](uv/functions/udp.md) | Datagram addresses, receive/send, multicast, queue queries, and batched sends. |
| [DNS](uv/functions/dns.md) | Address/name lookup and explicit address-result disposal. |
| [Filesystem](uv/functions/fs.md) | Files, directories, metadata, permissions, links, and request result access. |
| [Filesystem events](uv/functions/fs_event.md), [filesystem polling](uv/functions/fs_poll.md) | Native notifications or periodic metadata comparison. |
| [Processes](uv/functions/process.md) | Spawn, stdio setup, PID, signal delivery, and process-handle ownership. |
| [Worker pool](uv/functions/threadpool.md) | C-only blocking work with loop-thread completion. |
| [Threads and synchronization](uv/functions/threading.md) | Native threads, join/detach, affinity, locks, conditions, semaphores, once, TLS keys, and `native_*` entries. |
| [Dynamic libraries](uv/functions/dll.md) | Open, symbol lookup, error text, and explicit close. |
| [System utilities](uv/functions/misc.md) | Environment, paths, identity, memory, clocks, randomness, addresses, and encoding. |
| [Metrics](uv/functions/metrics.md) | Loop activity and idle-time measurements. |
| [Errors](uv/functions/errors.md), [version](uv/functions/version.md) | Error-domain conversion, text, and bundled native version. |
| [Legacy allocation helpers](uv/functions/undocumented.md) | Explicit `loop_t()` alternatives to deprecated heap loop helpers. |

See [API coverage](uv/coverage.md) for the nine omitted libuv C functions (such
as `uv_default_loop`, `uv_setup_args`, and `uv_write_nwritten`) and the five
snapshot-free functions that `titan.uv` runs automatically after copying
results.

## Abandoned-loop retirement

```text
function loop_abandon(loop: loop_t): integer
```

`loop_abandon` retires an exclusively owned loop during final Lua-state
teardown without invoking any Titan or Lua callbacks. `titan.async` calls it
from its Runtime finalizer when a Lua state closes before its Runtime finishes;
it is not ordinary shutdown or lexical cleanup. Call it only on the owning main
Lua thread outside any `run`, `walk`, or inline callback (otherwise it returns
`EBUSY` or raises on another Lua thread).

It unbinds the [transfer loop](#native-resource-handoff) if bound, clears all
handle and request callbacks, closes open handles, drains accepted native work
until completion, and closes the loop. Undelivered `open`, `mkstemp`, and
`opendir` results are released automatically; already-delivered resources,
custom C workers, and child processes stay with their owners. Because accepted
native work finishes before the loop closes, `loop_abandon` can block. It
returns `0` on success or on an already-closed/fresh loop; do not reuse the
loop or its owners afterward. `has_api` returns `false` for `loop_abandon`.

## Native resource handoff

```text
function tcp_t:to_transfer_payload(): string
function tcp_t.from_transfer_payload(payload: string): tcp_t
function pipe_t:to_transfer_payload(): string
function pipe_t.from_transfer_payload(payload: string): pipe_t
function tcp_t.discard_transfer_payload(payload: string): integer
function pipe_t.discard_transfer_payload(payload: string): integer
function stream_transfer_status(stream: stream_t, allow_reading: boolean?): integer
function bind_transfer_loop(loop: loop_t)
function unbind_transfer_loop(loop: loop_t)
```

`tcp_t` and `pipe_t` implement the custom record transfer hooks for
[`TransferValue`](async-io.md#transfer-values). Encoding duplicates the OS
socket or descriptor, serializes it, and initiates closing the source owner;
decoding creates a fresh owner on the destination Runtime's bound loop and
adopts the duplicate. (`async` manages `bind_transfer_loop` automatically;
callback-only programs bind and unbind their own initialized loop explicitly.
Before sending a native payload to an independent `lua.Lua` state, initialize
its Runtime first.)

Handoff requires an idle, connected, readable-and-writable TCP stream or an
idle non-IPC pipe with `nil` public handle data; listeners, half-closed
sockets, queued writes, pending connect/shutdown requests, and pending native
reads are rejected. `stream_transfer_status` performs a read-only preflight
check (`allow_reading = true` allows an adapter's stoppable read watcher, which
must be stopped before calling `to_transfer_payload`).

Native payloads obey the
[shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules):
adopt each payload exactly once, or release an unadopted payload with
`tcp_t.discard_transfer_payload` / `pipe_t.discard_transfer_payload` (which
consumes ownership even if the close status is negative).
