# Titan libuv async I/O standard library

Status: reviewed design and implementation plan. No production library code has
been implemented. The design below is based on the current `master` checkout,
the sketch in `/tmp/uv-io.md`, the implemented `coro` module, focused Titan and
libuv prototypes, and the public libuv 1.x contracts.

## Executive decision

The sketch is feasible, but its callback, rooting, scheduler, and shutdown
contracts need to be made explicit before implementation.

Keep the proposed four layers:

1. Public libuv calls through Titan's C FFI.
2. A small C shim for the fixed libuv callback ABIs and operations that cannot
   be expressed safely in Titan alone.
3. A coroutine scheduler that turns callbacks into resumptions.
4. Synchronous-looking `fs`, `net`, `os`, and `timer` modules.

Use these concrete decisions for v1:

- Standard-library module names are namespaced as `titan.uv`, `titan.timer`,
  `titan.fs`, `titan.net`, and `titan.os`. Root names such as `os`, `math`, and
  `string` collide with Lua libraries already installed by `luaL_openlibs`.
- `titan.uv` owns one private `uv_loop_t` per active `run`, not
  `uv_default_loop()`.
- `run` must be invoked on the main Lua thread and nested `run` calls are
  rejected.
- Each scheduled task owns a fresh, private identity-valued coroutine tag.
  There is no guessable shared string tag.
- A task yields an internal request to the scheduler. The scheduler, running on
  the main Lua state, allocates and roots the libuv operation, submits it, and
  checks immediate submission failure.
- Libuv callbacks enter one fixed module-local Titan dispatcher through the
  native Titan function pointer, following `titan_coro_entry`; they do not use
  the generated Lua entry wrapper.
- The native dispatcher only records completion and enqueues a wakeup. The
  scheduler resumes or errors coroutines after `uv_run` returns, so user code
  does not run inside an arbitrary libuv callback.
- Every native dispatcher arm has a catch-all. No Lua/Titan longjmp may cross a
  libuv frame.
- Lua userdata allocated from Titan owns loop, request, handle, and fixed-buffer
  storage wherever possible. Size it with `uv.<type>.sizeof`, cast the aligned
  payload pointer to the imported C pointer type, and keep the userdata rooted
  until libuv's terminal callback says it is safe to reclaim.
- A pointer allocated by libuv or the shim is a fallback. Store it in a rooted
  userdata and release it with the matching library deallocator; a `__gc`
  fallback may reclaim passive memory, but it never replaces required
  `uv_close`, request cleanup, or loop draining.
- Use only public, portable libuv APIs for runtime behavior. Platform-specific
  code is limited to build/link details and isolated mappings for concepts that
  libuv still represents with host constants, such as signal numbers.
- The default developer/CI build uses a pinned static libuv 1.52.1 built by the
  Makefile. A system `pkg-config` mode is optional.
- V1 uses an explicit `uv.run`/`uv.run_main` boundary. Automatic compiler
  wrapping of every `main` is a separately gated follow-up, not hidden import
  magic.

This design does not require general Titan-function-to-C callback support,
`CAdopted`, tagged variants, new syntax, or a Titan module ABI bump.

## Scope

### In scope

- Reproducible libuv availability and build integration on Linux and macOS.
- A private loop and cooperative task scheduler built on `coro`.
- Fixed native C-to-Titan callback trampolines.
- Timers and scheduler yielding.
- Asynchronous filesystem I/O.
- TCP sockets and asynchronous DNS.
- Portable OS helpers, signals, child processes, and `popen`-style convenience.
- Cancellation, errors, traceback preservation, deterministic shutdown, GC
  rooting, packaging, tests, and documentation.

### Out of scope for this plan

- Windows support. The runtime design must not prevent it, but Linux and macOS
  are the supported/tested targets for this iteration.
- UDP, TTYs, filesystem watching, named-pipe IPC, arbitrary `uv_poll_t`, and
  `uv_queue_work` as public APIs.
- General Titan closures as arbitrary C function pointers.
- Detached tasks or daemon tasks.
- Automatic source-level resource finalizers that start asynchronous work from
  Lua GC.
- Replacing Lua's own `io`, `os`, `math`, or `string` tables.
- Detailed plans for the separate `titan.math`, `titan.string`, and `titan.lua`
  modules. The namespace and packaging decisions here should be reused by
  those straightforward parts of the roadmap.

## Evidence from the current repository

The current architecture already supplies the necessary substrate:

- `coro.titan` owns coroutine policy while `titan-runtime/titan_coro.c` owns a
  small native trampoline (`doc/implementation/coroutines.md:3-14`).
- The trampoline recovers a rooted module and entry `CClosure`, reads the native
  pointer from `upvalue[2]`, and calls it directly with `_fn == NULL`
  (`titan-runtime/titan_coro.c:16-27`).
- A hidden identity tag can route a yield out through nested coroutines. The
  matching root becomes `suspended`, inner coroutines become `stacked`, and
  resuming the root restores the chain (`doc/language/coroutines.md:77-88`).
- `coro.titan` already selects `stacked_co` when transferring values, so the
  scheduler only needs to own and resume the task root (`coro.titan:91-139`).
- C FFI types may be used locally but may not appear in exported Titan
  interfaces (`doc/language/ffi.md:102-118`). The public libraries therefore
  expose only Titan records, scalars, strings, arrays/maps, functions, and
  opaque `value` fields.
- The FFI supports imported function names decaying to compatible C function
  pointers (`doc/language/ffi.md:250-270`). Fixed shim callbacks can therefore
  be passed directly to `uv_timer_start`, `uv_fs_*`, `uv_read_start`, and other
  public libuv APIs.
- The FFI supports `<module>.<type>.sizeof` and `.alignof`, exact `TValue`
  transfer, the built-in current `L`, mutable C out parameters, owned C
  userdata, pointer indexing, and explicit C pointer casts.
- Titan strings are binary values, but the generic FFI `char * -> string` cast
  stops at NUL and a generic `string -> char *` borrow is documented as
  call-duration-only (`doc/language/ffi.md:280-300`). Async buffers therefore
  need an explicit length and an operation-owned root/copy.
- The standalone launcher currently evaluates
  `require('<module>').main(arg)` directly (`titan-compiler/driver.lua:326-343`).
  Automatic async wrapping is a compiler/bootstrap feature, not only a library
  edit.
- Source dependencies are statically linked while binary-only modules are
  dynamically loaded (`doc/language/modules.md:327-347`). The build must produce
  `titan/uv.so` first and make higher-level standard modules import that binary,
  so the shim and libuv archive are linked exactly once.
- Module state is per Lua state (`doc/implementation/codegen-overview.md:483-490`).
  Libuv state must also be per Lua state/run; no process-global default loop or
  task table is acceptable.

## Feasibility experiments and what they proved

All spike artifacts were kept under `/tmp`; none are production files.

### Environment and header pipeline

- The host runtime reports libuv `1.51.0`, but it has no `uv.h`, `libuv.pc`, or
  unversioned `libuv.so`. `pkg-config --modversion libuv` and ordinary `-luv`
  linking fail. A runtime SONAME is not a development dependency.
- Official libuv 1.43.0 and 1.52.1 headers both passed simple imports through
  Titan's real `cpp.parse_file -> c99 -> ctypes` pipeline. Generated modules
  called `uv_version_string` and emitted `sizeof(uv_loop_t)`,
  `sizeof(uv_timer_t)`, and `sizeof(uv_fs_t)` successfully.
- Some libuv structs remain incomplete in Titan's parsed type model on current
  headers, so `uv.Type.new()` is not a dependable production mechanism.
  `uv.Type.sizeof` still emits the C compiler's correct size.
- A current-header probe allocated a Lua userdata with
  `lua_newuserdatauv(L, uv.uv_loop_t.sizeof, ...)`, explicitly cast the returned
  `void *` to `*uv.uv_loop_t`, then ran `uv_loop_init` and `uv_loop_close`.
  It returned `0`. This is the preferred storage technique.
