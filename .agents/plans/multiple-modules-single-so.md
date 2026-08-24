# Multiple modules in one shared library — specification and implementation plan

This plan expands the brief in `pasted-text-1.txt` into a source-grounded
design for the current Titan compiler. It is the binary-layout converse of
folder modules:

- a folder module combines several source files into one logical Titan module;
- this feature combines several logical Titan modules into one physical shared
  library while preserving each module's own namespace, metadata, state,
  initializer, nominal types, and Lua entry point.

The required production dogfood is the complete Titan standard library. The
seven logical modules

```text
titan.coroutine
titan.uv
titan.async
titan.timer
titan.fs
titan.net
titan.os
```

must be checked and compiled together by one `titanc` process and linked into
one `titan.so`. That image must also contain `titanlib.o`, so it exports the
bare `luaopen_titan` support module alongside `luaopen_titan_coroutine`,
`luaopen_titan_uv`, and the other logical module entries.

## 1. Outcome and scope

Given two logical source modules:

```text
a/b/left.titan       # module a.b.left
a/b/right.titan      # module a.b.right
```

one library-mode invocation:

```sh
titanc a.b.left a.b.right
```

produces:

```text
a/b/left.c
a/b/left.o
a/b/left.lua
a/b/right.c
a/b/right.o
a/b/right.lua
a/b.so
```

It does **not** produce `a/b/left.so` or `a/b/right.so`. The C objects remain
one per logical module; only the final link and physical load target are shared.

The two Lua shims both resolve `a.b` through `package.cpath`, globally load
`a/b.so`, and call their own exact Lua entry:

```text
a/b/left.lua  -> a/b.so -> luaopen_a_b_left
a/b/right.lua -> a/b.so -> luaopen_a_b_right
```

An external Titan consumer importing `a.b.right` probes the compiled candidates
`a.so`, `a/b.so`, and `a/b/right.so`. Once it finds `a_b_right_abi` and
`a_b_right_types` in `a/b.so`, its generated C records that selected physical
provider and later loads exactly `a/b.so` at run time.

The implementation includes:

- deterministic provider-prefix derivation for library-mode CLI roots;
- compile-time prefix probing of compiled-module containers;
- exact rules for what makes a container claim a logical module;
- propagation of the selected container through `Type.Module.file` into codegen;
- one final link containing several existing per-module translation units;
- one generated Lua shim per linked logical source module, never per folder
  contributor;
- an ordinary eager/local C-searcher bootstrap for `require "titan"`, followed by
  a cache-independent lazy/global loader exposed by that support module for
  generated shims;
- a distinct bootstrap-only Titan support image and post-install replacement by
  the full standard-library image;
- coordinated updates to the standard library, installation layout, test
  harness, CI, both manuals, and compiled-module ABI boundary.

The implementation does **not** add:

- a source-level declaration for library containers;
- a namespace relationship between modules merely because they share a DSO;
- a combined AST, combined checker invocation, or combined C translation unit;
- separate compilation followed by a later pack/link step;
- binary-rock or general Titan package ownership;
- aliases, symlinks, hard links, or compatibility copies of child DSOs;
- eager initialization of every module in a container;
- a patch to Lua's upstream `loadlib.c`;
- a change to per-module serialized type metadata or the native Titan call ABI.

## 2. Logical identity versus physical provider

### 2.1 Every logical module remains independent

Putting modules in the same DSO changes only where their global C symbols live.
For every logical module `M`, the existing code generator still emits:

- `M`'s own `<mangled>_abi` marker;
- `M`'s own `<mangled>_types` serialized interface;
- `M`'s own `<mangled>_init` function;
- `M`'s own `luaopen_<mangled>` entry;
- one private module-state `Udata` cached under `"Titan module M"`;
- one file-local `_initialized` flag;
- its own module variables, function closures/tags, record metatables, trace
  names, and optional module initializer.

The shared image does not create a parent module value. A container `a/b.so`
need not contain a logical Titan module named `a.b`; it may contain only
`a.b.left` and `a.b.right`. Requiring or importing one child does not
automatically initialize an unrelated sibling. Ordinary import edges still
control initialization, and the registry continues to provide once-per-state
identity for each logical module.

Nominal record identity remains the fully qualified logical record name and its
per-Lua-state metatable pointer. It does not acquire the container prefix as a
new owner. Two modules sharing a DSO remain just as distinct as two modules in
separate DSOs.

### 2.2 Provider prefix for a library invocation

In no-`main` mode, `titanc` derives one provider from the **requested CLI
roots**, not from their transitive source dependencies:

1. Deduplicate repeated CLI roots while retaining first occurrence order.
2. Split every root on dots.
3. Compute the longest common sequence of complete components.
4. Join that sequence with dots to obtain the provider name `Q`.
5. Link the output at `Q` with dots replaced by `/`, plus `.so`.

Examples:

| Requested roots | Provider | Output |
| --- | --- | --- |
| `foo` | `foo` | `foo.so` |
| `foo.bar` | `foo.bar` | `foo/bar.so` |
| `foo.left foo.right` | `foo` | `foo.so` |
| `foo.bar.left foo.bar.right` | `foo.bar` | `foo/bar.so` |
| `foo foo.bar` | `foo` | `foo.so` |
| all seven `titan.*` roots | `titan` | `titan.so` |

Use component comparison, not a textual prefix: `foo.bar` and `foo.baz` share
only `foo`, while `foo` and `foobar` have no common component.

Multiple roots with no common component are rejected before code generation:

```text
cannot link modules into one shared library: 'foo' and 'bar' have no common module prefix
```

This deliberately changes the currently documented `titanc foo bar -> foo.so
and bar.so` behavior. A single no-`main` invocation now means one discoverable
library container. Callers that want unrelated DSOs invoke `titanc` separately.
This keeps the public interface implicit, matches the brief's one-call model,
and avoids adding an otherwise unspecified output-prefix option.

The provider prefix is required to be an ancestor of every requested root by
construction. Transitive source dependencies do not participate in its name:
they retain the existing behavior of being statically embedded implementation
dependencies. They receive Lua shims pointing at the built provider, but an
unrelated dependency does not thereby become discoverable as a binary Titan
module through prefix lookup. Packaging such a dependency as an independently
importable Titan binary still requires making it a requested root in a
compatible provider invocation.

### 2.3 The bare `titan` name is reserved by the Lua support module

Every generated shim obtains its loader with `require "titan"`, so the bare Lua
name and `luaopen_titan` cannot simultaneously denote an ordinary generated
Titan module. In library mode, reject any linked logical source module named
exactly `titan`, including a transitive source dependency, before codegen. This
also prevents generation of a self-recursive top-level `titan.lua` shim.

A physical provider whose derived name is `titan` is valid only when its final
image also contains the native support entry from `titanlib.o`. Link library
outputs through a temporary pathname and, before publishing the image or any
shims, resolve and protected-call `luaopen_titan` in a fresh controlled Lua
process/state that does not reuse the compiler's `package.loaded.titan` when
`Q == "titan"`. Require the result to be a support table exposing both
`_loadlib` and `_loadlibglobal`; report a focused diagnostic if the symbol,
call, or contract is wrong. The standard-library Make rule is the canonical
case: it passes `titanlib.o` once, and packaging tests repeat the public
`require "titan"` proof.

Do not infer support-object identity from a filename, silently add a checkout
object to arbitrary builds, or allow a generated logical `titan` entry to
satisfy the check. Other provider names continue to use the separately
installed support DSO through ordinary `require "titan"`.

### 2.4 Standalone executable mode is unchanged

