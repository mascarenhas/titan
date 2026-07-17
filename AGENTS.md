# CLAUDE.md

This file provides guidance to a coding agent when working with code in this repository.

## What this is

Titan is a statically-typed, ahead-of-time-compiled sister language to Lua.
This repo is the prototype compiler, written in Lua, that translates each
`.titan` module to its own C translation unit and invokes the system C
compiler. A no-`main` invocation links all selected source modules into one
shared library named from the requested roots' longest common dotted prefix
and emits one generated Lua shim per linked logical module; when exactly one
requested module defines `main(args: {string}): integer`, it instead produces
a standalone executable bundling all modules. The language reference is
`doc/language/index.md`; the implementation documentation (lexer/parser,
checker, code generator, interop machinery) is `doc/implementation/index.md`.
**When you add or change a user-visible language feature, update BOTH manuals
as part of the same change** — typically a new
`doc/language/<feature>.md` chapter (user-facing syntax/semantics) and a
`doc/implementation/<feature>.md` chapter (parser/checker/coder/GC internals),
each linked from the respective `index.md`; the variadic-parameters feature is
the model (`doc/language/variadic-parameters.md`,
`doc/implementation/variadic-parameters.md`). Treat the docs as part of
"done," not a follow-up.

**Design judgment:** much of Titan's architecture is intentional even where
every consequence is not written down. Fill routine gaps by following the
existing invariants and design taste. If a gap appears to require an identity
trick, symbolic/hard-link dependency, unusual indirection, accumulating
special cases, or another architectural workaround, first inspect the existing
design and then pause to ask the maintainer about the intended invariant. Do
not add epicycles around what may be a misunderstood simpler design.

## Prerequisites (important — the suite cannot run without these)

- **Lua 5.5.** Both the compiler's own Lua code and generated C target Lua
  5.5 (rockspec: `lua ~> 5.5`). Use an absolute project-local prefix such as
  `PREFIX=$HOME/.local/titan/titan-dev`. `make lua` configures Lua 5.5.0's
  `LUA_ROOT` to that prefix while leaving upstream `loadlib.c` unchanged. The
  generated standard-module shims resolve physical `titan.so` through
  `package.cpath`, load bare native support with `require "titan"`, then use
  `titan._loadlibglobal` to map/promote the provider with
  `RTLD_LAZY | RTLD_GLOBAL` before invoking the exact `luaopen_titan_*` entry.
  It builds and installs Lua there
  and copies its matching `.c` and `.h` files to `$PREFIX/src/lua-5.5.0/`;
  `make luarocks` builds and installs
  pinned LuaRocks 3.13.0 against that Lua with `--prefix`, `--rocks-tree`, and
  `--with-lua` all set to the prefix and `--force-config`. CI uses these same
  targets. `PREFIX` owns Lua and the LuaRocks program/configuration;
  `ROCKS_TREE` owns the Titan rock, compiler SDK, and stdlib. The supported
  developer and CI layout currently configures `ROCKS_TREE == PREFIX`, but
  that equality is deployment policy rather than an ownership invariant. Use
  that LuaRocks' sole system-style tree; Titan
  library/application distribution through a separate packaging system is
  future work. Versioned completion stamps live under `$PREFIX/etc/titan`, so
  a warm `make luarocks` is a no-op while each new isolated prefix installs
  independently. Its generated config records Make's effective `CC`, `AR`, and
  `RANLIB` (`LD` follows `CC`), so invoke later rock builds through that
  prefix's LuaRocks rather than changing native tool identity between phases.
- **CI runs Linux on every push and the complete macOS suite only on manual
  dispatch.** Use `workflow_dispatch` as the **pre-merge check** with
  `gh workflow run ci.yml --ref <branch>`. Linux jobs are push-only and are not
  repeated by that macOS dispatch. The regular Linux flow
  uses two 1-core `ubuntu-slim` jobs designed to remain below that runner's
  15-minute limit. The regular build job runs the core compiler/language shard
  plus serial and net/OS tests on its warm tree, and uploads a same-run,
  full-tree tar artifact for one consumer. That consumer runs uv/timer/fs
  first, then the fixed heavy coverage shard (`coder_spec.lua` and
  `flexible_returns_spec.lua`). The complete local `compiler` group remains
  the union of both coverage shards. Each shard uploads its explicit report
  through Codecov's GitHub OIDC flow with job-local `id-token: write`; upload
  errors fail the job so coverage publication cannot be silently skipped. The
  sanitizer job keeps its build
  and focused native-memory gate on one warm runner: representative timer/fs
  suites, core owner/callback proofs, and production net/OS smokes. Keep full
  library behavior suites in regular Linux unless they exercise a
  distinct sanitizer-sensitive boundary; recompiling them under sanitizers
  can consume the complete runner limit without improving that gate. Keep each
  Linux dependency build in the job that consumes its warmed tree, and keep
  the Linux production mode smokes in the regular producer: rebuilding them
  in a consumer wastes aggregate billed runner time even when the workflow's
  wall-clock critical path is unchanged. Pack the regular artifact before the
  mode smoke replaces the bundled combined `titan.so`, but upload it only
  after both modes pass; repacking the system-linked tree changes every
  logical standard module at once and shifts
  recompilation into a consumer. The full-tree archive is intentional because
  partial output archives lose source/output timestamp ordering and trigger
  Make rebuilds; it also preserves the prepared Lua installation, executable
  bits, and standard-library images. Run the serial and net/OS library groups
  before core compiler coverage in that producer. Legacy compiler specs still
  clean root-generated module outputs; running the packaging gate first avoids
  rebuilding the complete standard library without exercising a new
  configuration. The complete macOS flow likewise runs the library
  group before its uncovered compiler group. CI snapshots and restores the
  prepared runtime artifacts, canonical installed `titan.so`, conditional
  dSYM, and all seven generated shims around the producer's compiler-only
  group so root output cleanup cannot stale or remove the production image
  before the mode smoke. The consumer deliberately runs its compiler shard
  after its final library group, so no later production image needs restoring.
  Compiler and language specs must not
  delete the shared checkout runtime archive merely to force recompilation;
  Make owns that dependency state. The serial coroutine suite is the isolated
  exception described below.