- With Titan's strict `--std=c99`, including current `uv.h` on Linux fails to
  expose `pthread_rwlock_t`/`addrinfo`. Adding the platform feature flags before
  all includes (`-D_GNU_SOURCE` on Linux) fixes it. `titanc` therefore needs
  standard-library-specific extra C flags or an equivalent driver hook.

### Libuv lifetime probe

A standalone public-libuv C probe ran this chain:

```text
zero timer -> async open -> write -> read -> close -> unlink
```

It intentionally checked loop closure before drain, cleaned every `uv_fs_t`,
freed the timer only from its close callback, then drained and closed the loop.
The observed summary was:

```text
version=1.51.0 busy=EBUSY run=0 close=0
stage=5 timer_closed=1 callbacks=7 read='async-ok'
```

This pins the two different libuv lifetime families:

- requests finish at their completion callback; filesystem requests also need
  `uv_fs_req_cleanup`;
- handles finish only after `uv_close` invokes the close callback.

### Native Titan callback and coroutine probes

- A zero timer stored a Lua userdata owner in `handle->data`. Its uservalues
  rooted the main Lua thread, module Udata, and a module-local Titan dispatcher
  closure. The C callback recovered `pvalue(&dispatcher->upvalue[2])` and called
  the native Titan function directly. The success path returned `true`.
- A forced dispatcher error was caught inside that native Titan dispatcher. The
  libuv callback returned normally and the captured trace named both the
  dispatcher and `run`; no error crossed libuv.
- Timer and async filesystem callbacks resumed Titan coroutines under
  generational GC with a forced full collection between submission and
  completion. The operation owner, coroutine, buffers, module, and dispatcher
  survived.
- A nested end-to-end probe ran a native timer callback on the main Lua state,
  entered a child Titan coroutine, submitted asynchronous filesystem work,
  yielded, forced GC, and later resumed with the read bytes from a native FS
  callback. It exited successfully.
- A queued scheduler probe completed two zero-duration waits and propagated a
  coroutine error only after `uv_run` returned. This validates the selected
  non-reentrant rule: native callbacks enqueue; the scheduler resumes.
- Existing coroutine tests already cover nested tagged routing, injected
  errors, stacked-resume rejection, traceback preservation, and generational
  rooting (`spec/coder/coro_spec.lua:295-428,647-733`).

### Consolidated selected-architecture probe

A final `/tmp/uv-consolidated` spike exercised the exact selected chain, rather
than the earlier callback and queue pieces separately:

```text
uv.<type>.sizeof + lua_newuserdatauv
  -> native Titan dispatcher enqueues only
  -> C callback returns
  -> uv_run returns
  -> scheduler extracts and closes/drains
  -> scheduler resumes/errors the coroutine
```

It forced collections after making an old owner point to a young coroutine and
ran both GC modes. Exact summaries were:

```text
CASE normal-incremental result=ok:done run=0 loop_close=0 timer_cb=1 close_cb=1 dispatch_returns=2 dispatch_in_uv_run=2 bad_resume=0 fatal=none trace=0
CASE normal-generational result=ok:done run=0 loop_close=0 timer_cb=1 close_cb=1 dispatch_returns=2 dispatch_in_uv_run=2 bad_resume=0 fatal=none trace=0
CASE dispatcher-failure result=caught:forced dispatcher failure run=0 loop_close=0 timer_cb=1 close_cb=1 dispatch_returns=2 dispatch_in_uv_run=2 bad_resume=0 fatal=forced dispatcher failure trace=1
CASE cancel-stop-close result=caught:cancelled run=0 loop_close=0 timer_cb=0 close_cb=1 dispatch_returns=1 dispatch_in_uv_run=1 bad_resume=0 fatal=none trace=0
ALL CASES PASS
```

`dispatch_returns` increments in C after native dispatch returns, and
`bad_resume=0` proves no coroutine was resumed inside either callback. The
cancellation case deliberately had no timer event but retained the owner until
the close callback. The probe also exposed three implementation constraints now
captured below: concrete typed wrappers are needed for libuv base-handle casts,
Linux needs compiler-level `_GNU_SOURCE`, and the production completion queue
must be multi-entry.

A separate checker-only probe accepted the proposed higher-order `run` APIs,
tuple-returning `communicate`, and extended `ExitStatus` declarations:
`public API syntax/checker: OK`.

### Experiment-driven constraints

1. The callback state is the scheduler's main Lua state, never the child Lua
   state whose native stack is suspended inside minicoro.
2. A raw `Udata *`, `CClosure *`, `lua_State *`, or buffer pointer in libuv data
   is navigation only; it is not a GC root.
3. The operation owner stays rooted for the entire C callback. Do not remove it
   from the pending table before native dispatch and C cleanup return.
4. The fixed native dispatcher must catch everything, record the failure, ask
   the scheduler to stop, and return normally.
5. `uv_stop` only makes `uv_run` return. It does not close handles, finish
   requests, or make `uv_loop_close` succeed.
6. Libuv worker threads never call Titan. Filesystem completion callbacks return
   on the loop thread. If `uv_queue_work` is added later, only its
   `after_work_cb` may dispatch to Titan.

## Review of `/tmp/uv-io.md`

### Parts to keep

- A thin C shim rather than general callback support.
- A hidden coroutine tag and direct-style `yield`/resume boundary.
- A synchronous-looking high-level API.
- Separate filesystem, network, OS/process, and timer modules.
- Pausing stream reads and retaining excess bytes in the connection.
- Fixed C trampolines that recover a Titan module dispatcher.

### Required corrections

| Sketch point | Final design |
| --- | --- |
| One hidden module string tag | One fresh private identity object per task. `_await` reads the currently running task's tag. |
| Start each task with a zero timer | Put a new task directly on the ready queue. A zero timer is used only for `timer.yield()`/`timer.sleep(0)`. |
| Callback resumes and then interprets the next request inline | Callback invokes the native completion dispatcher, which enqueues. The scheduler resumes after `uv_run` returns and interprets the newly yielded request. |
| Raw L/module/closure/coroutine tuple in `data` | `data` points to a Lua userdata owner rooted in `Runtime.pending` or `Runtime.resources`; uservalues root all Titan values. |
| Print traceback from a callback | Save `{error, traceback}`, close/cancel/drain, reinstall and pin the trace, then re-raise at `uv.run`. |
| Default/global event loop implied | Private loop allocated for one `run`, closed before `run` returns. |
| Callback owns all scheduling policy | Titan scheduler owns policy; C only normalizes callback ABI and exposes binary-length/lifetime details that the FFI cannot express cleanly. |
| Main is automatically wrapped | V1 uses explicit `run_main`; automatic bootstrap is an opt-in later phase if still desired. |
| `fs`, `net`, `os`, `timer` root names | Namespaced modules avoid Lua standard-library collisions and remain usable from both Titan `import` and Lua `require`. |

## Module and file layout

Add these production files:

```text
titan/
  uv.titan                 public scheduler + private low-level operations
  timer.titan              timers and cooperative yield
  fs.titan                 files and path operations
  net.titan                DNS and TCP
  os.titan                 portable OS/process/signal operations
titan-runtime/
  titan_uv.c               fixed native libuv callbacks and narrow helpers
  titan/uv.h               parser-friendly callback/helper declarations
```

`titan.uv` is the only Titan module that imports C types. Its exported surface
contains no C FFI type. Higher-level modules dynamically import its compiled
interface and use reserved underscore-prefixed middle-layer functions such as
`_fs_open`, `_tcp_read`, and `_spawn`. Titan has no package-private visibility,
so those names are technically public; document them as unstable and reject
untrusted opaque handles at runtime.

Use the symbol prefix `titan_uvshim_` for C helpers. The generated module name
`titan_uv_*` already occupies the shorter prefix.

## Scheduler design

### Runtime ownership

Each active `run` owns this Lua-traced graph:

