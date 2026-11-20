# Code generator: overview

`titan-compiler/coder.lua` is a small facade. It loads the code generator
slices under `titan-compiler/coder/` and exports seven functions: `generate`,
`prepare_coverage`, `generate_ffi_header`, `generate_foreign_header`,
`external_symbols`, `interface_external_symbols`, and
`foreign_external_symbols`. `coder/core.lua` owns the slices' shared private
lexical environment and generation policy, so helper names stay out of Lua's
global namespace. The other slices group native names, value and boundary
lowering, flow analysis, nominal storage and calls, Interfaces, numerics,
statements, calls, immediate functions, expressions, declarations, reflection,
nominal codecs, closure transfer, module artifacts, binary metadata, and final
generation.

```lua
coder.generate(modname, ast, static_deps, abi, emit_line_directives, options)
    --> {
          parts = { { index = 0, code = "...", code_bytes = n }, ... },
          private_header = "..." | nil,
          private_symbols = { { symbol = "...", owner = "..." }, ... },
          direct_native_modules = { ... },
          foreign_header = "..." | nil,
          native_bindings = { ... },
          encoded_layouts = "...",
        }
```

(`titan-compiler/coder/generate.lua` `coder.generate`)

- `modname` is the dot-separated logical module name.
- `ast` is the module's AST *after* `checker.check` has decorated and
  rewritten it.
- `static_deps` is the driver's finalized direct-native name set: every owned
  source module compiled into the invocation plus every logical module
  physically carried by a selected static provider. Imports selected from DSOs,
  as well as external installed-source dependencies checked by a library (or
  prospective library `-c`), are absent and use ordinary external `handle` or
  `global` bindings.