- **A local Titan prefix prepared by `make lua`.** The checkout keeps the
  gitignored `./lua-5.5.0` build tree, while the installation contains the
  same internal sources, including the configured `luaconf.h`, under
  `$PREFIX/src/lua-5.5.0/` and the
  matching `$PREFIX/lib/liblua.a`. Generated C includes Lua internal headers
  (`lobject.h`, `lgc.h`, `lvm.h`, ...) from that installed source tree and
  links the matching archive. That `luaconf.h` is also the public configuration
  used when this LuaRocks builds other Lua libraries and Titan packages.
  `make lua` uses `MYCFLAGS=-fPIC` and selects `linux`/`macosx`
  from `uname`; override with `make lua LUA_PLATFORM=...`, and use `LUA_CC`
  for Lua's compiler. Its configuration stamp cleans Lua objects whenever
  `PREFIX`, `LUA_PLATFORM`, `LUA_CC`, or a `LUA_MY*` input changes.
- **Lua deps and rock installation**: `$PREFIX/bin/luarocks make
  titan-dev-1.rockspec` installs lpeglabel, inspect, argparse, luafilesystem,
  then deploys the compiler/runtime SDK and the combined standard library. The
  rockspec keeps `build_target = "titan"`, disables LuaRocks' separate Make
  install pass, derives `ROCKS_TREE` from `$(SCRIPTS_DIR)/..`, and does not own
  a manifest C module named `titan`. `make titan` builds `libtitan.a`, the
  separate `libbacktrace.a`, and a private support-only image at
  `titan-runtime/bootstrap/titan.so`; with a nonempty `ROCKS_TREE` it also
  stages the matching compiler SDK. `libtitan.a` contains exactly `titan.o`,
  `titan_coro.o`, and `titan_uv.o`; `titanlib.o` is outside that archive and is
  the sole input to the private bootstrap. The non-Lua headers staged under
  `$ROCKS_TREE/include` are `minicoro.h`, `titan.h`, `titan_longjmp.h`, and
  `titan/{ffi,coro,uv}.h`; bundled mode also stages `uv.h` and `uv/`, but the
  private `libuv.a` is never installed.

  SDK staging atomically places the bootstrap at
  `$ROCKS_TREE/lib/titan/0.16/titan.so` only when the path is absent. It
  validates and preserves an existing usable bootstrap or full image, and
  refuses to clobber an incompatible file; a repeated build must never shrink
  a full image back to bootstrap form. After LuaRocks deploys the compiler, the
  source-only `post_install` hook invokes the just-installed `titanc` once with
  all seven roots and `titanlib.o`. The standard sources are
  `titan/coroutine.titan`, the explicit seven-file `UV_TITAN_SOURCES` folder
  ensemble, and `titan/{async,timer,fs,net,os}.titan`. Each logical module
  remains independent, but the one physical output is `titan.so`; bundled or
  system libuv inputs are applied once to that link.

  The hook builds in a private destination-filesystem stage, validates eight
  `luaopen_*` entries, seven ABI/types pairs, seven generated shims, and the
  macOS dSYM, then uses `titan-compiler.stdlib_installer` for recoverable
  publication. It backs up the current active-0.16 DSO/dSYM/shims and stale
  active-layout copies, commits shims and dSYM, and renames the DSO last; a
  failure restores the previous full image or first-install bootstrap. The
  canonical artifacts are `$ROCKS_TREE/lib/titan/0.16/titan.so`, its macOS
  dSYM, and generated
  `$ROCKS_TREE/share/lua/5.5/titan/{coroutine,uv,async,timer,fs,net,os}.lua`.
  No symbolic links, hard links, child DSOs, or `lib/lua` compatibility copies
  are used, and a separately versioned 0.15 tree is not purged. These direct
  SDK/stdlib files remain outside the rock manifest and are not removed by
  `luarocks remove`; binary-rock ownership is deferred until Titan has a
  library/application packaging story. The
  rockspec declares `test_dependencies` (busted, cluacov) plus a
  `test = { type = "busted" }` block, so `luarocks test` installs those and
  runs the suite. `luarocks test` does **not** build the rock-under-test, so
  `make test` runs `luarocks make` first.
- **C toolchain**: `CC` (default `cc`) for compilation and for the C FFI's
  predefined-macro/include-search probes. The FFI uses the same C99 mode and
  parsed `TITAN_EXTRA_CPPFLAGS` as generated C. The probe is POSIX-only today
  (`/dev/null`, `LANG=C`). Bundled libuv additionally needs CMake, tar, a
  downloader (`curl` or `wget`), and `sha256sum` or `shasum`.

## Commands

**First**, choose the standalone local installation and put its tools on the
path:

```sh
export PREFIX="$HOME/.local/titan/titan-dev"
export PATH="$PREFIX/bin:$PATH"
```

For throwaway verification, use an isolated absolute prefix under `/tmp`
(for example `/tmp/titan-$USER-check`) rather than relying on checkout-local
`.lua` or `lua_modules` trees. Give concurrent workers distinct prefixes; this
keeps their installed compiler snapshots and native SDKs independent and makes
parallel isolated builds possible.

```sh
make lua                                            # build/install prefix-configured Lua and matching source headers
make luarocks                                       # build/install LuaRocks for that Lua
make libuv                                          # build pinned static PIC libuv (bundled default)
"$PREFIX/bin/luarocks" make                        # build/install Titan runtime, compiler, and stdlib
make stdlib                                         # checkout-only one-container standard build plus seven generated shims
make test                                           # `luarocks make` + `luarocks test`: (re)install the rock, then run the full suite
luarocks test                                       # test an already current install; with its bin on PATH, PREFIX/ROCKS_TREE are not required
luarocks make && bash spec/support/ci_test_groups.sh compiler  # CI's covered compiler/language group
bash spec/support/ci_test_groups.sh libraries       # CI's complete uncovered library group
make clean                                           # remove generated artifacts; `make distclean` also removes downloaded Lua/LuaRocks/libbacktrace/libuv trees

busted                                              # full test suite — MUST run from repo root (all driver paths are relative); busted recurses into spec/ subdirs
busted spec/parser_spec.lua                         # single spec file
busted spec/coder/coder_spec.lua --filter='for loop' # single test (Lua pattern on test name)

./titanc [--print-ast] [-v] [--lua <luasrc>] [--tree <srcroot>] \
  [-l lib1,lib2] [-X object...] <module>...
```

**Coverage is for compiler and language behavior, not library suites.** Do not
run library API/runtime tests under LuaCov when their purpose is to test the
library rather than a compiler or language feature. LuaCov measures the Lua
compiler, not Titan or C library implementations, and its debug hook can make
repeated checks of large library sources disproportionately slow. CI uses
`spec/support/ci_test_groups.sh` to run the compiler/language group with
coverage and the library group without it. This includes both the async-I/O
stdlib suites and the earlier coroutine stdlib suite; both must still run in
full outside coverage. If a library suite exposes a compiler coverage gap, add
a small focused compiler/checker test for that code path instead of covering
the library integration suite.

