# CLAUDE.md

This file provides guidance to a coding agent when working with code in this repository.

## What this is

Titan is a statically-typed, ahead-of-time-compiled sister language to Lua.
This repo is the prototype compiler, written in Lua, that translates each
`.titan` module to its own C translation unit and invokes the system C
compiler. A no-`main` invocation links all selected source modules into paired
`.so` and `.a` providers named from the requested roots' longest common dotted
prefix and emits one generated Lua shim per linked logical module; when exactly
one requested module defines `main(args: {string}): integer`, it instead
produces a standalone executable bundling all modules. The language reference is
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
  `PREFIX=$HOME/.local/titan/titan-dev`. `make lua` configures Lua 5.5.1's
  `LUA_ROOT` to that prefix while leaving upstream `loadlib.c` unchanged. The
  generated standard-module shims resolve physical `titan.so` through
  `package.cpath`, load bare native support with `require "titan"`, then use
  `titan._loadlibglobal` to map/promote the provider with
  `RTLD_LAZY | RTLD_GLOBAL` before invoking the exact `luaopen_titan_*` entry.
  It builds and installs Lua there
  and copies its matching `.c` and `.h` files to `$PREFIX/src/lua-5.5.1/`;
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
  repeated by that macOS dispatch. The regular Linux flow uses one standard
  `ubuntu-24.04` producer with an explicit 30-minute timeout plus two
  consumers. The build-heavy uv/timer/fs consumer also uses standard
  `ubuntu-24.04` with a 30-minute timeout; the compiler-heavy consumer uses
  1-core `ubuntu-slim` and is subject to that runner's hard 15-minute limit. The
  producer runs the core compiler/language shard plus serial, net/OS, and
  PEG/string/math/Lua/iter/GC tests on its warm tree, and uploads a same-run,
  full-tree tar artifact for the two parallel consumers. The standard consumer
  runs the uv/timer/fs library group without coverage. The slim consumer runs
  the heavy coverage shard:
  `coder_spec.lua`,
  `flexible_returns_spec.lua`, `cdriver_spec.lua`, every checker/coder
  `c_ffi*_spec.lua`, and the static-provider specs that require isolated Busted
  processes for direct coverage. The complete local `compiler` group remains
  the union of both coverage shards. All Linux runner labels remain x86_64
  Ubuntu 24.04, so the prepared native tree crosses only the runner
  size/container boundary, never an OS, architecture, or object target. Each
  shard uploads its explicit report
  through Codecov's GitHub OIDC flow with job-local `id-token: write`; upload
  errors fail the job so coverage publication cannot be silently skipped. The
  Linux core invocation keeps Busted's per-file environments but uses
  `--no-auto-insulate` to reuse one compiler module graph and immutable
  foreign-header probe caches; the complete local and macOS compiler groups
  retain ordinary auto-insulation as the independent state-leak check.
  Disposable Titan fixtures and alternate images in the producer's serial,
  net/OS, and PEG/string/math/Lua/iter/GC groups compile at `-O0`;
  purpose-built native harnesses retain their explicit flags. Generated native
  fixtures in the producer's core compiler group compile at `-O1`, retaining optimized
  generated-C coverage
  without spending the full `-O2` compile cost. Fixtures in the heavy compiler
  consumer compile at `-O0` so optimization of disposable code does not consume
  its 1-core runner budget. The Linux system-mode source-install canary builds
  its installed provider at `-O0`, then its focused tests and production smoke
  use optimized consumers against that provider. The core
  Linux compiler group, the canonical bundled provider packed before those
  tests, its bundled production smoke, and the complete macOS run (including
  both libuv modes) remain optimized. The
  regular producer now prepares a clean ABI-0.21 prefix directly. Its
  dependency cache key includes the active Titan ABI; after restore it runs
  `make lua` and `make luarocks`, removes or replaces only known active-0.21
  Titan-owned rock/direct-shim state, and proves the interpreter's
  `package.cpath` contains `lib/titan/0.21/?.so` but not the 0.20 template.
  Separately versioned ABI-0.20 files remain preserved prior-version state;
  the 0.21 preparation has no cross-ABI migration or cleanup path.
  The historical ABI-0.17-to-0.18 cutover smoke is retired rather than carried
  forward as migration machinery. This does not waive the ordinary manually
  dispatched complete macOS pre-merge gate. The
  sanitizer job keeps its build and focused native-memory gate on one warm
  standard `ubuntu-24.04` runner with an explicit 30-minute timeout:
  representative timer/fs suites, core owner/callback proofs, and production
  net/OS smokes. The redesigned timer/fs suites are small direct-continuation
  behavior gates and run in full in this shard; there is no delayed-callback
  source variant or sanitizer-only filter. Keep ordinary Titan `#line` attribution
  throughout this job:
  the selected `uv_tasks` traceback gate depends on exact user-function
  frames, and `uv_bootstrap` additionally requires a standard-provider frame.
  Use
  `TITAN_NO_LINE_DIRECTIVES=1` only in an isolated diagnostic reproduction,
  not for the complete sanitizer suite. The Linux sanitizer build instead
  gives `rock-post-install` an exact diagnostic snapshot destination. Before
  the private stage is removed, it preserves that stage's sanitized
  `titan.so`, every exact generated standard-library `.c`/`.o` pair from the
  source output paths used for that link, and the
  NUL-delimited generated-C compile-prefix argv. Each sanitizer gate captures
  its original combined output, and only a failure-only diagnostic step reads
  those logs; the failed program and provider are never rerun. The mapper uses
  the original ASan frame's relocation-safe canonical-provider module offset
  and BuildId to find the saved provider function and its byte delta, then
  builds an on-demand shadow for the unique owning translation unit with its
  `#line` directives blanked in place and the exact captured prefix replayed. It
  reports physical generated-C context only after the saved and shadow target
  function bytes match exactly in `.text`, the provider function is in `.text`
  with the saved function's size, and the saved/shadow function names,
  addresses, sizes, and `.text` membership agree. Shadow symbolization is
  explicitly section-relative to `.text` and must return the exact private
  shadow pathname; its line-identical saved C supplies the displayed context.
  Any mismatch leaves the context unavailable instead of guessing.
  This side channel is why normal `#line` attribution can remain enabled for
  the test execution and its required logical Titan traceback frames. Its Lua,
  libbacktrace, and libuv dependencies compile with sanitizer instrumentation
  at `-O1`, while the much larger generated Titan images and disposable test
  fixtures use the same instrumentation at `-O0`; optimizing those generated
  translation units can consume the complete runner limit without improving
  the memory-safety gate. Keep full library behavior suites in regular Linux
  unless they exercise a distinct sanitizer-sensitive boundary. Keep each
  Linux dependency build in the job that consumes its warmed tree, and keep
  the Linux production mode smokes in the regular producer: rebuilding them
  in a consumer wastes aggregate billed runner time even when the workflow's
  wall-clock critical path is unchanged. The cold manual macOS job retries
  only its runtime and test dependency-acquisition commands inside the same
  prefix, so successful partial LuaRocks installs survive transient download
  failures; keep the actual Titan build and complete test suite single-shot.
  After the system-mode source-rock
  reinstall, rerun only the mode-dependent SDK-layout and external-DSO
  promotion cases from `rockspec_spec.lua`; the complete bundled packaging
  gate has already run, and repeating it would consume the producer's
  remaining job budget without adding system-policy coverage. The full
  system production smoke still follows those focused assertions. Pack the
  regular artifact before the mode smoke replaces the bundled
  `titan.so`/`titan.a` pair, but upload it only after both modes pass; repacking
  the system-linked tree changes every
  logical standard module at once and shifts
  recompilation into a consumer. The full-tree archive is intentional because
  partial output archives lose source/output timestamp ordering and trigger
  Make rebuilds; it also preserves the prepared Lua installation, executable
  bits, and standard-library images. Run the serial, net/OS, and
  PEG/string/math/Lua/iter/GC
  library groups before core compiler coverage in that producer. The
  `rockspec_spec.lua` layout-publication case copies the already validated
  installed pair and
  shims into a private stage before rerunning the real publisher; it must not
  invoke the build-dependent `install-stdlib` target and recompile all seventeen
  roots in the same bundled configuration. Use `publish-stdlib` with an exact
  `STDLIB_INSTALL_STAGE` instead. Legacy compiler specs still clean
  root-generated module outputs, so keep the packaging gate first. The
  complete macOS flow likewise runs the library
  group before its uncovered compiler group. Its compiler gate also exercises
  x86_64/arm64 universal Mach-O archive lookup and repackaging; keep that real
  macOS proof in the one pre-merge manual dispatch rather than replacing it
  with a host-only synthetic check. CI snapshots and restores the prepared
  runtime artifacts, canonical installed `titan.so` and `titan.a`, conditional
  dSYM, and all seventeen generated shims around the producer's compiler-only
  group so root output cleanup cannot stale or remove the production image
  before the mode smoke. The two consumers use independent restored trees, and
  the compiler consumer has no later production-image dependency, so it need
  not snapshot and restore the standard image around its shard. Compiler and
  language specs must not
  delete the shared checkout runtime archive merely to force recompilation;
  Make owns that dependency state. The serial coroutine suite is the isolated
  exception described below.
