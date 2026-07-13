# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Titan is a statically-typed, ahead-of-time-compiled sister language to Lua. This repo is the prototype compiler, written in Lua, that translates `.titan` modules to C and invokes the system C compiler — producing either a shared library per module (loadable from Lua via `require` and from Titan via `import`) or, when exactly one requested module defines `main(args: {string}): integer`, a standalone executable bundling all modules. The language reference is `doc/language/index.md`; the implementation documentation (lexer/parser, checker, code generator, interop machinery) is `doc/implementation/index.md`. **When you add or change a user-visible language feature, update BOTH manuals as part of the same change** — typically a new `doc/language/<feature>.md` chapter (user-facing syntax/semantics) and a `doc/implementation/<feature>.md` chapter (parser/checker/coder/GC internals), each linked from the respective `index.md`; the variadic-parameters feature is the model (`doc/language/variadic-parameters.md`, `doc/implementation/variadic-parameters.md`). Treat the docs as part of "done," not a follow-up.

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
  `PREFIX=$HOME/.local/titan/titan-dev`. `make lua` patches Lua 5.5.0's
  `LUA_ROOT` to that prefix and patches `loadlib.c` so the exact
  `luaopen_titan_uv` entry is globally visible while other required C modules
  remain local. It builds and installs Lua there and copies its matching `.c`
  and `.h` files to `$PREFIX/src/lua-5.5.0/`; `make luarocks` builds and installs
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
- **CI runs a macOS canary on every push and the complete macOS suite on
  manual dispatch.** The push canary combines the system/bundled libuv runtime
  smokes, fixed native ABI tests, and a commit-seeded 5% sample of each
  compiler/language spec file. A manual `workflow_dispatch` replaces that
  sample with the complete uncovered macOS suite; use it as the **pre-merge
  check** with `gh workflow run ci.yml --ref <branch>`. Linux jobs are
  push-only and are not repeated by that macOS dispatch. The regular Linux flow
  uses two 1-core `ubuntu-slim` jobs designed to remain below that runner's
  15-minute limit. The regular build job runs compiler/language plus
  serial and net/OS tests on its warm tree, and uploads a same-run, full-tree
  tar artifact for one uv/timer/fs consumer. The sanitizer job keeps its build
  and focused native-memory gate on one warm runner: representative timer/fs
  suites, core owner/callback proofs, and production net/OS smokes. Keep full
  transformed library fault suites in regular Linux unless they exercise a
  distinct sanitizer-sensitive boundary; recompiling them under sanitizers
  can consume the complete runner limit without improving that gate. Keep each
  Linux dependency build in the job that consumes its warmed tree, and keep
  the Linux production mode smokes in the regular producer: rebuilding them
  in a consumer wastes aggregate billed runner time even when the workflow's
  wall-clock critical path is unchanged. Pack the regular artifact before the
  mode smoke replaces the bundled `titan/uv.so`, but upload it only after both modes
  pass; repacking the system-linked tree makes every facade stale and shifts
  recompilation into a consumer. The full-tree archive is intentional because
  partial output archives lose source/output timestamp ordering and trigger
  Make rebuilds; it also preserves the prepared Lua installation, executable
  bits, and standard-library images. Run the serial and net/OS library groups
  before compiler coverage in that producer. Legacy compiler specs still
  clean root-generated module outputs; running the packaging gate first avoids
  rebuilding the complete standard library without exercising a new
  configuration. The complete macOS flow likewise runs the library
  group before its uncovered compiler group. CI snapshots and restores the
  prepared runtime artifacts and the canonical installed standard DSOs around
  compiler-only groups so root output cleanup cannot stale or remove the
  production image before the mode smoke. Compiler and language specs must not
  delete the shared checkout runtime archive merely to force recompilation;
  Make owns that dependency state. The serial coroutine suite is the isolated
  exception described below.
