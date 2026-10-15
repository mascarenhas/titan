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
longest common sequence of complete dotted components. That prefix is the
physical provider name:

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

Standalone-program mode is unchanged. When exactly one requested root has the
required `main(args: {string}): integer`, all source objects are linked into
that program, no provider prefix is derived, and no Lua shim is emitted.

## Compiled-module candidate search

For logical module `a.b.c`, `driver.module_binary_candidates` returns:

```text
a.so
a/b.so
a/b/c.so
```

The exact historical location is therefore the final candidate. The compiler
first expands the selected `TITAN_PATH_0_6`/`TITAN_PATH` with the runtime's
`;;` default-insertion semantics. It then searches **root-major**: all
shallow-to-exact candidates in the first path root, then all candidates in the
second root, and so on.

An occupied relative candidate shadows the same relative name in later roots.
The driver marks it occupied as soon as `lstat` finds any pathname, before
opening or inspecting metadata. A missing candidate remains available in a
later root. Consequently a local exact `./a/b/c.so` can still beat a shallow
installed `a.so`, while an earlier root's unrelated `a.so` prevents a later
root's `a.so` from being selected. This is the same relative-path precedence
that generated runtime imports can reproduce without embedding an absolute
compiler-machine path.

### Claim and terminal-error states

An existing candidate is inspected with `titan._loadlib`, the compiler-only
`RTLD_LAZY | RTLD_LOCAL` helper. Membership in logical module `a.b.c` is the
ordinary symbol pair:

```text
a_b_c_abi
a_b_c_types
```

The states are deliberately strict:

* neither symbol present is a clean nonclaim for an **ancestor** candidate;
* exactly one symbol present is a terminal corrupt-claim error;
* an open failure is terminal;
* once both symbols exist, a call failure, result-count/type error, ABI
  mismatch, malformed serialized type, or logical-name mismatch is terminal;
* both valid symbols claim the logical module and end the search;
* after that semantic claim, native compilation additionally requires a valid
  `<mangled>_layouts` string; a missing/malformed physical layout is terminal.
  Analysis-only queries retain the ABI/types pair and do not expose layouts;
* an exact candidate with neither symbol retains the markerless-binary error
  instead of falling through to source.

The ABI marker must return exactly one string equal to `TITAN_ABI_VERSION`. The types entry
must return exactly one serialized `Type.Module` for the requested logical
name, with a canonical public schema. The loader does not scan later images
after a claim; visible duplicate providers are resolved by ordinary first
match, not by ambiguity detection.

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

The coder retains `node._type.file` as the fallback provider filename; it does
not repeat candidate probing in generated C. An import of `a.b.c` selected
from `a/b.so` emits:

```c
TitanModuleProvider a_b_c_provider =
    titan_module_provider(L, "a.b.c", "a/b.so");
titan_check_module_abi(L, a_b_c_provider, "a_b_c_abi", "a/b.so");
titan_check_module_compatibility(L, a_b_c_provider, "a_b_c_compatibility", "a/b.so",
    verifier_source, verifier_length);
```

The registry entry for `"Titan module a.b.c"` takes precedence over the filename.
If it exists, its native payload supplies an export callback, including when
the module was initialized from an executable, archive, or `package.loadlib`.
Only an absent logical module reaches `loadlib`, which walks the runtime Titan
path, caches by relative provider file, maps with `RTLD_LAZY | RTLD_GLOBAL`,
and invalidates the backtrace image cache. Two logical imports in one provider
can reuse one handle while requesting different fully mangled symbols.

After ABI and selective compatibility checks, `titan_module_symbol` resolves
`a_b_c_init`, used native entries, and required variable/canonical-closure slot
symbols through the selected callback or handle. The importer caches native
bindings in its own per-state payload. Transitive nominal owners use their
logical registry callbacks after explicit dependencies initialize, with their
own ABI-first compatibility checks. They do not use global symbol selection.
See [Selective binary dependency verification](binary-compatibility.md).

This separation is important: candidate membership is a compiler concern;
the selected relative file makes fallback runtime loading exact and relocatable,
while the logical registry owns initialized module identity.

## One object per logical module

Multi-module linking does not merge ASTs, module types, or generated C.
`driver.defaultloader` checks each source module once and `coder.generate`
emits one translation unit per logical module. A folder module has already
been assembled into one AST, so it naturally contributes one object.

Library mode forms the union of every source module reachable from all
requested roots, sorts logical names with `util.bytewise_less`, and links each
source object exactly once. A dependency selected from a DSO remains dynamic
and contributes no object. A dependency selected from a static provider adds
that physical archive once; its complete validated membership is available
for direct native binding and is carried into both produced provider forms,
without making all of its logical keys ordinary resolver results. Every source
module sees the complete source union and physically carried static names as
direct during code generation, so those references become ordinary `extern`
calls rather than self-dlopen attempts.

