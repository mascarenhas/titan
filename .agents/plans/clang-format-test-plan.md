# Test plan: replace `pretty.lua` with `clang-format`

## Scope and current coverage

The current formatter is isolated in `spec/pretty_spec.lua`: six exact-output tests only exercise `pretty.reindent_c`. They do not exercise a real compiler write, command quoting, a tool failure, or the installed compiler. Those snapshots should be deleted with `titan-compiler/pretty.lua`; do not translate them into clang-format indentation snapshots, because supported Linux/macOS hosts can ship different clang-format versions.

The formatter replacement has four existing `pretty.reindent_c` call sites in `titan-compiler/driver.lua`:

1. the temporary `.titan.h.check.tmp.*` header used while checking a direct source import;
2. a single planned foreign header;
3. the final invocation-wide foreign-header rerender;
4. a module's persisted generated `.c`.

Two other compiler-written C sources currently bypass `pretty.lua` but fall under “generated C files”: the persisted standalone `__entrypoint.c` and the ephemeral static-provider executable probe source. C-probe snippets in `cprobe.lua` are checker implementation inputs, not Titan-generated source artifacts, and need not acquire a formatting subprocess.

Useful existing gates to extend rather than duplicate:

- `spec/driver_spec.lua` has pure foreign-header planning/ownership tests and is the right place for command/failure unit tests.
- `spec/coder/driver_flags_spec.lua` already captures `titanc -v` output and asserts exact shell-quoted tool commands.
- `spec/coder/foreign_functions_spec.lua` already checks the generated header banner at byte 1, UCN/source-local declarations, inclusion from generated C, compilation, and runtime behavior.
- `spec/coder/multi_module_libraries_spec.lua` already proves direct-source dependency headers are prepared before consumers and that user-owned headers are preserved.
- `spec/coder/multi_module_grouping_spec.lua` already retains and checks a standalone `application__entrypoint.c`.
- `spec/rockspec_spec.lua` already inventories installed Lua modules/rock manifest and compiles with the installed `$PREFIX/bin/titanc` from a separate workspace.
- `spec/asan_generated_c_context_spec.lua` already proves persisted generated `.c` and `.titan.h` artifacts can be saved for sanitizer shadow compilation; no duplicate ASan test is needed.

## Behavioral contract to pin

Tests should establish all of the following without pinning clang-format's chosen whitespace:

- clang-format is invoked through the driver's argv quoting path, not raw shell concatenation;
- a path containing spaces is one formatter argument;
- `-v` prints the exact quoted formatter command, and non-verbose compilation does not;
- formatting finishes successfully before the corresponding `cc -c` starts;
- persisted module C, source-foreign headers, and standalone entrypoint C are formatted;
- a formatter failure is a compiler failure with the artifact pathname and exit status, and native compilation is not attempted;
- a generated `.c` remains available as a diagnostic source artifact on formatter/compiler failure, while a foreign header is staged and only replaces an existing owned header after formatting succeeds;
- temporary checking headers/probe sources are cleaned on both success and failure;
- the installed compiler has no runtime dependency on the deleted `titan-compiler.pretty` module and finds `clang-format` from the ordinary inherited `PATH`.

## Concrete focused tests

### 1. `spec/driver_spec.lua`: deterministic command and failure tests

Add a `describe("generated C formatting", ...)` around a small public/testable driver seam such as `driver.format_generated_file(filename, verbose)`. The production helper may remain conceptually internal, but exposing the same pattern as other driver test seams is preferable to testing private duplicated logic.

**`quotes paths and reports the exact formatter command under verbose mode`**

- Save and restore `os.execute` and `_G.print` with `xpcall`/`table.pack`, even if an assertion fails.
- Make `os.execute` capture its one command and return `true, "exit", 0`.
- Call the helper with `"/tmp/titan format probe/generated module.c"` and `verbose=true`.
- Assert the execution and printed strings are identical and contain separately quoted argv, e.g. `'<formatter>' '-i' '/tmp/titan format probe/generated module.c'` (plus any deliberately selected stable flags).
- Repeat with `verbose=false` and assert no print. This directly covers existing `run_argv` behavior without a real compile.

