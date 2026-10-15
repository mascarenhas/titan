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
its single translation unit, just as in a build without `--output`.

For Linux and macOS, these examples show the paths relative to `out/`:

| Source for `app.main` | C and object | Library provider pair and Lua loader | Program |
| --- | --- | --- | --- |
| `app/main.titan` | `app/main.c`, `app/main.o` | `app/main.so`, `app/main.a`, `app/main.lua` | `app/main` |
| `app/main/main.titan` | `app/main/main.c`, `app/main/main.o` | `app/main.so`, `app/main.a`, `app/main.lua` | `app/main__main` |

The library columns apply when no requested root defines the program's exact
`main` signature. Multiple library roots still share the provider named from
their longest common dotted prefix: `titanc -o out app.left app.right` emits
`out/app.so`, `out/app.a`, and the logical loaders under `out/app/`.

The same destination contains generated `.ffi.h` and `.titan.h` companions,
entrypoints, native test runners, platform debug information, and temporary
compiler files. Authored quoted C headers continue to resolve relative to the
original source directory. The output directory changes neither logical module
names nor source filenames in diagnostics and tracebacks.

On Windows, library providers and logical loaders also move below the output
directory. Standalone and test programs retain their deployment layout there:
`out/bin/app.main.exe` and `out/lib/titan/0.6/app/main.dll`.
`--launcher-name` changes only the launcher basename. Supply the matching
controlled Lua runtime DLL as described in the [Windows build guide](../implementation/windows-build.md).

`--output` selects write locations; it does not add them to compiled-provider
lookup or Lua's search paths. When consuming a previously built library, add
its output directory to `TITAN_PATH_0_6`. For Lua consumers, select the generated
loaders and providers through the corresponding Lua paths:

```sh
LUA_PATH='out/?.lua;;' LUA_CPATH='out/?.so;;' lua -e 'require("app.main")'
```

## Separate compilation and coverage

Use the same output directory throughout an incremental build:

```sh
titanc -o out --source-first -c --incremental app.base
titanc -o out --source-first --incremental app.main
```

Object reuse and generated-header restoration use the selected output tree.
Objects left beside sources do not satisfy reuse in another output directory.
The build system still owns dependency and configuration invalidation; changing
flags or tools does not automatically invalidate an otherwise current object.
See [Incremental and separate compilation](incremental-compilation.md).

Coverage keeps its `.coverage` directories inside this tree. For example,
`app/calc.titan` produces `out/app/.coverage/calc.c` and
`out/app/.coverage/calc.o`. The default report directory becomes
`out/.coverage/report`:

```sh
titanc -o out --test --coverage app.tests
./out/app/tests
```

An explicit `--coverage-output DIRECTORY` still selects that report destination
directly. Probe results retain their separate SDK probe-cache location;
`--output` does not relocate or clear that cache. See [Native source coverage](native-coverage.md).

## Repository builds and compatibility

Titan's repository build passes `--output out` for its standard modules and
uses subdirectories of `out/` for native tests and coverage. `out/` is ignored
by Git. Native dependency builds and the authored C runtime retain their own
build locations.

Omitting `--output` preserves the original paths: generated C, objects, and
headers beside the selected source, with final providers, loaders, and program
paths relative to the compiler's working directory. Existing build scripts can
adopt the option without changing module identities or binary contracts.