**Spec layout.** Pure, layer-level specs live at `spec/` root (`abi_spec`,
`cdriver_spec`, `cpp_spec`, `ctypes_spec`, `driver_spec`,
`foreigntypes_spec`, `lexer_spec`, `location_spec`, `parser_spec`,
`symtab_spec`, `types_spec`, `util_spec`); serial native-build and packaging
gates also live there (`libuv_build_spec`, `rockspec_spec`,
`stdlib_installer_spec`). Compiler and
language specs are split by layer:
checker-only specs (run the checker, never generate or execute code) live
under `spec/checker/`, while compiler end-to-end specs (generate C, compile,
run) live under `spec/coder/`. Standard-library API and runtime behavior live
under `spec/stdlib/`, including `coroutine` and the
async-I/O modules; these suites deliberately run without LuaCov. Do not put a
library integration suite under `spec/checker/` or `spec/coder/` merely
because it typechecks or compiles Titan source. If it reveals missing compiler
coverage, add a small compiler-focused case for that path instead. A sizable
compiler feature gets its own topical `<feature>_spec.lua` in the relevant
layer rather than bloating `checker_spec` or `coder_spec`.
Folder-source resolution, blocking, composition, and cross-file diagnostics
belong in filesystem cases in `spec/driver_spec.lua`; public compilation,
artifact, external-`--tree`, and mixed-source traceback behavior belongs in
`spec/coder/folder_modules_spec.lua`. Keep uv runtime behavior in the existing
non-LuaCov stdlib suites.
Prefix-container public compilation and generated-shim behavior live in
`spec/coder/multi_module_libraries_spec.lua`; native support-loader mode and
promotion behavior live in `spec/stdlib/loadlibglobal_spec.lua`. Keep the
root-major provider/metadata-claim matrix in `spec/driver_spec.lua`.

All driver/artifact paths inside specs are relative to the repo-root CWD (not
the spec file), so subdir specs still run from repo root. The shared
compile/run/import scaffolding (`parse`, `compile`, `call`, `run_coder`,
`generate_modules`, `build_so_chain`, `check_against_so`, `run_checker`,
`check_errs`, `DEPTH_PROBE`, ...) lives in **`spec/support/helpers.lua`**,
`require`d as `spec.support.helpers`; async standard-library tests use
`spec/support/async_stdlib.lua` plus the filesystem and OS/process extensions
`spec/support/fs_test_support.lua` and `spec/support/os_test_support.lua` to
compile inline Titan sources and execute inline Lua assertions in unique
`/tmp` workspaces. Only genuine reusable C/H host and interposer artifacts
remain under `spec/fixtures/stdlib/native/`. These tests treat Makefile-owned
combined `titan.so`, generated standard shims, and the libuv archive as
read-only. These helpers may not clean
or rebuild shared root artifacts during Busted.
Helpers pull in luassert explicitly (`require 'luassert'`) because a
`require`d module does not inherit busted's `assert` global. Set
`helpers.verbose = true` (was a per-file `local verbose`) to print `cc`
command lines and keep generated `.c` files.

New or modified specs that generate compiler fixtures in the repository root
must remove only their exact module artifacts and must treat
`titan-runtime/libtitan.a` as shared Make-owned state. The grouped CI commands
also snapshot and restore the prepared runtime, combined standard-library
image/dSYM, and generated shims around legacy compiler suites that still clean
root artifacts; later
production smokes deliberately consume that restored image.

The serial `spec/stdlib/coroutine_spec.lua` suite temporarily exercises an
isolated exact-provider path, but must restore the prepared runtime, complete
production `titan.so`/dSYM, generated coroutine shim, and mtimes in teardown so
a later packaging test does not rebuild the whole standard library.

Async standard-library behavioral specs compile against the canonical
production modules whenever public behavior can prove the contract. The narrow
exception is `spec/stdlib/uv_late_fs_callbacks_spec.lua`: its isolated
`spec/support/make_delayed_fs_callback_variant.lua` flow copies the complete
`titan/uv/` source ensemble and patches the owning contributors through unique
per-file anchors, then builds exact coroutine/uv/async/timer DSOs under a
private root with no shallow `titan.so`, to delay selected FS callbacks. It
covers late cancellation,
disposal of a late successful open, and cross-generation
Runtime/File/Task/buffer/error rooting. Keep that timing hook out of installed
modules; it is not a general scheduler or fault-injection variant.

`titanc` takes dot-separated **module names**, not file paths (dots map to
directory separators under `--tree`, default `.`). For logical `M`, slash path
`P`, and leaf `B`, a source root checks folder main `P/B.titan` before flat
`P.titan`. A folder module collects every immediate regular `.titan` sibling,
non-recursively: the main declarations come first, contributors follow in
locale-independent numeric-byte basename order, and the main's optional root
initializer is the sole final initializer. Files are parsed independently with
real filenames, then combined into one dense ordinary AST and checked/generated
once under `M`. All contributors share one namespace; top-level `local` is
module-private, never file-private. An immediate constituent cannot be imported
as an apparent flat child once source lookup reaches its parent folder, but a
genuine deeper folder child remains legal. It recovers the Titan
SDK/rocks-tree root from the first `package.cpath` template ending in
`/lib/lua/5.5/?.so`; that works because the supported install currently sets
`ROCKS_TREE == PREFIX`, not because the two owners are inherently identical.
Compiled-module lookup defaults to `.;<root>/lib/titan/0.16`, with
`TITAN_PATH_0_16`/`TITAN_PATH` overriding it and `;;` inserting that ordinary
default at compile time and run time. For logical `a.b.c`, binary candidates
are `a.so`, `a/b.so`, and exact `a/b/c.so`; lookup is path-root-major and
shallow-to-exact within each root. An existing relative pathname shadows the
same pathname in later roots. Both requested ABI/types symbols absent is a
clean nonclaim only for an ancestor; a half claim, open failure, bad ABI,
malformed types, or logical-name mismatch is terminal, and an exact markerless
binary remains an error. The selected relative provider is stored transiently
in `Type.Module.file` and omitted from serialization; generated imports load
that exact file through the unchanged lazy/global runtime sequence.

