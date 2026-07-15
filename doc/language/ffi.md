# The C FFI

Titan can call C functions, read C constants and variables, and work with a
small but useful set of C types directly from a header:

```lua
local stdio = foreign import "stdio.h"

function hello(name: string): integer
    return stdio.printf("hello, %s\n", name)
end
```

The header is parsed at **compile time**. A foreign call compiles to a plain C
call in the generated translation unit; there is no run-time reflection layer
and no hand-written glue. The cost is that the FFI is exactly as unsafe as the C
it binds: Titan cannot stop a C function from writing past a buffer, storing a
pointer into a Titan string, freeing memory it does not own, or crashing the
process.

Implementation details are in [FFI internals](../implementation/ffi-internals.md).

## Importing a Header

`foreign import` is a top-level declaration. It binds a local module namespace
whose members are the declarations found in the C header:

```lua
local c = foreign import "myheader.h"
```

The namespace is a compile-time namespace, not a first-class value. You can
call `c.func(...)`, read `c.variable`, and name imported C types such as
`c.size_t`, but you cannot store or return `c` itself.

### Header Resolution

Header lookup mirrors C include intent:

* An absolute path is read directly and emitted as `#include "/path/header.h"`.
* A relative path that exists beside the Titan source file is emitted as
  `#include "header.h"`, so the C compiler applies the normal quoted-include
  search from that source directory.
* The compiler-provided header `titan/ffi.h` is found under the active Titan
  SDK's `include` directory (or `titan-runtime` in checkout developer mode)
  and emitted as `#include <titan/ffi.h>`.
* Other relative names are treated as system headers and emitted as
  `#include <...>`.

`titan/ffi.h` exposes selected portable C99 primitive aliases for Titan FFI
code: `titan_ffi_void`, `titan_ffi_bool`, `titan_ffi_char`,
`titan_ffi_signed_char`, `titan_ffi_unsigned_char`, `titan_ffi_short`,
`titan_ffi_unsigned_short`, `titan_ffi_int`, `titan_ffi_unsigned_int`,
`titan_ffi_long`, `titan_ffi_unsigned_long`, `titan_ffi_long_long`,
`titan_ffi_unsigned_long_long`, `titan_ffi_float`, `titan_ffi_double`, and the
opaque Lua state type `lua_State`. It also exposes Lua's internal `TValue`
type and `Udata` object type for private runtime helpers; Titan `value` and C
`TValue` are distinct types with explicit FFI coercions between them. A local,
temporary, or parameter whose C type is `TValue` or `Udata *` is treated as
GC-bearing, like Titan `value`.

## Imported Members

Foreign modules contain three categories of members:

* C functions become callable members. This includes ordinary prototypes and
  header-defined `static` functions. C variadic functions such as
  `printf`/`snprintf` accept extra arguments after their fixed parameters.
* C variables and object-like `#define` constants become C values. Assigning to
  a foreign variable name itself is rejected; assigning through an indexed C
  array or through a field is emitted as C. Titan does not model `const` or
  other C writeability rules for subobjects in v1, so the C compiler may still
  reject those assignments. Top-level enum constants become C integer members;
  simple numeric enum values are retained in Titan's C type list.
* C typedef names become the source-nameable type namespace. They may be used
  in local annotations, casts, and the `.new()` / `.new_array(count)` allocation
  pseudo-functions. Tag-only `struct S` / `union U` declarations are understood
  for imported values, pointers, and fields, but cannot be written as `c.S`
  unless the header also provides a typedef name.

The value namespace and the type namespace are separate: an `extern int x;`
member is read as `c.x`, but `c.x` is not a type annotation.

## C Types In Titan

Imported C types stay C types. They are not aliases for Titan `integer` or
`float`, though many casts and calls can convert between the two.

Supported C type families:

| C type | Titan FFI type |
| --- | --- |
| `void` | `void` for C calls and allocation checks |
| `_Bool`, `char`, signed/unsigned integer types | distinct C integer types |
| `float`, `double`, `long double` | distinct C float types |
| `T *` | nullable C pointer type |
| `R (*)(P...)` | nullable C function pointer type, usually through a typedef |
| `T[N]` | C array type with static length |
| `struct S`, `union U` | C aggregate type with fields when the header exposes them; source annotations need a typedef name in v1 |
| `typedef T name` | C typedef that resolves through its target |
| exact by-value `TValue` | distinct C `TValue`, with FFI coercions to/from Titan `value` |

Imported C types can appear in **local** type annotations:

```lua
local ffi = foreign import "titan/ffi.h"

local function add1(x: ffi.titan_ffi_int): ffi.titan_ffi_int
    local y: integer = (x as integer) + 1
    return y as ffi.titan_ffi_int
end
```

