# timer API reference

Complete public example: [timer_example](../examples/timer_example.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## Concrete timer data and close

```titan
function timer_get_data(timer: timer_t): value
function timer_set_data(timer: timer_t, data: value)
function timer_close(timer: timer_t, callback: timer_cb?)
```

These Titan convenience functions operate directly on the concrete timer, without
constructing a `handle_t` view. The data functions access the same traced public
slot as `handle_get_data` and `handle_set_data`; fresh owners contain nil, and
data remains accessible after close. Native `.data` remains reserved by UV.

`timer_close` has the same native lifetime, deferred callback timing, and errors
as `close`, but passes the original `timer_t` directly to its callback. A fresh
or retired timer raises `"handle is not initialized"`; a closing timer raises
`"handle is closing"`. The owner is retired before the callback and remains
rooted through callback return. The callback may reinitialize that same owner.
Callback errors are caught and rethrown by `run`, as for generic close. A nil
callback still closes and retires the timer. Generic `walk`/`close` remains valid
for timers using these accessors.

## timer_again

`uv_timer_again` — **canonical exported function**

Stop and rearm a previously started repeating timer using its repeat interval as the next delay. A timer that has never started returns EINVAL.

```titan
function timer_again(timer: timer_t): integer
```

**Inputs and outputs:** timer: INPUT/OUTPUT initialized timer_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Timeout/repeat in milliseconds; loop cached time affects timing; stop and one-shot firing do not close owner.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L982).


## timer_get_due_in

`uv_timer_get_due_in` — **canonical exported function**

Return milliseconds until the timer is due relative to the loop's cached time, or zero if due/expired.

```titan
function timer_get_due_in(timer: timer_t): integer
```

**Inputs and outputs:** timer: INPUT/OUTPUT initialized timer_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Timeout/repeat in milliseconds; loop cached time affects timing; stop and one-shot firing do not close owner.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L985).


## timer_get_repeat

`uv_timer_get_repeat` — **canonical exported function**

Return the configured repeat interval in milliseconds; zero denotes a one-shot timer.

```titan
function timer_get_repeat(timer: timer_t): integer
```

**Inputs and outputs:** timer: INPUT/OUTPUT initialized timer_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Timeout/repeat in milliseconds; loop cached time affects timing; stop and one-shot firing do not close owner.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L984).


## timer_init

`uv_timer_init` — **canonical exported function**

Initialize a timer owner on the loop. It is initially inactive but already requires close.

```titan
function timer_init(loop: loop_t, timer: timer_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; timer: INPUT/OUTPUT final timer_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. Starting event delivery is a separate operation; stopping later never replaces close. A rejected initialization establishes no new native lifetime.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L976).


## timer_set_repeat

`uv_timer_set_repeat` — **canonical exported function**

Set the repeat interval in milliseconds. Changing it inside a callback does not retroactively reschedule the next timeout already chosen by native timer processing.

```titan
function timer_set_repeat(timer: timer_t, repeat_ms: integer)
```

**Inputs and outputs:** timer: INPUT/OUTPUT initialized timer_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; repeat_ms: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: (). Timeout/repeat in milliseconds; loop cached time affects timing; stop and one-shot firing do not close owner.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L983).


## timer_start

`uv_timer_start` — **canonical exported function**

Start or update a timer. `timeout` and `repeat_ms` are nonnegative milliseconds; repeat zero is one shot, and timeout zero schedules a later loop iteration. This does not refresh the loop's cached time.

```titan
function timer_start(timer: timer_t, callback: function (timer_t): (), timeout: integer, repeat_ms: integer): integer
```

**Inputs and outputs:** timer: INPUT/OUTPUT initialized timer_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; callback: INPUT ordinary callable, retained until the promised callback interval ends; callback argument owners are borrowed views retained through callback return.; timeout: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; repeat_ms: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Timeout/repeat in milliseconds; loop cached time affects timing; stop and one-shot firing do not close owner. timeout/repeat milliseconds; repeat 0 one-shot. Timer callback can stop/rearm; stop does not close owner. Timeout zero is future loop iteration, not inline.

**Callbacks:** once-or-persistent. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L977).


## timer_stop

`uv_timer_stop` — **canonical exported function**

Stop future timer firings. The initialized timer remains owned and can be restarted or closed.

```titan
function timer_stop(timer: timer_t): integer
```

**Inputs and outputs:** timer: INPUT/OUTPUT initialized timer_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Timeout/repeat in milliseconds; loop cached time affects timing; stop and one-shot firing do not close owner.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L981).
