# Multi-module libraries

Titan keeps **logical module identity** separate from the **physical native
provider** that carries its symbols. A no-`main` `titanc` invocation
compiles every selected source module independently and links their objects
into matching shared and static providers. For example:

```sh
titanc app.model app.view
```

produces `app.so` and `app.a`, plus generated `app/model.lua` and
`app/view.lua` shims. Both native forms contain the modules' ordinary
`app_model_*` and `app_view_*` protocol symbols. They do not create a logical
`app` module or a combined module state.

This chapter describes DSO provider lookup, grouping, shims, and the dynamic
publication protocol. Archive metadata/resolution, flattening, paired
transaction, and three-way validation are in [Static compiled
modules](static-compiled-modules.md). Folder-source assembly remains a
property of one logical module; see [Folder modules](folder-modules.md). The
language-level packaging rules are in [Multi-module
libraries](../language/multi-module-libraries.md).

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
Unrelated roots are rejected before code generation. Transitive source
dependencies do not influence the provider name, but their objects are part
of the link union and they receive shims because their `luaopen_*` entries are
present in the image. An unrelated transitive dependency is not independently
discoverable through Titan prefix lookup merely because its object is embedded:
packaging it as a public Titan binary requires naming it as a compatible
requested root. Its generated Lua shim can still call the entry known to be in
this invocation's provider.

Standalone-program mode differs. When exactly one requested root has the
required `main(args: {string}): integer`, all source objects are linked into
that program, no provider prefix is derived, and no Lua shim is emitted.

## Compiled-module candidate search

For logical module `a.b.c`, `driver.module_binary_candidates` returns:

```text
a.so
a/b.so
a/b/c.so
```

The exact location is therefore the final candidate. The compiler first
expands the selected `TITAN_PATH_0_6`/`TITAN_PATH` with the runtime's `;;`
default-insertion semantics. It then searches **root-major**
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
relative-path precedence without embedding an absolute compiler-machine path.

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
  `<mangled>_layouts` string; a missing/malformed physical layout is terminal.
  Analysis-only queries retain the ABI/types pair and do not expose layouts;
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