They cannot be exported from a Titan module. A public function parameter or
return type, a public variable, or a public record member that mentions a C FFI
type is rejected. This version deliberately does not serialize C types into
compiled Titan module interfaces, because another Titan module would also need
the right C header included in its generated C. A local record field may mention
a C type because it remains private to the defining module.

Pointer types can also be written directly from an imported C type:

```lua
local ffi = foreign import "titan/ffi.h"

local function fill(out: *ffi.titan_ffi_int)
    out[0] = 42
end

local function read(p: const *ffi.titan_ffi_int): integer
    return p[0] as integer
end
```

`*T` means `T *`; `const *T` means `const T *`. The pointee must be an imported
C type, so `*integer` and pointers to non-FFI Titan types are compile-time
errors.

Every imported C type namespace exposes `sizeof` and `alignof` pseudo-members.
They compile to C `sizeof(T)` and `_Alignof(T)` and return a Titan `integer`:

```lua
local ffi = foreign import "titan/ffi.h"

function int_layout(): integer
    return ffi.titan_ffi_int.sizeof + ffi.titan_ffi_int.alignof
end
```

## The Built-In Lua State

Every Titan function, method, and anonymous function has an implicit read-only
local named `L`. It is the native `lua_State *L` that the generated C function
received, typed as a C pointer to `lua_State`:

```lua
local api = foreign import "lua_helpers.h"
-- lua_helpers.h:
-- #include <titan/ffi.h>
-- int current_top(lua_State *L);

function current_top(): integer
    return api.current_top(L) as integer
end
```

`L` is most useful when passing the current Lua state to a C function imported
through the FFI. It cannot be assigned to, and parameters or locals named `L`
are rejected so the built-in remains unambiguous. The pointer is not a Titan
value you should store for later use; pass it only to C APIs that use it during
the call.

## Casts And Coercions

Regular `as <type>` casts handle FFI conversions; there is no special
`as_int` form.

Allowed conversions include:

* C integer values to Titan `integer`, and Titan `integer` to C integer types;
* C float values to Titan `float`, and Titan `integer` or `float` to C float
  types;
* C pointers, including C function pointers, to `boolean`, with `nil` as the
  null pointer;
* C arrays and counted owned C arrays to compatible C pointers;
* any non-function C pointer to `void *`;
* non-pointer by-value C object expressions to compatible `const *T` pointers,
  materialized as the address of the C expression for the duration of the
  foreign call;
* mutable local or formal C values to compatible mutable `*T` or `void *`
  pointer parameters, for C out-parameters;
* Titan `string` to `char *` or `void *` for calls;
* C `char *` or `void *` to Titan `string` with an explicit `as string`;
* a foreign C function name to a compatible C function pointer type;
* C integers, C floats, non-function C pointers, and owned C userdata to/from
  `value`, with the same run-time checks used at the Lua boundary.
* Titan `value` to C `TValue` by value, and C `TValue` back to Titan `value`,
  for private runtime helper APIs that include `<titan/ffi.h>`.
* Lua-internal `Udata *` to the same full-userdata `value` and back. NULL maps
  to nil; unlike an ordinary C pointer, a non-NULL `Udata *` does not become
  lightuserdata, and converting back rejects lightuserdata.

By-value C structs and unions cannot cross through `value` in v1. C function
pointers are callable and nullable, but they are not C object pointers: they
cannot cross through `value` or through `void *`.

Mutable address coercions are intentionally limited to local variables and
formal parameters that have C types, because C may write through the pointer:

```lua
local ffi = foreign import "titan/ffi.h"
local c = foreign import "outparam.h" -- void write_int(int *p);

function read_written(): integer
    local x: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
    c.write_int(x)
    return x as integer
end
```

If the mutable C value is a GC-bearing `TValue`, Titan refreshes its stack
anchor immediately after the foreign call, before any later call can run
the collector.

When a C scalar participates in Titan arithmetic, cast it to the Titan type you
want:

```lua
local string_h = foreign import "string.h"

function len_plus_one(s: string): integer
    return (string_h.strlen(s) as integer) + 1
end
```

## Calling C Functions

A foreign call uses the imported C function name:

```lua
local stdio = foreign import "stdio.h"

function write(buf: string): integer
    return stdio.printf("%s", buf)
end
```

Fixed parameters are checked against the C prototype. For C variadic functions,
the fixed prefix is checked and explicit extra arguments are converted using
their own static types. This is enough to call functions such as `printf` and
`snprintf`, but Titan does not validate format strings. Titan variadic `...`
cannot be forwarded into a C variadic call in v1.

