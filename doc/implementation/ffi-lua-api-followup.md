# Lua C API FFI Follow-Up

The general Lua C API remains deliberately out of scope for the C FFI v1
implementation. The v1 surface is strong enough for ordinary C headers, owned
buffers, fields, arrays, and explicit C varargs, but exposing stack-oriented Lua
C API calls to arbitrary Titan programs still needs a separate design pass.

The standard `titan.peg`, `titan.string`, `titan.lua`, `titan.iteration`,
`titan.gc`, `titan.test`, `titan.transfer`, `titan.thread`, and the Receiver
boundary in `titan.async` are narrow trusted exceptions. Their module-private
code uses an audited allowlist of raw Lua C API operations. Ordinary
current-state functions use the generated function's built-in `lua_State *L`;
restricted foreign callbacks receive the exclusively owned state explicitly.
`titan.lua` owns independent states through its `Lua` record and a separately
audited [protected execution and transfer protocol](lua-library.md#independent-state-ownership).
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
* use native Titan `do ... catch` and `defer` for ordinary Titan error handling;
  errors from typed Lua callables use the generated generic-call boundary,
  not a manual `pcall` wrapper. Manual `lua_pcallk` sites are limited to the
  fixed Lua helper factory in `titan.test`, independent-state open/run in
  `titan.lua`, thread bootstrap, and the consuming raw transfer decoder.
  Restricted foreign bodies have no Titan catch/defer or implicit `L`, and a
  remote state's errors cannot use the host's jump chain. Each retained
  boundary has an explicit result ledger, nil continuation, and owned cleanup.

Independent-state execution is not a substitution of another pointer for a
generated function's built-in `L`. The ordinary wrapper keeps host data in
traced `LuaCall` storage, while restricted foreign callbacks operate only on
the separately owned state. They enclose standard-library initialization,
installation of the host's native loader/provider snapshot, argument copying,
chunk execution, result validation, and error rendering in
that state's protected-call boundary. This permits Lua and Titan code
initialized in the independent state to run there, including on a worker; it
never permits access to the hosting state's objects or callbacks.

The two runtime helpers exposed through `titan/ffi.h` are a narrow native
preload capability. `titan_module_preload_symbols(L, name, length, loader)`
returns a `TitanModuleSymbols` callback only when the canonical preload
table's current zero-upvalue C loader, the supplied loader, and the native
descriptor agree; descriptor lookup validates its exact userdata size.
`titan_module_preload(L, name, length, loader, symbols)`
installs the loader and its optional descriptor; a NULL resolver removes any
stale descriptor for that name. The descriptor is raw full userdata containing
only loader/resolver code pointers, with no GC references or module state.
Both helpers operate on their owning state through raw registry/table access,
reserve four temporary stack slots internally, and restore entry height on
success. They may allocate or raise but never invoke a loader or initialize
its module. Host discovery retains its saved-top
defer, and destination installation runs inside the existing protected opener.
Names are copied into destination strings; returned resolver pointers borrow
provider code for the same lifetime as the copied loader.

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

The async Receiver takes one native packet into an actual guarded raw local
and calls `transfer.decode_message(L, raw)` directly. The C-ABI decoder reserves
its stack before entering allocating work; noncollectable scalar decoding is
C-only, while strings, nominal reconstruction and user hooks remain protected.
It clears and disposes the owner on every normal status return, including
pre-entry failure, without letting a Lua longjmp bypass the caller's mutable
slot update. The ordinary caller first copies a nonnegative-status result or
error into traced Titan `value`, restores its saved stack top, and only then
returns or raises. No foreign sender accesses the destination state. Async's
private runtime registry and error-frame operations retain their separate
continuation-runtime contract.

The current allowlist has the following accounting rules. “Pushes one” means
the pushed slot is also a temporary GC root until the saved top is restored.

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Net zero; snapshots the current stack height. |
| `lua_checkstack` | Net zero; reserves the complete maximum temporary stack effect before the first push. Current-state `titan.lua` helpers reserve one or two slots, or four for preload discovery; independent-state callbacks reserve opener/handler/call slots and argument/result allowance. `titan.iteration` reserves three slots, `titan.gc` four, and raw transfer decode three. A failed raw-decode reservation consumes/disposes the packet and returns a negative status with no new stack value. |
| `ffi.lua_pushtvalue` | Push one traced Titan value. The boundary pushes an existing semantic Map, key, string, or other value rather than manufacturing a placeholder. `titan.gc` receives a `{value: value}` view of any more precise cache type and pushes that same underlying Map; the new stack slot roots it until the saved top is restored. |
| `lua_getglobal` | Push one global value and may invoke the global table's `__index`, allocate, call user code, or raise. `titan.lua` copies the result to a traced `value` before restoration. |
| `lua_getfield` | Push one fetched value and may invoke `__index`, allocate, call user code, or raise. PEG uses it for its private registry metatable lookup; `titan.lua` uses it on the registry's supported raw layout to fetch the loaded-module or preload table, then validates and roots that table. |
| `lua_getmetatable` | Push the exact metatable when present, otherwise push nothing. `titan.gc` keeps the conditional result on the stack while changing its raw `__mode` field. |
| `lua_setmetatable` | Pop the typed Titan metatable being installed on a typed Titan Map. `titan.gc` is the sole stdlib caller and uses it only when the supplied Map has no existing metatable; PEG and string configure their private weak caches through that public boundary. |
| `lua_rawset` | Pop key and value while retaining the table. `titan.gc` uses it on a confirmed existing metatable so changing `__mode` cannot invoke a metatable-of-metatable `__newindex`; the public API's write barrier remains responsible for the new edge. The runtime preload setter uses raw writes inside the protected independent-state initialization callback to install copied loader pairs and native descriptors. |
| `lua_next` | Pop the current key and, on success, push the next key and item; exhaustion pushes nothing. It can longjmp for an invalid key. `titan.iteration` copies both successful results into traced `value` locals before restoring the entry top. The host-side `titan.lua` preload snapshot keeps its registry table and iteration key rooted, tests key/loader kinds without changing the key, copies accepted names, and restores its entry top. |
| `luaL_loadbufferx` | Push exactly one compiled function on success or one error object on failure, using the explicit input length rather than a terminating zero. `titan.lua` checks the status, traces the surviving object, and restores the saved top. Compilation can allocate or longjmp. |
| `luaL_loadstring` | Push one compiled function or one error object. `titan.test` uses only a fixed internal helper-factory chunk, traces an error before raising, and restores the saved top. The `luaL_dostring` convenience is a function-like macro and is not FFI-callable. |
| `lua_pcallk` | Pop the function and arguments, then push the requested results or one error. The fixed `titan.test` Lua factory returns two closures; `titan.lua` open and thread bootstrap return zero results; independent execution returns `LUA_MULTRET`; raw transfer decode returns exactly one value/error above the saved top after removing its handler and disposing any residual owner. All use nil continuations and owning-state protection. Ordinary Titan error handling uses inline native catch/defer instead. |
| `lua_callk` | Inside an already protected foreign trampoline, call the chunk, native bootstrap, or traced destination transfer worker. A nil continuation forbids yielding through the C call. Errors reach the enclosing owning-state `lua_pcallk`; preserve its complete result/error and native-owner ledger before returning to ordinary Titan. |
| `luaL_newstate`, `lua_close` | Create or destroy a separate state, with no host stack effect. Check creation for NULL. `Lua` owns the handle, rejects close while busy, and clears its handle before `lua_close`; explicit close and the GC fallback share that policy. `lua_close` invokes that state's finalizers and invalidates its borrowed addresses. |
| `luaL_openselectedlibs` | Net zero in the independent state; the all-libraries mask opens the Lua standard libraries. It may allocate or raise, so it runs only inside the protected initialization callback. It creates fresh package tables/caches before eligible native loaders and matching provider descriptors from the host snapshot are installed. Cached host module values, package paths, and searchers are not copied. |
| `titan_module_preload_symbols` | Net zero on success; internally reserves four slots for raw registry/preload lookup and validates the current zero-upvalue C loader against the descriptor and supplied pointer. It may allocate or raise. The host snapshot keeps its saved-top defer; the returned resolver contains no GC reference and borrows provider code. |
| `titan_module_preload` | Net zero on success; internally reserves four slots, copies the name, installs the zero-upvalue loader, and writes only native loader/resolver pointers into a separate descriptor. A NULL resolver removes a stale descriptor. It may allocate or raise and is called only within the independent state's protected opener. It does not initialize the module. |
| `transfer_closure_entry` (source foreign function) | Push one copied declaring-module name and return the immutable entry matched through the closure's actual module manifest. The caller keeps the source closure rooted. No source module or GC pointer is retained in the entry. |
| `transfer_capture_count` (source foreign function) | No stack effect. Read only an entry already established by source lookup or destination `resolve`; never apply it directly to an incoming token. |
| `transfer_project` (source foreign function) | Push all immediate semantic captures together, reserving their complete stack run plus projection scratch. Generated typed code reads boxes/native slots; the caller keeps the closure and projected values rooted while later hooks may allocate or collect. |
| `transfer_load_module` (public foreign function) | Push only the module returned by a direct loader call from the registry preload table. The generated initializer supplies ordinary memoization; its result must equal the module already published in the generated initializer's registry entry before native manifest access. Loading may allocate or raise and stays under the owning-state protected boundary; an owning-state Lua wrapper is also valid. |
| `transfer_resolve` (source foreign function) | Net zero. Obtain the loaded destination module's own manifest and compare an incoming token against entry addresses before dereferencing it. This rejects invalid tokens and different physical providers before interpreting captures or running reconstruction hooks. |
| `transfer_restore` (source foreign function) | Push one destination closure from a borrowed contiguous semantic capture run and rooted destination module. One generated function converts and roots internal slots/fresh boxes before allocating and publishing the final closure; tags come from destination caches. Conversion/allocation may raise, and the caller restores its stack. |
| `transfer_nominal_module` (source foreign function) | Push one actual declaring-module name recovered through the candidate metatable's `TITAN_MT_MOD`. Reserve its metatable/owner scratch internally; do not infer module boundaries from nested or folder-qualified nominal names. |
| `lua_pushnil`, `lua_pushboolean`, `lua_pushinteger`, `lua_pushnumber`, `lua_pushlightuserdata` | Push one scalar or borrowed native address after stack reservation. Independent-state thread arguments use lightuserdata, never a thread-tagged cross-state GC reference. |
| `lua_pushcclosure` | The independent-state path uses zero upvalues, pushing only a native C function pointer. This includes copied native preload loaders. It rejects NULL input functions and never adapts a host Titan closure. |
| `lua_pushlstring` | Push one string copied from an explicit byte range. Independent-state input copies run under that state's protection; host result copies retain the independent stack root until conversion. Raw transfer decode copies from its owned packet under the protected destination worker, and the caller roots the value before stack restoration. |
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
