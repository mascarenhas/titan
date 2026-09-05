# Foreign-function implementation

Titan-written `foreign function` declarations are plain C-ABI entry points
implemented in Titan source. They reuse the imported-C type graph and the
configured target profile, but they do **not** reuse the ordinary Titan
function ABI. This chapter follows the feature from parser and source
collaboration through raw-C lowering and generated headers. It also records the
target-directed allocation work and callback ownership in the current ABI.

For the source contract, see [Foreign functions](../language/foreign-functions.md).
The imported-header pipeline and ordinary FFI boundary remain documented in
[FFI internals](ffi-internals.md) and
[C FFI declarations and expressions](c-ffi-expressions.md).

## Phase map

The feature deliberately adds source forms without adding another semantic
callable representation:

| Source/compiler form | Checked representation | Generated representation |
| --- | --- | --- |
| `foreign (P...) -> R` | `Type.CPointer(Type.CFunction(P, R, false, false))` | an exact C function-pointer declarator |
| `foreign function f(P...): R ... end` | `Type.CFunction(P, R, false, false)` on `Ast.TopLevelForeignFunc` | one plain C function, inline in the generated header or hidden out of line |
| a direct reference to `f` | a declaration designator, not a value | the bare generated C name |
| an exactly typed pointer context | C declaration-to-pointer decay | the same bare generated C name |

There is no foreign closure, Lua-stack entry, strict entry, module user-value
slot, function tag, capture list, traceback-name registration, or serialized
callable descriptor. `Type.Function` continues to mean the boxed Titan/Lua
callable protocol; `Type.CFunction` continues to mean a direct C declaration.

## Parser and AST

`foreign` was already a reserved token for `foreign import`. The top-level
grammar now tries `foreignfunc` before an ordinary function declaration:

```text
FOREIGN FUNCTION NAME "(" paramlist ")" rettypeopt block END
```

It constructs
`Ast.TopLevelForeignFunc(loc, name, params, rettypes, flexrettype, block)`.
Keeping a distinct tag prevents visitors from accidentally assigning `_mod`,
`_fn`, closure, or Lua-entry semantics merely because the surface body resembles
an ordinary function.

The type grammar also tries `foreignfunctype` before the ordinary arrow forms:

```text
FOREIGN typelist RARROW rettype
```

and constructs
`Ast.TypeForeignFunction(loc, argtypes, rettypes, varargtype, flexrettype)`.
The parser preserves input and result tails in the AST so the checker can issue
the foreign-specific rejection; it does not silently discard them. The checker
then lowers the admitted fixed shape to the existing C pointer/function types.

The allocation part of the wrap-up changes local-declaration grammar too.
`Ast.TypeCArray` is now accepted only as an initialized local target:

```titan
local fixed: c.Item[4] = c.Item.new_array(4)
local view: c.Item[] = c.Item.new_array(count)
```

Its `length` is an `Ast.ExpInteger` for the fixed form and `false` for the
unsized form. The latter is a target spelling, not a C incomplete-array local;
the checker lowers it to `Type.CPointer(element)`. Neither form enters the
general type grammar. The old special initializer-less C-array production is
gone, so either form follows the initialized `local ... = ...` AST shape. The
general parser separately admits an omitted RHS for mutable locals with an
explicit nil-bearing type, but a restricted foreign-function body rejects that
form and every const local requires an expression list.

As with every new `_tag`, the checker visitors, top-level duplicate/name passes,
source-interface builder, coder traversal, and AST debugging paths explicitly
handle both foreign tags. The foreign declaration participates in ordinary
top-level duplicate precedence, but not in ordinary module-member publication.

## Signature collection and the raw-C checking context

### Signature construction

Foreign signatures are collected in the callable-signature pass, alongside
ordinary top-level functions but before bodies. `_foreign_function_signature`
uses `typefromnode` and accepts only direct declarable C FFI components:

* parameters cannot be `void`, owners, arrays, direct functions, C modules, or
  Titan values;
* the result is either absent (`Type.CVoid`) or one non-void direct C type;
* complete structs and unions may travel by value, while incomplete objects are
  accepted only behind pointers; and
* input variadics, multiple results, and flexible result tails are diagnosed.

The declaration receives its `Type.CFunction`, `_foreign_module`, and dense
`_paramnames`. `Ast.TypeForeignFunction` goes through the same helper and wraps
the result in `Type.CPointer`. Direct calls therefore reuse the existing
`Checker.CallSignature` view for C functions: exact C arity, at most one result,
no Titan nil fill or surplus adjustment, and declaration-only named arguments.
Declaration decay compares the complete target function-pointer type with
`types.c_function_types_equal`; there is no structural conversion from a
`Type.Function`.

### One checker, a restricted context

The implementation reuses ordinary expression and statement checking under a
closed mode rather than maintaining a second type checker. `checkfuncbody` is
called with `{ foreign = true }` and increments
`checker._foreign_function_depth` while checking the body. In that mode it:

* does not synthesize the built-in `L` and `M` locals;
* does not annotate Lua argument/result boundary plans;
* gives literals raw target C types (`_Bool`, target `int`, `double`,
  `const char *`, and contextual `NULL`);
* requires conditions to be C scalars;
* requires numeric-for controls, limits, and steps to share a C integer or
  floating type; and
* permits only parameters/locals, current-module foreign declarations, C
  namespaces, and foreign members reached through an explicit source import.

`checkvar` rejects an ordinary top-level Titan declaration in this mode, and a
qualified Titan-module lookup is accepted only when
`_foreign_function_reference` identifies a source foreign member. An imported
C namespace remains usable because its functions, values, fields, types,
`sizeof`, and `alignof` are already direct C declarations. A producer's
`foreign import` alias is not copied into the consumer's symbol table.

After ordinary checking and elaboration, `_validate_foreign_body_node` performs
a closed AST walk. It rejects `StatTry` (including parser-lowered `defer`),
`raise`, generic `for`, `case`, constructors, lambdas, bound methods, variadic
expressions, subset/spread expressions, concatenation, `is`, Titan boolean
operators, and allocation pseudo-calls. Every local must have an initializer
and a direct non-owner, non-function, non-module, non-void C type. A return has
zero or one expression.
This second pass is important: parser desugarings and checker-synthesized nodes
cannot bypass the raw-C surface merely because their original spelling looked
innocent.

The allowed body is intentionally unsafe C. Pointer dereference, indexing,
function-pointer calls, arithmetic, and casts do not gain the NULL, bounds,
range, ownership, or Lua-error checks used by ordinary Titan-to-C lowering. A
literal zero step is rejected, but a dynamic zero step is the trusted
programmer's precondition. An explicit `lua_State *` can be passed in and used
to call the Lua C API, but a longjmp then follows that API's C contract: the
foreign entry has no Titan `setjmp`, root frame, catch, or cleanup protocol.

## Source collaboration and binary isolation

`makemoduletype` places every foreign declaration only in the producer's
compiler-private `source_members` overlay. The member is marked
`_foreign_source` and local regardless of its surface lack of a `local`
modifier. It is absent from `Type.Module.members`, `type_members`, serialized
`*_types`, and `.titan.meta`.

This declaration boundary is independent of C type exportability. A public
ordinary Titan signature may serialize a foreign function-pointer type built
only from contextual C primitives and pointers, but that structural type does
not publish any source `foreign function` declaration or generated-header
dependency.

A loader result grants access only when the import AST carries the written
`source_required` marker and provenance proves both `kind == "source"` and a
source module type. `TopLevelImport._source_import` then lets
`types.module_member` select the overlay for that one written edge. A binary
provider cannot forge the permission: the closed metadata validator rejects
`_source`, `source_members`, `source_type_members`, or the related source C
context fields. Another source module cannot relay the declaration, and static
co-residence or native symbol discovery does not create a Titan name for it.

