# idle API reference

Complete public example: [loop_phases](../examples/loop_phases.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## idle_init

`uv_idle_init` — **canonical exported function**

Initialize a idle owner on the loop. Starting callback delivery is separate; successful initialization already requires close.

```titan
function idle_init(loop: loop_t, handle: idle_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final idle_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Starting event delivery is a separate operation; stopping later never replaces close. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L950).


## idle_start

`uv_idle_start` — **canonical exported function**

Start a persistent callback on each loop iteration while preventing the poll from sleeping. Repeated start on an already active owner preserves native no-op callback behavior.

```titan
function idle_start(handle: idle_t, callback: function (idle_t): ()): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized idle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.

**Result, lifetime and cleanup:** Return type: integer. Loop-thread callback each iteration, prevents blocking; never a separate worker. Callback runs on loop thread each eligible phase; may stop/rearm. Idle active prevents blocking poll, not a background worker; stop never retires initialized owner.

**Callbacks:** persistent-phase. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L951).


## idle_stop

`uv_idle_stop` — **canonical exported function**

Stop the idle callback without closing the native handle.

```titan
function idle_stop(handle: idle_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized idle_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Loop-thread callback each iteration, prevents blocking; never a separate worker.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L952).

