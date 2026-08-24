# Titan test infrastructure implementation record

This record accompanies the designer's verbatim draft in
[`test-runner.md`](test-runner.md). The draft remains the authority. This file
records repository research, the detailed implementation plan, validation, and
any eventual divergence from the draft.

## Status

- Branch: `feat/test-runner`
- Draft-only initial commit: `eed38db` (`Add draft Titan test runner specification`)
- Phase: implementation published; explicit-Runtime and zero-Lua-stdlib follow-up in local validation
- ABI decision: retain the current marker; the canonical seventeen-key pair is
  a supported bounded transactional predecessor
- Architecture decisions: reviewed and closed in
  `/tmp/titan-test-runner-design-decisions.md`
- Implementation divergences: recorded below

## Existing invariants to preserve

1. `titanc` checks every requested logical root through one
   `driver.defaultloader`, then calls `driver.finalize_resolver_context`, compiles
   each source module exactly once, and chooses provider mode or standalone mode
   based on an exact `main(args: {string}): integer`. Test mode should reuse this
   pipeline rather than create a second compiler driver.
2. Ordinary dependencies are compiled-provider-first; explicit command-line
   roots are source roots. Test mode is the one deliberate source-first
   dependency policy. Ordinary invocations and `--static`'s ordering between
   `.a` and `.so` must remain unchanged.
3. Direct source visibility is a capability carried by the loader result. It is
   direct-only and never reconstructed from metadata or physical co-residence.
   The generated runner must source-import every module that owns a discovered
   test and must source-import the canonical `titan.test` implementation when
   using its runner-private declarations.
4. Every source module remains a separate translation unit. The synthetic
   `titan.test.runner` is an ordinary in-memory source module with the fixed
   logical identity from the draft; it is not an AST special case, metadata
   sidecar, C entrypoint special case, or contributor to another module.
5. A standalone's entrypoint initializes the selected main module and passes an
   Array containing `argv[1..argc-1]`. Test mode should use the same entrypoint
   and native link argument builder.
6. The canonical stdlib is one paired `titan.so`/`titan.a` provider with one Lua
   shim per logical module, installed transactionally. Adding `titan.test` means
   updating every exact module/key/shim manifest, validation fixture, snapshot,
   smoke, Make stamp, and installer assertion together.
7. `titan.test` and the generated runner may use Lua 5.5 and C99 through the FFI
   but may not import another Titan stdlib module. Lua stack balance, GC roots,
   and error preservation remain explicit at every helper boundary.
8. Test modules, not the non-test source modules they import, receive
   `-fno-optimize-sibling-calls`. A module is a test module when it contains a
   discovered public `test_*` function of the required Context parameter shape;
   explicit roots without such a function are not flagged merely because they
   were named on the command line.
9. Compiler/language specs stay under LuaCov. Standard-library behavior remains
   outside LuaCov even after its assertions move to Titan.

## Compiler and driver pointers

- `titanc`
  - argparse declaration and invocation setup;
  - requested-root checking and `main_module` discovery;
  - resolver finalization/source-module compilation;
  - standalone archive probe and `driver.compile_program` call.
- `titan-compiler/driver.lua`
  - installation/source path derivation near `installed_paths`;
  - `resolve_source` and folder/flat descriptors;
  - `new_resolver_context`, `find_dependency_interface`, and
    `defaultloader` (especially the explicit-root and binary-first branches);
  - `finalize_resolver_context` and invocation-wide direct/static sets;
  - `compile_module`/`compile` and `generated_compile_prefix`;
  - `compile_program`/`write_entrypoint` and optional output paths.
- `titan-compiler/checker.lua`
  - `checker.has_main` is the model for checked-AST callable-shape discovery;
  - checked `Ast.TopLevelFunc` nodes carry `islocal`, `_ignore`, and `_type`;
  - `makemoduletype` and `checkimport` establish source-private interfaces.
- `titan-compiler/types.lua`
  - `types.normalize` resolves transparent aliases before comparing the sole
    parameter with `Type.Nominal("titan.test.Context")`.
- `titan-compiler/parser.lua`
  - `standard_imports` gains `test = "titan.test"`.