If exactly one requested module has Titan's exact `main(args: {string}):
integer` signature, `titanc` continues to link all source objects into one
standalone executable selected by that main module. It does not derive a DSO
provider, produce a shared library, or emit Lua shims.

Multiple qualifying `main` functions remain an error. The common-prefix rule is
checked only after typechecking and main detection, so unrelated roots remain
legal when they form one program.

## 3. Compiled-module lookup

### 3.1 Candidate sequence

For logical module `M = a.b.c.d`, define these relative binary candidates:

```text
a.so
a/b.so
a/b/c.so
a/b/c/d.so
```

The final candidate is the existing exact-module location. A one-component
module such as `a` has only `a.so`; do not probe it twice.

Before walking, expand `TITAN_BIN_PATH` with the same semantics as runtime
`pushpath`: a versioned override wins, then the unversioned override, and `;;`
inserts the ordinary `.;<installed library root>` default at that position. Do not
let Lua's current `gmatch("[^;]+")` behavior silently discard this runtime
default. Add a driver path-expansion helper and cross-contract tests rather
than allowing the Lua and C parsers to drift again.

Preserve the resulting path-entry precedence while keeping the compiler's
selected relative provider reproducible by generated Titan code. Walk binary
search roots from left to right and candidates shallowest to deepest inside
each root, while maintaining an `occupied` set of relative candidate names:

1. If an earlier root already contained a file at this relative candidate,
   skip the same relative candidate in later roots.
2. If the file is absent, leave the candidate unoccupied so a later root may
   provide it.
3. As soon as a file exists, mark that relative candidate occupied before
   probing its metadata. A clean nonclaim may advance to a deeper relative
   candidate, but still shadows the same pathname in every later root.

Thus, with roots `R1;R2`, the conceptual order is:

```text
R1/a.so
R1/a/b.so
R1/a/b/c.so
R1/a/b/c/d.so
R2/a.so
R2/a/b.so
R2/a/b/c.so
R2/a/b/c/d.so
```

Entries in the second root whose relative name was occupied in `R1` are
skipped. For example, a metadata-less `R1/a.so` shadows `R2/a.so` but does not
block a valid `R1/a/b.so` or an unshadowed `R2/a/b.so`.

This interpretation preserves the existing meaning of an earlier Titan path
entry. In particular, a locally built exact module in `.` must not be shadowed
by a shallow installed bundle in the later default installation root. It also
guarantees that generated run-time `loadlib(L, relative_provider)` reaches the
same physical file selected by the compiler when the expanded Titan path is
unchanged/equivalent; neither side encodes a non-relocatable absolute build-time
root. A deliberately different run-time Titan path performs ordinary
relocatable path selection and must preserve the provider layout.

Lua's `package.cpath` is an independent template list. Generated shims use it by
design and cannot promise to replay an arbitrary compile-time Titan path. The
production packaging contract avoids ambiguity by installing only one canonical
provider for the active ABI. Checkout/fixture tests explicitly prepend their
intended output root to `package.cpath`; they do not rely on its configured
installed-root-before-`./?.so` order. Also prove that a deliberately conflicting
`package.cpath` reports the selected Lua-path error rather than claiming hidden
cross-path fallback.

The first candidate that **claims and validates** `a.b.c.d` wins. Do not scan
later candidates to report ambiguity. Packaging two visible containers that
both claim the same logical module is unsupported; first-match path semantics
decide which one is used.

### 3.2 What counts as module metadata

The requested logical module's metadata pair is:

```text
a_b_c_d_abi
a_b_c_d_types
```

Use `titan._loadlib` only to map each existing candidate lazily and locally and
to probe these symbols. A candidate is a non-claim only when **both** symbols
are absent. This permits an ordinary `a.so` Lua C module or an unrelated Titan
container to coexist ahead of a deeper provider name. It still occupies the
relative `a.so` path and shadows later-root `a.so` files, exactly as ordinary
path search and generated Lua shims do.

Once either requested symbol is present, the candidate has claimed the logical
module and validation is terminal:

- both symbols must exist;
- `_abi` must execute successfully, return one string, and equal the current
  current ABI marker;
- `_types` must execute successfully and return valid serialized Titan type
  metadata;
- deserialization must yield the requested logical module interface.

Missing half-metadata, an invalid marker, an ABI mismatch, malformed serialized
types, or a logical-name mismatch is a hard error. Do not continue to a deeper
or later candidate after a claim. This prevents a corrupt or incompatible
earlier installation from being silently hidden by another image.

Failure to open a filesystem candidate is likewise a hard error: the selected
path entry contains a broken image, and the loader cannot prove it is an
unrelated non-claim. Missing files simply advance the search.

The terminal exact candidate retains the current safeguard. If an exact
`a/b/c/d.so` exists but contains neither requested metadata symbol, report the
existing “no compatible Titan ABI marker” class of error rather than falling
back to source. Ancestor containers with neither symbol are the new skippable
case. This preserves current protection against accidentally compiling source
over an exact stale/non-Titan binary.

Only when every candidate file is absent or every **ancestor** file is a clean
non-claim does ordinary dependency lookup fall through to flat/folder source.
Explicit `titanc` roots remain source-first and do not probe binary containers.

### 3.3 Cache identity and selected provider

Each logical module keeps its own `driver.imported[M]` cache entry even when
several entries came from one physical DSO. The entry retains:

```lua
{
    type = module_type,
    compiled = true,
    filename = absolute_selected_candidate,
}
```

The compiler-side `titan._loadlib` cache continues to share the actual native
handle by absolute filename. No new combined-module cache identity is needed.

`Type.Module` already has the transient field `file`, defaulting to the exact
logical path. After rehydrating metadata from a candidate, set:

```lua
module_type.file = relative_selected_candidate
```

For the example above this is `"a/b.so"`. Keep `file` out of
`types.serialize`: physical deployment belongs to the importing compiler's
current binary path, not to the provider's logical public interface. Each
rehydration reconstructs the logical default and then overwrites it with the
current selected container.

### 3.4 Generated run-time import

Change `coder.import_module` to use `node._type.file` instead of deriving
`node.modname:gsub('.', '/') .. '.so'` again. Generated C then remains the
existing exact loader sequence:

```c
void *a_b_c_d_handle = loadlib(L, "a/b.so");
titan_check_abi(L, a_b_c_d_handle, "a_b_c_d_abi", "a/b.so");
```

and later resolves `a_b_c_d_init` and imported native entries from that handle.
Run-time `loadlib` therefore needs no prefix-probing redesign: it keeps its
relative-file cache, Titan-path walk, `RTLD_LAZY | RTLD_GLOBAL` mapping,
libbacktrace invalidation, and exact ABI check.

When two imports name modules in the same container, `loadlib` reuses one
handle, while handle-local `loadsym` still requests distinct fully mangled
symbols. Transitive record-alias providers continue to work: initializing the
explicit container publishes it globally, and `$LOADGLOBALS` continues to use
`loadglobalsym` only after explicit imports initialize.

## 4. Building one DSO from several modules

### 4.1 Typecheck and compile stages

Keep the current “all load/type errors before codegen” pipeline and add every
check that can be decided from logical inputs to that preflight. Semantic
validation of provider `titan` necessarily follows its temporary native link:

1. Build the complete `requested_roots` set.
2. Check every requested root through `driver.defaultloader`; those roots are
   source-first and their imports remain binary-first.
3. Accumulate all load/type errors and detect `main` exactly as today.
4. In library mode, derive/validate the common provider before compiling.
5. Build the complete linked logical-module list; reject reserved logical
   `titan`, C-symbol-prefix collisions, and any unowned shim destination before
   changing `.c`, `.o`, DSO, or shim output.
6. Compile every source entry in `driver.imported` once into its existing
   per-logical-module `.c` and `.o` path.
7. Sort linked logical module names with `util.bytewise_less`, deduplicate their
   objects, and invoke `driver.compile_library(provider, objects, ...)` once,
   targeting a sibling temporary DSO.
8. Apply `-X` extra objects, `-l` libraries, runtime archives, and ordered
   `TITAN_EXTRA_LDFLAGS` once to that link.
9. Validate required exported entries, including `luaopen_titan` for provider
   `titan` and its support-table loader functions, then atomically rename the
   DSO to its public pathname and move the matching dSYM into the public
   basename on macOS.
10. Emit all planned Lua shims only after the DSO publication succeeds.

The union is all source modules reachable from all requested roots, not one
root's closure and not a concatenation that can repeat a shared dependency.
Compiled-binary dependencies remain dynamic and contribute no object.

### 4.2 Symbol collisions

Several translation units can coexist because module-wide exported symbols use
the mangled logical module prefix and fixed helper state such as `_initialized`
is file-local. Nevertheless, two distinct logical names can currently mangle to
the same C prefix (for example a dash/dot collision). Separate DSOs hid that
collision; one image cannot.

Before code generation/final linking, map every linked source module to the
same mangling used by the coder. If two distinct names collide, report both
logical names and stop before producing the container. Do not wait for an
opaque duplicate-symbol linker failure.

### 4.3 No combined semantic unit

Do not merge ASTs or module types. Every source module retains one checker and
one coder call. Folder modules are already one logical cache entry and one
object, so they naturally participate as a single unit. Their constituent
`.titan` filenames never enter the linker-or-shim module list.

The final DSO may contain many `luaopen_*`, `_abi`, `_types`, and `_init`
symbols. No aggregate metadata table or container initializer is added. The
presence of ordinary per-module metadata is the complete membership protocol.

## 5. Generated Lua shims

### 5.1 One shim per linked logical source module

For every source-module object linked into provider `Q`, generate a shim at the
logical module path with `.lua`:

```text
M = a.b.c.d  -> a/b/c/d.lua
```

This includes requested roots and statically embedded source dependencies. It
restores direct Lua access to every `luaopen_M` actually present in the image.
Folder modules still generate exactly one shim for `M`; `source.files` and
contributor basenames are never consulted.

The shim is written under the compiler working directory, beside the logical
DSO output tree, even when `--tree` points to an external source root. Parent
directories use the same safe creation path as linked output directories.

### 5.2 Required correction to the pasted pseudocode

The pasted shim uses:

```lua
package.loadlib(path, "*")
```

Stock Lua 5.5 implements that operation as `RTLD_NOW | RTLD_GLOBAL`, not
`RTLD_LAZY | RTLD_GLOBAL`. It also caches C-library handles by exact pathname;
calling `"*"` after the same file was loaded locally does not reopen/promote
it. Therefore the pasted code cannot satisfy its own stated lazy/global
contract for arbitrary Titan DSOs.

Preserve the semantic requirement rather than silently claiming the stock API
is lazy. Add an internal `titan._loadlibglobal(path, symbol)` helper in
`titanlib.c` that:

- canonicalizes the existing path with `realpath` so relative/absolute aliases
  share one key and error reporting retains the original requested pathname;
- maintains its own per-Lua-state registry cache keyed by that canonical
  absolute pathname and never calls `dlclose`, so mappings remain for process
  lifetime;
- on the first request in that state-local cache, calls
  `dlopen(path, RTLD_LAZY | RTLD_GLOBAL)` even if Lua's C-library cache or the
  compiler's local cache has already opened that pathname;
- resolves the requested symbol with `dlsym`;
- returns the Lua C function, or `nil, error, stage` using the same style as the
  existing compiler-only `_loadlib` helper.

Keep `_loadlib` itself lazy/local for compiler interface inspection. Use
separate cache tables or explicit per-handle mode state; do not let an earlier
local compiler probe satisfy a later global request without performing the
global `dlopen` call.

Generated logical-module shims use:

```lua
-- Generated by titanc; do not edit.
local path, search_error = package.searchpath("a.b", package.cpath)
if not path then error(search_error, 0) end

