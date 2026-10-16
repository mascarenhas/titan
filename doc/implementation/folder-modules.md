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
An import AST marked `source_required` takes the same canonical resolver path
under its stripped logical name, but a clean miss is terminal and no compiled
lookup or fallback occurs.
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

| Form for `foo.bar` | Cached filename | C/object | Foreign companion when needed |
| --- | --- | --- | --- |
| flat | `foo/bar.titan` | `foo/bar.c`, `foo/bar.o` | `foo/bar.titan.h` |
| folder | `foo/bar/bar.titan` | `foo/bar/bar.c`, `foo/bar/bar.o` | `foo/bar/bar.titan.h` |

Only one compile call is made, so contributors produce no standalone C,
object, generated header, provider, or Lua-shim artifacts. Foreign declarations
from the combined AST share the canonical main's companion; all companions for
an invocation are planned and written before the first object is compiled. In library mode the logical module's
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

The `titan.uv` dogfood uses that rule rather than hiding public declarations
in the main source. Exported records and functions live in their semantic
contributors, so member order follows contributor order; the exact
`titan_uv_types` fixture pins the deterministic public interface. Moving
private records or constants among contributors changes private initialization
order without changing the public schema.

Folder composition has no independent ABI identity. ABI 2 covers the selected
physical prefix container, module-private Array cache, union and Interface
schemas, source-private provider identity, source foreign callbacks, generic
metadata, and current public standard-library signatures. Contributors first
become one checked AST and then emit one logical module, one `_mod` Udata, and
one initializer per Lua state. Contributor filenames never enter runtime
identity.

## `titan.uv` dogfooding

The production `titan.uv` folder ensemble is enumerated by the Makefile's
`UV_TITAN_SOURCES`; the set is explicit rather than a wildcard. Its canonical
`uv.titan` shares a logical module with contributors for callbacks, constants,
data records, addresses, descriptors, streams, TCP/UDP, DNS, processes,
threading, synchronization, dynamic libraries, startup, and utilities.
Every listed source is a prerequisite of the combined standard-library build.

The module exposes its low-level owners, views, callbacks, operations, and copied
values through an ordinary compiled interface. `titan.async` owns the scheduler,
Task/error/result/subscription declarations and automatic main hook in its own
logical module. Async and the domain libraries consume public UV declarations
without explicit source imports or a shared source-private operation union.
The production compiler invocation names all twenty-five logical roots:

```sh
titanc --output out titan.coroutine titan.uv titan.async titan.timer titan.io titan.fs titan.net \
  titan.ssl titan.url titan.http titan.websocket titan.os titan.path \
  titan.peg titan.string \
  titan.math titan.lua titan.iteration titan.gc titan.test titan.reflect titan.sqlite3 titan.json \
  titan.protobuf titan.transfer \
  -X titan-runtime/ltitanlib.o lpeglabel-build/libtitan-lpeglabel.a \
     libuv-build/libuv.a llhttp-build/libtitan-llhttp.a \
     sqlite3-build/libtitan-sqlite3.a \
     openssl-build/libssl.a openssl-build/libcrypto.a  # OPENSSL_MODE=bundled
```

Generated `out/titan/uv/uv.c`, `out/titan/uv/uv.o`, and the callback-bearing
`out/titan/uv/uv.titan.h` are build artifacts and are removed by `make clean`.
The flat high-level `titan.fs` root uses public UV callbacks and does not
emit a foreign-callback header. No contributor C/object/header, DSO, archive,
or contributor shim is built or installed. The one logical `titan.uv` object, its one generated
`out/titan/uv.lua` shim, and the remaining twenty-four logical modules (twenty-five in
total) reside in the physical `out/titan.so`/`out/titan.a` pair. The private
five-member LPegLabel archive is shared metadata-free payload for the
`titan.peg`/`titan.string` folder modules. The private libuv archive always
follows it, so its members enter both provider forms. The command above uses
bundled OpenSSL. The default system OpenSSL mode omits only its two OpenSSL
archives and repeats the ordered pkg-config link settings for the DSO; static
consumers must repeat those settings too. Higher
`async`/`timer`/`fs`/`net`/`os`/`sqlite3` modules still import
the independent logical `titan.uv` protocol, but their calls are direct
because all twenty-five source roots are linked together. The high-level `titan.fs` object uses the public UV filesystem and watcher
wrappers; their source-defined native callbacks remain in the UV object. `titan.ssl` reaches the
runtime only through public `titan.net`, and `titan.http` only through the
public net/SSL/I/O/async layers; `titan.url` is synchronous composition over
`titan.peg` and `titan.string`.

`titan.http`, `titan.websocket`, `titan.peg`, and `titan.string` apply the same folder-module
rules: each has one canonical main, immediate contributors sharing
module-private scope, one generated C/object pair, and one logical shim.
`titan.http`, like `titan.uv`, keeps public declarations with their semantic
contributors and owns one callback-bearing `titan/http/http.titan.h` companion.
The `titan.peg` and `titan.string` mains instead own their complete public APIs
and their contributors have only module-local top-level declarations; neither
currently needs a foreign companion. Contributor filenames do not become modules or archive metadata
keys.

See [Driver and toolchain](driver.md) for the complete search/build flow,
[Lexer and parser](lexer-parser.md) for locations and non-reentrancy,
[The type checker](checker.md) for the combined scope, and
[Code generator: overview](codegen-overview.md) for the generated module
protocol.