- Proposed new `titan-compiler/test_runner.lua`
  - checked-AST discovery, deterministic test descriptors, source-template
    hydration, and Titan string-literal quoting. It must be installed by the
    rockspec.

## Detailed compiler design

### `--test` resolution

Add an explicit `source_first` resolver option. For a non-root dependency in
that mode, perform ordinary folder/flat source resolution first. A found or
blocked source result is authoritative; only absence falls through to the two
compiled formats in the existing `prefer_static` order. Keep the current
explicit-root path and ordinary mode byte-for-byte in policy.

The compiler supplies a source override for exactly `titan.test`, rather than
adding the whole Titan checkout/installation source directory to the user's
source path. This prevents `--tree spec` from unexpectedly source-building all
stdlib modules while still letting the synthetic runner see `titan.test`'s
local runner contract. In a source checkout the override reads
`titan/test.titan`; an installed compiler reads the transactionally installed,
library-versioned support source. Missing support source is a test-mode diagnostic,
not an ordinary compiler startup failure.

The loader should support an in-memory source descriptor so the runner passes
through the same parse/check/dependency bookkeeping as a filesystem source.
No temporary `.titan` file participates in module lookup.

### Discovery

After all requested roots and their source closure typecheck successfully, walk
only finalized source ASTs (before adding the runner). A test is an
`Ast.TopLevelFunc` that:

- is not ignored or local;
- has a name beginning `test_`;
- has exactly one fixed parameter and no variadic parameter; and
- has that parameter normalized to nominal `titan.test.Context`.

The draft does not constrain return shape. Generated zero-return wrappers call
each discovered function as a statement, so fixed or flexible results are
ordinarily discarded. Sort descriptors by bytewise full name
`<module>.<function>` for deterministic execution. Duplicate full names cannot
survive the checker's ordinary duplicate rules.

The runner directly imports every test-owning source module, even when it was
only in another root's source closure. This preserves the draft's discovery
scope and direct source identity. It also imports `titan.test` from the exact
source override.

### Synthetic runner and outputs

Generate and check fixed logical module `titan.test.runner`. Reject a user
collision with that reserved test-mode identity. The template owns CLI parsing,
filtering, recursive execution, result counters/lists, and gtest-style
reporting as module-local declarations. Hydration adds only deterministic
imports, zero-return wrappers, and initial test registrations.

The executable uses the first requested root's existing `program_output`
(flat logical path or folder `__main` path), matching the single-main driver's
current output convention. Synthetic `.c`, `.o`, and entrypoint files use an
adjacent explicit `__test_runner` stem so the compiler does not create a
user-owned `titan/test/runner.*` tree. Extend driver output-path parameters
rather than changing ordinary standalone naming.

Ignore ordinary application `main` functions for test-mode main selection: the
synthetic runner is the sole entrypoint, while an application module can still
contain tests. Ordinary mode retains multiple-main diagnostics.

Pass an optional per-module compile flag list through
`compile_module`/`compile`; append `-fno-optimize-sibling-calls` only for the
modules marked by discovery. Do not mutate process-global C flags and do not
apply the flag to the runner, `titan.test`, ordinary source dependencies, the
entrypoint, probes, or selected providers.

### Runner semantics to pin in tests/docs

- Parse `-h`/`--help`, `-v`/`--verbose`, repeated `-f PATTERN`, and repeated
  `--filter=PATTERN`; reject unknown/missing/malformed options before running a
  test. Filters are Lua patterns and combine with OR.
- A filtered parent is not entered, so it cannot discover subtests. An entered
  parent does not automatically include its children; each full child name is
  filtered independently.
- Test bodies register children in order. Children execute after the body and
  before the parent's cleanup stack. Siblings continue after a child failure.
- Body failure or `skip` prevents registered children from running; matching
  registered children are reported skipped. Cleanup still runs LIFO.
- Cleanup registration closes only subtest registration. A captured parent
  Context cannot add children while cleanup runs. Every cleanup is attempted;
  the first cleanup error fails an otherwise passing/skipped test, while an
  earlier body failure remains primary.
- A skip marker is recognized only when raised by the test body. Raising it from
  cleanup is a cleanup failure because descendants may already have run.
