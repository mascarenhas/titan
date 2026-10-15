# Lua C API FFI Follow-Up

The general Lua C API remains deliberately out of scope for the C FFI v1
implementation. The v1 surface is strong enough for ordinary C headers, owned
buffers, fields, arrays, and explicit C varargs, but exposing stack-oriented Lua
C API calls to arbitrary Titan programs still needs a separate design pass.

The standard `titan.peg`, `titan.string`, `titan.lua`, `titan.iteration`,
`titan.gc`, and `titan.test` implementations are a narrow trusted exception. Their
module-private code uses an audited allowlist of raw Lua C API operations
against the generated function's built-in `lua_State *L`. `titan.lua` also
owns independent states through its `Lua` record and a separately audited
[protected execution and transfer protocol](lua-library.md#independent-state-ownership).
That exception is an implementation technique, not a user-facing FFI feature
and not permission to treat an imported `lua.h` as an ordinary safe binding.

## Why It Is Separate

Titan-generated C already includes Lua 5.5 internal headers and manipulates
`TValue`, `Udata`, stack slots, barriers, and `lua_State` internals directly.
The public Lua C API is stack-oriented and longjmp-based. Mixing the two through
ordinary FFI calls means the compiler must know which calls can move `L->top.p`,
allocate, longjmp, invalidate stack addresses, or require a protected-call
boundary.

The main open questions are:

* how much API-specific metadata should attach to the built-in `lua_State *L`
  beyond its raw C pointer type;
* whether public API calls should be ordinary foreign calls or a separate
  trusted binding layer with stack-effect metadata;
* how to express stack preconditions and postconditions, especially for APIs
  that push a variable number of results;
* how to keep GC-able Titan values anchored across calls that may allocate or
  throw;
* how to handle Lua callbacks and `lua_CFunction` values, which overlap with
  the parked C-function-pointer/callback design;
* whether API calls that can longjmp must always be wrapped by the same error
  machinery used by generated Lua entry points.

This is only about calling the **C API surface** as C. Titan already has a
separate route for Lua-callable operations: a value passed into Titan with a
function type can be called by `codevaluecall`'s generic Lua-stack path. That
path uses `luaD_callnoyield`, so it can invoke ordinary Lua closures, Lua C
functions, and `__call` objects without going through the C FFI at all. It is
therefore a viable way to call APIs that have already been packaged as Lua
callables. It does not solve raw stack-oriented API calls such as `lua_push*`,
`lua_get*`, registry operations, or macros that require generated code to reason
about `lua_State *L`, stack effects, allocation, and longjmp behavior.

## Trusted Standard-Library Discipline

The trusted standard-library modules follow these rules whenever they enter the
raw Lua C API:

* current-state helpers use only the built-in `L` for the generated function;
  never store, return, or substitute that host pointer. Independently allocated
  states are owned by `titan.lua.Lua` and obey the separate protocol below;
* snapshot `lua_gettop(L)` before a helper's first push and restore that exact
  top with `lua_settop(L, saved)` on every exit;
* put restoration in `defer`, so a caught Lua error cannot bypass it;
* keep an explicit stack-effect ledger for every path, including optional
  lookup results and zero-result cases;
* copy a result that must outlive restoration into a traced Titan `value` (or
  another traced Titan owner) before resetting the stack;
* never retain a pointer into a Lua string, userdata, or stack slot across an
  allocation, callback, protected call, metamethod, or other operation that can
  move the stack or run Lua. Retain the traced owner plus an integer offset and
  derive the pointer again after the operation;
* call user functions and metamethods only through a non-yieldable path. A
  yield attempt is a normal Lua error at this native/Titan boundary, not a
  suspended continuation;
* let ordinary errors from typed Lua callables use Titan's generated generic
  call boundary. Manual `lua_pcallk` uses are the fixed helper factory in
  `titan.test` and independent-state initialization/execution in `titan.lua`.
  Each has an explicit result ledger, nil continuation, and owned cleanup.

Independent-state execution is not a substitution of another pointer for a
generated function's built-in `L`. The ordinary wrapper keeps host data in
traced `LuaCall` storage, while restricted foreign callbacks operate only on
the separately owned state. They enclose standard-library initialization,
installation of the host's native preload snapshot, argument copying, chunk
execution, result validation, and error rendering in
that state's protected-call boundary. This permits Lua and Titan code
initialized in the independent state to run there, including on a worker; it
never permits access to the hosting state's objects or callbacks.

The cross-state ledger reserves the independent state and uses temporary
stack slots above its saved entry height. Host inputs are retained while native code borrows
their immutable bytes. Result strings stay rooted on the independent stack
until native execution has stopped and host-side conversion copies their
bytes into newly allocated host strings. No foreign GC object is installed in
the other state's collector. Raw returned thread/userdata pointers remain
borrowed and require a caller-maintained source-state root. Deferred host
cleanup frees the native result buffer, restores the independent stack to its
saved entry height, and releases its reservation only after native completion, including cancellation; it never closes an active worker's
state. See the [complete ledger](lua-library.md#protected-execution-and-stack-cleanup)
and [worker lifetime](lua-library.md#worker-ownership-and-cancellation).

The current allowlist has the following accounting rules. “Pushes one” means
the pushed slot is also a temporary GC root until the saved top is restored.

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Net zero; snapshots the current stack height. |
| `lua_checkstack` | Net zero; reserves the complete maximum temporary stack effect before the first push. Current-state `titan.lua` helpers reserve one or two slots, or four for preload discovery; its independent-state callbacks reserve the opener/handler/call slots and the complete argument or result-conversion allowance before each phase; `titan.iteration` reserves three slots for map/key/item, and `titan.gc` reserves four for map/metatable/key/value. |
| `ffi.lua_pushtvalue` | Push one traced Titan value. The boundary pushes an existing semantic Map, key, string, or other value rather than manufacturing a placeholder. `titan.gc` receives a `{value: value}` view of any more precise cache type and pushes that same underlying Map; the new stack slot roots it until the saved top is restored. |
| `lua_getglobal` | Push one global value and may invoke the global table's `__index`, allocate, call user code, or raise. `titan.lua` copies the result to a traced `value` before restoration. |
| `lua_getfield` | Push one fetched value and may invoke `__index`, allocate, call user code, or raise. PEG uses it for its private registry metatable lookup; `titan.lua` uses it on the registry's supported raw layout to fetch the loaded-module or preload table, then validates and roots that table. |
| `lua_getmetatable` | Push the exact metatable when present, otherwise push nothing. `titan.gc` keeps the conditional result on the stack while changing its raw `__mode` field. |
| `lua_setmetatable` | Pop the typed Titan metatable being installed on a typed Titan Map. `titan.gc` is the sole stdlib caller and uses it only when the supplied Map has no existing metatable; PEG and string configure their private weak caches through that public boundary. |
| `lua_rawset` | Pop key and value while retaining the table. `titan.gc` uses it on a confirmed existing metatable so changing `__mode` cannot invoke a metatable-of-metatable `__newindex`; the public API's write barrier remains responsible for the new edge. Independent-state initialization uses `lua_rawset` in its protected callback to install each copied loader name/function pair in the fresh preload table. |
| `lua_next` | Pop the current key and, on success, push the next key and item; exhaustion pushes nothing. It can longjmp for an invalid key. `titan.iteration` copies both successful results into traced `value` locals before restoring the entry top. The host-side `titan.lua` preload snapshot keeps its registry table and iteration key rooted, tests key/loader kinds without changing the key, copies accepted names, and restores its entry top. |
| `luaL_loadbufferx` | Push exactly one compiled function on success or one error object on failure, using the explicit input length rather than a terminating zero. `titan.lua` checks the status, traces the surviving object, and restores the saved top. Compilation can allocate or longjmp. |
| `luaL_loadstring` | Push one compiled function or one error object. `titan.test` uses only a fixed internal helper-factory chunk, traces an error before raising, and restores the saved top. The `luaL_dostring` convenience is a function-like macro and is not FFI-callable. |
| `lua_pcallk` | Pop the function and supplied arguments, then push the requested results on success or one error object on failure. `titan.test` uses zero arguments and exactly two closures in non-yieldable module initialization. `titan.lua` initializes a separate state's libraries with zero results, or invokes its native execution trampoline with one packet argument and `LUA_MULTRET`; its separately rooted error handler remains outside the returned result run. Both owners use nil continuations and complete their stack cleanup. |
| `lua_callk` | Inside the already protected independent-state trampoline, pop the loaded chunk and its arguments and retain its complete result run. Lua errors reach the enclosing `lua_pcallk`; nil continuation prevents yielding through this C call. Capture the complete result count and validate every kind before returning to the host. Native storage is sized to the actual run; the host's ordinary finite/open demand controls flexible-result materialization. |
| `luaL_newstate`, `lua_close` | Create or destroy a separate state, with no host stack effect. Check creation for NULL. `Lua` owns the handle, rejects close while busy, and clears its handle before `lua_close`; explicit close and the GC fallback share that policy. `lua_close` invokes that state's finalizers and invalidates its borrowed addresses. |
| `luaL_openselectedlibs` | Net zero in the independent state; the all-libraries mask opens the Lua standard libraries. It may allocate or raise, so it runs only inside the protected initialization callback. It creates fresh package tables/caches before eligible native preload loaders from the host snapshot are installed. Cached host module values, package paths, and searchers are not copied. |
| `luaL_getsubtable` | Push the selected table, creating it if absent. Independent-state initialization obtains the canonical registry preload table inside the protected callback, then retains it while each copied loader is installed. |
| `lua_pushnil`, `lua_pushboolean`, `lua_pushinteger`, `lua_pushnumber`, `lua_pushlightuserdata` | Push one scalar or borrowed native address after stack reservation. Independent-state thread arguments use lightuserdata, never a thread-tagged cross-state GC reference. |
| `lua_pushcclosure` | The independent-state path uses zero upvalues, pushing only a native C function pointer. This includes copied native preload loaders. It rejects NULL input functions and never adapts a host Titan closure. |
| `lua_pushlstring` | Push one string copied from an explicit byte range. Input copies run in the independent protected entry; result copies run on the host with the source still rooted in the exclusively owned independent stack. |
| `lua_getupvalue` | Push one value and return its name when the selected upvalue exists; otherwise push nothing and return NULL. Independent-state result validation probes index 1 and raises if a C function has any upvalues; the protected failure then owns cleanup. Host preload discovery uses the same test, removes any pushed upvalue, and skips unsupported loaders. |
| `lua_isinteger`, `lua_toboolean`, `lua_tointegerx`, `lua_tonumberx`, `lua_tothread`, `lua_touserdata`, `lua_tocfunction`, `lua_typename` | Net zero. The independent-state transfer loop checks the Lua kind before extracting its scalar or borrowed pointer; pointer results do not retain their source objects. |
| `lua_tolstring` | Net zero for an already string-valued slot and returns borrowed bytes plus length. The independent-state path retains the string's stack root until host copying finishes. Numeric conversion can allocate and must stay within a protected path. |
| `lua_error`, `luaL_error` | Terminate the independent execution callback by raising into its enclosing protected call; never allow this longjmp to cross the worker entry or enter the hosting state's Titan frames. |
| `lua_setupvalue` | Install and pop the stack-top value as the selected closure upvalue, applying Lua's barrier. If that upvalue does not exist it returns null and pops nothing, so `titan.lua` removes the unused environment explicitly. |
| `luaL_tolstring` | Push one string result. It may invoke `__tostring`, allocate, or raise, so the result is copied to a traced Titan value before restoration. `titan.test` catches a throwing renderer and preserves a fixed failure-text fallback. The independent-state error handler in `titan.lua` runs under `lua_pcallk` protection; rendering failure retains Lua's protected-call diagnostic. |
| `lua_type`, `lua_topointer` | Net zero. `lua_type` validates private opener/registry results. A pointer from `lua_topointer` is identity-only and must not be dereferenced. |
| `ffi.lua_totvalue` | Net zero; copies the selected slot into Titan's traced `value` representation before cleanup. |
| `titan_lpeglabel_open` | Push the private engine table and report one result. PEG validates both facts, copies the table to a traced Map, and restores the entry top. |
| `lua_gc` | Net zero and returns a C integer. `titan.gc` passes the exact `size_t` step argument or two promoted C `int` parameter arguments. It turns the API's unavailable `-1` into an error; callers must not invoke collector control from a finalizer. |
| `lua_settop(L, saved)` | The authoritative cleanup operation. Do not try to balance an exceptional path with a guessed series of pops. |

Stack slots created by pushing Titan values are real roots, but only while they
remain below `L->top`. Conversely, a C local containing a raw address is never
a root. A helper that restores its saved top before returning must therefore
have transferred every surviving collectable value to Titan's traced
representation first.

This discipline is intentionally local and reviewable. Adding another raw API
operation requires documenting its stack, allocation, error, callback, and
borrowed-pointer behavior at the use site; the trusted exception must not grow
into an untyped public Lua C API surface.

## Likely Direction

A plain header import of `lua.h` is not enough. A safer public iteration would
probably add a small compiler-provided binding header plus metadata for selected
Lua API functions. That metadata can describe stack effects, allocation/error
behavior, and any value anchoring rules the code generator must enforce.

The first useful milestone is a tiny allowlisted subset: stack size checks,
basic pushes, basic type predicates, and string/userdata reads that do not store
borrowed pointers past the call. More complex APIs, callbacks, and arbitrary
`lua_CFunction` interop should wait until the function-pointer/callback design
exists.
