# C FFI declarations, conversions, and expressions

This chapter describes the implementation added around the existing
[`foreign import` pipeline](ffi-internals.md): source-visible tag-only
aggregates, exact C declarators, session-scoped compiler probes, contextual
object-pointer conversions, automatic C objects, and C-mode operators. It is
the implementation counterpart of the language chapter
[C FFI declarations and expressions](../language/c-ffi-expressions.md).

The central boundary is intentional:

* the Titan checker decides which source constructs are semantically eligible;
* the configured C compiler validates exact target C constructs;
* generated code consumes checker-recorded traits and does not rediscover C
  compatibility or promotions.

Compiler acceptance is evidence that a construct compiles in the active header
and target context. It is not evidence of representation compatibility,
inheritance, lifetime safety, or defined run-time behavior.

## C tag identity and publication

### Raw canonical names

`ctypes.lua` continues to use internal keys such as `struct@Item` and
`union@Cell` for canonical file-scope aggregates. Those keys are not source
syntax and are never emitted into C. They distinguish the tag namespace from
ordinary identifiers and from real typedef spellings.

The complete `TypeList` now carries two pieces of registrar metadata before
best-effort declaration conversion:

* `typedef_names[name]` records every syntactic file-scope typedef name,
  including one whose target the converter cannot support;
* `file_scope_tags[name]` records the tag kind, canonical raw key, and
  declaration/definition provenance for named file-scope
  `struct`/`union`/`enum` declarations and references.

Collecting this metadata first makes alias publication independent of
declaration order. A real `typedef Item` always reserves the Titan spelling
`module.Item`; a tag-only fallback never shadows it merely because the tag was
converted first.

For an eligible named `struct` or `union` with no same-name real typedef, the
checker publishes the canonical `Type.CStruct`/`Type.CUnion` directly in the
synthetic `Type.CModule.type_members` table. It does not create
`Type.CTypedef("Item", ...)`, add a header declaration, or register a bare
ordinary C identifier. `cdeclarator` therefore renders the type as
`struct Item` or `union Item`, exactly as the header requires.

Anonymous aggregates and enum tags receive no source alias in this iteration.
An incomplete file-scope tag does receive an alias for pointer-only use; layout
sinks consult visibility/completeness separately.

### One tag namespace per C scope

C shares one tag namespace among `struct`, `union`, and `enum` within a scope.
The registrar diagnoses a different-kind reuse inside one parsed header.
Across foreign imports, the checker-owned module registry performs the same
check and reports both headers/provenances. Same-kind declarations reuse one
canonical `Type.CStruct`/`Type.CUnion`; a later definition completes that
object in place.

Prototype tags require more care. A parameter declaration can introduce a tag
whose scope ends with that prototype, but the isolated header parser cannot
know whether a tag from an earlier `foreign import` is already visible.
`ctypes.lua` gives each prototype a stable scope identity and preserves
unresolved tag-reference metadata. During `foreigntypes` conversion:

1. an already visible module-wide file tag of the same kind wins;
2. otherwise the reference interns a prototype-local owner under that scope
   identity;
3. repeated references in the same prototype reuse that local owner;
4. a later file-scope tag with the same spelling remains distinct.

Aggregate-member callback declarators also receive their proper prototype
scope; their aliases do not leak into the surrounding header scope.

### Frontiers and complete-object sinks

Forward completion does not make a later definition retroactively visible to a
module-variable initializer. The canonical owner records `_definition_order`,
and `symtab.foreign_definition_visible` compares that order with the current
initializer frontier.

The checker centralizes the complete-C-object predicate and applies it wherever
layout is required:

* by-value parameters and results;
* module variables and initialized locals;
* initializer-less automatic locals;
* by-value casts;
* fixed-array elements;
* allocation;
* `sizeof` and `alignof`;
* aggregate field access.

Typedefs and array elements are resolved recursively. Pointers to incomplete
objects remain valid. Flexible-array-member structs are complete for
`sizeof`/`alignof`, while their existing allocation and automatic-storage bans
remain.

### Dual type/value lookup

`Type.CModule` has separate `members` and `type_members`. Type syntax
`c.stat` consults the type table. Expression lookup is value-first so a legal C
function or variable named `stat` is not stolen by `struct stat`.

When only a type exists, expression lookup may synthesize a
`Type.CTypeNamespace` for `.new`, `.new_array`, `.sizeof`, and `.alignof`.
When both namespaces contain the spelling, those pseudo-members are
intentionally unavailable and the checker emits a collision-specific
diagnostic. This avoids parent-sensitive guessing and keeps real fields named
`new`, `new_array`, or `alignof` ordinary fields. `sizeof` itself is a C
keyword and cannot name a field.

None of these C type aliases are serialized into compiled Titan module
interfaces.

## Exact C declarators

