# Compiling for the browser target

`titanc --target browser` compiles Titan programs, tests, and libraries to
WebAssembly with Emscripten. A program or test becomes a pair of files, an ES
module `app.mjs` and its `app.wasm`, that runs under Node and in headless
Chrome or Chromium:

```sh
titanc --target browser -o out --exe out/app.mjs app
titan-browser-run out/app.mjs -- first second
```

The first command builds `out/app.mjs` and `out/app.wasm` from the module
`app`, which defines `main`. The second runs the program under Node with the
arguments `first` and `second`, copies its output byte for byte, and exits with
its status. A library build without `main` produces a WebAssembly archive, and
`-c` compiles objects only:

```sh
titanc --target browser --output out-browser -c app.widgets
titanc --target browser --output out-browser app.widgets
```

Source files for the browser use the `browser` label described in [target
source selection](target-source-selection.md): `name.browser.titan` is
selected before `name.titan`, and `name.native.titan` or an OS variant is
never selected.

The browser standard library currently provides `test`, `coroutine`, and
`gc`. Programs therefore cannot yet use `async`, timers, files, or the other
standard modules; see [current limits](#current-limits).

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

* **Node 24.** It runs browser programs and tests, and it runs the check that
  Titan performs before it publishes a browser library (see [library
  archives](#library-archives)). emsdk 6.0.13 ships a Node 24 under
  `$EMSDK/node/`. Titan uses the executable named by `TITAN_NODE` when that
  variable is set, and otherwise the `node` on `PATH`; another major version
  is rejected.
* **Chrome or Chromium**, only for running programs in a browser engine. Any
  Chrome, Chromium, or Chrome for Testing build that runs headless works,
  including the smaller Chrome for Testing *headless shell*. Set `TITAN_CHROME`
  to its executable, or put it on `PATH` as `google-chrome`,
  `google-chrome-stable`, `chromium`, `chromium-browser`, or
  `chrome-headless-shell`.
* **The browser build of Titan's Lua fork** and **the browser SDK**, both
  installed into the same prefix as Titan; the next two sections install them.

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
a Lua built for the browser with exactly the settings Titan expects. From a
Titan checkout, with Emscripten active and the same `PREFIX` as your Titan
installation, run:

```sh
source /path/to/emsdk/emsdk_env.sh
make lua-browser PREFIX="$PREFIX"
```

`make lua-browser` builds the fork's `browser` target and installs it. It
keeps an existing installation only when the complete browser configuration
matches it: the fork commit, the Emscripten version, the compile flags and
defines, the numeric types, and the digests of the installed archive and
headers. A matching commit alone is not enough; a changed setting or a
damaged archive or header is rebuilt and reinstalled. `luarocks make` and
`make browser-sdk` never run it.

The fork's own `install-browser` target does the same work without the
reuse check, and is the command that the compiler's diagnostics name. From
a source archive of the fork's release, which has no Git metadata, also pass
the release's 40-character commit as `FORK_REVISION=<commit>`. See [Installing
Titan](installation.md#the-browser-lua-and-sdk) for the complete steps.

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

### Installing the browser SDK

The browser SDK holds the browser runtime, the JavaScript loader, the runner
tool, and the browser standard library. After `luarocks make` (or `make
install-compiler-sdk`) and `make lua-browser`, run from the Titan checkout:

```sh
source /path/to/emsdk/emsdk_env.sh
make browser-sdk PREFIX="$PREFIX"
```

It uses the installed `titanc --target browser` and needs Node 24, because it
publishes the browser standard library through the same check as any browser
library. When `EMSDK` is set and `TITAN_NODE` is not, the target appends
emsdk's bundled Node directory to the end of `PATH`, so a different `node`
earlier on `PATH` still wins; set `TITAN_NODE` when that `node` is not version
24. It installs into `lib/titan-browser/0.6/` under the Titan installation
root:

| File | Contents |
| --- | --- |
| `libtitan.a` | the browser runtime archive |
| `libtitan-lpeglabel.a` | the PEG engine, for a later browser `peg` module |
| `titan.a` | the browser standard library: `titan.test`, `titan.coroutine`, and `titan.gc` |
| `titan-browser.mjs` | the [loader](#the-loader-api) |
| `titan-browser-library.js` | the Emscripten JavaScript library that every browser image links |
| `titan-browser-run`, `titan-browser-run.mjs`, `titan-browser-node-worker.mjs`, `titan-browser-page.mjs` | the [runner](#running-with-titan-browser-run) |
| `sdk-digests` | content digests of the browser SDK, written last |

The directory is a sibling of the native `lib/titan/0.6/`, never inside it,
and native builds never search it. `make browser-sdk` works into an empty
directory and is the only Titan Make target that needs Emscripten. In a
[separate rocks tree](installation.md#a-separate-rocks-tree), pass both roots,
`make browser-sdk PREFIX="$PREFIX" ROCKS_TREE="$ROCKS_TREE"`; it first copies
the verified browser Lua from `PREFIX` into `ROCKS_TREE`.

Rerun `make lua-browser` and `make browser-sdk` after changing Emscripten, the
fork, or Titan.

### Bootstrap order

The pieces build in this order:

1. the fork's `browser` target (`make lua-browser`) installs the verified
   browser Lua, `PREFIX/lib/browser/liblua.a` and its record;
2. `luarocks make` installs the compiler;
3. with only (1) and (2), `titanc --target browser` already performs C-only
   work into owned `--output` directories: object compilation with `-c`,
   including `--c-source` helpers;
4. `make browser-sdk` builds and installs the runtime archive, the loader
   library, and the runner tool into `lib/titan-browser/0.6/`;
5. it publishes the browser standard library, checked against the runtime from
   step 4; and
6. it writes the SDK digest manifest last.

A missing browser SDK is reported only when a program or test is linked or a
library is published, and then names the command that installs it:

```text
browser SDK is incomplete: missing "/home/me/.local/titan/lib/titan-browser/0.6/libtitan.a"; run 'make browser-sdk PREFIX=/home/me/.local/titan'
```

When `ROCKS_TREE` is set, the command also passes `ROCKS_TREE=<tree>`.
Compiling objects never needs the SDK.

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

### Objects

`-c` compiles each Titan module to a WebAssembly object with its metadata, and
`--c-source FILE` compiles C helpers with the same Emscripten settings.
`--incremental` reuses unchanged objects exactly as for native builds.

### Library archives

Without `-c`, a build with no `main` publishes only `<provider>.a`, named from
the roots' longest common dotted prefix as for native libraries. There is no
`.so`, debug bundle, or Lua file. Before publishing, Titan checks the archive
in two steps:

* **Structurally:** every member is a WebAssembly object with the expected
  target features; the archive holds exactly the intended modules, with the
  interfaces the compiler just checked; each module's own object defines its
  five protocol entry points as global functions; and no member refers to
  `dlopen`, `dlsym`, `dlerror`, or the native backtrace library.
* **By running it:** Titan links a small probe program against the archive
  and the browser runtime and runs it under Node. The probe checks that each
  module's entry points are present and that its ABI, type, and layout
  records match the archive's metadata.

A failed check publishes nothing and leaves an existing archive unchanged. The
second step needs Node 24 and the browser SDK:

```text
browser provider validation requires Node 24: node not found (TITAN_NODE unset; not on PATH); set TITAN_NODE to a Node 24 executable
selected static provider failed executable-context protocol validation (browser runner exit 21)
```

Titan also refuses to publish next to a native provider of the same name,
such as `out-browser/app/widgets.so`, rather than delete a file it does not
own:

```text
browser provider "out-browser/app/widgets.a" has native companion "out-browser/app/widgets.so"; use a separate --output directory
```

A consumer can build against a published browser archive without the
library's source, from the SDK directory or the browser Titan path described
[below](#dependencies-and-the-browser-titan-path).

### Programs

A build whose root module defines `main` links a program. The result is always
two files that belong together: the ES module and its WebAssembly binary with
the same stem. Without `--exe`, the program uses the native program's path
below the output directory with `.mjs` added, so `titanc --target browser -o
out app` writes `out/app.mjs` and `out/app.wasm`. An explicit `--exe` must end
in `.mjs`:

```text
browser executable output "out/app" must end in .mjs
```

Titan publishes the two files together: a failed link leaves
the previous pair in place. `--incremental` reuses an unchanged pair without
relinking.

`main` has the same signature as for a native program:

```titan
foreign import "stdio.h"

function main(args: {string}): integer
  local greeting = "hello, " .. (args[1] or "browser") .. "\n"
  ffi.fwrite(greeting, 1, #greeting, ffi.stdout)
  return 0
end
```

`args[1]` is the first program argument; there is no program name at index 0.
Arguments are byte strings; through the [loader API](#the-loader-api) they may
contain any byte, including NUL.

Building never runs the program. A link that selects browser archives, such
as the standard library's `titan.a`, first checks them under Node as described
for [library archives](#library-archives), so linking also needs Node 24.

### Tests

`--test` builds the native test runner for the browser:

```sh
titanc --target browser --test -o out --exe out/app_tests.mjs app.calc_test
titan-browser-run out/app_tests.mjs
titan-browser-run out/app_tests.mjs -- --filter='zero$' --verbose
```

Discovery, case names, filtering, and output are those of the [native test
runner](standard-library-test.md#running-and-filtering); pass its options
after `--`. Without `--exe`, the test image takes the first root's program
path with `.mjs` added. As with native tests, a run that selects no case exits
0, so a script that must prove something ran should check the reported case
count.

## Running with `titan-browser-run`

`titan-browser-run` is installed in the SDK directory,
`PREFIX/lib/titan-browser/0.6/titan-browser-run`. Put that directory on `PATH`
or call it by path:

```text
titan-browser-run [--engine node|chromium] [--timeout MS] [--grace MS]
                  [--chrome PATH] [--cdp pipe|port] [--root DIR]
                  [--js-test] FILE [-- ARG...]
```

`FILE` is the program's `.mjs`. Everything after `--` is passed to `main`
unchanged. The tool writes the program's stdout and stderr bytes to its own
stdout and stderr exactly, and writes its own messages, all starting with
`titan-browser-run:`, to stderr only.

| Option | Meaning |
| --- | --- |
| `--engine node` | Run under Node 24 (the default). |
| `--engine chromium` | Run in a new headless Chrome or Chromium. |
| `--timeout MS` | Wall-clock limit for the whole run, in milliseconds; default 30000. |
| `--grace MS` | Time to keep watching after the program completes, to catch late traps and aborts; default 1500. |
| `--chrome PATH` | The Chrome or Chromium executable; overrides `TITAN_CHROME`. |
| `--cdp pipe\|port` | How the tool controls Chromium: a private pipe (the default) or a loopback DevTools port. |
| `--root DIR` | The directory served to the engine; defaults to `FILE`'s directory, and must contain `FILE` and its `.wasm`. |
| `--js-test` | Run `FILE` as a JavaScript test module instead of a program (used by Titan's own tests). |
| `--help`, `--version` | Print usage or the version to stderr and exit 0. |
| `--probe` | Print one line of JSON describing the Node and Chrome that the tool would use, without running anything. |

Under Node, the program runs in a separate Node process. Under Chromium, the
tool serves the root directory on a loopback address, starts the browser with
a fresh profile, and logs the executable, its version, and the profile
directory to stderr. It closes the browser, stops every process it started,
and deletes the profile when the run ends, whatever the outcome. The browser
keeps its sandbox; inside a container that runs as root, where Chrome refuses
to start sandboxed, set `TITAN_BROWSER_ROOT_NO_SANDBOX=1`, which the tool
honors only for the root user.

### Exit status

| Exit | Meaning |
| --- | --- |
| `status & 255` | The program completed with `status`: the value `main` returned, or 1 after an uncaught error. A test image exits 0 when every selected case passed, 1 when a case failed, and 2 for invalid test options. |
| 2 | Invalid `titan-browser-run` options; usage is printed. |
| 70 | The engine aborted before the program completed. |
| 71 | WebAssembly trapped before the program completed. |
| 72 | The `--timeout` limit expired, including a program that never stops computing. |
| 73 | A trap or abort happened during the grace period after completion; it overrides the earlier result. |
| 74 | An unhandled Promise rejection, before completion or during the grace period. |
| 75 | The tool itself failed: Node or Chrome missing, an unreadable or invalid image, an engine that exited early, or a failed cleanup. |
| 76 | A loader output sink failed (only with `--js-test`). |

A program's own status can coincide with 70 to 76. The stderr message tells
the cases apart: an infrastructure failure always prints one, such as
`titan-browser-run: timed out after 30000 ms` or `titan-browser-run: abort:
<reason>`, while a completed program adds nothing of its own. Test statuses 0,
1, and 2 never coincide with them.

A missing or wrong Node is reported before anything starts, with exit 75:

```text
titan-browser-run: Node 24 is required (node not found (TITAN_NODE unset; not on PATH))
titan-browser-run: Node 24 is required ("/usr/bin/node" reports v26.1.0; expected Node 24)
titan-browser-run: headless Chromium not found; set TITAN_CHROME to a Chrome executable
```

## Status and output semantics

A browser program completes in one of two ways:

* **Returned.** `main` returned an integer. The status is its low 32 bits read
  as a signed 32-bit integer, so `-1` stays `-1` and `4294967297` becomes `1`.
  The runner then exits with `status & 255`.
* **Failed.** An error escaped `main` or the module initializers. The program
  writes the standard report to stderr, as a native program does:
  `<progname>: <message>`, then `stack traceback:`, then one tab-indented line
  per frame. The status is 1. `<progname>` is the last component of the main
  module's name, or of the first test root's name for a test image.

The program ends when `main` returns or fails; output written up to then,
including finalizer output while Lua closes and an unterminated last line, is
delivered in full. Output is binary: NUL, `0xFF`, and invalid UTF-8 pass
through unchanged. Standard input is always at end of file.

### Traces

A browser trace currently shows Lua frames only. Each Lua function appears as
`source:line: in name`, every C function, including the entry of each compiled
Titan function that Lua called, as `[C]: in name`, and Lua tail calls as
`(...tail calls...)`. Compiled Titan frames, Titan source lines, and native
addresses do not appear. `titan.backtrace()`, the `traceback` local in a
`catch`, bare `raise`, and coroutine traces follow the same rules as natively;
only the frames they contain differ. A browser trace backend that reports
Titan frames through source maps is planned.

## The loader API

The runner uses the loader `titan-browser.mjs` from the SDK directory, and
JavaScript code can use it directly. It works in Node 24 and in the browser:

```javascript
import factory from "./out/app.mjs";
import { create } from "/home/me/.local/titan/lib/titan-browser/0.6/titan-browser.mjs";

const instance = create(factory, {
  stdout: chunk => { process.stdout.write(chunk); },
  stderr: chunk => { process.stderr.write(chunk); },
});
try {
  const result = await instance.run(["first", new Uint8Array([0, 255])]);
  console.error(result.kind, result.status);
} finally {
  await instance.dispose();
}
```

`create(factory, options)` takes the default export of a generated `.mjs` and
returns an instance with three methods:

* `initialize()` instantiates the WebAssembly module and returns a Promise.
  It runs no Titan code, and calling it again returns the same Promise. `run`
  calls it when needed.
* `run(args)` runs `main` once with `args`, an Array of strings, which are
  encoded as UTF-8, and `Uint8Array` values, which are copied as they are. The
  Promise resolves to `{kind, status, bytes}`: `kind` is `"returned"` or
  `"failed"`, `status` is the signed 32-bit status, and `bytes` is a
  `Uint8Array` with the error message of a failed run (empty for a returned
  run). A nonzero status or a failed run is a result, not a rejection.
* `dispose()` releases the instance and returns a Promise. It waits for a run
  in progress to finish; it does not cancel it.

The options are `stdout` and `stderr`, the output sinks, and `locateFile`,
which Emscripten uses to find the `.wasm`; by default the `.wasm` beside the
`.mjs` is used. A missing sink discards that stream.

**One run per instance.** An instance runs `main` at most once. Create a new
instance for another run; independent instances can run at the same time in
one JavaScript realm, and a disposed instance can be collected.

**Sinks.** A sink is a synchronous function that receives each chunk of its
stream as a fresh `Uint8Array`, which it may keep or modify. The loader calls
sinks only when no WebAssembly code is running: when the run returns to
JavaScript, while it waits on an asynchronous operation, and at completion.
Chunks of one stream arrive in order; there is no ordering between the two
streams. A sink must return `undefined`. If a sink throws or returns anything
else, including a Promise, the loader stops calling it, lets the program
finish its Lua cleanup when the instance is still intact, and rejects the run
once with that failure; no unhandled rejection remains.

**Errors.** A rejected Promise carries an `Error` whose `name` is
`TitanBrowserError`, with a `code`, a fixed message, and, where there is one,
the original error as `cause`:

| `code` | Message | When |
| --- | --- | --- |
| `TITAN_BROWSER_REENTRY` | `browser instance is suspended; reentry is not allowed` | `run` while the instance's run is still active, including while it waits |
| `TITAN_BROWSER_STATE` | `browser instance has already run or is disposed` | `run` after the instance has run, failed, or been disposed |
| `TITAN_BROWSER_SINK` | `browser stdout sink failed`, `browser stderr sink failed`, `browser stdout sink must return undefined`, `browser stderr sink must return undefined` | a sink failed; `stream` names it |
| `TITAN_BROWSER_ABORT` | the engine's abort reason | the WebAssembly module aborted |
| `TITAN_BROWSER_TRAP` | the trap's message | the WebAssembly module trapped |
| `TITAN_BROWSER_PROTOCOL` | for example `browser entry returned without completion or suspension` | the image broke the loader's protocol |

After an abort or a trap the instance is unusable, and `dispose()` releases it
without running more WebAssembly code. Invalid arguments to `create` and
`run` throw or reject with a `TypeError`.

## Dependencies and the browser Titan path

Browser builds use only browser archives and source. An import is resolved
from, in order:

1. the browser SDK directory `PREFIX/lib/titan-browser/0.6/`, which holds the
   browser standard library;
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

## Compiler and linker flags

The browser target compiles with Titan's own Emscripten settings, the Lua
defines from the build record, and three target defines that C headers can
test: `TITAN_TARGET_BROWSER=1`, `TITAN_COROUTINE_STACK_SIZE=262144`, and
`MCO_ASYNCFY_STACK_SIZE=65536`. `-I`, `-D`, and `--cflag` options and
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

Titan also owns the link settings that the runtime depends on: Asyncify, the
longjmp mode, the stack and memory sizes, the program lifecycle and exports,
the filesystem layer, assertions and stack checks, and the three target
defines. Other Emscripten `-s` settings may be passed with `--ldflag`, but a
compile or link flag that sets, unsets, or negates one of these is rejected,
as are `--no-entry` and `--js-library`:

```text
browser link profile owns option -sASYNCIFY=0
```

## Limits

A browser program runs with these fixed sizes:

| Resource | Size | When it runs out |
| --- | --- | --- |
| Main C stack | 1 MiB | Deep Lua recursion raises Lua's ordinary C-stack overflow error. A deeper overrun in compiled code stops the program with an engine trap or abort, never a silent overwrite. |
| Coroutine C stack | 256 KiB per coroutine (2 MiB natively) | As for the main stack, inside the coroutine. |
| Asynchronous-wait state | 64 KiB, for the main context and for each coroutine | A wait or coroutine switch from a deeper call stack stops the program with an engine trap or abort. |
| Linear memory | 16 MiB initially, growing to at most 2 GiB | Allocation fails with Lua's ordinary out-of-memory error; creating a coroutine fails with an ordinary Titan error. The instance stays usable. |

Coroutine stacks are allocated in full when a coroutine is created, and memory
that the program has grown never shrinks, although freed blocks are reused.
At 256 KiB per coroutine, the 2 GiB limit holds several thousand live
coroutines.

## Current limits

* The browser standard library provides only `test`, `coroutine`, and `gc`.
  `async`, timers, files, networking, `lua`, `peg`, and the other standard
  modules are not available yet.
* Programs run under Node and headless Chrome or Chromium only. Firefox and
  WebKit are not supported yet.
* Traces show Lua frames only (see [traces](#traces)).
* A loader instance runs `main` once; sinks must be synchronous.
* Only Linux and macOS hosts are supported; `Makefile.win` offers neither
  `lua-browser` nor `browser-sdk`.
* The language server analyzes the host target only.
* Native source coverage (`--coverage` and its backend/report options) is not
  supported for the browser target.

See [the browser target](../implementation/browser-target.md) in the
implementation manual for the descriptor, the SDK, the link profile, the
entrypoint, the loader and runner mechanics, and the evidence behind the
design.
