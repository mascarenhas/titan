# CLAUDE.md

This file provides guidance to a coding agent when working with code in this repository.

## Titan skill startup

Before writing, editing, or reviewing any `.titan` source, read the project-local
`.agents/skills/titan-programmer/SKILL.md`. It is the mandatory, self-contained
Titan basics cartridge; do not reconstruct Titan from memories of Lua, TypeScript,
Go, or C. Load the relevant peer cartridge as well:

- `titan-tester` for native tests, test-layer placement, filtering, and fixtures;
- `titan-async` for Tasks, timers, cancellation, libuv callbacks, and native
  ownership;
- `titan-networking` for URL, TCP, TLS, and HTTP code;
- `titan-ffi` for C imports, callbacks, Lua interop, and `titan.lua`;
- `titan-pegs` for PEG/relabel parsers and combinators.

Load every applicable peer for cross-cutting work (for example, async networking
behavior tests need the programmer, tester, async, and networking cartridges).
The cartridges are the operational default; consult their linked manuals, source,
and focused tests when changing a contract or resolving an edge case.

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
  dispatch.** Use `workflow_dispatch` as the **pre-merge check**, but never
  trigger that costly run without the maintainer's express authorization. Once
  authorized, use `gh workflow run ci.yml --ref <branch>`. Linux jobs are
  push-only and are not repeated by that macOS dispatch. The regular push graph
  has exactly three standard `ubuntu-24.04` jobs. The stdlib producer and
  compiler consumer retain explicit 30-minute timeouts; the independent
  sanitizer has 35 minutes so a cold native-dependency cache miss remains a
  valid build under the same two-CPU bound. Linux jobs export `MAKEFLAGS=-j2`
  and `TITAN_JOBS=2`, matching the two CPUs on standard private-repository
  hosted runners; the macOS job
  overrides both bounds to three for its three CPUs. Make may overlap independent
  native prerequisites, and each `titanc` process may overlap only generated-C
  object compilations. The compiler suite schedules four external groups at
  most two at a time and overrides `MAKEFLAGS=-j1` and `TITAN_JOBS=1`, so
  ordinary test invocations consume at most two native/generated-C slots in
  aggregate. Dedicated parallel specs
  still pass their explicit bounds and may temporarily exceed that aggregate.
  The compiler launches larger generated units first and
  receives actual child completions through one private POSIX FIFO, refilling a
  slot immediately; diagnostics remain buffered and replay in request order.
  Do not replace wait-any notification with launch-order `pclose`, which leaves
  completed children occupying logical slots. Indirect LuaRocks/CMake recursive
  wrappers preserve the Make jobserver through guarded recursive recipe lines,
  and `ltitanlib.o`
  waits for the prefix Lua installation that owns its public headers. Busted
  2.3 has no native shard option. An exact unfiltered local `rock-test` instead
  runs the eight retained runtime/packaging specs serially, then externally
  partitions the complete compiler/language file set into four measured
  longest-first groups in private checkout copies. It defaults to four workers,
  accepts `TITAN_ROCK_TEST_JOBS=1` through `4`, gives each worker private
  general and ccache temporary directories, and caps nested Make/Titan work at
  one slot per worker. A Busted filter or forwarded argument preserves the
  single-process path; a Titan-only filter does not disable compiler sharding.
  The Linux compiler consumer uses the same partition and schedules at most two
  workers concurrently.
  Each group runs in a private extraction of the prepared checkout, because
  compiler specs share checkout-root artifact names; tagged Busted output
  streams to the job log. In Linux coverage CI each group owns one LuaCov stats
  file, and the job merges all four only after every worker passes; local shards
  do not collect LuaCov. The installed prefix is shared read-only. The
  aggregate native Titan suite also remains one fast executable.

  1. `test-linux-stdlib` is the prepared-tree producer. It prepares a clean
     ABI-2 prefix, builds and installs the optimized bundled provider, and
     packs the complete prepared tree before tests or a system-mode reinstall.
     It then runs, without LuaCov, the retained root build/runtime/packaging
     specs and the one 22-root native stdlib executable through `make
     stdlib-test`; there are no standard-library Lua boundary specs.
     Disposable generated fixtures and test objects use `-O0`; purpose-built
     native harnesses retain their explicit flags, and the provider packed for
     consumers remains optimized. After the uncovered tests it builds the
     child-process fixture, runs the bundled production smoke, reinstalls the
     source rock with system libuv/OpenSSL at `-O0`, reruns only the two
     mode-dependent SDK-layout/external-DSO promotion cases from
     `rockspec_spec.lua`, and runs the full system production smoke with
     optimized consumers. The bundled smoke and packed canonical provider also
     remain optimized. It uploads the already packed artifact only after both
     provider modes pass. Never repack the live system-linked tree.
  2. `test-linux-compiler` is the sole regular-artifact consumer. It needs the
     stdlib producer, restores that full tree on the same x86_64 Ubuntu target,
     and extracts four cache-free worker copies without their `.lua` trees. The
     measured `ci_compiler_test_groups.txt` manifest is exhaustive and assigns
     each compiler spec to one worker; ordinary files run once per group, while
     the retained unit/fresh-prototype cases keep their separate Busted process
     boundaries. Workers own private checkout roots and `TMPDIR`s, share only the
     prepared installed prefix read-only, stream tagged logs, and write distinct
     LuaCov stats. At most two workers run concurrently; the job sums all four
     stats files before reporting. Disposable
     generated fixtures use
     `TITAN_EXTRA_CFLAGS=-O0`. The job emits one filtered report and makes
     one failing-on-error OIDC Codecov upload named `compiler`; it is the only
     job with `id-token: write`. Its restored checkout is disposable and has no
     later production-image consumer, so it does not snapshot and restore the
     canonical image around compiler tests.
  3. `sanitizer` independently owns its ASan+UBSan-instrumented Lua,
     libbacktrace, libuv, llhttp, OpenSSL, and Titan tree; it never consumes the
     regular artifact. Before any LuaRocks or Titan installation, it restores a
     native-dependency cache keyed by pinned dependency identities, the current
     libbacktrace revision, sanitizer flags, system Readline/toolchain identity,
     OS/architecture, and an explicit recipe schema. It always reruns the native
     targets as one two-slot jobserver DAG to validate/repair the restored tree,
     then saves a miss at that clean boundary; the cached prefix must contain
     neither LuaRocks/Titan state
     nor C-probe markers. It builds the same aggregate native test executable once
     and uses `TITAN_FILTER` with repeated `make titan-stdlib-test-run`
     invocations when a fresh process is useful. Filters select focused lifetime
     cases; they are not group names and never trigger recompilation. Keep the retained
     owner/callback, observable coroutine-GC, TLS/HTTP, dense-Array, PEG/string, and
     production net/OS gates, but leave the complete stdlib behavior run in the
     regular producer.

  The producer archive is deliberately a full-tree tar: partial archives lose
  source/output timestamp ordering, prepared Lua files, executable bits, and
  standard-library images. Pack it before tests and before system publication,
  but upload it only after the bundled and system gates pass. The producer and
  consumer are the same OS, architecture, and object target; a prepared native
  tree must never cross one of those boundaries. Keep Linux dependency builds
  in the job that consumes their warm tree, and keep both production-mode
  smokes in the producer instead of rebuilding them in a consumer. The
  prefix-owned `var/cache/titan-probes/<ABI>` directory is the deliberate
  exception to that full-tree transfer: exclude it from the tar and snapshot it
  independently in the regular producer, sanitizer, and macOS jobs with
  `ubicloud/cache@v4`. The regular producer uses explicit restore/save actions
  and saves after the bundled tests and smoke but before the system-libuv/OpenSSL
  canary can add markers from another provider configuration. The other lanes
  save at job end. Those producing lanes have distinct OS/architecture keys
  whose immutable primary ends in the commit SHA and whose stable restore
  prefix omits it. Each selects its lane namespace with
  `TITAN_PROBE_CACHE_IDENTITY` before its first Titan build. The prepared-tree
  compiler consumer remains cache-free, and compiler specs explicitly disable
  persistent markers because independent fixtures reuse header pathnames;
  production builds and native aggregate compilation still benefit. A marker's
  presence is trusted success evidence, so never restore cache entries from a
  less-trusted writer.

  The regular producer's cache key includes the active ABI. After restore it
  reruns `make lua` and `make luarocks`, replaces only known active `0.6`
  Titan-owned rock/direct-shim state, and proves `package.cpath` contains
  `lib/titan/0.6/?.so`. There is no migration or compatibility path for
  installations from before the numbering reset. The `rockspec_spec.lua`
  publication gate copies
  the already validated installed pair and shims into a private stage, then uses
  `publish-stdlib` with that exact `STDLIB_INSTALL_STAGE`; it must not invoke
  build-dependent `install-stdlib` and rebuild all eighteen roots in the same
  configuration. Keep packaging gates before legacy compiler specs that clean
  root outputs.

  Sanitizer execution retains ordinary Titan `#line` attribution: selected
  traceback gates require exact user and standard-provider frames. Use
  `TITAN_NO_LINE_DIRECTIVES=1` only for an isolated reproduction. Before the
  private generation stage disappears, `rock-post-install` saves its sanitized
  `titan.so`, every exact generated stdlib `.c`/`.o` pair used by that link, and
  the NUL-delimited generated-C compile-prefix argv. Each gate captures its
  original combined output, and only the failure-only diagnostic step reads
  those logs; the failed program and provider are never rerun. The mapper uses
  the original ASan frame's relocation-safe canonical-provider offset and
  BuildId, then builds one on-demand shadow for the unique owning translation
  unit with `#line` directives blanked and the exact saved compile prefix. It
  reports physical C context only after saved/shadow function bytes, names,
  sizes, addresses, and `.text` membership agree; symbolization is
  section-relative to `.text` and must name the exact private shadow path. Any
  mismatch leaves context unavailable rather than guessing. Lua,
  libbacktrace, and libuv compile with sanitizer instrumentation at `-O1`; the
  much larger generated Titan images and disposable fixtures use the same
  instrumentation at `-O0`.

  The cold `test-macos` job remains dispatch-only and is a required pre-merge
  gate. It retries only dependency-acquisition commands within the same prefix;
  the Titan build and complete test run remain single-shot. Run all uncovered
  stdlib/runtime/packaging work, including the aggregate native executable,
  before `ci_test_groups.sh compiler-uncovered`. Snapshot the runtime archive,
  canonical `titan.so`/`titan.a`, conditional dSYM, all eighteen shims, and the
  canonical test-support source before compiler tests, then restore them before
  the bundled/system production smokes. Keep the real x86_64/arm64 universal
  Mach-O archive lookup and repackaging proof here rather than replacing it
  with a host-only synthetic check. The complete macOS run, including both
  libuv modes, remains optimized. Compiler and language specs must not delete
  the shared checkout runtime archive merely to force recompilation; Make owns
  that dependency state. The coroutine suite is the isolated restoration
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
  replacing an existing private installation. Under parallel Make, Lua source
  extraction precedes the Readline-selection file that lives in that tree;
  fallback compilation may overlap, but upstream Readline installation into
  the private stage is serialized because its archive replacement rules race.
  `READLINE_HOST` supplies an optional Autoconf cross-target triplet; the
  `READLINE_*FLAGS` inputs are
  recorded alongside the native tools. Its configuration stamp cleans Lua
  objects whenever `PREFIX`, `LUA_PLATFORM`, `LUA_CC`, a native-build input,
  or the selected Readline provider changes.
