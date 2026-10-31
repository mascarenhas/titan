# Incremental and separate compilation

With `--incremental`, `titanc` certifies generated objects, compiler-managed C
inputs, and final link outputs by semantic and content digests, reusing each
artifact when all of its inputs still match. A single `titanc` invocation
discovers the requested source import closure, certifies ready modules in
dependency order, restores hits in-process without parsing or typechecking
their sources, and runs short-lived worker processes only for modules that
miss. Without `--incremental`, `titanc` loads, checks, compiles, and links
selected source modules afresh.

For certificate layouts, worker scheduling, and record formats, see
[Object-backed source modules](../implementation/incremental-compilation.md),
[Compiler-owned build coordinator](../implementation/build-coordinator.md),
and [Driver and toolchain](../implementation/driver.md).

## Options and outputs

| Invocation | Effect |
| --- | --- |
| `titanc project.base project.feature` | Compile selected source modules and publish the usual provider pair, or an executable when one root has `main`. |
| `titanc --incremental project.base project.feature` | Certify and reuse eligible source objects, including requested roots, compile only misses across the module graph, and reuse or relink the final target. |
| `titanc -c project.feature` | Rebuild every source module in the requested closure to objects and generated headers; produce no provider or executable. |
| `titanc -c --incremental project.feature` | Certify and reuse eligible source objects, including requested roots, and compile only misses to objects and generated headers. |
| `titanc -c --incremental --c-source helper.c` | Certify or compile standalone native C source nodes without requiring Titan module roots. |
| `titanc -c --incremental --print-c-objects --c-source helper.c` | Also print the absolute path of each certified C object on standard output, one line per `--c-source` argument. |

`--compile-only` is the long spelling of `-c`. Plain `-c` without
`--incremental` forces every module in the requested source closure (and any
`--c-source` input) to rebuild. Combining `-c --incremental` certifies explicit
command-line roots by the same rules as source dependencies: an unchanged root
is a certified hit and compiles no object. Certification itself may still run
the C preprocessor and toolchain self-description probes.

