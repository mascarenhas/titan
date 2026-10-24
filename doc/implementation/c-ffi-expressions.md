# C FFI declarations, conversions, and expressions

This chapter covers the C-type and C-expression layer on top of the
[`foreign import` pipeline](ffi-internals.md): source-visible tag-only
aggregates, exact C declarators, the target arithmetic profile, session-scoped
compiler probes, contextual object-pointer conversions, target-directed C
allocation and its recovery storage, typed object macros, macro-field
projections, and C-mode operators. It is the implementation counterpart of the
language chapter [C FFI declarations and expressions](../language/c-ffi-expressions.md).

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

`ctypes.lua` uses internal keys such as `struct@Item` and
`union@Cell` for canonical file-scope aggregates. Those keys are not source
syntax and are never emitted into C. They distinguish the tag namespace from
ordinary identifiers and from real typedef spellings.

The complete `TypeList` carries two pieces of registrar metadata before
best-effort declaration conversion:

* `typedef_names[name]` records every syntactic file-scope typedef name,
  including one whose target the converter cannot support;
* `file_scope_tags[name]` records the tag kind, canonical raw key, and
  declaration/definition provenance for named file-scope
  `struct`/`union`/`enum` declarations and references.

Collecting this metadata first makes alias publication independent of
declaration order. A real `typedef Item` always reserves the Titan spelling
`foreign Item`; a tag-only fallback never shadows it merely because the tag was
converted first.

For an eligible named `struct` or `union` with no same-name real typedef, the
checker publishes the canonical `Type.CStruct`/`Type.CUnion` directly in the
synthetic `Type.CModule.type_members` table. It does not create
`Type.CTypedef("Item", ...)`, add a header declaration, or register a bare
ordinary C identifier. `cdeclarator` therefore renders the type as
`struct Item` or `union Item`, exactly as the header requires.

Anonymous aggregates and enum tags receive no source alias. An incomplete
file-scope tag does receive an alias for pointer-only use; layout sinks consult
visibility and completeness separately.

Member selectors, named argument labels, and foreign type names use
`lexer.ANYNAME`, which accepts keyword spellings such as `when`, `repeat`, and
`type`. The same token serves the ordinary Titan grammar positions that admit
keyword names. A keyword-spelled member of a qualified type name is marked
`_contextual_c_name` by `defs.qualifiedtype` (`parser.lua`);
`checker/type_syntax.lua` rejects that name unless the qualifier is a C module
("Titan keyword '%s' is only contextual for a C type"), and
`checker/variables.lua` applies the same rule to dotted access on a non-C
receiver. Otherwise the checker resolves the receiver or type namespace
normally, and the coder emits the accepted C member spelling unchanged.

### One tag namespace per C scope

C shares one tag namespace among `struct`, `union`, and `enum` within a scope.
The registrar sees the complete ordered module header translation unit. Include
guards and macro state determine which declarations enter that unit; different
kind reuse is diagnosed in its actual C scope. Same-kind declarations reuse one
canonical `Type.CStruct`/`Type.CUnion`, and a definition completes that owner.

A parameter declaration can introduce a prototype-local tag. `ctypes.lua`
retains the prototype scope identity and binds a reference to an already visible
file-scope tag when appropriate. A later file-scope tag stays distinct from an
earlier prototype-local tag. Aggregate-member callback declarators likewise
retain their own prototype scopes. The checker does not reconcile independent
header snapshots or equate these tags by spelling.

### Complete-object sinks

The module's complete C environment is established before module-variable
initializers, signatures, and bodies are checked. A definition from any of its
ordered headers is therefore available throughout `ffi`; ordinary Titan import
aliases and variables retain their existing initializer frontiers.

The checker centralizes the complete-C-object predicate and applies it wherever
layout is required: by-value parameters/results/locals/casts, automatic object
construction, fixed-array elements, allocation, `sizeof`/`alignof`, and aggregate
field access. Typedefs and array elements are resolved recursively. Pointers to
incomplete objects remain valid. Flexible-array-member structs are complete for
`sizeof`/`alignof` and have the dedicated scalar `foreign T.new(count)` allocation path;
they remain ineligible for `T.new_array`.

### Separate type/value lookup

