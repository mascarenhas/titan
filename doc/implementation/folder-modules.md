# Folder modules

Folder modules are a source-discovery and compilation-unit feature in
`driver.lua`. They let one logical module be assembled from several sibling
`.titan` files without changing Titan's AST, type model, checker scopes,
generated module protocol, or runtime loader.

For logical module `M`, the driver derives the slash path `P` and final
component `B`. A flat source is `P.titan`; a folder source has the required
main `P/B.titan` plus every other immediate regular `*.titan` sibling.

## Tagged source resolution

Source lookup uses an internal result that makes representation and privacy
decisions explicit:

```lua
-- selected source
{
    kind = "flat" | "folder",
    main = "<canonical main filename>",
    files = { "<main>", "<sorted contributor>", ... },
    program_output = "<module-relative executable path>",
}

-- an apparent flat child is a constituent of its parent folder module
{
    kind = "blocked",
    owner = "<parent logical module>",
    main = "<parent main filename>",
    contributor = "<requested flat filename>",
}
```

`nil` means a clean miss. Failure to enumerate an already selected folder is
returned separately as a hard error. These distinctions matter because a
selected or blocked result must not silently fall through to a flat candidate
or a later source root.

For each source-root entry, resolution (`driver.lua` `source_resolution_in_root`):

1. tests the requested folder main `P/B.titan` as a regular file;
2. if found, enumerates its directory, retains only immediate regular
   `.titan` siblings, sorts contributor basenames with
   `util.bytewise_less`, and returns main followed by contributors;
3. otherwise tests the flat source `P.titan`;
4. before accepting a nested flat source, tests whether its immediate parent
   has a folder main and the flat source is therefore a constituent; if so it
   returns `blocked`;
5. otherwise accepts the flat source or proceeds to the next root.

Testing the requested folder form before the flat form is what permits a real
deeper folder module such as `pkg/service/worker/worker.titan` even when
`pkg/service/worker.titan` contributes to `pkg.service`. Conversely, the
parent marker alone does not block a missing child: the privacy result exists
only when the requested flat constituent itself is present.

The source resolver runs only after ordinary compiled-module lookup for a
dependency has missed, so compiled providers keep precedence. `titanc` marks
command-line modules as explicit source roots, so they skip binary selection
but otherwise use the same folder/flat resolver. An import AST marked
`source_required` takes the same canonical resolver path under its stripped
logical name, but a clean miss is terminal and no compiled lookup or fallback
occurs. The in-memory `driver.tableloader` is a one-entry, one-source loader;
filesystem folder semantics do not leak into checker fixtures or embeddings.

## Source descriptors are not AST nodes

The `kind`, `main`, and `files` fields are temporary driver metadata. There is
no `Ast.SourceUnit`, per-file wrapper, or contributor namespace. The driver
calls `parser.parse(filename, input)` independently and sequentially for each
file, using its real filename, then appends the returned ordinary root nodes
to one dense numeric AST list.

Independent parsing preserves line and column coordinates and prevents token
or comment boundaries from flowing between files. Sequential calls also
preserve the parser's non-reentrant `THIS_FILENAME` contract: one
parse finishes completely before the next begins.

Assembly order (`driver.lua` `parse_source_inner`) is:

1. main-source roots in their parser order, temporarily excluding its final
   parser-marked module initializer when present;
2. contributor roots in numeric-byte basename order and their parser order;
3. the saved main initializer, appended once at the end.

The parser annotates that root role with `_module_initializer`, because a
plain initializer is an `Ast.StatBlock` while one with a `catch` trailer is an
`Ast.StatTry`. The driver uses the role annotation, rather than guessing from
the statement tag, to extract the main initializer and reject an initializer
from a contributor at its `do` location (`module initializer is only allowed in
the folder main source '…'`). Nested block statements
are ordinary descendants and remain legal. Parser desugarings stay in their
original per-file order: a record keeps its `_record_constructor` static
adjacent, and a union keeps all `_union_constructor` statics adjacent in
variant order. Later checker staging recognizes those markers rather than
relying on spellings.

