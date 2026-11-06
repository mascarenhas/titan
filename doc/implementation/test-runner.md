# Native test runner implementation

Opt-in [native source coverage](native-coverage.md) uses this same discovery,
build/run split, and executable. Production object instrumentation, source
attribution, counters, and reporting belong to the compiler and host tool;
the generated runner does not depend on gcovr or perform collection itself.

Titan's test infrastructure has four ordinary pieces:

1. `titan/test.titan`, the ordinary standard module containing the public
   test API and its execution, filtering, and reporting implementation;
2. `titan-compiler/testroots.lua`, which enumerates `--test-dir` search
   directories and resolves conventional test-module names through the ordinary
   tagged source resolver;
3. `titan-compiler/test_runner.lua`, which discovers checked test functions and
   renders a synthetic Titan module; and
4. the `titanc --test` orchestration in `titanc`, `driver.lua`, `build.lua`,
   and `linkcertificate.lua`.

There is no test AST node, special code-generator lowering, runner C runtime,
registry identity trick, or second compiler pipeline. The synthetic runner is
checked, generated, compiled, linked, and initialized as an ordinary logical
module.

## Resolution and the ordinary standard provider

A test invocation creates a resolver context with `source_first = true`.
For every ordinary non-root dependency, `defaultloader` first asks the tagged
folder/flat source resolver. A found source or blocked constituent is terminal;
only a clean miss enters the existing complete `.so`/`.a` format passes, in the
order selected by `prefer_static`. Explicit roots remain source-required.
Ordinary resolver contexts retain their binary-first behavior. This preference
changes selection only: a written `.titan` import remains the only dependency
edge that is source-required and collaboration-capable.

`titan.test` follows this ordinary resolution policy. The compiler neither
substitutes its source nor creates a separate support translation unit. An
installed SDK provides it through the same compiled standard provider selected
for other imports, so a static test link retains the standard archive without
any source overlap. Actual authored source overlaps retain the general
whole-provider composition checks; test mode does not weaken those checks.

The CLI's `source_overrides` holds any source descriptors returned by
`testroots.discover` and, at final link time, the generated `titan.test.runner`
descriptor. The runner's descriptor carries `files`, an in-memory `contents`
map, and its synthetic `program_output` stem; parsing and checking use the
ordinary source pipeline. The runner imports `titan.test` publicly. Its
discovered test owners use explicit `.titan` imports, preserving the
already-checked source provenance and inheriting the real C headers needed to
reconstruct their exported native fields. Discovery never supplies binary
owners to this source-only path. No test-support source is installed with the
SDK or copied into a test build.

