# FFI internals

`foreign import "stdio.h"` drives a compile-time C pipeline under
`c-parser/`, converts declarations into the `Type.C*` family in `types.lua`,
and emits direct C expressions in `coder.lua`. The generated translation unit
includes the same header, so the host C compiler sees the real prototypes; the
Lua-side pipeline exists to typecheck Titan source before code generation.

For user-facing behavior see [the C FFI](../language/ffi.md) and
[Named arguments](../language/named-arguments.md).

## Import Pipeline

The checker's `Ast.TopLevelForeignImport` handler calls
`cdriver.process_file` with the importing source directory plus the configured
compiler, C99 language mode, and already parsed `TITAN_EXTRA_CPPFLAGS`.
The driver also supplies its current fixed runtime and Lua include directories.
In source-checkout mode, `titanc --lua` updates that configuration before
checking begins. Installed mode rejects the override so FFI parsing, generated
C, `liblua.a`, and `libtitan.a` continue to use one matched SDK. On success it
gets:

* a TypeList from the C parser;
* no error;
* an include descriptor stored on `node._include`.

Top-level declaration collection invokes every foreign import in AST order
before aliases, records, and callable signatures. `visit_toplevel` exposes the
node's `_toplevel_order` as `st.current_toplevel_order` while its declarations
are converted. Thus non-module-variable declarations see the complete C
environment regardless of relative placement without changing include order
or the combined AST.

The include descriptor is later used by the coder. It records the original
header name, the resolved parse path, an `include_kind` (`"quote"` or
`"angle"`), and the include name to write in generated C. A relative header
found beside the Titan source becomes `#include "name.h"`; a compiler-provided
or system header becomes `#include <name.h>`; an absolute path is quoted.

The four C-pipeline stages are:

1. `cpp.new_context` asks the configured compiler with user CPP flags first,
   Titan's fixed C99 mode next, and the actual runtime/Lua include directories
   last for predefined macros (`-dM -E`) and system include paths (`-E -v`),
   then `cpp.parse_file` preprocesses the header. Contexts are cached by the
   complete effective argument vector and copied for each import; recursive
   includes share the per-import context.
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

Each accepted C type is also appended to `foreign_type_history` with the
foreign-import node's top-level order; accepted ordinary identifiers use the
parallel `foreign_name_history`. These histories are distinct from the final
namespace maps because module-variable declarations must recover the last C
declaration visible at their source frontier after all headers have already
been processed. A canonical C struct/union may instead be forward-declared by
one header and completed in place by another; completion stamps that owner with
`_definition_order` so its later fields do not leak backward through the shared
object.

The final module type is `Type.CModule`, not the older `Type.ForeignModule`.
`Type.CModule` is a namespace and is rejected as a first-class value.

Unsupported C declarations are skipped per member. A later reference to the
skipped name is therefore a clean `member 'x' not found inside module 'h'`
diagnostic. Preprocessing/parsing failures still fail the import itself.

## Header Support Files

The installed compiler ships `<root>/include/titan/ffi.h` and passes
`<root>/include` as both a C-FFI probe path and a generated-C include path.
Checkout developer mode instead searches upward from the loaded compiler
module for `titan-runtime/titan/ffi.h`. Thus `foreign import "titan/ffi.h"`
works without depending on the process cwd while keeping an installed compiler
inside one SDK root. The file exposes selected primitive aliases:
`titan_ffi_void`, `titan_ffi_bool`, `titan_ffi_char`,
`titan_ffi_signed_char`, `titan_ffi_unsigned_char`, `titan_ffi_short`,
`titan_ffi_unsigned_short`, `titan_ffi_int`, `titan_ffi_unsigned_int`,
`titan_ffi_long`, `titan_ffi_unsigned_long`, `titan_ffi_long_long`,
`titan_ffi_unsigned_long_long`, `titan_ffi_float`, `titan_ffi_double`, an
opaque `lua_State` typedef, and Lua's internal `TValue` type. `TValue` remains a
distinct C type in Titan's FFI type graph. Private runtime helpers can move
values across that boundary through explicit `value` <-> C `TValue` coercions.