The standard library uses ordinary qualified module names: most source files
are `titan/<module>.titan`, while `titan.uv` uses main
`titan/uv/uv.titan` plus its six contributors. Production invokes all seven
roots in one compiler process, links one `<root>/lib/titan/0.16/titan.so`, and
installs seven generated shims below `<root>/share/lua/5.5/titan/`.
`import "async"` is parser sugar for `import "titan.async"` (likewise for
`coroutine`, `uv`, `timer`, `fs`, `net`, and `os`). Dependencies resolve
binaries before sources; modules explicitly named on the `titanc` command
line are built from source. There is no parallel root `stdlib/` source tree.

The checker never reorders that combined AST. It premarks ordinary duplicate
winners and annotates `_toplevel_order`, precollects aliases, reserves names,
then visits all imports in AST order, resolves aliases, builds records and
synthesized constructors, collects ordinary callable/initializer signatures
and explicit methods/record functions, and finally checks module variables in
AST order before bodies. Records, aliases, callables, and imports used
outside module-variable declarations are therefore placement-independent. A
module-variable declaration/initializer sees only earlier imports and earlier
module variables, while seeing every other declaration kind. Combined source
order remains authoritative for duplicate precedence, serialized member/slot
order, module-variable initialization, and code generation.

The canonical main controls generated C/object placement, while logical `M`
controls native symbols, metadata, and the generated shim. Thus folder
`foo.bar` writes `foo/bar/bar.c` and `.o`; a single-root library invocation
links exact `foo/bar.so`, while compatible multiple roots link their one
longest-common-prefix provider. Folder contributors produce no artifacts or
shims. A standalone retains `foo/bar__entrypoint.c` and emits
`foo/bar__main`; flat paths remain unchanged. `make clean` must remove nested
generated `titan/uv/uv.c` and `titan/uv/uv.o` and only the explicitly known
generated standard shims, never source or arbitrary user-authored Lua files.
Filesystem source cache entries carry `program_output` (`P` flat,
`P__main` folder); `titanc` and filesystem child compilers must pass it to
`driver.compile_program`. Keep the optional argument's old dotted-name default
for `tableloader` and external callers.

The compiled-module ABI version is `0.16` (bumped from `0.15` because
generated/imported physical DSO resolution now records a selected prefix
container and the canonical standard layout is one `titan.so` plus shims,
even though per-module serialized types and native signatures are unchanged;
`0.15` itself was bumped from `0.14` when the
`titan.uv` folder split moved exported declarations into semantic contributors,
reordering its serialized module members and canonical closure slots; `0.14`
itself was bumped from `0.13` when flexible
returns added `flexrettype` to serialized callable descriptors and a
caller-owned `TitanVargX *_flexout, int _flexwant` pair to flexible-return
native signatures; `0.13` itself was bumped from `0.12` when named arguments
added formal-name metadata to the serialized `ModuleMember`, `Method`, and
`StaticMethod` descriptors in `<mangled>_types` without changing the native
call ABI; `0.12` itself was bumped from `0.11` when exported type
aliases added a separate `type_members` namespace to `<mangled>_types`; `0.11`
itself was bumped from `0.10` when module-local records and record
members changed that serialization to omit local records/members while
preserving record field-slot counts; `0.10` itself was bumped from `0.9` when
the `TitanVargX` family changed from inline flexible-array backing objects to
`{ n_args, args pointer }` descriptors; `0.9` itself was bumped from `0.8` for
variadic parameters: a variadic function's native signature gained a trailing
`TitanVargX *_varargs, int _start` pair after the declared params and before
the out-params, and `<mangled>_types` now encodes the `varargtype` element type
for variadic functions/methods; `0.8` itself was bumped from `0.7` when a
record's type identity moved from a `getudatamem` tag word to the udata's
metatable pointer; `0.7` itself was bumped from `0.6` when record instances and
module state collapsed to single Lua 5.5 `Udata` objects; `0.6` added the
native `_fn` closure parameter). `.so`s built by an older Titan are
incompatible. `-v` prints the exact `cc` command lines. Without the prepared
Lua 5.5.0 installation, only the pure specs pass (cpp, lexer, location,
parser, symtab, types, util); `spec/checker/`, `spec/coder/`, and
`spec/stdlib/` need the full setup.

**Gotcha — the installed rock shadows the working tree under busted.** The Busted launcher uses `luarocks.loader`, so once `$PREFIX/bin/luarocks make` has installed the `titan` rock, `require "titan-compiler.X"` inside specs resolves to the *installed snapshot* in `ROCKS_TREE` (currently the same directory as `PREFIX`), not your edited source files — edits silently do not take effect. Re-run `$PREFIX/bin/luarocks make` after changing compiler sources, before running Busted. (`make test` re-runs `luarocks make` for you each time, so it always tests current sources; `luarocks test` on its own does **not** rebuild the rock.) A bare `busted` without a preceding `luarocks make` can silently load a stale installed snapshot and pass or fail misleadingly.

When the active installation's `bin` directory is on `PATH`, plain
`luarocks test` needs neither `PREFIX` nor `ROCKS_TREE`: child interpreters use
`lua` from `PATH`, and async stdlib helpers discover the canonical installed
modules from `package.cpath`.

**Gotcha — do not inherit `luarocks init` paths.** The standalone-prefix flow
does not use `luarocks init`. Ambient `LUA_PATH`, `LUA_CPATH`, or their Lua-5.5
variants can make even the prefix's Lua load an obsolete checkout-local
`lua_modules` compiler. `make test` and the rock's post-install hook clear
those overrides; do the same before manually invoking prefix tools from a
shell that previously activated a project tree. Replace an installation prefix
created under the old project/user-tree layout instead of trying to migrate it:
third-party launchers embed their active Lua paths when installed and a later
LuaRocks config migration cannot safely rewrite them.

### Lua 5.5 internals conventions in generated C

The coder targets Lua 5.5 internals; keep these idioms when touching templates: stack fields are unions (`L->top.p`, `L->ci->func.p`, `StkId` + `s2v()` to view a slot as `TValue*`); the table array part has no `TValue` slots (read via `luaH_fastgeti`/`luaH_getint` into a local `TValue` holder testing `tagisempty(tag)`, write via `obj2arr`/`luaH_setint`/`luaH_set` — `luaO_nilobject` and `luaH_newkey` no longer exist); booleans carry no payload (`ttistrue`, `titan_setbvalue` from titan.h); `ttypetag()`/`LUA_V*` are the variant tags (old `ttnov` is now `ttype`); a record value IS a `Udata` (created with `luaS_newudata(L, 0, N)`) — its fields live in `uv[0..N-1].uv` (0-based, no reserved `uv[0]`), the record's TYPE IDENTITY is its metatable pointer (a type check compares `uvalue(v)->metatable`; the udata has no raw payload), and that metatable sits on the udata's `metatable` field; `_mod` (module state) is likewise a single `Udata`. Stores of collectable values into a `CClosure` upvalue (function values; capture boxes are userdata, see below) need the **forward** `luaC_barrier(L, owner, slot)`, while record-field and module-slot stores into a `Udata` user value and table stores need the **back** `luaC_barrierback(L, obj2gco(o), v)` (genlink-safe on userdata) — the generational GC makes missing barriers near-deterministic corruption, not a rare race.

