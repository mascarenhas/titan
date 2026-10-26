# Incremental and separate compilation

With `--incremental`, `titanc` certifies generated objects, compiler-managed C
inputs, and final link outputs by semantic and content digests, reusing each
artifact when all of its inputs still match. A single `titanc` invocation
discovers the requested source import closure, certifies ready modules in
dependency order, restores hits in-process without parsing or typechecking
their sources, and runs short-lived worker processes only for modules that
miss. Without `--incremental`, `titanc` loads, checks, compiles, and links
selected source modules afresh.

For compiler data structures, certificate canonicalization, worker RPC, and
record layouts, see
[Incremental compilation](../implementation/incremental-compilation.md) and
[Driver and toolchain](../implementation/driver.md).

## Options and outputs

| Invocation | Effect |
| --- | --- |
| `titanc project.base project.feature` | Compile selected source modules and publish the usual provider pair and Lua loaders, or an executable when one root has `main`. |
| `titanc --incremental project.base project.feature` | Certify and reuse eligible source objects, including requested roots, compile only misses across the module graph, and reuse or relink the final target. |
| `titanc -c project.feature` | Rebuild every source module in the requested closure to objects and generated headers; produce no provider, Lua loader, or executable. |
| `titanc -c --incremental project.feature` | Certify and reuse eligible source objects, including requested roots, and compile only misses to objects and generated headers. |
| `titanc -c --incremental --c-source helper.c` | Certify or compile standalone native C source nodes without requiring Titan module roots. |

`--compile-only` is the long spelling of `-c`. Plain `-c` without
`--incremental` forces every module in the requested source closure (and any
`--c-source` input) to rebuild. Combining `-c --incremental` certifies explicit
command-line roots by the same rules as source dependencies: an unchanged root
is a certified hit and runs no native compiler command.

