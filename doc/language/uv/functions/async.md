# async API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## async_init

`uv_async_init` — **canonical exported function**

Initialize and activate a native async notification handle. A nil callback is permitted. Close it even if no notification is ever sent.

```titan
function async_init(loop: loop_t, handle: async_t, callback: (function (async_t): ())?): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final async_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return. Optional nil is meaningful; see contract.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Success also starts the native async handle; notifications coalesce. A nil callback is allowed. Ordinary Titan async_send still runs on the Lua thread; foreign carriers use the explicit native-safe entry. A rejected initialization establishes no new native lifetime.

**Callbacks:** persistent-coalesced. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L976).


## async_send

`uv_async_send` — **canonical exported function**

Notify the loop through an initialized async handle. Multiple sends may coalesce. This Titan wrapper runs on the Lua thread; foreign threads use the separately obtained C-only `async_send_function()` entry.

```titan
function async_send(handle: async_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized async_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Native thread-safe send must be separated from ordinary Titan execution; callback coalesced on loop thread; handle active until close. May be invoked natively from another thread/signal handler; supplied Titan wrapper is ordinary Lua-thread code. Requires live initialized async storage through send and delivery.

**Callbacks:** coalesced-later. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L979).

