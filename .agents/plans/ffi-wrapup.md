# FFI wrapup

This discharges the "FFI with C, continued" roadmap item, with adopted pointers dropped from the roadmap.

## `foreign` functions (replaces the callback part of the roadmap item)

Introduce a new kind of Titan function, the `foreign` function, that
lets the programmer write effetively an FFI function with Titan
code.

The main use of this is to write functions that can be used as-is
as callbacks to C code, where they can replace existing callback
trampoline shims used in titan_coro.c, titan_uv.c, and titan_httpshim.c.

An example for one of the titan_uv.c callback trampolines (replacing
titan_uvshim_fs_cb):

```
local type uv_fs_cb_closure = foreign (*lua.lua_State, *lobject.Udata, *lobject.CClosure, *lobject.Udata, lua.lua_Integer) -> ()

foreign function uv_fs_cb_trampoline(req: *libuv.uv_fs_t)
  local owner = libuv.uv_req_get_data(req as *libuv.uv_req_t) as *lobject.Udata
  local result = libuv.uv_fs_get_result(req) as lua.lua_Integer
  local callback = ffi.lmacro_clCValue(owner.uv[1].uv)
  local L = libuv.uv_loop_get_data(req.loop) as *lua.lua_State
  local module = ffi.lmacro_uvalue(callback.upvalue[0])
  local top = lua.lua_gettop(L)
  ffi.lua_pushtvalue(L, callback.upvalue[0])
  local entry = ffi.lmacro_pvalue(callback.upvalue[2]) as uv_fs_cb_closure
  entry(L, module, callback, owner, result)
  lua.lua_settop(L, top)
end
```

There is no `foreign local` declaraton, since foreign functions are always
local module functions due to their FFI type.

A foreign function compiles to a local C function  without the `L`, 
`_mod`, and `_fn` parameters that are part of the Titan ABI and would tie it
to the Titan runtime. This makes it usable for C callbacks, but means it has several
restrictions, since it is essentially an FFI function, just written as
Titan code:

1. The type it has to Titan code is an FFI function type, so parameter types
and the return type must all be FFI types
2. It must have at most a single return type, multiple returns and flexible returns
are not allowed, and variadic parameters are also not allowed
3. No catch blocks, no defer statements, no raise statement, as error handling needs
to plug into the Lua state
4. All local variables must have FFI types, casts to/from non-FFI types not allowed (including
casts to/from `value`)
5. Ordinary module functions and variables are not visible, including from imported
Titan modules. Only foreign functions and FFI imports are visible. Together
with `foreign` members being local it means nothing from an imported Titan module is going
to be visible unless it is a direct source import
6. No for/in loops, no match statement (moot point since Titan unions are forbidden anyway)
7. Literal strings are allowed but they have the FFI `const char*` type, so no string concatenation
through `..`.
8. `nil` is allowed, but gets translated to `NULL`

The name of this function in the generated code is the same name as a Titan native entry point
(so includes the module name).

The "only FFI types" restriction means that even `value` is not allowed, the example
above uses the FFI type `TValue`, but in this context it is not a Titan `value`.

Imported FFI modules are visible normally, and their types and functions can be
called.

This is better enforced as a specialized type checker for the bodies of these functions that
enforces all of the above, together with a specialized code generator, mostly so that the
allowable statements (if, assignment, while, numeric for, repeat, return) get translated
properly. The expressions involving FFI types that Titan already allows are also
allowed.

The type syntax is extended with a `foreign <function type>` type constructor that allows
defining an FFI function pointer type within Titan code. This is used in the example above to
express the type of the Titan entry point of a Titan closure.

The `lmacro_` definitions in the example above are convenience additions to the Titan
`titan/ffi.h` header that wrap some useful Lua function-like macros as inline functions
so they are visible to the FFI. **As an alternative for this, do some exploration about
what it would take to support simple function-like C macros in the FFI, so
`lobject.{clCvalue/uvalue/pvalue}` could be used directly. The Titan code generator should
not be doing macro-expansion itself, it should emit C that uses the macro.**

