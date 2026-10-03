# process API reference

Complete public example: [pipe_process](../examples/pipe_process.titan). See the
[example guide](../examples/README.md) for build/run commands and platform conditions.

Construct process_t and process_options_t before spawn. args/env/stdio arrays become native vectors only inside the binding. stdin/stdout/stderr indices correspond to Array positions 1/2/3. nil env/cwd means inherit. The exit callback reports exit status and terminating signal once; exit does not close the process handle. Spawn failure can leave an initialized process handle requiring close. Closing a process handle does not kill or reap a still-running child; retain the chosen process policy.

## disable_stdio_inheritance

`uv_disable_stdio_inheritance` — **canonical exported function**

Ask libuv to disable inherited stdio/handle inheritance where supported. Call before spawning; it is process-level policy, not a per-child options field.

```titan
function disable_stdio_inheritance()
```

**Result, lifetime and cleanup:** Return type: (). Synchronous process-wide descriptor inheritance policy change. It takes no process handle and creates no handle lifetime. Low-level uv import does not perform it automatically.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1840).


## kill

`uv_kill` — **canonical exported function**

Send signum to a native PID using platform process-signal semantics; no process handle is acquired.

```titan
function kill(pid: integer, signum: integer): integer
```

**Inputs and outputs:** pid: INPUT integer value; checked native narrowing occurs before native ownership is accepted.; signum: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Signals the process identified by pid synchronously, subject to native platform policy. Returns the native status. This takes no process_t owner and neither waits for the child nor closes any watcher.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1180).


## process_get_pid

`uv_process_get_pid` — **canonical exported function**

Read the PID associated with the process handle. A numeric PID is an identifier, not child or handle ownership.

```titan
function process_get_pid(process: process_t): integer
```

**Inputs and outputs:** process: INPUT/OUTPUT initialized process_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.

**Result, lifetime and cleanup:** Return type: integer. Requires an initialized process owner. Returns the stored native process identifier; the integer does not own, keep alive, signal, or reap the child.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1181).


## process_kill

`uv_process_kill` — **canonical exported function**

Send signum to the process represented by the handle. Signalling neither waits for exit nor closes the handle.

```titan
function process_kill(process: process_t, signum: integer): integer
```

**Inputs and outputs:** process: INPUT/OUTPUT initialized process_t owner/view; mutations preserve its single owner and reserved native data slot; close completion ends native handle lifetime.; signum: INPUT integer value; checked native narrowing occurs before native ownership is accepted.

**Result, lifetime and cleanup:** Return type: integer. Signals the process represented by an initialized process_t according to native platform policy. Returns the native status. Signalling neither waits for child exit nor releases the watcher close obligation.

**Callbacks:** none. no callback

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1179).


## spawn

`uv_spawn` — **canonical exported function**

Start a child process from process_options_t. After native handoff the process handle requires close on success or failure; the exit callback does not close it. See process and CREATE_PIPE ownership rules.

```titan
function spawn(loop: loop_t, process: process_t, options: process_options_t): integer
```

**Inputs and outputs:** loop: INPUT initialized owning loop; accepted handles/requests retain it through retirement.; process: INPUT/OUTPUT final process_t owner in fresh or retired state, before this native initialization; successful initialization establishes a close obligation. Follow the explicit rejection rule for this operation.; options: INPUT configuration record; file/args/env/cwd and stdio arrays are prepared before spawn, exit callback retained to exit, native stdio handles/descriptors follow their own lifetimes.

**Result, lifetime and cleanup:** Return type: integer. Process handles and exit callbacks retain loop/owner until close; close does not kill child. Process-global helpers have explicit application side effects. Options/argv/env/stdio consumed during submission, exit callback retained. Failed spawn can already register initialized process handle: close even after failure where native init occurred. Exit callback reports child status; close does not kill/reap child. Each CREATE_PIPE entry requires a distinct eligible initialized, nonclosing pipe on the spawn loop. All stdio entries and selected owners are validated before any pipe eligibility is consumed. Binding preflight rejection preserves every selected pipe. After native spawn handoff, every selected CREATE_PIPE owner remains ineligible even on native failure; INHERIT_STREAM does not consume source eligibility. Any native spawn attempt establishes the process close obligation, including negative results; an error does not prove that no child started. The bundled Unix libuv repair supports the required failure close. Titan uses only its pinned, patched libuv; no system-libuv path is supported. See PROCESS-POLICY.md.

**Callbacks:** deferred exit for an established process watcher, including after a late spawn error. the owning main Lua thread; timing is specified above

**Cancellation:** not applicable or unsupported by uv_cancel

**Availability:** Pinned patched libuv 1.52.1 only; native OS/kernel support and native error statuses still apply.

**Native declaration:** [pinned libuv](https://github.com/libuv/libuv/blob/v1.52.1/include/uv.h#L1176).

