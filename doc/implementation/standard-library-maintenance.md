# Standard-library implementation rules

The [style guide](../style-guide.md) covers ordinary Titan source style.
This chapter records cross-module maintenance rules; each library's
implementation chapter specifies its particular ownership and behavior.

## Keep public behavior with its declaration

In `titan.string` and `titan.peg`, the canonical main owns public declarations
and their bodies. Folder modules such as `titan.uv` intentionally assign
semantic contributors public ownership; keep each body with its declaration
there. Contributors may retain shared or recursive helpers, callback machinery,
and lifetime state. A sole-use local function whose public caller only forwards
the same arguments/results adds no semantic boundary: inline it and remove the
dead helper. An exact-type adapter can still be worthwhile when a repeated
typed call avoids generic callable adjustment; measure its one-time wrapper
cost against the hot path rather than removing adapters mechanically.

Library modules depend on each other only through ordinary public imports
(`import "coroutine"`, `import "os"`); no source under `titan/` uses an
explicit `.titan` [source import](source-import-visibility.md), and the import
graph check in `spec/libuv_build_spec.lua` rejects one. Each source module must
therefore compile against a compatible compiled-only provider of every
dependency. When a consumer needs a producer's private state, either the
behavior belongs with the producer (the shell facade lives in `titan.os`, next
to the Process and streams it owns) or the producer should export one complete
public operation (`Coroutine:transfer` returns the outcome and trace that
async needs). There is no second module graph in Make: `titanc --incremental`
discovers and orders the imports itself, and `spec/libuv_build_spec.lua`
asserts that no `STDLIB_IMPORTS_*` list or per-module object rule returns. The
Makefile's source lists are audit inventories, not prerequisites
([Make inventories](target-source-selection.md#make-inventories-and-audits)).

Evaluate a pure zero-argument machine/module invariant once in the owning
module's final initializer and cache it locally (the `titan.string` initializer
in `titan/string/string.titan` is the model). Factories, mutable-state
initialization, locale-sensitive builders, and intentionally lazy conditional
work do not satisfy that rule. When you find one violation, audit the sibling
library implementations for the same call-graph pattern.

## Keep the browser subset dependency-closed

Thirteen shared modules form the portable part of the [browser standard
library](browser-target.md#the-browser-standard-library): `coroutine`, `gc`,
`iteration`, `math`, `test`, `reflect`, `json`, `protobuf`, `transfer`, `peg`,
`string`, `url`, and `path`. None of them may gain an import path to `uv`,
`async`, `timer`, `titan.browser`, or a native-only module (`io`, `fs`, `net`,
`ssl`, `http`, `websocket`, `os`, `lua`, `sqlite3`, `thread`), and their only native
payload and include path is LPegLabel: a libuv, OpenSSL, llhttp, or SQLite
header, archive, or symbol fails the [dependency-closure
check](browser-target.md#the-dependency-closure-check) in `make browser-sdk`
and `make titan-stdlib-browser-test`. A new shared module or member keeps
its native signature and behavior; the [member
inventory](browser-target.md#interface-derived-member-inventory) fails on any
difference between the native and browser interfaces that it does not record.
Read a target-dependent constant from a target C define through `ffi`, as
`coroutine`, `protobuf`,
`json`, and `path` do, rather than adding a `.browser.titan` copy; reserve a
variant for a real behavioral difference. The native-only modules keep their
canonical mains as `<name>.native.titan`, so a later browser composition adds
a selected `.browser.titan` main or contributors without renaming them back.

`titan.async` is a browser module through its own browser composition: its
shared main and the `runtime.browser.titan` and `external.browser.titan`
contributors, which import `titan.browser`. Its browser omissions and its
opaque `ExternalWait` are recorded in the member inventory, so a new public
`async` member that the browser cannot provide must be recorded there, and a
shared one must type-check without `uv`. `titan.timer` is one through its
flat variant `titan/timer.browser.titan`, built on public `async` and the
SDK's timer sources; a member added to `timer.native.titan` needs its browser
twin, and its opaque `Ticker` is recorded in the inventory. Only these browser
files of `async` and `timer` may import `titan.browser`.

The browser provider's other target-specific module, `titan.browser`
(`titan/browser.browser.titan`), is the one reviewed browser-only exception.
It has no native placeholder or native interface, so the member inventory
skips it. It imports only `gc`, defines its native entry points as foreign
functions in `titan/browser.browser.titan`, and must not gain a native-only
dependency either. A native module must not import it; see [browser bridge
runtime](browser-bridge.md).

## Use existing typed storage and narrow foreign boundaries

An owned FFI `T.new_array(count)` is already a traced, counted allocation. It
can be stored directly as `value`, counted with `#`, and cast to `T *` without
a duplicate alias or wrapper record. Keep a record when it carries distinct
logical length, offset, borrowed-pointer, asynchronous-lifetime, type-erasure,
or other semantic state. Use Titan Arrays/Maps for ordinary internal tables
rather than `lua_createtable` followed by recovery through `value`.

When only a metatable operation needs the Lua API, create the table at its
actual Array/Map type and its typed metatable in Titan, push those same values
with the trusted bridge, and perform that narrow operation. `lua_setmetatable`
mutates the existing table; placeholder Map types, dynamic round-trips, and
recasts add no ownership or type guarantee. Keep weak-table policy in
`titan.gc`, dynamic loading in `titan.lua`, and raw Lua calls within the
[audited stack-effect boundary](ffi-lua-api-followup.md).

Foreign workers consume stable native callback data rather than the hosting
state's Titan/Lua objects. In `titan/uv/uv.native.titan`, `uv_work_t.data` points to
the embedded C `titan_uv_work_data` (`titan/uv/work-data.h`) that `queue_work`
fills and that stays unchanged while work is pending; public
`work_t:get_data`/`set_data` accesses a separate traced value. Keep those roles
distinct, and clear the old worker/argument state on terminal delivery
(`work_deliver`) before user code may requeue the request. The
[foreign-worker contract](libuv-runtime.md#foreign-workers) specifies the
stable storage, callback ordering, and C-only entry boundary, including the
exclusive independent-state execution used by `titan.lua`.

## Keep C and the Lua C API to what Titan cannot do

The style guide states six [rules for standard-library and runtime C and
JavaScript](../style-guide.md#write-native-bindings-titan-first);
a review justifies every new `lua_*`/`luaL_*` call, authored C line, and
authored JavaScript line against them. This maintainer contract pairs each
rule with its counterexample from the
initial browser bridge (`titan-runtime/browser/titan-browser.c`,
`titan/browser.browser.titan`, and `titan-runtime/browser/titan-browser.mjs` at
commit `843b446e`, PR #364, before #371's rewrite), and with existing
code that follows it. [Foreign functions](foreign-functions.md) and the
[libuv extension rules](libuv-extension-guide.md) describe the mechanisms. The
[`titan-ffi` cartridge](../../.agents/skills/titan-ffi/SKILL.md) carries the
same pairs for agents under "Guard-rails for standard-library and runtime C",
with compiled examples. [The same rules for browser
JavaScript](#the-same-rules-for-browser-javascript) follow the six pairs.

1. **Layering.** Wrong (`titan-browser.c` at `843b446e`): a 600-line runtime C
   file (`titan-browser.c`) hand-writing the Emscripten exports, the image
   launcher `protected_entry`, a C `states` linked list, and
   `titan_browser_root_callable` (validating the closure, copying its signature
   into a new userdata, and rooting it in C). Right: `titan-browser.c` is
   gone; `browserentry.lua` generates the launcher (sharing `titan_entry_error_message`
   with native `main`) and one-line weak forwards (`titan_browser_invoke`,
   `titan_browser_release_callable`) to public `foreign function`s in
   `titan/browser.browser.titan`. Its state record is Titan-owned module
   storage finalized by an ordinary function through `gc.finalizable`;
   `mark_closing` and the entry trampolines remain foreign functions. The
   cross-state token map lives in the JavaScript registry. The libuv callbacks
   are local `foreign function`s whose one C helper,
   `titan_uv_push_owner` in `titan/uv/callback.h`, wraps the `setuvalue` macro
   that the FFI cannot spell ([standard-library foreign
   callbacks](foreign-functions.md#standard-library-foreign-callbacks)). Two
   more kinds of C stay. A private helper of such an entry, or a C-only
   critical interval, is a `local foreign function` called by name:
   `channel_try_enqueue_native` in `titan/thread/channel.titan` holds the
   channel mutex around the enqueue. A helper that only computes is an
   ordinary function (`reserve_resource` in `titan/transfer.titan`).
   Platform-conditional work is a `static inline` helper that returns a
   status or fills a plain struct, as `titan_probe_parent_stdio` in
   `titan/os_platform.h` does for `titan.os`, which keeps the classification;
   a platform flag is a macro (`TITAN_UV_NETWORK_WINDOWS` in
   `titan/uv/network-native.h`), not a function.
2. **Plain C stays plain C.** Wrong (`titan-browser.c` at `843b446e`):
   `root_callable_worker`, pushed with a light-userdata context and run under
   `lua_pcall` only so that `luaL_ref` can raise, be caught, `luaL_unref`'d and
   raised again. Right: a helper that returns a status for its caller to act
   on, as each `uv_*` call returns its status to the Titan wrapper. Scratch
   storage is not transit: `titan_path_query_root` in `titan_path.c` keeps the
   child's environment block as userdata on its own stack until `posix_spawnp`
   has copied it, and restores the top instead of taking a registry reference.
3. **Protected work belongs in Titan.** Wrong (`titan-browser.c` at
   `843b446e`): the invoke and release entries each run a C worker under
   `protected_entry`'s `lua_pcall`, and `complete_failure` adds three more
   (`original_trace`, `error_description`, `restore_trace`) to rebuild the
   message and trace that a Titan `catch` has as `error` and `traceback`.
   Right: `timer_callback` and its handler `timer_deliver` in
   `titan/uv/uv.native.titan`, and `invoke` / `invoke_entry` and
   `release_callable` / `release_entry` in `titan/browser.browser.titan`.
4. **Pinning.** Wrong (`titan-browser.c` at `843b446e`): the first bridge's
   callable roots and generations, `luaL_ref` slots in tables hanging off a
   registry userdata's uservalues. Right: `loop.handles`, which `timer_init`
   sets and `timer_closed` clears ([public native
   owners](libuv-extension-guide.md#public-native-owners)), and the per-state
   `pins_by_slot` Array, `pins_by_fn` Map, and owned state record in
   `titan/browser.browser.titan`. Its state record uses `gc.finalizable`, with
   no bridge root in the Lua registry.
5. **Rooting.** Wrong (`browser.browser.titan` at `843b446e`): `invoke`,
   `request` and `callable` push their parameters, and `invoke` and `request`
   push an `extra` buffer declared inside an `if`. Right: an owner local
   declared before the `if` keeps the buffer, and the parameters need nothing.
6. **Don't duplicate checks the receiver makes.** Wrong
   (`browser.browser.titan` and `titan-browser.mjs` at `843b446e`): `callable`
   reflects a closure's signature into kind descriptors that the loader
   re-checks (`snapshotArguments`) before Titan's dynamic entry checks the call
   again. Right: one tagged union (`BrowserValue`) marshalled by runtime type
   at the boundary, with a callee that cases on it and raises for a variant it
   rejects (the cartridge's `twice` example).

### The same rules for browser JavaScript

Authored JavaScript is the embedded loader
(`titan-runtime/browser/titan-browser.mjs`), the `--js-library` files beside it
(`titan-browser-library.js`, `titan-browser-bridge.js`, and
`titan-browser-trace.js`), an `EM_JS` or `EM_ASM` block in a C helper, and
JavaScript text that the compiler emits. [Source
ownership](browser-bridge.md#javascript-files) records what each shipped file
owns. The runner (`titan-browser-run.mjs` with its page and worker scripts) is
host tooling outside the image, reviewed as an ordinary Node program.

A review counts the authored JavaScript lines that a diff adds and names, for
each added function or block, the host capability that requires it:

- suspending or resuming Wasm (JSPI), or handling an engine failure;
- holding or converting JavaScript values and host objects;
- a host scheduling or event API (`setTimeout`, `MessageChannel`,
  `AbortSignal`, a listener, a promise continuation);
- the embedder-facing promise API (admission, settlement, `Error` objects,
  option callbacks);
- engine stack capture.

A function or block with none of these is a finding of the same class as an
avoidable C line: its state, policy, validation, or bookkeeping belongs in
Titan. The counterexamples below come from the loader at commit `843b446e`
and at commit `48b26b75`; rules 2 and 5 have no JavaScript reading.

1. **Layering.** Wrong (`titan-browser.mjs` at `843b446e`): `signatureAt`
   decoded each exported callable's parameter and result descriptors,
   `wrapCallable` stored them on the wrapper, and `completionTarget` rejected
   a request whose completion had "an incompatible signature". That is
   validation of Titan functions, written in JavaScript. Right:
   `registerCallable` creates one wrapper object for a pin identity and
   nothing else. Every import in `titan-browser-bridge.js` is one line that
   forwards to the loader owner (`titan_browser_host_adopt` to `adoptSlot`),
   and its two helpers hold the only shared logic: a trusted import that
   throws poisons the instance (`trusted`), and a host import that throws
   fills the response (`response`). A Task-form call is Titan too:
   `spawn_call` and `shutdown_call` in `titan/async/runtime.browser.titan`
   start, cancel, and settle the Task, while the loader keeps the promise,
   the `AbortSignal` listener (`taskAborted`), and the `Error` objects.
   Wrong (`titan-browser.mjs` at `48b26b75`): `armChunk` and `periodElapsed`
   re-armed long delays inside the loader. Right: each SDK source arms one
   bounded host timer, and `timer.browser.titan` chains chunks for long sleeps
   and ticker periods.
3. **Protected work belongs in Titan.** Right: `importResponse` catches a
   binding's exception at the import, keeps the thrown value in a slot, and
   fills `titan_browser_response`; `check_response` in
   `titan/browser.browser.titan` raises `BrowserError` after the import
   returns. A trusted import never throws into Wasm. The bridge library
   treats the opposite as corruption: a synchronous callback that a
   JavaScript exception ends poisons the instance (`callbacksLeft`).
4. **Pinning and data placement.** Wrong (`titan-browser.mjs` at
   `48b26b75`), twice. The `holds` map was a per-state copy of Titan's count
   of open `BrowserPin`s, kept current by a dedicated import
   (`titan_browser_host_hold`) only so that `hasWakeSources` could read it.
   And each request record counted its queued notifications
   (`pendingNotifications`, `holdsReleased`) to decide when Titan's holds on
   `completion` and `failure` could drop. Right: the pin table and its hold
   counts are module variables of `titan/browser.browser.titan`
   (`pins_by_slot`, `Pin.holds`, `RequestHolds`), and the loader holds one
   wrapper object per pin and the slot table of JavaScript values. Where the
   loader needs a Titan fact, Titan passes it with the call that needs it.
   `titan.browser` counts its open pins (`open_pins`), and `relinquish`
   passes `WAIT_HELD` instead of `WAIT` while one is open. The driver's
   choice between a turn and a wait crosses the same way
   (`browser.relinquish(runtime.ready_head == nil)`), so the loader keeps no
   copy of the ready queue either.
6. **Don't duplicate checks the receiver makes.** Wrong (`titan-browser.mjs`
   at `48b26b75`), twice. `driveBegin` poisoned when a drive was already
   active, after `drive_begin` had refused the same call with `"browser drive
   is already active"`. And the loader tested for an exhausted operation
   identity at seven sites, though it allocates an identity at two. Right:
   each side tests the fact it owns, once. `nextOperationId` is the one
   place that refuses an exhausted identity. `validateCallable` tests what
   only JavaScript knows (the wrapper's brand, its instance, and its logical
   release, which is synchronous in JavaScript), and `invoke_work` tests the
   pin generation that Titan owns.

## Model actual call and result protocols

Fixed Titan calls nil-fill omitted positions and evaluate/discard surplus
arguments. Every nil-filled position must still pass its static or dynamic
type check. Only a declared variadic tail consumes surplus values. An API
that observes the first heterogeneous argument therefore needs one `value`
formal, not a variadic tail merely to ignore later arguments.

Express callbacks with their fixed prefix, variadic tail, and flexible result
types whenever those describe the protocol. Reserve unqualified `value` for
dynamic unions/dispatch or opaque Lua objects. Use fixed option tuples when
the result protocol has a fixed number of slots, even when one branch fills
slots with nil or typical callers use only the first. Flexible results describe
runtime-variable arity, not a looser source API's accidental result count.
When tightening a producer, recursively inspect every `return callee(...)`
forwarder and remove propagated flexible tails until reaching a truly variable
result protocol. Callable adjustment follows the same directionality: extra
actual fixed formals must accept nil and, when behind an expected variadic
tail, its element type. The [boundary chapter](type-relations-and-boundaries.md)
owns the precise relation.

The PEG and string substitution, search, label, and grammar-collection
protocols that apply these rules are specified in [PEG
embedding](lpeglabel-embedding.md) and
[strings](string-library.md#iteration-and-replacement).

## Keep behavior tests at the public boundary

Library behavior belongs to the native module-owned suites. Compiler, provider,
build, source-interposition, and raw-layout proofs belong to their existing
Lua/native harnesses; do not recreate source transformers, redundant native
interposition, or generated-object inspection in library cases. A library
failure exposing a compiler gap gets a small separate compiler regression.
See [test placement](test-runner.md#regression-placement).

A case for a browser-subset module belongs in an owner that the browser suite
runs (`TITAN_STDLIB_BROWSER_TEST_ROOTS`), which imports only subset modules,
owner-local support, and `support.common.titan`. A case that needs `lua`,
`fs`, `thread`, a host command, or another native-only facility goes to the
module's native-only owner (`test.host_tests`, `reflect.lua_tests`,
`json.lua_tests`, `protobuf.resource_tests`) or a `.native.titan` contributor,
never to a browser copy. Express target facts (sizes, endianness, locale,
pointer width) as target-derived expectations instead of skipping them; see
[the browser test owners](browser-target.md#test-owners-and-the-browser-suite).

Runtime-bound resources must retire through the same supervisor Task before
its loop ends. Cancellation never releases native callback owners early, and
unrelated root cleanup must not invalidate shared provider/runtime artifacts.
Use the [async runtime](libuv-runtime.md) and each domain chapter for request,
subscription, cancellation, and shutdown details.
