# handle API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

Every concrete handle retains its owning loop through close completion. stop/unref do not release native lifetime. close schedules one close callback, after which reinitialization is allowed for supported handle owners. User data is a traced Titan value distinct from reserved native .data. Base views never create a second native owner.

## close

`uv_close` — **canonical exported function**

Begin asynchronous handle close. The optional callback runs after native close retirement; stopping, unreferencing, or collecting a view does not replace this operation.

```titan
function close(handle: handle_t, callback: (function (handle_t): ())?)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: (). Requires an initialized concrete handle that is not already closing; fresh, retired and already-closing owners raise. Schedules native close and retains the owner through retirement. The binding always installs its own retirement callback, even when the public callback is nil. Old registration is retired before user close code runs, so that code may initialize a supported owner again. Pending operation callbacks may still complete or report cancellation before retirement.

**Callbacks:** deferred-once. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L504).


## fileno

`uv_fileno` — **canonical exported function**

Return `(status, descriptor?)` for an initialized handle with a native descriptor. The descriptor is borrowed from the handle; the query does not transfer close ownership.

```titan
function fileno(handle: handle_t): (integer, os_fd_t?)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (integer, os_fd_t?). Accepts an allocated concrete handle view. Fresh or retired storage returns EINVAL, nil; initialized storage is passed to native fileno, which decides supported handle kinds, descriptor availability and its native status. Success returns status plus an exact-width borrowed os_fd_t token. The token neither owns nor duplicates the descriptor and becomes stale when the underlying resource closes; collecting it never closes that resource.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L509).


## handle_get_data

`uv_handle_get_data` — **canonical exported function**

Return the separate traced Titan userdata value, initially nil. The binding's native `.data` slot remains reserved and is not exposed.

```titan
function handle_get_data(handle: handle_t): value
```

**Inputs and outputs:** handle: INPUT/OUTPUT allocated concrete owner/view in any lifetime state; traced public data does not require initialized native storage.

**Result, lifetime and cleanup:** Return type: value. Accepts an owner-retaining handle_t view of an allocated concrete owner in fresh, initialized, closing or retired state. Returns its separate traced public value, initially nil; native initialization is not required.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L486).


## handle_get_loop

`uv_handle_get_loop` — **canonical exported function**

Return the owning loop association. This is a retained owner reference, not a new loop.

```titan
function handle_get_loop(handle: handle_t): loop_t
```

**Inputs and outputs:** handle: INPUT owner/view with an established nonnil loop association; close preserves it, but a later initialization attempt can replace or clear it even on failure.

**Result, lifetime and cleanup:** Return type: loop_t. Requires an allocated concrete owner with an established nonnil loop association. Returns that associated loop while initialized, closing, during the user close callback, and after retirement. A fresh owner with no association raises. Close retirement preserves the association, but a later initialization attempt can replace or clear it even if that attempt fails; do not assume the prior loop survives a rejected reinitialization.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L487).


## handle_get_type

`uv_handle_get_type` — **canonical exported function**

Return the tagged native handle/request kind. This does not initialize, submit, or complete an operation.

