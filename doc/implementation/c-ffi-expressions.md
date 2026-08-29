# C FFI declarations, conversions, and expressions

This chapter describes the implementation added around the existing
[`foreign import` pipeline](ffi-internals.md): source-visible tag-only
aggregates, exact C declarators, session-scoped compiler probes, contextual
object-pointer conversions, automatic C objects, typed object macros, lazy
macro-field projections, and C-mode operators. It is the implementation
counterpart of the language chapter
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

Source-nameable C selectors use the raw contextual `lexer.CNAME`, not
ordinary Titan `NAME`. It accepts the C identifier shape without rejecting a
Titan keyword and is referenced only by C member/type grammar positions.
Consequently headers may expose `when`, `repeat`, `type`, or another
Titan-only keyword without reserving an escape syntax or making that spelling
legal in ordinary Titan declarations. Named C prototype arguments retain the
separate contextual `NAMEDLABEL` path. The parser marks the corresponding
`Ast.VarDot`/`Ast.TypeQualName` with `_contextual_c_name`; the checker accepts
that marker only after proving the qualifier is a C namespace/receiver, while
the coder simply emits the stored spelling unchanged.

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
* constructor-initialized automatic locals;
* by-value casts;
* fixed-array elements;
* allocation;
* `sizeof` and `alignof`;
* aggregate field access.

Typedefs and array elements are resolved recursively. Pointers to incomplete
objects remain valid. Flexible-array-member structs are complete for
`sizeof`/`alignof` and have the dedicated scalar `T.new(count)` allocation
path; they remain ineligible for `T.new_array`.

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

The checker records the target profile's authoritative `size_t` type on each
`sizeof`/`alignof` pseudo-declaration. Code generation preserves that C result
and uses the shared checked numeric conversion before producing Titan
`integer`; it never emits an unchecked `size_t`-to-`lua_Integer` cast.

Contextual primitive type namespaces are self-contained. They and transparent
Titan aliases whose complete C graph is built from contextual primitives may
be serialized into compiled module interfaces. Namespaces derived from a
foreign import remain source-local even when an imported typedef resolves to a
portable primitive.

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
* `FLT_RADIX` plus the mantissa precision, maximum exponent/range, and
  precedence of `float`, `double`, and `long double`;
* the actual `lua_Integer` and `lua_Number` spellings/types and their
  corresponding numeric traits;
* a stable identity used in resolver-local probe cache keys.

The same effective compiler prefix and target-selecting flags used for
generated objects feed macro discovery. `TITAN_EXTRA_CFLAGS`, architecture
flags, and the configured SDK cannot describe a different target from the one
used by the profile.

`csemantics` supplies typedef/qualification-aware classification, integer
promotion, usual arithmetic conversion, bounded integer object-macro
expression evaluation, array decay, complete-object checks, and symmetric
pointer common-type rules. `numeric_trait` and the integer-range containment
query expose the same target facts to checked numeric lowering. Canonical C
scalar descriptors retain those traits as checker-local metadata; they do not
participate in structural type identity or serialized module metadata.
Unknown extension ranks/precision are rejected where a result type cannot be
proven.

## Compile probes and semantic-result caching

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
`cdriver` configuration. Rich result tables remain resolver-local and do not
survive `driver.configure_foreign_c`; a production service may additionally use
the analysis-local and persistent semantic-result caches below.

The resolver closes the service on success, reported type errors, codegen
errors, and exceptional exits. Tests inject both runner and workspace
providers to prove lifecycle and cleanup without depending on a real compiler.

### Header and toolchain fidelity