The numeric-byte comparator compares `string.byte` values and shorter
prefixes, not locale collation. It is also used for keyed interface maps whose
serialization must be reproducible. Ordered interface data remains ordered:
module-member, record-field, and union-variant arrays are never alphabetized.

## One checker invocation and one identity

After assembly, `driver.defaultloader` installs the usual `CIRCULAR_MARK` for
logical name `M` and calls `checker.check` exactly once with:

- module name `M`;
- the combined dense AST;
- the main source text and filename;
- the ordinary recursive loader.

This produces one symbol table, module scope, module type, nominal-owner
owner, dependency closure, and `has_main` decision. A top-level `local`
declaration is consequently module-private across all contributors, never
file-private. An import in any contributor enters the one direct-dependency
set. Circularity and cache identity remain keyed solely by `M`.

The main filename also remains the checker's source directory. Because every
contributor is an immediate sibling of the main, a quoted `foreign import`
from any contributor resolves relative to that shared directory.

The source cache entry is:

```lua
driver.imported[M] = {
    kind = "source",
    ast = combined_ast,
    type = module_type,
    filename = source.main,
    source_files = source.files,
    native_output = source.native_output,
    program_output = source.program_output,
    deps = direct_deps,
    -- plus generated-header and C-header dependency state:
    -- headers, c_header_dependencies, source_manifest
}
```

The entry keeps the constituent filenames (`source_files`) for timestamps and
coverage, but no per-file AST wrapper. Source filenames survive on each node's
`loc` value. Duplicate-declaration diagnostics use those locations for both the
later declaration and the full `filename:line:column` location of the earlier
one.

The checker annotates this unchanged list with `_toplevel_order`
(`checker/declarations.lua`) and premarks ordinary duplicate winners in
combined order. It then precollects aliases before reserving surviving ordinary
names and visiting imports, alias targets, records/unions and their synthesized
constructors, callable signatures, and nominal members in dependency order.
Module variables and bodies follow. This visitation schedule makes nominal
owners, aliases, functions, methods, and nominal functions visible across file
boundaries regardless of placement. For each module variable,
`st.initializer_order` and `symtab:hidden_from_initializer` mask imports and
module variables at or beyond that combined-order frontier. Folder composition
therefore supplies the order but no new visibility mechanism.

## One code-generation pass