C declaration plumbing is kept separate from permission. An explicit source import
of a producer that has foreign declarations records the producer's generated
header path on the import node. That header makes the C prototype and any
inline definition visible to the consumer translation unit, but only the
source-provenance overlay makes `alias.member` typecheck. Including a header is
therefore not authorization.

The consumer checker must see the same preprocessing environment as its final
C compiler. After all direct Titan and C imports have been visited,
`apply_source_foreign_headers` adds source-generated headers to the module probe
context in AST order and replays their producer-owned final macro environments
and changed-name deltas before aliases, declarations, module initializers, or
bodies are checked. The source module type carries only that compiler-private
macro state and the exact transitive real-header inputs already established
while checking the producer. Keeping the complete final environment is
necessary when a source companion is the consumer's first C include:
compiler-default and configured `-D` macros are part of that environment even
though the header itself did not change them. The
consumer synthesizes the generated-companion include descriptor from those
facts; it does not preprocess, parse, or convert the resolver-owned temporary
header through `cdriver` a second time. Nested randomized checking-header paths
are canonicalized to the dependency's public path and stable generated identity
before the companion contributes to a probe-cache key. The authoritative C probe baseline still
includes the physical companion, so its declarations and emitted include order
are checked by the same C compiler that will compile the module. This keeps
macro projections and contextual probes aligned with the emitted translation
unit without treating compiler output as a new foreign API. As elsewhere in the trusted C FFI, deliberately
configuration-dependent cross-translation-unit ABI declarations remain the C
programmer's responsibility.

## Exact raw-C lowering and sequencing

Foreign definitions use a dedicated family of coder functions:
`_foreign_raw_exp`, `_foreign_raw_var`, `_foreign_raw_call`,
`_foreign_raw_stat`, and `_foreign_raw_block`. They never enter `codefuncdec` or
the ordinary native/Lua/strict entry generator.

`_foreign_function_signature` renders every parameter with `cdeclarator`,
including C parameter adjustment, and renders a real `void` parameter list when
there are no parameters. The body uses only ordinary C locals and the written
parameters. Inline definitions use `static inline`; out-of-line definitions use
`TITAN_SOURCE_LOCAL`, which selects hidden visibility on the supported
GCC/Clang toolchains.

C does not specify the evaluation order of operands or call arguments, whereas
Titan does. `_foreign_freeze` is the sequencing primitive: it emits an exact
C declarator, evaluates the source once, applies the checker-selected target
cast when needed, and assigns the result to a fresh temporary. The raw lowering
uses it systematically:

* unary and binary operands are frozen left to right before the C operator;
* a call's callee is evaluated once, positional arguments are frozen in source
  order, and named arguments are frozen in written order before their temporary
  names are assembled in formal order;
* a non-void C result is assigned to its own result temporary;
* declaration targets are declared first, initializers are frozen left to
  right, and only then are the declared locals assigned;
* assignment lvalues are prepared left to right, right-hand expressions are
  frozen left to right, and stores happen afterward; and
* numeric-for start, limit, and step are frozen once before the C loop.

`if`/`elseif` lowering nests C scopes so a later condition and its temporary
statements execute only when the earlier arm failed. A `while` recomputes its
condition statements at the top of every iteration, and `repeat` does so after
the body. Numeric `for` chooses `<=` or `>=` from the frozen step and advances
with C addition. These paths preserve source sequencing without replacing C
operator semantics.

Raw field and bracket expressions render C `.`/`->`/`[]` operations directly.
They deliberately omit the ordinary `codeforeigncall`,
`codecfunctionptrcall`, and `codecindex_parts` guards that require an implicit
Lua state. String literals are emitted as C string literals with static
storage, and nil is `NULL`. No `luaC_checkGC`, stack rebase, anchoring, or trace
registration appears in a foreign body.

## Generated `*.titan.h` planning

