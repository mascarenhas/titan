# Titan C FFI follow-up: Lua API calls from Titan

Status: preliminary roadmap note. This is out of scope for the first C FFI
redesign implementation.

## Why this is separate from v1

The README roadmap wants the redesigned C FFI to be strong enough to build a
Titan standard library that wraps Lua's standard library. That is a good target,
but "can call Lua API functions" is not just "can import lua.h".

The current FFI is compile-time header parsing plus direct generated C calls.
It intentionally has no runtime marshalling layer. The current implementation
also targets Lua 5.5 internals directly in generated code, while Lua's public
API exposes an opaque `lua_State *` and stack-index protocol. A safe-enough Lua
API layer needs extra policy around the current Lua state, stack effects,
macros, ownership, errors, and callbacks.

This note should guide a follow-up design after the v1 C type model, ownership,
field access, arrays, and C variadic calls have landed.

## Capabilities needed

- C type coverage for Lua's public API typedefs: `lua_State *`, `lua_Integer`,
  `lua_Unsigned`, `lua_Number`, `lua_KContext`, `size_t`, `const char *`,
  `const void *`, pointer-to-pointer shapes, and arrays/structs for helper
  tables such as `luaL_Reg`.
- Function pointer support for public API callback types: `lua_CFunction`,
  `lua_KFunction`, `lua_Reader`, `lua_Writer`, `lua_Alloc`, warning functions,
  and hooks. This depends on the future Titan-to-C callback roadmap, not v1.
- A way for Titan code to obtain a typed handle to the current `lua_State *L`.
  Generated Titan native functions already receive `L`, but Titan source cannot
  currently name or pass it.
- A macro strategy. Many familiar Lua API operations are macros, including
  `lua_call`, `lua_pcall`, `luaL_checkstring`, `luaL_newlib`, and table/library
  helpers. The current C FFI does not import function-like macros.
- Stack-effect metadata for functions that push, pop, inspect stack indices,
  grow the stack, may call Lua, may allocate, or may raise errors.
- Ownership and lifetime metadata for borrowed strings, `lua_tolstring`
  results, registry references, userdata payloads, external buffers, and
  `lua_newuserdatauv` payloads.
- Error-boundary policy for calls that can longjmp through `lua_error`,
  `luaL_error`, metamethod invocation, or callbacks.

## Likely design shape

Do not expose arbitrary Lua internals as ordinary FFI imports. Prefer a
privileged, allowlisted binding layer for the public Lua API:

```lua
local lua = foreign import "titan/lua_api.h"
local ffi = foreign import "titan/ffi.h"

local L = lua.current_state()
lua.pushinteger(L, n as lua.Integer)
```

The exact syntax is open, but the important split is:

- Public API bindings (`lua_*`, selected `luaL_*`, selected `lualib.h`) are
  visible to Titan through annotated wrappers.
- Internal-header operations (`TValue`, `StkId`, `s2v`, `luaS_*`, `luaH_*`,
  direct `L->top.p` manipulation) remain compiler/runtime-internal unless a
  later unsafe capability explicitly exposes them.

The binding layer should probably be hand-authored at first. Header parsing can
discover declarations, but it cannot infer stack effects, ownership, macro
semantics, or longjmp behavior.

## Stack effects

Lua API calls are not ordinary pure C calls. A later checker should understand
at least conservative metadata such as:

- `pushes = N`
- `pops = N`
- `may_error`
- `may_call_lua`
- `may_gc`
- `requires_stack = N`
- `borrows_stack_indices`
- `returns_borrowed_string`
- `returns_registry_ref`

This metadata lets generated code reserve stack space, avoid dangling raw stack
pointers after `lua_checkstack`, and make long-lived borrows explicit.

The existing Lua-entry wrappers already save stack offsets and restore them
after calls that may relocate the stack. A user-facing Lua API layer should use
the same discipline rather than exposing raw stack slots.

## Macro strategy

Options, from most conservative to most ambitious:

1. Provide explicit wrapper functions in a Titan-owned C header/source pair for
   common macros.
2. Teach the FFI about selected macro expansions and emit equivalent C snippets.
3. Import only real functions initially, using the underlying `lua_*k` forms
   where needed.

The first follow-up should start with wrapper functions. General C macro import
is too broad for the same milestone.

## Callback dependency

Exposing Titan functions as `lua_CFunction` or `lua_KFunction` depends on the
parked callback design. A generated wrapper must recover or root the Titan
callable, preserve module/capture state, follow Lua entrypoint conventions,
return the number of Lua stack results, and handle errors without crossing an
unsafe C boundary unexpectedly.

This is not part of the first C FFI implementation.

## Suggested follow-up milestones

1. Add the core v1 C FFI work first: official C type tags, local C type
   annotations, owned inline userdata, field access, arrays, and C varargs.
2. Add `titan/ffi.h` primitive names and enough C typedef support to represent
   the public Lua API's scalar and pointer types.
3. Prototype an allowlisted `titan/lua_api.h` with wrapper functions for safe
   stack operations: push/read primitives, stack top management, table get/set,
   registry refs, protected calls, and userdata allocation.
4. Add stack-effect and ownership metadata to those wrappers, hand-authored in
   the compiler until a more general annotation format exists.
5. Only after callback semantics are settled, add `lua_CFunction` and related
   callback support for registering Titan functions with Lua.

## Out of scope for the first follow-up

- Arbitrary `TValue *` manipulation from Titan source.
- General import of function-like C macros.
- A universal model for every C library's stack-like or callback-heavy API.
- Yieldable continuations through `lua_KFunction`.
- Safe lifetime management for arbitrary foreign pointers returned by user
  libraries.

## Source references

- `README.md` names a Titan standard library built through a stronger C FFI as
  the next roadmap item.
- `doc/language/ffi.md` documents the current direct-call, compile-time FFI and
  its limits around function-like macros, function pointers, and pointer
  leakage.
- `doc/implementation/ffi-internals.md` documents the current foreign-import
  pipeline and direct C call codegen.
- `doc/implementation/lua-interop-internals.md` documents Lua entry wrappers,
  stack-offset restoration, `checkandget`, and error-boundary behavior.
- `doc/lua-5.3-to-5.5-internals.md` records the Lua 5.5 stack, userdata, and
  buffer constraints that make raw internal access fragile.