- Parent status does not inherit a child's failure; each body/cleanup is one
  reported test, while any failed descendant makes the executable return 1.
- Filtered tests are absent, not skipped. Skips do not make the executable fail.
- Help returns 0; invalid CLI returns 2; test failures return 1; an all-pass or
  all-skip run returns 0.
- Full names may repeat only through repeated subtest names; preserve
  registration order rather than deduplicating them.

These are routine completions of the draft and will be recorded as such unless
the designer changes them.

## `titan.test` design pointers

The final public declarations are:

- `testing`, `verbose`, `location`, `skip`, and `assert`;
- exported `Context` with public `cleanup`, `name`, `log`, and `run` methods.

`log` is the narrow implementation divergence recorded below: it lets a test
emit a flushed, prefixed informational boundary without importing another
stdlib module.

The public record has module-local fields for its full name, ordered child
registrations, LIFO cleanup stack, and registration phase. Its synthesized
constructor is therefore local, which is desirable: only the direct-source
runner constructs contexts. Module-local declarations provide the skip marker,
registered-child descriptor, runner state setter/resetter, traceback scanner,
error renderer, Lua-pattern predicate, and Context drain operations. They stay
out of binary metadata and Lua's public surface.

Use precise Titan Arrays and function types for children/cleanups. Use `value`
only for caught arbitrary errors and reviewed Lua-stack values. Load small,
fixed-signature Lua closures with `luaL_loadstring` + `lua_pcallk` (the callable
implementation of the draft's `luaL_dostring` idea; function-like C macros are
not FFI-callable) for Lua-pattern matching, traceback-line parsing, and numeric
text. Root those closures in module variables and restore the Lua stack with an
immediate `defer` on every path. Render arbitrary errors with `luaL_tolstring`
and a conservative fallback.

`location()` deliberately raises and catches a private marker, scans the raw
unified traceback in innermost-to-outer order, skips frames owned by exact
module `titan.test`, and returns the first remaining native frame. It returns
the exact sentinel tuple when none exists. The runner reuses the same scanner
and adds the failed test's known name when reporting.

Synchronous output may use C99 `putchar`/`fflush` through the FFI so it neither
imports `titan.io` nor relies on nonportable `stdout`/`stderr` macros. No other
Titan stdlib import is permitted in either source.

## Packaging and exact-manifest pointers

Update together:

- `Makefile`: `STDLIB_MODULES`, `STDLIB_ROOTS`,
  `STDLIB_TITAN_SOURCES`, `STDLIB_SHIMS`, comments/counts, clean lists, stage
  creation, configuration identity, and post-install source staging.
- `scripts/stdlib_installer.lua`: exact module/shim set, stage validation,
  backup/commit/rollback plan, and publication of the versioned canonical
  `titan.test` support source.
- the active rockspec: install `titan-compiler.test_runner`.
- `spec/fixtures/stdlib/titan_stdlib_types.lua`: exact `test` interface.
- `spec/fixtures/libuv/stdlib_provider_smoke.lua` and static/system smokes:
  require `titan.test` and prove `testing()` is false outside the runner.
- `spec/libuv_build_spec.lua`, `spec/rockspec_spec.lua`,
  `spec/stdlib_installer_spec.lua`, snapshot scripts, CI preparation, and the
  former seventeen-module/eighteen-entry assertions (now eighteen modules and
  nineteen `luaopen_*` entries).
- `AGENTS.md`, `README.md`, and manuals: module lists, canonical artifacts,
  clean behavior, CI grouping, and short-import set.

The installed support source is part of the same recoverable publication as the
provider/shim set and is committed before `titan.so`; rollback restores its
exact predecessor. It lives under the library-versioned Titan SDK namespace, not
under Lua's public module tree and not as a second runtime module.

## Validation plan

### Focused compiler and runner specs

Add `spec/coder/test_runner_spec.lua` (and small parser/driver cases where layer
appropriate) covering:

- ordinary binary-first behavior unchanged and test-mode source-first choice,
  including malformed/occupied binary candidates being bypassed by present
  source and binary fallback when source is absent;
- local member use through a direct source import;
- discovery from explicit roots and their source closure, rejection of
  lookalike signatures/local functions, alias-normalized Context, deterministic
  order, and test functions whose results are discarded;