- **Lua deps and rock installation**: `$PREFIX/bin/luarocks make
  titan-0.6.0-1.rockspec` installs lpeglabel, inspect, argparse, luafilesystem,
  then deploys the compiler/runtime SDK and the combined standard library. The
  rockspec keeps `build_target = "titan"`, disables LuaRocks' separate Make
  install pass, derives `ROCKS_TREE` from `$(SCRIPTS_DIR)/..`, and does not own
  a manifest C module named `titan`. `make titan` builds `libtitan.a`, the
  separate `libbacktrace.a`, and a private support-only image at
  `titan-runtime/bootstrap/titan.so`; with a nonempty `ROCKS_TREE` it also
  stages the matching compiler SDK, including the runtime archive at
  `$ROCKS_TREE/lib/titan/0.6/libtitan.a`. `libtitan.a` contains exactly
  `titan.o` and `minicoro.o`; `ltitanlib.o` is outside that archive and is
  the sole input to the private bootstrap. The non-Lua headers staged under
  `$ROCKS_TREE/include` are `minicoro.h`, `titan.h`, and
  `titan/ffi.h`; bundled mode also stages `uv.h` and `uv/`, but the
  private `libuv.a` is never installed.
  The pinned, privately namespaced LPegLabel build produces
  `lpeglabel-build/libtitan-lpeglabel.a` with exactly `lplcap.o`, `lplcode.o`,
  `lplprint.o`, `lpltree.o`, and `lplvm.o`. It is standard-provider payload,
  not a runtime-SDK archive: neither it nor its private headers are installed.

  SDK staging atomically places the bootstrap at
  `$ROCKS_TREE/lib/titan/0.6/titan.so` only when the path is absent. It
  validates and preserves an existing usable bootstrap or full image, and
  refuses to clobber an incompatible file; a repeated build must never shrink
  a full image back to bootstrap form. After LuaRocks deploys the compiler, the
  source-only `post_install` hook invokes the just-installed `titanc` once with
  all eighteen roots and a shared `-X` payload beginning with `ltitanlib.o` followed
  by the private namespaced LPegLabel archive. The
  standard sources are
  `titan/coroutine.titan`, the explicit seven-file `UV_TITAN_SOURCES` folder
  ensemble, `titan/{async,timer,io,fs,net,ssl,url,os}.titan`, the explicit
  `titan/http/` folder ensemble, and the explicit
  `titan/peg/` and `titan/string/` folder ensembles, plus
  `titan/{math,lua,iteration,gc}.titan`, and `titan/test.titan`. Each logical
  module
  remains independent, but the physical outputs are the paired `titan.so` and
  self-describing `titan.a`. In bundled mode the pinned private `libuv.a`
  follows the LPegLabel archive in that same `-X` payload, followed by the
  private llhttp archive, then the bundled OpenSSL archives used
  directly by `titan.ssl`. The compiler force-carries all bundled payload into
  the DSO and flattens it into the archive. In system mode the LPegLabel
  archive and private llhttp archive remain present while
  pkg-config's ordered libuv and OpenSSL results remain final-link inputs, must
  be repeated by static consumers, and are never copied into `titan.a`.

  The hook builds in a private destination-filesystem stage, validates nineteen
  `luaopen_*` entries and all eighteen logical protocols, requires exactly eighteen
  embedded archive keys, and compares embedded ABI/types with both the staged
  DSO and a fresh-process archive-backed validation image before checking the
  eighteen generated shims, exact staged `titan/test.titan` compiler source,
  and macOS dSYM. It then runs the source-only
  `scripts/stdlib_installer.lua` under the same effective `CC`, `AR`, `RANLIB`,
  `TITAN_EXTRA_*`, `TITAN_ROCKS_ROOT`, and runtime-prebuilt environment for
  recoverable publication. The script is not part of the installed compiler
  modules. It recognizes bootstrap-only and the current complete pair as
  bounded predecessor states; backs up the
  exact current DSO/archive/dSYM/shims/compiler source and stale active-layout
  copies; commits shims and compiler source, then dSYM and `titan.a`, and
  renames `titan.so` last. Caught errors and
  injected archive/DSO failpoints restore the exact supported predecessor. This is
  not crash-, power-loss-, or asynchronous-signal-atomic publication. The
  canonical artifacts are `$ROCKS_TREE/lib/titan/0.6/{titan.so,titan.a}`, the DSO's
  macOS dSYM, the compiler source
  `$ROCKS_TREE/share/titan/0.6/src/titan/test.titan`, and generated
  `$ROCKS_TREE/share/lua/5.5/titan/{coroutine,uv,async,timer,io,fs,net,ssl,url,http,os,peg,string,math,lua,iteration,gc,test}.lua`.
  No symbolic links, hard links, child DSOs, or `lib/lua` compatibility copies
  are used. Earlier Titan installations are not migration sources. These direct
  SDK/stdlib files remain outside the rock manifest and are not removed by
  `luarocks remove`; binary-rock ownership is deferred until Titan has a
  library/application packaging story. The
  rockspec declares `test_dependencies` (busted, cluacov) plus a `command`
  test backend that enters `run_rock_tests.sh`. The adapter passes ordinary
  appended arguments only to Busted, maps `BUSTED_FILTER` and `TITAN_FILTER`
  independently, and invokes `make rock-test`; the latter runs the Busted tree
  and the one aggregate native Titan suite. Its exact unfiltered path runs the
  retained runtime/packaging specs once and the compiler/language specs in four
  isolated local shards; filtered or otherwise customized Busted runs remain
  serial. Filtering one domain does not skip the other, so use its leaf Make
  target when only that domain is wanted.
  `luarocks test` does **not** build the rock-under-test, so `make test` runs
  `luarocks make` first.