Angle headers keep their angle spelling. A source-relative quoted header is
rendered as its resolved absolute quoted path before the probe source moves
under `/tmp`. An explicit source import is the exception to exposing that physical
spelling: its generated checking header deliberately has a unique randomized
sibling name. The checker synthesizes its descriptor from the producer's
already checked real-header inputs and complete macro context instead of sending that
compiler-generated file through `cdriver`. It then replaces the physical
spelling in the probe context with a private hash-named wrapper derived from the
logical module and eventual public-header path. The probe includes the stable
wrapper name, and the wrapper includes the unique physical header by its
absolute quoted spelling. Thus nested quoted includes still begin at the
physical header's directory, while the rendered probe text and every descriptor
field used by `header_context_key` remain stable across rebuilds. When one
generated header includes another resolver-owned companion, its identity
stream replaces that randomized spelling with the dependency's public path and
stable generated identity; real byte changes still propagate into the outer
digest. One service
rejects conflicting bindings for the same wrapper identity. The forwarding
wrapper is necessarily one additional C preprocessor include level; extension
macros such as `__INCLUDE_LEVEL__` can observe that level even though ordinary
quoted-header origin is preserved.

Alias construction fails closed unless both the physical descriptor and public
identity are absolute and the physical include is quoted. The persistent cache
lookup occurs before Titan creates the probe workspace or materializes any
wrappers. On a miss, wrappers live only in that private
workspace and are removed when the resolver closes; a wrapper-write failure is
infrastructure failure and cannot publish a result. `cpreamble.fixed_includes`
supplies the same preceding standard, Lua, and Titan headers used by generated
module C. Ordered duplicate behavior within the foreign-header block, fixed
include directories, language mode, parsed compiler command, and target flags
therefore match generated compilation.

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

The preprocessor's final object-like definition set is an unordered map. When
`cdefines` projects supported definitions into the ordered TypeList, it visits
macro names with `util.bytewise_less`; ordinary Lua string ordering is
locale-dependent, and direct table traversal is randomized between processes.
This canonicalizes only map-origin macro projections, not syntactic C
source declarations, and keeps otherwise identical declaration-batch probe C
byte-for-byte stable across compiler processes.

Ordinary redeclarations are compared from their isolated TypeLists, but their
shared canonical composite is not committed until the final baseline and that
pair's compatibility probe succeed. The pure declaration relation resolves
typedefs, normalizes declaration-only qualification, adjusts array/function
parameters, and recognizes an incomplete/known array pair as compatible.
Structurally matching anonymous aggregates are only conditional candidates.
Every queued exact or conditional repeat then contributes two `extern`
declarations of one probe-private synthetic identifier. The checker constructs
dependency-safe waves in source order: only the first remaining occurrence of
one ordinary name is eligible, and a type-graph read after an earlier possible
composite write starts a later wave. Accepted composites are therefore formed
before the next dependent pair is rendered. Within one wave, identical rendered
pairs are deduplicated and every distinct pair receives its own identifier and
nested C block scope, preventing one candidate's file-scope tag from changing
another candidate. All uncached pairs in that wave share one compiler
invocation on the ordinary success path. A rejected group is recursively
bisected to recover pair-specific verdicts and diagnostics; an infrastructure
failure is neither bisected nor cached. Compiler acceptance proves that two
extracted types can form compatible declarations in that foreign-header
context; it is not evidence that both declarations occurred. After acceptance,
the merger forms any known-bound array composite in a declaration-owned deep
view. Later probes structurally expand only typedefs marked as private
declaration-owned array views, so a bound completed in an earlier wave is not
hidden again behind the source header's still-incomplete typedef spelling;
ordinary typedefs retain their source names.

There is one narrow source-provenance exception. If isolated compatibility
fails, matching preprocessor source identity, line, and column make the pair a
candidate, but are not sufficient. A recursive relation must also prove that
the complete declaration graphs are exact except for distinct canonical
objects explicitly marked as same-spelled prototype-local structs or unions;
their kind, completeness, layout, and bidirectional reuse topology must match
too. Filesystem device/inode
identity is used when available, with the resolved pathname as fallback. The
checker then queues a `source-repeat`. A successful final header baseline
canonicalizes it directly because rendering two synthetic function declarations
would invent two prototype scopes for a tag that a guarded physical declaration
emitted only once. Distinct source declarations remain nominal, macro-dependent
changes elsewhere in the type remain conflicts, and exact or conditional
repeats retain their pair probes.

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

