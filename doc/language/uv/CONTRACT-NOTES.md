# Ownership and value contracts

Use ordinary `import "titan.uv"` to access these public types. The provider uses pinned, patched libuv 1.52.1. `has_api("tcp_connect")` queries the canonical exported wrapper set, without the `uv_` prefix; it does not promise OS/kernel support. Platform constants can be nil when the native platform omits them. The [coverage map](coverage.md) explains the unavailable wrappers and internal copied-result cleanup.

## Objects and native storage

| Public object | Allocation and initialization | Native ownership ends | Afterward |
| --- | --- | --- | --- |
| `loop_t` | Construct `loop_t()`, then `loop_init` | Successful `loop_close` | Titan storage is GC-managed; close must finish first |
| Concrete handle | Construct final owner, then its init/spawn operation | Native close callback finishes | Supported handle owners may initialize again; original loop association survives close, but a later initialization attempt can replace or clear it |
| `handle_t`, `stream_t`, `req_t` | Obtain a view from the concrete owner | Same lifetime as that owner | A view neither initializes nor duplicates native storage |
| One-shot request | Construct concrete request before submission | Its promised completion returns | Reuse is legal from its callback after old registration retires; FS also needs cleanup |
| `fs_t` result memory | Prepared by an FS call | `fs_req_cleanup` after terminal state | File descriptors and directories remain separately owned |
| `dir_t` | Produced by successful `fs_opendir` | Successful `fs_closedir` | Cancelled closedir leaves it open for retry |
| `addrinfo_result_t` | Produced by successful getaddrinfo | Explicit `freeaddrinfo` | Copied entries/strings/address values remain valid |
| CPU/interface/env/passwd/group snapshots | Binding copies native results | Matching native free runs before wrapper return | Caller owns ordinary GC-managed values; no public free operation |
| `thread_t` | Construct, then create/create_ex | Join succeeds, or permitted detach succeeds | Joined/detached identifiers may be reused; thread_self is a borrowed identity |
| Synchronization owner | Construct, then init/create | Explicit destroy/delete after all native users stop | Single native lifetime; constructor again for another lifetime |
| `lib_t` | Construct, then one dlopen attempt | Explicit dlclose, including failed native open | Terminal close; old symbols cannot become valid for a new image |
| `os_fd_t`, `os_sock_t`, integer descriptor | Borrowed identifier or result of an acquiring operation | Explicit corresponding resource close/adoption | Collecting a token never closes a native resource |

Stopped or unreferenced handles remain rooted until close completion. `loop_alive` can be false while `loop_close` remains busy. `walk` sees handles only, so absence from walk is not evidence that requests or descriptors have retired. Data getters/setters expose a separate traced `value`; native loop/handle/request `.data` belongs to the binding.

`process_t` is a handle. Exiting does not close it and closing does not kill a child. After native spawn handoff, even a negative status leaves a process owner requiring close and does not prove that no child started. Binding preflight failures occur before that close obligation. Process options retain the exit callback to exit. Native file/args/env/cwd/stdio preparation occurs before handoff. Array positions 1, 2, and 3 correspond to standard input, output, and error (native descriptors 0, 1, and 2).

CREATE_PIPE requires distinct eligible initialized pipes on the spawn loop. Successful pipe_init begins eligibility; mutating native pipe/stream operations and CREATE_PIPE spawn handoff consume it, including native failures. Binding preflight failures preserve it. Queries/views/data/ref/unref/buffer-size operations and borrowed send_handle/INHERIT_STREAM source uses preserve it. [Process policy](PROCESS-POLICY.md) lists the exact operations and documents the approved bundled Unix native repair and bundled-only dependency policy. The binding checks eligibility before handing the process and pipes to native spawn.

## Close obligations after partial poll initialization

Construct a fresh `poll_t` and obtain its `handle_t` view before calling `poll_init` or `poll_init_socket`. If initialization returns a negative status, `view:is_initialized()` distinguishes a native close obligation from untouched fresh storage. If it is initialized and `is_closing(view)` is false, call `close(view, nil)`. A dedicated top-level loop can then run to drain close completion; code inside a callback must return to its existing driver and must never reenter `run`.

`is_initialized()` is true during closing and false for fresh or retired storage. It reads the current owner lifetime. A user close callback may create a replacement lifetime on the same owner, so trailing cleanup from an older operation must not close whatever lifetime happens to exist later. The recipe above is for the caller-owned fresh initialization attempt, with cleanup decided before unrelated callback code can reuse the owner. Process failure cleanup follows the separate patched native policy in PROCESS-POLICY.md.

## Return channels, callbacks, and rejection

Most native status operations return zero on success and a negative error code on failure. Some operations return useful nonnegative results instead: FS synchronous calls can return a descriptor/count; try_write/try_send return bytes; try_send2 returns packets sent and may report partial progress. `run` returns libuv's activity report rather than an ordinary success status; its exact rule is below. Inspect each exact signature and native contract before interpreting a nonnegative result.