- **Bash for bounded native tests.** `spec/support/run_with_timeout.sh` starts
  the aggregate executable in its own process group and enforces the deadline
  with `TERM` followed by `KILL`. The Make runner streams combined output
  through a pipe, not a regular-file redirection, so the stdio/parent-descriptor
  cases keep their supported boundary.
- **clang-format.** Ordinary Linux and macOS builds do not invoke or require a
  formatter. `titanc --pretty-print` opts in: the `CLANG_FORMAT` command defaults
  to `clang-format`, is parsed into argv only in that mode, and receives Titan's
  fixed explicit style with include sorting disabled for every generated `.c`
  and `.titan.h` stage. It never discovers a project's `.clang-format`; `-v`
  prints the safely quoted formatter command only when it is executed. Every
  mode still removes blank physical lines immediately after `#line` directives.
- **C toolchain**: `CC` (default `cc`) for compilation and for the C FFI's
  predefined-macro/include-search probes, plus `AR` (default `ar`) and
  `RANLIB` (default `ranlib`) for every generated static provider. All three
  may be configured command strings, are parsed into argv, and must remain the
  same tools recorded by the prefix's LuaRocks configuration through source
  build, post-install validation, and later consumer builds. The archive
  builder prefers deterministic `ar qDc`/`ranlib -D`, falls back to portable
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
export PREFIX="/tmp/titan-$USER-test"
export PATH="$PREFIX/bin:$PATH"
```

For throwaway verification, use an isolated absolute prefix under `/tmp`
(for example `/tmp/titan-$USER-test`) rather than relying on checkout-local
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
make test                                           # prepare/install the rock, then run the complete mixed suite
TITAN_JOBS=4 make -j4 test                           # supported four-way build/compiler variant
luarocks test                                       # test an already current install; PREFIX/ROCKS_TREE are not required when its bin is on PATH
make rock-test BUSTED_FILTER='parser' TITAN_FILTER='^http[.]tests[.]'  # independent domain filters
make stdlib-test                                    # complete retained stdlib/runtime category without coverage
make busted-test BUSTED_FILTER='for loop'           # Busted only
make titan-stdlib-test TITAN_FILTER='^net[.]tests[.]' # build/run the aggregate native suite
make titan-stdlib-test-build                        # build all 22 roots once under .titan-tests
make titan-stdlib-test-run TITAN_FILTER='^ssl[.]tests[.]' # reuse that executable
luarocks make && bash spec/support/ci_test_groups.sh compiler  # complete covered compiler/language group
make clean                                           # remove generated artifacts; `make distclean` also removes downloaded Lua/Readline/LuaRocks/libbacktrace/libuv/OpenSSL/llhttp trees

TITAN_PROBE_CACHE_DISABLE=1 busted                  # full Busted tree — MUST run from repo root (all driver paths are relative)
TITAN_PROBE_CACHE_DISABLE=1 busted spec/parser_spec.lua  # single spec file
TITAN_PROBE_CACHE_DISABLE=1 busted spec/coder/coder_spec.lua --filter='for loop' # single test

./titanc [--print-ast] [--pretty-print] [--test] [--no-uv-bootstrap] \
  [-v] [-j jobs] [--static] [--no-line-directives] \
  [--lua <luasrc>] [--tree <srcroot>] \
  [-l lib1,lib2] [-X object...] <module>...
```

`--no-uv-bootstrap` is valid only for a standalone program or `--test`. It
changes only the generated entrypoint's hook choice: imports and `titan.uv`
initialize normally, argc/argv reconstruction and protected error handling are
preserved, and the registry hook is neither cleared nor identified. The
repository aggregate uses it for explicit sequential Runtime ownership;
children that test automatic bootstrap behavior deliberately omit it.

**Coverage is for compiler and language behavior, not library suites.** Do not
run library API/runtime tests under LuaCov when their purpose is to test the
library rather than a compiler or language feature. LuaCov measures the Lua
compiler, not Titan or C library implementations, and its debug hook can make
repeated checks of large library sources disproportionately slow. Linux CI has
one uncovered stdlib producer and one consumer that runs the complete
`spec/support/ci_test_groups.sh compiler` set with coverage and emits the sole
LuaCov/Codecov report. The producer runs retained host/build boundaries plus
the aggregate native suite without coverage; the independent sanitizer selects
only focused native-memory cases and does not publish coverage. This includes
both async-I/O and coroutine behavior, which must still run in full in the
regular uncovered job. The repository `.luacov` limits debug-hook collection to
the same compiler, root-spec, and `titanc` paths emitted by the one report
command; keep those filters aligned. If a library suite exposes a compiler
coverage gap, add a small focused compiler/checker test for that code path
instead of covering the library integration suite.