`Type.CModule` retains `members` and `type_members` for the imported C graph.
`Ast.TypeForeignName` selects primitive, imported, or authored foreign typedef
names independently of lexical term lookup. Ordinary `Ast.TypeName` and
`Ast.TypeQualName` resolve only the Titan type namespace.

`Ast.ExpForeignType(type)` is the receiver for the dedicated
`foreign T.new()`, `.new_array(n)`, `.sizeof`, and `.alignof` expressions.
The checker exposes a syntax-bound pseudo declaration only for these
operations; ordinary `ffi.member` lookup never manufactures a type namespace.
Thus `ffi.stat(...)` and `foreign stat.new()` coexist without parent-sensitive
collision resolution. Real aggregate fields named `new` remain fields.

The target profile's authoritative `size_t` type stays on each layout
pseudo-declaration. Code generation uses the shared checked numeric conversion
before producing Titan `integer`; restricted foreign bodies retain native
`size_t` directly.

Portable primitive/pointer/callback graphs can occur directly in compiled
Titan signatures. Authored foreign aliases are actual header typedefs and stay
source-only, just like imported header typedefs. Titan owned aliases use
`Ast.TypeOwned` and keep their normal public embedded-type eligibility checks.

## Exact C declarators

`titan-compiler/cdeclarator.lua` is the single renderer for C declarations,
type names, and parameter adjustment:

