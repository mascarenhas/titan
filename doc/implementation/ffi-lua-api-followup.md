# Lua C API FFI Follow-Up

This note is deliberately out of scope for the C FFI v1 implementation. The v1
surface is strong enough for ordinary C headers, owned buffers, fields, arrays,
and explicit C varargs, but calling the Lua C API safely needs a separate design
pass.

## Why It Is Separate

Titan-generated C already includes Lua 5.5 internal headers and manipulates
`TValue`, `Udata`, stack slots, barriers, and `lua_State` internals directly.
The public Lua C API is stack-oriented and longjmp-based. Mixing the two through
ordinary FFI calls means the compiler must know which calls can move `L->top.p`,
allocate, longjmp, invalidate stack addresses, or require a protected-call
boundary.

The main open questions are:

* how to model `lua_State *` in Titan source without exporting it through module
  interfaces;
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

## Likely Direction

A plain header import of `lua.h` is not enough. A safer next iteration would
probably add a small compiler-provided binding header plus metadata for selected
Lua API functions. That metadata can describe stack effects, allocation/error
behavior, and any value anchoring rules the code generator must enforce.

The first useful milestone is a tiny allowlisted subset: stack size checks,
basic pushes, basic type predicates, and string/userdata reads that do not store
borrowed pointers past the call. More complex APIs, callbacks, and arbitrary
`lua_CFunction` interop should wait until the function-pointer/callback design
exists.