```text
Runtime (module-local record + loop-owner userdata)
  |
  +-- main thread value
  +-- private uv_loop_t payload
  +-- tasks map ----------> Task ----------> root coro.Coro
  |                           |                  +-- coroutine handle userdata
  |                           +-- private tag    +-- child Lua thread
  |                           +-- state/result   +-- entry closure/function
  |                           +-- current op
  +-- pending map --------> Operation owner userdata
  |                           +-- uv request/handle payload
  |                           +-- main thread / module / dispatcher uservalues
  |                           +-- Task / Request / input/output roots
  +-- resources map ------> open File/Connection/Server/Process/Ticker owners
  +-- ready queue --------> Completion(Task, generation, ok, payload)
  +-- first failure ------> exact error value + copied traceback string
```

Every arrow that reaches a Lua/Titan value is visible to the Lua collector.
Libuv `data` pointers point back into this graph but do not create it.

`active_runtime` is a module Udata slot, so it is per Lua state. Reject a second
`run` while it is non-nil. After complete shutdown and `uv_loop_close == 0`,
clear it so a later sequential `run` can create a fresh loop.

### Task state

An opaque `Task` contains:

- root `coro.Coro`;
- private identity tag;
- generation number;
- state: `new`, `ready`, `running`, `waiting`, `succeeded`, `failed`, or
  `cancelled`;
- current operation owner;
- final error/trace when failed;
- joiners;
- sticky cancellation reason.

Only the scheduler calls `root:resume` or `root:error`. A callback, cancellation
request, join, or spawn only queues scheduler work.

Set `Runtime.running_task` immediately before entering a root and clear it as
soon as control returns. Any `_await` function obtains the tag from that slot.
This also handles a user-created nested coroutine: its hidden async yield walks
outward until it reaches the task root, which becomes `suspended` while the
intermediate coroutines become `stacked`.

### Request flow

Use one private `Request` record in `titan.uv`. It has an integer operation kind,
ordinary Titan/value arguments, and a generation. No tagged-variant language
feature is required.

The selected flow is:

1. A high-level middle-layer function, executing on the task's child Lua state,
   validates arguments and creates a pure Titan `Request`.
2. `_await(request)` calls `coro.yield(request, task.tag)`.
3. The task root's `resume` returns on the main scheduler state.
4. The scheduler checks `root:status()`:
   - `suspended`: the returned value must cast to the private `Request` type;
   - `dead`: the returned value is task completion;
   - any other status is an internal scheduler error.
5. On the main state, the scheduler allocates operation owner userdata and
   buffers, sets uservalues, inserts the owner in `pending`, sets libuv data to
   the owner, and submits the public libuv operation.
6. A negative immediate return means that operation's completion callback will
   not arrive. Apply the lifecycle-matrix arm and queue an error wakeup without
   entering `uv_run`; if a handle was already initialized, its owner remains
   rooted through an explicit `uv_close` callback.
7. A successful submission leaves the task `waiting` and the operation rooted.
8. The libuv callback records status/result in the still-rooted owner, calls the
   native Titan dispatcher, and returns. It must not clean or release anything
   whose result storage the scheduler still needs.
9. The dispatcher enqueues the rooted owner plus its generation. It does not
   resume user code or expose a borrowed result pointer as the payload.
10. After `uv_run` returns, the scheduler applies that operation kind's
    extraction contract: copy/convert all result data into Lua-owned values,
    perform the one required cleanup, transition terminal state, and only then
    remove the logical wait/final operation root.
11. The scheduler calls `root:resume(result, tag)` or
    `root:error(error, tag)`. Result extraction/cleanup failure is contained as
    a Runtime failure and enters the same drain path.

For `uv_fs_t`, use public `uv_fs_get_result`, `uv_fs_get_ptr`,
`uv_fs_get_statbuf`, `uv_fs_get_path`, and `uv_fs_scandir_next` as appropriate.
Copy all request-owned data before calling `uv_fs_req_cleanup` exactly once.
The immediate-submission-error arm also runs its operation-specific cleanup;
it is not a shortcut around this state machine.

A submit-before-yield fast path was also proven feasible, provided the context
stores `Runtime.main_L` and never dispatches on suspended child state `T`. Keep
it out of v1 until profiling shows the request handoff matters; the yield-first
path has simpler state ownership and matches the original sketch.

### Fair event-loop driver

Use a bounded ready-task budget so CPU-ready tasks cannot starve I/O:

```text
enqueue root start

while root not terminal or shutdown not drained:
    run up to READY_BUDGET queued task actions
    uv_run(loop, UV_RUN_NOWAIT)
    drain callback-produced completions into the ready queue

    if ready is empty and loop still owns active work:
        uv_run(loop, UV_RUN_ONCE)
        drain callback-produced completions

    if ready is empty, tasks are waiting, and uv_loop_alive(loop) is false:
        fail with a scheduler-deadlock diagnostic
```

No callback calls `uv_run`. `timer.yield()` uses a zero-duration timer when the
contract specifically requires the next loop turn; ordinary spawning simply
queues at the tail. The callback-to-scheduler completion queue is a multi-entry
FIFO with one entry per terminal event, not a single mailbox slot: one `uv_run`
iteration may invoke many callbacks before returning. Its growth is bounded by
rooted pending operations/resources, and shutdown drains it before releasing
those roots.

## Low-level FFI and C shim contract

### Titan-owned storage first

For a loop, request, or handle:

1. Read the exact C size and alignment from `uv.<type>.sizeof` and `.alignof`.
2. Call `lua_newuserdatauv` from `titan.uv`, using enough uservalues for its
   ownership contract.
3. Cast the returned `void *` payload to the source-level pointer type such as
   `*uv.uv_loop_t`, `*uv.uv_fs_t`, or `*uv.uv_timer_t`.
4. Keep the full userdata value in `pending`/`resources` before a call that can
   make it visible to libuv.
5. Use public `uv_loop_set_data`, `uv_req_set_data`, or `uv_handle_set_data` to
   associate the userdata owner; avoid depending on macro-expanded struct
   fields in Titan's parsed type model.
6. Remove the final root only after the operation's terminal callback or the
   handle close callback returns and all required cleanup is complete.

This works even when Titan considers the imported libuv struct incomplete:
`.sizeof` and the pointer cast are emitted for the C compiler, which sees the
real definition. Phase 0 must assert for every allocated libuv type that the
returned userdata payload satisfies its imported alignment. If a future
platform has an over-aligned type, use the rooted pointer-owner fallback for
that type rather than assuming alignment.

Titan currently rejects libuv's implicit concrete-to-base pointer conversions
such as `uv_timer_t * -> uv_handle_t *`. Keep tiny concrete typed wrappers in
the shim for set/get-data, `uv_close`, `uv_is_closing`, and similar base-handle
calls; each wrapper performs only the cast and calls the corresponding public
libuv API. Do not read private fields or expand this into POSIX wrappers.

Import `uv.h` once and keep the private shim header narrow. The spike found
false `stdin`/`stdout`/`stderr` declaration conflicts when `stdio.h` was also
foreign-imported independently; avoid redundant broad system-header imports
and add a parser regression before introducing one.

Use library/shim allocation only when an API allocates and returns its own
object or when callback-driven variable storage cannot practically be created
in Titan. The fallback mirrors `coro.titan`: a full userdata roots the pointer,
the matching library cleanup is explicit, and `__gc` is a last-resort passive
memory release. Never free an initialized libuv handle from `__gc` before its
close callback.

### Uservalue layout

Give every callback owner a documented fixed slot layout. A representative
layout is:

| Slot | Root |
| --- | --- |
| 1 | scheduler main Lua thread |
| 2 | `titan.uv` module Udata |
| 3 | fixed module-local native dispatcher CClosure |
| 4 | Task/root coroutine |
| 5 | private Request/operation metadata |
| 6 | input buffer/string or output buffer userdata |
| 7 | resource owner when request and handle differ |

Not every family needs every slot, but a family must have one stable contract
covered by a C layout test. Lua's uservalue API numbers these slots from one;
the corresponding `Udata.uv` indices in the C shim are zero-based. Define both
sets of named constants together and assert the mapping in that layout test.