`titan-compiler/cdeclarator.lua` is the single renderer for C declarations,
type names, and parameter adjustment:

```lua
render_type_name(type)
render_declaration(type, name)
adjust_parameter_type(type)
```

The renderer recursively places the name inside pointer, array, and function
declarators. It handles direct and nested arrays, pointers to arrays, function
pointers, abstract cast names, pointee/pointer qualifiers, aggregate tag
spellings, and real typedef names. Examples include:

```c
T object[3];
T (*pointer)[3];
int (*callback)(uv_handle_t *, int);
```

Raw arrays are declarations rather than cast type names. Array and function
parameters undergo C parameter adjustment. A real `CTypedef` preserves its
source spelling even while semantic helpers inspect its resolved target and
embedded qualifiers.

Code generation and `cprobe` use this same module. A probe cannot validate one
approximate declaration while the coder emits another.

## Target arithmetic profile

`titan-compiler/csemantics.lua` is pure target-C reasoning. It never asks the
Lua process that runs Titan for its integer sizes or signedness.

The driver builds one profile from the configured compiler's predefined macros
and the active prefix's `luaconf.h`, then injects it into `cprobe.Service`. The
direct-checker fallback performs the same acquisition before constructing its
private service. The service validates and owns a copy and keys its caches by
that profile. It records:

* `CHAR_BIT`, primitive storage widths, signedness, rank, precision, minima,
  and maxima;
* `float`, `double`, and `long double` precedence;
* the actual `lua_Integer` and `lua_Number` spellings/types;
* a stable identity used in probe cache keys.

The same effective compiler prefix and target-selecting flags used for
generated objects feed macro discovery. `TITAN_EXTRA_CFLAGS`, architecture
flags, and the configured SDK cannot describe a different target from the one
used by the profile.

`csemantics` supplies typedef/qualification-aware classification, integer
promotion, usual arithmetic conversion, bounded integer object-macro
expression evaluation, array decay, complete-object checks, and symmetric
pointer common-type rules. Unknown extension ranks/precision are rejected
where a result type cannot be proven.

## Session-scoped compile probes

### Ownership and lifetime

`titan-compiler/cprobe.lua` owns compile-only target validation. One lazily
created `Service` belongs to the resolver for a complete public `titanc`
invocation, including source dependencies. It contains the effective compiler
argv, language/compile/CPP flags, ordered include directories, target profile,
runner, private workspace, baseline cache, result cache, and verbose state.

Each checked Titan module obtains a `ModuleContext` after its ordered
foreign-import pass. That context contains its source directory and exact
include descriptors. Candidate probes never borrow another module's header
preamble.

`titanc`, the filesystem loader, table loader, and child compiler paths thread
the service through `checker.check`. A direct external `checker.check` without
an injected service creates and closes a fresh one using the current
`cdriver` configuration. There is no process-global result cache surviving
`driver.configure_foreign_c`.

The resolver closes the service on success, reported type errors, codegen
errors, and exceptional exits. Tests inject both runner and workspace
providers to prove lifecycle and cleanup without depending on a real compiler.

### Header and toolchain fidelity

Angle headers keep their angle spelling. A source-relative quoted header is
rendered as its resolved absolute quoted path before the probe source moves
under `/tmp`. `cpreamble.fixed_includes` supplies the same preceding standard,
Lua, and Titan headers used by generated module C. Ordered duplicate behavior
within the foreign-header block, fixed include directories, language mode,
parsed compiler command, and target flags therefore match generated
compilation.

Every candidate probe first compiles a baseline translation unit. In
addition, every module with at least one successful foreign import validates
the complete ordered foreign-header preamble once immediately after the import
pass. The one-header case catches illegal repeated declarations that the
best-effort registrar may collapse before publishing its TypeList. That final
compile checks include suppression, cumulative macro state, ordinary
declarations, and tag definitions within the foreign-header block. A completed
compiler rejection makes the header context invalid; a spawn, interruption,
workspace, or cleanup failure remains infrastructure and supplies no semantic
verdict. Candidate acceptance and rejection are both cached, and the same
final-context baseline cache entry serves declaration, conversion, and operator
probes.

Ordinary redeclarations are compared from their isolated TypeLists, but their
shared canonical composite is not committed until the final baseline and that
pair's compatibility probe succeed. The pure declaration relation resolves
typedefs, normalizes declaration-only qualification, adjusts array/function
parameters, and recognizes an incomplete/known array pair as compatible.
Structurally matching anonymous aggregates are only conditional candidates.
Every queued exact or conditional repeat then gets a pair-specific probe
containing two `extern` declarations of one probe-private synthetic identifier.
Compiler acceptance proves that the two extracted types can form compatible
declarations in that foreign-header context; it is not evidence that both
declarations occurred. After acceptance, the merger forms any known-bound
array composite in a declaration-owned deep view. No include-guard/path/line
heuristic participates.

