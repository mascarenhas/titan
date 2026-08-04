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

For each source-root entry, resolution:

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
dependency has missed. Exact binaries therefore retain their existing
precedence. `titanc` marks command-line modules as explicit source roots, so
they skip binary selection but otherwise use the same folder/flat resolver.
The old in-memory `driver.tableloader` remains a one-entry, one-source loader;
filesystem folder semantics do not leak into checker fixtures or embeddings.

## Source descriptors are not AST nodes

The `kind`, `main`, and `files` fields are temporary driver metadata. There is
no `Ast.SourceUnit`, per-file wrapper, or contributor namespace. The driver
calls `parser.parse(filename, input)` independently and sequentially for each
file, using its real filename, then appends the returned ordinary root nodes
to one dense numeric AST list.

Independent parsing preserves line and column coordinates and prevents token
or comment boundaries from flowing between files. Sequential calls also
preserve the parser's existing non-reentrant `THIS_FILENAME` contract: one
parse finishes completely before the next begins.

Assembly order is:

1. main-source roots in their parser order, temporarily excluding its final
   parser-marked module initializer when present;
2. contributor roots in numeric-byte basename order and their parser order;
3. the saved main initializer, appended once at the end.

The parser annotates that root role with `_module_initializer`, because a
plain initializer is an `Ast.StatBlock` while one with `catch` or `finally`
trailers is an `Ast.StatTry`. The driver uses the role annotation, rather than
guessing from the statement tag, to extract the main initializer and reject an
initializer from a contributor at its `do` location. Nested block statements
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
    ast = combined_ast,
    type = module_type,
    filename = source.main,
    program_output = source.program_output,
    deps = direct_deps,
}
```

The cache does not retain contributor descriptors after parsing. Source
filenames survive on each node's existing `loc` value. Duplicate-declaration
diagnostics use those locations for both the later declaration and the full
`filename:line:column` location of the earlier one.

The checker annotates this unchanged list with `_toplevel_order` and premarks
ordinary duplicate winners in combined order. It then precollects aliases
before reserving surviving ordinary names and visiting imports, alias targets,
records/unions and their synthesized constructors, callable signatures, and
nominal members in dependency order. Module variables and bodies follow. This
visitation schedule makes nominal owners, aliases, functions, methods, and
nominal functions visible across file boundaries regardless of placement. For each
module variable, `initializer_order` temporarily masks imports and module
variables at or beyond the applicable combined-order frontier. Thus folder
composition supplies the order but does not create a new visibility mechanism.

## One code-generation pass

`coder.generate(M, combined_ast, static_deps, abi,
emit_line_directives)` still receives the same AST shape and emits one
translation unit. Whole-root-list allocation and emission passes use `ipairs`,
making the declared composition order explicit. Internal maps and sets whose
order is immaterial may continue to use `pairs`.

Checker declaration staging never rearranges this list. Consequently duplicate
precedence, ordered interface members, module slots, module-variable
initialization, and code emission continue to follow main/contributor source
order even though declaration visibility is broader.

The generated module name, mangled symbols, nominal type names, Lua registry
key, `_init`, `luaopen_*`, ABI marker, and serialized interface all derive
from logical name `M`, never a contributor basename. Public declarations from
contributors therefore occupy the same module member space and module
`Udata` as declarations from the main source.

`coder.emitline(node)` already quotes and emits each node's own
`loc.filename`. Because functions and statements from several files are
interleaved in one C output, code generation retains the existing per-node
directives at safe physical-line sites: function entries, statements, calls,
`raise`, and related throw sites. It does not emit one translation-unit-wide
source directive or stamp expression fragments that may appear in the middle
of a physical C line. DWARF and libbacktrace can consequently report the
actual contributor filename and line.

## C, library, and program paths

`driver.compile` already derives its `.c` and `.o` paths from the cached
source filename, so storing the canonical main gives the required output:

| Form for `foo.bar` | Cached filename | C/object |
| --- | --- | --- |
| flat | `foo/bar.titan` | `foo/bar.c`, `foo/bar.o` |
| folder | `foo/bar/bar.titan` | `foo/bar/bar.c`, `foo/bar/bar.o` |

Only one compile call is made, so contributors produce no standalone C,
object, provider, or Lua-shim artifacts. In library mode the logical module's
object joins the invocation-wide source union. A single `foo.bar` root derives
the exact provider pair `foo/bar.so` and `foo/bar.a`; several compatible roots
may derive a shallower common pair. Either way exactly one generated shim
represents logical `foo.bar`. The provider and program link paths ensure their
output parent directories exist, so a dotted module under an external
`--tree` does not depend on source-shaped directories already existing in the
working directory. Archive metadata still belongs to the one logical module
object, never to its contributors; see [Static compiled
modules](static-compiled-modules.md).

Standalone entrypoint generation also remains logical-name based:
`write_entrypoint("foo.bar")` writes `foo/bar__entrypoint.c` and embeds the
same module name, `luaopen_foo_bar`, and program name as before. The only new
value is the cached executable path:

- flat source: `foo/bar`;
- folder source: `foo/bar__main`.

`driver.compile_program` accepts that path as the optional `program_output`
argument immediately before the trailing selected-static-archive list, and
defaults to the old dotted-name mapping for existing callers and
`tableloader`. `titanc` and filesystem-based child compilers pass the cached
`program_output`. The `__main` sibling avoids colliding with the folder
`foo/bar/`, including when `--tree` is outside the current directory.

## Interface determinism and compatibility

Folder modules add no AST tag, `Type.*` variant, serialized descriptor field,
native function parameter, module-state slot category, or runtime DSO lookup
rule. The representation mechanism does not itself require an ABI change.

One adjacent determinism fix makes interfaces reproducible: keyed module type
aliases and nominal method/static-function maps are serialized in
`util.bytewise_less` name order. This changes only the textual order chosen for
maps whose Lua insertion order was never a contract. Ordered module members,
record fields, and union variants retain source order because they define
module slots, field slots, and absolute tags.

A language `interface` declaration may appear in the main or any immediate
contributor. Because the files become one dense AST before checking, it shares
the module-wide type namespace, duplicate rules, declaration staging, and
fully qualified identity with every other top-level declaration. Its method
order is its written declaration order inside that source file; contributor
byte order decides only where the whole declaration appears in the combined
AST. No contributor name enters the Interface identity or wrapper ABI.

The `titan.uv` dogfood intentionally uses that rule rather than hiding public
declarations in the main source. Its exported records and functions live in
the semantic contributors, so their member order follows the contributor
sequence `file`, `os`, `process`, `runtime`, `task`, `tcp`. That initial public
move differed from the old monolithic member order, so the release advanced
the compiled-module ABI to **0.15** and the exact `titan_uv_types` fixture pins
the resulting deterministic interface. The subsequent declaration-order pass
moves the remaining private records to their semantic contributors and moves
the private `FS` constants instance beside `FsConstants` in `file.titan`.
Private slot and initialization order change, but no serialized public member,
importer-visible variable slot, canonical exported-function closure slot, or
fixture does. It therefore remained ABI 0.15 until the later provider-layout
transition.

ABI 0.16 leaves this logical interface unchanged but permits `M`'s symbols to
reside in a shared prefix container. Runtime imports load the selected
`Type.Module.file`, publish one `_mod` `Udata` for `M` in the registry, and
invoke only `M`'s initializer once per Lua state. No runtime component knows
whether its object came from a flat or folder source representation, and the
container does not gain a contributor protocol.

ABI 0.17 likewise leaves folder composition and the serialized logical
interface unchanged. Every generated module—flat or folder—reserves the same
unconditional private Array-metatable cache after its importer-reconstructed
public prefix. That private slot and the new Array boxing protocol require the
ABI transition, but contributor boundaries still have no runtime identity.
See [Dense Arrays](dense-arrays.md#canonical-proxy-and-module-cache).

ABI 0.18 preserved folder composition, contributor ordering, and the logical
interface again. Its compatibility boundary is instead the external callback
symbol contract between standard-library archive objects and the runtime.

ABI 0.19 still gave contributors no runtime identity. It added union schemas
and absolute variant tags, plus the reconstructible public nominal-static slot
prefix. Folder order therefore remains authoritative for public owner/member
order and for variant tags, while keyed static maps use bytewise ordering.

ABI 0.20 again leaves folder composition unchanged. Array writer inventories,
callable strict entries, Interface descriptors, and concrete/Interface pair
obligations are collected only after the contributors have become one checked
AST, then emitted once per logical module. Their module-private slots follow
the same importer-reconstructible public prefix and never give a contributor a
runtime identity. The `process.titan` contributor now also exports the nominal
`uv_stdio_t` process-stream wrapper used by `titan.os`; its private native
representation is a pipe-or-TTY union. This changes the logical `titan.uv`
schema, not contributor identity or composition.

## `titan.uv` dogfooding

The production `titan.uv` source is the folder ensemble
`titan/uv/uv.titan`, `file.titan`, `os.titan`, `process.titan`,
`runtime.titan`, `task.titan`, and `tcp.titan`. The main file
owns shared imports, shared constants, module state, bootstrap setup,
program-argument setup, and the sole initializer. Each contributor owns its
public API and both public and private records alongside the related
implementation. The main file
exports no member and declares no record. The Makefile
declares this set explicitly as `UV_TITAN_SOURCES`; it does not use a
wildcard, so adding a production source changes the reviewed build graph.
Every listed source is a prerequisite of the one combined standard-library
completion target. The production compiler invocation names all seventeen logical
roots:

```sh
titanc titan.coroutine titan.uv titan.async titan.timer titan.io titan.fs titan.net \
  titan.ssl titan.url titan.http titan.os \
  titan.peg titan.string \
  titan.math titan.lua titan.iter titan.gc \
  -X titan-runtime/titanlib.o lpeglabel-build/libtitan-lpeglabel.a \
     libuv-build/libuv.a llhttp-build/titan_httpshim.o \
     llhttp-build/libtitan-llhttp.a \
     openssl-build/libssl.a openssl-build/libcrypto.a  # bundled modes