Generated C in installed mode compiles with `-I <root>/include` (checkout mode
uses `-I titan-runtime`), so the emitted `#include <titan/ffi.h>` resolves
through the same normal compiler path.

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
* function declarators preserve `paramstyle` (`prototype` versus C old-style)
  and an eligible complete list of fixed-parameter spellings;
* simple enum values, including typedef-enum values, are stored on the enum
  type's `values` list.

Array extents and enum values are constant-folded when possible. Unknown but
syntactically present extents are preserved rather than thrown away; the checker
treats only numeric extents as known and rejects operations that require a known
bound.

`c99.lua` distinguishes a true `(void)` prototype from `()`: both have no
effective parameter types, but only the former establishes a known empty name
list. `ctypes.get_params` publishes `paramnames = { ... }` only when every
effective non-void fixed parameter is named and the names are unique;
otherwise it publishes `false`. Compatible redeclarations merge that
declaration metadata after ordinary type equality: unknown can upgrade to
complete, unknown cannot erase complete, and two differing complete lists
permanently become `conflicting`/`false`. Parameter spellings therefore do not
participate in C type identity.

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

`CFunction` deliberately has no parameter-name field. Callback/function-pointer
types remain structural; declaration spellings stay on raw CTypes until a
direct foreign member is built.

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
* non-pointer by-value C object expressions -> compatible `const *T` pointers
  by address;
* mutable non-pointer local/formal C variables -> compatible mutable `*T` or
  `void *` out-parameters by address;
* Titan `string` -> C `char *` or `void *`;
* C `TValue` -> Titan `value`, and Titan `value` -> C `TValue`;
* C integers, C floats, non-function C pointers, and `COwned` <-> `value`;
* Lua-internal `Udata *` <-> full-userdata `value`, with NULL <-> nil.

C `TValue` and typedef-resolved pointers to Lua's internal `Udata` are treated
as GC-bearing C types by the code generator. A local, temporary, or parameter
with either type gets the same Lua-stack anchoring used for Titan `value`.
A by-value `TValue` may itself contain a collectable pointer, while a
non-NULL `Udata *` denotes the full userdata GC object directly.

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
`void` becomes `CVoid`. `TValue` follows the normal C conversion path and stays
a C typedef/struct type; `TValue *` and `TValue[]` are therefore ordinary C
pointer/array types. The special handling lives in the checker and coder
coercion rules, not in foreign type import.

Pointer and array suffixes are applied in declaration order. Typedefs become
`CTypedef(name, target)`. Structs and unions become `CStruct`/`CUnion` objects
with a named field table and array part; the converter registers a composite
owner in `symtab.foreign_types` before walking fields so recursive pointer
fields reuse the same owner. When a definition completes that canonical owner,
`populate_struct_or_union` records the active foreign import's order in
`owner._definition_order`.

Foreign function declarations are stored in the C module's value namespace with
a `Type.Function`-shaped signature whose params and returns are C types. That
shape is an implementation convenience for checking a direct foreign call; it
does **not** make a foreign function a Titan first-class function value.
The structural shape sets both Titan tail slots to false: C's `vararg` marker
is kept separately, and a C function has no Titan `flexrettype`.
`Ast.ExpVar` rejects taking a foreign function as a value, except when the
surrounding context asks for a compatible C function pointer. The pre-existing
`vararg` boolean on `Type.Function` remains the marker for a C variadic
function. It is distinct from Titan variadic functions, which use `varargtype`.
The surrounding `Type.ModuleMember` separately copies the raw function CType's
`paramnames` table or `false`; `foreigntypes.convert` does not put those names
in the structural signature.

C function pointer typedefs are represented as `CTypedef` targets that resolve
to `CPointer(CFunction(...))`. `CFunction` is only a C function signature inside
a pointer type; it is not a Titan function value.

## Checker Rules

The checker has FFI-specific handling in a few narrow places:

* `Ast.TypeQualName` accepts `c.T` when `c` is a `CModule` and source-nameable
  `T` is in its `type_members`. This lifts the prototype restriction that C
  types could only be inferred. A non-module-variable declaration may use a
  later `foreign import`; while checking a module variable,
  `symtab.find_symbol` masks a later C-module alias by `initializer_order`.