Whether linking or running with `-c`, one `titanc` invocation plans the
complete source closure from the requested roots. Running module-frontend
workers and native compiler commands (generated-C translation-unit parts and
batched C validation probes) share the invocation's `-j` / `--jobs` (or
`TITAN_JOBS`) slot budget and any supported parent GNU Make jobserver pool
([Compiler jobs and GNU Make](build-profiles.md#compiler-jobs-and-gnu-make)).
Unrelated roots and multiple roots defining `main` can be compiled together
with `-c`; common provider naming and executable selection happen when linking.

Pass `-o out` or `--output out` so generated C, objects, headers, native C
nodes (`out/.native/`), final-link certificates (`out/.titan-links/`), and the
output-tree lock (`out/.titan-build.lock`) stay together in the
[output tree](output-directory.md). Without `--output`, module objects and
generated headers stay beside each flat source or folder main, including when
`--tree` points elsewhere, and the first configured source root hosts the build
lock and link/native metadata directories. A folder module's objects belong to
the entire module, never to one contributor: one object, or one object per part
when the module is [split](build-profiles.md#split-modules).

Use `--source-first` when source dependencies should take precedence over
installed `.so`, `.a`, or `.dll` providers. This option still allows compiled
fallback on an ordinary import's source miss. It does not grant access to
private declarations: only a direct `import "project.base.titan"` requests the
source collaboration view.

`-c` rejects `--exe`, `-l`, `-L`, `--ldflag`, `-X`, and `--no-uv-bootstrap`
because those options apply only to linking. `--static` remains a compiled
dependency preference (unsupported on Windows). `--incremental` cannot be
combined with `--print-ast`, which requires freshly checked ASTs in the
coordinator process. `--test` supports both incremental whole-graph linking and
`-c` compile-only object compilation, including automatic root discovery with
`--test-dir` and `--test-exclude`
([Testing Titan code](standard-library-test.md#discovery-and-compilation)).

## What object reuse promises

Each compiled primary module object (`<stem>.o`) embeds a `.titan.source`
record whose envelope carries `abi = version.TITAN_ABI_VERSION` (`"2"`),
`schema = version.OBJECT_RECORD_SCHEMA` (`"1"`), and
`digest = version.CERTIFICATE_DIGEST` (`"sha256"`), canonicalized under
`version.CERTIFICATE_CANONICALIZATION` (`"titan-certificate-v1"`). Generated-code
ABI (`TITAN_ABI_VERSION`), persisted cache and record schemas
(`OBJECT_RECORD_SCHEMA`, `TITAN_LINK_RECORD_SCHEMA = "1"`,
`TITAN_NATIVE_RECORD_SCHEMA = "1"`, `C_HEADER_CACHE_VERSION = 8`,
`PROJECT_CACHE_VERSION = 6`, `SOURCE_INTERFACE_FORMAT =
"titan-source-interface-v2"`), and `driver.LANGUAGE_SERVER_API_VERSION` (`1`)
are separate contracts defined in `titan-compiler/version.lua` and
`titan-compiler/driver.lua`. Older or incompatible record schemas miss cleanly
and recompile from source without an ABI bump or migration layer.

For each source module in the planned closure, `--incremental` certifies the
following inputs before accepting `<stem>.o`:

* **Own sources and folder membership.** The certificate records whether the
  module resolved as `flat` or `folder`, the exact ordered list of constituent
  `.titan` paths (canonical main first, then immediate contributors in bytewise
  order), and the SHA-256 content digest of each file. Adding or removing a
  folder contributor, switching between flat and folder layout, or editing a
  file with a preserved timestamp misses; touching a timestamp without changing
  bytes remains a hit. Explicit roots and direct `.titan` imports still require
  actual source files on disk.
* **Compiler and native configuration.** The coordinator computes one
  invocation-wide configuration digest with four components:
  * `compiler`: the SHA-256 content inventory of all `.lua` files in
    `titan-compiler/`, `titan-compiler/checker/`, `titan-compiler/coder/`, and
    `c-parser/` from the loaded compiler root, plus the executing `titanc`
    frontend script (not a LuaRocks wrapper script; API callers record `api`).
  * `preamble`: the native preprocessor output (`-E -dD -P -MD -MF`) and
    transitive header SHA-256 content digests for the fixed generated-C include
    preamble (`titan.h`, `titan/ffi.h`, Lua headers, and C library headers)
    probed through `<output>/.titan/preamble.c`. This covers active macros,
    expanded declarations, forced `-include` headers, `-isystem` shadowing, and
    `__has_include` presence queries even in modules without `foreign import`.
  * `toolchain`: the target/profile identity, preprocessor self-description and
    `-E -v` banner, and the physical executable identity (resolved realpath,
    size, device/inode/mode where available, and modification/change timestamps)
    of the C compiler driver, any explicit `ccache`/`sccache`/`distcc` target
    compiler, and named compiler stages (`cc1` and `as` for GCC; `as` for Clang
    with `-fno-integrated-as`).
  * `options`: the effective generated-C compile argv (including profile
    defaults, `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`, and CLI `-I`, `-D`,
    and `--cflag` arguments), build profile, `#line` directive policy,
    `--pretty-print`, extra FFI include directories, and the selected Titan SDK
    root.
* **Module code-generation options.** Each record certifies its output stem and
  `codegen` policy: `c_parts`, `split_threshold`, `test_flags` (whether the
  module owns discovered `test_` functions in `--test` mode and therefore
  receives `-fno-optimize-sibling-calls`), and `coverage` (`enabled` and
  `backend`).
* **Split parts, companions, and coverage notes.** A
  [split module](build-profiles.md#split-modules) is reused as a whole or
  rebuilt from source. Only the primary `<stem>.o` carries Titan metadata,
  including the authoritative `parts` inventory (`<stem>.c`,
  `<stem>.part1.c`/`.part1.o`, and `<stem>.priv.h`); no `.parts` sidecar file is
  written or consulted. Every recorded generated `.c` part, `.priv.h` header,
  and sidecar `.part<k>.o` (plus `.gcno` notes when coverage is enabled for the
  module) must exist as a regular file, and sidecar objects must be plain
  metadata-free native objects whose target fingerprint matches the primary
  object. The metadata reader supports ELF, Mach-O, and ordinary Windows COFF
  objects (PE images, COFF import objects, and BigObj are not reusable source
  objects). Missing generated `.ffi.h` and `.titan.h` headers are restored from
  a certified object without recompiling the module.
* **Transitive C header closure.** Before restoring any declarations from a
  cached object, `titanc` revalidates its `c_header_dependencies` and generated
  `.ffi.h` search inputs across a shared per-invocation memo:
  * Readable files use content-only identity
    (`version.C_HEADER_FILE_PROTOCOL = "c-header-file-v3"` with SHA-256 hex),
    so republishing identical SDK or library headers with new timestamps,
    inodes, copies, hardlinks, or symlinks at the same realpath is a hit.
  * Every real (non-generated) header whose declarations reach parsed output
    also records a declaring-origin input
    (`version.C_HEADER_ORIGIN_PROTOCOL = "c-header-origin-v1"` with resolved
    `realpath`), certifying the nominal C declaration scope. Retargeting a
    symlink or replacing it with a hardlink to a different realpath changes the
    origin and triggers a clean miss before declaration restore, even when the
    file bytes are identical.
  * Search candidates record existence (`lstat`), followed kind (`stat`), and
    effective readability
    (`version.C_HEADER_SEARCH_PROTOCOL = "c-header-search-v2"`), catching newly
    created shadowing headers in earlier `-I` or quoted-include directories and
    permission changes.
  * Physical file observations (`size`, `device`, `inode`, `mtime`, `ctime`,
    and explicit `"ns"` vs `"coarse"` precision) authorize skipping a file read
    only when the I/O strategy declares `"ns"` precision and every field
    matches; the CLI's synchronous I/O strategy reports `"coarse"` precision
    and always hashes header bytes with before/after read-race guards.
* **Direct imports, contextual nominal owners, and native bindings.** Each
  direct import records its required view (`public` for ordinary imports, or
  `source` under `version.SOURCE_INTERFACE_FORMAT =
  "titan-source-interface-v2"` for `import "name.titan"`) and the dependency's
  semantic interface digest. For source modules, the `public` digest covers
  serialized semantic public types, exact generated nominal layout bytes, and
  any copied `.titan.h` foreign helper bodies; the `source` digest adds the
  serialized source-private manifest. For compiled providers (`.so`, `.a`,
  `.dll`), each logical module inside a combined provider is fingerprinted
  individually from its own `_types` and `_layouts`, not from the whole
  provider file's bytes or timestamp. An implementation-only edit in a producer
  module (or an edit to an unrelated module in `titan.so`/`titan.a`) leaves its
  interface digest unchanged, so importing consumers hit without recompiling.
  Contextually reached nominal owners—modules not directly imported whose
  records, unions, or Interfaces flow through another dependency's
  signatures—are certified by their `public` interface digests. Every direct
  import and contextual owner also certifies its resolved native access binding
  (`direct`, `handle`, or `global`) and selected provider filename.
  `--source-first`, `--static`, and `--test` do not globally invalidate
  objects: unchanged production modules without `test_` functions are shared
  between application and `--test` builds when their resolved bindings and
  compile flags match.

### Native `--c-source` nodes and final-link certification

Authored or generated C files passed with repeatable `--c-source FILE` are
compiled with the invocation's effective native compile flags and toolchain
identity (excluding Titan-only test-owner and coverage flags) into
`<output>/.native/<hash>.o` alongside `<hash>.record`
(`version.TITAN_NATIVE_RECORD_SCHEMA = "1"`). On each invocation, `titanc`
preprocesses each C file (`-E -MD -MF`) and hashes the authored source,
preprocessed output, transitive header contents, compile argv, and toolchain
identity. When `--incremental` is active and both the input digest and current
`.o` bytes match the sidecar record, `titanc` reuses the object without running
native `-c`. Resulting objects are linked in `--c-source` command-line order
before `-X` payloads.

For executable, test, and library builds (without `-c` or `--print-ast`),
`titanc` maintains a final-link certificate under
`<output>/.titan-links/<key>/record`
(`version.TITAN_LINK_RECORD_SCHEMA = "1"`), where `<key>` hashes the sorted
canonical paths of the target's final output set. Synthetic entrypoint and test
runner sources are isolated per target under
`<output>/.titan-links/<key>/synthetic/`. The link check runs before test
runner rendering, entrypoint generation, static-archive validation probes, and
native linking. It certifies:

* the link recipe: ordered requested roots, entry module and
  `--no-uv-bootstrap`, effective link argv (`-L`, `-l`, `--ldflag`,
  `TITAN_EXTRA_LDFLAGS`), compiler/archiver/ranlib/resource-compiler
  identities, discovered test cases, compiler template digest, coverage runtime
  inventory, Windows launcher manifest and relative provider path, Darwin
  `.dSYM` policy, native bindings, and target/deployment environment;
* the actual SHA-256 content digests of all linked module `.o` parts,
  `--c-source` objects, `-X` payloads, selected dynamic providers, static
  archives, and runtime inputs;
* the complete immutable owned output set on disk (executables, `.so`/`.a`
  pairs, Windows `.exe`/`.dll` pairs, generated Lua shims, and Darwin `.dSYM`
  bundles), checking file/directory kind, non-symlink status, content digests,
  and executable permission bits on Unix (mutable runtime `.gcda` counter files
  and coverage reports are not link outputs); and
* the resolved native link libraries (via `-Wl,--dependency-file` on GNU/LLD,
  `-Wl,-dependency_info` on Darwin ld64, or compiler `-print-file-name`
  resolution where linker dependency output is unavailable).

When the link certificate hits, `titanc` restores any missing public `.ffi.h`
or `.titan.h` headers and exits without generating synthetic C or invoking the
linker. Pure link changes (`-L`, `-l`, `--ldflag`, `-X`, `--exe`) or
implementation-only edits inside a dynamic provider miss only the final link and
relink existing module objects without recompiling Titan modules.

### Verbose hit and miss diagnostics

Passing `-v` or `--verbose` writes per-module, per-C-source, and per-link
decisions to standard error (module decisions are buffered and flushed in
deterministic plan order):

```text
Titan object hit <module>: <primary-object-path>
Titan object miss <module>: <code>[ <detail>]
Titan object uncertified <module>: <error>
Titan native hit <c-source-path>
Titan native miss <c-source-path>
Titan link hit <target-path>
Titan link miss <target-path>: <reason>
titanc: waiting for build lock '<lock-path>'
```

| Object miss code (`<code>[ <detail>]`) | Meaning |
| --- | --- |
| `no-object` | Primary `<stem>.o` is missing or is not a regular file. |
| `record-unreadable [<detail>]` | Object file or its `.titan.source` metadata section cannot be read or decoded. |
| `record-schema [<detail>]` | ABI mismatch, older or incompatible `OBJECT_RECORD_SCHEMA` or `CERTIFICATE_DIGEST`, module-name mismatch, or missing/invalid certificate fields. |
| `configuration compiler\|preamble\|toolchain\|options` | Loaded compiler/parser/frontend Lua inventory, generated-C preamble header closure, native toolchain identity, or effective compile options changed. |
| `source-set added\|removed <path>` | Flat-versus-folder layout or folder contributor membership changed. |
| `source-content <path>` | SHA-256 content of the main `.titan` source or a contributor changed, or could not be read. |
| `output-moved` | Output stem differs from the stem recorded in the certificate. |
| `codegen-options c_parts\|split_threshold\|test_flags\|coverage` | Per-module code-generation policy changed. |
| `parts [<detail>]` | A recorded generated `.c` part, `.priv.h` header, or sidecar `.part<k>.o` is missing, not a regular file, carries unexpected metadata, or mismatches the primary target fingerprint. |
| `coverage-artifacts <path>` | A required `.c` source or `.gcno` note file for a coverage-instrumented module is missing or not a regular file. |
| `c-input <path>: content\|provenance\|missing\|unreadable\|candidate\|changed-during-read` | A transitive C header or include-search candidate changed content, declaring realpath origin, existence/kind, or readability, or changed while being read. |
| `import-interface <module> (public\|source)` | A direct dependency's semantic public interface, nominal layout, copied `.titan.h` helper body, or (for `.titan` imports) source-private manifest changed. |
| `owner-interface <module>` | A contextually reached nominal owner's public interface or layout changed. |
| `import-binding <module>: <before> -> <after>` | A direct dependency's native binding (`direct`, `handle`, or `global`) or selected provider path changed. |
| `owner-binding <module>: <before> -> <after>` | A contextual nominal owner's native binding changed. |
| `dependency-unavailable <names>` / `dependency-rebuilt <names>` | A dependency could not supply a certified interface digest (or was freshly checked in an in-process single-pass loader). |

Common `Titan link miss <target>: <reason>` reasons include `missing record`
(or a record read error on a cold link), `link record schema`,
`link inputs changed`, `link output set changed`, `link outputs changed` (or a
specific missing/nonregular/non-executable output error),
`native libraries changed`, or an uncacheable native flag diagnostic (`opaque
linker input mechanism: <flag>`, `opaque native C input mechanism`,
`linker scripts require dependency output`, or
`cannot resolve native library: <name>`).

### Certification boundaries and limitations

* **External build tools still own non-Titan inputs and actions.** Building
  third-party native libraries (such as libuv, OpenSSL, SQLite, or llhttp),
  running custom code generators (whose generated `.c` or `.titan` outputs can
  then be passed to `titanc`), preparing SDKs and environment variables,
  assembling platform distribution bundles, and running test binaries or
  external coverage aggregators remain build-tool responsibilities.
* **Always invoke `titanc`.** Certification runs only when `titanc` runs. A
  build script that skips invoking `titanc` based on incomplete timestamp lists
  can miss header, flag, or interface changes.
* **Linker-reported library inputs do not rewalk earlier `-L` directories.**
  Link certification hashes the library files reported by the linker (or
  resolved through `-L` and `$(CC) -print-file-name` when linker dependency
  output is unavailable). On a warm check, `titanc` verifies the recorded
  library files' byte digests; it does not rewalk `-L` search paths to check
  whether a newly created file in an earlier `-L` directory would shadow a
  previously linked library. Opaque compiler or linker mechanisms (`@file`
  response files, `-fplugin`/`--plugin`, `--specs`, `-Xclang`, `-wrapper`,
  `-Xlinker`, or linker scripts without linker dependency output) explicitly
  mark the `--c-source` node or final link uncacheable so it rebuilds cleanly.
* **Toolchain physical identity.** Native tool identity combines preprocessor
  self-description (`-E -v` banner, target, predefined macros) with the
  physical file metadata (realpath, size, device/inode/mode, and timestamps) of
  the compiler driver, explicit `ccache`/`sccache`/`distcc` target, named stage
  binaries (`cc1`, `as`), and linker/archiver/resource tools. It does not hash
  tool executable bytes; an in-place binary replacement at the same path that
  preserves file size and coarse timestamps (or Windows creation time), or an
  opaque wrapper script that hides a changed downstream binary, is not
  detected.
* **Stable compiler installation and inputs during a build.** The compiler
  installation, SDK, and source/header inputs must remain stable while a build
  runs. Worker processes verify the loaded `compiler` Lua inventory against the
  coordinator and fail with `compiler installation changed during build` on a
  mismatch. Read-race guards and pre-publication revalidation reject observed
  concurrent file modifications, although under coarse synchronous `stat`
  timestamps a same-second, same-size edit during a single read cannot be
  distinguished.
* **Whole-interface and compiler-Lua digests are conservative.** Interface
  digests cover a module's complete public interface (or complete
  source-private manifest for `.titan` imports) rather than per-consumer symbol
  usage: adding an unused export rechecks direct importers, and editing a doc
  comment in a `.titan`-imported module rechecks its explicit source consumers.
  Editing a comment in `titan-compiler/*.lua` or `c-parser/*.lua` invalidates
  `configuration compiler` across all modules.
* **Shared source-resolver `stat` behavior.** Automatic test-root discovery
  (`--test-dir`) reports errors from its own directory `stat`, `list`, entry
  `lstat`, and symlink target `stat` calls, then delegates candidate selection
  to the shared source resolver, which on POSIX treats a candidate `stat`
  failure as an absent candidate.
* **Local-filesystem output locking.** `titanc` coordinates concurrent
  invocations sharing an output tree or `--exe` destination directory through
  OS-backed locks on `<dir>/.titan-build.lock` (`flock` on Linux/macOS,
  `LockFileEx` on Windows). Locking is supported on local Linux, macOS, and
  Windows NTFS filesystems; network filesystems (such as NFS or SMB) are not
  covered.
* **GNU Make jobserver pool sharing.** Sharing a parent Make's job pool across
  `titanc`'s internal worker and native jobs requires GNU Make 4.4 or newer's
  FIFO jobserver (`--jobserver-auth=fifo:...`), or Linux where inherited pipe
  descriptors can be reopened privately through `/proc/self/fd`. When a parent
  Make advertises an inherited pipe jobserver that cannot be reopened privately
  (such as macOS's stock GNU Make 3.81 or GNU Make earlier than 4.4 on macOS),
  `titanc` warns once and enforces its own local `--jobs`/`TITAN_JOBS` cap
  without borrowing from the parent pool
  ([Compiler jobs and GNU Make](build-profiles.md#compiler-jobs-and-gnu-make)).

## Optimization and toolchain settings

Titan-generated C defaults to `-O3` on Linux, macOS, and Windows. On Linux, GCC
and Clang also receive `-flto=auto -ffat-lto-objects` during compilation and
linking. These objects retain native code and readable Titan metadata alongside
the compiler's intermediate representation. The final provider or executable
link can inline and propagate constants across separately compiled source
objects and members of Titan-produced archives. Normal export, private
visibility, and provider identity rules still apply. A dependency used through
an existing DSO remains a dynamic boundary.

The Linux compiler/linker toolchain must support fat LTO objects and the
matching LTO backend. Titan keeps the ordinary native-container contract; it
does not silently fall back to bitcode-only objects or omit requested LTO.

macOS and Windows do not enable LTO by default: their objects retain the
ordinary Mach-O or COFF representation consumed by Titan's metadata reader.
Bitcode-only object files are not supported module inputs.

Native compile and link flags are normalized once per invocation in a fixed
order: profile defaults first, then `TITAN_EXTRA_CPPFLAGS`,
`TITAN_EXTRA_CFLAGS`, and `TITAN_EXTRA_LDFLAGS` from the environment, and
finally command-line `-I`, `-D`, `--cflag`, `-L`, `-l`, and `--ldflag` switches
in command-line order
([Output directories](output-directory.md#native-compiler-and-linker-switches)).
Fixture and debugging builds can override the optimization defaults either via
CLI switches or environment variables:

```sh
titanc --incremental -o out --cflag=-O0 --cflag=-fno-lto \
  --ldflag=-O0 --ldflag=-fno-lto project.main
```

```sh
TITAN_EXTRA_CFLAGS='-O0 -fno-lto' TITAN_EXTRA_LDFLAGS='-O0 -fno-lto' \
  titanc --incremental -o out project.main
```

With `--incremental`, changing compile flags (`-I`, `-D`, `--cflag`,
`TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`, or `TITAN_BUILD_PROFILE`)
automatically misses `configuration options` and recompiles affected objects,
while changing link-only flags (`-L`, `-l`, `--ldflag`, `TITAN_EXTRA_LDFLAGS`,
`-X`, or `--exe`) misses only the final-link certificate and relinks existing
module objects.

## A Make build

Because `titanc --incremental` discovers the module import graph, certifies
sources, C headers, interfaces, flags, `--c-source` files, and final links, and
coordinates shared output directories, a project Makefile does not need
per-module `.o` rules, hand-maintained import lists, header prerequisites, or
configuration stamp files. Mark each `titanc` recipe phony and prefix it with
`+` so GNU Make passes its jobserver:

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

In this layout:

* `make app` and `make tests` always invoke `titanc`. On a warm build where
  nothing changed—including immediately after an identical SDK reinstall—all
  module objects, `src/native_helper.c`, and the final link record under
  `build/.titan-links/` hit, so `titanc` performs no C compilation and no link.
* Editing a function body in a dependency module recompiles only that module's
  `.o` and relinks; consumers whose imported public (or `.titan` source-private)
  interface did not change reuse their existing `.o` files.
* Editing `include/header.h` or `src/native_helper.c` recompiles only the
  modules or native C node whose closure includes that file, without listing C
  headers in `Makefile`.
* `app` and `tests` share `build/`. Unchanged production modules without
  `test_` functions compile once and are reused by both targets, while each
  executable keeps its own link certificate and synthetic entrypoint/runner
  directory under `build/.titan-links/<key>/`. If `make -j2 test` runs `app`
  and `tests` concurrently, `build/.titan-build.lock` serializes the two
  `titanc` invocations so the second waits without holding Make jobserver tokens
  and then reuses the objects published by the first.

Keep native dependency builds (such as bundled C libraries), custom code
generators, packaging rules, and test execution in Make; pass any generated or
authored helper `.c` files to `titanc` with `--c-source` and prebuilt native
archives or objects with `-X`. See
[Static compiled modules](static-compiled-modules.md) and
[Multi-module libraries](multi-module-libraries.md) for provider contracts.

The Titan repository's own standard-library and native-test targets use this
same single-invocation model: `make stdlib` and `make stdlib-objects` invoke
`titanc --output out --source-first --incremental -j$(TITAN_JOBS)` over the 26
standard-library roots (with `-c` for objects only, or `-X` for the runtime and
bundled native archives when linking `titan.so` and `titan.a`), and
`make titan-stdlib-test-build` invokes the installed `titanc --test
--incremental --no-uv-bootstrap` with `--test-dir`, `--exe`, and `--c-source`
for its aggregate C helpers. After an identical `luarocks make --force`
reinstall, rebuilding the native test aggregate hits every module object,
`--c-source` helper, and final link without recompiling or relinking.

## Separate standalone executables

An application can build in one `--incremental` invocation or prepare certified
objects with `-c --incremental` first. For example, if `app.helper` imports
`titan.math`, and `app.main` imports `app.helper.titan` and a separately built
`vendor.algorithms` provider:

```sh
titanc -o out vendor.algorithms
TITAN_PATH_0_6='out/?.a;out/?.so;;' \
  titanc -o out --static --incremental --exe out/bin/app app.main
./out/bin/app
```

When separate object steps are desired, `-c --incremental` certifies both
dependencies and explicit roots:

```sh
TITAN_PATH_0_6='out/?.a;out/?.so;;' \
  titanc -o out --static -c --incremental app.helper
TITAN_PATH_0_6='out/?.a;out/?.so;;' \
  titanc -o out --static -c --incremental app.main
TITAN_PATH_0_6='out/?.a;out/?.so;;' \
  titanc -o out --static --incremental --exe out/bin/app app.main
./out/bin/app
```

Repeating either `-c --incremental` command when inputs are unchanged is a
certified hit and runs no native compilation. The final invocation detects
`main` from the certified object metadata, reuses both application objects,
links the selected standard-library and external-library archives, and records
the final link certificate under `out/.titan-links/`. Pass `--exe`, `-L`, `-l`,
`--ldflag`, `-X`, and `--no-uv-bootstrap` on the final link invocation;
compile-only invocations do not emit an executable or entrypoint.

## Separate native test executables

A test suite can likewise build in one whole-graph invocation—listing roots
explicitly or discovering them with `--test-dir`—or precompile objects with
`-c --test --incremental`:

```sh
titanc -o out --test --incremental --exe out/project-tests \
  --test-dir tests
./out/project-tests
```

Or with separate compile-only invocations:

```sh
titanc -o out --test -c --incremental project.unit_tests
titanc -o out --test -c --incremental project.integration_tests
titanc -o out --test --incremental --exe out/project-tests \
  project.unit_tests project.integration_tests
```

`-c --test --incremental` discovers `test_` cases to certify and apply the
test-owner compilation flags (`-fno-optimize-sibling-calls`) without rendering
a runner or linking an executable. The final `--test --incremental` invocation
collects discovered cases from certified objects and any freshly compiled
modules, checks the target's link certificate under `out/.titan-links/`, and on
a miss renders the synthetic runner and entrypoint under
`out/.titan-links/<key>/synthetic/` and links the test executable. Application
`main` functions in test roots remain ignored.

`titan.test` is an ordinary dependency of the thin generated runner, supplied
by the installed SDK's compiled provider. Production source objects without
`test_` functions are shared between application and test builds in the same
output directory when native compile flags, SDK, and resolved dependency
bindings match. A test's explicit `.titan` import exposes the producer's local
declarations without changing the producer's generated object.
`--no-uv-bootstrap`, `--exe`, `-L`, `-l`, `--ldflag`, and `-X` belong on the
final link command.
