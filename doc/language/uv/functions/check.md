# check API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## check_init

`uv_check_init` — **canonical exported function**

Initialize a check owner on the loop. Starting callback delivery is separate; successful initialization already requires close.

```titan
function check_init(loop: loop_t, handle: check_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final check_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Starting event delivery is a separate operation; stopping later never replaces close. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L956).


## check_start

`uv_check_start` — **canonical exported function**

Start a persistent callback after polling for I/O. Repeated start on an already active owner preserves native no-op callback behavior.

```titan
function check_start(handle: check_t, callback: function (check_t): ()): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized check_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: integer. After poll callback, loop thread; stopped handle remains rooted until close. Callback runs on loop thread each eligible phase; may stop/rearm. Idle active prevents blocking poll, not a background worker; stop never retires initialized owner.

**Callbacks:** persistent-phase. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L957).


## check_stop

`uv_check_stop` — **canonical exported function**

Stop the check callback without closing the native handle.

```titan
function check_stop(handle: check_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized check_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. After poll callback, loop thread; stopped handle remains rooted until close.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L958).

