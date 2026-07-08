# FFI internals

`foreign import "stdio.h"` drives a compile-time C pipeline under
`c-parser/`, converts declarations into the `Type.C*` family in `types.lua`,
and emits direct C expressions in `coder.lua`. The generated translation unit
includes the same header, so the host C compiler sees the real prototypes; the
Lua-side pipeline exists to typecheck Titan source before code generation.

For user-facing behavior see [the C FFI](../language/ffi.md).

## Import Pipeline

The checker's `Ast.TopLevelForeignImport` handler calls
`cdriver.process_file(header, { source_dir = st.source_dir })`. On success it
gets:

* a TypeList from the C parser;
* no error;
* an include descriptor stored on `node._include`.

The include descriptor is later used by the coder. It records the original
header name, the resolved parse path, an `include_kind` (`"quote"` or
`"angle"`), and the include name to write in generated C. A relative header
found beside the Titan source becomes `#include "name.h"`; a compiler-provided
or system header becomes `#include <name.h>`; an absolute path is quoted.

The four C-pipeline stages are:

1. `cpp.parse_file` preprocesses the header, using `gcc -dM -E` for predefined
   macros and `cpp -v` for system include paths.
2. `c99.match_language_grammar` parses the preprocessed C translation unit.
3. `ctypes.register_types` extracts declarations into a TypeList.
4. `cdefines.register_defines` adds typed object-like `#define` constants.

The checker iterates the TypeList array part in declaration order. Each
successful `foreigntypes.convert(st, ftype)` result is either a value member or
a type member:

* functions, variables, constants and enum constants become
  `types.ModuleMember`;
* `typedef`, `struct` and `union` declarations become entries in
  `symtab.foreign_types`, while source-nameable typedefs also become entries in
  the C type namespace (`modtype.type_members`). Tag-only aggregates are kept
  under internal keys such as `struct@P`; users need a typedef name to write
  `c.T` in Titan source.

The final module type is `Type.CModule`, not the older `Type.ForeignModule`.
`Type.CModule` is a namespace and is rejected as a first-class value.

Unsupported C declarations are skipped per member. A later reference to the
skipped name is therefore a clean `member 'x' not found inside module 'h'`
diagnostic. Preprocessing/parsing failures still fail the import itself.

## Header Support Files

The compiler ships `titan-runtime/titan/ffi.h`. `cdriver` searches upward from
the loaded compiler module until it finds `titan-runtime`, so `foreign import
"titan/ffi.h"` works without installing a system header and without depending
on the process cwd. The file exposes selected primitive aliases:
`titan_ffi_void`, `titan_ffi_bool`, `titan_ffi_char`,
`titan_ffi_signed_char`, `titan_ffi_unsigned_char`, `titan_ffi_short`,
`titan_ffi_unsigned_short`, `titan_ffi_int`, `titan_ffi_unsigned_int`,
`titan_ffi_long`, `titan_ffi_unsigned_long`, `titan_ffi_long_long`,
`titan_ffi_unsigned_long_long`, `titan_ffi_float`, `titan_ffi_double`, an
opaque `lua_State` typedef, and Lua's internal `TValue` type. Exact by-value
`TValue` is special-cased to Titan `value` for private runtime helper
boundaries; pointer and array forms such as `TValue *` and `TValue[]` are not
part of the supported FFI surface.

Generated C already compiles with `-I titan-runtime`, so the emitted
`#include <titan/ffi.h>` resolves through the normal C compiler path too.

## TypeList Extraction

`ctypes.lua` preserves more C shape than the old prototype:

* standalone `struct`/`union` declarations nested under `item.spec[1]` are
  registered;
* typedef and extern array dimensions are kept in `idxs`;
* field declarators keep names, pointer suffixes and array suffixes;
* bitfields store `bitfield`, `width` and `anonymous`;
* flexible array members are marked with `flexible_array = true`;
* function-pointer typedefs are represented as `functionptr` CTypes;
* header-defined `static` functions are imported like ordinary C functions;
* simple enum values are stored on the enum type's `values` list.