- **A local Titan prefix prepared by `make lua`.** The checkout keeps the
  gitignored `./lua-5.5.1` build tree, while the installation contains the
  same internal sources, including the configured `luaconf.h`, under
  `$PREFIX/src/lua-5.5.1/` and the
  matching `$PREFIX/lib/liblua.a`. Generated C includes Lua internal headers
  (`lobject.h`, `lgc.h`, `lvm.h`, ...) from that installed source tree and
  links the matching archive. That `luaconf.h` is also the public configuration
  used when this LuaRocks builds other Lua libraries and Titan packages.
  `make lua` uses `MYCFLAGS=-fPIC` and selects `linux-readline`/`macosx`
  from `uname`; override with `make lua LUA_PLATFORM=...`, and use `LUA_CC`
  for Lua's compiler. It compile-links a host Readline probe first. When the
  development header/library is unavailable, it verifies and builds pinned
  GNU Readline 8.3 patchlevel 3 as a static prefix-local dependency using the
  same `PREFIX`, `LUA_CC`, `AR`, and `RANLIB`;
  `READLINE_MODE=system|bundled` can override automatic selection. Its
  checksum-bound repair path builds and validates a sibling stage before
  replacing an existing private installation. `READLINE_HOST` supplies an
  optional Autoconf cross-target triplet; the `READLINE_*FLAGS` inputs are
  recorded alongside the native tools. Its configuration stamp cleans Lua
  objects whenever `PREFIX`, `LUA_PLATFORM`, `LUA_CC`, a native-build input,
  or the selected Readline provider changes.
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
  The pinned, privately namespaced LPegLabel build produces
  `lpeglabel-build/libtitan-lpeglabel.a` with exactly `lplcap.o`, `lplcode.o`,
  `lplprint.o`, `lpltree.o`, and `lplvm.o`. It is standard-provider payload,
  not a runtime-SDK archive: neither it nor its private headers are installed.

  SDK staging atomically places the bootstrap at
  `$ROCKS_TREE/lib/titan/0.21/titan.so` only when the path is absent. It
  validates and preserves an existing usable bootstrap or full image, and
  refuses to clobber an incompatible file; a repeated build must never shrink
  a full image back to bootstrap form. After LuaRocks deploys the compiler, the
  source-only `post_install` hook invokes the just-installed `titanc` once with
  all seventeen roots and a shared `-X` payload beginning with `titanlib.o` followed
  by the private namespaced LPegLabel archive. The
  standard sources are
  `titan/coroutine.titan`, the explicit seven-file `UV_TITAN_SOURCES` folder
  ensemble, `titan/{async,timer,io,fs,net,ssl,url,os}.titan`, the explicit
  `titan/http/` folder ensemble, and the explicit
  `titan/peg/` and `titan/string/` folder ensembles, plus
  `titan/{math,lua,iter,gc}.titan`. Each logical module
  remains independent, but the physical outputs are the paired `titan.so` and
  self-describing `titan.a`. In bundled mode the pinned private `libuv.a`
  follows the LPegLabel archive in that same `-X` payload, followed by the HTTP
  adapter and private llhttp archive, then the bundled OpenSSL archives used
  directly by `titan.ssl`. The compiler force-carries all bundled payload into
  the DSO and flattens it into the archive. In system mode the LPegLabel
  archive, HTTP adapter, and private llhttp archive remain present while
  pkg-config's ordered libuv and OpenSSL results remain final-link inputs, must
  be repeated by static consumers, and are never copied into `titan.a`.

  The hook builds in a private destination-filesystem stage, validates eighteen
  `luaopen_*` entries and all seventeen logical protocols, requires exactly seventeen
  embedded archive keys, and compares embedded ABI/types with both the staged
  DSO and a fresh-process archive-backed validation image before checking the
  seventeen generated shims and macOS dSYM. It then runs the source-only
  `scripts/stdlib_installer.lua` under the same effective `CC`, `AR`, `RANLIB`,
  `TITAN_EXTRA_*`, `TITAN_ROCKS_ROOT`, and runtime-prebuilt environment for
  recoverable publication. The script is not part of the installed compiler
  modules. It recognizes bootstrap-only and current complete-pair predecessor
  states; backs up the
  exact current DSO/archive/dSYM/shims and stale active-layout copies; commits
  shims and dSYM, then `titan.a`, and renames `titan.so` last. Caught errors and
  injected archive/DSO failpoints restore the exact supported predecessor. This is
  not crash-, power-loss-, or asynchronous-signal-atomic publication. The
  canonical artifacts are `$ROCKS_TREE/lib/titan/0.21/{titan.so,titan.a}`, the DSO's
  macOS dSYM, and generated
  `$ROCKS_TREE/share/lua/5.5/titan/{coroutine,uv,async,timer,io,fs,net,ssl,url,http,os,peg,string,math,lua,iter,gc}.lua`.
  No symbolic links, hard links, child DSOs, or `lib/lua` compatibility copies
  are used, and separately versioned 0.17/0.18/0.19/0.20 trees are not purged,
  migrated, or cleaned up. These direct
  SDK/stdlib files remain outside the rock manifest and are not removed by
  `luarocks remove`; binary-rock ownership is deferred until Titan has a
  library/application packaging story. The
  rockspec declares `test_dependencies` (busted, cluacov) plus a
  `test = { type = "busted" }` block, so `luarocks test` installs those and
  runs the suite. `luarocks test` does **not** build the rock-under-test, so
  `make test` runs `luarocks make` first.
- **C toolchain**: `CC` (default `cc`) for compilation and for the C FFI's
  predefined-macro/include-search probes, plus `AR` (default `ar`) and
  `RANLIB` (default `ranlib`) for every generated static provider. All three
  may be configured command strings, are parsed into argv, and must remain the
  same tools recorded by the prefix's LuaRocks configuration through source
  build, post-install validation, and later consumer builds. The archive
  builder prefers deterministic `ar qD`/`ranlib -D`, falls back to portable
  `q`/ordinary `ranlib`, and then rescans the regular output and exact ordered
  member manifest; do not infer success from tool exit status alone. The FFI
  uses the same C99 mode and parsed `TITAN_EXTRA_CPPFLAGS` as generated C. The
  authoritative object target comes from the first generated module object,
  not `uname`, because `CC`/`TITAN_EXTRA_CFLAGS` may select another target; all
  other source, selected-provider, and `-X` objects must match it. The probe is
  POSIX-only today (`/dev/null`, `LANG=C`). A system Readline development
  package is optional: when its compile/link probe fails, `make lua` builds the
  pinned, officially patched source fallback inside `PREFIX`. Bundled native
  dependencies need CMake for libuv, Perl for OpenSSL, tar, a downloader
  (`curl` or `wget`), and `sha256sum` or `shasum`.

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

Canonical full-suite validation must also start without ambient
`ROCKS_TREE`, `TITAN_ROCKS_ROOT`, `TITAN_EXTRA_CPPFLAGS`, or
`TITAN_NO_LINE_DIRECTIVES`. Those variables change provider/root selection,
every generated fixture's C preprocessing, or source-line attribution;
`make test` deliberately clears Lua module-path overrides, but it does not
erase these explicit build-policy inputs.