local titan = require "titan"
local open, open_error = titan._loadlibglobal(path, "luaopen_a_b_c_d")
if not open then error(open_error, 0) end

return open()
```

This differs deliberately from the pasted sketch only where stock Lua cannot
provide the required loading flags. It preserves `package.cpath` discovery,
the exact provider prefix, exact logical Lua entry, and level-zero errors.

### 5.3 Bare support load and provider promotion

Do not install a top-level `titan.lua`. The first ordinary `require "titan"`
uses Lua's C searcher, which maps the canonical `titan.so` eagerly and locally
and then calls `luaopen_titan`. That support entry exposes `_loadlibglobal`; it
does not try to change its own loading mode while the C entry is running.

Every generated logical-module shim then calls `require "titan"` and invokes
`_loadlibglobal` for its resolved provider pathname. The helper deliberately
does not consult Lua's private C-library handle cache. Its first
`dlopen(path, RTLD_LAZY | RTLD_GLOBAL)` therefore has two useful cases:

- for an unrelated provider such as `a/b.so`, it performs that provider's first
  mapping with the required lazy/global flags;
- for the combined standard-library provider, the same canonical `titan.so`
  has just been mapped eager/local by `require "titan"`, and the second
  `dlopen` promotes the existing image into the global namespace before the
  shim resolves `luaopen_titan_*`.

The second call cannot undo relocations already performed by Lua's eager first
load. Both the bootstrap-only and final standard-library `titan.so` must
therefore be link-complete under eager loading. The helper still supplies the
required global visibility, and it is genuinely lazy for providers that were
not already mapped. Prove the promotion behavior on every supported platform
rather than relying only on Linux loader folklore.

Keep the helper's registry key separate from both Lua's internal C-library cache
and the compiler-only `_loadlib` cache. A second Lua state performs its own
first `dlopen`; the operating-system loader reuses/promotes the process mapping,
and the state then caches that returned handle. Do not add a self-dlopen trick
inside `luaopen_titan`, a top-level Lua bootstrap module, or a patch to upstream
Lua.

Bare `require "titan"` returns only the existing support table. It must not call
any `titan.*_init`, create standard module state, or install the async main
bootstrap merely because their entry points share its image.

### 5.4 Generated-file ownership

Generated shims begin with the exact banner shown above. Before code generation,
validate all destinations:

- a missing destination is available;
- an existing file with the exact generated banner may be replaced;
- any other existing `.lua` file is user-authored and makes the invocation fail
  before C/object/DSO output is changed.

Write replacements through a sibling temporary file and atomic rename. This
prevents a failed link or interrupted write from destroying an existing valid
shim. The checked-in special-case `titan/uv.lua` is removed during migration;
the new compiler owns that path with the other generated standard shims.

Repository `.gitignore`, test cleanup, and `make clean` list the known standard
shim outputs explicitly. Do not use a broad rule that could delete arbitrary
user-authored Lua sources.

## 6. Standard-library bundle and installation

### 6.1 One reviewed build graph

Replace the seven production DSO recipes with:

```make
STDLIB_ROOTS = titan.coroutine titan.uv titan.async titan.timer \
               titan.fs titan.net titan.os

STDLIB_TITAN_SOURCES = titan/coroutine.titan $(UV_TITAN_SOURCES) \
                       titan/async.titan titan/timer.titan \
                       titan/fs.titan titan/net.titan titan/os.titan

STDLIB_SHIMS = titan/coroutine.lua titan/uv.lua titan/async.lua \
               titan/timer.lua titan/fs.lua titan/net.lua titan/os.lua