### Native callback path

`titan-runtime/titan_uv.c` follows the current coroutine pattern:

```c
Udata *owner = uv_req_get_data((uv_req_t *)req);
lua_State *L = thvalue(&owner->uv[MAIN_THREAD_SLOT].uv);
Udata *M = uvalue(&owner->uv[MODULE_SLOT].uv);
CClosure *dispatcher = clCvalue(&owner->uv[DISPATCH_SLOT].uv);
titan_uv_dispatch f = pvalue(&dispatcher->upvalue[2]);

/* Keep owner rooted until this C callback has completely finished. */
TValue owner_value = push_owner_temporarily(L, owner);
f(L, M, NULL, owner_value, event_kind, result, size);
restore_stack(L);
```

The dispatcher is a fixed module-local top-level function with no captures, so
`_fn == NULL` matches `titan_coro_entry`. Do not route through its Lua wrapper;
these callbacks are frequent and their arguments are already trusted by the
private shim.

The dispatcher body is one outer `do ... catch`:

- normal path: validate generation/state and append a `Completion`;
- catch path: save exact `error` and `traceback`, mark the runtime failing,
  request `uv_stop`, and return;
- it never re-raises while the C callback is active.

The scheduler later performs orderly shutdown and only then reinstalls/pins the
saved trace and raises.

### Initial fixed callbacks

Declare only the callback shapes actually needed:

- timer;
- handle close;
- filesystem request;
- stream allocation/read;
- connect;
- write;
- incoming connection;
- getaddrinfo/getnameinfo;
- process exit;
- signal.

Imported shim function names decay to libuv's callback pointer typedefs. The C
functions should contain no scheduler policy.

### Binary buffers

V1 uses explicit-length buffers throughout.

- Known-size filesystem reads: allocate a Lua userdata byte buffer before
  submission and root it in the operation owner.
- Filesystem/stream writes: copy the Titan string into a GC-owned byte userdata
  and root both the owner and length until `uv_write_cb`/`uv_fs_cb`. A later
  proven optimization may pin the immutable `TString` and write directly.
- Stream reads: when a waiter starts reading, associate a preallocated
  GC-owned buffer with the stream owner. The C alloc callback returns that
  buffer without entering Titan. On data, EOF, or error (`nread != 0`), the C
  read callback must synchronously call public `uv_read_stop` before enqueueing
  the owner. That quiesces the single buffer so another callback cannot
  overwrite it before post-`uv_run` extraction. The scheduler converts exactly
  `nread` bytes into a Titan string and explicitly restarts reading for the next
  waiter. A negative stop result is an invariant failure: record it and close
  the stream (or observe that it is already closing) before returning from the
  callback, so the buffer is still never reused.
- `nread == 0` is not EOF; enqueue nothing and keep reading.
- `UV_EOF` becomes `nil` at the high-level read API. Other negative results
  become `titan.uv.Error`.
- Stop reading as soon as the current waiter has data/EOF/error. Higher-level
  methods retain excess bytes and explicitly restart when another read waits.

No NUL-terminated cast is used for file/socket payloads.

Paths, host/service names, environment names/values, and process arguments are
text rather than payloads. Reject embedded NUL bytes before crossing the FFI,
and keep an operation-owned NUL-terminated copy whenever libuv may retain the
pointer beyond the submission call. Tests must distinguish accepted binary
file/socket data from rejected NUL-containing text arguments.

## Errors and traceback preservation

Expose:

```titan
record Error
  code: integer
  name: string
  message: string
  operation: string
  subject: string?
end

record Cancelled
  reason: value
end
```

Negative libuv statuses are converted with public `uv_err_name` and
`uv_strerror`. Copy both strings before releasing the request/context. EOF is a
normal optional read result, and cancellation is a distinct semantic value.

There are three error boundaries:

1. Immediate submission failure: queue `Error` without entering the loop.
2. Async operation failure: callback queues the negative result; scheduler
   injects `Error` with `Coro:error` at the suspended `_await` site.
3. Task/user failure: scheduler catches the error escaping `root:resume`, copies
   the catch-local `traceback`, marks the task failed, and applies fail-fast
   structured-concurrency policy.

Do not depend on `registry[TITAN_BACKTRACE_KEY]` retaining a task failure while
other callbacks run. Store the traceback string in the Task/Runtime immediately.

Before `run` or `Task:join` re-raises a stored error, reinstall the saved trace
and set `TITAN_TRACE_PINNED`, following `coro.titan:57-89` and
`doc/implementation/error-handling.md:27-49`. Joining a failed child appends a
join-site propagation trace so both the child failure and observer are visible.

The library never prints errors. Standalone/Lua callers retain control over
presentation.

## Cancellation and structured concurrency

### Public task policy

V1 has structured tasks and no detach:

- a child with an already waiting joiner delivers its stored failure to the
  joiner; `Task:join` re-raises it with its saved trace and the joiner may catch
  it;
- a child that fails with no waiting joiner is unobserved and fails the run,
  cancelling the root and siblings immediately;
- joining self is rejected; a cycle among joiners is reported by the
  scheduler-deadlock diagnostic rather than hanging;
- when the root finishes, remaining children are cancelled and drained before
  `run` returns;
- cancellation is cooperative and cannot preempt CPU-bound Titan code;
- cancellation is sticky: catching it permits cleanup, but a later `_await`
  observes it again, and returning without another await still leaves the Task
  terminally `cancelled`, so `join` raises its `Cancelled` value.

### Logical versus physical cancellation

`Task:cancel(reason)` marks the task and schedules injection of
`Cancelled(reason)` through `root:error` at the next safe point. For ordinary
waits that can be immediate; for cleanup-critical waits, the safe point is only
after physical cleanup. It also requests operation-specific physical
cancellation:

- non-cleanup request families supported by `uv_cancel`: call it, but keep the
  owner rooted until the completion callback, including when cancellation
  succeeds;
- never physically cancel `uv_fs_close` or another request whose purpose is
  required cleanup. Cancellation is logical only and is delivered after its
  callback and request cleanup. If a logically cancelled `uv_fs_open`
  nevertheless completes with a valid file descriptor, immediately schedule
  an uncancellable close and retain ownership until that close completes;
- timers: `uv_timer_stop`, then `uv_close`, free only after close callback;
- reads: `uv_read_stop`; keep stream storage and late event handling valid;
- connect/write: mark logically cancelled and consume the eventual callback;
- process wait: cancel the waiter without implicitly killing the child;
- explicit `Process:kill` controls process termination.

Any resource-producing operation that wins a race after logical cancellation
must dispose of the acquired resource instead of returning it or leaving it
idle: a successful late connect closes its stream handle, just as a successful
late open schedules the uncancellable file close above.

Generation and terminal-state checks make completion/cancellation exactly once.
A late callback after logical cancellation performs physical cleanup and is not
allowed to resume the task again.

Dropping a coroutine is not cancellation. Current minicoro collection abandons
stacked frames without running user code, so it would skip `finally` blocks.

### Operation lifecycle matrix

Every owner carries an explicit state and separate logical-completion and
physical-cleanup bits. Requests normally progress `allocated -> submitted ->
callback_seen -> extracted -> cleaned -> unrooted`; handles progress
`allocated -> initialized -> closing -> close_callback_seen -> unrooted`.
Exactly-once assertions guard every transition. In particular, a cancellation
path must never wait for a callback that the public libuv operation does not
promise.

