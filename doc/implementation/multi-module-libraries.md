# Multi-module libraries

Titan keeps **logical module identity** separate from the **physical native
provider** that carries its symbols. A no-`main` `titanc` invocation
compiles every owned authored source module independently (checking external
installed-source dependencies without compiling or linking them) and links
those owned objects into matching shared and static providers. For example:

```sh
titanc app.model app.view
```

produces `app.so` and `app.a`. Both native forms contain the modules' ordinary
`app_model_*` and `app_view_*` protocol symbols. They do not create a logical
`app` module or a combined module state, and library mode writes no Lua file:
Lua reaches each logical module through the [Titan package
searcher](driver.md#the-titan-package-searcher), which uses the same candidate
and claim rules as the compiler.

This chapter describes DSO provider lookup, grouping, and the dynamic
publication protocol. Archive metadata/resolution, flattening, paired
transaction, and three-way validation are in [Static compiled
modules](static-compiled-modules.md). Folder-source assembly remains a
property of one logical module; see [Folder modules](folder-modules.md). The
language-level packaging rules are in [Shared, static, and multi-module
providers](../language/toolchain.md#shared-static-and-multi-module-providers).

## Provider selection for a library invocation

After typechecking and exact `main` detection, library mode deduplicates the
requested CLI roots while preserving their first occurrence and takes their
longest common sequence of complete dotted components
(`driver.common_module_provider`). That prefix is the physical provider name:

| Requested roots | Provider | Outputs |
| --- | --- | --- |
| `foo` | `foo` | `foo.so`, `foo.a` |
| `foo.bar` | `foo.bar` | `foo/bar.so`, `foo/bar.a` |
| `foo.left foo.right` | `foo` | `foo.so`, `foo.a` |
| `foo.bar.left foo.bar.right` | `foo.bar` | `foo/bar.so`, `foo/bar.a` |

The comparison is component-wise: `foo` and `foobar` have no common prefix.
Unrelated roots are rejected before code generation. Authored transitive source
dependencies from `--tree` do not influence the provider name, but their objects
are part of the link union and their `luaopen_*` entries are present in the
image; external installed-source dependencies are checked without entering the
library's link union. An unrelated transitive dependency is not independently
discoverable through Titan prefix lookup, at compile time or by the run-time
searcher, merely because its object is embedded: packaging it as a public Titan
binary requires naming it as a compatible requested root.

Standalone-program mode differs. When exactly one requested root has the
required `main(args: {string}): integer`, all source objects are linked into
that program and no provider prefix is derived.

## Compiled-module candidate search

For logical module `a.b.c`, `driver.module_binary_candidates` returns:

```text
a.so
a/b.so
a/b/c.so
```

The exact location is therefore the final candidate. The compiler first
expands the selected `TITAN_PATH_0_6`/`TITAN_PATH` with the [shared `;;` and
`!` grammar](driver.md#titan-path-syntax) (`driver.titan_bin_path_entries`).
It then searches **root-major**
(`driver.find_dynamic_interface`; `driver.find_static_interface` is the `.a`
pass described in [Static compiled modules](static-compiled-modules.md#resolver-state-and-format-passes)):
all shallow-to-exact candidates in the first path root, then all candidates in
the second root, and so on.

An occupied relative candidate shadows the same relative name in later roots.
The driver marks it occupied as soon as `lstat` finds any pathname, before
opening or inspecting metadata. A missing candidate remains available in a
later root. Consequently a local exact `./a/b/c.so` can still beat a shallow
installed `a.so`, while an earlier root's unrelated `a.so` prevents a later
root's `a.so` from being selected. Generated runtime imports reproduce the same
relative-path precedence without embedding an absolute compiler-machine path,
and the run-time [Titan package searcher](driver.md#the-titan-package-searcher)
applies the same root-major, shadowing, and claim rules to `require`. Only the
defaults differ: the compiler searches `.;<root>/lib/titan/0.6`, while
programs and Lua hosts search `!;!/../lib/titan/0.6` and then the lazy SDK
fallback.

### Claim and terminal-error states

An existing candidate is inspected with `titan._loadlib`, the compiler-only
`RTLD_LAZY | RTLD_LOCAL` helper (`titan-runtime/ltitanlib.c` `lazyload`). On
Windows the ABI marker is first read through the plain-C `_abivalue` query; see
[Windows loader boundary](windows-build.md#windows-loader-boundary). Membership
in logical module `a.b.c` is the ordinary symbol pair:

```text
a_b_c_abi
a_b_c_types
```

The states are deliberately strict:

* neither symbol present is a clean nonclaim for an **ancestor** candidate;
* exactly one symbol present is a terminal corrupt-claim error (`compiled
  container '…' claims module '…' but is missing metadata symbol '…'`);
* an open failure is terminal;
* once both symbols exist, a call failure, result-count/type error, ABI
  mismatch, malformed serialized type, or logical-name mismatch is terminal;
* both valid symbols claim the logical module and end the search;
* after that semantic claim, native compilation additionally requires a valid
  `<mangled>_layouts` string (missing or malformed physical layouts are
  terminal), whereas analysis-only queries skip `<mangled>_layouts` and do not
  expose layouts;
* after ABI/type validation (and, in native compilation, after layout
  validation), both native and analysis-only queries probe optional
  `<mangled>_source_requirements` (clean absence when omitted; open/call/decode
  failure is terminal; no module initialization runs, and
  `<mangled>_compatibility` is not queried during compiler DSO lookup);
* an exact candidate with neither symbol retains the markerless-binary error
  instead of falling through to source.

The ABI marker must return exactly one string equal to `TITAN_ABI_VERSION`;
otherwise the claim fails with `compiled module '…' has no compatible Titan ABI
marker (expected 2)` before any type decoding. The types entry must return
exactly one serialized `Type.Module` for the requested logical name, with a
canonical public schema. The loader does not scan later images after a claim;
visible duplicate providers are resolved by ordinary first match, not by
ambiguity detection.

Each logical module still receives its own `driver.imported[M]` entry. The
entry's `filename` is the normalized absolute candidate used by the compiler,
so several logical entries may share one compiler-side native handle. The
module type receives a different, relocatable value:

```lua
modtype.file = "a/b.so"
```

`Type.Module.file` defaults to the exact `a/b/c.so` path when the type is
constructed. Rehydration overwrites it with the selected relative provider.
It is intentionally omitted from `types.serialize`: physical deployment is a
property of this lookup, not part of the module's public type interface.

## Runtime imports reuse canonical logical modules

The coder uses `node._type.file` (the relative provider selected above) as the
fallback provider filename; generated C never repeats candidate probing. An
import of `a.b.c` selected from `a/b.so` emits:

```c
TitanModuleProvider a_b_c_provider =
    titan_module_provider(L, "a.b.c", "a/b.so");
titan_check_module_abi(L, a_b_c_provider, "a_b_c_abi", "a/b.so");
titan_check_module_compatibility(L, a_b_c_provider, "a_b_c_compatibility", "a/b.so",
    verifier_source, verifier_length);
```

Generated dynamic imports declare one `TitanModuleProvider` variable per
logical compiled module, even when several local aliases import it. Only the
declaration is shared: every alias keeps its own module slot and still elects
and checks the provider, calls initialization, and rechecks the canonical
provider afterward. Deduplication is by logical module, not provider filename,
so two logical imports from one provider reuse one runtime handle while
resolving different mangled symbols.

Registry-first selection, native preloads, the executable's linked provider
set, the `loadlib` fallback, and per-state bindings are described in
[Static vs dynamic dependency
wiring](codegen-overview.md#static-vs-dynamic-dependency-wiring); the
compatibility checks are in [Generated exports and runtime
verification](binary-compatibility.md#generated-exports-and-runtime-verification).
Candidate membership is a compiler concern. The relative file only makes the
fallback runtime load exact and relocatable; the logical registry owns
initialized module identity.

## One object set per logical module

Multi-module linking does not merge ASTs, module types, or generated C.
`driver.defaultloader` checks each source module once and `coder.generate`
emits one generated module per logical module: one translation unit, or
several [parts](codegen-overview.md#translation-unit-parts) when the module is
large. A folder module has already been assembled into one AST, so it
naturally contributes one ordered object set: its primary object followed by
any part objects.

Library mode forms the union of every owned authored source module reachable
from all requested roots (stopping at external installed-source dependencies,
which are checked for their public interface and public nominal layouts without
entering the library's link union) and links each owned source module's objects
exactly once, in bytewise logical-name and part order. In a native build, a
compiled external dependency must supply a shared provider, which contributes
no object. Native library mode does not flatten another Titan archive into the
pair. Browser providers retain their preexisting separate archive composition
for compiled browser archive dependencies while leaving external installed
sources and their private dependencies outside the library archive. Native `-X`
objects and archives keep command-line order; see [Native
composition](static-compiled-modules.md#native-composition).

Before code generation, `titanc` preflights every logical module in the link
union. It rejects the reserved name `titan`, distinct logical names that map to
one C prefix (`driver.mangle_module_name`, for example through dot/dash
replacement: `cannot link logical modules '…' and '…': both use C symbol prefix
'…'`), and any two modules whose externally visible symbols
(`coder.external_symbols`, or `coder.interface_external_symbols` for carried
compiled interfaces) coincide. Real collisions are therefore reported by name
instead of as an opaque duplicate-symbol linker error. The `ℳ`/`ℱ` separators
that keep module `a` function `b_c` distinct from module `a.b` function `c` are
described in [Anatomy of a generated translation
unit](codegen-overview.md#anatomy-of-a-generated-translation-unit).

Both native provider forms contain independent copies of every logical
protocol:

* `<mangled>_abi`, semantic `<mangled>_types`, physical `<mangled>_layouts`,
  the separate `<mangled>_compatibility` projection, and (only when the module
  has non-empty folded external source obligations) `<mangled>_source_requirements`
  returning the newline-joined canonical list (decoded by
  `staticmetadata.decode_source_requirements`, probed by
  `probe_compiled_interface` with clean `stage == "init"` absence when omitted,
  and matched against the paired archive—including clean absence when empty—by
  `driver.validate_library_image_fresh`);
* `<mangled>_init` and `luaopen_<mangled>`;
* a native export descriptor and per-state binding caches in the module payload;
* a distinct registry-owned module `Udata`, variables, canonical closures,
  record/union metatables, initializer, and nominal owners.

There is no provider initializer and a container need not provide a logical
module having the provider's own name. Requiring one logical child from the
DSO initializes only that child and its imports. Each Titan-generated object
also carries its one-key archive metadata section; the archive's validated
union is physical membership metadata, not a new run-time module table.
Layout strings are independent of semantic descriptors and analysis inventories;
paired archive/DSO publication compares both byte strings. The public-prefix
layout rules are in [Native nominal storage](nominal-storage.md).

## Validated publication

Both native forms go to one sibling staging directory; the contained DSO keeps
the public basename so its macOS dSYM agrees. The staged pair is validated
against itself and against an archive-backed image, then published as one
recoverable transaction. The [provider link
pipeline](static-compiled-modules.md#provider-link-pipeline) orders those links
and validations within the shared job budget; see also [Three-way
validation](static-compiled-modules.md#three-way-validation) and [Publication
and installation](static-compiled-modules.md#publication-and-installation).

The provider pair (plus the Darwin dSYM) is the whole published set.
`driver.provider_output_path(provider, output_root)` returns the DSO path for
a provider prefix below the output root, or `nil, "invalid library provider
name '…'"`. No Lua loader is planned, generated, validated for ownership,
retired, or published, so a published library is consumable from Lua exactly
where it is consumable from Titan: on the Titan path.

Lua code reaches a logical module with ordinary `require` once the state has
the Titan searcher. The searcher's runtime candidate probe uses
`dlopen(realpath, RTLD_LAZY | RTLD_LOCAL)` and promotes only a valid claim to
`RTLD_LAZY | RTLD_GLOBAL` before resolving `luaopen_<mangled>`, so the
provider's unresolved calls can later bind to dependencies that generated
imports load. `require` passes the requested name and the provider path to
that opener, and the generated [file-load name
guard](codegen-overview.md#lua-entries-and-abi-type-and-layout-metadata)
rejects a logical name that merely shares the mangled spelling. The loading paths and
caches are in [Four shared-library loading
paths](lua-interop-internals.md#four-shared-library-loading-paths).

The searcher is appended after Lua's own searchers. A Titan provider
directory must therefore not appear on `package.cpath`: Lua's all-in-one C
searcher would otherwise open `titan.so` for `require "titan.string"` and call
`luaopen_titan_string` itself, bypassing the ABI check and the lazy/global
promotion. Likewise, an old generated `<logical/path>.lua` file left on
`package.path` (`./?.lua` included) is found before the Titan searcher; delete
such files from pre-release output trees.

## Reserved `titan` and the standard-library image

The bare logical module name `titan` is reserved: `require "titan"` loads the
Lua support module from `lib/lua/5.5`, and the Titan searcher never resolves
that name. `titanc` therefore rejects a logical module named exactly `titan`
in the link union (`logical module 'titan' is reserved by Titan's native Lua
support module`). A **physical** provider prefix `titan` carries no support
entry and needs no special validation; the standard library is the canonical
provider with that prefix.

The production standard library is the canonical example. One compiler
invocation names all twenty-six logical roots (`Makefile` `STDLIB_ROOTS`):
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`,
`titan.websocket`, `titan.os`, `titan.path`, `titan.peg`, `titan.string`,
`titan.math`, `titan.lua`, `titan.iteration`, `titan.gc`, `titan.test`,
`titan.reflect`, `titan.sqlite3`, `titan.json`, `titan.protobuf`,
`titan.transfer`, and `titan.thread`. `titan.uv`, `titan.async`, `titan.http`,
`titan.websocket`, `titan.os`, `titan.peg`, `titan.string`, `titan.sqlite3`,
`titan.json`, `titan.lua`, `titan.protobuf`, and `titan.thread` are folder
ensembles; the others are flat sources. The mains of `titan.fs`,
`titan.net`, `titan.ssl`, `titan.uv`, `titan.http`, `titan.websocket`,
`titan.sqlite3` and `titan.thread` are `native` variants
(`titan/fs.native.titan`, `titan/uv/uv.native.titan`), so the browser target
has none of them. `titan.os` and `titan.lua` have shared mains with native and
browser contributors: browser `os` omits native host/process capabilities,
and browser `lua` omits file loading and background execution.
The complete shared `titan.io` facade imports the selected `os` composition.
`titan.timer` has a `native` and a `browser` variant
(`titan/timer.native.titan`, `titan/timer.browser.titan`) with one public
interface. Fourteen shared roots including `io`, the target-specific
compositions of `async`, `timer`, `os`, `lua`, `http`, and `websocket`, and the
browser-only `titan.browser` form the twenty-one-module [browser standard
provider](browser-target.md#the-browser-standard-library). The root order is
not topological (`titan.async` precedes `titan.string`, which it imports);
recursive import loading resolves dependencies while the roots are processed.
The invocation publishes root `titan.so` and `titan.a`:

```sh
titanc --output out --source-first --incremental <STDLIB_ROOTS> \
  -X lpeglabel-build/libtitan-lpeglabel.a \
     libuv-build/libuv.a llhttp-build/libtitan-llhttp.a \
     sqlite3-build/libtitan-sqlite3.a \
     openssl-build/libssl.a openssl-build/libcrypto.a  # OPENSSL_MODE=bundled
```

Internal standard imports are direct. The private namespaced five-member
LPegLabel archive is the first, metadata-free `-X` payload. The pinned libuv
payload follows it, then the private llhttp and SQLite archives, and finally
any bundled OpenSSL payload used directly by `titan.ssl`. The eight HTTP
callback definitions already live in the generated `titan.http` object; there
is no adapter object. Bundled archives are force-carried into the DSO and
flattened into the archive; system OpenSSL settings remain final-link inputs
and are never copied into `titan.a`. The provider carries no `ltitanlib.o`:
the DSO exports exactly the twenty-six logical Lua entries and no
`luaopen_titan`, both forms define the twenty-six logical protocols, and the
archive advertises exactly twenty-six metadata keys.
`OPENSSL_MODE` defaults to `system`. Static consumers then pass the ordered
`pkg-config --libs openssl` result through `TITAN_EXTRA_LDFLAGS`; both the
executable-context archive probe and the final program link append those
inputs after the consumer and provider objects. Foreign headers provide
declarations, not link directives, so a direct application FFI call such as
`SHA256` needs the same system inputs even when no TLS operation makes an
OpenSSL reference reachable from `titan.ssl`.
The private LPegLabel archive and its headers remain source-build inputs; they
are not installed in the compiler/runtime SDK. The generated `.titan.h`
companions of `titan.coroutine`, `titan.uv`, `titan.async`, `titan.http`,
`titan.sqlite3`, `titan.lua`, `titan.protobuf`, `titan.transfer`, and
`titan.thread` (`Makefile` `STDLIB_GENERATED_FOREIGN_HEADERS`) are
likewise generated source-build intermediates: they are available before the
standard objects compile but never become provider members, publication-stage
artifacts, or installed headers.

The canonical installed files are the provider pair, plus the DSO's macOS
dSYM, and the separately built support module:

```text
<root>/lib/titan/0.6/titan.so
<root>/lib/titan/0.6/titan.a
<root>/lib/titan/0.6/titan.so.dSYM          # macOS only
<root>/lib/lua/5.5/titan.so                 # support module, not a provider
```

The Make object graph, support module, LuaRocks install and
`post_install` copy, uninstall, and binary rock are described in [Build and
installation responsibilities](build-script-audit.md). Production library tests
treat the installed set as read-only; CI snapshots and restores it around
compiler groups (see [Continuous integration](continuous-integration.md)).
Windows builds a DLL-only form of the same image; see [Standard-provider build
and publication](windows-build.md#standard-provider-build-and-publication).

## ABI and test-only exact providers

The dynamic and static forms carry the same ABI marker and logical type
manifests, and a mismatched marker is terminal before metadata decoding or
native linking. What the ABI covers, and how `TITAN_PATH_0_6` and
`lib/titan/0.6` derive from `TITAN_VERSION`, is in [Compiled-module
ABI](codegen-overview.md#compiled-module-abi). Exact-path test providers remain
valid as the final candidate in each format.

Production, installed, and native standard-library behavior tests all use the
combined image. There is no alternate exact-provider graph or source-rewritten
standard image; implementation mechanics are covered by the compiler and native
harness specs.