The TypeLists themselves are still produced by preprocessing each foreign
import independently without generated C's fixed preceding standard/Lua/Titan
headers. Probes do include that prefix. Consequently, a declaration whose
spelling depends on macro state established by an earlier import can differ
between the isolated checker and cumulative probe/generated-C views; one that
depends on the fixed prefix can differ even in the first import.

The baseline and pair probes do not invent a replacement cumulative TypeList
or establish that an isolated declaration survived preprocessing. A valid
preamble can therefore retain a unique isolated value or type binding, reject
an isolated incompatibility that would disappear cumulatively, or canonicalize
a macro-suppressed repeat. In particular, a suppressed isolated
`extern int a[7]` can complete an earlier `extern int a[]` to `[7]` in Titan's
composite view. There is no general portable C99 occurrence probe; such APIs
require one umbrella header imported once.

Cache identities length-prefix every component and include the probe kind and
direction, exact rendered declarations, operator spelling/operand
conversions, ordered header context, compiler argv/flags/include roots, and
arithmetic-profile identity.

The service creates a private `mktemp -d` workspace, writes deterministic
collision-free sources, and invokes a non-linking compiler mode. Production
uses `-c source.c -o private.o`; an explicitly configured and separately
established service may opt into `-fsyntax-only`.
Arguments are already parsed and individually shell-quoted; `LANG=C` and
`LC_ALL=C` make diagnostics stable. Missing/interrupted compilers are
infrastructure failures. Candidate source/object/diagnostic artifacts are
removed after each run and the directory is removed on every close path.

Ordinary diagnostics show the first useful compiler line. Verbose mode also
prints the full command, source, cache result, status, and captured diagnostic.

## Contextual object-pointer conversion

The pure `types.compatible` relation is deliberately unchanged. Pointer
conversion is an expression adjustment owned by the checker because it needs a
destination, source node, use-site diagnostic, header context, and service.

The adjustment ladder is:

1. existing Titan/FFI boundaries (`value`, `TValue`, `Udata`, owned storage,
   string pointers, nil/boolean/numeric coercions);
2. exact C equality, typedef resolution, qualification-compatible pointers,
   array decay, and object-pointer/`void *`;
3. exact local/formal address conversion;
4. host-validated unsafe object-pointer conversion;
5. a directional error.

Arrays decay before unsafe probing and emit the array expression rather than
`&array`. For a by-value local aggregate targeting an unrelated object pointer,
steps 3 and 4 compose as
`address_then_unsafe_object_pointer`; the coder emits `(Target *)&local`.

Before probing, recursive qualifier analysis rejects reachable `const` or
`volatile` loss. Qualifiers attached through typedefs and array element types
participate. Object/function-pointer category crossings are rejected. A
category-safe object-pointer candidate then compiles an explicit directional
cast using `cdeclarator`.

The checker records an implicit `Ast.ExpCast` trait:

```lua
node._c_conversion = {
    kind = "unsafe_object_pointer",
    source = resolved_source,
    target = resolved_target,
    probe_key = key,
}
```

The same adjustment path is used for locals, assignment, returns, direct/named
C calls, C function-pointer calls, fixed and typed C-vararg arguments, fields,
and explicit casts. A successful use-site conversion does not alter structural
function compatibility.

Mutable-address call analysis unwraps the recorded cast while retaining whether
it formed an address or array decay. The direct source declaration is added to
the call's `_c_mutated_decls`, marks address-taken/assigned state, and feeds the
try-spill analysis below.

## Automatic aggregates and fixed arrays

The parser adds `Ast.TypeCArray` only in the dedicated single,
initializer-less automatic-local production. Source-written `T[N]` is not a
general Titan type form. The checker accepts the no-RHS statement only for a
complete non-GC-bearing C struct, union, or recursively complete fixed array;
the source extent must be a positive integer literal.

Accepted statements and declarations carry `_c_zero_init` and
`_c_automatic_object`. `cdeclarator.render_declaration` gives the coder an
exact object declaration and the coder emits `{0}`.

Whole struct/union assignment retains C copy behavior. Whole-array inference,
copy, assignment, return, and capture are rejected. Array indexing and `#`
reuse the established static-array paths, and contextual adjustment performs
normal C decay. Aggregate capture is rejected because boxing would change the
object's address; a derived pointer remains an ordinary unsafe C pointer and
may escape.

The transitive eligibility walk rejects `TValue`, `Udata *`, and recognized
GC-bearing fields. Generated automatic storage is not recursively traced by
Lua's collector.

### Longjmp-safe aggregate spills

`try`/`catch` uses C `setjmp`/`longjmp`; an automatic object modified after
`setjmp` would otherwise be indeterminate after recovery. The write analysis
traces C field/index lvalues to their root declaration and consumes
`_c_mutated_decls` from mutable foreign calls.