- **A local Titan prefix prepared by `make lua`.** The checkout keeps the
  gitignored `./lua-5.5.0` build tree, while the installation contains the
  same patched internal sources under `$PREFIX/src/lua-5.5.0/` and the
  matching `$PREFIX/lib/liblua.a`. Generated C includes Lua internal headers
  (`lobject.h`, `lgc.h`, `lvm.h`, ...) from that installed source tree and
  links the matching archive. The patched `luaconf.h` is also the public
  configuration used when this LuaRocks builds other Lua libraries and Titan
  packages. `make lua` uses `MYCFLAGS=-fPIC` and selects `linux`/`macosx`
  from `uname`; override with `make lua LUA_PLATFORM=...`, and use `LUA_CC`
  for Lua's compiler. Its configuration stamp cleans Lua objects whenever
  `PREFIX`, `LUA_PLATFORM`, `LUA_CC`, or a `LUA_MY*` input changes.
- **Lua deps and rock installation**: `$PREFIX/bin/luarocks make
  titan-dev-1.rockspec` installs lpeglabel, inspect, argparse, luafilesystem,
  plus the `titan` Lua support module (`titan.backtrace()`). The rockspec
  keeps `build_target = "titan"` and disables LuaRocks' separate Make install
  pass. It derives the rocks tree from `$(SCRIPTS_DIR)/..` and passes it as
  `ROCKS_TREE`: `make titan` always builds `libtitan.a` and `titan.so`, and
  only a rock build with a nonempty `ROCKS_TREE` also copies the matching Lua
  sources, native archives, and SDK headers into that tree. `libtitan.a`
  contains exactly `titan.o`, `titan_coro.o`, and `titan_uv.o`;
  `libbacktrace.a` remains a separate vendored archive; and `titan.so` is
  linked solely from `titanlib.o`, compiled from `titanlib.c`. The non-Lua
  headers staged under
  `$ROCKS_TREE/include` are `minicoro.h`, `titan.h`, `titan_longjmp.h`, and
  `titan/{ffi,coro,uv}.h`; bundled mode also stages `uv.h` and `uv/`. Its
  `libuv.a` remains a private source-build artifact used only to link canonical
  `titan/uv.so`, never an installed SDK archive. A direct developer
  `make titan` only builds. After
  LuaRocks deploys the compiler, the
  source-only `post_install` hook invokes the standard-library install target,
  which deliberately uses the just-installed `titanc`. There is no
  `pre_install` hook. Each standard DSO is installed exactly once at
  `$ROCKS_TREE/lib/titan/0.11/titan/<module>.so`; Titan imports and Lua
  `require "titan.<module>"` load that same canonical file. The Titan-owned
  Lua's patched default `package.cpath` places
  `$PREFIX/lib/titan/0.11/?.so` before its ordinary `lib/lua` templates. No
  symbolic links, hard links, Lua-facing copies, or parent-level compatibility
  copies are used. These direct SDK/stdlib files are
  outside the rock manifest and are not removed by `luarocks remove`;
  binary-rock ownership is deferred until Titan has a library/application
  packaging story. The
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
make lua                                            # build/install patched Lua and matching source headers
make luarocks                                       # build/install LuaRocks for that Lua
make libuv                                          # build pinned static PIC libuv (bundled default)
"$PREFIX/bin/luarocks" make                        # build/install Titan runtime, compiler, and stdlib
make stdlib                                         # checkout-only standard build: coroutine -> uv -> timer/fs/net/os
make test                                           # `luarocks make` + `luarocks test`: (re)install the rock, then run the full suite
luarocks make && bash spec/support/ci_test_groups.sh compiler  # CI's covered compiler/language group
bash spec/support/ci_test_groups.sh libraries       # CI's complete uncovered library group
bash spec/support/ci_test_groups.sh macos-canary SEED # replay the sampled macOS test gate locally
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
gates also live there (`libuv_build_spec`, `libuv_shim_spec`,
`rockspec_spec`). Compiler and language specs are split by layer:
checker-only specs (run the checker, never generate or execute code) live
under `spec/checker/`, while compiler end-to-end specs (generate C, compile,
run) live under `spec/coder/`. Standard-library API, runtime, fault, and
packaging behavior lives under `spec/stdlib/`, including `coroutine` and the
async-I/O modules; these suites deliberately run without LuaCov. Do not put a
library integration suite under `spec/checker/` or `spec/coder/` merely
because it typechecks or compiles Titan source. If it reveals missing compiler
coverage, add a small compiler-focused case for that path instead. A sizable
compiler feature gets its own topical `<feature>_spec.lua` in the relevant
layer rather than bloating `checker_spec` or `coder_spec`.

