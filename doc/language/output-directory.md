# Keeping generated files in an output directory

Pass `-o DIRECTORY` or `--output DIRECTORY` to keep a build's generated files
in one directory:

```sh
titanc --output out app.main
./out/app/main
```

The argument names a **directory**, including when compiling one program. Titan
creates it and its missing parents, like `mkdir -p`. Relative paths are relative
to the compiler's working directory; absolute paths and paths containing spaces
are supported. An existing file cannot serve as the output directory.

Use an output directory for application, library, and test builds. Add that
directory to your project's ignore rules. Different configurations can share
sources while keeping their generated files separate:

```sh
titanc -o out/release app.main
titanc -o out/tests --test app.tests
./out/tests/app/tests
```

## Source hierarchy and final outputs

Generated C, objects, and FFI headers reproduce the source hierarchy **relative
to the selected source root**. `--tree` selects that root and `--output` selects
the destination independently. For example:

```sh
titanc --tree /projects/demo/src -o out app.main
```

This reads `/projects/demo/src/app/main.titan` and writes `out/app/main.c` and
`out/app/main.o`. It does not write into `/projects/demo/src` or reproduce the
absolute `/projects/demo/src` prefix. A folder module's canonical main owns
its generated C and objects, just as in a build without `--output`.

For Linux and macOS, these examples show the paths relative to `out/`:

| Source for `app.main` | C and object | Library provider pair and Lua loader | Program |
| --- | --- | --- | --- |
| `app/main.titan` | `app/main.c`, `app/main.o` | `app/main.so`, `app/main.a`, `app/main.lua` | `app/main` |
| `app/main/main.titan` | `app/main/main.c`, `app/main/main.o` | `app/main.so`, `app/main.a`, `app/main.lua` | `app/main__main` |

The library columns apply when no requested root defines the program's exact
`main` signature. Multiple library roots still share the provider named from
their longest common dotted prefix: `titanc -o out app.left app.right` emits
`out/app.so`, `out/app.a`, and the logical loaders under `out/app/`.