For each live non-GC automatic aggregate crossing such a boundary, the coder
declares a volatile byte spill:

```c
volatile unsigned char spill[sizeof object];
```

It copies object-representation bytes with explicit loops:

* after zero initialization;
* after whole-object, field, and element writes;
* after a mutable foreign call returns normally.

The recovery path reloads the last committed bytes before Titan reads the
object. The loops preserve volatile accesses; they do not cast volatility away
through `memcpy`. A call that mutates and then nonlocally exits does not commit
partial bytes. Mutation through an untracked raw alias or asynchronously from C
remains outside Titan's guarantee.

## C operator traits

The checker dispatches C operator mode before every Titan-special numeric or
comparison path. It first evaluates category rules, array decay, mixed
`lua_Integer`/`lua_Number` participation, promotions, symmetric pointer common
types, and result type through `csemantics`. It then asks `cprobe` to compile
the exact lowered expression.

An accepted AST node carries the complete lowering contract:

```lua
node._c_operator = {
    cop = "!=",
    lhs_target = ...,
    rhs_target = ...,
    lhs_decay = false,
    rhs_decay = false,
    result = ...,
    probe_key = ...,
}
```

The coder does not recompute conversions. It evaluates operands once into
ordered temporaries, applies the trait's casts/decays, and emits the recorded C
operator (`~=` becomes `!=`; binary Titan `~` becomes `^`). This branch runs
before `intop`, Lua floor division/modulo, normalized shifts, `pow`, numeric
comparison helpers, and divide-by-zero guards.

Unsupported C combinations stop with C-specific diagnostics rather than
falling into Titan lowering. Bit-field operands are rejected before promotion;
an explicit cast to an ordinary integer removes the width-dependent bit-field
category.

Pointer subtraction converts the C result to Titan `integer`. Unrelated object
pointers share a qualification-union `void *` common type for equality only;
ordering requires qualification-compatible object-pointer types, while
subtraction and pointer arithmetic additionally require complete non-void
pointees.

## Preprocessor raw arguments

The hand-written preprocessor now maintains raw and prescanned macro arguments
independently:

* ordinary parameter occurrences use a separately expanded copy;
* `#` and `##` use raw preprocessing tokens;
* empty paste operands become placemarkers;
* paste is validated as exactly one preprocessing token and rescanned.

Per-token side metadata records whether real whitespace preceded the token and
its raw spelling. Stringification trims the argument edges, inserts one space
only where whitespace/comments existed, retains adjacency, preserves digraph
spellings, and escapes backslashes/quotes. Macro substitution propagates that
metadata, including through a generated nested call. Deleting an empty macro
preserves whitespace before the invocation but not whitespace consumed inside
an empty function-like call.

The C99 preprocessing grammar canonicalizes digraphs as one token; the raw
spelling remains solely in the side metadata. This avoids the earlier
raw-plus-canonical duplicate-token bug.

## Ownership map

| Module | Owns |
| --- | --- |
| `c-parser/cpp.lua` | preprocessing, raw/prescanned macro forms, captured compiler execution |
| `c-parser/c99.lua` | preprocessing-token and C99 declaration grammar |
| `c-parser/ctypes.lua` | `TypeList`, file/prototype tag metadata and scopes |
| `titan-compiler/foreigntypes.lua` | ordered canonical C-type conversion and tag binding |
| `titan-compiler/cdeclarator.lua` | exact C declarations/type names/parameter adjustment |
| `titan-compiler/cpreamble.lua` | fixed generated/probe prefix around ordered foreign headers |
| `titan-compiler/csemantics.lua` | target profile interpretation, C categories/promotions/result types |
| `titan-compiler/cprobe.lua` | session/workspace/header contexts, baselines, candidate probes and caches |
| `titan-compiler/checker.lua` | source eligibility, contextual adjustments, traits, completeness and mutation analysis |
| `titan-compiler/coder.lua` | ordered lowering of already-proven traits and volatile aggregate spills |

## Tests

Pure ownership lives in `spec/cpp_spec.lua`, `spec/ctypes_spec.lua`,
`spec/cdeclarator_spec.lua`, `spec/csemantics_spec.lua`,
`spec/cprobe_spec.lua`, and the existing `cdriver`/`foreigntypes`/`symtab`
specs. Checker-only behavior is split into topical C FFI tag, target-profile,
pointer-conversion, stack-object, and operator specs. Coder specs compile and
execute exact declarators, automatic storage, longjmp spills, pointer casts,
and C operator results.

Real-header/tag and libuv-shaped conversions remain compiler tests rather than
stdlib integration tests. Libuv/process/DNS behavior stays under
`spec/stdlib/` without LuaCov.