**Spec layout.** Pure, layer-level specs live at `spec/` root (`abi_spec`,
`cdriver_spec`, `cpp_spec`, `ctypes_spec`, `driver_spec`,
`foreigntypes_spec`, `lexer_spec`, `location_spec`, `parser_spec`,
`staticmetadata_spec`, `symtab_spec`, `titanc_parallel_spec`, `types_spec`,
`util_spec`); serial native-build and packaging
gates also live there (`libuv_build_spec`, `rockspec_spec`,
`stdlib_installer_spec`). Compiler and
language specs are split by layer:
checker-only specs (run the checker, never generate or execute code) live
under `spec/checker/`, while compiler end-to-end specs (generate C, compile,
run) live under `spec/coder/`. Standard-library API and runtime behavior lives as Titan source under
`spec/stdlib/titan/`, including `coroutine` and the async-I/O modules, and runs
in the unified native executable without LuaCov. There are no Lua files under
`spec/stdlib/` and no root-level standard-library `*_boundary_spec.lua` files.
Fresh-process public behavior belongs in the owning native Titan module: a
compiled parent may launch a focused standalone fixture through C99 `system`,
receive its explicit result through a temporary file, and remove that file with
`defer`. Do not retain implementation/codegen inspection, provider-cache
internals, or redundant FFI/interposition checks as library behavior. Do not put a
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
behavior under
`spec/stdlib/titan/string/regex_test.titan`, run by the native test runner
outside LuaCov.
Folder-source resolution, blocking, composition, and cross-file diagnostics
belong in filesystem cases in `spec/driver_spec.lua`; public compilation,
artifact, external-`--tree`, and mixed-source traceback behavior belongs in
`spec/coder/folder_modules_spec.lua`. Keep uv runtime behavior in the existing
non-LuaCov stdlib suites.
Prefix-container public compilation and generated-shim behavior live in
`spec/coder/multi_module_libraries_spec.lua`; support-loader publication and
promotion are covered by that compiler suite plus `rockspec_spec.lua` and
`stdlib_installer_spec.lua`, without a duplicate library boundary spec. Keep the
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
`require`d as `spec.support.helpers`. The remaining
`spec/support/async_stdlib.lua` and OS process support are build/production-smoke
infrastructure, not a home for standard-library behavior assertions. Reusable
C/H host fixtures live under `spec/fixtures/stdlib/native/`; compiled Titan
fresh-process fixtures live under `spec/fixtures/stdlib/titan/`. Tests treat the
Makefile-owned combined `titan.so`/`titan.a`, generated standard shims, and the
private libuv archive as read-only. Helpers may not clean or rebuild shared root
artifacts during Busted.
Helpers pull in luassert explicitly (`require 'luassert'`) because a
`require`d module does not inherit busted's `assert` global. Set
`helpers.verbose = true` (was a per-file `local verbose`) to print `cc`
command lines and keep generated `.c` files.

Native standard-library behavior lives in 22 module-owned roots under
`spec/stdlib/titan/`. `TITAN_STDLIB_TEST_ROOTS` names every root explicitly;
`make titan-stdlib-test-build` invokes the active
`titanc --test --no-uv-bootstrap` once from `.titan-tests/`, with an absolute
source tree, so every root remains source-authoritative. Source-first lookup
does not expose locals through ordinary imports; the generated runner uses
`import "titan.test.titan"` for its private protocol. The runner is
Task-independent; each async case explicitly owns `async.run`/`async.loop`
through source-only `support.runtime`, and Runtime-bound cleanup runs in LIFO
order inside that same supervisor Task before the loop returns. Ordinary later
`Context:cleanup` is only for non-Runtime resources. The designated program
root, `test.tests`, owns the one `.titan-tests/test/tests` executable and its
synthetic support/runner/entrypoint artifacts. Execute it from the repository root with
`make titan-stdlib-test-run`, because fixtures rely on that CWD; `make
titan-stdlib-test` performs both steps. `TITAN_FILTER` adds one run-time Lua
pattern but still compiles all 22 roots. The separate build/run targets let CI
and ASan reuse one executable for several fresh filtered processes without
reintroducing native groups.

The retained Busted specs own compiler, provider-publication, packaging, and
native dependency/build gates; public standard-library host and process behavior
belongs to the aggregate native executable. Its narrow parent-stdio probe is
linked into the compiled parent, which launches standalone Titan children with
C99 `system`; each child reports through a temporary result file removed by
`defer`. `make rock-test` runs the retained Busted gates and then the aggregate
native executable. There are no per-suite native scripts, named host group
selectors, root standard-library boundary specs, or Busted wrappers around
Titan cases. `run_with_timeout.sh` gives the
executable its own Bash process group, enforces a bounded deadline with
`TERM`/`KILL`, and preserves its exit status. The Make recipe streams merged
stdout/stderr through a pipe rather than a regular file, preserving the parent
pipe semantics exercised by OS/stdio tests. Cases that intentionally cause
uncaught async Task diagnostics bracket the expected region with flushed
`Context:log("BEGIN expected uncaught async Task diagnostics")` and matching
`END` lines. Those source-owned brackets are the complete presentation
contract for expected aggregate diagnostics.

Generated test cleanup is generic but bounded. The owned `.titan-tests/`
directory may be removed recursively. Below `spec/`, remove generated `.o`
files and remove a `.c` only when a same-stem `.titan` source exists; this works
without Git metadata and preserves author-written native C fixtures. Reserved
`__test_{support,runner,entrypoint}` suffixes identify a test program's synthetic
files, executable, and dSYM, while the root `test_runner_*` namespace belongs to
interrupted compiler fixtures. Do not replace these ownership patterns with an
indiscriminate `spec/**/*.c` deletion or a per-test artifact list. The build
target cleans source-adjacent outputs after compilation, and `make clean` always
removes them plus `.titan-tests`.

New or modified specs that generate compiler fixtures in the repository root
must remove only their exact module artifacts, including the paired `.a` for a
no-`main` compile, and must treat `titan-runtime/libtitan.a` as shared
Make-owned state. The Linux compiler job runs on a disposable restored tree and
has no later production consumer, so it needs no canonical-image snapshot.
The manual macOS job does have later bundled/system smokes and must snapshot
and restore the prepared runtime archive, combined standard-library
DSO/archive/dSYM, all generated shims, and canonical test-support source around
legacy compiler specs that clean root artifacts.

Standard-library tests do not rewrite production source or inspect generated
objects to re-prove codegen mechanics. Coroutine transfer rooting, checked Lua
API use, loader publication, and similar implementation contracts remain owned
by the existing compiler/native harness coverage; library tests exercise their
observable public behavior instead. This rule also forbids recreating source
transformers or interposition-only variants in `titan.uv` tests.

Async standard-library behavioral specs compile against the canonical
production modules. Keep them centered on public callback-continuation
behavior: one outer loop, captured Task outcomes, independent one-shot
requests, one waiter plus buffered state for multi-shot handles, Task-local
uncaught errors, and final Runtime cleanup. Do not recreate the retired
`uv_states`/`uv_late_callbacks` source variants, delayed-callback transformers,
generation fencing, scheduler-owned joiner lists, Titan-side operation queues,
or reentrant loop scenarios. Public `async.join*` coverage belongs here: those
functions are generic over an independent success/cancellation pair for every
fixed named operand, install per-operand Task terminal registrations, suspend
once, and call every returned idempotent remover in `defer`; they do not add a
scheduler join protocol or collect operands into a Task Array. Terminal
publication stores the final `TaskStatus`, detaches the registration Array as a
stable snapshot, installs an empty live list, clears snapshot ownership, then
invokes every snapshot listener sequentially on the main thread with
per-listener empty catches. A
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
Compiled-module lookup defaults to `.;<root>/lib/titan/0.6`, with
`TITAN_PATH_0_6`/`TITAN_PATH` overriding it and `;;` inserting that ordinary
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

