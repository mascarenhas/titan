# Lua states and loading standard library

The `titan.lua` module creates independent Lua states, compiles Lua chunks,
reads chunks through Titan I/O, executes Lua files asynchronously, and loads
Lua, C, or Titan modules into the current Lua state. Import it by its
qualified name:

```titan
local lua = import "lua"
```

## Independent Lua states

```text
record Lua
  -- Private state ownership.
end

function new(): Lua
function Lua:close()
function Lua:detach(): foreign *lua_State

function Lua:run(chunk: string, name: string?, ...: async.TransferValue):
    (...: async.TransferValue)
function Lua:run_async(chunk: string, name: string?, ...: async.TransferValue):
    (...: async.TransferValue)
function Lua:run_from_loader(reader: io.Reader, name: string?,
    ...: async.TransferValue): (...: async.TransferValue)
function Lua:run_async_from_loader(reader: io.Reader, name: string?,
    ...: async.TransferValue): (...: async.TransferValue)
```

`new` creates a Lua state with its own globals, registry, and garbage
collector, and opens the Lua standard libraries. Its globals and loaded-module
cache are independent of the Titan program's hosting Lua state and every
other `Lua` instance. Changes persist between calls on that instance.
`new` also snapshots native loaders from the creating state's
registry-backed preload table. String-keyed C functions with no upvalues are
installed under the same names in the new state's preload table. This includes
the generated loaders of initialized Titan modules, so code in the new state
can require modules embedded in the hosting executable without a separate
provider file. Lua closures, C closures with upvalues, nonfunction values,
and nonstring keys are skipped.

Only loader names and native function pointers are copied. Requiring a Titan
module initializes that module in the new state; no host module value or
`package.loaded` cache entry is shared. The snapshot is taken at creation, so
later changes to either state's preload table do not update the other. The
source is the canonical registry `LUA_PRELOAD_TABLE`, even if Lua code has
reassigned the public `package.preload` field. Custom native loaders and any
library containing their code must remain loaded for every state using the
copied function pointers, just as for a transferred native function.

For generated Titan loaders, the snapshot also carries a matching native
provider descriptor containing code pointers, not module state. Compiled
dynamic imports use an already initialized destination module first, then a
copied native provider, then the ordinary provider file search. Dependencies
available in the snapshot therefore need no manual initialization order or
filesystem path. ABI and consumer compatibility checks still run before a new
dependency is initialized. Globals, metatables, module values, and resolved
bindings are created independently in each state. A nested `lua.new()` can
copy inherited loaders and descriptors even before their modules have been
initialized in the intermediate state.

`require` otherwise uses the new state's own `package.path`, `package.cpath`,
and searchers, initially configured by Lua's standard-library initialization.
Host path/searcher customizations are not copied. Installed Titan shims and
providers remain available when that state's paths find them.

`run` compiles and executes the complete text or binary chunk, passing
its variadic arguments to Lua's `...` and returning the complete result list.
An omitted or nil `name` uses the chunk itself, as in `load`. Input byte
lengths are explicit; strings and chunks can contain embedded zero bytes.
A synchronous call blocks the calling thread until Lua returns.

`detach` transfers ownership of an idle open `lua_State *` out of the `Lua`
wrapper and marks the wrapper closed so neither `close` nor GC finalization
closes the underlying state. Calling `detach` on a busy or already closed
`Lua` instance raises. The caller becomes responsible for eventually calling
`lua_close` on the returned pointer.

### Transferring values

The canonical [`transfer.TransferValue`](standard-library-transfer.md) union is
defined by `titan.transfer`; `async.TransferValue` in the signatures above is a
transparent alias of that same type. Import `transfer` or `async` to construct
its variants. Only these variants cross the independent-state boundary:

| Variant | Argument in the independent state | Result mapped to this variant |
| --- | --- | --- |
| `is_nil` | nil | nil |
| `is_boolean` | boolean | boolean |
| `is_integer` | Lua integer | Lua integer |
| `is_float` | Lua float | Lua float, even when numerically integral |
| `is_string` | a copied Lua byte string | a copied Titan byte string |
| `is_lua_state` | lightuserdata containing the borrowed state address | Lua thread, as its borrowed `lua_State *` |
| `is_function` | a C function with no upvalues | light C function or C closure with no upvalues |
| `is_pointer` | lightuserdata containing the borrowed address | lightuserdata or other full userdata's payload address |
| `is_record(module, name, data)` | a fresh record decoded from protobuf bytes | a public record serialized with its module and fully qualified name |
| `is_union(module, name, data)` | a fresh union decoded from protobuf bytes | a public union serialized with its module and fully qualified name |
| `is_closure(module, entry, data)` | a reconstructed Titan closure with copied captures | a Titan closure, including an adjusted closure or bound method |
| `is_record_payload(module, name, data)` | a record reconstructed by its static transfer hook | a public record with the custom transfer-hook pair |

**Existing policies.** A result that is already an origin-state `async.TransferValue` uses that
variant's policy. For example, returning `TransferValue.is_string(bytes)`
copies those bytes, and returning `TransferValue.is_record(module, name, data)` carries
that existing serialized payload without serializing the wrapper. Pointer and
state variants preserve their explicitly selected kind. Custom record payloads
likewise retain their supplied module, name, and opaque bytes.