**Numeric semantics must reproduce Lua exactly, not C's** (see `doc/implementation/codegen-constructs.md` "Operators with inlined Lua semantics"): integer `+ - *`, unary `-` (`intop(-, 0, x)`) and binary `~`/xor (`intop(^, …)`) go through `intop`/`l_castS2U`/`l_castU2S` from `lvm.h` for defined two's-complement wraparound — raw signed C `+ - * -` is overflow UB (`driver.CFLAGS` has no `-fwrapv`); `//`/`%`/shifts inline `luaV_idiv`/`luaV_mod`/`luaV_shiftl`; `^` follows `luai_numpow` (exponent `2` → `x*x`); mixed `integer`/`float` comparisons inline the `titan_lt_intfloat`/`titan_le_intfloat`/`titan_lt_floatint`/`titan_le_floatint`/`titan_eq_intfloat` helpers in `titan.h` (chosen by static operand type, no `TValue` boxing) rather than promoting the integer to float; float literals are emitted with `%.17g`.

## Architecture

Pipeline (all in `titan-compiler/`): for each logical module, the driver
resolves a flat source or folder descriptor → `parser.parse` runs
independently for each real source file → one dense AST → one
`checker.check` → one `coder.generate` translation unit →
`pretty.reindent_c` → `driver` writes the `.c` **next to the flat source or
canonical folder main** and invokes the parsed `CC` command with each argument
shell-quoted. Folder descriptors are temporary loader metadata, not AST nodes
or namespaces. In no-main mode, `titanc` derives the longest common dotted
provider from the deduplicated requested roots, rejects unrelated roots,
reserved logical `titan`, mangling collisions, and user-owned shim paths before
codegen, then sorts/deduplicates the complete source-object union, links it once
through a staged provider, validates every logical protocol, publishes the DSO
(and macOS dSYM), and writes generated shims. Standalone mode remains the
all-source executable path. `TITAN_EXTRA_CPPFLAGS` precedes the defaults and is
shared with foreign-import probes, `TITAN_EXTRA_CFLAGS` is compile-only, and
ordered `TITAN_EXTRA_LDFLAGS` is final-link-only. Type/load errors are all
reported before codegen.

### The `_tag` / typedecl convention (cross-cutting)

AST nodes (`ast.lua`) and types (`types.lua`) are plain tables created by `typedecl.lua` constructors: positional, arity-checked args producing `{_tag = "Ast.ExpCall", ...}` / `{_tag = "Type.Integer", ...}`. All dispatch is string comparison on `_tag`. `util.make_visitor` **asserts** a handler exists per tag — adding an AST tag means updating every checker visitor (`checkstat`/`checkexp`/`checkvar`/`typefromnode`/toplevel) and the coder's if/elseif chains; adding a Type tag means updating `types.tostring`/`equals`/`compatible`/`serialize` by hand. Group names in `ast.lua` (Exp, Stat, ...) are documentation only — they don't appear on nodes.

### Frontend (`lexer.lua`, `parser.lua`, `syntax_errors.lua`)

Lexing and parsing are fused in one LPegLabel/relabel grammar; `lexer.lua` exports raw LPeg patterns referenced as `%TOKEN` terminals (no token stream). Every AST constructor is auto-injected into the grammar's defs table, so grammar actions like `-> TopLevelFunc` call constructors directly. Every error label used in the grammar (`^Label`, `%{Label}`) or lexer (`lpeg.T`) **must** have an entry in `syntax_errors.errors` or error formatting breaks. The parser is not reentrant (module-global `THIS_FILENAME`, asserted nil on entry). `record` declarations are desugared at parse time into a `TopLevelRecord` plus an adjacent synthesized `new` static function marked `_record_constructor`; explicit record functions do not carry that marker. `[local] type Name = T` produces a compile-time-only `TopLevelTypeAlias`. Short standard-library imports are also parser sugar: `coroutine`, `uv`, `async`, `timer`, `fs`, `net`, and `os` become the ordinary qualified module names under `titan.*` before module resolution.

### Checker (`checker.lua`, `types.lua`, `symtab.lua`)

`checker.check(modname, ast, subject, filename, loader) -> moduletype, errors`; callers test `#errors == 0`. Without reordering the AST, it marks ordinary duplicate winners and `_toplevel_order`, precollects aliases, then stages name reservation; imports in AST order; alias resolution; records; parser-marked synthesized constructors; ordinary callable/module-initializer signatures; methods and record functions; module variables in AST order; and finally bodies. It annotates `_ignore` on rejected duplicates. The checker also annotates (`_type`, `_types` for multi-return calls, `_decl` on variable uses, `_used`/`_assigned`) and **mutates** the AST:

For a folder source the driver calls the checker exactly once with the
combined AST, logical module name, and canonical main filename/source
directory. Duplicate declarations, aliases, and alias/record conflicts use
the later node's normal error prefix and print the earlier declaration's full
`filename:line:col`; do not regress those to line-only messages.

During each `TopLevelVar`, `symtab.initializer_order` hides the current/later
module variables and later Titan/foreign imports; foreign type/name histories
recover the last C declaration visible at that frontier, while
`foreign_definition_visible` uses a canonical struct/union owner's
`_definition_order` to hide completion performed by a later header. Every other
declaration kind sees all imports, records, aliases, and callables regardless
of relative placement. Body checking and the coder still traverse the unchanged
AST order, as does `makemoduletype`.

- Every legal implicit coercion is materialized as a synthesized `Ast.ExpCast` node (`trycoerce`) **before** `checkmatch` — the coder generates conversions only from ExpCast, and `checkmatch` reports an error if a still-coerceable mismatch reaches it.
- Extra multiple-return values become synthesized `Ast.ExpExtra` nodes appended to `exps`/`args` lists; for-loops get a default step synthesized into `node.inc`.
- Generic `for ... in` elaborates its iterator tuple into synthesized
  `_init_call`, `_next_call`, and optional `_close_call` nodes. `next` and
  `close` may be Titan functions, `value` callables, or C function
  pointers/direct FFI functions; `value` callables are coerced to a synthesized
  function type from the state/start/declaration list for `next`, and from the
  state for `close`. The first iterator return may be an option, `value`, raw
  `TValue`, or nullable C pointer sentinel; close callables accept zero or one
  state argument.