* `Ast.TypeCPointer` accepts `*c.T` and `const *c.T`, producing `CPointer`
  values over imported C pointees and rejecting non-C pointees.
* `Ast.VarDot` on a `CModule` first consults `type_members`; a type member
  yields a `Type.CTypeNamespace` pseudo-declaration so `.new` and `.new_array`
  can be resolved on it. `sizeof` and `alignof` on a C type namespace produce
  pseudo-declarations that codegen emits as `sizeof(T)` and `_Alignof(T)`.
  Value members still come from `mod.members`.
* `Ast.VarDot` on a C struct/union, pointer-to-aggregate, or owned aggregate
  resolves a `Type.CField`. At a module-variable frontier it does so only when
  `symtab.foreign_definition_visible` says the aggregate's defining import is
  already visible.
* `Ast.VarBracket` accepts C pointers, C arrays with known static length, and
  counted owned C arrays. C indexing is 0-based.
* After checking each `Ast.StatAssign` target, `check_c_assignment_storage`
  recursively verifies that a by-value `CStruct`, `CUnion`, or `CArray`
  receiver ends in persistent storage. `CPointer` and `COwned` expressions
  identify storage regardless of how their values were produced. Aggregate
  storage may instead be a local/parameter, an imported C object, or a nested
  field/index chain rooted in such storage. A call, cast, or other aggregate
  temporary used as the object being mutated is rejected with
  `C assignment receiver must have persistent storage; expression of type 'T' is a by-value C aggregate`.
  Extracting a pointer value from such a temporary is accepted because the
  pointer's pointee, not the temporary aggregate, is the mutation target.
* `#exp` accepts C arrays with known static length and counted owned C arrays.
* `Ast.ExpCall` validates C allocation pseudo-functions, rejecting `void`,
  incomplete aggregates, C array typedefs, and structs with flexible array
  members. A struct/union completed only by a later foreign import is treated
  as incomplete while checking an earlier module variable.
* Top-level initializer validation recognizes `Type.CPseudoNew` as a sound
  constructor. `T.new()` and `T.new_array(count)` are accepted when their
  actual argument list is constant; a count that reads module state is
  rejected just like a non-constant record-constructor argument. The
  `Ast.ExpAdjust` introduced by parenthesizing a call is transparent to this
  check. The same validator checks both expression-valued map keys and their
  values in initializer lists.
* `Ast.ExpCall` also recognizes callees whose resolved type is
  `CPointer(CFunction(...))`. It checks arguments against the C function
  signature and records `_c_pointer_call` for codegen.
* Direct C and C-function-pointer calls keep exact C arity. The shared
  expression-list demand may project enough finite values from a trailing
  flexible Titan producer to fill fixed C parameters, but it diagnoses a
  missing fixed argument or an explicit surplus expression instead of applying
  Titan's nil-padding/downward-adjustment rules. A runtime-open `...` or
  flexible-result run is rejected at a C variadic boundary because Titan's
  typed descriptor has no C default-promotion ABI.
* A brace-delimited call to a direct C module function uses the member's
  declaration-only `paramnames`. The checker rejects C variadics, unavailable
  name lists, C function pointers, and allocation pseudo-constructors. For an
  eligible fixed declaration, it matches/checks explicit fields in lexical
  order and synthesizes `nil` only for omitted C parameters whose converted
  Titan-visible type passes `nil_can_adjust_to`. The resulting dense positional
  list carries `_named_arg_order` and `_named_call_kind = "foreign"`; see
  [named-argument internals](named-arguments.md).
* `Ast.ExpVar` rejects foreign functions as Titan first-class values, but allows
  a foreign function name in a context whose target is a compatible C function
  pointer type. The node records `_foreign_function_pointer` so codegen can emit
  a C cast of the bare function name.
  The reverse conversion also rejects a Titan function type with an input
  `varargtype`, more than one fixed result, or a flexible `flexrettype`: none of
  those native Titan calling-convention pieces has a compatible C function
  pointer signature.
