# signal API reference

Complete public example: [signal_poll_tty](../examples/signal_poll_tty.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## signal_init

`uv_signal_init` — **canonical exported function**

Initialize a signal watcher. Call a start operation to select the signal and begin delivery.

```titan
function signal_init(loop: loop_t, handle: signal_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final signal_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Starting event delivery is a separate operation; stopping later never replaces close. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1727).


## signal_start

`uv_signal_start` — **canonical exported function**

Watch `signum` repeatedly. Signal callbacks run on the owning loop thread, not in the native signal handler.

```titan
function signal_start(handle: signal_t, callback: function (signal_t, integer): (), signum: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized signal_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; signum: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Native signal delivered as ordinary loop callback; platform restrictions remain explicit; handle close separate from stop. Callback loop thread; signal may coalesce; native OS signal delivery does not enter Titan directly. Platform signal restrictions remain native statuses.

**Callbacks:** persistent-signal. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1728).


## signal_start_oneshot

`uv_signal_start_oneshot` — **canonical exported function**

Watch for one delivery of `signum`; native delivery makes the watcher inactive afterward. Inactivity does not close it.

```titan
function signal_start_oneshot(handle: signal_t, callback: function (signal_t, integer): (), signum: integer): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized signal_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; signum: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Native signal delivered as ordinary loop callback; platform restrictions remain explicit; handle close separate from stop. One delivered signal callback then inactive; owner still requires close. Version included in supported floor.

**Callbacks:** deferred-one-signal. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1731).


## signal_stop

`uv_signal_stop` — **canonical exported function**

Stop signal delivery and reset the native configured signal number. The handle still requires close.

```titan
function signal_stop(handle: signal_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized signal_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Native signal delivered as ordinary loop callback; platform restrictions remain explicit; handle close separate from stop.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1734).