Foreign functions are not Titan first-class function values. `stdio.printf` can
be called by name, but it cannot be stored, passed, or returned as a Titan
function. A foreign function name can, however, be converted to a compatible C
function pointer type. Generic `for ... in` iterator and close slots are also
such a context when the C signature satisfies the generic-for rules:

```lua
local c = foreign import "callbacks.h"
-- typedef int (*callback)(int);
-- extern int add1(int);
-- extern int apply(callback cb, int x);

function via_callback(): integer
    local cb: c.callback = c.add1
    return c.apply(cb, 41) as integer
end
```

C function pointer values are callable with the same call syntax. The call is a
C call through the pointer, not a Titan function-value call, and raises a
run-time error if the pointer is `NULL`:

```lua
local c = foreign import "callbacks.h"

function call_it(cb: c.callback): integer
    return cb(41) as integer
end
```

## Strings And Pointers

Passing a Titan `string` to C as `char *` or `void *` passes a pointer to the
string's internal immutable byte buffer. No copy is made. The pointer is valid
only while the Titan string is alive and anchored for the call; a C function
must not store it, mutate it, free it, or reallocate it.

Casting a C `char *` or `void *` to `string` copies bytes up to the first
`\0` into a fresh Titan string:

```lua
local stdlib = foreign import "stdlib.h"

function path(): string
    return stdlib.getenv("PATH") as string
end
```

The cast raises a run-time error if the C pointer is `NULL`. A `void *` cast to
`string` must point at a valid NUL-terminated C string; this is not a
binary-buffer conversion.

Pointers are nullable and can be tested directly:

```lua
local stdio = foreign import "stdio.h"

function exists(name: string): boolean
    local f = stdio.fopen(name, "r")
    if f then
        stdio.fclose(f)
        return true
    end
    return false
end
```

Raw C pointers are not owned by Titan. Memory obtained from C must be released
through the matching C API.

## C Arrays And Length

C array indexing uses the same syntax as Titan array indexing but is **0-based**:

```lua
local c = foreign import "data.h"  -- extern int values[4];

function third(): integer
    return c.values[2] as integer
end
```

The base expression may be:

* a C pointer, indexed with no bounds check;
* a C static array, bounds-checked against its declared length;
* a counted owned C array, bounds-checked against its allocation count.

`#exp` is valid for C static arrays and counted owned C arrays. It returns the
static length for a C array and the allocation count for an owned array:

```lua
local ffi = foreign import "titan/ffi.h"

function count(): integer
    local xs = ffi.titan_ffi_int.new_array(8)
    return #xs
end
```

Unsized C arrays, including flexible array members, cannot be indexed or
measured in this version.

## Structs, Unions, And Fields

When the header exposes a complete struct or union definition, Titan imports
its named fields:

```lua
local c = foreign import "point.h"

function sum(): integer
    local p = c.ffi_point.new()
    p.x = 10
    p.y = 20
    return (p.x as integer) + (p.y as integer)
end
```

Field access works on C struct/union values, pointers to structs/unions, and
owned C objects. For pointer and owned bases, `p.x` uses C's `->` semantics.

Bitfields are parsed and typed, but they remain C bitfields: assignment follows
the C compiler's rules. Anonymous fields are not exposed as Titan members.

## Owned C Objects

Any supported C object type has two pseudo-functions on its type namespace:

```lua
local ffi = foreign import "titan/ffi.h"

function make(): integer
    local one = ffi.titan_ffi_int.new()
    local many = ffi.titan_ffi_int.new_array(16)
    return #many
end
```

`T.new()` allocates one zeroed C object. `T.new_array(count)` allocates `count`
zeroed adjacent objects and records the count through the userdata payload size.
The returned value is an owned C userdata whose lifetime belongs to Titan's Lua
GC. No finalizer is installed.

These pseudo-constructor calls are also valid module-variable initializers when
their arguments are constant:

```lua
local ffi = foreign import "titan/ffi.h"

local counter = ffi.titan_ffi_int.new()
local samples = ffi.titan_ffi_float.new_array(16)
```

Each module instance performs the allocation once and keeps the owned userdata
in its GC-traced module state. A `new_array` count that reads another module
variable is not a constant initializer and is rejected.

Passing an owned C object or owned C array to a C function expecting `T *`
passes a pointer to the userdata payload:

```lua
local ffi = foreign import "titan/ffi.h"
local stdio = foreign import "stdio.h"

function formatted_len(s: string): integer
    local buf = ffi.titan_ffi_char.new_array(32)
    return stdio.snprintf(buf, 32, "%s", s)
end
```

Allocation is intentionally limited in v1. Titan rejects owned allocation of
`void`, incomplete struct/union types, C array typedefs, and structs with a
flexible array member. Flexible array members need a dedicated design for
passing the member length, storing it, and bounds-checking the member.

