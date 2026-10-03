# loop API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

loop_t owns stable packed native loop storage and explicit loop_init/loop_close. Only the owning main Lua thread drives it; run is nonreentrant. loop_alive is not a resource inventory: inactive/unreferenced handles still need close and may keep loop_close busy. walk is synchronous and sees handles, not requests or plain descriptors. Callback failure preserves first error/trace, retires obligatory bookkeeping, stops native driving, then rethrows after the native boundary returns.

## backend_fd

`uv_backend_fd` — **canonical exported function**

Return a borrowed backend polling descriptor, or native -1 when unavailable. Do not close it; the loop owns it.

```titan
function backend_fd(loop: loop_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop; otherwise raises. Returns the native backend descriptor or native -1 when unavailable. This is a borrowed descriptor; no close ownership is transferred.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L320).


## backend_timeout

`uv_backend_timeout` — **canonical exported function**

Return the next backend polling timeout in milliseconds; -1 means an indefinite wait. This call does not drive the loop.

```titan
function backend_timeout(loop: loop_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop; otherwise raises. Returns the native backend wait timeout in milliseconds, including -1 for an indefinite wait. It does not drive the loop or change ownership.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L321).


## default_loop

`uv_default_loop` — **not exported**

This native function has no direct public wrapper.

**Result, lifetime and cleanup:** Process-global loop and its reserved data slot cannot be independently owned by multiple Lua states. Construct loop_t and call loop_init explicitly; do not claim replacement default-loop semantics. Process-global loop and its reserved data slot cannot be independently owned by multiple Lua states. Construct loop_t and call loop_init explicitly; do not claim replacement default-loop semantics.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L290).

## loop_alive

`uv_loop_alive` — **canonical exported function**

Report whether the initialized loop currently has referenced active handles, active requests, or closing handles. This is a boolean snapshot, not proof that all native resources are retired.

```titan
function loop_alive(loop: loop_t): boolean
```

**Inputs and outputs:** loop: INPUT allocated loop owner; this operation also accepts fresh or successfully closed storage; see its exact result contract.

**Result, lifetime and cleanup:** Return type: boolean. Accepts any allocated loop owner. Returns false before loop_init or after successful loop_close. For an initialized loop, reports current native active referenced handles, accepted requests, pending callbacks and closing activity. False is not permission to skip close: stopped/unreferenced initialized handles can still make loop_close return EBUSY.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L306).


## loop_close

`uv_loop_close` — **canonical exported function**

Retire an initialized loop. Returns EBUSY while handles, requests, driving, or inline callbacks still own it; a stopped loop is not necessarily closeable.

```titan
function loop_close(loop: loop_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop; otherwise returns EINVAL. Returns EBUSY while the loop is being driven, walked, or used for inline dispatch, or while any initialized handle or accepted request remains rooted. Native success retires the loop and permits a later loop_init on the same owner. Public data remains accessible after close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L292).


## loop_configure

`uv_loop_configure` — **canonical exported function**

Apply a loop option before the work that depends on it. `LOOP_BLOCK_SIGNAL` takes `signum`; idle-time metrics must be enabled before they are collected. Unsupported options return native status.

```titan
function loop_configure(loop: loop_t, option: loop_option, signum: integer?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; option: INPUT loop_option value; checked native narrowing occurs before native ownership is accepted.; signum: INPUT integer? value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop. The typed loop_option replaces native variadic arguments. block_signal requires a nonnil signum; other options ignore signum. Returns the native configuration status, preserving platform support. Call before run as required by the selected native option; no resource ownership is transferred.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L307).


## loop_fork

`uv_loop_fork` — **canonical exported function**

Reinitialize the loop backend in a child after a native fork. This does not fork the process or make inherited application resources safe automatically.