Recovered ABI-2 module interfaces use one closed validator for DSO and archive
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
Clean validation invokes all eighteen roots in one compiler process, stages
`<root>/lib/titan/0.6/{titan.so,titan.a}`, and installs eighteen generated shims
below `<root>/share/lua/5.5/titan/`. The archive advertises exactly eighteen
logical metadata keys; its metadata-free payload begins with `ltitanlib.o` and
the private five-member LPegLabel archive, followed by the selected libuv
payload, the private llhttp archive, and the selected OpenSSL
payload used directly by `titan.ssl`. Bundled archives are flattened into
`titan.a`;
system-mode dependencies remain final-link inputs. The DSO exposes those
eighteen protocols plus bare `luaopen_titan` support, for nineteen
`luaopen_*` entries total. `titan.io`
owns the standard Interface vocabulary and high-level I/O helpers.
`import "async"` is parser sugar for `import "titan.async"` (likewise for the other modules under
`titan/`).
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
they record the archive name, effective `AR`/`RANLIB`,
embedded-format/coder inputs, full `-X` payload, LPegLabel source/archive
identity, libuv mode, platform support, and existing
compiler/source/flag inputs. Every warm `make stdlib` rescans `titan.a` for the
exact eighteen logical keys without changing pair mtimes; a missing or corrupt
archive invalidates completion and rebuilds both forms. CI's
`ci_stdlib_snapshot.sh` saves and restores the installed pair, runtime archive,
dSYM, and shims with content/mode/mtime assertions around legacy compiler
cleanup.
Filesystem source cache entries carry `program_output` (`P` flat,
`P__main` folder); `titanc` and filesystem child compilers must pass it to
`driver.compile_program`. Keep the optional argument's old dotted-name default
for `tableloader` and external callers.

The current ABI gives every Array proxy a traced user value carrying its
construction-selected Lua-write policy and every Titan function closure a
fixed opaque brand upvalue plus a trailing strict generic entry. It also covers
the Interface representation, the source-local `titan.uv` public/private
boundary, every module's fixed source-provider identity slot, and
source-defined foreign callbacks. The embedded Lua contract is 5.5.1.
Callable entry families use `_\u2133_` between module and remainder and
`_\u2131_` between a record/union/Interface owner and its static, constructor,
variant, method, bound, or metamethod role; generated C uses UCNs while linkage
tools expose UTF-8 `ℳ`/`ℱ`. Serialized interfaces include generic binder
scopes, applied nominal arguments, declaration schemes, generic owners and
methods, and constructor-preserving aliases. Const-qualified descriptors,
Interface field wrappers, and the mutable/const Array runtime split are also
ABI-visible. `TITAN_ABI_VERSION` is `2`; `TITAN_VERSION` is `0.6.0`; and
`TITAN_LIBRARY_VERSION_SUFFIX`, `TITAN_PATH_0_6`, `lib/titan/0.6`, and
`stdlib_0_6` follow the derived `0.6` library version. A mismatched provider is
rejected before its type metadata is decoded. `.so`/`.a` providers built for a
different ABI are incompatible. `-v` prints the exact executed C tool commands
and any opted-in formatter command line.
Without the prepared Lua 5.5.1 installation, only the pure specs pass (cpp,
lexer, location, parser, symtab, types, util); `spec/checker/`, `spec/coder/`,
and
`spec/stdlib/` need the full setup.

**Gotcha — the installed rock shadows the working tree under busted.** The Busted launcher uses `luarocks.loader`, so once `$PREFIX/bin/luarocks make` has installed the `titan` rock, `require "titan-compiler.X"` inside specs resolves to the *installed snapshot* in `ROCKS_TREE` (currently the same directory as `PREFIX`), not your edited source files — edits silently do not take effect. Re-run `$PREFIX/bin/luarocks make` after changing compiler sources, before running Busted. (`make test` re-runs `luarocks make` for you each time, so it always tests current sources; `luarocks test` on its own does **not** rebuild the rock.) A direct `TITAN_PROBE_CACHE_DISABLE=1 busted` invocation without a preceding `luarocks make` can silently load a stale installed snapshot and pass or fail misleadingly.

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
`checker.check` → one `coder.generate` translation unit → `driver` writes the
`.c` **next to the flat source or canonical folder main**, performs required
`#line` normalization, optionally invokes the configured `clang-format` when
`--pretty-print` is selected, and then invokes the parsed `CC` command with each
argument shell-quoted. An opted-in formatter failure retains the raw or
partially formatted C for diagnosis but prevents native compilation. Generated
source-foreign `.titan.h` companions use the same boundary in a sibling stage
before publication. Folder descriptors are temporary loader
metadata, not AST nodes or namespaces. In no-main mode, `titanc` derives the
longest common dotted provider from the deduplicated requested roots, rejects
unrelated roots,
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

Lexing and parsing are fused in one LPegLabel/relabel grammar; `lexer.lua` exports raw LPeg patterns referenced as `%TOKEN` terminals (no token stream). Every AST constructor is auto-injected into the grammar's defs table, so grammar actions like `-> TopLevelFunc` call constructors directly. Every error label used in the grammar (`^Label`, `%{Label}`) or lexer (`lpeg.T`) **must** have an entry in `syntax_errors.errors` or error formatting breaks. The parser is not reentrant (module-global `THIS_FILENAME`, asserted nil on entry). `record` declarations are desugared at parse time into a `TopLevelRecord` plus an adjacent synthesized `new` static marked `_record_constructor`. `union` declarations emit `TopLevelUnion` plus one adjacent synthesized static per variant, marked `_union_constructor`/`_union_variant`; explicit nominal functions carry neither marker. `case`/`when` arms consume the ordinary full block production. `[local] type Name = T` produces a transparent `TopLevelTypeAlias`; it is not a standalone value, but a record/union alias preserves the canonical nominal namespace and its visible constructors/statics. `interface Name ... end` produces a nonempty type-only `TopLevelInterface` with ordered bodyless methods. Short standard-library imports are also parser sugar: `coroutine`, `uv`, `async`, `timer`, `io`, `fs`, `net`, `ssl`, `url`, `http`, `os`, `peg`, `string`, and `test` become the ordinary qualified module names under `titan.*` before module resolution.

### Checker (`checker.lua`, `checker/*.lua`, `types.lua`, `symtab.lua`)

`checker.lua` is the five-operation production facade. It eagerly loads the
logical slices under `checker/`; every slice installs into the single private
lexical environment and state table from `checker/core.lua`, so cross-slice
recursion, visitor dispatch, probe ownership, and checker lifecycle state remain
one instance without publishing implementation names in `_G`. Slices require
`core`, never the facade or one another. Generic implementation helpers remain
in their semantic slices and use `generic_`-prefixed names in that private core;
do not recreate a `checker._generic` namespace. Keep the facade limited to
`configure_foreign_c`, `check`, `register_module_interface`, `checkimport`, and
`has_main`; white-box tests require `checker/core` before helpers/the facade and
then inspect that core or require the owning slice, because Busted insulation
unloads dependencies reached only through another module.