A large module may be split into several C translation units
([split modules](build-profiles.md#split-modules)). Its first unit keeps the
`app/main.c` and `app/main.o` names shown above, and only `app/main.o` carries
the module's metadata, including the authoritative list of its parts.
Additional units are numbered from 1, as `app/main.part1.c` and
`app/main.part1.o`, and every unit of that module includes a shared generated
`app/main.priv.h`. All of these files stay in the module's output directory,
and providers, archives, and programs link every object of the module.
Modules that are not split have no `.part` files or `.priv.h`, but the part
names up to the configured `--c-parts` maximum stay reserved for the
compiler, so do not place authored files there.

The same destination contains generated `.ffi.h` and `.titan.h` companions,
platform debug information, and compiler-managed metadata directories. Authored
quoted C headers continue to resolve relative to the original source directory.
The output directory changes neither logical module names nor source filenames
in diagnostics and tracebacks.

`--output` selects write locations; it does not add them to compiled-provider
lookup or Lua's search paths. When consuming a previously built library, add
its output directory to `TITAN_PATH_0_6`. For Lua consumers, select the
generated loaders and providers through the corresponding Lua paths:

```sh
LUA_PATH='out/?.lua;;' LUA_CPATH='out/?.so;;' lua -e 'require("app.main")'
```

### Executable destination (`--exe`)

Pass `--exe PATH` to choose the exact executable output path on Linux, macOS,
and Windows:

```sh
titanc --incremental -o out --exe out/my-app app.main
titanc --incremental -o out --test --exe out/my-tests app.tests
```

`PATH` is resolved relative to the compiler's working directory (not relative to
`--output`), and `titanc` creates any missing parent directories. `--exe` is
valid only when linking a standalone or `--test` executable; it is rejected with
`-c` / `--compile-only` or library-only builds.

On Windows, library providers and logical loaders move below `--output`.
Without `--exe`, standalone and test programs place their console launcher at
`<output>/bin/<logical-module>.exe` and their application provider DLL at
`<output>/lib/titan/0.6/<module>.dll` (for `app.main` with `-o out`,
`out/bin/app.main.exe` and `out/lib/titan/0.6/app/main.dll`). With `--exe PATH`,
`titanc` appends `.exe` when absent, writes the launcher to `PATH`, and keeps
the provider DLL at `<output>/lib/titan/0.6/<module>.dll`. The launcher embeds
the relative path from `<exe-dir>/../lib/titan/0.6` to that provider DLL on the
same volume, so `--exe out/app.exe`, `--exe out/bin/app.exe`, and external
same-volume destinations all locate the provider without changing its identity;
a destination on a different volume is rejected. A test executable's provider
is named after its first root, so two Windows test executables with the same
first root in one output directory share that DLL: building one replaces it
and makes the other relink on its next build. Give them separate output
directories when both must stay current. Supply the matching controlled
Lua runtime DLL as described in the
[Windows build guide](../implementation/windows-build.md).

### Native compiler and linker switches

`titanc` accepts native preprocessor, compiler, linker, and C-source options
directly on the command line:

| Option | Effect |
| --- | --- |
| `-I DIR` / `--include-dir DIR` | Repeatable include directory for C-FFI header parsing, C probes, generated C, and `--c-source` files, searched in order before the Titan/Lua SDK headers. |
| `-D NAME[=VALUE]` / `--define NAME[=VALUE]` | Repeatable preprocessor macro definition passed to C-FFI header parsing, probes, generated C, and `--c-source` files in command-line order. |
| `--cflag ARG` | Repeatable single native compile argument (such as `--cflag=-pthread` or `--cflag=-O0`). |
| `-L DIR` / `--library-dir DIR` | Repeatable native library search directory for final links. |
| `-l LIB` / `--link LIB` | Repeatable native library for final links; comma-separated lists and repeated flags preserve exact command-line order without deduplication. |
| `--ldflag ARG` | Repeatable single native link argument (such as `--ldflag=-Wl,--as-needed`). |
| `--c-source FILE` | Repeatable C source file compiled and certified by `titanc` under `<output>/.native/`, linked in command-line order before `-X` payloads. |
| `--print-c-objects` | With `-c`, print the absolute path of each certified `--c-source` object on standard output, one line per `--c-source` argument in argument order. |

For each native phase, `titanc` normalizes arguments once: profile defaults
first, then tokenized `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`, and
`TITAN_EXTRA_LDFLAGS` from the environment, and finally command-line switches in
their written order, with SDK `-I` directories placed last. Compile-phase switches
(`-I`, `-D`, `--cflag`, `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`) enter the
module configuration certificate. Link-only settings (`-L`, `-l`, `--ldflag`,
`TITAN_EXTRA_LDFLAGS`, `-X`, `--exe`) enter only the final-link certificate.
`-c` rejects the command-line link switches, while an environment
`TITAN_EXTRA_LDFLAGS` is accepted and simply unused because nothing is linked.
`-c` (with or without `--incremental`) may be used with `--c-source FILE` and
no Titan module names to compile or certify standalone C helper objects.

## Separate compilation and coverage

Use the same output directory across related builds so they share certified
module objects, native C nodes, link records, and output-tree locking:

```sh
titanc -o out --incremental --exe out/app app.main
titanc -o out --incremental --test --exe out/app-tests --test-dir tests
```

Inside the selected output directory, `titanc` maintains:

* `out/.titan-build.lock`: an exclusive OS-backed lock file held from
  certification through publication (`flock` on Linux and macOS, `LockFileEx` on
  Windows). When `--exe` names a directory outside `--output`, that directory
  is locked as well, in a deterministic order. Concurrent `titanc` invocations
  sharing `out/` serialize cleanly on local filesystems; the waiting process
  acquires the lock before certifying and reuses objects published by the
  first.
* `out/.titan/`: compiler caches. `preamble.c` is the stable translation unit
  used to certify the generated-C preamble headers, `digests` (only with
  `--output`) remembers file digests by precise file metadata so unchanged
  inputs need not be read and hashed again, and `linker-feature` remembers
  whether the linker can report its inputs. All of them are rebuilt when
  missing.
* `out/.native/<hash>.o` and `<hash>.record`: compiled objects and
  certificates for `--c-source` inputs, keyed by canonical source path.
  Preprocessed output and dependency files are temporary. Use
  `--print-c-objects` to learn an object's path.
* `out/.titan-links/<key>/record`, `link.d`, and `synthetic/`: per-target
  final-link certificates, linker dependency reports, and the generated test
  runner (`<name>__test_runner.titan` and its C and object) and entrypoint
  (`<name>__entrypoint.c` or `<name>__test_entrypoint.c`) for that target,
  keyed by its set of final outputs. Application and test binaries sharing
  `out/` keep separate link records and synthetic intermediates while reusing
  unchanged production module objects.

Without `--output`, `titanc` locks every `--tree` source root and the working
directory, and keeps preamble, linker-feature, native, and link metadata in
the first source root; it keeps no persistent digest cache.

Objects left beside sources do not satisfy reuse in another output directory.
See [Incremental and separate compilation](incremental-compilation.md) for the
complete certification inventory and miss codes.

Coverage keeps its `.coverage` directories inside this tree. For example,
`app/calc.titan` produces `out/app/.coverage/calc.c`,
`out/app/.coverage/calc.o`, and `out/app/.coverage/calc.gcno`. The default
report directory becomes `out/.coverage/report`:

```sh
titanc -o out --test --coverage app.tests
./out/app/tests
```

An explicit `--coverage-output DIRECTORY` still selects that report destination
directly. Probe results retain their separate SDK probe-cache location;
`--output` does not relocate or clear that cache. See
[Native source coverage](native-coverage.md).

## Repository builds and compatibility

Titan's repository build passes `--output out` for its standard modules and
uses subdirectories of `out/` for native tests and coverage. `out/` is ignored
by Git. Native dependency builds and the authored C runtime retain their own
build locations.

Omitting `--output` preserves the original paths: generated C, objects, and
headers beside the selected source, with final providers, loaders, and program
paths relative to the compiler's working directory. Existing build scripts can
adopt the option without changing module identities or binary contracts.
