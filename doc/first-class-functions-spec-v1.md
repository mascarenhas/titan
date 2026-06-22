# First-class functions v1

> **Status: implemented.** This was the original design draft; first-class
> functions have since shipped. Where the implementation diverged from this
> draft, reconcile as follows:
>
> * **Upvalue ordering.** The shipped Titan function closure uses
>   upvalue[0] = the module reference (`_mod`), upvalue[1] = the
>   function-type tag (light userdata), upvalue[2] = the native entry
>   pointer (light userdata) — i.e. the module reference stays at slot 0
>   rather than moving to slot 2 as proposed below.
> * **Call paths.** There are **two**, not three: an exact-type *fast path*
>   (a direct native call) and a *generic path* through the Lua stack (via
>   `luaD_callnoyield`) used for non-exact Titan function values, Lua
>   closures, C functions, and `__call` objects. Titan can now call Lua
>   functions directly through the generic path.
> * **Default return type.** A function with no return annotation now
>   defaults to **zero returns** (`() -> ()`, returning nothing as in Lua),
>   not a single `nil`.
>
> **Nested/anonymous functions and closures have since shipped too.** This
> draft deliberately scoped them *out* (see the Overview below), but a
> follow-on feature added anonymous function expressions that capture
> enclosing locals, plus bound instance-method references `obj:method`. The
> extra native-ABI `_fn` parameter that closures need is a hard `.so` ABI
> break, so `TITAN_VER` was bumped 0.5 → 0.6. See
> [anonymous functions and closures](language/closures.md) for the language
> feature and [the code generator overview](implementation/codegen-overview.md#closures-and-captured-variables)
> for the implementation.
>
> Foreign (C FFI) functions remain the **only** kind that is still not a
> first-class value.

## Overview

This spec covers the addition of first-class functions to Titan
**without support for nested/anonymous functions** (which a later feature
added — see the status note above). First class
function values are either references to Titan top-level functions
or function-like values coming from Lua (native Lua functions, C functions,
anything with a `__call` metamethod). Notice this excludes Titan foreign
(C FFI) functions.

A call to a first-class function value that represents
a Titan function **with an exact match of for the function type** uses the
same fast path as current Titan to Titan function calls, after a
constant-time check.

Non-exact matches to a Titan function (meaning that at some point there will be an
gradual typing coercion) use the Lua stack and `lua_CFunction` (from `lua.h`)
entry point the Titan function has, as if the Titan function was being
called from Lua, although it should be possible to do a faster path than Lua uses,
since no adjustment of number of arguments/return values are needed.

For Lua function-like values the call path uses a regular `lua_call`.

## Type-checking

Gradual typing compatibility predicate should already be in place for function types,
and no changes to the coerceability predicate are needed, either, so for type-checking
what is needed is to remove the restrictions on referring to values of function types,
and to assign to them.

## Value representation

First class function values are always boxed Lua `TValue`s. For Titan top-level
functions and static record functions we extend the current C closures that
are already created for Lua interop with two extra upvalues, yielding this
layout for the upvalues:

```
0: unique tag that marks this as a Titan function with an exact function type (light userdata)
1: function pointer to the Titan entry point of the function (light userdata)
2: module reference (position 0 in the current layout)
```

The unique tag uses a similar system as record type identity, but using the canonical string representation of
the function type as a nominal type. This gets encoded in a `static const void*` with a name derived from
the type string representation, and published in the registry by the
first loaded module that uses that function type.

The actual function for the C closure is still the Lua entry point for the function.

Pushing the module reference to slot 2 will change the existing generated code for the Lua entry
point, but the purpose is to be able to do the access the tag without needing to compute an offset.
