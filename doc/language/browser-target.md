# Compiling for the browser target

`titanc --target browser` compiles Titan modules and C sources to WebAssembly
objects with Emscripten, and builds Titan libraries as WebAssembly archives.
Use it to prepare browser code and check that it compiles; the compiler does
not yet produce a runnable browser program:

```sh
titanc --target browser --output out-browser -c app.widgets
titanc --target browser --output out-browser app.widgets
```

The first command compiles `app.widgets` and its source dependencies to
objects. The second builds the library archive `out-browser/app/widgets.a`.

The browser target currently covers **object compilation and library
archives only**. Linking a program or a test executable stops with
`browser program linking is not available yet`. Program linking, the browser
runtime and standard library, and running the result are planned in
[#329](https://github.com/mascarenhas/titan/issues/329).

Source files for the browser use the `browser` label described in [target
source selection](target-source-selection.md): `name.browser.titan` is
selected before `name.titan`, and `name.native.titan` or an OS variant is
never selected.

## Prerequisites

You need:

* **A Linux or macOS host.** On any other host, including Windows,
  `--target browser` stops with `browser builds are supported from Linux and
  macOS hosts (host is windows)`.
* **Emscripten 6.0.13**, exactly. Install it with
  [emsdk](https://emscripten.org/docs/getting_started/downloads.html):

  ```sh
  git clone https://github.com/emscripten-core/emsdk.git
  cd emsdk
  ./emsdk install 6.0.13
  ./emsdk activate 6.0.13
  source ./emsdk_env.sh
  ```

* **The browser build of Titan's Lua fork**, installed into the same prefix as
  Titan (see [below](#installing-the-browser-lua)).

Titan finds `emcc` through `EMSDK` when it is set and not empty, as
`$EMSDK/upstream/emscripten/emcc`, and otherwise on `PATH`. `emar` and
`emranlib` must sit beside that `emcc`. Your `CC`, `AR`, and `RANLIB` settings
are not used for the browser target. A missing or different Emscripten stops
the build with a message that names where Titan looked, the version it found,
and the commands to fix it:

```text
browser target requires Emscripten 6.0.13: emcc not found (EMSDK unset; not on PATH); install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh
browser target requires Emscripten 6.0.13: "/opt/emsdk/upstream/emscripten/emcc" reports 6.0.12; install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh
```

### Installing the browser Lua

Titan's generated C includes Lua's internal headers, so a browser build needs
a Lua built for the browser with exactly the settings Titan expects. The
fork's `browser` target builds it, and its `install-browser` target installs
it, building it first if needed. Run it in the fork with the same `PREFIX`
as your Titan installation and with Emscripten active:

```sh
source /path/to/emsdk/emsdk_env.sh
cd lua-5.5.1        # the submodule of a Titan checkout
make install-browser PREFIX="$PREFIX"
```

From a source archive of the fork's release, which has no Git metadata, also
pass the release's 40-character commit as `FORK_REVISION=<commit>`. See
[Installing Titan](installation.md#the-browser-lua) for the complete steps.

The installation writes only below `PREFIX/lib/browser/`:

| Path | Contents |
| --- | --- |
| `lib/browser/liblua.a` | Lua compiled to WebAssembly |
| `lib/browser/include/` | every Lua header the archive was compiled against, including the internal headers and `luaconf.h` |
| `lib/browser/liblua-config.txt` | the build record: the fork commit, the archive and header digests, the Emscripten version, and the compile settings |

It does not change the native Lua installation. Every browser invocation
checks the record against the installed archive, the headers, and the running
Emscripten before compiling. An inconsistent Lua installation reports the
record, the field, both values, and the command that repairs it:

```text
browser Lua record "/home/me/.local/titan/lib/browser/liblua-config.txt" field archive_sha256 mismatch: recorded "c64a...", expected "9f1e..." (fork_revision=4f74...); install it with 'make install-browser PREFIX=/home/me/.local/titan'
```

A missing record is reported as `is unavailable: <reason>` and a damaged one
as `is malformed: <detail>`, with the same install command.

### Bootstrap order

Bootstrap order: (1) the fork's `browser` target, a prerequisite of #328,
installs the verified browser Lua (`PREFIX/lib/browser/liblua.a` and its
record); (2) `luarocks make` installs the compiler; (3) with only (1) and (2),
`titanc --target browser` permits C-only work into owned `--output`
directories: object compilation, and library-mode archives checked
structurally (#328); (4) `make browser-sdk` (#329) builds and installs the
runtime archive, loader library and runner tool into
`lib/titan-browser/<ver>/`; (5) it publishes the minimal stdlib provider and
protocol-probes it against the runtime staged in step (4); (6) it writes the
browser SDK digest manifest last. Missing browser-SDK paths are diagnosed,
naming `make browser-sdk`, only when a program or test is linked or when
library-mode publication runs #329's executing protocol check; compile-only
work needs only the verified Lua pieces.

Steps (1) to (3) are what this compiler supports. `make browser-sdk` and the
directory `lib/titan-browser/0.6/` belong to #329; today that directory may be
absent or empty, and object and archive builds never require it.

## Selecting the target

Pass `--target browser` (or `-T browser`, or `--target=browser`), or set
`TITAN_TARGET=browser` in the environment. The option wins over the variable.
See [choosing the target](target-source-selection.md#choosing-the-target--t--target-and-titan_target)
for the complete vocabulary. Only the `titanc` command reads `TITAN_TARGET`;
the compiler library and the language server do not. Editors analyze the host
target only.

## One target per output directory

The browser target always needs an output directory:

```text
$ titanc --target browser -c app.widgets
--target browser requires --output
```

This applies whether the target came from the option or from
`TITAN_TARGET`. An output directory holds the files of one target, recorded
in a marker file `<output>/.titan-target`:

* The first browser build into an empty directory writes the marker, which
  contains `browser`. The directory may already hold Titan's lock file
  `.titan-build.lock`, but nothing else.
* A browser build refuses a nonempty directory without a marker, and a
  directory whose marker names another target.
* A native build refuses a directory marked `browser`. Native builds read the
  marker but never write one.

```text
browser output root "out" is not empty and has no .titan-target marker; use a separate --output directory
output root "out-browser" belongs to target "browser", not "linux"; use a separate --output directory
```

Keep separate output directories for native and browser builds, such as
`out/` and `out-browser/`. The two never share objects, certificates, or link
records, and building one leaves the other untouched. A native build without
`--output` also checks the source roots and the working directory, so do not
use a browser output directory as a native source root. See [output
directories](output-directory.md#the-target-marker) for the marker's place
among the other compiler-owned files.

## What you can build

**Objects.** `-c` compiles each Titan module to a WebAssembly object with its
metadata, and `--c-source FILE` compiles C helpers with the same Emscripten
settings. `--incremental` reuses unchanged objects exactly as for native
builds.

**Library archives.** Without `-c`, a build with no `main` publishes only
`<provider>.a`, named from the roots' longest common dotted prefix as for
native libraries. There is no `.so`, debug bundle, or Lua file. Titan never
loads a browser archive on the build machine. Instead it checks every archive
it builds structurally before publishing it:

* every member is a WebAssembly object with the expected target features;
* the archive holds exactly the intended modules, with the interfaces the
  compiler just checked;
* each module's own object defines its five protocol entry points as global
  functions; and
* no member refers to `dlopen`, `dlsym`, or the native backtrace library.

A failed check publishes nothing and leaves an existing archive unchanged.
Titan also refuses to publish next to a native provider of the same name,
such as `out-browser/app/widgets.so`, rather than delete a file it does not
own:

```text
browser provider "out-browser/app/widgets.a" has native companion "out-browser/app/widgets.so"; use a separate --output directory
```

**Programs and tests.** A module with `main`, or `--test` without `-c`, stops
with `browser program linking is not available yet`.

## Dependencies and the browser Titan path

Browser builds use only browser archives and source. An import is resolved
from, in order:

1. the browser SDK directory `PREFIX/lib/titan-browser/0.6/` (empty until
   #329 installs the browser runtime and standard library);
2. the [Titan path](modules.md#the-titan-path) from `TITAN_PATH_0_6` or
   `TITAN_PATH`, where `;;` stands for `.`; without either variable, only `.`
   is searched; and
3. source, with the usual `--tree`, `--source-first`, `--test`, and explicit
   `.titan` import rules.

The native standard library and native providers are never used. Shared
libraries are never considered, and an archive on the path that is not a
matching browser archive is an error rather than skipped:

```text
cannot inspect static provider '/home/me/native-libs/app/util.a': "/home/me/native-libs/app/util.a": archive member #2 at byte <offset> name "util.o": target mismatch: object format elf does not match target format wasm
```

A `TITAN_PATH` written for native builds therefore usually names native
archive directories. Set a separate path for browser invocations that lists
only browser output directories:

```sh
titanc --target browser -o out-browser app.util
TITAN_PATH_0_6='out-browser' titanc --target browser -o out-app app.main_lib
```

## Compiler flags

The browser target compiles with Titan's own Emscripten settings, the Lua
defines from the build record, and the define `TITAN_TARGET_BROWSER=1`, which
C headers can test. `-I`, `-D`, and `--cflag` options and
`TITAN_EXTRA_CPPFLAGS`/`TITAN_EXTRA_CFLAGS` are added after them, as for
native builds. Flags that only make sense for a native target are rejected
rather than ignored:

`-fPIC`, `-fpic`, `-fPIE`, `-fpie`, `-pie`, `-shared`, `-dynamiclib`,
`-rdynamic`, `-pthread`, `-flto` and `-flto=...`, `-ffat-lto-objects`,
`-march=...`, `-mcpu=...`, `-mtune=...`, `-m32`, `-m64`, `-fwasm-exceptions`,
and an `-sSUPPORT_LONGJMP` setting other than `emscripten`.

The check covers `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`,
`TITAN_EXTRA_LDFLAGS`, `--cflag`, and `--ldflag`, and names the source:

```text
browser target does not support TITAN_EXTRA_CFLAGS flag "-flto"
```

`-fno-lto` is accepted. Environment settings meant for native builds, such as
`TITAN_EXTRA_CFLAGS=-O0 -fno-lto -march=native`, must be cleared for browser
invocations.

Flags that change the Wasm feature set, such as `--cflag=-msimd128`, are
reported separately from Lua record errors. The diagnostic lists the supplied
compile flags and the actual versus required target features. Remove the
feature-changing flag; reinstalling browser Lua does not repair that mismatch.

## Current limits

* Programs and tests cannot be linked, and nothing built for the browser can
  run yet (#329).
* No browser standard library is installed yet, so imports of standard
  modules have no browser provider (#329).
* Only Linux and macOS hosts are supported.
* The language server analyzes the host target only.
* Native source coverage (`--coverage` and its backend/report options) is not
  supported for the browser target.

See [the browser target](../implementation/browser-target.md) in the
implementation manual for the target descriptor, the record checks, cache and
output isolation, and the archive format.