```text
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

`cdriver.target_profile_inputs` acquires the configured compiler's predefined
macros and the active prefix's `lua_Integer`, `lua_Number`, `size_t` and
`ptrdiff_t` spellings; `csemantics.build_profile` turns them into one profile,
which is injected into `cprobe.Service`. The direct-checker fallback performs
the same acquisition before constructing its private service. The service
validates and owns a copy for target-C reasoning. It records:

* `CHAR_BIT`, primitive storage widths, signedness, rank, precision, minima,
  and maxima;
* `FLT_RADIX` plus the mantissa precision, maximum exponent/range, and
  precedence of `float`, `double`, and `long double`;
* the actual `lua_Integer` and `lua_Number` spellings/types and their
  corresponding numeric traits.

The same effective compiler prefix and target-selecting flags used for
generated objects feed macro discovery. `TITAN_EXTRA_CFLAGS`, architecture
flags, and the configured SDK cannot describe a different target from the one
used by the profile.

Completed header entries preserve only the predefined names consumed by the
profile builder and their direct alias dependencies. Replacement strings and
function-like rejection markers suffice for that interpretation; unrelated
macros and token sidecars remain outside the profile facts. The configured
carrier typedefs and signed-minimum expressions retain their original types
and exact integer token spellings.

`csemantics` supplies typedef/qualification-aware classification, integer
promotion, usual arithmetic conversion, bounded integer object-macro
expression evaluation, array decay, complete-object checks, and symmetric
pointer common-type rules. `coder._numeric_trait` (`coder/numerics.lua`) and
the integer-range containment query expose the same target facts to checked
numeric lowering. Canonical C scalar descriptors retain those traits as
checker-local metadata; they do not participate in structural type identity
or serialized module metadata. Unknown extension ranks or precision are
rejected where a result type cannot be proven.

## Compile probes and semantic-result caching

### Ownership and lifetime

`titan-compiler/cprobe.lua` owns compile-only target validation. One lazily
created `Service` belongs to the resolver for a complete public `titanc`
invocation, including source dependencies. It contains the effective compiler
argv, language/compile/CPP flags, ordered include directories, target profile,
runner, private workspace, source-result cache, and verbose state.

Each checked Titan module obtains a `ModuleContext` for its generated
`A.ffi.h`. That descriptor carries the ordered explicit-source dependency
headers followed by the module's direct foreign directives. Candidate probes
use this combined environment for the current consumer.

`titanc`, the filesystem loader, table loader, and child compiler paths thread
the service through `checker.check`. A direct external `checker.check` without
an injected service creates and closes a fresh one using the current
checker configuration. Embeddings must supply explicit `compiler_include_dirs`
(or a toolchain's `include_dirs`); the C parser and probe service do not discover
an SDK by walking up from their Lua modules. Driver-backed helpers use
`driver.foreign_include_dirs()` so preprocessing and compilation select the
same configured installation. An explicit empty array means no fixed SDK roots.
Rich result tables remain resolver-local and do not
survive `driver.configure_foreign_c`; a production service may additionally use
the analysis-local and persistent semantic-result caches below.

The resolver closes the service on success, reported type errors, codegen
errors, and exceptional exits. Tests inject both runner and workspace
providers to prove lifecycle and cleanup without depending on a real compiler.

### Header and toolchain fidelity

`titan-compiler/ffiheaders.lua` renders each module's `A.ffi.h` with explicit
source dependencies first and local foreign directives afterward. Folder
modules use the canonical main's directives followed by contributors in
bytewise filename order. The C driver preprocesses and parses that actual
header once. Include guards, macro definitions and undefinitions, ordinary
redeclarations, and C tag scopes therefore act on one ordered translation unit.

Quoted author headers are resolved relative to the canonical Titan source
directory and retain their absolute quoted spelling. Nested quoted includes
then begin at the physical author header's directory. Angle headers keep their
angle spelling. Recursive checking materializes a validated, deterministic
logical tree of actual generated `.ffi.h` files; probes use that same tree.
There is no forwarding include, symlink, or independently reconstructed
per-type origin list.

`cpreamble.fixed_includes` supplies the preceding standard, Lua, and Titan
headers used by probes and generated module C. The C driver's declaration parse
starts at `A.ffi.h`; it does not synthesize that runtime prefix. Include
directories, language mode, parsed compiler command, and target flags are shared
with generated compilation. They configure execution without adding separate
probe-cache identity beyond the literal text emitted into the probe.

SDK staging waits for its native header producers. Bundled OpenSSL's public
include directory combines ordinary source headers with generated configured
headers; copying only its build directory loses required public includes.
The default system OpenSSL mode removes only that bundled directory on
reinstall. The SDK always installs the public libuv, llhttp, and SQLite headers.

Each uncached candidate first validates its baseline translation unit. The
checker also validates the module's combined C environment after extraction,
so the configured C compiler rejects invalid declarations that the best-effort
parser may have accepted. A completed rejection makes the header context
invalid. Spawn, interruption, workspace, object-read, and cleanup failures are
infrastructure failures and supply no semantic verdict. Ordinary declaration
compatibility follows the combined parse and the actual C compiler; no
per-header pair probes or source-provenance exception reconcile snapshots.

The final object-like macro definition set is an unordered map. `cdefines`
projects its supported members into the TypeList in `util.bytewise_less` order.
This canonicalizes map-origin projections without changing syntactic C source
order. Macro state from an earlier header participates directly in later
conditional preprocessing and declaration extraction.

### Analysis-local and persistent semantic results

The cache is source-to-result memoization. Render the complete C probe, then
compute `SHA256(source)` over those exact bytes before preprocessing. That
same digest indexes service-local memory, analysis-local memory, and disk.
Literal include directives participate; the included files' contents do not.
The generated header tree's digest appears as a comment in the raw probe
source beside its stable logical include path, so a changed generated bundle
changes that source. Author
header content is still outside this source-only key. Compiler commands, flags, target profiles, source-directory metadata, and
semantic descriptors do not add anything to the key. Generated helper names
must likewise be independent of those external inputs.

A result records acceptance or a completed compiler rejection with its exit
status and stable diagnostics. A baseline is an ordinary source-keyed probe and
uses the same result path as a candidate. Each uncached candidate is compiled
individually, so a rejection already belongs to the exact question asked.
Infrastructure failures, including unavailable or interrupted compilers,
workspace failures, and cleanup failures, remain retryable.

The persistent directory is `<prefix>/var/cache/titan-probes/<VERSION>`
(`cprobe_cache.VERSION`, currently 2; `driver.PROBE_CACHE_DIRECTORY`). The
prefix is an absolute `TITAN_PREFIX`, otherwise `driver.TITAN_ROOT`, the
installation recovered from `package.cpath`. Each source has one bounded record
at `<digest>.result` for either outcome. An accepted enum-carrier query also
stores its typed selection result: match count and carrier identifier (the
identifier sum when several match).
Readers reject malformed, truncated, trailing, oversized, or impossible typed
results and treat cache I/O failures as misses. Private source/object paths in diagnostics
are normalized before storing or returning them. Oversized diagnostics may be
reused in memory but are not persisted.

Both outcomes are published by complete-file replacement. Publication failure
does not change the compiler verdict. Within one service or analysis, the
first completed result for a source wins; a lookup that yields rechecks memory
before using a disk result or launching a compiler. Independent processes need
no cache lock because readers see complete records and invalid data is a miss.

The cache deliberately does not detect changes to headers or compiler policy.
A programmer who suspects stale acceptance or rejection clears the directory
or uses `TITAN_PROBE_CACHE_DISABLE=1` to bypass persistent reuse. Final generated
C is compiled normally. Header preprocessing and analysis snapshot validation
retain their own dependency tracking independently of this result cache.
Service-local and analysis-local memory remain enabled when persistent reuse
is disabled. Compiler specs that reuse header pathnames for different fixtures
disable persistent reuse for this reason.

An embedding may give `cprobe.Service` a
`persistent_cache_trace(stage, hit, key, path, module_name)` callback. Titan
invokes it once for each enabled persistent lookup, before either the
cached-semantic return or the ordinary probe path. All arguments are scalars,
the callback is protected, and it is independent of verbose evidence: enabling
cache telemetry does not retain probe sources or commands and never prints
them. The driver adapts it to the resolver-level `c_probe_cache_trace`
callback (`driver.lua`).

Two optional structured observers provide terminal accounting without source
or command retention. `semantic_trace(event)` emits one logical result per
request with its source digest, probe kind, header label, semantic outcome, cache
tier (`service`, `analysis`, `persistent`, or `compiler`), repeat flag, and
publication outcome. `execution_trace(event)` emits one event per physical
compiler launch with its source digest, probe kind, header label,
outcome, persistent-lookup/publication state, `batch_kind` (`single` for a
synchronous launch, `speculative` for a flushed batch member), and optional
nonnegative child wall time supplied by the compiler-I/O strategy. Observer
exceptions are ignored and neither stream writes to stdout. A batch member's
semantic event is emitted when its batch flushes, in request order.

The default workspace provider (`default_temp_provider` in `cprobe.lua`)
reserves a private directory through the compiler I/O strategy's `tmpname`,
writes deterministic collision-free sources, and invokes a non-linking compiler
mode. Production uses `-c source.c -o private.o`; an explicitly configured and
separately established service may opt into `-fsyntax-only`.
Arguments are already parsed and individually shell-quoted; `LANG=C` and
`LC_ALL=C` make diagnostics stable. Missing/interrupted compilers are
infrastructure failures. Candidate source/object/diagnostic artifacts are
removed after each run and the directory is removed on every close path.

Ordinary diagnostics show the first useful compiler line. Verbose mode also
prints the full command, source, cache result, status, and captured diagnostic.

### Speculative batched acceptance probes

Most probe misses only accept or reject a construct whose Titan result the
checker already computed. During `checkbodies`, a check whose resolver allows
batching defers those misses into one `ProbeBatch` per checker invocation
and continues as if the probe had passed. The batch is flushed at the
checker's body barrier ([Checker](checker.md#speculative-probe-barrier-and-authoritative-recheck)).

Eligibility is per call site. `c_operator` (`checker/calls.lua`
`finish_c_operator`) and `unsafe_object_pointer`
(`checker/type_syntax.lua` `_unsafe_c_pointer_conversion`) consume only
acceptance and the source key, so their kinds are deferrable. The two
extent validations, the automatic FAM extent and the fixed nominal C array
extent in `checker/c_types.lua`, opt in with
`validate_declaration_compatibilities(candidates, { deferrable = true })`.
Enum-carrier selection and the enumerator range check inside the enum-support
sequence choose checker state and stay synchronous, as do baselines,
target-profile acquisition and every probe made during top-level checking.

`Service:_run_source` defers only after the unchanged synchronous steps:
render and hash the complete source at the call site from the context's
immutable preamble and generated-header descriptor; look up memory, analysis
and disk results; and, for a candidate miss, validate the context baseline.
A hit or a failed baseline therefore returns exactly as before. A deferred
request keeps its rendered source, key, cache path, kind and context; it is
never rendered again. A repeated key while pending is a duplicate of the
same request, separate from the completed `result_cache`, and observes the
same memory-hit verbose event as the synchronous path. The call receives a
success result carrying the real key.

`ProbeBatch:flush` prepares each unique request with the synchronous path's
`_prepare_execution` (workspace or staged generated-header workspace,
numbered names, written source, argv), passes all argv arrays to the I/O
strategy's optional `run_batch(commands, { jobs = N })`, and finishes each with
`_finish_execution`: runner-result normalization, private-path diagnostic
normalization and per-probe artifact removal. `_publish_result` then stores
only real success and compiler rejection in memory, analysis and disk tiers.
Assumed success, infrastructure failures, malformed results and
cancellation are never published. A result container that is not a table
answers no command: every prepared probe still finishes, as an
infrastructure failure. An error raised during preparation or by
`run_batch` itself, such as a strategy cancellation, removes every prepared
probe's artifacts and is then rethrown unchanged. Staged generated headers
belong to the service until `Service:close`, so they outlive every reaped
child.

Every executed run that was not published, including synchronous baselines
and enum queries of the same pass, is retained in `ProbeBatch.outcomes` in the
order the pass observed it. When a flush reports a failure the checker
rechecks with a batch whose `answers` are those outcomes. The recheck's
`_run_source` replays them before any cache lookup: each recorded run of a
source answers exactly one request of that source, in the recorded order,
and needs no new baseline because it had already passed one. Once a source's
recorded runs are used up the request looks up memory and disk and, on a
miss, launches the compiler, exactly as the synchronous path retries a
failed run. A failed run that preceded a success the speculative pass
published later therefore still reports its failure at its own use; a use
that pending deduplication folded into one deferred run retries like its
synchronous counterpart; and a completed verdict is never compiled twice.

Batching requires `Service:batching()`: the runner is the I/O strategy
itself, the service `jobs` cap is above one, and the strategy provides
`run_batch`. The stock `run_batch` of `compiler_io.new_sync()`, implemented
over the shared native scheduler in `jobs.lua`, launches its own processes,
so it counts only while the strategy's resolved `run` is the stock one too.
The driver's output-root wrapper, which overrides only `tmpname`, therefore
still batches, while a strategy that overrides `run` on its instance or
behind its metatable keeps its synchronous runner calls, cancellation and
answers unless it also supplies its own `run_batch`. Strategies without it,
injected custom runners, `jobs = 1`, analysis and completion checks keep
calling the runner synchronously. No API-1 strategy method is required.

`run_batch` reaps every launched child and returns its borrowed tokens on
every exit ([Driver](driver.md#parallel-generated-c-compilation)). A caught
INT/TERM/HUP comes back to `flush` as a signal number. After per-probe cleanup
the flush records it on the service and raises
`C probe batch interrupted by signal N`, so checking never continues under a
returning signal handler. The check unwinds to the service's owner:
`driver.close_resolver_context` closes the resolver's C header bundle and
then the service, whose `Service:close` removes its workspaces and staged
headers and only then delivers the signal with `jobs.propagate`. `titanc`
closes its resolver from a to-be-closed variable on that unwinding error, so
a terminating signal ends the process only after its probe and header
temporaries are gone.

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

Exact pointer-local output parameters use the existing `mutable_c_address`
plan before unsafe reinterpretation. Its endpoint check compares the local's
complete pointer type with the target's pointee, including nested qualifiers;
`const char *` storage can become `const char **` without qualifier loss. This
does not turn pointer-to-`void *` into address-taking. The checker marks the
local as assigned/address-taken and rejects an exact output-storage request
from a const or captured binding or a temporary. Both ordinary and raw-foreign
lowering emit the address of the original local, never the address of a copied
argument temporary.
Written pointer casts bypass this address selection and retain the existing
pointer-value conversion. Mutation analysis follows the actual address plan,
so an explicit `raw as foreign *(*void)` does not mark `raw` as mutated by the callee.

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

`Ast.TypeCArray` represents unsized foreign arrays. At a direct initialized
local sink, `foreign T[]` is an uncounted borrowed pointer view. There is no
written `T[N]` source form, and aggregates, fixed arrays and const locals still
require an initializer. Foreign function bodies reject `.new` and `.new_array`
(`checker._validate_foreign_body_node`) because they have no Lua allocation or
root context.

### Selection at the direct declaration sink

`Checker.CPseudoNew`, built by `c_pseudo_member` (`checker/c_types.lua`), is a
syntax-bound callee descriptor, not a `Type.Function`. While `StatDecl` checks
its expression list, the result-demand callback attaches the destination
declaration as `allocation_decl` (`checker/statements.lua`).
`checker._plan_c_allocation` then freezes one `kind = "c_allocation"` plan
(`payload_type`, `result_type`, `storage`, `array`, `fam`, `count_expression`,
`array_count_literal` or `fam_count_literal`, `fam_field`) on the call and, for
automatic or hidden-owner storage, on the declaration as `_c_allocation_plan`.
An allocation passed directly to a nominal constructor is planned by
`plan_nominal_c_allocation` instead; see [nominal storage](nominal-storage.md).

Planning happens before inference and sink coercion. Code generation switches
only on the recorded plan and never rediscovers stack versus owner storage from
endpoint types. A module initializer, return, argument, assignment to an
existing variable, nested expression, or discarded call has no direct
declaration sink and keeps the ordinary owned result.

For a complete, eligible struct or union `T`, `.new()` selects:

| Direct local sink | Plan/result |
| --- | --- |
| inferred, or explicitly `T` | `automatic_object`, a zeroed C `T` local |
| `owned *T` | `owned`, a zeroed Lua userdata owner |
| compatible `foreign *T` | `owned_borrow`, a pointer into a hidden owner rooted for the generated frame |
| any non-direct-local context | ordinary `owned *T` |

For a non-FAM element type `T`, `.new_array(count)` selects:

| Direct local sink/count | Plan/result |
| --- | --- |
| inferred, positive integer literal or eligible integer macro `N` | `automatic_array`, zeroed `T[N]` |
| written `foreign T[]` or `foreign *T`, positive literal or eligible macro | `automatic_array_borrow`, pointer over zeroed `T[N]` backing |
| written `foreign T[]` or `foreign *T`, dynamic or zero count | `owned_borrow`, pointer into hidden counted-owner backing |
| written `owned T[]` | `owned` for every count |
| inferred dynamic/zero count or non-direct-local context | ordinary `owned T[]` |

Automatic selection is aggregate-specific; a scalar, pointer, or enum
pseudo-allocation never becomes an automatic scalar. Completeness, nested-owner
and transitive GC-bearing-storage checks (`types.c_automatic_gc_bearing`) are
closed eligibility gates: `TValue`, `Udata *` and other recognized GC-bearing
fields are rejected because Lua does not trace C automatic storage. A C array
typedef cannot become owned storage or use `.new()`, but positive-literal
`.new_array(N)` may use it as an element when the sink selects nested fixed
automatic storage. Whole-array assignment, return and capture remain rejected,
and there is no automatic-allocation size threshold.

A constant count is an integer literal AST or a proven object-like integer
macro. `foreigntypes.convert` retains a successfully evaluated macro's exact
target-profile decimal value as the namespace member's `_c_integer_constant`,
and the converted-foreign cache preserves it. Values outside the supported
extent representation are rejected; macros that denote C variables carry no
constant. There is no host arithmetic evaluation or general constant folder,
and Titan bindings never qualify.

Lifetimes: automatic storage has ordinary block lifetime and no escape
analysis, so a pointer to it can dangle after its block. A pointer into a hidden
owner loses ownership when the generated frame stops rooting the owner. The
borrowed `foreign T[]` view lowers to a raw pointer, so `#` and counted bounds
checks are unavailable through it.

