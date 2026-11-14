# Lua-state and loading library implementation

The user-facing contract is in the
[Lua states and loading standard-library chapter](../language/standard-library-lua.md).
`titan.lua` is a folder module built against the pinned Lua 5.5 API. Shared
code uses `titan.io` for the Reader interface and `string.StringWriter` for
binary-safe accumulation; native contributors add `titan.fs` and background
execution. The public operations need no compiler intrinsic.

| File | Owns |
| --- | --- |
| `titan/lua/lua.titan` | shared current-state loading and `require`; the public `Lua` owner, `LuaCall`, synchronous execution, admission, argument preparation and host-side result copy |
| `titan/lua/loading.native.titan` | the `fs` import, source-file search and `dofile` |
| `titan/lua/loading.browser.titan` | the fixed no-filesystem source miss |
| `titan/lua/background.native.titan` | `Lua:run_async`, `Lua:run_async_from_loader`, worker submission and abandoned-call release |
| `titan/lua/worker.titan` | shared source-defined foreign entries on the independent state: `lua_state_open`, `lua_state_run`, `lua_state_execute` and result converters |
| `titan/lua/native.h` | the `titan_lua_open`/`titan_lua_preload` initialization packet and the `titan_lua_call`/`titan_lua_value` call carrier |

`titan.transfer` owns the canonical `TransferValue` union;
`async.TransferValue` is a transparent alias.

## Independent-state ownership

`Lua` owns a separately allocated `lua_State *`, not a coroutine of the hosting
state. Each state has its own globals, registry, loaded-module cache,
allocator/GC state, and Titan modules initialized through its own loaders.
Shared provider code does not make module values shared objects.

`new` registers the GC finalizer first and then calls `Lua:initialize`:

1. `preload_snapshot` walks the hosting state's registry
   `LUA_PRELOAD_TABLE` (not the possibly replaced `package.preload` field) and
   keeps string keys whose value is a C function with no first upvalue. Lua
   closures, C closures with upvalues and other key/value kinds are skipped.
   The traversal keeps the table, iteration key and copied names rooted.
2. For each kept loader, `titan_module_preload_symbols` returns the native
   `TitanModuleSymbols` resolver only when the provider descriptor matches that
   exact loader. Descriptors the creating state itself inherited, for modules
   it has not initialized, are copied the same way, so nested independent
   states keep the same native dependency graph.