All driver/artifact paths inside specs are relative to the repo-root CWD (not
the spec file), so subdir specs still run from repo root. The shared
compile/run/import scaffolding (`parse`, `compile`, `call`, `run_coder`,
`generate_modules`, `build_so_chain`, `check_against_so`, `run_checker`,
`check_errs`, `DEPTH_PROBE`, ...) lives in **`spec/support/helpers.lua`**,
`require`d as `spec.support.helpers`; libuv runtime tests use
`spec/support/phase2.lua` plus the filesystem, networking, and OS/signal
extensions `spec/support/phase3.lua`, `spec/support/phase5.lua`, and
`spec/support/phase6.lua` to compile into unique `/tmp` workspaces while
treating Makefile-owned standard DSOs and the libuv archive as read-only.
These helpers may not clean or rebuild shared root artifacts during Busted.
Helpers pull in luassert explicitly (`require 'luassert'`) because a
`require`d module does not inherit busted's `assert` global. Set
`helpers.verbose = true` (was a per-file `local verbose`) to print `cc`
command lines and keep generated `.c` files.

New or modified specs that generate compiler fixtures in the repository root
must remove only their exact module artifacts and must treat
`titan-runtime/libtitan.a` as shared Make-owned state. The grouped CI commands
also snapshot and restore the prepared runtime and canonical standard-library
images around legacy compiler suites that still clean root artifacts; later
production smokes deliberately consume that restored image.

The serial `spec/stdlib/coroutine_spec.lua` suite temporarily exercises its
root build path, but must
restore the prepared runtime/coroutine artifacts and mtimes in teardown so a
later packaging test does not rebuild the whole standard library.

Filesystem transition faults live in
`spec/stdlib/fs_fault_spec.lua`; its isolated source transformer is
`spec/support/make_fs_test_variant.lua`.

Networking transition faults use `spec/stdlib/net_fault_spec.lua` and the
isolated `spec/support/make_phase5_test_variant.lua` transformer.

OS/signal, checked-buffer, and child-process transition faults use
`spec/stdlib/os_signal_fault_spec.lua`,
`spec/stdlib/os_helpers_fault_spec.lua`,
`spec/stdlib/os_process_fault_spec.lua`, and the isolated
`spec/support/make_phase6_test_variant.lua` transformer.

The Phase 5 and Phase 6 helpers compile each identical transformed standard
image once per Busted process, retain the pristine template in the Lua
registry (so it survives per-file insulation), and give every suite an
independent `cp -Rp` clone. Keep fixture sources and generated artifacts in the
returned workspace; never mutate or hard-link the cached template. Cache keys
include the compiler and sanitizer flags, and Lua-state shutdown removes the
templates.

`titanc` takes dot-separated **module names**, not file paths (dots map to
directory separators under `--tree`, default `.`). It recovers the Titan
SDK/rocks-tree root from the first `package.cpath` template ending in
`/lib/lua/5.5/?.so`; that works because the supported install currently sets
`ROCKS_TREE == PREFIX`, not because the two owners are inherently identical.
Compiled-module lookup defaults to `.;<root>/lib/titan/0.11`, with
`TITAN_PATH_0_11`/`TITAN_PATH` overriding that ordinary path. The standard
library uses ordinary qualified module names: source files are
`titan/<module>.titan`, installed binaries are
`<root>/lib/titan/0.11/titan/<module>.so`, and `import "uv"` is parser sugar
for `import "titan.uv"` (likewise for `coroutine`, `timer`, `fs`, `net`, and
`os`). A checkout build therefore invokes roots such as `titanc titan.uv` and
uses the directory containing `titan/` as its Titan path. Dependencies resolve
binaries before sources; modules explicitly named on the `titanc` command
line are the generic exception and are built from source.

