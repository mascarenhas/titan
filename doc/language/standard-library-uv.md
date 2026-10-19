# Low-level libuv standard library

`titan.uv` exposes libuv's event loop, handles, requests, buffers, addresses,
processes, threads, and system utilities as public Titan types. Import it with
`local uv = import "uv"` or `import "titan.uv"`. Ordinary compiled clients need
neither the binding's source files nor a C `uv.h` import. Use the higher-level
[`async`](async-io.md), [`fs`](standard-library-fs.md),
[`net`](standard-library-net.md), [`timer`](standard-library-timer.md), and
[`os`](standard-library-os.md) modules when their direct-style APIs fit the task.
Use `uv` when implementing an adapter or using a native operation those modules
do not expose.

The provider contains Titan's pinned, patched **libuv 1.53.0**. System libuv is
not a supported dependency. OS and kernel restrictions still apply: an exported
function can return an unsupported-operation status on a particular platform.
`uv.has_api("tcp_connect")` checks whether a canonical wrapper is exported; it
does not probe kernel support. The name omits the native `uv_` prefix.

The [runnable example guide](uv/examples/README.md) provides eleven complete
programs covering the lifetimes in all 28 native API families.

## Start with an explicit loop

A low-level client constructs and initializes its own loop. Constructing a
handle allocates its Titan owner; the matching `*_init` begins its native
lifetime. Stopping an event source does not end that lifetime. Close every
initialized handle and drive its close completion before closing the loop.

The complete [timer example](uv/examples/timer_example.titan) uses only the
public module:

```titan
local uv = import "titan.uv"

function main(args: {string}): integer
  local loop = uv.loop_t()
  if uv.loop_init(loop) < 0 then return 1 end
  local timer = uv.timer_t()
  if uv.timer_init(loop, timer) < 0 then
    uv.loop_close(loop)
    return 1
  end
  local calls = 0
  local status = uv.timer_start(timer,
    function (owner: uv.timer_t)
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

From the repository root, with an installed Titan SDK on `PATH`:

```sh
titanc --tree doc/language/uv/examples timer_example
./timer_example
```

Importing `uv` alone does not install async's Task bootstrap, create a default
loop, or change SIGPIPE policy. This main therefore runs on the main Lua thread
and may call `uv.run`. Importing `async`, including through a high-level module,
installs the standalone Task bootstrap instead. A program deliberately mixing
that module with explicit driving must compile with `--no-uv-bootstrap` and
provide its own `async.run`/`async.loop` session. Never drive `uv.run` from an
async Task, a native callback, or a nested `walk` callback.

`uv.run` requires the owning main Lua thread and cannot reenter any loop.
`uv.walk` also requires that thread; it invokes callbacks synchronously.
Ordinary wrappers execute Titan/Lua code and are not callable from foreign
threads, even when the underlying C operation is thread-safe. The explicit
C-only worker/thread entries, direct `native_*` synchronization functions, and
cross-thread `external_wake_t` bridge have their own
[contracts](uv/CONTRACT-NOTES.md#cancellation-and-worker-boundaries) and
[synchronization ownership rules](uv/types.md#synchronization-and-native-carrier-ownership).

The [synchronization entry map](uv/supplemental.md#direct-synchronization-entry-map)
lists all 20 removed getters and exact direct C signatures (18 newly public
entries, plus the already-public mutex lock/unlock). Native carriers use those
entries without a source import. A borrowed checked synchronization owner must
stay rooted until every native user is quiescent, then be explicitly retired.
`mutex_t.create_native()` instead returns caller-owned heap storage, destroyed
and freed only by `native_mutex_destroy`; never pass `mutex_t:borrow()` there.
`once_t.new()` already initializes its stable guard with no separate
init/reset/destroy, and TLS keys neither identify Tasks nor own their pointees.
Do not suspend a Task while holding a blocking `uv` lock; use
[same-state channels](async-io.md#bounded-channels) or
[cross-thread channels](standard-library-thread.md#cross-thread-channels) for
cooperative coordination.

The separate [heap-thread-token helpers](uv/supplemental.md#create_native_thread)
provide manual native ownership: creation returns a unique process-heap token,
and native join/detach consume it only on success. They retain no GC argument
graph and do not change checked `thread_t` semantics. Detach is not join or
proof that worker arguments may be released.

`external_wake_t` is a low-level identity wake bridge, not a message queue or
permission for a worker to touch destination GC objects. Preparation borrows a
target without keeping the loop alive; an admitted wait activates it, and the
shared handle remains referenced through registration retirement, not merely
through notification delivery. Native producers take separate references, and
the destination drains bounded batches into its own traced wait map. Follow
the [complete borrow, close, and teardown contract](uv/types.md#synchronization-and-native-carrier-ownership);
normal close rejects any remaining registration with `EBUSY`, whereas GC
detach is only a nonyielding fallback and does not complete native loop cleanup.
The native `is_notified` query preserves notification observability after
drain while a valid target borrow/reference remains. Native unregister is a
consuming **destination-loop-thread-only** entry, not a foreign producer call;
it may unreference the loop handle and immediately free the registration borrow.

## Read status and lifetime together

Native status positions use zero for success and negative libuv error codes for
failure. `uv.err_name(status)` and `uv.strerror(status)` produce copied text.
Data positions can also be signed integers: a byte count, descriptor, timestamp,
counter, or `uv.run` liveness result is not automatically an error status. Each
entry below specifies its result channel.

For asynchronous requests, the immediate result says whether submission was
accepted. The callback reports the eventual operation result. A negative
submission result normally means there will be no callback, but the request or
handle may still need cleanup: filesystem request memory, partial poll
initialization, and native spawn handoff have explicit rules. Do not infer
ownership from the sign alone.

Accepted requests retain their callbacks and borrowed owners through terminal
completion. Cancellation is only an attempt to shorten the operation; even a
successful `uv.cancel` still owes a completion callback. Native resources such
as file descriptors, directories, child processes, and dynamic-library symbols
have distinct owners. Garbage collection of an integer or identifier token
does not close them.

The [synchronous stat example](uv/examples/fs_stat_example.titan) shows a
request that needs `fs_req_cleanup` but no loop or Task. The full
[ownership and value contracts](uv/CONTRACT-NOTES.md) explain callback timing,
buffer borrowing, copied results, partial rejection, cancellation, and cleanup.

## Compose with async

Within an async adapter, `async.current_loop()` supplies the borrowed Runtime
loop; async owns driving and closing it. An `async.await` registration runs
outside the suspended Task and can submit a public `uv` request. Its terminal
callback copies results, retires native ownership, and calls the registration's
typed resolver or rejecter. Unexpected terminal callback exceptions follow the
third `fatal(error, traceback)` capability and bare-rethrow protocol.

Persistent sources use `async.CoalescingSubscription.new` or
`async.BufferedSubscription.new`. Their producer owns native start/stop/close
actions, while the subscription owns queued values and its one reserved reader.
Resource-bearing unread events need explicit disposal on close. See
[callback adapters](async-io.md#adapting-callbacks-with-await) and
[subscriptions](async-io.md#persistent-callback-subscriptions), including the
complete [file adapter example](async-file-example.titan).

## Types and operation families

The [type reference](uv/types.md) lists public records, tagged owner views,
callback aliases, enums, constants, constructors, and methods. The
[callback reference](uv/callbacks.md) specifies timing, argument ownership,
thread affinity, and exception handling. [Supplemental APIs](uv/supplemental.md)
cover owner methods, direct `native_*` synchronization foreign entries,
`mutex_t.create_native()`, the `external_wake_t` cross-thread wake bridge, and
Titan-specific helpers such as `setup_process_args()`.

| Family | Operations |
| --- | --- |
| [Loops](uv/functions/loop.md) | Construction, driving, time, backend queries, configuration, and handle walks. |
| [Handles](uv/functions/handle.md) | Close, active/reference state, public data, loop/type views, and socket buffer sizes. |
| [Requests](uv/functions/request.md) | Cancellation, public data, kind/size queries, and request views. |
| [Timers](uv/functions/timer.md) | One-shot and repeating callback timers, stop/rearm, repeat/due-time queries. |
| [Prepare](uv/functions/prepare.md), [check](uv/functions/check.md), [idle](uv/functions/idle.md) | Callbacks around the loop's polling phase. |
| [Async notifications](uv/functions/async.md) | Coalesced native-to-loop notifications, C-only send entries, and the supplemental `external_wake_t` waiter bridge. |
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
| [Threads and synchronization](uv/functions/threading.md) | Native threads, join/detach, affinity, locks, conditions, semaphores, once, TLS keys, and direct `native_*` C-only entries. |
| [Dynamic libraries](uv/functions/dll.md) | Open, symbol lookup, error text, and explicit close. |
| [System utilities](uv/functions/misc.md) | Environment, paths, identity, memory, clocks, randomness, addresses, and encoding. |
| [Metrics](uv/functions/metrics.md) | Loop activity and idle-time measurements. |
| [Errors](uv/functions/errors.md), [version](uv/functions/version.md) | Error-domain conversion, text, and bundled native version. |
| [Legacy allocation helpers](uv/functions/undocumented.md) | Why native heap loop allocation/deletion is not exported. |

## Native resource handoff

`tcp_t` and `pipe_t` provide the custom record hooks used by
[`TransferValue`](async-io.md#transfer-values):

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

Encoding duplicates the platform socket or descriptor, serializes that identifier
with a private protobuf field schema, and then starts closing the source owner.
A serialization failure closes the duplicate and preserves the source owner. Its old native storage remains rooted until the close
callback. Reconstruction creates a fresh owner on the destination Runtime's
loop and adopts the duplicate. It does not copy native `uv_*_t` storage,
callbacks, or Lua-state references. The async Runtime manages the state-local
loop binding; callback-only programs may bind an initialized loop explicitly
and must unbind it before shutdown. A different live binding is rejected, and
unbinding an unrelated loop leaves the current binding intact.

Independent `lua.Lua` calls decode transfer arguments before executing their
chunk. Establish that state's Runtime before passing a native payload, for
example with `state:run("local a = require('titan.async'); a.run(function () end)")`.
The receiving chunk can schedule its work and drive `async.loop`. After that
loop retires, establish another Runtime before a later native handoff.

Handoff requires an idle, connected, fully readable and writable TCP endpoint,
or an idle non-IPC pipe endpoint. Active listeners, bound pipe servers,
half-closed TCP sockets, IPC framing state, queued writes, pending connect or
shutdown requests, and native reads awaiting completion are rejected before
detachment. Windows may retain a native read after `read_stop`; stopping the
watcher alone does not make that handle transferable. Public handle userdata
must be nil. Destination code registers its own callbacks and userdata.

`stream_transfer_status` is a read-only preflight returning zero or a negative
native status. With `allow_reading = true`, it permits a stoppable read watcher
owned by a higher-level adapter, while still rejecting pending native reads and
all other unsupported state. The adapter must stop that watcher before calling
the actual hook.

Native payloads follow the
[shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules):
the caller delivers and adopts them exactly once and recovers the resource if
delivery or adoption fails. The source is already detached when encoding
returns. Copying a payload does not duplicate its descriptor, and discarding
one does not close it or invoke `from_transfer_payload`. That includes
`transfer.discard_message` and channel or receiver teardown, which
automatically release only packet-attached `thread.Sender` and `thread.Receiver`
endpoints.

The two explicit `discard_transfer_payload` methods close a known unadopted
native payload without a bound loop or Runtime and return the native close
status. The close attempt consumes ownership even if it returns an error; do
not adopt or discard that payload again. These are ordinary cleanup methods,
not additional hooks recognized by `TransferValue`.

## Coverage and deliberate omissions

The [coverage map](uv/coverage.md) accounts for all **319** native functions in
the pinned header: 305 canonical wrappers, nine unavailable
wrappers, and five native free functions performed internally after copying
public results. Libuv 1.53.0's new `uv_write_nwritten` query has no Titan wrapper
yet, and `cancel` continues to reject write requests. The separately documented
startup helper uses the generated
entrypoint's original argument storage; it is not an arbitrary `uv_setup_args`
wrapper. Type, field, callback, macro, and platform-constant mappings accompany
the function inventory. Coverage does not remove platform-specific native
limitations or make every operation appropriate inside a cooperative Task.

The **232** [supplemental declarations](uv/supplemental.md) include the direct
synchronization map, **12** external-wake helpers, and three heap-thread-token
helpers. None of them adds a distinct libuv C operation. Counts describe the
exported API inventory, not a claim that every operation has been executed on
every platform. The generated-code ABI is version **2** and the language-server
API is version **1**.
