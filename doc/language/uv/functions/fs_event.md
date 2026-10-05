# fs_event API reference

Complete public example: [fs_watch](../examples/fs_watch.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## fs_event_getpath

`uv_fs_event_getpath` — **canonical exported function**

Return `(status, copied_path?, native_length)` for the watched path using the supplied byte capacity. No hidden buffer-growth retry occurs.

```titan
function fs_event_getpath(handle: fs_event_t, capacity: integer): (integer, string?, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized fs_event_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; capacity: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (integer, string?, integer). Requires an initialized watcher. capacity allocates temporary bytes internally. Success returns 0, a copied path string, and native output size; failure returns status, nil, and native size output. Retaining the copy after stop/close is valid.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1792).


## fs_event_init

`uv_fs_event_init` — **canonical exported function**

Initialize a fs_event_t owner on the loop. It needs close even if a later start is rejected.

```titan
function fs_event_init(loop: loop_t, handle: fs_event_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final fs_event_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Starting event delivery is a separate operation; stopping later never replaces close. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1786).


## fs_event_start

`uv_fs_event_start` — **canonical exported function**

Watch path for native change/rename events. Callback filename can be nil and events are best effort; backend readiness and granularity remain platform-specific.

```titan
function fs_event_start(handle: fs_event_t, callback: function (fs_event_t, string?, integer, integer): (), path: string, flags: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized fs_event_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; path: INPUT immutable text/byte owner; native C-string conventions apply where the operation takes text. The binding retains or copies bytes for accepted asynchronous uses; synchronous borrows end on return.; flags: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Initialized watcher rooted until close; start retains path and callback as required; public filename is copied and nullable; stop does not close. A null native filename becomes nil; otherwise the binding copies it into an ordinary Titan string before the callback. Retaining that string after callback return is valid. Events are combinable RENAME/CHANGE flags; stop preserves handle owner until close.

**Callbacks:** persistent-event. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1787).


## fs_event_stop

`uv_fs_event_stop` — **canonical exported function**

Stop this filesystem notification source without closing its native handle.

```titan
function fs_event_stop(handle: fs_event_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized fs_event_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Initialized watcher rooted until close; start retains path and callback as required; public filename is copied and nullable; stop does not close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L1791).

