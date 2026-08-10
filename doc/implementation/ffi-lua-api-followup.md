# Lua C API FFI Follow-Up

The general Lua C API remains deliberately out of scope for the C FFI v1
implementation. The v1 surface is strong enough for ordinary C headers, owned
buffers, fields, arrays, and explicit C varargs, but exposing stack-oriented Lua
C API calls to arbitrary Titan programs still needs a separate design pass.

The standard `titan.peg`, `titan.string`, `titan.lua`, `titan.iter`,
`titan.gc`, and `titan.test` implementations are a narrow trusted exception. Their
module-private code uses an audited allowlist of raw Lua C API operations
against the generated function's built-in `lua_State *L`. That exception is
an implementation technique, not a user-facing FFI feature and not permission
to treat an imported `lua.h` as an ordinary safe binding.

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

* use only the built-in `L` for the current generated function; never store,
  return, or substitute the pointer;
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
  call boundary. The one manual `lua_pcallk` use in `titan.test` is a fixed,
  module-initialization helper factory with an exact two-result ledger.

The current allowlist has the following accounting rules. “Pushes one” means
the pushed slot is also a temporary GC root until the saved top is restored.

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Net zero; snapshots the current stack height. |
| `lua_checkstack` | Net zero; reserves the complete maximum temporary stack effect before the first push. `titan.lua` reserves one or two slots depending on the helper, `titan.iter` reserves three slots for map/key/item, and `titan.gc` reserves four for map/metatable/key/value. |
| `ffi.lua_pushtvalue` | Push one traced Titan value. The boundary pushes an existing semantic Map, key, string, or other value rather than manufacturing a placeholder. `titan.gc` receives a `{value: value}` view of any more precise cache type and pushes that same underlying Map; the new stack slot roots it until the saved top is restored. |
| `lua_getglobal` | Push one global value and may invoke the global table's `__index`, allocate, call user code, or raise. `titan.lua` copies the result to a traced `value` before restoration. |
| `lua_getfield` | Push one fetched value and may invoke `__index`, allocate, call user code, or raise. PEG uses it for its private registry metatable lookup; `titan.lua` uses it on the registry's supported raw layout to fetch the loaded-module table, then validates and traces that table. |
| `lua_getmetatable` | Push the exact metatable when present, otherwise push nothing. `titan.gc` keeps the conditional result on the stack while changing its raw `__mode` field. |
| `lua_setmetatable` | Pop the typed Titan metatable being installed on a typed Titan Map. `titan.gc` is the sole stdlib caller and uses it only when the supplied Map has no existing metatable; PEG and string configure their private weak caches through that public boundary. |
| `lua_rawset` | Pop key and value while retaining the table. `titan.gc` uses it on a confirmed existing metatable so changing `__mode` cannot invoke a metatable-of-metatable `__newindex`; the public API's write barrier remains responsible for the new edge. |
| `lua_next` | Pop the current key and, on success, push the next key and item; exhaustion pushes nothing. It can longjmp for an invalid key. `titan.iter` copies both successful results into traced `value` locals before restoring the entry top. |
| `luaL_loadbufferx` | Push exactly one compiled function on success or one error object on failure, using the explicit input length rather than a terminating zero. `titan.lua` checks the status, traces the surviving object, and restores the saved top. Compilation can allocate or longjmp. |
| `luaL_loadstring` | Push one compiled function or one error object. `titan.test` uses only a fixed internal helper-factory chunk, traces an error before raising, and restores the saved top. The `luaL_dostring` convenience is a function-like macro and is not FFI-callable. |
| `lua_pcallk` | Pop the fixed helper-factory function and zero arguments, then push exactly two closures on success or one error object on failure. `titan.test` uses a nil continuation in non-yieldable module initialization and traces both successful closures before restoring the top. |
| `lua_setupvalue` | Install and pop the stack-top value as the selected closure upvalue, applying Lua's barrier. If that upvalue does not exist it returns null and pops nothing, so `titan.lua` removes the unused environment explicitly. |
| `luaL_tolstring` | Push one string result. It may invoke `__tostring`, allocate, or raise, so the result is copied to a traced Titan value before restoration. `titan.test` catches a throwing renderer and preserves a fixed failure-text fallback. |
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