- no-main executable generation, application-main coexistence, multiple
  unrelated roots, folder modules, output paths, static-provider fallback, and
  no-test suites;
- test-only sibling-call flag placement from verbose compiler argv;
- pass/fail/skip, arbitrary error rendering, concise/verbose tracebacks,
  `location`, cleanup ordering/error handling, nested subtests, parent failure,
  captured-context rejection, duplicate names, filters, help/errors, and exit
  statuses;
- source/installed compiler support-source lookup and missing/corrupt source
  diagnostics;
- public Lua boundary of `titan.test` and absence of runner-private members.

Extend parser specs for `import "test"` sugar and exact stdlib packaging specs
for the eighteenth module/source artifact. Keep test-runner compiler behavior
in the covered compiler group; keep public library behavior outside LuaCov.

### Dogfooding

Move standard-library API/runtime assertions to module-owned roots under
`spec/stdlib/titan/` (for example `lua.tests`, `peg.tests`, and
`uv.task_tests`). They exercise the installed canonical provider built by
`make test`, while `--test` source-compiles the tests, their ordinary imported
support modules, and private `titan.test` support. Use C/Lua FFI only in narrow
Titan test-support modules for temporary files, process fixtures, and
Lua-boundary checks.

Retain Busted only for compiler, provider-publication, packaging, and native
dependency/build gates. Standard-library implementation/codegen inspection,
source rewriting, provider-cache internals, and redundant FFI/interposition
cases rely on their existing compiler/native-harness owners instead of a second
library assertion. Public host and process behavior is Titan-owned, including
tests that supervise a child.

There are no Lua files below `spec/stdlib/` and no root-level standard-library
`*_boundary_spec.lua` survivors. Fresh-process and parent-stdio behavior uses a
compiled Titan parent, C99 `system` to launch a focused standalone child, and an
explicit temporary result file removed with `defer`. The Makefile now owns one explicit
`TITAN_STDLIB_TEST_ROOTS` manifest with all 22 module roots. `make
titan-stdlib-test-build` compiles them in one
`titanc --test --no-uv-bootstrap` invocation from
`.titan-tests/`; the designated `test.tests` program root owns
`.titan-tests/test/tests`. `make titan-stdlib-test-run` executes
that binary from the repository root, and `make titan-stdlib-test` composes the
two. A `TITAN_FILTER` selects cases only at run time, so repeated focused or
sanitizer invocations reuse the same executable rather than restoring root
partitions.

The Bash timeout helper places each run in its own process group and preserves
the child's status, including a distinct deadline status. Make streams merged
output through a pipe so parent-descriptor tests do not observe a regular file.
Tests that deliberately produce uncaught Task reports surround them with
flushed `Context:log` `BEGIN`/`END expected uncaught async Task diagnostics`
lines. The producing test therefore owns the diagnostic presentation; there
is no native output group supervisor.

Cleanup owns `.titan-tests/` recursively and is generic for source-adjacent
translation units: remove every `.o` below `spec/`, but remove a `.c` only when
its same-stem `.titan` source exists. Reserved synthetic `__test_*` suffixes
derive each test program executable/dSYM, and the root `test_runner_*` namespace
covers interrupted compiler fixtures without a per-test list. This remains safe
without Git metadata and preserves tracked C fixtures. The native suite owns
fresh-state coroutine API behavior, exact `io.print` write/current-stdout observation, parent descriptors, process status,
and sanitizer composition through observable public behavior. Its linked
parent-stdio helper prepares descriptors before a standalone child starts; the
parent waits through C99 `system`, checks the post-Runtime descriptor state, and
reads the child's explicit result file. Loader/global-promotion and private
engine implementation mechanics remain with existing compiler, packaging, and
native-harness coverage rather than duplicate boundary specs. Process exit,
automatic bootstrap, and cross-Runtime lifecycle behavior are likewise
Titan-owned tests supervising children or explicit sessions.

CI runs this complete stdlib surface in one uncovered Linux producer. One
standard Linux consumer restores the prepared tree and runs the complete
compiler/language set with one LuaCov report; the independent sanitizer builds
its own instrumented aggregate and selects focused cases. The complete macOS
suite stays a manually dispatched pre-merge gate.