STDLIB_CONTAINER = titan.so
```

The exact Make spelling may use a completion/config stamp, but its invariants
are:

- every reviewed source is a normal prerequisite;
- the deployed or checkout compiler is invoked once with all seven roots;
- `titanlib.o` is passed once as an extra final-link object;
- the selected libuv CPP/C flags apply to the one compiler invocation;
- the bundled archive or system libuv link flags apply once to the one final
  image;
- changing any standard source, folder contributor, compiler source,
  `titanlib.c`, runtime archive member, libuv mode/configuration, or native
  tool identity invalidates the complete image;
- a warm valid build does not oscillate between bootstrap and full forms;
- missing `titan.so` or any expected shim invalidates the completion stamp;
- the final output contains all eight Lua entries (`luaopen_titan` plus seven
  `luaopen_titan_*`) and all seven ABI/type metadata pairs.

Internal imports among the seven roots are source/static because the complete
`requested_roots` set is installed before checking. They become direct `extern`
calls and do not try to dynamically open their own container.

The combined image is the one and only libuv provider. Bundled mode force-loads
the pinned private archive into `titan.so`; system mode records the selected
shared libuv dependency on `titan.so`. There are no facade DSOs left whose
dependency sets need separate inspection.

### 6.2 Distinct bootstrap artifact

Do not use one timestamped `titan.so` target for both the bootstrap-only and
full images. A full image left by an earlier build could otherwise be mistaken
for a current bootstrap, while a freshly staged bootstrap could make the full
target look current.

Add a distinct private bootstrap artifact, for example:

```text
titan-runtime/bootstrap/titan.so
```

It is linked only from `titanlib.o`. `make titan` builds this bootstrap plus the
native runtime/SDK. When `ROCKS_TREE` is provided and the canonical active path is
absent, it atomically stages the bootstrap there before LuaRocks deploys the
compiler. A repeated install validates and preserves an existing usable support
or full image until its complete replacement is ready; a present but
incompatible file is an error and is left untouched. The build never shrinks a
full image back to bootstrap form. This target does not compile standard Titan
sources.

Checkout `make stdlib` runs the compiler with a controlled `LUA_CPATH` that can
find the private bootstrap (or an already staged canonical bootstrap), while
the full output is written separately as root `titan.so`. Ambient project Lua
paths remain cleared.

### 6.3 Source-rock two-stage flow

The source installation becomes:

1. `build_target = "titan"` builds the checkout runtime archive and stages it
   as `lib/titan/<library-version>/libtitan.a`, keeps `libbacktrace.a` under `lib/`, and builds
   the private bootstrap image and SDK.
2. `install-titan-sdk` ensures
   `$ROCKS_TREE/lib/titan/<library-version>/titan.so` can provide `luaopen_titan`: install the
   private bootstrap atomically only if the path is absent; retain an existing
   valid active-layout support/full image; fail without clobbering an incompatible file.
3. The rockspec installs the compiler Lua/script files but no manifest-owned
   `titan` Lua or C module. The configured Lua C path finds the directly staged
   canonical image before ordinary `lib/lua` templates.
4. The source-only `post_install` hook invokes the just-deployed `titanc` once
   for all seven roots, passing `titanlib.o`, and writes its public candidates
   into a private staging tree on the destination filesystems.
5. Before touching public paths, validate the staged DSO's eight `luaopen_*`
   entries and seven metadata pairs, every generated shim's provider/entry and
   banner, and the presence of the one staged dSYM on macOS.
6. Save the prior public DSO, dSYM, seven exact shim paths, and stale active-layout
   child/parent/`lib/lua` copies as rollback entries. Atomically rename the
   shims one by one without replacing their parent directory or touching
   unrelated Lua files, refresh/remove the platform-appropriate dSYM, remove
   the backed-up stale active-layout copies, and rename the validated DSO last.
   A shell trap restores every prior entry if any commit command fails; first
   install rolls back to its bootstrap-without-new-shims state.
7. Treat the final DSO rename as the commit point, disarm the rollback, and
   remove backups best-effort without turning a coherent committed install into
   a reported hook failure. Do not create aliases and do not automatically
   add migration or compatibility aliases.

This sequencing makes repeated `luarocks make --force` deterministic without
destroying the last working full image at the start of the build. The
multi-path commit is recoverable under ordinary hook failures rather than
literally atomic across the library-versioned DSO directory and Lua share directory; tests
inject failures at each commit point and assert rollback. No claim is made
about surviving process kill or power loss between cross-directory renames.

The canonical installed artifacts are exactly:

```text
$ROCKS_TREE/lib/titan/<library-version>/titan.so
$ROCKS_TREE/lib/titan/<library-version>/titan.so.dSYM   # macOS only
$ROCKS_TREE/share/lua/5.5/titan/coroutine.lua
$ROCKS_TREE/share/lua/5.5/titan/uv.lua
$ROCKS_TREE/share/lua/5.5/titan/async.lua
$ROCKS_TREE/share/lua/5.5/titan/timer.lua
$ROCKS_TREE/share/lua/5.5/titan/fs.lua
$ROCKS_TREE/share/lua/5.5/titan/net.lua
$ROCKS_TREE/share/lua/5.5/titan/os.lua
```

The dSYM is a canonical direct artifact only on macOS. It is staged, backed up,
committed, restored, and snapshotted with the DSO; non-macOS installation
removes a stale active-layout dSYM left by a prior cross-platform tree copy.

The canonical DSO, conditional dSYM, and SDK remain direct files outside
LuaRocks' manifest, as the current standard DSOs are. The manifest owns only
the compiler Lua/script files on this surface; the generated logical-module
shims are direct standard-library files too. `luarocks remove` still does not
pretend to own Titan binary package artifacts before Titan has a packaging
system.

### 6.4 Development and isolated variants

Production `make stdlib` and source-rock install always use the combined image.
The delayed-FS fault-injection variant may continue compiling isolated exact
`titan/coroutine.so`, `titan/uv.so`, `titan/async.so`, and `titan/timer.so` in
its private root: that root contains no shallow `titan.so`, so the new finder
reaches the exact terminal candidates. This is a test-only separately compiled
variant, not a supported way to construct the production combined image.

Update the async helper's production discovery to return the library root containing
`titan.so` plus the installed shim root, rather than a directory containing
four child DSOs. Variant helpers explicitly describe their exact-DSO layout so
the two cases cannot be confused.

The serial coroutine suite must likewise isolate its temporary exact image or
save/restore the complete production container and generated coroutine shim.
A shallow production `titan.so` in the same Titan path would intentionally win
before `titan/coroutine.so`.

## 7. Compatibility and ABI boundary

Per-module metadata shapes and native signatures do not change. Nevertheless,
this is a compiled-module compatibility boundary:

- pre-boundary generated dynamic imports hard-code the exact logical DSO path,
  such as `titan/uv.so`;
- their statically linked runtime cannot discover a new shallow container;
- the new installation intentionally removes those exact child DSOs;
- therefore an old consumer would fail at run time despite seeing the same
  nominal ABI marker if the version were not advanced.

Advance the compiled-module ABI for this physical provider-contract change.
The current repository keeps the ABI marker distinct from release/search
versioning:

```text
TITAN_ABI_VERSION      <active-ABI>
TITAN_VERSION          <semantic-version>
TITAN_LIBRARY_VERSION  <major>.<minor>
TITAN_PATH_<major>_<minor>
lib/titan/<library-version>
```

Document that the boundary changes the generated/imported physical
DSO-resolution contract and canonical standard-library layout, even though the
serialized type schema and native call convention remain unchanged.

Loaders can still consume a same-ABI module packaged at its exact path,
because exact is the final candidate. Version separation, rather than
compatibility child copies, protects old consumers and installations.

## 8. Current implementation seams

| Surface | Current behavior | Required change |
| --- | --- | --- |
| `titanc` | Compiles all source entries, then links one DSO per requested no-main root | Derive common provider, validate collisions, union/sort objects, link once, emit shims |
| `driver.findmodule` / `defaultloader` | Looks only for exact `P.so` | Probe prefix candidates per path root, track occupied relative names, and distinguish nonclaim/claim/error |
| `load_compiled_interface` | Treats missing exact ABI as terminal and returns only module type | Probe ABI/types membership pair and return selected relative provider |
| `Type.Module.file` | Defaults to exact path and is transient | Override on binary rehydration; keep unserialized |
| `coder.import_module` | Re-derives exact path from logical name | Use `node._type.file` |
| `driver.compile_library` | Can already link arbitrary object and extra-object lists | Reuse unchanged apart from deterministic caller/output reporting if useful |
| generated module protocol | One metadata/init/Lua entry set per object | Reuse unchanged; no container metadata |
| `titan.c::loadlib` | Exact Titan-path lookup, lazy/global, relative-name handle cache | Reuse unchanged with selected provider filename |
| `titanlib.c::_loadlib` | Compiler-only lazy/local inspection helper | Retain; add distinct lazy/global shim helper with canonical paths and its own per-state cache |
| `titan/uv.lua` | One hand-written special-case global loader | Remove; generate every logical module shim |
| rockspec | Installs bootstrap `titan.so` as an ordinary manifest-owned Lua C module | Conditionally stage direct bootstrap, preserve prior full image, transactionally publish DSO/dSYM/shims, and install no base Lua module or `lib/lua` C copy |
| Make stdlib | Seven compiler calls and seven DSOs | One reviewed source set, one call, one link, one dSYM, seven shims |
| test helpers/CI | Discover, snapshot, replace, and inspect child DSOs | Operate on combined image/shims; keep isolated exact variants explicit |

## 9. Detailed implementation phases

### Phase A — Lock lookup and grouping contracts with focused tests

Files: `spec/driver_spec.lua`, `spec/abi_spec.lua`, and a new
`spec/coder/multi_module_libraries_spec.lua` skeleton.

- Characterize exact binary precedence, source fallback, cached interfaces,
  explicit source roots, and current markerless-exact failure.
- Add table-driven candidate derivation tests for one through four components.
- Pin search-root-major/candidate-within-root ordering and same-relative
  occupancy/shadowing across roots.
- Pin common-component-prefix derivation, CLI deduplication, no-common-prefix
  error, reserved logical `titan`, provider-`titan` support requirement, and
  unchanged main mode.
- Pin generated-shim destination ownership before implementation.

Exit: every ambiguous rule in sections 2, 3, and 5 has an executable expected
result before the loader/linker is changed.

### Phase B — Implement compiled-container discovery

Files: `titan-compiler/driver.lua`, `titan-compiler/types.lua` only if a small
helper is useful, `spec/driver_spec.lua`, `spec/checker/so_rehydration_spec.lua`.

- Factor a component-prefix/candidate helper that never duplicates a
  one-component terminal.
- Expand versioned/unversioned Titan path overrides and `;;` defaults exactly as
  runtime `pushpath` does before filesystem probing.
- Replace exact `findmodule` use for binary imports with the nested path-root /
  prefix-candidate walk.
- Track occupied relative candidates so a later-root file can be selected only
  when generated exact run-time lookup under an equivalent expanded Titan path
  will reach that same file; keep Lua `package.cpath` as the separately tested
  packaging surface.
- Refactor interface probing to distinguish absent file, open failure,
  nonclaim, claimed-invalid, and claimed-valid.
- Require the ABI/types pair and preserve exact-terminal compatibility errors.
- Set `modtype.file` to the selected relative candidate and cache the absolute
  filename separately.
- Prove two logical modules can rehydrate from one physical DSO and share the
  compiler-side handle without sharing cache/module identity.

Exit: checker imports recover correct interfaces and physical providers from
every prefix depth, while source and explicit-root behavior remains intact.

### Phase C — Carry provider selection through code generation

Files: `titan-compiler/coder.lua`, `spec/coder/so_import_spec.lua`,
`doc/implementation/codegen-overview.md` later in Phase I.

- Replace the dynamic import's derived file with `node._type.file`.
- Keep logical ABI/init/function symbol names unchanged.
- Add generated-C assertions for one and two imports sharing a provider.
- Extend the transitive record-alias case so handle-local direct symbols and
  later `loadglobalsym` recovery still work from a combined image.
- Verify runtime handle reuse, initialization order, record identity, and
  libbacktrace invalidation behavior.

Exit: an external consumer dynamically imports multiple modules from one DSO
and behaves exactly like the former exact-DSO arrangement.

### Phase D — Implement one-link CLI orchestration and shims

Files: `titanc`, `titan-compiler/driver.lua`, new topical coder spec,
`spec/support/helpers.lua`, `.gitignore`.

- Deduplicate roots, compute the longest common dotted prefix, and issue the
  no-common-prefix error before codegen.
- Build the linked logical-module list; reject logical module `titan`.
- Detect mangled module-prefix collisions with a source-level diagnostic.
- Add a rendered shim template, generated banner, collision validation, atomic
  writes, and exact cleanup helpers; validate every destination before codegen.
- Build the sorted, deduplicated union of source objects and link once to a
  sibling temporary DSO.
- For derived provider `titan`, semantically validate its native support table;
  then publish by atomic rename before generating shims.
- Generate shims for every linked source module only after link success.
- Ensure external `--tree` writes shims under the output working directory.
- Prove a folder module receives one shim and no contributor shim.
- Prove main mode emits no `.so` or `.lua` shim.

Exit: public `titanc` produces one discoverable provider and complete shim set
for ordinary flat/folder/source-dependency graphs.

### Phase E — Provide genuinely lazy/global Lua loading

Files: `titan-runtime/titanlib.c`, remove tracked `titan/uv.lua`,
`spec/coder/multi_module_libraries_spec.lua`, and direct-libuv coverage in
`spec/rockspec_spec.lua`.

- Refactor the native helper's common error/symbol plumbing without changing
  `_loadlib`'s lazy/local compiler contract.
- Add `_loadlibglobal` with path canonicalization, its own per-state registry
  cache, process-lifetime mappings, and `RTLD_LAZY | RTLD_GLOBAL` calls.
- Switch generated logical shims to the helper-based template.
- Keep bare `require "titan"` on Lua's ordinary eager/local C-searcher path;
  add no top-level Lua bootstrap module.
- Test `require "titan"` before and after logical modules on Linux and macOS,
  including the second-dlopen promotion of the canonical `titan.so`.
- Test relative/absolute pathname aliases and two independent Lua states so the
  cache and process-mapping claims stay exact.
- Use a DSO with a genuinely unresolved provider function to prove that a Lua
  shim maps lazily/global; a self-contained smoke alone is insufficient.

Exit: both Titan imports and Lua shims meet the stated lazy/global contract,
and the eager/local support bootstrap is promoted by the first logical shim
without initializing any unrelated logical module.

### Phase F — Advance the ABI and configure library search independently

Files: `Makefile`, `titan-compiler/driver.lua`, `titan-runtime/titan.h`,
`spec/abi_spec.lua`, Lua configuration-stamp coverage, and live workflow/support
paths.

- Advance the compiler/runtime ABI marker and generated metadata before
  installing a combined image; keep the release and library-layout constants
  independent.
- Make the Lua configuration stamp regenerate `luaconf.h` with
  `lib/titan/<library-version>/?.so` and force the matching Lua reinstall when the active
  library-layout version changes.
- Require `make lua` and `make luarocks` before the first rock install into a
  fresh prefix.
- Add an isolated clean-prefix test that proves bare `require "titan"` finds
  the staged active bootstrap without ambient path overrides.

Exit: the active compiler, runtime, configured Lua search path, Make variables,
and ABI specs all agree before the new build/install graph consumes
them.

### Phase G — Collapse the standard-library build

Files: `Makefile`, `spec/libuv_build_spec.lua`, standard generated outputs and
cleanup rules.

- Define the reviewed root/source/shim sets and one combined output.
- Add the separate private bootstrap image from `titanlib.o`.
- Invoke all seven roots together and pass `titanlib.o` once.
- Apply libuv flags/archive once and validate all expected exported entries.
- Replace per-module timestamp logic with a full-image completion/config stamp
  that verifies every output exists.
- Update bundled/system dependency inspections and exact uv interface fixture
  lookup to read `titan.so`.
- Preserve the exact `titan_uv_types` serialized interface unless another
  intentional language change occurs; the ABI bump is for deployment loading.

Exit: checkout bundled and system builds each produce one complete `titan.so`,
one dSYM where applicable, seven shims, and no child DSO.

### Phase H — Rework source installation and test infrastructure

Files: the active rockspec, `spec/rockspec_spec.lua`,
`spec/support/async_stdlib.lua`, `spec/support/async_stdlib_compile.lua`,
`spec/stdlib/coroutine_spec.lua`, delayed-FS support, snapshot/mode-smoke
scripts, and `.github/workflows/ci.yml`.

- Stage the private bootstrap at the canonical library path only when that path is
  absent; preserve a usable prior support/full image and fail untouched on an
  incompatible occupant rather than beginning a forced reinstall by clobbering
  it.
- Remove the manifest-owned C-module copy without adding a base Lua module.
- Stage and validate the complete new DSO, optional dSYM, and seven-shim set
  before changing any public artifact; commit with backups, DSO last, and a
  trap that restores the prior full set (or first-install bootstrap state) on
  any ordinary hook failure.
- Add first-install, failed-install, and repeated-force-install coverage proving
  the public set is never left bootstrap-plus-mixed-shims or new-DSO-plus-partial
  shims after the hook reports failure.
- Teach production helpers to discover one library-root container and shim tree.
- Keep private exact-DSO variants isolated and explicit.
- Snapshot/restore `titan.so`, its dSYM, completion/config stamps, and shims.
- Rebuild the whole combined image for system-mode smoke and inspect only its
  libuv dependency.
- Update sanitizer symbol checks and artifact paths.

Exit: ordinary `luarocks make --force`, `luarocks test`, CI groups, and isolated
variants all consume the intended container without checkout-local fallbacks,
and failed hook commands restore the previously documented artifact set.

### Phase I — Complete both manuals and repository guidance

Files: new `doc/language/multi-module-libraries.md` and
`doc/implementation/multi-module-libraries.md`; both indexes; cross-references
listed in section 11; ABI rationale; `README.md`; `AGENTS.md`.

- Record the loader/deployment compatibility boundary in feature-based terms.
- Document logical identity, provider derivation, lookup ordering, metadata
  claim rules, shim loading, generated artifacts, and bootstrap/final ownership.
- Remove active claims that each standard module has a canonical child DSO or
  only `titan.uv` needs a Lua loader.
- Preserve the prior folder-module rationale without a version timeline.

Exit: neither manual nor repository guidance teaches the old exact-only,
seven-DSO, special-uv-shim model.

### Phase J — Full verification and delivery

- Reinstall the edited compiler before Busted to avoid the stale rock snapshot.
- Run focused loader, ABI, coder, build, packaging, coroutine, and stdlib tests.
- Run compiler/language groups with coverage and library groups without it.
- Run the full trusted `make test` gate.
- Exercise both bundled and system libuv modes.
- Verify clean removes generated combined outputs/shims but no source.
- Inspect exported symbols and absence of compatibility child DSOs/copies.
- If published, wait for push-triggered Linux CI and manually dispatch/wait for
  the complete macOS workflow before merge.

## 10. Test plan

### 10.1 Prefix finder and metadata matrix

Add table-driven filesystem/mocked-loader cases for:

| Case | Expected result |
| --- | --- |
| One-component module | exact candidate probed once |
| Four-component module | all four relative candidates in order |
| Earlier root exact vs later root shallow bundle | earlier-root exact wins |
| Earlier root shallow valid bundle vs its deeper exact | shallow claim wins |
| Earlier root has same-relative nonclaim, later root has valid claim | later occurrence is shadowed; continue to an unshadowed deeper candidate/source |
| Earlier roots lack selected relative path, later root has valid claim | later claim wins and generated run time opens that same file |
| Versioned/unversioned override with `R1;;R2` | compiler inserts the same default roots/runtime order |
| Shallow file absent | continue deeper |
| Shallow file opens with neither requested symbol | nonclaim; continue |
| Shallow has only `_abi` | claimed malformed; stop |
| Shallow has only `_types` | claimed incompatible; stop |
| Shallow ABI mismatch and deeper valid exact | mismatch stops fallback |
| Shallow types malformed and deeper valid exact | metadata error stops fallback |
| Existing candidate cannot open | hard error; no later fallback |
| Existing exact has neither symbol | current compatible-marker error |
| Ancestors are nonclaims, no exact binary, source exists | source fallback |
| Prefix binary and folder source both exist | binary wins for dependency |
| Explicit requested root and prefix binary exist | source root wins |
| Two logical interfaces in one file | distinct cache entries, same filename/handle |
| Duplicate claim at a different, still-visible candidate | first valid claim in the defined walk wins |
| Malformed dotted module name | existing non-crashing error behavior |

Assert both the absolute cached `filename` and transient relative
`module_type.file` in successful cases. For the later-root success case, compile
and run an external consumer with both path roots to prove generated exact
loading reproduces compiler selection under the same expanded Titan path. With
an aligned `package.cpath`, also prove the generated Lua shim reaches the same
provider; with a deliberately conflicting Lua path, prove normal Lua-path
precedence is reported rather than hidden Titan-path fallback.

### 10.2 Grouping and link behavior

The topical multi-module library spec covers:

- one root retains exact output;
- two siblings derive their parent provider;
- a root and descendant derive the root provider;
- comparison is by dot component, not character prefix;
- duplicate CLI roots compile/link once;
- unrelated no-main roots fail before `.c`/`.o`/`.so`/shim output;
- unrelated roots with one main still form one executable;
- all source closures are unioned and a shared dependency object appears once;
- a source dependency receives a shim pointing at the provider;
- a binary dependency remains dynamic and receives no generated shim;
- `-X`, `-l`, and ordered native flags occur once on one link;
- link order is stable by numeric-byte logical name;
- mangling collisions report both logical modules before link;
- any linked logical module named exactly `titan` is rejected in library mode;
- provider `titan` without a valid native support table from `luaopen_titan`
  fails before public DSO/shim publication, while the reviewed `titanlib.o`
  case succeeds;
- a fake `-X` object exporting `luaopen_titan` but returning a stub/wrong table
  fails the same pre-publication semantic check;
- no exact child DSO exists after success.

Inspect the combined DSO for each module's `_abi`, `_types`, `_init`, and
`luaopen_*` symbols. Do not accept only an `nm` check: compile an external
consumer against the resulting binary-only tree and run it.

### 10.3 Logical behavior inside one image

Prove:

- importing either module alone returns its own module `Udata`;
- requiring/importing both in either order reuses one physical image but keeps
  distinct logical states;
- an initializer runs once per logical module per Lua state;
- a peer source import becomes static/direct and does not self-dlopen;
- module variables remain independent;
- records, methods, record functions, exact/generic function values, exported
  aliases, and transitive record-alias methods behave identically;
- `loadglobalsym` still resolves transitive providers after the shared handle is
  published;
- native traceback names and libbacktrace refresh work for frames in several
  translation units in one DSO;
- bare `require "titan"` initializes none of the standard logical modules.

### 10.4 Lua shims

Cover:

- exact provider and `luaopen_*` strings in every generated file;
- level-zero search/load/symbol errors;
- shims generated only after a successful link;
- atomic replacement of banner-owned shims;
- refusal to overwrite an unrecognized Lua file before C output changes;
- external `--tree` output placement;
- one folder-module shim and no main/contributor-file shims;
- no shim in executable mode;
- `require` of two modules in either order;
- `require "titan"` before a logical module and vice versa;
- relative and absolute aliases canonicalize to one state-local helper entry;
- a second Lua state performs its own globalizing `dlopen` and can require the
  same logical module;
- an unresolved native provider that succeeds only with lazy/global loading;
- no dependence on patched Lua sources or checkout-local package paths.

Run the handle/global-visibility cases on both Linux and macOS. Lua's cached
library behavior and Mach-O symbol namespace are why the helper must own a
separate cache and the eager/local-to-global promotion needs direct coverage.

### 10.5 Standard library, Make, and packaging

Prove:

- `STDLIB_ROOTS`, reviewed flat sources, and `UV_TITAN_SOURCES` exactly match
  the production ensemble;
- a dry run contains one `titanc` invocation with all seven roots;
- one link receives `titanlib.o` and provider libuv flags once;
- touching any flat source or uv contributor rebuilds the same `titan.so`;
- changing bundled/system mode rebuilds that image;
- bundled `titan.so` has no dynamic libuv dependency;
- system `titan.so` has the expected selected dependency;
- `titan.so` exports `luaopen_titan` plus all seven module entries;
- its seven `_types` interfaces match their pre-bundle logical contracts;
- no `titan/{coroutine,uv,async,timer,fs,net,os}.so` exists or is installed;
- all seven generated shims are installed and no top-level `titan.lua` is
  required;
- no active-layout parent-level, `lib/lua`, symbolic-link, or hard-link copy
  exists;
- the initial canonical image exposes `luaopen_titan` but no stdlib metadata;
- post-install replaces it with the full image only after success;
- an existing valid full image is not downgraded to bootstrap at the start of a
  forced reinstall;
- two consecutive forced rock installs both finish with the full image;
- failure injection at every individual-shim/dSYM/DSO commit point restores the
  known first-install bootstrap state or the complete prior full set, never a
  partially mixed set after the hook returns failure;
- macOS installs/snapshots the one canonical `titan.so.dSYM`, while Linux has no
  stale active-layout dSYM;
- an isolated fresh prefix configures through `make lua`, `make luarocks`, and
  the rock install without path overrides;
- `require "titan"`, every `require "titan.*"`, and Titan short imports work
  outside the checkout with only configured default paths;
- `luarocks test` works with `PREFIX`/`ROCKS_TREE` unset when prefix `bin` is on
  `PATH`;
- delayed-FS exact variants still work in roots without shallow containers;
- cleanup removes final/generated outputs while preserving unrelated Lua files
  and all `.titan` sources.

### 10.6 ABI and compatibility

Update `spec/abi_spec.lua` to prove:

- driver, runtime header, Makefile, workflow, and docs agree on the active ABI;
- the active versioned override is `TITAN_PATH_<major>_<minor>`;
- a synthetic mismatched marker is rejected before its types metadata executes;
- old exact-only generated C is not claimed compatible;
- an exact same-ABI DSO remains the terminal supported layout;
- a shallow same-ABI container with the requested metadata is accepted;
- a shallow wrong-ABI claim stops before a deeper valid DSO.

## 11. Documentation plan

### Language manual

Create `doc/language/multi-module-libraries.md` and link it from
`doc/language/index.md` next to Modules/Folder modules. Cover:

- logical module versus physical provider;
- longest common dotted-prefix CLI rule and no-common-prefix error;
- examples of one exact module and several bundled modules;
- independent state/initialization/nominal identity;
- compiled prefix lookup, path precedence, same-relative shadowing, and first
  valid metadata claimant;
- binary-first dependencies and explicit source roots;
- generated `.lua` artifacts, folder-module one-shim rule, and reserved output
  paths;
- the reserved bare logical name `titan` and native-support requirement for a
  physical `titan.so` provider;
- Lua `require` behavior, including the eager/local support load followed by
  shim-driven lazy/global provider loading or promotion;
- standalone executables remaining unchanged;
- the complete standard library as the production example.

Update:

- `doc/language/modules.md` for CLI output, compiled lookup, static/dynamic
  linking, Lua searchers, installed layout, and source dependency shims;
- `doc/language/lua-interop.md` for generated loaders and several `luaopen_*`
  entries in one DSO;
- `doc/language/functions.md` to replace the `titanc foo bar` two-DSO example;
- `doc/language/folder-modules.md` to distinguish one logical shim from source
  contributors;
- `doc/language/ffi.md` for the lazy/global direct-extension contract and new
  combined libuv provider;
- active standard-library chapters that name child DSOs or only `uv.lua`.

### Implementation manual

Create `doc/implementation/multi-module-libraries.md` and link it from
`doc/implementation/index.md`. Cover:

- candidate generation, path-root-major probing, occupied relative paths, and
  why exact run time can reproduce compiler selection;
- ABI/types membership pair and terminal claim/error states;
- compiler-side local handles and per-logical cache entries;
- transient `Type.Module.file` and why it is deliberately unserialized;
- unchanged exact runtime loader/codegen sequence;
- one-object-per-module link union and symbol-collision validation;
- independent generated module protocols within one image;
- shim rendering/ownership, canonical path/per-state cache semantics, and the
  `titanlib` lazy/global helper;
- ordinary C-searcher bootstrap, separate handle caches, and provider promotion;
- reserved bare `titan`, private bootstrap versus full image, recoverable
  cross-directory publication, and macOS dSYM ownership;
- ABI rationale despite unchanged type/native shapes;
- Lua configured-path regeneration plus build/test/CI coverage.

Update:

- `doc/implementation/driver.md` for loader states, grouping/linking, shim
  generation, build orchestration, and install ownership;
- `doc/implementation/codegen-overview.md` for `Type.Module.file` and several
  translation units/metadata sets in one DSO;
- `doc/implementation/lua-interop-internals.md` for all four loading paths:
  Lua C-searcher eager/local support bootstrap, compiler lazy/local inspection,
  Titan runtime lazy/global imports, and Lua-shim lazy/global loading/promotion;
- `doc/implementation/folder-modules.md` for one logical object/shim;
- `doc/implementation/libuv-runtime.md` and `coroutines.md` for the combined
  provider and test variants;
- `README.md` for commands and installed artifacts;
- `AGENTS.md` for the current ABI, standard source/build ownership, generated shims,
  one-container CI/snapshot rules, and exact test-only variants.

Run final searches for stale ABI/path constants, `titan/uv.so`, every other
standard child DSO, and `titan/uv.lua`. All live instructions and behavior
claims must use the new model.

## 12. Validation commands

Use the active standalone Lua 5.5 prefix and clear ambient project paths:

```sh
export PREFIX="$HOME/.local/titan/titan-dev"
export PATH="$PREFIX/bin:$PATH"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
export CCACHE_DISABLE=1

