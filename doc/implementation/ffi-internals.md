# FFI internals

`foreign import "stdio.h"` drives a compile-time C pipeline under
`c-parser/`, converts declarations into the `Type.C*` family in `types.lua`,
and emits direct C expressions from the `titan-compiler/coder/` slices. The
generated translation unit includes the same header, so the host C compiler
sees the real prototypes; the Lua-side pipeline exists to typecheck Titan
source before code generation.

`coder._foreign_reference_name` (`coder/names.lua`) spells every foreign
designator. An imported C declaration is parenthesized, for example
`(memchr)(...)`, in ordinary Titan calls, restricted foreign bodies, and
callback conversions; this keeps the checked declaration when a header also
defines a same-name function-like macro, such as glibc's const-generic string
wrappers, while object-like aliases still expand normally. A source
`foreign function` of the same module uses its bare generated name. A public
source foreign function from another module is read from the importing image's
hidden binding slot with `__atomic_load_n(&slot, __ATOMIC_ACQUIRE)`; see
[source collaboration](foreign-functions.md#source-collaboration-and-binary-isolation).

For user-facing behavior see [the C FFI](../language/ffi.md),
[C FFI declarations and expressions](../language/c-ffi-expressions.md),
[Foreign functions](../language/foreign-functions.md), and
[Named arguments](../language/named-arguments.md). The exact tag, declarator,
target-profile, probe, contextual-conversion, target-directed allocation,
recovery-storage, and C-operator machinery is in
[C FFI declarations and expressions](c-ffi-expressions.md); the restricted
raw-C checker and lowering, generated source headers, and standard-library
callbacks are in [Foreign-function implementation](foreign-functions.md).

## Import Pipeline

`Ast.TopLevelForeignImport` stores a source location and `headername`; it has
no `localname`. The import pass resolves ordinary Titan imports and collects
unbound foreign directives. `check_foreign_environment` installs one implicit
`Checker.ForeignNamespace` named `ffi`, backed by a `Type.CModule` with separate
value and type members. The readonly builtin term may be shadowed normally.
Foreign type lookup uses `st.ffi_namespace` directly; a hidden later module
binding falls back to the builtin during an earlier initializer.

Before aliases, signatures, initializers, or bodies are checked, the driver
prepares one `.ffi.h` for the complete logical module. Direct explicit source
imports contribute their `.ffi.h` files first, in import order, followed by
local foreign directives. A folder's selected main and its selected
contributors, in bytewise order of logical filenames, share this one ordered
plan. Repeated directives are retained;
real C guards, conditional macros, and `#undef` determine their effect.

`cdriver.resolve_includes` determines quote/angle intent without parsing each
header. Authored relative headers keep their resolved absolute quoted origin;
SDK/system includes retain their angle spelling. `cdriver.process_module`
then preprocesses and parses the generated header through the configured C99
toolchain context. Modules without foreign aliases need one pass; modules with
aliases first establish the imported C types, then resolve and append their
typedefs before converting the final declaration-complete header. The stages are:

1. Configure predefined macros, system include search, user CPP flags, and the
   active Lua/Titan SDK, then preprocess the whole ordered include chain.
2. Parse the flattened C translation unit with `c99` and register its
   declarations with `ctypes` in their actual C scopes.
3. Project supported final object-like macros with `cdefines`, using bytewise
   order for entries obtained from an unordered macro map. Preserve supported
   scalar/accessor expressions and classify every active object macro as a
   pure dotted field projection or a terminal unsupported field token.
4. Convert the final TypeList through `foreigntypes.convert` into
   `ffi.members` and `ffi.type_members`. Tag-only named file-scope structs and
   unions retain their canonical tag owners; real typedefs take precedence.

There is no cross-import per-name comparison queue or synthetic redeclaration
probe loop. Include suppression and C scope are resolved by the combined parse.
Use-specific enum, pointer, operator, and layout probes remain, as does the
module header baseline. The actual configured C compiler can diagnose
incompatible declarations or implicit conversions during baseline or final
generated-C compilation; Titan does not promise an earlier error for every C
conflict.

### Include suppression and depth

The built-in preprocessor executes `#pragma once` in active conditional branches.
It marks the current file when the directive is reached, so includes above it
are not suppressed retroactively. Later entries in the same C environment are
skipped by the followed file's device/inode identity, including symbolic and
hard links. Strategies without device/inode information use the resolved header
spelling instead; they cannot deduplicate distinct spellings of one file.
Forced `-include` and `-imacros` inputs share that environment's once state.
Other pragmas and `#error` remain ignored. Generated `.ffi.h` files retain their
ordinary `#ifndef` guards.

The top-level input has include depth zero. Up to 200 nested includes are
accepted; an attempted entry at depth 201 returns a preprocessing diagnostic
naming the offending header and the input at the top of its include chain,
rather than exhausting the Lua stack. This also bounds unguarded cycles and
cycles whose only pragma occurs after the recursive include.

`preprocessor_semantic_digest` includes the once policy and the include-depth
limit alongside the configured include paths and predefined macros. The changed
digest invalidates header graphs produced under different preprocessing
semantics without changing a cache format version.
Certified reuse does not observe every byte-identical once-header alias
retarget; see the [incremental cache limit](incremental-compilation.md#semantic-c-header-identity-summary).

The completed C environment is visible throughout the Titan module, including
earlier module-variable closures and initializers. Ordinary Titan import and
variable frontiers, direct source-private visibility, physical provider
identity, and ABI slots retain their existing rules. The compiler does not
copy an imported module's C namespace table: the consumer parses its own real
header chain, which may augment the inherited C definitions.

The module-variable dependency check in `checker/declarations.lua` accepts
foreign member reads, C calls, and allocation/layout pseudo operations.
It checks their evaluated operands just like ordinary expressions: a C
callee does not make a same-module variable argument safe, and like any other
evaluated call it exposes lambdas and other own callables in its arguments.
Implicit Map calls nested in operands strengthen exposure under the same
initializer check; the outer C operation cannot hide them.
No foreign initializer is evaluated by the checker. Existing expression and
call lowering executes it in the module's declaration-order `_init` path,
with the usual checked numeric conversions and GC roots. Imported Titan
members are likewise admissible because the loader initializes dependencies
first; this does not widen the import frontier or source-private visibility.

The resolver owns generated checking headers and their dependency graph; real
header contents and search observations keep normal analysis invalidation,
while temporary checking paths are not persistent dependencies. How checking
trees are staged and how the final `.ffi.h`/`.titan.h` pair is planned and
included is in [generated `*.titan.h` planning](foreign-functions.md#generated-titanh-planning).
A `.ffi.h` never includes a `.titan.h`, and generated module C includes its own
`.ffi.h` before any `.titan.h`.

`cdeclarator` owns exact shared C spelling and `csemantics` owns target numeric
policy. The resolver's `cprobe.Service` owns runner execution, baselines,
temporary artifacts, and source-result memoization; see
[semantic-result caching](c-ffi-expressions.md#analysis-local-and-persistent-semantic-results).

Unsupported C declarations are skipped per member. A later reference reports
the missing member in `ffi`; preprocessing/parsing failures still fail the
module C environment itself.

### Authored foreign typedefs and immutable headers

`Ast.TopLevelForeignTypeAlias` is always source-local. `symtab.foreign_aliases`
is distinct from `type_aliases`; the resolver tracks resolving/resolved state,
rejects cycles, and accumulates dependency-ordered C declarations without
reordering the module AST. Every RHS is raw C and excludes owned storage.
`cdeclarator.render_declaration` preserves real tag/typedef spellings.

An include-only C pass supplies the imported names needed for alias resolution.
The checker then emits the typedefs, clears that preliminary conversion's
C maps/tag owners/memos, and converts the final header. This prevents stale
include provenance from entering cached final graphs. Native baseline validation
uses a new include generation; the final namespace must also contain the exact
requested typedef name, since C compilers may merely warn about declarations
such as `typedef long int;` that introduce no name.

`ffiheaders` descriptors retain `typedef_declarations` alongside direct includes
and dependency descriptors. Their `titan-module-ffi-v2` digest covers the final
contents and dependency digests. Restoration validates the declaration plan and
materializes actual header files; it never reconstructs typedefs from public
Titan metadata. The project manifest (`projectcache.VERSION`, set from
`version.PROJECT_CACHE_VERSION = 6` in `titan-compiler/version.lua`) and the
source-interface manifest (`version.SOURCE_INTERFACE_FORMAT =
"titan-source-interface-v2"`) include this schema and its `file`, `search`, and
`origin` header dependencies. The foreign conversion cache (`foreigncache.lua`,
`VERSION = 8`, kind `ffi-conversion-v8`) retains exact integer macro constants
used in allocation selection and C declaration origins; payloads of another
version are misses.

The C driver maps parsed declaration positions through the preprocessor's
existing output origins (`cdriver.declaration_scope_resolver`,
`c-parser/cdriver.lua`). Runtime identity is nominal: the declaring
header's `realpath` (`"c-header-" .. sha256("physical-header\0" .. realpath)`)
and the C declaration determine identity independently of the consuming Titan
module, and `declaration_scope_resolver` records an `origin` dependency input
for every real header that contributes lines to the parsed output. Generated
FFI headers use their stable logical source identity; temporary checking paths
never become runtime keys. Anonymous aggregates retain distinct
declaration sites. Typedef and tag origins survive conversion and cache restore,
including named payloads reached after an owned pointer or array alias is
unwrapped. Direct imports, source imports, and forced headers follow this same
rule; intrinsic `lua_State` retains its built-in identity. The recursive
`csemantics.same_c_tag_identity` guard uses that same identity when comparing
pointer and callback signatures, including descriptors restored from compiled
metadata. All other C struct/union tags remain nominal; matching spelling or
fields do not make distinct declarations compatible.

This bookkeeping adds no preprocessing pass, macro-environment fingerprint,
layout digest, or native compatibility probe. Compatible C build configuration
is a program precondition, as in ordinary C linking. The origin metadata is not
a certificate of matching C layouts under different compiler options or macros.

### Header file, search, and origin identities

`c-parser/cpp.lua` and `c-parser/cdriver.lua` separate semantic header identity
from physical filesystem observations, using canonical protocol constants from
`titan-compiler/version.lua`:

* **`file` (`version.C_HEADER_FILE_PROTOCOL = "c-header-file-v3"`).** A
  readable regular file has content-only identity
  `c-header-file-v3:sha256:<hex>` (`cpp.header_file_identity`). Device, inode,
  mode, and timestamps do not enter the identity string, so copy, hardlink, and
  symlink publications of identical bytes compare equal. If a former `file`
  input is missing, non-regular, or unreadable when revalidated, its identity
  becomes `c-header-file-v3:unreadable:<search-identity>`.
* **`search` (`version.C_HEADER_SEARCH_PROTOCOL = "c-header-search-v2"`).**
  Every candidate path probed during ordered quote or angle lookup up to and
  including the winning file records
  `c-header-search-v2;exists=<yes|no>;kind=<followed-kind|missing>;open=<readable|unreadable>`
  (`cpp.header_search_identity`). `exists` comes from `strategy:lstat(path)`
  (so a dangling symlink has `exists=yes;kind=missing`), `kind` comes from
  following the path with `strategy:stat(path)`, and `open` comes from
  `strategy:readable(path)`.
* **`origin` (`version.C_HEADER_ORIGIN_PROTOCOL = "c-header-origin-v1"`).**
  Every real (non-generated) header whose lines reach the preprocessed output
  and are resolved by `declaration_scope_resolver` records
  `c-header-origin-v1;real=<realpath>` (`cpp.header_input_identity`).
  Dependency maps key by `kind .. "\0" .. path`, so `file` and `origin` entries
  for the same header coexist in `c_header_dependencies`. If a symlink or an
  ancestor directory link is retargeted to a different `realpath` that happens
  to contain identical bytes, `file` stays equal while `origin` changes (or
  becomes `c-header-origin-v1;unresolved` if missing/unreadable), preventing a
  cached module's nominal C declaration scopes from disagreeing with a fresh
  parse.

Each `file` dependency may also carry a physical `observation` table validated
by `cpp.copy_header_observation` (`cpp.lua`; schema in
`titan-compiler/declarationschemas.lua`):

```lua
{
    precision = "ns" | "coarse",
    size = <integer>,
    physical_identity = "lstat=<kind:mode:dev:ino>;stat=<kind:mode:dev:ino>",
    modified_seconds = <integer>,
    modified_nanoseconds = <integer>,
    changed_seconds = <integer?>,
    changed_nanoseconds = <integer?>,
}
```

The synchronous strategy in `titan-compiler/io.lua` reads metadata through the
runtime's native `titan._stat_precise(path, follow)` whenever the `titan`
support library loads, as it does in every installed `titanc`. The native call
returns integer `mtime_ns` and `ctime_ns` and opaque `dev`/`ino` strings:
POSIX `st_dev`/`st_ino`, or on Windows the volume serial number and the
128-bit `FileIdInfo` file ID (or, when that ID is zero or unavailable, the
`GetFileInformationByHandle` file index), with `ChangeTime` as the change
time. Those observations declare `"ns"` precision and are reusable. A Windows
volume that reports no `ChangeTime`, or a file with no nonzero file ID, gets
no substituted value: the missing fields are omitted and the observation is
`"coarse"`, so the header is read and hashed on every pass. `"ns"` names the
API's integer-nanosecond representation, not the filesystem's timestamp
granularity, which no portable API reports (see [Fresh verification
contexts](incremental-compilation.md#fresh-verification-contexts)). Without the native
library (pure-Lua harnesses), `Sync` falls back to LuaFileSystem and reports
`"coarse"` precision, because LuaFileSystem exposes floating-point seconds
rather than a guaranteed native nanosecond clock; a zero nanosecond fraction
is never used to infer nanosecond precision. The Windows fallback exposes no
device or inode, so no reusable `observation` is saved (`reusable = false`),
while a local `guard` observation still surrounds each read.

`cpp.revalidate_header_input(previous, options)` (`cpp.lua`, re-exported
as `cdriver.revalidate_header_input`) returns
`refreshed_input, err, changed, reason`:

* **Fast path (`metadata_reuses`).** A `file` input reuses its previous
  `c-header-file-v3:sha256:<hex>` digest without reading bytes only when both
  the saved (or `options.header_observations` baseline) observation and the
  current observation have `precision == "ns"`, `saved.changed_seconds ~= nil`,
  and equal `precision`, `size`, `modified_seconds`, `modified_nanoseconds`,
  `changed_seconds`, `changed_nanoseconds`, and `physical_identity`, and
  `strategy:readable(path)` is true.
* **Guarded fresh read (`file_reads`, `file_hashes`).** In all other cases
  (including every build that uses the coarse LuaFileSystem fallback),
  `revalidate_header_input` reads
  the file once per `options.header_validation` pass, checks that `physical_header`
  and `guard` before and after the read are identical (returning
  `nil, "C header changed while it was read: <path>", true, "changed-during-read"`
  on a race), and hashes the bytes via `options.file_digest` or
  `cache_adapter.sha256_binary`.
* **Independent origin recheck (`origin_checks`).** `origin` inputs call
  `strategy:realpath(path)` on every validation pass even when leaf `file`
  observations use the `"ns"` fast path, so directory-symlink retargets over
  hardlinked leaves are always detected.
* **Classified change reasons.** When `changed` is `false`, `reason` is `nil`.
  When `changed` is `true`, `reason` is `"content"`, `"provenance"` (`origin`
  realpath changed), `"missing"`, `"unreadable"`, `"candidate"` (`search`
  changed), or `"changed-during-read"`.

## Header Support Files

The installed compiler ships `<root>/include/titan/ffi.h` and passes
`<root>/include` as both a C-FFI probe path and a generated-C include path.
The driver supplies the configured SDK and Lua source roots explicitly through
`driver.foreign_include_dirs()`; checkout developer mode uses its configured
`titan-runtime` root. Neither the C parser nor probe service walks parent
directories to locate headers. Direct checker embeddings supply the same roots
through their foreign-C configuration. Thus `foreign import "titan/ffi.h"`
uses the selected installation independently of the process cwd. Portable
primitives are contextual Titan types rather than
typedefs in this header. The file includes the matched Lua internal declarations
for `lua_State`, `TValue`, `Udata`, and `CClosure`. `TValue` remains a distinct
C type in Titan's FFI type graph. Private runtime helpers can move values across
that boundary through explicit `value` <-> C `TValue` coercions.

The header also defines typed one-expression `static inline` bridges,
`lmacro_*`, for operations the FFI cannot spell directly. These include real
Lua function-like macros, evaluated where the host preprocessor can see them:
value extractors (`lmacro_thvalue`, `lmacro_uvalue`, `lmacro_clCvalue`,
`lmacro_pvalue`, `lmacro_fvalue`, `lmacro_ccl_f`, `lmacro_getudatamem`), tag
tests (`lmacro_ttype`, `lmacro_ttypetag`, `lmacro_ttisLclosure`,
`lmacro_ttisCclosure`, `lmacro_ttisfulluserdata`, `lmacro_ttislcf`,
`lmacro_ttislightuserdata`), and writes (`lmacro_sethvalue`,
`lmacro_luaC_barrierback`, whose untyped object casts to `GCObject *` rather
than through `obj2gco`, which reads the object's tag under `-DLUAI_ASSERT`).
Other bridges access internal fields of incomplete structs
(`lmacro_get_errfunc`, `lmacro_set_errfunc`) or remove `const` for native
deallocation (`lmacro_unconst`). These are narrow support for trusted
standard-library foreign functions, not general function-like-macro
inference. Add a one-expression bridge here for such an unsupported operation
rather than inferring a function-like macro.

The same header defines `lua_totvalue`, `lua_pushtvalue`,
`lua_pushconstlightuserdata`, `lua_togco`, and `titan_newthread` as small typed
`static inline` functions, so trusted source modules need no exported runtime
symbols for them; `titan_newthread` also reserves the initial coroutine stack
and installs Titan's shared `errorhandler` as the thread's message handler.
Their stack obligations are in the
[trusted Lua C API ledger](ffi-lua-api-followup.md#operation-ledger).

Generated C in installed mode compiles with `-I <root>/include` (checkout mode
uses `-I titan-runtime`), so the emitted `#include <titan/ffi.h>` resolves
through the same normal compiler path.

## TypeList Extraction

`ctypes.lua` preserves this C shape:

* standalone `struct`/`union` declarations nested under `item.spec[1]` are
  registered;
* typedef and extern array dimensions are kept in `idxs`;
* field declarators keep names, pointer suffixes and array suffixes;
* anonymous struct and union members promote their fields in source order;
* bitfields store `bitfield`, `width` and `anonymous`;
* flexible array members are marked with `flexible_array = true`;
* function-pointer typedefs are represented as `functionptr` CTypes;
* header-defined functions are imported like ordinary C functions regardless
  of whether their storage form is `static`, `extern inline`, or bare `inline`;
* function declarators preserve `paramstyle` (`prototype` versus C old-style)
  and an eligible complete list of fixed-parameter spellings;
* simple enum values, including typedef-enum values, are stored on the enum
  type's `values` list.

The C grammar parses each inline struct/union body once before distinguishing
an anonymous member from an ordinary named member. Qualifiers after the body
still require a declarator; a tagged forward declaration is not an anonymous
member. Field promotion uses the existing aggregate conversion path and
propagates nested conversion errors. It does not calculate layout by flattening
storage: generated C keeps the original aggregate declaration, and configured
compiler probes supply authoritative size, alignment, and field facts.

Array extents and enum values are constant-folded when possible. Unknown but
syntactically present extents are preserved rather than thrown away; the checker
treats only numeric extents as known and rejects operations that require a known
bound.

### Enum carriers

C enum descriptors retain their exact tag, typedef, or enumerator-expression
spelling plus the normalized origin header. They are not lowered through the
parser's provisional `int`. On first value use, the checker asks the configured
compiler which ordinary plain/signed/unsigned character, short, int, long, or
long long declaration is compatible. One compatibility query renders the exact
surface at the use, retaining an outer typedef, and uses the consumer's complete
module `.ffi.h` environment. Thus a tag spelling that a
later macro invalidates cannot be certified by an earlier producer or alias.
The query declares that surface once and compares its address type against all
eligible primitive carrier pointer types with `__builtin_types_compatible_p`.
The object-file answer protocol, stable carrier IDs, and cache validation are in
[enum carrier selection](c-ffi-expressions.md#enum-carrier-selection).

Enum object types are accepted only when that carrier's full range fits
`lua_Integer`; `__int128` is deliberately not a candidate. Unused enum
declarations require no probe. Invocation of a C function pointer triggers the
same check for its by-value parameter and result graph; merely storing a pointer
or carrying a spellable wide enum behind one checks declarator spelling, not a
numeric carrier. Transparent Titan aliases resolve without forcing a carrier;
each eventual use rechecks their resolved graph in full or spelling-only mode.

Every enumerator, including one owned by a tagged enum, gets its own exact
`__typeof__((NAME))` view and is validated independently. Its
compiler-selected ordinary expression type establishes that no wider carrier
is involved, and a compile-time array-bound predicate checks the exact value
against the `lua_Integer` range. That selected carrier remains intact through C
promotions and operators; the eventual Titan/Lua coercion performs the range
check. The sole automatic C-enum adjustment is from an enumerator view to its
canonical owning enum. Every directly named object from one anonymous enum
declaration keeps that same canonical owner; its object-specific declarator is
only an exact spelling, never a new nominal type. Generated temporaries and
carrier probes cast through `__typeof__((object))` to obtain the exact
unqualified value type, removing top-level `const`/`volatile` without integer
promotion. An enum surface without any standalone exact spelling, such as a
prototype-local tag, fails closed even when reached below a pointer.

`c99.lua` distinguishes a true `(void)` prototype from `()`. The resulting
declaration-only parameter-name metadata (`paramnames`, merged across
redeclarations, never part of C type identity) is described in
[C prototype metadata](named-arguments.md#c-prototype-metadata).

The C99 grammar is non-reentrant because it uses a module-global typedef table,
reset at the start of each parse. Preprocessor limitations are listed under
[platform constraints](#platform-constraints-and-failure-modes).

## `Type.C*`

`types.lua` registers the C FFI vocabulary with `typedecl`:

```lua
CVoid        = {}
CNamed       = {"tagname"}
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

Declaration origins are not constructor fields: conversion sets `origin` on
named typedefs and aggregates, and `types.c_declaration_origin(typ)` reads
`typ.origin` or `typ._ffi_scope`. `CNamed` is the serialized backreference used
for aggregate cycles (below). `CFunction` deliberately has no parameter-name
field. Callback/function-pointer types remain structural; declaration
spellings stay on raw CTypes until a direct foreign member is built.

`types.resolve_c_typedef` unwraps `CTypedef` chains. The type predicates keep
three different questions separate:

* `types.is_c` detects a direct C value or one nested through ordinary
  Array/Map/Option storage, but deliberately excludes `CModule`, since a C
  module is only a namespace;
* `types.first_c_type` finds C provenance through ordinary storage shapes but
  deliberately stops at boxed Titan callable signatures, preserving the
  representation/lowering question used by `types.is_c`;
* `types.contains_c_ffi_type` is the broader any-C predicate: it also descends
  boxed callable signatures and therefore governs C-bearing function-tag
  identity;
* `types.first_non_exportable_type` performs the recursive public-interface
  scan, accepting portable primitives and named, recursively exportable C
  declaration graphs with stable origin identity;
* `types.is_direct_c` asks whether the value itself has a C representation,
  while `types.has_tvalue_representation` asks whether that representation can
  round-trip through a Lua `TValue`.

The checker and coder use the direct/boxability predicates for lowering.
Structural C provenance remains relevant to interface validation; it must not
send an ordinary Titan Array, Map, option, or callable down a direct-C path
merely because one component contains `COwned`.

The parser represents the Titan constructor `owned foreigntype` as
`Ast.TypeOwned(loc, subtype)`. The checker resolves the foreign operand,
including typedefs, requires `CPointer` or `CArray`, then selects its
pointee/element and countedness. Before removing that outer constructor, it
rejects outer qualifiers, including those inherited through typedefs. In
particular, `owned const *T` and `owned const T[]` are invalid because there is
no construct that allocates and initializes const owned storage together.
It shares allocation eligibility with the
foreign allocation expressions and produces the existing `Type.COwned` runtime
representation. A trailing `?` wraps that owner in ordinary `Type.Option`.
Record fields write `name: Owner?`; optional field-name sugar is absent.
`COwned` remains a direct native representation for lowering, but belongs to
the Titan category for source aliases. Raw foreign typedefs and source foreign
signatures/body locals do not admit owned types.

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
* non-pointer by-value C object expressions -> compatible `foreign const *T` pointers
  by address;
* mutable non-pointer local/formal C variables -> compatible mutable `foreign *T` or
  `void *` out-parameters by address;
* Titan `string` -> C `char *` or `void *`;
* C `TValue` -> Titan `value`, and Titan `value` -> C `TValue`;
* C integers, C floats, and `COwned` <-> `value`;
* C object and function pointers -> `value`; the reverse direction is written
  and unsafe rather than automatic;
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

Written-only conversions include both directions between a C function pointer
and `void *`, GC identity erasure from a Titan Array, Map, nominal record/union,
or function to C `void *`, counted-character-owner to `string`, the character-
pointer case of `void *` recovery, and the explicitly unsafe raw object-pointer
cases. These are recorded in `WrittenCastPlan` and never participate in
recursive Array/Map/Option/function consistency.

Ordinary object-pointer adjustment constructs one qualified pointer view. It
may add qualification, convert an object pointer to `void *`, or convert
`void *` to a qualification-preserving non-character object pointer. A
character-pointer target requires the written plan above. Owner adjustment uses
the same rules, and no path discards typedef-carried `const` or `volatile`.

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

Serialization accepts the closed, header-independent C subset: contextual
`CVoid`, target-profile `CInteger` and `CFloat` leaves, recursively composed
`CPointer`, nonvariadic `CFunction`, and `COwned` descriptors. It emits only
their structural fields and no source scope, header origin, probe, or parser
state. The intrinsic opaque `lua_State` descriptor is additionally accepted
as a pointer pointee, including within a callback signature.

Named `CTypedef`, `CStruct`, and `CUnion` declarations additionally carry a
compact `origin` identity copied from their defining header provenance.
Their recursively exportable fields, fixed `CArray` extents, qualifiers, and
completeness enter the public metadata. Cycles through aggregate pointers use
qualified `CNamed` backreferences; decoding resolves them before publication
and restores field owner/name views. By-value cycles, FAM aggregates,
unspellable anonymous aggregates, enum identities, and noncanonical array
expressions are rejected. Native layout recipes retain the same checked graph.
Neither metadata format transports header contents or emits replacement C
definitions.

After final C-environment extraction, the checker compares imported public C
declarations with the consumer's visible declarations by origin and shape.
An ordinary or binary Titan import therefore needs explicit consumer foreign
headers. Explicit `.titan` imports continue to inherit their generated header
environment. This check never mutates the provider's descriptors.

The compiled-interface decoder independently validates that closed schema as
hostile input before code generation. Primitive spellings and structural
numeric fields must be canonical, parameter lists dense, pointer qualifiers
exact, function ABI/variadic fields the one supported public form, and each C
descriptor must contain only its serialized keys; source-only fields and
unknown extras are rejected. Module
registration then rehydrates each decoded numeric descriptor against the active
target profile: it compares the serialized signedness/rank/width fields and
attaches the checker-only lowering traits, rejecting a mismatch before the
interface is published. These checks, not the availability of a constructor in
the deserialization environment, are the authority for portable C metadata.

An analysis-only embedded provider may supply that target through a
validated build-profile manifest rather than native SDK discovery. The pure
profile boundary does not skip numeric normalization or synthesize traits from
individual module types. Exported profile data contains only version/identity,
C and Lua carrier names, character properties, canonical integer ranges and
widths, and floating representation properties. Import reconstructs all Type
leaves and lowering traits; no caller-supplied annotations survive. Native C
probes independently acquire the live target and reject disagreement with the
semantic host's declared target.

The decoder reapplies `types.has_tvalue_representation` to decoded module
variables and Interface fields. Public record fields and union parts may
instead use valid native nominal storage, including complete non-GC-bearing
C aggregates and fixed arrays. Private fields remain absent from the public
graph. Function pointers have a lightuserdata representation. Nominal physical
storage is selected separately from semantic-interface eligibility.

## Converting C Declarations

`foreigntypes.lua` converts parser CTypes into `Type.C*`.

Contextual primitive type syntax is lowered through the active target profile
by `foreigntypes.surface_primitive` to the same `CVoid`, `CInteger`, and
`CFloat` descriptors used by imported C. It has no `_ffi_scope` or origin
header. Primitive tokens from headers are canonicalized before conversion, so spellings such as
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
fields reuse the same owner. Definitions from the complete module C environment
complete that canonical owner before any module initializer is checked.

Foreign function declarations are stored in the C module's value namespace
as their authoritative `Type.CFunction`. Its `params`, single `ret`, C
`vararg` bit, ABI, prototype/old-style state, return qualifiers, typedef
spellings, and origin header remain on the C graph; there is no projected or
decorated `Type.Function`. The surrounding `Type.ModuleMember` separately
carries the raw declaration's `paramnames` table or `nil`, so parameter
spellings remain outside structural C signature identity.

The checker obtains argument/result reuse from a private `Checker.CallSignature`
view. For a `CFunction` the view exposes its C parameters, maps a resolved
`CVoid` return to zero visible Titan results and any other return to one, has no
Titan input or flexible-result tail, and exposes C `...` only as `c_vararg`.
The view never enters the type algebra, AST's value type, serialization, or
code generation. `Ast.ExpVar` therefore rejects taking a direct declaration as
a value except when an exact C-function-pointer context performs declaration
decay.

C function pointer typedefs are represented as `CTypedef` targets that resolve
to `CPointer(CFunction(...))`. Direct declarations and pointer pointees share
the same C signature representation, but neither is a Titan/Lua callable value:
only `Type.Function` denotes that boxed, traced representation.

## Checker Rules

The checker has FFI-specific handling in a few narrow places:

* `Ast.TypeForeignName` selects unqualified raw C names. Foreign aliases have
  their own module-wide declaration map and resolve independently of ordinary
  Titan aliases, type parameters, nominal names, and the term binding `ffi`.
  Primitive spellings resolve through the configured target profile. Header
  typedefs and eligible tag-only names come from the complete C environment,
  including explicit source dependency headers.
* `Ast.TypeCPointer` requires a raw C pointee and preserves pointer qualifiers.
  Nested constructor syntax is explicitly grouped. `Ast.TypeCArray` carries an
  unsized foreign array spelling, with qualifiers retained; fixed C array
  types arise from imported declarations and allocation inference.
* `Ast.TypeOwned` is the Titan owner constructor described above. Its resolved
  pointer/array operand selects an eligible payload. `void`, direct functions,
  incomplete aggregates, C array-typedef payloads, and nested owners remain
  invalid; FAM structs use the separate `foreign T.new(count)` allocation path.
* `Ast.TypeOption` requires its base to satisfy
  `types.has_tvalue_representation`. This admits `COwned` and other boxable C
  scalars and object/function pointers while rejecting by-value C
  aggregates/arrays and direct C functions before `getslot`/`setslot` code
  generation.
  This predicate treats Arrays, Maps, and Titan function values as already
  boxed and recurses only through `Option`; it does not recursively reject
  their component/signature types. Record fields and union parts instead use
  separate nominal-storage eligibility, which admits complete fixed non-GC
  aggregates and arrays without granting them a general boxed representation.
* `Ast.VarDot` on a `CModule` selects only ordinary C value members.
  `Ast.ExpForeignType` is the dedicated type receiver for `foreign T.new()`,
  `.new_array(n)`, `.sizeof`, and `.alignof`; same-named values do not interfere.
* `Ast.VarDot` on a C struct/union, pointer-to-aggregate, or owned aggregate
  resolves a `Type.CField`. A pure dotted field macro is expanded logically
  through physical aggregate fields first, because C preprocessing precedes
  member lookup; otherwise the checker selects the ordinary physical field.
  Generated C hoists all foreign includes, so macro lookup always uses the
  final module-wide environment even inside an earlier module-variable closure.
  Every aggregate along the selected physical path must be complete in that
  final environment. An active object-like macro with an unsupported final
  expansion is terminal rather than falling back.
* `Ast.VarBracket` accepts C pointers, C arrays with known static length, and
  counted owned C arrays. A marked FAM field additionally accepts 0-based
  indexing while its automatic/owner allocation provenance remains attached;
  erasing the enclosing object to a raw pointer erases that count.
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
* `#exp` accepts C arrays with known static length, counted owned C arrays,
  and provenance-marked FAM field projections.
* `Ast.ExpCall` validates C allocation pseudo-functions through that same
  helper, including the direct-C-function rejection. Their narrow
  `Checker.CPseudoNew` descriptor owns only the pseudo-call parameters/results;
  it is exposed while the member is a direct callee and is never manufactured
  as a `Type.Function` value. Completeness comes from the final module C
  environment, including headers written after an earlier module variable.
* Top-level initializer validation accepts `foreign T.new()` and
  `foreign T.new_array(count)` when their arguments satisfy the dependency rule,
  including imported members/calls and foreign values/calls. A count that reads
  own-module state is rejected like any other own-variable dependency. The
  `Ast.ExpAdjust` introduced by parenthesizing a call is transparent to this
  check. Expression-valued Map keys and values are both checked.
* `Ast.ExpCall` has explicit, separate branches for a direct foreign
  `Type.ModuleMember` whose type is `CFunction` and for a callee whose resolved
  type is `CPointer(CFunction(...))`. Both use the checker-local signature view
  for shared argument/result checking; only the pointer branch records
  `_c_pointer_call`, and neither can fall through to Titan/Lua callable
  adjustment or dispatch.
* Direct nonvariadic C and nonvariadic C-function-pointer calls keep exact C
  arity. The shared expression-list demand may project enough finite values
  from a trailing flexible Titan producer or spread carrier to fill fixed C
  parameters, but it diagnoses a missing fixed argument or an explicit surplus
  expression instead of applying Titan's nil-padding/downward-adjustment rules.
  Codegen evaluates the adjusted lexical list but sends only its fixed
  projections to the C ABI; the spread carrier is never a formal argument. C
  variadic calls retain their independent explicit-scalar/default-promotion
  path and do not accept a Titan spread as their variadic operands.
* A brace-delimited call to a direct C module function uses the member's
  declaration-only `paramnames`; C variadics, unavailable name lists, C
  function pointers, and allocation pseudo-constructors are rejected. Matching,
  omission and the resulting `_named_arg_order` are in
  [named-argument internals](named-arguments.md#checker-elaboration).
* `Ast.ExpVar` rejects imported and source-defined foreign declarations as
  Titan first-class values, but allows a foreign name in a context whose target
  is an exactly compatible C function pointer type. The checker compares the
  target pointee directly with the authoritative `CFunction`, retaining
  typedefs, qualifiers, ABI, prototype style, and C `...`; it never
  reconstructs a C signature from a `Type.Function`. The coder emits the decay
  from the node's `_foreign_function_reference` as a C cast of
  `coder._foreign_reference_name` (`coder/expressions.lua`). Automatic
  adaptation of an ordinary Titan closure remains unsupported; a top-level
  source `foreign function` is already the exact C entry.
* `checkforin` treats generic-for iterator and close slots as C function-pointer
  contexts when a foreign function name appears there. It decays the exact
  declaration into the hidden tuple slot, while an already-materialized pointer
  retains its own pointer/typedef type. Both use the neutral C signature view,
  and their synthesized calls record the authoritative `CFunction` in
  `_c_pointer_call`.
* `trycoerce` and explicit casts recognize mutable address coercion only for
  local/formal C variables. The checker marks those declarations as assigned and
  rejects later capture, so generated C cannot take the address of a boxed
  captured local.
* `checkfuncbody` synthesizes the read-only local `L` for every ordinary
  Titan function-like body. A restricted source foreign body deliberately gets
  neither `L` nor `M`; it must declare any C state parameter explicitly.
  `lua_state_pointer_type` gives ordinary `L` type `CPointer(CTypedef("lua_State",
  ...))`, reusing an imported `lua_State` type when one is already present in
  the module's final C type namespace. This same C environment is available
  inside a lambda in a module-variable initializer. The initializer's ordinary
  Titan import and variable frontier remains in force.

Export checks use `types.first_non_exportable_type`: a public function
signature, variable, alias, or nominal member may contain contextual C
primitives and recursively exportable pointer, foreign-function-pointer,
owned, named aggregate, typedef, and fixed-array graphs. Required header
declarations must be visible in each consumer. Local fields/variants, methods, and nominal functions are
skipped before this check, so a private C-typed record slot or union variant
can remain module-internal. `CModule` itself is
rejected as a first-class value in the same `ExpVar` path as ordinary Titan
modules.

Exportability is separate from physical slot representation. Every module
variable lives in the module userdata's `TValue` upvalue array, so declaration
checking also requires `types.has_tvalue_representation`; a portable C
function pointer satisfies both the export and storage checks. `genluaentry`
applies the same predicate to fixed and flexible results, allowing boxed
function-pointer results. If any result lacks a `TValue`
representation, both the genuine-Lua and strict stack entry raise before the
native entry is invoked, while exact compiled calls continue to use the native
signature directly.

The checker keeps final per-module C type maps and extracted field-macro
classifications produced by the combined parse. A field projection is resolved
against that classification and the receiver's canonical C aggregate. The
checker owns its mutable lookup map, so negative field-lookup memos never
modify the immutable classifications shared by header-cache hits. Include
guards and C scopes decide which declarations exist; no isolated snapshots
are merged by ordinary name, and no source-repeat/prototype-tag escape hatch
is needed to reconcile independently parsed imports. Anonymous and
prototype-local tags keep their actual C scope identities rather than being
equated by spelling.

All C definitions are available to module initializers after the environment
pass. Ordinary Titan variables and import aliases still obey their sequential
frontiers. Real header/search dependency validation and generated-header
ownership remain separate from source-only probe-result caching.

Completed header caches retain a closed extracted-declaration contract:
ordered CType signatures, typedef targets, recursive aggregate fields and tag
scopes, parameter-name availability, exact array/bitfield expressions, macro
constant types, final field-macro classifications and target-profile facts.
Integer expression leaves retain their exact token spelling; the evaluator
reconstructs C99 literal candidates on demand. Floating literal suffixes retain
their C rank, and numeric expressions choose their floating result rank before
publication. The registrar recognizes the bounded GCC/Clang `inf`, `huge_val`,
`nan`, and `nans` builtin constant families used by math headers, including
their `f` and `l` variants and required argument shapes. Expressions containing
floating leaves retain only their inferred C type, so mixed expressions never
enter the exact integer evaluator. Generated C emits the public macro name
and leaves all floating evaluation to the native compiler. A macro cast retains its target
type and a scalar-cast marker, not the parsed operand. Parser bodies, ordinary
source-location maps, raw macro environments, CPP spelling/spacing sidecars,
and registrar bookkeeping do not survive this boundary.

The `c-header-v8` byte payload (`cdriver.HEADER_CACHE_VERSION =
version.C_HEADER_CACHE_VERSION = 8`) uses this same read-only extracted graph,
including declaration origins for typedefs and tags. A live hit shares it,
while a disk restore reconstructs the closed schema once after codec/checksum
and envelope validation. Real `file`, `search`, and `origin` dependencies still
validate the input closure. Forced `-include`/`-imacros` preprocessing state
remains local to its I/O provider because another preprocessing request needs
its mutable macro/output context. A fresh provider rescans those forced inputs
before reusing the extracted header payload; no complete forced preprocessor
context is written to disk.

The `ffi-conversion-v8` payload (`foreigncache.lua`, `VERSION = 8`) retains
final `Type.CModule` members and type members, callable parameter spellings,
reachable C types/layouts/enum carriers, the final C type lookup and file-tag
canonical map, numeric profile, and final field-macro classifications. Its
cache key hashes `kind`, `path`, and `identity` across the module's complete
`file`, `search`, and `origin` input closure, and saved observations pass
through `cpp.copy_header_observation`, which drops legacy observation shapes.
It excludes raw-CType conversion memos, old declaration histories, unused
ordinary-name lookup state, and prototype conversion registries. Restore binds
origins to the current combined include descriptor and reconstructs the final
order-zero type lookup used by module initializers; conversion is already
complete. Each projection/reconstruction uses one memo and cooperative work
budget, without another validation walk on ordinary cache reuse. Old-version
and malformed payloads are cache misses.

## Code Generation

### Rendering C Types

`cdeclarator.render_type_name` and `render_declaration` render C FFI types back
to exact C spellings. A `CTypedef` renders as its typedef name, preserving
headers' preferred spelling for calls and allocation. Declarators are built
recursively for locals and temporaries, because `int (*cb)(int)` cannot be
produced by concatenating a type spelling and a name. `COwned` renders as
`Udata *`; its payload is reached through `getudatamem`. The Titan diagnostic
renderer preserves its logical shape as `owned *T` or `owned T[]`.
`types.tostring` prints legal unqualified source spellings, while
`types.runtime_identity` uses the same formatting rules with each header type's
declaration-origin `_ffi_scope` retained. The owner metatable cache and
registry both use that scoped identity string; the serialized descriptor is
separate runtime type metadata. Portable primitive graphs remain shared, and
header-dependent owners share keys when they refer to the same C declaration.

The general `ctype` function routes C values through `cdeclarator`, applying C
parameter adjustment where appropriate. `COwned` remains a Lua full-userdata
pointer.

### Calls And Variables

`codeforeigncall` (`coder/calls.lua`) requires the callee annotation itself to
be the authoritative `Type.CFunction` and emits a direct C call of the
designator from `coder._foreign_reference_name`. It has no `Type.Function`
fallback; closure tags, brands, strict relays, and adjustment wrappers are
therefore unreachable from this path. Fixed and C-vararg arguments both flow
through `codeforeignexp`. Syntactic string literals, including their checked
pointer casts, use the existing C-literal byte escaping without a temporary;
other Titan strings become `getstr(TString*)`. Literal addresses are unspecified
and need not alias a same-content Titan string. Function-pointer/`void *` casts
keep their native portability adapter rather than being treated as ordinary
byte-pointer literal conversions. Owned C objects decay to payload pointers when
the target is a C pointer, and most `value` arguments consume their
checker-attached plan when the target C type has a sound runtime representation.
An implicit typed Titan projection carries
a strict `GuardPlan`; an explicitly written or genuine-Lua boundary carries
the broader dynamic plan before this foreign sink. A raw C-pointer target has
no implicit guard and must have arisen from an explicit unsafe written cast. A
target C type of `TValue` is special: Titan passes the raw `TValue`
struct by value, for private runtime helpers that already know how to preserve
the owning Lua state and root any collectable payloads.

This path has no flexible-result descriptor. C returns its single ordinary
result (or `void`) according to `CFunction.ret`; any finite projections used to
form its fixed arguments have already been made explicit by the checker.

A checked named direct call freezes its nonliteral arguments into target-typed
C temporaries in lexical order and emits them in formal order. String literals
remain inline because evaluating them has no effects; surrounding argument
effects retain their written order. The same rule applies to adjusted fixed
argument lists and raw foreign bodies; see
[code generation and evaluation order](named-arguments.md#code-generation-and-evaluation-order).
The positional path's post-call `mutable_out_anchor` refreshes for GC-bearing
`TValue` out parameters still apply.

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
raises `cannot call a NULL C function pointer` if the temporary is `NULL`,
converts arguments through `codeforeignexp`, and emits `tmp(args...)`. The
expression dispatcher checks this path before the direct C-module call path so
`ffi.callback_value(...)` is treated as an indirect call when `callback_value`
has a function pointer type.

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

Include spelling is fixed when the header plan is built (see the import
pipeline above); the coder never rediscovers includes from the C types it
renders.

### Casts And Boundary Values

`nativetoforeignexp` handles Titan-to-C conversion:

* C values pass through unchanged;
* `COwned` to a C pointer, including a targetless C vararg argument, becomes
  `getudatamem(owned)`;
* Titan strings become `getstr(tstring)` for C pointer targets and for C
  vararg arguments;
* `nil` becomes `NULL`;
* `value` to C `TValue` passes the raw `TValue` by value;
* non-pointer by-value C or `value` expressions passed to compatible `foreign const *T`
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

The checker accepts both written C-function-pointer/`void *` directions before
`_unsafe_c_pointer_conversion` diagnoses cross-category object/function
reinterpretations. Implicit and contextual function/object pointer conversions
remain rejected. The coder emits `titan_cast_func(target_type, source)` for
either explicit direction, preserving the compiler-specific portability
handling already used by dynamic symbol loading. Ordinary `void *` recovery to
a non-function object pointer instead uses its separately validated C-pointer
plan; the implicit form excludes character targets, while the written form may
select one.

Materializing a GC-identity source protects it through subsequent expression
and call-argument setup, but the resulting raw pointer carries no ownership.
Once the containing generated frame stops anchoring the source, only another
reachable reference keeps it alive. The `Table *`, `Udata *`, and general
`GCObject *` identities are internal runtime addresses, not stable public
layouts or independently managed allocations.

This is the only Titan-union/C boundary. A Titan union may be explicitly
erased to C `void *` as a GC identity, just like a Titan record; it is never
structurally converted to a C `union` or `struct`, and no reverse aggregate
cast is defined.

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

`getslot` and `setslot` know how to box C scalars, object/function pointers, owned
userdata, and by-value C `TValue`s for `value` conversions and for Lua-facing
slots. C numeric `getslot`/strict-get paths share the target-profile predicate
with dynamic coercion, and `setslot` validates carrier representability before
calling `setivalue` or `setfltvalue`; these are not unchecked native casts.
Ordinary C object pointers are exposed as light userdata in `value`;
`COwned` is full userdata. Lua-internal `Udata *` is the deliberate exception:
boxing emits the full-userdata tag for that same object (or nil for NULL), and
unboxing accepts full userdata or nil rather than lightuserdata. C arrays are
not accepted through `value` because there is no array unboxing path.
Function-pointer boxing uses `titan_cast_func(void *, pointer)` before storing
lightuserdata; recovery uses the corresponding exact C function-pointer type.
The ordinary C-to-`value` coercion permits this boxing, but recovery from an
arbitrary `value` still requires the written `unsafe_dynamic_c_pointer` plan.
It checks only lightuserdata/nil, with no runtime C-signature proof. Direct C
function-pointer/`void *` conversions remain written-only, and function
pointers do not participate in object-pointer address coercions. By-value C
structs/unions are not boxable.

An Option over a C integer or float uses a native presence/value carrier across
exact native calls, locals, and nominal storage. Its present arm invokes these
checked helpers only when boxing is requested. Other Options retain their
ordinary `TValue` carrier. `TypeOption` still validates its base's boxed
representation eagerly; this eligibility check does not force an early carrier
conversion. See [Native nominal storage](nominal-storage.md).
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
`foreign const *T` address coercions may likewise materialize by-value aggregate
temporaries because their addresses do not have to survive a separately
evaluated right-hand side.

### Owned C Objects

Source-written `owned *T` and `owned T[]` lower to
`COwned(T, false)` and `COwned(T, true)`. The pseudo-functions remain
checker-only declarations (`Checker.CPseudoNew`) selected by a dedicated
`Ast.ExpForeignType` receiver; their narrow call descriptors are not `Type.Function` values. At
a direct initialized local sink the checker may instead record automatic or
borrowed backing, as detailed in
[target-directed automatic aggregates and fixed arrays](c-ffi-expressions.md#target-directed-automatic-aggregates-and-fixed-arrays).
In an owned plan, `codecpseudonew` allocates Lua userdata directly:

```c
size_t _nbytes = (size_t)_count * sizeof(T);
Udata *_box = luaS_newudata(L, _nbytes, 0);
_box->metatable = hvalue(&_mod->uv[type_slot].uv);
setuvalue(L, stack_slot, _box);
memset(getudatamem(_box), 0, _nbytes);
```

There is no finalizer. Titan owns the lifetime through the Lua GC, and the
payload size in `Udata.len` is enough to reconstruct the dynamic count for
ordinary counted owned arrays. A FAM owner instead allocates the exact host
layout extent and stores its logical element count in one private integer user
value because byte padding cannot recover that count. The userdata is anchored
in a stack slot immediately after allocation, before any later operation can
trigger a collection.

Module-variable initializers may use these pseudo-constructors: `isconstructor`
treats `Checker.CPseudoNew` like a generated constructor, so allocation itself
creates no call exposure. The dependency rule still checks every evaluated
operand, including its implicit Map dispatch, without clearing exposure from
an enclosing call. The allocation occurs once per module instance at
initialization time, and the resulting `COwned` userdata is stored in a
GC-traced module slot.

Each distinct owned C pointee/count shape also gets a hidden module slot holding
a metatable. New allocations stamp that metatable onto the `Udata`, and
`value` casts back to `COwned` compare the metatable before accepting the
userdata. This prevents unrelated full userdata, including Titan records, from
being reinterpreted as C payload memory.

The module initializer constructs each owned-C metatable privately, stamps
it with `TITAN_BRAND` set to integer constant `TITAN_OWNED` (6) and its serialized
`COwned` type descriptor under lightuserdata key `TITAN_MT_TYPE`, installs
its protected display name (`__name` and `__metatable`), and publishes the registry
key only after setup succeeds. When recovering a pre-existing metatable from the registry,
generated code strictly validates the entry: it must be a table whose `TITAN_BRAND`
property is an integer equal to `TITAN_OWNED`, or it errors with `"invalid Titan owned C metatable registry entry"`.
The registry cannot expose a half-initialized identity, and an incompatible or
corrupted entry is rejected. This is a metatable publication rule, not a transaction
boundary for the complete module initializer.

C-bearing callable registry keys follow the same `types.runtime_identity`
policy as owned metatables. A function whose components contain only portable
primitive graphs has a structural key shared across modules. A function that
contains a named header type retains that type's `_ffi_scope`, because the
same C spelling may name unrelated declarations. These are nominal keys, not
an attestation of C layout compatibility under different build settings.
Source-facing `types.tostring` remains unqualified and is not used for these
runtime keys.

Owned payloads keep their declaration origin through owned-alias unwrapping
(see [authored foreign typedefs](#authored-foreign-typedefs-and-immutable-headers)).

Owned storage is distinct from borrowed C pointers, which are raw values the GC
does not manage. Titan has no operation that adopts a foreign-allocated pointer
as an owner.

## Platform Constraints And Failure Modes

* Compile-time POSIX dependency: the configured C compiler's `-E`, `-dM`, and
  `-v` modes, `/dev/null`, and `LANG=C`/`LC_ALL=C`. Ambient `CPATH` remains in
  force; explicit include paths and feature macros belong in
  `TITAN_EXTRA_CPPFLAGS` so checking and generated compilation agree.
* The built-in C parser accepts common GNU/Clang/macOS extensions, but headers
  outside that subset can fail during preprocessing or parsing.
* Some preprocessor paths still raise raw Lua errors instead of diagnostics
  (`#if` operators outside the implemented set, unterminated function-like
  macros, directives whose required token list is absent). `#error` and pragmas
  other than `#pragma once` are ignored.
* Function-like macros are invisible to general Titan FFI inference; the
  `lmacro_*` bridges in `titan/ffi.h` are ordinary C functions whose bodies
  evaluate selected Lua macros. An object-like macro is
  expression-valued through bounded recognized forms, including supported
  integer-constant expressions, floating numeric expressions and the bounded
  math-header constant builtins, and typed dereferenced accessors, or when it
  fully expands to an outer cast to a supported scalar type. A pure dotted
  identifier replacement can become a field projection. Other object-like
  forms are not generally supported.
* Generated C and the module's combined header parse share one ordered authored
  header chain. C identifiers are not renamed or placed in separate native
  namespaces. C implicit conversions and native-compiler diagnostics remain
  part of the FFI contract.
* Parser support is bounded. A declaration outside its C/GNU/Clang subset may
  be unavailable to Titan even if the configured native compiler accepts it.
* Enum selection requires a valid ELF, Mach-O, or ordinary COFF result object.
  Missing, malformed, oversized, duplicated, or relocated result data is
  retryable infrastructure failure. A cached result deliberately does not
  detect external header or compiler-policy changes; clear the source-result
  cache when necessary.

## `typed.lua`

The C parser modules are written with the repository's `typed.lua` DSL, but the
DSL ships disabled (`typed.off()`). Turn it on temporarily when debugging parser
type confusion; do not rely on it for normal compiler execution.