`coder.generate` receives the same AST shape and emits one generated module:
one translation unit, or several [parts](codegen-overview.md#translation-unit-parts)
partitioned by size, never one unit per contributor.
Whole-root-list allocation and emission passes use `ipairs`, making the
declared composition order explicit. Internal maps and sets whose order is
immaterial may use `pairs`.

Checker declaration staging never rearranges this list. Consequently duplicate
precedence, ordered interface members, module slots, module-variable
initialization, and code emission follow main/contributor source order even
though declaration visibility is broader.

The generated module name, mangled symbols, nominal type names, Lua registry
key, `_init`, `luaopen_*`, ABI marker, and serialized interface all derive
from logical name `M`, never a contributor basename. Public declarations from
contributors therefore occupy the same module member space and module
`Udata` as declarations from the main source.

Because statements from several files are interleaved in the module's
generated C, per-node `#line` directives name each contributor's own file; see
[Mixed-source `#line`
attribution](codegen-overview.md#mixed-source-line-attribution).

## C, library, and program paths

`driver.compile` derives its `.c` and `.o` paths from the entry's
`native_output` stem, which is the canonical main's path. With `-o` that stem
is rerooted under the output directory (see [output-directory
routing](output-directory.md)); the table shows paths relative to the source
root or output root:

| Form for `foo.bar` | Cached filename | C/object | Foreign companion when needed |
| --- | --- | --- | --- |
| flat | `foo/bar.titan` | `foo/bar.c`, `foo/bar.o` | `foo/bar.titan.h` |
| folder | `foo/bar/bar.titan` | `foo/bar/bar.c`, `foo/bar/bar.o` | `foo/bar/bar.titan.h` |

Only one compile call is made, so contributors produce no standalone C,
object, generated header, or provider artifacts. Foreign declarations
from the combined AST share the canonical main's companion; all companions for
an invocation are planned and written before the first object is compiled. In
library mode the logical module's object joins the invocation-wide source
union, and only logical `foo.bar` has a `luaopen_foo_bar` entry in the provider (see
[Multi-module libraries](multi-module-libraries.md#provider-selection-for-a-library-invocation)
for provider naming). The provider and program link paths create their output
parent directories, so a dotted module under an external `--tree` does not
depend on source-shaped directories already existing in the working directory.
Archive metadata belongs to the one logical module object, never to its
contributors; see [Static compiled modules](static-compiled-modules.md).

Standalone entrypoint generation is logical-name based: the entrypoint is
`foo/bar__entrypoint.c` and embeds `luaopen_foo_bar`. Only the executable path
depends on the form (`source_resolution_in_root` sets `program_output`):

- flat source: `foo/bar`;
- folder source: `foo/bar__main`.

`titanc` passes that cached `program_output` to `driver.compile_program` (see
[Linking a standalone
program](driver.md#linking-a-standalone-program-drivercompile_program)); when it
is absent the dotted-name mapping applies. The `__main` sibling avoids
colliding with the folder `foo/bar/`, including when `--tree` is outside the
current directory.

## Interface determinism and compatibility

Folder modules add no AST tag, `Type.*` variant, serialized descriptor field,
native function parameter, module-state slot category, or runtime DSO lookup
rule.

Interfaces are reproducible because `types.serialize` emits keyed maps (module
`type_members`, record/union method and static-function maps) in
`util.bytewise_less` name order; Lua insertion order is never a contract.
Ordered module members, record fields, and union variants keep source order
because they define module slots, field slots, and absolute tags.

A language `interface` declaration may appear in the main or any immediate
contributor. Because the files become one dense AST before checking, it shares
the module-wide type namespace, duplicate rules, declaration staging, and
fully qualified identity with every other top-level declaration. Its method
order is its written declaration order inside that source file; contributor
byte order decides only where the whole declaration appears in the combined
AST. No contributor name enters the Interface identity or wrapper ABI.

Folder composition has no independent ABI identity: contributors first become
one checked AST and then emit one logical module, one `_mod` Udata, and one
initializer per Lua state. Contributor filenames never enter runtime identity.

## `titan.uv` dogfooding

The standard-library folder ensembles are listed in [Reserved `titan` and the
standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image),
which also owns the root list, payload order, and provider counts. Each follows
the rules above: one canonical main, immediate contributors sharing
module-private scope, one generated C/object pair, and one logical Lua entry.
Contributor filenames never become modules or archive metadata keys.

`titan.uv` is the largest. Its sources are enumerated explicitly by the
Makefile's `UV_TITAN_SOURCES`, not by a wildcard. The list is the source
inventory the Busted audits read; the compiler's own incremental build
certifies the module graph, so no listed source is a Make prerequisite of the
standard-library build. Its variants, when a source gains them, are listed
beside their default. The canonical `uv.titan` shares one
logical module with contributors for callbacks, constants, data records,
addresses, descriptors, streams, TCP/UDP, DNS, processes, threading,
synchronization, dynamic libraries, startup, and utilities. Exported records
and functions live in their semantic contributors, so member order follows
contributor order; `spec/fixtures/libuv/titan_uv_types.lua` pins the resulting
public interface. Moving private records or constants among contributors
changes private initialization order without changing the public schema. The
one `titan.uv` object owns the callback-bearing `titan/uv/uv.titan.h`
companion; consumers such as `titan.async` and `titan.fs` use its public
declarations through ordinary imports, without explicit source imports.

`titan.http`, like `titan.uv`, keeps public declarations with their semantic
contributors and owns one callback-bearing `titan/http/http.titan.h`
companion. The `titan.peg` and `titan.string` mains instead own their complete
public APIs, and their contributors have only module-local top-level
declarations; neither needs a foreign companion.

See [Driver and toolchain](driver.md) for the complete search/build flow,
[Lexer and parser](lexer-parser.md) for locations and non-reentrancy,
[The type checker](checker.md) for the combined scope, and
[Code generator: overview](codegen-overview.md) for the generated module
protocol.