Ordinary production module code generation is independent of `--test`.
`driver.test_owner_flags(test_build, test_functions, context)` enables
`test_runner.TEST_COMPILE_FLAGS` (`-fno-optimize-sibling-calls`) and records
`codegen.test_flags = true` in the module certificate only when `test_build` is
true and the module declares discovered `test_` functions. For a browser
context whose descriptor profile is `production`, it puts `-fno-inline` before
those flags ([browser test images](browser-target.md#test-images)); the
descriptor identity carries the profile. Because a module
with no `test_` functions records `test_flags = false` in both application and
`--test` builds, application and test executables sharing an output tree reuse
unchanged certified production objects without recompiling them. Direct private
imports from tests affect only the consumer's visibility; the producer object
already carries its source collaboration surface.

## Automatic test-root discovery

Repeatable `--test-dir DIR` and `--test-exclude MODULE` (`titan-compiler/testroots.lua`
`testroots.discover`) are valid only with `--test`, and `--test-exclude`
requires at least one `--test-dir`. Each `DIR` is resolved relative to the
invocation working directory via `context.io:stat` and `context.io:realpath`.
A missing, unreadable, or non-directory `DIR` fails immediately. Every `DIR`
must lie lexically or physically inside a configured `--tree` source root
(`driver.TITAN_SOURCE_PATH`); `testroots.discover` selects the **first**
configured containing `--tree` root in `--tree` order to derive the directory's
logical module prefix, rather than stripping `DIR`'s basename or choosing a
longest prefix. Repeated or overlapping `--test-dir` arguments deduplicate.

For each discovery area, `testroots.discover` walks entries in bytewise order
with `context.io:list` and `context.io:lstat`, yielding cooperatively through
`context.io:yield`. Hidden files and directories (names starting with `.`) and
names that are not valid single module components are skipped. A candidate
logical root is a module whose final component is `test`, `tests`, `spec`, or
`specs`, or ends in `_test`, `_tests`, `_spec`, or `_specs`. Symbolic links
whose name can form a candidate or directory are inspected with
`context.io:stat`, so broken candidate links fail discovery; file symlinks
resolve through the ordinary source resolver, while directory symlinks are
tested at most once as a folder module owner and are not descended into
recursively (an explicitly passed `--test-dir` directory symlink is traversed).

Discovery is [target-aware](target-source-selection.md#test-root-discovery).
It reads the selection target with `driver.context_target(context)` (the CLI
has already initialized the platform) and classifies each `*.titan` entry with
`driver.classify_source_filename`. A variant `<base>.<label>.titan` contributes
the candidate `<base>` only when its label applies to that target; an inactive
variant is skipped silently, so platform-only roots need no `--test-exclude`.
A stacked or mis-cased label fails discovery with `invalid test source
'<path>': ...`. Other dotted stems are not candidates. The candidate stem names
the root and `driver.resolve_source` selects its file, so variants of one root
deduplicate as one descriptor, and a folder root without an applicable main
resolves to nothing and is skipped.

Each candidate name is resolved both against its containing source root and
across the full `--tree` path with `driver.resolve_source`. Immediate folder
contributors (`kind == "blocked"`) and non-folder directories are ignored, while
nested directories inside a folder module are still traversed for independently
resolvable modules. If full `--tree` resolution is blocked by an earlier source
root's folder module or resolves `source.main` outside all requested
`--test-dir` areas, discovery fails with an explicit shadowing error rather
than silently running another subtree's tests. If two discovery areas resolve
the same logical name to different source descriptors, discovery fails with an
ambiguity error. Discovery reports errors from its own requested-directory
`stat`/`realpath`, directory `list`, entry `lstat`, and candidate symlink
`stat`, and reports vanished selected source files; candidate existence checks
inside `driver.resolve_source` use the shared `regular_file` helper, which on
POSIX discards a returned `stat` error while probing candidate paths.

`--test-exclude MODULE` validates `MODULE` as an exact logical module name and
removes matching names from automatic discovery only. Explicit positional CLI
roots are deduplicated in command-line order and win over `--test-exclude`;
remaining discovered roots are sorted with `util.bytewise_less` and appended
after explicit roots. An empty combined root list fails with `no test modules
found`. Discovery never reads source bytes, parses, or typechecks: unselected
malformed `.titan` files are ignored unless reached through the import closure
of a selected root, while a selected root with zero `test_` functions remains
legal.

## Source discovery

Before `test_runner.discover` runs, `build.run` plans and certifies the
requested source closure. Each module whose source-object certificate hits
(`incremental.certify_local` and `incremental.verdict`) is restored into
`driver.imported` by `driver.restore_source_object` with `kind = "source"`,
`object_metadata`, and saved `test_functions` (`test_runner.function_names`
recorded when the object was compiled), without parsing or typechecking its
source. Only certified and restored source records or freshly checked ASTs from
worker misses enter `driver.imported`.

`test_runner.discover` walks source-backed entries in the union of the
requested roots' dependency closures (`mod.ast` or `mod.kind == "source"` with
`mod.object_metadata`). On a freshly checked AST, a candidate is a surviving
nonlocal `Ast.TopLevelFunc` whose name begins with `test_`, has one fixed
parameter and no `varargtype`, and normalizes that parameter with
`types.normalize` to `Type.Nominal("titan.test.Context")`; on a restored
certified object, `mod.test_functions` supplies the function names directly.
Results are not restricted because the generated wrapper calls the function as
a statement.

Source module names and then full case names are sorted with
`util.bytewise_less`; discovery never depends on `pairs` order. It returns both
the sorted case descriptors and the exact owner-module set. Binary providers
are never discovered, even when a static provider physically carries other
logical keys.

## Synthetic source and native outputs

`titan-compiler/test_runner.lua` renders a thin module with:

* an ordinary public import of `titan.test`;
* one explicit `.titan` import alias per distinct source-backed test owner;
* one exact `function (test.Context): ()` wrapper per case, discarding results;
* private registration helpers, each appending at most 64 public
  `test.Case.new(full_name, owner_module, body)` descriptors to one Array; and
* `main(args)`, which returns `test.run(args, cases)`.

`main` owns the descriptor Array and calls the registration helpers in case
order before entering `test.run`. Bounding each registration function keeps
native compiler temporary and root state small, especially under sanitizers.
The helpers reuse the exact callback wrappers and return before execution;
discovery, case order, and the public test API are unchanged. Empty suites
need no registration helper.

The reserved logical name `titan.test.runner` is absent from the standard
provider. Test owners remain subject to ordinary import and native-symbol
naming. A bare owner rewritten by standard-library shorthand is rejected
because generated source has no exact import spelling for it; a bare name such
as `math` would instead collide with Lua's `luaopen_math`. The documented
`*_test`/`*_spec` convention avoids those existing module constraints.

For non-`-c`, non-`--print-ast` builds, `titanc` prepares and checks the
final-link certificate (`linkcertificate.prepare` and `linkcertificate.check`)
under `<output>/.titan-links/<key>/record` before rendering the synthetic
runner or entrypoint, where `<key>` is the SHA-256 digest of the canonical
sorted final output paths. The link recipe includes the ordered `roots`,
`test_cases`, compiled module object parts, `--c-source` objects, `-X`
payloads, selected providers and archives, runtime inputs, link flags,
toolchain identity, and coverage inventory. On a link hit, `titanc` restores
any missing public foreign headers, prints `Titan link hit <target>` under
`-v`, and exits without generating or compiling the runner or entrypoint or
invoking the linker.

On a link miss, `titanc` invalidates `<output>/.titan-links/<key>/record` and
places the target's synthetic files under
`<output>/.titan-links/<key>/synthetic/<leaf>__test_runner.titan` (with its
generated `.c` and `.o`) and
`<output>/.titan-links/<key>/synthetic/<leaf>__test_entrypoint.c` (and `.o`),
where `<leaf>` is the final component of the first root's logical name. Giving
each final output set its own `synthetic/` directory prevents two test targets
in one output tree that share a first root from overwriting each other's runner
or entrypoint. Unless `--exe PATH` overrides the destination, the first root
(`requested_modules[1]` — the first explicit root, or the bytewise-first
discovered root when no explicit root is given) owns the default executable
path (`program_output`, including the folder `__main` convention, or
`<output>/bin/<logical>.exe` and `<output>/lib/titan/0.6/<logical/module>.dll`
on Windows). Input application mains do not participate in main selection under
`--test`. See [output-directory routing](output-directory.md).

`-c --test` (with or without `--test-dir`) certifies or compiles the source
closure so test-owner objects receive `test_runner.TEST_COMPILE_FLAGS`
(`-fno-optimize-sibling-calls`), compiles any `--c-source` nodes, and stops
before link certification, runner generation, or linking.

Before emitting C for the final link, `validate_program_output_paths` checks
every source, runner, entrypoint, executable, and Darwin dSYM destination in
both normalized and physical-parent form. It rejects aliases,
ancestor/descendant conflicts, symlink leaves, and leaves of the wrong kind.
Generated-parent creation never replaces an occupied path.

### Browser test images

`titanc --test --target browser -o out --exe out/tests.mjs <roots>` discovers
and checks the same test owners, renders the same synthetic runner with its
public `titan.test` import, and links it through the [browser
entrypoint](browser-target.md#the-browser-entrypoint) into `out/tests.mjs`
and `out/tests.wasm` with the link profile's `test` purpose. Under the
`production` build profile, test owners get `-fno-inline` as well as the
native test flag, and the link skips Binaryen's `inlining-optimizing` and
`duplicate-function-elimination` passes, so the test owners keep the exact
frames the browser trace gate asserts ([browser test
images](browser-target.md#test-images)). Without `--exe` the image takes the
first root's `program_output` path with `.mjs` appended; an explicit `--exe`
must end in
`.mjs`. `titan.test` comes from the browser standard provider `titan.a` in the
SDK, so the link first runs the [executing protocol
check](browser-target.md#the-executing-protocol-runner) under Node. `titanc`
builds the image and never runs it, exactly as for native tests. The SDK's
`titan-browser-run` runs it under Node or headless Chromium, forwards the
arguments after `--` unchanged to `test.run`, writes the runner's output
bytes exactly, and exits with the completion status masked to its low byte,
so the runner's 0, 1, and 2 keep their meaning and never coincide with the
[runner's infrastructure statuses](browser-target.md#the-runner). A run that
selects no case exits 0, so browser acceptance checks count the selected
cases rather than trusting the exit status. The repository's [browser core
stdlib suite](browser-target.md#test-owners-and-the-browser-suite) builds all
browser-portable standard-library owners into one such image and audits its
complete owner inventory.

## `titan.test` execution API and private state

The public module serializes `testing`, `verbose`, `location`, `skip`, `assert`,
`run`, the nominal `Case` and `Case.new`, the nominal `Skip` with readonly
`reason`, and `Context` with its four methods. `Case` fields, `Context` fields,
`RegisteredTest`, callback aliases, execution state, and all `runner_*` helpers
remain local. The standard module's own execution code uses:

* `runner_begin` / `runner_end` for module-local active and verbose state and
  the standard module's reporting callback;
* `runner_new_context` to construct the otherwise unconstructible public
  nominal record;
* `runner_take_subtests` to seal subtest registration and detach the ordered
  child Array while leaving parent cleanup registration open to descendants;
* `runner_take_cleanup` to pop the live cleanup Array in LIFO order;
* `runner_skip_reason` for nominal marker classification;
* `runner_trace_location`, `runner_error_text`, and `runner_matches` for the
  trusted Lua boundary.

A Context has separate `subtests_open` and `cleanups_open` state. The former
closes at the body-to-descendants transition; the latter closes when cleanup
starts, so a descendant may deliberately append cleanup to a captured parent.
Popping before invoking cleanup ensures every registered callback can be
attempted without retaining a completed closure. `runner_begin` installs the
standard module's reporting callback. `Context:log` supplies the context's full
name and message for a decorated, flushed line. Public `run` parses its arguments
before activating the state, rejects an already active run, and defers state
reset around execution. The generated `main` calls it after module
initialization, so `testing()` stays false in imported initializers.

## Execution state machine

`execute` applies filters before constructing a context. An entered case
increments `run`, invokes its body under `catch`, classifies only the nominal
skip marker as skipped, and otherwise stores the separately rendered error and
raw trace. It then detaches children:

* pass: recursively execute selected children in registration order;
* skip/failure: report each selected child skipped with a parent reason.

The parent does not inherit a descendant failure. All selected descendants
still contribute to the shared counters, so any failure reaches process status
1. Cleanup then pops under one catch per callback. The first cleanup error
replaces pass/skip but never replaces an existing body failure. A cleanup skip
is converted to a readable failure. Finally the case prints one terminal line;
failed names are retained for the final list.

CLI parsing happens before `runner_begin`. Repeated filter patterns are stored
in a dense Array, validated once, and ORed. Help returns 0, malformed input 2,
failed cases 1, and all other runs 0. Reporting uses C99 `putchar`, not
`titan.io`, and is byte-length-aware.

### Wall-time accounting and output

The internal runtime entry `titan_test_monotonic_ns` returns monotonic
nanoseconds as a `lua_Integer`, with no allocation or Lua-state access.
Unix and browser builds use libc `clock_gettime(CLOCK_MONOTONIC)`; Windows
uses `QueryPerformanceCounter` with its actual `QueryPerformanceFrequency`.
The Windows conversion splits whole seconds from the subsecond remainder
before scaling, avoiding overflow from multiplying the full counter by a
billion. Clock failure or an unrepresentable timestamp returns `-1`; the
Titan caller raises rather than inventing a zero duration. This helper is
declared in the existing internal `titan/ffi.h`, so `titan.test` gains no
Titan imports, native-only dependency, asynchronous bridge, or public API.

`execute` starts its interval immediately before invoking the body and stops
after all selected descendants and LIFO cleanup finish. It returns the elapsed
nanoseconds for an entered case and nil for an unselected case. Every pass,
failure, and skip terminal line ends in `(N.NN ms)`, after any skip reason.
`skip_registered` reports an uninvoked child's duration as exactly `0.00 ms`.
The final failed-name list remains untimed: those entries are references to
already-reported failures, not second outcomes.

`run` accumulates each returned top-level interval in an owner map and retains
first-execution order in an Array. Interleaved custom case owners therefore
produce one owner total each, without summing inclusive descendant intervals
again. Before the ordinary count summaries it prints
`[----------] <owner> (N.NN ms total)`. The run summary is
`[==========] N tests ran. (N.NN ms total)` (or `1 test ran.`); its independent
clock spans the banner and execution loop, including case-output overhead,
but not the final owner/count summaries. Zero-case and zero-selected runs
still carry a run duration and print no owner totals.

Formatting rounds integer nanoseconds to the nearest hundredth of a
millisecond and renders the decimal point explicitly, independent of the C
locale. Owner totals sum unrounded top-level intervals; a sum of rounded
displayed case times can differ by a final decimal place. Selection,
registration order, cleanup/error precedence, counts, and exit statuses do
not depend on timing.

## Trusted Lua helpers and traces

`titan.test` imports `lua.h`, `lauxlib.h`, `titan/ffi.h`, `stdio.h`, and
`string.h`, and no Titan standard modules. A guarded
final initializer compiles one fixed Lua chunk with callable `luaL_loadstring`
and `lua_pcallk`; the function-like `luaL_dostring` macro is intentionally not
available through the FFI. In a normal standalone, `luaL_openlibs` has already
run, so this snapshots the helpers before any test-owner initializer. A bare
validation state may not have opened the standard libraries; the initializer
first checks for the required Lua callables and defers loading when they are
absent. The first later trace or pattern operation then loads the helpers.
The chunk snapshots the required base/string callables into locals before it
returns two traced closures:

* a raw-trace scanner using the captured `string.gmatch`/`string.match`; and
* a Lua-pattern predicate using the captured `string.find`.

Capturing at `titan.test` initialization keeps those helpers valid even when a
test owner has a logical name such as `math` and replaces the corresponding Lua
global during standalone initialization. The helper saves the Lua top, reserves
stack space, converts returned closures to traced Titan function values, and
restores the stack through `defer`.
`runner_error_text` uses the same ledger around `luaL_tolstring` and catches a
throwing `__tostring`, preserving a fixed fallback.

A native frame has the runtime form
`file.titan:LINE: in qualified.function`. The scanner skips exact support
functions/methods and the `titan.test.runner` namespace, but not unrelated user
modules whose names merely begin `titan.test.`. It remembers the first external
Titan frame and prefers one whose function belongs to the known test owner.
The raw trace stays unmodified for verbose output. Normal `#line` directives,
`-g`, and the test-owner sibling-call flag are therefore part of the useful
location contract.

## Standalone asynchronous bootstrap

The generated runner has an ordinary Titan `main`. It does not own a scheduler
or special-case asynchronous tests. Without another option, an imported
standard module may install the existing standalone async bootstrap, which
invokes the complete runner inside one Task and one Runtime.

`--no-uv-bootstrap` changes only the generated entrypoint's choice after module
initialization: it takes the ordinary direct call to runner `main` even when the
registry hook is non-nil. It does not clear or identify the hook and does not
change `titan.uv`. The repository aggregate uses this option so its source-only
`support.runtime` helper can establish sequential sessions. `run(body)` creates
one supervisor Task, runs `async.loop`, and re-raises the body's original value
with its pinned traceback after all registered LIFO Runtime cleanup completes.
A Runtime-bound Task or handle must be registered there; later
`Context:cleanup` cannot suspend in a Runtime that already ended.

The runner remains Task-independent in both modes. Automatic-bootstrap behavior
is tested by separately compiled child programs that deliberately omit the
option, rather than by exposing private registry state or adding a runner
lifecycle protocol.

The parent-stdio hint matrix compiles its immutable child image once in the
parent and retains the workspace until parent `Context:cleanup`. Every named
child still enters its own `support.runtime` session, starts a fresh child
process, and sets up and restores its own descriptors. Each invocation creates
a distinct result file and registers its removal before starting the child, so
one failed invocation cannot leave a result for a later case. Parent cleanup
uses the synchronous test-private filesystem remover; no live Runtime-owned
resource crosses the sessions.

## Validation profile and isolated SDKs

Profile selection, prefixes and command ownership are in [repository
workflow](repository-workflow.md#choose-the-matching-profile-and-command); the
per-component optimization policy is in [build
profiles](../language/build-profiles.md). The test harness adds these flag
rules:

- The native aggregate and its fresh child compilers receive the profile's
  native flags followed by `TITAN_EXTRA_*FLAGS` when set, otherwise
  `TITAN_TEST_EXTRA_*FLAGS` (`Makefile` `TITAN_TEST_CFLAGS` and
  `TITAN_TEST_COMPILER_ENV`). The same environment reaches Busted workers.
- When no `TITAN_BUILD_PROFILE` is set, `spec/support/helpers.lua` prepends
  `-O0 -fno-lto` to the driver's extra compile and link flags for direct coder
  fixtures.
- `spec/coder/lto_spec.lua` clears the inherited profile and cheap overrides for
  its subprocess, compiling and running cross-module providers and source-free
  consumers with the unset production defaults (O3, with fat LTO on Linux).
- The fat-object metadata reader, foreign-prototype diagnostics, nominal
  array-boundary diagnostics and `setjmp`/`longjmp` value-survival fixtures
  keep explicit optimization levels because optimization is part of their
  oracle. Make's flag regression separately checks production/validation,
  platform defaults and explicit flags. Benchmark scripts keep the profiles
  recorded by their measurements.

## Regression placement

Choose a test layer according to the behavior it proves. A large compiler
feature gets a topical spec rather than expanding the generic checker/coder
spec. All commands run from the repository root; the shared harness is
`spec/support/helpers.lua`.

| Behavior under test | Owning suite |
| --- | --- |
| Pure lexer/parser/location/symbol/type/preprocessor behavior and driver/metadata algorithms | Root `spec/*_spec.lua`; `cpp_spec.lua` drives preprocessing without the toolchain and bounds macro recursion with an instruction-count hook. |
| Typechecking, plan construction, visibility, or rejection without executing generated code | `spec/checker/`. |
| C generation, compilation, real native execution, or compiler boundary parity | `spec/coder/`. |
| Public standard-library API/runtime behavior, including fresh-process host behavior | Module-owned Titan sources in `spec/stdlib/titan/`, through the aggregate executable; no Busted wrappers or Lua library suites. |
| Native dependency builds and canonical standard-provider ownership | `spec/libuv_build_spec.lua` and `spec/rockspec_spec.lua`. |
| Production bundled/system OpenSSL static consumers | `spec/support/ci_dependency_mode_smoke.sh`. |
| Browser target mechanics: SDK build, source-map extensions, entry registration, images, incremental certification and rollback, providers, protocol check, entry gate, budgets, runtime fixtures, minicoro on Emscripten, the browser stdlib's dependency closure, member inventory, and initialization/fidelity gate | Busted files `spec/browser_sdk_spec.lua`, `spec/browser_trace_map_spec.lua`, `spec/browser_stdlib_spec.lua`, `spec/coder/browser_{trace_entries,images,incremental,providers,protocol,entry_gate,fixtures,budgets,stdlib_closure,stdlib_gate}_spec.lua`, and `spec/minicoro_spec.lua`, run with the real toolchain in the [`browser-toolchain`](continuous-integration.md#browser-toolchain-job) and [`browser-stdlib`](continuous-integration.md#browser-stdlib-job) jobs; Titan and C fixtures under `spec/fixtures/browser_runtime/` and `spec/fixtures/browser_stdlib/`. |
| Browser loader, runner, and trace-adapter behavior | The portable `spec/browser/loader.test.mjs` (fixtures in `spec/fixtures/browser_loader/`) through the installed runner's `--js-test` on both engines, and the Node `node:test` suites `spec/browser/runner.test.mjs` (`spec/browser/runner-fixtures.mjs`) and `spec/browser/trace-adapter.test.mjs` (`spec/fixtures/browser_trace_adapter/`). |
| Browser traceback behavior across engines | Native Titan cases in `spec/fixtures/browser_trace/` (`trace_cases` and `trace_uncaught`), staged by `spec/browser/build-trace.lua` and driven through `spec/browser/trace.test.mjs` by `titan-browser-run` (Node) and `spec/browser/playwright-run.mjs` (Playwright Chromium, Firefox, and WebKit). |
| Public behavior of the browser standard library on the browser target | The owning module tests in `spec/stdlib/titan/` named by `TITAN_STDLIB_BROWSER_TEST_ROOTS`, which import only browser-subset modules and `support.common.titan`; host-only cases go to native-only owners (`test.host_tests`, `reflect.lua_tests`, `json.lua_tests`, `protobuf.resource_tests`) or `.native.titan` contributors, and browser-only ones to `.browser.titan` contributors. `make titan-stdlib-browser-test` runs them on Node and Chromium ([browser test owners](browser-target.md#test-owners-and-the-browser-suite)); `spec/coder/browser_fixtures_spec.lua` also builds `coroutine.tests` and `gc.tests` and checks their selected case counts. |

Keep library behavior outside LuaCov. Compilation alone does not make a
library integration a compiler test; add a small independent compiler case
when it exposes a compiler coverage gap. Fresh-process behavior belongs to
the native owner: a compiled parent can invoke a standalone fixture with
argv-aware `support.command`, receive an explicit temporary result file, and
remove it with `defer`. Authored C/H fixtures live in
`spec/fixtures/stdlib/native/`, authored Titan children in
`spec/fixtures/stdlib/titan/`. The remaining Lua async/process support is
build/production-smoke infrastructure, not a library assertion suite.

The following existing splits avoid duplicated provider/build scaffolding:

| Contract | Existing regression homes |
| --- | --- |
| Type-relation laws / checker plans / generated boundary parity | `spec/types_spec.lua`, then the topical checker/coder `type_relations_soundness_spec.lua`. |
| Union syntax / checker frontiers / generated representation / hostile metadata | Lexer/parser specs, checker/coder `unions_spec.lua`, and `spec/union_interface_spec.lua`; reflected payload readers in `spec/coder/unions_stdlib_spec.lua`; extend compiled-module suites for source/DSO/archive composition. |
| Folder resolution and diagnostics / public artifacts and mixed-file traces | Filesystem cases in `spec/driver_spec.lua`, then `spec/coder/folder_modules_spec.lua`. |
| Root-major metadata claims and provider lookup; compiler root, compile-time Titan path, `;;`/`!` expansion | `spec/driver_spec.lua`. |
| Run-time Titan path, SDK fallback, Titan package searcher, canonical reuse, name guard, searcher installation in every state | `spec/coder/multi_module_path_runtime_spec.lua`; `titanc --print-root` in `spec/titanc_root_spec.lua`. |
| Prefix-container compilation, promotion, paired publication, rollback, real macOS universal archives | `spec/coder/multi_module_libraries_spec.lua`, with packaging in `rockspec_spec.lua`. |
| Bounded archive/ELF/Mach-O/COFF and synthetic universal parsing | `spec/staticmetadata_spec.lua`. |
| Static format preference, occupied paths, claims, cache, source fallback | `spec/driver_spec.lua`. |
| Direct/dynamic nominal-owner constraints | `spec/checker/static_compiled_modules_spec.lua`. |
| Target derivation, `-X` classification, archive tools/construction, native archive validation | `spec/coder/static_compiled_modules_spec.lua`. |
| DSO-selected imports and serialized rehydration | `spec/coder/so_import_spec.lua` and `spec/checker/so_rehydration_spec.lua`; omit dependency source and paired archives and assert dynamic selection. |
| Dense Array capacity/hash/GC representation | `spec/dense_array_runtime_spec.lua`; language and checker behavior stays in topical compiler specs. |
| Source-object certification, depfile parsing, scheduler workers, native inputs, link certification, output locking, and automatic test-root discovery | `spec/incremental_spec.lua`, `spec/depfile_spec.lua`, and `spec/coder/{incremental_compilation,build_scheduler,link_certification,native_inputs,build_coordination,test_root_discovery,compiler_build_scenarios}_spec.lua`. |

Regex dogfood stays under `spec/stdlib/titan/string/regex_test.titan` outside
LuaCov. Standard-library tests must not rewrite production source, recreate
retired callback transformers or reentrant loops, inspect generated objects
to re-prove codegen, or invalidate shared Make-owned runtime/provider outputs.
Public async tests observe outcomes, cancellation, listener delivery, buffering,
and resource retirement through the current production modules. The canonical
[async runtime chapter](libuv-runtime.md) specifies the token/FIFO protocol;
HTTP deadline tests retain reader-cancel-and-join before connection/parser
teardown when the deadline wins, and timer-only cancellation when the reader wins.

## Repository dogfooding

The shared `spec/support/stdlib_test_modules.mk` manifest names the
module-owned roots under `spec/stdlib/titan/` (`TITAN_STDLIB_TEST_ROOTS`,
beginning with `TITAN_STDLIB_TEST_PROGRAM_ROOT := test.tests`) along with their
measured validation durations and timing guards, and the browser-portable
subset in `TITAN_STDLIB_BROWSER_TEST_ROOTS`. This manifest is runtime
scheduling and output-audit metadata for Linux, macOS, and Windows, not a Make
dependency graph or compiler input list (`spec/libuv_build_spec.lua` and
`spec/coder/test_root_discovery_spec.lua` verify that `testroots.discover` over
`spec/stdlib/titan` matches the native owner set exactly).

The browser roots are named explicitly rather than discovered with
`--test-dir`, because native-only owners in the same tree (such as
`test.host_tests`, which imports `fs`) cannot build for `browser`. Every
browser root is also a native root, so the two suites share logical owners and
their portable cases; target-selected contributors still differ, so an owner
can hold native-only cases (`tests/unwind_test.native.titan` in
`coroutine.tests`) and browser-only ones (`tests/close.browser.titan`).
`make titan-stdlib-test` does not run the browser suite, which is the separate
[`make titan-stdlib-browser-test`](browser-target.md#test-owners-and-the-browser-suite).

On Unix, `titan-stdlib-test-objects` and `titan-stdlib-test-build` run from
`TITAN_TEST_BUILD_DIR` (default `out/tests`) and invoke a single installed
`$(TEST_TITANC)` command with `--output . --test --incremental
-j$(TITAN_JOBS) --tree $(abspath spec/stdlib/titan) --test-dir $(abspath
spec/stdlib/titan) test.tests` and the three aggregate C helpers
(`async_foreign_work.c`, `fs_fixture.c`, and `uv_stdio_probe.c`) passed via
`--c-source`. `titan-stdlib-test-objects` adds `-c`;
`titan-stdlib-test-build` adds the link-phase `--no-uv-bootstrap` and `--exe`
options, which `-c` rejects. `test.tests` stays explicit and first so it owns
the default provider identity and executable path (`out/tests/test/tests`,
passed explicitly via `--exe` on `titan-stdlib-test-build`); `--test-dir`
discovers the other owners and deduplicates `test.tests`. Module C, objects,
and headers reproduce the test source hierarchy below `out/tests`, aggregate
`--c-source` objects live in `out/tests/.native/`, and the link certificate and
synthetic runner/entrypoint live under `out/tests/.titan-links/<key>/`.

Fixed fixture objects (`uv_stdio_probe.o`, `sqlite3_worker_fixture.o`,
`ssl_allocator_fixture.o`, `ssl_error_strings.o`, `os_descriptor_limit.o`, and
on Linux `transfer_alloc_fault.o`, `uv_sync_alloc_fault.o`, and
`thread_retirement_fault.o`) are certified by separate `$(TEST_TITANC) -c
--incremental --output $(TITAN_TEST_BUILD_DIR)/native/<stem>.o
--print-c-objects ... --c-source` rules; each copies the object path that
`titanc` reports to `$(TITAN_TEST_BUILD_DIR)/<stem>.o` only when `cmp -s`
detects a content change. `os_process_host_child` is compiled directly by
`$(CC)` from its C source and `$(TITAN_TEST_BUILD_DIR)/native-flags.config`
([native test aggregate and C fixture
rules](build-script-audit.md#native-test-aggregate-and-c-fixture-rules)). After
an identical `luarocks make --force` reinstall, `make titan-stdlib-test-build`
certifies every module object, `--c-source` helper, and final link as a hit and
performs zero object compilations and zero links; certification still runs its
preprocessing and toolchain probes.

`make titan-stdlib-test-run` returns to the repository root before executing,
because several fixtures use repository-relative paths. `TITAN_FILTER` supplies
one Lua pattern to this already built executable; it never changes the
compiled root set. `make titan-stdlib-test` composes build and run, while the
split leaf targets let sanitizer and focused development runs reuse one build
in multiple fresh processes. `BUSTED_FILTER` is independent and belongs to
`busted-test`; `rock-test` enters both domains without inventing native group
names. Running edited compiler Lua through Busted without reinstalling uses the
explicit [checkout profile](repository-workflow.md#run-checkout-compiler-lua-with-busted).

`run_with_timeout.sh` uses Bash monitor mode to give the executable its own
process group and checks completion every 100 milliseconds. Make's default
`TITAN_TEST_TIMEOUT=600` covers the whole aggregate, including fresh
child-fixture compilation under the selected profile. Explicit overrides,
including the 15-second CI shutdown check, are independent of that default. At
the deadline it sends `TERM`, then `KILL` after a short grace period, maps the
timeout to status 124, and otherwise preserves the child's status. Make
streams combined stdout/stderr through a pipe rather than redirecting either
stream to a regular file, preserving the parent-pipe boundary tested by
OS/stdio cases. Expected uncaught Task diagnostics are owned by their Titan
tests: a case emits flushed `Context:log` messages containing `BEGIN expected
uncaught async Task diagnostics` and `END expected uncaught async Task
diagnostics` around the operation. Those prefixed brackets make a successful
aggregate log readable and keep the expectation owned by the case that
produces it.

### Native SDK selection

The aggregate (`out/tests/test/tests`) and the fixture programs its tests compile
in fresh child processes do not live in an SDK's `bin` directory. Their
executable-relative entries `!` and `!/../lib/titan/0.6` therefore miss, and the
runtime's SDK fallback decides which installed `titan` provider they load. That
fallback uses `TITAN_ROOT` and otherwise spawns `$TITANC` or `titanc
--print-root` from `PATH`
([Titan path](../language/modules.md#the-titan-path)).
Left to `PATH`, a user installation earlier on `PATH` can supply a
different provider than the one the suite was built against.

The Unix `Makefile` therefore sets `TITAN_ROOT` to `TITAN_TEST_INSTALL_ROOT`,
the installation that `TEST_LUA` resolves, at every native-only launch:

- `titan-stdlib-test-objects` and `titan-stdlib-test-build`;
- the fixed fixture-object rules (`titan_test_native_rule`);
- `titan-stdlib-test-run` and `titan-stdlib-test-run-parallel`.

Fresh children inherit the root through `support.command`, so their own
compiles and runs select the same SDK. `TITAN_TEST_SDK_ROOT`, set beside it, is
test-helper metadata: it locates SDK tools for fixtures and selects nothing at
run time. `TITAN_TEST_COMPILER_ENV` carries no root because Busted workers also
receive it, and their specs choose their own provider paths.

The pin replaces only the PATH-derived fallback. Explicit `TITAN_PATH_0_6` or
`TITAN_PATH` entries and executable-relative providers still come first, and
helpers that select exact provider paths for their children
(`spec/support/async_stdlib.lua`) still remove `TITAN_ROOT` deliberately. A
`TEST_LUA` outside an SDK leaves the root empty, which the runtime treats as
unset.

This is Make's own selection for its suite. A canonical run still starts
without an ambient `TITAN_ROOT`, `TITANC`, or Titan path variable
([repository workflow](repository-workflow.md)).

`spec/libuv_build_spec.lua` ("runs prepared native tests against the selected
SDK, not a titanc on PATH") covers this behavior. It runs a one-case aggregate
with a logging `titanc` first on `PATH`. With the SDK selected, the run passes
and that `titanc` is never called. With an empty selection, the aggregate
queries it.

### Concurrent filtered runs

The Unix `Makefile` `titan-stdlib-test-run` tees the merged output to
`TITAN_TEST_RUN_LOG` (default `$(TITAN_TEST_BUILD_DIR)/stdout.log`, with
`TITAN_TEST_BUILD_DIR` defaulting to `out/tests`) and writes the root inventory
that `check_stdlib_test_output.lua` audits it against (default
`$(TITAN_TEST_BUILD_DIR)/roots.txt`; `<log>.roots` beside an explicitly
selected log). The built executable and fixture objects are only read, so
several filtered runs can share one build at once when each selects its own
log and `TMPDIR`:

```sh
mkdir -p /tmp/run-a /tmp/run-b
TMPDIR=/tmp/run-a make titan-stdlib-test-run TITAN_FILTER='^uv[.]' \
  TITAN_TEST_RUN_LOG=/tmp/run-a/stdout.log & uv_run=$!
TMPDIR=/tmp/run-b make titan-stdlib-test-run TITAN_FILTER='^protobuf[.]' \
  TITAN_TEST_RUN_LOG=/tmp/run-b/stdout.log & protobuf_run=$!
wait "$uv_run"; uv_status=$?
wait "$protobuf_run"; protobuf_status=$?
```

Each run audits only its own log and keeps its own exit status. Cases still
share the host, so timing-bound cases see more load and loopback port scans
more contention. The CI sanitizer gates stay serial
([continuous integration](continuous-integration.md#sanitizer-ownership-and-failure-diagnostics)).
`Makefile.win` does not take `TITAN_TEST_RUN_LOG`: its runner writes fixed
logs, root lists, and scratch paths inside the one workspace, so Windows runs
of one workspace must stay sequential.

### Busted partitions

`make busted-test`, `luarocks test` (the rockspec `test` command) and Windows
`rock-test` all enter `spec/support/run_rock_tests.sh`. An exact unfiltered
run, with no `BUSTED_FILTER` and no appended Busted arguments, hands every
classified spec file to `spec/support/run_parallel_compiler_tests.sh`. A Busted
filter or appended Busted argument selects the ordinary single-process route; a
Titan-only filter leaves the partitioned run enabled.

`spec/support/ci_compiler_test_groups.txt` (schema `titan-busted-timings-v2`) is
the timing dataset. Its header records host, profile, date, and compiler; each
row names one discovered `spec/**/*_spec.lua` file, its domain, its measured
local validation seconds, and an optional covered-seconds column
(`ci_covered_seconds`; `-` falls back to the local value). Despite the column
name, it holds Linux CI covered+stress durations only in `compiler` rows. In
`stdlib` rows it holds same-host serial four-CPU LuaCov diagnostic seconds of
the CI step's files, not a CI run, and `retained` rows leave it `-`. The
`retained` domain is the runtime/packaging set
(`Makefile` `STDLIB_BUSTED_TESTS`, `Makefile.win`
`TITAN_ROCK_TEST_STDLIB_SPECS`), `stdlib` is
`spec/support/ci_stdlib_compiler_test_files.txt`, and everything else is
`compiler`. `spec/libuv_build_spec.lua` asserts that the two retained lists are
equal and that the retained, stdlib, and stress domains each match their
declaring list, so adding such a spec needs no re-pinned count.
`spec/support/compiler_test_groups.lua` validates the complete
classified union: a missing, stale, duplicate, or cross-domain row, or an
unlisted `#stress` file, fails before any test starts. It plans any positive
worker count with deterministic longest-processing-time assignment (heaviest
file first, ties by path, to the least-loaded worker); each worker runs its
files in path order. No shard identity is stored. Add a measured row with every
new spec file and remeasure rows when costs change materially.

Compiler integrations that import standard-library modules belong to the
installed-stdlib domain and consume the installed provider. For example,
`spec/coder/split_units_spec.lua` uses transfer, protobuf, and reflection, and
`spec/coder/unions_stdlib_spec.lua` tests generated payload readers through
reflection. Compiler-only union cases remain in `spec/coder/unions_spec.lua`.
The shared-provider helpers `helpers.build_so_chain` and `check_against_so`
link only the root module and reject dependencies resolved from source or
static archives.
CI runs the installed-stdlib files only after installing the standard provider;
local Unix and Windows unfiltered runs still schedule each file exactly once
through the same per-file inventory.

`EXCLUSIVE_SPECS` (`spec/support/compiler_test_groups.lua`) names the
genuinely exclusive files: `spec/coder/parallel_compilation_spec.lua`,
`spec/coder/jobserver_spec.lua`, `spec/coder/build_scheduler_spec.lua`, and
the stdlib-domain `spec/coder/build_coordination_spec.lua`. They count
overlapping real compiler processes against their own caps, drive real
parent Make jobservers, or install process-global signal guards. They run
alone in their own checkout copy after every ordinary worker and any
overlapped native build have finished, with `MAKEFLAGS`, `MFLAGS`,
`MAKELEVEL`, and `TITAN_JOBS` unset so each test sets its own caps; `titanc`
would read an inherited `-j1` as a serial Make job policy. Every other file,
including the retained and stdlib-compiler specs, is scheduled per file; there
is no serial prefix. Those files write only their own checkout (for example
`libuv-build/` or checkout-root fixtures) or private temporary SDK and staging
trees, so all workers share the installed SDK read-only.

`TITAN_ROCK_TEST_JOBS` (any positive integer) sets the number of ordinary
workers, capped at the number of ordinary files. It defaults to four, or to
three when the native build shares the pool (Unix `rock-test`): a fourth
worker would wait for a slot while the build holds one. In calibration runs on
a 24-thread Linux host with a cold native build, taken while seven spec files
still failed (so only the comparison is meaningful), three workers finished
`rock-test` about 12% sooner than four, while `busted-test` alone was about 7%
faster with four. Each worker owns a private copy of the prepared checkout,
`TMPDIR`, ccache scratch, and tagged log. It runs one Busted process per file
with `MAKEFLAGS=-j1` and
`TITAN_JOBS=1`, removes checkout-root generated artifacts between files,
records one PASS or FAIL row per file, and continues after a failed file.
`TITAN_SOURCE_GIT_ROOT` lets `rockspec_spec.lua` read the real checkout's Git
inventory from its `.git`-less copy. The copies come from one snapshot of the
prepared checkout that omits `.git`, `libbacktrace/.git`, `.lua`, and the
selected `PREFIX` when that directory resolves inside the checkout. Tar reads
exclusions as patterns, so a prefix whose checkout-relative name contains `*`,
`?`, `[`, or a backslash is copied instead. Unix workers base their scratch on
the caller's `TMPDIR`; Windows workers also get private TEMP/TMP below MSYS2's
short `/tmp`, so nested fixture paths fit ordinary Win32 filename limits, and
run under the native Job Object supervisor.

A private `TMPDIR` does not make every temporary name private. On POSIX,
Lua's `os.tmpname()` ignores `TMPDIR`: it creates a file from the fixed
template `/tmp/lua_XXXXXX` with `mkstemp`. Both the spec helper
`spec/support/temporary.lua` and the compiler's synchronous filesystem
strategy (`Sync:tmpname` in `titan-compiler/io.lua`) take their names from it,
so concurrent Unix workers, local or in CI, also share the host's `/tmp`
temporary-file namespace. `mkstemp` reserves each base name it returns, but a
name that `temporary.name(suffix)` derives after removing that reservation is
not reserved, so these names are not guaranteed collision-free.

On Unix the ordinary workers are the targets of an ephemeral GNU Make
3.81-compatible work graph with ASCII phony names, run with `-k` so every
worker drains after a failure. The workers share one job pool with the
optional native-aggregate build target. The launcher joins an inherited usable
jobserver; otherwise it keeps an explicit `-j` word from `MAKEFLAGS`, including
`-j1`; otherwise it seeds a fresh pool of `TITAN_JOBS` slots. The Makefile
passes its four-slot default, except on GNU Make before 4.2, which cannot show
`make -j1` ([Make job pool](build-script-audit.md#make-job-pool-and-titanc-recipes)):
there it passes no `TITAN_JOBS` unless the user set one, and the launcher
sizes the pool with one slot per worker plus one for the native build.
Each Busted worker holds one slot. The native build target is ordered first;
its `titan-stdlib-test-build` sub-make and `titanc` processes borrow the
remaining slots. A four-slot budget therefore runs four units in total, not
four Busted workers plus four compilers, and `TITAN_JOBS=8` alone never widens
an inherited four-slot pool. On Windows the launcher keeps its FIFO scheduler:
the exclusive shard runs first and alone, then the ordinary shards share
`TITAN_ROCK_TEST_JOBS` slots, so the exclusive files' explicit native job
bounds never multiply with another active shard.

At the end the launcher requires exactly one result row for every planned
file, prints `Per-file Busted summary: passed=... failed=... total=...` and one
`FAILED spec file:` line per failure, and exits nonzero if any file, worker, or
required row failed. HUP, INT, and TERM terminate the work graph, the native
build, and every worker's process group, killing TERM-ignoring descendants
after a short grace period, then remove the scratch tree. Local workers collect
no LuaCov and never upload coverage.

On Unix `rock-test` runs that partitioned Busted phase with the native
aggregate build overlapped inside its pool, then the native phase:
`titan-stdlib-test-run-parallel`, or the focused `titan-stdlib-test-run` leaf
when `TITAN_FILTER` is set. The native run starts only after every Busted
worker and the build have finished. A Busted failure does not suppress the
native phase, a failed native build skips only the native run, and the target
fails when either phase failed. A focused Busted run builds the aggregate
afterwards instead. On Windows `rock-test` builds and runs the native aggregate
first, then the Busted phase, and likewise reports both statuses. Both Windows
Busted launchers (`run_rock_tests.sh` and the worker launcher in
`run_parallel_compiler_tests.sh`) preload `luv` before Busted's per-file
isolation. The library owns its native loop through its first module table, so
that table must stay loaded while Busted restores `package.loaded` between
files.

### Parallel native aggregate runs

`make titan-stdlib-test-run-parallel` runs one complete prebuilt aggregate as
owner groups through `spec/support/run_parallel_stdlib_tests.sh`. The plan
derives from `TITAN_STDLIB_TEST_ROOTS` through `make -f
spec/support/stdlib_test_modules.mk print-stdlib-test-owner-schedule`. That
manifest annotates owners with measured validation durations
(`TITAN_STDLIB_TEST_SECONDS_<owner>`; an unlisted owner counts one second) and
timing guards (`TITAN_STDLIB_TEST_GUARD_<owner> := 1`). Ordinary owners are
assigned by the same longest-processing-time rule to `TITAN_TEST_JOBS` groups
(default four, any positive integer; one is serial). Each group executes the
same binary from the repository root with one `--filter=^<owner>[.]test_` per
owner (Lua patterns, never regex alternation), its own `TMPDIR` and
`TITAN_TEST_ROOT`, its own log and process group, and the `TITAN_TEST_TIMEOUT`
supervisor. A failing group does not stop the others. A group's status is the
supervised executable's exit status (124 after a timeout), never that of the
log pipeline, so a nonzero exit after a complete passing report still fails
the run. The `fs.tests` workspaces and `uv.public_tests` filesystem scratch
live below `TITAN_TEST_ROOT`, or the platform temporary directory when a run
sets none, so the launcher's removal of its scratch tree also covers them.

The guarded owners then run alone in one group, with no other group, Busted
worker, or native build running. They are `timer.tests` (millisecond ticker
cadence), `net.tests` (short transfer windows), `ssl.tests` (bounded
backpressure turns), `http.tests` (30–200 ms TLS and idle deadlines),
`websocket.tests` (continuous backpressure duration and read-step deadlines),
and `os.tests` (wall-clock comparisons). `async.tests`, `thread.tests`, and
`uv.runtime_tests` use phase barriers or multi-second safety deadlines and stay
ordinary; the 15-second runtime-shutdown oracle keeps its explicit filtered CI
step. Deadlines, retries, and case selection are unchanged.

`check_stdlib_test_output.lua --union` audits every group's log as an
unfiltered run of its planned owners, then the union: every root planned
exactly once, no case reported by two groups, all selected cases terminal,
classified skips only, and consistent totals. The concatenated group logs
become `TITAN_TEST_RUN_LOG` and the root inventory `TITAN_TEST_RUN_ROOTS`. The
target rejects `TITAN_FILTER`; `titan-stdlib-test-run` remains the focused
single-invocation leaf, and `make titan-stdlib-test` builds and then runs the
parallel target unless `TITAN_FILTER` is set. Native coverage
(`titan-native-coverage-run`), the CI sanitizer gates, and Windows keep serial
aggregate runs because they share coverage counters, timing ownership, or one
workspace.

Each successful group report includes its independent run duration and one
total per executed owner. The union preserves those group/owner measurements;
it does not call their sum the elapsed time of the parallel run. When a group
fails after producing complete final counts, the diagnostic report retains
its run and owner timings as well.

The stdout audit requires a two-decimal timing suffix on every outcome, one
owner total per executed owner, zero time for never-invoked child skips, and a
run interval no shorter than its top-level owner intervals. It follows the
nested `RUN`/outcome stack rather than inferring parenthood from dots in a
custom case name. Owner totals are checked against top-level case times with
only the rounding allowance implied by their displayed precision. Malformed,
missing, duplicate, out-of-inventory, and inconsistent timing metadata fail the
gate, and untimed execution output is rejected. Ordinary `Context:log` lines
remain distinct from owner metadata because they include `<case>: <message>`.

The report scanners `validate` and `final_counts` in
`spec/support/check_stdlib_test_output.lua`, which also audit browser stdout for
`scripts/check_browser_stdlib.lua`, and that script's diagnostic outcome counter
accept LF, or one CR immediately before an actual LF, as a line ending.
Embedded CR, repeated CR, and a CR that ends an unterminated final line stay in
the scanned text, so the strict grammar rejects them; an iterator's appended
sentinel never turns data into a fabricated CRLF boundary. The private native
timing assertion helper in `spec/stdlib/titan/test/host_tests.titan` scans only
the LF-terminated rows of a complete captured child report and removes one CR
before each such LF. Ordinary Windows CRLF therefore neither fails the assertion
nor re-emits the captured transcript through the parent text stream; an
unterminated final fragment is not scanned. Sanitizer guards represent their
optional terminal CR through Bash ANSI-C quoting and test the actual workflow
expression. Browser byte-fidelity fixtures retain their exact LF/binary-byte
contracts rather than normalizing arbitrary captured bytes.

### Platform portability and complete execution

`Makefile.win` provides the same build/run leaf targets through
`spec/support/windows_stdlib_tests.sh`. It refreshes the supplied native
CLANG64/UCRT SDK, test sources, collaboration headers (`titan/transfer_native.h`
and `titan/protobuf/native.h`), and authored fixtures into a marked local NTFS
workspace using NUL-delimited owned-input manifests (`sdk.inputs`,
`source.inputs`, `fixtures.inputs`, `native-headers.inputs`) and copy-if-different
comparisons, preserving generated objects, providers, certificates, and `.gcno`
notes across builds. Pure-C `process child ação 東京.exe` and
`windows-test-supervisor.exe` are built through `Makefile.win`
`windows-stdlib-test-native`, which delegates to the UTF-8 Bash helper
`spec/support/build_windows_stdlib_native.sh` and its timestamp freshness
checks against `native-flags.config`. The fixed C fixture `.o` files are
certified via `titanc -c --incremental --print-c-objects --c-source` in
`work/native/<fixture>` and copied to `work/cwd/.titan-tests/<fixture>.o` when
changed, and the aggregate is built with one `titanc --output ... --test
--incremental --no-uv-bootstrap -j "$TITAN_JOBS" --exe
"$winprefix/bin/titan-stdlib-tests.exe" --tree "$test_tree" --test-dir
"$test_tree" --c-source ... test.tests` invocation ([shared native
standard-library tests](windows-build.md#shared-native-standard-library-tests)).
Execution resets only `work/scratch` and the run logs, then runs the aggregate
under the Windows Job Object supervisor: descendants enter the private job
before execution and are killed when supervision ends. PowerShell drains both
output pipes concurrently and reads the complete Windows exit status, which can
exceed 255. It prints that status and exits 1 for any nonzero value, because
Bash keeps only eight exit bits and a native status such as 256 would otherwise
read as success. The aggregate still uses `--no-uv-bootstrap`; fresh child
tests select their own bootstrap normally.

The same width difference applies inside the suite. A POSIX process exit
status carries only eight bits, so `os.process_tests` skips its above-255 exit
cases off Windows with a `platform:` reason, while `support.command` keeps the
complete 32-bit Windows status (`code & 0xffffffff`) rather than treating high
bits as POSIX signals.

The platform runners audit named results with
`spec/support/check_stdlib_test_output.lua`. An unfiltered run must execute every
manifest owner, and named terminal results must match the runner's summary.
Empty selections, duplicate results, unclassified skips, unfinished cases,
and unfinished fixture portability fail the gate. A filter affects execution
only and reports the number of owners it actually selected.

Repository skips use one of these reason prefixes (the public `test.skip` API
continues to accept arbitrary reasons):

- `platform: ` for semantics belonging to another operating system, such as
  POSIX user signals, Unix-domain stdio sockets, or Windows DWORD exit codes;
- `capability: ` for a probed environment limitation, such as an unavailable
  locale or Windows symbolic-link privilege;
- `unsupported: ` for a documented production API that Titan has not implemented
  on that platform; lack of test evidence alone does not justify this label;
- `portability: ` for an unfinished test fixture; this records the gap but
  deliberately fails a complete validation gate.

Keep the exclusion at the smallest independent assertion and cite the actual
platform or implementation limitation. Native source-frame assertions run on
Windows through libbacktrace; they must not be excluded merely because the
original port had not exercised them.
Port compile-time and link-time dependencies before adding runtime conditions:
every root and its native fixtures must compile on every platform. The async
foreign-work and SQLite fixtures use Windows synchronization or POSIX
counterparts; print capture and inherited stdio retain binary pipes on Windows.
`support.command` invokes the compiler's existing argv-aware platform transport
for compiler/Lua children, environment overrides, capture, and cleanup. Shell
syntax appears only in cases testing the shell-command API itself.

Filesystem, SQLite, and local watcher cases run on local NTFS in Windows.
Shared-folder notification behavior cannot satisfy or replace those assertions.
Validation evidence records source identity, OS and architecture, SDK/compiler
and provider settings, selected/passed/skipped/failed counts, and every skip
reason. An Intel macOS run does not establish Apple Silicon behavior.

Builds retain their reusable outputs; explicit `make clean` removes the
selected `TITAN_OUTPUT_DIR` (default `out/`) as a Make-owned tree. The test
cleanup helper (`spec/support/clean_generated_test_artifacts.sh` and
`spec/support/clean_generated_test_artifacts.lua`) prunes `out/` while
inspecting synthetic fixtures and, unless `--keep-output` is selected, removes
the owned `out/tests` and legacy `.titan-tests` directories recursively. First,
`clean_generated_test_artifacts.lua` inspects every regular, non-symlink `.o`
file under `spec/`, `titan/`, and the repository root with
`objectmetadata.read` and `objectmetadata.validate_parts`. When the object
carries a valid primary `.titan.source` record, the helper removes the exact
recorded `<stem><part.c_suffix>`, `<stem><part.object_suffix>`, and optional
`<stem><native.private_header>` files; a missing or malformed record deletes
nothing. Under `spec/`, the shell
script then removes a primary `<stem>.c` only when a same-stem `<stem>.titan`
source exists, preserving author-written C fixtures. Generated `.titan.h` and
`.ffi.h` headers below `spec/` and at `./test.titan.h` and `./test.ffi.h`
require their exact compiler banner; synthetic `*__test_support.*`,
`*__test_runner.*`, and `*__test_entrypoint.*` suffixes (together with their
matching executable and `.dSYM` bundle) and root `test_runner_*` paths identify
other owned fixtures. This does not consult Git, so it also works in a source
rock while preserving author-written C/header fixtures and the ordinary `out/`
provider stage. `make clean` additionally removes any legacy source-adjacent
standard-library foreign headers, providers, and `.dSYM` bundles, and the
checkout support module.

CI runs this aggregate twice: once source-linked with native coverage in the
`native-coverage` job, and once as an independent ASan+UBSan build in the
`sanitizer` job, which selects focused cases with the run target. See
[continuous integration](continuous-integration.md) for the lanes.

## Packaging and compatibility

`titan.test` is an ordinary logical module in the combined
`titan.so`/`titan.a` pair (see the [standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image)).
The same compiled `titan.test` implementation serves ordinary programs and
generated test executables. Standard installation publishes the provider pair;
it does not install a private test-source payload. Packaging tests
check those artifacts, while compiler regressions verify static-provider
retention and production-object reuse across application and test links.

The public `Case`, `Skip`, and `run` declarations use the existing native
calling conventions and metadata schema. Reinstall the compiler and standard
provider together when changing this API. Use a fresh installation after ABI
changes; earlier Titan installations are not migration sources.
