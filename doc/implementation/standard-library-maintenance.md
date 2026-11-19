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

Thirteen shared core modules form the dependency-free part of the [browser
standard library](browser-target.md#the-browser-standard-library):
`coroutine`, `gc`, `iteration`, `math`, `test`, `reflect`, `json`, `protobuf`,
`transfer`, `peg`, `string`, `url`, and `path`. None may gain an import path
to `io`, `os`, `lua`, `http`, `websocket`, `uv`, `async`, `timer`,
`titan.browser`, or a native-only module (`fs`, `net`, `ssl`, `sqlite3`,
`thread`), and
their only native payload and include path is LPegLabel: a libuv, OpenSSL,
llhttp, or SQLite header, archive, or symbol fails the [dependency-closure
check](browser-target.md#the-dependency-closure-check) in `make browser-sdk`
and `make titan-stdlib-browser-test`.

The browser library is a reviewed subset of the native one, enforced by the
[subset parity gate](browser-target.md#subset-parity-gate) against the status
inventory `scripts/browser_stdlib_inventory.lua`:

* A change to a public declaration that both targets have updates every
  implementation that declares it (shared source, `.native.titan`, and
  `.browser.titan`), both type fixtures
  (`spec/fixtures/stdlib/titan_stdlib_types.lua` and
  `titan_stdlib_browser_types.lua`, the latter regenerated with
  `check_browser_stdlib.lua fixture`), and its inventory row. The browser
  declaration keeps the native signature exactly, including parameter names,
  generics, and C facts.
* A delivered module must not declare a public member its native module
  lacks; a browser-only declaration belongs in `titan.browser`.
* A public member added to the native module either gets a browser
  implementation and a test that the inventory names, or an `absent:typed`
  or `absent:native-only` row. A member that would always raise needs a
  `raise` row and the maintainer's approval; none exists today.
* A new native module gets a `present` or `absent` module row; an absent
  row's reason is what the [absent-module
  diagnostic](browser-target.md#the-absent-module-diagnostic) prints.

Read a target-dependent constant from a target C define through `ffi`, as
`coroutine`, `protobuf`,
`json`, and `path` do, rather than adding a `.browser.titan` copy; reserve a
variant for a real behavioral difference. Native-only modules with no shared
main keep their canonical mains as `<name>.native.titan`. The complete shared
`io` facade instead imports `os`, whose shared main composes with native or
browser clock, environment, process, and stdio contributors.
The `lua` composition shares its main and worker; the browser selects a
no-filesystem loading contributor and omits native background execution
([Lua composition](lua-library.md#browser-states-and-stock-profile)).

`titan.async` is a browser module through its own browser composition: its
shared main and the `runtime.browser.titan` and `external.browser.titan`
contributors, which import `titan.browser`. Its absent members and its
type-only `ExternalWait` and `Completion` are inventory rows, so a new public
`async` member that the browser cannot provide needs an absent row, and a
shared one must type-check without `uv`. A browser declaration that can
produce an `ExternalWait` or `Completion` value fails the gate's type-only
check.
`titan.timer` is one through its flat variant `titan/timer.browser.titan`,
built on public `async` and the SDK's timer sources; a member added to
`timer.native.titan` needs its browser twin. Private fields of `Ticker`, of
the `os` stream records, and of the network clients may differ between
targets; their public fields and methods may not.

`titan.http` and `titan.websocket` are browser modules through their client
compositions. Their shared contributors (`http.titan`, `headers.titan`,
`options.titan`, `websocket/types.titan`, `websocket/utf8.titan`) must
type-check on both targets, so they import neither `net`, `ssl`, `uv`, nor
`titan.browser`; native transport, server, upgrade, and transfer code lives in
`*.native.titan` contributors, and the browser client in `*.browser.titan`.
A public member added to a native contributor is either given a browser
implementation with the same signature or given an absent row in the
inventory. Neither browser composition may reach llhttp, OpenSSL, or libuv.
Request and connection policy stays in Titan; the SDK's `titan:fetch` and
`titan:websocket` sources only reach host objects ([the same rules for
browser JavaScript](#the-same-rules-for-browser-javascript)).

Only these browser files may import `titan.browser`: those of `async`
(`runtime.browser.titan` and `external.browser.titan`), `timer.browser.titan`,
`os/stdio.browser.titan`, `http/client.browser.titan`, and the WebSocket
browser main `websocket/websocket.browser.titan`, whose import the browser
`websocket/client.browser.titan` uses within the same module.

The browser provider's other target-specific module, `titan.browser`
(`titan/browser.browser.titan`), is the one reviewed browser-only exception.
It has no native placeholder or native interface, so the gate does not
compare it. It imports only `gc`, defines its native entry points as foreign
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

Standard-library and runtime code that touches C (authored C, a source
`foreign function` callback, or a `lua_*`/`luaL_*` call) or JavaScript (a
`--js-library` file, the browser loader, an `EM_JS` or `EM_ASM` block, or
JavaScript glue that the compiler generates) follows six rules. A review counts
the new Lua C API calls, authored C lines, and authored JavaScript lines in a
diff and justifies each one against a rule.

Each rule below states the requirement, then pairs it with a counterexample
from the initial browser bridge (`titan-runtime/browser/titan-browser.c`,
`titan/browser.browser.titan`, and `titan-runtime/browser/titan-browser.mjs` at
commit `843b446e`) and with current code that follows it. [Foreign
functions](foreign-functions.md) and the [libuv extension
rules](libuv-extension-guide.md) describe the mechanisms; the
[`titan-ffi` cartridge](../../.agents/skills/titan-ffi/SKILL.md) carries the
same pairs for agents with compiled examples. [The same rules for browser
JavaScript](#the-same-rules-for-browser-javascript) apply across the browser
host boundary.

1. **Layering.** Write the work in Titan; do not add hand-written runtime C
   files or JavaScript state machines for standard-library bindings. Place each
   piece of a native boundary by how C or the host reaches it:
   - *Called through a function pointer* (libuv callbacks, `__gc` and other
     `lua_CFunction`s): a `local foreign function`, address taken.
   - *Called by name where any C symbol works*: a public `foreign function`; C
     callers use the generated `.titan.h` (or the mangled declaration).
   - *A private helper of such an entry, or a C-only critical interval* (a body
     that holds a native mutex, performs an atomic handoff, or moves a native
     resource between two owners, where nothing may raise, collect, or grow the
     Lua stack): a `local foreign function` called by name, taking formals and
     returning a status (rule 2). Code that only computes, or that a raise on
     entry cannot harm, is an ordinary Titan function.
   - *Needs an exact unmangled C symbol* (an Emscripten export, a symbol a C
     library looks up): a compiler-generated one-line forward to a public
     `foreign function` (with a weak declaration when the owning module may be
     absent), never a hand-written runtime C wrapper.
   - *Program entry and image lifecycle* (native `main`, browser
     `initialize`/`entry`/`close`): a compiler-generated launcher sharing one
     error-conversion and trace implementation; protected calls live there, not
     in runtime libraries.
   - *Needs the JavaScript host* (browser target): JavaScript, and only for an
     operation that the host alone can perform — suspending and resuming Wasm
     (JSPI) or handling engine failure, holding and converting JavaScript
     values and host objects, host scheduling and event APIs (`setTimeout`,
     `MessageChannel`, `AbortSignal`, listeners, promise continuations), the
     embedder-facing promise API (admission, settlement, `Error` objects,
     option callbacks), and engine stack capture. State, policy, validation,
     and bookkeeping stay in Titan, and an import is a one-line forward to the
     JavaScript object that owns the capability.
   - *Data placement*: per-state roots in module variables or owner fields; a
     cross-state map with the host that owns the instance (the browser loader's
     state-token map), not C statics in runtime code; in JavaScript only what
     needs host lifetime (JavaScript values and host objects, promises and
     their continuations, and items waiting for a point where Wasm can be
     entered), never a running copy of a count or table that Titan owns,
     because Titan passes such a fact with the call that needs it; the Lua
     registry only to anchor an object before any module variable exists,
     explicitly justified.
   - *Struct access and marshalling*: in Titan through `foreign import`;
     headers hold only struct layouts, declarations, and one-expression inline
     bridges (`lmacro_*` in `titan/ffi.h`) for macros, internal fields of
     incomplete structs, and `const` casts that the FFI cannot spell directly.
   - *Platform-conditional code*: Titan has no conditional `foreign import`, so
     an operation whose headers, types, or calls differ by platform lives in a
     `static inline` function in the owning module's `*_platform.h` or
     `*-native.h` header. It takes formals and returns a status or fills a
     plain struct (rule 2), and its comment names the platform difference.
     Classification, mapping to public errors, retries, and ownership stay in
     Titan (`titan/os/os_platform.h` and its callers in `titan.os`). A platform
     fact that takes no argument is not a function: define a macro on every
     platform (`TITAN_PATH_WINDOWS` in `titan/path_platform.h`,
     `TITAN_UV_NETWORK_WINDOWS` in `titan/uv/network-native.h`) and read it
     through `ffi` as a constant.
   - *Test-only C*: stays in test fixtures.

   ```text
   -- In titan/browser.browser.titan: public foreign function called by the
   -- compiler-generated `titan_browser_invoke` weak forward in browserentry.lua.
   foreign function invoke(
       raw_id: unsigned long long, raw_token: unsigned int,
       raw_slot: unsigned int, raw_generation: unsigned int,
       raw_argc: unsigned int, raw_args: const *void): int
   ```

   ```javascript
   // In titan-runtime/browser/titan-browser-bridge.js: an import is a one-line
   // forward to the loader owner, which holds the JavaScript value in a slot.
   titan_browser_host_adopt: (state, slot, generation) =>
     TitanBridge.trusted('adoptSlot', state >>> 0, slot >>> 0, generation >>> 0),
   ```

   *Wrong* (`titan-browser.c` at `843b446e`): a 600-line runtime C file
   hand-writing the Emscripten exports, the image launcher `protected_entry`, a
   C `states` linked list, and `titan_browser_root_callable` (validating the
   closure, copying its signature into a new userdata, and rooting it in C).
   *Right*: `browserentry.lua` generates the launcher (sharing
   `titan_entry_error_message` with native `main`) and one-line weak forwards
   (`titan_browser_invoke`, `titan_browser_release_callable`) to public
   `foreign function`s in `titan/browser.browser.titan`. Its state record is
   Titan-owned module storage finalized by an ordinary function through
   `gc.finalizable`; `mark_closing` and the entry trampolines remain foreign
   functions, and the cross-state token map lives in the JavaScript registry.
   The libuv callbacks are local `foreign function`s whose one C helper,
   `titan_uv_push_owner` in `titan/uv/callback.h`, wraps the `setuvalue` macro
   that the FFI cannot spell ([standard-library foreign
   callbacks](foreign-functions.md#standard-library-foreign-callbacks)).
   `channel_try_enqueue_native` in `titan/thread/channel.titan` is a `local
   foreign function` holding the channel mutex around enqueue; `reserve_resource`
   in `titan/transfer.titan` is an ordinary function; `titan_probe_parent_stdio`
   in `titan/os/os_platform.h` is a `static inline` platform helper returning a
   status while `titan.os` keeps the classification.

2. **Plain C stays plain C.** Data that only C uses lives in C locals, formals,
   and return codes, never on the Lua stack. Never `lua_pcall` a C function
   that Lua never sees just to get a protected region; return a status from it
   instead. Scratch storage is not transit: a `lua_CFunction` in the runtime
   may allocate a buffer as userdata and keep it on its own stack while it
   calls Lua API functions that can raise, anchoring the buffer by that stack
   slot and never by `luaL_ref`.

   *Wrong* (`titan-browser.c` at `843b446e`): `root_callable_worker`, pushed
   with a light-userdata context and run under `lua_pcall` only so that
   `luaL_ref` can raise, be caught, `luaL_unref`'d and raised again. *Right*: a
   helper that returns a status for its caller to act on, as each `uv_*` call
   returns its status to the Titan wrapper; and `titan_path_query_root` in
   `titan_path.c`, which keeps the child's environment block as userdata on its
   own stack until `posix_spawnp` has copied it and then restores the top.

3. **Protected work belongs in Titan.** A boundary that must catch raises calls
   a Titan function whose body uses `catch` and `defer`, where `error` and
   `traceback` are available. The native callback trampolines are the model:
   recover the state, owner, handler closure, and entry; push the owner when
   the handler may remove its last other home; call the entry; restore the
   stack top. A JavaScript import that can throw follows the same split: it
   catches at its own boundary and fills a status record, and Titan raises
   after the import returns. A JavaScript exception never unwinds Wasm frames.

   *Wrong* (`titan-browser.c` at `843b446e`): the invoke and release entries
   each run a C worker under `protected_entry`'s `lua_pcall`, and
   `complete_failure` adds three more (`original_trace`, `error_description`,
   `restore_trace`) to rebuild the message and trace that a Titan `catch` has
   as `error` and `traceback`. *Right*: `timer_callback` and its handler
   `timer_deliver` in `titan/uv/uv.native.titan`, and `invoke` / `invoke_entry`
   and `release_callable` / `release_entry` in `titan/browser.browser.titan`.

4. **Pinning.** Per-state roots live in a module variable (a Map or Array) or
   in an owner record's field, as `loop.handles` does in `titan.uv`, never in
   `luaL_ref` slots, registry tables, or userdata uservalue tables. The browser
   state record uses owned module storage and `gc.finalizable`, not a registry
   anchor; a genuinely pre-module lifecycle anchor needs separate justification.

   *Wrong* (`titan-browser.c` at `843b446e`): the first bridge's callable roots
   and generations, stored in `luaL_ref` slots inside tables hanging off a
   registry userdata's uservalues. *Right*: `loop.handles`, which `timer_init`
   sets and `timer_closed` clears ([public native
   owners](libuv-extension-guide.md#public-native-owners)), and the per-state
   `pins_by_slot` Array, `pins_by_fn` Map, and `gc.finalizable` state record in
   `titan/browser.browser.titan`.

5. **Rooting.** A Titan parameter is rooted by its caller until the call
   returns, wherever the caller read the argument from, and a local by its
   frame slot, which is refreshed at its declaration and at every assignment
   and is reused by sibling scopes once its block ends ([the function
   frame](values-and-gc.md#1-the-function-frame-reserved-nil-initialized-stack-slots),
   [home roots](values-and-gc.md#2-home-roots-shadow-slots-and-borrowed-c-copies),
   and [calls](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport)).
   Declare a value that must outlive an inner block in the outer block. A Titan
   function may remove an argument's last other home and keep using the
   parameter. A `foreign function` that calls a native entry is the caller in
   that contract and keeps what it passes reachable itself (rule 3). Never
   `lua_pushtvalue` a parameter or local just to keep it alive.

   *Wrong* (`browser.browser.titan` at `843b446e`): `invoke`, `request`, and
   `callable` push their parameters, and `invoke` and `request` push an `extra`
   buffer declared inside an `if`. *Right*: an owner local declared before the
   `if` keeps the buffer, and the parameters need nothing.

6. **Don't duplicate checks the receiver makes.** Where the other side of a
   boundary is dynamically typed, marshal by runtime type into one tagged union
   at the boundary and let the receiver decide what it accepts. Do not build
   parallel signature or descriptor machinery that re-checks the same thing on
   both sides. Across the JavaScript boundary in both directions, the side
   that owns a fact checks it once: Titan refuses what Titan knows (a closed
   handle, an inactive drive) before calling an import, and JavaScript refuses
   what only JavaScript knows (a released wrapper, a disposing instance, an
   ill-formed string).

   *Wrong* (`browser.browser.titan` and `titan-browser.mjs` at `843b446e`):
   `callable` reflects a closure's signature into kind descriptors that the
   loader re-checks (`snapshotArguments`) before Titan's dynamic entry checks
   the call again. *Right*: one tagged union (`BrowserValue`) marshalled by
   runtime type at the boundary, with a callee that cases on it and raises for
   a variant it rejects.

### The same rules for browser JavaScript

Authored JavaScript is the embedded loader
(`titan-runtime/browser/titan-browser.mjs`), the `--js-library` files beside it
(`titan-browser-library.js`, `titan-browser-bridge.js`, and
`titan-browser-trace.js`), an `EM_JS` or `EM_ASM` block in a C helper, and
JavaScript text that the compiler emits. [Source
ownership](browser-bridge.md#javascript-files) records what each shipped file
owns. The runner (`titan-browser-run.mjs` with its page and worker scripts)
and the compiler's module check (`titan-browser-module-check.mjs`, which needs
a JavaScript parser) are host tooling outside the image, reviewed as ordinary
Node programs.

A review counts the authored JavaScript lines added by a diff and names, for
each added function or block, which host capability listed under rule 1
requires it. Any function or block without one is a finding of the same class
as an avoidable C line: its state, policy, validation, or bookkeeping belongs
in Titan. The counterexamples below come from the loader at commits `843b446e`
and `48b26b75`; rules 2 and 5 are specific to C and the Lua stack.

- **Rule 1 — Layering.** *Wrong* (`titan-browser.mjs` at `843b446e`): `signatureAt`
  decoded each exported callable's parameter and result descriptors,
  `wrapCallable` stored them on the wrapper, and `completionTarget` rejected
  a request whose completion had "an incompatible signature" — validating
  Titan functions in JavaScript. *Right*: `registerCallable` creates one
  wrapper object for a pin identity and nothing else. Every import in
  `titan-browser-bridge.js` is one line forwarding to the loader owner
  (`titan_browser_host_adopt` to `adoptSlot`), and its two helpers hold the
  only shared logic: a trusted import that throws poisons the instance
  (`trusted`), and a host import that throws fills the response (`response`).
  Task-form calls follow the same split: `spawn_call` and `shutdown_call` in
  `titan/async/runtime.browser.titan` start, cancel, and settle the Task,
  while the loader keeps the promise, the `AbortSignal` listener
  (`taskAborted`), and the `Error` objects.
  *Wrong* (`titan-browser.mjs` at `48b26b75`): `armChunk` and `periodElapsed`
  re-armed long delays inside the loader. *Right*: each SDK source arms one
  bounded host timer, and `timer.browser.titan` chains chunks for long sleeps
  and ticker periods.
- **Rule 3 — Protected work belongs in Titan.** *Right*: `importResponse`
  catches a binding's exception at the import, keeps the thrown value in a
  slot, and fills `titan_browser_response`; `check_response` in
  `titan/browser.browser.titan` raises `BrowserError` after the import
  returns. A trusted import never throws into Wasm; a synchronous callback
  that ends by a JavaScript exception poisons the instance (`callbacksLeft`).
- **Rule 4 — Pinning and data placement.** *Wrong* (`titan-browser.mjs` at
  `48b26b75`), twice: the `holds` map mirrored Titan's count of open
  `BrowserPin`s via a dedicated import (`titan_browser_host_hold`) just so
  `hasWakeSources` could read it, and each request record counted its queued
  notifications (`pendingNotifications`, `holdsReleased`) to decide when
  Titan's holds on `completion` and `failure` could drop. *Right*: the pin
  table and its hold counts are module variables of
  `titan/browser.browser.titan` (`pins_by_slot`, `Pin.holds`, `RequestHolds`),
  while the loader holds one wrapper object per pin and the slot table of
  JavaScript values. Where the loader needs a Titan fact, Titan passes it with
  the call: `relinquish` passes `WAIT_HELD` instead of `WAIT` while
  `open_pins > 0`, and `browser.relinquish(runtime.ready_head == nil)` reports
  ready-queue emptiness without duplicating the queue in JavaScript.
- **Rule 6 — Don't duplicate checks the receiver makes.** *Wrong*
  (`titan-browser.mjs` at `48b26b75`), twice: `driveBegin` poisoned on an
  active drive after `drive_begin` had already refused it, and the loader
  checked for an exhausted operation identity at seven sites even though it
  allocates one at only two. *Right*: each side tests the fact it owns once.
  `nextOperationId` is the single check for identity exhaustion;
  `validateCallable` tests what only JavaScript knows (brand, instance, and
  synchronous logical release), and `invoke_work` tests the pin generation
  that Titan owns.

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
owner-local support, and the portable `support.common`, `support.runtime`,
and `support.async` helpers. A case that needs native Lua file or worker
execution, `fs`, `thread`, a host command, or another native-only facility
goes to the module's native-only owner (`test.host_tests`, `reflect.lua_tests`,
`json.lua_tests`, `protobuf.resource_tests`) or a `.native.titan` contributor,
never to a browser copy. Express target facts (sizes, endianness, locale,
pointer width) as target-derived expectations instead of skipping them; see
[the browser test owners](browser-target.md#test-owners-and-the-browser-suite).

Runtime-bound resources must retire through the same supervisor Task before
its loop ends. Cancellation never releases native callback owners early, and
unrelated root cleanup must not invalidate shared provider/runtime artifacts.
Use the [async runtime](libuv-runtime.md) and each domain chapter for request,
subscription, cancellation, and shutdown details.