* `checkforin` treats generic-for iterator and close slots as C function-pointer
  contexts when a foreign function name appears there, then records
  `_c_pointer_call` on the synthesized calls.
* `trycoerce` and explicit casts recognize mutable address coercion only for
  local/formal C variables. The checker marks those declarations as assigned and
  rejects later capture, so generated C cannot take the address of a boxed
  captured local.
* `checkfuncbody` synthesizes the read-only local `L` for every function-like
  body. `lua_state_pointer_type` gives it type `CPointer(CTypedef("lua_State",
  ...))`, reusing an imported `lua_State` type when one is already present in
  the visible C type namespace. Ordinary callable bodies see the completed
  module environment; a lambda inside a module-variable initializer retains
  that initializer's frontier and therefore cannot reuse a `lua_State`
  declaration from a later foreign import.

Export checks use `types.contains_c_ffi_type`: any public function signature,
public variable, or public record member that mentions a C type is rejected.
Local record fields, methods and record functions are skipped before this check, so a
private C-typed record slot can remain module-internal. `CModule` itself is
rejected as a first-class value in the same `ExpVar` path as ordinary Titan
modules.

The checker keeps a per-module `symtab.foreign_names` table for the final
ordinary C identifier environment and a source-ordered history for frontier
lookup. If a later foreign import declares the same ordinary name with an
incompatible type, Titan reports the conflict before generating C. Duplicate
declarations from the same header are ignored here because system headers can
expose implementation-specific aliases during preprocessing. During a module
variable, `find_foreign_name` and `find_foreign_type` scan their histories
backward and return the last declaration whose order is no later than
`initializer_order`; outside that pass they use the final maps directly.
`foreign_definition_visible` performs the analogous check for canonical
struct/union objects that a later import completed in place.

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

This path has no flexible-result descriptor. C returns its single ordinary
result (or `void`) according to `CFunction.ret`; any finite projections used to
form its fixed arguments have already been made explicit by the checker.

For a checked named direct call, `codeforeigncall` freezes converted explicit
arguments into target-typed C temporaries in `_named_arg_order`, then freezes
synthetic omissions. It emits those temporary names in formal order in the C
call. This prevents C's unspecified argument-evaluation order—and the
name-to-position mapping itself—from reordering Titan effects. The path retains
the positional implementation's post-call `mutable_out_anchor` refreshes for
GC-bearing `TValue` out parameters.

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
* non-pointer by-value C or `value` expressions passed to compatible `const *T`
  parameters are materialized as `&(expr)`;
* local/formal non-pointer C variables passed to compatible mutable pointer
  parameters are materialized as `&(local)`, enabling C out-parameters;
* other `value` to C conversions use the runtime `checkandget` path.

`foreigntonativeexp` handles C-to-Titan conversion for call results and foreign
variables. C `TValue` results become Titan `value`s directly. C
integers/floats cast to Lua numeric C types when a Titan numeric target needs
them; C pointers/arrays/aggregates remain C values; C `char *` / `void *` to
`string` is implemented by an explicit cast arm with a NULL guard and
`luaS_new` copy.

`getslot` and `setslot` know how to box C scalars, non-function pointers, owned
userdata, and by-value C `TValue`s for `value` conversions and for Lua-facing
slots. Ordinary C object pointers are exposed as light userdata in `value`;
`COwned` is full userdata. Lua-internal `Udata *` is the deliberate exception:
boxing emits the full-userdata tag for that same object (or nil for NULL), and
unboxing accepts full userdata or nil rather than lightuserdata. C arrays are
not accepted through `value` because there is no array unboxing path. C
function pointers are not object pointers in portable C and cannot cross
through `value` or the object-pointer address coercions. By-value C
structs/unions are deliberately not boxable in v1.

### C Arrays And Fields

Read lowering uses `codecindex_parts`: it evaluates the base and index once,
materializes the integer index, emits bounds checks for static C arrays and
counted owned arrays, and returns the C lvalue base/index pair. `codecfield`
likewise renders a direct aggregate field read:

```c
if (_i < 0 || _i >= 4) luaL_error(...);
tmp = values[_i];
```

