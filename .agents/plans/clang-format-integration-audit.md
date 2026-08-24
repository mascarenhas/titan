# clang-format integration audit

## Purpose and audited baseline

This audit covers removing `titan-compiler/pretty.lua` and replacing every
compiler-output use of `pretty.reindent_c` with an external `clang-format`
step. It distinguishes emitted code from the C snippets used internally to ask
the configured C compiler semantic questions. It also records the ordering and
packaging details needed to make the formatter a real, supported compiler
prerequisite rather than a cosmetic post-processing command.

The implementation was being developed concurrently in the shared checkout,
so the first sections describe the pre-migration call graph and required
contract; the final section records the live patch reviewed during the audit.
Line numbers are approximate because the surrounding FFI work is changing.

## Complete generated-source inventory

### Four old `pretty.reindent_c` call sites

All four old calls were in `titan-compiler/driver.lua`:

1. **Direct source-import checking header** — `defaultloader` rendered a
   preliminary source-owned foreign header into a sibling temporary
   `<module>.titan.h.check.tmp.*` (old driver lines 1674–1691). The checker and
   its C probes consume this path before invocation-wide output planning.
2. **Initial header plan** — `driver.plan_foreign_header` rendered the first
   `*.titan.h` plan (old lines 2505–2524).
3. **Final invocation-aware header rerender** —
   `driver.plan_foreign_headers` first finalized all direct source edges, then
   rerendered every nonempty header (old lines 2561–2604). This second render is
   the authoritative one because it contains finalized absolute companion
   includes.
4. **Persistent logical-module C** — `driver.compile` rendered one module
   translation unit, reindented it in memory, wrote the canonical `.c`, and
   compiled it (old lines 2621–2658).

The initial header-plan contents can be superseded before materialization.
There is no reason to invoke an external formatter on that in-memory first
render. Format only actual files: the preliminary checking header and the
final public-header stage.

### Generated C that bypassed `pretty.lua`

Two valid generated C sources also belonged in the migration even though they
had never used `pretty.reindent_c`:

5. **Standalone/test entrypoint C** — `write_entrypoint` wrote the public
   `__entrypoint.c` path directly (old lines 2880–2895); `compile_program`
   then compiled it. This includes ordinary programs and synthetic test
   entrypoints.
6. **Standalone static-provider protocol probe** —
   `standalone_archive_probe_source` generated a valid temporary `.c`, and
   `run_standalone_archive_probe` compiled and ran it before executable
   publication (old lines 4718–4858). It is a generated native-validation
   translation unit and should be formatted even though it is ephemeral.

### Intentional exclusion: semantic C probes

`titan-compiler/cprobe.lua` writes short workspace `.c` files for contextual
FFI questions (type compatibility, macro expressions, arithmetic/profile
facts, and rejection checks). Those snippets are inputs to the configured C
compiler, not emitted Titan codegen artifacts. Some are expected not to
compile. Formatting them would add an unrelated failure boundary before the
very compiler diagnostic the probe is designed to observe. They should remain
unformatted and the boundary should be stated explicitly in implementation
documentation.

No other production caller writes the return value of `coder.generate` or
`coder.generate_foreign_header`; the other direct calls are tests inspecting
raw generated strings.

## Recommended command contract

Add the same sort of configurable command used for the native tools:

```lua
driver.CLANG_FORMAT = os.getenv("CLANG_FORMAT") or "clang-format"
```

Parse it with `cdriver.split_shell_words`, require a nonempty dense argv, append
Titan-owned arguments, shell-quote each element with `cdriver.shell_quote`, and
execute through the driver's `run_argv`. This preserves quoted commands,
versioned binaries, launchers such as `env ... clang-format`, and paths with
spaces. `-v` must print exactly the safely quoted command before execution.

The reviewed invocation is equivalent to:

```text
$CLANG_FORMAT -i \
  '--style={BasedOnStyle: LLVM, IndentWidth: 4, SortIncludes: false}' \
  -- GENERATED_PATH
```

`CLANG_FORMAT` is parsed as an argv prefix rather than substituted as one
executable word. The inline style is deliberate:

- `BasedOnStyle: LLVM` supplies a complete, stable base rather than accepting
  a user's nearest `.clang-format`;