### Contents and inline classification

A logical source module with at least one foreign declaration owns one
source-adjacent companion:

| Canonical source | Header |
| --- | --- |
| flat `foo/bar.titan` | `foo/bar.titan.h` |
| folder main `foo/bar/bar.titan` | `foo/bar/bar.titan.h` |

`driver.foreign_header_filename` derives the name from the physical native
output, so an external `--tree` and a folder module follow the same canonical
main rule as generated C and object files. Contributors never own headers.

`coder.generate_foreign_header` emits, in order:

1. the ownership banner and a module-derived include guard;
2. direct C imports in AST order;
3. bytewise-sorted supplemental origin headers required to render C types used
   by the declarations and bodies;
4. generated headers for explicit source dependencies that define foreign
   functions;
5. the portable definition of `TITAN_SOURCE_LOCAL`;
6. all foreign prototypes in declaration order; and
7. all eligible inline bodies, also in declaration order.

Before any generated companion is consumed or published, the driver applies
required `#line` normalization. With `titanc --pretty-print` it additionally
runs the configured `clang-format` with Titan's explicit style and include
sorting disabled. Default builds do not invoke the formatter; either mode
preserves the intentional include sequence above.

Putting every prototype before every inline body supports calls among the
module's foreign declarations. Include lines are normalized and deduplicated.
A generated module C file includes its own companion as the complete checked
foreign block rather than repeating the user's direct headers; a module with no
companion includes its direct C and source-generated headers itself.

`_foreign_function_is_inline` skips an optional prefix of initialized local
declarations and then recognizes exactly three root shapes: one return; one
`if` whose sole then and else statements return; or one returning `if` without
else followed by one return. The decision is cached as `_foreign_inline` and is
shared by header and translation-unit generation. Every other declaration gets
a hidden prototype in the header and one hidden definition in the owning C
file. A static-inline address is translation-unit-local; the compiler does not
manufacture a canonical out-of-line identity.

### Temporary headers during checking

Recursive source checking happens before the final physical output graph is
planned. When a checked dependency contains foreign declarations,
`defaultloader` therefore renders a sibling temporary header such as the final
path plus `.check.tmp.<unique>`, completes its normalization/optional-format
boundary, converts the completed checking path to an absolute pathname, and only
then returns it in the trusted source loader result. A consumer can immediately
process the completed header in the exact header/probe
context described above, even when final object compilation will sort the
consumer before the producer. The C registrar reads that unique physical file,
but probe rendering uses a hash-named wrapper keyed by the logical producer and
its eventual public companion path. The wrapper contains an absolute quoted
include of the physical file, preserving that file's nested quoted-include
origin without placing its randomized name in probe text or header-context
identity. It is materialized only after a persistent-cache miss inside the
probe service's private workspace.

These files belong to the resolver context. `close_resolver_context` removes
every recorded temporary and closes the shared C-probe service on ordinary,
diagnostic, and protected exceptional exits. A removal failure becomes a
cleanup diagnostic without masking an already propagating Lua exception in the
CLI's close guard.

### Final planning, ownership, and stale cleanup

After all source modules typecheck, `titanc` calls
`driver.plan_foreign_headers` over the sorted invocation-wide source graph. It
first derives every final absolute header identity without rendering content,
rejects two logical modules claiming one path, then rewrites each explicit source
edge from its temporary checking path to the finalized producer path. It renders
each required header exactly once from that finalized graph. The completed text
is retained on the AST for the later module-code generation pass instead of
walking the same decorated foreign-function bodies again. Every plan is
ownership-validated before any plan is written and is also included in the
CLI's general output-path preflight.

A required path may be replaced only when its first bytes are
`driver.FOREIGN_HEADER_MARKER`; a user file, symlink, directory, or other
unowned object is refused. For a source module with no remaining foreign
declaration, a banner-owned old companion is removed and an unowned same path is
left alone. Each final companion is written to a sibling stage, normalized and
optionally formatted, then renamed over its owned destination only after the
selected steps succeed. All final
companions are published before any source object is compiled, and
`driver.compile` retains a single-module fallback for direct programmatic
callers.