### Completion gates

1. Parse/check touched Titan sources through the current source graph with
   production feature flags.
2. Reinstall the working compiler before Busted to avoid the installed-snapshot
   shadow.
3. Run focused parser/driver/coder/stdlib/packaging specs.
4. Run the complete uncovered stdlib surface and the one covered compiler
   group, then canonical `make test` from an isolated absolute prefix with
   ambient root/CPP/line-policy variables cleared.
5. Review all Titan code against the Titan programmer skill and language/style
   reference; independently review compiler/packaging code and both manuals.
6. Push, open a PR with `gh`, wait for every Linux push job, fix failures, and
   rerun until green. Run the required manual macOS workflow before declaring
   the branch ready.

## Closed architecture decisions

The final Titan design review established these invariants:

1. **ABI/provider generation:** retain the current ABI because the independent
   `titan.test` key and compiler-data source change no existing serialized,
   userdata, native-call, or loader contract. The canonical eighteen-key
   pair may be replaced transactionally; rollback restores the immediately
   preceding seventeen-key pair and the prior absence of the new source/shim. This is bounded same-ABI additive
   publication, not cross-ABI migration.
2. **Source-first resolution:** source is authoritative for the complete test
   invocation. A provisionally selected static archive that later overlaps a
   source identity may be rebound, before finalization only, to ABI-valid DSOs
   with byte-identical serialized interfaces for every already selected key.
   Missing or different fallback remains a composition error.
3. **Runner activation:** `testing()` and `verbose()` remain false during module
   initialization and CLI help/error handling. They become active only after a
   successful parse calls the private begin operation, and remain active through
   bodies, descendants, and cleanup.
4. **Context phases:** descendant execution may register cleanup on a captured
   parent. Both registration channels seal immediately before cleanup draining;
   cleanup cannot extend either stack.
5. **Executable ownership:** the first deduplicated requested root's ordinary
   `program_output` owns every synthetic artifact and executable. All input
   `main` declarations are compiled but ignored in test mode; the generated
   runner supplies the sole entrypoint.

## Divergence ledger

- The draft's abstract Lua helper technique is implemented with
  `luaL_loadstring` plus `lua_pcallk`, because `luaL_dostring` is a function-like
  C macro and therefore not directly importable through Titan's FFI. Semantics
  are unchanged.
- The installed private `titan.test` source is snapshotted into and published
  from the exact native generation stage. It remains compiler data outside the
  rock manifest and is committed in the same recoverable transaction.
- Make owns one explicit 22-root native manifest and one executable under
  `.titan-tests`; there is no native group orchestrator or per-suite executable.
  `luarocks test` reaches it through `run_rock_tests.sh` and `make rock-test`.
  `BUSTED_FILTER` and `TITAN_FILTER` remain independent, and ordinary appended
  command-backend arguments remain Busted arguments.
- The public `Context:log` method is an intentional narrow addition to the
  draft. It sends the context name and message through the private logger
  callback; the generated runner writes and flushes the prefixed C-stdio line.
  Tests can bracket their own expected async Task diagnostics without another
  stdlib import.
- The aggregate executable has a portable Bash process-group deadline. The
  build/run target split lets a focused lifetime oracle use a fresh filtered
  process without recompiling or introducing a runner lifecycle API.
- The earlier partitioned Linux plan is replaced by one uncovered stdlib
  producer and one standard-runner complete compiler consumer with a single
  coverage report. ASan+UBSan remains an independent instrumented build, and the
  complete macOS gate remains manual and pre-merge.
- `--no-uv-bootstrap` is an entrypoint-only standalone option. The aggregate
  uses it so source-only `support.runtime` can own one supervisor Task and LIFO
  same-Runtime cleanup per async case, including multiple sequential sessions.
  Automatic-bootstrap tests compile child executables that omit the option.
- Direct source-private imports let test-support declarations remain local.
  Host-side exact-provider coverage is retained only where native redirection
  cannot observe the number of `io.print` writes/current-output lookup, along
  with the previously identified loader, process, sanitizer, and provider
  boundaries.
