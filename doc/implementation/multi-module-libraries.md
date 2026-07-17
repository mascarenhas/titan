# Multi-module shared libraries

Titan keeps **logical module identity** separate from the **physical shared
library** that provides its native symbols. A no-`main` `titanc` invocation
compiles every selected source module independently and links their objects
into one shared library. For example:

```sh
titanc app.model app.view
```

produces `app.so`, plus generated `app/model.lua` and `app/view.lua` shims.
The image contains both modules' ordinary `app_model_*` and `app_view_*`
protocol symbols. It does not create a logical `app` module or a combined
module state.

This chapter describes the provider lookup, link, shim, and publication
protocol. Folder-source assembly remains a property of one logical module;
see [Folder modules](folder-modules.md). The language-level packaging rules
are in [Multi-module libraries](../language/multi-module-libraries.md).

## Provider selection for a library invocation

After typechecking and exact `main` detection, library mode deduplicates the
requested CLI roots while preserving their first occurrence and takes their
longest common sequence of complete dotted components. That prefix is the
physical provider name:

| Requested roots | Provider | Output |
| --- | --- | --- |
| `foo` | `foo` | `foo.so` |
| `foo.bar` | `foo.bar` | `foo/bar.so` |
| `foo.left foo.right` | `foo` | `foo.so` |
| `foo.bar.left foo.bar.right` | `foo.bar` | `foo/bar.so` |

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
first expands the selected `TITAN_PATH_0_16`/`TITAN_PATH` with the runtime's
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
* an exact candidate with neither symbol retains the markerless-binary error
  instead of falling through to source.

The ABI marker must return exactly one string equal to `0.16`. The types entry
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

## Runtime imports remain exact

The coder reads `node._type.file`; it does not repeat candidate probing in
generated C. An import of `a.b.c` selected from `a/b.so` emits the existing
exact sequence:

```c
void *a_b_c_handle = loadlib(L, "a/b.so");
titan_check_abi(L, a_b_c_handle, "a_b_c_abi", "a/b.so");
```

It then resolves `a_b_c_init` and the used native entries from that handle.
`loadlib` still walks the runtime Titan path, caches by relative provider file,
maps with `RTLD_LAZY | RTLD_GLOBAL`, and invalidates the backtrace image cache.
Two logical imports in one provider therefore reuse one handle but request
different fully mangled symbols. Transitive record-alias method lookup still
uses `loadglobalsym` only after explicit providers have initialized.

This separation is important: candidate membership is a compiler concern;
the selected relative file makes generated runtime loading exact and
relocatable.

## One object per logical module

Multi-module linking does not merge ASTs, module types, or generated C.
`driver.defaultloader` checks each source module once and `coder.generate`
emits one translation unit per logical module. A folder module has already
been assembled into one AST, so it naturally contributes one object.

Library mode forms the union of every source module reachable from all
requested roots, sorts logical names with `util.bytewise_less`, and links each
object exactly once. Compiled dependencies remain dynamic and contribute no
object. Every source module sees the complete source union as static during
code generation, so imports between linked roots and shared source
dependencies become ordinary `extern` calls rather than self-dlopen attempts.
`-X`, `-l`, the Titan/Lua/backtrace archives, and ordered extra linker flags
are applied once to the final image.

The compiler preflights the coder's complete externally visible symbol set.
Distinct logical names that both map to one coder prefix (for example through
dot/dash replacement) are rejected by name. It also catches a boundary that a
prefix-only check would miss: module `a` function `b_c` and module `a.b`
function `c` both produce `a_b_c_titan`. The same inventory covers public
methods, their bound trampolines, record functions, and each module protocol,
so every collision is reported before code generation instead of as an opaque
duplicate-symbol linker error.

The final DSO contains independent copies of every logical protocol:

* `<mangled>_abi` and `<mangled>_types`;
* `<mangled>_init` and `luaopen_<mangled>`;
* a file-local `_initialized` wiring flag;
* a distinct registry-owned module `Udata`, variables, canonical closures,
  record metatables, initializer, and nominal owners.

There is no provider metadata table or provider initializer. Requiring one
logical child initializes only that child and its imports. A container need
not provide a logical module having the provider's own name.

## Validated publication and generated shims

The final link goes to a sibling staging directory whose contained DSO has the
same basename as the public output. This preserves macOS dSYM basename
agreement. Before publication, the driver calls every linked module's ABI and
types entries and resolves its `_init` and `luaopen_*` entries. It then
atomically renames the validated DSO to its public pathname; on macOS the
matching `.dSYM` is staged and moved as the DSO's companion.