```sh
make lua                                            # build/install prefix-configured Lua and matching source headers
make luarocks                                       # build/install LuaRocks for that Lua
make lpeglabel                                      # build/validate private five-member PEG payload
make libuv                                          # build pinned static PIC libuv (bundled default)
make openssl                                        # build pinned static PIC OpenSSL (bundled default)
make llhttp                                         # build/validate private three-member HTTP parser payload
"$PREFIX/bin/luarocks" make                        # build/install Titan runtime, compiler, and stdlib
make stdlib                                         # checkout-only titan.so/titan.a standard pair plus seventeen generated shims
make test                                           # `luarocks make` + `luarocks test`: (re)install the rock, then run the full suite
luarocks test                                       # test an already current install; with its bin on PATH, PREFIX/ROCKS_TREE are not required
luarocks make && bash spec/support/ci_test_groups.sh compiler  # CI's covered compiler/language group
bash spec/support/ci_test_groups.sh libraries       # CI's complete uncovered library group
make clean                                           # remove generated artifacts; `make distclean` also removes downloaded Lua/Readline/LuaRocks/libbacktrace/libuv/OpenSSL/llhttp trees

busted                                              # full test suite — MUST run from repo root (all driver paths are relative); busted recurses into spec/ subdirs
busted spec/parser_spec.lua                         # single spec file
busted spec/coder/coder_spec.lua --filter='for loop' # single test (Lua pattern on test name)

./titanc [--print-ast] [-v] [--static] [--no-line-directives] \
  [--lua <luasrc>] [--tree <srcroot>] \
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
full outside coverage. The repository `.luacov` limits debug-hook collection
to the same compiler, root-spec, and `titanc` paths emitted by CI's explicit
report command; keep those filters aligned. If a library suite exposes a
compiler coverage gap, add a small focused compiler/checker test for that code
path instead of covering the library integration suite.

**Spec layout.** Pure, layer-level specs live at `spec/` root (`abi_spec`,
`cdriver_spec`, `cpp_spec`, `ctypes_spec`, `driver_spec`,
`foreigntypes_spec`, `lexer_spec`, `location_spec`, `parser_spec`,
`staticmetadata_spec`, `symtab_spec`, `types_spec`, `util_spec`); serial
native-build and packaging
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
Type-relation laws and truth tables live in `spec/types_spec.lua`; checker
plan/rejection cases live in
`spec/checker/type_relations_soundness_spec.lua`; generated-C and runtime
boundary parity lives in `spec/coder/type_relations_soundness_spec.lua`.
Both topical soundness specs remain in the covered compiler group.
Union syntax/token coverage remains in `spec/parser_spec.lua` and
`spec/lexer_spec.lua`; checker/frontier/type-rejection coverage lives in
`spec/checker/unions_spec.lua`; generated representation, dispatch,
catch/finally/defer, Lua, first-class, and GC behavior lives in
`spec/coder/unions_spec.lua`; and hostile serialized-schema validation lives
in `spec/union_interface_spec.lua`. Source/DSO/archive/prefix-container union
coverage extends the existing compiled-module specs rather than duplicating
their provider scaffolding. The regex-AST dogfood remains standard-library
behavior under `spec/stdlib/string_regex_spec.lua`, outside LuaCov.
Folder-source resolution, blocking, composition, and cross-file diagnostics
belong in filesystem cases in `spec/driver_spec.lua`; public compilation,
artifact, external-`--tree`, and mixed-source traceback behavior belongs in
`spec/coder/folder_modules_spec.lua`. Keep uv runtime behavior in the existing
non-LuaCov stdlib suites.
Prefix-container public compilation and generated-shim behavior live in
`spec/coder/multi_module_libraries_spec.lua`; native support-loader mode and
promotion behavior live in `spec/stdlib/loadlibglobal_spec.lua`. Keep the
root-major provider/metadata-claim matrix in `spec/driver_spec.lua`.
Static-provider coverage is intentionally split: bounded ELF/Mach-O/archive
and synthetic universal-container parsing belongs in
`spec/staticmetadata_spec.lua`; format preference, occupied-path behavior,
archive claim/error rules, caching, and source fallback belong in
`spec/driver_spec.lua`; direct/dynamic nominal-owner constraints belong in
`spec/checker/static_compiled_modules_spec.lua`; target derivation, `-X`
classification, archive construction/tool wrappers, and archive-backed native
validation belong in `spec/coder/static_compiled_modules_spec.lua`; and paired
publication, physical composition, rollback, and the real macOS universal
archive gate belong in `spec/coder/multi_module_libraries_spec.lua`.
Canonical stdlib pair ownership stays in `spec/libuv_build_spec.lua`,
`spec/rockspec_spec.lua`, and `spec/stdlib_installer_spec.lua`; production
bundled/system static smokes stay in
`spec/support/ci_libuv_mode_smoke.sh`.

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
combined `titan.so`/`titan.a`, generated standard shims, and the private libuv
archive as
read-only. These helpers may not clean
or rebuild shared root artifacts during Busted.
Helpers pull in luassert explicitly (`require 'luassert'`) because a
`require`d module does not inherit busted's `assert` global. Set
`helpers.verbose = true` (was a per-file `local verbose`) to print `cc`
command lines and keep generated `.c` files.

New or modified specs that generate compiler fixtures in the repository root
must remove only their exact module artifacts, including the paired `.a` for a
no-`main` compile, and must treat
`titan-runtime/libtitan.a` as shared Make-owned state. The grouped CI commands
also snapshot and restore the prepared runtime, combined standard-library
DSO/archive/dSYM, and generated shims around legacy compiler suites that still
clean root artifacts; later
production smokes deliberately consume that restored image.

The serial `spec/stdlib/coroutine_spec.lua` suite temporarily exercises an
isolated exact-provider path, but must restore the prepared runtime, complete
production `titan.so`/`titan.a`/dSYM, generated coroutine shim, and mtimes in
teardown so a later packaging test does not rebuild the whole standard
library. It is the one surviving standard-library source-rewrite exception:
one variant deterministically forces GC in the otherwise inaccessible native
resume-to-transfer-root window, and a second interposes Lua stack operations
to prove the otherwise inaccessible `lua_checkstack` failure path restores the
exact stack. Both require unique anchors, build isolated coroutine providers,
and must disappear if those boundaries become directly injectable. This
exception does not authorize source rewriting in `titan.uv` tests.

Async standard-library behavioral specs compile against the canonical
production modules. Keep them centered on public callback-continuation
behavior: one outer loop, captured Task outcomes, independent one-shot
requests, one waiter plus buffered state for multi-shot handles, Task-local
uncaught errors, and final Runtime cleanup. Do not recreate the retired
`uv_states`/`uv_late_callbacks` source variants, delayed-callback transformers,
generation fencing, scheduler-owned joiner lists, Titan-side operation queues,
or reentrant loop scenarios. Public `async.join*` coverage belongs here: those
functions scan their fixed named operands, install per-operand Task terminal
listeners, suspend once, and remove every registration in `defer`; they do not
add a scheduler join protocol or collect operands into a Task Array. Terminal
publication stores the final `TaskStatus`, detaches the listener Array as a
stable snapshot, installs an empty live list, then invokes the snapshot
sequentially on the main thread with per-listener empty catches. A
deciding listener calls `Task:resume()`, which synchronously installs one
coalesced target-owned zero timer. Its `timer_cb` submits `uv_close`, and only
`close_cb` resumes the target. The same wake must handle external cancellation
of an explicitly suspended Task, and `resume()` must work from either terminal
notification or another running Task without resuming inline. Coverage must
prove `async.running`, explicit suspend/resume, listener order/error isolation/
removal including removal during delivery, cancellation-time defer cleanup,
coalescing, and close-before-resume.
HTTP idle-timeout coverage must preserve its ownership asymmetry: reader-win
paths cancel and detach the timer-only deadline, while deadline-win paths
cancel and join the reader before parser/connection/TLS-busy teardown.
Do not introduce a public Waiter, `uv_check_t`, Runtime `uv_idle_t`, Task polling
loop, taskless timer, or exact-next-libuv-iteration promise for this protocol.

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
Compiled-module lookup defaults to `.;<root>/lib/titan/0.21`, with
`TITAN_PATH_0_21`/`TITAN_PATH` overriding it and `;;` inserting that ordinary
default at compile time and run time. For logical `a.b.c`, each compiled-format
pass checks `a.<ext>`, `a/b.<ext>`, and exact `a/b/c.<ext>` path-root-major and
shallow-to-exact. Default lookup completes the `.so` pass across every path
root, then completes the `.a` pass, then tries folder/flat source; `--static`
swaps only the two compiled-format passes and is a preference, not a
static-only or system-linker `-static` option. An existing relative pathname
shadows the same pathname in later roots for that format, and the `.so` and
`.a` occupied-path sets are independent.

A DSO claims a module through its callable `<mangled>_abi`/`_types` pair. Both
absent is a clean nonclaim only for an ancestor; a half claim, open failure,
bad ABI, malformed types, or logical-name mismatch is terminal, and an exact
markerless DSO remains an error. A regular static provider is self-describing:
each Titan-generated ELF/Mach-O object carries one canonical `.titan.meta` or
`__TEXT,__titanmeta` section with exactly one logical ABI/types entry. The
in-process reader rejects thin/nested/raw/unsupported archives, duplicate
logical keys, malformed or incompatible entries, and an exact archive without
the requested key; an ancestor archive without that key is a clean nonclaim.
Universal Mach-O providers must expose identical key/value sets in every
slice, and the driver selects the slice matching the authoritative generated
object target. There is no `.tmm` sidecar and lookup must not shell out to
`ar`, `nm`, `objcopy`, `lipo`, or a linker.

Recovered ABI-0.21 module interfaces use one closed validator for DSO and archive
metadata. Value-facing graphs reject descriptor wrappers (including
`Type.Variant` outside its owning union list); callable `paramnames` must be
dense, unique, and match fixed arity; and union schemas must prove canonical
owner/count/tag ordering, constructor projection, and variant/function/method
namespace separation. Before serialization drops locality, the source
producer validates the exact `types.public_union_projection`, including that
each private/public variant and its synthesized constructor are omitted or
published together.

The selected DSO's relative provider is stored transiently in
`Type.Module.file` and omitted from serialization; generated handle imports
load that exact file through the unchanged lazy/global runtime sequence.
Selecting an archive records static provenance and makes its physical archive
a direct native link input; it does not store the archive path in the public
module type or automatically import every other logical key carried by that
archive. Modules explicitly named on the `titanc` command line remain source
roots regardless of either compiled format.

Standalone ELF links search selected providers once before ordered `-X`
payload, then group `libtitan.a` with those providers at the runtime position.
This ordinary second search resolves runtime references to metadata-free
payload flattened into a provider (notably bundled libuv in `titan.a`) without
force-loading modules or broadly rescanning `-X`; Darwin keeps its continual
archive search. The executable-context protocol probe and the real program
must use the same shared argument builder for this order.

The standard library uses ordinary qualified module names: most source files
are `titan/<module>.titan`, while `titan.uv`, `titan.http`, `titan.peg`, and
`titan.string` use canonical folder mains plus immediate contributors.
`titan.uv` and `titan.http` keep public declarations with their semantic
contributors; `titan.peg` and `titan.string` instead collect their complete
public APIs in the canonical main and require every contributor top-level
declaration to be module-local.
Clean validation invokes all seventeen roots in one compiler process, stages
`<root>/lib/titan/0.21/{titan.so,titan.a}`, and installs seventeen generated shims
below `<root>/share/lua/5.5/titan/`. The archive advertises exactly seventeen
logical metadata keys; its metadata-free payload begins with `titanlib.o` and
the private five-member LPegLabel archive, followed by the selected libuv
payload, the HTTP adapter and private llhttp archive, and the selected OpenSSL
payload used directly by `titan.ssl`. Bundled archives are flattened into
`titan.a`;
system-mode dependencies remain final-link inputs. The DSO exposes those
seventeen protocols plus bare `luaopen_titan` support, for eighteen
`luaopen_*` entries total. `titan.io`
owns the standard Interface vocabulary and high-level I/O helpers.
`import "async"` is parser sugar for `import "titan.async"` (likewise for
`coroutine`, `uv`, `timer`, `io`, `fs`, `net`, `ssl`, `url`, `http`, `os`, `peg`, and
`string`). The `titan.math`, `titan.lua`, `titan.iter`, and `titan.gc` modules
use their qualified names and deliberately add no compiler short-import sugar.
Dependencies resolve binaries before sources; modules explicitly named on the
`titanc` command line are built from source. There is no parallel root
`stdlib/` source tree.

The checker never reorders that combined AST. It premarks ordinary duplicate
winners and annotates `_toplevel_order`, precollects aliases, reserves names,
then visits all imports in AST order, resolves aliases, builds records/unions
and synthesized constructors, collects ordinary callable/initializer
signatures and explicit methods/nominal functions, and finally checks module
variables in AST order before bodies. Nominal owners, aliases, callables, and imports used
outside module-variable declarations are therefore placement-independent. A
module-variable declaration/initializer sees only earlier imports and earlier
module variables, while seeing every other declaration kind. Combined source
order remains authoritative for duplicate precedence, serialized member/slot
order, module-variable initialization, and code generation.

Unions are nominal v1 sum types. `union`, `case`, and `when` are keywords;
every arm starts with `when`. Variant constructors are positional-only,
first-class fixed Titan functions (`paramnames = false`) and use ordinary
nil-fill/surplus adjustment. Imported union visibility exactly follows record
frontiers. Each case arm/else is a full ordinary block with its own
`catch`/`finally`, and the normal recursive `defer` transformation remains
clause-bounded. A `Union?` scrutinee is auto-forced before dispatch; cases are
not required to be exhaustive, and unmatched/no-else is a no-op. For control
flow, a case is non-fallthrough when every `when` arm is non-fallthrough and
either those arms cover every variant of the statically known closed union or
an explicit `else` is non-fallthrough. Imported hidden variants count in the
union's total, so a consumer that cannot name them needs the `else` route; when
all variants are covered, a redundant falling-through `else` is unreachable
and does not defeat the proof.
Record fields and union payloads share `types.has_tvalue_representation`:
ordinary boxed Titan values including functions are legal; direct C
aggregates/arrays/functions/function pointers are not, and only Option recurses.
Titan unions cast only by nominal GC identity to C `void *`, never
structurally to C unions/structs. `Type.Variant` is owner metadata, not a source
type and not valid in annotations, aliases, `as`, or `is`. Contextual
`lexer.CNAME` keeps C selectors/type names spelled with Titan keywords
source-nameable without weakening ordinary `NAME`.

The canonical main controls generated C/object placement, while logical `M`
controls native symbols, metadata, and the generated shim. Thus folder
`foo.bar` writes `foo/bar/bar.c` and `.o`; a single-root library invocation
publishes exact `foo/bar.so` and `foo/bar.a`, while compatible multiple roots
publish their one longest-common-prefix pair. Folder contributors produce no
artifacts or shims. A standalone retains `foo/bar__entrypoint.c` and emits
`foo/bar__main`; it does not emit a provider pair. Flat paths remain unchanged.
`make clean` must remove nested generated `titan/uv/uv.c` and
`titan/uv/uv.o`, the exact known generated archives (`titan.a`,
`examples/{utils,artisanal,sdl_quit}.a`, and
`testfiles/{selection_sort,sieve}.a`), and only the explicitly known generated
standard shims. Never use `*.a`, `examples/*.a`, or another broad archive/Lua
glob that can remove user-authored files.

The stdlib configuration/completion stamps own the provider pair as one build:
they record the archive name, effective `AR`/`RANLIB`, embedded-format/coder
inputs, full `-X` payload, LPegLabel source/archive identity, libuv mode,
platform support, and existing
compiler/source/flag inputs. Every warm `make stdlib` rescans `titan.a` for the
exact seventeen logical keys without changing pair mtimes; a missing or corrupt
archive invalidates completion and rebuilds both forms. CI's
`ci_stdlib_snapshot.sh` saves and restores the installed pair, runtime archive,
dSYM, and shims with content/mode/mtime assertions around legacy compiler
cleanup.
Filesystem source cache entries carry `program_output` (`P` flat,
`P__main` folder); `titanc` and filesystem child compilers must pass it to
`driver.compile_program`. Keep the optional argument's old dotted-name default
for `tableloader` and external callers.

ABI 0.20 gave every Array proxy a second traced user value carrying its
construction-selected Lua-write policy and every Titan function closure a
fixed opaque brand upvalue plus a trailing strict generic entry. The relation
review owned that mechanical path advance, and the Interface layout inherited
0.20 without another bump. The resulting ABI-0.20 release/provider contract
includes both changes; the intermediate
relation-only and Interface-only layouts were validation artifacts and were
never independently publishable.
The current compiled-module ABI version is `0.21`. It retains those layouts
while advancing the embedded Lua contract from 5.5.0 to 5.5.1. `TITAN_VER`,
`_0_21`, `TITAN_PATH_0_21`, `lib/titan/0.21`, and `stdlib_0_21` advance
together; a 0.20 provider is rejected before its type metadata is decoded.
There is no 0.20-to-0.21 migration or cleanup path; any separately versioned
0.20 tree remains preserved prior-version state.
`0.19` itself was bumped from `0.18` when serialized union/variant schemas and
userdata/tag dispatch extended the importer-reconstructible public module-slot
prefix with exported statics of each public record/union. This preserves
canonical first-class imported constructors and nominal functions.
`0.18` itself was bumped from `0.17` when libuv callback trampolines used
directly by generated standard-library objects entered the runtime's external
native symbol contract and references to replaced libuv/coroutine helpers
left it; either direction of a 0.17/0.18 static pairing is incompatible.
`0.17` itself was bumped from `0.16` while exact Array signatures remained
`Table *`/`Table **` and serialized Array type text stayed unchanged: key `0`
became reserved for the canonical proxy, `lenhint` became authoritative,
positive values stopped falling back to the hash, and Lua/`value`/raw-Map
boundaries began exchanging proxies instead of backing Tables. ABI 0.16 code
can violate each invariant, so 0.16 providers are incompatible. `0.16` itself
was bumped from `0.15` because
generated/imported physical DSO resolution records a selected prefix container
and the then-new canonical standard layout was one `titan.so` plus shims, even
though per-module serialized types and native signatures were unchanged; the
later paired static provider remained ABI 0.16 because its embedded section
repeated the unchanged ABI/types protocol as an artifact contract and
supported same-ABI migration from a DSO-only 0.16 installation; `0.15` itself
was bumped from `0.14` when the
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
native `_fn` closure parameter). `.so`/`.a` providers built by an older Titan are
incompatible. `-v` prints the exact `cc` command lines. Without the prepared
Lua 5.5.1 installation, only the pure specs pass (cpp, lexer, location,
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

Titan Arrays are a deliberate exception to ordinary Lua Table semantics.
Their exact/internal value remains a backing `Table *`; exact
variadic/flexible descriptors therefore remain `Table **`. The backing hash
key `0` owns one canonical zero-payload/two-uservalue proxy Udata. Public
uservalue 1 (internal `uv[0]`) owns the backing; public uservalue 2 (internal
`uv[1]`) owns the construction-selected, type-directed Lua-write `CClosure`.
Positive elements live only in the array part, `asize` is capacity, and
`lenhint` is the explicit
highest-present-positive length (zero when `asize == 0`). Typed reads use
`getArrTag`/`arr2obj`; typed writes use `obj2arr` plus a backward barrier on
the backing Table. A resize must save and restore the explicit length. Reads
below 1 return nil before conversion; writes below 1 error before mutation.
Lua, `value`, and raw-Map storage see only the canonical proxy, while typed
slots and exact calls see the backing. A non-nil Lua `__newindex` write invokes
the carried writer and mutates only after its dynamic coercion succeeds; nil
deletion bypasses the writer and preserves the allocation-free beyond-capacity
no-op. Typed Array/Map reads use strict gradual guards, including the sanctioned
backing/proxy normalization for nested Arrays. Maps have no writer or
write-provenance channel, so every typed Map read stays strict regardless of
where the stored value originated. `value`, alternate Array views, imports,
returns, and nested boxing preserve the same proxy and writer; none compares
or replaces writer identity. Do not query the registry or load a
proxy/uservalue to address the outer Array, and do not treat the writer as a
runtime element-type tag.
Both direct and `titan.uv.bootstrap` standalone paths place arguments only at
positive indices, set the explicit length, and pass the proxy to the generated
Lua entry wrapper, which unboxes before calling exact native `main`. The
standalone driver supplies the dedicated construction writer for this
`{string}` Array.

Every generated module owns one private, ABI-visible user-value slot caching
the per-state shared Array proxy metatable and one private cached writer slot
for each structural Array element type it constructs. Writer selection uses
the constructor's final context-adjusted element type. Writers are
module-local, capture that module's `_mod`, and are never globally registered,
interned, or selected through a first-wins protocol; proxy to writer to module
   is a traced ownership path. Populate the metatable immediately after
   registry-anchoring the module. Populate the selected writers after imported
   modules, globals, record metadata, and function tags, but before this module's
   variable and root initializers can construct or box an Array. Runtime
   construction roots the writer, backing, and proxy until both cycle edges,
   both user values, and all barriers exist. Direct
debug-library or C-API mutation of either private proxy user value opts out of
Titan's invariants; ordinary generated code does not defensively recheck the
writer slot. Specs that need capacity/hash/GC evidence belong in
`spec/dense_array_runtime_spec.lua`; language/checker behavior belongs in the
topical dense-Array specs. A Titan Array is table-like but not a Lua table:
stock Lua 5.5 `table.*` accepts its proxy through raw `__index`, `__newindex`,
and `__len`, while `rawget`, `rawset`, and `rawlen` reject it. Do not add
caller-identity tricks or patch Lua to change that consequence.

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
through one staged provider bundle, and builds a flattened archive from the
same logical/native payload. It validates embedded, DSO-callable, and
archive-backed logical protocols, then transactionally publishes shims/dSYM,
the `.a`, and the `.so` last. Standalone mode remains the all-source executable
path and emits no pair. `TITAN_EXTRA_CPPFLAGS` precedes the defaults and is
shared with foreign-import probes, `TITAN_EXTRA_CFLAGS` is compile-only, and
ordered `TITAN_EXTRA_LDFLAGS` is final-link-only rather than copied into a
provider archive. Type/load errors are all reported before codegen.

### The `_tag` / typedecl convention (cross-cutting)

AST nodes (`ast.lua`) and types (`types.lua`) are plain tables created by `typedecl.lua` constructors: positional, arity-checked args producing `{_tag = "Ast.ExpCall", ...}` / `{_tag = "Type.Integer", ...}`. All dispatch is string comparison on `_tag`. `util.make_visitor` **asserts** a handler exists per tag — adding an AST tag means updating every checker visitor (`checkstat`/`checkexp`/`checkvar`/`typefromnode`/toplevel) and the coder's if/elseif chains; adding a Type tag means auditing `types.tostring`, `equals`, `normalize`, guardability/`gradual_guard`, `consistent`, `coercion`, `dynamic_coercion`, `written_cast`, `comparable`, `callable_adjustment`, `assignment_adjustment`, and `serialize` by hand. Group names in `ast.lua` (Exp, Stat, ...) are documentation only — they don't appear on nodes.

### Frontend (`lexer.lua`, `parser.lua`, `syntax_errors.lua`)

Lexing and parsing are fused in one LPegLabel/relabel grammar; `lexer.lua` exports raw LPeg patterns referenced as `%TOKEN` terminals (no token stream). Every AST constructor is auto-injected into the grammar's defs table, so grammar actions like `-> TopLevelFunc` call constructors directly. Every error label used in the grammar (`^Label`, `%{Label}`) or lexer (`lpeg.T`) **must** have an entry in `syntax_errors.errors` or error formatting breaks. The parser is not reentrant (module-global `THIS_FILENAME`, asserted nil on entry). `record` declarations are desugared at parse time into a `TopLevelRecord` plus an adjacent synthesized `new` static marked `_record_constructor`. `union` declarations emit `TopLevelUnion` plus one adjacent synthesized static per variant, marked `_union_constructor`/`_union_variant`; explicit nominal functions carry neither marker. `case`/`when` arms consume the ordinary full block production. `[local] type Name = T` produces a transparent `TopLevelTypeAlias`; it is not a standalone value, but a record/union alias preserves the canonical nominal namespace and its visible constructors/statics. `interface Name ... end` produces a nonempty type-only `TopLevelInterface` with ordered bodyless methods. Short standard-library imports are also parser sugar: `coroutine`, `uv`, `async`, `timer`, `io`, `fs`, `net`, `ssl`, `url`, `http`, `os`, `peg`, and `string` become the ordinary qualified module names under `titan.*` before module resolution.

### Checker (`checker.lua`, `types.lua`, `symtab.lua`)

`checker.check(modname, ast, subject, filename, loader) -> moduletype, errors`; callers test `#errors == 0`. Without reordering the AST, it marks ordinary duplicate winners and `_toplevel_order`, precollects aliases and Interfaces, then stages name reservation; imports in AST order; alias resolution; records and unions; Interface descriptors; parser-marked synthesized constructors; ordinary callable/module-initializer signatures; methods and nominal functions; module variables in AST order; and finally bodies. It annotates `_ignore` on rejected duplicates. The checker also annotates (`_type`, `_types` for multi-return calls, `_decl` on variable uses, `_used`/`_assigned`, union case/variant metadata, and checker-owned Interface conversion/adapter plans) and **mutates** the AST:

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
declaration kind sees all imports, nominal owners, aliases, and callables regardless
of relative placement. Body checking and the coder still traverse the unchanged
AST order, as does `makemoduletype`.

- Every ordinary type-directed target sink asks
  `types.assignment_adjustment(source, target)` once. Expression-dependent C
  edges are checker-finalized separately: mutable local/formal address
  formation records its exact coercion before the ordinary classifier, while
  an otherwise unavailable object-pointer reinterpretation records the one
  successful probe-bearing plan afterward. A successful non-identity plan is
  attached either to a synthesized
  `Ast.ExpCast` (`trycoerce`), directly to a same-representation source
  expression, or to the owning callable/open-result adjustment; the coder
  consumes that exact plan and must not rediscover a semantic relation from
  the two endpoint types. `checkmatch` consumes the result already recorded by
  `trycoerce`; it reports an error when no adjustment exists or when a
  representation-changing direct coercion reaches it without an inserted
  cast. Typed Array/Map reads carry `_read_guard`; strict function
  formals/variadics/results carry GuardPlans distinct from genuine-Lua dynamic
  plans; equality carries its symmetric `ComparisonPlan`. A deferred
  positional-constructor open edge is classified only after its final element
  type is known, exactly once, and the sink/producer share that plan. Coder
  lowering validates plan kind, operation, target, and recursive children
  before any representation-specific emitter runs; missing/unknown/mismatched
  plans are compiler errors, never permission inferred from source/target
  tags.
- Keep Titan's type relations separate. `types.normalize` collapses transparent
  alias chains (and rejects alias cycles); `types.consistent` is the pure,
  symmetric, deliberately non-transitive gradual-consistency relation. Titan
  has no general subtyping relation. `types.coercion(source, target)` describes
  one direct automatic conversion (including recursive Option mapping), and
  `types.callable_adjustment(source, target)` describes directional
  function-shape adjustment while requiring aligned component consistency.
  Ordinary conversions such as numeric conversion and `T -> T?` do not lift
  through Array, Map, or Function structure. `types.dynamic_coercion(target)`
  is the canonical policy for genuine Lua inputs/results and written
  `value as/is T`: it recurses through Option, while Array, Map, and Function
  plans convert only the outer boundary. Strict Titan projections and typed
  Array/Map reads instead require `types.has_sound_gradual_guard` and consume
  `types.gradual_guard` plans. Written-only casts use `types.written_cast`;
  equality admission uses the symmetric `types.comparable` relation.
  Raw C pointer to `value` is an automatic lightuserdata boxing conversion;
  direct written `value -> raw C pointer` remains explicitly unsafe, and
  raw-pointer leaves are not dynamically coercible inside Option, Array, Map,
  or Function targets. Record/union to Interface conversion is one
  policy-supplied outer coercion, never consistency, subtyping, or a
  structurally lifted conversion. Both scalar expression types are
  `Type.Nominal`; the cast-site policy callback resolves and validates the
  record/union and Interface owner descriptors plus visibility.
- C numeric boundary checks use the active target profile, including the
  configured `lua_Integer`/`lua_Number` plus authoritative `size_t` and
  `ptrdiff_t` carriers. `sizeof`/`_Alignof` and pointer subtraction retain
  those exact C result types until a checked conversion to Titan `integer`.
  Titan currently validates that signed profile ranges are two's-complement;
  do not reintroduce unchecked carrier casts or host-derived width guesses.
- Extra multiple-return values become synthesized `Ast.ExpExtra` nodes appended to `exps`/`args` lists; for-loops get a default step synthesized into `node.inc`.
- Generic `for ... in` elaborates its iterator tuple into synthesized
  `_init_call`, `_next_call`, and optional `_close_call` nodes. `next` and
  `close` may be Titan functions, `value` callables, or C function
  pointers/direct FFI functions; `value` callables are coerced to a synthesized
  function type from the state/start/declaration list for `next`, and from the
  state for `close`. The first iterator return may be an option, `value`, raw
  `TValue`, or nullable C pointer sentinel; close callables accept zero or one
  state argument.

`checkstat` handlers return a boolean "cannot fall through", stored in the historical `_always_returns` field and used to enforce that functions with fixed nonnil returns cannot fall off the end. Imports go through a `loader` callback (`driver.defaultloader` for real lookup, `driver.tableloader` for in-memory sources in tests); source deps are recursively typechecked, while compiled-provider deps probe the requested `<mangled>_abi`/`<mangled>_types` pair before recovering the interface.

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
`types.registry` (FQTN → `Type.Record`/`Type.Union`/`Type.Interface`;
`Type.Nominal` carries only the FQTN string and resolves through the registry
at every use), `driver.imported`
(import cache with a `CIRCULAR_MARK` sentinel for cycle detection). Tests must
save and restore both together.

### Coder and driver (`coder.lua`, `pretty.lua`, `driver.lua`)

`coder.generate(modname, ast, static_deps, abi, emit_line_directives)` produces
one C translation unit as a string — no C AST, just `util.render` templates (`$VAR`
substitution, recursive; error on missing keys). Key facts:

- Whole-root AST passes use `ipairs` to preserve main/contributor declaration
  order. Keyed interface maps use `util.bytewise_less`; ordered module members,
  record fields, and union variants retain source/slot/tag order. `emitline(node)` remains per-node
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
  ABI 0.17 is the dense-Array invariant/boundary transition; exact pointer
  descriptors and serialized Array type text did not change. ABI 0.18 was the
  runtime/provider native-symbol boundary for promoted libuv callbacks and
  removed libuv/coroutine helpers. ABI 0.19 adds union/variant schemas,
  union userdata/tag dispatch, and the public nominal-static slot prefix. ABI
  0.20 adds the Array proxy's traced writer user value and the strict
  Titan-generic function entry/fixed-brand closure protocol.
- Each generated logical module object contains the canonical serialized
  interface twice: callable `<mangled>_types`/`_abi` entries and one
  relocation-free, byte-aligned metadata section rendered by
  `staticmetadata.lua`. Generated Clang builds exclude that byte array from
  AddressSanitizer instrumentation so a global redzone cannot pad the custom
  section beyond the canonical payload. The section must travel with the same
  object that owns `_init`/`luaopen_`; do not create an aggregate metadata
  member, use archive leaf names as logical identity, or add a sidecar.
  `static_deps` is the finalized native-direct set: all invocation source
  modules plus every logical key physically carried by selected static
  providers. Static imports use direct calls; DSO imports keep handle/global
  paths.
- Coroutine result/error transfer roots the value in the exact source
  coroutine Udata's fifth uservalue through public `lua_setiuservalue`, using
  Titan's existing `Udata *`/`TValue` push bridge after `lua_checkstack`
  succeeds and before the first source `mco_push`. Clear that root only after
  the receiver's successful payload `mco_pop` has refreshed its generated
  stack anchor; the retired native root/clear helpers must not return.

- **Keep public standard-library implementations direct, and audit every
  sibling occurrence of a spotted antipattern.** In `titan.string` and
  `titan.peg`, the canonical main owns both each public declaration and its
  implementation; modules such as `titan.uv` that intentionally give semantic
  contributors public ownership keep each implementation with its declaration
  there instead. Contributors may retain module-local records, state, and
  helpers that are shared or represent genuine recursive, callback, lifetime,
  or other internal machinery. Do not put the complete implementation in a
  sole-use local function when its only caller is a public function that
  forwards the same arguments and results; inline the body and delete the dead
  local. Preserve an adapter closure when its exact callable type pays for a
  repeatedly executed fast path: that is semantic performance machinery, not
  an obfuscating forwarding layer. Likewise, evaluate a pure zero-parameter
  machine/module invariant once in its owning module's final `do ... end`
  initializer and cache it in module-local state; do not apply this to
  factories, mutable-state initialization, locale-sensitive builders, or
  intentionally lazy conditional work. An owned FFI
  `T.new_array(count)` value is already a traced, counted allocation: use it
  directly as a `value`, query it with `#`, and cast it to `T *` without a
  duplicate storage alias or wrapper record. Retain a record when it carries
  distinct logical length, offset/borrowed pointer, asynchronous lifetime or
  type erasure, or related state. Likewise, construct ordinary internal tables
  as typed Titan Arrays or Maps rather than calling `lua_createtable` and
  recovering the result through `value`. If only a Lua metatable operation is
  missing from Titan, declare the table at its actual semantic Array/Map type,
  create its typed metatable in Titan, push those same values through
  `ffi.lua_pushtvalue`, and use only that narrow Lua API operation.
  `lua_setmetatable` mutates the existing table; do not manufacture a
  placeholder Map type, round-trip it through `value`, or recast it afterward.
  A maintainer spot-check of any one of these patterns requires the same
  call-graph audit across the standard library.
- **Apply Titan's existing call adjustment before widening an API.** A
  fixed call fills each missing parameter position with nil and discards the
  values of surplus arguments, including through Lua entry wrappers and
  generic first-class/value calls. Ordinary type checks still apply to every
  nil-filled position, so only a nil-accepting formal observes nil; other
  formals fail at the applicable static or dynamic boundary. Surplus argument
  expressions are still evaluated left-to-right before their values are
  discarded. Only a declared variadic tail collects those surplus values.
  Therefore do not make a function variadic merely to ignore extra arguments:
  if an API observes only the first heterogeneous argument, declare one
  `value` parameter (with omission consequently equivalent to explicit nil).
  Likewise, do not hide a callback in an unqualified `value` when a callable
  type with a fixed prefix, variadic tail, and/or flexible result can express
  its protocol. Reserve unqualified `value` arguments for genuinely dynamic
  unions/dispatch surfaces or opaque Lua objects, not a callback whose
  callable protocol is expressible. Apply the same discipline to results: use
  a fixed option tuple when the semantic protocol has a fixed number of slots,
  even if one branch fills them with nil and callers commonly consume only
  the first. A flexible result tail is for genuinely run-time-variable arity,
  not for preserving the raw result count of a looser source API. Flexible
  returns are contagious through `return callee(...)`: whenever a producer is
  tightened, recursively inspect every return-all forwarder and remove the
  propagated tail until the call graph reaches a genuinely variable result.
  Directional callable adjustment must account for the same shape: extra
  actual fixed parameters are safe only when they accept nil, and, behind an
  expected variadic tail, its element type. A non-exact but consistently
  adjusted Titan callable uses its strict generic entry, so an exact-type
  adapter closure can still be worthwhile when a Titan typed call site will
  invoke it repeatedly; weigh that one-time wrapper against the hot-path
  savings rather than removing adapters mechanically.
  All public standard-library `gsub` operations use the same exact
  `(found: string) -> string` replacement contract and pass the whole matched
  byte string independently of captures. Keep template, capture-index, table,
  and other dynamic replacement forms inside an expression language such as
  relabel syntax; do not overload a public substitution parameter through
  `value` dispatch.
  In `titan.peg`, module-level `match` is the leftmost-search API and returns a
  `Match?` carrying inclusive `first`/`last` plus the genuinely flexible
  capture projection from `Match:values()`; `Pattern:match` remains the
  anchored low-level operation. Do not recreate a position-only `peg.find`.
  Public grammar rules and relabel definitions are dense Titan Arrays, not raw
  Lua tables. PEG labels are exact strings all the way through the native
  engine: empty, numeric-looking, and embedded-NUL labels are not integer
  encodings or sentinel namespaces. The one reserved spelling,
  `throw("fail")`, constructs ordinary PEG failure itself; it must be
  indistinguishable from `fail()` inside choice, repetition, grammar recovery,
  and the final match result. Numeric recovery labels produced by the vendored
  LPegLabel C API remain an internal compatibility detail and must not leak
  into Titan's string-label surface.
- **Use `is` when the question is whether a written cast would succeed.**
  `exp is T` is the nonraising predicate twin of `exp as T`: the checker admits
  exactly the same source/target relation, the operand is evaluated exactly
  once, the result is boolean, and the test does not narrow either branch.
  Prefer it to a raw Lua type probe when cast success is the intended question;
  do not widen the written-cast relation to admit a test. Because a
  direct or Option-composed numeric cast may fail, its `is` lowering must
  consume the same recursive `CoercionPlan`, not treat static admission as
  total. Because a
  function-typed cast from `value` defers callability checking until
  invocation, `value is <function type>` is always true and a noncallable value
  still fails when called. Retain exact raw-subtype probes such as
  `lua_isinteger` only when identity or representation tag, rather than cast
  success, is semantically significant.
- **Treat ABI bumps as clean-start prototype boundaries.** Titan is still a
  prototype, so users are expected to remove stale compiled providers and
  rebuild or start from a fresh installation when the ABI changes. Do not add
  cross-ABI migration, conflicting-file reconciliation, historical-layout
  cleanup, or compatibility machinery unless a task explicitly requires that
  particular transition. This does not weaken same-ABI validation and
  recoverable publication of the current canonical artifacts.
- Each Titan function has **three entry roles**: a raw native-convention entry
  (`RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, params..., input-vararg
  pair, out-params for returns 2..n, flexible-output pair)`; the input and
  output pairs appear only when declared, and the **caller** owns
  flexible-output storage and anchors GC-able values on the Lua stack), a
  coercive Lua-stack entry used by genuine Lua callers, and a strict
  Lua-stack-convention LCF used by branded non-exact Titan calls. One canonical
  `CClosure` remains the function value: its `f` is the coercive Lua entry,
  upvalues 0 through 3 are the owning module, exact function-type tag, native
  pointer, and fixed opaque brand; captures or a bound receiver begin at
  upvalue 4, and the strict LCF is the final upvalue. A strict call passes that
  original closure as a hidden first stack argument so the strict entry can use
  it as `_fn` without creating an adapter identity. Exact Titan calls use the
  native entry; branded non-exact calls guard arguments and results without
  automatic coercion. Non-Titan Lua callables use ordinary Lua dispatch; their
  results entering typed Titan slots use the canonical dynamic coercion. The
  non-exact classifier requires at least five upvalues and compares only the
  raw fixed-brand slot, with no registry lookup or `ttis*` shape checks. `_fn`
  is `NULL` on
  fully-static top-level native calls and the callee itself on
  first-class/closure/value calls. The brand plus strict trailer reduce the
  anonymous-function capture budget to 250, enforced by the checker before
  Lua's `MAXUPVAL` limit. Debug/C mutation or extraction of the private closure
  upvalues opts out of Titan's invariants.

  The uniform `_fn` parameter was ABI 0.6; `_mod`/record `Udata` was 0.7;
  metatable record identity was 0.8; native vararg descriptors evolved through
  0.9 and 0.10; local records, aliases, named arguments, and flexible returns
  were 0.11 through 0.14; the `titan.uv` folder split was 0.15; prefix
  containers were 0.16; dense Arrays were 0.17; the promoted libuv callback
  contract was 0.18; union/variant schemas and the public nominal-static
  closure prefix were 0.19; and the Array writer plus strict function-entry
  closure protocol is ABI 0.20.
- A dynamically imported module is loaded from its transient
  `Type.Module.file` with `RTLD_LAZY | RTLD_GLOBAL` before it is initialized.
  `file` defaults to the exact logical path, is overwritten by prefix-container
  rehydration, and is never serialized. If an imported interface re-exports a nominal record type
  owned by one of its own imports, initialization of the explicit import first
  publishes the owner's method entry points. The importer then resolves those
  transitive symbols through `RTLD_DEFAULT`; it does not open the owner DSO a
  second time.
- Module state is a `Udata` (`_mod`), allocated with `luaS_newudata(L, 0, NUPVALS)`. Its ABI-visible prefix is exported variables, exported top-level function closures, then exported static closures of public record/union owners in module-member and bytewise-static order. Private user values hold imported modules, record/union metatables, per-nominal static-namespace tables, one unconditional per-state Array-metatable cache immediately after that reconstructed prefix, and module-local Array-writer closures allocated once per constructed structural element type; there is no distinguished `uv[0]` header. Publish function-type tags before any module-variable initializer can construct a lambda or bound-method closure, and initialize Array writers before module variable initializers. There is **no** Lua-facing module table — `require` returns the module `Udata` itself (so `type(require "m")` is `"userdata"`), and all member access (functions, variables, nominal namespaces such as `m.Rec`/`m.Union`) flows through a metatable `__index`/`__newindex` over a unified name→slot member map; functions and nominal namespaces are served read-only (assigning errors), variables use the same dynamic boundary coercions as Lua function arguments and Array writes, and the "not found" message is "member '%s' does not exist". A record instance is likewise a single `Udata` (fields in `uv[0..N-1]`, type identity is its metatable pointer, no raw payload); Lua field writes use that same dynamic policy. A union instance is a single zero-byte `Udata` with the union metatable identity, integer tag in `uv[0]`, and optional payload in `uv[1]`; empty variants allocate no payload slot and instance Lua access exposes methods only.
- Typedef-resolved pointers to Lua's internal `Udata` are GC-bearing FFI
  values, not ordinary C pointers: boxing a non-NULL `Udata *` emits a full
  userdata `TValue` for that same object, NULL boxes as nil, and unboxing
  accepts full userdata or nil rather than lightuserdata. Owned C
  pseudo-constructors (`T.new()` and `T.new_array(constant_count)`) are valid
  top-level initializers and keep their userdata rooted in the module state.
- **Semantic state must live in the Lua registry or GC-traced Lua objects, never
  in shared C globals.** Several logical modules may share one physical DSO or
  static provider; once linked, each keeps its own `_abi`, `_types`, `_init`,
  `luaopen_*`, registry module `Udata`, initializer, record identities,
  closures, and file-local native wiring. The ABI-0.21 `titan.so`/`titan.a`
  pair carries all seventeen current logical modules, including the
  `titan.io` Interface vocabulary and high-level I/O helpers.
  `titan.so` is the shared runtime provider and also owns bare Lua support,
  while `titan.a` is the corresponding static payload. Bundled libuv enters
  both through the one reviewed `-X` payload rather than an installed child
  archive. A Titan extension DSO that directly
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
  calls `dlclose`. System mode leaves libuv as pkg-config/user-selected final
  link policy: `titan.a` retains unresolved `uv_*`, a static consumer repeats
  the same setting, and two DSOs may instead bind the same selected shared
  libuv. The private bundled `libuv.a` must never be linked into an extension
  DSO or installed separately.
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
- First-class function values use the `CClosure` layout introduced in ABI 0.20
  and retained in ABI 0.21: `_mod`, exact tag, native pointer, opaque brand in slot 3,
  captures or a bound receiver from slot 4, and the strict LCF last. Anonymous
  functions/closures and `obj:method` **bound methods** are supported as
  values. A captured-and-mutated local is stored in a **box** so all sharers
  mutate one cell. A box is a Lua *userdata* (not a CClosure): a userdata's GC
  traversal calls `genlink`, so an overwriting write can use the back barrier
  (`luaC_barrierback`) without floating fresh values to the old generation —
  which a `CClosure`/forward-barrier box would (`traverseCclosure` does not call
  `genlink`). Two forms, chosen by `not types.is_gc(typ)`: a 1-user-value
  `Udata` holding a `TValue` written with `luaC_barrierback` (GC-typed values),
  or a 0-user-value `Udata0` holding the raw non-GC C scalar inline via
  `getudatamem` (no tagging, no barrier). Boxes are module-internal (never
  cross a module boundary), so the representation is not part of the ABI.
- Generated C must follow the style contract in `pretty.lua`'s header (K&R braces, `/**/` comments never after `{`, braces mandatory) — `reindent_c` is purely heuristic.
- Module resolution is compiled-first for dependencies: one complete
  format-preference pass over `.so`/`.a`, then the other compiled format, then
  source. A dependency with no claiming prefix/exact provider but available
  flat/folder source is compiled in and linked directly; a DSO dependency is
  loaded by generated `_init`, while a static dependency contributes its
  selected archive once and generates direct calls. Explicit `titanc` roots
  are forced through source, so the same ordinary rule builds all seventeen
  standard roots from source in one process. There is no separate
  standard-module origin or loader. Within one source root folder beats flat;
  source roots retain left-to-right precedence. Once an immediate constituent
  is recognized as private to its parent folder module, do not fall through to
  a later root; all compiled candidates were already considered, and a genuine
  requested deeper folder was already considered first. Every compiled module exports
  `luaopen_<mangled>`, `<mangled>_init`
  (idempotent), `<mangled>_abi` (returns `TITAN_VER`; checked before trusting a
  provider), and `<mangled>_types` (serialized interface type, evaluated with
  `types.lua` as env). For an explicit root, `titanc` gives code generation the
  finalized invocation-wide direct set so every linked source peer and
  physically carried static peer is wired directly while DSO dependencies
  stay dynamic. Library mode derives one provider from the requested roots,
  sorts/deduplicates that source-object union, publishes a `.so`/`.a` pair,
  and emits one shim per logical source module.
- Installed and checkout driver modes both link `libtitan.a`, never
  `titan.o` directly. The installed path is `<root>/lib/libtitan.a`; checkout
  mode lazily rebuilds and links `titan-runtime/libtitan.a`. The archive
  contains exactly `titan.o`, `titan_coro.o`, and `titan_uv.o`. The vendored
  `libbacktrace.a` is a separate final-link input; neither archive is copied
  into an ordinary generated provider archive. `titanlib.c` is compiled into
  `titanlib.o`; that object alone forms the private support bootstrap and is
  the first `-X` payload member for the full combined standard pair. It is
  metadata-free but physically carried into `titan.a`, so that archive-backed
  consumers receive its public `backtrace`, internal testing helpers
  `pin`/`clear`, compiler-only lazy/local `_loadlib`, and shim-facing
  canonical-path lazy/global `_loadlibglobal`. Bare logical module `titan` is
  reserved in library mode, and a physical provider named `titan` must pass
  fresh-process support-table validation through both the DSO and an
  archive-backed image before publication.
- In `minicoro.h`, sanitizer detection must remain before the public
  `mco_runtime`/`mco_coro` declarations. Gate ASan and TSan bookkeeping fields
  with their matching feature macros so ordinary builds carry no sanitizer
  words, and compile every translation unit sharing those layouts with the
  same sanitizer configuration.
- **Operand expressions are not auto-hoisted: a template that references one more than once multiply-evaluates its side effects.** `codeexp` returns `(stats, expr)` and for a non-GC return `codecall` puts the bare call *in `expr`*, not in `stats` — so a `render` template that splices an operand into several slots (as the naive integer `//`/`%`/shift templates did) calls a side-effecting operand like `f() // g()` multiple times, unlike Lua which evaluates each once. Materialize each operand into a temp first (the pattern in `codebinaryop`'s `and`/`or` arms, the shift/idiv/mod helpers, and the mixed int/float comparison branch).

### C FFI (`c-parser/`, `foreigntypes.lua`)

`foreign import "header.h"` invokes a pure-Lua C toolchain: `cpp.lua` (full hand-written preprocessor; asks the configured `CC -std=c99` plus parsed `TITAN_EXTRA_CPPFLAGS` for system include paths and predefined macros), `c99.lua` (relabel C99 grammar; module-global typedef table, not reentrant), `ctypes.lua`/`cdefines.lua` (build a TypeList), and `cdriver.lua` (include resolution plus C type extraction). The checker passes the importing Titan source directory and the shared toolchain configuration to `cdriver`, which emits quoted `#include "..."` syntax only when the header is found by the quoted-include rules relative to that source; otherwise generated C uses angle brackets. `cdriver` also exposes `titan-runtime/titan/ffi.h`, which defines selected `titan_ffi_*` aliases for portable C primitive types. Contextual conversions and C operators use one resolver-owned, session-scoped `cprobe.Service`: its compile-only probes share the generated objects' exact parsed `CC`, C99/CPP/target flags, include ordering, and target arithmetic profile. Probe answers and caches do not survive that compilation session or enter the pure gradual-consistency/coercion relations or serialized module types.

Recognized existing object-like integer/accessor expressions and fully expanded
outer casts to C integer, floating, object-pointer, or function-pointer types
become typed FFI values while generated C retains the public macro spelling.
The bounded accessor path includes typed dereferences such as the common
`errno` expansion; it is not general support for arbitrary call-containing
expressions. A pure dotted identifier replacement becomes a lazily resolved
field projection, again emitted by public spelling. Generated C hoists all
foreign headers, so checker lookup replays their raw definitions,
redefinitions, dependency rescans, and undefinitions into one final module
macro environment, even for earlier closure initializers. Because C
preprocessing precedes field lookup, a live projection wins over a same-named
physical field, and an invalid path or active unsupported object macro is
terminal rather than falling back to that field. Other object-like forms are
not generally supported, and all function-like macros remain unsupported.
Declaration extraction still preprocesses each foreign header independently,
while probes and generated C see the cumulative ordered header block, so
conditional macro coupling and later changes to scalar macros typed by an
earlier import belong behind one umbrella header imported once.

`foreigntypes.convert` maps C declarations to the `Type.C*` family (`CVoid`, `CInteger`, `CFloat`, `CPointer`, `CArray`, `CStruct`, `CUnion`, `CFunction`, `CTypedef`, `CModule`, and owned storage wrappers). C imports are namespaces, not first-class values: the checker represents them as `Type.CModule` (renamed from the prototype's foreign-module type), typedef-qualified names such as `c.T` may be used in local annotations, and `types.serialize` rejects any exported function/method/variable type that mentions a C FFI type. An eligible named file-scope tag-only `struct T` or `union T` is published as the base-name Titan type `c.T`, but remains its canonical `CStruct`/`CUnion` and generates exact tag spelling; do not invent a `CTypedef`, header alias, or ordinary C identifier. A real same-name typedef always wins. C aggregate fields, C array indexing, `#` on static arrays and counted owned buffers, and explicit C vararg calls are implemented; C array indexing is 0-based, bounds-checked for `CArray` and counted `COwned`, and null-checked but otherwise unchecked for raw `CPointer`. Object-pointer conversions, C arithmetic, relational/equality, bitwise, and shift operators, C promotions, and mixed Titan/C operands follow the target profile plus the contextual probe policy; they do not reuse Titan's Lua-semantics operator helpers. Titan's `and`/`or`/`not` remain excluded from C-mode operators.

Exact C integer and floating values stay in their raw C representation until a
checker-owned conversion or boxing plan reaches a real Titan/Lua carrier
boundary. Every potentially lossy crossing must use the shared target-profile
numeric predicate/cast; do not emit an ad hoc C cast to `lua_Integer`,
`lua_Number`, `setivalue`, or `setfltvalue`. Strict boxed C-integer/C-float
guards require the exact integer/float tag, while dynamic guards admit an
integral float for C integers and either numeric tag for C floats before the
same target-range check. `_Bool` accepts only 0 and 1. Floating narrowing
rejects non-finite or out-of-range values but permits rounding/underflow, and
`is` must be the non-raising twin of the same `as` predicate, recursively
through Option. Written C-integer-to-C-integer casts and C usual-arithmetic
integer conversions retain C semantics; a potentially out-of-range C
integer-to-floating operator cast remains checked.

Owned C objects are Titan-owned Lua userdata payloads allocated by the generated
`.new()` and `.new_array(count)` pseudo-functions on C types. Their source
spellings are `owned *T` for one object and `owned T[]` for a dynamically
counted array; aliases and a whole-type trailing `?` are allowed locally, but
any public surface containing an owned C type is rejected just like every
other C-bearing type. They are zeroed, anchored on the Lua stack during
initialization, stamped with a per-owned-C-type metatable for `value` cast
checks, and need no finalizer because the Lua GC owns the payload; dynamic
array counts are reconstructed from `Udata.len`. An owner implicitly converts
to its corresponding raw object pointer where C code borrows it. Casting an
`owned char[]`, `owned signed char[]`, or `owned unsigned char[]` directly to
`string` copies exactly the counted payload, including embedded NULs; a raw
character pointer cast retains NUL-terminated C-string semantics. Do not
manufacture an intermediate Lua stack value, parallel `value` storage field,
or duplicate length record for capabilities already carried by an owner.
Function-local complete non-pointer C structs, unions, and fixed arrays may
also be declared without a right-hand side as zero-initialized automatic
objects. Their lifetime is the generated C block, no escape analysis is
attempted, and aggregate values are spilled through volatile byte storage
around catchable Titan calls so normal-return mutation commits while a caught
longjmp reloads the last Titan-visible state. Owned allocation rejects `void`,
incomplete aggregates, C array typedefs, and structs/unions with flexible array
members. Automatic storage accepts complete fixed arrays, including imported
array-typedef and nested-array shapes, but rejects void, incomplete,
flexible-array-member, and GC-bearing objects. Imported/static C functions can
be converted to compatible C function pointers and called through them;
adapting a Titan function to a C callback ABI remains a parked follow-up
alongside `CAdopted` lifetimes and stronger Lua C API coverage. Generated
run-time type tags for C-bearing callable types are module-scoped because
foreign C type identity is compilation-unit-local; never coalesce those
registry keys globally by rendered spelling. `c-parser/typed.lua` (used only
by c-parser) is a runtime signature-checking DSL that ships **disabled** —
`typed.off()` is the last line; flip to `typed.on()` to debug c-parser type
confusion.

Use the explicit C-`void *` cast instead of Lua-stack round trips when native
code needs a Titan GC object's identity. Arrays and Maps expose their backing
`Table *`, nominal records expose their `Udata *`, and function values expose
the collectable object carried by their boxed `TValue`; a noncollectable
function-typed value makes `is` false and `as` raise. Strings deliberately
remain byte pointers, `COwned` remains its payload pointer, and arbitrary
`value` does not acquire a GC-identity interpretation. C pointer shapes,
including function pointers, may be explicitly erased to `void *` (the
function-pointer case must use `titan_cast_func`). Materialize each GC source
exactly once and anchor it through later argument setup, but remember that the
result is borrowed: retaining the C pointer does not keep the Titan object
alive. Do not add `lua_pushtvalue`/`lua_togco` helpers or parallel storage just
to recover an identity already represented by this cast.

The current `titan.uv` sources import `UV_E*` enumerators directly and call public
libuv operations directly, including process, stat, DNS traversal/release,
bind, and connect submission. The retained native boundary is deliberately
narrow: the plain-C libuv-shaped callback trampolines declared by
`titan-runtime/titan/uv.h`, one common helper that only extracts the Lua main
state/module/native Titan entry, and deliberately overprovisioned opaque
normalized-address storage. Titan initializes public `uv_buf_t` fields directly
through the FFI, using Titan's documented direct `string`-to-`char *`
conversion for libuv's historically mutable spelling of borrowed write bytes.
The callback owner retains the original string throughout that exceptional
asynchronous borrow. Each trampoline selects and invokes its exact Titan
callback handler; there is no generic dispatcher or event-kind argument.

The conditional inherited-`SIGPIPE` policy is implemented in
`titan/uv/uv.titan` through direct `signal.h`/`errno.h` FFI calls and
`uv_translate_sys_error`. Operational
libuv wrappers, including the old DNS/address helpers, must not return.
Archive-backed generated modules now have direct undefined references to those
external callbacks and no references to the retired helpers, which established
the compiled-module ABI-0.18 boundary rather than 0.17. ABI 0.19 preserved that
native callback contract while adding union and public-slot changes; ABI 0.20
preserved both while adding the Array-writer and strict function-closure
protocols. ABI 0.21 retains those contracts while advancing the matched Lua
runtime.

Ordinary libuv handles, requests, read buffers, and normalized address arrays
are owned directly by source-level `owned *T`/`owned T[]` fields. There is one
module-instance coroutine tag for every uv Task; the yielded `Call` union, not
the tag, selects the operation. A wrapper exists only to hide an unexportable
FFI value and retain values required through its callbacks. Multi-shot handles
may also carry their natural buffer/latest result and at most one waiter.
One-shot request owners retain the native request and exact callback; the
callback closure captures the suspended Task and borrowed arguments until
completion. Write callbacks retain the original immutable Titan strings while
libuv borrows their bytes; libuv copies the submitted `uv_buf_t` descriptors,
not their payloads. Libuv copies
asynchronous filesystem paths and DNS text during submission, while `uv_spawn`
consumes file/argv synchronously, so keep originals rooted only for the actual
borrow interval. A direct alloc callback cannot unwind an allocation exception
through libuv: return the zero buffer, preserve the exact exception, and
deliver it through the required paired read callback; do not add a recovery
status or a defensive missing-alloc branch. Do not add `FooControl` layers,
wrapper-on-wrapper state records, uniform nil-padded owner layouts, Task-side
operation queues, or a second handle registry. The minicoro object remains the
sole intentional custom `lua_newuserdatauv` allocation in the standard
library. Capacity-sized
backing arrays must not be cast wholesale to strings when only a logical
prefix is valid.

The Runtime's sparse `handle_roots` is only the C-to-Titan callback live-owner
set and is never traversed. Its sparse `task_roots` is the intentional Task
inventory: it determines when the last user Task finishes and lets `os.exit`
cancel the others. The first `os.exit` request fixes the exit code and cancels
every user Task, including its requester; that cancellation stays pending if
user code catches it and is injected again before the next yielded operation
can be dispatched. Do not reintroduce a parallel active-Task counter.

Only top-level `async.loop` or the standalone bootstrap may call `uv_run`; the
loop is non-reentrant, and an operation callback normally resumes one
continuation, dispatches the next yielded operation, and returns. Every
one-shot timer callback instead submits `uv_close`; only `close_cb`, after the
native owner is released, resumes its suspended Task. Explicit Task resume,
external cancellation of `async.suspend`, repeating-ticker delivery, and other
deferred continuations may use such a Task-owned one-shot timer. The delivery
is callback-deferred but does not promise one exact libuv iteration. An uncaught
error retires and logs only its Task; the task-root set decides whether it was
the last user Task. Public Task state is the `TaskStatus` union with live
`ready`/`running`/`waiting` variants plus exact success, `Error` failure, and
terminal `CancellationReason` payloads. `Task:cancel` stores its first reason
privately until terminal `cancelled` and invokes the current cancellation
action without a public `cancelling` state.

Task terminal publication first stores the final status, detaches the listener
Array as a stable snapshot, and installs an empty live list. It then runs that
snapshot sequentially in registration order on the main thread and ignores
each listener error independently; removal during delivery cannot mutate the
snapshot or skip a later callback. Fixed-arity async
combinators scan their named operands directly, install a separate listener for
each still-relevant operand, suspend once, and defer removal of every
registration. The deciding listener calls the suspended Task's synchronous,
coalescing `resume()`, which installs its target-owned close-before-resume zero
timer and returns. There is no public Waiter, `uv_check_t`, Runtime `uv_idle_t`,
polling loop, phase bridge, taskless timer, scheduler queue, join protocol, or
generation fence. Never collapse the separate typed operands into a `{Task}`
helper. Only `join`
has a unary form; unary `any`/`race`/`all` would be mere result repackaging and
are intentionally absent. The combinators do not cancel unfinished inputs.

Runtime cleanup discovers handles exclusively with `uv_walk` and closes them
with `uv_close`. A `uv_file` is a process descriptor, crosses Runtime sessions,
and is never registered for shutdown. Closing a `uv_process_t` watcher neither
terminates nor reaps its child; child-lifecycle policy belongs above `titan.uv`.

Spawn configuration owns the actual `uv_process_options_t` and stdio array;
each option installs concrete streams immediately and returns status. Parent
stdio inheritance always uses wrapped pipe/TTY streams with
`UV_INHERIT_STREAM`, never `UV_INHERIT_FD`.

## Test suite notes

- `spec/coder/coder_spec.lua` is end-to-end: it generates C, compiles with
  the real `cc`, and runs the result under `$PREFIX/bin/lua` via `io.popen`
  (the shared helper retains compatibility fallbacks for older trees).
  Artifacts (`test.c`, `test.so`, `test.a`, `./test`, and exact `*.o` outputs)
  land in the repo root;
  `after_each` and the shared application helpers clean them. These cases
  consume the prepared runtime archive; only the serial coroutine suite may
  invalidate it inside its explicit preserve/rebuild/restore boundary. Set
  `helpers.verbose = true` in `spec/support/helpers.lua` to see `cc` command
  lines and keep generated `.c` files.
- The **DSO-selected import path** (a dependency reachable only as a compiled
  shared library, not `.titan` source or a matching archive) has dedicated
  coverage: `spec/coder/so_import_spec.lua` (end-to-end: dlopen + ABI check +
  dlsym, cross-module function/variable/record use incl. transitive
  `.so`→`.so` chains, and the first-class fast path across the `.so` boundary)
  and `spec/checker/so_rehydration_spec.lua` (the typechecker checking
  `<mangled>_abi` then rehydrating
  function/record/variable/first-class-function types from the serialized
  `<mangled>_types` symbol). Both build each dependency `.so` *from memory* so
  neither its `.titan` source nor a paired `.a` reaches the loader, forcing
  `driver.defaultloader` down the DSO route; `build_so_chain`/`so_check` assert
  the dependency was resolved dynamically, not statically linked. A module's
  interface may *reference* a record defined in a module it imported but that
  the importer does not import directly — `checker.checkimport` recovers those
  transitively-referenced record modules so their nominal types still resolve.
- `cpp_spec.lua` is the only coverage for the FFI preprocessor (`c-parser/cpp.lua`), and runs **without** the C toolchain: its `expand` helper drives `cpp.parse_file` with a hand-built `ctx` (empty `defines`/`incdirs`) so the `gcc`/`cpp` shell-out is skipped, and wraps each expansion in a Lua instruction-count `debug.sethook` so a regression that reintroduces unbounded macro recursion fails loudly instead of hanging the suite. The recursion-guard cases pin the C "no recursive expansion" rule — keep them when touching macro loop detection.
- Test helpers that touch the checker/coder must reset shared state first: `types.registry = {}` (and `driver.imported = {}` where imports are involved) — see `run_checker`/`run_coder`.
- Parser/checker specs compare ASTs with a subset assertion (`restrict` + `assert_is_subset`): only fields present in the expected table are compared, so adding new AST decorations doesn't break existing tests. Follow this pattern.
- `TableFormatLevel` (luassert's table-printing depth) is global across spec files, and post-checker ASTs are self-referential — printing one in a failure diff at unlimited depth hangs busted. `parser_spec.lua` raises the depth in `setup()` and restores it in `teardown()`, but a stray `assert:set_parameter("TableFormatLevel", -1)` in its describe body (runs at collection time) partially defeats this. If a full-suite run hangs while printing a failing diff, that line is the suspect.
