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
| `<module>...` | Dotted logical module names to compile as build roots. |
| `-o`, `--output DIR` | Root directory for all generated files, created if missing. Required for `--target browser`. |
| `--exe PATH` | Exact destination for a standalone or `--test` executable, relative to the current directory. |
| `-t`, `--tree PATH` | Semicolon-separated source root directories (default: `.`). |
| `-T`, `--target TGT` | Compilation target: host OS (`linux`, `darwin`, `windows`) or `browser` (default: `TITAN_TARGET` or host OS). |
| `--static` | Require archives for compiled dependencies of a Linux/macOS executable or test. Also valid for their compile-only objects. |
| `--source-first` | Prefer available `.titan` source dependencies over compiled providers, with compiled fallback on miss. |
| `--incremental` | Certify and reuse unchanged module objects, `--c-source` objects, and final links. |
| `-c`, `--compile-only` | Generate objects and headers only without linking. Rebuilds all sources unless combined with `--incremental`. |
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

### Incompatible option combinations

- `-q` and `-v` cannot be combined.
- `-c` rejects link-only options: `--exe`, `-l`, `-L`, `--ldflag`, `-X`, and `--no-uv-bootstrap`.
- `--exe` and `--no-uv-bootstrap` are valid only for standalone or `--test` executables.
- `--print-root` cannot be combined with module names or `--print-c-objects`.
- `--print-ast` cannot be combined with `--incremental` or `--print-c-objects`.
- `--print-c-objects` requires `-c` and at least one `--c-source`.
- `--test-dir` requires `--test`; `--test-exclude` requires both `--test` and `--test-dir`.
- `--test` reserves `titan.test` and rejects it as an explicit root.

### Selecting the target (`-T` / `--target` and `TITAN_TARGET`)

`--target` overrides `TITAN_TARGET`, including an explicit empty `--target ''`
that selects the host. Native compilation targets the host OS only; Linux,
macOS, and Windows hosts also support `browser` (see
[WebAssembly and the browser target](browser-target.md)).

| `-T` / `--target` or `TITAN_TARGET` | Effect |
| --- | --- |
| absent or empty | Select the host OS (`linux`, `darwin`, `windows`, or unlabeled native host). |
| host OS label | Same as absent. |
| `browser` | Build WebAssembly output with Emscripten. Requires `--output`. |
| another OS label | Error: native cross-compilation is not supported. |
| `native` | Error: `native` is a source-variant label (see [Modules](modules.md)), not a build target. |
| any other value | Error: unknown target. |

Target validation runs before source lookup. Only `titanc` reads
`TITAN_TARGET`; the language server selects targets from workspace
configuration.

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
| `EMSDK` | Active Emscripten SDK root (`$EMSDK/upstream/emscripten/emcc`) for `--target browser`. |
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
  file and places final outputs relative to the working directory.

`--output` selects write locations only; it does not add `out` to provider
search paths. To consume a library built under `out`, add `out` to
`TITAN_PATH_0_6`.

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
(which must be on the same volume as `PATH`).

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

Explicit command-line roots and explicit source imports (`import "pkg.mod.titan"`)
always resolve to source. Ordinary `import` statements resolve in this order:

| Mode | Search order |
| --- | --- |
| Default | 1. Shared providers (`.so`/`.dll`) on the Titan path -> 2. Static providers (`.a`, Unix executable builds only) on the Titan path -> 3. Source (folder then flat) on `--tree` |
| `--static` | 1. Static providers (`.a`) -> 2. Source on `--tree`; no shared-provider fallback |
| `--source-first` or `--test` | 1. Source on `--tree` -> 2. Compiled providers according to the selected mode |

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
generation; compile unrelated libraries in separate invocations. Transitive
source dependencies are linked into the provider without changing its name.

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
modules and their source-backed helpers, not any selected external compiled
provider. An external compiled dependency must have a shared provider to
build the pair; an archive alone is not sufficient. `--static` is not a
library-production mode.

A default application may still use an archive when no shared provider
claims its import. To link the full Titan dependency closure of an
executable or test on Linux and macOS, use `titanc --static -o out app`.
An application module already compiled from source can satisfy an import.
Otherwise every reached compiled module, including a prebuilt library's
private imports, must have an archive. A missing archive is a build
error, even if its shared provider exists. Rebuild older archives that
lack the import inventory. Dormant siblings in a multi-module archive are
not loaded or extracted just because another member was selected.

Direct imports still require the exact physical owner. A prebuilt library's
external import can instead bind to the executable's linked copy after ABI
and used-declaration checks, without initializing modules early or exposing
unused modules to Lua `require`. Shared consumers of an external owner reuse
the first initialized compatible provider in the state; physical carrying
conflicts still fail. `--static` does not request the system linker's `-static`
flag: system libraries such as libc can remain dynamic.

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
On Linux and macOS, a standalone executable can also supply a linked copy
before a dynamic import opens a provider file. Replacing that file cannot
replace the linked copy.

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
modules are restored without re-parsing, typechecking, or re-running the C
compiler; only modules whose inputs changed compile in parallel worker
processes.

| Invocation | Behavior |
| --- | --- |
| `titanc -o out app.base app.feature` | Compile all selected source modules afresh and link. |
| `titanc -o out --incremental app.base app.feature` | Reuse unchanged source objects (including roots), compile only misses, and reuse or relink the target. |
| `titanc -o out -c app.feature` | Rebuild every module in the closure to objects and headers; skip linking. |
| `titanc -o out -c --incremental app.feature` | Certify and reuse unchanged objects (including roots); compile only misses. |
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
  explicit `.titan` source imports), nominal layouts, and resolved provider
  bindings of direct imports and contextually reached nominal owners.
  Implementation-only edits inside a producer module do not recompile its
  importers.
- **Final links (`out/.titan-links/`):** linked objects, `--c-source` objects,
  `-X` payloads, resolved native libraries (`-L`/`-l`/`--ldflag`/
  `TITAN_EXTRA_LDFLAGS`), discovered test cases, and final outputs on disk.
  Pure link-flag changes relink existing module objects without recompiling
  Titan sources.

With `-o`, moving a checkout whose source paths remain relative (together with
its output tree and an identical SDK) preserves reuse; `titanc` verifies the
preprocessed C once on first use after the move. Source-adjacent builds
without `-o` miss conservatively when moved.

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

Compile-only builds of a root with `main`, or of `--test` roots, use the same
provider composition rules as the executable build. They write only objects
and headers: the launcher and executable are generated at the final link.
Pass the same provider-selection and compile options in both steps, including
`--test` and `--coverage` when applicable.

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

- By default, `--coverage` instruments every source-imported module in the
  build graph that defines no top-level `test_*` function. Prebuilt providers
  and modules containing any `test_` function are excluded. To include an
  untested module in the denominator, import it from a test root.
- Repeatable `--coverage-module GLOB` replaces automatic selection with a
  union of logical-module globs (`*` matches zero or more characters, `?`
  matches one, including dots; quote globs from the shell). Prebuilt and
  `test_`-bearing modules remain excluded, and an empty match is an error.
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