`coder._codeautomaticallocationdecl` (`coder/statements.lua`) emits real
declaration-owned storage rather than an expression temporary: `{0}` for an
object or fixed array, a separate fixed backing plus one pointer-view
declaration for `automatic_array_borrow`, and the aligned union backing below
for a FAM. This keeps address-taking, C out-parameter mutation, block lifetime,
defer-tail predeclaration, and try-spill analysis attached to the actual
`Ast.Decl`. For `automatic_array_borrow` the emitter owns both declarations, so
generic local lowering must not redeclare the view; defer-tail predeclaration
places backing and view together in the enclosing cleanup scope and suppresses
both at the original statement.

### Flexible-array-member provenance

For a complete `struct T` whose final field is a flexible array member
`E field[]`, `c_pseudo_member` gives `.new` a one-count arity and makes
`.new_array` unavailable. A literal nonnegative count at an inferred or by-value
direct local selects `automatic_fam`; an explicit owner, explicit `foreign *T`,
dynamic count, or non-local expression selects one owner (with a borrowed
pointer for the raw-pointer sink).

The target C compiler remains the layout authority. Both paths use the exact
extent

```text
max(sizeof(T), offsetof(T, field) + count * sizeof(E))
```

and zero all of it. Before recording `automatic_fam`,
`checker._validate_automatic_fam_extent` asks the configured C probe context to
prove `count <= (((size_t)-1 - offsetof(T, field)) / sizeof(E))`, so the literal
bounds provenance and the generated backing extent agree without host layout
guesses. The automatic form is a union containing `T` for alignment and an
unsigned-byte member of the complete constant extent. The owned form evaluates
the count once, rejects a negative value, checks addition and multiplication
overflow, allocates exactly that many payload bytes, and stores the logical
count in one private integer user value. `Udata.len` stays the byte extent, so
padding is never mistaken for an element count.

