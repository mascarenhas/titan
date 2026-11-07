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
| Installed C contract | `titan-runtime/titan/browser.h` |
| State-token list, launcher entry, and C→Titan shims | `titan-runtime/browser/titan-browser.c` |
| Browser-only Titan API, pin table, and protected invoke/release entries | `titan/browser.browser.titan` |
| Generated image C exports | `titan-compiler/browserentry.lua` |
| Generated module bootstrap/main | `driver.browser_entrypoint_contents` |
| JSPI owner, bridge imports and loader | `titan-runtime/browser/titan-browser-library.js`, `titan-browser-bridge.js`, and `titan-browser.mjs` |
| Browser runtime/provider staging | `Makefile` and `scripts/browser_sdk.lua` |

The runtime C object is added only to the browser runtime archive: the native
runtime archive keeps its four objects, and the native standard provider has
no `titan.browser`. The common installed header is not a native placeholder.
The browser provider adds `titan.browser` beside the thirteen shared modules.
It imports only `gc`, and the [member
inventory](browser-target.md#interface-derived-member-inventory) skips it
because it has no native interface to compare.

## Persistent lifetime and C shims

Generated initialization and main are separate workers. Initialization creates
the owner state, attaches the C state-token record, then opens libraries,
installs the existing Titan searcher/preloads, and requires image roots. It
does not call main. Main retrieves the initialized root from the ordinary
loaded-module table, constructs its counted byte-argument Array, and invokes
main once through the existing optional bootstrap hook. It does not close
Lua. Module initialization remains idempotent through the existing protocol.

The runtime remembers successful initialization separately from attempted
initialization and main-started. A partially initialized state remains owned
and disposable after an ordinary failure, but cannot run main or an owner
application callback. The loader saves the failed initialization record and
report for a subsequent failed/status1 run without a repeated report.

Every public Lua-running entry consumes a nonzero operation id and expected
operation kind from the existing JSPI execution owner. The owner spans private
coroutine transfers, allocation-triggered GC cleanup, and terminal engine
retirement. Public loader admission additionally spans marshaling, every
contained C entry, and output flush. A sink or import cannot admit another
application operation between contained entries.

Before publishing an operation, reverse-call argument snapshotting reads only
primitive tags, well-formed UTF-16 strings, captured TypedArray tag/length
getters and `set`, and WeakMap callable identities. This keeps `call` and
`notify` snapshots synchronous without a host-code gap before publication.

| Export | Operation kind | Role |
| --- | --- | --- |
| `titan_browser_initialize(uint64_t)` | INITIALIZE1 | Protected bootstrap, once |
| `titan_browser_entry(uint64_t, int, argv, lengths)` | MAIN2 | Protected main, once |
| `titan_browser_invoke(uint64_t, state, slot, generation, argc, args)` | INVOKE3 | C shim to Titan `invoke_entry` |
| `titan_browser_release_callable(uint64_t, state, slot, generation)` | RELEASE4 | C shim to Titan `release_entry` |
| `titan_browser_close(uint64_t)` | CLOSE5 | Owner-held state close |

`operation_id` is an instance-local never-reused unsigned 64-bit identity.
JavaScript uses a BigInt counter; exhaustion rejects instead of wrapping to
zero. Export return values are admission only. Exactly one completion with
the same id/kind carries application values/status/errors, and the loader
settles only after both completion and promised-export/context retirement.
A private engine entry is not an application gateway. The only owner-free
exports are documented C allocation/free and backend stack-metadata helpers.

## Protected launcher helper and Titan entry shims

`titan-browser.c` follows the [Titan-first native-binding
rules](../style-guide.md#write-native-bindings-titan-first):

1. **Image initialization and main (`protected_entry`):** Because
   `titan_browser_initialize_image` runs before any Titan module exists and
   `titan_browser_main_image` must also work in C-only protocol/probe images
   that do not link `titan.browser`, those two launcher entries share one
   `lua_pcall` with `entry_errorhandler`. The message handler captures the
   unified trace via `errorhandler` and converts non-string error objects while
   preserving the original `TITAN_BACKTRACE_KEY` snapshot even if `__tostring`
   raises.
2. **Invoke and release shims (`titan_browser_invoke`,
   `titan_browser_release_callable`):** When `titan.browser` initializes in a
   Lua state, its `do ... end` block roots its entry closures in module
   variables (`invoke_handler`, `release_handler`, `pin_handler`,
   `unpin_handler`) and registers the module `Udata *`, `CClosure *`, and
   native entry pointers with `titan_browser_configure`. Each exported C shim
   checks `titan_browser_entry_allowed`, looks up `bridge_state` by token,
   reserves `LUA_MINSTACK` with `lua_checkstack`, saves `lua_gettop`, calls the
   Titan native entry directly, and restores `lua_settop`. Neither shim uses
   `lua_pcall`.
3. **Titan `invoke_entry` and `release_entry`:** Both are ordinary Titan
   functions in `titan/browser.browser.titan` whose whole body is protected by
   `catch`. `invoke_entry` reads the `titan_browser_value` argument array
   through the FFI, builds the `{BrowserValue}` arguments, rechecks incoming
   handle/callable identities through the nonthrowing
   `titan_browser_host_identity_live` import, invokes the pinned Titan
   function, encodes its single `BrowserValue` result, rechecks outgoing
   handle/callable liveness, flushes `stdout` and `stderr`, and calls
   `titan_browser_complete`. On any raise, the `catch` block rolls back any
   provisional pin from the failed encoding, formats `error`, and completes
   with `TITAN_BROWSER_TITAN_ERROR`, the message bytes, and the `traceback`
   string captured by Titan's error boundary.

Close is deliberately different. `titan_browser_close_state` marks the state
closing, clears the cached module and entry pointers, and invokes `lua_close`
directly while the JSPI execution owner is held. It is never a `lua_pcall` on
the Lua state being freed. Lua's own per-finalizer protection remains
authoritative. Warnings alone do not convert successful close into an invented
application failure. Both libc streams are flushed, preserving the first error
while attempting both; the loader then handles copied stream queues and
disposal outcomes.

## State tokens and the Titan pin table

`titan_browser_attach` runs before `luaL_openlibs`, preloads, or any user
initializer. Its 0-uservalue `bridge_state` userdata is the first finalizable
object in that state and is strongly rooted in the Lua registry. The C list
maps opaque host-issued state tokens to live `bridge_state` records; no
JavaScript application API exposes a `lua_State *`. Tokens distinguish reused
state addresses.

Lua closes latest-finalized-first. The earliest `bridge_state` userdata
therefore invalidates last, after coroutine unwinding and user/module
finalizers. Its `state_gc` finalizer marks closing, invalidates the full
state's callable targets, notifications, requests, and JavaScript slot units
once via `titan_browser_host_state_closed`, unlinks its C state record, and
clears its token. Explicit close and reachability close use that same endpoint.
Detach does not invalidate anything; the caller remains responsible for a later
close.

An independent state must attach at construction too. `titan_browser_state` and
`titan_browser_state_closing` walk the C `states` list without touching the Lua
stack and detect `GCSTPCLS` on ordinary bridge use, so a direct independent
`lua_close` closes asynchronous/reverse admission before a finalizer's first
binding call, even when the whole instance is not disposing. Synchronous
binding lookup/call, copied output admission, and nonthrowing release remain
valid until final invalidation. Every new JS slot is charged to the state,
including slots allocated during close when Lua suppresses new reachability
finalizers.

`BrowserHandle` registers the allocation-free
`gc.finalizable<|value|>(owner, finalizer)` callback shape, initially with an
inert slot, then adopts the live unit.

Callable pinning lives entirely in `titan/browser.browser.titan` in per-state
module variables (`pins_by_slot: {integer: Pin}`, `pins_by_fn: {value: Pin}`,
`free_slots: {integer}`, `slot_generations: {integer: integer}`, and
`next_slot: integer`), with no `luaL_ref`, registry tables, or uservalue tables:

- One `Pin` and one JavaScript `CallableView` wrapper exist per function per
  state while live.
- Titan is the single authority for hold counts on each `Pin`:
  - `wrapper_live: boolean` tracks whether a live JavaScript wrapper currently
    holds the pin (set when the callable crosses as `BrowserValue.is_callable`
    and no live wrapper exists in JavaScript).
  - `holds: integer` counts active request and listener holds (incremented for
    `completion` and `failure` at `BrowserHandle:start` / `BrowserHandle:listen`
    and C SDK `titan_browser_pin_callable`).
- JavaScript reports each hold drop once via `release_callable`:
  `wrapper.release()` drops the wrapper hold (`wrapper_live = false`), and
  request retirement (after any queued settlement notification finishes in
  `drain()`, or upon cancellation/discard) drops the request's holds on
  `completion` and `failure`. When `!pin.wrapper_live && pin.holds <= 0`,
  `release_entry` removes the pin from `pins_by_slot` and `pins_by_fn`,
  recycles its slot with a monotonically increasing generation, and notifies
  `titan_browser_host_callable_closed`.
- Re-exporting a callable while its wrapper release is queued in JavaScript
  cancels that queued wrapper release and issues a fresh `CallableView` wrapper
  for the existing pin.
- Any provisional pin or request hold created while marshalling a crossing that
  fails before JavaScript takes the value (a later argument raises in Titan,
  the host call or request start fails in `importResponse`, or result
  validation fails before `titan_browser_complete`) is rolled back in the same
  operation.

## Fixed wasm32 layout

The installed header is the sole C/JavaScript layout contract. C layout
assertions check sizes and offsets for wasm32. There is no native packet
serialization, schema codec, attachment index, or per-call JSON/protobuf step.

Kinds are `NIL = 0`, `BOOLEAN = 1`, `INTEGER = 2`, `FLOAT = 3`, `STRING = 4`,
`BYTES = 5`, `HANDLE = 6`, `CALLABLE = 7`, and `REQUEST = 8`. `REQUEST` is an
import result kind for `host_start`, `host_read`, and completion-carrying
`host_write`. Statuses are `OK = 0`, `TITAN_ERROR = 1`, `JS_ERROR = 2`,
`STATE = 3`, and `MEMORY = 4`. All fields below use unsigned 32-bit widths
unless specified otherwise.

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

`titan_browser_identity` is three u32 fields (`state`, `slot`, `generation`),
12 bytes.

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
result buffers are freed by `titan_browser_response_dispose` on every path.
Unadopted `HANDLE`, `REQUEST`, and thrown-value units are released there too;
wrappers clear fields when their completed Titan owner adopts a unit. Thus
allocation while building a Titan owner/error cannot leak an unowned host slot.

For reverse-call `BrowserHandle` arguments, the marshaler initially owns
temporary slots. The Titan constructor rejects an absent identity, registers
its inert finalizer, and checks the actual host unit again after that
potentially allocating setup before trusted `host_adopt(state, slot,
generation)`. Slots never adopted are released on failed delivery. Trusted
adoption, release, state, and callable-registration imports are nonthrowing.
Close validates its potentially raising state access before clearing an owner's
slot; a contained admission failure leaves the original ownership available for
retry.

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
  `TextDecoder('utf-8', {fatal: true})`.
- Genuine `Uint8Array` views (identified via the `%TypedArray%` `@@toStringTag`
  getter, without invoking Proxy traps, iterators, accessors, or species hooks)
  are copied as `TITAN_BROWSER_BYTES` (`is_bytes`) and return to JavaScript as
  `Uint8Array` copies.
- Live same-state `CallableView` wrappers cross as `TITAN_BROWSER_CALLABLE`
  (`is_callable`), recovering the original pinned Titan function.
- All other JavaScript values (including plain objects, arrays, `Error`s,
  `Promise`s, `Proxy`s, and JavaScript functions) cross as
  `TITAN_BROWSER_HANDLE` (`is_handle`).

## Request and SDK I/O boundary

`host_start` receives target identity, counted `titan_browser_value` arguments,
completion and failure slot/generation pairs, mode `START = 0` / `LISTEN = 1`,
and a response pointer. The request slot is reserved before argument decoding
and host invocation.
- One-shot `start` settlement enqueues one argument (the resolved value
  marshalled by runtime type, with `undefined` mapped to `is_nil`).
- `listen` emissions enqueue every emitted argument marshalled by runtime type.
- Failure settlement enqueues `(is_string(message), is_handle(thrown))`, where
  `thrown` is always wrapped in a handle slot even for a primitive rejection.

Detachable mailbox and guaranteed-terminal retained ownership, cancellation,
listener removal, late-settlement dropping, FIFO batching, and disposal all
remain with the JS bridge owner. No C import awaits host work.

Drain rechecks each detached entry's request cancellation before invoking it:
cancellation can remove entries from the live queue, not the already-detached
batch. A normally settled one-shot marks its request retired before delivery;
retirement alone does not cancel that queued completion, and the request's pin
holds on `completion` and `failure` are released only after that queued
notification finishes in `drain()` (or is discarded).

The SDK also declares completion-carrying `host_write` and `host_read`, plus
`titan_browser_pin_callable` and `titan_browser_unpin_callable` (which delegate
to `pin_sdk_entry` and `unpin_sdk_entry` in `titan.browser`). Streams are
`STDOUT = 1` and `STDERR = 2`. A write with `completion_slot == 0` is copied
append admission and remains usable during close. Otherwise write completion is
invoked with zero arguments; read completion receives one `is_bytes` argument
bounded by the requested capacity; and failure receives `(is_string(message),
is_handle(thrown))`.

## Test layers

Public behavior belongs to the browser-target native Titan owner under
`spec/stdlib/titan/browser/`, linked against the real JavaScript bridge and
explicit test bindings. Its native cases cover exact scalars, UTF-8 strings and
invalid-UTF-8/lone-surrogate rejection, counted bytes, original captures,
wrapper identity and round-tripping, GC finalizers, cross-entry/STACKED
resumption, hidden allocation cleanup, provisional pin rollback, requests, and
SDK byte admissions. A test-owned C fixture constructs truly independent Lua
states with the same earliest registry and exercises explicit, GC, and
detach-then-later close. Initializer failure has a separate real Titan image
with a suspended cleanup coroutine.

Busted owns provider/header/runtime inventories, native-target absence,
generated bootstrap mechanics, final artifacts and link integration. The
JavaScript integration driver exercises public promises, two instances,
runtime-type marshalling, variant rejections, pin hold lifetimes, re-export
cancelling a queued release, notification batches, disposal, sinks, requests,
and WeakRef ownership with real linked images.