| Family | Immediate/start failure | Logical/physical cancellation | Terminal event and extraction | Final unroot point |
| --- | --- | --- | --- | --- |
| Private loop | Failed `uv_loop_init` leaves no live loop and releases its owner | Runtime shutdown drains all other families; `uv_stop` is only a wakeup | `uv_loop_close == 0` | After successful loop close |
| One-shot timer or signal wait | Init failure releases immediately; start failure after successful init queues the error and calls `uv_close` | `uv_timer_stop`/`uv_signal_stop`, then `uv_close`; cancellation may be injected immediately | Event callback stops the watcher, enqueues once, and initiates close | Only after close callback, and after any queued completion no longer needs the owner |
| Repeating Ticker | Same init/start split | Stop and close; pending `next` waiter receives closed/cancelled outcome | Tick coalesces in owner; scheduler consumes it | Close callback after no pending completion references it |
| `uv_fs_t` including open/read/write/stat/path/scandir/close | A negative submit return queues its result and follows the wrapper's cleanup arm; no callback is assumed | Call `uv_cancel` only for non-cleanup operations where supported. Never physically cancel `uv_fs_close`; logical cancellation waits for close callback + cleanup. A cancelled open that returns a valid fd is converted immediately into an uncancellable close | Scheduler copies buffer/stat/path/scandir entries through public accessors, then calls `uv_fs_req_cleanup` exactly once; cleanup-close status is consumed before delivering cancellation | After extraction and cleanup; any acquired `uv_file` remains owned until its close request completes |
| DNS (`uv_getaddrinfo`/`uv_getnameinfo`) | Negative submit return has no callback and releases request inputs | `uv_cancel` success still ends in completion callback; too-late/failure leaves normal callback path | Copy normalized addresses/names; for `getaddrinfo`, call `uv_freeaddrinfo` on every non-null result after copying | After callback result is copied and any address list freed |
| Connect, write, and `uv_shutdown_t` requests | Negative submit return has no callback; release request/buffer roots, while any initialized stream handle follows handle-close policy | No assumed physical cancellation; mark logical cancellation and consume the eventual callback. A late successful connect closes the undelivered stream | Scheduler copies status; write buffer remains rooted through callback; shutdown closes only the write side | After callback extraction; a delivered stream remains until explicit close, an undelivered one until close callback |
| Stream read waiter | Negative `uv_read_start` has no callback and retires the waiter synchronously | Successful `uv_read_stop` produces no terminal read callback: retire the waiter and inject cancellation synchronously while retaining the stream owner | For `nread != 0`, callback calls `uv_read_stop` before enqueue; scheduler copies the quiesced buffer. `nread == 0` is ignored | Per-wait owner/buffer after scheduler extraction; stream handle only at close callback |
| Listener and accepted TCP handles | Listen failure after successful handle init initiates close | Closing the server uses `uv_close`; no nonexistent listen-stop API is assumed | Each connection notification performs `uv_accept` into a new GC-owned handle; a full queue closes that new client immediately | Each handle's own close callback |
| Spawned process and stdio pipes | On `uv_spawn` failure, the process handle is treated as uninitialized; already initialized pipe handles are closed and drained | Cancelling a waiter does not kill; Runtime shutdown uses `uv_process_kill`, consumes exit, then closes process/pipes | Exit callback records status; pipe read/write requests follow stream/request rows | Process close callback plus all pipe close callbacks |

Wrapper tests fault each transition, including init failure, start/submit failure,
cancel-before-complete, complete-before-cancel, too-late cancellation, and close
with a completion still queued.

## Deterministic shutdown

On root completion, task failure, or internal dispatcher failure:

1. Mark Runtime `closing`; reject new tasks and operations.
2. Preserve the first failure and its trace.
3. Inject cancellation into all live child tasks so their `finally` paths run.
4. Cancel supported requests but keep every context rooted for its callback.
5. Stop watchers/readers and initiate `uv_close` for every initialized handle.
6. Close open files asynchronously.
7. For live child processes owned by the run, send the documented graceful
   termination signal (`SIGTERM` on Linux/macOS), wait up to a five-second
   grace timer, then force termination with `SIGKILL`;
   consume the exit callback before closing the process handle. Task
   cancellation alone does not kill a process.
8. Continue `uv_run` calls until all request and close callbacks drain.
9. Call `uv_loop_close`. Treat `UV_EBUSY` as an implementation bug; in a debug
   build, enumerate remaining handles with `uv_walk` for the diagnostic.
10. Clear `active_runtime` and release the loop-owner root.
11. Return normally or reinstall/pin and re-raise the preserved error.

No userdata finalizer starts async close after the loop may already be gone.
Explicit resource `close` plus Runtime ownership is the correctness path.

## Public APIs

The declaration forms below passed a checker-only probe; committed checker and
binary-interface tests will lock the exact surface during implementation.

### `titan.uv`

```titan
record Task
end

record Error
  code: integer
  name: string
  message: string
  operation: string
  subject: string?
end

record Cancelled
  reason: value
end

function run(func: () -> value): value
function run_main(func: ({string}) -> integer,
                  args: {string}): integer
function spawn(func: () -> value): Task
function Task:join(): value
function Task:cancel(reason: value)
function Task:status(): string
```

`run_main` is the explicit v1 standalone convenience:

```titan
local uv = import "titan.uv"

function async_main(args: {string}): integer
  -- synchronous-looking async code
  return 0
end

function main(args: {string}): integer
  return uv.run_main(async_main, args)
end
```

Every async operation outside an active main-thread `run` raises a clear usage
error. A Task or resource from an older Runtime generation is rejected. The
dynamic `value` result keeps task functions useful without adding generics;
callers cast the joined result back to the application type, while `run_main`
provides the typed integer-returning standalone path.

### `titan.timer`

Initial API:

```titan
function sleep(milliseconds: integer)
function yield()

record Ticker
end

function ticker(milliseconds: integer): Ticker
function Ticker:next(): boolean
function Ticker:close()
```

- Negative durations are rejected.
- `sleep(0)`/`yield()` cede through a zero timer and therefore reach another
  event-loop turn.
- `Ticker:next` returns false after close.
- Ticks coalesce to one pending tick if the consumer is slow; they do not grow an
  unbounded queue.
- Close is idempotent and callbacks after close are cleanup-only.

### `titan.fs`

Initial API:

```titan
record File
end

function open(path: string, mode: string): File
function read_file(path: string): string
function write_file(path: string, data: string)

function File:read(max_bytes: integer): string?
function File:write(data: string): integer
function File:flush()
function File:close()
function File:is_closed(): boolean
```

Second filesystem slice:

```titan
record Stat
  size: integer
  kind: string
  mode: integer
  modified_seconds: integer
  modified_nanoseconds: integer
end

function stat(path: string): Stat
function mkdir(path: string)
function unlink(path: string)
function rmdir(path: string)
function rename(from: string, to: string)
function list(path: string): {string}
```

Contracts:

- Mode strings are `r`, `w`, `a`, `r+`, `w+`, `a+`, with an optional `b`
  accepted for familiarity. Translate them in Titan to public `UV_FS_O_*`
  constants; do not expose host `O_*` numbers.
- `File:read(n)` requires `n > 0`, returns up to `n` binary bytes, and returns
  `nil` only at EOF.
- `File:write` loops over partial writes and returns the full byte count on
  success.
- File operations are serialized in a FIFO with one active libuv request.
  Calling `close` immediately marks the File `closing`, rejects all later
  operations, lets operations already ahead of close finish in order, then
  submits exactly one close request. Cancelling a waiter removes an operation
  that has not been submitted; an active operation follows the lifecycle
  matrix. Cancellation of the task awaiting `close` does not abandon physical
  close; cleanup finishes before the cancellation is delivered.
- Offset `-1` uses the file's current position. Random-access methods can be a
  follow-up.
- Every filesystem request calls `uv_fs_req_cleanup` exactly once on success,
  failure, or cancellation.
- `close` is idempotent. Any other method after close raises a use-after-close
  error.
- `mkdir` passes mode `0777` to public `uv_fs_mkdir`, subject to the process
  umask on Linux/macOS; an explicit permission API is a follow-up. `unlink`
  removes files/symlinks through `uv_fs_unlink`; `rmdir` removes only an empty
  directory through `uv_fs_rmdir`. Neither guesses based on a failed POSIX
  operation.
- Whole-file helpers cap growth against integer/size overflow and stream rather
  than trusting `stat.size` alone.

### `titan.net`

Initial API:

```titan
record Connection
end

record Server
end

function connect(host: string, port: integer): Connection
function listen(host: string, port: integer,
                backlog: integer): Server

function Connection:read_some(max_bytes: integer): string?
function Connection:read_exactly(bytes: integer): string
function Connection:read_until(delimiter: string,
                               max_bytes: integer): string
function Connection:write(data: string)
function Connection:shutdown()
function Connection:close()

function Server:accept(): Connection
function Server:close()
```

Contracts:

- Resolve through `uv_getaddrinfo`; try compatible returned addresses in order
  and always call `uv_freeaddrinfo`.
- Use `uv_tcp_t`, `uv_tcp_connect`, `uv_listen`, and `uv_accept`; no raw sockets.
- Exactly one reader may wait on a Connection. `read_some` starts libuv reading
  only when needed and stops it as soon as data/EOF/error satisfies the waiter.
- `read_exactly` and `read_until` loop over `read_some` and retain excess bytes
  in the Connection. Premature EOF in `read_exactly` raises
  `titan.uv.Error` with libuv's `UV_EOF` and includes the requested and partial
  byte counts in `message`/`subject`; it never returns a short string.
  `read_until` enforces `max_bytes` and raises without discarding already
  buffered bytes.
- Writes are ordered FIFO. Each write buffer remains rooted until its callback.
- `Connection:shutdown` queues `uv_shutdown` after earlier writes, permanently
  closes only the write side, and leaves reads active until EOF/error or
  `close`. Later writes are rejected as soon as shutdown is requested. `close`
  closes both directions and remains idempotent.
- EOF is `nil`; reset and other errors raise `titan.uv.Error`.
- `listen` requires `backlog > 0` and uses it both for `uv_listen` and as the
  accepted-connection queue capacity. Libuv exposes no public listen-stop
  operation, so every connection notification calls `uv_accept` into a fresh
  GC-owned client handle. Deliver directly to an existing accept waiter;
  otherwise enqueue it, or, when that queue is full, immediately `uv_close` the
  new client while keeping the listening handle active. No private/POSIX pause
  and no unbounded queue.
- Client, server, and requests must belong to the same Runtime generation.

UDP and Unix-domain/named pipes are follow-ups.

### `titan.os`

Portable synchronous helpers use public `uv_os_*`/utility functions:

```titan
function getenv(name: string): string?
function setenv(name: string, value: string)
function unsetenv(name: string)
function cwd(): string
function chdir(path: string)
function homedir(): string
function tmpdir(): string
function hostname(): string
function exepath(): string
function pid(): integer
function ppid(): integer
```

Buffer-sized helpers retry on `UV_ENOBUFS` with checked growth. If a public
libuv operation returns `UV_ENOSYS`, expose that Error; do not add a hidden
POSIX fallback.

Processes and signals:

```titan
record ExitStatus
  code: integer
  signal: string?
  signal_number: integer
end

record Process
end

function spawn(file: string, args: {string}): Process
function Process:wait(): ExitStatus
function Process:kill(signal: string)
function Process:write_stdin(data: string)
function Process:close_stdin()
function Process:read_stdout(max_bytes: integer): string?
function Process:read_stderr(max_bytes: integer): string?

function communicate(file: string, args: {string},
                     input: string?): (string, string, ExitStatus)
function wait_signal(name: string): string
```

- Use `uv_spawn`, `uv_process_t`, and `uv_pipe_t`; no `fork`, `pipe`, or
  `waitpid` fallback.
- `file` is the executable and `args` contains only arguments after `argv[0]`.
  The shim builds a GC-owned, NUL-terminated vector `[file, args..., NULL]` and
  roots every copied string/vector through the return of `uv_spawn`; the child
  inherits the current environment and working directory in v1.
- The process owner remains rooted until the exit callback and all pipe closes.
- `communicate` drains stdout and stderr concurrently while optionally writing
  stdin, so it cannot deadlock on a full child pipe.
- `Process:wait` may be cancelled without killing the child. `Process:kill` is
  explicit.
- Signal names map to the common Linux/macOS subset inside the shim. Numeric
  signal values are not accepted as public inputs; `signal_number` is
  diagnostic output preserving an unknown termination signal.
- Canonical input/output names are lowercase `hup`, `int`, `quit`, `term`,
  `usr1`, and `usr2`; `Process:kill` additionally accepts `kill`, while
  `wait_signal` rejects the uncatchable `kill`. Unknown names raise before any
  libuv call.
- Process exit status and terminating signal are retained independently.
  `signal_number` is zero on normal exit and preserves an unknown host signal;
  `signal` is its canonical lowercase name when it belongs to the documented
  Linux/macOS subset, otherwise `nil`.
- `communicate` is the v1 argv-based, popen-style convenience. Do not add an
  implicit shell-string `popen`; callers that intentionally need a shell must
  spawn it explicitly with an argument array.

## Portable libuv acquisition and build

### Default: pinned bundled static libuv

Mirror the existing Lua/libbacktrace dependency workflow:

```make
LIBUV_VERSION := 1.52.1
LIBUV_TARBALL := libuv-v$(LIBUV_VERSION).tar.gz
LIBUV_URL := https://dist.libuv.org/dist/v$(LIBUV_VERSION)/$(LIBUV_TARBALL)
LIBUV_SHA256 := 66d511b9e6e334c0e62279eb234fbfb2b3110b1479c09b95b44c7afca8cff9e7
```

`make libuv` must:

1. Download the exact release tarball.
2. Verify SHA-256 using `sha256sum` or macOS `shasum -a 256`.
3. Extract into a versioned ignored directory.
4. Fail early with actionable instructions if CMake is unavailable.
5. Configure a PIC static build:

   ```sh
   cmake -S libuv-v1.52.1 -B libuv-build \
     -DLIBUV_BUILD_SHARED=OFF \
     -DBUILD_TESTING=OFF \
     -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
     -DCMAKE_BUILD_TYPE=Release
   cmake --build libuv-build --target uv_a
   ```

6. Expose the archive and include directory to the standard-module build.

Reuse the Makefile's existing `curl`-then-`wget` download fallback and emit a
specific missing-tool error. The documented clean-checkout path is:

```sh
# Ubuntu/Debian prerequisites for the bundled default
sudo apt-get install build-essential cmake curl
make libuv

# Fedora prerequisites for the bundled default
sudo dnf install gcc make cmake curl
make libuv

# macOS prerequisites for the bundled default
xcode-select --install                 # if command-line tools are absent
brew install cmake                     # or install CMake by another supported route
make libuv
```

`make help` must explain that `make all`/`make stdlib` build the bundled copy
automatically, while `make libuv` is the focused dependency target. A missing
compiler, downloader, checksum tool, CMake, or archive tool must fail before a
partial standard-module link and print the corresponding Linux/macOS remedy.

Add `clean-libuv` and include it in `distclean`. Add libuv source/build/tarball
paths to `.gitignore`. Cache by OS, architecture, version, and build flags in
CI. Preserve libuv's license/attribution in source and binary distribution
artifacts that contain the statically linked library.

Linux links the static archive with `pthread`, `dl`, and `rt` (the driver already
adds `dl`); macOS links `pthread` and must not add Linux-only `rt`. Keep this
conditional in the Makefile, not in Titan runtime code.

Build the generated `titan.uv` translation unit and shim with
`-fno-strict-aliasing`, as upstream recommends for libuv's public base-handle
casts. On Linux also put `_GNU_SOURCE` in compiler flags before all headers.

After linking, assert that bundled `titan/uv.so` has no dynamic libuv dependency:

- Linux: inspect `readelf -d` or `ldd`;
- macOS: inspect `otool -L`.

### Optional: system libuv

Support `LIBUV_MODE=system` only through full `pkg-config` output, never by
guessing `/usr/local`:

```sh
pkg-config --atleast-version=1.43.0 libuv
pkg-config --cflags libuv
pkg-config --libs libuv
```

Phase 0 must audit every selected symbol against 1.43.0 and raise the minimum if
needed. The bundled version remains the release/CI authority.

User setup hints:

```sh
# Ubuntu/Debian
sudo apt-get install libuv1-dev pkg-config

# Fedora
sudo dnf install libuv-devel pkgconf-pkg-config

# macOS
brew install libuv pkgconf
```

Homebrew's prefix may be outside compiler defaults; always consume pkg-config's
include/library paths. Do not tell users to set an unversioned runtime SONAME
manually.

### Required Titan build plumbing

Current `titanc` only accepts bare `-l` names and extra objects, and the FFI
parser independently probes bare `cpp`/`gcc`. Add narrowly scoped, generic
plumbing before the standard module:

- append-only `TITAN_EXTRA_CPPFLAGS` for `-I`/`-D` flags that must affect both
  FFI header discovery/predefined macros and every generated/runtime C compile;
- append-only `TITAN_EXTRA_CFLAGS` for compilation-only flags;
- append-only `TITAN_EXTRA_LDFLAGS` for final links;
- preserve existing defaults rather than replacing them;
- honor `CC`, `CPATH`, and `LIBRARY_PATH`, but do not rely on ambient variables
  for the reproducible bundled mode;
- print all effective flags under `-v`.

This requires a real FFI-preprocessor change, not only driver link plumbing:

1. `c-parser/cdriver.lua` obtains the configured compiler and parsed
   `TITAN_EXTRA_CPPFLAGS` from its options.
2. Both include-search discovery (`CC -E -v`) and predefined-macro discovery
   (`CC -std=gnu11 -dM -E`) run with those same flags. Cache their results by
   compiler plus flag string, not process-globally.
3. `cdriver` passes the resulting include directories and macro table into
   `cpp.parse_file`; recursive includes share that context.
4. `titan-compiler/checker.lua` supplies the configuration for every `foreign
   import`, while `driver.lua` puts the same CPP flags before CFLAGS on generated
   C, runtime, and entrypoint compilation commands.
5. Avoid shell-word guessing inside the parser: centralize validated flag
   splitting/quoting in the driver utility and test paths containing spaces.

The bundled build sets `TITAN_EXTRA_CPPFLAGS=-I<versioned include> -D_GNU_SOURCE`
on Linux (only the include flag on macOS), passes `libuv.a` through existing
`-X`, and uses existing `-l` for platform support libraries. System mode splits
`pkg-config --cflags` into the shared CPP channel and sends the complete ordered
`pkg-config --libs` output to the link channel. Add parser/driver tests proving
that a header visible only through these flags is parsed with the same macro
branches the C compiler sees, compile-only flags do not leak into the link-only
phase, and link flags retain order.

### Makefile and LuaRocks packaging

Extend the build graph:

```text
lua + libbacktrace + libuv
  -> titan.o + titan_coro.o + titan_uv.o
  -> coro.so
  -> titan/uv.so
  -> titan/timer.so, titan/fs.so, titan/net.so, titan/os.so
```

Build `coro.so` and `titan/uv.so` before higher-level modules and force those
dependencies down the compiled-module path, so `titan_uv.o`/`libuv.a` are not
duplicated into every library.

Replace the rockspec's single `coro.so` copy hook with an `install-stdlib`
target that preserves `titan/*.so` subdirectories in both Lua's `LIBDIR` and
Titan's ABI-versioned binary path. Installed high-level modules depend on the
binary `titan.uv` interface and need no libuv headers at user compile time.

Do not add LuaRocks `external_dependencies.UV` in bundled mode: that would
incorrectly require a system developer package. In system mode, its
`UV_INCDIR`/`UV_LIBDIR` mechanism may be enabled by a separate rockspec variant
or build variable.

## Implementation phases

Each phase ends with focused tests, current-source rebuild, and
`git diff --check`. Do not begin the high-level breadth until the preceding
lifetime gate is green.

### Phase 0 - lock dependency and proof fixtures

Files:

- `Makefile`
- `.gitignore`
- `.github/workflows/ci.yml`
- `c-parser/cpp.lua`
- `c-parser/cdriver.lua`
- `titan-compiler/checker.lua`
- `titan-compiler/driver.lua`
- `spec/cdriver_spec.lua`
- `spec/cpp_spec.lua`
- `spec/coder/coder_spec.lua`
- optional `spec/fixtures/uv/`

Work:

- Add pinned `make libuv`, checksum verification, cleanup, help text, and cache
  inputs.
- Record and package the upstream libuv license for static redistribution.
- Add Linux/macOS platform link variables.
- Add `TITAN_EXTRA_CPPFLAGS`/`TITAN_EXTRA_CFLAGS`/`TITAN_EXTRA_LDFLAGS`
  plumbing across `c-parser/cpp.lua`, `c-parser/cdriver.lua`, the checker, and
  `titan-compiler/driver.lua`, plus `doc/implementation/driver.md`.
- Turn the native timer, FS, GC, loop-lifetime, and consolidated
  enqueue-return-extract-resume spikes into small repeatable fixtures/spec
  helpers.
- Assert `.sizeof`/`.alignof` + `lua_newuserdatauv` + pointer cast for every
  allocated libuv type on both supported platforms.

Exit criteria:

- A clean checkout with no system libuv can run `make libuv` on Linux and macOS.
- The archive is PIC and a trivial linked module has no dynamic libuv dependency.
- System mode fails early with useful package/prefix instructions when absent.
- A foreign header found only through `TITAN_EXTRA_CPPFLAGS` takes the same
  feature-macro branch in Titan's parser and in generated C compilation.

### Phase 1 - GC-owned low-level objects and native callbacks

Files:

- `titan/uv.titan`
- `titan-runtime/titan_uv.c`
- `titan-runtime/titan/uv.h`
- `spec/checker/uv_spec.lua`
- `spec/libuv_shim_spec.lua`
- `spec/coder/uv_spec.lua`

Work:

- Import public `uv.h`, Lua headers, `titan/ffi.h`, private shim header, and
  `coro`.
- Implement loop owner and operation owner userdata allocation in Titan with
  imported `.sizeof`.
- Implement fixed uservalue layouts and data association through public libuv
  getters/setters.
- Add concrete typed shim wrappers only where Titan rejects a libuv
  concrete-to-base handle cast; assert that each wrapper delegates to a public
  libuv API and contains no field access.
- Implement native trampoline pointer recovery and the catch-all dispatcher.
- Implement timer, close, FS, read/alloc, connect/write, DNS, process, and signal
  callback shapes incrementally; begin with timer + FS only.
- Add exact-length buffer helpers.
- Lock the public declarations in checker tests, reject any exported C type,
  and verify the same interface rehydrates from a binary-only `titan.uv`.

Exit criteria:

- Native path counters prove no callback uses a Lua entry wrapper.
- The consolidated path proves callbacks only enqueue, `uv_run` returns before
  extraction/resume, and cancellation without an operation callback still
  drains the close callback.
- Owner survives incremental and generational GC, including old owner -> young
  Task/buffer stores.
- Dispatcher failure never unwinds through libuv.
- Request/handle roots are released after, and only after, terminal cleanup.

### Phase 2 - scheduler, errors, shutdown, and timers

Files:

- `titan/uv.titan`
- `titan/timer.titan`
- `spec/coder/uv_spec.lua`
- `spec/coder/timer_spec.lua`

Work:

- Implement Runtime, Task, Request, Completion, per-task tag, ready queue,
  pending/resources maps, and fair loop driver.
- Implement `run`, `run_main`, `spawn`, `join`, cancel/status.
- Implement immediate failure, async failure, trace copying/reinstallation, and
  first-error policy.
- Implement close/cancel/drain and `UV_EBUSY` diagnostics.
- Implement sleep, zero-turn yield, and Ticker.

Exit criteria:

- Out-of-order timers wake the correct task exactly once.
- Nested tagged coroutine await and cancellation work.
- CPU-ready tasks do not starve timers.
- Root/child errors preserve both task and propagation traces.
- Repeated `run` cycles end with `uv_loop_close == 0` and no retained owners.

### Phase 3 - filesystem core

Files:

- `titan/fs.titan`
- `spec/coder/fs_spec.lua`