```

Generated `titan/uv/uv.c` and `titan/uv/uv.o` are build artifacts and are
removed by `make clean`. No contributor DSO, archive, or contributor shim is
built or installed. The one logical `titan.uv` object, its one generated
`titan/uv.lua` shim, and the remaining sixteen logical modules (seventeen in
total) reside in the physical `titan.so`/`titan.a` pair. The private
five-member LPegLabel archive is shared metadata-free payload for the
`titan.peg`/`titan.string` folder modules. Bundled mode then supplies the
private libuv archive, so its
members enter both provider forms;
system mode repeats the configured final-link setting for the DSO and does not
copy it into `titan.a` (and omits `libuv-build/libuv.a` from the command).
That setting may itself select a shared or static system library. Higher
`async`/`timer`/`fs`/`net`/`os` modules still import
the independent logical `titan.uv` protocol, but their calls are direct
because all seventeen source roots are linked together. `titan.ssl` reaches
that runtime only through public `titan.net`, and `titan.http` only through the
public net/SSL/I/O/async layers; `titan.url` is synchronous composition over
`titan.peg` and `titan.string`. None adds a direct uv dependency.

`titan.http`, `titan.peg`, and `titan.string` apply the same folder-module
rules: each has one canonical main, immediate contributors sharing
module-private scope, one generated C/object pair, and one logical shim.
`titan.http`, like `titan.uv`, keeps public declarations with their semantic
contributors. The `titan.peg` and `titan.string` mains instead own their
complete public APIs and their contributors have only module-local top-level
declarations. Contributor filenames do not become modules or archive metadata
keys.

See [Driver and toolchain](driver.md) for the complete search/build flow,
[Lexer and parser](lexer-parser.md) for locations and non-reentrancy,
[The type checker](checker.md) for the combined scope, and
[Code generator: overview](codegen-overview.md) for the generated module
protocol.