The companion is a source-build intermediate. Provider publication validates
and commits the DSO, archive, shims, dSYM, and standard test-support source—not
generated foreign headers. Headers add no metadata key, DSO claim, archive
member, installed SDK declaration, Lua shim, or module-state slot. Repository
cleanup names the three known standard companions exactly, while generic test
cleanup removes a `.titan.h` only under its bounded generated-source ownership
rule. Sanitizer generated-C snapshots preserve the required header closure with
the saved translation unit.

## Target-directed allocation plans

Target-directed `.new`/`.new_array` selection is part of the same FFI wrap-up,
but it applies to ordinary Titan functions only; foreign bodies reject both
pseudo-functions because they have no Lua allocation/root context.

### Selection at the direct declaration sink

`Checker.CPseudoNew` remains a syntax-bound direct-callee descriptor, not a
`Type.Function`. While `StatDecl` checks its expression list, the result-demand
callback attaches the actual destination declaration as `allocation_decl`.
`_plan_c_allocation` then freezes one `kind = "c_allocation"` plan on the call
and, for an automatic or hidden-owner local, on the declaration. Important
fields include `payload_type`, `result_type`, `storage`, `array`, `fam`, the
literal count, and the FAM field descriptor.

This happens before inference and sink coercion. Code generation switches only
on the recorded plan; it never rediscovers stack versus owner storage from the
endpoint tags. A module initializer, return, argument, assignment to an existing
variable, nested expression, or discarded call has no direct declaration sink
and retains the ordinary owned result.

For a complete, eligible struct or union `T`, `.new()` selects:

| Direct local sink | Plan/result |
| --- | --- |
| inferred, or explicitly `T` | `automatic_object`, a zeroed C `T` local |
| `owned *T` | `owned`, a zeroed Lua userdata owner |
| compatible `*T` | `owned_borrow`, a pointer into a hidden owner rooted for the generated frame |
| any non-direct-local context | ordinary `owned *T` |

Automatic selection is aggregate-specific; a scalar, pointer, or enum
pseudo-allocation does not silently become an automatic scalar. Completeness,
nested-owner, and transitive GC-bearing-storage checks remain closed eligibility
gates. A C array typedef cannot become owned storage or use
`.new()`, but positive-literal `.new_array(N)` may use an imported array typedef as an
element when the sink selects nested fixed automatic storage.

For a non-FAM element type `T`, `.new_array(count)` selects:

| Direct local sink/count | Plan/result |
| --- | --- |
| inferred positive integer literal `N` | `automatic_array`, zeroed `T[N]` |
| written `T[N]`, matching positive literal | `automatic_array`, exact `T[N]` |
| written `T[]` or `*T`, positive literal | `automatic_array_borrow`, pointer over zeroed `T[N]` backing |
| written `T[]` or `*T`, dynamic or zero count | `owned_borrow`, pointer into hidden counted-owner backing |
| written `owned T[]` | `owned` for every count |
| inferred dynamic/zero count or non-direct-local context | ordinary `owned T[]` |

A written fixed extent must be positive and match the source literal count.
“Compile-time” deliberately means the literal AST form, not a host-side
constant folder. The borrowed `T[]` target becomes a raw pointer and carries no
length; `#` and counted bounds checks are unavailable after that lowering. A
pointer may escape and dangle after its automatic block/frame, and a pointer
into a hidden owner loses ownership when that frame stops rooting the owner.

`_codeautomaticallocationdecl` emits real declaration-owned storage rather than
an expression temporary: `{0}` for an object/fixed array, a separate fixed
array plus pointer for `automatic_array_borrow`, and the aligned backing below
for a FAM. This keeps address-taking, C out-parameter mutation, block lifetime,
defer-tail predeclaration, and try-spill analysis attached to the actual
`Ast.Decl`.