For accepted asynchronous one-shot work, the callback is the terminal result channel. A negative immediate submission result normally promises no callback and retires the just-created request root. Windows poll_init/poll_init_socket can also fail after native handle registration: the partial owner remains rooted and closeable, but poll_start rejects it. Use the direct owner-state query described below to distinguish this branch. Native exceptions to that general form remain explicit: legacy pipe_connect returns void and delivers errors in its callback; spawn can leave a handle requiring close after error. FS immediate rejection still needs explicit request cleanup after the binding has prepared a dirty request. Do not infer ownership solely from the sign of a return value.

For `run`, an uninitialized loop returns EINVAL. An initialized loop must be driven on the owning main Lua thread without reentry. `nil` selects RUN_DEFAULT, which drives until libuv reports no alive work or stop interrupts driving. RUN_ONCE performs at most one iteration and may block; RUN_NOWAIT performs at most one iteration without blocking for I/O. Zero is the native report that no alive work remains; nonzero is its report that alive work remains. This is not an error count. There is a native sampling edge: RUN_DEFAULT samples activity before its initial timer pass, so a timer calling stop can preserve that earlier nonzero report even when `loop_alive(loop)` now returns false. Query `loop_alive` for current activity; the binding preserves the native `run` return. A captured callback error raises after the native boundary returns instead of producing a numeric callback-error result.