`checker.check(modname, ast, subject, filename, loader) -> moduletype, errors`; callers test `#errors == 0`. Without reordering the AST, it marks ordinary duplicate winners and `_toplevel_order`, precollects aliases and Interfaces, then stages name reservation; imports in AST order; alias resolution; records and unions; Interface descriptors; parser-marked synthesized constructors; ordinary callable/module-initializer signatures; methods and nominal functions; module variables in AST order; and finally bodies. It annotates `_ignore` on rejected duplicates. The checker also annotates (`_type`, `_types` for multi-return calls, `_decl` on variable uses, `_used`/`_assigned`, union case/variant metadata, and checker-owned Interface conversion/adapter plans) and **mutates** the AST:

For a folder source the driver calls the checker exactly once with the
combined AST, logical module name, and canonical main filename/source
directory. Duplicate declarations, aliases, and alias/record conflicts use
the later node's normal error prefix and print the earlier declaration's full
`filename:line:col`; do not regress those to line-only messages. Source tooling
also relies on exact parser `_name_loc`/`_module_loc`/`_owner_loc` and structural
`_end_loc`/`_structure_loc`, checker `_decl` bindings (including
`Checker.TypeMember` and `Checker.Parameter`), and the private
`_surface_typeparams`/`_surface_typeargs`/`_surface_named_args` lists. Those
private edges are not serialized ABI or runtime input and must stay outside the
coder's erased-boundary traversal.

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

`checkstat` handlers return a boolean "cannot fall through", stored in the historical `_always_returns` field and used to enforce that functions with fixed nonnil returns cannot fall off the end. Imports go through a `loader` callback (`driver.defaultloader` for real lookup, `driver.tableloader` for in-memory sources in tests); source deps are recursively typechecked, while compiled-provider deps probe the requested `<mangled>_abi`/`<mangled>_types` pair before recovering the interface. A `TopLevelImport` whose spelling ended in `.titan` passes a source-required request under the stripped canonical module name.

An ordinary import exposes only the producer's public declarations even when
the loader selected source. An explicit spelling such as
`import "app.model.titan"` removes the terminal marker before shorthand and
lookup, requires source with no binary fallback, and may select locals through
that qualified alias only when the loader also returns trusted source
provenance. The canonical module, dependency, native, artifact, and manifest
identity remains `app.model`. Dotted logical names ending in the component
`titan` are forbidden because that spelling is always the marker; bare `titan`
and a nonterminal `titan` component remain valid. The capability is direct-only
and comes from written opt-in plus loader provenance, never metadata, registry
state, static co-residence, or another module's import. Source-private variables
and closures use the canonical producer state; generated importers verify the
exact physical producer identity before reading a private slot.
The five source facades `titan.async`, `titan.timer`, `titan.fs`, `titan.net`,
and `titan.os` therefore write `import "uv.titan"`; an ordinary `import "uv"`
never exposes `titan.uv` locals.

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

### Coder and driver (`coder.lua`, `coder/*.lua`, `driver.lua`)

`coder.lua` is the four-operation production facade. It eagerly loads the
logical slices under `coder/`, all of which install into the single private
lexical environment and policy table from `coder/core.lua`; slices require only
that core, never the facade or each other, and implementation helpers must never
be proxied into `_G`. Keep the facade limited to `generate`,
`generate_foreign_header`, `external_symbols`, and
`interface_external_symbols`. White-box tests must require `coder/core` before
helpers/the facade and then the owning slice so Busted's dependency insulation
does not create a second internal state table.

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
  does not require an ABI change. The `titan.uv` dogfood deliberately moves
  public declarations into contributors and changes their ordered slots, while
  later checker staging and relocation of private uv records change only
  private slot and initialization order. The current ABI also covers the
  physical-provider layout, dense-Array invariants, promoted callback symbols,
  union schemas, Interface and generic metadata, source-private module state,
  source foreign callbacks, and affected public standard-library signatures.
  Its Lua contract is 5.5.1, and its callable names use the injective
  `_\u2133_` module and `_\u2131_` nominal-member separators.
- Generic owner arguments attach to the nominal namespace (`Pair<T>.new`,
  `Pair<T>.static<U>`), while callable-local arguments remain after the member;
  never accept constructor owner arguments as `Pair.new<T>`. When both owner
  and callable scopes are open, explicit lists are all-or-none. After all
  receiver/result/argument/constraint evidence, a free binder closes to its
  declared erased carrier (`value` or its recursively substituted Interface
  application). Contextual constructor inference looks through an ordinary
  outer Option wrap, as in `task:cancel(CancellationReason.simple("timeout"))`.
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
  still fails when called. Dynamic Interface discovery has one deliberate
  trusted-protocol exception: `value is I` accepts exact wrapper identity or
  any non-nil witness entry on the candidate userdata metatable without
  invoking it, while `value as I` calls that entry. Compiler-generated
  witnesses therefore agree, but forged debug/native non-callable entries can
  make `is` true and the corresponding `as` raise normally. Retain exact
  raw-subtype probes such as
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

- The invariant for the `_mod` parameter of any generated function, method,
  or adapter is that it must always be the `_mod` of the module that
  function, method, or adapter belongs to (the module in which it was
  compiled). For a callable adapter (created when casting a closure to a
  compatible function type), `wrapper->upvalue[0]` is initialized with the
  adapter's module `_mod`, and the wrapped closure's own `_mod` is recovered
  from `source->upvalue[0]` when delegating to the source native entry. For an
  interface wrapper, `wrapper->uv[0]` stores `_mod` of the module where the
  cast to the interface took place. When an interface method is called across
  module boundaries (`owner_module ~= cast_module`), the interface adapter
  resolves `concrete_mod` from `_mod->uv[slot]` and passes it as `_mod` to the
  concrete method entry. Because `_mod` is always the module that compiled the
  adapter, all nominal, array, and owned-C metatables and type tags are
  resolved statically from `_mod->uv[slot]` in that module, completely
  eliminating dynamic Lua registry lookups in adapters.
- A dynamically imported module is loaded from its transient
  `Type.Module.file` with `RTLD_LAZY | RTLD_GLOBAL` before it is initialized.
  `file` defaults to the exact logical path, is overwritten by prefix-container
  rehydration, and is never serialized. If an imported interface re-exports a nominal record type
  owned by one of its own imports, initialization of the explicit import first
  publishes the owner's method entry points. The importer then resolves those
  transitive symbols through `RTLD_DEFAULT`; it does not open the owner DSO a
  second time.