Cache identities length-prefix every component. The unchanged toolchain key
contains the parsed compiler argv, compile flags, language mode and optional
language flag, CPP/C flags, ordered include flags and paths, target-profile
identity, compile mode, and forced-header manifest. The version-2 module header
context contains `source_dir`, that forced-header manifest, and, for every
ordered include, its original and resolved spellings, kind, name, rendered
spelling, and every dependency/search kind, path, identity, and restat flag.
Candidate semantic keys then add the
probe kind and direction, exact rendered declarations, or operator
spelling/operand conversions as applicable.

### Analysis-local and persistent semantic results

One explicit `cdriver` analysis shares completed baseline and candidate
verdicts across its short-lived resolver services, partitioned by the exact I/O
provider and unchanged toolchain key. Service-local and analysis-local tables
admit only completed baseline successes and completed candidate successes or
compiler rejections. They are indexed by the raw semantic key and are consulted
before persistent source hashing or filesystem lookup. Infrastructure failures
are always retried. A new analysis has fresh mutable result tables; only the
persistent cache described below crosses that boundary.

After a memory miss, Titan derives the same version-3 persistent digest used by
the success-only cache before #108. Its length-prefixed fields are
`persistent_success_version = 3`, the complete toolchain key, the forced-header
manifest, the semantic key, and the full probe C source. The source is included
directly in that one digest input rather than separately hashed under a new
domain. No further identity layers are applied. The raw compiler and flag
spelling already belongs to the unchanged toolchain key. The optional
`TITAN_PROBE_CACHE_IDENTITY` namespace remains the explicit caller-controlled
partition for any additional policy.

The same digest names two deliberately different representations. A successful
probe uses the existing empty `<digest>.success` marker; presence is the entire
diagnostic-free positive verdict, so old markers and their stat-only fast path
remain valid. A deterministic compiler rejection uses a bounded, checksummed
`<digest>.negative` sibling containing the key digest, ordinary nonzero child
exit status, and exact stable diagnostic bytes. Lookup checks the positive
marker before reading a negative record. Generated private source/object paths
and source-foreign checking-header aliases are normalized before a negative is
returned or persisted. A negative record with an unknown format or outcome,
invalid status, wrong key, bad checksum, truncation, trailing bytes, or
excessive size fails open as a miss.

This identity is intentionally a practical cache boundary, not a perfect model
of every input which could affect a C compiler. In particular, Titan does not
hash the compiler executable or interrogate it for a version solely for the
cache. The compilation of Titan's final generated C remains authoritative and
will report any incompatible cached assumption. The optional cache namespace
lets an embedding separate policies when desired without making speculative
partitions part of every lookup.

Outside an explicit `process_analysis`, a service validates and hashes its
forced-header input set once, and each module context validates and hashes its
deduplicated ordinary-header input set once. Every later logical probe,
positive-marker hit, and negative-record hit reuses that immutable snapshot.
With `process_analysis`, the compiler client already owns a coherent snapshot
and its publication-time validation, so the probe service performs no local
header restats. Neither mode adds a post-compiler restat: a header change which
races a single physical invocation is intentionally outside this approximate
cache boundary, and final generated-C compilation remains authoritative.

After an ordinary compiler invocation and artifact cleanup, a successful
declaration batch retains the existing batch success-marker behavior. A
rejected batch is stored under that exact historical batch source and key, then
Titan bisects it because the aggregate proves only that at least one member
failed. A cached aggregate rejection follows the same bisection path; only a
compiler-rejected singleton becomes an individual negative verdict. Baseline
rejection, spawn failure, exit 126/127, signal/interruption, malformed or
contradictory runner data, failed initial snapshot validation, workspace
failure, and cleanup failure publish no negative. Oversized diagnostics remain
valid in-memory answers but are not persisted.