**`turns a formatter exit into a path-specific compiler error`**

- Make `os.execute` return `nil, "exit", 23`.
- Assert the helper returns false/nil rather than throwing, and its diagnostic contains `clang-format`, the full generated path, `exit`, and `23`.
- A missing-tool case may use the same table-driven test with status 127; one nonzero test is sufficient if the message does not special-case statuses.

**`does not publish a foreign header until its staged copy formats`**

- Create a temporary directory whose name contains a space.
- Seed `item.titan.h` with `driver.FOREIGN_HEADER_MARKER` plus recognizable old bytes.
- Construct a valid plan with different new contents and an empty AST.
- Inject a formatter failure for the sibling staging pathname (either replace the exported formatting seam temporarily or use an executable wrapper).
- Assert `driver.write_foreign_header_plan` fails, the public header is byte-for-byte the old version, `plan.ast._foreign_header_prepared` is not set, and no `.tmp.*` sibling remains.
- Then inject a formatter that rewrites the staged file and succeeds. Assert the formatted bytes, not the raw plan bytes, become public, the AST flag is set, and the temporary is gone.

This test is important because the old writer removes an owned header before writing it; adding clang-format creates a new fallible boundary and must not turn a usable direct-source header into partial formatter output.

**`keeps planning side-effect free`**

- Temporarily count calls to the formatting seam.
- Run `plan_foreign_header`/`plan_foreign_headers`; assert zero calls.
- Run `write_foreign_header_plans`; assert formatting happens there. Output-collision and user-owned-path validation must still finish before a formatter subprocess.

### 2. `spec/coder/driver_flags_spec.lua`: real `titanc -v` ordering

Extend the existing successful `-v` setup rather than adding another expensive compiler fixture.

- Filter verbose output for the exact persisted path `spec/fixtures/driver_flags/application/flagprobe.c`.
- Assert exactly one formatter command names that path and that the pathname is quoted as one argv element.
- Locate the `cc` line containing both `'-c'` and the same path; assert the formatter line precedes it.
- Do not count every formatter line globally: library validation may format private probe sources too.
- Keep the direct driver-unit assertion for non-verbose behavior rather than compiling the fixture twice.

If failure injection is performed through a real command, create a temporary `clang-format` wrapper on `PATH` (or use a test-only/configured formatter argv). The wrapper should verify its argv count, log the final filename unambiguously, delegate to the absolute real formatter, and optionally append a harmless `/* formatter sentinel */`. Never construct a wrapper command by concatenating an unquoted source path.

### 3. `spec/coder/foreign_functions_spec.lua`: persisted C/header integration

Enhance the existing test **“emits one reserved companion header and the UCN entry family”**:

- Retain its current byte-prefix banner assertion. This is also the ownership marker consumed by driver and sanitizer code, so clang-format must not move anything ahead of it.
- Add a helper that runs the same `clang-format` executable without `-i`, captures stdout, and asserts it is byte-for-byte equal to the persisted file.
- Apply it once to `test.titan.h` and once to `test.c`.
- Keep all current UCN, declaration, include, native-symbol, and runtime assertions.

A fixed-point assertion proves the real files are formatted while avoiding a hard-coded LLVM/WebKit whitespace snapshot. It also catches accidental formatting of only the in-memory header or only the C translation unit.

### 4. Direct-source headers and standalone entrypoint

Use existing integration cases, not new broad fixtures:

- In `spec/coder/multi_module_libraries_spec.lua`'s **“prepares source foreign headers before compiling direct consumers”**, run through a logging wrapper once and assert calls include the provider's temporary checking header, both final `.titan.h` files, and both module `.c` files. Match the random checking-header name by bounded prefix/suffix, not an exact tmpname. Existing include-order/runtime assertions prove formatting did not change semantics.
- In `spec/coder/multi_module_grouping_spec.lua`'s **“bundles unrelated roots when exactly one root defines main”**, assert `application__entrypoint.c` is a clang-format fixed point (or contains the injected wrapper sentinel). This distinguishes entrypoint formatting from module formatting.
- If the implementation formats the ephemeral static-provider executable probe, assert its logged temporary `.c` call and cleanup in the wrapper test, but do not expose or pin `os.tmpname()` output. Do not add formatting to `cprobe.lua` merely to satisfy this matrix.