This should be enough to remove all of the remaining C shims that the stdlib is using
(titan_coro.c, titan_uv.c, titan_httpshim.c, plus related header files).

A module with foreign members generates not just the regular `.c` file a Titan module has,
but also a `.h` file with the function prototypes for the foreign functions it has,
plus `#include`s for any FFI imports and direct source imports of modules that have
foreign members.

A foreign function that has either of these body shapes:

```
<local variable declarations>
return <exp>
```

```
<local variable declarations>
if <exp> then
  return <exp>
else
  return <exp>
end
```

```
<local variable declarations>
if <exp> then
  return <exp>
end
return <exp>
```

Should be compiled to a `static inline` function directly in the emitted header. This should
be used for defining foreign "constants" that can still be used as such by the host C compiler.

## Owned structs with FAMs

Right now structs with flexible-array members are not allowed. The FFI should lift this
restriction, and for these structs the `new` pseudo-function to allocate an owned struct
should take an integer parameter with the number of elements to allocate for
the flexible array member.

For `new_array` this should be the second parameter (each element of the array has the same
number of elements for its FAM).

## Stack-allocated FFI aggregates from `.new/.new_array`

When used to initialize a new local variable the `.new` pseudo-function should use
stack allocation if the local variable's type is not a pointer type:

...
-- options is stack-allocated `uv_process_options_t`, not payload in an owned UData*
local options = libuv.uv_process_options_t.new()
```

...
-- options is stack-allocated `uv_process_options_t`, not payload in an owned UData*
local options: libuv.uv_process_options_t = libuv.uv_process_options_t.new()
```

...
-- options is an owned UData*, struct in payload
local options: owned *libuv.uv_process_options_t = libuv.uv_process_options_t.new()
```

...
-- struct in payload of anonymous owned UData*, options is bare native pointer to payload
local options: *libuv.uv_process_options_t = libuv.uv_process_options_t.new()
```

In the first two cases, coercion of `options` to a bare FFI `*libuv.uv_process_options_t`
should just take the address of the stack-allocated variable. Coercion to
`owned *libuv.uv_process_options_t` should allocate a new `UData*` and copy the struct
into its payload.

This extends to `.new_array` and structs with FAMs (in both `.new(<count>)` and `.new_array(<array count>, <FAM count>)`)
**if counts are known at compile time**:

```
-- stack-allocated array of `uv_stdio_container_t`
-- inferred type for stdio is `libuv.uv_stdio_container_t[3]`
local stdio = libuv.uv_stdio_container_t.new_array(3)
```

```
-- array is payload in owned Udata*
-- inferred type for stdio is `owned libuv.uv_stdio_container_t[]`
-- stdio is the owned Udata*
local stdio = libuv.uv_stdio_container_t.new_array(count_from_variable)
```

```
-- compile-time-error
local stdio: libuv.uv_stdio_container_t[3] = libuv.uv_stdio_container_t.new_array(count_from_variable)
```

```
-- array is payload in owned Udata*
-- stdio is bare pointer to payload
local stdio: libuv.uv_stdio_container_t[] = libuv.uv_stdio_container_t.new_array(count_from_variable)
```

```
-- stack-allocated array of `uv_stdio_container_t`
-- stdio is bare pointer to stack array
local stdio: libuv.uv_stdio_container_t[] = libuv.uv_stdio_container_t.new_array(3)
```

```
-- array is payload in owned Udata*
-- stdio is the owned Udata*
local stdio: owned libuv.uv_stdio_container_t[] = libuv.uv_stdio_container_t.new_array(3)
```

This is a semantic change for existing code, so audit uses of `.new()`/`.new_array()` in
the stdlib to fix sites where static allocation would be used for a struct that outlives the
function's frame.

This also removes the need for the `local var: <ffi_type>[<literal>]` syntax for declaring
stack-allocated arrays, these should stop being special-cased so they become a compile-time
error since the implicit ` = nil` initialization would not typecheck.