Positive publication keeps the existing empty-marker write. Negative
publication uses the compiler-I/O strategy's complete-file sibling-write and
rename operation. Cache lookup, directory creation, decoding, and publication
failures never change the compiler verdict. Negative reads enforce a hard
record-size bound both before and after the file read, covering replacement
between stat and read. The optional `read_file(path, max_bytes)` strategy form
reads at most one byte beyond the bound, allowing the decoder to reject a
record which grew after its stat without allocating the replacement in full.

Within one service/analysis, publishing a completed result updates memory
without yielding and the first completed result is authoritative. A lookup
which suspends while reading a negative record checks those in-memory
authorities again after resuming, so it cannot overwrite a sibling Task's newer
answer or launch a duplicate compiler. Equal concurrent negative publishers
may both attempt the durable write. Independent processes do not take a cache
lock: each publishes a complete key-bound negative record by replacement,
readers see only a complete old or new file, and invalid/corrupt records fail
open. A failed write counts as an existing publication only when the complete
record already on disk decodes to the same rejection.

The default directory is
`<prefix>/var/cache/titan-probes/<ABI>`, using nonempty `TITAN_PREFIX` before the
supported prefix recovered from `package.cpath`. Stable local rebuilds normally
reuse that directory, which is also cached in CI. A nonempty
`TITAN_PROBE_CACHE_IDENTITY` selects a hashed subdirectory so either environment
can separate build policies without placing arbitrary text in a pathname.

Compiler specs which deliberately reuse paths for different synthetic header
worlds run with `TITAN_PROBE_CACHE_DISABLE=1`; that test-only switch leaves
production caching enabled for the preceding build. The optional identity
namespace is deliberate additional partitioning for policy outside the
unchanged key.

An embedding may give `cprobe.Service` a
`persistent_cache_trace(stage, hit, key, path)` callback. Titan invokes it once
for each enabled persistent lookup, before either the cached-semantic
return or the ordinary probe path. All arguments are scalars, the callback is
protected, and it is independent of verbose evidence: enabling cache telemetry
does not retain probe sources or commands and never prints them. The driver
adapts this to the resolver-level callback documented below.

Two optional structured observers provide terminal accounting without source
or command retention. `semantic_trace(event)` emits one logical result per
request with its digest, probe kind, header identity, semantic outcome, cache
tier (`service`, `analysis`, `persistent`, or `compiler`), repeat flag, and
publication outcome. `execution_trace(event)` emits one event per physical
compiler launch with an execution digest, single/batch kind, header identity,
outcome, persistent-lookup/publication state, and optional nonnegative child
wall time supplied by the compiler-I/O strategy. Observer exceptions are
ignored and neither stream writes to stdout.

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

Pointer conversion is an expression adjustment owned by the checker because
it needs a destination, source node, use-site diagnostic, header context, and
service. It returns a concrete coercion or written-cast plan; it is not part of
the symmetric `types.consistent` relation and cannot be lifted through a
container or callable shape.

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

For a written cast, the same table is also the
`WrittenCastPlan.conversion`; the two fields refer to the identical
probe-bearing object. The coder validates every named safe pointer operation
against its exact endpoint predicate and accepts an unrelated object-pointer
conversion only under this checked annotation. A type-only candidate or an
unsafe endpoint pair mislabeled as a safe pointer operation is an internal
plan error, not lowering authority.

The same adjustment path is used for locals, assignment, returns, direct/named
C calls, C function-pointer calls, fixed and typed C-vararg arguments, fields,
and explicit casts. A successful use-site conversion does not alter structural
gradual consistency and does not become a callable-component adjustment.

Titan records and unions are nominal GC objects, not C aggregate layouts. The
explicit GC-identity path may expose either one's rooted `Udata *` as C
`void *`, and `is` uses the corresponding non-raising identity predicate.
There is no conversion between a Titan union and `Type.CUnion` (nor between a
Titan record and `Type.CStruct`); C aggregate casts remain governed solely by
the C-type rules in this chapter.

