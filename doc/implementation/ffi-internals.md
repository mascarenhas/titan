# FFI internals

`foreign import "stdio.h"` drives a compile-time C pipeline under
`c-parser/`, converts declarations into the `Type.C*` family in `types.lua`,
and emits direct C expressions in `coder.lua`. The generated translation unit
includes the same header, so the host C compiler sees the real prototypes; the
Lua-side pipeline exists to typecheck Titan source before code generation.

For user-facing behavior see [the C FFI](../language/ffi.md),
[C FFI declarations and expressions](../language/c-ffi-expressions.md), and
[Named arguments](../language/named-arguments.md). The exact tag, declarator,
probe, contextual-conversion, automatic-storage, and C-operator machinery is
covered in
[C FFI declarations and expressions](c-ffi-expressions.md).

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
or system header becomes `#include <name.h>`; an absolute path is quoted. The
coder splices these completed lines between separately rendered preamble
halves, because a valid header spelling may contain `$identifier` and must
remain opaque to the compiler's recursive template renderer.

After the import pass, every module with a nonempty list of successful foreign
imports builds one `cprobe.ModuleContext` from the complete ordered descriptor
list and validates its baseline translation unit. The shared
`cpreamble.fixed_includes` block places the same standard, Lua, and Titan
headers before those imports as generated module C. This includes a one-header
module: the best-effort isolated registrar can collapse an invalid repeated
declaration before two published entries reach the checker. The baseline
compiler-checks cumulative state and declaration legality: include guards,
`#pragma once`, ordinary redeclarations, and repeated tag definitions are
interpreted by the configured compiler rather than inferred from parser
provenance. The immutable context is versioned by the include count, so an
earlier prefix context cannot be reused after another import.

The C-pipeline stages are:

1. `cpp.new_context` asks the configured compiler with user CPP flags first,
   Titan's fixed C99 mode next, and the actual runtime/Lua include directories
   last for predefined macros (`-dM -E`) and system include paths (`-E -v`),
   then `cpp.parse_file` preprocesses the header. Contexts are cached by the
   complete effective argument vector and copied for each import; recursive
   includes share the per-import context.
2. `c99.match_language_grammar` parses the preprocessed C translation unit.
3. `ctypes.register_types` extracts declarations into a TypeList.
4. `cdefines.register_defines` adds supported object-like `#define` constants
   and records pure dotted-identifier field projections. A bare-identifier
   replacement that resolves to a parsed typedef is type-valued: a macro-only
   type alias remains unsupported, while a macro shadowing an existing typedef
   rebinds that public spelling to the active replacement typedef so generated
   C and checker semantics agree. Aliases to functions, objects, and
   enumerators remain expression-valued members. Integer-constant expressions
   retain target-neutral literal and expression metadata for later
   target-profile evaluation, while the existing best-effort expression path
   recognizes typed dereferenced accessors such as `errno`'s `*accessor()`
   expansion. A fully expanded outer cast to a supported integer, floating,
   object-pointer, or function-pointer type records that target declaration for
   ordinary C-type conversion while preserving the public macro spelling.
   `cdriver` also retains raw macro definitions and the names changed by each
   header closure. Dotted replacements are left unresolved until a field
   access supplies both the receiver aggregate and the final module-wide macro
   environment.

`cdeclarator.lua` then owns exact C spelling shared by generated code and
compile probes; `csemantics.lua` owns target categories, constants, promotions,
and result types; and one resolver-scoped `cprobe.lua` service owns the active
toolchain profile, header-context baselines, candidate compilation, caches,
temporary files, and cleanup. The checker decides which candidates are
semantically eligible before asking that service to compile them.

The checker iterates the TypeList array part in declaration order. Each
successful `foreigntypes.convert(st, ftype)` result is either a value member or
a type member:

* functions, variables, constants and enum constants become
  `types.ModuleMember`;