A nil callback selects the native synchronous form for FS, getaddrinfo/getnameinfo and random where their signatures allow it. It is not a request to forget an accepted async callback. Ordinary callbacks use the owning main Lua state and ordinary callable adjustment. Binding-owned catches contain errors before returning through libuv, preserve the first error and trace, count later failures, and stop driving. The first error is rethrown after run returns from native code. Preservation starts with the caught Lua error; raised nil follows the ordinary [error normalization](../error-handling.md#raising-errors). `secondary_error_count()` describes additional failures captured during that boundary. Native ownership survives the exception and still needs explicit cleanup.

`walk` invokes callbacks synchronously. Windows TTY read_start and tty_set_mode can also invoke allocation/read callbacks inline. These calls isolate the originating loop's failure state and rethrow only after the native operation returns. The loop cannot be reentered from an inline native callback. Accepted native ownership remains intact even when that callback failed.

Persistent callbacks may rearm or stop their resources according to native semantics; stop does not close. Idle/prepare/check and fs_poll repeated start on an already active handle preserve the native no-op callback behavior. Signal oneshot becomes inactive after native delivery returns. Close completion retires the old registration before user code, so the same concrete owner may be initialized again where supported.

## Buffers and bytes

`buf_t.allocate(capacity)` returns writable owned bytes. `buf_t.from_string(text)` and `buf_init(text, length)` borrow immutable string bytes for input operations only. `slice(first, length)` creates an owner-retaining view, using 1-based indices and a byte count. `get`/`set` use 1-based indices; `set` accepts one byte (0 through 255). `to_string(length)` copies exactly that many bytes, including embedded NULs.

Read/receive/random destinations must be writable. Passing immutable string storage for native output is rejected before submission. Async vector operations snapshot descriptors and retain every underlying owner. Mutating the caller's Array after acceptance does not retarget the native request, but mutating borrowed byte contents before completion is still an application race. A result getter that copies bytes or records produces ordinary values surviving native cleanup.

Stream receive callbacks receive the actual count and an optional retained buffer. UDP receive distinguishes an empty datagram (nonnull peer, zero bytes) from a no-data notification. Truncated packets retain the PARTIAL flag. MMSG_CHUNK slices retain the original allocation; MMSG_FREE retires it. Native stop during a CHUNK can suppress FREE, so the binding retains the allocation until the next allocation or close. A saved slice retains its parent independently.

`udp_send` rejects an empty vector before registration. One zero-length `buf_t` is the supported empty-datagram representation. `udp_try_send` rejects an empty vector, and `udp_try_send2` rejects an empty outer batch. An empty inner vector in a nonempty try-send2 batch retains native platform behavior: Linux may send an empty datagram; Windows returns EINVAL for that packet.

Known IPv4/IPv6 addresses preserve all native fields, including IPv6 flow/scope. `sockaddr_t` accessors expose host integers or copied bytes without requiring a system sockaddr type. Callback addresses without an authoritative native size preserve unknown families as explicitly incomplete values; `is_complete()` is false, `byte_length()` is zero, and `raw_bytes()` is nil. Pointer-consuming operations reject incomplete values. Sized native getters and DNS results retain authoritative bytes.

## Cancellation and worker boundaries

Only FS, getaddrinfo, getnameinfo, random, and work requests support native `cancel`. Connect/write/shutdown/UDP-send do not become cancellable merely because they expose req_t. Successful cancellation still requires terminal completion, normally with ECANCELED. EBUSY means native work has already progressed too far; keep all owners until ordinary completion. Cancellation never closes a resource automatically.

Work, native-thread, and once callbacks are C-only entries. Their `foreign function` spelling uses portable structural C types and does not require a libuv header outside this module. These entries must never call Lua/Titan or inspect a Titan owner on a foreign thread. After-work callbacks are ordinary loop-thread callables. `queue_work` retains the request and caller-owned argument graph through after-work; provide that graph through its explicit trailing `argument_owner: value` parameter (nil means an externally owned borrow). Native thread creation uses argument_owner explicitly. Detach requires nil argument_owner and externally valid code/argument storage; a retained GC graph must join.

`work_t:get_loop()` preserves the last accepted loop through completion; a rejected submission preserves that previous association. `signal_t:get_signum()` reads the configured native signal number while initialized: stop resets it, while oneshot delivery resets it only after the callback returns.

Raw synchronization/async/thread helpers are escape hatches for already-C-only carriers. Obtain their opaque pointer/entry on the Lua thread, retain the corresponding owner through every native use, and coordinate completion before destroying it. A native-safe returned entry does not make the ordinary Titan wrapper safe to call from a worker.

## Units, ranges, nullable values, and defaults

| API/value | Public interpretation |
| --- | --- |
| timer timeout/repeat/due time; now; backend timeout; sleep | Milliseconds. timer_start requires nonnegative timeout/repeat. Repeat zero means one shot. backend_timeout may return -1 for indefinite wait. sleep blocks the calling thread. |
| hrtime; metrics_idle_time | Nanoseconds. hrtime has an arbitrary monotonic origin; use differences, not a wall-clock timestamp. |
| cond_timedwait | Relative nanosecond timeout, explicit unsigned long long channel; returns native timeout status. |
| uptime | Seconds as float. |
| timespec_t/timespec64_t | tv_sec seconds, tv_nsec nanoseconds. The 64 suffix preserves the native wider seconds contract. |
| timeval_t/timeval64_t | tv_sec seconds, tv_usec microseconds. |
| FS utime/futime/lutime | Floating seconds; FS_UTIME_NOW/OMIT retain native sentinel meaning where supported. |
| CPU times and CPU speed | user/nice/sys/idle/irq are milliseconds; speed is MHz. |
| Native memory queries, buffer lengths, stack_size | Bytes; counts/capacities are explicit and checked before native allocation/acceptance. |
| FS read/write offsets | Byte offset; native -1 uses and updates the descriptor's current offset. |
| Stat sizes and block values | st_size/st_blksize and statfs block sizes are bytes; other fields retain native counts/IDs/modes. Platform-specific unused values remain native outputs. |
| Socket port | Integer port 0–65535 through address constructors; zero requests native ephemeral binding where applicable. |
| TCP keepalive | Native idle/delay/interval seconds and count of probes. Enable values preserve native integer channel. |
| send_buffer_size/recv_buffer_size | Bytes; zero queries current value, positive value requests a new size; returned size follows native behavior. |
| thread/OS priority | Numeric levels, not bit flags; named levels remain integers because native APIs use int. |
| `run(loop, nil)` | Selects RUN_DEFAULT. RUN_ONCE and RUN_NOWAIT are distinct true-enum values. |
| `loop_configure(..., LOOP_BLOCK_SIGNAL, signum)` | Requires a signal value; the other options do not need signum. Native platform support remains explicit. |
| Optional callback | Selects synchronous operation only where that native API has such a form; see its exact contract. |
| Optional env/cwd in process options | nil inherits; an explicitly empty Array/string is distinct and follows native semantics. |
| Optional address in UDP operations | nil uses/disconnects a native connected peer according to the operation; it is not a wildcard destination. |
| Capacity-taking string utilities | Caller supplies native byte capacity. No hidden retry occurs; returned native required/actual length is preserved. NUL terminator rules differ by API. |
| Error `_r` helpers | Copy native bounded text; zero capacity gives the wrapper's bounded empty result, and truncation remains explicit through requested capacity. |

Checked narrowing to native int/unsigned/pointer-width inputs happens before accepting new native ownership. Native unsigned 64-bit output counters and stat words use the established signed Titan integer bit-pattern channel; a high-bit native value can appear negative without being a native negative-status return. Explicit native identifier tokens preserve full width. Avoid interpreting arbitrary negative data values as error status outside the documented status position.

The capacities/nullable return tuples in the exact API entries are intentional. For example, cwd/os_getenv return `(status, string?, native_length)` so ENOBUFS evidence is not hidden. exepath preserves native successful truncation behavior rather than converting it into an invented failure. Pinned utility flags and constants initialized by the module are immutable values; source-level `integer?` declarations do not imply omission. The separate platform constants (such as AF_UNIX, S_I* and SIG*) are explicitly nil only when the selected native platform does not define them; check those before use.