Only after DSO publication does `titanc` write one shim per linked source
module at `<logical/path>.lua`. Source contributors do not receive shims.
Every generated file starts with:

```lua
-- Generated by titanc; do not edit.
```

Preflight accepts a missing destination or an existing file with that exact
banner. Any other file is user-owned and aborts before code generation. Shim
replacement uses a sibling temporary file and rename.

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
`titanlib.c` therefore exposes a separate internal
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
`titanlib.o`'s genuine `luaopen_titan`. The driver checks that entry in a fresh
Lua process and requires exactly one support table exposing `_loadlib` and
`_loadlibglobal`; compiler-side `package.loaded` state cannot satisfy the
proof.

The production standard library is the canonical example. One compiler
invocation names all seven logical roots and links their seven objects, the
runtime, `titanlib.o`, and the selected libuv inputs into root `titan.so`.
Internal standard imports are static. Bundled mode force-loads the one private
libuv archive into this image; system mode records the selected shared libuv
dependency on it. The image exports eight Lua entries (`luaopen_titan` plus
the seven logical entries) and seven independent ABI/types pairs.

`make titan` builds a distinct private bootstrap at
`titan-runtime/bootstrap/titan.so`, linked only from `titanlib.o`. During a
source-rock install it is staged at `<root>/lib/titan/0.16/titan.so` only when
that pathname is absent. A usable existing bootstrap or full image is
preserved, so a repeated build never replaces a full library with the smaller
bootstrap. An incompatible existing image is an error and is not overwritten.

After LuaRocks deploys `titanc`, the post-install hook builds all roots once in
a private directory on the destination filesystem. It then executes the
source-only `scripts/stdlib_installer.lua` directly with the installed Lua;
the publisher is not an installed compiler module. The script validates the
eight Lua entries, seven ABI/types pairs, seven shim banners/provider entries,
and the macOS dSYM. It backs up the existing active-0.16 DSO, dSYM, shims, and
stale active-layout copies, leaving those stale public paths vacant; commits
the shims and platform dSYM; and renames `titan.so` last as the commit point.
Injected failures restore the previous full image or the first-install
bootstrap and shim set. After that commit, backup cleanup is best effort and
cannot turn the coherent install into a reported hook failure. Separately
versioned 0.15 artifacts are not purged.

The canonical installed files are one DSO (plus its macOS dSYM) and seven Lua
shims:

```text
<root>/lib/titan/0.16/titan.so
<root>/lib/titan/0.16/titan.so.dSYM          # macOS only
<root>/share/lua/5.5/titan/{coroutine,uv,async,timer,fs,net,os}.lua
```

These remain direct Titan artifacts outside the source-rock manifest. The
manifest owns the compiler Lua/script files; `luarocks remove` does not claim
to remove Titan library-package artifacts.

The checkout Make graph has one full-image completion/configuration stamp: all
seven flat/folder source sets, native inputs, tool identity, and libuv mode are
prerequisites, and the DSO, conditional dSYM, and every shim must exist for a
warm no-op. `make clean` removes only those known generated outputs. Production
library tests treat the combined set as read-only. CI snapshots and restores
the checkout runtime archive plus the installed DSO, dSYM, and shims around
compiler groups; its system-libuv smoke replaces the whole combined image
rather than one logical child, while the ordinary artifact retains the
prepared bundled image.

## ABI 0.16 and test-only exact providers

ABI 0.16 changes neither per-module serialized type shapes nor Titan's native
calling convention. It is nevertheless a mandatory compatibility boundary:
0.15 generated imports hard-coded exact logical DSO paths, while the 0.16
standard installation contains only a shallow combined `titan.so`. The marker,
`TITAN_PATH_0_16`, and `lib/titan/0.16` namespace move together so an old
consumer cannot appear compatible and then fail to locate a removed child
DSO. Exact 0.16 DSOs remain valid because exact is the final candidate.

Production and installed tests use the combined image. The delayed-filesystem
callback variant is deliberately different: in an isolated root with no
shallow `titan.so`, it builds exact `titan/coroutine.so`, `titan/uv.so`,
`titan/async.so`, and `titan/timer.so`. Prefix search reaches those terminal
candidates. The serial coroutine suite similarly isolates its exact test
image or preserves and restores the complete production `titan.so`, dSYM, and
generated coroutine shim. These are fault-injection/test layouts, not an
alternate production packaging model.