* `typedef`, `struct` and `union` declarations become entries in
  `symtab.foreign_types`, while source-nameable typedefs also become entries in
  the C type namespace (`modtype.type_members`). Named file-scope tag-only
  structs/unions are published there by base name when no real same-name
  typedef exists, but still point directly at canonical internal owners such as
  `struct@P`; no fake `CTypedef` is created.

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
* header-defined functions are imported like ordinary C functions regardless
  of whether their storage form is `static`, `extern inline`, or bare `inline`;
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
CArray       = {"elem", "len", "quals"}
CFunction    = {"params", "ret", "vararg", "abi"}
CStruct      = {"cname", "tagname", "typedef", "fields", "complete", "has_fam"}
CUnion       = {"cname", "tagname", "typedef", "fields", "complete"}
CField       = {"owner", "name", "type", "bitfield", "flexible_array"}
CTypedef     = {"name", "target", "quals"}
COwned       = {"pointee", "count"}
CModule      = {"name", "members", "type_members"}
```

`CFunction` deliberately has no parameter-name field. Callback/function-pointer
types remain structural; declaration spellings stay on raw CTypes until a
direct foreign member is built.

`types.resolve_c_typedef` unwraps `CTypedef` chains. The type predicates keep
three different questions separate:

* `types.is_c` detects a direct C value or one nested through ordinary
  Array/Map/Option storage, but deliberately excludes `CModule`, since a C
  module is only a namespace;
* `types.first_c_ffi_type` performs the full recursive interface/export scan,
  including boxed callable signatures;
* `types.is_direct_c` asks whether the value itself has a C representation,
  while `types.has_tvalue_representation` asks whether that representation can
  round-trip through a Lua `TValue`.

The checker and coder use the direct/boxability predicates for lowering.
Structural C provenance remains relevant to interface validation; it must not
send an ordinary Titan Array, Map, option, or callable down a direct-C path
merely because one component contains `COwned`.

The source parser represents both written owner shapes as
`Ast.TypeCOwned(loc, subtype, count)`. `count = false` is the scalar
`owned *T` form; `count = true` is the dynamically counted `owned T[]` form.
The parser keeps the payload optionless and applies a trailing `?` outside this
node, so optionality is the ordinary `Type.Option(COwned(...))` shape.
The record-field shorthand `name?: T` constructs that same outer option.
`typefromnode` resolves the payload in the current foreign namespace, applies
the same allocation-eligibility check used by `.new()`/`.new_array()`, and
constructs the existing `Type.COwned` representation.

Exact value-type equality compares primitive spelling, qualifiers, array
length, aggregate identity/shape, and the other representation fields.
`CTypedef` equality itself is nominal by typedef name and qualifiers; it
deliberately does not compare the stored target graph. The separate C
declaration-compatibility relation unwraps typedef chains, preserves their
qualifiers, and compares the resolved targets before accepted repeated
declarations are canonicalized. This C declaration relation is unrelated to
Titan gradual consistency.

Titan use sites consume plans. `types.consistent` admits a C-bearing type
against `value` only when that C-bearing type has a sound `TValue`
representation and a strict guard. `types.coercion(source, target)` plans
ordinary automatic C adjustments; `types.written_cast` owns the additional
explicitly requested operations. No caller obtains permission from a broad boolean
"compatibility" result. The automatic coercions include:

* C integer -> Titan `integer`, and Titan `integer` -> C integer;
* C float -> Titan `float`, and Titan `integer`/`float` -> C float;
* C pointer, including C function pointer -> `boolean`, `nil` -> C pointer;
* C array / counted `COwned` -> compatible pointer;
* scalar `COwned` -> its payload object pointer;
* any non-function C pointer -> `void *`;
* non-pointer by-value C object expressions -> compatible `const *T` pointers
  by address;
* mutable non-pointer local/formal C variables -> compatible mutable `*T` or
  `void *` out-parameters by address;
* Titan `string` -> C `char *` or `void *`;
* C `TValue` -> Titan `value`, and Titan `value` -> C `TValue`;
* C integers, C floats, and `COwned` <-> `value`;
* non-function C pointers -> `value`; the reverse direction is written and
  unsafe rather than automatic;
* counted `COwned` arrays of typedef-resolved `char`, `signed char`, or
  `unsigned char` -> Titan `string`;
* Lua-internal `Udata *` -> full-userdata `value`, with NULL -> nil; written
  `value as Udata *` is the reverse full-userdata/nil operation.

The numeric entries are partial whenever the selected target profile cannot
prove range containment. The profile supplies exact integer intervals,
floating radix/mantissa/range, and the configured `lua_Integer`/`lua_Number`
carriers. C scalar results remain raw until a checker-owned conversion or
boxing plan reaches an actual boundary. At that point the shared checked
numeric lowering validates representability before casting or mutating a
`TValue`. Written C-integer-to-C-integer conversions and checker-selected C
usual-arithmetic integer conversions retain ordinary C semantics; potentially
out-of-range integer-to-floating operator conversions remain checked.

Written-only conversions include C-function-pointer erasure to `void *`, GC
identity erasure from a Titan Array, Map, nominal record/union, or function to
C `void *`, counted-character-owner to `string`, and the explicitly unsafe
raw object-pointer cases. These are recorded in `WrittenCastPlan` and never
participate in recursive Array/Map/Option/function consistency.

Owner-to-pointer adjustment constructs the same qualified pointer view used by
ordinary pointer/array compatibility. It may add qualification and perform
legal object-pointer-to-`void *` adjustment, but it never discards
typedef-carried `const` or `volatile`.

`types.dynamic_coercion(target)` covers Lua-boundary and written-`value`
conversion for C integers, C floats, `COwned`, and C `TValue`. It deliberately
returns no plan for a raw C pointer: a lightuserdata address cannot establish
the requested pointee type. `value as CPointer(T)` is the narrow exception;
the written cast records `unsafe_dynamic_c_pointer`, making the unsafe intent
explicit. Implicit `value` projection and Lua boundary entry reject the same
request.

For C numeric targets, strict plans accept only the exact Lua numeric tag and
then validate the target interval. Dynamic C-integer plans additionally admit
an integral float that first fits `lua_Integer`; dynamic C-float plans admit
either numeric tag. `_Bool` accepts only 0 and 1. Floating narrowing rejects
non-finite or out-of-range values while allowing rounding and underflow, and
floating-to-integer conversion truncates only after its finite/range check.
The non-raising written `is` lowering consumes the same plan and predicate as
the corresponding `as`.

`types.is_gc_identity_void_pointer_cast` is a deliberately narrower
representation relation. It resolves Titan aliases and the C target typedef,
requires a C `void *` target, and admits only `Array`, `Map`, `Nominal`, and
`Function`. It excludes `Value`, `Option`, and `String`: `Value` keeps its
checked lightuserdata/nil C-pointer conversion, options must be unwrapped,
and strings keep their byte-buffer pointer. `COwned` also stays on its existing
payload-pointer path. `types.is_c_function_pointer_void_cast` identifies the
separate written C function-pointer erasure.

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
  The parser uses contextual `lexer.CNAME` for this selector and for C member
  access, so a header spelling that is a Titan keyword (`when`, `repeat`,
  `type`, and so on) remains source-nameable. Ordinary Titan names still use
  keyword-rejecting `NAME`; C prototype labels continue to use
  `NAMEDLABEL`. The parser stamps accepted `Ast.VarDot` and
  `Ast.TypeQualName` nodes with `_contextual_c_name`; the checker admits that
  marker only when the qualifier resolves to a `Type.CModule`, and the coder
  emits the stored C spelling unchanged.
* `Ast.TypeCPointer` accepts `*c.T` and `const *c.T`, producing `CPointer`
  values over direct imported C pointees and rejecting non-C pointees and
  `COwned` wrappers.
* `Ast.TypeCOwned` accepts the source `owned *c.T` and `owned c.T[]`
  forms. It shares `c_allocation_error` with the allocation
  pseudo-constructors, rejecting non-C and nested owners, `void`, direct C
  functions, incomplete aggregates, C array typedefs, and
  flexible-array-member structs before any generated `sizeof` can be formed.
* `Ast.TypeOption` requires its base to satisfy
  `types.has_tvalue_representation`. This admits `COwned` and other boxable C
  scalars while rejecting by-value C aggregates/arrays, direct C functions,
  and C function pointers before `getslot`/`setslot` code generation.
  Record fields and union payloads use the same predicate because they occupy
  the same kind of user-value slot. It treats Arrays, Maps, and Titan function
  values as already boxed and recurses only through `Option`; it does not
  recursively reject their component/signature types.
* `Ast.VarDot` on a `CModule` consults ordinary `members` first. If no value
  has that name, a `type_members` entry yields a `Type.CTypeNamespace`
  pseudo-declaration so `.new`, `.new_array`, `.sizeof`, and `.alignof` can be
  resolved. When both namespaces contain the spelling, the ordinary value
  remains usable and the checker records the collision so a later
  type-pseudo-member access gets a specific diagnostic instead of silently
  selecting the type.
* `Ast.VarDot` on a C struct/union, pointer-to-aggregate, or owned aggregate
  resolves a `Type.CField`. A pure dotted field macro is expanded logically
  through physical aggregate fields first, because C preprocessing precedes
  member lookup; otherwise the checker selects the ordinary physical field.
  Generated C hoists all foreign includes, so macro lookup always uses the
  final module-wide environment even inside an earlier module-variable closure.
  Every aggregate definition along the selected physical path must still be
  visible at the ordinary module-variable frontier. An active object-like macro
  with an unsupported final expansion is terminal rather than falling back.
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
* `Ast.ExpCall` validates C allocation pseudo-functions through that same
  helper, including the direct-C-function rejection. A struct/union completed
  only by a later foreign import is treated as incomplete while checking an
  earlier module variable.
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
public variable, or public nominal member that mentions a C type is rejected.
Local fields/variants, methods, and nominal functions are skipped before this
check, so a private C-typed record slot or union variant can remain
module-internal. `CModule` itself is
rejected as a first-class value in the same `ExpVar` path as ordinary Titan
modules.

The checker keeps a per-module `symtab.foreign_names` table for the final
ordinary C identifier environment and a source-ordered history for frontier
lookup. Field tokens instead use the generated translation unit's final macro
view: the first import seeds a raw macro environment, later imports replay
their active definitions/redefinitions/undefinitions, and lazy lookup rescans
transitive dependencies before classifying a projection. A later published
occurrence of one ordinary name is compared with the first using C declaration
compatibility, including typedef resolution, normalized qualification,
parameter adjustment, and incomplete/known array composites. Structurally
matching anonymous aggregates are only conditional candidates.

After the final baseline succeeds, every queued exact or conditional pair is
rendered as two `extern` declarations of one probe-private synthetic identifier and
compiled in the same foreign-header context. Acceptance proves that the two
independently extracted declaration types can form compatible declarations in
that context; it does not prove that both source declarations survived
preprocessing. Only an accepted pair is rewritten to the first canonical
declaration type and allowed to form a declaration composite.

One otherwise-incompatible pair is also queued when both ordinary declarations
have the same preprocessor source identity, line, and column *and* a dedicated
recursive relation proves that every unequal type node is an explicitly marked
prototype-local struct or union with the same tag spelling, kind, completeness,
and layout. A bidirectional object map also requires the two graphs to preserve
tag reuse and shadowing topology. Source identity uses filesystem device/inode identity where the host
provides it, with the resolved preprocessor pathname as the fallback, so lexical
include aliases do not split one physical declaration. Independent parsing can
assign different canonical objects to such a tag in one guarded declaration.
After the ordered-header baseline succeeds, this `source-repeat` is canonicalized
directly: rendering a synthetic pair would introduce two prototype scopes that
the guarded ordered includes never emit. The fallback applies only when ordinary
isolated compatibility failed, so exact and conditional repeats retain the
declaration-pair probe, different source declarations retain nominal
prototype-tag identity, and macro-dependent changes outside those tag objects
remain conflicts even if cumulative preprocessing suppresses one occurrence.

Array-bound completion mutates only a declaration-owned cloned view, never a
canonical shared typedef target. Accepted repeated typedefs use a separate
operation: the checker rebinds the later isolated `CTypedef.target` to the
first target so transitive references that share that alias in the later
snapshot follow the chosen canonical target.

An isolated semantic incompatibility is reported immediately unless it is the
narrow prototype-tag re-extraction fallback above. A failed final baseline
reports the complete header-context failure, reports that incompatible source
repeat, and performs no canonicalization. A rejected or unrenderable
declaration pair is reported as a conflict and any later type-registry entries
are withdrawn. A compiler spawn, interruption, workspace, or cleanup failure
is an infrastructure diagnostic, never a declaration-compatibility verdict.
During a module variable, `find_foreign_name` and `find_foreign_type` scan their
histories backward and return the last declaration whose order is no later than
`initializer_order`; outside that pass they use the final maps directly.
`foreign_definition_visible` performs the analogous check for canonical
struct/union objects that a later import completed in place.

## Code Generation

### Rendering C Types

`cdeclarator.render_type_name` and `render_declaration` render C FFI types back
to exact C spellings. A `CTypedef` renders as its typedef name, preserving
headers' preferred spelling for calls and allocation. Declarators are built
recursively for locals and temporaries, because `int (*cb)(int)` cannot be
produced by concatenating a type spelling and a name. `COwned` renders as
`Udata *`; its payload is reached through `getudatamem`. The Titan diagnostic
renderer preserves its logical shape as `owned *T` or `owned T[]`. The hidden
owned-metatable key uses that same canonical renderer, so scalar and counted
owners cannot acquire inconsistent hand-built spellings.

The general `ctype` function routes C values through `cdeclarator`, applying C
parameter adjustment where appropriate. `COwned` remains a Lua full-userdata
pointer.

### Calls And Variables

`codeforeigncall` emits a direct C call of the bare C name. The Titan foreign
module name is gone by codegen time. Fixed and C-vararg arguments both flow
through `codeforeignexp`, so Titan strings become `getstr(TString*)`, owned C
objects decay to payload pointers when the target is a C pointer, and most
`value` arguments consume their checker-attached plan when the target C type
has a sound runtime representation. An implicit typed Titan projection carries
a strict `GuardPlan`; an explicitly written or genuine-Lua boundary carries
the broader dynamic plan before this foreign sink. A raw C-pointer target has
no implicit guard and must have arisen from an explicit unsafe written cast. A
target C type of `TValue` is special: Titan passes the raw `TValue`
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

`codeforeignvar` emits a bare C variable or public macro name. A C scalar from
a foreign variable, function result, field, index, macro, or C operator keeps
its exact C type and raw value until a cast, typed context, or boxed store
converts it. C arrays are kept as C array expressions and can be indexed or
decayed to pointers. For a live pure dotted-identifier macro, the checker resolves the
recorded replacement lazily against the receiver before physical field lookup,
matching preprocessing precedence, and retains the projected field's type,
lvalue status, and mutation rules. The coder still emits the public field
spelling, leaving expansion to the included host header. This does not widen
the separate contextual address coercion from eligible locals to subobjects.

`codecfunctionptrcall` handles calls through C function pointer values. It
evaluates the pointer expression once, materializes it into a C temporary,
raises a Lua error if the temporary is `NULL`, converts arguments through
`codeforeignexp`, and emits `tmp(args...)`. The expression dispatcher checks this
path before the direct C-module call path so `c.callback_value(...)` is treated
as an indirect call when `callback_value` has a function pointer type.

Every direct or function-pointer foreign call is conservatively treated as a
possible Lua-stack relocation point. The coder materializes a non-`void`
result, recovers the generated function's cached `_base` from `_base_off`, and
only then performs post-call stack-slot anchoring or result conversion; `void`
calls use the same recovery without a result temporary. This permits trusted
runtime FFI functions to re-enter Lua or grow its heap stack without leaving
later generated stack accesses pointed at the old allocation. It does not
widen the public FFI safety boundary: arbitrary Lua C API stack effects,
borrowed-pointer lifetimes, and nonlocal exits still require their existing
operation-specific contracts.

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
* other sound `value` to C conversions use the attached strict `GuardPlan`;
  raw C pointers have no implicit or dynamic plan.

`nativetoforeignexp` recognizes explicit GC-identity casts before its ordinary
direct-C pass-through. It materializes the source exactly once and anchors it
in a scanned temporary. Array and Map values then expose that temporary's
native `Table *`; a nominal record or union exposes its `Udata *`. Function values are
native `TValue`s, so the lowering first tests `iscollectable(&temporary)`,
raises for an immediate value, and otherwise converts
`gcvalue(&temporary)` to the requested C `void *` spelling. `_codeis` uses the
same materialization but returns the collectability predicate instead of
raising. This GC-identity predicate belongs only to the explicitly written
erasure to C `void *`. A written `value as Function` instead uses the
canonical dynamic function plan, preserving the boxed value and deferring
callability/type verification to invocation.

The checker accepts the written C-function-pointer-to-`void *` case before
`_unsafe_c_pointer_conversion` diagnoses cross-category object/function
reinterpretations. Implicit and contextual function/object pointer
conversions remain rejected. The coder emits
`titan_cast_func(target_type, source)` for this explicit erasure, preserving
the compiler-specific portability handling already used by dynamic symbol
loading.

Materializing a GC-identity source protects it through subsequent expression
and call-argument setup, but the resulting raw pointer carries no ownership.
Once the containing generated frame stops anchoring the source, only another
reachable reference keeps it alive. The `Table *`, `Udata *`, and general
`GCObject *` identities are internal runtime addresses, not stable public
layouts or independently managed allocations.

This is the only Titan-union/C boundary added by unions v1. A Titan union may
be explicitly erased to C `void *` as a GC identity, just like a Titan record;
it is never structurally converted to a C `union` or `struct`, and no reverse
aggregate cast is defined.

`foreigntonativeexp` handles C-to-Titan conversion for call results and foreign
variables. C `TValue` results become Titan `value`s directly. C
integers/floats remain raw C values until a checker-planned numeric or carrier
crossing; the shared checked conversion then validates the target profile
before producing `lua_Integer`, `lua_Number`, or another C scalar.
The same rule covers compiler-synthesized C results: `sizeof`/`_Alignof`
retain the profile's `size_t`, and pointer subtraction retains its
`ptrdiff_t`, until a checked conversion produces Titan `integer`. The profile
names both carriers explicitly and is rejected unless its signed integer
ranges are two's-complement, which is the representation assumed by emitted
minimum-bound expressions. Public macro-expression evaluation still validates
the complete supplied profile on every call; `csemantics` retains only a
bounded set of modest pure exact decimal powers of two used by those range
proofs, so macro-heavy headers do not rebuild the same constants hundreds of
times, larger powers remain exact without being retained, and profile-table
mutation cannot bypass validation.
C pointers/arrays/aggregates remain C values; C `char *` / `void *` to
`string` is implemented by an explicit cast arm with a NULL guard and
`luaS_new` copy.

A written cast from a counted character owner takes a separate length-aware
path. The coder materializes the `Udata *` in a scanned slot, then calls
`luaS_newlstr(L, (const char *)getudatamem(owner), owner->len)`. The explicit
payload length preserves embedded and trailing NUL bytes, while the scanned
slot keeps even a temporary owner rooted across the string allocation.
Scalar character owners and non-character arrays never enter this arm; a cast
through `char *` retains the NUL-terminated pointer behavior above.

`getslot` and `setslot` know how to box C scalars, non-function pointers, owned
userdata, and by-value C `TValue`s for `value` conversions and for Lua-facing
slots. C numeric `getslot`/strict-get paths share the target-profile predicate
with dynamic coercion, and `setslot` validates carrier representability before
calling `setivalue` or `setfltvalue`; these are not unchecked native casts.
Ordinary C object pointers are exposed as light userdata in `value`;
`COwned` is full userdata. Lua-internal `Udata *` is the deliberate exception:
boxing emits the full-userdata tag for that same object (or nil for NULL), and
unboxing accepts full userdata or nil rather than lightuserdata. C arrays are
not accepted through `value` because there is no array unboxing path. C
function pointers are not object pointers in portable C and cannot cross
through `value` or the object-pointer address coercions; only the explicit
`titan_cast_func`-lowered erasure to `void *` crosses that category. By-value C
structs/unions are deliberately not boxable in v1.

An option uses one `TValue` slot and delegates its present arm to these same
checked helpers, which is why `TypeOption` validates the base eagerly.
Owner-to-pointer
coercion also stops at an outer option: `Option(COwned(T))` cannot coerce
directly to either `CPointer(T)` or `Option(CPointer(T))`. The source must first
be explicitly unwrapped, keeping a definite owner live while its borrowed
payload pointer is used.

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
* `CArray`, `CStruct`, and `CUnion` subobjects retain a stable access path
  assembled only from already-frozen roots and indices, rather than being
  copied by value.

The access-path form is equivalent to retaining the subobject address while
remaining valid C99 for anonymous nested structs/unions and arrays whose
element type has no legal standalone declarator. Named pointer and `COwned`
bases still use real materialized pointers, and the latter remains rooted in
its scanned slot across right-hand evaluation.

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

Source-written `owned *T` and `owned T[]` lower to the same
`COwned(T, false)` and `COwned(T, true)` values already inferred from `.new()`
and `.new_array(count)`. The pseudo-functions remain checker-only declarations
(`Type.CPseudoNew`) generated when a type namespace is accessed.
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

Making C-bearing Titan function types source-nameable exposes a separate
registry-identity issue. Canonical C type spellings are meaningful only within
the module that imported their headers, so two modules may render unrelated
local owner/function types identically. Function-type registry keys therefore
remain globally shared for C-free function types, preserving their
cross-module exact-call fast path, but include the defining Titan module name
when `types.first_c_ffi_type` finds any C type in the callable shape. A
separate C-bearing marker in the module-local tag cache prevents a C typedef
whose diagnostic spelling matches a Titan type from reusing that Titan
callable's entry before either registry key is emitted. A
same-spelled C-bearing function crossing through `value` in another module
then takes the generic checked path, where the owned metatable mismatch is
reported instead of entering a native function with the wrong payload layout.

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
* Function-like macros are invisible to Titan. An object-like macro is
  expression-valued through bounded recognized forms, including supported
  integer-constant expressions and typed dereferenced accessors, or when it
  fully expands to an outer cast to a supported scalar type. A pure dotted
  identifier replacement can become a field projection. Other object-like
  forms are not generally supported.
* Generated C shares one ordinary-identifier namespace and one tag namespace
  across all foreign imports. Titan does not rename declarations; the final
  foreign-header baseline validates cumulative declaration and tag state
  before module checking continues.
* `cdriver.process_file` still extracts each import's TypeList from an
  independently preprocessed header without the fixed generated-C prefix.
  Probes and generated module C both place the ordered foreign-header block
  after the shared fixed standard, Lua, and Titan headers. Earlier
  foreign-import macros can therefore make an isolated TypeList differ from
  the cumulative probe/generated-C view, and macros from the fixed prefix can
  cause that divergence even for the first import.
* Neither the final baseline nor a declaration-pair probe reconstructs the
  alternate cumulative TypeList or proves that both extracted declarations
  occurred. The checker can retain an isolated unique value or type-namespace
  binding, reject a distinct-source isolated incompatibility that disappears
  cumulatively, or canonicalize a repeat that cumulative preprocessing
  suppressed. The source-repeat fallback covers a guarded physical declaration
  only when its complete type graphs differ solely in independently extracted,
  same-spelled prototype-local tag identities; it never unifies tags from
  distinct declarations, changes tag reuse/shadowing topology, or hides other
  macro-dependent changes. A suppressed
  `extern int a[7]` can, for example, complete an earlier `extern int a[]` in Titan's
  declaration composite even though only the incomplete declaration occurs
  cumulatively. Macro-coupled APIs need one umbrella header imported once.

## `typed.lua`

The C parser modules are written with the repository's `typed.lua` DSL, but the
DSL ships disabled (`typed.off()`). Turn it on temporarily when debugging parser
type confusion; do not rely on it for normal compiler execution.