make lua
make luarocks
"$PREFIX/bin/luarocks" make --force

busted spec/abi_spec.lua
busted spec/driver_spec.lua
busted spec/checker/so_rehydration_spec.lua
busted spec/coder/so_import_spec.lua
busted spec/coder/multi_module_libraries_spec.lua
busted spec/coder/folder_modules_spec.lua
busted spec/libuv_build_spec.lua
busted spec/rockspec_spec.lua
busted spec/stdlib/coroutine_spec.lua

make stdlib
bash spec/support/ci_test_groups.sh compiler
bash spec/support/ci_test_groups.sh libraries
make test
```

Run the production mode gates with their existing process fixture setup:

```sh
bash spec/support/ci_libuv_mode_smoke.sh bundled
bash spec/support/ci_libuv_mode_smoke.sh both
```

Inspect the artifacts after the bundled build:

```sh
test -f titan.so
test -f titan/coroutine.lua
test -f titan/uv.lua
test -f titan/async.lua
test -f titan/timer.lua
test -f titan/fs.lua
test -f titan/net.lua
test -f titan/os.lua

test ! -e titan/coroutine.so
test ! -e titan/uv.so
test ! -e titan/async.so
test ! -e titan/timer.so
test ! -e titan/fs.so
test ! -e titan/net.so
test ! -e titan/os.so