Mutable-address call analysis unwraps the recorded cast while retaining whether
it formed an address or array decay. The direct source declaration is added to
the call's `_c_mutated_decls`, marks address-taken/assigned state, and feeds the
try-spill analysis below.

## Target-directed automatic aggregates and fixed arrays

The parser adds `Ast.TypeCArray` only to an initialized local target. A fixed
`T[N]` or uncounted `T[]` is not a general Titan type form. The old
initializer-less automatic-local production is gone; `.new()` and
`.new_array(...)` make zero initialization explicit. The ordinary mutable
local grammar may omit an RHS only for an explicit nil-bearing type; neither a
direct C aggregate nor a fixed C array is such a type, and every const local
still requires an expression list.

During `StatDecl` checking, the result-demand callback identifies a direct
allocation sink. `_plan_c_allocation` records one immutable plan on the call and
declaration. An inferred/by-value eligible struct or union `.new()` becomes
`automatic_object`; an explicit owner remains owned, and a raw pointer target
uses hidden rooted owner backing. A positive literal array count can become
`automatic_array` or `automatic_array_borrow`; dynamic/zero borrowed views use
hidden owner backing. A written fixed extent must be positive and match the
literal count. Whole-array assignment, return, and capture remain rejected.

The coder consumes only that plan. Automatic declarations emit exact C storage
with `{0}`; borrowed automatic arrays add a pointer to their separate fixed
backing. The transitive eligibility walk rejects `TValue`, `Udata *`, and other
recognized GC-bearing fields because Lua does not trace ordinary C automatic
storage. The storage has ordinary block lifetime and no escape analysis.