- Module state is a `Udata` (`_mod`), allocated with `luaS_newudata(L, 0, NUPVALS)`. Its ABI-visible prefix is exported variables, exported top-level function closures, then exported static closures of public record/union owners in module-member and bytewise-static order. The unconditional per-state Array-metatable cache follows that prefix, then one lightuserdata source-provider identity token, then the deterministic source-private variable/callable region. An explicit source importer compares that token with its exact linked producer's hidden immutable identity entry before reading any private slot; a same-name module state installed by another physical provider is an error. Remaining private user values hold imported modules, record/union metatables, per-nominal static-namespace tables, and module-local Array-writer closures allocated once per constructed structural element type; there is no distinguished `uv[0]` header. Publish function-type tags before any module-variable initializer can construct a lambda or bound-method closure, and initialize Array writers before module variable initializers. There is **no** Lua-facing module table — `require` returns the module `Udata` itself (so `type(require "m")` is `"userdata"`), and all member access (functions, variables, nominal namespaces such as `m.Rec`/`m.Union`) flows through a metatable `__index`/`__newindex` over a unified name→slot member map; functions and nominal namespaces are served read-only (assigning errors), variables use the same dynamic boundary coercions as Lua function arguments and Array writes, and the "not found" message is "member '%s' does not exist". A record instance is likewise a single `Udata` (fields in `uv[0..N-1]`, type identity is its metatable pointer, no raw payload); Lua field writes use that same dynamic policy. A union instance is a single zero-byte `Udata` with the union metatable identity, integer tag in `uv[0]`, and optional payload in `uv[1]`; empty variants allocate no payload slot and instance Lua access exposes methods only.
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
  closures, and file-local native wiring. The ABI-2 `titan.so`/`titan.a`
  pair carries all eighteen current logical modules, including the
  `titan.io` Interface vocabulary and high-level I/O helpers plus `titan.test`.
  The canonical runner-private source is published at
  `$ROCKS_TREE/share/titan/0.6/src/titan/test.titan`.
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
- First-class function values use the current ABI's `CClosure` layout: `_mod`,
  exact tag, native pointer, opaque brand in slot 3,
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
- The driver normalizes every compiler-generated `.c` and `.titan.h` stage
  before compilation, probing, or publication. `--pretty-print` additionally
  applies a fixed `clang-format` style with include sorting disabled, because
  generated header and preamble include order is intentional; never delegate the
  style to an ambient project configuration. Generated multiline C comments use
  ordinary ` *` continuation lines so an opted-in formatter pass is already a
  fixed point. Code generation and the final file boundary remove every blank
  physical line immediately after `#line`: the next generated statement retains
  the exact Titan source line named there in either mode.
- Ordinary module resolution is compiled-first for dependencies: one complete
  format-preference pass over `.so`/`.a`, then the other compiled format, then
  source. A dependency with no claiming prefix/exact provider but available
  flat/folder source is compiled in and linked directly; a DSO dependency is
  loaded by generated `_init`, while a static dependency contributes its
  selected archive once and generates direct calls. Explicit `titanc` roots
  are forced through source, so the same ordinary rule builds all eighteen
  standard roots from source in one process. There is no separate
  standard-module origin or loader. An import spelling ending in `.titan`
  strips that marker, requires source for the canonical name, and neither
  probes nor falls back to a compiled provider; source resolution without that
  spelling remains public-only. Within one source root folder beats flat;
  source roots retain left-to-right precedence. Once an immediate constituent
  is recognized as private to its parent folder module, do not fall through to
  a later root; for ordinary resolution all compiled candidates were already
  considered, while an explicit source request deliberately considers none, and
  a genuine requested deeper folder was already considered first. Every compiled module exports
  `luaopen_<mangled>`, `<mangled>_init`
  (idempotent), `<mangled>_abi` (returns `TITAN_ABI_VERSION`; checked before trusting a
  provider), and `<mangled>_types` (serialized interface type, evaluated with
  `types.lua` as env). For an explicit root, `titanc` gives code generation the
  finalized invocation-wide direct set so every linked source peer and
  physically carried static peer is wired directly while DSO dependencies
  stay dynamic. Library mode derives one provider from the requested roots,
  sorts/deduplicates that source-object union, publishes a `.so`/`.a` pair,
  and emits one shim per logical source module.
- Installed and checkout driver modes both link `libtitan.a`, never
  `titan.o` directly. The installed path is
  `<root>/lib/titan/0.6/libtitan.a`; checkout
  mode lazily rebuilds and links `titan-runtime/libtitan.a`. The archive
  contains exactly `titan.o` and `minicoro.o`. The vendored
  `libbacktrace.a` is a separate final-link input; neither archive is copied
  into an ordinary generated provider archive. `ltitanlib.c` is compiled into
  `ltitanlib.o`; that object alone forms the private support bootstrap and is
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

`foreign import "header.h"` invokes a pure-Lua C toolchain: `cpp.lua` (full hand-written preprocessor; asks the configured `CC -std=c99` plus parsed `TITAN_EXTRA_CPPFLAGS` for system include paths and predefined macros), `c99.lua` (relabel C99 grammar; module-global typedef table, not reentrant), `ctypes.lua`/`cdefines.lua` (build a TypeList), and `cdriver.lua` (include resolution plus C type extraction). The checker passes the importing Titan source directory and the shared toolchain configuration to `cdriver`, which emits quoted `#include "..."` syntax only when the header is found by the quoted-include rules relative to that source; otherwise generated C uses angle brackets. `cdriver` also exposes `titan-runtime/titan/ffi.h`, which defines selected `titan_ffi_*` aliases for portable C primitive types. Contextual conversions and C operators use one resolver-owned `cprobe.Service`: its compile-only probes share the generated objects' exact parsed `CC`, C99/CPP/target flags, include ordering, and target arithmetic profile. Rich answers remain session-scoped and never enter the pure gradual-consistency/coercion relations or serialized module types. Production services persist only successful probes as empty `<sha256(exact probe C)>.success` markers under the ABI-owned prefix cache; marker presence is the whole verdict and rejection is never persisted. This intentionally keys no compiler, flag, environment, or header state. Stable local rebuilds and CI reuse their selected trusted cache folder; change `TITAN_PROBE_CACHE_IDENTITY`, use another prefix, or clear the markers when build-policy isolation is required. An explicit source import keeps its unique randomized physical checking header, but probes include a stable private-workspace wrapper keyed by logical module/absolute eventual public-header identity; that wrapper includes the physical file by absolute quoted spelling, preserving nested quoted origin. Keep every header-context descriptor field stable, perform marker lookup before creating the workspace/wrapper, reject conflicting bindings, and treat wrapper failures as infrastructure. Do not add dependency manifests, preprocessing, verdict payloads, or negative-result records.

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
The preprocessor's final object-like definition set is an unordered map:
`cdefines` projects its supported members into the TypeList in
`util.bytewise_less` order. Do not use process-random `pairs` order or
locale-sensitive ordinary string sorting there, because that makes otherwise
identical declaration-batch probe C miss exact-source success markers.
Declaration extraction still preprocesses each foreign header independently,
while probes and generated C see the cumulative ordered header block, so
conditional macro coupling and later changes to scalar macros typed by an
earlier import belong behind one umbrella header imported once.