```titan
function loop_fork(loop: loop_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop; otherwise returns EINVAL. Repairs native loop state in a forked child according to libuv's platform support. It does not create or initialize a separate loop owner.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L308).


## loop_get_data

`uv_loop_get_data` — **canonical exported function**

Return the separate traced Titan userdata value, initially nil. The binding's native `.data` slot remains reserved and is not exposed.

```titan
function loop_get_data(loop: loop_t): value
```

**Inputs and outputs:** loop: INPUT allocated loop owner; this operation also accepts fresh or successfully closed storage; see its exact result contract.

**Result, lifetime and cleanup:** Return type: value. Accepts any allocated loop owner before initialization, while initialized, and after successful close. Returns its separate traced public value; initial value is nil. Does not access native loop data or initialize/retain a native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1958).


## loop_init

`uv_loop_init` — **canonical exported function**

Initialize a caller-constructed loop owner. Success begins an explicit loop lifetime; call `loop_close` after every handle and request has retired.

```titan
function loop_init(loop: loop_t): integer
```

**Inputs and outputs:** loop: INPUT/OUTPUT final loop_t() storage in fresh or successfully closed state; native loop is not currently initialized.

**Result, lifetime and cleanup:** Return type: integer. Requires an allocated loop_t whose native loop is not currently initialized: a fresh owner or one successfully closed. Returns EBUSY without reinitializing a live loop. Native success establishes the loop lifetime and requires eventual loop_close; native failure establishes no loop lifetime. Public traced data is preserved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L291).


## loop_set_data

`uv_loop_set_data` — **canonical exported function**

Replace the separate traced Titan userdata value; nil clears it. This does not change native lifetime or overwrite the binding's reserved `.data` pointer.

```titan
function loop_set_data(loop: loop_t, data: value)
```

**Inputs and outputs:** loop: INPUT allocated loop owner; this operation also accepts fresh or successfully closed storage; see its exact result contract.; data: INPUT traced public data, stored separately from reserved native .data; nil clears the value.

**Result, lifetime and cleanup:** Return type: (). Accepts any allocated loop owner before initialization, while initialized, and after successful close. Replaces its separate traced public value, including nil. Native loop .data remains reserved for the binding; no native initialization or cleanup is required by this call.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1959).


## loop_size

`uv_loop_size` — **canonical exported function**

Return the native loop storage size in bytes. Construct `loop_t()` for storage; this query does not allocate or initialize a loop.

```titan
function loop_size(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Takes no loop owner and requires no initialized loop. Returns the native uv_loop_t storage size in bytes for this provider. Use loop_t() to allocate an owner; this query does not allocate or initialize storage.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L305).


## now

`uv_now` — **canonical exported function**

Read the loop's cached monotonic time in milliseconds. It changes when the loop updates its time, not on every query.

```titan
function now(loop: loop_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop; otherwise raises. Returns the loop's cached monotonic time in milliseconds; update_time refreshes the cache. This is a time value, not a status code.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L318).


## run

`uv_run` — **canonical exported function**

Drive the loop in DEFAULT, ONCE, or NOWAIT mode. The integer result describes remaining native liveness, not an error count; captured callback exceptions are rethrown after native driving returns.

```titan
function run(loop: loop_t, mode: run_mode?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; mode: INPUT run_mode? value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. An uninitialized loop returns EINVAL without native driving. For an initialized loop, execution requires the owning main Lua thread and forbids reentry from run, walk or inline native callbacks; violations raise. nil selects RUN_DEFAULT. RUN_DEFAULT drives until libuv reports no alive work or stop interrupts driving. RUN_ONCE performs at most one iteration and may block waiting for activity; RUN_NOWAIT performs at most one iteration without blocking for I/O. The integer is libuv's alive-work report, not a success/error count: zero reports no remaining alive work; nonzero reports remaining alive work. A pinned-native edge matters: RUN_DEFAULT samples activity before its initial timer pass, so a timer that calls stop can preserve that earlier nonzero report even if loop_alive now returns false. Use loop_alive to query current activity; the binding does not normalize the native return. A captured callback error is raised with its saved trace after the native boundary returns, instead of being converted into a numeric error result. Remaining native ownership still needs explicit cleanup.

**Callbacks:** drives-callbacks. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L310).


## stop

`uv_stop` — **canonical exported function**

Request that the current or next run call stop as soon as possible. This neither closes handles nor cancels requests.

```titan
function stop(loop: loop_t)
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: (). Requires an initialized loop; otherwise raises. Requests that the current or next run stop as soon as native iteration permits. Later callbacks in the current iteration may still occur. It neither closes handles nor cancels requests.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L311).


## update_time

`uv_update_time` — **canonical exported function**

Refresh the loop's cached monotonic time. Use after a long callback when subsequent relative timer calculations need a fresh value.

```titan
function update_time(loop: loop_t)
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.

**Result, lifetime and cleanup:** Return type: (). Requires an initialized loop; otherwise raises. Refreshes the loop's cached native time without driving callbacks.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L317).


## walk

`uv_walk` — **canonical exported function**

Invoke a callback synchronously for every native handle on the loop, passing the supplied Titan `arg` value. It does not enumerate requests, bare descriptors, or child-process ownership.

```titan
function walk(loop: loop_t, callback: function (handle_t, value): (), arg: value)
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; arg: INPUT traced callback argument retained through the synchronous walk boundary.

**Result, lifetime and cleanup:** Return type: (). Requires caller-owned final loop storage initialized with loop_init; no Lua state sharing or reentrant driver; loop stays alive through every initialized handle/accepted request. walk calls supplied callable synchronously, once per discovered handle; binding must contain errors and rethrow only after native walk returns. Requests/descriptors are absent.

**Callbacks:** sync-per-handle. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L498).