**Custom records.** Public records with the exact synchronous
[`to_transfer_payload` / `from_transfer_payload` pair](async-io.md#custom-record-transfer)
use that protocol before structural protobuf encoding. Their fields may be
private. The returned `is_record_payload` is an inspectable policy;
`policy:to_value()` invokes the current state's reconstruction hook. Incoming
custom-record arguments reconstruct before the chunk runs. Their policy
carries the defining module name, record name, and opaque byte string. If the
record is absent from the destination registry, transfer calls that module's
native preload loader and retries lookup. It does not infer a module name from
the record's dotted name. The reconstruction hook interprets the bytes, using
the same descriptor as its encoder when it uses an anonymous protobuf message.

**No packet attachments.** These calls carry values over the Lua library's own
native carrier, not a transfer packet. `Lua:run`, `run_async`, and both
Reader-loading companions open no packet scope, so they cannot move
packet-attached resources such as `thread.Sender` or `thread.Receiver`, whether
passed directly, nested in records, inside opaque hook bytes, or in closure
captures. Converting an endpoint to a policy outside a packet scope raises.
Inside an enclosing packet scope the conversion reuses that packet, but the
index bytes own nothing and do not turn this carrier into an attachment
transport. Use a
[`thread` packet route](standard-library-thread.md#closing-cloning-and-transferring-endpoints)
or an [`async.Receiver`](async-io.md#cross-state-receivers) when endpoint
ownership must cross states.

**Manual handoff.** The programmer owns safe native resource handoff inside supported custom hooks.
Transport copies opaque payloads and borrows explicit native tokens; it neither
moves native ownership automatically nor rolls back hook side effects if
conversion or later execution fails. Only the specific types listed in the
[manual-handoff inventory](standard-library-transfer.md#manual-handoff-api-inventory)
provide those hooks; other filesystem, process, stream, and SQLite objects do
not acquire a handoff API by using this carrier. Deliver each detached payload
to exactly one adopter or use its documented recovery/disposal path.

**Closures.** Titan closures transfer automatically when returned directly. Their owning
modules are initialized through the receiving state's native preload table
before reconstruction. A missing preload is an error. The loader returns its
memoized module and does not depend on global `require`.
Captured values follow the [closure transfer rules](async-io.md#transfer-values):
captures are snapshotted by `TransferValue.from_value`, each restored closure
receives fresh mutable cells,
module globals belong to the destination module, and unsupported captures or
cycles raise in the origin. The returned `is_closure` contains the module name,
an immutable native entry token, and capture bytes. Calling `to_value()` builds
a callable owned by the caller's collector. The policy survives the independent
state closing, subject to the lifetime of any borrowed native pointers it contains.

**Records and unions.** Public records without custom transfer hooks, and public unions, are serialized through
[`protobuf.serialize`](standard-library-protobuf.md). All record fields and
union variants must be public, and the encountered value graph must contain
only supported data and no cycles. Unsupported nominal values raise; they do
not silently become borrowed addresses. The caller receives the nominal name
and defining module name plus wire bytes and may decode them with `TransferValue:to_value()` or
`protobuf.deserialize_nominal`.
Incoming record/union arguments are decoded automatically before the chunk
runs. `TransferValue:to_value()` uses the defining module's preload loader on a
registry miss; direct `protobuf.deserialize_nominal` still requires the type
to be initialized already.

**Counts and results.** Argument and result counts preserve nil positions. Results follow Titan's
ordinary flexible-return demand: a finite consumer takes the requested prefix,
while materializing an open result run has the usual 200-value limit. The
independent-state API does not impose that limit on a larger Lua result run
consumed through a smaller finite prefix. Every returned value is still
validated, including an ignored tail. A table, Lua function, or ordinary C closure
with upvalues has no transfer representation and raises if returned. An `is_lua_state` argument
is an opaque pointer in the destination, not a coroutine attached to its
collector. Its original variant is erased there: returning that lightuserdata
produces `is_pointer` unless Lua explicitly returns an `is_lua_state` wrapper.
Foreign userdata metatables, uservalues, and ownership are never copied.
A null `is_function` pointer is rejected before execution or when encountered
in an origin-state transfer wrapper.

**Strings and borrowed pointers.** Each side allocates its own strings from the exact bytes; neither side installs
the other state's `TString` in its own collector. Serialized nominal graphs
also allocate fresh destination values. The three pointer variants are borrowed addresses. They
neither retain nor validate the originating object or native code. Keep a
returned thread or full userdata reachable in its originating state for the
complete borrow, and keep the state open. For example, a global or registry
reference can retain an object; retaining only its `async.TransferValue` cannot.
Native memory and C functions likewise require an independently valid
lifetime. Concurrent access to pointed-to mutable data must be synchronized
by the caller.

**Errors.** Load errors, execution errors, and unsupported results raise on the Titan
caller. The independent state's stack is restored to its entry height on
success and failure, preserving any preexisting stack values, so a failed call
does not prevent a later call. Effects already made
to globals or external resources are not rolled back. Lua errors cross as
copied diagnostics, not shared error objects.

### Asynchronous execution

`run_async` executes the chunk in
[`async.run_foreign`](async-io.md)'s shared libuv worker pool. It must run in
an async Task; while the worker runs, other Titan Tasks can continue. The
worker has exclusive access to the independent state. The chunk can require
and execute Titan modules initialized in that state, including running their
own async Tasks and loop. Their module values, runtime, and GC objects belong
to that state; they cannot access the hosting state's corresponding objects.
C functions or modules used by the chunk must obey the same isolation and
their own thread-safety contracts.

For example, this complete Titan module requires Titan's string module in
the independent state and calls it on a worker. The module can be found through
a copied native preload entry or the state's configured provider paths. Call
`uppercase` from an async Task:

```titan
local lua = import "lua"
local async = import "async"

function uppercase(text: string): string
  local state = lua.new()
  defer state:close()
  local result = state:run_async([[
    local strings = require("titan.string")
    return strings.upper(...)
  ]], "=independent-uppercase", async.TransferValue.is_string(text))
  case result
  when is_string(upper) then return upper
  else raise "independent state returned an unexpected value"
  end
end
```

Only one chunk call may own a `Lua` instance at a time. A concurrent
`run`, `run_async`, or `close` on that busy instance raises
immediately. Different independent states may execute concurrently. A raw
pointer does not bypass this ownership rule: foreign code must not access the
state while its worker is active.

Cancellation does not interrupt running Lua code or release the state early.
After an async call has been accepted, the worker must finish and its native
completion must reach the event loop before the waiting Task receives its
pending cancellation. The state remains reserved through that completion;
after cleanup it can be used again or closed. A Lua chunk that never returns
therefore also prevents that Task's cancellation from completing. Long jobs
share worker capacity with filesystem and DNS operations.

### Two-phase receiver bootstrap

A first `run_async` call can create a receiver before its independent state's
loop starts. Keep its owner rooted there and return only its native handle. A
second call runs that state's Tasks and loop. `async.send` uses the handle
without accessing the remote state's Lua objects and can publish a message
before the loop starts. The Receiver retains only the latest pending packet;
its [coalescing contract](async-io.md#cross-state-receivers) does not guarantee
one receipt per send.

This complete standalone module sends one copied control message before
starting the remote loop. The send has returned before the remote waiter can
close the Receiver or end its Runtime. The handle stays inside one lexical
scope and is never published to another sender. Cleanup closes and drains the
remote Runtime before releasing its Receiver root and closing the state.

```titan
local lua = import "lua"
local async = import "async"

function main(_args: {string}): integer
  local state = lua.new()
  defer state:close()
  defer state:run([[
    if control_receiver then control_receiver:close() end
    require("titan.async").loop()
    control_receiver = nil
  ]], "=receiver-cleanup")

  local exported = state:run_async([[
    control_receiver = require("titan.async").receiver()
    return control_receiver:handle()
  ]], "=receiver-bootstrap")
  defer exported = async.TransferValue.is_nil()
  case exported
  when is_pointer(handle) then
    -- Finish sending before the remote loop can begin teardown.
    async.send(handle, async.TransferValue.is_string("stop\0"))
    state:run_async([[
      local async = require("titan.async")
      local task = async.run(function()
        control_receiver:wait()
        control_receiver:close()
      end)
      async.loop()
      if not task:status():has_succeeded() then
        error("receiver Task failed")
      end
    ]], "=receiver-worker")
  else raise "receiver bootstrap returned no native handle"
  end
  return 0
end
```

A long-lived service can send through the same handle while `run_async` owns
the remote state. Its shutdown protocol must stop senders and establish that
every send has returned before the remote Receiver closes or its Runtime
shuts down. A stop message can arrive before its sender returns, so receipt
alone does not establish that ordering. Then wait for the worker to finish
before dropping the remote Receiver root or calling `Lua:close`. Cancelling
the hosting Task does not interrupt its Lua chunk or synchronize senders.

Long-lived `run_async` calls occupy libuv worker threads for their entire
execution, even while their remote event loop is waiting. The pool is shared
across every state and loop, including filesystem, DNS, and other
`run_foreign` work such as SQLite. Keep capacity for work that these services
need; occupying every worker with services that await queued pool jobs can
prevent progress. Configure `UV_THREADPOOL_SIZE` before the first pool use;
creating a new Lua state does not create another pool. See
[libuv's thread-pool contract](https://docs.libuv.org/en/v1.x/threadpool.html).

### Reader input and closing

`run_from_loader` and `run_async_from_loader` first collect the complete
Reader contents, then call the matching chunk method. They accept empty chunks and preserve all
bytes, and never close the borrowed Reader. Reader methods may suspend and
therefore require an async Task when they do. The state is reserved only
after reading finishes: another call may use or close it while the Reader is
being drained, and admission is checked when the chunk call starts.

`close` releases the independent state and is idempotent after successful
closure. Later chunk calls raise. Call it explicitly with `defer` when the
state's useful lifetime is lexical. If an unclosed `Lua` wrapper becomes
unreachable, its finalizer closes the state. Closing invokes Lua's `__gc`
metamethods as part of `lua_close`; code owning resources inside the state can
use those metamethods for shutdown. Accepted asynchronous work retains the
wrapper until native completion, so GC cannot close a state that a worker is
still using.

## Loading a string

```text
function load(chunk: string, name: string?, env: value):
    function (...: value): (...: value)
```

`load` compiles all bytes in `chunk` as a Lua text or binary chunk. It uses
an explicit byte length, so an embedded zero byte is never mistaken for the end
of the input. An invalid text chunk, an invalid binary chunk, or any other load
failure raises the Lua error; unlike Lua's global `load`, this API does not
return a `(nil, message)` pair.

`name` is the chunk name used in diagnostics. When it is omitted or nil, the
chunk string itself is the name, matching Lua's default. The returned callable
forwards a run-time-sized sequence of `value` arguments and results, including
nil elements:

```text
local lua = import "lua"

local chunk = lua.load("return ...", "=passthrough", nil)
return chunk("first", nil, "third")
```

When `env` is omitted or nil, the chunk retains the ordinary global
environment. A nonnil value replaces its first upvalue, which is `_ENV` for
an ordinary text chunk. This is Lua's environment rule: the supplied value need
not be a Map, and indexing a value that cannot satisfy the chunk's global
accesses raises when the chunk runs. For a binary chunk, the first upvalue is
set regardless of its debug name; a chunk with no upvalues simply ignores the
environment.

`load` compiles but does not execute the chunk. Errors raised later by the
callable propagate normally.

## Loading through a Reader

```text
function load_from_reader(reader: io.Reader, name: string?, env: value):
    function (...: value): (...: value)
```

`load_from_reader` uses `reader:read` as a generic-for iterator. Every nonnil
string, including `""`, is the next exact chunk of Lua input, and nil is EOF.
After EOF the collected bytes are compiled with the same name, environment,
error, and flexible-call rules as `load`.

Reader methods may yield; each accepted chunk is appended through a
synchronous `titan.string` writer so loading adds no scheduling boundary of
its own. When the supplied Reader yields, the function must run in an async
Task with the usual loop discipline. It never closes the Reader, whether
reading or compilation succeeds or raises; ownership remains with the caller.

## Executing a file

```text
function dofile(filename: string, ...: value): (...: value)
```

`dofile` opens `filename` with
[`fs.open`](standard-library-fs.md), compiles the complete file with chunk
name `@filename`, and executes it. It forwards every argument to the chunk and
every result back to its caller without collapsing inner nil values. The File
is closed after success, a read or syntax error, or an error raised while the
chunk runs.

Opening and reading use asynchronous filesystem operations. A call which
reaches those operations must therefore run in an async Task with the usual
[`async`](async-io.md) loop discipline.

## Loading modules

```text
function require(modname: string): value
```

`require` shares Lua's registry-backed `package.loaded` table. A truthy
cached value is returned immediately. A loader's nonnil result is stored and
returned; if both its result and `package.loaded[modname]` are nil, `true`
is installed as the fallback. A stored false value deliberately causes the
next call to load the module again.

Loader lookup preserves the ordinary Lua ordering while replacing only the
blocking source-file operation:

1. Call `package.searchers[1]`, normally the preload searcher.
2. Search every template in `package.path` with asynchronous `fs`
   operations. Dots in `modname` become directory separators and every `?`
   in a template becomes that path. A readable candidate is compiled and
   receives `(modname, filename)` when its loader runs.
3. Call searchers at indexes 3 and above, normally the two C searchers followed
   by any appended custom searchers, until the first nil slot.

This source pass loads ordinary Lua files and generated Titan Lua shims. A shim
then performs its normal exact-provider lookup, so `titan.lua.require` does
not need a special Titan-loader branch. C modules continue through Lua's
installed C searchers.

A standalone Titan entrypoint initially publishes only the main module through
the first, preload searcher. Its bootstrap require performs the normal
transitive Titan initialization before `main`. After each generated module
finishes `_init` successfully, it publishes its own `luaopen_*` function in
`registry[LUA_PRELOAD_TABLE]`; `package.preload` aliases that registry table.
This makes every initialized import, including a private static archive
dependency, visible to the preload searcher without a generated shim or
separate provider DSO. Registration itself performs no initialization and does
not fill `package.loaded`. A later `titan.lua.require` calls the published
loader, receives the canonical initialized userdata, and installs it in the
loaded table. The entrypoint does not publish unused or otherwise
uninitialized linked modules. Independent-state snapshots can inherit these
native loaders before their modules are initialized in the destination, as
described above.

The second searcher slot is reserved for the asynchronous source pass and is
never called. Replacing `package.searchers[2]` therefore does not replace that
pass. Moving or copying Lua's built-in source searcher to another slot is not
supported, because invoking it there would reintroduce blocking file I/O.
Replacement or appended custom searchers in the callable slots are supported;
they receive the module name and may return a loader plus loader data, or a
diagnostic string. Searchers and loaders are invoked through Titan's
non-yieldable Lua-callable boundary. A custom searcher or loader that attempts
to yield raises rather than suspending.

Missing source candidates contribute `no file` lines, and diagnostic strings
from other searchers are accumulated into the final
`module ... not found` error. Once a source candidate opens, a read or
compilation failure is terminal instead of being treated as another miss.
Task cancellation during open or reading remains authoritative: the Task's
terminal status is `cancelled` with its original
`async.CancellationReason`, and no contextual source-load failure is reported
as an uncaught Task error.

Source lookup can yield between the start of a load and installing its cache
entry. A simultaneous or recursive `titan.lua.require` for that same module
raises `module 'name' is already being loaded`; it does not start a duplicate
loader and does not wait on hidden scheduler state. The guard is removed after
both success and error, so a later call can retry. Different module names may
load concurrently.

`require` returns only the module value. Lua 5.5's additional loader-data
result is intentionally not part of this typed API.