`foreigntypes.convert` maps C declarations to the `Type.C*` family (`CVoid`, `CInteger`, `CFloat`, `CPointer`, `CArray`, `CStruct`, `CUnion`, `CFunction`, `CTypedef`, `CModule`, and owned storage wrappers). C imports are namespaces, not first-class values: the checker represents them as `Type.CModule` (renamed from the prototype's foreign-module type), typedef-qualified names such as `c.T` may be used in local annotations, and `types.serialize` rejects any exported function/method/variable type that mentions a C FFI type. An eligible named file-scope tag-only `struct T` or `union T` is published as the base-name Titan type `c.T`, but remains its canonical `CStruct`/`CUnion` and generates exact tag spelling; do not invent a `CTypedef`, header alias, or ordinary C identifier. A real same-name typedef always wins. C aggregate fields, C array indexing, `#` on static arrays and counted owned buffers, and explicit C vararg calls are implemented; C array indexing is 0-based, bounds-checked for `CArray` and counted `COwned`, and null-checked but otherwise unchecked for raw `CPointer`. Object-pointer conversions, C arithmetic, relational/equality, bitwise, and shift operators, C promotions, and mixed Titan/C operands follow the target profile plus the contextual probe policy; they do not reuse Titan's Lua-semantics operator helpers. Titan's `and`/`or`/`not` remain excluded from C-mode operators.

Source modules remain ordinary separate C translation units compiled with the
same configured compiler and flags. Generated C includes every header directly
foreign-imported by that module plus normalized origin headers reached from C
types whose declarations codegen actually renders. Retained typedefs and
aggregates stop at their own spelling; `owned` values render as `Udata *` and do
not collect payload origins until a real payload cast/access. C operator and
unsafe-pointer probes use the same direct-plus-rendered-origin rule. Do not
propagate a blanket source-module header or preprocessing closure, compare
cross-TU macro/layout/attribute state, or give header order semantic meaning.
Direct and supplemental quoted headers must both use the same normalized
`include.rendered` spelling.

A C enum is nominal and is never lowered through the parser's provisional
`int`. On first value use, the configured compiler must select an ordinary
carrier whose complete range fits `lua_Integer`; unused unsafe enums remain
inert. Probe the exact use surface (retaining an outer typedef) in the
consumer's direct-plus-rendered-origin context; never let one alias/module
context cache certification for another. Every enumerator expression, including
one from a tagged enum, is checked independently through exact
`__typeof__((NAME))` spelling for an ordinary carrier and exact value range, and
keeps that carrier through C operators. Only enumerator-to-owning-enum adjusts
implicitly. Calling a C function pointer triggers the same checks on its
by-value enum parameter/result graph; a pointer to a spellable wide enum needs
only spelling validation. Transparent Titan aliases do not force a carrier and
must defer that choice to their eventual use. Directly named qualified anonymous
enum objects use an exact unqualified, nonpromoting value spelling while every
object declarator from one anonymous enum retains the same canonical owner; an
unspellable prototype enum fails closed even below a pointer. Signed/unsigned
`__int128` are not candidates and Titan has no wide-enum integer lowering.

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
Every function-local C object still requires an initializer. `.new()` and
`.new_array(...)` request zeroed storage; at their direct local declaration sink
a complete non-pointer struct/union or positive-literal fixed array may select
automatic storage. Its lifetime is the generated C block, no escape analysis is
attempted, and aggregate values are spilled through volatile byte storage
around catchable Titan calls so normal-return mutation commits while a caught
longjmp reloads the last Titan-visible state. Owned allocation rejects `void`,
incomplete aggregates, direct functions, nested owners, and C array-typedef
payloads. A complete struct with one flexible-array member instead uses
`T.new(count)` as a scalar owner (or automatic object for a nonnegative literal);
arrays of variably extended objects remain unsupported. Automatic fixed storage
accepts imported array-typedef and nested-array shapes but rejects void,
incomplete, and GC-bearing objects. Imported/static C functions can
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
bind, and connect submission. Their plain-C libuv-shaped callbacks are
source-defined foreign functions in the owning semantic contributors. Each
callback recovers the exact rooted owner and invokes its exact Titan handler;
there is no runtime shim header, generic dispatcher, or event-kind argument.
Normalized-address storage remains deliberately overprovisioned. Titan
initializes public `uv_buf_t` fields directly through the FFI, using Titan's
documented direct `string`-to-`char *` conversion for libuv's historically
mutable spelling of borrowed write bytes. The callback owner retains the
original string throughout that exceptional asynchronous borrow.

The conditional inherited-`SIGPIPE` policy is implemented in
`titan/uv/uv.titan` through direct `signal.h`/`errno.h` FFI calls and
`uv_translate_sys_error`. Operational
libuv wrappers, including the old DNS/address helpers, must not return.
Generated standard-module objects own the callback definitions; the runtime
exposes no retired operational helper. Generated modules and runtimes built for
different ABIs must not be mixed.

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
continuation, dispatches the next yielded operation, and returns. A condition
callback that publishes through owner state retains that direct path unless a
public-resume timer already owns the continuation; it then leaves that timer as
the sole wake rather than advancing into a later suspension. If a callback
failure retires the Task first, that timer's completion clears its pending bit
and does not reenter the terminal coroutine. Every one-shot timer callback
instead submits `uv_close`; only `close_cb`, after the native owner is released,
resumes its suspended Task. Explicit Task resume, external
cancellation of `async.suspend`, repeating-ticker delivery, and other deferred
continuations may use such a Task-owned one-shot timer. The delivery is
callback-deferred but does not promise one exact libuv iteration. An uncaught
error retires and logs only its Task; the task-root set decides whether it was
the last user Task. Public Task state is the `TaskStatus` union with live
`ready`/`running`/`waiting` variants plus exact success, `Error` failure, and
terminal `CancellationReason` payloads. `Task:cancel` stores its first reason
privately until terminal `cancelled` and invokes the current cancellation
action without a public `cancelling` state.

`Task<A,B>`, `TaskStatus<A,B>`, and `CancellationReason<B>` are the public
owners, while Runtime roots, waiters, callbacks, and `running()` deliberately
use the bare all-`value` Task application. Task terminal publication first
stores the final status, detaches the registration Array as a stable snapshot,
installs an empty live list, and clears every snapshot registration's live
ownership. It then runs every snapshot listener sequentially in registration
order on the main thread and ignores each listener error independently; a
remover called during delivery cannot mutate the snapshot or skip a later
callback. Fixed-arity async combinators preserve the independent generic type
pair of every named operand, install a separate listener for each still-relevant
operand, suspend once, and call every idempotent remover in `defer`. The deciding
listener calls the suspended Task's synchronous,
coalescing `resume()`, which installs its target-owned close-before-resume zero
timer and returns. There is no public Waiter, `uv_check_t`, Runtime `uv_idle_t`,
polling loop, phase bridge, taskless timer, scheduler queue, join protocol, or
generation fence. Never collapse the separate typed operands into a `{Task}`
helper. Only `join`
has a unary form; unary `any`/`race`/`all` would be mere result repackaging and
are intentionally absent. The combinators do not cancel unfinished inputs.

Runtime cleanup discovers handles exclusively with `uv_walk` and closes them
with `uv_close`. A `uv_file` is a process descriptor, crosses Runtime sessions,
and is never registered for shutdown. `titan.uv` keeps it as a source-local
alias to `libuv.uv_file`; the high-level `fs.File` facade owns the raw
descriptor, its closed sentinel, and delimiter excess. It marks the sentinel
before an accepted close can suspend, restores it only on a pre-commit failure,
and reloads the field for every short-write submission so a concurrent close
cannot leave a recycled descriptor integer in use. Closing a `uv_process_t`
watcher neither
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
  `after_each` and the shared application helpers clean them. These cases consume the prepared runtime archive; standard-library native
  tests and fixtures must not invalidate that shared Make-owned image. Set
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