Array extents and enum values are constant-folded when possible. Unknown but
syntactically present extents are preserved rather than thrown away; the checker
treats only numeric extents as known and rejects operations that require a known
bound.

The C99 grammar remains non-reentrant because it uses a module-global typedef
table, reset at the start of each parse. The preprocessor still has the older
limitations: raw Lua errors for some macro/`#if` cases, ignored `#error` and
`#pragma`, and best-effort GNU/Clang extension handling.

## `Type.C*`

`types.lua` now registers the C FFI vocabulary with `typedecl`:

```lua
CVoid        = {}
CInteger     = {"spelling", "signed", "rank", "bits"}
CFloat       = {"spelling"}
CPointer     = {"pointee", "quals"}
CArray       = {"elem", "len"}
CFunction    = {"params", "ret", "vararg", "abi"}
CStruct      = {"cname", "tagname", "typedef", "fields", "complete", "has_fam"}
CUnion       = {"cname", "tagname", "typedef", "fields", "complete"}
CField       = {"owner", "name", "type", "bitfield", "flexible_array"}
CTypedef     = {"name", "target"}
COwned       = {"pointee", "count"}
CModule      = {"name", "members"}
```

`types.resolve_c_typedef` unwraps `CTypedef` chains. `types.is_c` detects C
value/type shapes but deliberately excludes `CModule`, since a C module is only
a namespace.

The equality relation compares exact C identity: spelling, qualifiers, array
length, typedef name and target, aggregate field shape, and so on. The
compatibility/coercion relations add the Titan boundary conversions:

* C integer -> Titan `integer`, and Titan `integer` -> C integer;
* C float -> Titan `float`, and Titan `integer`/`float` -> C float;
* C pointer, including C function pointer -> `boolean`, `nil` -> C pointer;
* C array / counted `COwned` -> compatible pointer;
* any non-function C pointer -> `void *`;
* Titan `string` -> C `char *` or `void *`;
* exact by-value C `TValue` -> Titan `value`, and Titan `value` ->
  by-value C `TValue`;
* C integers, C floats, non-function C pointers, and `COwned` <-> `value`.

Serialization rejects any type tree containing a C FFI type. This is the
enforcement point for "C types are local to the importing module": exported
module interfaces cannot contain C types because a consumer module would also
need the correct header included in its generated C.

## Converting C Declarations

`foreigntypes.lua` converts parser CTypes into `Type.C*`.

Primitive tokens are canonicalized before conversion, so spellings such as
`long unsigned int` and `unsigned long` map to the same `CInteger` identity.
Integer ranks preserve signedness and relative width; known 128-bit compiler
types carry `bits = 128`. `float`, `double` and `long double` become `CFloat`.
`void` becomes `CVoid`. Exact `TValue` is special-cased to Titan's dynamic
`value` type for private runtime helpers that need to move arbitrary Lua
values through the FFI; `TValue *` and `TValue[]` are rejected rather than
exposing raw Lua stack/value storage through Titan.

Pointer and array suffixes are applied in declaration order. Typedefs become
`CTypedef(name, target)`. Structs and unions become `CStruct`/`CUnion` objects
with a named field table and array part; the converter registers a composite
owner in `symtab.foreign_types` before walking fields so recursive pointer
fields reuse the same owner.

Foreign function declarations are stored in the C module's value namespace with
a `Type.Function`-shaped signature whose params and returns are C types. That
shape is an implementation convenience for checking a direct foreign call; it
does **not** make a foreign function a Titan first-class function value.
`Ast.ExpVar` rejects taking a foreign function as a value, except when the
surrounding context asks for a compatible C function pointer. The pre-existing
`vararg` boolean on `Type.Function` remains the marker for a C variadic
function. It is distinct from Titan variadic functions, which use `varargtype`.

C function pointer typedefs are represented as `CTypedef` targets that resolve
to `CPointer(CFunction(...))`. `CFunction` is only a C function signature inside
a pointer type; it is not a Titan function value.

## Checker Rules

The checker has FFI-specific handling in a few narrow places:

* `Ast.TypeQualName` accepts `c.T` when `c` is a `CModule` and source-nameable
  `T` is in its `type_members`. This lifts the prototype restriction that C
  types could only be inferred.
