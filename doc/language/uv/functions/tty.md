# tty API reference

Complete public example: [signal_poll_tty](../examples/signal_poll_tty.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

The signatures use ordinary public `titan.uv` types. Read the [ownership contracts](../CONTRACT-NOTES.md) before submitting native work. Status values and callback results remain distinct.

## tty_get_vterm_state

`uv_tty_get_vterm_state` — **canonical exported function**

Return `(status, virtual_terminal_state?)` where supported.

```titan
function tty_get_vterm_state(): (integer, tty_vtermstate_t?)
```

**Result, lifetime and cleanup:** Return type: (integer, tty_vtermstate_t?). Synchronous process-wide Windows virtual-terminal capability query. No TTY handle is needed. Returns status and a typed state on success, or nil on native failure; an unknown native state raises.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L860).


## tty_get_winsize

`uv_tty_get_winsize` — **canonical exported function**

Return `(status, width, height)` in character cells.

```titan
function tty_get_winsize(handle: tty_t): (integer, integer, integer)
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tty_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: (integer, integer, integer). Requires initialized TTY handle; init adopts platform descriptor behavior and mode policies; fields/output sizes native. Avoid assuming Unix fd representation on Windows.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L858).


## tty_init

`uv_tty_init` — **canonical exported function**

Initialize a terminal owner from a descriptor. The final integer is the native legacy/unused argument; later mode operations use the typed mode enum.

```titan
function tty_init(loop: loop_t, handle: tty_t, fd: integer, unused: integer): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; handle: INPUT/OUTPUT final tty_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; fd: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; unused: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized loop and a concrete owner in fresh or retired state; an uninitialized loop or currently initialized/closing handle returns EINVAL. Successful initialization establishes the native lifetime and close obligation, even if no event is ever started. The descriptor and unused native parameter are passed with checked widths. Descriptor handling follows native platform rules; do not assume native Windows handles are Unix integers. Native rejection in the pinned implementation leaves no close obligation.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L855).


## tty_reset_mode

`uv_tty_reset_mode` — **canonical exported function**

Restore terminal mode changed through libuv. This is a synchronous process-level terminal action, not handle close.

```titan
function tty_reset_mode(): integer
```

**Result, lifetime and cleanup:** Return type: integer. Synchronous process-wide restoration of changed terminal modes; no TTY handle is needed. Returns the native status. Native signal-safety claims do not make the ordinary Titan wrapper callable from a signal handler.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L857).


## tty_set_mode

`uv_tty_set_mode` — **canonical exported function**

Set the terminal input mode. Windows can invoke alloc/read callbacks inline during this operation; callback errors are rethrown only after native return.

```titan
function tty_set_mode(handle: tty_t, mode: tty_mode_t): integer
```

**Inputs and outputs:** handle: INPUT/OUTPUT initialized tty_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; mode: INPUT tty_mode_t value.

**Result, lifetime and cleanup:** Return type: integer. Requires initialized TTY handle; init adopts platform descriptor behavior and mode policies; fields/output sizes native. Avoid assuming Unix fd representation on Windows. Windows synchronous TTY callbacks require the main Lua thread, disallow uv.run and uv.loop_close reentry (uv.close(handle) remains allowed), isolate original-loop first-error state, and rethrow after native return while preserving accepted ownership.

**Callbacks:** none; Windows TTY allocation/read callbacks can occur inline before return. owning main Lua thread; immediate inline failures rethrow only after native call returns; no run reentry

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L856).


## tty_set_vterm_state

`uv_tty_set_vterm_state` — **canonical exported function**

Set libuv's virtual-terminal support state using the tagged state value.

```titan
function tty_set_vterm_state(state: tty_vtermstate_t)
```

**Inputs and outputs:** state: INPUT tty_vtermstate_t value.

**Result, lifetime and cleanup:** Return type: (). Synchronous process-wide Windows virtual-terminal capability update. Takes a typed state and no TTY handle. It creates no handle or cleanup obligation.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.53.0 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.53.0/include/uv.h#L859).