### Flexible-array-member provenance

For a complete `struct T` whose marked final field is `E field[]`,
`c_pseudo_member` changes `.new` to one-count arity and makes `.new_array`
unavailable. A literal nonnegative count at an inferred/by-value direct local
selects `automatic_fam`; an explicit owner, explicit `*T`, dynamic count, or
non-local expression selects one owner (with a borrowed pointer for the raw
pointer sink).

The target C compiler remains the layout authority. Both paths use the exact
extent

```text
max(sizeof(T), offsetof(T, field) + count * sizeof(E))
```

and zero the entire extent. Before recording `automatic_fam`, the checker asks
the configured C probe context to prove
`count <= (((size_t)-1 - offsetof(T, field)) / sizeof(E))`; this keeps the
literal bounds provenance and generated backing extent identical without host
layout guesses. The automatic form uses a union containing `T` for alignment
and an unsigned-byte member for the complete constant extent. The owned form
evaluates the count once, rejects a negative value, checks
addition/multiplication overflow, allocates exactly that many payload bytes,
and stores the logical count in one private integer user value. `Udata.len`
remains the byte extent; padding is never mistaken for a logical element count.

Field checking attaches `_c_fam_access` only while allocation provenance is
present. Direct `owner.field[i]` and `automatic.field[i]` are 0-based and use
the stored/literal count for bounds and `#field`. Converting either object to a
raw `T *` erases that annotation; the resulting unsized C field has neither a
recoverable length nor the count-aware index path. Titan does not invent a
collection of variably extended `T` objects or a custom outer stride.

### Copies to owners and longjmp spills

`types.coercion` has two narrow directional operations:
`c_automatic_to_owned` for a matching struct/union and
`c_automatic_array_to_owned` for a matching fixed array. The coder validates
the exact plan, materializes the source once, allocates and stack-roots the
owner, copies the complete object representation, and only then publishes the
owner. A FAM source is recognized from its declaration plan, so the copy uses
the full extended backing and reproduces the logical-count user value. These
are allocating direct coercions, not consistency, subtyping, or recursively
lifted structural conversions.

Ordinary Titan `catch`/`finally` still uses C `setjmp`/`longjmp`. The existing
write/read analysis marks a declaration when a protected region can mutate it
and recovery can observe it. Constructor-created storage participates because
it is declaration-owned. `_c_backing_storage` generalizes a spill to an address
and byte expression: ordinary aggregates use `&local`/`sizeof local`, borrowed
fixed arrays use their hidden backing, and automatic FAMs use their complete
extended byte area.

The coder maintains a volatile byte spill with explicit byte loops after
initialization, assignments, and normally returning mutable C calls, then
reloads it on recovery. It intentionally does not cast away volatility through
`memcpy`. A C call that mutates and then longjmps does not commit its partial
post-call state; an untracked alias remains outside the supported contract.
Foreign functions themselves have no such spill protocol because their bodies
cannot establish a Titan recovery boundary.

## Standard-library callback migrations

The standard library dogfoods foreign declarations at the three former hand-written
callback boundaries:

* `titan.coroutine` defines `coro_entry_trampoline` in
  `titan/coroutine.titan` and assigns it directly to `mco_desc.func`.
  `titan-runtime/minicoro.c` now owns only the one `MINICORO_IMPL`
  translation unit and the fixed raw-Lua tag comparator.
* Six `titan.uv` contributors (`file`, `os`, `process`, `runtime`, `task`, and
  `tcp`) define thirteen exact callbacks: filesystem, signal, process exit,
  write, alloc, read, close, walk, timer, DNS, connect, shutdown, and
  connection.
* `titan/http/native.titan` defines the eight synchronous llhttp data and
  completion callbacks. The private llhttp archive still contains exactly
  `llhttp.o`, `http.o`, and `api.o`; there is no separate HTTP adapter object.

