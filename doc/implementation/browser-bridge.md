# Browser bridge runtime

The core JavaScript bridge uses the browser JSPI backend and the single
persistent image lifecycle. It does not add another coroutine driver,
scheduler, native message format, or synchronous reverse-call backend. The
public Titan API is [JavaScript bindings](../language/standard-library-browser.md);
[the browser target](browser-target.md) owns link profiles, the embedded
loader, the runner, deployment, and fatal engine classifications.

## Source ownership

| Owner | Files |
| --- | --- |
| Installed C layout and JS import contract | `titan-runtime/titan/browser.h` |
| Browser-only Titan API, pin table, foreign trampolines, and protected entries | `titan/browser.browser.titan` |
| Generated image launcher and weak C export forwards | `titan-compiler/browserentry.lua` and `driver.browser_entrypoint_contents` |
| JSPI owner, bridge imports and loader | `titan-runtime/browser/titan-browser-library.js`, `titan-browser-bridge.js`, and `titan-browser.mjs` |
| Browser runtime/provider staging | `Makefile` and `scripts/browser_sdk.lua` |

There is no hand-written C runtime file for the browser bridge: `libtitan.a`
contains the same four objects (`titan.o`, `minicoro.o`, `titan_path.o`,
`ltitanlib.o`) on both native and browser targets. The native standard provider
has no `titan.browser`, while the browser provider adds `titan.browser` beside
the thirteen shared modules. It imports only `gc`, and the [member
inventory](browser-target.md#interface-derived-member-inventory) skips it
because it has no native interface to compare.

## Generated launcher and foreign-function trampolines

`browserentry.lua` and `driver.browser_entrypoint_contents` generate the image
launcher next to native `main`, following the [Titan-first native-binding
rules](../style-guide.md#write-native-bindings-titan-first):

1. **Shared launcher and error conversion (`browserentry.lua`):** Initialization
   creates the owner `lua_State *`, attaches its state record (or opens a bare
   host state token in C-only images that do not link `titan.browser`), opens
   the Lua libraries, installs the Titan searcher and preloads, and requires
   the root module without calling `main`. `titan_browser_entry` retrieves the
   initialized module from `LUA_LOADED_TABLE`, constructs its counted string
   Array, and runs `main` once. Both run under `titan_browser_protected_entry`
   with plain `errorhandler` as the `lua_pcall` message handler. On failure,
   `titan_browser_complete_failure` snapshots `TITAN_BACKTRACE_KEY` on the
   stack, converts the final escaped error object once under `lua_pcall` using
   the `errmsg_tostring` and `strip_bootstrap_prefix` implementation shared
   with native `main`, restores the `TITAN_BACKTRACE_KEY` snapshot, writes
   `<progname>: <message>` and `stack traceback:` to `stderr`, and flushes the
   completion. Caught raises inside module initializers are never converted,
   and stale traces never leak into `main`. The owner state keeps
   `luaL_newstate`'s warning handler, including its prefix, warning controls,
   and multipart messages; its stderr output enters the byte queue. Attaching
   an independent state preserves the warning handler its creator chose.
2. **One-line weak forwards (`titan_browser_invoke`,
   `titan_browser_release_callable`):** `browserentry.lua` declares
   `titan_browser_\u2133_invoke_titan`,
   `titan_browser_\u2133_release_callable_titan`,
   `titan_browser_\u2133_attach_titan`, and
   `titan_browser_\u2133_close_state_titan` as `__attribute__((weak))`. When
   `titan.browser` is linked into the image, `titan_browser_invoke` and
   `titan_browser_release_callable` forward in one line to those public
   `foreign function`s in `titan/browser.browser.titan`; in C-only protocol or
   probe images without `titan.browser`, the weak pointers are `NULL` and the
   exports reject cleanly with `titan_browser_invalid_entry` (`TITAN_BROWSER_STATE`).
3. **Foreign trampolines (`invoke`, `release_callable`) and protected Titan
   entries (`invoke_entry`, `release_entry`):** The public foreign functions in
   `titan/browser.browser.titan` use header-free C primitive parameter types so
   consumers of `"browser"` need no `foreign import`. Each trampoline checks
   `titan_browser_entry_allowed`, recovers the `titan_browser_state_record *`
   from the JS registry via `titan_browser_host_state_record(token)`, checks
   close admission and `lua_checkstack(L, LUA_MINSTACK)` (writing an immediate
   `TITAN_BROWSER_TITAN_ERROR` `"not enough memory"` completion if that stack
   check fails), recovers `module` (`upvalue[0]`) and the native entry pointer
   (`upvalue[2]`) from the handler closure stored in the state record, installs
   `errorhandler` as `L->errfunc`, calls `invoke_entry` or `release_entry`, and
   restores `L->errfunc` and the stack top.
4. **Minimal protected entries (`invoke_entry` -> `invoke_work`, `release_entry` -> `release_work`):**
   `invoke_entry` and `release_entry` are minimal function-scope `catch`
   wrappers whose own preambles fit inside the trampoline's `LUA_MINSTACK`
   reservation and call `invoke_work` / `release_work` inside their installed
   `errorJmp`. All argument decoding, execution, rollback, and formatted error
   reporting run inside `invoke_work` / `release_work`. In `invoke_work`, a
   failed completion flush rolls back the provisional wrapper inline into
   `free_slots`, pre-grown during `allocate_pin`. The inner `catch` performs
   the same rollback before calling `complete_titan_failure`. If a work
   function raises at its own preamble (`titan_ensure_stack`) or while
   reporting an error from its inner `catch`, the outer function-scope `catch`
   in `invoke_entry` / `release_entry` writes `"not enough memory"` into
   `state_record.fallback` via inline FFI
   struct writes, flushes `stdout`/`stderr`, and calls `titan_browser_complete`.
   That outer handler does not roll back wrappers or call Titan helpers, grow
   the stack, or allocate Lua objects. Non-string error objects raised by
   callables are formatted in Titan (`format_error_value` under `catch`) using
   the same `__tostring` / `(error object is a <type> value)` rule as the
   launcher while preserving `invoke_work`'s inner `catch`'s `traceback` local.

| Export | Operation kind | Role |
| --- | --- | --- |
| `titan_browser_initialize(uint64_t)` | INITIALIZE1 | Generated protected bootstrap, once |
| `titan_browser_entry(uint64_t, int, argv, lengths)` | MAIN2 | Generated protected main, once |
| `titan_browser_invoke(uint64_t, state, slot, generation, argc, args)` | INVOKE3 | 1-line weak forward to `titan.browser` `invoke` |
| `titan_browser_release_callable(uint64_t, state, slot, generation, wrapper)` | RELEASE4 | 1-line weak forward to `titan.browser` `release_callable` |
| `titan_browser_close(uint64_t)` | CLOSE5 | Generated owner-held state close (`close_state` or fallback) |

`operation_id` is an instance-local never-reused unsigned 64-bit identity.
JavaScript uses a BigInt counter; exhaustion rejects instead of wrapping to
zero. Export return values are admission only. Exactly one completion with
the same id/kind carries application values/status/errors, and the loader
settles only after both completion and promised-export/context retirement.
A private engine entry is not an application gateway. The loader uses
Emscripten's exported `_malloc` and `_free` for temporary argument buffers.

Close is deliberately different. `close_state` (a public `foreign function` in
`titan/browser.browser.titan`) marks the state closing, clears `configured = 0`,
and invokes `lua_close` directly while the JSPI execution owner is held. It is
never a `lua_pcall` on the Lua state being freed. Lua's own per-finalizer
protection remains authoritative. Warnings alone do not convert successful
close into an invented application failure. Both libc streams are flushed,
preserving the first error while attempting both; the loader then handles
copied stream queues and disposal outcomes.

## State records and the Titan pin table

`attach` (a public `foreign function` in `titan/browser.browser.titan`) runs
before `luaL_openlibs`, preloads, or any user initializer, and is idempotent.
Its 0-uservalue `titan_browser_state_record` userdata is the first finalizable
object in that state and is anchored in the Lua registry under the private
lightuserdata key `ffi.lmacro_cfunc_key(state_gc)` (the pre-module lifecycle
exception to rule 4: no module variable exists yet when `attach` runs, and the
userdata must survive until `lua_close` finalizes it last). `attach` passes the
record pointer to `titan_browser_host_state_open(state)`, which allocates the
opaque host state token and maps `token -> record` in the JS owner's
`stateRecords` table; no JavaScript application API exposes a `lua_State *`,
and no C static state list exists.

When `titan.browser` initializes in a state, its `do ... end` block calls
`attach(L)`, caches the `titan_browser_state_record *` in its module variable
`state_record`, roots `invoke_entry` and `release_entry` in module variables,
and writes their `TValue` closures into `state_record` (`configured = 1`).

Lua closes latest-finalized-first. The earliest `titan_browser_state_record`
finalizes after every application userdata, table, or retained-coroutine
finalizer. Its `state_gc` finalizer (a `local foreign function` in
`titan/browser.browser.titan`) calls `mark_closing`, clears `state.token = 0`,
and notifies `titan_browser_host_state_closed(token)`, which removes the state's
record, callable targets, notifications, requests, and JavaScript slot units.
If `attach` fails before assigning a token, collecting its token-zero userdata
does not invalidate anything or close the state. The creator of that Lua state
remains responsible for calling `close_state` or `lua_close`.

An independent state created in a C test fixture calls
`titan_browser_\u2133_attach_titan(L)` at construction. `state_closing()` and
`current_state()` in `titan/browser.browser.titan` read `state_record` from the
module variable and check `titan_state_closing(L)` (`G(L)->gcstp & GCSTPCLS`), so
a direct independent `lua_close` closes asynchronous/reverse admission before a
finalizer's first binding call, even when the whole instance is not disposing.
Synchronous binding lookup/call, copied output admission, and nonthrowing
release remain valid until final invalidation. Every new JS slot is charged to
the state, including slots allocated during close when Lua suppresses new
reachability finalizers.

`BrowserHandle` registers the allocation-free
`gc.finalizable<|value|>(owner, finalizer)` callback shape, initially with an
inert slot, then adopts the live unit.

Callable pinning lives entirely in `titan/browser.browser.titan` in per-state
module variables (`pins_by_slot: {Pin}`, `pins_by_fn: {value: Pin}`,
`free_slots: {integer}`, `slot_generations: {integer}`, and
`next_slot: integer`), with no `luaL_ref`, registry tables, or uservalue tables:

- One `Pin` and one JavaScript `CallableView` wrapper exist per function per
  state while live.
- Titan is the single authority for hold counts on each `Pin`:
  - `wrapper_live: boolean` tracks whether a live JavaScript wrapper currently
    holds the pin (set when the callable crosses as `BrowserValue.is_callable`
    and no live wrapper exists in JavaScript).
  - `holds: integer` counts active request and listener holds (incremented for
    `completion` and `failure` at `BrowserHandle:start` / `BrowserHandle:listen`).
- JavaScript reports each hold drop once via `release_callable(id, state, slot,
  generation, wrapper)`: `wrapper.release()` passes `wrapper = 1` (setting
  `wrapper_live = false`), and request retirement (after any queued settlement
  notification finishes in `drain()`, or upon cancellation/discard) passes
  `wrapper = 0` (decrementing `holds`). When `!pin.wrapper_live && pin.holds <= 0`,
  `Pin:retire_if_unused()` removes the pin from `pins_by_slot` and `pins_by_fn`
  and recycles its slot with a monotonically increasing generation.
- Every pin allocation and hold mutation is exception-atomic: `allocate_pin`
  undoes partial table insertions on raise before mutating `free_slots` or
  `next_slot`, and `pin_wrapper` / `pin_request_hold` allocate and append their
  `ProvisionalPin` rollback record before `allocate_pin` or mutating `Pin`.
- Re-exporting a callable while its wrapper release is queued in JavaScript
  cancels only that queued wrapper release (`entry.wrapper === true`) while
  preserving any queued request-hold drops (`entry.wrapper === false`), and
  issues a fresh `CallableView` wrapper for the existing pin.
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
  without touching queued request-hold drops and returns `1`, then retire the
  pin if unused. Once exposed to host JavaScript,
  `titan_browser_host_callable_closed` returns `0` and the wrapper stays live
  until its own `release()`.

## Fixed wasm32 layout

The installed header is the sole C/JavaScript layout contract. C layout
assertions check sizes and offsets for wasm32. There is no native packet
serialization, schema codec, attachment index, or per-call JSON/protobuf step.

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
| 8 | `scalar` | Union: signed i64 integer/boolean, f64 number; allocated capacity for returned `STRING`/`BYTES` |
| 16 | `bytes` | wasm32 byte pointer |
| 20 | `length` | Exact byte count |
| 24 | `slot` | State-local handle/callable slot |
| 28 | `generation` | Exact live generation |

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

For reverse-call `BrowserHandle` arguments, the marshaler initially owns
temporary slots (`entry.temporary = true`). `new_handle` rejects an absent
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
and host invocation.
- One-shot `start` settlement enqueues one argument (the resolved value
  marshalled by runtime type, with `undefined` mapped to `is_nil`).
- `listen` emissions enqueue every emitted argument marshalled by runtime type.
- Failure settlement (including a `start` settlement or `listen` emission that
  fails marshalling with `TypeError` or a handle error) enqueues
  `(is_string(message), is_handle(thrown))`, where `thrown` is always wrapped in
  a handle slot even for a primitive rejection.

Detachable mailbox and guaranteed-terminal retained ownership, cancellation,
listener removal, late-settlement dropping, FIFO batching, and disposal all
remain with the JS bridge owner. No C import awaits host work.

Drain rechecks each detached entry's request cancellation before invoking it:
cancellation can remove entries from the live queue, not the already-detached
batch. A normally settled one-shot marks its request retired before delivery;
retirement alone does not cancel that queued completion, and the request's pin
holds on `completion` and `failure` are released only after that queued
notification finishes in `drain()` (or is discarded).

## Test layers

Public behavior belongs to the browser-target native Titan owner under
`spec/stdlib/titan/browser/`, linked against the real JavaScript bridge and
explicit test bindings. Its native cases cover exact scalars, UTF-8 strings
(including leading `U+FEFF` and invalid-UTF-8/lone-surrogate rejection),
copied bytes, original captures, wrapper identity and round-tripping, GC
finalizers, cross-entry/STACKED resumption, hidden allocation cleanup,
provisional pin rollback (including allocation failures and host-retained
wrappers), requests, and C stdio output. A test-owned C fixture constructs
truly independent Lua states with the same earliest registry (`attach` /
`close_state`) and exercises explicit, GC, and detach-then-later close.
Initializer failure has a separate real Titan image with a suspended cleanup
coroutine and `main` error-conversion checks.

Busted owns provider/header/runtime inventories, native-target absence,
generated bootstrap mechanics, final artifacts, and link integration. The
JavaScript integration driver exercises public promises, two instances,
runtime-type marshalling, variant rejections, non-string callable errors, pin
hold lifetimes, re-export cancelling a queued release, notification batches,
disposal, sinks, requests, and WeakRef ownership with real linked images.
Test-only C instrumentation may hand explicit frozen controls to a supplied
fixture binding; the generated application API never exposes the raw Emscripten
Module or factory.

Each collection case prepares and releases its targets in a helper frame that
returns before the driver performs at most forty acknowledged-GC checks. The
waiting frame keeps the WeakRefs and the deliberately retained host promises or
listener continuations, not locals that formerly held the targets. This keeps a
suspended fixture frame from conservatively retaining an otherwise retired
object. The target set and collection oracle are the same on every engine.
