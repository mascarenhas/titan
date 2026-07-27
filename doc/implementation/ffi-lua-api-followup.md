# Lua C API FFI Follow-Up

The general Lua C API remains deliberately out of scope for the C FFI v1
implementation. The v1 surface is strong enough for ordinary C headers, owned
buffers, fields, arrays, and explicit C varargs, but exposing stack-oriented Lua
C API calls to arbitrary Titan programs still needs a separate design pass.

The standard `titan.peg` and `titan.string` implementations are a narrow trusted
exception. Their module-private contributors use an audited allowlist of raw Lua
C API operations against the generated function's built-in `lua_State *L`.
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

The PEG and string contributors follow these rules whenever they enter the raw
Lua C API:

* use only the built-in `L` for the current generated function; never store,
  return, or substitute the pointer;
* snapshot `lua_gettop(L)` before a helper's first push and restore that exact
  top with `lua_settop(L, saved)` on every exit;
* put restoration in `finally`, so a caught Lua error cannot bypass it;
* keep an explicit stack-effect ledger for every path, including loop
  exhaustion, protected-call failures, and zero-result cases;
* copy a result that must outlive restoration into a traced Titan `value` (or
  another traced Titan owner) before resetting the stack;
* never retain a pointer into a Lua string, userdata, or stack slot across an
  allocation, callback, protected call, metamethod, or other operation that can
  move the stack or run Lua. Retain the traced owner plus an integer offset and
  derive the pointer again after the operation;
* call user functions and metamethods only through a non-yieldable path. A
  yield attempt is a normal Lua error at this native/Titan boundary, not a
  suspended continuation;
* use a protected boundary when an error from user code must be classified or
  translated. Restore the helper's stack first, then raise the Titan-facing
  error; a Lua longjmp must not cross an unrelated generated frame.

The current allowlist has the following accounting rules. “Pushes one” means
the pushed slot is also a temporary GC root until the saved top is restored.

| Operation | Stack effect and obligation |
| --- | --- |
| `lua_gettop` | Net zero; snapshots the current stack height. |
| `ffi.lua_pushtvalue`, `lua_pushnil`, `lua_pushvalue` | Push one value. |
| `lua_pushstring`, `lua_pushlstring` | Push one string. They can allocate or raise; any returned pointer is borrowed. |
| `lua_createtable`, `lua_newuserdatauv` | Push one new collectable value and can allocate or raise. |
| `lua_getfield` | Push one fetched value. It can invoke `__index`, allocate, call user code, or raise. |
| `lua_gettable` | Pop the key and push the fetched value (net zero). It has the same metamethod, allocation, callback, and error obligations as `lua_getfield`. |
| `lua_rawget` | Pop the key and push the fetched value (net zero), without invoking a metamethod. |
| `lua_rawgeti` | Push one fetched value, without invoking a metamethod. |
| `lua_getmetatable` | Push the metatable when present and otherwise push nothing. It does not invoke `__index`; callers must account for both result counts. |
| `lua_setfield` | Pop the value. It can invoke `__newindex`, allocate, call user code, or raise. |
| `lua_setmetatable` | Pop the table or nil being installed as the metatable. |
| `lua_rawset` | Pop the key and value. |
| `lua_rawseti` | Pop the value. |
| `lua_next` | On success, replace the incoming key with the next key and value (net +1); on exhaustion, pop the key (net -1). |
| `luaL_tolstring` | Push one string result. It may invoke `__tostring`, allocate, or raise, so any returned pointer is borrowed only until the next unsafe operation or stack restoration. |
| `luaL_checkinteger`, `luaL_checknumber`, `luaL_checklstring` | Net zero, but may convert or raise. The pointer from `luaL_checklstring` is borrowed under the same rule. |
| `lua_type`, `lua_isinteger`, `lua_toboolean`, `lua_tointegerx`, `lua_topointer`, `lua_rawequal` | Net zero. A pointer from `lua_topointer` is identity-only and must not be dereferenced. |
| `ffi.lua_totvalue` | Net zero; copies the selected slot into Titan's traced `value` representation before cleanup. |
| `lua_pcallk` | Consume the function and arguments and leave the requested results, or one error object. Snapshot the top before preparing the call, request/count the exact result shape, copy any surviving results into traced Titan values, and normalize back to the snapshot on both success and failure. |
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
