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
| Protected state/closure runtime | `titan-runtime/browser/titan-browser.c` |
| Browser-only Titan API | `titan/browser.browser.titan` |
| Generated image C exports | `titan-compiler/browserentry.lua` |
| Generated module bootstrap/main | `driver.browser_entrypoint_contents` |
| JSPI owner, bridge imports and loader | `titan-runtime/browser/titan-browser-library.js`, `titan-browser-bridge.js`, and `titan-browser.mjs` |
| Browser runtime/provider staging | `Makefile` and `scripts/browser_sdk.lua` |

The runtime C object is added only to the browser runtime archive: the native
runtime archive keeps its four objects, and the native standard provider has
no `titan.browser`. The common installed header is not a native placeholder.
The browser provider adds `titan.browser` beside the thirteen shared modules.
It imports only `gc` and `reflect`, and the [member
inventory](browser-target.md#interface-derived-member-inventory) skips it
because it has no native interface to compare.

## Persistent C lifetime

Generated initialization and main are separate workers. Initialization creates
the owner state, installs the C bridge registry, then opens libraries,
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

Before publishing an operation, reverse-call argument validation reads only
bridge-owned Arrays, frozen descriptors, primitive tags and WeakMap identities.
Byte snapshots use captured TypedArray tag/length getters and `set`, not the
input's prototype, iterator, accessors, constructor or species. This keeps
`call` and `notify` snapshots synchronous without a host-code gap before
publication. The existing operation owner publishes its active token and
promise before its deferred action can invoke host code.

| Export | Operation kind | Role |
| --- | --- | --- |
| `titan_browser_initialize(uint64_t)` | INITIALIZE1 | Protected bootstrap, once |
| `titan_browser_entry(uint64_t, int, argv, lengths)` | MAIN2 | Protected main, once |
| `titan_browser_invoke(uint64_t, state, slot, generation, argc, args)` | INVOKE3 | Original rooted callback |
| `titan_browser_release_callable(uint64_t, state, slot, generation)` | RELEASE4 | Protected physical root release |
| `titan_browser_close(uint64_t)` | CLOSE5 | Owner-held state close |

`operation_id` is an instance-local never-reused unsigned 64-bit identity.
JavaScript uses a BigInt counter; exhaustion rejects instead of wrapping to
zero. Export return values are admission only. Exactly one completion with
the same id/kind carries application values/status/errors, and the loader
settles only after both completion and promised-export/context retirement.
A private engine entry is not an application gateway. The only owner-free
exports are documented C allocation/free and backend stack-metadata helpers.

## One protected gateway

`protected_entry` saves the exact stack top and reserves its entry slots with
nonraising `lua_checkstack`. The initial C-function/lightuserdata pushes do
not allocate. It installs the existing `errorhandler` and enters a C dispatch
worker with `lua_pcall`; all initialization, user invocation, allocation,
result conversion, and result encoding run inside that boundary. Stack top
is restored exactly after completion copying.

Invoke dispatch retains the callable/signature userdata on the Lua stack,
pushes its original-closure uservalue, converts exact typed arguments, and
uses a normal Lua call. It never jumps to a captured native address and never
reconstructs capture cells. Results remain rooted while slots are encoded and
copied by the completion import. The common small result array is automatic
C storage; a larger array is a protected Lua-owned allocation, not a raw
malloc buffer leaked by longjmp. No stack-slot pointer is kept across a Lua
allocation; indexes are reacquired from the current stack.

After the last allocating/GC-capable argument or result conversion, dispatch
rechecks every physical callable root and then queries every HANDLE/CALLABLE
identity through the private nonthrowing
`host_identity_live(state, slot, generation, kind)` import. A synchronous host
release may invalidate a JS identity while its physical Lua root is correctly
retained through the active operation; that becomes an ordinary protected
error before success, not an exception in trusted completion decoding.
The query runs no Lua, user callback or sink, and no later conversion can
invalidate an earlier result between this boundary and synchronous copying.

An ordinary error has one protected description/report conversion without a
second errorhandler. It retains the raw `TITAN_BACKTRACE_KEY` trace already
captured by Titan. If `__tostring` raises, a conservative fixed diagnostic is
used and fallback trace retrieval is protected too; no promise catch
reconstructs a trace. Initialization/main report once to stderr; ordinary
callback failures carry bytes/trace to their JavaScript promise. The owner
state keeps `luaL_newstate`'s warning handler, including its prefix, warning
controls and multipart messages; its stderr output enters the byte queue.
Attaching an independent state preserves the warning handler its creator chose.

Close is deliberately different. `titan_browser_close_state` marks the state
closing and invokes `lua_close` directly while the JSPI execution owner is
held. It is never a `lua_pcall` on the Lua state being freed. Lua's own
per-finalizer protection remains authoritative. Warnings alone do not convert
successful close into an invented application failure. Both libc streams are
flushed, preserving the first error while attempting both; the loader then
handles copied stream queues and disposal outcomes.

## Earliest registry, last invalidation

`titan_browser_attach` runs before `luaL_openlibs`, preloads, or any user
initializer. Its runtime-C userdata is the first finalizable object in that
state and is strongly rooted in the Lua registry. Three uservalues hold:

1. Original callable/signature roots.
2. Per-slot generations which survive root removal.
3. The bridge module's typed handle/callable constructors and identity readers.

The registry constructor, finalizer, and state-closed import require no
initialized Titan module. The C list maps opaque host-issued state tokens to
live state registries; no JavaScript application API exposes a `lua_State *`.
Tokens distinguish reused state addresses. Callable root slots can be reused
only with a new generation, and a released generation never revives.

Original-closure root publication is transactional. The sole bridge
`luaL_ref` and its generation-table insertion run in one protected worker.
Any error after the reference commits removes that exact unpublished root
before rethrowing. Stack space is reserved beforehand: `luaL_unref` only
rewrites the already existing reference and free-list keys, so rollback does
not allocate even when generation bookkeeping exhausted memory. Host metadata
and the caller's identity are published only after success. Generation
non-reuse and explicit successful-root lifetime do not change.

Lua closes latest-finalized-first. The earliest registry therefore invalidates
last, after coroutine unwinding and user/module finalizers. It marks closing,
invalidates the full state's callable targets/notifications and JavaScript
slot units once, unlinks its C state record, and clears its token. Explicit
close and reachability close use that same endpoint. Detach does not invalidate
anything; the caller remains responsible for a later close.

An independent state must attach at construction too. The runtime detects
`GCSTPCLS` on ordinary bridge use, so a direct independent `lua_close` closes
asynchronous/reverse admission before a finalizer's first binding call, even
when the whole instance is not disposing. Synchronous binding lookup/call,
copied output admission, and nonthrowing release remain valid until final
invalidation. Every new JS slot is charged to the state. This includes slots
allocated during close when Lua suppresses new reachability finalizers:
state-wide retirement, not a hoped-for `JSHandle` finalizer, owns their final
release.

`JSHandle` registers the exact allocation-free
`gc.finalizable<|value|>(owner, finalizer)` callback shape, initially with an
inert slot, then adopts the live unit. `Callable` roots are intentionally
explicit: collecting a transient Titan wrapper must not invalidate an
externally reachable JavaScript callable. Cross-heap cycles require release
or disposal; neither collector traces the other heap.

## Fixed wasm32 layout

The installed header is the sole C/JavaScript layout contract. C layout
assertions check sizes and offsets for wasm32. There is no native packet
serialization, schema codec, attachment index, or per-call JSON/protobuf step.

Kinds are NIL0, BOOLEAN1, INTEGER2, FLOAT3, BYTES4, HANDLE5, CALLABLE6, VOID7,
and REQUEST8. VOID and REQUEST are import result kinds, not callback scalar
signature descriptors. Statuses are OK0, TITAN_ERROR1, JS_ERROR2, STATE3,
SIGNATURE4, and MEMORY5. All fields below use unsigned 32-bit widths unless
specified otherwise.

### `titan_browser_value` — 32 bytes, alignment 8

| Offset | Field | Meaning |
| --- | --- | --- |
| 0 | `kind` | Exact discriminant |
| 4 | `state` | Handle/callable owner token |
| 8 | `scalar` | Union: signed i64 integer/boolean, f64 number; allocated capacity for returned bytes |
| 16 | `bytes` | wasm32 byte pointer |
| 20 | `length` | Exact byte count |
| 24 | `slot` | State-local handle/root slot |
| 28 | `generation` | Exact live generation |

`identity` is three u32 fields (`state`, `slot`, `generation`), 12 bytes.
`signature` is 16 bytes: parameter count0, result count4, parameter-kind
pointer8, result-kind pointer12. Kind arrays are copied into the state-owned
callable userdata alongside the original rooted closure. They are not an
intern table substituted for a closure root.

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
and raises `browser.Error` after return, retaining that exact value. A
MEMORY/error response without a thrown unit instead raises an ordinary
protected memory/diagnostic error before constructing an owner; zero
slot/generation never reaches trusted adoption. Message/result-byte buffers
are freed by `titan_browser_response_dispose` on every path. Unadopted HANDLE,
REQUEST, and thrown-value units are released there too; wrappers clear fields
when their completed Titan owner adopts a unit. Thus allocation while building
a Titan owner/error cannot leak an unowned host slot.

For reverse-call raw JSHandle arguments, the marshaler initially owns temporary
slots. The Titan constructor rejects an absent identity, registers its inert
finalizer, and checks the actual host unit again after that potentially
allocating setup before trusted `host_adopt(state, slot, generation)`.
The marshaler removes exactly that unit from its rollback set: a callback may
store the owner and then raise, and failure must not invalidate the stored
value. Slots never adopted are released on failed delivery. Trusted adoption,
release, state and callable-metadata imports are nonthrowing. Close validates
its potentially raising state access before clearing an owner's slot; a
contained admission failure leaves the original ownership available for retry.

### `titan_browser_completion` — 48 bytes, alignment 8

| Offset | Field |
| --- | --- |
| 0 | unsigned 64-bit operation id |
| 8 | operation kind |
| 12 | status |
| 16 | signed 32-bit application status |
| 20 | exact result count |
| 24 | result-slot pointer |
| 28 | message pointer |
| 32 | message length |
| 36 | original raw trace pointer |
| 40 | trace length |

The completion import copies arrays/bytes synchronously while all Lua owners
are still rooted. Missing, duplicate, wrong-id, or wrong-kind completion is
protocol corruption, not an ordinary binding error. A fulfilled export promise
never substitutes an application result. Zero results and one nil result are
separate records; multiple results retain every trailing nil.

The public reverse `call`/`Callable.call` promise always resolves with that
existing decoded values Array, without an additional copy: `[]`, `[null]`,
`[value]`, or the full multiple-result list. It must not return a sole raw
value from an async function: JavaScript would assimilate a Promise/thenable
stored in a JSHandle and could hold logical admission or disposal forever.
Raw values remain untouched Array elements, including rejected Promises whose
host rejection handling is still explicit. Lifecycle results, synchronous
`call_handle` imports, and request success-argument mapping are unchanged.

## Signature and byte conversion

`callable(callback: value)` inspects the original value once with
`reflect.inspect`, requires its actual Titan `FunctionType`, rejects both open
tails, and maps each fixed descriptor to one supported kind. It never roots
the inspection union's generic variadic callable view. Option/value/container
and non-bridge nominal schemas are rejected before invocation. The original
callback remains a traced value throughout inspection and is installed in its
real state root without a function adjustment.

Both directions enforce exact kinds/arity. Integers are signed-i64/BigInt;
Number coercion is not an alternate input policy. Floats preserve Number's
floating tag, NaN, negative zero and integral values. Nil is null, not an absent
argument. A JSHandle parameter adopts an ordinary JavaScript value into a new
state-owned unit; Callable parameters require live correctly branded wrappers.

Byte arguments are copied with the current `HEAPU8` before an import returns.
Returned counted bytes validate length against capacity, allocate/copy using
current views after possible growth, and Titan copies exactly `length`, never
a capacity-sized partially filled array. Native temporary arrays/buffers are
caller-owned and original Titan owners stay rooted through borrows. Only
names/messages are text; payload bytes never use UTF8 string helpers.

## Request and SDK I/O boundary

`host_start` receives target identity, counted typed arguments, success and
mandatory failure identities, mode START0/LISTEN1, and a response pointer. The
failure signature is exactly `(BYTES, HANDLE) -> ()`. Both success and failure
are ordinary queued protected notifications. A rejected host promise does not
route to `onNotificationError`; that observer is for a handler which failed.
Detachable mailbox and guaranteed-terminal retained ownership, cancellation,
listener removal, late-settlement dropping, FIFO batching, and disposal all
remain with the JS bridge owner. No C import awaits host work.

Multiple success arguments are read from an exact dense host Array under the
already-published request owner, then materialized as a bridge-owned Array
before checking cancellation and target liveness for notification publication.
Host length/index/property checks may reenter during materialization, but no
host Array method, iterator or index getter runs between the notification's
liveness check and queue insertion.
Disposal publishes its stable promise before signalling host cancellation or
listener removal, so reentrant disposal joins the same retirement.

The SDK also declares completion-carrying `host_write` and `host_read`.
Streams are STDOUT1 and STDERR2. A write with success slot0 is copied append
admission and remains usable during close. Otherwise write success has no
arguments; read success has one BYTES argument and an explicit requested
capacity. Both have the same mandatory `(BYTES,HANDLE)->()` failure callback
and REQUEST result unit. Source/sink failure is a terminal request outcome,
not cancellation-based early ownership release.

## Test layers

Public behavior belongs to the browser-target native Titan owner under
`spec/stdlib/titan/browser/`, linked against the real JavaScript bridge and
explicit test bindings. Its native cases cover exact scalars/bytes, original captures,
GC, signatures, cross-entry/STACKED resumption, hidden allocation cleanup,
requests, and SDK byte admissions. A test-owned C fixture constructs truly
independent Lua states with the same earliest registry and exercises explicit,
GC, and detach-then-later close. Initializer failure has a separate real Titan
image with a suspended cleanup coroutine.

Busted owns provider/header/runtime inventories, native-target absence,
generated bootstrap mechanics, final artifacts and link integration. The
JavaScript integration driver exercises public promises, two instances,
state/argument revalidation, notification batches, disposal, sinks, requests,
and WeakRef ownership with real linked images. Test-only C instrumentation
may hand explicit frozen controls to a supplied fixture binding; the generated
application API never exposes the raw Emscripten Module or factory.

Each collection case prepares and releases its targets in a helper frame that
returns before the driver performs at most forty acknowledged-GC checks. The waiting
frame keeps the WeakRefs and the deliberately retained host promises or listener
continuations, not locals that formerly held the targets. This keeps a suspended
fixture frame from conservatively retaining an otherwise retired object. The
target set and collection oracle are the same on every engine.