Registry-first selection, copied provider descriptors, `loadlib`, and per-state
bindings are described in [Static vs dynamic dependency
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

Library mode forms the union of every source module reachable from all
requested roots, sorts logical names with `util.bytewise_less`, and links each
source module's objects exactly once, part 0 first. A dependency selected from a DSO remains dynamic
and contributes no object. A dependency selected from a static provider adds
that physical archive once; its complete validated membership is available
for direct native binding and is carried into both produced provider forms,
without making all of its logical keys ordinary resolver results. Every source
module sees the complete source union and physically carried static names as
direct during code generation, so those references become ordinary `extern`
calls rather than self-dlopen attempts.

Selected static-provider archives are ordered bytewise by normalized absolute
path, and user `-X` objects and archives keep command-line order. How the DSO
force-loads them and how the archive flattens them is in [Native
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

* `<mangled>_abi`, semantic `<mangled>_types`, physical `<mangled>_layouts`, and
  the separate `<mangled>_compatibility` projection;
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

## Validated publication and generated shims

Both native forms go to one sibling staging directory; the contained DSO keeps
the public basename so its macOS dSYM agrees. The staged pair is validated
against itself and against an archive-backed image, then published as one
recoverable transaction. The [provider link
pipeline](static-compiled-modules.md#provider-link-pipeline) orders those links
and validations within the shared job budget; see also [Three-way
validation](static-compiled-modules.md#three-way-validation) and [Publication
and installation](static-compiled-modules.md#publication-and-installation).

`titanc` stages one shim per physical logical module at
`<logical/path>.lua` (`driver.plan_module_shims`). Source contributors do not
receive shims. Every generated file starts with `driver.GENERATED_SHIM_BANNER`:

```lua
-- Generated by titanc; do not edit.
```

The banner is the ownership mark. Before code generation,
`validate_generated_shim_destination` accepts a missing destination or a regular
file that begins with the banner; any other file is user-owned and aborts the
build. Retirement is stricter: when a valid prior self-describing archive
advertises keys absent from the replacement, `driver.publish_provider_bundle`
removes an old shim only if its full contents equal
`generated_shim_contents` for that provider and module, and otherwise refuses
with `refusing to retire unrecognized old Lua shim`.

The body selects the provider through Lua's independent `package.cpath` and
calls the exact logical entry:

```lua
local path, search_error = package.searchpath("a.b", package.cpath)
if not path then error(search_error, 0) end

local titan = require "titan"
local open, open_error = titan._loadlibglobal(path, "luaopen_a_b_c")
if not open then error(open_error, 0) end

return open()
```

The Windows template passes the logical name as a third `_loadlibglobal`
argument so the helper can return an already initialized canonical module; see
[Windows loader boundary](windows-build.md#windows-loader-boundary).
`package.searchpath` intentionally follows Lua-path precedence rather than the
compiler's Titan path. Production installation avoids ambiguity by publishing
one canonical provider; fixtures prepend their intended provider root
explicitly.

### The lazy/global support helper

Stock Lua's `package.loadlib(path, "*")` is eager/global and shares Lua's own
pathname cache, so it cannot promote an image that Lua's C searcher already
mapped eager/local. Shims therefore call the internal
`titan._loadlibglobal(path, symbol)` (`titan-runtime/ltitanlib.c`
`lazyglobalload`), which keeps its own per-state cache and maps with
`RTLD_LAZY | RTLD_GLOBAL`. For the standard library this promotes the
`titan.so` image that `require "titan"` already mapped for the support table.
Bare support loading never initializes a standard module or installs the async
program bootstrap. The helper's caching, error shape, and promotion rules are
in [Generated-shim lazy/global loading and
promotion](lua-interop-internals.md#4-generated-shim-lazyglobal-loading-and-promotion).

## Reserved `titan` and the standard-library image

The bare logical module name `titan` is reserved in library mode because it
belongs to the Lua support API and every shim requires it. A **physical**
provider named `titan` is valid only when its final image also contains
`ltitanlib.o`'s genuine `luaopen_titan`. The driver checks that entry in a fresh
Lua process (`driver.lua` `support_validation_script`) and requires exactly one
support table exposing `_loadlib`, `_loadlibglobal`, and the compiler digests
`_sha256_binary` and `_sha256_stream`. A stale support object without either
digest fails as stale before publication. Compiler-side `package.loaded` state cannot satisfy the
proof.

The production standard library is the canonical example. One compiler
invocation names all twenty-six logical roots (`Makefile` `STDLIB_ROOTS`):
`titan.coroutine`, `titan.uv`, `titan.async`, `titan.timer`, `titan.io`,
`titan.fs`, `titan.net`, `titan.ssl`, `titan.url`, `titan.http`,
`titan.websocket`, `titan.os`, `titan.path`, `titan.peg`, `titan.string`,
`titan.math`, `titan.lua`, `titan.iteration`, `titan.gc`, `titan.test`,
`titan.reflect`, `titan.sqlite3`, `titan.json`, `titan.protobuf`,
`titan.transfer`, and `titan.thread`. `titan.uv`, `titan.http`,
`titan.websocket`, `titan.peg`, `titan.string`, `titan.sqlite3`,
`titan.json`, `titan.lua`, `titan.protobuf`, and `titan.thread` are folder
ensembles; the others are flat `titan/<name>.titan` sources. The root order is
not topological (`titan.async` precedes `titan.string`, which it imports);
recursive import loading resolves dependencies while the roots are processed.
The invocation publishes root `titan.so` and `titan.a`:

```sh
titanc --output out --source-first --incremental <STDLIB_ROOTS> \
  -X titan-runtime/ltitanlib.o lpeglabel-build/libtitan-lpeglabel.a \
     libuv-build/libuv.a llhttp-build/libtitan-llhttp.a \
     sqlite3-build/libtitan-sqlite3.a \
     openssl-build/libssl.a openssl-build/libcrypto.a  # OPENSSL_MODE=bundled
```

Internal standard imports are direct. `ltitanlib.o` is shared `-X`
payload and supplies bare `luaopen_titan` without adding a logical metadata
key. The private namespaced five-member LPegLabel archive follows it as
metadata-free payload. The pinned libuv payload follows it, then the private
llhttp and SQLite archives, and finally any bundled OpenSSL payload used directly by
`titan.ssl`. The eight HTTP callback definitions already live in the generated
`titan.http` object; there is no adapter object. Bundled archives are
force-carried into the DSO and flattened into the archive; system OpenSSL settings remain final-link inputs
and are never copied into `titan.a`. The DSO exports twenty-seven Lua entries
(`luaopen_titan` plus the twenty-six logical entries); both forms define the
twenty-six logical protocols, and the archive advertises exactly twenty-six
metadata keys.
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

The canonical installed files are the provider pair (plus the DSO's macOS
dSYM) and twenty-six Lua shims:

```text
<root>/lib/titan/0.6/titan.so
<root>/lib/titan/0.6/titan.a
<root>/lib/titan/0.6/titan.so.dSYM          # macOS only
<root>/share/lua/5.5/titan/{coroutine,uv,async,timer,io,fs,net,ssl,url,http,websocket,os,path,peg,string,math,lua,iteration,gc,test,reflect,sqlite3,json,protobuf,transfer,thread}.lua
```

The Make object graph, private support bootstrap, LuaRocks install and
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