- `IndentWidth: 4` preserves Titan's established generated-C indentation;
- `SortIncludes: false` is semantic preservation, not merely presentation.
  Generated module preambles and source-foreign headers intentionally order
  direct, supplemental, and generated companion includes. Local
  clang-format 22 testing confirmed its default LLVM style otherwise sorts
  them.

Use `-i` so Lua neither captures nor duplicates huge output. A representative
`titan/uv/uv.c` is about 70 MB; local clang-format 22.1.8 took roughly seven
seconds and about 1 GB resident memory. Capturing another complete output
string through `io.popen`/`cdriver.capture_command` would be wasteful and makes
large stdlib builds more fragile.

A future cleanup may add `--assume-filename=<canonical .c or .h path>` for
randomly suffixed header stages, but it is not needed for current
clang-format: the reviewed tool accepts the temporary names and the explicit
style already prevents configuration discovery.

## Exact file lifecycles and failure ordering

### Persistent logical-module `.c`

Required sequence:

1. typecheck and generate raw C in memory;
2. ensure the canonical output parent exists;
3. remove the stale `.o` (so no previous object can survive a new formatter
   failure);
4. write the raw C at the canonical diagnostic `.c` path;
5. run clang-format in place;
6. only on formatter success, construct/run the ordinary `CC -c` command.

A formatter failure is a compiler failure. It must retain the canonical raw or
partially rewritten `.c` for diagnosis but leave no `.o` that callers could
mistake for this compilation. Do not remove an existing provider/library as a
side effect of a formatter command that has not yet succeeded; provider
publication already has its own later staging/validation transaction.

The old code removed the `.c` and object before writing an already-reindented
string. In-place formatting introduces a new fallible boundary, so the object
removal must precede it. A formatted source must never be followed by use of a
stale object.

### Standalone and `--test` entrypoint `.c`

The entrypoint is a persistent diagnostic artifact just like module C:

1. derive and validate its public output path;
2. remove the stale executable and entrypoint `.o` before the new fallible
   write/format boundary;
3. write raw `__entrypoint.c` at its canonical path;
4. format in place;
5. compile, then link.

On formatter failure the raw/partial entrypoint remains, while its `.o` and
executable do not. `write_entrypoint` should use the common checked file writer
(or carefully check write and close failures); a direct `io.open(..., "w")`
must not leave an unchecked close error.

### Preliminary source-check `*.titan.h`

This is already a random sibling temporary, not public state:

1. render raw header;
2. write the checking temporary;
3. format it before putting it in `context.source_foreign_header_temporaries`
   or allowing any C probe to consume it;
4. on write/format failure, remove it immediately and add the path-specific
   error to the source module;
5. on success, keep it registered so `close_resolver_context` removes it on
   every ordinary/exceptional loader exit.

A formatter failure should preserve both layers of useful context, e.g.
“could not prepare source foreign header `<temp>`: failed to format generated
file `<temp>` …”. No failed checking temporary should leak.

### Final public source-owned `*.titan.h`

Header planning must remain side-effect-free. First calculate the entire set,
resolve direct source includes against final physical paths, rerender final
contents, detect collisions, and validate every destination/ownership marker.
Then, for each plan with contents:

1. write raw bytes to a unique sibling stage on the same filesystem;
2. format the stage in place;
3. atomically rename the formatted stage over the owned public header;
4. remove the stage on every write, formatter, or rename failure;
5. set `_foreign_header_prepared` only after publication succeeds.

Do **not** unlink an existing owned header before the rename. POSIX `rename`
already atomically replaces a regular destination, and removing it first turns
a formatter/rename error into loss of a usable direct-source interface. When a
module no longer defines source foreign functions, removal of its recognized
owned header remains the explicit no-contents path. A user-owned/nonregular
path is still rejected before any formatter subprocess.

The existing writer publishes a list sequentially rather than as a multi-file
transaction. The migration need not invent broader rollback machinery: it
must preserve the existing semantics while making each replacement atomic.
If Titan later promises invocation-wide header atomicity, it should stage and
format all headers before the first rename and use backups/rollback as the
provider publisher does.

### Ephemeral standalone archive-protocol `.c`