### 5. Failure before native compilation and source-artifact state

Add one subprocess-level failure case, preferably beside `driver_flags_spec` or the multi-module compiler harness:

- Put a failing formatter wrapper in a directory with spaces and make it exit 23.
- Put a CC wrapper behind it that creates a marker if invoked.
- Compile a tiny module whose generated output path also contains spaces.
- Assert `titanc` fails with the generated pathname and formatter exit 23, the CC marker is absent, no `.o` exists, and the generated `.c` still exists for diagnosis.
- Assert the verbose formatter command is shell-safe if `-v` was used.
- For a temporary header/probe failure, additionally assert no random staging/checking file leaks.

This is stronger than only stubbing a return tuple: it proves formatter-before-compiler ordering and actual POSIX argv boundaries.

### 6. `spec/rockspec_spec.lua`: installed compiler and module removal

Extend the installed-tree inventory:

- Assert `$PREFIX/share/lua/5.5/titan-compiler/pretty.lua` is absent.
- Assert `pretty.lua` is absent from the installed rock manifest while the normal driver/coder modules remain present.
- In the existing installed-driver smoke that produces `workspace/installed.c`, assert that file is a clang-format fixed point. The successful compile/run already proves the installed `driver.lua` no longer tries to require `titan-compiler.pretty`.

The source rock/rockspec should likewise contain no installed `titan-compiler.pretty` entry; do not keep a compatibility stub solely for stale installations.

## PATH regression found during inspection

Several native compiler specs currently replace, rather than prefix, `PATH` with `PREFIX/bin:/usr/bin:/bin`:

- `spec/coder/multi_module_libraries_spec.lua`
- `spec/coder/multi_module_grouping_spec.lua`
- `spec/coder/multi_module_path_runtime_spec.lua`
- `spec/coder/static_dynamic_facade_spec.lua`
- `spec/coder/static_protocol_mismatch_spec.lua`

That hides the active formatter on this Linux checkout (`/home/linuxbrew/.linuxbrew/bin/clang-format`) and can hide a Homebrew formatter on macOS. Change those harnesses to `PREFIX/bin:` plus the ambient `PATH`, as `rockspec_spec.clean_environment` already does. The installed-compiler test must exercise this inherited-path behavior; do not bypass formatting or add a checkout-relative formatter path.

## Assertions to avoid

- Do not preserve the six exact `pretty_spec.lua` indentation snapshots.
- Do not assert two-space versus four-space indentation, brace wrapping, total file size, or complete generated-file golden text.
- Do not assume one global formatter invocation count; source headers, entrypoints, and validation probes legitimately add calls.
- Do not match random temporary names exactly.
- Do not allow a fake formatter that merely exits zero to be the only integration proof; at least one real-tool fixed-point test is required.

## Validation sequence

Because Busted loads the installed rock snapshot, reinstall before focused tests after changing driver/rockspec files:

```sh
export PREFIX=/tmp/titan-$USER-clang-format
export PATH="$PREFIX/bin:$PATH"
make lua
make luarocks
"$PREFIX/bin/luarocks" make

"$PREFIX/bin/busted" spec/driver_spec.lua --filter='generated C formatting'
"$PREFIX/bin/busted" spec/coder/driver_flags_spec.lua
"$PREFIX/bin/busted" spec/coder/foreign_functions_spec.lua \
  --filter='reserved companion header'
"$PREFIX/bin/busted" spec/coder/multi_module_libraries_spec.lua \
  --filter='source foreign headers'
"$PREFIX/bin/busted" spec/coder/multi_module_grouping_spec.lua \
  --filter='exactly one root defines main'
"$PREFIX/bin/busted" spec/rockspec_spec.lua --filter='installed'
```

Then run the complete compiler group and the normal uncovered packaging/runtime gates. The dispatch-only macOS suite is required because formatter discovery and shipped clang-format versions differ across the two supported hosts.