Whether linking or running with `-c`, one `titanc` invocation plans the
complete source closure from the requested roots. Running module-frontend
workers and native compiler commands (generated-C translation-unit parts and
batched C validation probes) share the invocation's `-j` / `--jobs` (or
`TITAN_JOBS`) slot budget and any supported parent GNU Make jobserver pool
([Compiler jobs and GNU Make](build-profiles.md#compiler-jobs-and-gnu-make)).
Unrelated roots and multiple roots defining `main` can be compiled together
with `-c`; common provider naming and executable selection happen when linking.

Pass `-o out` or `--output out` so generated C, objects, headers, native C
nodes (`out/.native/`), final-link certificates (`out/.titan-links/`),
compiler caches (`out/.titan/`), and the output-tree lock
(`out/.titan-build.lock`) stay together in the
[output tree](output-directory.md). Without `--output`, module objects and
generated headers stay beside each flat source or folder main, including when
`--tree` points elsewhere; `titanc` then locks every source root and the
working directory, and keeps link and native metadata in the first source
root. A folder module's objects belong to the entire module, never to one
contributor: one object, or one object per part when the module is
[split](build-profiles.md#split-modules).

Reuse follows the source spelling but not the output spelling. The selected
`--tree` path appears in generated `#line` directives, debug information, and
tracebacks, so naming the same source root differently (for example relative
instead of absolute) rebuilds the affected modules. Different spellings of
the same `--output` or `--exe` destination, such as relative and absolute
paths, reuse the existing objects and link record.

Use `--source-first` when source dependencies should take precedence over
installed `.so`, `.a`, or `.dll` providers. This option still allows compiled
fallback on an ordinary import's source miss. It does not grant access to
private declarations: only a direct `import "project.base.titan"` requests the
source collaboration view.

`-c` rejects `--exe`, `-l`, `-L`, `--ldflag`, `-X`, and `--no-uv-bootstrap`
because those options apply only to linking. `--print-c-objects` requires `-c`
and at least one `--c-source`. `--static` remains a compiled
dependency preference (unsupported on Windows). `--incremental` cannot be
combined with `--print-ast`, which requires freshly checked ASTs in the
coordinator process. `--test` supports both incremental whole-graph linking and
`-c` compile-only object compilation, including automatic root discovery with
`--test-dir` and `--test-exclude`
([Testing Titan code](standard-library-test.md#discovery-and-compilation)).

## What object reuse promises

Each compiled primary module object (`<stem>.o`) embeds a certificate of the
inputs it was built from. An object written for another Titan ABI, an older
record schema, or another certificate format misses with `record-schema` and
is rebuilt from source; no cleanup or migration step is needed.

For each source module in the planned closure, `--incremental` certifies the
following inputs before accepting `<stem>.o`:

* **Own sources and folder membership.** The certificate records whether the
  module resolved as `flat` or `folder`, the exact ordered list of constituent
  `.titan` paths (main first, then immediate contributors in bytewise order of
  their logical filenames), and the SHA-256 content digest of each file. Adding or removing a
  folder contributor, switching between flat and folder layout, or editing a
  file with a preserved timestamp misses; touching a timestamp without changing
  bytes remains a hit. Explicit roots and direct `.titan` imports still require
  actual source files on disk. The paths are the files selected for the
  compilation's [target](target-source-selection.md#incremental-builds):
  adding or removing a target variant that changes the selection, or switching
  between byte-identical files, misses; editing, adding, or removing a variant
  whose label does not apply is a hit that compiles and links nothing.
* **Compiler and native configuration.** One invocation-wide configuration
  has four components, and `-v` names the one that changed:
  * `compiler`: the contents of every compiler and C-parser Lua file in the
    loaded installation, plus the executing `titanc` frontend script.
    Reinstalling identical files is a hit; editing any of them, even a
    comment, rebuilds every module.
  * `preamble`: the preprocessed fixed generated-C preamble (`titan.h`,
    `titan/ffi.h`, Lua headers, and C library headers) and the contents of
    every header it reaches, probed through `<output>/.titan/preamble.c`.
    This covers active macros, forced `-include` headers, `-isystem`
    shadowing, and `__has_include` queries, even in modules without
    `foreign import`.
  * `toolchain`: which C compiler installation runs. `titanc` asks the
    complete `CC` command (without the effective compile flags) for its
    predefined macros and its `-E -v` banner, and records the physical
    identity (resolved path, size, file identity, mode, and modification and
    change times) of the compiler driver, an explicit compiler behind
    `ccache`, `sccache`, or `distcc`, and the named compiler stages (`cc1` and
    `as` for GCC; `as` for Clang with `-fno-integrated-as`, where Clang is
    recognized from its `clang version` line, not from a path). The working
    directory that Clang prints in its banner does not take part, and on
    Linux and macOS a leading shell `exec` in `CC` is ignored.
  * `options`: the effective generated-C compile command (including profile
    defaults, `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`, and CLI `-I`, `-D`,
    and `--cflag` arguments), build profile, `#line` directive policy,
    `--pretty-print`, extra FFI include directories, and the selected Titan
    SDK root.
* **Module code-generation options.** Each record certifies its output stem and
  its code-generation policy: `--c-parts` and the split threshold, whether the
  module owns `test_` functions in a `--test` build (and therefore receives
  `-fno-optimize-sibling-calls`), and coverage instrumentation.
* **Split parts, companions, and coverage notes.** A
  [split module](build-profiles.md#split-modules) is reused as a whole or
  rebuilt from source. Only the primary `<stem>.o` carries Titan metadata,
  including the authoritative list of the module's parts (`<stem>.c`,
  `<stem>.part1.c`/`.part1.o`, and so on, plus `<stem>.priv.h`). Every
  recorded generated `.c` part, `.priv.h` header, and `.part<k>.o` object
  (plus `.gcno` notes when coverage is enabled for the module) must exist as a
  regular file, and part objects must be plain metadata-free native objects
  for the primary object's target. The metadata reader supports ELF, Mach-O,
  and ordinary Windows COFF objects (PE images, COFF import objects, and
  BigObj are not reusable source objects). Missing generated `.ffi.h` and
  `.titan.h` headers are restored from a certified object without
  recompiling the module.
* **Transitive C header closure.** Before restoring any declarations from a
  cached object, `titanc` revalidates every C header and include-search
  candidate the module's foreign imports reached:
  * Header files are identified by content, so republishing identical SDK or
    library headers with new timestamps, inodes, copies, hardlinks, or
    symlinks at the same resolved path is a hit.
  * Every real (non-generated) header whose declarations reach the module
    also records its resolved path, which determines the nominal identity of
    its C declarations. Retargeting a symlink or replacing it with a hardlink
    to a different resolved path is a clean miss, even when the bytes are
    identical.
  * Search candidates record existence, followed kind, and readability,
    catching newly created shadowing headers in earlier `-I` or
    quoted-include directories and permission changes.
* **Direct imports, contextual nominal owners, and native bindings.** Each
  direct import records its required view (`public` for ordinary imports, or
  `source` for `import "name.titan"`) and the dependency's semantic interface
  digest. For source modules, the `public` digest covers
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

With `--output`, `titanc` reads file metadata (device, inode, size, mode, and
nanosecond modification and change times) and keeps a digest cache in
`<output>/.titan/digests`, so a file whose metadata is unchanged since the
last invocation is not read and hashed again; each module's primary object is
still read for its
certificate. A changed file is always rehashed, and deleting the cache is
safe. Without `--output`, `titanc` keeps no persistent digest cache. An SDK
installed by its installer also records the digests of Titan's own providers
and runtime archives, `libbacktrace.a`, and the Lua archive it links, so even
a fresh output tree, or a build without `--output`, reuses them until those
files change. If the SDK files are replaced any other way, they are simply
read and hashed again. After compiling and linking, `titanc` checks every
input again by the same rule, so an edit made during the build is still
caught without rereading files that did not change. Unchanged metadata is
trusted. The times are reported in nanoseconds, but a filesystem may store
them more coarsely: on HFS+, ext3, or some NFS servers, a same-size edit made
in place within the same second as the previous write can go unnoticed until
the file changes again.

### Native `--c-source` nodes and final-link certification

Authored or generated C files passed with repeatable `--c-source FILE` are
compiled with the invocation's effective native compile flags and toolchain
identity (excluding Titan-only test-owner and coverage flags) into
`<output>/.native/<hash>.o` alongside a `<hash>.record` certificate, where
`<hash>` is derived from the C file's canonical path. On each invocation,
`titanc` preprocesses each C file and hashes the authored source,
preprocessed output, transitive header contents, compile command, and
toolchain identity. When `--incremental` is active and both the input digest
and current `.o` bytes match the record, `titanc` reuses the object without
compiling. Resulting objects are linked in `--c-source` command-line order
before `-X` payloads.

A build script that needs the compiled object itself, for example to copy a
helper to a fixed path, should ask for it with `--print-c-objects` rather
than listing `.native/`. Standard output then contains exactly one absolute
path per `--c-source` argument, in argument order. Moving a checkout leaves
the nodes keyed by its old paths in place, so `.native/` can hold more than
one object for the same C file:

```sh
object=$(titanc -c --incremental -o out/helper --print-c-objects \
  --c-source native/helper.c)
cmp -s "$object" out/helper.o || cp -p "$object" out/helper.o
```

For executable, test, and library builds (without `-c` or `--print-ast`),
`titanc` maintains a final-link certificate under
`<output>/.titan-links/<key>/record`, where `<key>` identifies the target's
set of final outputs. The generated test runner and entrypoint sources live
beside it in `<output>/.titan-links/<key>/synthetic/`, so an application and
a test executable sharing one output directory never overwrite each other's.
The link check runs before test runner rendering, entrypoint generation,
static-archive validation probes, and native linking. It certifies:

* the link recipe: ordered requested roots, entry module and
  `--no-uv-bootstrap`, effective link argv (`-L`, `-l`, `--ldflag`,
  `TITAN_EXTRA_LDFLAGS`), the compiler identity and the physical identities of
  the linker the compiler actually selects, the archiver, ranlib,
  resource-compiler, or `dsymutil` tools that target uses, every linker stage
  and plugin the compiler names for the link, and, with LTO, GCC's LTO
  compiler stages, discovered test cases, compiler
  template digest, coverage runtime
  inventory, Windows launcher manifest and relative provider path, Darwin
  `.dSYM` policy, native bindings, and target/deployment environment;
* the actual SHA-256 content digests of all linked module `.o` parts,
  `--c-source` objects, `-X` payloads, selected dynamic providers, static
  archives, and runtime inputs;
* the complete immutable owned output set on disk (executables, `.so`/`.a`
  pairs, Windows `.exe`/`.dll` pairs, and Darwin `.dSYM` bundles), checking
  file/directory kind, non-symlink status, content digests,
  and executable permission bits on Unix (mutable runtime `.gcda` counter files
  and coverage reports are not link outputs); and
* the resolved native link libraries and file operands (via
  `-Wl,--dependency-file` on GNU/LLD, `-Wl,-dependency_info` on Darwin ld64,
  or, where linker dependency output is unavailable, the `-l` libraries
  resolved through `-L` and compiler `-print-file-name` plus raw archive,
  object, import-library, `--just-symbols`, and `--retain-symbols-file`
  operands).

When the link certificate hits, `titanc` restores any missing public `.ffi.h`
or `.titan.h` headers and exits without generating synthetic C or invoking the
linker. Pure link changes (`-L`, `-l`, `--ldflag`, `-X`, `--exe`) or
implementation-only edits inside a dynamic provider miss only the final link and
relink existing module objects without recompiling Titan modules.

### Verbose hit and miss diagnostics

Without `-v`, `titanc` reports restored modules only as a count
(`N modules up to date`) and a final-link certificate hit as
`<output> up to date`; see [Build output](modules.md#build-output). Passing
`-v` or `--verbose` writes per-module, per-C-source, and per-link
decisions, and the native commands `titanc` runs, to standard error, beside
the plain progress lines. Module decisions are buffered and flushed in
deterministic plan order. Compiler output replayed from workers and native
jobs also goes to standard error, so standard output stays reserved for
requested results such as `--print-c-objects` paths:

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
| `record-schema [<detail>]` | Another Titan ABI, an older or incompatible record schema or digest algorithm, a module-name mismatch, or missing/invalid certificate fields. |
| `configuration compiler\|preamble\|toolchain\|options` | Loaded compiler/parser/frontend Lua inventory, generated-C preamble header closure, native toolchain identity, or effective compile options changed. |
| `source-set added\|removed <path>` | Flat-versus-folder layout, folder contributor membership, or the selected target variant of a source changed. |
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
* **Compiler-reserved output names.** Before any module compilation starts,
  `titanc` reserves every file the planned build may write and checks the
  whole set for collisions with sources, native inputs, the C headers of
  already certified modules, and other outputs; a module being recompiled
  checks the C headers it discovers against the same set before writing its
  generated module artifacts. For
  each module this includes `<stem>.part1.c`/`.part1.o` through the configured
  `--c-parts` maximum, even when the module generates fewer parts, along with
  `<stem>.priv.h`, `<stem>.titan.h`, and `<stem>.ffi.h`. An authored file at a
  reserved name is an error, never overwritten: keep hand-written C and headers
  away from those names.
* **Linker-reported library inputs do not rewalk earlier `-L` directories.**
  Link certification hashes the library files reported by the linker (or
  resolved through `-L` and `$(CC) -print-file-name` when linker dependency
  output is unavailable). On a warm check, `titanc` verifies the recorded
  library files' byte digests; it does not rewalk `-L` search paths to check
  whether a newly created file in an earlier `-L` directory would shadow a
  previously linked library. Opaque compiler or linker mechanisms (`@file`
  response files, `-fplugin`/`--plugin`, `--specs`, `-Xclang`, `-wrapper`,
  `-Xlinker`, file lists, and, without linker dependency output, linker
  scripts, thin archives, and any linker option outside the supported set)
  mark the `--c-source` node or final link uncacheable so it rebuilds cleanly.
* **Toolchain physical identity.** Native tool identity combines the
  compiler's self-description (its `-E -v` banner and predefined macros) with
  the physical file metadata (resolved path, size, file identity, mode, and
  modification and change times) of the compiler driver, an explicit
  `ccache`/`sccache`/`distcc` target, named stage binaries (`cc1`, `as`), and
  linker/archiver/resource tools. It does not hash tool executable bytes; an
  in-place binary replacement at the same path that preserves its size and
  both timestamps, or an opaque wrapper script that hides a changed downstream
  binary, is not detected.
* **Stable compiler installation and inputs during a build.** The compiler
  installation, SDK, and source/header inputs must remain stable while a build
  runs. Worker processes verify the loaded `compiler` Lua inventory against the
  coordinator and fail with `compiler installation changed during build` on a
  mismatch. Read-race guards and pre-publication revalidation reject observed
  concurrent file modifications.
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
  `build/.titan-links/` hit, so `titanc` compiles no object and runs no link;
  only certification probes such as preprocessing run.
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

`TITANC` here names one program, which matters because Titan reads an
environment variable of the same name. A compiled program or Lua host that
misses a module in its default directories may run `$TITANC --print-root`,
without a shell, to find the installed SDK (see [The Titan
path](modules.md#the-titan-path)), and GNU Make exports a `TITANC` given on its
command line, or inherited from the environment, to every recipe, including
`./build/app-tests`. Keep the value a single program name or path, as in
`make TITANC=/opt/titan/bin/titanc`, and give a compiler command that needs
arguments or a wrapper another variable name.

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
TITAN_PATH_0_6='out;;' \
  titanc -o out --static --incremental --exe out/bin/app app.main
./out/bin/app
```

When separate object steps are desired, `-c --incremental` certifies both
dependencies and explicit roots:

```sh
TITAN_PATH_0_6='out;;' \
  titanc -o out --static -c --incremental app.helper
TITAN_PATH_0_6='out;;' \
  titanc -o out --static -c --incremental app.main
TITAN_PATH_0_6='out;;' \
  titanc -o out --static --incremental --exe out/bin/app app.main
./out/bin/app
```

Repeating either `-c --incremental` command when inputs are unchanged is a
certified hit and compiles no object. The final invocation detects
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