Write the temporary source, format it, then compile it. On formatter failure,
invoke the existing cleanup closure so source, object, executable, and dSYM
are all removed. A compile or execution failure keeps the existing cleanup and
diagnostic behavior. Unlike persistent module/entrypoint C, this private
validation source need not be retained for users.

## Tool discovery, build, packaging, and CI

### Driver and Make

`CC`, `AR`, and `RANLIB` already accept environment-overridable command
strings. `CLANG_FORMAT` should follow that convention and be parsed with the
same shell-word and quoting helpers. It is a presentation tool, not part of the
C target-profile descriptor: do not feed it to `cprobe.Service`, `CC`, or final
link arguments.

The top-level Makefile must:

- define `CLANG_FORMAT ?= clang-format`;
- export it to every recipe-owned `titanc`, especially LuaRocks
  `post_install`/`rock-post-install` and standard-library builds;
- include the exact command string in `$(STDLIB_CONFIG_STAMP)` next to
  `CC`/`AR`/`RANLIB`, so changing formatter identity/configuration invalidates
  the generated standard-library image rather than accepting a stale warm
  completion stamp;
- mention clang-format in `make help` prerequisites.

The rockspec should remove the installed
`["titan-compiler.pretty"] = "titan-compiler/pretty.lua"` module. A generic
LuaRocks 3.13 `external_dependencies = { ... program = "clang-format" }` was
considered but is **not** recommended for this repository: its program lookup
uses LuaRocks' configured external dependency prefixes rather than Titan's
supported ordinary `PATH`/custom `CLANG_FORMAT` command policy, and can reject
Homebrew or wrapper commands that Titan itself correctly supports. Treat the
program as a documented runtime compiler prerequisite and let the installed
compiler resolve the configured command normally.

The Make compiler-source inventory is wildcard-based and therefore needs no
explicit removal. The rockspec's explicit Lua module inventory does.

### CI jobs

Every job that invokes the compiler needs the formatter independently:

- `test-linux-stdlib`: add `clang-format` to the regular apt dependency step;
- `test-linux-compiler`: it restores a prepared tree on a fresh runner, so add
  its own apt installation after checkout/before covered compiler tests—the
  executable is not part of the uploaded workspace tree;
- `test-macos`: add `clang-format` to the Homebrew dependency step;
- `sanitizer`: add `clang-format` to its independent apt dependency step.

Do not rely on an image's incidental tool version. Tests must not hard-code
`PREFIX/bin:/usr/bin:/bin`, because that hides Linuxbrew/Homebrew formatters.
The five installed-compiler harnesses found during the audit were:

- `spec/coder/multi_module_libraries_spec.lua`;
- `spec/coder/multi_module_grouping_spec.lua`;
- `spec/coder/multi_module_path_runtime_spec.lua`;
- `spec/coder/static_dynamic_facade_spec.lua`;
- `spec/coder/static_protocol_mismatch_spec.lua`.

They should prefix the installed Titan bin while retaining ambient `PATH`, as
`spec/rockspec_spec.lua` already does.

## Removal and documentation inventory

Delete:

- `titan-compiler/pretty.lua`;
- `spec/pretty_spec.lua` (its exact indentation snapshots test the retired
  heuristic, not the external-tool contract).

Remove/update live references in:

- `titan-compiler/driver.lua` (`require` and all four calls);
- `titan-compiler/coder.lua`'s comments about `reindent_c`;
- the active rockspec's explicit compiler-module list;
- `AGENTS.md` pipeline, coder/driver heading, style contract, prerequisites,
  and stdlib configuration-stamp description;
- `doc/implementation/codegen-overview.md`;
- `doc/implementation/driver.md`;
- `doc/implementation/index.md` anchors, module inventory, and pipeline;
- `README.md` and `doc/language/modules.md` for the new user-visible build
  prerequisite and `CLANG_FORMAT` override;
- historical Lua migration notes only by qualifying them as a former pass;
  do not rewrite historical plan records as though `pretty.lua` never existed;
- stale “pretty.lua multiply-evaluation gotcha” wording in
  `spec/coder/variadic_spec.lua` (the real gotcha is repeated template operand
  expansion, independent of the formatter).

The generated-C template contract becomes: templates must render valid C,
braces remain mandatory where the generator's semantics need them, and
clang-format owns presentation. Preserve ordinary comments/source text and do
not rely on formatting to repair invalid C.