The compiled-module ABI version is `0.11` (bumped from `0.10` when
module-local records and record members changed `<mangled>_types`
serialization to omit local records/members while preserving record
field-slot counts; `0.10` itself was bumped from `0.9` when the `TitanVargX`
family changed from inline flexible-array backing objects to
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

Pipeline (all in `titan-compiler/`): source text → `parser.parse` → `checker.check` → `coder.generate` → `pretty.reindent_c` → `driver` writes the `.c` **next to the `.titan` source** and invokes the parsed `CC` command with each argument shell-quoted. `TITAN_EXTRA_CPPFLAGS` precedes the defaults and is shared with foreign-import probes, `TITAN_EXTRA_CFLAGS` is compile-only, and ordered `TITAN_EXTRA_LDFLAGS` is final-link-only. `titanc` orchestrates: typecheck everything first, exit 1 with all errors before any codegen, then compile and link.

### The `_tag` / typedecl convention (cross-cutting)

AST nodes (`ast.lua`) and types (`types.lua`) are plain tables created by `typedecl.lua` constructors: positional, arity-checked args producing `{_tag = "Ast.ExpCall", ...}` / `{_tag = "Type.Integer", ...}`. All dispatch is string comparison on `_tag`. `util.make_visitor` **asserts** a handler exists per tag — adding an AST tag means updating every checker visitor (`checkstat`/`checkexp`/`checkvar`/`typefromnode`/toplevel) and the coder's if/elseif chains; adding a Type tag means updating `types.tostring`/`equals`/`compatible`/`serialize` by hand. Group names in `ast.lua` (Exp, Stat, ...) are documentation only — they don't appear on nodes.

### Frontend (`lexer.lua`, `parser.lua`, `syntax_errors.lua`)

Lexing and parsing are fused in one LPegLabel/relabel grammar; `lexer.lua` exports raw LPeg patterns referenced as `%TOKEN` terminals (no token stream). Every AST constructor is auto-injected into the grammar's defs table, so grammar actions like `-> TopLevelFunc` call constructors directly. Every error label used in the grammar (`^Label`, `%{Label}`) or lexer (`lpeg.T`) **must** have an entry in `syntax_errors.errors` or error formatting breaks. The parser is not reentrant (module-global `THIS_FILENAME`, asserted nil on entry). `record` declarations are desugared at parse time into a `TopLevelRecord` plus a synthesized `new` static function. Short standard-library imports are also parser sugar: `coroutine`, `uv`, `timer`, `fs`, `net`, and `os` become the ordinary qualified module names under `titan.*` before module resolution.

### Checker (`checker.lua`, `types.lua`, `symtab.lua`)

`checker.check(modname, ast, subject, filename, loader) -> moduletype, errors`; callers test `#errors == 0` (the doc comment claiming a boolean return is stale). Two passes over toplevels: signatures first (duplicates get `node._ignore = true` — later passes must skip these), then bodies. The checker both annotates (`_type`, `_types` for multi-return calls, `_decl` on variable uses, `_used`/`_assigned`) and **mutates** the AST:

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

`checkstat` handlers return a boolean "always returns", used to enforce that non-nil-returning functions return on all paths. Imports go through a `loader` callback (`driver.defaultloader` for real lookup, `driver.tableloader` for in-memory sources in tests); source deps are recursively typechecked, `.so`-only deps first check the compiled `<mangled>_abi` marker, then recover their interface from the compiled `<mangled>_types` symbol.

**Process-global mutable state** — tests and tools must reset these:
`types.registry` (FQTN → `Type.Record`; `Type.Nominal` carries only the FQTN
string and resolves through the registry at every use), `driver.imported`
(import cache with a `CIRCULAR_MARK` sentinel for cycle detection), and
`driver._uv_provider_path` (the canonical `titan/uv.so` identity loaded while probing
a direct-libuv DSO). Tests must save/restore all three together. A real
long-lived compiler must retain the provider path and reject a request that
would switch to another provider in the same process; clearing the Lua field
does not unload the native image.

### Coder and driver (`coder.lua`, `pretty.lua`, `driver.lua`)

`coder.generate(modname, ast, static_deps)` produces one C translation unit as a string — no C AST, just `util.render` templates (`$VAR` substitution, recursive; error on missing keys). Key facts:

- Each Titan function becomes **two** C functions: a raw native-convention one (`RETTYPE f(lua_State *L, Udata *_mod, CClosure *_fn, params..., out-params for returns 2..n)`; the **caller** anchors GC-able arguments on the Lua stack) and a Lua-stack entry wrapper that coerces arguments and installs the error handler. `_fn` is the function value's own closure (still a `CClosure`): `NULL` on fully-static top-level calls, and the callee itself on first-class/closure/value calls; for anonymous functions it carries the captured variables (this uniform parameter is what bumped the module ABI to `0.6`). `_mod` becoming `Udata*` and record instances becoming a single `Udata` (so every record-typed param/return changes C type and `<mangled>_init` returns `Udata*`) is what bumped it to `0.7`; the ABI then bumped to `0.8` when a record's type tag became its metatable pointer (no `getudatamem` payload), to `0.9` when a variadic function's native signature gained the trailing `TitanVargX *_varargs, int _start` pair (after the declared params, before the out-params) and `<mangled>_types` began encoding the `varargtype` element type, to `0.10` when the `TitanVargX` structs changed from inline flexible arrays to descriptor structs with an `args` pointer, and to `0.11` when local records/members changed record interface serialization.
- Module state is a `Udata` (`_mod`), allocated with `luaS_newudata(L, 0, NUPVALS)`: there is no reserved user value; the module's user values (0-based) hold module globals, exported-function canonical closures, imported-module `Udata`s, record metatables, and per-record static-namespace tables. There is **no** Lua-facing module table — `require` returns the module `Udata` itself (so `type(require "m")` is `"userdata"`), and all member access (functions, variables, record namespaces `m.Rec`) flows through a metatable `__index`/`__newindex` over a unified name→slot member map; functions and record namespaces are served read-only (assigning errors), variables coerce in/out, and the "not found" message is "member '%s' does not exist". A record instance is likewise a single `Udata` (fields in `uv[0..N-1]`, type identity is its metatable pointer (no raw payload), metatable on the udata).
- Typedef-resolved pointers to Lua's internal `Udata` are GC-bearing FFI
  values, not ordinary C pointers: boxing a non-NULL `Udata *` emits a full
  userdata `TValue` for that same object, NULL boxes as nil, and unboxing
  accepts full userdata or nil rather than lightuserdata. Owned C
  pseudo-constructors (`T.new()` and `T.new_array(constant_count)`) are valid
  top-level initializers and keep their userdata rooted in the module state.
- **Semantic state must live in the Lua registry or GC-traced Lua objects, never
  in shared C globals.** The standard library has one canonical installed DSO
  per module, shared by Titan imports and Lua requires. Canonical
  `titan/uv.so` is
  the sole complete bundled-libuv provider. A Titan extension DSO that directly
  foreign-imports libuv must also `import "uv"` (desugared to
  `titan.uv`), leave its `uv_*`
  references unresolved, and let the optional second `"uv-provider"` result
  from `<mangled>_types` classify it as `"dynamic-uv"`. The coder emits that
  marker for `titan.uv` or a `"dynamic-uv"` dependency, so classification
  is stable even when a provider is already visible. Reading it establishes or
  validates canonical `titan/uv.so` and its compiler-process identity. An
  open-stage unresolved `uv_*` error is the bootstrap fallback: load canonical
  `titan/uv.so`,
  retry, and then require the marker. Reject the binary if it is absent: it
  was not built with the required explicit `titan.uv` import. Generated Titan
  consumers use `loadlibwithuv` to load canonical `titan/uv.so` globally before
  mapping that extension; unmarked ordinary DSOs remain eager/local. A Lua caller
  must `require "titan.uv"` before requiring such an extension. The
  Titan-owned Lua's patched `loadlib.c` opens a DSO globally only when its
  requested entry symbol is exactly `luaopen_titan_uv`; all other Lua C modules
  remain local, and `titan/uv.so` has no self-dlopen/promotion shim. System mode may
  instead link both against the same pkg-config-selected shared libuv; the
  private bundled `libuv.a` must never be linked into another DSO.
  Provider-first mapping also supports eager data/function-address relocations
  and native constructors. A compiler process records the provider's canonical
  path and rejects an attempt to switch providers.
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
  binary but available `.titan` source is compiled in and statically linked;
  a binary dependency is dlopened at runtime by the generated `_init`.
  Explicit `titanc` roots are forced through source, so the same ordinary rule
  builds `titan.uv` from `titan/uv.titan` while its already-built qualified
  dependencies remain binary. There is no separate standard-module origin or
  loader. Every compiled module exports `luaopen_<mangled>`, `<mangled>_init`
  (idempotent), `<mangled>_abi` (returns `TITAN_VER`; checked before trusting a
  `.so`), and `<mangled>_types` (serialized interface type, evaluated with
  `types.lua` as env, plus optional `"uv-provider"` dependency metadata). For
  an explicit root, `titanc` gives code generation the full recursive source
  dependency closure, so that metadata propagates from `titan.uv` or a
  `"dynamic-uv"` dependency used by a statically linked source dependency.
- Installed and checkout driver modes both link `libtitan.a`, never
  `titan.o` directly. The installed path is `<root>/lib/libtitan.a`; checkout
  mode lazily rebuilds and links `titan-runtime/libtitan.a`. The archive
  contains exactly `titan.o`, `titan_coro.o`, and `titan_uv.o`. The vendored
  `libbacktrace.a` is a separate link input. `titanlib.c` is compiled into
  `titanlib.o` and that object alone is linked into `titan.so`; its public
  `backtrace` function and internal testing helpers `pin` and `clear` are not
  part of the generated-code archive.
- In `minicoro.h`, sanitizer detection must remain before the public
  `mco_runtime`/`mco_coro` declarations. Gate ASan and TSan bookkeeping fields
  with their matching feature macros so ordinary builds carry no sanitizer
  words, and compile every translation unit sharing those layouts with the
  same sanitizer configuration.
- **Operand expressions are not auto-hoisted: a template that references one more than once multiply-evaluates its side effects.** `codeexp` returns `(stats, expr)` and for a non-GC return `codecall` puts the bare call *in `expr`*, not in `stats` — so a `render` template that splices an operand into several slots (as the naive integer `//`/`%`/shift templates did) calls a side-effecting operand like `f() // g()` multiple times, unlike Lua which evaluates each once. Materialize each operand into a temp first (the pattern in `codebinaryop`'s `and`/`or` arms, the shift/idiv/mod helpers, and the mixed int/float comparison branch).

### C FFI (`c-parser/`, `foreigntypes.lua`)

`foreign import "header.h"` invokes a pure-Lua C toolchain: `cpp.lua` (full hand-written preprocessor; asks the configured `CC -std=c99` plus parsed `TITAN_EXTRA_CPPFLAGS` for system include paths and predefined macros), `c99.lua` (relabel C99 grammar; module-global typedef table, not reentrant), `ctypes.lua`/`cdefines.lua` (build a TypeList), and `cdriver.lua` (include resolution plus C type extraction). The checker passes the importing Titan source directory and the shared toolchain configuration to `cdriver`, which emits quoted `#include "..."` syntax only when the header is found by the quoted-include rules relative to that source; otherwise generated C uses angle brackets. `cdriver` also exposes `titan-runtime/titan/ffi.h`, which defines selected `titan_ffi_*` aliases for portable C primitive types.

`foreigntypes.convert` maps C declarations to the `Type.C*` family (`CVoid`, `CInteger`, `CFloat`, `CPointer`, `CArray`, `CStruct`, `CUnion`, `CFunction`, `CTypedef`, `CModule`, and owned storage wrappers). C imports are namespaces, not first-class values: the checker represents them as `Type.CModule` (renamed from the prototype's foreign-module type), typedef-qualified names such as `c.T` may be used in local annotations, and `types.serialize` rejects any exported function/method/variable type that mentions a C FFI type. C aggregate fields, C array indexing, `#` on static arrays and counted owned buffers, and explicit C vararg calls are implemented; C array indexing is 0-based, bounds-checked for `CArray` and counted `COwned`, and null-checked but otherwise unchecked for raw `CPointer`.

Owned C objects are Titan-owned Lua userdata payloads allocated by the generated `.new()` and `.new_array(count)` pseudo-functions on C types. They are zeroed, anchored on the Lua stack during initialization, stamped with a per-owned-C-type metatable for `value` cast checks, and need no finalizer because the Lua GC owns the payload; dynamic array counts are reconstructed from `Udata.len`. Allocation rejects `void`, incomplete aggregates, C array typedefs, and structs/unions with flexible array members in this iteration. `CAdopted`, C callbacks/function pointers, and stronger Lua C API coverage are parked follow-ups. `typed.lua` (used only by c-parser) is a runtime signature-checking DSL that ships **disabled** — `typed.off()` is the last line; flip to `typed.on()` to debug c-parser type confusion.

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
