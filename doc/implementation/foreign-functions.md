# Foreign-function implementation

Titan-written `foreign function` declarations are plain C-ABI entry points
implemented in Titan source. They reuse the imported-C type graph and the
configured target profile, but they do **not** reuse the ordinary Titan
function ABI. This chapter follows the feature from parser and source
collaboration through raw-C lowering, generated headers, and the standard
library's native callbacks.

For the source contract, see [Foreign functions](../language/foreign-functions.md).
The imported-header pipeline and ordinary FFI boundary remain documented in
[FFI internals](ffi-internals.md) and
[C FFI declarations and expressions](c-ffi-expressions.md).

## Phase map

The feature deliberately adds source forms without adding another semantic
callable representation:

| Source/compiler form | Checked representation | Generated representation |
| --- | --- | --- |
| `foreign function(P...): R` | `Type.CPointer(Type.CFunction(P, R, false, false))` | an exact C function-pointer declarator |
| `[local] foreign function f(P...): R ... end` | `Type.CFunction(P, R, false, false)` on `Ast.TopLevelForeignFunc` | one plain C function; public entries are exported out of line, local entries may be inline or hidden |
| a direct reference to `f` | a declaration designator, not a value | the bare generated C name |
| an exactly typed pointer context | C declaration-to-pointer decay | the same bare generated C name |

There is no foreign closure, Lua-stack entry, strict entry, module user-value
slot, function tag, capture list, traceback-name registration, or serialized
callable descriptor. `Type.Function` continues to mean the boxed Titan/Lua
callable protocol; `Type.CFunction` continues to mean a direct C declaration.

## Parser and AST

The factored top-level grammar distinguishes `foreign function`, `foreign
import`, and `foreign type` by their next keyword. A foreign function uses
foreign-only parameter and return types, and its body is parsed by a grammar
of its own:

```text
[local] foreign function AnyName '(' [foreignparlist] ')' [':' foreigntype] fblock end
```

It produces `Ast.TopLevelForeignFunc(loc, name, params, rettypes, flexrettype,
block)` with an `islocal` flag. Missing results become C void. `Ast.TypeForeignFunction` represents
`function(foreign_types): foreign_result` inside foreign type syntax and lowers
to a C function pointer. Bare C variadic tails remain represented for a precise
unsupported-source-variadic diagnostic. Titan function types use their distinct
`function(types): results` grammar and may carry Titan flexible tails.

