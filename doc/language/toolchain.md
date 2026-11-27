# The `titanc` toolchain, linking, and coverage

`titanc` compiles dotted Titan module names to C, invokes the native C
toolchain, and links standalone executables, test runners, or library
providers.

## Command-line options

`titanc` takes zero or more dotted logical module names (for example
`app.main`, never file paths) and compiles them from the source tree. At
least one module name is required unless you pass `--print-root`,
`--test-dir`, or `-c --c-source`.

### Core build and target options

| Option | Meaning |
| --- | --- |
| `<module>...` | Dotted logical module names to compile as build roots (resolved only from authored `--tree` roots, never the implicit SDK source fallback). |
| `-o`, `--output DIR` | Root directory for all generated files, created if missing. Required for `--target browser` and whenever a build selects an installed `.titan` source through the SDK fallback. |
| `--exe PATH` | Exact destination for a standalone or `--test` executable, relative to the current directory. |
| `-t`, `--tree PATH` | Semicolon-separated authored source root directories (default: `.`). Positional roots and `--test-dir` use only these authored roots; ordinary imports search authored roots before the read-only implicit SDK root `<root>/lib/titan/0.6`. |
| `-T`, `--target TGT` | Compilation target: host OS (`linux`, `darwin`, `windows`) or `browser` (default: `TITAN_TARGET` or host OS). |
| `--static` | Require archives for compiled dependencies of a Linux/macOS executable or test. Also valid with `-c`, even for roots without `main`. |
| `--source-first` | Prefer available `.titan` source dependencies over compiled providers, with compiled fallback on miss. |
| `--incremental` | Certify and reuse unchanged module objects, `--c-source` objects, and final links. |
| `-c`, `--compile-only` | Generate owned objects and headers only without linking. Plain non-`main`, non-`--test`, non-`--static` `-c` compiles as a prospective library (leaving installed fallback sources external). Rebuilds owned sources unless combined with `--incremental`. |
| `--no-source-records` | Omit the trusted source record each module object normally carries. The build links and archives as usual, but its objects can never be reused or restored by a later build, so the option cannot be combined with `--incremental`, `-c`, or `--print-ast`. Use it for a link-only library whose size matters, such as the [playground's browser provider](../implementation/playground-bundle.md#the-link-only-provider). |
| `--no-uv-bootstrap` | Call `main(args)` directly in standalone or `--test` executables even if `titan.uv` installs its bootstrap hook. |
| `--print-root` | Print the active Titan installation root to stdout and exit. Ignores `--target` and `TITAN_TARGET`. |
| `-u`, `--lua PATH` | Path to a Lua source and build tree (source checkouts only; rejected by an installed compiler). |

### Native compiler, linker, and C-source options

| Option | Meaning |
| --- | --- |
| `-I`, `--include-dir DIR` | Add an include directory for C-FFI parsing, probes, generated C, and `--c-source` files, searched before SDK headers. Repeatable, order preserved. |
| `-D`, `--define DEF` | Define a preprocessor macro `NAME[=VALUE]` for C-FFI parsing, probes, generated C, and `--c-source` files. Repeatable, order preserved. |
| `--cflag ARG` | Pass one native compile argument (for example `--cflag=-pthread`). Repeatable, order preserved. |
| `-L`, `--library-dir DIR` | Add a native library search directory for final links. Repeatable, order preserved. |
| `-l`, `--link LIB` | Link a native library (comma-separated lists allowed). Repeatable, order preserved without deduplication. |
| `--ldflag ARG` | Pass one native link argument (for example `--ldflag=-Wl,--as-needed`). Repeatable, order preserved. |
| `--c-source FILE` | Compile and certify an authored or generated C file under `<output>/.native/`, linked before `-X` payloads. Repeatable, order preserved. |
| `--print-c-objects` | With `-c` and at least one `--c-source`, print each certified object's absolute path on stdout in argument order. |
| `-X`, `--extra-object FILE...` | Carry native `.o` or `.a` payloads into linked library providers or final executables. |

### Testing and coverage options

| Option | Meaning |
| --- | --- |
| `--test` | Source-prefer the dependency graph, discover public `test_*` functions, and link a test executable. |
| `--test-dir DIR` | With `--test`, discover test roots (`test`, `tests`, `spec`, `specs`, `*_test(s)`, `*_spec(s)`) below `DIR`. Repeatable. |
| `--test-exclude MOD` | With `--test` and `--test-dir`, exclude a discovered logical module. Repeatable. |
| `--coverage` | Instrument non-test source modules for executable-line coverage. Requires a standalone or `--test` executable (or `-c`). Unsupported on `--target browser`. |
| `--coverage-backend NAME` | Coverage backend: `gcc-gcov` (Unix default) or `llvm-gcov` (Windows default). Requires `--coverage`. |
| `--coverage-module GLOB` | Override automatic coverage selection with a logical-module glob (`*` and `?`). Repeatable. Requires `--coverage`. |
| `--coverage-root DIR` | Source root used for coverage report paths (default: `.`). Requires `--coverage`. |
| `--coverage-gcov CMD` | Override the `gcov` command (default: `GCOV`, `gcov`, or `llvm-cov gcov`). Requires `--coverage`. |
| `--coverage-format FMT` | Request an additional report format: `html`, `lcov`, or `cobertura` (requires `gcovr`). Repeatable. Requires `--coverage`. |
| `--coverage-output DIR` | Coverage report directory (default: `<output>/.coverage/report`, or `.coverage/report` without `-o`). Requires `--coverage`. |
| `--coverage-gcovr CMD` | Override the `gcovr` command (default: `GCOVR` or `gcovr`). Requires `--coverage`. |

### Parallelism, output, and diagnostics

| Option | Meaning |
| --- | --- |
| `-j`, `--jobs N` | Cap concurrent module workers and native compiler jobs (default: `TITAN_JOBS` or `4`). Must be a positive integer. |
| `--c-parts N` | Cap generated C translation units per module above 2 MiB (default: `TITAN_C_PARTS`, or `4` on Linux and `1` elsewhere). `1` disables splitting. |
| `-q`, `--quiet` | Suppress progress output; stderr keeps only diagnostics and native tool output. |
| `-v`, `--verbose` | Print native tool commands and `--incremental` hit/miss decisions to stderr alongside plain progress lines. |
| `--pretty-print` | Format generated C and `.titan.h` headers in place with `clang-format` (`CLANG_FORMAT`). |
| `--print-ast` | Parse, typecheck, and print the checked AST to stdout. |
| `--no-line-directives` | Omit `#line` directives from generated C so native tools report generated C lines. Disallowed on `--target browser`. |

### Lint options

| Option | Meaning |
| --- | --- |
| `--lint` | Check the named modules (and `--test --test-dir` roots) and print [style diagnostics](#linting-with---lint) instead of building. |
| `--lint-enable RULE` | Turn on an opt-in rule; `--lint-enable=all` turns on every rule. Repeatable. |
| `--lint-allow RULE` | Turn a rule off. Repeatable. |
| `--lint-deny RULE` | Turn a rule on and make its diagnostics fail the run; `--lint-deny=warnings` or `--lint-deny=hints` fails every enabled rule of that severity. Repeatable. |
| `--lint-format FMT` | Diagnostic output: `human` (default) or `json`. |

### Incompatible option combinations

- `-q` and `-v` cannot be combined.
- `-c` rejects link-only options: `--exe`, `-l`, `-L`, `--ldflag`, `-X`, and `--no-uv-bootstrap`.
- `--exe` and `--no-uv-bootstrap` are valid only for standalone or `--test` executables.
- `--print-root` cannot be combined with module names or `--print-c-objects`.
- `--print-ast` cannot be combined with `--incremental` or `--print-c-objects`.
- `--print-c-objects` requires `-c` and at least one `--c-source`.
- `--test-dir` requires `--test`; `--test-exclude` requires both `--test` and `--test-dir`.
- `--test` reserves `titan.test` and rejects it as an explicit root.
- `--lint` accepts only `-t`, `-T`, `-I`, `-D`, `-u`, `-q`, `-v`, `--test`, `--test-dir`, `--test-exclude`, and the `--lint-*` options; every other build, link, output, or `--print-*` option is rejected. The `--lint-*` options require `--lint`.

### Selecting the target (`-T` / `--target` and `TITAN_TARGET`)

`--target` overrides `TITAN_TARGET`, including an explicit empty `--target ''`
that selects the host. Native compilation targets the host OS only; Linux,
macOS, and Windows hosts also support `browser` (see
[WebAssembly and the browser target](browser-target.md)).

| `-T` / `--target` or `TITAN_TARGET` | Effect |
| --- | --- |
| absent or empty | Select the host OS (`linux`, `darwin`, `windows`, or unlabeled native host). |
| host OS label | Same as absent. |
| `browser` | Build WebAssembly output with `wasi-sdk` and Binaryen. Requires `--output`. |
| another OS label | Error: native cross-compilation is not supported. |
| `native` | Error: `native` is a source-variant label (see [Modules](modules.md)), not a build target. |
| any other value | Error: unknown target. |

Target validation runs before source lookup. Only `titanc` reads
`TITAN_TARGET`; the language server selects targets from workspace
configuration.

## Linting with `--lint`

`titanc --lint` checks modules exactly as a build would (parsing, type
checking, and C-header analysis for `foreign import`) and then reports style
and correctness diagnostics. It generates no C, objects, providers, or
executables and takes no output locks; header analysis may still run cached C
preprocessor and probe commands.

```sh
titanc --lint -t src app.main app.store
titanc --lint --lint-enable=all --test --test-dir src/tests -t src app.main
titanc --lint --lint-deny=warnings --lint-format=json -t src app.main
```

Positional modules are dotted logical names resolved only from the `-t`
roots, never from the SDK source fallback, and `--test --test-dir` (with
`--test-exclude`) adds the [discovered test roots](#testing-and-coverage-options)
without building a runner. Imports resolve as usual, but only the requested
roots are linted; each diagnostic names the file (including a folder-module
contributor) that contains the construct. `-T`/`--target` selects the target's
source variants; `browser` needs the installed browser SDK. If any requested
module fails to resolve, parse, or type-check, `titanc` prints the compiler
errors, reports no lint diagnostics, and exits with status 1.

Diagnostics are sorted by file, line, column, and rule. The `human` format
prints `file:line:col: warning[rule]: message` (or `hint[rule]`); the `json`
format prints one document,
`{"version":1,"diagnostics":[{"file":…,"line":…,"col":…,"severity":"warning"|"hint","rule":…,"message":…,"denied":true|false}]}`.

Every rule has a fixed severity: the default rules report `warning`s, and the
opt-in rules report `hint`s only after `--lint-enable`. The rule options apply
strictly left to right: `--lint-enable` turns a rule on (keeping it denied if
it was), `--lint-allow` turns it off, `--lint-deny=RULE` turns it on and
denies it, and `--lint-deny=warnings` or `=hints` denies every rule of that
severity that is on at that point. An unknown rule name is an error. Individual
lines can also suppress named rules with
[in-source exceptions](#in-source-exceptions). `titanc --lint` exits with
status 1 when any invalid directive or denied diagnostic is reported, and with
status 0 otherwise, warnings included.

| Rule | Default | Reports |
| --- | --- | --- |
| `unused-local-binding` | warning | A local or loop variable that is never read or written; rename it to `_` (its initializer still runs). |
| `unused-lambda-param` | warning | The only named parameter of a lambda when it is never used; rename it to `_`. |
| `prefer-record-call-shorthand` | warning | `Record.new(...)` where deleting `.new` gives the same call ([calling a record](records.md#calling-a-record)); keep any owner type arguments. |
| `unmatched-public-test-signature` | hint | A public `test_*` function in a module importing `test` that `--test` does not discover (it does not take exactly one `test.Context`). |
| `union-identity-equality` | hint | `==`/`~=` against a freshly constructed variant of an `async`, `uv`, HTTP mode, `reflect.Type`, or `websocket.MessageType` union: union equality is identity, so the result never changes. |
| `stdlib-import-spelling` | hint | `import "titan.<name>"` where the short standard-library spelling `"<name>"` exists. |
| `prefer-const-local-field` | hint | A non-const `local` record field, or an unmarked field of a `local record` (other than inline C storage), that this module never assigns. |
| `prefer-const-local` | hint | A single-name local with a written initializer, other than inline C storage, that is read but never reassigned. |
| `boolean-option-silent-truthiness-local` | hint | An unannotated local initialized from a `boolean?`, which turns nil into false. |
| `ephemeral-interface-map-key` | hint | Indexing a Map keyed by an Interface with a concrete value, which builds a new wrapper key each time. |
| `catch-reraise-resets-trace` | hint | `raise error` inside `catch`, which starts a new traceback (bare `raise` keeps it). |
| `extra-do-block-around-try` | hint | A `do ... catch ... end` that is a block's only statement, where the block could carry the `catch`. |
| `duplicate-record-literal-field` | hint | A record literal naming the same field twice. |
| `gc-finalizable-non-collectable-arg` | hint | `gc.finalizable` on a scalar, string, or raw C value, which always raises. |
| `gc-finalizable-captures-target` | hint | A finalizer lambda that captures its own target. |
| `race-any-unmanaged-losers` | hint | An inline `async.run*` argument to `async.race_*`/`any_*`, whose losing Task can never be cancelled. |
| `header-dependent-public-c-export` | hint | A public declaration whose type, including the public fields and variants of the records and unions it reaches, exposes a header-dependent C type, so importers need the same headers. |
| `dso-imported-record-literal` | hint | A raw record literal for a record from a compiled provider. |
| `dso-closed-union-case` | hint | An exhaustive `case` without `else` on a union from a compiled provider. |

The last two matter when that provider is replaced independently of the code
that uses it ([Replacing shared-library dependencies](#replacing-shared-library-dependencies)).
As a conservative v1 exclusion, they and `header-dependent-public-c-export`
skip every module that defines a discovered `test_*` function, including a
module that mixes tests with production code; this does not mean such a
module has no importers.

### In-source exceptions

Suppress a named lint rule on a specific declaration or statement with a
short comment of the form:

```titan
local record Counter
  -- titan-lint: allow(prefer-const-local-field): mutated through Lua
  count: integer
  step: integer -- titan-lint: allow(prefer-const-local-field) -- assigned by tests
end
```

Multiple rule IDs are comma-separated inside `allow(...)`, and an optional
explanation follows `:` or `--`:

- **Placement.** A directive after code on the same line covers that line. A
  standalone directive covers the next code line, skipping blank lines,
  ordinary comments, and `---` documentation comment blocks; stacked standalone
  directives combine. Place standalone directives *above* `---` documentation
  comments, never inside them.
- **Strict validation.** Every directive must name one or more valid rule IDs
  explicitly (group names `all`, `warnings`, and `hints` are rejected).
  `titanc --lint` exits with status 1 and reports
  `file:line:col: invalid titan-lint directive: ...` for missing colons
  (`-- titan-lint allow(...)`), unknown verbs, empty or duplicate rule lists,
  unclosed parentheses, unexpected trailing text, empty reasons after `:` or
  `--`, directives inside `---` documentation comments, or dangling standalone
  directives before end of file or a block closer (`end`, `else`, `elseif`,
  `until`, `catch`, `when`). Ordinary comments that mention `titan-lint`
  without `titan-lint:` (or `titan-lint allow(`) and directive text inside
  string literals or `--[[ ... ]]` long comments are ignored.
- **Precedence with `--lint-deny`.** An in-source `allow(...)` drops matching
  diagnostics before reporting, counting, and `--lint-deny` checks, so an
  allowed line passes even under `--lint-deny=warnings`, `--lint-deny=hints`,
  or `--lint-deny=<rule>`.
- **Unused exceptions.** An `allow(...)` whose rule does not fire on that line
  never fails, so an exception for a rule that triggers only on another
  target's source variant or contributor remains safe across targets.

### Repository standard-library lint targets

In a Titan source checkout, two `Makefile` targets run `titanc --lint` over the
standard library and its test suites:

- `make titan-stdlib-lint` lints the native standard library in its build
  environment and all native test roots and helper modules under
  `spec/stdlib/titan`.
- `make titan-stdlib-browser-lint` lints the browser standard library, browser
  test owners, and helper modules under `--target browser` (requiring the
  installed browser SDK) and verifies that the native and browser lint roots
  cover every source under `spec/stdlib/titan`.

Both targets default `TITAN_LINT_FLAGS` to
`--lint-enable=all --lint-deny=warnings --lint-deny=hints`. Override
`TITAN_LINT_FLAGS` to replace the rule switches (for example,
`TITAN_LINT_FLAGS='--lint-enable=all --lint-format=json'`).

## Environment variables

### Titan variables

| Variable | Effect |
| --- | --- |
| `TITAN_ROOT` | Override the Titan SDK installation root for `titanc`, compiled programs, and Lua hosts. |
| `TITAN_PATH_0_6` | Semicolon-separated directories searched for compiled Titan providers (checked before `TITAN_PATH`). |
| `TITAN_PATH` | Fallback compiled-provider search path when `TITAN_PATH_0_6` is unset. |
| `TITANC` | Single program name or path executed with `--print-root` for the runtime SDK fallback when `TITAN_ROOT` is unset. |
| `TITAN_TARGET` | Default compilation target when `-T` / `--target` is omitted. |
| `TITAN_BUILD_PROFILE` | Native and browser build profile: `production` (default) or `validation`. |
| `TITAN_JOBS` | Default `--jobs` cap (fallback: `4`). |
| `TITAN_C_PARTS` | Default `--c-parts` cap (fallback: `4` on Linux, `1` on macOS/Windows). |
| `TITAN_EXTRA_CPPFLAGS` | Extra `-I`/`-D` flags shared by C-FFI parsing, probes, generated C, and `--c-source`. |
| `TITAN_EXTRA_CFLAGS` | Extra native compile flags for generated C and `--c-source`. |
| `TITAN_EXTRA_LDFLAGS` | Extra final-link flags (unused under `-c`). |
| `TITAN_NO_LINE_DIRECTIVES` | Set to `1` to omit `#line` directives (rejected on `--target browser`). |
| `TITAN_PROBE_CACHE_DISABLE` | Set to `1` to bypass the persistent C-FFI probe cache. |
| `TITAN_PREFIX` | Alternate prefix for the persistent C-FFI probe cache. |
| `TITAN_NODE` | Node 26+ executable used for browser library validation and `titan-browser-run`. |
| `TITAN_RUNTIME_PREBUILT` | In a Titan source checkout, set to `1` to skip rebuilding the checkout runtime archive. |

### Toolchain and terminal variables

| Variable | Effect |
| --- | --- |
| `CC`, `AR`, `RANLIB` | Override the C compiler (`cc` on Unix, `clang.exe` on Windows), archiver, and `ranlib`. |
| `CLANG_FORMAT` | Override the formatter run by `--pretty-print` (default: `clang-format`). |
| `GCOV`, `GCOVR` | Default `gcov` and `gcovr` commands for `--coverage`. |
| `WASI_SDK_PATH` | Active `wasi-sdk` 34 root (`$WASI_SDK_PATH/bin/clang`, `llvm-ar`, `llvm-ranlib`, `wasm-ld`) for `--target browser`. |
| `BINARYEN_ROOT`, `WASM_OPT` | Active Binaryen `version_133` root (`$BINARYEN_ROOT/bin/wasm-opt`) or explicit `wasm-opt` executable for `--target browser`. |
| `MAKEFLAGS` | Inspected on Linux/macOS to share a GNU Make jobserver and switch terminal progress to plain lines. |
| `TERM`, `NO_COLOR`, `COLUMNS` | Control terminal progress layout and ANSI color (`NO_COLOR` disables color without disabling live progress). |
| `LC_ALL`, `LC_CTYPE`, `LANG` | First non-empty UTF-8 locale enables Unicode progress symbols on Linux and macOS. |

### Flag ordering and quoting

For every native phase, `titanc` assembles flags in a fixed order:

1. Build-profile defaults.
2. Shell-tokenized `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`, and `TITAN_EXTRA_LDFLAGS`.
3. Command-line `-I`, `-D`, `--cflag`, `-L`, `-l`, and `--ldflag` switches in written order.
4. Titan and Lua SDK `-I` directories last.

`TITAN_EXTRA_*` and tool commands (`CC`, `AR`, `RANLIB`) use a small
shell-word grammar: whitespace, single or double quotes, and backslash
escapes, with no variable expansion or shell operators. Malformed quoting is
an error. On Windows, quote paths containing spaces with forward slashes, such
as `CC='"C:/native tools/clang.exe"'`.

## Output directories

Pass `-o DIR` (or `--output DIR`) so generated files stay out of your source
tree and different configurations stay isolated:

```sh
titanc -o out/release app.main
titanc -o out/tests --test app.tests
./out/tests/app/tests
```

`DIR` is always a directory; `titanc` creates missing parent directories as
needed. Generated C, objects, and headers mirror the source hierarchy relative
to the selected `--tree` root without writing into the source tree. Target
variants (`app/main.linux.titan`) always produce logically named outputs
(`out/app/main.c`, `out/app/main.o`, `out/app/main`), while diagnostics and
tracebacks report the actual source file.

Paths relative to `out/` on Linux and macOS:

| Source for `app.main` | Generated C and object | Library provider pair | Standalone program |
| --- | --- | --- | --- |
| Flat `app/main.titan` | `app/main.c`, `app/main.o` | `app/main.so`, `app/main.a` | `app/main` |
| Folder `app/main/main.titan` | `app/main/main.c`, `app/main/main.o` | `app/main.so`, `app/main.a` | `app/main__main` |

- The folder program's `__main` suffix avoids colliding with the `app/main/`
  source directory.
- On **Windows**, library builds emit one DLL (`app/main.dll`), and standalone
  or `--test` builds emit a launcher at `out/bin/<logical-module>.exe` plus an
  application DLL at `out/lib/titan/0.6/<module>.dll` (see
  [Windows](windows-build.md)).
- On **browser**, library builds emit only `out/app/main.a`, and programs emit
  `out/app/main.mjs`, `out/app/main.wasm`, `out/app/main.wasm.trace`, and
  `out/app/main.wasm.map` (see [Browser target](browser-target.md)).
- Omitting `-o` writes generated C, objects, and headers beside each source
  file and places final outputs relative to the working directory. However,
  when a build actually selects an installed `.titan` source through the
  implicit SDK source fallback (`<root>/lib/titan/0.6`), `-o`/`--output` is
  required: `titanc` refuses (naming the logical module) rather than writing
  or locking in that implicit fallback root. Builds that do not select an
  installed source keep their existing behavior.

`--output` selects write locations only; it does not add `out` to provider
search paths. To consume a library built under `out`, add `out` to
`TITAN_PATH_0_6` (or install it into the SDK with `titan-install`; see
[Packaging and distributing modules with LuaRocks](modules.md#packaging-and-distributing-modules-with-luarocks)).

On POSIX hosts (Linux and macOS), `\` is an ordinary filename character rather
than a directory separator, and Titan's path handling never reinterprets it as
`/`. Output directories (`-o`/`--output`) and `--c-source` paths containing
literal backslashes work with GCC and Clang, including under `--incremental`.
However, Clang's POSIX Make dependency writer rewrites `\` to `/` in C
dependency reports, so external C headers whose paths contain literal
backslashes on POSIX are unsupported with Clang (GCC does not fold them during
preprocessing). Separately, ELF LLD's `--dependency-file` rewrites `\` to `/`
in linker dependency reports, so ELF LLD final links involving
backslash-containing link paths run uncertified (without link-cache reuse).

### Choosing the executable path (`--exe`)

`--exe PATH` sets the exact destination for a standalone or `--test`
executable, resolved relative to the current working directory (not relative
to `-o`):

```sh
titanc --incremental -o out --exe out/my-app app.main
titanc --incremental -o out --test --exe out/my-tests --test-dir tests
```

On Windows, `.exe` is appended if absent, the launcher is written to `PATH`,
and the application provider DLL stays at `<output>/lib/titan/0.6/<module>.dll`
(named after the logical root module—for example `main.dll` for root `main`—not
the `--exe` basename; it must be on the same volume as `PATH`).

### Compiler-managed state inside `-o`

| Path | Role |
| --- | --- |
| `out/.titan-build.lock` | Exclusive OS lock (`flock` / `LockFileEx`) serializing concurrent `titanc` runs on local filesystems. If `--exe` points outside `out`, that directory is locked too. |
| `out/.titan/` | Compiler caches (file-digest cache and preamble/linker probes). Safe to delete; rebuilt automatically. |
| `out/.native/` | Compiled objects and metadata for `--c-source` files. Use `--print-c-objects` to obtain their paths. |
| `out/.titan-links/<key>/` | Per-target final-link records and synthetic test runners/entrypoints, allowing app and test binaries to share `out/`. |
| `out/.coverage/` | Coverage-instrumented C, objects, `.gcno`/`.gcda` files, and the default `out/.coverage/report/` directory. |
| `out/.titan-target` | Target isolation marker written by `--target browser` (`browser`). Prevents mixing native and browser artifacts in one output root. |

For every module `<stem>`, `titanc` reserves `<stem>.c`, `<stem>.o`,
`<stem>.part1.c`/`.o` through `--c-parts`, `<stem>.priv.h`, `<stem>.ffi.h`,
and `<stem>.titan.h`. Do not place hand-written files at those names; `titanc`
refuses to overwrite authored files occupying reserved paths.

## Module lookup and the Titan path

### Source versus compiled lookup order

Explicit positional command-line roots—for a library, program, `-c`, explicit
`--test`, or `--exe` build—always resolve to source **only** under the authored
`--tree` roots (default `.`), never through the implicit installed source
fallback `<root>/lib/titan/0.6`. If a requested root exists only as installed
source, `titanc` rejects it and directs you to compile from a source checkout
with `--tree`. Explicit source imports (`import "pkg.mod.titan"`) also require
source. Ordinary `import` statements inside a valid authored root resolve in
this order:

| Mode | Search order |
| --- | --- |
| Default | 1. Shared providers (`.so`/`.dll`) on the Titan path -> 2. Static providers (`.a`, Unix executable builds only) on the Titan path -> 3. Source (folder then flat) on authored `--tree` roots, then read-only `<root>/lib/titan/0.6` |
| `--static` *(executables/`-c`, Unix only)* | 1. Static providers (`.a`) -> 2. Source on authored `--tree` roots, then read-only `<root>/lib/titan/0.6`; no shared-provider fallback (rejected on final no-main library outputs) |
| `--source-first` or `--test` | 1. Source on authored `--tree` roots, then read-only `<root>/lib/titan/0.6` -> 2. Compiled providers according to the selected mode |

Authored source roots come from `--tree` (default `.`). Passing `--tree`
replaces the default `.` without disabling the read-only implicit SDK fallback
`<root>/lib/titan/0.6` for ordinary imports. That fallback applies on both
native targets and `--target browser` (where `<root>/lib/titan/0.6` is searched
for `.titan` source only, selecting `.browser.titan` and shared `.titan`
variants normally; native compiled providers there are never eligible for
browser builds). `--test-dir` scans only the specified directory inside an
authored `--tree` root and never scans the installed SDK automatically.
Whenever a build selects an installed source through the fallback—even when a
library build only checks it—`-o`/`--output` is required so generated files land
in the caller's output directory by logical module name without writing or
locking inside the implicit SDK root. In a library build (including plain
non-`main`, non-`--test`, non-`--static` `-c`), an ordinary public `import`
selected from the implicit installed source fallback (including under
`--source-first`) is checked against its public interface and public layouts
and stays external rather than entering the library provider (explicit `.titan`
collaboration across that installed-source library boundary is rejected). Native
library providers carry only their authored `--tree` modules (plus explicit
non-Titan `-X` payloads); browser library archives likewise leave external
installed sources outside the archive while retaining browser's preexisting
separate archive composition for compiled browser dependencies.

When a consumer application or `--test` executable imports prebuilt libraries
whose reached logical members recorded dependencies from installed source,
`titanc` satisfies each module once through ordinary single-owner lookup for
the active target and build mode—with no redundant user `import`—either
compiling authored or installed source once into the application (requiring
`--output` for this lookup only when installed fallback source is selected or
on `--target browser`) or selecting a compatible standalone provider, canonical
common-prefix bundle, or already-carried archive/bundle member without
rebuilding the library. Explicit `.titan` imports remain strictly source-only;
unreached siblings impose no additional logical build demand. Missing owners,
malformed claimed providers, conflicting physical owners, and cross-boundary
cycles are diagnosed at build time, while ABI and used-interface compatibility
are also verified on binding/initialization when a shared provider is replaced
after linking. For the full per-target, upgrade, editor, and bare-Lua rules,
see [Source-only modules](modules.md#source-only-modules).

Within each compiled format, lookup is **path-root first, shallowest prefix to
exact module**. For logical module `a.b.c`, one directory is probed as:

```text
a.so       -> a/b.so       -> a/b/c.so
```

An earlier path root containing `a/b.so` shadows `a/b.so` in later roots even
if the earlier file does not contain `a.b.c`, while an unrelated ancestor file
still allows advancing to `a/b/c.so`. A candidate that claims `a.b.c` but has
corrupt, incomplete, or incompatible metadata is an error rather than a miss.

### The Titan path

A Titan path is a semicolon-separated list of directories (not `?` templates).
Titan checks `TITAN_PATH_0_6`, then `TITAN_PATH`, then the built-in default.
An explicitly empty variable searches nothing. Two tokens have special meaning:

- `;;` inserts the default path at that position (`TITAN_PATH_0_6='out;;'`
  searches `out` first, then the defaults).
- `!` expands once to the directory of the running executable (following
  symlinks).

| Searcher | `!` resolves to | Default path |
| --- | --- | --- |
| `titanc` (compile time) | Directory of the Lua interpreter running `titanc` (or `titanc.exe` on Windows) | `.;<root>/lib/titan/0.6` |
| Standalone programs, Lua hosts, independent `lua.Lua` states (run time) | Directory of the running executable | `!;!/../lib/titan/0.6`, then SDK fallback |

The runtime default deliberately omits `.`: a program's working directory does
not supply compiled providers.

When a runtime search using the default path (or `;;`) misses every directory,
Titan attempts one **SDK fallback** per Lua state:

1. If `TITAN_ROOT` is set and non-empty, search `<TITAN_ROOT>/lib/titan/0.6`.
2. Otherwise run `<TITANC> --print-root` (default `titanc`, invoked directly
   without a shell and without `LUA_INIT`/`LUA_INIT_5_5`) and search
   `<printed root>/lib/titan/0.6`. On Windows, a bare `TITANC` name searches
   `PATH` only, never the current directory.

The fallback lets development executables built into `out/` find the installed
standard library when `titanc` is on `PATH`. Deployed applications should
place providers beside the executable or in `../lib/titan/0.6` (or build with
`--static`) rather than relying on the fallback.

## Shared, static, and multi-module providers

### Provider naming and grouping

When no requested root declares `function main(args: {string}): integer`,
`titanc` builds a library provider named from the **longest common sequence of
complete dotted components** across the requested roots:

| Requested roots | Provider | Outputs (Linux / macOS) |
| --- | --- | --- |
| `geom` | `geom` | `geom.so`, `geom.a` |
| `geom.point` | `geom.point` | `geom/point.so`, `geom/point.a` |
| `geom.shape geom.draw` | `geom` | `geom.so`, `geom.a` |
| `a.b.left a.b.right` | `a.b` | `a/b.so`, `a/b.a` |
| All 26 `titan.*` standard roots | `titan` | `titan.so`, `titan.a` |

Roots with no common component (for example `titanc client server`) fail before code
generation; compile unrelated libraries in separate invocations. Authored
transitive source dependencies from `--tree` are linked into the provider
without changing its name; external installed-source dependencies are checked
without being linked into the library provider.

Grouping modules into one physical provider does not merge them: each logical
module keeps its own exports, private state, initialization guard, nominal
identities, and `require` name. Loading `a.b.left` initializes only `a.b.left`
and its imports, not `a.b.right`.

The bare logical module name `titan` is reserved for the Lua support module
loaded by `require "titan"` (`lib/lua/5.5/titan.so` or `titan.dll`). A
physical provider named `titan` (such as the standard library's `titan.so` and
`titan.a`) is valid and holds `titan.*` modules, never a logical `titan`
module.

### Paired `.so` / `.a` outputs and `--static`

On Linux and macOS, library mode validates and publishes matching `.so` and
`.a` providers atomically—if linking or validation fails, previously published
files stay untouched. Static `.a` providers are self-describing: each module's
primary object embeds its public type interface, so no sidecar file is needed.
On macOS, `titanc` can consume universal `x86_64`/`arm64` `.a` providers and
selects the active compiler's slice.

Build a library or canonical bundle by listing its source roots, for example
`titanc --tree src -o out pkg.left pkg.right`. The pair contains those
modules and their authored source helpers from `--tree`, not any selected
external compiled provider or external installed-source dependency. An external
installed-source dependency is checked against its public interface and left
external for the consuming application to compile once. An external compiled
dependency must have a shared provider to build a native pair; an archive alone
is not sufficient. `--static` is not a library-production mode.

A default application may still use an archive when no shared provider
claims its import, and compiles any source-only dependencies required by
reached members of its selected libraries once into the application (under
`--output` whenever an installed fallback source is selected). To link the
full Titan dependency closure of an executable or test on Linux and macOS, use
`titanc --static -o out app`. An application module compiled from source
(including a source-only dependency materialized for a prebuilt library)
satisfies any reached prebuilt member's import of that module. Otherwise every
reached compiled module, including a prebuilt library's private imports, must
have an archive. A missing archive is a build error, even if its shared
provider exists. Rebuild older archives that lack the import inventory. Dormant
siblings in a multi-module archive are not loaded or extracted, and impose no
source build, just because another member was selected.

Direct imports still require the exact physical owner. A prebuilt library's
external import (including an external source-only dependency compiled by the
application) can instead bind to the executable's linked copy after ABI and
used-declaration checks, without initializing modules early or exposing unused
modules to Lua `require`. Shared consumers of an external owner reuse the first
initialized compatible provider in the state; physical carrying conflicts still
fail. `--static` does not request the system linker's `-static` flag: system
libraries such as libc can remain dynamic.

The closure covers the executable's Titan `import` declarations, not
modules explicitly loaded at runtime. A plugin loaded through Lua
`require` can still load its own shared dependencies in a `--static`
executable.

Native payloads passed with `-X` are carried into both `.so` and `.a`
providers in command-line order (child archives are flattened into the
generated `.a`, and metadata-bearing Titan objects are rejected on `-X`).
Common final-link inputs—Titan's runtime and backtrace archives, `liblua.a`,
`-l` libraries, and `TITAN_EXTRA_LDFLAGS`—are not copied into package archives
and are supplied once at final link. In particular, when Titan is installed in
system-OpenSSL mode, a `--static` executable using `titan.ssl` supplies the
OpenSSL link flags at final link.

### Standalone executables

When exactly one requested source root declares the exact signature
`function main(args: {string}): integer`, `titanc` links a standalone
executable instead of a library provider. Declaring `main` in more than one
requested root is an error.

- `args[1]` through `args[#args]` hold user command-line arguments (the
  program name is excluded).
- The returned integer becomes the process exit status.
- An uncaught error prints the message and unified Titan/Lua traceback to
  stderr and exits non-zero.
- Modules linked from source or `.a` archives are embedded directly; modules
  selected from `.so`/`.dll` providers load dynamically along the runtime
  Titan path.
- Each initialized module registers its loader in `package.preload`, so Lua
  code running inside the program can `require` any initialized embedded
  module without loading another file.
- `--no-uv-bootstrap` runs `main(args)` directly instead of letting `titan.uv`
  wrap program entry.

### Loading compiled libraries from Lua

Lua reaches compiled Titan modules through Titan's package searcher. A plain
Lua host installs it once with `require "titan"`; standalone Titan programs
and `lua.Lua` states already have it installed:

```sh
TITAN_PATH_0_6='out;;' \
  lua -e 'require "titan"; local left = require("a.b.left"); print(left.version())'
```

Never add Titan provider directories (`lib/titan/0.6` or `out`) to
`package.cpath`: Lua's built-in C searchers run before Titan's searcher and
would open provider files without Titan's compatibility checks.

## Running with a stock Lua

On Linux and macOS, compiled Titan modules load in an unmodified stock Lua
5.5.1 interpreter (built with the default numeric configuration). Point
`LUA_CPATH_5_5` at Titan's support module and point `TITAN_PATH_0_6` (or
`TITAN_ROOT`) at the providers:

```sh
export LUA_CPATH_5_5="$ROCKS_TREE/lib/lua/5.5/?.so;;"
export TITAN_PATH_0_6="$ROCKS_TREE/lib/titan/0.6;;"
lua -e 'require "titan"; assert(require("titan.string"))'
```

Titan modules keep all mutable state per Lua state, so one loaded provider can
serve multiple independent Lua states in the same process. Modules remain tied
to Lua 5.5's exact internal layout; see [A stock Lua tree](installation.md#a-stock-lua-tree)
for linking against a stock Lua source tree and
[The Lua DLL and C helpers](windows-build.md#the-lua-dll-and-c-helpers) for
Windows.

## Replacing shared-library dependencies

A compiled consumer can load a newer replacement of a separate `.so` or `.dll`
provider without being rebuilt, provided the replacement keeps the exact
declarations that consumer relies on. Replacing source or `.a` dependencies on
disk has no effect on code already linked into a binary.

Within one Lua state, the first initialized provider for a logical module is
canonical. Later dynamic imports check their assumptions against that
initialized module rather than opening a second copy—so a dynamically loaded
plugin importing a module already embedded in its host uses the host's
instance. Checks run at load time; replacing a file on disk never hot-reloads
a running Lua state.
On Linux, macOS, and Windows, a standalone or `--test` executable can also
supply an application-linked copy (on Windows, from the application's provider
DLL behind the launcher) before a dynamic import opens a separate provider
file. Replacing a file on disk cannot replace that linked copy.

Source-only obligations follow two separate rebuild rules:

- **Editing an installed source-only module itself:** Compatible implementation
  or private-dependency edits require rebuilding only the consuming application;
  prebuilt libraries that depend on that source do not need rebuilding.
- **Changing a compiled library's source-only obligations:** If a compiled
  library is replaced with a build that adds, removes, or changes which
  source-only modules it requires—even with an unchanged public type
  interface—rebuild any compiled intermediate libraries that forward those
  obligations (`titanc --incremental` detects the change automatically).

| Declaration used by consumer | Must stay identical in replacement |
| --- | --- |
| Function | Erased parameter/result types, parameter names, variadic input, flexible return shape. |
| Public `foreign function` | Exact C parameter/result types and parameter names. |
| Module variable | Erased type and `const`/mutable status (declaration order may change). |
| Record | Nominal identity and the complete ordered list of public field names, erased types, and `const` status. |
| Union | Nominal identity and the complete ordered list of public variant names and named payload parts. |
| Interface | Nominal identity and every ordered field and method signature (including parameter names). |
| Concrete method or static function | Signature and parameter names, only if the consumer uses that member (including implicitly via an Interface conversion). |

Key rules for safe replacements:

- **Unused exports and declaration order:** Adding or removing unused exports
  or reordering functions and variables does not break consumers.
- **Generic parameter names:** Type-parameter names (`T` vs `U`) may change
  because checks compare erased runtime signatures; value parameter names
  remain part of the contract for named calls.
- **Private record fields and constructors:** Adding, removing, or changing
  `local` record fields is safe for consumers that only read/write public
  fields or call `Record(...)` / `Record.new(...)`. However, consumers that
  construct the record with a raw `{ ... }` literal, pass one of their own
  functions to the generated constructor inside a module-variable initializer,
  or fuse fresh native C storage into the record require the record to keep all
  fields public and keep the default generated `new`.
- **Private union variants and `case`:** Adding or reordering `local` variants
  preserves public tags and is safe unless the consumer relied on complete
  coverage of the closed union to prove a `case` cannot fall through (for
  example, returning from every `when` arm without an `else`). Adding an
  explicit terminating `else` avoids that dependency.
- **Type aliases:** Removing or retargeting a public alias referenced by a
  consumer fails load-time checks even if the new target has identical fields.

## Incremental and separate compilation

Passing `--incremental` reuses certified module objects, `--c-source` objects,
and final links whenever every observable input still matches. Unchanged
owned modules are restored without re-parsing, typechecking, or re-running the
C compiler; only modules whose inputs changed compile in parallel worker
processes. In a library build with external installed source-only
dependencies, `titanc` may still re-parse and re-check those external sources
in memory on each invocation while owned library objects and the final
provider hit their certificates—no separate persisted source-interface cache
or orphan `.o` file is written for them.

| Invocation | Behavior |
| --- | --- |
| `titanc -o out app.base app.feature` | Compile all owned source modules afresh and link. |
| `titanc -o out --incremental app.base app.feature` | Reuse unchanged source objects (including roots), compile only misses, and reuse or relink the target. |
| `titanc -o out -c app.feature` | Rebuild every owned module in the closure to objects and headers (leaving external installed sources unemitted for non-`main` library roots); skip linking. |
| `titanc -o out -c --incremental app.feature` | Certify and reuse unchanged owned objects (including roots); compile only misses. |
| `titanc -o out -c --incremental --c-source helper.c` | Certify or compile standalone C helper objects without Titan roots. |
| `titanc -o out -c --incremental --print-c-objects --c-source helper.c` | Same as above and print each certified object's absolute path on stdout. |

### What `--incremental` tracks

A cached module object is reused only when all of the following match:

- **Own sources:** flat vs folder layout, selected target variants, folder
  contributor membership, and file contents (touching timestamps without
  changing bytes stays a hit; switching to a byte-identical target variant
  rebuilds because the reported filename changes).
- **Compiler, SDK, and C toolchain:** installed compiler and SDK files,
  generated-C preamble headers, native compiler identity (`CC`), build profile,
  `-I`/`-D`/`--cflag`, `TITAN_EXTRA_CPPFLAGS`/`TITAN_EXTRA_CFLAGS`, `#line`
  policy, `--pretty-print`, `--c-parts`, `--test` mode, and `--coverage`.
- **Transitive C headers:** content and resolved paths of every header reached
  by `foreign import`, plus search-path shadowing candidates.
- **Dependencies:** semantic public interface (and private interface for
  explicit `.titan` source imports), nominal layouts, resolved provider
  bindings of direct imports and contextually reached nominal owners, and
  external source-only obligations folded into a compiled module.
  Implementation-only edits inside a producer module—including compatible
  implementation edits inside an external installed source-only dependency—do
  not recompile its importers, whereas a change in a dependency's external
  source-only obligations invalidates compiled intermediates that forward them.
- **Final links (`out/.titan-links/`):** linked objects, `--c-source` objects,
  `-X` payloads, resolved native libraries (`-L`/`-l`/`--ldflag`/
  `TITAN_EXTRA_LDFLAGS`), discovered test cases, and final outputs on disk.
  Pure link-flag changes relink existing module objects without recompiling
  Titan sources.

With `-o`, moving a checkout whose source paths remain relative (together with
its output tree and an identical SDK) preserves reuse when the compiler can
rebind owned preprocessor directives and verify that the preprocessed C is
unchanged on first use after the move. Generated line-control operands (`#line`
and `TITAN_GENERATED_C_FILE`) are decoded and rebound accurately for
representable owned paths containing characters that require C escapes (such as
quotes, backslashes, `?`, or `$`), while unowned paths and ordinary C strings
stay untouched; builds whose generated code observes concrete source locations
or whose required `#include` header names cannot represent a directory
character (such as a quote in a header name) still miss or fail as usual.
Source-adjacent builds without `-o` miss conservatively when moved.

Pass `-v` to inspect why a module or link rebuilt:

```text
Titan object hit app.model: out/app/model.o
Titan object miss app.view: import-interface app.model (public)
Titan native hit src/helper.c
Titan link miss out/app: link inputs changed
```

Common miss reasons are `source-set` / `source-content` (edited or added
sources), `configuration` (`compiler`, `preamble`, `toolchain`, or `options`),
`c-input` (changed or newly shadowed C header), `import-interface` /
`owner-interface` (dependency interface changed), `import-binding` (provider
changed), `codegen-options` (`--c-parts`, `--test`, or `--coverage`), and
link misses (`link inputs changed`, `native libraries changed`, or an opaque
linker flag such as `@file` or `-Xlinker` that prevents caching).

On POSIX hosts, `--incremental` preserves exact certification for
`-o`/`--output` directories and `--c-source` inputs whose paths contain literal
backslashes with GCC and Clang. With Clang, external C headers whose paths
contain literal backslashes are unsupported; if preamble dependency reporting
becomes uncertain, Titan compilation still succeeds uncertified (rebuilding
Titan source objects and final links without reuse). With ELF LLD, final links
whose known link paths contain literal backslashes—or whose linker dependency
report cannot be trusted—succeed without caching a link record.

### Single-invocation Make integration

Because `titanc --incremental` tracks the full import graph, C headers, flags,
and `--c-source` files itself, a `Makefile` does not need per-module `.o`
rules or header lists. Mark `titanc` recipes `.PHONY` and prefix them with `+`
so GNU Make shares its jobserver:

```make
TITANC ?= titanc
TITAN_JOBS ?= 4
TITAN_FLAGS = --static --incremental --output build -j $(TITAN_JOBS) \
  -I include --c-source src/native_helper.c

.PHONY: all app tests test clean
all: app

app:
	+$(TITANC) $(TITAN_FLAGS) --exe build/app app.main

tests:
	+$(TITANC) $(TITAN_FLAGS) --test --exe build/app-tests --test-dir tests

test: app tests
	./build/app-tests

clean:
	rm -rf build
```

Application and `--test` builds can share `build/`: unchanged production
modules without `test_` functions compile once, while each binary keeps its
own link record under `build/.titan-links/`. Under `make -j2 test`,
`build/.titan-build.lock` serializes the two `titanc` invocations cleanly. Keep
`TITANC` a single executable name or path (never a command with arguments)
because GNU Make exports it to recipes and Titan's runtime SDK fallback may
invoke it directly.

If you need separate compile-only and link steps (for example to precompile
modules or inspect certified `--c-source` object paths), pair `-c --incremental`
with a final `--incremental` link passing link-only flags (`--exe`, `-L`, `-l`,
`--ldflag`, `-X`, `--no-uv-bootstrap`):

```sh
titanc -o out --static -c --incremental app.helper
titanc -o out --static -c --incremental app.main
titanc -o out --static --incremental --exe out/bin/app app.main
```

Compile-only builds with a `main` root, `--test`, or `--static` use prospective
executable composition (compiling required source dependencies as for the
corresponding executable—under `--output` when an installed fallback is
selected—and with `-c --static` checking the complete import closure even for a
helper without `main`). Plain `-c` on non-`main` roots without `--test` or
`--static` uses prospective library composition: it emits only owned library
objects, leaves external installed fallback sources unemitted, and enforces the
library explicit-`.titan` boundary, so a subsequent `--incremental` library
link reuses those objects directly. None of these `-c` modes publishes a final
provider or executable; pass the same provider-selection and compile options in
both steps, including `--static`, `--test`, and `--coverage` when applicable.

## Build profiles, parallelism, and build output

### Build profiles

`TITAN_BUILD_PROFILE` selects one of two build profiles:

| Profile | Optimization & LTO | Debug info | Typical use |
| --- | --- | --- | --- |
| `production` (default) | `-O3` (plus `-flto=auto -ffat-lto-objects` on Linux) | GCC: `-g1`; Clang: `-gline-tables-only -fdebug-info-for-profiling`; others: `-g` | Everyday builds and releases (keeps full Titan backtraces with small binaries) |
| `validation` | `-O0 -fno-lto` | Full `-g` with variable tracking | Debugging, sanitizers, and compiler/stdlib test runs |

Use separate SDK prefixes when maintaining both profiles side by side. For an
interactive debugger build against a `production` installation without
reinstalling Titan, override both compile and link flags:

```sh
TITAN_EXTRA_CFLAGS='-Og -g -fno-lto' \
TITAN_EXTRA_LDFLAGS='-Og -g -fno-lto' \
  titanc --incremental -o out app.main
```

On `--target browser`, `TITAN_BUILD_PROFILE` selects optimized `-O3` browser
images (`production`) versus frame-preserving trace images (`validation`); see
[Browser build profiles](browser-target.md#build-profiles).

### Parallelism and split modules

- **`-j N` / `--jobs N` / `TITAN_JOBS`** (default `4`) caps concurrent
  module-frontend workers and native compiler jobs within one `titanc`
  invocation. Generated code and diagnostic order never depend on `N`. On
  Linux and macOS, values above `1` require `mkfifo`.
- **GNU Make jobserver:** In a `+` recipe under GNU Make 4.4+ (FIFO jobserver)
  or Linux (pipe jobserver), `titanc` borrows slots from Make's `-j` pool
  while respecting its own `--jobs` cap. Under `make -j1`, `titanc` runs
  serially. On macOS, older GNU Make (including stock 3.81) cannot share pipe
  jobservers; `titanc` warns once and applies its local `--jobs` cap.
- **`--c-parts N` / `TITAN_C_PARTS`** (default `4` on Linux, `1` elsewhere)
  splits modules whose generated C exceeds 2 MiB into up to `N` parallel C
  translation units (`<stem>.c`, `<stem>.part1.c`, ..., plus `<stem>.priv.h`).
  Only the primary `<stem>.o` carries Titan metadata, and providers/programs
  link all parts automatically. Pass `--c-parts 1` to disable splitting.

### Build output

`titanc` writes progress and diagnostics to stderr, keeping stdout clean for
`--print-root`, `--print-ast`, and `--print-c-objects`.

| Mode | Flag | Stderr output |
| --- | --- | --- |
| Quiet | `-q` / `--quiet` | Diagnostics and native tool output only (recommended when scripts parse stderr). |
| Progress | *(default)* | Quiet output plus module phases (`parsing`, `checking`, `generating C`, `compiling C`, `linking`) and final summary. |
| Verbose | `-v` / `--verbose` | Native tool commands, `--incremental` hit/miss decisions, and plain progress lines. |

When stderr is an interactive terminal (`TERM` is not `dumb`, `-v` is absent,
and `MAKEFLAGS` advertises no jobserver), `titanc` draws a live updating
status region and erases it on completion; otherwise it prints one plain line
per event. Set `NO_COLOR=1` to disable ANSI colors while keeping live updates.

## Native source coverage

Pass `--coverage` with `--test` (or a standalone executable) to measure
executable-line coverage of original `.titan` sources, then run the binary:

```sh
export CC=gcc-14 GCOV=gcov-14
titanc -o out --test --coverage calc_tests
./out/calc_tests
```

A passing run prints an executable-line summary and writes annotated output to
`out/.coverage/report/coverage.gcov` without needing Python or `gcovr`.

### Source selection and artifacts

- By default, `--coverage` instruments every authored source-imported module in
  the build graph that defines no top-level `test_*` function. Modules resolved
  from source through the implicit SDK fallback (`<root>/lib/titan/0.6`),
  prebuilt providers, and modules containing any `test_` function are excluded.
  To include an untested authored module in the denominator, import it from a
  test root.
- Repeatable `--coverage-module GLOB` replaces automatic selection with a
  union of logical-module globs (`*` matches zero or more characters, `?`
  matches one, including dots; quote globs from the shell). A matching glob
  opts an installed fallback source into instrumentation, while selected
  compiled providers and `test_`-bearing modules remain excluded, and an empty
  match is an error.
- Coverage C, objects, and `.gcno`/`.gcda` files live in `.coverage/`
  subdirectories (`out/app/.coverage/calc.o`), completely separate from normal
  objects so normal and coverage builds never contaminate each other.
- `--incremental` certifies coverage objects and final links. Each execution
  of the coverage binary clears old `.gcda` counters on startup, runs tests,
  and dumps fresh counters after a passing run. Because runs share counter
  files, do not run two coverage sessions against the same `-o` directory at
  once, and keep the build artifacts in place while running tests.

### Backends and richer reports

- **`gcc-gcov` (Unix default):** requires GCC 14+ and the matching `gcov`
  (`CC=gcc-14 GCOV=gcov-14` or `--coverage-gcov`).
- **`llvm-gcov` (Windows default):** uses Clang's gcov-compatible format with
  `llvm-cov gcov`:

```sh
CC=clang titanc -o out --test --coverage --coverage-backend llvm-gcov \
  --coverage-gcov 'llvm-cov gcov' calc_tests
./out/calc_tests
```

- **HTML, LCOV, and Cobertura:** install `gcovr` 8.4 and pass repeatable
  `--coverage-format` (`html`, `lcov`, `cobertura`), optionally with
  `--coverage-output DIR`, `--coverage-root DIR`, and `--coverage-gcovr CMD`.
  Reports write `coverage.html`, `coverage.info`, and `coverage.xml` filtered
  to selected `.titan` lines.

For compiler internals, record formats, and build-coordinator architecture,
see [Driver and toolchain](../implementation/driver.md),
[Incremental compilation](../implementation/incremental-compilation.md),
[Binary compatibility](../implementation/binary-compatibility.md), and
[Native coverage](../implementation/native-coverage.md).