Pointer indexing emits no bounds check, but it materializes the pointer once
and raises a Lua error on `NULL`. Owned array length is reconstructed as
`owner->len / sizeof(T)`, relying on Lua's `Udata.len` field.

The direct field forms are:

* `base.field` for C aggregate values;
* `base->field` for C pointers after a `NULL` check;
* `((T *)getudatamem(owner))->field` for owned objects.

Assignment uses the generic prepared-lvalue pipeline instead of re-running
those read helpers at store time. Both `codesingleassignment` and
`codemultiassignment` call `_materialize_assignment_lvalue` before
`_codeadjustedfixed` evaluates the right-hand side. The returned descriptor is
then consumed by `codeassignment`, which performs the final validation and
mutation. A multiple assignment prepares every target in lexical left-hand
order first and consumes the descriptors from left to right.

`_prepare_c_base` recursively preserves the original addressable storage:

* a `CPointer` value is loaded and frozen in a C temporary;
* a `COwned` userdata is materialized in a scanned Lua slot, and the descriptor
  retains its payload pointer plus the count expression when applicable;
* a `CArray` lvalue is retained through a synthesized element pointer (ordinary
  C array decay) plus its static length, rather than copied into an
  unassignable array temporary; and
* a `CStruct` or `CUnion` subobject is retained through a synthesized pointer
  to its persistent storage, rather than copied by value.

`_prepare_c_storage` walks nested `VarDot`/`VarBracket` bases recursively.
NULL and bounds validation for the *final* field or index stays in the
descriptor and runs after the right-hand side. A validation needed to obtain
an intermediate base runs during left-hand preparation, because the next
field/index address cannot be formed safely without first dereferencing or
indexing that base. This is why `null_link().next.x = rhs()` raises before
`rhs()`, while `null_point().x = rhs()` evaluates `rhs()` before the final
NULL check.

The recursive storage path requires a by-value C aggregate receiver to end in
persistent addressable storage. An imported C object, C local/parameter, or
field/index chain rooted in one can supply that storage. `CPointer` and
`COwned` expressions already identify storage regardless of how they were
produced, but a call, cast, or other expression that produces a
`CStruct`/`CUnion`/`CArray` temporary by value cannot. The checker emits
`C assignment receiver must have persistent storage; expression of type 'T' is a by-value C aggregate`
before code generation, while
`_prepare_c_storage` retains a defensive assertion when persistent storage was
required but an unexpected non-`ExpVar` receiver reaches code generation.

There is one deliberate intermediate-read exception.
`_prepare_c_loaded_value` needs only a copied pointer value when the final
target base is a C pointer. It calls `_prepare_c_storage(..., true)`, allowing
a by-value struct/union to be materialized long enough to read a pointer field
or a pointer-array element. The pointer is then frozen in its own temporary;
the final mutation targets its pointee, not the aggregate temporary. Thus
`make_outer().inner.x = rhs()` is rejected, while
`make_outer().pointer_field.x = rhs()` is valid. Ordinary reads and one-call
`const *T` address coercions may likewise materialize by-value aggregate
temporaries because their addresses do not have to survive a separately
evaluated right-hand side.

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

The top-level constant-expression check admits these pseudo-constructors when
all arguments are constant. The allocation still occurs once per module
instance at initialization time, and the resulting `COwned` userdata is stored
in a GC-traced module slot.

Each distinct owned C pointee/count shape also gets a hidden module slot holding
a metatable. New allocations stamp that metatable onto the `Udata`, and
`value` casts back to `COwned` compare the metatable before accepting the
userdata. This prevents unrelated full userdata, including Titan records, from
being reinterpreted as C payload memory.

This is deliberately different from adopted/borrowed C pointers. Borrowed
pointers are raw C pointer values and are not GC-managed; adopted pointers are
left for a later FFI iteration.

## Platform Constraints And Failure Modes

* Compile-time POSIX dependency: the configured C compiler's `-E`, `-dM`, and
  `-v` modes, `/dev/null`, and `LANG=C`/`LC_ALL=C`. Ambient `CPATH` remains in
  force; explicit include paths and feature macros belong in
  `TITAN_EXTRA_CPPFLAGS` so checking and generated compilation agree.
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