Work:

- Implement mode translation using `UV_FS_O_*`.
- Implement File state/serialization, open/read/write/flush/close.
- Implement whole-file helpers with checked chunk growth.
- Then implement stat/path operations and list.

Exit criteria:

- Success, missing path, permission/error, EOF, short read/write, empty file,
  embedded NUL, payload larger than one chunk, cancel, and close races pass.
- Cleanup counters prove one `uv_fs_req_cleanup` per request.
- No operation runs after close; double close is harmless.

### Phase 4 - task races and cancellation hardening

Before sockets/processes multiply handle types, complete the race matrix:

- completion before cancellation;
- cancellation before completion;
- `uv_cancel` success and failure/too-late cases;
- late callback after logical task death;
- callback after resource close request;
- root completion with live children;
- child error while another callback is queued;
- generational GC with old Runtime/owner and young task, buffer, error, and tag.

Add an ASan/UBSan CI job for the shim and focused library specs. Local sanitizer
availability is not assumed; CI is the release gate.

### Phase 5 - TCP and DNS

Files:

- `titan/net.titan`
- `spec/coder/net_spec.lua`

Work:

- Implement getaddrinfo ownership/cleanup.
- Implement TCP connect, binary stream read/write, shutdown, close.
- Implement server listen/accept and bounded accept queue.
- Implement excess buffering and one-reader policy.

Exit criteria:

- Loopback-only client/server tests cover IPv4 and available IPv6.
- Partial reads, read stop/restart, EOF, reset, failed connect, ordered writes,
  embedded NUL, and write-buffer GC stress pass.
- All handles close and the loop drains after both success and failure.

### Phase 6 - OS helpers, signals, and processes

Files:

- `titan/os.titan`
- `spec/coder/os_spec.lua`

Work:

- Implement portable `uv_os_*` helpers and checked resizing.
- Implement common signal-name mapping and one-shot wait.
- Implement Process + pipe ownership, wait/kill, and communicate/popen.
- Implement runtime shutdown policy for live processes.

Exit criteria:

- Tests use only owned child fixtures and temporary directories.
- stdout/stderr are drained concurrently; large dual-stream output cannot
  deadlock.
- exit code/signal, spawn failure, stdin close, cancellation, and forced runtime
  shutdown pass on Linux and macOS.

### Phase 7 - packaging, docs, and optional bootstrap follow-up

Files:

- `titan-dev-1.rockspec`
- `Makefile`
- `README.md`
- `CLAUDE.md`
- `doc/language/index.md`
- new `doc/language/async-io.md`
- new `doc/language/standard-library-{timer,fs,net,os}.md`
- `doc/language/coroutines.md`
- `doc/implementation/index.md`
- new `doc/implementation/libuv-runtime.md`
- `doc/implementation/coroutines.md`
- `doc/implementation/ffi-internals.md`
- `doc/implementation/driver.md`

Work:

- Install all namespaced modules and document both bundled/system libuv modes.
- Document synchronous appearance, cooperative scheduling, cancellation points,
  explicit close, errors, task policy, and unsupported operations.
- Correct coroutine implementation prose that still describes older callback
  rooting rather than the current handle-uservalue shape.
- Update the roadmap only when shipped behavior and tests justify it.

Optional auto-main gate, after the explicit API is stable:

- prefer an explicit compiler option or declared main convention;
- do not silently make every executable depend on libuv;
- preserve exact integer exit status and standalone trace reporting;
- add standalone tests before enabling it.

## Verification plan

### Focused suites

Add topical suites instead of growing catch-all files:

- `spec/libuv_shim_spec.lua`
- `spec/checker/uv_spec.lua`
- `spec/coder/uv_spec.lua`
- `spec/coder/timer_spec.lua`
- `spec/coder/fs_spec.lua`
- `spec/coder/net_spec.lua`
- `spec/coder/os_spec.lua`

Extend `spec/support/helpers.lua` once for native archives/objects, standard
module build order, environment flags, and standalone execution.

### Required behavioral coverage

- private loop and sequential runs;
- nested-run/main-thread rejection;
- two independent Lua states in one process;
- unique task tags and nested `stacked` routes;
- native callback path, callback catch-all, and trace preservation;
- immediate versus asynchronous error;
- incremental and generational GC;
- pending/resource root release verified with weak references;
- request cleanup and handle close order;
- cancellation and late callback matrix;
- binary strings, NUL, empty buffers, overflow/negative lengths;
- filesystem temp-directory cases;
- loopback networking only;
- owned subprocess fixtures and common signals;
- source import during development, binary-only installed import, Lua
  `require`, and standalone executable paths;
- checker rejection of C types in exported APIs; runtime rejection of forged
  opaque handles and handles/resources from another Runtime generation;
- bundled static and optional system libuv modes;
- Linux and macOS.

### CI and release gates

Linux push CI:

1. Install/verify CMake explicitly.
2. Build/cache pinned libuv.
3. Build/install the rock and standard modules.
4. Run focused sanitizer/lifetime job.
5. Run full coverage suite.

Manual macOS pre-merge CI:

1. Build the same pinned libuv, not an undeclared Homebrew runtime.
2. Run focused stdlib tests and full suite.
3. Verify `otool -L titan/uv.so` has no dynamic libuv dependency.

Final local gate:

```sh
CCACHE_DISABLE=1 make libuv
CCACHE_DISABLE=1 ./luarocks make
CCACHE_DISABLE=1 busted \
  spec/libuv_shim_spec.lua \
  spec/checker/uv_spec.lua \
  spec/coder/uv_spec.lua \
  spec/coder/timer_spec.lua \
  spec/coder/fs_spec.lua \
  spec/coder/net_spec.lua \
  spec/coder/os_spec.lua
CCACHE_DISABLE=1 make test
git diff --check
```

The full `make test` remains authoritative because an installed compiler
snapshot can otherwise shadow source edits.

## Completion checklist for the implementation

- [ ] Pinned libuv builds from a clean checkout on Linux and macOS.
- [ ] Optional system mode has tested discovery and useful failure messages.
- [ ] Runtime behavior uses public libuv APIs; no hidden POSIX I/O/process path.
- [ ] Loop/request/handle storage is Lua-GC-owned by default using imported
      `.sizeof`.
- [ ] All libuv data pointers refer to independently rooted owner userdata.
- [ ] Native callbacks use Titan native entry pointers, not Lua wrappers.
- [ ] No error can unwind through libuv.
- [ ] Scheduler resumes outside `uv_run` callbacks.
- [ ] Per-task hidden tags support nested coroutines.
- [ ] Cancellation runs Titan cleanup and tolerates late libuv callbacks.
- [ ] Every request/handle/loop reaches its documented terminal cleanup.
- [ ] Binary buffers preserve length and embedded NUL.
- [ ] Timer, file, TCP/DNS, OS/process/signal APIs match documented contracts.
- [ ] Namespaced modules work through Titan import and Lua require.
- [ ] Source, `.so`-only, and standalone paths are covered.
- [ ] Incremental, generational, sanitizer, Linux, and macOS gates pass.
- [ ] Both language and implementation manuals, README, CLAUDE, Makefile,
      rockspec, and CI are updated in the same change.

## Authoritative external contracts

- Libuv design overview: <https://docs.libuv.org/en/v1.x/design.html>
- Event loop and non-reentrancy: <https://docs.libuv.org/en/v1.x/loop.html>
- Handle close lifetime: <https://docs.libuv.org/en/v1.x/handle.html>
- Request and cancellation lifetime: <https://docs.libuv.org/en/v1.x/request.html>
- Filesystem requests and cleanup: <https://docs.libuv.org/en/v1.x/fs.html>
- Streams and buffer lifetime: <https://docs.libuv.org/en/v1.x/stream.html>
- Processes: <https://docs.libuv.org/en/v1.x/process.html>
- Official source/build/version policy: <https://github.com/libuv/libuv>
- Current Homebrew formula/setup alternative:
  <https://formulae.brew.sh/formula/libuv.html>