nm titan.so | grep luaopen_titan
nm titan.so | grep luaopen_titan_coroutine
nm titan.so | grep luaopen_titan_uv
nm titan.so | grep luaopen_titan_async
```

On Linux use `readelf -d titan.so`; on macOS use `otool -L titan.so` and verify
the companion `titan.so.dSYM`. Then run `make clean` and prove the generated DSO,
dSYM, standard shims, C, and objects are gone while unrelated Lua files, every
`.titan` source, and every uv folder contributor remain.

For a published branch, push-triggered CI proves Linux. Then run:

```sh
gh workflow run ci.yml --ref <branch>
```

and wait for the complete manual macOS workflow before merge.

## 13. Acceptance criteria

1. For `a.b.c.d`, compiled dependency lookup considers `a.so`, `a/b.so`,
   `a/b/c.so`, then `a/b/c/d.so` within each Titan binary-path root after
   expanding versioned/unversioned overrides and `;;` defaults like runtime.
2. Earlier binary-path roots retain precedence over shallower containers in
   later roots; the first existing occurrence of a relative candidate shadows
   the same relative name in later roots even when it is a clean nonclaim.
3. A candidate is a nonclaim only when both requested logical ABI and types
   symbols are absent; any partial/invalid/wrong-version claim is terminal.
4. The current markerless exact-DSO error remains intact, while markerless
   ancestor containers can be skipped and source fallback still works.
5. A successful binary import caches the physical absolute filename and sets
   transient `Type.Module.file` to the selected relative provider, and no
   earlier entry in the equivalent expanded Titan run-time path contains that
   relative pathname. Lua shims follow independent `package.cpath` precedence;
   production installs one canonical active-ABI provider and checkout tests
   explicitly put their intended root first.
6. Generated dynamic-import C loads `node._type.file`, then checks/resolves the
   requested logical module's own ABI/init/native symbols from that handle.
7. Runtime loading remains exact, cached, `RTLD_LAZY | RTLD_GLOBAL`; several
   logical imports reuse one handle without sharing module state.
8. No-main CLI roots derive one provider from their longest common dotted
   component prefix; unrelated roots fail before codegen, while main mode is
   unchanged. Linked logical module `titan` is reserved, and physical provider
   `titan` must contain the native Lua support entry before publication.
9. Every linked source module is compiled once, objects are deterministically
   unioned, and one final DSO receives native extras/libraries exactly once.
10. Distinct logical names whose C manglings collide are rejected before link.
11. Each embedded logical module retains its own `_abi`, `_types`, `_init`,
    `luaopen_*`, registry identity, initializer, module state, records, and
    trace names; the container adds no aggregate semantic module.
12. One generated Lua shim exists for every linked logical source module and
    none for folder contributors or executables.
13. Generated shims resolve the provider through `package.cpath`, map it with a
    real lazy/global Titan helper, canonicalize aliases into a per-state cache,
    call the exact `luaopen_*`, preserve level-zero errors, and never clobber
    unrecognized Lua sources.
14. Bare `require "titan"` uses Lua's eager/local C searcher and initializes no
    stdlib module; the first generated logical shim then uses Titan's separate
    lazy/global cache to load or promote its provider before symbol lookup.
15. The standard library is checked/compiled in one `titanc` call and linked
    with `titanlib.o` into one `titan.so` containing all seven logical modules.
16. Production bundled mode has one private libuv instance in `titan.so`; system
    mode records only the selected shared dependency on that same image.
17. Source-rock build creates a distinct bootstrap-only image, stages it only
    when the canonical active path is absent, preserves a usable existing image,
    fails untouched on an incompatible occupant, and restores the complete
    prior public DSO/dSYM/shim set until a verified full replacement commits.
18. Installation contains one versioned canonical `titan.so` and seven logical
    shims plus one canonical dSYM on macOS, with no top-level `titan.lua`, child
    DSO, active-layout compatibility copy, symlink, or hard link.
19. The ABI boundary isolates the new physical resolution/deployment contract,
    while exact same-ABI DSOs remain valid terminal candidates; installation
    first configures Lua's `lib/titan/<library-version>` C path before the rock install.
20. The delayed-FS and other private exact-DSO variants remain isolated and
    continue working only in roots without a shallow combined container.
21. Both manuals, their indexes, active cross-references, README, and AGENTS
    describe provider lookup, shims, stdlib ownership, and the ABI accurately.
22. Focused specs, compiler/library groups, `make test`, bundled/system smokes,
    push Linux CI, and manually dispatched macOS CI pass before merge.

## 14. Principal risks and review traps

- **Treating a container as a module.** `a/b.so` is a physical provider, not an
  implicit `a.b` value or initializer.
- **Merging ASTs or checker state.** Sharing a link does not create shared
  visibility, declaration order, local scope, or nominal ownership.
- **Re-deriving the exact child path in codegen.** Prefix discovery is lost
  unless `node._type.file` reaches generated C.
- **Serializing `Type.Module.file`.** That would bake one installation's
  packaging path into portable logical metadata.
- **Candidate-major search across roots.** It lets an installed shallow bundle
  override an earlier local exact module and breaks Titan-path precedence.
- **Selecting a later-root file at an already occupied relative path.** Generated
  exact run-time loading and `package.searchpath` would reopen the earlier
  metadata-less file; the occupied-candidate rule is what makes transient
  relative provider selection reproducible.
- **Continuing after a metadata claim fails.** A wrong ABI/corrupt earlier
  container must not be hidden by a deeper image.
- **Treating a half-interface as a nonclaim.** `_types` without `_abi` is an
  incompatible claimed module, not an unrelated C library.
- **Adding runtime prefix probing.** The compiler already knows the selected
  relative provider, has a transient field for it, and now guarantees that no
  earlier root occupies it; a second native probe would add
  handle-promotion/error-order complexity.
- **Using stock `package.loadlib("*")` while claiming lazy loading.** Lua 5.5
  uses `RTLD_NOW`; the generated shim needs the Titan helper.
- **Letting Lua's private handle cache satisfy the global request.** Bare
  `require "titan"` is intentionally eager/local; the generated shim must call
  Titan's independently cached `dlopen(..., RTLD_LAZY | RTLD_GLOBAL)` so the
  provider is newly loaded or the already mapped canonical image is promoted.
- **Treating bare `titan` as an ordinary generated module/provider.** Its Lua
  name belongs to the native support API; logical `titan` is rejected in library
  mode and physical `titan.so` must prove it includes `luaopen_titan`.
- **Reusing one Make target for bootstrap and full images.** Timestamp order can
  silently install the wrong form on warm/repeated builds.
- **Overwriting the mapped bootstrap in place.** Stage and atomically rename the
  final image so the LuaRocks parent/child processes keep a valid old inode.
- **Committing the DSO before the complete shim set.** Cross-directory publish
  is not one atomic rename; stage everything, commit the DSO last, and restore
  backups on any hook failure.
- **Compiling stdlib modules in separate invocations.** The brief explicitly
  excludes later combination of separately compiled roots; all seven must be in
  the one source-root set/process.
- **Linking child closures independently.** That repeats shared objects and can
  duplicate nominal/module state; link the union once.
- **Forgetting mangling collisions.** Separate files may compile but the shared
  link cannot contain duplicate global metadata/entry symbols.
- **Generating shims from folder source files.** Only logical cache entries get
  shims; contributors are never modules.
- **Writing shims beside an external source tree.** They are output artifacts
  beside the logical DSO tree under the compiler working directory.
- **Broadly cleaning `*.lua`.** User-authored Lua sources are not generated
  standard shims.
- **Keeping the ABI marker unchanged because symbol shapes look unchanged.** Pre-boundary generated
  consumers contain an exact physical filename and cannot use the new install.
- **Installing with Lua configured for a stale library path.** Re-running the rock
  cannot change `luaconf.h`; `make lua` and `make luarocks` precede the first
  install.
- **Leaving CI on the old uv-only boundary.** System/bundled mode now replaces
  and inspects the complete `titan.so`, and snapshots must preserve that image
  plus its shims/stamps.
