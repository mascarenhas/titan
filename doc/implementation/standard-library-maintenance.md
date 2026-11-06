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
`async`, or another native-only module (`timer`, `io`, `fs`, `net`, `ssl`,
`http`, `websocket`, `os`, `lua`, `sqlite3`, `thread`), and their only native
payload and include path is LPegLabel: a libuv, OpenSSL, llhttp, or SQLite
header, archive, or symbol fails the [dependency-closure
check](browser-target.md#the-dependency-closure-check) in `make browser-sdk`
and `make titan-stdlib-browser-test`. A new shared module or member keeps
its native signature and behavior; the [member
inventory](browser-target.md#interface-derived-member-inventory) fails on any
difference between the native and browser interfaces. Read a target-dependent
constant from a target C define through `ffi`, as `coroutine`, `protobuf`,
`json`, and `path` do, rather than adding a `.browser.titan` copy; reserve a
variant for a real behavioral difference. The native-only modules keep their
canonical mains as `<name>.native.titan`, so a later browser composition adds
a selected `.browser.titan` main or contributors without renaming them back.

The browser provider's fourteenth module, `titan.browser`
(`titan/browser.browser.titan`), is the one reviewed browser-only exception.
It has no native placeholder or native interface, so the member inventory
skips it. It imports only `gc` and `reflect`, keeps its C runtime in the
browser runtime archive, and must not gain a native-only dependency either. A
native module must not import it; see [browser bridge
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

Ordinary C/libuv calls stay in Titan wrappers behind `foreign import`, with
their error translation and rooting beside the operation. Source-defined
`foreign function` declarations own expressible callbacks. Handwritten C
shims are reserved for opaque layout or compile-time portability facts the
FFI cannot express; document the exception immediately above each narrow,
namespaced shim. Prefer the public libuv operation over platform-specific
shortcuts when libuv provides it. See [foreign functions](foreign-functions.md)
and [libuv extension rules](libuv-extension-guide.md).

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