Field checking attaches `_c_fam_access` (`checker/variables.lua`) only while
allocation provenance is present. Direct `owner.field[i]` and
`automatic.field[i]` are 0-based and use the stored or literal count for bounds
and `#field`. Converting either object to a raw `T *` erases that annotation:
the unsized field then has no recoverable length or count-aware index path.
Titan does not model a collection of variably extended `T` objects.

### Copies to owners

`types.coercion` has two narrow directional operations: `c_automatic_to_owned`
for a matching struct or union and `c_automatic_array_to_owned` for a matching
fixed array. `coder/values.lua` validates the exact plan; `coder/calls.lua`
materializes the source once, allocates and stack-roots the owner, copies the
complete object representation, and only then publishes the owner. A FAM source
is recognized from its declaration plan, so the copy uses the full extended
backing and reproduces the logical-count user value. These are allocating
direct coercions, not structural subtyping or lifted conversions.

### Longjmp-safe aggregate spills

`try`/`catch` uses C `setjmp`/`longjmp`, so an automatic object modified after
`setjmp` is indeterminate after recovery unless it is read from volatile
storage. The spill analysis, GC-slot reloads and the volatile home for
address-exposed scalars are documented in
[setjmp-sensitive local/parameter spills](error-handling.md#setjmp-sensitive-localparameter-spills).
This section covers the C-storage specifics.

The write analysis traces C field and index lvalues to their root declaration,
consumes `_c_mutated_decls` from mutable foreign calls, and adds
`coder._titan_call_aggregate_out_decls` for ordinary Titan calls: every
automatic aggregate or fixed array whose contextual mutable address (implicit
or written `as` address cast, or decay to a non-const pointer parameter) is
passed directly as an argument. A marked non-GC aggregate or fixed array gets
a volatile byte spill (`spill_decl_init`/`spill_decl_zero` in
`coder/flow.lua`):

```c
unsigned char volatile _spill_local_x[sizeof(_local_x)];
```

`coder._aggregate_spill_copy` copies the object representation with explicit
byte loops, preserving volatile accesses rather than casting volatility away
through `memcpy`. It commits:

- after zero initialization;
- after whole-object, field, and element writes;
- after a mutable foreign call returns normally;
- after an ordinary Titan call that received its mutable address returns
  normally (`codecall` in `coder/calls.lua`). A call that passes no tracked
  aggregate address emits no commit.

Recovery reloads the last committed bytes before Titan reads the object. An
automatic FAM's `_c_backing_storage` supplies the address and byte extent of
the complete extended backing.

Boundaries of the guarantee:

- A call that mutates an aggregate and then exits nonlocally commits no partial
  bytes.
- Mutation through an untracked raw alias, or asynchronously from C, is outside
  the guarantee.
- Storage reached only through a pointer local is never spilled or restored:
  the walk stops at the first pointer, so reads after recovery observe current
  memory. Code that lets C commit state during a protected region (for example a
  native registrar writing a wait cell) therefore holds that cell as automatic
  storage plus a pointer local instead of rolling its bytes back.
- Address escape alone does not exempt a non-volatile automatic object from
  ISO C's `setjmp` rule.
- An `automatic_array_borrow` declaration preserves only its pointer value
  under the scalar rules (an ordinary scalar spill, or the volatile home when
  its mutable address is exposed); its backing bytes are never snapshotted.
  Writes through the pointer stay in the live backing, and capturing the
  pointer does not extend the backing's lifetime.
- Foreign function bodies have no spill protocol, because they cannot
  establish a Titan recovery boundary.

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

The hand-written preprocessor maintains raw and prescanned macro arguments
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
spelling lives only in the side metadata, so a digraph is never duplicated as
raw and canonical tokens.

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
such as `implementation.member`. `cdefines.classify_expanded_field_macro`
classifies every final object macro after the combined module header has been
preprocessed and stores the result in `TypeList.field_macro_classes`. Field lookup uses the
saved pure path or unsupported marker and expanded spelling. A later header
redefinition or `#undef` has already affected this final classification, so it
cannot leave a stale projection at an earlier initializer. Empty object macros
remain terminal unsupported tokens; function-like and undefined macros leave
ordinary field lookup available. No raw macro environment is needed at lookup.

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
classification uses the same final macro environment as combined declaration
extraction. A header may establish macro state used by a later directive, and a
later definition, redefinition, or undefinition controls the final supported
macro binding throughout the module.

## Enum carrier selection

One compiler query selects a carrier for an exact enum use surface. The checker
first filters the eleven ordinary C integer candidates by complete-range
containment in the target `lua_Integer`. The query declares that exact enum
object once and applies `__builtin_types_compatible_p` to its pointer type and
each eligible primitive pointer type, preserving pointee qualification.

The query emits a used, byte-aligned 12-byte constant payload in `.titan.cprobe`
(ELF/COFF) or `__DATA,__titancprobe` (Mach-O): the eight magic bytes
`TITENUM\0`, version 1, payload length 12, match count, and carrier identifier
sum (`render_enum_selection_source` and `decode_enum_selection_object` in
`cprobe.lua`). This is an object-producing
compile; it does not link or execute target code. The shared bounded object
reader locates one initialized, uncompressed, relocation-free section and
rejects objects larger than 16 MiB before reading them. Invalid or missing
payloads are retryable infrastructure failures and are not cached. Clang marks
only this inert serialized array `no_sanitize("address")` to prevent ASan global
redzones from changing its exact size; runtime instrumentation remains enabled.

Exactly one match selects its carrier. Zero and multiple matches are valid
completed query answers and yield the checker's unsupported/ambiguous carrier
diagnostic. Cache answers are checked against the exact eligible candidate set
before reuse. Stable IDs are `char`, `signed char`, `unsigned char`, `short`,
`unsigned short`, `int`, `unsigned int`, `long`, `unsigned long`, `long long`,
and `unsigned long long`, numbered 1 through 11. Independent enumerator value
range validation remains unchanged; `__int128` is not a candidate.

## Ownership map

| Module | Owns |
| --- | --- |
| `c-parser/cpp.lua` | preprocessing, raw/prescanned macro forms, captured compiler execution |
| `c-parser/c99.lua` | preprocessing-token and C99 declaration grammar |
| `c-parser/ctypes.lua` | `TypeList`, file/prototype tag metadata and scopes |
| `c-parser/cdefines.lua` | target-neutral object-macro expression/cast metadata and extracted classification of final field macros |
| `titan-compiler/cdefinitioncache.lua` | closed header/FFI declaration projection and reconstruction without parser/CPP state |
| `titan-compiler/foreigntypes.lua` | ordered canonical C-type conversion, tag binding, target-profile macro-expression finalization, and macro cast-target conversion |
| `titan-compiler/cdeclarator.lua` | exact C declarations/type names/parameter adjustment |
| `titan-compiler/ffiheaders.lua` | deterministic module `.ffi.h` descriptors and physical checking trees |
| `titan-compiler/cpreamble.lua` | fixed generated/probe prefix around the module C environment |
| `titan-compiler/csemantics.lua` | target profile interpretation, C categories/promotions/result types |
| `titan-compiler/cprobe.lua` | session/workspace/header contexts, baselines, candidate probes and caches |
| `titan-compiler/checker/` (`c_types.lua`, `type_syntax.lua`, `variables.lua`, `expressions.lua`) | source eligibility, contextual adjustments, allocation plans, lazy macro-field projection, traits, completeness and mutation analysis |
| `titan-compiler/coder/` (`calls.lua`, `expressions.lua`, `statements.lua`, `flow.lua`, `numerics.lua`) | ordered lowering, public macro spelling, automatic storage, and volatile aggregate spills |

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