The trusted callbacks need a few Lua-internal operations that remain awkward as
function-like C macros. `titan/ffi.h` supplies only four typed inline bridges:
`lmacro_thvalue`, `lmacro_uvalue`, `lmacro_clCvalue`, and `lmacro_pvalue`. The
host preprocessor expands the real Lua macros inside those wrappers; general
function-like macro inference remains unsupported. The same header owns small
typed inline definitions of `lua_totvalue`, `lua_pushtvalue`, `lua_togco`, and
`titan_newthread`, so trusted source modules do not depend on separate runtime
exports for those bridges.

Each uv/HTTP callback preserves the reviewed owner protocol in source: recover
the exact already-traced owner and callback closure, recover the loop/main Lua
state and module from their fixed slots, read the closure's native entry through
an exact `foreign (...) -> ...` type, save the stack top, invoke the entry with
the original closure as `_fn`, and restore the top. The owner remains reachable
through its runtime/parser ownership throughout the callback, so pushing the
same userdata would add no GC protection. The
filesystem path deliberately passes only its owner; its Titan handler reads the
result through `uv_fs_get_result`. No event-kind dispatcher, registry callback
table, or compatibility shim replaces the deleted C files.

The runtime SDK archive consequently has exactly `titan.o` and `minicoro.o`.
Its installed namespaced header set is only `titan/ffi.h`, alongside top-level
`minicoro.h` and `titan.h` (and the separately governed
bundled libuv headers). The standard provider payload is `ltitanlib.o`, private
LPegLabel, the selected libuv payload, private llhttp, and the selected OpenSSL
payload; it has no `titan_uv.o`, `titan/coro.h`, `titan/uv.h`, or
`titan_httpshim.o`.

## Native names and ABI

`coder._function_prefix` separates a flattened logical module name from the
remaining callable with `_\u2133_` (U+2133 SCRIPT CAPITAL M):

```text
foo.bar + baz -> foo_bar_\u2133_baz
```

`coder._nominal_function_prefix` adds `_\u2131_` (U+2131 SCRIPT CAPITAL F)
between a record, union, or Interface owner and its member or synthetic
metamethod role:

```text
foo.bar + Point:move -> foo_bar_\u2133_Point_\u2131_move_titanmethod
```

Neither character can occur in Titan's identifier alphabet, so both tuple
boundaries are injective without a universal `titan_` prefix or a separate
hexadecimal source-private scheme. C source retains the UCN spellings; object
symbols, DWARF, libbacktrace, and native tools see UTF-8 `ℳ` and `ℱ`, which
`_linkage_symbol_name` computes for native trace keys.

Ordinary public and local top-level entries share the family:

```text
foo_bar_\u2133_baz_titan
foo_bar_\u2133_baz_titanentry_lua
foo_bar_\u2133_baz_titanentry_strict
```

A foreign declaration uses only the first native spelling. Hidden linkage and
source/Lua visibility are properties of the declaration, not alternate name
encodings. Library preflight calls `coder.external_symbols`, so hidden
cross-object foreign and local entries still participate in collision checks
before the linker runs.

The native symbol contract has two ABI-visible properties: generated standard
objects define callbacks absent from the runtime/HTTP support objects, and
callable entry families use the separated module/nominal/member hierarchy.
ABI 2 carries that contract together with generic and public standard-library
metadata. A mismatched runtime or generated object is rejected even when its
serialized public types happen to match.

`TITAN_VERSION` `0.6.0` derives the `0.6` library namespace used by
`TITAN_PATH_0_6`, `lib/titan/0.6`, `share/titan/0.6`, and `stdlib_0_6`.
Earlier Titan installations are not migration or compatibility inputs.

Foreign declarations, allocation plans, and generated headers remain
compiler-local. They add no public type descriptor or module-state slot, so the
combined standard provider still has eighteen logical metadata keys and
nineteen DSO openers including bare `luaopen_titan`.
