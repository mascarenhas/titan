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

Named tag-only aggregates, automatic C storage, contextual object-pointer
casts, and C-mode operators are covered in
[C FFI declarations and expressions](c-ffi-expressions.md). Implementation
details are in [FFI internals](../implementation/ffi-internals.md).

## Importing a Header

`foreign import` is a top-level declaration. It binds a local module namespace
whose members are the declarations found in the C header:

```lua
local c = foreign import "myheader.h"
```

The namespace is a compile-time namespace, not a first-class value. You can
call `c.func(...)`, read `c.variable`, and name imported C types such as
`c.size_t`, but you cannot store or return `c` itself.

Each import is written into generated C in source order. After at least one
foreign import has been parsed successfully, Titan asks the configured C
compiler to validate the complete generated header preamble once before
checking the rest of the module: the fixed standard, Lua, and Titan headers
followed by the ordered foreign imports. This includes a module with only one
foreign import, so the compiler can reject an invalid same-header
redeclaration that the isolated declaration extractor did not retain as two
entries. The check observes real include guards, `#pragma once`, macro state,
ordinary-identifier redeclarations, and tag redefinitions.

Before Titan treats compatible extracted repeats as declarations of one C
ordinary identifier, the compiler also checks the pair of extracted declaration
types in that final foreign-header context. This proves that the pair can form
compatible declarations there, not that both original declarations survived
preprocessing. An accepted incomplete/known array pair forms the known-bound
composite, and array or function parameters undergo the usual C parameter
adjustment.

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
* C variables and supported object-like `#define` constants become C values.
  Recognized forms include integer-constant expressions, typed dereferenced
  accessors such as the common `errno` expansion, and fully expanded outer
  casts to supported C integer, floating, object-pointer, or function-pointer
  types; generated C emits the public macro spelling. Assigning to a foreign
  variable name itself is rejected; assigning through an indexed C array or
  through a field is emitted as C. A pure dotted-identifier replacement macro
  may also provide a lazily resolved public field spelling. Field lookup uses
  the final macro environment from the module's ordered, hoisted headers,
  including ordinary redefinitions, dependency rescans, and `#undef`. Like the
  C preprocessor, a live macro takes precedence over a physical field with the
  same name; an active unsupported object macro is terminal rather than
  falling back. Titan does not model `const` or other C writeability rules for
  subobjects in v1, so the C compiler may still reject those assignments.
  Top-level enum constants become C integer members; simple numeric enum values
  are retained in Titan's C type list. See
  [C constants and macro-projected fields](c-ffi-expressions.md#c-constants-and-macro-projected-fields).
* C typedef names become the source-nameable type namespace. Named file-scope
  tag-only `struct S` / `union U` declarations also publish `c.S` using their
  exact tag spelling; a real same-name typedef takes precedence. These names
  may be used in local annotations, casts, and the `.new()` /
  `.new_array(count)` allocation pseudo-functions. See
  [named C tags](c-ffi-expressions.md#named-struct-and-union-tags).

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
| `struct S`, `union U` | C aggregate type with fields when the header exposes them; named file-scope tags are source-nameable through the foreign module |
| `typedef T name` | C typedef that resolves through its target |
| exact by-value `TValue` | distinct C `TValue`, with FFI coercions to/from Titan `value` |
| `owned *c.T` | one GC-owned C `T` object |
| `owned c.T[]` | a dynamically counted GC-owned array of C `T` |

Imported C types can appear in **local** type annotations:

```lua
local ffi = foreign import "titan/ffi.h"

local function add1(x: ffi.titan_ffi_int): ffi.titan_ffi_int
    local y: integer = (x as integer) + 1
    return y as ffi.titan_ffi_int
end
```

They cannot be exported from a Titan module. A public function parameter or
return type, a public variable, or a public record field/union payload that
mentions a C FFI
type is rejected. This version deliberately does not serialize C types into
compiled Titan module interfaces, because another Titan module would also need
the right C header included in its generated C. A local record field or union
payload may mention only a C type with a real `TValue` representation: a
boxable scalar/object pointer, exact `TValue`/`Udata *`, or owned form. Direct
C aggregates, arrays, functions, and function pointers remain ineligible even
when private. Source-written
owned types have the same boundary: they may be used in local aliases,
variables, eligible local record fields/union payloads, local callable
parameters and results, options,
Arrays, and Maps, but any public type containing one is rejected.

An option stores its present value in a Lua `TValue`. A direct C type may
therefore be used as an option base only when it has that boxed
representation: C integers, C floats, non-function object pointers, exact
`TValue`, and owned C storage are supported. By-value C aggregates and arrays,
direct C functions, and C function pointers are not valid option bases.
This is a storage-shape rule, not a promise that every value of a boxable C
scalar fits Titan's configured carrier. Storing a particular C integer or
floating value in an Option, Array, Map, record field, union payload, or
`value` still performs the checked `lua_Integer`/`lua_Number` conversion
described below.
This restriction does not make an ordinary Titan container foreign: an Array,
Map, or local callable containing owned C values remains a boxed Titan value
and may itself cross through `value`.

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

An imported C type namespace exposes `sizeof` and `alignof` pseudo-members when
no ordinary C value has the same module member name. They compile to C
`sizeof(T)` and `_Alignof(T)` and return a Titan `integer`. The intermediate
result retains the target profile's exact `size_t` type; conversion to
`lua_Integer` is range-checked, so an unusually wider `size_t` raises instead
of narrowing:

```lua
local ffi = foreign import "titan/ffi.h"

function int_layout(): integer
    return ffi.titan_ffi_int.sizeof + ffi.titan_ffi_int.alignof
end
```

When a legal ordinary identifier collides with the type spelling, as with
`struct stat` and `stat()`, expression lookup keeps the ordinary value usable
and these type pseudo-members are unavailable. See
[C FFI declarations and expressions](c-ffi-expressions.md#named-struct-and-union-tags).

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
`as_int` form. C conversions are named directional coercions or explicit
written casts, not gradual consistency. They never lift automatically through
an Array, Map, Function, or nominal member. Option has only its explicitly
enumerated nil-preserving plans.

Allowed conversions include:

* C integer values to Titan `integer`, and Titan `integer` to C integer types;
* C float values to Titan `float`, and Titan `integer` or `float` to C float
  types;
* C pointers, including C function pointers, to `boolean`, with `nil` as the
  null pointer;
* C arrays and counted owned C arrays to compatible C pointers;
* any non-function C pointer to `void *`;
* a C function pointer to C `void *` with a written cast;
* a Titan Array, Map, record, union, Interface, or function value to C
  `void *` with a written identity cast;
* non-pointer by-value C object expressions to compatible `const *T` pointers,
  materialized as the address of the C expression for the duration of the
  foreign call;
* mutable local or formal C values to compatible mutable `*T` or `void *`
  pointer parameters, for C out-parameters;
* Titan `string` to `char *` or `void *` for calls;
* C `char *` or `void *` to Titan `string` with an explicit `as string`;
* a counted owned array of C `char`, `signed char`, or `unsigned char` to
  Titan `string`, copying its exact allocated byte length;
* a foreign C function name to a compatible C function pointer type;
* C integers, C floats, non-function C pointers, and owned C userdata to
  `value`; an ordinary pointer becomes lightuserdata, while an owner remains
  full userdata.
* `value` to a guardable C integer, C float, or owned C userdata, using either
  the strict implicit guard or the broad written/Lua dynamic rule selected by
  the [normative boundary matrix](types.md#normative-boundary-matrix).
* `value` to a raw C pointer only through an explicitly written, unsafe
  `as`/`is` assertion; implicit gradual and dynamic boundary paths do not
  establish raw pointee types.
* Titan `value` to C `TValue` by value, and C `TValue` back to Titan `value`,
  for private runtime helper APIs that include `<titan/ffi.h>`.
* Lua-internal `Udata *` to the same full-userdata `value` and back. NULL maps
  to nil; unlike an ordinary C pointer, a non-NULL `Udata *` does not become
  lightuserdata, and converting back rejects lightuserdata.

Mutable address-taking remains local/formal-only even with written `as` or
`is` syntax. A call, cast, or other by-value C temporary is not addressable
storage and is rejected instead of receiving a hidden mutable temporary.

### Checked C scalar boundaries

Foreign variables, call results, fields, indexes, macro values, and C-mode
operator results retain their exact C type and raw C value. Titan does not
prematurely narrow them to `lua_Integer` or `lua_Number`. A checked conversion
is performed only when a typed context requests another numeric type or the
value must enter a `TValue` carrier.

The selected C target profile is authoritative for integer widths and ranges,
floating radix/precision/range, the configured `lua_Integer` and `lua_Number`
carriers, and the target's `size_t` and `ptrdiff_t` spellings. Titan currently
requires a two's-complement signed-integer profile and rejects a target
description with a different signed range:

* a strict boxed projection to a C integer accepts only an integer tag whose
  value fits the target interval; `_Bool` accepts only 0 and 1;
* a dynamic projection to a C integer additionally accepts an exactly
  integral float that first fits `lua_Integer`, then applies the target-range
  check;
* a strict boxed projection to a C float accepts only a float tag and checks
  the target range; the dynamic form accepts either numeric tag before the
  same range check;
* same-or-wider floating conversions preserve finite values, NaNs, and
  infinities. Floating narrowing rejects non-finite or out-of-range values,
  but ordinary rounding and underflow remain allowed;
* floating-to-integer conversion rejects non-finite values and values whose
  truncation-toward-zero result lies outside the target interval, then
  performs that truncating conversion;
* moving a C scalar into Titan `integer`, `float`, `value`, or any other
  boxed slot checks that the exact value fits the corresponding Lua carrier
  before storing it.

Written C-integer-to-C-integer casts retain ordinary C conversion semantics.
The integer promotions and usual arithmetic conversions selected inside a C
expression likewise retain C's integer semantics; an integer-to-floating
operator conversion is still checked when the target profile cannot prove its
range. Every partial written numeric cast has a matching `is` test that runs
the identical acceptance predicate without converting or raising. The same
predicate is reused recursively through Option conversions.

By-value C structs and unions cannot cross through `value` in v1. C function
pointers are callable and nullable, but they are not C object pointers: they
cannot cross through `value`. A written `as` cast may erase a C function
pointer to `void *`; Titan uses its toolchain portability cast rather than
pretending that this is an ordinary C object-pointer coercion. The reverse
`void *`-to-function-pointer cast is not part of this rule.

The explicit GC-identity cast exposes the native object address:

* Arrays and Maps expose their backing `Table *`;
* records expose their full-userdata `Udata *`;
* unions expose their full-userdata `Udata *`;
* Interfaces expose their wrapper full-userdata `Udata *`;
* a function exposes the GC object carried by its boxed function value.

The function case has a dynamic precondition because function-typed values
defer callability checks until call time. With
`local ffi = foreign import "titan/ffi.h"`,
`f is ffi.titan_ffi_void_ptr` is false when the boxed value is not
collectable, and `f as ffi.titan_ffi_void_ptr` raises in that case. The operand
is evaluated exactly once.

This identity rule is explicit only: it does not make any of these Titan types
implicitly assignable to C `void *`, and it does not unwrap an option.
Arbitrary `value` also gains no GC-identity conversion. A written
`value as *c.T` may accept only the ordinary lightuserdata/nil representation,
but that operation is an unsafe programmer assertion: every lightuserdata
looks alike and Titan cannot prove that the address points to `c.T`. The
corresponding `is` can test only this outer representation, not the pointee.
Implicit `value -> *c.T`, typed Array/Map reads of raw pointers, gradual
container/function views whose eventual leaf is a raw pointer, and raw-pointer
results from non-Titan Lua callables are rejected. Titan strings retain their
established pointer conversion to
the first string byte, and owned C objects retain their payload-pointer
conversion. Neither exposes the enclosing GC object's identity.

Direct statically typed pointer/address/qualifier conversions remain
available. The restriction is specifically on treating a boxed
lightuserdata's category as evidence of a precise pointee type. A raw pointer
is boxable in a `TValue`, but it is not **guardable/reifiable** without a
future tagged-pointer representation.

Every pointer produced by these conversions is borrowed. Titan keeps the
source GC object rooted while the cast is evaluated and while later arguments
for the same call are prepared, but storing or returning the C pointer does
not extend the object's lifetime. Keep the original Titan value reachable for
as long as C retains the pointer. The Array, Map, record, union, Interface, and
function addresses are Lua/Titan runtime representations, not public payload
layouts; code must not dereference, mutate, free, or reallocate them unless it
is deliberately using the matching internal runtime contract.

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

When a C scalar participates in arithmetic, cast it to the Titan type you want
when you require Titan semantics:

```lua
local string_h = foreign import "string.h"

function len_plus_one(s: string): integer
    return (string_h.strlen(s) as integer) + 1
end
```

Supported operators can instead remain in
[C operator mode](c-ffi-expressions.md#c-operator-mode), where the configured
target's C promotions, result type, and behavior apply.

## Calling C Functions

A foreign call uses the imported C function name:

```lua
local stdio = foreign import "stdio.h"

function write(buf: string): integer
    return stdio.printf("%s", buf)
end
```

A direct fixed-arity foreign function can use
[named-call syntax](named-arguments.md) when its effective C prototype provides
one complete, unambiguous list of unique parameter names:

```lua
local api = foreign import "api.h"
-- int clamp_int(int value, int low, int high);

function clamp(n: integer): integer
    return api.clamp_int {
        high = 100,
        value = n,
        low = 0,
    } as integer
end
```

The names are the exact spellings in the active header, not Titan aliases.
They may include a Titan keyword because labels are contextual; for example a
C parameter named `repeat` is written `repeat = interval` inside the named
list. A `(void)` prototype publishes a known empty list and accepts `f{}`.
Old-style `f()`, unnamed or partially named parameter lists, duplicate names,
and conflicting complete names across compatible redeclarations do not publish
named-call metadata. Named syntax then gets a specific unavailable-prototype
diagnostic, while the positional call remains available.

C member and qualified-type positions use the same contextual raw-identifier
principle. A C field, symbol, or tag named `when`, `type`, `repeat`,
`interface`, or another current or future Titan keyword may be written after
the foreign namespace or a C receiver. Reserving such a spelling in Titan does
not remove it from contextual C lookup.

Parenthesized direct C calls retain strict C arity. A trailing Titan call with
several statically visible results may be truncated to fill exactly the
remaining C formals, but explicitly written surplus arguments remain an
arity error. A run-time-open flexible result sequence cannot cross a C call
boundary. In a named call, every
omitted fixed parameter is treated as `nil` and accepted only if its
Titan-visible type accepts or can coerce nil. An omitted pointer can therefore
become `NULL`, but a required C integer cannot be omitted.

Fixed parameters are checked against the C prototype. For C variadic functions,
the fixed prefix is checked and explicit extra arguments are converted using
their own static types. This is enough to call functions such as `printf` and
`snprintf`, but Titan does not validate format strings. Titan variadic `...`
cannot be forwarded into a C variadic call in v1. Named syntax is rejected for
every C variadic function, even when all fixed-prefix arguments are present.

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

Titan does not adapt a Titan function or closure to a C callback ABI. The
source of a C function-pointer value must itself be a compatible C function,
C function pointer, or null value.

C function pointer values are callable with the same call syntax. The call is a
C call through the pointer, not a Titan function-value call, and raises a
run-time error if the pointer is `NULL`. It remains named-ineligible even if
the pointer's typedef happened to spell parameter names, because it is a value
rather than a direct declaration member:

```lua
local c = foreign import "callbacks.h"

function call_it(cb: c.callback): integer
    return cb(41) as integer
end
```

C function and pointer return conventions remain fixed by their prototypes.
A Titan function type with a flexible result tail cannot be converted to a C
function pointer, and calling a C function never creates a Titan flexible
result run. These strict boundaries are intentionally separate from
[Titan's flexible returns](flexible-returns.md).

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

Functions may also declare a zero-initialized automatic fixed array with
`local values: c.element_type[N]`; the declaration, decay, copy, capture, and
lifetime rules are in
[Fixed C arrays](c-ffi-expressions.md#fixed-c-arrays).

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

Named file-scope tag-only aggregates are available as `c.Tag` without a C
typedef. A function may also declare a complete aggregate without an
initializer to request C `{0}` initialization. See
[C FFI declarations and expressions](c-ffi-expressions.md).

A Titan [union](unions.md) is unrelated to a C `union`: it is nominal tagged
userdata, not an overlay of C fields. There is no structural cast in either
direction between Titan unions and C unions or structs. The only identity
escape is the explicit Titan-union-to-C-`void *` cast described above.

### C Assignment Receivers And Order

C field and index targets follow Titan's
[prepared-target assignment order](statements.md#multiple-assignment). For a
single assignment, Titan evaluates and freezes the complete receiver/base and
index chain before the right-hand side, then performs the final NULL or bounds
check and the store. A multiple assignment prepares every target in lexical
left-hand order before any right-hand expression and later stores from left to
right.

A check needed merely to *reach* the final target is different from that final
store check. For example, in `links()[i].next.x = rhs()`, checking the pointer
and index needed to load `next` happens while preparing the left-hand side. If
that intermediate step fails, `rhs()` does not run. Once the final target has
been reached, its own pointer or bound validation remains deferred until after
the right-hand side. An owned C receiver stays GC-rooted across this interval,
so reassigning the Titan variable that supplied it does not retarget the
pending store.

A by-value C struct, union, or array used as an assignment receiver must
ultimately denote persistent, addressable storage. Imported C objects, C
locals or parameters, pointer-referenced storage, and fields or elements
reached from those objects are persistent. A C pointer or owned C object
identifies persistent storage regardless of how that pointer/userdata value was
produced, so a pointer-returning function or `T.new()` call can be a receiver.
A call, cast, or other temporary that produces a struct, union, or array *by
value* is not persistent: Titan cannot retain a pointer to that temporary while
the right-hand side runs.

```lua
local p: c.ffi_point = c.make_point()
p.x = 1                  -- valid: p is persistent local storage
c.make_point().x = 2     -- rejected: the returned struct is temporary
```

The rejected form reports:

```text
C assignment receiver must have persistent storage; expression of type 'ffi_point' is a by-value C aggregate
```

Reading from such a temporary remains valid. That includes reading a pointer
field or pointer-array element during target preparation and then mutating the
persistent object named by that copied pointer:

```lua
c.make_outer().pointer_field.x = 3  -- valid: x belongs to the pointee
```

Titan may materialize the returned aggregate just long enough to extract and
freeze `pointer_field`; it does not try to mutate the temporary `outer`.
Passing a materialized by-value object to a compatible `const *T` parameter
for the duration of one C call likewise remains valid. The restriction is
specifically on mutation of a by-value aggregate through an assignment
receiver.

## Owned C Objects

Owned C storage has source-written types as well as allocation
pseudo-functions:

```lua
local ffi = foreign import "titan/ffi.h"

function make(): integer
    local one: owned *ffi.titan_ffi_int =
        ffi.titan_ffi_int.new()
    local many: owned ffi.titan_ffi_int[] =
        ffi.titan_ffi_int.new_array(16)
    return #many
end
```

`owned *T` means one GC-owned object whose C payload type is `T`.
`owned T[]` means a dynamically counted GC-owned array whose element type is
`T`. The first `*` in the scalar spelling marks ownership; it is not a pointer
layer in the payload. Consequently, `owned **T` owns one `T *` object, while
`owned *T[]` owns an array of `T *` elements.

The payload must be an imported, complete, allocatable C object type. Titan
rejects `void`, direct C function types, incomplete structs and unions, C array
typedefs, structs with flexible array members, Titan types, and nested owned
storage. Fixed extents such as `owned T[4]` are not part of the owner syntax;
use `owned T[]` and supply the count when allocating.

`T.new()` allocates one zeroed C object and returns `owned *T`.
`T.new_array(count)` allocates `count` zeroed adjacent objects and returns
`owned T[]`. The inferred and written shapes remain distinct even when the
array count is one. Both are full userdata whose lifetime belongs to Titan's
Lua GC. No finalizer is installed.

A trailing option marker wraps the complete owner:

```lua
local type Handle = owned *ffi.titan_ffi_int

local record State
    local handle?: Handle
end
```

Here `Handle?` and the field shorthand `handle?: Handle` mean that the owner
may be absent. The C payload itself is never an option, and an optional owner
must be explicitly unwrapped before it adjusts to a C pointer.

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

Passing a mutable owner to a C function expecting `T *`, `const T *`, or a
permitted `void *` passes a pointer to the userdata payload. A counted owner
adjusts to its element pointer. Qualifiers may be added but not discarded, so
an owner of typedef-qualified `const T` cannot become `T *` or mutable
`void *`:

```lua
local ffi = foreign import "titan/ffi.h"
local stdio = foreign import "stdio.h"

function formatted_len(s: string): integer
    local buf: owned ffi.titan_ffi_char[] =
        ffi.titan_ffi_char.new_array(32)
    return stdio.snprintf(buf, 32, "%s", s)
end
```

Counted owned character arrays have one additional explicit conversion:

```lua
local bytes: owned ffi.titan_ffi_char[] =
    ffi.titan_ffi_char.new_array(4)
bytes[0] = 65 as ffi.titan_ffi_char
bytes[1] = 0 as ffi.titan_ffi_char
bytes[2] = 66 as ffi.titan_ffi_char
bytes[3] = 0 as ffi.titan_ffi_char
local binary = bytes as string       -- four bytes: "A\0B\0"
```

The conversion is binary-safe: it copies exactly the owned array's byte
length, including embedded and trailing NUL bytes. It is available for arrays
of `char`, `signed char`, and `unsigned char`, including typedef chains and
legal qualifiers. A scalar character owner and a non-character array do not
have this cast. Casting the same owner to `*char` first retains the older C
pointer conversion: `(bytes as *ffi.titan_ffi_char) as string` scans to the
first NUL.

Indexing a counted owner is 0-based and bounds-checked, and `#owner` returns
its element count. Scalar owners have neither a length nor array indexing.

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

Bundled Titan gives libuv one complete dynamic process owner: the combined
standard-library provider `titan.so`; the paired `titan.a` carries the same
libuv objects for static Titan consumers. Its SDK installs `uv.h` and the
`uv/` headers, but not the private libuv archive used as payload for that
provider pair. A Titan extension DSO that calls functions declared by `uv.h`
must import
`titan.uv` (normally through its short spelling) in addition to importing the
header:

```titan
local runtime = import "uv"
local uv = foreign import "uv.h"
```

Build that extension without `-luv` and without a `libuv.a` linker input. Its
`uv_*` references remain unresolved in the DSO. The bundled archive carried
into the standard provider pair is private and is not installed as part of the
Titan SDK.
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

The generated `titan/uv.lua` loader resolves the physical provider name
`titan` through `package.cpath`, obtains the native support table with
`require "titan"`, and asks that table's internal loader to reopen/promote the
canonical `titan.so` with `RTLD_LAZY | RTLD_GLOBAL` before invoking
`luaopen_titan_uv`. The support load itself uses Lua's ordinary C searcher and
is eager/local; the separate global handle cache deliberately performs the
promotion. This works with stock Lua 5.5 on both Linux and macOS without a
`loadlib.c` patch or self-loading provider. A stock host can use the bundled
direct-extension contract when its `LUA_PATH_5_5` finds the generated loader
and its `LUA_CPATH_5_5` finds the canonical DSO (see
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
* Titan functions and closures cannot be adapted to C callback ABIs.
* C types are local to the importing Titan module and cannot appear in exported
  compiled-module interfaces.
* Function-like macros are not imported. Object-like macros are values only
  through bounded recognized expression forms, including supported
  integer-constant expressions and typed dereferenced accessors, or when they
  fully expand to an outer cast to a supported scalar type. A pure dotted
  identifier replacement can stand in for a field. Other object-like forms are
  not generally supported. Conditional macro behavior that depends on state
  from a separate earlier import, or a later import changing a scalar macro
  already typed through another module namespace, requires an umbrella header.
* Owned allocation does not support `void`, incomplete aggregate types, C array
  typedefs, or structs with flexible array members.
* C adopted pointers/lifetimes are parked for a later design; v1 has borrowed C
  pointers and Titan-owned userdata only.
* The C ordinary-identifier namespace is shared across all foreign imports in
  one generated C file. Titan validates the ordered foreign-header context and
  checks compatible extracted repeats before treating them as declarations of
  the same identifier, but it does not attempt to namespace or rename C
  declarations.
* Declaration extraction still preprocesses each foreign import independently,
  without the fixed generated-C prefix. Compiler probes replay that fixed
  standard/Lua/Titan prefix followed by the ordered foreign-header block, just
  as generated module C does. Macro state established by an earlier foreign
  import can therefore make a later isolated TypeList differ from the
  cumulative probe/generated-C view; macro state from the fixed prefix can
  cause that divergence even for the first foreign import.
* The baseline and declaration-pair checks validate the contexts and
  declaration types they compile, but they neither reconstruct a cumulative
  TypeList nor prove that an extracted declaration survived preprocessing. A
  unique value or type-namespace binding can consequently retain its isolated
  type, and Titan may reject isolated declarations that become compatible only
  cumulatively. Conversely, a macro-suppressed isolated repeat can still affect
  canonicalization or contribute composite information: for example, an
  isolated `extern int a[7]` hidden by cumulative macro state can complete an
  earlier `extern int a[]` to `[7]` in Titan's view. Put macro-coupled
  declarations behind one umbrella header and import that header once.