The body rules (`fblock`, `fstatement`, `fexp` and the rest, in the section
"Foreign function bodies" of `parser.lua`'s `grammar_source`) admit exactly
the raw-C subset and take a `foreigntype` wherever the ordinary rules take a
`type`, so a body annotation or cast is written without `foreign`. They add
no AST node and no action: each rule ends in the action of its ordinary
counterpart, and the block of a foreign function is the tree that the
ordinary grammar builds for the same statements with `foreign` before each
type (`spec/parser_spec.lua` compares the two). A construct outside the
subset is a labelled syntax error; see
[the foreign-body rules](lexer-parser.md#foreign-function-bodies).

Unqualified `Ast.TypeForeignName` nodes never consult term bindings. Foreign
pointer/array constructors use existing `TypeCPointer`/`TypeCArray` syntax nodes;
another constructor beneath a pointer must be parenthesized. Unsized array
annotations retain the direct-local borrowed-view semantics. There is no
written fixed-array extent; allocation inference creates fixed arrays.

`Ast.TypeOwned(loc, subtype)` belongs to the Titan type grammar. Its full foreign
operand must resolve to a pointer or array, possibly through an alias; the
checker extracts payload and countedness and creates `Type.COwned`. This keeps
ordinary owned aliases and trailing Options in the Titan category. Owned types
are rejected in foreign signatures and foreign-body local declarations.

`Ast.TopLevelForeignTypeAlias(loc, name, type)` is always local and emits an
actual raw-C typedef through the `.ffi.h` plan. It has no Titan runtime member.
`Ast.ExpForeignType(loc, type)` routes foreign allocation/layout expressions
without making ordinary terms or imported type names into namespaces.

## Signature collection and the raw-C checking context

### Signature construction

Foreign signatures are collected in the callable-signature pass, alongside
ordinary top-level functions but before bodies.
`checker._foreign_function_signature` (`checker/interfaces.lua`) uses
`typefromnode` and accepts only direct declarable C FFI components:

* parameters cannot be `void`, owners, arrays, direct functions, C modules, or
  Titan values;
* the result is either absent/explicit void (`Type.CVoid`) or one direct C type;
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
* gives literals raw target C types (`_Bool`, unsuffixed C99 integer
  classification, `double`, `const char *`, and contextual `NULL`), sharing the
  [C-operator literal classifier](c-ffi-expressions.md#c-operator-traits);
* contextually types fitting numeric literals at annotated declarations,
  assignments, C arguments, and C returns, without passing the expected result
  type into operator operands;
* gives every operator its C99 result type: `finish_c_operator` types a
  pointer difference as the [trait's](c-ffi-expressions.md#c-operator-traits)
  `result_source`, the target's `ptrdiff_t`, and a relational or equality
  operator as the target's `int`, where an ordinary function sees `integer`
  and `boolean`; a binary operator that is not a C operator (`//`, `^`), or
  that has no C operand, is an error;
* accepts any C integer as a subscript of a C pointer or array (`checkvar`,
  `Ast.VarBracket`): a numeral is an `int`, and an index that already has a C
  integer type is not converted, where an ordinary function converts its
  Titan `integer` index;
* requires conditions to be C scalars;
* requires numeric-for controls, limits, and steps to share a C integer or
  floating type; and
* permits only parameters/locals, current-module foreign declarations, C
  namespaces, public foreign members through regular imports, and local foreign
  members through an explicit source import.

`checkvar` rejects an ordinary top-level Titan declaration in this mode, and a
qualified Titan-module lookup is accepted only when
`_foreign_function_reference` identifies a source foreign member. An imported
C namespace remains usable because its functions, values, fields, types,
`sizeof`, and `alignof` are already direct C declarations. A producer's
builtin `ffi` value namespace and separate foreign type namespace is established from the consumer's combined C header.

The grammar has already removed every construct that has no raw-C meaning, so
after ordinary checking and elaboration `checker._checkforeignfunc` runs a
small walk, `checker._validate_foreign_body_node` (`checker/declarations.lua`),
for what syntax cannot decide:

* a local declaration has an initializer;
* a local has a C value type. `void` is the case that occurs: an inferred
  local takes it from a void pointee, and it can be written (a C namespace or
  a function designator never gets that far: expression checking rejects them
  as values). The test also rejects a Titan type, which nothing produces: it
  is a guard, so that a Titan value that ever reaches a local is a diagnostic
  and not a coder error;
* an allocation pseudo-call has an automatic-storage plan
  ([allocation](#allocation-and-recovery-storage)).

The length operator `#` is rejected by the `ExpUnop` check in foreign mode.
With that and the C99 operator results, every expression of a foreign body
has a C type: literals are C-typed in this mode, names are C declarations,
calls return C values, operators are C operators, and a cast's target is a
`foreigntype`. The checker synthesizes one C-to-Titan conversion, the count
argument of an allocation pseudo-call, which the walk does not enter. The
former check on casts between Titan and C values therefore has no case left
and is gone, together with the tables of forbidden statement and expression
tags.

The allowed body is intentionally unsafe C (see [The C FFI](../language/ffi.md)). Pointer dereference, indexing,
function-pointer calls, arithmetic, and casts do not gain the NULL, bounds,
range, ownership, or Lua-error checks used by ordinary Titan-to-C lowering. A
literal zero step is rejected, but a dynamic zero step is the trusted
programmer's precondition. An explicit `lua_State *` can be passed in and used
to call the Lua C API, but a longjmp then follows that API's C contract: the
foreign entry has no Titan `setjmp`, root frame, catch, or cleanup protocol.

## Source collaboration and binary isolation

`makemoduletype` publishes ordinary foreign declarations as
`Type.ModuleMember(Type.CFunction)` with exact parameter names. Their signature
must satisfy the existing exportable C type graph contract. The closed binary
validator permits `CFunction` as a module declaration or pointer pointee, never
as a module variable; it validates fixed arity, return/parameter types and
parameter names. Foreign declarations consume no module uservalue or closure
slot and have no Lua or strict entry. Selective binary compatibility records
used foreign signatures in the existing function category.

`local foreign function` lives only in the compiler-private `source_members`
overlay, marked `_foreign_source` and local. It is absent from serialized
interfaces. Binary metadata cannot acquire source authority by carrying that
marker.

Regular imports expose public C declarations to ordinary Titan bodies and
restricted foreign bodies. Each imported public raw entry has an exact typed
function-pointer slot qualified by its importing source module. The generated
image owns the hidden slot; it is absent from public metadata, module userdata,
and Windows exports. Own and local raw entries still use direct C designators.

After ordinary dependency ABI/compatibility checks, initialization, and final
canonical selection, `init_data_from_other_modules` resolves dynamic candidates
with the existing `titan_module_symbol` and obtains static candidates from the
exact linked entry. The existing runtime resolver therefore selects initialized
modules, copied native preloads, and runtime-path DSOs as usual. There is no
direct shared-library link input, generated import library, or build-time path
dependency. Only static candidates enter the native-reference extraction set.
Windows `.def` publication includes public raw entries alongside the existing
protocol exports.

Bindings publish in sorted native-symbol order with GCC/Clang's C99-compatible
`__atomic_compare_exchange_n` (`ACQ_REL` success, `ACQUIRE` failure). A null slot
accepts its first candidate; an equal existing address is valid, while a
different one raises before publishing the consumer module. Raw calls and
callback conversions acquire-load the exact pointer, with no hidden `L` or
`_mod` argument and no forwarding wrapper. Independent states may initialize
the same image concurrently without a data race or callback redirection.
Published slots persist even if a later initialization step fails. This is a
stable native-image binding, not a rollback transaction; ordinary Titan native
bindings remain per-state. Runtime-loaded Titan DSOs already remain mapped for
the process lifetime.

Checking-time source headers precede final static/dynamic provenance, so both
kinds of imported public entry use the same slot expression. A copied local
direct-call helper body declares its owner's hidden slot as `extern` in
`.titan.h` and reads that owner slot, never a separate translation-unit-local
copy. The binary-usage prescan retains references used only in prepared helper
bodies.
Header-dependent C types still require compatible original headers in the
consumer.

A loader result grants local access only when the import AST carries the written
`source_required` marker and provenance proves both `kind == "source"` and a
source module type. `TopLevelImport._source_import` then lets
`types.module_member` select the overlay for that one written edge. A binary
provider cannot forge the permission: the closed metadata validator rejects
`_source`, `source_members`, `source_type_members`, or the related source C
context fields. Another source module cannot relay the declaration, and static
co-residence or native symbol discovery does not create a Titan name for it.

C declaration plumbing is kept separate from permission. Every explicit source
import carries the producer's generated `.ffi.h` descriptor into the consumer's
combined C environment. If the producer defines foreign functions, its
`.titan.h` also makes their prototypes and local direct-call helpers visible to
generated C. The source-provenance overlay alone makes `alias.member` typecheck.
Transitive C header inclusion does not grant transitive private Titan access.

The consumer checker prepares one `A.ffi.h` containing explicit-source
dependency FFI headers before its local directives, then preprocesses and parses
that actual header. Include guards, final macro state, and actual C scopes
produce the builtin `ffi` value namespace and the separate foreign type
namespace before aliases, signatures, initializers, and bodies are checked.
Probes use the same generated FFI tree (see
[semantic-result caching](c-ffi-expressions.md#analysis-local-and-persistent-semantic-results)).
Additional consumer headers can cause late C diagnostics for imported
declarations while Titan source-private visibility stays direct.

## Exact raw-C lowering and sequencing

Foreign definitions use a dedicated family of coder functions:
`_foreign_raw_exp`, `_foreign_raw_var`, `_foreign_raw_call`,
`_foreign_raw_stat`, and `_foreign_raw_block`. They never enter `codefuncdec` or
the ordinary native/Lua/strict entry generator.

`_foreign_function_signature` renders every parameter with `cdeclarator`,
including C parameter adjustment, and renders a real `void` parameter list when
there are no parameters. The body uses only ordinary C locals and the written
parameters. Every source foreign function has exactly one out-of-line
definition, a movable item of its module's generated C. Local definitions use
`TITAN_SOURCE_LOCAL`, which selects hidden visibility on the supported
GCC/Clang toolchains; public definitions keep external visibility and appear
in the native provider export inventory. A local function additionally gets
the `static inline` direct-call helper described in
[Contents and inline classification](#contents-and-inline-classification).

C does not specify the evaluation order of operands or call arguments, whereas
Titan does. `_foreign_freeze` is the sequencing primitive: it emits an exact
C declarator, evaluates the source once, applies the checker-selected target
cast when needed, and assigns the result to a fresh temporary. A string literal
needs no temporary because its evaluation has no effects. The raw lowering uses
this primitive systematically:

* nonliteral unary and binary operands are frozen left to right before the C operator;
* a call's callee is evaluated once; nonliteral positional arguments are frozen
  in source order, and nonliteral named arguments in written order before the
  values are assembled in formal order. String literals stay inline through
  ordinary byte-pointer casts, using the ordinary C-literal byte escaping
  without introducing evaluation effects. Function-pointer/`void *` conversions
  retain their native portability adapter;
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

Each nested `elseif` scope follows the preceding arm's single `else`; the
later condition's temporary statements remain inside that scope. Regression
coverage checks both generated validity and lazy, once-only condition effects.
Native `sizeof`/`alignof` expressions retain the profile's `size_t`, and exact
pointer output arguments reuse the checker-owned `mutable_c_address` plan to
pass the original local's address before argument freezing.
Ordinary Titan call statements and deferred statements use the same explicit
foreign-reference annotation as value-producing expressions to select the C
ABI, including source-defined foreign functions with discarded or no results.

Raw field and bracket expressions render C `.`/`->`/`[]` operations directly.
They deliberately omit the ordinary `codeforeigncall`,
`codecfunctionptrcall`, and `codecindex_parts` guards that require an implicit
Lua state. String literals are emitted as C string literals with static
storage, and nil is `NULL`. `_foreign_raw_stat` stamps `#line` source
directives (`emitline(node) .. coverage_region(node, code, ctx)`) on raw
statements, and `coder.generate` registers `<module>.<name>` in
`registry[TITAN_NAMES_KEY]` for both `_foreign_func_name` and any local
`_foreign_inline_name` helper so foreign-body frames carry their `.titan`
location and display name in tracebacks. No `luaC_checkGC`, stack rebase, or
GC anchoring appears in a foreign body.

## Generated `*.titan.h` planning

### Contents and inline classification

Every logical source module owns `A.ffi.h`; a module with foreign functions also
owns `A.titan.h`:

| Canonical source | C environment | Foreign declarations |
| --- | --- | --- |
| flat `foo/bar.titan` | `foo/bar.ffi.h` | `foo/bar.titan.h` |
| folder main `foo/bar/bar.titan` | `foo/bar/bar.ffi.h` | `foo/bar/bar.titan.h` |

`driver.ffi_header_filename` and `driver.foreign_header_filename` derive these
names from the canonical physical output. External `--tree` sources and folder
modules follow the same main-file rule as generated C and object files;
contributors never own separate headers.

`coder.generate_ffi_header` delegates to `ffiheaders.render`: ownership banner
and guard, explicit-source dependency `.ffi.h` includes in declaration order,
then local foreign directives in combined AST order. For folder modules this is
the selected main first, then the selected contributors in bytewise order of
logical filenames.

`coder.generate_foreign_header` emits:

1. the ownership banner and module-derived include guard;
2. its own `.ffi.h` and needed explicit-source `.titan.h` includes;
3. the portable definition of `TITAN_SOURCE_LOCAL`;
4. in declaration order, each foreign function's canonical prototype
   (`TITAN_SOURCE_LOCAL` for a local function, `extern` for a public one),
   followed for a local function by the `static inline` declaration of its
   direct-call helper; then `extern TITAN_SOURCE_LOCAL` declarations of the
   module's imported raw foreign binding slots; and
5. every local direct-call helper body in declaration order.

Fresh source-foreign headers and restored recipes share
`ffiheaders.foreign_contents` and the canonical generated-line cleanup. It
removes blank physical lines after generated `#line` directives while preserving
LF/CRLF spelling and all other recipe bytes.

Fresh publication, checking-header restoration, and relocated companion replay
all apply the original formatting policy before native preprocessing. With
`titanc --pretty-print`, both `.ffi.h` and `.titan.h` companions are formatted
with Titan's explicit style and include sorting disabled. Published companions
are staged and compared before replacement, so unchanged formatted bytes keep
the existing file. Default builds do not invoke the formatter; either mode
preserves the intentional include sequence above.

Putting every prototype before every helper body supports calls among the
module's foreign declarations. Include lines are normalized and deduplicated.
A generated module C file includes its own `.ffi.h` first and then its own
`.titan.h` when present, plus needed explicit-source Titan declaration headers.
It does not reconstruct a supplemental origin list from individual C types.
When `coder.generate` runs without a prepared `.titan.h`, it puts the same
prototypes and helper bodies in `$SIGS`.

Each source foreign function has one canonical out-of-line definition,
`coder._foreign_func_name` (the ordinary `ℳ` spelling), emitted once by its
owning module. Every pointer-producing use, in the owner or in a source
importer, names that definition, so all pointers to one foreign function are
equal: across modules, across the [parts of a split
module](codegen-overview.md#translation-unit-parts), and whether or not the
module is split. Public entries have only this definition.

A local function also has a direct-call helper
`<prefix>\u2119_foreign_inline_<name>` (`coder._foreign_inline_name`), defined
`static inline` in every translation unit that includes the header. Direct
calls to a local source foreign function, in the owner or a source importer,
call the helper (`coder._foreign_reference_name` with `direct = true`). The
helper's address is never taken, so its per-unit copies are unobservable.
`coder._code_foreign_inline` makes it a copy of the body when
`_foreign_function_is_inline` accepts the function, and otherwise a one-line
forwarder to the canonical definition. `_foreign_function_is_inline` first
excludes public declarations, coverage-outlined functions, and functions with
private native-record field layouts. It then excludes a body whose lowering
names something the header does not declare (`needs_producer_unit`). The
header includes only the module's `.ffi.h`, and authored C may include it
before any other header, so three lowerings keep a body in the producer's C
unit: a declaration with an
[allocation plan](#allocation-and-recovery-storage), whose zeroed storage is
rendered with `memset`, `offsetof` and `size_t`; a cast between a function
pointer and `void *`, which is rendered with `titan_cast_func` of
`titan/ffi.h`; and a non-finite float literal, which is rendered with
`HUGE_VAL` of `math.h`. Every other lowering names only C itself and the
module's own declarations. `nil` is `((void *)0)`, not the `NULL` of
`stddef.h`. The built-in `lua_State` of a module that does not import `lua.h`
is rendered by its tag, and a tag first written in a parameter list is scoped
to that one declaration. Each generated header that names the tag therefore
declares `struct lua_State;` at file scope first
(`ffiheaders.names_state_tag`): the `.ffi.h` before its typedefs, and the
source header before its includes, when a prototype or a copied body names
it. The declaration is derived from the rendered text, so the stored `.ffi.h`
plan does not change. Any lowering added
to the raw-C path that names a C library or runtime symbol belongs in the
predicate, and a function that uses the new lowering belongs in the fixture of
`spec/coder/foreign_functions_spec.lua` that compiles the header alone.
Finally it skips an optional prefix
of initialized local declarations and recognizes exactly three root shapes:
one return; one `if` whose sole then and else statements return; or one
returning `if` without else followed by one return. Header and module
generation each recompute the classification; nothing is cached on the AST
node.

### Temporary headers during checking

Recursive source checking happens before the final physical output graph is
published. `ffiheaders` validates immutable descriptors for each logical module,
its authored include text, and its dependency descriptors, and materializes the
actual generated `.ffi.h` tree under a private root with deterministic logical
paths. A content-derived descriptor digest binds its text and dependencies.
Relative generated-header edges preserve that logical tree. Absolute author
header includes preserve quoted-include origin. A consumer can parse and probe
its complete environment immediately after its source dependencies are checked.

Dependencies with foreign functions also receive a completed checking
`.titan.h` in that tree, including its own `.ffi.h` and needed dependency Titan
headers. These actual files require no forwarding include or filesystem alias.
They pass the required normalization and optional formatting boundary before
use.

These files belong to the resolver context. `close_resolver_context` removes
every recorded temporary and closes the shared C-probe service on ordinary,
diagnostic, and protected exceptional exits. A removal failure becomes a
cleanup diagnostic without masking an already propagating Lua exception in the
CLI's close guard.

### Final planning, ownership, and stale cleanup

After all source modules typecheck, `titanc` calls
`driver.plan_foreign_headers` over the sorted invocation-wide source graph. It
first derives every final absolute header identity without rendering content,
rejects two logical modules claiming one path, then rewrites explicit-source
`.ffi.h` and `.titan.h` edges from checking paths to finalized producer paths.
It renders each required header exactly once from that finalized graph. The completed text
is retained on the AST for the later module-code generation pass instead of
walking the same decorated foreign-function bodies again. Every plan is
ownership-validated before any plan is written and is also included in the
CLI's general output-path preflight.

A required path may be replaced only when byte zero begins the exact marker for
its header kind: `ffiheaders.MARKER` for `.ffi.h` or
`ffiheaders.FOREIGN_MARKER` for `.titan.h`. The shared
`ffiheaders.check_destination` check refuses a user file, a wrong-kind or
displaced marker, a symlink, a directory, or another unowned object. Fresh
header-kind checks use LuaFileSystem's scalar `mode` query; its table form can
fail while resolving Windows directory destinations. Incremental relocation
applies the same ownership check before comparing, adopting, or writing
descriptor headers, recursive source-dependency helpers, and the module's own
persisted foreign-header recipe. It also checks split-unit `.priv.h` contents
against the existing `coder.PRIVATE_HEADER_MARKER` before rebinding or adopting
them; their existing regular-file requirement remains in force.

Missing `.ffi.h` descriptors and a module's own persisted `.titan.h` recipe can
be materialized again. A refused destination remains untouched through the
relocation miss and subsequent fresh-build preflight. For a source module with
no remaining foreign declaration, a marker-owned old companion is removed and
an unowned same path is left alone. Fresh publication writes each final companion
to a sibling stage, normalizes and optionally formats it, then renames it over
its owned destination only after the selected steps succeed. All final
companions are published before any source object is compiled, and
`driver.compile` retains a single-module fallback for direct programmatic
callers.

The companion is a source-build intermediate. Provider publication validates
and commits the DSO, archive, and dSYM; it excludes generated foreign
headers. Headers add no metadata key, DSO claim, archive
member, installed SDK declaration, Lua entry, or module-state slot. Repository
cleanup covers both generated header suffixes under their bounded
generated-source ownership rules. Sanitizer generated-C snapshots preserve the required header closure with
the saved translation unit.

## Allocation and recovery storage

Foreign bodies have no Lua allocation or root context, and they have no
`setjmp` spill protocol because they cannot establish a Titan recovery
boundary. An allocation pseudo-call (`.new`, `.new_array`) is planned by
`checker._plan_c_allocation` exactly as in an ordinary function. The body
validator then reads the recorded plan:

* `automatic_object`, `automatic_array`, `automatic_array_borrow` and
  `automatic_fam` are accepted. They exist only at a direct local sink and
  need no Lua state. The walk does not descend into the call: its count is a
  constant of the plan.
* `owned_borrow` (a pointer local with `.new()`, or with a dynamic or zero
  `.new_array` count) and `owned` are rejected. `foreign_allocation_error`
  words the diagnostic by the plan and by `local_sink`, the name of the
  declaration the allocation initializes, which is absent for an argument, a
  return value, an assigned value or an operand.

`foreign_raw_stat_dispatch` (`coder/declarations.lua`) lowers a declaration
with a plan through `coder._automatic_allocation_storage`, the renderer that
ordinary locals use, and emits no initializer assignment for it. The storage
is declared at the statement, inside the C block of its Titan block, so a
loop body zeroes it again on every iteration. The names are
`_foreign_local_<name>_<n>` for an object, a fixed array or the pointer view,
`_foreign_backing_<name>_<n>` for the borrow's array and the FAM union, and
`_foreign_fam_pointer_<name>_<n>` for the FAM's typed pointer; a FAM local is
spelled `(*pointer)` wherever the body names it. Indexing stays raw C: the
foreign lowering never reads `_c_fam_access`, and `#` is rejected.

Target-directed allocation plans, flexible-array-member provenance,
automatic-to-owned copies and aggregate spills in ordinary Titan functions
are documented in
[target-directed automatic aggregates and fixed arrays](c-ffi-expressions.md#target-directed-automatic-aggregates-and-fixed-arrays).

## Standard-library foreign callbacks

The standard library implements its native callback boundaries as source
foreign functions compiled into the owning module objects:

* `titan/coroutine.titan` defines `coro_entry_trampoline` and assigns it
  directly to `mco_desc.func`. `titan-runtime/minicoro.c` holds only the
  `MINICORO_IMPL` translation unit and the fixed raw-Lua tag comparator.
* The `titan.uv` folder contributors define the native callbacks for the public
  low-level loop, handle, stream, request, process, and worker operations.
  Ordinary Titan callbacks remain main-thread entries; C-only workers, thread
  entries, and once callbacks have separate foreign signatures and cannot call
  into Titan or Lua.
* `titan/http/parser.native.titan` defines the eight synchronous llhttp data and
  completion callbacks; the private llhttp archive contains only `llhttp.o`,
  `http.o`, and `api.o`.
* `titan/transfer.titan` and `titan/thread/*.titan` define the C-ABI packet and
  channel callbacks.
* `titan/browser.browser.titan` defines the browser bridge's public foreign
  functions (`invoke`, `release_callable`) and local foreign `mark_closing`.
  Its module-owned state record uses `gc.finalizable` with an ordinary Titan
  finalizer. `browserentry.lua` emits one-line weak C forwards
  (`titan_browser_invoke`, `titan_browser_release_callable`) to the public
  foreign functions, so the browser runtime needs no hand-written C file.

The runtime SDK archive therefore contains only the four portable runtime
objects (`titan.o`, `minicoro.o`, `titan_path.o`, and `ltitanlib.o`); no adapter
object carries callback code. The Lua-internal macro and field bridges these
callbacks use (`lmacro_*`, `lua_totvalue`, `lua_pushtvalue`) are typed inline
functions in `titan/ffi.h`; see
[header support files](ffi-internals.md#header-support-files).

A UV or HTTP callback recovers the exact owner, callback closure, owning main
Lua state and module, and the closure's native entry through an exact
`foreign function(...): ...` type, then invokes that entry with the original
closure as `_fn` and preserves the Lua stack top. Callback exceptions latch the
original error and trace, complete mandatory native bookkeeping, and are
rethrown only after returning across the native boundary. Pinning, request and
terminal-callback ownership are in the
[extension guide](libuv-extension-guide.md); the synchronous HTTP parser keeps
its own parser-owner protocol. High-level fs/net/os/timer modules use ordinary
Titan callbacks through the compiled UV interface and public async
registration APIs, never this raw bridge. This trampoline is the model for
rules 1 and 3 of the
[standard-library native-binding rules](standard-library-maintenance.md#keep-c-and-the-lua-c-api-to-what-titan-cannot-do),
which every new standard-library or runtime C callback into Titan follows.

## Native names and ABI

A foreign declaration owns only the `<module>_\u2133_<name>_titan` spelling of
the [generated-name hierarchy](codegen-overview.md#generated-names); it has no
`_titanentry_lua` or `_titanentry_strict` entry. Public or local linkage and
source visibility are properties of the declaration, not alternate name
encodings. `coder.external_symbols` and `coder.foreign_external_symbols`
(`coder/names.lua`) include hidden cross-object foreign entries, so library
preflight catches collisions before the linker runs.

Public foreign declarations reuse the `ModuleMember(CFunction)` type graph and
the function compatibility category of the
[compiled-module ABI](codegen-overview.md#compiled-module-abi). Local foreign
declarations, allocation plans, and generated headers stay compiler-local.
Neither kind adds a module-state slot or Lua opener.