```titan
function handle_get_type(handle: handle_t): handle_type
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: handle_type. Requires a currently initialized concrete handle lifetime, including closing; fresh or retired storage raises. Returns the native handle kind as handle_type. No resource is acquired and no second owner is created.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L484).


## handle_set_data

`uv_handle_set_data` — **canonical exported function**

Replace the separate traced Titan userdata value; nil clears it. This does not change native lifetime or overwrite the binding's reserved `.data` pointer.

```titan
function handle_set_data(handle: handle_t, data: value)
```

**Inputs and outputs:** handle: INPUT/OUTPUT allocated concrete owner/view in any lifetime state; traced public data does not require initialized native storage.; data: INPUT traced public data, stored separately from reserved native .data; nil clears the value.

**Result, lifetime and cleanup:** Return type: (). Accepts an owner-retaining handle_t view of an allocated concrete owner in fresh, initialized, closing or retired state. Replaces its separate traced public value, including nil. It does not touch the reserved native .data slot or change the native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L488).


## handle_size

`uv_handle_size` — **canonical exported function**

Return the native byte-size query for the selected kind. Use a concrete Titan constructor to allocate actual owner storage.

```titan
function handle_size(kind: handle_type): integer
```

**Inputs and outputs:** kind: INPUT handle_type value.

**Result, lifetime and cleanup:** Return type: integer. Takes a handle_type value, not a handle owner; no initialized handle is required. Returns the native byte-size result for that kind, including the native unsupported-kind size result. It does not allocate or initialize storage; construct the concrete public owner for allocation.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L483).


## handle_type_name

`uv_handle_type_name` — **canonical exported function**

Return the native name for a kind, or nil when no name is available. The result is a copied Titan string.

```titan
function handle_type_name(kind: handle_type): string?
```

**Inputs and outputs:** kind: INPUT handle_type value.

**Result, lifetime and cleanup:** Return type: string?. Takes a handle_type value, not a handle owner; no initialized handle is required. Returns a copied native kind name or nil when native lookup has no name. No native allocation is exposed.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L485).


## has_ref

`uv_has_ref` — **canonical exported function**

Report whether this handle currently counts toward keeping the loop alive.

```titan
function has_ref(handle: handle_t): boolean
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: boolean. Requires a currently initialized concrete handle lifetime, including closing; fresh or retired storage raises. Returns the native reference-state predicate; false does not mean the owner can be collected or that close has completed.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L315).


## is_active

`uv_is_active` — **canonical exported function**

Report whether this handle currently has active native work. Active and referenced are separate properties.

```titan
function is_active(handle: handle_t): boolean
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: boolean. Requires a currently initialized concrete handle lifetime, including closing; fresh or retired storage raises. Returns the native active-state predicate; an inactive handle remains initialized and must still close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L496).


## is_closing

`uv_is_closing` — **canonical exported function**

Report whether close has begun for this handle. It does not wait for its close callback.

```titan
function is_closing(handle: handle_t): boolean
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: boolean. Requires a currently initialized concrete handle lifetime, including closing; fresh or retired storage raises. Returns whether native close has begun for this lifetime. After the user close callback starts, the old lifetime is retired and this query raises; use handle_t:is_initialized() before querying current closing state.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L584).


## recv_buffer_size

`uv_recv_buffer_size` — **canonical exported function**

Query or request the native socket buffer size in bytes. `size == 0` queries, a positive size requests a change; return `(status, actual_size)` because the OS may adjust the requested amount.

```titan
function recv_buffer_size(handle: handle_t, size: integer): (integer, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; size: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, integer). Requires a currently initialized concrete handle. size 0 queries its socket receive-buffer size; a positive size requests a new size. Returns status and the native size output. The scalar result creates no ownership obligation; platform buffer-size behavior is preserved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L507).


## ref

`uv_ref` — **canonical exported function**

Make this handle count toward loop liveness. Repeated calls do not add a reference count.

```titan
function ref(handle: handle_t)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (). Requires a currently initialized concrete handle lifetime, including closing; fresh or retired storage raises. Marks the handle referenced. Repeating ref is idempotent; reference state affects loop liveness, not ownership or the close obligation.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L313).


## send_buffer_size

`uv_send_buffer_size` — **canonical exported function**

Query or request the native socket buffer size in bytes. `size == 0` queries, a positive size requests a change; return `(status, actual_size)` because the OS may adjust the requested amount.

```titan
function send_buffer_size(handle: handle_t, size: integer): (integer, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; size: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, integer). Requires a currently initialized concrete handle. size 0 queries its socket send-buffer size; a positive size requests a new size. Returns status and the native size output. The scalar result creates no ownership obligation; platform buffer-size behavior is preserved.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L506).


## unref

`uv_unref` — **canonical exported function**

Exclude this handle from the loop's active-reference liveness test. Native storage and callback ownership remain live until close.

```titan
function unref(handle: handle_t)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized handle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (). Requires a currently initialized concrete handle lifetime, including closing; fresh or retired storage raises. Marks the handle unreferenced. Repeating unref is idempotent; the initialized owner stays rooted and still requires close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L314).