A FAM struct has a separate `automatic_fam` plan for a nonnegative literal
count and an owned/hidden-owner plan otherwise. Its aligned backing and logical
count provenance are described in
[Foreign-function implementation](foreign-functions.md#flexible-array-member-provenance).
The narrow automatic-to-owned coercions copy a complete aggregate/fixed-array
representation (or the complete FAM extent) into a freshly rooted owner; they
are checker-owned operations, not structural subtyping.

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

“C behavior” here includes ordinary integer promotion and usual-arithmetic
integer conversion: signed/unsigned integer results retain C semantics rather
than becoming Titan boundary checks. A trait that converts an integer operand
to a floating type is different because an out-of-range C cast would not be a
sound boundary. The coder uses the shared target-profile numeric predicate
and performs that cast only after containment is proved or checked.

Unsupported C combinations stop with C-specific diagnostics rather than
falling into Titan lowering. Bit-field operands are rejected before promotion;
an explicit cast to an ordinary integer removes the width-dependent bit-field
category.

Pointer subtraction converts the C result to Titan `integer`. Unrelated object
pointers share a qualification-union `void *` common type for equality only;
ordering requires qualification-compatible object-pointer types, while
subtraction and pointer arithmetic additionally require complete non-void
pointees. The checker records the target profile's authoritative `ptrdiff_t`
type on the subtraction trait, and the coder feeds that exact source through
the shared checked numeric conversion to `lua_Integer`.

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

## Typed object macros and field projections

`cdefines.lua` classifies supported object-like macros after recursively
expanding their replacement tokens in the importing header's preprocessor
context. The existing integer-constant path remains target-profile aware, and
the bounded best-effort expression path retains typed dereferenced accessors
such as `errno`'s `*accessor()` expansion. A second path accepts a fully
expanded replacement whose outer expression is a C cast to a supported scalar
type: integer, floating, object pointer, or function pointer. The cast target
goes through the ordinary C-type converter and becomes the foreign member's
static type.

The expansion is evidence for typing only. The member retains its public macro
name, and `codeforeignvar` emits that spelling rather than copying the expanded
tokens. The generated compiler therefore performs the authoritative expansion
under the translation unit's real header state.

A separate object-macro form contains only a dotted identifier replacement,
such as `implementation.member`. `cdriver` also retains the raw final macro
definitions plus the names actively defined, redefined, or undefined by each
header closure. Because generated C hoists all foreign includes, the symbol
table seeds one module macro environment from the first import and applies
those later mutations in source order. Field lookup expands the public token
lazily against that final environment, so a later dependency redefinition or
`#undef` cannot leave a stale projection at an earlier initializer.

When the final expansion is a pure dotted path, the checker resolves it against
the expression's actual aggregate type before physical field lookup, matching
C preprocessing precedence. The result keeps the projected physical field's
type and lvalue/mutation properties, but the coder emits the public source
spelling so the host header performs the same projection. An active
object-like macro with any unsupported final expansion is terminal; falling
back to a physical same-named field would disagree with generated C. Existing
contextual address coercion remains limited to eligible locals and does not
acquire a special subobject exception.

Field projection deliberately stops at pure identifier paths: calls, indexing,
operators, casts, and other replacement forms do not become projected fields.
That does not categorically reject every call-containing value macro: the
existing typed dereferenced-accessor form remains supported. Function-like
macros remain unavailable, while other object-like forms beyond recognized
existing integer/accessor expressions, fully expanded outer casts to supported
scalar types, and pure dotted projections are not generally supported. Macro
classification also retains the existing independent-header limitation:
declaration extraction does not inherit macro state from an earlier foreign
import, even though probes and generated C see the cumulative ordered header
block. The replayed field environment handles ordinary definitions,
redefinitions, dependency rescans, and undefinitions, but conditional
preprocessing whose result itself depends on an earlier import still belongs
behind one umbrella header. The same umbrella rule applies when a later import
changes a scalar value macro whose type was inferred in an earlier import.

## Ownership map

| Module | Owns |
| --- | --- |
| `c-parser/cpp.lua` | preprocessing, raw/prescanned macro forms, captured compiler execution |
| `c-parser/c99.lua` | preprocessing-token and C99 declaration grammar |
| `c-parser/ctypes.lua` | `TypeList`, file/prototype tag metadata and scopes |
| `c-parser/cdefines.lua` | target-neutral object-macro expression/cast metadata and lazy classification against the final raw field-macro environment |
| `titan-compiler/foreigntypes.lua` | ordered canonical C-type conversion, tag binding, target-profile macro-expression finalization, and macro cast-target conversion |
| `titan-compiler/cdeclarator.lua` | exact C declarations/type names/parameter adjustment |
| `titan-compiler/cpreamble.lua` | fixed generated/probe prefix around ordered foreign headers |
| `titan-compiler/csemantics.lua` | target profile interpretation, C categories/promotions/result types |
| `titan-compiler/cprobe.lua` | session/workspace/header contexts, baselines, candidate probes and caches |
| `titan-compiler/checker.lua` | source eligibility, contextual adjustments, lazy macro-field projection, traits, completeness and mutation analysis |
| `titan-compiler/coder.lua` | ordered lowering, public macro spelling, and volatile aggregate spills |

## Tests

Pure ownership lives in `spec/cpp_spec.lua`, `spec/ctypes_spec.lua`,
`spec/cdeclarator_spec.lua`, `spec/csemantics_spec.lua`,
`spec/cprobe_spec.lua`, and the existing `cdriver`/`foreigntypes`/`symtab`
specs. Checker-only behavior is split into topical C FFI tag, target-profile,
pointer-conversion, stack-object, and operator specs. Coder specs compile and
execute exact declarators, automatic storage, longjmp spills, pointer casts,
typed object macros, macro-projected field lvalues, and C operator results.

Real-header/tag and libuv-shaped conversions remain compiler tests rather than
stdlib integration tests. Libuv/process/DNS behavior stays under
`spec/stdlib/` without LuaCov.