`checkstat` handlers return a boolean "always returns", used to enforce that non-nil-returning functions return on all paths. Imports go through a `loader` callback (`driver.defaultloader` for real lookup, `driver.tableloader` for in-memory sources in tests); source deps are recursively typechecked, while compiled-provider deps probe the requested `<mangled>_abi`/`<mangled>_types` pair before recovering the interface.

Titan aliases occupy a module-wide type-only namespace in `symtab`, resolve
transparently to their RHS `Type.*` value, and never create a run-time member.
Public aliases are serialized separately as `Type.Module.type_members`; local
aliases are omitted. Alias names may be forward referenced, and the import
stage precedes alias resolution, so a qualified alias target may use an import
written later. Only a module-variable declaration is prevented from directly
using a later import alias.

`driver.defaultloader` obtains those two Lua C functions through the internal
`titan._loadlib` helper, which maps every compiled interface with
`RTLD_LAZY | RTLD_LOCAL`; this is generic compiler plumbing, not a libuv
bootstrap or dependency classifier.

**Process-global mutable state** — tests and tools must reset these:
`types.registry` (FQTN → `Type.Record`; `Type.Nominal` carries only the FQTN
string and resolves through the registry at every use), `driver.imported`
(import cache with a `CIRCULAR_MARK` sentinel for cycle detection). Tests must
save and restore both together.

### Coder and driver (`coder.lua`, `pretty.lua`, `driver.lua`)

`coder.generate(modname, ast, static_deps)` produces one C translation unit as a string — no C AST, just `util.render` templates (`$VAR` substitution, recursive; error on missing keys). Key facts:

- Whole-root AST passes use `ipairs` to preserve main/contributor declaration
  order. Keyed interface maps use `util.bytewise_less`; ordered module members
  and record fields retain source/slot order. `emitline(node)` remains per-node
  at safe function/statement/call/raise sites, so one folder C unit switches
  `#line` filenames between contributors. Do not add a unit-global directive.
- Folder modules change only source discovery and compilation-unit assembly:
  there is no new AST/Type tag, native calling convention, serialized field,
  or runtime DSO rule. Every symbol, nominal owner, registry key, module state,
  and initializer is derived once from logical `modname`. The mechanism itself
  does not require an ABI change, but the `titan.uv` dogfood deliberately moves
  public declarations into contributors and changes their ordered slots; ABI
  0.15 segregates those DSOs from 0.14 importers. The later checker staging,
  relocation of private uv records, and move of the private `FS` constants
  instance change private slot/initialization order but neither the exact
  serialized public interface nor native signatures. ABI 0.16 is the later
  physical-provider/layout boundary, not a folder-source schema change.

- Each Titan function becomes **two** C functions: a raw native-convention one (`RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, params..., input-vararg pair, out-params for returns 2..n, flexible-output pair)`; the input and output pairs appear only when declared, and the **caller** owns flexible-output storage and anchors GC-able values on the Lua stack) and a Lua-stack entry wrapper that coerces arguments and installs the error handler. `_fn` is the function value's own closure (still a `CClosure`): `NULL` on fully-static top-level calls, and the callee itself on first-class/closure/value calls; for anonymous functions it carries the captured variables (this uniform parameter is what bumped the module ABI to `0.6`). `_mod` becoming `Udata*` and record instances becoming a single `Udata` (so every record-typed param/return changes C type and `<mangled>_init` returns `Udata*`) is what bumped it to `0.7`; the ABI then bumped to `0.8` when a record's type tag became its metatable pointer (no `getudatamem` payload), to `0.9` when a variadic function's native signature gained the trailing `TitanVargX *_varargs, int _start` pair (after the declared params and before the out-params) and `<mangled>_types` began encoding the `varargtype` element type, to `0.10` when the `TitanVargX` structs changed from inline flexible arrays to descriptor structs with an `args` pointer, to `0.11` when local records/members changed record interface serialization, to `0.12` when public type aliases added the serialized `type_members` namespace, to `0.13` when named arguments added serialized declaration-only `paramnames` metadata without changing native function signatures, and to `0.14` when flexible returns added serialized `flexrettype` metadata and the conditional trailing `TitanVargX *_flexout, int _flexwant` native pair.
- A dynamically imported module is loaded from its transient
  `Type.Module.file` with `RTLD_LAZY | RTLD_GLOBAL` before it is initialized.
  `file` defaults to the exact logical path, is overwritten by prefix-container
  rehydration, and is never serialized. If an imported interface re-exports a nominal record type
  owned by one of its own imports, initialization of the explicit import first
  publishes the owner's method entry points. The importer then resolves those
  transitive symbols through `RTLD_DEFAULT`; it does not open the owner DSO a
  second time.
- Module state is a `Udata` (`_mod`), allocated with `luaS_newudata(L, 0, NUPVALS)`: there is no reserved user value; the module's user values (0-based) hold module globals, exported-function canonical closures, imported-module `Udata`s, record metatables, and per-record static-namespace tables. There is **no** Lua-facing module table — `require` returns the module `Udata` itself (so `type(require "m")` is `"userdata"`), and all member access (functions, variables, record namespaces `m.Rec`) flows through a metatable `__index`/`__newindex` over a unified name→slot member map; functions and record namespaces are served read-only (assigning errors), variables coerce in/out, and the "not found" message is "member '%s' does not exist". A record instance is likewise a single `Udata` (fields in `uv[0..N-1]`, type identity is its metatable pointer (no raw payload), metatable on the udata).
- Typedef-resolved pointers to Lua's internal `Udata` are GC-bearing FFI
  values, not ordinary C pointers: boxing a non-NULL `Udata *` emits a full
  userdata `TValue` for that same object, NULL boxes as nil, and unboxing
  accepts full userdata or nil rather than lightuserdata. Owned C
  pseudo-constructors (`T.new()` and `T.new_array(constant_count)`) are valid
  top-level initializers and keep their userdata rooted in the module state.