Selected static-provider archives are ordered bytewise by normalized absolute
path. User `-X` objects and archives retain command-line order. Library-mode
DSO construction force-loads selected and `-X` archives, while archive
construction flattens their object members in the same logical/native order.
`-l`, the Titan/Lua/backtrace archives, platform libraries, and ordered extra
linker flags are final-link inputs and are not copied into the produced
archive.

The compiler preflights the coder's complete externally visible symbol set.
Distinct logical module names that map to one flattened protocol prefix (for
example through dot/dash replacement) are rejected by name. Callable names use
`_\u2133_` and `_\u2131_`, so module `a` function `b_c` and module `a.b`
function `c` produce distinct `a_\u2133_b_c_titan` and
`a_b_\u2133_c_titan` entries. The same inventory covers public methods, their
bound trampolines, record/union functions and constructors, the three exported
bound trampolines for every public Interface method, each module protocol, and
cross-family protocol collisions, so every real collision is reported before
code generation instead of as an opaque duplicate-symbol linker error.

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
the public basename so its macOS dSYM agrees. Before publication, the driver:

1. calls every physical logical module's ABI/types entries in the staged DSO
   and resolves its `_init` and `luaopen_*` entries;
2. scans the complete staged archive and requires the exact intended key set;
3. compares every embedded ABI/types value with the DSO callables;
4. force-loads only the staged archive into a private validation DSO with the
   same final native policy; and
5. validates that image's protocols in a fresh child process.

The archive builder separately reparses the output and compares every
non-index object member byte-for-byte with the intended flattened sequence, so
metadata-free native payload cannot be silently omitted or reordered.

`titanc` stages one shim per physical logical module at
`<logical/path>.lua`. Source contributors do not receive shims. Every
generated file starts with:

```lua
-- Generated by titanc; do not edit.
```

Preflight accepts a missing destination or an existing file with that exact
banner and exact provider/entry template. Any other file is user-owned and
aborts before code generation. If a valid prior self-describing archive
advertises keys absent from the replacement, only their exact recognized
generated shims are eligible for transactional retirement.

Publication backs up all current owned destinations, installs the new
shims/dSYM, publishes the archive, and renames the DSO last as the default
dynamic-path commit point. Caught errors and injected archive/DSO failpoints
restore the predecessor bundle. This is recoverable in-process publication,
not crash-, power-loss-, or asynchronous-signal-atomic publication.

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

`package.searchpath` intentionally follows Lua-path precedence rather than
the compiler's Titan path. Production installation avoids ambiguity by
publishing one canonical provider; fixtures prepend their intended provider
root explicitly.

### The lazy/global support helper

Stock Lua's `package.loadlib(path, "*")` is eager/global and shares Lua's own
pathname cache, so it cannot provide the required lazy promotion contract.
`ltitanlib.c` therefore exposes a separate internal
`titan._loadlibglobal(path, symbol)`:

* it canonicalizes an existing pathname with `realpath` and keys its own
  per-state cache by that canonical absolute name;
* its first request in a state calls `dlopen(canonical,
  RTLD_LAZY | RTLD_GLOBAL)` even if Lua or `_loadlib` already opened the image;
* it resolves the requested Lua C function with `dlsym` and returns the same
  `nil, message, stage` error shape as `_loadlib`;
* it keeps handles mapped for process lifetime and preserves the originally
  requested path in diagnostics.

The global helper, compiler-local helper, Lua C-library cache, and runtime
`TITAN_LIBS_KEY` cache are separate. A second state performs its own cache
entry and `dlopen`; the operating-system loader may reuse the process mapping.

Ordinary `require "titan"` first enters through Lua's C searcher, which maps
the support image eagerly/local and returns only the native support table. A
standard-module shim then calls `_loadlibglobal` on the same canonical
`titan.so`, promoting the already mapped combined provider before resolving
its `luaopen_titan_*` entry. Bare support loading never initializes a standard
module or installs the async program bootstrap.

## Reserved `titan` and the standard-library image

The bare logical module name `titan` is reserved in library mode because it
belongs to the Lua support API and every shim requires it. A **physical**
provider named `titan` is valid only when its final image also contains
`ltitanlib.o`'s genuine `luaopen_titan`. The driver checks that entry in a fresh
Lua process and requires exactly one support table exposing `_loadlib` and
`_loadlibglobal`; compiler-side `package.loaded` state cannot satisfy the
proof.

