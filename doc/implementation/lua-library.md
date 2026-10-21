# Lua-state and loading library implementation

The user-facing contract is in the
[Lua states and loading standard-library chapter](../language/standard-library-lua.md).
`titan.lua` is a folder module built against the pinned Lua 5.5 API. It
uses `titan.fs` for cooperative file access, `titan.io` for the Reader
interface, and binary-safe search/slicing helpers from `titan.string`. It
keeps independent-state ownership separate from current-state loading. The
public operations require no compiler intrinsic. `titan/lua/lua.titan` owns
the public `Lua` owner and host-thread wrappers; `titan.transfer` owns the
canonical `TransferValue` union, with `async.TransferValue` a transparent alias.
`worker.titan` supplies the raw foreign entries, and `native.h` declares their
native packet layouts.

## Independent-state ownership

`Lua` owns a separately allocated `lua_State *`, not a coroutine of the
hosting state. Creation opens the Lua standard libraries. Each state has an
independent global environment, registry, loaded-module cache, allocator/GC
state, and any Titan modules initialized through its Lua loaders. Shared
provider code does not make those module values shared host objects.
Creation snapshots eligible native loaders from the hosting state's
canonical registry `LUA_PRELOAD_TABLE`. It includes only string keys paired
with zero-upvalue C functions; Lua closures, C closures with upvalues, and
other key/value kinds are skipped. The host traversal keeps the source table,
iteration key, loader, and copied names rooted while building the snapshot.
`preload_snapshot` returns traced `LuaPreload` entries. It uses
`titan_module_preload_symbols` to obtain a native `TitanModuleSymbols` callback
only when the live zero-upvalue preload function and descriptor both match the
eligible loader. Initialization marshals names, lengths, loader pointers, and
optional resolver pointers into `titan_lua_preload[]` and passes a `titan_lua_open` packet to the protected
`lua_state_open` entry. Inside that protected callback,
`titan_module_preload` installs each loader and its optional descriptor in the
new state. Matching generated-provider descriptors travel with their
loader entries; only native code pointers cross this boundary. Module names
become new strings in the destination, and C loaders have no captured host
GC state. Native loader and resolver addresses remain borrowed code pointers;
provider libraries must stay loaded for all destination uses.
Runtime-loaded Titan providers remain mapped for process lifetime under the
existing [native-image binding rule](foreign-functions.md#source-collaboration-and-binary-isolation).
That code lifetime does not make a closed Lua state usable.

Generated module initialization registers its native loader in
`LUA_PRELOAD_TABLE` and a separate native provider descriptor under
`TITAN_MODULE_PRELOADS_KEY` (`"Titan module preload providers"`) on each
successful initialization path. Each descriptor is raw full userdata containing
only a `lua_CFunction loader` and `TitanModuleSymbols symbols`; it contains no
module userdata, globals, metatables, or resolved native bindings.
The snapshot copies a descriptor only when it matches an eligible loader. It
also preserves inherited descriptors whose modules have not yet initialized
in the creating state, so nested independent states retain the same native
dependency graph. Invoking a copied loader performs ordinary per-state module
initialization. Neither `package.loaded` entries nor canonical host module
userdata are copied.
Later changes to either preload table are independent; the snapshot source
is the registry table even if the public `package.preload` field was replaced.
Fresh source/provider search paths and searchers still come from Lua's
standard-library initialization, rather than host package-table copies.

An explicit compiled dynamic import selects the destination's canonical
module first, a copied native provider resolver second, and its normal DSO
provider last. Resolving the copied descriptor does not invoke its Lua loader
or initialize a module: generated import code still checks ABI, then the
consumer's compatibility requirements, before calling the selected initializer.
The initializer creates fresh state and bindings in the destination. This
permits copied transitive dependencies to load without provider search paths
or an application-imposed require order. A transitive-owner lookup with a
NULL filename remains canonical-only after explicit imports initialize; a
copied descriptor alone does not satisfy that lookup.

The wrapper is the sole admission owner. A chunk call reserves it before
preparing the independent state's stack, saves its entry height, and retains
the reservation through result transfer and cleanup. An already reserved or closed state rejects a
new chunk call. `close` rejects a busy state, closes an idle state once, and
then becomes a no-op. `detach` rejects a busy or already closed state, clears
`self.handle`, and returns the raw `lua_State *` so an external owner (such as
`titan.thread` worker bootstrap) can adopt and close the state on its own OS
thread without triggering `lua_close` from the creating state's GC finalizer.
The wrapper's GC finalizer uses the same close ownership;
`lua_close` runs the independent state's `__gc` metamethods. Async work retains
the wrapper until native completion, so finalization cannot race a worker.

Reader methods deliberately drain their borrowed Reader before delegating to
the chunk method. They add no second state reservation or reader-close policy.
If reading suspends, a different Task may use or close the state in that
interval. The actual chunk call checks admission against the state that
exists when reading completes.

### Receiver bootstrap and teardown

A `Lua:run` or `Lua:run_async` bootstrap may require `titan.async`, construct a
Receiver outside a Task, root it in that state's module/global storage, and
return its opaque native handle. This does not drive the new Runtime. A subsequent `run_async`
can create the remote waiting Task and drive `async.loop` under its existing
exclusive-state reservation. Sender calls use only the native notification
handle and copied transfer packet; they never enter the busy state or access its Receiver
record. Sends coalesce and the receiving callback overwrites any unread value;
there is no per-message delivery guarantee. See [receiver ownership](libuv-runtime.md#cross-state-receiver-ownership).

The origin must keep that Receiver reachable through the complete exported
handle lifetime. A raw token never becomes an owner. Withdraw the handle and
finish all send calls before receiver close, Runtime shutdown, release of the
remote root, or Lua-state destruction. Send and close are not concurrent-safe;
receiving a stop message alone does not establish that its sender has returned.
After the worker returns, a synchronous cleanup chunk can close any remaining receiver and run
its loop to drain native closure, then drop the root. This also covers bootstrap
or worker-admission failure before asynchronous execution starts. The
[complete two-phase example](../language/standard-library-lua.md#two-phase-receiver-bootstrap)
keeps all sends local and uses this order on success and failure. If the state
is closed with its Runtime still unretired anyway, the Runtime's finalizer
closes its remaining handles and the loop during `lua_close`
([state-close retirement](libuv-runtime.md#lua-state-close-of-an-unretired-runtime));
that fallback does not relax the send-quiescence rule.

A remote Runtime shares libuv's process-wide thread pool with its host and all
other states. A worker that drives a long-lived Runtime still occupies its
pool slot; nested filesystem/DNS/SQLite work needs separate available pool
capacity. Receiver messaging does not add a scheduler or resize that pool.

## Cross-state transfer

The canonical `transfer.TransferValue` union (`async.TransferValue` is a
transparent alias) is interpreted on the host thread. Nil,
boolean, integer, and float keep their exact Lua value kinds. String arguments
are copied into the independent state; string results are copied into newly
allocated host strings. The destination collector must never receive a
foreign `TString *` as one of its own objects. Result strings remain rooted
on the independent stack until the host has copied their complete bytes.
Binary strings retain their explicit lengths throughout.

This boundary uses the separate `titan_lua_value` carrier in
`titan/lua/native.h`, not `titan_async_message`. It has no packet resource table
and opens no attachment/claim scope. `Lua:run`, `run_async`, and their
Reader-loading companions therefore do not carry packet-attached `thread.Sender`
or `thread.Receiver` ownership, even inside nominal payloads, opaque hooks, or
closure captures. Standalone policy conversion cannot manufacture reusable
endpoint ownership bytes. Use a thread packet route or an `async.Receiver` for
those resources; see the
[owning Lua API restriction](../language/standard-library-lua.md#transferring-values)
and [packet scope rules](transfer-library.md#scoped-resource-table-and-manual-resource-ownership).

Before the userdata fallback, the worker identifies an origin-state
`titan.transfer.TransferValue` by its exact canonical metatable and uses its
generated `TITAN_MT_PAYLOAD` reader. Tag and payload queries follow the native
layout rather than assuming uservalue positions. The originating result slot
roots the wrapper and any string payloads until host conversion completes.
Explicit packets preserve their supplied module, name or entry token, and bytes.

Branded Titan closures and other Titan nominals pass through the origin state's
`TransferValue.from_value` under the existing protected call. Exact public
record hooks take precedence over structural protobuf encoding; their private
fields need not be serializable. Both hooks remain synchronous and nonyielding
and exchange one string. Their signatures and calls use ordinary public
reflection descriptors, with no reserved compiler names or generated hook manifest.

Closure conversion projects every immediate capture before calling any custom
hook, converts captures to flat policies, and serializes those policies and
explicit-policy flags with an anonymous protobuf descriptor. Nested closures
and custom records have already become byte strings. Capture cycles raise;
separate closures receive independent mutable cells when restored. The native
entry token is checked for membership in the loaded destination module's
manifest before any descriptor dereference or captured-resource adoption.
Compiler-generated callbacks then restore typed captures and canonical
destination function tags.

The worker loads `titan.transfer` by calling its native preload directly. Titan
module initialization is memoized; no additional cache, carried initializer,
or global `require` is needed. A converted result replaces its original stack
slot and roots all packet strings until host copying finishes. Returning the
original result count keeps these temporary roots private. Conversion failure
rejects the complete result run, including a failed hook in an ignored tail.

Nominal conversion obtains the actual declaring module from `TITAN_MT_MOD`
before invoking a detaching hook. Packets carry that module name explicitly;
no dotted-name splitting is involved. Destination lookup first tries the
nominal registry, then calls the named preload on a miss and retries. Missing
preloads or missing/wrong-kind registered types raise.

Incoming packet arguments use ordinary `TransferValue` constructors or the
closure payload factory and are unwrapped with `to_value()` before the chunk
runs. Returned packets remain policies for explicit host reconstruction. The native carrier
contains only scalar fields, pointer tokens, and borrowed string ranges; the
source owner roots those ranges until the receiving state copies them. No
source GC object, descriptor, or module instance crosses the boundary. There
is no native transfer graph, arena, or recursive cleanup. Application hooks
remain responsible for safe native detachment/adoption and side effects.
Only the [specific supported handoff APIs](../language/standard-library-transfer.md#manual-handoff-api-inventory)
provide such hooks; the separate Lua carrier neither adds missing hooks nor
automatically disposes manually transferred native resources.

State pointers and ordinary pointers become lightuserdata when passed as
arguments. Creating a thread-tagged `TValue` from a foreign state's pointer
would install a GC reference belonging to the wrong state and is prohibited.
Returned threads become borrowed state pointers, other full userdata becomes its
`lua_touserdata` payload address, and lightuserdata preserves its address.
Those addresses do not retain their source object. Callers must arrange a
source-state root for a thread or userdata before its temporary result stack
slot is removed. A zero-upvalue C function carries only its native function
pointer; an ordinary C closure with upvalues or a Lua closure cannot be represented.
Tables are likewise rejected. Function and native-memory lifetime remain
external responsibilities.

The packet and conversion loops preserve every argument/result position,
including nil. Native result count uses an `int`, and a native allocation
holds the complete Lua result run. The host converts it to a Titan Array and
return-spreads that Array under the ordinary flexible-return demand. A finite
consumer can take a small prefix from a Lua run exceeding 200 results; only
an open sink materializing more than `TITAN_VARARG_MAX` (200) values raises
the usual flexible-result error. There is no independent-state truncation or fixed
200-slot native result buffer. Every result is validated before publication,
so an unsupported ignored tail still fails the whole call.

### Protected execution and stack cleanup

Loading, argument installation, chunk execution, and error formatting are
protected operations on the independent state. A Lua failure must return a
status to the host; it must not longjmp across the worker entry or into host
Titan frames. Error objects stay in the state that created them, and the host
raises a copied diagnostic. Error formatting must itself respect the
protected-call boundary, because a nonstring error's conversion can call user
code and fail. `lua_state_error_message` uses `luaL_tolstring` as the protected
call's error handler. If that handler fails, Lua's protected-call error status
and diagnostic are retained; a nonstring fallback uses a fixed diagnostic.

The stack transaction has these ownership phases:

| Phase | Independent stack and host obligation |
| --- | --- |
| Admission | Reserve the wrapper, then save the independent state's exact entry stack height before pushing temporary values. |
| Protected loading and argument copy | Root the compiled chunk, copied input strings, and decoded nominal arguments in the independent state; keep host input owners live while their bytes are borrowed. |
| Protected chunk call and result encoding | Execute and serialize only values belonging to the independent state; preserve its result roots or error object. |
| Host conversion | Read rooted result slots after native execution stops; allocate host strings and canonical `transfer.TransferValue` wrappers on the host thread. |
| Deferred cleanup | Free the native result buffer, restore the independent stack to its saved entry height, and release the reservation after success, load/runtime/conversion error, queue rejection, or cancellation. |

Stack pointers cannot survive an operation that grows that stack. Result
addresses used for copying are derived after native execution finishes and
while the independent state is exclusively owned. Stack cleanup does not undo
changes the Lua code already made to globals, module state, or external data.

### Worker ownership and cancellation

`run_async` builds a `LuaCall` owner containing its state wrapper,
chunk/name strings, argument Array, native input array, and embedded
`titan_lua_call` packet. The packet carries the independent state, chunk bytes
and length, NUL-terminated diagnostic name, argument data, and result/status
storage. The worker allocates the native result buffer for the actual result
count and zeroes every slot before converting results. Slots borrow strings
from rooted remote policies and own no further native allocation, so freeing
the one result buffer also handles a partially converted run. Cleanup occurs
after native retirement on every path.
The host prepares transfer values before submission. The worker entry accepts
only the packet's `void *`; it never recovers a hosting-state Titan record,
reads host module fields, or allocates through the host runtime. The separate
state's own Lua and independently initialized Titan code may allocate and run
there under its exclusive ownership. Native libraries and transferred
pointers remain responsible for synchronization of any process-shared data.

The worker may retain independent-state string pointers in its result data,
but does not create host strings. The host resumes only after
`async.run_foreign` receives native after-work completion. It then performs
host-side result conversion before restoring the independent stack's saved
entry height. Both the
packet and the complete input owner graph stay reachable in the suspended
caller for this interval.

Cancellation follows `run_foreign`'s ordinary accepted-work policy: the Task
stays attached until after-work completion and receives cancellation only
then. The deferred state cleanup also covers that injected cancellation,
without publishing results or prematurely freeing data the worker still
uses. There is no Lua instruction hook, worker termination, hidden queue, or
per-state cancellation scheduler. A nonterminating chunk can therefore hold
its state and worker indefinitely.

## Compiling and rooting a chunk

`load` is a small audited Lua-stack transaction:

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Save the exact entry height. |
| `lua_checkstack(L, 2)` | Reserve the loaded function/error and a possible environment slot before compilation. |
| `luaL_loadbufferx` | Consume no caller-owned stack values and push either one compiled function or one error object. The explicit Titan string length keeps the operation binary-safe. It may allocate or longjmp. |
| `ffi.lua_pushtvalue(env)` | For a nonnil environment, push and root that exact value beside the compiled function. |
| `lua_setupvalue(L, -2, 1)` | On success, pop the environment and install it as the function's first upvalue with Lua's barrier. If no first upvalue exists it returns null and leaves the environment for explicit removal. |
| `ffi.lua_totvalue` | Copy the compiled function into Titan's traced `value` representation before cleanup. |
| deferred `lua_settop` | Restore the entry height on success or any caught load/setup error. |

The load status is checked before the stack error is copied and raised. The
function value remains rooted first by the temporary stack slot and then by the
traced local returned as the flexible callable type. No pointer into the input
string or Lua stack survives an allocating operation.

Omitting `env` adjusts it to nil. That branch deliberately does not touch the
first upvalue, leaving Lua's global environment in place. A nonnil value follows
Lua's first-upvalue rule rather than assuming a table or inspecting the
upvalue's debug name.

## Reader and File ownership

`load_from_reader` uses `Reader:read` directly as a generic-for iterator and
passes every yielded chunk, including `""`, to a synchronous
`string.StringWriter`, the same checked accumulator used by the string
library's formatting, packing, and substitution paths. `Reader:read` owns the
scheduling boundary. Each writer call checks aggregate growth; nonempty inputs
are retained as traced Titan strings, while empty inputs add no storage.
`drain` performs one exact-size allocation and copy after the Reader reports
nil. The result is passed to `load`, with no borrowed Reader buffer or C
pointer retained.

The Reader is borrowed and is never closed. In contrast, `dofile` owns the
`fs.File` it opens and immediately installs a deferred close. That one cleanup
path covers asynchronous read errors, `luaL_loadbufferx` failures, returns, and
errors from the resulting flexible call. The chunk call directly spreads the
incoming flexible tail and returns its flexible results.

## Asynchronous `require`

The module reproduces Lua's require state machine without calling the stock
blocking source searcher:

```text
truthy registry cache
        | miss
        v
same-name loading guard
        |
        v
searcher 1 ---> async package.path pass ---> searchers 3..first nil
        |                 |                         |
        +---------- selected loader + loader data --+
                                  |
                                  v
                  loader result / package.loaded / true
```

In a standalone executable, searcher 1 initially sees only the main loader that
the entrypoint installed. The bootstrap require of that module performs the
existing transitive `_init` recursion before `main`. After each generated
module finishes `_init` successfully, it publishes its own `luaopen_*` function
in `registry[LUA_PRELOAD_TABLE]`, which `package.preload` aliases. Searcher 1
therefore sees every initialized import—including private static imports—by the
time `main` runs. The entrypoint does not publish unused or otherwise
uninitialized linked modules. An independent state can inherit the native
loaders and provider descriptors before initializing their modules, as
described above. A later asynchronous require invokes the published loader, recovers the
canonical module value, and then follows the same registry cache rules shown
above without initializing the module again.

The cache is fetched from
`LUA_REGISTRYINDEX[LUA_LOADED_TABLE]`, just as Lua's own `require` does; a
reassigned public `package.loaded` field does not redirect it. `package`,
`package.searchers`, and `package.path` are read for each uncached load and
validated at their dynamic boundary.

The source pass maps dots to slashes, substitutes every literal `?` in each
semicolon-separated path template, and attempts `fs.open`. A filesystem open
error is a candidate miss. Cancellation and non-filesystem errors retain their
own types and propagate. After a candidate has opened, a read or load error is
wrapped with the module and filename and is terminal. A deferred close owns the
opened candidate on every path. Cancellation uses the nominal
`async.CancellationReason` union rather than an exception-wrapper record: even
if the post-open context wrapper transforms the injected union value, the
Task's stored cancellation request remains authoritative and terminalizes it
as `cancelled` with the original reason rather than reporting a load failure.

Literal module-name and `?` substitutions, Reader chunk loading, ordered
source-miss diagnostics, and the final cross-searcher diagnostic accumulation
all use synchronous `string.StringWriter` instances. This removes local
chunk-array joins and incremental concatenation while retaining binary strings
and encounter order. Actual Reader and File operations remain the cooperative
boundaries; pure substitution and diagnostic assembly do not create extra
scheduler turns. The module-level loading guard spans every real I/O yield, so
cancellation still clears it through `defer` and a concurrent same-name
request cannot publish a duplicate load.

Slot 2 is structurally reserved instead of identified by closure identity.
This avoids comparing, capturing, or wrapping Lua's private built-in searcher:
slot 1 and slots 3 onward are the mutable callable policy, while source lookup
always occupies the asynchronous middle pass. Built-in C searchers and custom
searchers are called through the ordinary typed function-value path. That path
uses the generated non-yieldable Lua-call boundary, so it is safe with respect
to Titan native frames but deliberately cannot suspend. Returned loaders use
the same boundary.

Lua source loaders receive their filename as loader data. Preload and C
searchers retain the loader data they produce. A function-valued first result
selects a loader; a string-valued first result contributes a diagnostic; other
results are ignored. Search stops at the first nil searcher slot, matching
Lua's array traversal.

The module-level `{string: boolean}` loading Map is set before any yielding
search and cleared by `defer`. It is not a promise table: a same-name recursive
or concurrent request raises immediately. This keeps cache publication exactly
once without introducing scheduler ownership or waiter cancellation into a
module loader. Different names have independent entries.

After the loader returns, a nonnil result replaces
`package.loaded[modname]`. The table is then reread so a nil-returning loader
can publish its own value; only a still-nil entry becomes true. False remains
false and therefore triggers a fresh load on the next call.

## Raw stack and GC audit

Three small helpers isolate the other raw operations:

* `global_value` saves/restores the stack, pushes one global with
  `lua_getglobal`, and copies it to a traced `value`;
* `registry_map` pushes the registry field, checks that it is a table, and
  transfers it to a traced typed Map before cleanup;
* `is_lua_function` pushes a traced candidate and uses `lua_type` without
  retaining the temporary slot.

Each helper calls `lua_checkstack` before its first push and uses one deferred
`lua_settop` as the authoritative cleanup. Global lookup can run `__index`
on the global table and allocate or raise; the deferred restoration and traced
copy cover those paths. Registry lookup does not invoke a metamethod for the
registry table's ordinary raw layout in the supported Lua state, but is
nevertheless treated as an allocating/error-capable API boundary.

The source/path builder holds only traced Titan strings and integers. Loader,
loader-data, package, searcher, and cache values likewise remain in traced
locals across filesystem yields and Lua calls. There are no borrowed raw
pointers and no stack index is retained across an operation that can reallocate
the stack.

The focused behavior suite is the native `lua.tests` owner under
`spec/stdlib/titan/lua/`, outside LuaCov. It exercises text and binary chunks,
embedded zero handling, Reader ownership, repeated File-error descriptor
accounting, cache states, asynchronous source loads, duplicate-load rejection,
preload/C/Titan/custom loaders, and diagnostics. Its cancellation case reads an
unbounded source candidate, cancels the waiting Task, checks the terminal
cancelled status, and then retries the same module name from a finite source to
prove deferred guard cleanup. Narrow Lua-host access (for example `/dev/fd`
enumeration) is obtained through a test-only Lua C-API helper without moving
ordinary behavior back into a Busted suite.