- **Semantic state must live in the Lua registry or GC-traced Lua objects, never
  in shared C globals.** Several logical modules may share one physical DSO;
  each keeps its own `_abi`, `_types`, `_init`, `luaopen_*`, registry module
  `Udata`, initializer, record identities, closures, and file-local native
  wiring. The standard library's one canonical installed `titan.so` is shared
  by all seven logical modules and by bare Lua support. It is the sole complete
  bundled-libuv provider. A Titan extension DSO that directly
  foreign-imports libuv must also `import "uv"` (desugared to `titan.uv`) and
  leave its `uv_*` references unresolved. Titan's one generic runtime DSO
  loader uses `RTLD_LAZY | RTLD_GLOBAL`: lazy binding lets the extension map
  first, then its
  generated initializer loads the explicit `uv` import globally before
  ordinary libuv function calls bind. `RTLD_NOW` would try to bind those calls
  before the initializer could load the provider, and a provider mapped
  `RTLD_LOCAL` later would not be visible to them. There is no libuv-specific
  origin, interface metadata, compiler bootstrap, or Titan loader entry point;
  every generated runtime import uses these flags. Compiler interface recovery
  remains lazy/local through `titan._loadlib`. This runtime path does not
  support native constructors, imported data, or taken-function-address
  relocations that need libuv while the extension itself is being mapped. A
  Lua caller must `require "titan.uv"` before requiring such an extension. The
  generated `titan/uv.lua` shim resolves physical provider `titan` through
  `package.cpath`, requires bare native support, then calls
  `titan._loadlibglobal(path, "luaopen_titan_uv")`. That helper uses a separate
  canonical-path per-state cache and performs `RTLD_LAZY | RTLD_GLOBAL` even
  when Lua or compiler `_loadlib` already opened the image; for combined
  `titan.so` this promotes Lua's initial eager/local support mapping. It never
  calls `dlclose`. System mode may
  instead link both against the same pkg-config-selected shared libuv; the
  private bundled `libuv.a` must never be linked into another DSO.
  Lua's shim-driven global promotion occurs before the extension is mapped, so that
  path also supports eager relocations and native constructors. It can resolve
  native symbols for a Lua-only extension without a Titan `uv` import, but the
  import remains mandatory for modules that must work through Titan's loader.
  A generated standalone entrypoint publishes its original `argc` and `argv`
  under `TITAN_MAIN_ARGC_KEY`/`TITAN_MAIN_ARGV_KEY` before requiring the main
  module. Canonical `titan.uv` calls `uv_setup_args` once during initialization,
  writes libuv's possibly replaced `argv` back, and keeps readiness in a
  module-local boolean; the entrypoint rereads the pointer before building the
  Titan argument table. A Lua or other embedding host has no such keys, so
  `os.exepath` raises before calling libuv. Variable-size OS text helpers keep
  sizes as `size_t` and recurse on `UV_ENOBUFS`; the Linux/macOS `uv_exepath`
  adapter translates a saturated success into one such recursive retry. Do not
  reintroduce a retry loop, attempt limit, or synthetic growth fault hooks.
  When either representation satisfies the ownership invariant, hot Titan
  paths should keep state directly reachable through module/userdata fields
  instead of performing Lua-registry table lookups; use the registry for
  identity, bootstrap, or genuinely shared lookup rather than as the default
  access path.
  Likewise, use an exact record type (or `T?` for an absent-or-record link) for
  homogeneous record fields and private function signatures. Reserve `value`
  for opaque Lua roots, arbitrary payloads, and genuinely heterogeneous state:
  recovering a record from `value` performs a metatable/tag check, while
  unwrapping `T?` needs only the nil check.
  Translation-unit statics may hold only immutable
  constants and non-stateful wiring that is known to be identical for every
  Titan module; native caches belong in registry-owned userdata rather than
  mutable per-DSO globals.
- First-class function values are `CClosure`s (upvalue 0 = `_mod`, then a type tag, the native pointer, and one upvalue per captured variable); anonymous functions/closures and `obj:method` **bound methods** are supported as values. A captured-and-mutated local is stored in a **box** so all sharers mutate one cell. A box is a Lua *userdata* (not a CClosure): a userdata's GC traversal calls `genlink`, so an overwriting write can use the back barrier (`luaC_barrierback`) without floating fresh values to the old generation — which a `CClosure`/forward-barrier box would (`traverseCclosure` does not call `genlink`). Two forms, chosen by `not types.is_gc(typ)`: a 1-user-value `Udata` holding a `TValue` written with `luaC_barrierback` (GC-typed values), or a 0-user-value `Udata0` holding the raw non-GC C scalar inline via `getudatamem` (no tagging, no barrier). Boxes are module-internal (never cross a module boundary), so the representation is not part of the ABI.
- Generated C must follow the style contract in `pretty.lua`'s header (K&R braces, `/**/` comments never after `{`, braces mandatory) — `reindent_c` is purely heuristic.
- Module resolution is binary-first for dependencies. A dependency with no
  claiming prefix/exact provider but available flat/folder source is compiled
  in and statically linked; a binary dependency's selected provider is
  dlopened at runtime by the generated `_init`.
  Explicit `titanc` roots are forced through source, so the same ordinary rule
  builds all seven standard roots from source in one process. There is no
  separate standard-module origin or loader. Within one source root folder beats flat; source roots retain
  left-to-right precedence. Once an immediate constituent is recognized as
  private to its parent folder module, do not fall through to a later root;
  all binary candidates were already considered, and a genuine requested deeper
  folder was already considered first. Every compiled module exports
  `luaopen_<mangled>`, `<mangled>_init`
  (idempotent), `<mangled>_abi` (returns `TITAN_VER`; checked before trusting a
  `.so`), and `<mangled>_types` (serialized interface type, evaluated with
  `types.lua` as env). For an explicit root, `titanc` gives code generation the
  complete invocation-wide source-module set so every linked peer is wired
  directly while compiled dependencies stay dynamic. Library mode derives one
  provider from the requested roots, sorts/deduplicates that source-object
  union, and emits one shim per logical source module.
- Installed and checkout driver modes both link `libtitan.a`, never
  `titan.o` directly. The installed path is `<root>/lib/libtitan.a`; checkout
  mode lazily rebuilds and links `titan-runtime/libtitan.a`. The archive
  contains exactly `titan.o`, `titan_coro.o`, and `titan_uv.o`. The vendored
  `libbacktrace.a` is a separate link input. `titanlib.c` is compiled into
  `titanlib.o`; that object alone forms the private support bootstrap and is
  passed once into the full combined standard `titan.so`. Its public
  `backtrace`, internal testing helpers `pin`/`clear`, compiler-only lazy/local
  `_loadlib`, and shim-facing canonical-path lazy/global `_loadlibglobal` are
  not part of the generated-code archive. Bare logical module `titan` is
  reserved in library mode, and a physical provider named `titan` must pass a
  fresh-process support-table validation before publication.