The production standard library is the canonical example. One compiler
invocation names all twenty-three logical roots and publishes root `titan.so` and
`titan.a`. Internal standard imports are direct. `ltitanlib.o` is shared `-X`
payload and supplies bare `luaopen_titan` without adding a logical metadata
key. The private namespaced five-member LPegLabel archive follows it as
metadata-free payload. The pinned libuv payload follows it, then the private
llhttp and SQLite archives, and finally any bundled OpenSSL payload used directly by
`titan.ssl`. The eight HTTP callback definitions already live in the generated
`titan.http` object; there is no adapter object. Bundled archives are
force-carried into the DSO and flattened into the archive; system OpenSSL settings remain final-link inputs
and are never copied into `titan.a`. The DSO exports twenty-four Lua entries
(`luaopen_titan` plus the twenty-three logical entries); both forms define the
twenty-three logical protocols, and the archive advertises exactly twenty-three
metadata keys.
The private LPegLabel archive and its headers remain source-build inputs; they
are not installed in the compiler/runtime SDK. The callback-bearing
`titan/coroutine.titan.h`, `titan/uv/uv.titan.h`,
`titan/http/http.titan.h`, and `titan/sqlite3/sqlite3.titan.h` companions are
likewise generated source-build intermediates: they are available before the
standard objects compile but never become provider members, publication-stage
artifacts, or installed headers.

`make` (or `make all`) builds a distinct private bootstrap at
`titan-runtime/bootstrap/titan.so`, linked only from `ltitanlib.o`. The
source-rock build uses that image with the in-tree compiler Lua sources and
matching Lua SDK to build the standard library before installation. It needs
no installed Titan compiler and does not seed the canonical provider with the
bootstrap. The shared Make object graph
retains generated C, headers, and objects below `out/` with `--output out`. One final link carries
`ltitanlib.o`, private LPegLabel, libuv, llhttp, SQLite, and optional bundled
OpenSSL into the paired provider. TLS uses the selected OpenSSL library directly.
LuaRocks' Make install pass stages compiler Lua modules and generated shims in
`INST_LUADIR`, plus `titanc` and `titan-uninstall` in `INST_BINDIR`. The prebuilt
native SDK, provider pair, licenses, and optional macOS dSYM are retained in
`<rock-prefix>/titan-sdk`, with the helper at
`<rock-prefix>/installer/titan_install.lua`. The `post_install` hook invokes
that copier by absolute path to publish canonical SDK/provider files. Neither
install nor the hook compiles anything. Binary rocks retain the same payload
and helper. `publish-stdlib` copies an
already built `STDLIB_INSTALL_STAGE` without rebuilding it. Explicit packaging
tests own the provider protocol, symbol, metadata, and layout checks.

The canonical installed files are the provider pair (plus the DSO's macOS
dSYM) and twenty-three Lua shims:

```text
<root>/lib/titan/0.6/titan.so
<root>/lib/titan/0.6/titan.a
<root>/lib/titan/0.6/titan.so.dSYM          # macOS only
<root>/share/lua/5.5/titan/{coroutine,uv,async,timer,io,fs,net,ssl,url,http,websocket,os,path,peg,string,math,lua,iteration,gc,test,reflect,sqlite3,json}.lua
```

Canonical SDK/providers remain outside LuaRocks' manifest; compiler scripts,
Lua modules, and generated shims use ordinary LuaRocks ownership. The
`titan-uninstall` command removes all installed Titan rock versions in its
selected tree through LuaRocks first, then removes exact external Titan files
only after success. It preserves Lua and shared dependency artifacts. Cleanup
cannot target one rock version because these canonical paths are shared.
`make binary-rock` packs the installed private payload and gives the output
its native platform suffix; stock LuaRocks 3.13 would label the same payload
`.all.rock`.

The checkout Make graph has one provider-pair completion marker. The twenty-three
flat/folder source sets, selected compiler/SDK, native headers, and imported
generated outputs are prerequisites. The DSO, archive, conditional dSYM, and
every shim must exist; warm invocations preserve their mtimes. Callers run
`make clean-stdlib` before changing tools, flags, profile, or OpenSSL mode, and
clean affected native build directories or use separate source copies and SDKs.
`make clean` removes the known generated outputs. Production
library tests treat the combined set as read-only. CI snapshots and restores
the checkout runtime archive plus the installed DSO/archive/dSYM/shims
around compiler groups; its system-OpenSSL smoke replaces the whole
paired generation rather than one logical child, while the prepared artifact retains the
bundled generation.

## ABI and test-only exact providers

The current provider contract covers shallow prefix-container discovery, the
paired dynamic and self-describing static formats, canonical Array proxies,
union and Interface metadata, callable branding, generic declarations,
source-private provider identity, source-defined callback symbols, and
const-qualified descriptors and wrappers. The dynamic and static forms carry
the same ABI and logical type manifests. Exact-path test providers remain valid
as the final candidate in each format, but a mismatched marker is terminal
before metadata decoding or native linking.

Current lookup uses `TITAN_PATH_0_6` and `lib/titan/0.6`; those paths derive
from `TITAN_VERSION` `0.6.0`, independently of `TITAN_ABI_VERSION`. Earlier Titan
installations are not migrated, cleaned up, or used as compatibility inputs.
See [Dense Arrays](dense-arrays.md#abi-boundary).

Production, installed, and native standard-library behavior tests use the
combined image; the uv redesign has no delayed-callback source variant,
alternate exact-provider graph, or serial source-rewritten coroutine image.
Implementation mechanics remain owned by compiler/native harness coverage
rather than an alternate production packaging model.