3. `Lua:initialize` marshals names, lengths, loader and resolver pointers into
   a `titan_lua_preload[]` inside a `titan_lua_open` packet, creates the state
   with `luaL_newstate`, and calls the protected `lua_state_open` entry. Its
   `lua_state_open_libraries` callback opens the standard libraries, calls
   `titan_module_preload` for each entry, and then calls
   `titan_install_searcher`, so every independent state, including each
   `titan.thread` child, has exactly one [Titan package
   searcher](driver.md#the-titan-package-searcher) at the end of
   `package.searchers`. On the browser it then applies the stock Lua profile
   described below, inside the same protected opener. A failure closes the
   new state and raises the copied message.

How generated initialization publishes the loader and its descriptor is
described in [the module protocol](codegen-overview.md#the-module-protocol);
the registry keys are listed in the
[registry footprint](lua-interop-internals.md#the-registry-footprint).

Only native code pointers cross: module names become new destination strings,
and no `package.loaded` entry, module userdata, metatable or resolved binding is
copied. Later changes to either state's preload table are independent. Lua
search paths come from the destination's own standard-library initialization.
On native targets the Titan searcher computes the destination's own effective
Titan path on its first lookup; neither the creator's `TITAN_PATH_KEY` nor its
SDK fallback outcome is inherited. On the browser it reads no environment
variables and probes no provider files. Invoking a copied loader performs
ordinary per-state module
initialization. Loader and resolver addresses are borrowed code pointers;
runtime-loaded Titan providers stay mapped for the process lifetime under the
[native-image binding rule](foreign-functions.md#source-collaboration-and-binary-isolation),
which does not make a closed Lua state usable.

An explicit compiled dynamic import in the destination selects the canonical
module first, the copied provider resolver second, and the normal DSO provider
last (`titan-runtime/titan_path.c` `titan_module_provider`). Resolving a copied
descriptor neither invokes its Lua loader nor initializes a module: generated
import code still checks the ABI and the consumer's compatibility requirements
before calling the selected initializer. Copied transitive dependencies
therefore load without provider search paths or an application-imposed require
order. A transitive-owner lookup with a NULL filename stays canonical-only; a
copied descriptor alone does not satisfy it.

The wrapper is the sole admission owner (`Lua:reserve`, `Lua:close`,
`Lua:detach`):

- A chunk call reserves the wrapper, saves the independent stack height, and
  keeps the reservation through result copy and cleanup. A busy or closed state
  rejects the call.
- `close` rejects a busy state, closes an idle state once, and is then a no-op.
  The GC finalizer calls the same `close` unless the wrapper is busy; `lua_close`
  runs the independent state's `__gc` metamethods. Ordinary collection never
  sees a busy wrapper, because async work keeps it reachable until native
  completion. Only a [host-state close](#host-state-close-during-run_async)
  can, and the abandoned call then closes the state.
- `detach` rejects a busy or closed state, clears `handle`, and returns the raw
  `lua_State *` so an external owner (the `titan.thread` worker bootstrap) can
  close it on its own OS thread instead of the creating state's finalizer.

`run_from_loader` and `run_async_from_loader` drain their borrowed Reader
before calling `run`/`run_async`. They add no reservation or reader-close
policy. If reading suspends, another Task may use or close the state; admission
is checked against the state that exists when reading completes.

### Browser states and stock profile

Browser independent states use synchronous `run` and `run_from_loader` in the
same WebAssembly instance and on its owner thread. The native background
contributor is not selected; there are no declarations for either async
method or `dofile`. A child cannot create or drive browser Tasks: the browser
driver belongs to the original instance state.

`titan/ffi.h` defines `TITAN_LUA_BROWSER_PROFILE` as a Lua source string on the
browser and an empty string on native targets. The one chunk replaces only
stock `os.clock` and `os.exit`; filesystem, process, environment and stdio
behavior comes from the existing Lua/libc build and launcher definitions.
The chunk first binds `error`, `package.loaded`, `package.preload` and
`require` to locals, so its closures behave like C functions: replacing those
globals later changes neither replacement. Lua's own `require` reads the same
registry tables, so the captured tables are the ones it uses.
`os.clock` raises the no-CPU-clock diagnostic. `os.exit` first consults the
loaded table's `titan.os` entry. When that entry is absent but the linked
preload loader exists, it calls the captured `require`; loader
errors propagate. The generated opener reuses the canonical per-state module
userdata already created by a native import, without rerunning initialization
or creating another stdin/stdout/stderr set. The profile maps boolean
statuses and delegates to Titan's exit request. Without a linked module or
an owner Task it raises the outside-Task diagnostic. Requiring `titan.os` in
a child does not grant driver ownership, so its `os.exit` still raises. It
never reaches C `exit()`.

The [browser initializer](browser-target.md#the-browser-entrypoint) runs the
same chunk immediately after `luaL_openlibs` and `titan_install_searcher`.
`lua_state_open_libraries` applies it after installing the independent state's
searcher, only when the macro is nonempty:

| Step | Stack obligation |
| --- | --- |
| `luaL_loadstring` | Push one rooted chunk or one error; the enclosing `lua_state_open` call is already protected. |
| Failed compilation | `lua_error` propagates the existing error object to that protected call; initialization closes the state. |
| `lua_callk(..., 0, 0, ...)` | Consume the chunk, keep no results, and propagate a runtime failure to the same protected call. |

No temporary stack values survive successful application and no host-state
value crosses into the child. Native openers skip the empty macro.

### Receiver bootstrap and teardown

This section is native-only.

A `Lua:run` or `Lua:run_async` bootstrap chunk may require `titan.async`,
construct an `async.Receiver` outside a Task, root it in that state's module or
global storage, and return its opaque native handle. This does not drive the
new Runtime. A later `run_async` creates the waiting Task and drives
`async.loop` under its exclusive-state reservation. Senders use only the native
handle and copied packets; they never enter the busy state or touch its
Receiver record.

The handle rules (keep the Receiver reachable, withdraw the handle and let every
in-flight send return before close, shutdown, root release or state
destruction) are in
[receiver lifecycle and teardown](libuv-runtime.md#receiver-lifecycle-and-teardown).
A stop message alone does not prove its sender has returned. After the worker
returns, a synchronous cleanup chunk closes any remaining Receiver, runs the
loop to drain native close, and drops the root. The same order covers bootstrap
or worker-admission failure before asynchronous execution starts; the
[two-phase example](../language/standard-library-lua.md#two-phase-receiver-bootstrap)
uses it on success and failure. If the state is closed with its Runtime still
unretired, the Runtime finalizer closes the remaining handles and loop during
`lua_close`
([state-close retirement](libuv-runtime.md#lua-state-close-of-an-unretired-runtime));
that fallback does not relax the send-quiescence rule.

A remote Runtime shares libuv's process-wide thread pool with its host and all
other states. A worker driving a long-lived Runtime occupies its pool slot, so
nested filesystem, DNS or SQLite work needs separate pool capacity. Receiver
messaging adds no scheduler and does not resize the pool.

## Cross-state transfer

`Lua:run*` arguments and results are `TransferValue` policies carried by
`titan_lua_value` (`titan/lua/native.h`), not by a transfer packet. The carrier
holds only scalars, pointer tokens and borrowed byte ranges. It has no resource
table and opens no attachment or claim scope, so `thread.Sender` and
`thread.Receiver` cannot cross this boundary, even inside nominal payloads,
custom hooks or closure captures. Use a thread packet route or an
`async.Receiver` for them; see the
[Lua API restriction](../language/standard-library-lua.md#transferring-values)
and [packet scope rules](transfer-library.md#scoped-resource-table-and-manual-resource-ownership).

**Arguments.** On the host, `LuaCall:prepare` maps each policy variant to a
carrier entry that borrows its strings from the rooted `LuaCall.arguments`
Array. Inside the protected call, `lua_state_execute` pushes nil, booleans,
numbers and copied strings directly; state and pointer tokens as
lightuserdata (a thread-tagged value for a foreign state's pointer would
install a GC reference owned by the wrong state); a C function token as a
zero-upvalue closure; and record, union, closure and record-payload entries
through `lua_state_push_packet`. That helper calls the matching destination
`TransferValue` constructor (`is_record`, `is_union`, `from_closure_payload`,
`is_record_payload`) and then its `to_value`, so the chunk sees the
reconstructed value. `titan.transfer` is loaded in the destination with
`transfer_load_module` ([native module loading](transfer-library.md#native-module-loading)),
not a global `require`.

**Results.** Still inside the protected call, `lua_state_execute` classifies
each result by `lua_type`:

| Lua result | Carrier entry |
| --- | --- |
| nil, boolean, integer, float, string | same kind; string bytes stay rooted in the result slot |
| thread | borrowed `lua_State *` |
| light userdata | pointer, same address |
| full userdata | an explicit `TransferValue` (canonical metatable via `luaL_testudata`, read through its `TITAN_MT_PAYLOAD` reader; `lua_state_transfer_value`); else a branded Titan record or union through `TransferValue.from_value` (`lua_state_nominal_value`); else the `lua_touserdata` payload address |
| function | `TransferValue.from_value` (`lua_state_converted_value`): a zero-upvalue C function becomes its function pointer, a Titan closure becomes a [closure snapshot](transfer-library.md#closure-snapshots), anything else raises |
| table, other | raises `cannot transfer Lua <type> from an independent state` |

A converted `TransferValue` replaces its original stack slot, which roots the
wrapper and its strings until the host has copied them. Custom record hooks
take precedence over structural encoding and must not yield
([hook rules](transfer-library.md#flat-packets-and-direct-classification)).
After native execution, `LuaCall:values` copies every string into the host and
builds host `TransferValue` wrappers. Returned record, union and closure entries
stay policies: the host reconstructs them only through an explicit `to_value`.

Pointer results do not retain their source object. Callers must keep a
source-state root for a returned thread or userdata after the result slot is
removed. Function and native-memory lifetimes are external responsibilities.
The carrier never walks a capture graph, holds no arena, and needs no recursive
cleanup. Application hooks remain responsible for safe native detachment and
adoption; only the
[supported handoff APIs](../language/standard-library-transfer.md#manual-handoff-api-inventory)
provide such hooks, and this carrier does not dispose manually transferred
native resources.

Every argument and result position is preserved, including nil. The worker
allocates one zeroed `titan_lua_value` array sized by `lua_gettop` after the
call, so there is no fixed 200-slot buffer. The host converts all results to a
Titan Array and return-spreads it under ordinary flexible-return demand: a
finite consumer can take a prefix of a longer run, and only an open sink
materializing more than `TITAN_VARARG_MAX` (200) values raises. Every result is
converted before any is published, so an unsupported value in an ignored tail
still fails the whole call.

### Protected execution and stack cleanup

`lua_state_run` performs loading, argument installation, chunk execution and
result conversion inside one `lua_pcallk` of `lua_state_execute` on the
independent state. A Lua failure returns a status to the host; it never
longjmps across the worker entry or into host Titan frames. Error objects stay
in the state that created them, and the host raises a copied diagnostic. The
message handler `lua_state_error_message` applies `luaL_tolstring`, which can
run user `__tostring` code; if the handler itself fails, Lua's error status and
diagnostic are kept. A non-string message after the handler is replaced by the
fixed `independent Lua call failed without a string error`.

| Phase | Independent stack and host obligation |
| --- | --- |
| Admission | Reserve the wrapper, then save the independent state's exact entry stack height before pushing temporary values. |
| Protected loading and argument copy | Root the compiled chunk, copied input strings, and decoded nominal arguments in the independent state; keep host input owners live while their bytes are borrowed. |
| Protected chunk call and result conversion | Execute and convert only values belonging to the independent state; preserve its result roots or error object. |
| Host conversion | Read rooted result slots after native execution stops; allocate host strings and `TransferValue` wrappers on the host thread. |
| Deferred cleanup (`LuaCall:finish`) | Free the native result buffer, restore the independent stack to its saved entry height, and release the reservation after success, load/runtime/conversion error, or cancellation. A [call abandoned by a host-state close](#host-state-close-during-run_async) skips this. |

Stack pointers cannot survive an operation that grows that stack. Result
addresses used for copying are read after native execution finishes and while
the independent state is exclusively owned. Stack cleanup does not undo changes
the Lua code made to globals, module state or external data.

### Worker ownership and cancellation

This section and host-state-close handling are native-only.

`run_async` builds a `LuaCall` holding the `Lua` owner, chunk and name strings,
the argument Array, the owned `titan_lua_value[]` inputs, and an embedded
`titan_lua_call` packet. The packet carries the independent state, chunk bytes
and length, the diagnostic name (`name or chunk`, passed as `const char *`),
argument data, and result and status storage. It then calls
`async.run_foreign(lua_state_run_worker, call.packet, lua_state_release_abandoned)`
through `LuaCall:run_worker`; the third argument is the
[host-state-close release](#host-state-close-during-run_async).
`lua_state_run_worker` restores the pool thread's x87 precision on Windows
([worker floating-point state](libuv-runtime.md#worker-floating-point-state);
the call is empty on other targets) and then calls `lua_state_run`, which
synchronous `run` calls directly. Result slots borrow strings
from the rooted independent stack and own no further allocation, so freeing the
single result buffer also handles a partially converted run.

The worker entry receives only the packet's `void *`. It never recovers a
hosting-state Titan record, reads host module fields, creates host strings or
allocates through the host runtime. The independent state's own Lua and Titan
code may allocate and run there under exclusive ownership. Native libraries and
transferred pointers must synchronize any process-shared data themselves. The
host resumes only after `run_foreign`'s loop-thread after-work callback; the
packet and its input owner graph stay reachable in the suspended caller until
then. Host result copy runs before `LuaCall:finish` restores the stack.

Cancellation follows `run_foreign`'s accepted-work policy
([foreign workers](libuv-runtime.md#foreign-workers)): the Task stays attached
until after-work completion and only then receives the cancellation. The same
deferred `LuaCall:finish` covers that path without publishing results or
freeing data the worker still uses. There is no Lua instruction hook, worker
termination or per-state cancellation scheduler, so a nonterminating chunk holds
its state and pool worker indefinitely.

### Host-state close during `run_async`

A host-state close unwinds a Task parked in `run_async` before the worker
returns, so `LuaCall:finish` would restore the stack, free results and release
the reservation while the worker still runs the independent state. The
wrapper's finalizer could then `lua_close` it under the worker.
`LuaCall:run_worker` sets `pending` before submission and clears it when the
wait returns or raises. `catch` never runs during an unwind, so only an
abandoned wait leaves it set. Its `defer` then clears the wrapper's handle and
reservation, which makes the wrapper behave as closed and its later finalizer
a no-op, and `finish` skips a pending call. Finalizers run newest first: a
wrapper newer than the Task is finalized before the unwind, while still busy,
and its finalizer skips it.

The independent state itself goes to `run_foreign`'s
[abandoned-work release](libuv-runtime.md#foreign-workers):
`lua_state_release_abandoned` frees the result buffer and closes the state on
the closing host thread, after the host Runtime's drain has seen the worker
return. It must not run on the worker. Closing the independent state drains
that state's own Runtime, which can wait for pool work the state queued, and
abandoned `run_async` jobs can occupy every pool thread: closing on each
worker would deadlock once four abandoned jobs occupy the default pool of four. After
the drain, no abandoned job holds a pool thread. The `LuaCall` that embeds the
packet, and the strings its packet borrows, outlive the worker and the release:
`lua_close` frees no object before every finalizer, including the Runtime's,
has run.

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
function value is rooted first by the temporary stack slot and then by the
traced local returned as the flexible callable type. No pointer into the input
string or Lua stack survives an allocating operation.

Omitting `env` adjusts it to nil. That branch does not touch the first upvalue,
leaving Lua's global environment in place. A nonnil value follows Lua's
first-upvalue rule rather than assuming a table or inspecting the upvalue's
debug name.

## Reader and File ownership

`load_from_reader` uses `Reader:read` directly as a generic-for iterator and
writes every yielded chunk, including `""`, to a `string.StringWriter`.
`Reader:read` owns the scheduling boundary. Each write checks aggregate growth;
nonempty inputs are retained as traced Titan strings, while empty inputs add no
storage. `drain` performs one exact-size allocation and copy after the Reader
reports nil. The result is passed to `load`, with no borrowed Reader buffer or C
pointer retained.

The Reader is borrowed and never closed. `dofile` owns the `fs.File` it opens
and immediately defers its close. That one cleanup path covers asynchronous
read errors, `luaL_loadbufferx` failures, returns, and errors from the
resulting flexible call. The chunk call spreads the incoming flexible tail and
returns its flexible results.

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
searcher 1 ---> selected source pass ---> searchers 3..first nil
        |                 |                         |
        +---------- selected loader + loader data --+
                                  |
                                  v
                  loader result / package.loaded / true
```

In a standalone executable, searcher 1 initially sees only the main loader that
the entrypoint installed. Each generated module publishes its own `luaopen_*`
function in `registry[LUA_PRELOAD_TABLE]` after a successful `_init`, so by the
time `main` runs searcher 1 sees every initialized import, including private
static imports, but no unused linked module. A later asynchronous require
invokes the published loader, receives the canonical module value, and follows
the cache rules below without initializing the module again.

The cache is `LUA_REGISTRYINDEX[LUA_LOADED_TABLE]` (`registry_map`), as for
Lua's own `require`; a reassigned public `package.loaded` field does not
redirect it. `package`, `package.searchers` and `package.path` are read for
each uncached load and validated at their dynamic boundary.

The native source pass (`loading.native.titan`'s `source_search`) maps dots to
slashes, substitutes every literal `?` in each semicolon-separated template,
and attempts `fs.open`. An
`async.OperationError` from the open is a candidate miss
(`open_source_candidate`); cancellation and other errors keep their types and
propagate. After a candidate opens, a read or load error is wrapped with the
module and filename and ends the search. A deferred close owns the opened
candidate on every path. Even when that wrapper transforms an injected
`async.CancellationReason`, the Task's stored cancellation request is
authoritative and terminalizes the Task as cancelled with the original reason.

The browser contributor has the same private signature and returns only the
miss line `no source search: the browser target has no filesystem`; it does
not inspect templates or perform I/O. The rest of `find_loader` and `require`
is shared.

Name substitution, Reader chunk loading, and source-miss and cross-searcher
diagnostics all use `string.StringWriter`, preserving binary strings and
encounter order. Only Reader and File operations yield; substitution and
diagnostic assembly add no scheduler turns.

Slot 2 is reserved by position, not identified by closure identity, so Lua's
private built-in searcher is never compared, captured or wrapped: slot 1 and
slots 3 onward are the mutable callable policy, and source lookup always runs
as the selected middle pass. Built-in C searchers, custom searchers and
returned loaders are called through the ordinary typed function-value path,
which uses the generated non-yieldable Lua-call boundary: safe with respect to
Titan native frames, but it cannot suspend.

Lua source loaders receive their filename as loader data. Preload and C
searchers keep the loader data they produce. A function-valued first result
selects a loader; a string-valued first result contributes a diagnostic; other
results are ignored. Search stops at the first nil searcher slot, matching
Lua's array traversal.

Compiled Titan modules therefore need no special branch: in every state Titan
creates, and in a host after `require "titan"`, the [Titan package
searcher](driver.md#the-titan-package-searcher) occupies a slot after Lua's
C searchers (normally slot 5) and runs in the synchronous tail of this
traversal. On native targets its probing, `dlopen` calls, and any one-time
SDK-fallback query block without yielding. On the browser it keeps canonical
and preload lookup, then returns
`no Titan provider search: the browser target has no dynamic providers`.
The filesystem, environment and SDK-fallback helpers are compiled out with
their callers; there is no browser dynamic-provider search.

The module-level `loading: {string: boolean}` Map is set before any yielding
search and cleared by `defer`, so cancellation also clears it. It is not a
promise table: a same-name recursive or concurrent request raises immediately.
This keeps cache publication exactly once without adding waiter ownership or
cancellation to a module loader. Different names have independent entries.

After the loader returns, a nonnil result replaces `package.loaded[modname]`.
The table is then reread so a nil-returning loader can publish its own value;
only a still-nil entry becomes true. False stays false and therefore triggers a
fresh load on the next call.

## Raw stack and GC audit

Three small helpers isolate the other raw operations:

* `global_value` saves/restores the stack, pushes one global with
  `lua_getglobal`, and copies it to a traced `value`;
* `registry_map` pushes the registry field, checks that it is a table, and
  transfers it to a traced typed Map before cleanup;
* `is_lua_function` reads the candidate's type tag from a `foreign TValue`
  copy with `lmacro_ttype` and uses no stack slot.

The first two call `lua_checkstack` before their first push and use one deferred
`lua_settop` as the authoritative cleanup. Global lookup can run `__index` on
the global table and allocate or raise; the deferred restoration and traced copy
cover those paths. Registry lookup is treated as an allocating, error-capable
API boundary as well.

The source/path builder holds only traced Titan strings and integers. Loader,
loader-data, package, searcher and cache values likewise stay in traced locals
across filesystem yields and Lua calls. No borrowed raw pointer and no stack
index is retained across an operation that can reallocate the stack.

The `lua.tests` owner under `spec/stdlib/titan/lua/` runs on native and browser
targets. Shared cases cover text and binary chunks, embedded zeros, borrowed
Reader ownership, custom searchers, cache states, linked initialized imports,
independent-state preload snapshots, close and detach. Transfer case bodies
run through both `run` and a borrowed `run_from_loader`: scalars and binary
strings, C functions and borrowed pointers, explicit policies, records,
unions, custom record payloads, and closures. They check hook execution in
the source and destination, native hook-error text, destination preload
loading, captured cells, module globals, and survival after source close.
Native `run_async` cases use the same assertions rather than duplicate them.
Browser cases also check destination-stable stdin/stdout/stderr identities
and repeated payload discard returning zero. The stock Lua profile runs in
both state kinds, including exit without a published `titan.os` loader and
both replacements after `require`, `package` and `error` are cleared, with
fixed miss diagnostics immune to `TITAN_PATH` changes.

Native-only contributors retain File-error descriptor accounting (through
`titan_uv_test_stdio_open_fd_count`), asynchronous source loads, duplicate-load
rejection, C loaders, receivers and worker execution. The cancellation case
cancels a Task reading an unbounded FIFO source, then retries the same name
from a finite source to prove guard cleanup. `state_close_test.native.titan`
closes hosts with a Task parked in `run_async`: wrapper newer or older than the
Task, worker still running or already returned, and a SIGALRM-guarded child
with four abandoned jobs while each child state has queued pool work. Direct
`package` access and FIFO creation use
`spec/stdlib/titan/lua/test_support.native.titan`.

Embedding-sensitive public-state cases live in the
[bridge and scheduler gates](browser-bridge.md#test-layers), not this plain
owner. They cover bridge invalidation after explicit close, collection or
detach followed by test-owned `lua_close`; non-owner driver and Task
refusals; and stock Lua input, exit, environment and binary output with real
embedding options. Stock exit checks the first normal Lua load against the
native import's stable streams and buffered-output flush order. In the output
case, short buffered `io.write` bytes share print's body chunk; the newline
arrives as a second chunk at that flush. A later `io.flush` publishes the
next buffered write before the following Titan write.