- `abi` is the required compiled-module ABI string.
- `emit_line_directives` defaults to true when omitted.
- `options` carries the coverage mode (`coverage`, `coverage_backend`), the
  imported nominal layout plans (`nominal_layouts`), and the
  [translation-unit split](#translation-unit-parts) policy: the maximum part
  count `c_parts` (a positive integer, default `1`), the threshold
  `split_threshold` (a nonnegative integer, default
  `coder.DEFAULT_SPLIT_THRESHOLD`, 2 MiB), and `private_header_output`, the
  path that split parts `#include` (default `<modname as path>.priv.h`). The
  driver passes its effective `--c-parts` value, the threshold, and the
  absolute `<stem>.priv.h` path; only tests override the threshold.

`parts` is a dense array of C translation units whose `index` fields are
`0 .. K - 1` in array order. `code` is the unit's complete C text and
`code_bytes` its share of the module's measured code size. An unsplit module
has exactly one part and no `private_header`. A split module's
`private_header` is the text of the shared `<stem>.priv.h`.
`private_symbols` inventories every module-private linkage name, with an
owner description for diagnostics.
`direct_native_modules` is the set of direct dependencies that the generated
module actually references. `native_bindings` classifies each referenced
dependency as `direct`, `handle` (an explicit dynamic import), or `global` (a
transitive owner reached without its own import). `encoded_layouts` is this
module's physical nominal layout string. `foreign_header` is the generated
`.titan.h` text when the module defines foreign functions.

For a [folder module](folder-modules.md), `ast` is the same dense root list
as for a flat module. It is assembled from independently parsed files and
checked once. The checker may visit declarations in dependency stages, but it
never rearranges the list. The coder therefore observes the logical source
order that defines interface members, module slots, module-variable
initialization, and emission; it has no source-unit node or contributor
context.

The driver (`driver.compile`) writes the result under the
[output directory](output-directory.md), or next to the source when `--output`
is absent. It optionally runs `clang-format`, then performs `#line`
normalization or [coverage marker conversion](native-coverage.md) and invokes
the C compiler ([driver and toolchain](driver.md)).

The checker's rewriting matters constantly here:

- every representation-changing implicit conversion is an annotated
  `Ast.ExpCast`;
- same-representation and open adjustments remain on their checked consumers;
- every statically demanded extra result is an `Ast.ExpExtra`;
- finite/open expression-list demand is recorded on the enclosing sink.

The coder lowers these checker-owned plans; it does not invent conversions or
arity rules of its own ([the type checker](checker.md)). This chapter covers
the shape of the output and the protocols it implements. Related chapters:

- value-level details: [values and the GC](values-and-gc.md);
- per-construct translations: [code generator: constructs](codegen-constructs.md);
- strict and dynamic policies: [type relations and boundary plans](type-relations-and-boundaries.md);
- Array representation and lowering: [Dense Arrays](dense-arrays.md).

One no-`main` CLI invocation may link the objects of several logical modules
into a single [multi-module provider](multi-module-libraries.md). The coder
still runs once per logical module; it never sees a provider AST or emits
aggregate metadata.

## No C AST: templates, `util.render`, and `clang-format`

The coder builds no intermediate representation of the C program. Each
code-generation function returns C source as a Lua string, produced by
substituting into literal templates with `util.render` (`titan-compiler/util.lua`).

- Placeholders are `$VAR` or `${VAR}`.
- Substitution is **recursive**: the replacement text is itself rendered
  against the same table, so templates nest freely.
- A placeholder missing from the substitution table is a hard error,
  `Internal compiler error: missing template variable <name>`, followed by the
  offending template.
- The optional `ignore_missing` flag disables that error. Callers pass it when
  a fragment deliberately leaves placeholders for an enclosing render. The
  main example is `codethrow`, whose `luaL_error` templates leave `$FILE`,
  `$LINE` and `$COL`; some bounds-check and call templates in
  `coder/statements.lua`, `coder/expressions.lua`, and `coder/calls.lua` do the
  same.

Because there is no C AST, template output must already be valid C. Before
returning, `coder.generate` removes blank physical lines that templates leave
after a `#line` directive, so the directive applies to the intended line.
Optional formatting with `titanc --pretty-print` is described in
[Driver and toolchain](driver.md#optional-clang-format-generated-source-formatting).
It disables include sorting because the generator deliberately orders its
includes.

## Anatomy of a generated translation unit

`coder.generate` renders the preamble template (`coder/module.lua` `preamble`)
and an ordered list of emission items. Each item is one complete top-level C
text classified as `callable`, `pinned`, or `metadata`; the classification
drives the [translation-unit split](#translation-unit-parts). This section
describes the single unit of an unsplit module. Three kind-filtered passes over
the top levels fill the item list:

1. imports, variables, records, unions, and Interfaces;
2. nominal static-namespace tables;
3. functions, methods, statics, and foreign functions.

Each whole-root-list walk uses `ipairs`, which preserves the dense
main/contributor order within those categories. Maps whose order has no
semantic effect may still use `pairs`. The pieces appear in this order:

1. **Preamble includes** (`titan-compiler/cpreamble.lua`
   `cpreamble.fixed_includes`): `<stdlib.h>`, `<stddef.h>`, `<string.h>`,
   `<math.h>`, then `luaconf.h`, `lauxlib.h`, and Lua's **internal** headers
   (`lstate.h`, `lgc.h`, `ltable.h`, `ltm.h`, `lfunc.h`, `lstring.h`,
   `lvm.h`, `lobject.h`, `ldo.h`), and `titan.h` from `titan-runtime/`. The
   internal headers are the point: generated code manipulates `TValue`s,
   tables, and the Lua stack directly instead of going through the Lua C API.
   That makes Titan fast and ties each compiler release to one Lua version;
   see [Upgrading the pinned Lua](#upgrading-the-pinned-lua).
2. **Foreign `#include`s** (`$FOREIGNIMPORTS`): one per `foreign import`.
   Absolute paths and local relative headers get quoted includes;
   compiler-provided and system headers get angle includes
   ([FFI internals](ffi-internals.md)). Then `cpreamble.after_foreign_imports`
   defines `TITAN_SOURCE_LOCAL` (hidden visibility) and silences clang's
   `-Wunused-function` and `-Wparentheses-equality`. The `$MODULEPRIVATE`
   definition of [`TITAN_MODULE_PRIVATE`](#storage-and-visibility) follows.
   On ELF, a `#pragma GCC visibility push(protected)` comes next; see
   [the module protocol](#the-module-protocol).
3. **Cross-module declarations** (`$INCLUDES`, filled by
   `init_data_from_other_modules`): `extern` prototypes for the direct
   dependencies' native entries that this module calls, plus the per-image
   address bindings of imported raw foreign functions. Dynamic dependencies'
   bindings live in the module's native payload instead; see
   [Static vs dynamic dependency wiring](#static-vs-dynamic-dependency-wiring).
4. **Forward declarations** (`$SIGS`): the nominal payload declarations, the
   module's `<prefix>native_data` payload type, the prototype of every
   generated function in this module, and
   `extern Udata *<dep>_init(lua_State *L);` per direct import. A split
   module also declares its function-type tag arrays here.
5. **Nominal support**: per record, union, and Interface, the
   `meta_index`/`meta_newindex` metamethod entries that serve field access from
   Lua ([Lua interop internals](lua-interop-internals.md)). A nominal type's
   identity is its per-state metatable, cached in a `_mod` user value, so
   there is no per-type C tag to declare. Generated native payload
   declarations, exact numeric Option carriers, and public-prefix physical
   plans are described in [Native nominal storage](nominal-storage.md).
6. **Function bodies**: the native-convention body of every function, plus
   the stack entries. Every top-level ordinary function and static, local or
   exported, also has a coercive genuine-Lua entry and a strict Titan-generic
   entry, and `_init` builds its canonical closure. Methods have their Lua
   method entry plus the native, Lua, and strict bound-value trampolines.
7. **Module metamethods**: one `meta_index`/`meta_newindex` pair
   (`coder._module_metamethod_name`) installed on the module `Udata`'s
   metatable. It serves all members: variables, functions, and public nominal
   namespaces.
8. **`<prefix>_abi`**, **`<prefix>_abi_value`**, **`<prefix>_types`**,
   **`<prefix>_layouts`**, **`<prefix>_init`**, **`luaopen_<prefix>`**: the
   module-protocol functions, described below. One final DSO may contain this
   complete set for several logical modules; each set remains independent.

### Mixed-source `#line` attribution

A folder module's generated C contains functions and statements from several
Titan files. `emitline(node)` (`coder/names.lua`) therefore works per node. It
C-quotes `node.loc.filename` and emits `#line` at safe physical-line sites
such as function entries, statements, calls, `raise`, and related throw paths.
It never installs one directive for the whole translation unit and never
stamps expression fragments that may be embedded mid-line. The filename
changes as root nodes and nested bodies from different contributors are
emitted, so compiler diagnostics, DWARF, and libbacktrace frames identify the
actual source file and line.

`definitionline(loc)` (`coder/names.lua`, installed in the shared `coder.core`
environment) additionally stamps a `#line` directive immediately before the
signature of every generated C function definition, on **both** targets and in
generated `.titan.h` foreign headers. Source-owned definitions receive their
real declaration or site location; source-less helpers (module protocol,
metamethod, and init/opener functions, unlocated adapters, and the four inline
helpers in `cpreamble.definition_prefix`) emit
`#line 1 TITAN_GENERATED_C_FILE`, where each emitted part defines
`TITAN_GENERATED_C_FILE` to its actual `<stem>.c` or `<stem>.partN.c` filename
(avoiding Clang's `__BASE_FILE__`, which follows prior `#line` changes). This
prevents a function prologue (such as `luaC_checkGC` or argument/root setup
before the first statement's `#line`) from inheriting the preceding definition's
trailing `#line` across folder contributors, so DWARF, libbacktrace, and the
browser trace table's declaring basename for a function body (`first[body]`) name
the function's own declaring `.titan` file and definition line.

`definitionline` and the part preamble follow exactly the policies below:
`definition_stamps()` is false under coverage generation and under a false
line-directive policy, so those modes emit neither a definition stamp nor the
`TITAN_GENERATED_C_FILE` macro. Within a definition, everything before the
first body statement — the signature, the GC poll, variable anchors, stack
reservation, and argument checks — therefore carries the definition's own
location rather than another file's.

A foreign-header plan is one immutable published unit: `{policy, contents,
recipe}` plus `digest`, the canonical identity of that recipe
(`coder._foreign_header_digest`, internal). Only the planning path produces and publishes
it — disk bytes and recipe together — and nothing is cached on the AST, so no
earlier build can leave a header behind to be relabelled. Every render receives
an explicit policy (`coder._emission_policy`, applied by
`coder._with_emission_policy`; both are internal helpers, not public facade APIs); the driver derives it with
`driver.header_policy(coverage)` from the same `EMIT_LINE_DIRECTIVES` option and
per-module coverage selection that its C uses, for immediate and graph
planning, the per-module worker, the CLI restore path, and checking headers
(never coverage). Plans that a direct compile must not reuse are simply not
passed: `driver.compile` plans under its own policy, and `coder.generate`
consumes a supplied plan verbatim or raises if its policy differs from the
generation it is embedded in — it never re-renders or falls back.

The policy is part of the header recipe digest, not of the producer interface
digest: the interface digest keeps hashing the rendered header text only, so a
policy change that leaves that text identical does not over-invalidate every
consumer of a declaration-only header. A producer is invalidated through its
own recorded configuration (which includes `emit_line_directives` and the
native coverage policy) and a consumer through changed header text. A published
plan also records the checked module object it was rendered from, and a compile
reuses it only when that same object and the policy match. A different checked
buffer — a changed foreign body or signature, or an unsaved/overridden source
that happens to share a filename — always replans and republishes rather than
reusing the old header; disk contents are never consulted.

`emitline` and `definitionline` return nothing in two cases:

- **Coverage generation.** Coverage uses scoped region metadata instead; see
  [native coverage](native-coverage.md).
- **A false line-directive policy.** The public `--no-line-directives` flag and
  the `TITAN_NO_LINE_DIRECTIVES=1` build setting use this path, so native
  diagnostics show physical generated-C coordinates. `coder.generate` resets
  the policy at the start of every generation, so it cannot leak between
  compiler calls in one Lua process.

The cost of disabling directives is deliberate. Traceback reconstruction uses
Titan-attributed debug filenames to keep ordinary native Titan frames, so this
mode can drop them from logical traces even though the symbol-to-display-name
registry remains populated.

### Deterministic emission order

Generated C is a function of its inputs alone: the same module always yields
byte-identical part files, private headers, and foreign headers. Lua randomizes
its string hash seed per process, so no emitter walks a string-keyed registry
directly. `coder._sorted_keys` supplies the bytewise-sorted key order for the
emission sites whose order reaches generated C: the per-record and per-Interface
method maps, nominal and owned-C metatable recovery blocks, static-dependency
`extern` declarations and their binding code, and bound method/function
entries. Registries that carry a source order keep it — declarations, fields,
union parts, and the discovered adapter/Array-writer lists. Sorted emission
orders independent groups deterministically without altering any emitted
declaration or statement, and `spec/coder/codegen_determinism_spec.lua`
generates one module with every such registry in separate processes and requires
byte equality.

A trimmed but real example of an unsplit module (elisions marked `...`). This
module:

```titan
-- counter.titan
x = 1
function inc(n: integer): integer
    return n + x
end
```

generates:

```c
#include <stdlib.h>
...                /* C library and Lua internal headers, titan.h, pragmas */
#define TITAN_MODULE_PRIVATE static
...
#if defined(__ELF__)
#pragma GCC visibility push(protected)
#endif
...                /* $SIGS: native payload type and every prototype */
lua_Integer counter_\u2133_inc_titan(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer _param_n);
TITAN_MODULE_PRIVATE int counter_\u2133_inc_titanentry_lua(lua_State *L);
...

TITAN_SOURCE_LOCAL const void *counter_module_identity(void) { ... }

lua_Integer counter_\u2133_inc_titan(lua_State *L, Udata *_mod, CClosure *_fn, lua_Integer _param_n) {
    ...
    _tmp_1 = intop(+, _param_n,  ivalue(&_mod->uv[0].uv));
    ...
}

TITAN_MODULE_PRIVATE int counter_\u2133_inc_titanentry_lua(lua_State *L) {
    ...    /* argument count adjustment, error handler, dynamic argument plan */
}

TITAN_MODULE_PRIVATE int counter_\u2133_inc_titanentry_strict(lua_State *L) {
    ...    /* hidden original closure plus strict argument guards */
}

TITAN_MODULE_PRIVATE void counter_\u2119_transfer_entry_0_project(lua_State *L, CClosure *_fn) { ... }
TITAN_MODULE_PRIVATE void counter_\u2119_transfer_entry_0_restore(lua_State *L, Udata *_mod, int _capture_base) { ... }
TITAN_MODULE_PRIVATE const TitanTransferEntry counter_\u2119_transfer_entries[] = { ... };
TITAN_MODULE_PRIVATE const TitanTransferModule counter_\u2119_transfer_manifest = { ... };
TITAN_MODULE_PRIVATE int counter_\u2133_meta_index(lua_State *L) { ... }    /* module member read  */
TITAN_MODULE_PRIVATE int counter_\u2133_meta_newindex(lua_State *L) { ... } /* module member write */
static const unsigned char counter_\u2119_titan_metadata[] = { ... };      /* .titan.meta section */
int counter_types(lua_State* L) { ... }     /* serialized interface, below  */
int counter_abi(lua_State* L) { ... }       /* returns TITAN_ABI_VERSION */
...
TITAN_MODULE_PRIVATE const char counter_\u2119_functag_0_tag[] = "Function({Integer()},{Integer()},false,nil,nil)";
TITAN_MODULE_PRIVATE void counter_\u2119_register_preload(lua_State *L) { ... }

Udata *counter_init(lua_State *L) { ... }

int luaopen_counter(lua_State *L) {
    titan_invalidate_backtrace_state(L);
    Udata *mod = counter_init(L);
    setuvalue(L, s2v(L->top.p), mod);   /* require returns the module Udata */
    L->top.p++;
    return 1;
}

TITAN_MODULE_PRIVATE void *counter_\u2119_native_symbol(const char *symbol) { ... }
#if defined(__ELF__)
#pragma GCC visibility pop
#endif
...                /* driver-appended .titan.source record */
```

### Generated names

Module protocol names come from `mangle_qn` (`coder/names.lua`), which replaces
`.` and `-` with `_`. The driver has already restricted every logical
component to `[A-Za-z_][A-Za-z0-9_-]*`, so this cannot admit arbitrary path or
template bytes. Module `foo.bar` yields `foo_bar_init`, `foo_bar_abi`,
`foo_bar_types`, `foo_bar_layouts`, and `luaopen_foo_bar`.

Callable names have two structural boundaries:

- `_function_prefix` separates the flattened module prefix from the callable
  with the C99 UCN `_\u2133_` (U+2133 SCRIPT CAPITAL M). A top-level function
  `f` becomes `foo_bar_\u2133_f_titan`, `..._titanentry_lua`, and
  `..._titanentry_strict`. A source `foreign function f` owns only the first
  spelling.
- `_nominal_function_prefix` then separates a record, union, or Interface
  owner from its member with `_\u2131_` (U+2131 SCRIPT CAPITAL F), as in
  `foo_bar_\u2133_Point_\u2131_move_titanmethod`. Statics, synthesized record
  `new` and union variants, ordinary methods, bound native/Lua/strict entries,
  and Interface bound entries all use this hierarchy. The nominal metamethods
  are synthetic `meta_index` and `meta_newindex` members in the same family;
  module metamethods use only the module boundary.

Role suffixes:

| Callable | Native | Lua entry | Strict entry |
| --- | --- | --- | --- |
| function | `_titan` | `_titanentry_lua` | `_titanentry_strict` |
| static | `_titanstatic` | `_titanentry_luastatic` | `_titanentry_strictstatic` |
| method | `_titanmethod` | `_titanentry_luamethod` | none |
| bound method value | `_boundmethod` | `_titanentry_boundlua` | `_titanentry_boundstrict` |
| lambda | `<prefix>\u2119_lambda_<n>` (`lambda_register`, `coder/declarations.lua`) | `..._titanentry_lua` | `..._titanentry_strict` |

Neither U+2133 nor U+2131 can occur in Titan's ASCII identifier alphabet, so
the boundaries stay injective even when source names contain underscores.
Generated C keeps the UCN spellings. `coder._linkage_symbol_name` converts
them, and the private boundary below, to UTF-8 `ℳ`, `ℱ`, and `ℙ` for
object-file, DWARF, libbacktrace, display-name registry, and native-tool
comparisons.

Synthetic module-private helpers that have no source owner use a third
boundary. `coder._private_symbol(modname, family, id)` spells them
`<prefix>\u2119_<family>` or `<prefix>\u2119_<family>_<id>` (U+2119 DOUBLE-STRUCK
CAPITAL P). The families are:

| Family | Definition |
| --- | --- |
| `native_symbol` | the module's native-symbol resolver (`coder/binary.lua`) |
| `register_preload` | the helper that registers the module's preload descriptor |
| `titanentry_module_initializer` | the computed module-initializer body; it keeps the `titanentry` stack marker |
| `lambda_<n>` | a hoisted lambda's native entry; its Lua and strict entries append `_titanentry_lua`/`_titanentry_strict` |
| `callable_adapter_<n>` | a realized non-exact callable adapter site and its strict relay |
| `array_writer_<n>` | a constructed Array element writer |
| `transfer_entry_<n>` | a closure-transfer entry; its functions append `_project`/`_restore` |
| `transfer_entries`, `transfer_codecs`, `transfer_manifest` | the closure-transfer entry table, nominal codec table, and module manifest |
| `functag_<n>_tag` | a function-type tag string |
| `interface_pair_<concrete>_to_<interface>_adapter_<slot>` | an adjusted Interface method adapter |
| `foreign_inline_<name>` | the `static inline` direct-call helper of local foreign function `<name>` ([foreign functions](foreign-functions.md#contents-and-inline-classification)) |

The family words are fixed, ids are decimal or a Titan identifier, and
Interface fragments come from `coder._interface_symbol_fragment`, so names
stay injective under the module prefix. Source-owned callables, accessors,
metamethods, codecs, reflection helpers and Interface wrappers keep their
`ℳ`/`ℱ` names even when they are module-private.

`coder.external_symbols` inventories the non-file-local subset of the public
names plus each module protocol. Library-mode orchestration in the `titanc`
script compares that exact set before code generation, including flattened
module-prefix and cross-family protocol collisions, rather than waiting for
the linker to report duplicate definitions. Module-private names are checked
separately through `private_symbols`; see
[Storage and visibility](#storage-and-visibility).

### Failure-only ASan generated-C mapping

The Linux sanitizer workflow keeps ordinary per-node `#line` directives
enabled, because traceback gates need the logical Titan frames. After a
failure, a mapper recovers physical generated-C lines from saved objects and a
line-identical shadow compile, without rerunning the failure. The snapshot,
proof steps, and refusal conditions are in
[Continuous integration](continuous-integration.md#sanitizer-ownership-and-failure-diagnostics).

## Translation-unit parts

A module can be split into several C translation units so that one large
module compiles as several parallel jobs (`coder.generate`, end of
`coder/generate.lua`). The split happens after emission and moves whole
emission items only. It never parses rendered C or divides a function.

**Item classes.** Every emission item has one of three classes:

- `callable` items are movable. Each is one complete top-level C text: a
  top-level function, method, or static with its Lua, strict, and bound
  entries; one of the generated function groups of a record, union, or
  Interface (field accessors, metamethods, the `__call` entry, codecs,
  reflection helpers); the out-of-line definition of a source foreign
  function; a hoisted lambda with its three entries;
  one closure-transfer `project`/`restore` pair; an Array writer; an Interface
  pair wrapper or adapter; a realized callable adapter with its transfer
  entry; or the module `meta_index`/`meta_newindex` pair.
- `pinned` items stay in part 0 because they define data or a single module
  identity: the module identity function and its static token, the computed
  module-initializer body, the transfer entry, codec, and manifest tables,
  `<prefix>_types`, `<prefix>_layouts`, `<prefix>_abi`, `<prefix>_compatibility`
  and the public slot constants, imported foreign-binding pointers, the
  function-type tag strings, `<prefix>_init` with the preload helper,
  `luaopen_<prefix>`, and the native-symbol resolver. A large initializer is
  never divided.
- The `metadata` item, the `.titan.meta` section payload, also stays in part 0.

**Size and threshold.** An item's `code_bytes` is the byte length of its
rendered text, including its `#line` directives; the `metadata` item counts
zero. The rendered preamble, the `$SIGS` declarations, and the `.titan.source`
record that the driver appends to part 0 are not counted. The module total is
the sum over all items. A module is split only when `c_parts > 1`, the total is
at least `split_threshold`, and at least one item is movable; it then gets
`min(c_parts, 1 + #movable)` candidate parts.

**Unsplit output.** Without a split, the single part is the rendered preamble,
every item in emission order, and the closing ELF visibility pop. Its
`code_bytes` is the module total, and `private_header` is `nil`. Generation
with `c_parts = 1` and generation below the threshold produce byte-identical
text.

**Partition.** Part 0 starts with every pinned and metadata item and a load
equal to the pinned bytes. Movable items are sorted by decreasing `code_bytes`,
with ties in source order, and each goes to the least-loaded part; on equal
load the lowest part index wins. Each part then restores source order among
its own items. Empty parts are dropped and the rest are renumbered densely, so
the result has at most `c_parts` nonempty parts. A part's `code_bytes` is its
final load, which the driver uses as the compile-cost estimate.

**Split output.** `private_header` holds
`/* Generated by Titan: module private declarations. */`
(`coder.PRIVATE_HEADER_MARKER`), an include guard
`TITAN_GENERATED_PRIVATE_<MANGLED MODULE>_HEADER_H`, the complete rendered
preamble, and an ELF `#pragma GCC visibility pop` before the guard ends. The
header therefore carries the includes, the split `TITAN_MODULE_PRIVATE`
definition, typedefs, `static inline` preamble helpers, cross-module
declarations, every prototype, and `extern` declarations of the function-type
tag arrays. Each part, part 0 included, is
`#include "<private_header_output>"`, an ELF
`#pragma GCC visibility push(protected)`, its items, and the matching pop.

### Storage and visibility

Every generated module-private definition that another part may reference is
declared with `TITAN_MODULE_PRIVATE`, emitted by the preamble's
`$MODULEPRIVATE` placeholder:

| Mode | `TITAN_MODULE_PRIVATE` |
| --- | --- |
| unsplit | `static` |
| split, `_WIN32` | empty |
| split, GCC or Clang elsewhere | `__attribute__((visibility("hidden")))` |
| split, other compilers | empty |

Unsplit modules therefore keep internal linkage. Split modules link the parts
with hidden external symbols on ELF and Mach-O. On PE the macro adds nothing:
the DLL link uses `--exclude-all-symbols` and an explicit `.def`, so only the
fixed module entries and public raw foreign functions are exported
([Windows build](windows-build.md)). Public native entries and module
protocol functions keep ordinary external linkage. Local source entries that
other modules may reach keep `TITAN_SOURCE_LOCAL`.

Each function-type tag string is a pinned `TITAN_MODULE_PRIVATE` definition in
part 0, and a split module's header declares it `extern`, so every part
publishes the same tag address.
The remaining `static` objects are function-local statics, section payloads in
part 0 (`.titan.meta` and `.titan.source`; external on Wasm so that final
images drop them, and named with the private `\u2119` separator on every target
so that they never meet a module's protocol functions or an authored C name;
see [program images](browser-target.md#program-and-test-images)),
and preamble helpers, including
the `static inline` direct-call helpers of local foreign functions. Those
helpers' addresses are never taken: every pointer to a foreign function names
its single out-of-line definition; see
[Foreign functions](foreign-functions.md#contents-and-inline-classification).

`private_symbols` lists every `TITAN_MODULE_PRIVATE` linkage name and each
imported foreign-binding pointer, in UTF-8 linkage spelling, with an owner
description. It includes `ℳ` and `ℱ` names as well as `ℙ` names. The object
record stores it, and the driver checks the union of all modules' public and
private symbols across the link set before any output changes; see
[batch planning](driver.md#batch-planning-drivercompile_modules).

## Three entry roles per first-class Titan function

Every first-class Titan function has three entry roles:

1. the typed native-convention function used by static/direct and exact-tag
   first-class calls;
2. a coercive Lua-stack entry used when genuine Lua calls the source closure;
   and
3. a strict Titan-generic Lua-stack entry used after a branded exact-tag
   mismatch.

The two stack entries share one generation template but apply different
checker-produced policies. The canonical **source** closure's public
`CClosure.f` is the coercive entry; its declaration-specific strict entry is a
light C function stored in the final upvalue. Local top-level functions and
statics get the same entries and closure layout in a source-private module
slot, but are not exported through the module member map. Unbound methods use
their native/Lua method entries; their first-class bound values receive native,
Lua, and strict bound trampolines.

A realized non-exact callable adjustment reuses these roles instead of adding a
fourth ABI entry: its native pointer names a target adapter, its `CClosure.f`
copies the source's coercive entry, and its final upvalue names a
consumer-local strict relay. Eligibility, construction, and fallback are in
[Closure adjustment wrappers](closure-adjustment-wrappers.md).

### Cross-state closure transfer metadata

`coder/closure_transfer.lua` emits one immutable `TitanTransferModule` manifest
per generated module (`coder._transfer_emit_manifest`), named
`<prefix>\u2119_transfer_manifest`, beside its `<prefix>\u2119_transfer_entries`
table when it has entries. Both are pinned `TITAN_MODULE_PRIVATE` data in part 0. The module's
native-symbol resolver returns the manifest for
`TITAN_TRANSFER_MANIFEST_SYMBOL`.
Ordinary closure allocation and invocation do no extra lookup and keep their
upvalue layout.

Each first-class source function, lambda, bound method, and realized callable
adapter has a `TitanTransferEntry` (`titan-runtime/transfer.h`) holding:

- its native and strict entry pointers, which serve as the lookup key;
- its immediate capture count;
- a generated `project` function; and
- a generated `restore` function.

When it has generated codecs, the module also emits one pinned `TITAN_MODULE_PRIVATE`
`TitanTransferCodec` array, `<prefix>\u2119_transfer_codecs`, with one entry per
generated record or union codec (`coder/nominal_codec.lua`): qualified name,
`is_union`, and the generated encode and decode functions. The
manifest does not reach this array. Instead, the nominal's metatable
registration binds `TITAN_MT_CODEC` to the entry's address; see
[generated nominal codecs](protobuf-library.md#generated-nominal-codecs).

**Projection.** One generated function projects **all** immediate semantic
captures onto the source stack, boxing each with `setboxed`, before custom
hooks run. It visits capture values, never module userdata or a mutable cell's
bytes as if they were a Lua value: a boxed capture is read through `box_read`.
The checker records capture conversion plans and refreshes them after generic
erasure. Native integer bits and long-double text use the same exact
projection representation as reflected native fields. Generated code rejects a
Lua-managed `Udata *` before native-pointer projection, including typedef
spellings and present optional pointers, so the trusted GC-bearing pointer
representation never becomes a borrowed lightuserdata address. An absent
optional projects and reconstructs as nil. Unsupported reconstruction
conversions also fail during projection, before the packet crosses the
boundary.

**Restoration.** One generated restore function consumes a contiguous capture
run. It converts and roots every internal slot, allocating a fresh box for each
mutable capture with `newbox`/`box_write`, before allocating the final closure.
The fresh-white closure receives its complete header, slots, and strict trailer
without intervening allocation, then becomes rooted before the allocation debt
check. Function tags come from the destination module's per-state caches.

**Adapters.** An adapter entry projects only its immediate source closure.
After that source is reconstructed, the generated adapter callback repeats the
ordinary prefix-copy construction with the destination adapter's module, tag,
native, and strict entries. Private wrapper layout is never serialized.

What may transfer, how packets name modules and tokens, destination
resolution, and provider-image lifetime are transfer policy; see
[Closure snapshots](transfer-library.md#closure-snapshots).

### The Titan-native function and its calling convention

The authoritative statement is the comment above `codefuncdec` in
`titan-compiler/coder/declarations.lua`. `function_sig` (`coder/flow.lua`)
produces this shape:

```c
RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, [Udata *self,]
          <ctype(param_1)>, ..., <ctype(param_n)>,
          [TitanVargX *_varargs, int _start,]
          <ctype(ret_2)> *_outparam_2, ..., <ctype(ret_m)> *_outparam_m,
          [TitanVargY *_flexout, int _flexwant]);
```

- `RETTYPE` is `ctype(rettypes[1])`, the unboxed C type of the first result
  (`lua_Integer`, `TString*`, `Table*`, `TValue`, `Udata*`, …; full map in
  [values and the GC](values-and-gc.md#the-ctype-map)). A function returning
  only `nil` returns `int` and ends with `return 0;`. A flex-only function
  returns C `void` and writes its caller-owned descriptor.
- The input vararg pair, when present, precedes the fixed result
  out-pointers. The flexible output pair, when present, comes last.
  `TitanVargX` and `TitanVargY` stand for the element-specific descriptor types
  (`TitanVargInteger`, `TitanVargString`, …).
- `_mod` is the callee's **own** module `Udata`. A cross-module caller passes
  it from one of its user values.
- `_fn` is the **callee's own closure**: the `CClosure` of the function value
  being invoked, whose `upvalue[4..]` hold its captures (see
  [closures and captured variables](#closures-and-captured-variables)). It
  comes immediately after `_mod` and before the method `self`. *Every* Titan
  function takes it, even when the body never reads it, because the fast
  value-call path dispatches purely on the function-type tag, so all native
  entries of one `Type.Function` must share one ABI.
- `Udata *self` exists only for methods (`Type.Method`) and is named
  `__self__` in the generated body.

`_fn` at a call site depends on the path:

- **`NULL`** on a static direct call (`codecall`): a top-level
  function, method, or static reached by name has no closure to pass;
- **the callee value itself** (`_vc_callee`) on the fast value-call path
  (`codevaluecall`);
- **`clCvalue(s2v(func))`** in either Lua-stack entry (directly for the
  genuine-Lua entry, through the hidden carrier for the strict entry), which
  then derives `_mod = uvalue(&_fn->upvalue[0])`.

Real signatures from a generated module:

```c
TString*    packtest_\u2133_Point_\u2131_getname_titanmethod(lua_State *L, Udata *_mod, CClosure *_fn, Udata* __self__);
lua_Integer packtest_\u2133_two_titan(lua_State *L, Udata *_mod, CClosure *_fn, TString* *_outparam_2);
void        packtest_\u2133_strings_titan(lua_State *L, Udata *_mod, CClosure *_fn,
                          TitanVargString *_flexout, int _flexwant);
```

A Titan-to-Titan call is therefore an ordinary C call: no `CallInfo`, and no
boxing of integers, floats, or booleans. Inputs are evaluated in lexical
order. When later setup is effectful, `coder._stabilize_input_code` freezes
the first-class callee or receiver and the affected inputs in untraced C
temporaries; a pure trailing suffix may stay as direct C expressions. The
caller keeps every GC-bearing input reachable until the call returns: it
publishes an input in a slot of its own frame only when that input has no
root that later code cannot clear, so a parameter needs no root in the
callee. The caller also roots every live GC-bearing result immediately after
return. The complete rooting protocol, including which inputs are already
stable, stack rebasing after native calls and the VM transport slots of the
slow paths, is in
[values and the GC](values-and-gc.md#calls-c-only-inputs-immediate-result-roots-and-vm-transport).

### Direct calls and lexical evaluation order

Positional direct calls follow the checker's adjustment plan. Every explicit
argument is evaluated once in lexical order. Surplus expressions are evaluated
only for effect; only the fixed prefix and any accepted input tail reach the
native call. On the result side, `codecall` (`coder/calls.lua`) allocates the
fixed holders that the declared ABI requires, publishes only the
consumer-visible projection, and, for a flexible producer, allocates a typed
caller-owned buffer sized to the finite demand or to the bounded open budget.

Named calls reach `codecall` already normalized to formal order, with the
lexical order kept in `_named_arg_order`; `named_ordered_call_args` evaluates
and freezes them in lexical order. Direct foreign calls use
`codeforeigncall`, and calls through `CPointer(CFunction)` use
`codecfunctionptrcall`; neither emits closure tags, brands, strict relays, or
adjustment wrappers. See
[named-argument code generation](named-arguments.md#code-generation-and-evaluation-order)
and [FFI internals](ffi-internals.md).

### Calling function values (`codevaluecall`)

Calling a first-class function value is the one Titan-to-Titan call form that
may deliberately fall back to Lua's ordinary call machinery. The callee
expression has static type `Type.Function`, but its runtime value is a boxed
`TValue`: a Titan `CClosure`, a Lua closure, a Lua C function, or an object
with a `__call` metamethod. `codevaluecall` (`coder/calls.lua`) therefore
emits three branches. A non-exact Function adjustment is lowered before this
dispatch as an `Ast.ExpCast`
([Closure adjustment wrappers](closure-adjustment-wrappers.md)).

**Exact fast path.** It is tested first and marked `TITAN_LIKELY`. It requires
a `CClosure` with at least the five minimum Titan upvalues and raw pointer-bit
equality between upvalue 1 and the tag for the callee expression's static
type:

```c
if (TITAN_LIKELY(runtime_tag == <function-type tag>)) {
    ...
}
```

- The tags are canonical pointers cached in the current module's native
  payload. `function_type_tag` allocates the cache entry; initialization
  publishes or recovers its immutable candidate through the Lua registry, so
  source-linked and `.so`-loaded modules agree on the pointer for the same
  exact type.
- All shapes use `types.runtime_identity(ftype)`, which keeps nested
  declarator qualifiers and adds C declaration origins to header-dependent
  shapes. The same C declaration shares identity across modules.
- Exact pointer equality is sufficient evidence for the private Titan layout,
  under the same trusted-debug/C-API invariant as the closure upvalues
  themselves. The hot branch neither queries the registry nor rechecks the
  module, native pointer, brand, or strict-trailer slots, and needs no `ttis*`
  discriminator.
- Matching the tag is stricter than gradual consistency. A Titan
  `function (value): (integer)` viewed as `function (integer): (integer)`
  through a dynamic `value` round trip has no static source Function edge, so
  its tag does not match. A checker-approved non-exact `A -> B` cast may
  instead realize a closure tagged B, which *does* enter this branch.

Once the predicate holds, the call is again an unboxed native call:
`_vc_callee = clCvalue(&fn)`, `_vc_mod = uvalue(&_vc_callee->upvalue[0])`, and
the native entry pointer in `upvalue[2]` is cast to the exact `function_sig`
typedef and called with `L`, `_vc_mod`, `_vc_callee`, the evaluated native
arguments, and the usual out-parameters. Passing `_vc_callee` as `_fn` is what
lets anonymous closures and bound-method trampolines read their captures on
the same fast branch as top-level function values.

**Branded strict path.** Only after the exact comparison fails does the coder
test the type-independent closure brand in fixed `upvalue[3]`. The brand is
the opaque 64-bit pointer sentinel `TITAN_BRAND` (`titan-runtime/titan/ffi.h`),
never dereferenced. The coder reads the slot only after checking the
five-upvalue minimum. Raw equality is then enough to trust the rest of the
private layout. An unrelated C closure would need both the upvalue count and
the exact random sentinel in the exact slot.

The branded path pushes the closure's trailing strict light C function as the
VM callee, then the original closure as one hidden first argument, then the
evaluated ordinary arguments.

- For an ordinary source closure, the declaration-specific strict entry
  validates the carrier's header, trailer, coercive entry, and exact source
  tag; it does not repeat the brand check.
- For a realized wrapper, the consumer-local relay validates the target tag,
  native adapter and header shapes, brand-selected carrier, and its own
  trailer, without requiring one source `CClosure.f`. It invokes the target
  adapter with the wrapper as `_fn`.

Either strict entry recovers its module and native route, runs strict guards
for the known callable shape, and returns boxed results for the call site's
strict result actions. This path never calls the coercive `CClosure.f`, so
integral-float or truthiness conveniences cannot leak into a Titan callable
adjustment.

**Non-Titan path.** Lua closures, Lua light C functions, foreign C closures,
and `__call` objects push the boxed callee and the evaluated arguments onto the
Lua stack with `setslot`. Results returning into Titan consume the
checker-attached `DynamicCoercionPlan` for each expected result.

- Ordinary finite calls use
  `luaD_callnoyield(L, restorestack(L, _vc_func), nresults)`. Lua 5.5 encodes a
  finite VM result request in `CallInfo` with a maximum of 250, so the checker
  rejects generic function-value sites whose finite visible request exceeds
  that count. This is independent of Titan's 200-element descriptor cap.
- A generic producer that is statically open at the call site uses
  `LUA_MULTRET`, even when an enclosing flexible native entry has a finite
  `_flexwant`. The results stay rooted on the Lua stack while the branch
  measures the raw count, nil-fills a missing fixed prefix, converts the tail
  into the same typed descriptor the exact path uses, caps the retained run at
  `TITAN_VARARG_MAX` (or copies only an inherited finite remainder), and then
  resets `L->top.p`. An open sink over a fixed-only static callable remains an
  ordinary finite call.
- Non-callable values fail cleanly here, at run time.

The branded and Lua paths share the finite/open shape machinery but keep
distinct strict versus dynamic element policies.

Because the generic branches can grow and relocate the Lua stack,
`codevaluecall` marks the function `uses_base_off`, saves stack positions as
offsets, and recomputes `_base = restorestack(L, _base_off)` after every
branch. Before branch selection the callee and arguments are only stable C
values; the exact branch passes them directly, and the other two push them
because those slots are their real VM call frame. After the branches join,
each live fixed result is published into its caller result slot.

### The two Lua-stack entries

`genluaentry` (`coder/declarations.lua`) emits one shared
arity/tail/result/error-frame shell under two policies: the coercive
genuine-Lua entry in `CClosure.f`, which applies each formal's
`DynamicCoercionPlan`, and the strict Titan-generic entry in the final upvalue,
which excludes the hidden carrier from arity math and applies strict gradual
actions. The generated anatomy is in
[Lua interop internals](lua-interop-internals.md#the-two-lua-stack-entries-genluaentry),
and the boundary matrix in
[Type relations and boundary plans](type-relations-and-boundaries.md).

## Closures and captured variables

An anonymous literal used directly as a call's callee instead follows the
[inline immediate-call path](immediate-functions.md): its body becomes a scoped
block, and its closure and entries are omitted. The layout below applies when a
function value is materialized, including nested closures that escape from an
inline body.

An anonymous function ([closures](../language/closures.md)) is a source
function value just like a top-level reference: a `CClosure` whose `f` is the
coercive genuine-Lua entry, with a four-slot header, one upvalue per captured
variable, and the declaration's strict light C function in a final trailer
slot:

```
upvalue[0]     = _mod                  (the module Udata, captured lexically)
upvalue[1]     = function-type tag     (light userdata)
upvalue[2]     = native entry ptr      (light userdata)
upvalue[3]     = closure brand         (light userdata)
upvalue[4 + i] = captured variable i   (a box, or a copied value)
upvalue[4 + ncaptures] = strict entry  (light C function)
```

The trailer is found from the closure's actual upvalue count, so capture
indices stay stable. A closure body reaches capture *i* as
`_fn->upvalue[4 + i]`. A top-level call passes `_fn = NULL`, but a closure is
always entered with `_fn` pointing at itself. A realized adjustment wrapper
keeps the copied captures at the same indexes; its layered layout is in
[Wrapper layout](closure-adjustment-wrappers.md#wrapper-layout).

### The captured-variable box

A variable that is both **captured and assigned** cannot be a plain C local:
the inner closure must share one mutable cell with the declarer and any sibling
closures. The cell is a **box** `Udata` copied into every capturing closure
(`newbox`, `box_read`, `box_write`):

- A non-GC value uses a zero-uservalue `Udata` with the raw C value in its
  payload. It contains no collectable edge and needs no barrier.
- A GC-bearing value uses a one-uservalue `Udata` with the boxed value in
  `uv[0]`, and uses `luaC_barrierback` on mutation because userdata traversal
  participates in `genlink`. This avoids promoting every freshly stored loop
  value, as a closure forward barrier would.

A box is allocated and **immediately anchored** in a dedicated stack slot
before its initializer is stored, so there is never an unanchored-box window.
Capturing closures receive the box pointer while they are still fresh-white
(below), so no barrier is needed there. A variable that is captured but
immutable, or mutated but not captured, keeps its ordinary representation;
only the conjunction is boxed.

### Capture lists, lambda hoisting, transitive capture

The checker computes, for each `ExpFunction`, the ordered de-duplicated list of
enclosing-function declarations it captures (see
[the type checker](checker.md#closures-capture-analysis-and-lambda-inference)).
The coder turns that list into the `upvalue[4 + i]` slots in the same order.
At the use site it allocates the exact closure with `luaF_newCclosure`, fills
the header, captures, and strict trailer directly while the closure is white,
then publishes it into its traced result slot before paying the allocation's GC
debt. No capture transits through `L->top`, and no barrier is needed before
publication. The post-publication collector poll may relocate the Lua stack,
so generated code restores `_base` from `_base_off` afterward.

Lua permits at most 255 C-closure upvalues. Five structural slots leave **250
captures**; the checker rejects a larger capture list, so code generation never
depends on a Lua API failure. A callable wrapper adds one source-closure link;
when that would exceed `MAXUPVAL`, guarded realization keeps the value and uses
generic dispatch.

Each lambda's native, coercive-Lua, and strict entries are **hoisted to file
scope** and emitted alongside the top-level functions under the name
`<prefix>\u2119_lambda_<n>` (`lambda_register`). A lambda nested inside another is
discovered only while the outer body is generated, so the emission loop in
`coder.generate` drains `tlcontext.lambdas` with an index-based `while` that
re-reads the length on every iteration.

**Transitive capture** (a deep lambda using a variable from a function it is
not directly inside) falls out of the per-frame capture lists. The variable
appears in the capture list of *every* intervening lambda, so each level reads
it from its own `_fn` and copies it into the next level's closure. A boxed
transitive capture copies the one box pointer all the way down, so every level
shares the cell; a by-value capture copies the immutable value down.

### Bound-method trampolines

A bound method reference `obj:m` is a one-capture closure whose captured
"variable" is the receiver `self`, with **three trampolines** that delegate to
the method's real entries. The method's **defining module** emits all three for
every method. Public methods use exported, recoverable symbols plus a
`function_type_tag` for the self-removed type, so a bind site in another module
that has only the provider can point at them. Local methods declare their
trampolines `TITAN_SOURCE_LOCAL` (hidden visibility) and are not serialized
into interfaces.

- The **native trampoline** matches the self-removed function type's ABI,
  extracts `self` from its closure's `upvalue[4]`, and tail-calls the method's
  native entry. A trailing flexible-output descriptor and budget pass through
  unchanged.
- The **Lua trampoline** inserts `self` as the first stack argument and
  delegates to the method's Lua entry, reusing its boundary checks.
- The **strict trampoline** is generated for the self-removed callable shape.
  It keeps the hidden original bound closure, strictly guards the visible
  arguments and results, and invokes the native bound trampoline.

At the bind site `obj` is evaluated once into an untraced C temporary. The
closure is built like a one-capture lambda (`_mod`, the self-removed tag, the
native trampoline, `self`, and the strict trampoline trailer) and receives its
initial result root immediately. The result is an ordinary source
`Type.Function` value, so a downstream non-exact callable cast needs no
bound-method special case.

Interface bound methods use six-upvalue branded closures that capture the
wrapper; their layout and dispatch are in
[Interfaces](interfaces.md#four-dispatch-paths).

### Compiled-module ABI

`TITAN_ABI_VERSION` is the monotonic compatibility marker carried by every
compiled provider. It covers native entry signatures, physical nominal layout
metadata and exact native Option carriers, serialized type schemas,
module-state layout, canonical Array proxies, unions, Interfaces, generic
metadata, source-private provider identity, foreign callback symbols, and
const-qualified descriptors and wrappers. A mismatched provider is rejected
before interface rehydration or native value exchange.

The compiler and standard-library release version is independently
`TITAN_VERSION` `0.6.0`. Its derived `0.6` library version selects
`TITAN_PATH_0_6` and the `lib/titan/0.6` provider namespace; patch releases
share that namespace. There is no migration, compatibility alias, or cleanup
path for earlier Titan installations.

Closure adjustment wrappers reuse the current `CClosure` header and native call
shapes; their adapters and relays are private consumer artifacts with no
serialized field, provider symbol, or module-state slot. Another fixed slot or
signature would require an ABI advance.

Generated nominal codecs are generated-code ABI that **no load-time check
covers**: the `TITAN_MT_CODEC` metatable binding, the `TitanTransferCodec`,
`TitanCodecState`, `TitanCodecHandoff`, and `TitanCodecField` layouts, and the
inline codec runtime that every module compiles from the SDK's `transfer.h`.
Every provider, the standard library included, must therefore be built against
one SDK; a module compiled against another `transfer.h` is not detected when it
loads. The one cross-module call, from a generated codec into
`titan.protobuf`'s `codec_handoff`, checks only the closure's shape and
`TITAN_BRAND` on each call. `titan.protobuf`'s initializer, the sole producer
of the handoff value, checks that closure's function-type tag against its own
`TITAN_CODEC_HANDOFF_TYPE` once per Lua state and fails initialization
otherwise. A generated codec compiled against another handoff signature is
therefore not re-checked on each call; it relies on the same one-SDK rule as
the codec layouts (see
[generated nominal codecs](protobuf-library.md#generated-nominal-codecs)).

The abandoned-coroutine unwind protocol is also generated-code ABI that no
load-time check covers, and it is not reflected in `TITAN_ABI_VERSION`: the
`TITAN_STATUS_FINALLY`, `TITAN_STATUS_UNWIND` and `TITAN_STATUS_FLOOR` boundary
markers, the `PA_UNWIND` landing and guard, and the `titan_unwind_floor` record
([unwinding through finally](error-handling.md#unwinding-through-finally)).
Each image's generated code pairs with its own copy of the runtime, and the
walker in `titan.coroutine` interprets the markers. Mixed builds degrade
safely:

- A provider compiled before the protocol leaves its finally boundaries at
  `LUA_OK`. The walker skips them like catch-only boundaries, so that
  provider's `defer`s do not run when a coroutine is abandoned, and its catches
  do not run either.
- A module compiled with the protocol, under a `titan.coroutine` built before
  it, is never unwound: that coroutine library destroys abandoned stacks
  without running their code.

Standard-library providers are built together, under the one-SDK rule above.

### Upgrading the pinned Lua

Generated C, `titan.h`, and the runtime compile against Lua's internal headers,
so even a Lua point release can change Titan's generated-code contract. Lua
5.5.1, for example, changed `LUAI_MAXALIGN`, which sizes the raw userdata
header (`Udata0`) and `luaL_Buffer`. An upgrade therefore needs a source-level
audit of the complete upstream diff against the compiler, runtime, standard
library and vendored sources, not only a public-API check. It also advances
`TITAN_ABI_VERSION` whenever internal layouts or call shapes can change. The
SDK pairs `src/lua-<version>` with its matching `liblua.a`, and the ABI marker
rejects providers built against another header set.

These sites mirror Lua internals and must be rechecked on every upgrade:

|Site|Mirrors|Details|
|---|---|---|
|`titan-runtime/titan.h` `lua_longjmp` and the setjmp selector|`ldo.c`, vendored verbatim|[Error handling](error-handling.md#code-generator-overview)|
|Generated stack-slot nil writes (`setnilvalue2s`)|Lua's stack-aware store macros|[Values and GC](values-and-gc.md#1-the-function-frame-reserved-nil-initialized-stack-slots)|
|Floating numeric `for` advancing through `luai_numadd(L, ...)`|`llimits.h` numeric hooks|[Codegen constructs](codegen-constructs.md#the-numeric-for)|
|Map assignment delegating unresolved sets to `luaV_finishset`|`lvm.c` set protocol|[Codegen constructs](codegen-constructs.md#assignment-set_table_entry-and-constructor-codemap)|
|`titan.string` default `!` alignment|`LUAI_MAXALIGN` members|[String library](string-library.md#pack-translation)|
|LPegLabel UTF-8 lead-byte guard|`lutf8lib.c` decoder|[LPegLabel embedding](lpeglabel-embedding.md#source-provenance)|
|Off-registry metatable construction|`lauxlib.c` publication rule|[Values and GC](values-and-gc.md#type-identity-the-metatable-pointer)|
|`titan_unwind_close_thread` reset of an exhausted Lua coroutine|`lstate.c` `resetCI` (static) and `luaE_resetthread`|[Coroutines](coroutines.md#unwinding-an-abandoned-coroutine)|
|`titan_unwind_close`, `titan_coroutine_enter`, and the generated unwind landing and re-armed recovery close|`luaD_closeprotected`'s retry loop, `luaF_close`, `luaD_rawrunprotected`, `luaD_seterrorobj`, `luaE_warnerror`, and the `G(L)->gcstp` bits `GCSTPGC`/`GCSTPCLS`|[Error handling](error-handling.md#unwinding-through-finally)|
|Browser wrapper-release collector stop (`lmacro_get_gcstp`, `lmacro_set_gcstp`)|`GCTM` saves `gcstp`, adds `GCSTPGC`, and restores it; `luaC_step` leaves debt alone when stopped without `GCSTPUSR`; `lua_gc` refuses operations under `GCSTPGC`|[Browser bridge](browser-bridge.md#the-collector-stop)|
|`titan_unwind` walker, `titan_unwind_cross` floor and resumer search, and the floor's self-close branch|only `luaD_throw` writes `lua_longjmp.status`; `G(L)->allgc` links the main thread and threads are never in `finobj`; `lua_resume` and `precover` install a `previous == NULL` base boundary on the resumed thread; a self-closing `lua_closethread` ends in `luaD_throwbaselevel`, which jumps to the thread's outermost boundary (the floor on a Titan coroutine) with the reset status, `LUA_OK` when every close succeeded; `luaC_checkfinalizer` ignores registrations under `GCSTPCLS`|[Coroutines](coroutines.md#unwinding-an-abandoned-coroutine)|

Gate an upgrade on all of these:

- compiler and C-parser tests against the new headers;
- generated-C and standard-library behavior tests;
- packaging and layout tests for the active ABI and library version;
- the full local suite;
- Linux CI;
- the complete macOS suite.

## The module protocol

Each Lua state owns one canonical `Udata` for each initialized logical module,
registered under `"Titan module <modname>"`. Generated functions receive that
userdata as `_mod`; Lua entries recover it from closure upvalue 0. A module has
two storage regions:

- traced uservalues hold variables, imported module userdata, canonical
  closures, metatables, Array writer closures, and nominal namespaces (see
  [User-value allocation](#user-value-allocation));
- its native payload begins with `TitanModuleData` and holds its immutable
  symbol-resolver callback, resolved dependency pointers and slot numbers,
  canonical function-type tag pointers, and Interface implementation arrays.

State-dependent native bindings never live in mutable file-global C variables.
An immutable symbol resolver can belong to a shared object, a linked archive,
or an executable; it identifies the code that created this module state
without recovering a filename or loader handle.

Public raw [foreign imports](foreign-functions.md#source-collaboration-and-binary-isolation)
have no state argument. Their exact C addresses resolve through the same
checked providers and publish atomically into stable consumer-image slots. A
later state must select the same address; it cannot overwrite a raw binding.

Generated Titan declarations and definitions have protected visibility on ELF,
so a resolver's native addresses bind to its own image despite duplicate
logical-module exports elsewhere. The pragma starts after the foreign headers
and ends with the generated module, so foreign C linkage is unaffected. In a
split module the private header pops it at its end, and each part pushes it
again after including the header.
Darwin's two-level namespace already preserves these image-local bindings.

### `<prefix>_init` — one canonical module per Lua state

The initializer (`coder/module.lua` `init` template) first checks the logical
registry key. If the module exists, it returns that userdata immediately. It
does not load dependencies or initialize another image's function tags,
Interface arrays, or native bindings.

When the module is absent, initialization proceeds in this order:

1. Allocate the complete native payload and uservalues and root the object
   privately. Install the native export header and physical-provider identity,
   and prepare the Array metatable caches.
2. Select, check, and initialize each explicit import before selecting the
   next. A canonical selection that changed during initialization is checked
   again.
3. Resolve transitive owners and fill native entry and slot bindings from the
   final canonical providers.
4. Prepare nominal metatables, function tags, Interface arrays and witnesses,
   Array writers, canonical closures, variable initializers, Lua member access,
   and the module initializer, in their dependency order.

Dependency-check failures occur before the new module is published in the
logical registry, so a caught failure cannot let a retry bypass verification.

Each successful initialization path registers both the native Lua loader and a
native provider descriptor through `titan_module_preload`. The registry table
`TITAN_MODULE_PRELOADS_KEY` holds `TitanModulePreload` userdata containing only
the loader and the `TitanModuleSymbols` resolver pointer, with no module state.
Independent Lua states can copy this descriptor without sharing module
userdata, metatables, or resolved bindings.

A fresh Lua state gets a fresh userdata and fresh native caches even when it
shares the same generated code, so one state's selected provider cannot
overwrite another state's dynamic calls or Interface dispatch. Record, union,
and Interface identity remains the per-state metatable, discoverable through
`TITAN_METATABLES_KEY` and cached in traced module uservalues.

`$INITPAIRS` fills the current module payload's exact/adjusted Interface arrays
once imported native pointers are available. It then raw-checks
`concrete_metatable[target_Interface_metatable]`. A nil entry receives the
pair's private C witness closure with the emitting `_mod` as upvalue 0; an
existing witness is preserved. The closure and metatables are traced Lua
objects, while the pair array contains only native function pointers.

### Lua entries and ABI, type, and layout metadata

`luaopen_<mangled-modname>` is what `require` finds, through the package
preload table or the [Titan package
searcher](driver.md#the-titan-package-searcher). Standard-library short
imports are desugared before module resolution, so Titan `import "os"`
compiles as an import of `titan.os` and emits `luaopen_titan_os`, the same
entry Lua `require "titan.os"` uses, without defining `luaopen_os` or replacing
Lua's own `os` library. The Lua entry calls `_init` and pushes the module
`Udata` itself: **`require` returns a userdata**, and there is no module table.
Its members (exported functions, exported variables, and one static-namespace
table per public record or union) are all served by the module metatable
([Lua interop internals](lua-interop-internals.md)).

Mangling maps both `.` and `-` to `_`, so it is not injective: `a.b-c` and
`a.b_c` share `luaopen_a_b_c`, `a_b_c_abi`, and `a_b_c_types`. The generated
opener therefore starts with a logical-name guard for file loads
(`coder/module.lua` postamble). `require` passes the requested name as
argument 1 and the searcher's loader data as argument 2. When argument 2 is a
Lua string other than Lua's documented preload loader data `":preload:"`, the
call is a file load: the [Titan
searcher](driver.md#the-titan-package-searcher) passes the provider path and
Lua's C searchers pass the file name. A file load whose argument 1 is a Lua
string must name the logical module exactly, by length and bytes; otherwise
the opener raises `module name mismatch: requested '<x>', provider defines
'<logical>'` before invalidating backtrace state, calling `_init`, or
publishing anything. Every other call skips the comparison. Preload loads pass
`":preload:"`, so `package.preload[alias] = luaopen_<m>` deliberately aliases
the opener under another name in that state and still returns the canonical
module; copied native preloads (including registry `_PRELOAD` snapshots in
[independent states](lua-library.md#independent-state-ownership)) and the
Windows launcher's `titan_open_main` preload loader take this path. Calls
without string loader data (transfer preload loaders, native harnesses,
`package.loadlib(...)()`) skip it too.

`<prefix>_abi` is a tiny marker function that returns `TITAN_ABI_VERSION`;
`<prefix>_abi_value` returns the same string as a native bootstrap query,
callable before a Lua state or module exists. Both the compile-time DSO loader
and generated dynamic imports check the ABI before trusting any other callable
symbol. Static providers embed the same ABI, serialized interface, and separate
layout string in each logical object's metadata section
(`titan-compiler/staticmetadata.lua`). `<prefix>_types` is the
separate-compilation interface:

```c
int counter_abi(lua_State* L) {
    lua_pushliteral(L, TITAN_ABI_VERSION);
    return 1;
}

int counter_types(lua_State* L) {
    lua_pushliteral(L, "Module('counter',{ModuleVariable('counter', 'x', Integer()),...},{['Count'] = Integer()})");
    return 1;
}
```

The literal is `types.serialize` of the module type: the checker's detached
declared graph `ast._declared_type` when present, otherwise `ast._type`. It is
a Lua *expression* that rebuilds the module's type when evaluated with
`types.lua`'s constructors as its environment.

- A `Type.Module` serializes runtime `members` separately from public
  type-only `type_members` (transparent aliases and direct Interface
  declarations). Neither creates a module slot or Lua-visible member.
- Keyed type-member, nominal-method, and nominal-static maps are serialized in
  locale-independent byte order of their names, so equivalent interfaces have
  reproducible text. Ordered Interface methods, module members, record fields,
  and union variants keep their logical source order. Physical UV and member
  indices never enter this semantic schema.
- Contextual `CVoid`/`CInteger`/`CFloat` descriptors and recursively portable
  `CPointer`, nonvariadic `CFunction`, and `COwned` graphs serialize
  structurally without source scope or header provenance. Named header
  `CTypedef`, `CStruct`, and `CUnion` descriptors serialize with their
  `c_declaration_origin`, so consumers can verify original compatible
  declarations. Enum identities, unnamed aggregates without a typedef name, and
  flexible-array aggregates never enter the literal.
- Callable declaration descriptors serialize formal `paramnames`; structural
  `Type.Function` values do not. Callable shapes also carry their optional
  `flexrettype`, which interface recovery accepts (the driver's validator
  rejects it only on record and union constructors).
- There is no dependency-origin metadata. `Type.Module.file` is omitted too:
  it defaults to the logical path when the expression is evaluated, and only a
  successful DSO claim overwrites it with the selected relative shared-provider
  path. Static archive paths never enter the serialized type.

`<prefix>_layouts` returns one binary graphcodec string
(`nominallayout.encode`) pushed with `lua_pushlstring` and an explicit byte
count. `nominallayout.decode` validates its module identity and closed physical
schema independently of `_types`. Native loading keeps those plans in the
resolver's `nominal_layouts` map and passes them to `coder.generate` as
`options.nominal_layouts`. No private C declaration graph is exported. See
[Native nominal storage](nominal-storage.md).

How the driver's loader recovers and validates these strings from a DSO or an
archive object is in [driver and toolchain](driver.md) and
[Static compiled modules](static-compiled-modules.md); the tests' in-memory
`tableloader` exercises the same serialization round trip.

Folder and provider representation change none of this logical protocol.
Mangled symbols, nominal names, registry keys, `luaopen_*`, and the serialized
module identity derive solely from the logical `modname`; there is no
contributor ABI. Moving local declarations or private state among contributors
can change private initialization layout without changing the serialized
interface.

## Static vs dynamic dependency wiring

`coder.generate` decides per import from the finalized `static_deps[modname]`
provenance (`import_module` and `init_data_from_other_modules`,
`coder/module.lua`). It reports its choice per dependency in the
`native_bindings` result.

**Direct/static** dependencies are source objects or archive members carried
in the same binary. Their native functions use `extern` declarations and direct
calls, and their public slots are compile-time constants. Their initializer is
called directly, and the returned module must carry the exact linked producer's
physical identity: a same-name module created by another image cannot safely
supply the private state that direct native code expects.

When a native call implicitly uses a directly linked nominal owner (through
an exposing import), the importer checks the same physical identity once
while caching the canonical module userdata. It does not call the owner's
initializer early or add a check to each method invocation.

**Dynamic** dependencies (`handle` bindings) first use `titan_module_provider`
(`titan-runtime/titan.h`) to look up the logical module in the Lua registry.

- An initialized module supplies its native export callback, even if its code
  is embedded in the executable or was opened locally through
  `package.loadlib`.
- If the module is absent, a matching native preload descriptor supplies its
  resolver.
- Next, an executable or test can supply the resolver (or, on Windows, the
  companion application provider DLL) of a module already linked into that
  application. See [The linked provider set](#the-linked-provider-set).
- If `file` is the empty string `""`—emitted by `coder/module.lua` for external
  installed-source dependencies (`check_only_sources`) compiled by a library—
  `titan_module_provider` stops without opening any disk image and raises
  `Titan module '<name>' is not supplied by the application`.
- Otherwise, the selected DSO filename is consulted only when no descriptor is
  available: `loadlib` takes the first occupied `<entry>/<file>` along the
  state's [run-time Titan path](driver.md#the-run-time-titan-path-and-sdk-fallback),
  then the lazy SDK fallback.

Descriptor lookup does not call a Lua preload loader or initialize the
dependency. `titan_check_module_abi` and `titan_check_module_compatibility` run
before the selected initializer is called, no matter which provider supplies
the resolver.

`titan_module_symbol` then resolves the required metadata callbacks, native
entries, bound-method trampolines, and public slot numbers through the selected
provider. The importer saves these bindings in its own module native payload.
Direct calls remain typed native calls with the dependency's module userdata
and a `NULL` closure argument; they never fetch a first-class closure or invoke
a Lua namespace lookup. First-class functions read the canonical closure at
the provider's resolved slot.

A **transitive dynamic owner** (`global` binding) is resolved after the
explicit exposing imports are initialized: `titan_module_provider` is called
with the owner's logical name and a null filename. That owner must already be
initialized; neither a copied preload nor an uninitialized linked module
satisfies this canonical-only lookup. Its own ABI and selective compatibility
checks precede native lookup through its export callback, and global symbol
order never chooses the owner. The same Lua state's registry supplies the
module userdata and nominal metatables. See [Type aliases](type-aliases.md)
and [Selective binary dependency verification](binary-compatibility.md).

The runtime's `loadlib` (`titan-runtime/titan_path.c`) maps newly needed DSOs with
`RTLD_LAZY | RTLD_GLOBAL`. This supports ordinary native-library relocations:
for example, an extension can initialize its imported standard provider before
its lazy `uv_*` calls bind. This C-linker behavior is separate from Titan's
logical module binding. Eager data or function-address relocations and native
constructors cannot rely on initializer ordering. Compiler interface inspection
is a separate `RTLD_LAZY | RTLD_LOCAL` operation.

### The linked provider set

Application and `--test` preflight walks reached archive `imports` and reached
`source_requirements`. When an executable or test image activates private
linked election (`elect_linked` on Unix, or `app_requirements` when
`context.application_source_requirements` is non-nil on any target),
`finalize_resolver_context` reconciles canonical owners (`linked_owner`) and
builds `context.linked_modules`, a bytewise-sorted array of `{ name }` (for
in-image modules) and `{ name, provider = selected.relative }` (for required
external dynamic providers) entries covering every application-owned source
module in `source_names` (excluding `titan.test.runner`), every required or
`elect_linked` archive member in `selected_static_modules`, and every required
module in `dynamic_names`—while a published library's folded
`source_requirements` still stops at its direct or forwarded recorded names and
never consumes a dependency's transitive imports.
`perf.linked_module_catalog(modules, companion)` and `perf.catalog_install`
(`driver.lua`) emit one sorted `TitanLinkedModule` array—each row carrying
`{ const char *name; TitanModuleSymbols symbols; const char *provider; }`—and
one uniform `TitanLinkedModules` descriptor (`{ begin, end }`) installed under
`TITAN_LINKED_MODULES_KEY` in the Lua registry inside the protected entrypoint
before requiring the root:

* **Linux and macOS:** Enabled when `elect_linked` holds (strict `--static`,
  `--test`, physical archive owners, or dynamic imports with multiple linked
  sources) or when `app_requirements` holds
  (`context.application_source_requirements` is non-nil). In-image rows
  (`source_names` excluding the synthetic test runner, plus reached archive
  members from `selected_static_modules` that are required or elected under
  `elect_linked`) emit hidden `TITAN_SOURCE_LOCAL` native resolvers with
  `provider = NULL`; each archive entry is a strong reference that retains its
  primary object while dormant siblings are never referenced. Required external
  dynamic providers (`dynamic_names[name]` in `app_requirements`) emit
  `{ name, NULL, "<relative-provider>" }` with the exact elected provider path
  (such as `"warehouse.so"` for `warehouse.counter`), never emitting a hidden
  resolver reference for an external DSO; ordinary unmarked dynamic imports do
  not become catalog rows. A default program with only its source root and
  shared-provider imports carrying no recorded obligations needs no catalog.
* **Windows:** App-owned source modules live in the companion application
  provider DLL, not the launcher EXE. Enabled only when `app_requirements`
  holds (`context.application_source_requirements` is non-nil):
  `entrypoint_contents` passes `options.provider` as `companion` to
  `perf.linked_module_catalog(modules, companion)`. In-image source rows emit
  `{ name, NULL, "<companion-dll>" }` (never the EXE basename), while external
  required DLL rows emit `{ name, NULL, "<selected-relative-dll>" }` (standalone
  or canonical prefix bundle). On a catalog hit, `titan_path_find_linked_module`
  opens `entry->provider` lazily via `loadlib`, so a loaded library DLL resolves
  the selected module's already-exported `_abi_value`, `_compatibility`, and
  `_init` entries and then switches to the initialized canonical in-memory
  resolver—without passing hidden resolver pointers across the PE boundary or
  adding general PE exports to the application DLL. Ordinary Windows builds
  without recorded obligations omit the table.
* **Browser (`--target browser`):** Enabled only when `app_requirements` holds
  (`context.application_source_requirements` is non-nil):
  `browser_entrypoint_contents` emits hidden `TITAN_SOURCE_LOCAL` resolver rows
  (`provider = NULL`) for all app-owned source modules in `source_names`
  (excluding the synthetic test runner) and required archive members, and
  installs the table in `titan_browser_initialize_worker` before
  `require("$MODNAME")`, anchoring those objects under `wasm-ld --gc-sections`.
  Under `TITAN_TARGET_BROWSER`, `titan_path_find_linked_module` reads only
  `entry->symbols`, with no dynamic opening, no new Wasm imports, and no host
  JavaScript/loader changes. Ordinary browser builds without recorded
  obligations omit the table.

When `app_requirements` holds (`context.application_source_requirements` is
non-nil), `finalize_resolver_context` also populates
`context.application_nominal_layouts` through `perf.public_source_layout(name,
mod)` (backed by `coder._own_nominal_layouts`) across all compiled
`source_names`, so non-collaborating consumers (without a direct explicit
`.titan` import on that owner) use erased public nominal layouts
(`coder/nominal.lua`)—including for installed sources reached transitively
through another required source.

`titan_module_provider` preserves its four-step order: (1) initialized
per-state canonical module, (2) matching native preload descriptor, (3) binary
search of the installed `TITAN_LINKED_MODULES_KEY` catalog (returning
`entry->symbols` or, on native targets when `entry->provider != NULL`, opening
`entry->provider` lazily via `loadlib`), and (4) the caller's non-empty baked
fallback `file` (`NULL` permits only initialized canonical lookup; `""` disables
caller fallback, as emitted by `coder/module.lua` for both `check_only_sources`
and `check_only_binaries` so libraries never rediscover forwarded dependencies
on their own). The table holds image-lifetime data, not initialized module
userdata; binding to it still goes through the normal ABI and used-declaration
checks. Modules still initialize in written import order. The table adds
nothing to `package.preload` or `package.loaded`. The Lua package searcher does
not consult it, and child states do not inherit it. Once initialized, a module
registers its ordinary native preload as before, and that preload can be copied
into children. Because `TitanLinkedModule` / `TitanLinkedModules` is a private
prerelease runtime/launcher layout (with frozen public versions), rebuild
launchers and artifacts carrying their own runtime/resolver together whenever
upgrading the compiler/runtime across a layout change.

For Unix `--static`, preflight verifies the complete written import closure and
the table anchors its archive members. On native platforms the runtime still
opens a named DSO on a catalog miss when `file` is non-empty (so a plugin
loaded explicitly through Lua `require` and its own dependencies are not part
of the host's certified graph), while an empty `file` (`""`) raises
`Titan module '<name>' is not supplied by the application`.
The catalog never replaces an existing physical producer token or redirects
direct calls. Final-link certification includes the sorted catalog names and
the bytes of the input objects and archives.

## User-value allocation

`allocate_upvalues` (`coder/module.lua`) assigns `_mod` user-value slots before
any code is generated. `nextupvalue` hands out slots from 0 with no reserved
slot, so `NUPVALS` equals the number of slots. The order is:

1. **Public prefix**, derived by `coder._public_prefix_layout` entirely from
   the serialized interface:
   1. exported module variables, in module-member order;
   2. exported ordinary-function canonical closures, in module-member order;
   3. exported static closures of each public record or union, with owners in
      module-member order and statics in bytewise name order.
2. **Array metatable caches**: the mutable, then the const Array metatable.
3. **Provider identity**: one lightuserdata slot holding the source producer's
   immutable physical-provider token.
4. **Source-private region** (`coder._source_prefix_layout`): local module
   variables, local ordinary-function closures, and local static closures.
5. **Imports**, in AST order.
6. **Nominal namespaces**: each record's or union's static-namespace table, in
   AST order.
7. **First-use slots**, allocated as code generation encounters them:
   module-local Array writers; record, union, Interface, and owned-C
   metatables; concrete-owner module caches needed by wrappers; transitive
   module `Udata` caches; and up to three error-recovery `TString` anchors
   (`TITAN_BACKTRACE_KEY`, `TITAN_TRACE_PINNED`, and `""`) requested by
   generated `catch`/`defer`/re-raise code. These categories may interleave,
   and no order among them is serialized.

Who reconstructs which part:

- The producer stamps the public-prefix slots on its AST declarations. A
  same-binary importer walks the same layout; a separate dynamic importer
  resolves the producer's exported slot symbols. Both read the exact canonical
  closure for an imported constructor or nominal function.
- Items 2–4 are a fixed private header that is part of the current ABI. A
  direct importer compares the provider token with the hidden identity function
  of its exact linked producer before using its state, and explicit source
  imports additionally read the source-private region.
- Items 5–7 are coder-private and never perturb importer slot math.

Initialization order inside `_init`:

- Requested error-recovery `TString` slots are initialized first (`$INITNAME`),
  right after `titan_pushmodule(L, _mod)` and before metatables, dependency
  loading, or generated code can enter a protected boundary.
- Function-type tags are published before any variable initializer runs,
  because an initializer may build a lambda or bound-method closure and must
  copy a live exact tag into it. The tags live in the module native payload,
  not in user values. The closure brand is a compile-time constant and needs
  no initialization.
- Array writers for each distinct constructed element type are initialized
  after nominal metatables, imports, and tag publication but before
  `$INITVARS`, so an initializer can construct an Array without seeing an empty
  slot.
- Canonical top-level and static closures are populated before variable
  initializers and before module exposure.

`$INITVARS` evaluates module-variable initializers in AST declaration order.
Imported and foreign calls use the ordinary expression/call lowerings and may
relocate the Lua stack. `coder/generate.lua` therefore declares `_base` and its
saved `_base_off` whenever `initctx.uses_base_off` is set, even when
`initctx.nslots == 0`. A scalar-only initializer needs the saved base but no
root-slot allocation or clearing loop; GC-bearing results retain the existing
reserved slots and barriers. The initializer restores `L->top.p` afterward.

An importing module never sees this module's AST. The `Type.Module` interface
reconstructs the public prefix at compile time, but a separately loaded
provider may later reorder compatible declarations. Cross-module variable
access therefore uses `uvalue(&_mod->uv[MOD].uv)->uv[VAR].uv`, where `MOD` is
the consumer's own import slot and `VAR` comes from the provider's exported
variable-slot symbol for a dynamic dependency, or is a constant for a
same-binary dependency. Canonical callable slots follow the same rule; direct
native calls bypass them. The module metatable's name-to-slot map serves Lua
from the producer's own current indices. See
[Selective binary dependency verification](binary-compatibility.md#provider-owned-slots-and-direct-calls).

## Per-function code-generation contexts

`newcontext(tlcontext)` (`coder/flow.lua`) creates the context for one function
body. Its fields:

- `tmp`: counter for temporary names (`_tmp_1`, …), used by `newtmp`.
- `depth`, `nslots`, `dstack`: the current Lua-stack-slot depth, its
  high-water mark, and the saved depths that `pushd`/`popd`
  (`coder/statements.lua`) use around blocks so sibling scopes reuse slots.
- `allocations`: bumped by every `reserveslot`; loop generators compare it
  across the body to decide whether to poll the collector.
- `names`: per-name suffixes that `localname` uses to give each declared local
  a distinct C name (`_local_x_1`, `_local_x_2`, …), so Titan shadowing is
  valid C.
- `prefix` and `module`: the module's name prefix and name.
- Shared accumulators pointing into the top-level context (`metatables`,
  `functions`, `variables`, `modules`, `bound_luas`, `bound_stricts`): each
  records the external nominals, functions, variables, and bound trampolines
  the body touches. `init_data_from_other_modules` turns them into declarations
  and init-time wiring. Function-type tags are collected on the top-level
  context itself.

`newslot`/`reserveslot` return a slot expression,
`s2v(restorestack(L, _base_off) + k)`, and mark the function `uses_base_off`.
`newtmp(ctx, typ, isgc)` declares a C temporary of the value's unboxed type
and, when `isgc`, also reserves a slot and returns its expression; the caller
stores the value there before the next possible allocation. The preamble that
`nslots` sizes, the return-path reset of `L->top.p`, the shadow-slot
discipline, and where `luaC_checkGC` goes are in
[values and the GC](values-and-gc.md#gc-discipline-the-invariants).