- In `minicoro.h`, sanitizer detection must remain before the public
  `mco_runtime`/`mco_coro` declarations. Gate ASan and TSan bookkeeping fields
  with their matching feature macros so ordinary builds carry no sanitizer
  words, and compile every translation unit sharing those layouts with the
  same sanitizer configuration.
- **Operand expressions are not auto-hoisted: a template that references one more than once multiply-evaluates its side effects.** `codeexp` returns `(stats, expr)` and for a non-GC return `codecall` puts the bare call *in `expr`*, not in `stats` — so a `render` template that splices an operand into several slots (as the naive integer `//`/`%`/shift templates did) calls a side-effecting operand like `f() // g()` multiple times, unlike Lua which evaluates each once. Materialize each operand into a temp first (the pattern in `codebinaryop`'s `and`/`or` arms, the shift/idiv/mod helpers, and the mixed int/float comparison branch).

### C FFI (`c-parser/`, `foreigntypes.lua`)

`foreign import "header.h"` invokes a pure-Lua C toolchain: `cpp.lua` (full hand-written preprocessor; asks the configured `CC -std=c99` plus parsed `TITAN_EXTRA_CPPFLAGS` for system include paths and predefined macros), `c99.lua` (relabel C99 grammar; module-global typedef table, not reentrant), `ctypes.lua`/`cdefines.lua` (build a TypeList), and `cdriver.lua` (include resolution plus C type extraction). The checker passes the importing Titan source directory and the shared toolchain configuration to `cdriver`, which emits quoted `#include "..."` syntax only when the header is found by the quoted-include rules relative to that source; otherwise generated C uses angle brackets. `cdriver` also exposes `titan-runtime/titan/ffi.h`, which defines selected `titan_ffi_*` aliases for portable C primitive types.

`foreigntypes.convert` maps C declarations to the `Type.C*` family (`CVoid`, `CInteger`, `CFloat`, `CPointer`, `CArray`, `CStruct`, `CUnion`, `CFunction`, `CTypedef`, `CModule`, and owned storage wrappers). C imports are namespaces, not first-class values: the checker represents them as `Type.CModule` (renamed from the prototype's foreign-module type), typedef-qualified names such as `c.T` may be used in local annotations, and `types.serialize` rejects any exported function/method/variable type that mentions a C FFI type. C aggregate fields, C array indexing, `#` on static arrays and counted owned buffers, and explicit C vararg calls are implemented; C array indexing is 0-based, bounds-checked for `CArray` and counted `COwned`, and null-checked but otherwise unchecked for raw `CPointer`.

Owned C objects are Titan-owned Lua userdata payloads allocated by the generated `.new()` and `.new_array(count)` pseudo-functions on C types. They are zeroed, anchored on the Lua stack during initialization, stamped with a per-owned-C-type metatable for `value` cast checks, and need no finalizer because the Lua GC owns the payload; dynamic array counts are reconstructed from `Udata.len`. Allocation rejects `void`, incomplete aggregates, C array typedefs, and structs/unions with flexible array members in this iteration. `CAdopted`, C callbacks/function pointers, and stronger Lua C API coverage are parked follow-ups. `c-parser/typed.lua` (used only by c-parser) is a runtime signature-checking DSL that ships **disabled** — `typed.off()` is the last line; flip to `typed.on()` to debug c-parser type confusion.

## Test suite notes

- `spec/coder/coder_spec.lua` is end-to-end: it generates C, compiles with
  the real `cc`, and runs the result under `$PREFIX/bin/lua` via `io.popen`
  (the shared helper retains compatibility fallbacks for older trees).
  Artifacts (`test.c`, `test.so`, `./test`, `*.o`) land in the repo root;
  `after_each` and the shared application helpers clean them. These cases
  consume the prepared runtime archive; only the serial coroutine suite may
  invalidate it inside its explicit preserve/rebuild/restore boundary. Set
  `helpers.verbose = true` in `spec/support/helpers.lua` to see `cc` command
  lines and keep generated `.c` files.
- The **`.so`-only import path** (a dependency reachable only as a compiled shared library, not `.titan` source) has dedicated coverage: `spec/coder/so_import_spec.lua` (end-to-end: dlopen + ABI check + dlsym, cross-module function/variable/record use incl. transitive `.so`→`.so` chains, and the first-class fast path across the `.so` boundary) and `spec/checker/so_rehydration_spec.lua` (the typechecker checking `<mangled>_abi` then rehydrating function/record/variable/first-class-function types from the serialized `<mangled>_types` symbol). Both build each dependency `.so` *from memory* so its `.titan` source never reaches the source path, forcing `driver.defaultloader` down the `.so` route; `build_so_chain`/`so_check` assert the dep was resolved dynamically, not statically linked. A module's interface may *reference* a record defined in a module it imported but that the importer does not import directly — `checker.checkimport` recovers those transitively-referenced record modules so their nominal types still resolve.
- `cpp_spec.lua` is the only coverage for the FFI preprocessor (`c-parser/cpp.lua`), and runs **without** the C toolchain: its `expand` helper drives `cpp.parse_file` with a hand-built `ctx` (empty `defines`/`incdirs`) so the `gcc`/`cpp` shell-out is skipped, and wraps each expansion in a Lua instruction-count `debug.sethook` so a regression that reintroduces unbounded macro recursion fails loudly instead of hanging the suite. The recursion-guard cases pin the C "no recursive expansion" rule — keep them when touching macro loop detection.
- Test helpers that touch the checker/coder must reset shared state first: `types.registry = {}` (and `driver.imported = {}` where imports are involved) — see `run_checker`/`run_coder`.
- Parser/checker specs compare ASTs with a subset assertion (`restrict` + `assert_is_subset`): only fields present in the expected table are compared, so adding new AST decorations doesn't break existing tests. Follow this pattern.
- `TableFormatLevel` (luassert's table-printing depth) is global across spec files, and post-checker ASTs are self-referential — printing one in a failure diff at unlimited depth hangs busted. `parser_spec.lua` raises the depth in `setup()` and restores it in `teardown()`, but a stray `assert:set_parameter("TableFormatLevel", -1)` in its describe body (runs at collection time) partially defeats this. If a full-suite run hangs while printing a failing diff, that line is the suspect.