* `Ast.VarDot` on a `CModule` first consults `type_members`; a type member
  yields a `Type.CTypeNamespace` pseudo-declaration so `.new` and `.new_array`
  can be resolved on it. Value members still come from `mod.members`.
* `Ast.VarDot` on a C struct/union, pointer-to-aggregate, or owned aggregate
  resolves a `Type.CField`.
* `Ast.VarBracket` accepts C pointers, C arrays with known static length, and
  counted owned C arrays. C indexing is 0-based.
* `#exp` accepts C arrays with known static length and counted owned C arrays.
* `Ast.ExpCall` validates C allocation pseudo-functions, rejecting `void`,
  incomplete aggregates, C array typedefs, and structs with flexible array
  members.
* `Ast.ExpCall` also recognizes callees whose resolved type is
  `CPointer(CFunction(...))`. It checks arguments against the C function
  signature and records `_c_pointer_call` for codegen.
* `Ast.ExpVar` rejects foreign functions as Titan first-class values, but allows
  a foreign function name in a context whose target is a compatible C function
  pointer type. The node records `_foreign_function_pointer` so codegen can emit
  a C cast of the bare function name.
* `checkfuncbody` synthesizes the read-only local `L` for every function-like
  body. `lua_state_pointer_type` gives it type `CPointer(CTypedef("lua_State",
  ...))`, reusing an imported `lua_State` type when one is already present in
  the module's C type namespace.

Export checks use `types.contains_c_ffi_type`: any public function signature,
public variable, or public record member that mentions a C type is rejected.
Local record fields, methods and record functions are skipped before this check, so a
private C-typed record slot can remain module-internal. `CModule` itself is
rejected as a first-class value in the same `ExpVar` path as ordinary Titan
modules.

The checker keeps a per-module `symtab.foreign_names` table for ordinary C
identifiers imported so far. If a later foreign import declares the same ordinary
name with an incompatible type, Titan reports the conflict before generating C.
Duplicate declarations from the same header are ignored here because system
headers can expose implementation-specific aliases during preprocessing.

## Code Generation

### Rendering C Types

`foreignctype` renders C FFI types back to C spellings. A `CTypedef` renders as
its typedef name, preserving headers' preferred spelling for calls and
allocation. C function pointer types use declarator-aware rendering helpers for
locals and temporaries, because `int (*cb)(int)` cannot be produced by simply
concatenating a type spelling and a name. `COwned` renders as `Udata*`; its
payload is reached through `getudatamem`.

The general `ctype` function routes C values through `foreignctype`, except
`COwned`, which is always a Lua full userdata pointer.

### Calls And Variables

`codeforeigncall` emits a direct C call of the bare C name. The Titan foreign
module name is gone by codegen time. Fixed and C-vararg arguments both flow
through `codeforeignexp`, so Titan strings become `getstr(TString*)`, owned C
objects decay to payload pointers when the target is a C pointer, and most
`value` arguments are checked with `checkandget` when the target C type is
known. A target C type of `TValue` is special: Titan passes the raw `TValue`
struct by value, for private runtime helpers that already know how to preserve
the owning Lua state and root any collectable payloads.

`codeforeignvar` emits a bare C variable or macro name. Reading a C scalar into
Titan code keeps the C value type until a cast or context converts it. C arrays
are kept as C array expressions and can be indexed or decayed to pointers.

`codecfunctionptrcall` handles calls through C function pointer values. It
evaluates the pointer expression once, materializes it into a C temporary,
raises a Lua error if the temporary is `NULL`, converts arguments through
`codeforeignexp`, and emits `tmp(args...)`. The expression dispatcher checks this
path before the direct C-module call path so `c.callback_value(...)` is treated
as an indirect call when `callback_value` has a function pointer type.

Generated includes use `node._include`:

```c
#include "local_header.h"
#include <stdio.h>
```

The old absolute-path heuristic in `coder.lua` is gone; the checker/cdriver
decides quote-vs-angle based on actual resolution.

### Casts And Boundary Values

`nativetoforeignexp` handles Titan-to-C conversion:

* C values pass through unchanged;
* `COwned` to a C pointer, including a targetless C vararg argument, becomes
  `getudatamem(owned)`;
* Titan strings become `getstr(tstring)` for C pointer targets and for C
  vararg arguments;
* `nil` becomes `NULL`;
* `value` to C `TValue` passes the raw `TValue` by value;
* other `value` to C conversions use the runtime `checkandget` path.

`foreigntonativeexp` handles C-to-Titan conversion for call results and foreign
variables. C `TValue` results become Titan `value`s directly. C
integers/floats cast to Lua numeric C types when a Titan numeric target needs
them; C pointers/arrays/aggregates remain C values; C `char *` / `void *` to
`string` is implemented by an explicit cast arm with a NULL guard and
`luaS_new` copy.

`getslot` and `setslot` know how to box C scalars, non-function pointers, and
owned userdata into Lua `TValue`s for `value` conversions and for Lua-facing
slots. C object pointers are exposed as light userdata in `value`; `COwned` is
full userdata. C arrays are not accepted through `value` because there is no
array unboxing path. C function pointers are not object pointers in portable C
and cannot cross through `value`. By-value C structs/unions are deliberately not
boxable in v1.

### C Arrays And Fields

`codecindex_parts` centralizes C indexing. It evaluates the base and index once,
materializes the integer index, emits bounds checks for static C arrays and
counted owned arrays, and returns the C lvalue base/index pair. Reads and writes
reuse that helper:

```c
if (_i < 0 || _i >= 4) luaL_error(...);
tmp = values[_i];
values[_i] = rhs;
```

Pointer indexing emits no bounds check, but it materializes the pointer once
and raises a Lua error on `NULL`. Owned array length is reconstructed as
`owner->len / sizeof(T)`, relying on Lua's `Udata.len` field.

`codecfield` renders aggregate field lvalues:

* `base.field` for C aggregate values;
* `base->field` for C pointers after a `NULL` check;
* `((T *)getudatamem(owner))->field` for owned objects.

### Owned C Objects

The `.new()` and `.new_array(count)` pseudo-functions are checker-only
declarations (`Type.CPseudoNew`) generated when a type namespace is accessed.
`codecpseudonew` allocates Lua userdata directly:

```c
size_t _nbytes = (size_t)_count * sizeof(T);
Udata *_box = luaS_newudata(L, _nbytes, 0);
_box->metatable = hvalue(&_mod->uv[type_slot].uv);
setuvalue(L, stack_slot, _box);
memset(getudatamem(_box), 0, _nbytes);
```

There is no finalizer. Titan owns the lifetime through the Lua GC, and the
payload size in `Udata.len` is enough to reconstruct the dynamic count for
counted owned arrays. The userdata is anchored in a stack slot immediately after
allocation, before any later operation can trigger a collection.

Each distinct owned C pointee/count shape also gets a hidden module slot holding
a metatable. New allocations stamp that metatable onto the `Udata`, and
`value` casts back to `COwned` compare the metatable before accepting the
userdata. This prevents unrelated full userdata, including Titan records, from
being reinterpreted as C payload memory.

This is deliberately different from adopted/borrowed C pointers. Borrowed
pointers are raw C pointer values and are not GC-managed; adopted pointers are
left for a later FFI iteration.

## Platform Constraints And Failure Modes

* Compile-time POSIX dependency: `gcc -dM -E`, `cpp -v`, `/dev/null`,
  `LANG=C`.
* The built-in C parser accepts common GNU/Clang/macOS extensions, but headers
  outside that subset can fail during preprocessing or parsing.
* Some preprocessor paths still raise raw Lua errors instead of diagnostics
  (`#if` operators outside the implemented set, unterminated function-like
  macros).
* Function-like macros are invisible to Titan.
* The generated C translation unit has one flat C namespace. Titan does not
  rename declarations; it detects incompatible ordinary declarations from
  distinct foreign imports before the C compiler sees them.

## `typed.lua`

The C parser modules are written with the repository's `typed.lua` DSL, but the
DSL ships disabled (`typed.off()`). Turn it on temporarily when debugging parser
type confusion; do not rely on it for normal compiler execution.
