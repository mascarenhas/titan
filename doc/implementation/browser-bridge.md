# Browser bridge runtime

The core JavaScript bridge uses the browser JSPI backend and the single
persistent image lifecycle. It adds no second coroutine driver and no native
message format, and JavaScript has no general synchronous call into Titan:
every application entry is a promised export. Two narrow entries are
synchronous and run in no-switch mode on a callback thread: [synchronous C
callbacks](#synchronous-c-callbacks) and [wrapper
release](#synchronous-wrapper-release). The bridge supplies the [drive
interface](#drive-interface-and-delivery) that a scheduler uses, not a
scheduler. The public Titan API is [JavaScript
bindings](../language/standard-library-browser.md); [the browser
target](browser-target.md) owns link profiles, the embedded loader, the
runner, deployment, and fatal engine classifications.

## Source ownership

| Owner | Files |
| --- | --- |
| Installed C layout and JS import contract | `titan-runtime/titan/browser.h` |
| Browser-only Titan API, pin table, foreign trampolines, and protected entries | `titan/browser.browser.titan` |
| Generated image launcher and weak C export forwards | `titan-compiler/browserentry.lua` and `driver.browser_entrypoint_contents` |
| JSPI owner, bridge imports, loader, trace adapter, and standalone portable peer | the five [JavaScript files](#javascript-files) under `titan-runtime/browser/` |
| Browser runtime/provider staging | `Makefile` and `scripts/browser_sdk.lua` |

There is no hand-written C runtime file for the browser bridge: `libtitan.a`
contains the same four objects (`titan.o`, `minicoro.o`, `titan_path.o`,
`ltitanlib.o`) on both native and browser targets. The native standard provider
has no `titan.browser`, while the twenty-one-module browser provider includes
it alongside fourteen shared modules and the browser compositions of `async`,
`timer`, `os`, `lua`, `http`, and `websocket`. It imports only `gc`, and the
[subset parity gate](browser-target.md#subset-parity-gate) does not compare
it because it has no native interface.

### JavaScript files

JavaScript does only what the host alone can do ([Keep C and the Lua C API to
what Titan cannot do](standard-library-maintenance.md#keep-c-and-the-lua-c-api-to-what-titan-cannot-do)). Each
shipped file is justified by the capability in its last column.

| File | Owns | Host capability |
| --- | --- | --- |
| `titan-browser-library.js` (`--js-library`) | The execution owner of one Module: the pending entry, the promising wrappers of the state-entering exports, one promise per coroutine context with its saved linear stack, the suspending imports (`titan_mco_transfer`, `titan_mco_destroy`, `titan_browser_relinquish`), the synchronous-callback depth, and poison | JSPI suspension and resumption; engine failure |
| `titan-browser-bridge.js` (`--js-library`) | The JavaScript half of `titan/browser.h`: one line per import, forwarding to the loader owner, including `titan_browser_host_output` for C stdio; the one-line `$getEnvStrings` override supplies the instance's environment snapshot. It keeps no state | Emscripten import glue; the embedder's libc environment input |
| `titan-browser.mjs` (embedded in each image) | The loader: `create` and `BrowserOwner`, in the parts listed below | See below |
| `titan-browser-trace.js` (`--js-library`) | The index read from the fetched `.wasm.trace` table, stack capture into C-owned records, and symbolization ([trace metadata](browser-target.md#eager-trace-loader-and-trace-metadata)) | Engine stack capture; fetching and reading the table outside the Wasm heap |
| `titan-protobuf.mjs` (standalone SDK module) | The portable protobuf peer: retains no per-call state, shares a class table only when the caller supplies one, and is not part of any image | Building and reading JavaScript values and classes: records, union variants, Arrays, BigInts, byte arrays, and strings |

The loader's parts:

| Part | Holds | Host capability |
| --- | --- | --- |
| Public object, admission, `operate`, `entry`, `initialize`, `run`, `dispose` | One promise per operation, the lifecycle state, the pending completion, which failure an operation reports, and the references that disposal must drop | The embedder-facing promise API; entering Wasm through a promising export |
| `create` environment snapshot | The embedder's `NAME=value` strings, empty by default, for Emscripten's later libc initialization | Holding and validating the embedder's option data |
| Slot table and `CallableView` wrappers | JavaScript values with their state, generation, and units; one wrapper per pin with its logical-release flag | Holding JavaScript values and host objects |
| Marshalling (`snapshotArguments`, `writeValue`, `valuesAt`, `completionAt`, `importResponse`) | Nothing between calls | Converting JavaScript values to and from the records of `titan/browser.h` |
| Queue (`queue`, `batch`) | Notifications, request events, and calls that wait for `drain()` or a drive, with each queued call's promise | JavaScript values that have no slot yet; items that wait for a point where Wasm can be entered |
| Pending Task-form calls (`openTasks`) | Delivered Task-form calls whose Task has not reported its outcome, with each call's promise | The embedder-facing promise API; promises waiting for a Titan-reported outcome |
| Requests | The detachable cell of each promise or listener continuation, the host cancel function, the ownership form, the completion and failure targets, and the terminal promise that disposal awaits; no callable hold accounting | Promise and listener continuations |
| Drive | The gate promise of the suspending import, the turn source, the owner token, and the exit latch | JSPI resumption; macrotask scheduling |
| `OutputChannel`, `output`, and `drainOutput` | One FIFO of copied C iovec batches and Titan write/end entries per stream, each Titan entry's settlement promise, one latched C sink error, at most one sink or end hook in flight, and C-only drains after image release; no per-byte buffer | Copying bytes out of the Wasm heap; the embedder's sinks/end hooks and their promise continuations |
| SDK sources (`titan:timeout`, `titan:interval`, `titan:driver`, `titan:stdout`, `titan:stderr`, `titan:stdin`, `titan:stdio`) | One bounded host timer per arm, the two driver callables, output-entry settlement promises, the optional input function, and declared backings; long-wait chunking belongs to `timer.browser.titan` | Host timer APIs; the embedder's byte source, sinks, end hooks, declared backings and promises |
| `titan:fetch` SDK source | Per session, one `AbortController`, the settled `Response`, and its `ReadableStreamDefaultReader`; nothing about headers, modes, or redirects | `fetch`, `AbortController`, and stream-reader promises; whether the host has an HTTP cache |
| `titan:websocket` SDK source | Per connection, the `WebSocket` object, its three named listeners, and one holder object per received message until Titan takes or closes it | The host `WebSocket` object, its event listeners, and its `readyState` and `bufferedAmount` |

`titan-browser-run.mjs`, `titan-browser-page.mjs`, and
`titan-browser-node-worker.mjs` are [the runner](browser-target.md#the-runner),
and `titan-browser-module-check.mjs` is the compiler's [module
check](browser-target.md#the-module-check): host tooling outside the image.

## Generated launcher and foreign-function trampolines

`browserentry.lua` and `driver.browser_entrypoint_contents` generate the image
launcher next to native `main`, following the [Titan-first native-binding
rules](standard-library-maintenance.md#keep-c-and-the-lua-c-api-to-what-titan-cannot-do):

1. **Shared launcher and error conversion (`browserentry.lua`):** Initialization
   creates the owner `lua_State *`, opens the Lua libraries, installs the Titan
   searcher and preloads, and requires the root module without calling `main`.
   `titan.browser` initializes in ordinary dependency order; images without it
   use a bare host state token. `titan_browser_entry` requires the launcher's
   ready owner, retrieves the initialized module from `LUA_LOADED_TABLE`,
   constructs its counted string Array, and runs `main`. The launcher keeps no
   one-shot flags of its own: the loader memoizes `initialize()` and admits
   `run()` once ([logical
   operations](browser-target.md#logical-operations-and-protected-entries)).
   Both entries run under `titan_browser_protected_entry` with plain
   `errorhandler` as the `lua_pcall` message handler. On failure,
   `titan_browser_complete_failure` snapshots `TITAN_BACKTRACE_KEY` on the
   stack, converts the final escaped error object once under `lua_pcall` using
   `titan_entry_error_message` and `strip_bootstrap_prefix`, shared with native
   `main`, restores the `TITAN_BACKTRACE_KEY` snapshot, writes
   `<progname>: <message>` and `stack traceback:` to `stderr`, and flushes the
   completion. Caught raises inside module initializers are never converted,
   and stale traces never leak into `main`. The owner state keeps
   `luaL_newstate`'s warning handler, including its prefix, warning controls,
   and multipart messages; its stderr output enters the byte queue. Loading
   `titan.browser` in an independent state preserves its creator's warning handler.
2. **One-line weak forwards (`titan_browser_invoke`,
   `titan_browser_release_callable`):** `browserentry.lua` declares
   `titan_browser_\u2133_invoke_titan` and
   `titan_browser_\u2133_release_callable_titan` as `__attribute__((weak))`. When
   `titan.browser` is linked into the image, `titan_browser_invoke` and
   `titan_browser_release_callable` forward in one line to those public
   `foreign function`s in `titan/browser.browser.titan`. In a C-only protocol
   or probe image without `titan.browser` the weak pointers are `NULL`: the
   promised invoke entry then reports an admitted failure through
   `titan_browser_invalid_entry`, and the synchronous release entry, which has
   no completion, returns `TITAN_BROWSER_STATE`. The C entries for
   [synchronous callbacks](#synchronous-c-callbacks) forward the same way.
3. **Foreign trampoline (`invoke`) and protected Titan entry (`invoke_entry`):**
   The public foreign function in `titan/browser.browser.titan` uses
   header-free C primitive parameter types so consumers of `"browser"` need no
   `foreign import`. The trampoline checks `titan_browser_entry_allowed`,
   recovers the `titan_browser_state_record *` through
   `titan_browser_host_state_record(token)`, checks admission and
   `lua_checkstack(L, LUA_MINSTACK)`, and writes a `"not enough memory"`
   completion if the stack check fails. It recovers the module (`upvalue[0]`)
   and entry pointer (`upvalue[2]`) from the handler closure, installs
   `errorhandler` as `L->errfunc`, calls `invoke_entry`, and restores the
   error handler and stack top. `release_callable` is a callback trampoline
   instead ([synchronous wrapper release](#synchronous-wrapper-release)).
4. **Minimal protected entry (`invoke_entry` -> `invoke_work`):**
   `invoke_entry` is a function-scope `catch` wrapper whose preamble fits
   inside the trampoline's `LUA_MINSTACK` reservation. Argument decoding,
   execution, rollback, and formatted error reporting run in `invoke_work`.
   The inner `catch` rolls back a provisional wrapper into `free_slots`,
   pre-grown during `allocate_pin`, before calling `complete_titan_failure`.
   If work raises
   at its own preamble or while reporting an error, the outer `catch` writes
   `"not enough memory"` into `state_record.fallback` through inline FFI
   writes, flushes both streams, and calls `titan_browser_complete`, without
   calling Titan helpers or allocating Lua objects.
   `error_message` formats non-string
   callable errors under its existing Titan `catch`, using the launcher's
   `titan_entry_error_message(L, index)` through the FFI. It reserves four
   temporary slots, pushes the error for that indexed conversion, copies the
   returned string into a traced local, and restores the saved top in `defer`.
   The shared converter handles strings/numbers, a string-valued `__tostring`,
   or `(error object is a <type> value)`; a numeric metamethod result is not a
   string. The original `traceback` local stays authoritative even if conversion
   runs user code or fails. No second protected C boundary is introduced.

| Export | Operation kind | Role |
| --- | --- | --- |
| `titan_browser_initialize(uint64_t)` | INITIALIZE1 | Generated protected bootstrap; the loader enters it once |
| `titan_browser_entry(uint64_t, int, argv, lengths)` | MAIN2 | Generated protected main; the loader enters it once |
| `titan_browser_invoke(uint64_t, state, slot, generation, argc, args)` | INVOKE3 | 1-line weak forward to `titan.browser` `invoke` |
| `titan_browser_close(uint64_t)` | CLOSE5 | Generated owner-held `lua_close` |

These four are the promised entries. `titan_browser_release_callable(state,
slot, generation)` is exported as well, but it is synchronous and has no
operation identity, kind, or completion ([synchronous wrapper
release](#synchronous-wrapper-release)).

`operation_id` is an instance-local never-reused unsigned 64-bit identity.
JavaScript uses a BigInt counter. It never wraps to zero: once the identities
run out, an operation is refused at the point where it would allocate one.
Export return values are admission only. Exactly one completion with
the same id/kind carries application values/status/errors, and the loader
settles only after both completion and promised-export/context retirement.
A private engine entry is not an application gateway. The loader uses
Emscripten's exported `_malloc` and `_free` for temporary argument buffers.

Close is deliberately different. The generated launcher clears its owner-state
pointer and invokes `lua_close` directly while the JSPI execution owner is
held, never a `lua_pcall` on the state being freed. The browser record's Titan
finalizer handles invalidation; C-only images close their bare host token
around `lua_close`. Lua's per-finalizer protection remains authoritative.
Warnings alone do not convert successful close into an application failure.
Both libc streams are flushed before completion; the loader then handles
copied stream queues and disposal outcomes.

The launcher also defines `titan_browser_owner_thread()`, a C function that
returns its owner `lua_State *` (set before any initializer runs, cleared
before `lua_close`). It is not a JavaScript export: `titan.browser`'s
initializer compares it once with its own state's main thread to decide
whether it initializes in the instance owner ([drive
interface](#drive-interface-and-delivery)).

## State records and the Titan pin table

The `titan.browser` module initializer allocates an
`owned *titan_browser_state_record` in its `state_record` module variable.
The userdata owns stable inline C storage. It is finalized through
`gc.finalizable<|value|>(state_record, state_finalize)`, using an ordinary Titan
function, not a foreign `__gc` callback. No bridge registry anchor, metatable
construction, or record lookup in the Lua registry is needed.

The initializer roots `invoke_entry` and `release_entry` (and the callback
entries `call_sync_entry` and `callback_entry`) in module variables, writes
their `TValue` closures and the module-owned fallback completion pointer into
the record, creates the first callback thread, then publishes its address with
`titan_browser_host_state_open`. That import assigns the opaque token and maps
`token -> record` in the JS owner's `stateRecords` table. No JavaScript
application API exposes a `lua_State *`, and there is no C static state list.

Finalization follows Lua's natural registration order. The record finalizer
runs after finalizers registered for values created after `titan.browser`
initialized, including its handles, callables, requests, and modules that
import it. It calls `mark_closing`, clears `state.token = 0`, and notifies
`titan_browser_host_state_closed(token)` exactly once, removing the state's
record, callable targets, notifications, requests, and JavaScript slot units.

An object's earlier-registered finalizer can run after the browser record.
At that point `BrowserHandle:close`, `BrowserRequest:close`, and JavaScript
callable release are no-ops, while binding lookup and calls raise. An uncaught
raise becomes a Lua finalizer warning on stderr. A zero token in a record that
has not finalized remains an admission failure, not a successful close.

The launcher does not initialize `titan.browser` specially. Independent states
created by `lua.new()` or C load it normally too: no `attach` operation or
pre-`luaL_openlibs` bootstrap is required. A `lua.new()` state shares the
WebAssembly instance but owns its own module records.
`state_closing()` and `current_state()` check `titan_state_closing(L)`
(`G(L)->gcstp & GCSTPCLS`) before imports, so a direct `lua_close` of an
independent state refuses new requests and reverse calls before a finalizer's
first binding call. Synchronous binding calls, copied output, and handle
release stay valid until the browser record is finalized. Wrapper release is
different: it is admitted as a callback is, so a closing state refuses it and
state close retires the pin. Every JS slot is charged to the state, including
slots created during close, when Lua suppresses new reachability finalizers.

`BrowserHandle` registers the allocation-free
`gc.finalizable<|value|>(owner, finalizer)` callback shape, initially with an
inert slot, then adopts the live unit.

Callable pinning lives entirely in `titan/browser.browser.titan` in per-state
module variables (`pins_by_slot: {Pin}`, `pins_by_fn: {value: Pin}`,
`free_slots: {integer}`, `slot_generations: {integer}`, and
`next_slot: integer`), with no `luaL_ref`, registry tables, or uservalue tables:

- One `Pin` and one JavaScript `CallableView` wrapper exist per function per
  state while live.
- Titan is the single authority for what holds each `Pin`:
  - `wrapper_live: boolean` records that a live JavaScript wrapper holds the
    pin (set when the callable crosses as `BrowserValue.is_callable` and
    JavaScript has no live wrapper for it).
  - `holds: integer` counts the other holders: a request or listener (one
    hold each for `completion` and `failure`, taken at `BrowserHandle:start` /
    `BrowserHandle:listen`) and an open `BrowserPin`.
- Each hold ends in Titan, once, and the loader keeps no hold accounting:
  - `wrapper.release()` enters `release_callable(state, slot, generation)`
    synchronously, which clears `wrapper_live` ([synchronous wrapper
    release](#synchronous-wrapper-release)).
  - A request's `RequestHolds` record drops its two holds together
    ([request holds](#request-holds)).
  - `BrowserPin:close` drops its hold ([synchronous C
    callbacks](#synchronous-c-callbacks)).

  `Pin:retire_if_unused()` then removes a pin with no wrapper and no holds
  from `pins_by_slot` and `pins_by_fn` and recycles its slot with the next
  generation.
- Every pin allocation and hold mutation is exception-atomic: `allocate_pin`
  undoes partial table insertions on raise before mutating `free_slots` or
  `next_slot`, and `pin_wrapper` / `pin_request_hold` allocate and append their
  `ProvisionalPin` rollback record before `allocate_pin` or mutating `Pin`.
- Exporting a function again after its wrapper was released creates a fresh
  `CallableView`. If the release retired the pin, the export allocates a new
  one. If another hold kept the pin, or the release was refused, the fresh
  wrapper takes over the existing pin.
- A newly registered callable wrapper starts with `exposed = false` in
  JavaScript and is marked `exposed = true` only when `valuesAt` finishes
  decoding that crossing's own arguments in `hostCall` or `hostStart` (right
  before invoking the host function) or when `receiveCompletion` decodes a
  successful completion result. A nested import triggered during marshalling
  (such as a GC finalizer calling another binding) exposes only the callables
  decoded by its own crossing. If a crossing fails before its own `valuesAt`
  completes, host calls and starts use `rollback_provisioned`, while invoke
  completions use `invoke_work`'s inline rollback. Both call
  `titan_browser_host_callable_closed`, which discards the unexposed wrapper
  and returns `1`, then retire the pin if unused. Once exposed to host JavaScript,
  `titan_browser_host_callable_closed` returns `0` and the wrapper stays live
  until its own `release()`.

## Drive interface and delivery

`titan.browser` exposes the primitives of a browser drive (`is_owner`,
`drive_begin`, `drive_end`, `relinquish`, `deliver`, `wake`; [language
contract](../language/standard-library-browser.md#driver-interface-low-level)).
They are ordinary Titan functions over trusted JavaScript imports: no C entry
drives, and `titan.browser` never learns about Tasks.

- **Owner identity.** The initializer sets the module variable `owner_state`
  once, comparing `titan_browser_owner_thread()` with the state's main thread,
  and, when true, reports its token with `titan_browser_host_owner`. A
  C-created state compares a different main `lua_State *` and is never the
  owner, whatever order states load `titan.browser` in. The loader records
  the reported owner token.
- **Drive state.** Two more module variables, `drive_active` and
  `delivering`, make the refusals structural: `drive_begin` requires
  `owner_state` and `L == lmacro_mainthread(L)` (not a coroutine thread);
  `deliver`, `relinquish` and `drive_end` require an active drive, the main
  thread and no delivery in progress. `drive_begin` and `drive_end` report to
  the loader through `titan_browser_host_drive_begin` and the nonthrowing
  `titan_browser_host_drive_end(state, status, exited)`, which latches an exit
  status (the low 32 bits as a signed value) so the driver can call it from a
  `defer`.
- **Main failure.** `main_failed(message, trace)`, owner state only, passes
  both strings to the nonthrowing `titan_browser_host_main_failed`, which
  marks the pending `run()` ([loader drives](browser-target.md#drives-the-call-queue-and-wake-sources)).
  Titan keeps no record of it.
- **Relinquish.** `relinquish(wait)` flushes C `stdout` and `stderr`, chooses
  the mode, and calls the suspending import
  `titan_browser_relinquish(state, mode)` ([relinquish
  import](browser-target.md#the-relinquish-import)); the import's resolved
  value is the status. The mode carries what Titan knows: `TURN` when `wait`
  is false, `WAIT_HELD` for a wait while the state has an open `BrowserPin`
  (`open_pins > 0`), and `WAIT` for any other wait. The loader therefore
  keeps no copy of the pin count.
- **Delivery.** `deliver` sets `delivering` for its extent and asks
  `titan_browser_host_batch` to snapshot the owner's queued items. For each
  one, `titan_browser_host_item` passes over an item whose target was
  released or whose request was cancelled, marshals the arguments, and fills
  a `titan_browser_delivery` record, which `deliver` handles by kind:
  - `NOTIFY` and `CALL` run through `invoke_work`, the same body as an
    `invoke` entry, with `queued = true`: the completion record goes to
    `titan_browser_host_settle` instead of `titan_browser_complete`, because
    the entry that hosts the drive still owns the one ordinary completion. An
    inline `catch` around each item keeps `invoke_entry`'s allocation-free
    fallback, settling through the same import, so an item never leaves the
    delivery half done. `titan_browser_host_item_done` then frees the item's
    host allocations and releases unadopted temporaries.
  - `UNDELIVERED` names a request's failure event that the loader could not
    marshal ([request boundary](#request-boundary)). It carries the target
    identity and nothing else: no arguments, no settlement, and no
    `item_done`. `drop_undelivered` finds the pin and, for a one-shot, drops
    the request's holds. A listener's pin names no `RequestHolds`, so its
    holds stay.

  The loader deals with every other item that it cannot marshal without
  handing it to Titan: a call's promise rejects, a request's success event
  becomes its failure event at the end of the live queue, and a plain
  notification is reported through `onNotificationError`.
- **Wake.** `wake` calls `titan_browser_host_wake(state)`; the loader ignores
  it unless that state is driving.

## Synchronous C callbacks

An Emscripten API calls C synchronously from JavaScript, so Titan code in such
a callback runs below a JavaScript frame and cannot suspend ([language
contract](../language/standard-library-browser.md#synchronous-c-callbacks)).
`titan.browser` provides the pin, the C entry and its bracket; core modules
learn about the callback only through `titan_no_switch`.

- **Pins.** `pin(fn)` adds one hold to the function's existing `Pin`
  (`holds`, as a request hold does, allocating the pin when the function has
  none) and returns a `BrowserPin` record with the state token, slot and
  generation. The record registers the allocation-free `gc.finalizable`
  shape, so an unreachable pin closes. `BrowserPin:close` is idempotent: it
  drops the hold and calls `retire_if_unused`.

  An open pin is a [wake
  source](browser-target.md#drives-the-call-queue-and-wake-sources) for the
  owner's drive, and Titan keeps that fact too. The per-state module variable
  `open_pins` counts open `BrowserPin`s: `pin` increments it once the record
  holds its slot, and `close` decrements it. `relinquish` passes `WAIT_HELD`
  while the count is above zero, so the drive parks even when the loader
  knows no wake source. Closing the last pin calls `wake`: the parked gate
  resumes with `RESUMED`, and the drive's next wait finds out whether a wake
  source remains.
- **C entries.** `browserentry.lua` declares `call_sync`, `callback_enter`
  and `callback_leave` as weak, like the invoke and release forwards, and
  defines the C functions `titan_browser_call_sync`,
  `titan_browser_callback_enter` and `titan_browser_callback_leave` that
  forward to them. They are C entry points for authored C in the image, not
  JavaScript exports. Without `titan.browser`, the first two return
  `TITAN_BROWSER_STATE` and the third does nothing.
- **Admission.** The three synchronous entries (`call_sync`,
  `callback_enter`, and the [release
  trampoline](#synchronous-wrapper-release)) start with one helper,
  `callback_begin`. It refuses without entering Lua in four cases, tested in
  this order:
  1. The token names no open, configured state record (`callback_state`:
     record lookup through `titan_browser_host_state_record`, then the
     closing and configured checks).
  2. `titan_browser_host_callback(state, 1)` refuses. That import admits
     unless the bridge library is poisoned or the loader's `callbackAdmit`
     refuses (closing, exited or terminal), and it increments
     `$TitanBrowser.callbackDepth` on admission.
  3. The state has no callback thread to give, because callbacks nest too
     deeply.
  4. `LUA_MINSTACK` cannot be reserved on that thread.

  The first three return `TITAN_BROWSER_STATE` with the reason as text, and
  the fourth returns `TITAN_BROWSER_MEMORY`. A refusal after the import
  admitted the entry ends that admission. Each entry answers a refusal in its
  own way: `call_sync` copies the reason into a `malloc`'d message of its
  result, and the bracket and the release trampoline return the status alone.
- **Callback threads.** The state record gains `callback_handler` and
  `call_sync_handler` (`TValue` entries like `invoke_handler`),
  `callback_next` and `callback_depth`. A callback runs on its own Lua thread,
  so its `CallInfo` chain, error jumps and traceback stay apart from parked
  drive and coroutine frames. `callback_threads` (a module variable of
  `CallbackThread` records holding each thread and its `lua_State *`) keeps
  one thread per nesting level. The initializer creates level 1 and publishes
  it as `callback_next`. `callback_begin` takes `callback_next`, reserves
  `LUA_MINSTACK` on it, increments `callback_depth` and clears
  `callback_next`; the entry then installs `errorhandler` and runs its
  handler on that thread. The handler's first
  step, `prepare_callback_thread`, publishes the next level's thread,
  creating it once (`titan_newthread` in a stack transaction) on first use.
  `callback_finish` then restores the depth, republishes the thread and
  calls `titan_browser_host_callback(state, -1)`. Nested callbacks take
  levels in LIFO order, and the steady state allocates no threads.
- **Running the callable.** `call_sync_entry`, a function-level `catch`
  around `call_sync_work`, reports `TITAN_BROWSER_MEMORY` if even that
  preparation fails. `call_sync_work` looks the pin up by slot and
  generation (a stale identity raises `"browser callable is released"`),
  decodes the arguments with `decode_value`, checks handle and callable
  arguments are live, and calls the function. A HANDLE argument is borrowed
  from C: its new `BrowserHandle` takes a unit of its own through
  `titan_browser_host_retain` (the loader's `retainSlot`) instead of
  adopting the slot, so closing or collecting it leaves C's unit in place.
  `encode_sync_result` encodes
  the one result and copies STRING and BYTES bytes into `malloc`'d memory. A
  callable result's provisional JavaScript wrapper is rolled back at once,
  since no wrapper will hold it, so C's copy stays valid only while another
  holder pins the function. A raise fills `TITAN_BROWSER_TITAN_ERROR` with
  `malloc`'d copies of the message and raw traceback. A copy that cannot be
  allocated, of the result, the message, the trace or `sync_refuse`'s
  refusal message, reports `TITAN_BROWSER_MEMORY` instead, with the other
  copies freed and no value.
- **Bracket.** `callback_enter(state, frame)` runs the same admission and
  thread selection for a standard library's hand-written trampoline and
  returns the thread in `frame->L`; `callback_leave(frame)` restores the depth
  and the next thread and ends the admission. The trampoline then follows
  the raw Lua C API rules of the [standard-library maintenance guard-rails](standard-library-maintenance.md#keep-c-and-the-lua-c-api-to-what-titan-cannot-do).
  It is not an application API.
- **No-switch mode.** `titan/ffi.h` defines `titan_no_switch(L)` for wasm
  builds as the import `titan_browser_in_callback()`, true while
  `callbackDepth > 0`, and as the constant 0 natively. The flag is per
  instance because the engine stack that cannot suspend is the instance's
  one stack, whichever Lua state the callback entered. `coroutine` and
  `async` consult it to refuse or defer switches
  ([coroutines](coroutines.md#synchronous-callbacks)).
- **Switches that escape the check.** In the bridge library, `transfer`,
  the suspending path of `destroy` and `relinquish` refuse a switch when no
  promising entry holds the owner or a callback runs (`switchRefused`): they
  poison with `TITAN_BROWSER_PROTOCOL`, `"Titan stack switch outside a
  promising entry or inside a synchronous callback"`, and throw to the
  callback's caller. V8 throws its `SuspendError` before it calls the import
  at all, so the bridge also checks after the fact: the first admission of a
  callback queues a microtask, and no microtask runs while a callback is on
  the stack, so a depth still above zero then means a callback ended by an
  exception without its leave (`callbacksLeft`). That poisons with
  `"a synchronous C callback ended by an exception"`.
- **Linear stack.** A callback's C frames use the linear stack of the code it
  interrupted: the main stack, a Task's 256 KiB coroutine stack for a
  callback nested in a binding that Task called, or, from a microtask between
  two internal coroutine hops, possibly a coroutine's stack. Titan keeps no
  C-stack counter of its own and Lua's `LUAI_MAXCCALLS` starts afresh on a
  callback thread, so Emscripten's checked stack is the limit; overflowing it
  aborts and poisons the instance.

## Synchronous wrapper release

`wrapper.release()` invalidates the wrapper in JavaScript at once and then
tells Titan, in the same call, to drop the wrapper's hold on the pin. Unless
the instance is disposing or poisoned, the loader calls the export
`titan_browser_release_callable(state, slot, generation)` directly. This is
the bridge's one synchronous entry from the loader. It takes no operation
identity and writes no completion, and the loader ignores its status: a
release that Titan refuses is not an error ([refused
releases](#refused-releases)).

### The trampoline

The export forwards to the `foreign function` `release_callable`, which is a
callback trampoline like `call_sync` ([synchronous C
callbacks](#synchronous-c-callbacks)). It starts with the shared
`callback_begin`: find the open, configured state record, ask
`titan_browser_host_callback(state, 1)` for admission, take the state's next
callback thread, and reserve `LUA_MINSTACK` on it. It then installs
`errorhandler`, calls `release_entry`, restores the error handler and the
stack top, and ends the callback with `callback_finish`. The body therefore
runs in no-switch mode, apart from the frames of a parked drive or
coroutine.

`release_entry` is a function-scope `catch` around `apply_release`.
`apply_release` finds the pin by slot and generation, clears `wrapper_live`,
and, when no hold remains, removes the pin from both tables and appends its
slot to `free_slots`, whose capacity `allocate_pin` reserved. It allocates
nothing, calls no import, and runs none of the program's code. The entry
does not publish a thread for a nested callback, because nothing in it can
start one.

### The collector stop

The body allocates nothing, but that alone does not keep the collector out.
A compiled Titan function that reserves root slots polls the collector when
it is entered, and the poll runs a step whenever one is due from earlier
allocation. A step can call finalizers. Inside `release()` a finalizer would
run program code in the middle of the embedder's call, and it could export
the function that is being released: the loader would create a fresh wrapper
for the pin, and `apply_release` would then clear `wrapper_live` and retire
the pin under that wrapper.

So the trampoline stops the collector for the extent of the entry. It reads
`G(L)->gcstp` (`lmacro_get_gcstp`), writes the saved bits plus `GCSTPGC`
(`lmacro_set_gcstp`), calls the entry, and writes the saved value back. Lua's
`GCTM` brackets every finalizer call the same way. Restoring the saved bits,
instead of restarting the collector, has three consequences:

- a pause that the program set with `gc.pause()` survives the release;
- a release made from inside a finalizer leaves that finalizer's own stop in
  place;
- the collector's debt is untouched, so a step that was due runs at the first
  poll after the release returns, and pacing does not change.

`titan_in_finalizer` reads `GCSTPGC`, so it is true inside the entry
([finalizer context](coroutines.md#finalizer-context)). Nothing in the entry
consults it.

The bracket is exact only if no raise can skip the restore. `release_entry`
reserves its own small frame before its `catch` begins, so that frame must
fit in what is left of the `LUA_MINSTACK` reservation after the pushed error
handler takes one slot. `apply_release`'s larger frame is reserved inside the
`catch`: when the stack cannot grow for it, the raise is caught and the pin
stays.

### Refused releases

`release_callable` returns `TITAN_BROWSER_STATE` when the state record or the
callback admission refuses, and `TITAN_BROWSER_MEMORY` when the callback
thread's stack cannot be reserved. In those cases, and when `release_entry`
catches an error, the wrapper hold is not dropped. The pin then stays in the
table until its state closes, or until the function is exported again and a
fresh wrapper takes the pin over. Nothing is retried, queued, or reported.

The admission rule is the callbacks' rule, so one rule covers every
synchronous entry: a closing or unconfigured state, a disposing, exited, or
poisoned instance, and callbacks nested too deeply all refuse. The loader
does not even call the export once disposal has begun or the instance is
poisoned. A JavaScript exception from the export poisons the instance.

## Fixed wasm32 layout

The installed header is the sole C/JavaScript layout contract. C layout
assertions check sizes and offsets for wasm32. There is no native packet
serialization, schema codec, attachment index, or per-call JSON/protobuf step.

The header also declares `titan_browser_host_output(stream, bytes, length)`.
The generated launcher's libc adapter passes descriptor 1 or 2 and one
nonempty iovec. The import copies the counted bytes into that stream's queue
before returning, never starts a sink, and retains no borrowed Wasm pointer.

Kinds are `NIL = 0`, `BOOLEAN = 1`, `INTEGER = 2`, `FLOAT = 3`, `STRING = 4`,
`BYTES = 5`, `HANDLE = 6`, `CALLABLE = 7`, and `REQUEST = 8`. `REQUEST` is the
import result kind for `host_start`. Statuses are `OK = 0`, `TITAN_ERROR = 1`,
`JS_ERROR = 2`, `STATE = 3`, and `MEMORY = 4`. All fields below use unsigned
32-bit widths unless specified otherwise.

### `titan_browser_value` — 32 bytes, alignment 8

| Offset | Field | Meaning |
| --- | --- | --- |
| 0 | `kind` | Exact discriminant |
| 4 | `state` | Handle/callable owner token |
| 8 | `scalar` | Union: signed i64 integer/boolean, f64 number; unused for other kinds |
| 16 | `bytes` | wasm32 byte pointer |
| 20 | `length` | Exact byte count |
| 24 | `slot` | State-local handle/callable slot |
| 28 | `generation` | Exact live generation |

### `titan_browser_delivery` — 32 bytes, alignment 8

| Offset | Field | Meaning |
| --- | --- | --- |
| 0 | `id` | Unsigned 64-bit item identity for `item_done` and settlement; zero for `UNDELIVERED` |
| 8 | `kind` | `NOTIFY = 1`, `CALL = 2`, or `UNDELIVERED = 4` |
| 12 | `slot` | Target callable slot |
| 16 | `generation` | Its generation |
| 20 | `argc` | Argument count; zero for `UNDELIVERED` |
| 24 | `args` | Host-owned array valid until `item_done`; absent for `UNDELIVERED` |

Relinquish modes are `TURN = 0`, `WAIT = 1`, and `WAIT_HELD = 2`; statuses
are `RESUMED = 0`, `IDLE = 1`, and `DISPOSING = 2`.

### `titan_browser_response` — 56 bytes, alignment 8

| Offset | Field |
| --- | --- |
| 0 | status |
| 4 | state, filled on every status |
| 8 | 32-byte result value |
| 40 | malloc-owned message pointer |
| 44 | message length |
| 48 | exact thrown-value slot |
| 52 | thrown-value generation |

Potentially throwing imports always return normally after filling this
zero-initialized response. With a real thrown-value unit, Titan checks status
and raises `browser.BrowserError` after return, retaining that exact value. A
`MEMORY`/error response without a thrown unit instead raises an ordinary
protected memory/diagnostic error before constructing an owner; zero
slot/generation never reaches trusted adoption. Message and `STRING`/`BYTES`
result buffers are freed by `response_dispose` in `titan/browser.browser.titan`
on every path. Unadopted `HANDLE`, `REQUEST`, and thrown-value units are
released there too; wrappers clear fields when their completed Titan owner
adopts a unit. Thus allocation while building a Titan owner/error cannot leak
an unowned host slot.

For reverse-call `BrowserHandle` arguments, each slot is created temporary
(`entry.temporary = true`), before any later argument can fail to marshal.
`new_handle` rejects an absent
identity, registers its inert finalizer, and checks the actual host unit again
after that potentially allocating setup before trusted
`titan_browser_host_adopt(state, slot, generation)`, which clears
`entry.temporary = false`. `invokeTarget`'s `finally` block releases only slots
whose `entry.temporary` is still `true`, so a callback may store an adopted
`BrowserHandle` and then raise without invalidating the stored handle. Slots
never adopted are released on failed delivery. Trusted adoption, release, state,
and callable-registration imports are nonthrowing. Close validates its
potentially raising state access before clearing an owner's slot; a contained
admission failure leaves the original ownership available for retry.

### `titan_browser_completion` — 48 bytes, alignment 8

| Offset | Field |
| --- | --- |
| 0 | unsigned 64-bit operation id |
| 8 | operation kind |
| 12 | status |
| 16 | signed 32-bit application status |
| 20 | exact result count (`1` for `INVOKE`, `0` otherwise) |
| 24 | result-slot pointer |
| 28 | message pointer |
| 32 | message length |
| 36 | original raw trace pointer |
| 40 | trace length |

The completion import copies arrays/bytes synchronously while all Lua owners
are still rooted. Missing, duplicate, wrong-id, or wrong-kind completion is
protocol corruption, not an ordinary binding error. A fulfilled export promise
never substitutes an application result.

Inside `operate('call', ...)`, `invokeTarget` boxes the single decoded result as
`{value}` so that internal operation completion, `this.active` release, and
`dispose()` never await a thenable returned inside a `BrowserHandle`. The
public `instance.call` and `wrapper.call` methods unwrap `.then(box =>
box.value)`, resolving to the bare value.

## Runtime-type marshalling and UTF-8 / byte rules

Both directions marshal by runtime type into `BrowserValue`:
- `null` and `undefined` map to `is_nil()`, which returns to JavaScript as
  `null`.
- Booleans map to `is_boolean`.
- Signed 64-bit `BigInt` values map to `is_integer`; `Number` values map to
  `is_float` (preserving NaN, `-0`, and integral floats). Neither direction
  coerces a `Number` to an integer.
- JavaScript strings must be well-formed UTF-16 (`String.prototype.isWellFormed`);
  lone surrogates raise `TypeError` at marshalling. Valid strings are UTF-8
  encoded as `TITAN_BROWSER_STRING` (`is_string`). Outgoing `is_string` values
  are validated as UTF-8 in Titan before crossing into C/JS imports (so invalid
  UTF-8 raises an ordinary catchable Titan error with traceback and never
  poisons `receiveCompletion`) and decoded in JavaScript with
  `TextDecoder('utf-8', {fatal: true, ignoreBOM: true})`, preserving a leading
  `U+FEFF`.
- Genuine `Uint8Array` views (identified via the `%TypedArray%` `@@toStringTag`
  getter, without invoking Proxy traps, iterators, accessors, or species hooks)
  are copied as `TITAN_BROWSER_BYTES` (`is_bytes`) and return to JavaScript as
  `Uint8Array` copies.
- Live same-state `CallableView` wrappers cross as `TITAN_BROWSER_CALLABLE`
  (`is_callable`), recovering the original pinned Titan function.
- All other JavaScript values (including plain objects, arrays, `Error`s,
  `Promise`s, `Proxy`s, and JavaScript functions) cross as
  `TITAN_BROWSER_HANDLE` (`is_handle`).

## Request boundary

`host_start` receives target identity, counted `titan_browser_value` arguments,
completion and failure slot/generation pairs, mode `START = 0` / `LISTEN = 1`,
and a response pointer. The request slot is reserved before argument decoding
and host invocation. The loader then queues one event per outcome:

- A one-shot `start` settlement queues one argument for `completion`: the
  resolved value marshalled by runtime type, with `undefined` mapped to
  `is_nil`.
- Each `listen` emission queues its arguments for `completion`, marshalled by
  runtime type.
- A rejection queues `(is_string(message), is_handle(thrown))` for `failure`.
  `thrown` always gets a handle slot, even for a primitive.
- A success event that cannot be marshalled becomes a failure event whose
  `thrown` is the marshalling error. The arguments are snapshotted when the
  event is queued and written into Wasm memory when it is delivered, and
  either step can fail: an out-of-range `BigInt` fails the first, and a
  wrapper argument released in between fails the second. A failure found at
  delivery is appended to the live queue, behind the events already waiting,
  so it arrives in a later batch. Nothing is retried in place.
- A failure event that cannot be marshalled has no callable left to receive
  it. The loader reports it through `onNotificationError`.

`browser.failure_text(message, thrown)` is the shared Titan-side consumer for
failure callbacks that need only a diagnostic. It closes an `is_handle`
thrown value and returns an `is_string` message, or nil otherwise.
The timer and OS adapters supply their own fallback text and construct their
own `OperationError`; neither duplicates handle disposal or message extraction.

Detachable mailbox and guaranteed-terminal retained ownership, cancellation,
listener removal, late-settlement dropping, FIFO batching, and disposal all
remain with the JS bridge owner. No C import awaits host work.

The SDK stream sources use this same boundary. Output sources return a
retained promise tied to their FIFO entry; the optional stdin source calls
the embedder synchronously under `hostInvoke` and turns either a return or
throw into a detachable promise outcome. `valuesAt` already copies a bytes
argument, so output admission does not copy it again. A missing SDK source
(`titan:stdin` without an option) yields the ordinary unknown-binding error.
`titan:stdio` is an ordinary synchronous call returning an option value.

The network sources use the same boundary and take the operation name as
their first argument. `titan:fetch` answers `has-cache`, `new`, and `close` as
ordinary calls and starts `open` and `read` as detachable requests whose
cancel function aborts the session's controller; the `http` client also
closes the session itself, because once `open` has settled with headers the
bridge retires that cancel function while the body stream is still open.
`open` takes its fixed arguments first and the header pairs last, as
alternating copied byte values that become Latin-1 `ByteString`s without
inspection, because a `BrowserValue` has no Array variant; it completes with
one byte string of NUL-terminated fields (status, `redirected`, status text,
URL, `Response.type`, then each header name and value), and Titan alone tells
`opaqueredirect` from `opaque`. `titan:websocket` takes subprotocols the same
way, as trailing strings, and registers `connect` as a listener whose
unregister function removes the three DOM listeners before it closes the
socket. A message event carries a holder handle instead of bytes, so a message
that Titan refuses by length never enters Wasm memory. Neither source holds
policy: header checks, `Set-Cookie` filtering, the `only-if-cached` gate,
redirect normalization, the read limit, write backpressure, and every error
classification are Titan's ([HTTP browser client](http-library.md#browser-client),
[WebSocket browser client](websocket-library.md#browser-client)).

`drain()` and a drive's `deliver` each work on a detached batch, so both
recheck an entry's request before invoking it. Cancellation removes the
request's entries from the live queue, including the queued event of a
one-shot that has already settled, and the recheck silences entries that a
detached batch already holds. Retirement on the host side alone cancels
nothing: a one-shot that settled normally still delivers its queued event.

### Request holds

`titan.browser` owns the holds that keep a request's `completion` and
`failure` pinned, and the loader keeps no count. `BrowserHandle:request`
allocates the inert `BrowserRequest` and its `RequestHolds` before the host
accepts the request and only assigns fields afterwards, so nothing can raise
between acceptance and ownership. `RequestHolds:drop` then releases both
holds, once:

| Event | One-shot (`start`) | Listener (`listen`) |
| --- | --- | --- |
| The callback returns or raises | drops | keeps |
| `BrowserRequest:cancel`, once the cancel import returns, also when the host's cancel function threw | drops | drops |
| `BrowserRequest:close`, once the request slot is released | drops | drops |
| A drive hands the failure event back as `UNDELIVERED` | drops | keeps |

State close needs no drop: the pin table goes with the state.

A one-shot gets the first row by pinning two fresh closures instead of the
caller's functions. Each closure calls the caller's function under a `defer`
that drops the holds, and each of the two pins names the `RequestHolds` in
its `request` field, which is how `drop_undelivered` finds them. A listener
pins the caller's functions directly.

Two failures leave a one-shot's holds in place until the request is closed or
its state closes, because no Titan code runs for the event. One is the double
fault in an idle `drain()`, which has no drive to hand the item back to. The
other is a failure inside `invoke_work` before it calls the callback, such as
a handle argument that is no longer live.

## Test layers

Public behavior belongs to the browser-target native Titan owner under
`spec/stdlib/titan/browser/`, linked against the real JavaScript bridge and
explicit test bindings. Its native cases cover exact scalars, UTF-8 strings
(including leading `U+FEFF` and invalid-UTF-8/lone-surrogate rejection),
copied bytes, original captures, wrapper identity and round-tripping, GC
finalizers, cross-entry/STACKED resumption, hidden allocation cleanup,
provisional pin rollback (including allocation failures and host-retained
wrappers), requests, and C stdio output. A test-owned C fixture constructs
independent Lua states, loads their modules normally, and exercises explicit,
GC, and detach-then-later close. User-module finalizers close handles before
record invalidation; an earlier object's finalizer verifies inert close and
release, followed by the expected binding-error warning. The same owner checks
that the owner state reports `is_owner()`, that a C-created state does not and
cannot begin a drive, and that the drive members refuse outside a drive or
from a coroutine. Its synchronous-callback cases call `call_sync` and the
bracket from inside an entry: arguments and results, Titan errors as a status,
every refusal, callback threads reused per nesting depth (no main thread, so
no drive), `titan_no_switch` set only inside a callback, pins held until
closed or collected, callable results that follow their holders, and
`TITAN_BROWSER_MEMORY` for each C-heap copy that fails (the test image's C
fixture wraps `malloc` to fail one call).
Initializer failure has a separate real Titan image with a
suspended cleanup coroutine and `main` error-conversion checks.

`browser.portable_tests`, in
`spec/stdlib/titan/browser/portable_tests.browser.titan`, is a separate native
owner requiring host bindings rather than the ordinary browser stdlib gate.
`spec/fixtures/browser_bridge/portable.mjs` first runs `peerTests()` from
`portable-peer.mjs`, then exchanges real-image `BrowserValue.is_bytes` values
with the SDK's standalone `titan-protobuf.mjs`. The bridge spec stages the
installed peer beside the driver; neither the loader nor bridge libraries
import it.

The driver checks both directions against independently constructed values
and Titan-produced golden bytes: generated record and variant classes, i64
and float tags, binary and marked text, Array holes and constness, dynamic
arms and closed nominal sets, repeated and recursive graphs, public record
construction, encode-only views, private variants, and refusal without
running transfer hooks. It checks shared class tables and recovery after
both peer and Titan errors. A 33,554,433-byte payload, more than twice
`browserlink.lua`'s default `initial_heap`, crosses in each direction, the
inbound one in a fresh instance. A fixture callable reports the public
Emscripten `emscripten_get_heap_size()` result before and after, so the
driver asserts that memory grew from below the payload length to at least it,
without exposing the loader's private Module. Encode/decode timings for
10,000 integers are informational. All rows
run under Node and Chromium with both assertion profiles.

The same gate uses a separate ordinary owner, `browser.public_state_tests`,
to create children through public `lua.new`. Its image imports Lua and thus
registers async's owner driver; the legacy C-state image retains its original
no-driver composition and operation-identity exhaustion checks. A child loads
`browser.public_state` through its preload snapshot, creates handles and
requests, and publishes a callable. Explicit close, wrapper collection, and
detach followed by test-owned `lua_close` each discard a queued notification
and request settlement; late settlement and later wrapper calls are refused
before Lua entry. Detach first leaves calls and notification delivery live.
Fixture-only JavaScript instrumentation counts every host callable record,
handle/request slot identity and ownership unit through retirement, including
duplicate-free checks. These are host callable-record counts, not observations
of Titan's private pin table. Public pins and close idempotence are checked
while the child is live. An earlier object's finalizer then verifies inert
handle, request and pin closes followed by a binding-error warning. The parent
and another public child remain usable, and instance disposal succeeds.

Drives themselves are exercised by `spec/coder/browser_scheduler_spec.lua`
with the fixture `spec/fixtures/browser_scheduler/`: a test-owned mini driver
(`mini_driver.titan`) runs "jobs" in place of Tasks over the drive interface
and registers `titan:driver` callables that follow the `async` spawn and
settle protocol, a test-only C helper creates a child state
(`mini_child.titan`) and publishes loader observations, and
`mini-driver.mjs` checks turn and wait relinquishes, idle detection,
delivery, queued and refused calls (including one made between internal
coroutine hops), Task-form calls with `AbortSignal`, the SDK timer sources,
output at relinquish points (on both streams, a sink call still pending when
the next gate publishes output and released at swept points around the pump
runner's retirement, no sink call started by a held call that settles during
a later turn's coroutine switches, including over large C-output batches, and
no sink during the coroutine switches that follow an `IDLE` relinquish),
disposal with a running, cleanup and shutdown drive, the exit latch, an open
`BrowserPin` keeping a waiting drive parked until a C callback settles its job,
and authored C that switches stacks inside a callback (idle, from a parked
drive, and nested in a binding), under Node and Chromium in both assertion
builds. The fixture's C helper fires callbacks through its Wasm table entry,
as an Emscripten API does.
`mini-driver-abort.mjs` forces a checked C-stack overflow during a drive.
`admission.mjs` runs the admission matrix of the loader: every application
method, wrapper release, `_malloc`/`_free` and the trace view, each from a
parked wait, a macrotask between turns, a microtask between internal coroutine
hops, and a binding the drive invoked. Release also runs from a synchronous
callback's binding, with capture collection checked in each context.
It also covers owner and other-state request
settlements (the harness settles the child state's request only after the
owner parked, and the owner takes no turn for it), `dispose()` from each of
those contexts, and the idle-instance
rows (entries start after the calling method returns; `notify()` waits for a
later `drain()` or drive). The synchronous-callback rows fire callbacks from a
parked wait, between turns and nested in a binding, then check the
idle-instance rows of entries from a callback's binding and from its caller,
`notify()`, `dispose()`, a nested callback, and a callback after disposal.
`measure.mjs` is run by hand,
never by the spec (`titan-browser-run --js-test measure.mjs -- <image>`): it
prints a `MEASURE` line with macrotask chain costs (`setImmediate`,
`MessageChannel`, `setTimeout(0)`), the per-turn cost of drives with 1 and 64
jobs, the wake latency from `notify()` to delivery in a parked drive, and
`call()` round trips on an idle instance and into a parked drive, in
microseconds.
The same spec builds the real `async` driver's scheduler gate, the browser-only
test owner `spec/stdlib/titan/async/browser_tests/`, with a C helper
(`scheduler_child.c`) that creates child states loading
`spec/stdlib/titan/async/browser_child.browser.titan`. `scheduler.mjs` runs its
Titan cases (Tasks over host requests across hundreds of turns, inline
registrations, cleanup under cancellation, fatal and ordinary failures,
combinators, channels and a listener-fed subscription, nested coroutines,
child-state refusals, the `timer` cases, and the synchronous-callback cases).
- **Public-state ownership:** the same child refusal module loads through
  `lua.new`, with no owner Runtime and with an owner request held pending.
  `async.loop` and Task creation refuse, including calls from an owner Task;
  synchronous child computation still succeeds. Initializing the child while
  an owner notification is queued does not deliver it or replace the driver:
  owner request completion, notification delivery, and later Task-form calls
  keep progressing.
- **Timer cases:** sleeps mixed with host requests, and zero delays and yields
  that resume in a later browser task, shown by a marker armed on the driver's
  turn source having run. Sleeps, tickers and a ticker left open past its
  Runtime leave no JavaScript timer armed. Long sleeps and ticker periods
  chain bounded chunks, never fire early, and clear the current chunk on
  cancellation or close; each long ticker re-arms its whole period before
  publishing. The shared harness spy holds long delays for manual firing and
  counts pending timers.
- **Synchronous-callback cases:** they run in `browser.call_sync`.
  - Coroutine switches raise, also from inside a coroutine, and the current
    coroutine and Task are hidden.
  - A coroutine collected in a callback unwinds, in order, at the next
    collection.
  - A settlement, `async.run` and the yield refusal show that `async` acts
    outside any Task, and `fatal` still refuses there, because the Task that
    called the binding is current.
  - Inside a request's settlement callback, where no Task is current, a
    callback's settlement and its fatal failure are both queued. The Task
    continues, or raises its operation's error, in a later turn. `async.loop`
    then rethrows the fatal error with its trace, and a new Runtime runs.

It then drives the owner's published entries:
- Task-form calls.
- Disposal while relinquished. The cleanup shows that new host work raises
  the closing error and that a sleep raises the Task's cancellation. While the
  cleanup awaits a 200 ms host request, the drive takes at most three turns.
  The harness counts the loader's turn-source macrotasks: `setImmediate` calls
  that pass the turn cell, otherwise `postMessage(undefined)` on the
  instance's channel. Elapsed time alone would not show that the drive parked.
- Disposal mid-turn, with an orphaned cleanup, and with no drive. The cleanup
  drive that `dispose()` starts when nothing drives has the same three-turn
  bound.
- Disposal of Tasks parked on a retained request (`dispose()` settles only
  after that request does) and on a detachable one (its late settlement is
  dropped).
- Disposal of 2,000 parked Tasks, after which the harness's acknowledged
  collection must clear a `WeakRef` to the instance.
- The exit latch, with a `dispose()` afterwards that still runs the state's
  finalizers.
- Refused child-state calls during a drive.

The spec also
builds `bootstrap.titan`, a program whose `main` runs as the async bootstrap
Task, without `--no-uv-bootstrap`. `bootstrap.mjs` then checks `run()`'s
`returned` result, `failed` for a failed main Task (its uncaught report as the
only stderr report, with its message and trace in the result), `returned`/1
for a cancelled main, and `exited`, including after main failed. It also
checks that output reaches stdout while the drive waits. Plain runs check the
runner's exit statuses.

The same spec builds `os.browser_tests` as a normal program and runs
`os-streams.mjs` separately from the async owner's SDK-source `streams.mjs`.
It supplies held or failing sinks, input chunks, declared stream kinds, TCP
end hooks, and an environment through public `create` options. Its named
cases cover print conversion and redirection, exact binary output and FIFO
completion, cancellation, disposal and graceful exit, C-stdio ordering and
failure latching, shutdown and kind errors, input buffering and reader
ownership, line-iterator cleanup, wall time, calendars, and C/Titan environment
agreement. Both engines run both assertion builds.

Stock Lua cases repeat input, environment and output checks in the owner and
in public `lua.new` states. Configured embedding input is never consumed by
`io.read` or `io.stdin:read`: both return errors, not EOF, with no prompt.
Stock `os.getenv` sees embedding values and later Titan environment changes.
Short buffered binary `io.write` bytes share print's body chunk, followed by a
separate newline chunk at print's flush. A later `io.write` flushes at explicit
`io.flush`, in order between Titan writes. Stock `os.exit(3)`, `os.exit(true)`
and `os.exit(false)` inside the owner bootstrap Task produce `run()` exit
statuses 3, 0 and 1; all three remain unavailable in a child state. First stock
exit resolves the linked OS module through normal Lua loading, preserving
the native import's three stream identities and native-exit flush ordering.

Disposal preserves native cancellation precedence: admitted writers and new
cleanup writes observe the nominal `instance disposed` cancellation, while
their public Task-form calls reject `TITAN_BROWSER_DISPOSED`. The disposal case
holds the original sink promise through retirement and checks that every
cleanup runs without calling a later sink.

These drive-sensitive fixtures deliberately use private published
`BrowserValue` callbacks with `test.assert`, rather than ordinary
`test.Context` cases: the test runner's own C-stdio reports would contaminate
the observed streams. The JavaScript driver names, counts, and asserts each
case. A small normal `main` retains the async bootstrap to check `run()` return
flushing and exit. Native captured printing and this owner share the portable
test-only `io.print_values` conversion fixture.

Busted owns provider/header/runtime inventories, native-target absence,
generated bootstrap mechanics, final artifacts, and link integration. The
JavaScript integration driver exercises public promises, two instances,
runtime-type marshalling, variant rejections, non-string callable errors, pin
hold lifetimes, re-export after synchronous release, notification batches,
disposal, sinks, requests, and WeakRef ownership with real linked images.
The separate `environment.mjs` driver, run by `browser_bridge_spec.lua`,
checks empty and supplied libc environments, validation, UTF-8 round trips,
mutation, and per-instance isolation under Node and Chromium.
Test-only C instrumentation may hand explicit frozen controls to a supplied
fixture binding; the generated application API never exposes the raw Emscripten
Module or factory.

The html5 click counter of the [language
chapter](../language/standard-library-browser.md#synchronous-c-callbacks)
(`counter.titan` and the page test `counter.mjs` in
`spec/fixtures/browser_bridge/`) imports `emscripten/html5.h` directly in
Titan and registers real buttons through `emscripten_set_click_callback_on_thread`.
Its callback is a `foreign function` of the same module: the
synchronous-result aggregate is a
[zeroed automatic local](foreign-functions.md#allocation-and-recovery-storage)
of its body, and it calls pinned handlers through `titan_browser_call_sync`.
The image has no authored C. It needs a page's DOM, so the bridge spec runs it
on Chromium only and the Playwright bridge gate on Chromium, Firefox and
WebKit.

Each collection case prepares and releases its targets in a helper frame that
returns before the driver performs at most forty acknowledged-GC checks. The
waiting frame keeps the WeakRefs and the deliberately retained host promises or
listener continuations, not locals that formerly held the targets. This keeps a
suspended fixture frame from conservatively retaining an otherwise retired
object. The target set and collection oracle are the same on every engine.