## Linking And Platform Requirements

`foreign import` gives Titan the declarations. You still link against the C
library that implements them with `titanc -l`:

```sh
titanc examples.sdl_demo -lSDL2
```

The compile-time FFI depends on a POSIX-like C toolchain. Titan asks the
configured `CC` (default `cc`) for predefined macros and include paths in C99
mode, using the same parsed `TITAN_EXTRA_CPPFLAGS` that precede the defaults
when generated C is compiled. This is the supported way to provide `-I` and
`-D` options, including quoted paths containing spaces. Titan then parses the
preprocessed header with its own C99 grammar. Headers using unsupported
compiler extensions may fail with a compile-time parse error.

### Direct libuv extensions

Bundled Titan gives libuv a single complete native owner: the canonical
`titan/uv.so`. Its SDK installs `uv.h` and the `uv/` headers, but not the
private static archive used to build that provider. A Titan extension DSO that
calls functions declared by `uv.h` must import `titan.uv` (normally through its
short spelling) in addition to importing the header:

```titan
local runtime = import "uv"
local uv = foreign import "uv.h"
```

Build that extension without `-luv` and without a `libuv.a` linker input. Its
`uv_*` references remain unresolved in the DSO. The bundled archive used to
build `titan/uv.so` is private and is not installed as part of the Titan SDK.
Titan uses the same `RTLD_LAZY | RTLD_GLOBAL` runtime loader for this extension
as for every compiled dependency. Lazy binding lets the extension map with
unresolved libuv function calls. Its generated initializer then loads the
explicit `uv` import globally before Titan code can make one of those calls.
`RTLD_NOW` would fail while mapping the extension, before the initializer could
load the provider, while a provider loaded `RTLD_LOCAL` would not be visible to
the extension's lazy bindings. No special interface marker, compiler
classification, or provider-specific Titan loader is involved. The compiler's
separate interface-inspection loader remains
`RTLD_LAZY | RTLD_LOCAL`.

This bundled Titan path supports ordinary function calls through lazy binding.
It does not support native constructors, imported libuv data, or taken function
addresses that create eager relocations: those are needed while the extension
is being mapped, before its generated initializer can load `uv`. Use the system
mode below or arrange for the embedding process to preload the provider when
one of those forms is required.

Lua code that requires the extension directly must establish the provider
first:

```lua
local uv = require "titan.uv"
local extension = require "my.libuv_extension"
```

The installed `titan/uv.lua` loader resolves canonical `titan/uv.so` through
`package.cpath`, calls `package.loadlib(path, "*")` to make its symbols global,
and then invokes `luaopen_titan_uv` from the same handle. All other Lua C
modules retain ordinary local loading. This uses stock Lua's public package
API, not a `loadlib.c` patch or a self-loading/self-promoting provider, and
works on both Linux and macOS. A stock Lua 5.5 host can use the bundled
direct-extension contract when its `LUA_PATH_5_5` finds the loader and its
`LUA_CPATH_5_5` finds the canonical DSO (see
[Running with a stock Lua](modules.md#running-with-a-stock-lua)).
Because Lua performs this explicit global load before mapping the extension,
this route also supports its eager relocations and native constructors. The
global symbols can resolve a Lua-only extension even if it omitted the Titan
`uv` import, but the import remains mandatory for a Titan module that must also
work through Titan's runtime loader.

With `LIBUV_MODE=system`, an extension may instead consume the same shared
library selected for Titan by passing the complete pkg-config output through
the normal flag channels:

```sh
TITAN_EXTRA_CPPFLAGS="$(pkg-config --cflags libuv)" \
TITAN_EXTRA_LDFLAGS="$(pkg-config --libs libuv)" \
titanc my.libuv_extension
```

Do not statically embed Titan's bundled archive in an extension. Even an
identical archive version would create another libuv instance with separate
process-global state.

## Current Limitations

* Foreign functions are not Titan first-class values. They can only be called by
  name or converted to compatible C function pointer types.
* C types are local to the importing Titan module and cannot appear in exported
  Titan interfaces.
* Function-like macros are not imported.
* Owned allocation does not support `void`, incomplete aggregate types, C array
  typedefs, or structs with flexible array members.
* C adopted pointers/lifetimes are parked for a later design; v1 has borrowed C
  pointers and Titan-owned userdata only.
* The C namespace is flat across all foreign imports in one generated C file,
  so compatible duplicate names denote the same C symbol. Titan reports
  conflicting ordinary declarations from distinct foreign imports before code
  generation, but it does not attempt to namespace or rename C declarations.
