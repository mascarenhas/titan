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
C-only worker/thread entries and raw synchronization helpers have their own
[contracts](uv/CONTRACT-NOTES.md#cancellation-and-worker-boundaries).

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
cover owner methods and Titan-specific helpers, including
`setup_process_args()`.

| Family | Operations |
| --- | --- |
| [Loops](uv/functions/loop.md) | Construction, driving, time, backend queries, configuration, and handle walks. |
| [Handles](uv/functions/handle.md) | Close, active/reference state, public data, loop/type views, and socket buffer sizes. |
| [Requests](uv/functions/request.md) | Cancellation, public data, kind/size queries, and request views. |
| [Timers](uv/functions/timer.md) | One-shot and repeating callback timers, stop/rearm, repeat/due-time queries. |
| [Prepare](uv/functions/prepare.md), [check](uv/functions/check.md), [idle](uv/functions/idle.md) | Callbacks around the loop's polling phase. |
| [Async notifications](uv/functions/async.md) | Coalesced native-to-loop notifications and the C-only send entry. |
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
| [Threads and synchronization](uv/functions/threading.md) | Native threads, join/detach, affinity, locks, conditions, semaphores, and once. |
| [Dynamic libraries](uv/functions/dll.md) | Open, symbol lookup, error text, and explicit close. |
| [System utilities](uv/functions/misc.md) | Environment, paths, identity, memory, clocks, randomness, addresses, and encoding. |
| [Metrics](uv/functions/metrics.md) | Loop activity and idle-time measurements. |
| [Errors](uv/functions/errors.md), [version](uv/functions/version.md) | Error-domain conversion, text, and bundled native version. |
| [Legacy allocation helpers](uv/functions/undocumented.md) | Why native heap loop allocation/deletion is not exported. |

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