## Test plan and acceptance matrix

1. **Driver unit seam (`spec/driver_spec.lua`)**
   - configured `CLANG_FORMAT` with quoted executable/options becomes the
     expected dense argv;
   - a generated pathname containing spaces remains one argument;
   - verbose output is exactly the safely quoted command; nonverbose is quiet;
   - missing/nonzero tool errors include artifact path, termination kind, and
     exit status;
   - malformed and empty commands fail before subprocess execution;
   - public-header formatter failure preserves old owned bytes, does not mark
     the AST prepared, and leaks no stage; success publishes the formatter's
     bytes.
2. **Real compiler ordering (`spec/coder/driver_flags_spec.lua`)**
   - successful `titanc -v` shows one formatter command for the persisted
     module `.c` before its `CC -c` command;
   - a failing wrapper (exit 23) leaves `.c`, removes/no longer creates `.o`,
     and proves no `CC -c` ran.
3. **Real-tool fixed point (`spec/coder/foreign_functions_spec.lua`)**
   - existing persisted module C and `test.titan.h` are clang-format fixed
     points under Titan's exact explicit style;
   - retain the header ownership banner at byte zero, include-order, UCN,
     symbol, compilation, and runtime assertions.
4. **Direct-source and entrypoint integration**
   - existing multi-module source-private tests continue to prove final
     headers exist before consumer compilation;
   - a focused logging-wrapper or fixed-point case should prove standalone/test
     `__entrypoint.c` is formatted;
   - the static-provider probe may be asserted by bounded temporary-name
     logging, without exposing its random path as API.
5. **Installed package (`spec/rockspec_spec.lua`)**
   - installed `titan-compiler/pretty.lua` is absent;
   - rock manifest lacks `pretty.lua` but still contains ordinary compiler
     modules;
   - an installed `titanc` smoke inherits ordinary `PATH` and formats its
     emitted C.
6. **Do not use brittle goldens**
   - no exact clang-format whitespace snapshot or assumed host version;
   - no one-global-invocation-count assertion;
   - do not match random stages exactly;
   - at least one real-tool fixed-point test, not only a fake formatter that
     exits zero.

Run focused driver/coder/foreign-function/packaging specs after reinstalling
the edited compiler snapshot, then the complete compiler group and uncovered
stdlib/packaging gates. The dispatch-only macOS suite remains required because
tool discovery and available clang-format versions differ from Linux.

## Live-patch review outcome (2026-08-12)

The concurrent implementation was reviewed against this inventory. It now:

- removes the driver import, deletes `pretty.lua`/`pretty_spec.lua`, and removes
  the rockspec module;
- implements parsed, safely quoted, verbose `CLANG_FORMAT` execution with the
  explicit LLVM/four-space/no-sort style;
- formats all five materialized artifact classes: preliminary checking
  header, staged public header, module C, standalone/test entrypoint C, and the
  standalone archive validation C;
- correctly leaves `cprobe.lua` snippets alone;
- formats headers before consumer probes/publication, atomically replaces each
  public header, cleans temporary failures, removes stale objects before
  formatter failure can return, retains persistent raw/partial C for diagnosis,
  and cleans the ephemeral native-validation probe;
- exports and stamps `CLANG_FORMAT` in Make;
- installs clang-format in all four CI runners and preserves ambient PATH in
  the five installed-compiler specs;
- updates current docs and qualifies historical references;
- adds focused argv/error/header-rollback, real compiler ordering/failure,
  fixed-point, and installed-module-inventory coverage; and
- uses ordinary ` *` continuation lines in generated multiline C comments, so
  one formatter invocation is itself a fixed point even in protected-boundary
  heavy translation units; and
- removes every template-introduced blank physical line immediately after
  generated `#line` directives before formatting, then enforces the same
  invariant at the final formatted-file boundary, preserving exact Titan
  traceback lines.

The reviewed focused tests reported passing. Remaining optional strengthening
is a dedicated persisted entrypoint/protocol-probe formatter assertion; their
production call sites are present and ordered correctly. The existing
per-header sequential publication semantics were intentionally retained rather
than expanded into a new invocation-wide transaction.
