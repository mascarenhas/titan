# Compiling for the browser target

`titanc --target browser` compiles Titan programs, tests, and libraries to
WebAssembly with Emscripten, to run inside web pages and web applications. A
program becomes three files that belong together: an ES module, its
WebAssembly binary, and its extended source map. A page runs the program
through Titan's JavaScript [loader](#the-loader-api). For testing, the
command-line runner [`titan-browser-run`](#testing-with-titan-browser-run)
runs the same files under Node and headless Chrome.

## A first web page

This walk-through builds a small Titan program, embeds it in a web page, and
opens the page in a browser. It assumes that the toolchain from
[prerequisites](#prerequisites) is installed, with Emscripten active in the
shell, and that `PREFIX` names the Titan installation that holds the browser
SDK.

The program, `hello.titan`, prints a greeting and three counting lines:

```titan
foreign import "stdio.h"

local function greeting(name: string): string
  return "Hello, " .. name .. ", from Titan!"
end

function main(args: {string}): integer
  ffi.puts(greeting(args[1] or "web page"))
  for count = 1, 3 do
    ffi.puts("Titan counts " .. count)
  end
  return 0
end
```

The browser standard library has no `io` module (see [the browser standard
library](#the-browser-standard-library)), so the program writes its lines with
C's `puts` through the [C FFI](ffi.md). Whatever a program writes to standard
output or standard error reaches the page through the loader's output sinks.

Build it for the browser:

```sh
titanc --target browser -o out hello
```

This writes `out/hello.mjs`, `out/hello.wasm`, and `out/hello.wasm.map`: the
ES module, its WebAssembly binary, and its source map, next to the compiler's
intermediate files. Copy the three files into a folder `site/` that will hold
the page:

```sh
mkdir -p site
cp out/hello.mjs out/hello.wasm out/hello.wasm.map site/
```

The generated ES module already contains Titan's loader. There is no runtime
JavaScript file to copy from the SDK: the three generated files are the whole
program image.

Then write the page, `site/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Hello from Titan</title>
</head>
<body>
  <pre id="output"></pre>
  <script type="module">
    import create from "./hello.mjs";

    const output = document.getElementById("output");
    const text = new TextDecoder();
    function show(chunk) {
      output.textContent += text.decode(chunk, { stream: true });
    }

    const instance = create({ stdout: show, stderr: show });
    try {
      const result = await instance.run(["browser"]);
      output.textContent += `(${result.kind}, status ${result.status})\n`;
    } finally {
      await instance.dispose();
    }
  </script>
</body>
</html>
```

The module script imports the program's default `create(options)` function.
Each output sink receives copied `Uint8Array` chunks; this page decodes them
as UTF-8 and appends the text to the `<pre>` element. `run(["browser"])`
initializes the image and runs `main` with `args[1] == "browser"`, resolving to
a `returned` result with status 0. The state remains alive after `main`
returns. **Always await `dispose()` in `finally`**: it closes Lua, runs state
finalizers, drains their output, and releases the image. The
[loader API](#the-loader-api) describes every option and result.

Browsers do not load module scripts or WebAssembly into a page opened from a
`file://` URL, so serve the folder over HTTP. Any static web server works if it
sends `.mjs` files with a JavaScript content type, such as `text/javascript`,
which browsers require for module scripts. It should also send `.wasm` files
as `application/wasm`; with another type the program still runs, but the
browser console shows `wasm streaming compile failed` and the browser compiles
the binary only after downloading all of it. Python's built-in server is one
example:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory site
```

Open <http://127.0.0.1:8000/>. The page shows:

```text
Hello, browser, from Titan!
Titan counts 1
Titan counts 2
Titan counts 3
(returned, status 0)
```

To deploy the page, serve `hello.mjs`, `hello.wasm`, and `hello.wasm.map`
together with it. No external loader is required. The source map lets errors
report Titan source files and lines (see [traces](#traces)).

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

* **Node 26 or newer with WebAssembly JSPI.** `titanc` uses it for the
  executing check before publishing browser libraries or linking their
  archives, and `titan-browser-run` uses it for command-line execution.
  Set `TITAN_NODE` explicitly or put this Node on `PATH`. Emscripten 6.0.13's
  bundled Node 24 is for its own tools, not for Titan browser images.
* **A JSPI-capable browser.** The supported floor is Chrome/Chromium 137,
  Firefox 153, and Safari 27. The loader checks for
  `WebAssembly.promising` and `WebAssembly.Suspending`; there is no legacy
  backend or experimental-flag requirement. `titan-browser-run` drives
  headless Chrome/Chromium, including Chrome for Testing's *headless shell*.
  Set `TITAN_CHROME` to its executable or put it on `PATH` as
  `google-chrome`, `google-chrome-stable`, `chromium`, `chromium-browser`,
  or `chrome-headless-shell`.
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

### Wasm-EH longjmp contract

Browser Lua, Titan's runtime, generated C, and authored C helpers use
`-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1` on every compile and
link. This pins Emscripten 6.0.13's legacy Wasm exception encoding; that
toolchain labels Wasm longjmp experimental. Rebuild the browser Lua and SDK
when moving from a JavaScript-SJLJ installation: setting only a final link
flag cannot convert old objects. The existing record and descriptor identities
distinguish the settings without a record-format change.

Wasm-EH protected calls preserve `catch`, `defer`, and coroutine cleanup
across JSPI transfers. The browser C-call limit remains 100. Engine traps
and engine stack overflow remain fatal, not catchable Titan errors. Native
targets are unchanged.


The fork's own `install-browser` target does the same work without the
reuse check, and is the command that the compiler's diagnostics name. From
a source archive of the matching fork commit, which has no Git metadata, also
pass its 40-character commit as `FORK_REVISION=<commit>`. See [Installing
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

It uses the installed `titanc --target browser` and needs Node 26 or newer
with JSPI because it publishes the standard library through the ordinary
executing check. It uses nonempty `TITAN_NODE`, otherwise `node` on `PATH`;
it does not substitute emsdk's bundled Node. A refusal says
`browser provider validation requires Node 26 or newer: <reason>; set
TITAN_NODE to a Node 26 or newer executable`. The SDK installs into
`lib/titan-browser/0.6/` under the Titan installation root:

| File | Contents |
| --- | --- |
| `libtitan.a` | the browser runtime archive |
| `libtitan-lpeglabel.a` | the PEG engine, built for the browser; `make browser-sdk` links it into `titan.a` |
| `titan.a` | the [browser standard library](#the-browser-standard-library): fourteen standard modules and the PEG engine they use |
| `titan-browser.mjs` | the [loader](#the-loader-api) source embedded by the compiler into each generated image; pages do not copy or import it separately |
| `titan-browser-library.js`, `titan-browser-bridge.js`, `titan-browser-trace.js` | the Emscripten JavaScript libraries that Titan-entry browser images link (channels, protected bridge imports, admission, eager trace-map loading, and stack capture) |
| `titan-browser-run`, `titan-browser-run.mjs`, `titan-browser-node-worker.mjs`, `titan-browser-page.mjs` | the [test runner](#testing-with-titan-browser-run) |
| `sdk-digests` | content digests of the browser SDK, written last |

The directory is a sibling of the native `lib/titan/0.6/`, never inside it,
and native builds never search it. `make browser-sdk` works into an empty
directory. Like `make lua-browser`, it needs Emscripten; no native Make target
does. In a
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
   step 4 and checked to use no libuv, OpenSSL, llhttp, or SQLite header,
   archive, or symbol; and
6. it writes the SDK digest manifest last.

A missing browser SDK is reported only when a program or test is linked or a
library is published, and then names the command that installs it:

```text
browser SDK is incomplete: missing "/home/me/.local/titan/lib/titan-browser/0.6/libtitan.a"; run 'make browser-sdk PREFIX=/home/me/.local/titan'
```

When `ROCKS_TREE` is set and not empty, the command also passes `ROCKS_TREE=<tree>`.
Compiling objects never needs the SDK.

## Selecting the target

Pass `--target browser` (or `-T browser`, or `--target=browser`), or set
`TITAN_TARGET=browser` in the environment. The option wins over the variable.
See [choosing the target](target-source-selection.md#choosing-the-target--t--target-and-titan_target)
for the complete vocabulary. Only the `titanc` command reads `TITAN_TARGET`;
the compiler library and the language server do not. Editors analyze the host
target only.

Source files for the browser use the `browser` label described in [target
source selection](target-source-selection.md): `name.browser.titan` is
selected before `name.titan`, and `name.native.titan` or an OS variant is
never selected.

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

## Build profiles

The browser target follows the same `TITAN_BUILD_PROFILE` as native builds
([native build profiles](build-profiles.md)): `production`, the default, or
`validation`. The profile decides how much the C compiler and Emscripten's
WebAssembly optimizer may restructure the code, and therefore which frames a
[trace](#traces) shows:

| Profile | Object compilation | Link | Frames in traces |
| --- | --- | --- | --- |
| `production` | `-O3`, without `-fno-inline` or `-fno-optimize-sibling-calls`, so functions can be inlined | `-O3`, which also runs Emscripten's WebAssembly optimizer, including its own inlining | the frames that survive optimization, as in a native production build |
| `validation` | `-O1 -fno-inline -fno-optimize-sibling-calls` | `-O1`, without the WebAssembly optimizer | every frame |

In both profiles, objects keep their line tables (`-gline-tables-only`), the
link writes the source map and keeps the WebAssembly `name` section
(`-gsource-map -g2`), and Titan extends the map as described in
[traces](#traces). Every Titan frame that a trace shows is therefore
attributed to its `.titan` file and line as that section describes, and a
deployed program needs its `<stem>.wasm.map` next to `<stem>.wasm`, in either
profile. The implementation manual's [historical measurement
table](../implementation/browser-target.md#measurements) records pre-JSPI
sizes, link times, engine ceilings, and micro-benchmarks. Those results do not
predict the current backend's image sizes or relative profile speeds.
[Traces](#traces) shows what an optimized trace looks like.

**Test images keep their frames.** Under `production`, `titanc --test`
compiles each test module (a module that declares discovered `test_`
functions) with `-fno-inline -fno-optimize-sibling-calls`, and links the image
without the WebAssembly optimizer's inlining and without its merging of
identical functions, which would otherwise report one function's frame under
another function's name. The frames of a test module, and the
[`location`](standard-library-test.md#location-and-failure-traces) results
built on them, are therefore exact under both profiles. This is the browser
form of native `--test`'s frame preservation
([compilation](standard-library-test.md#source-first-resolution-and-runner-generation)).
Other modules keep the profile's own flags: production dependencies compiled
from source, the generated runner, and the SDK's `titan.test`. A function
inlined inside one of those modules can still be missing from a test's trace.

**The SDK and output directories.** `make browser-sdk` compiles the browser
runtime and standard library under the `TITAN_BUILD_PROFILE` in effect when it
runs (`production` unless set), and every browser build links those archives
as installed, as native builds link the installed standard provider. Install
the SDK under the profile you build with, in a separate prefix for each
profile as for native builds. The profile is part of the browser target's
configuration, so objects and images built under one profile are never reused
by a build under the other; keep one output directory for each, such as
`out-browser/` and `out-browser-validation/`.

## What you can build

A browser build links a program (the module `app` defines `main`) or a test
image (`--test`), publishes a library archive (no `main`), or compiles objects
only (`-c`):

```sh
titanc --target browser -o out --exe out/app.mjs app
titanc --target browser --test -o out --exe out/app_tests.mjs app.calc_test
titanc --target browser --output out-browser app.widgets
titanc --target browser --output out-browser -c app.widgets
```

### Programs

A build whose root module defines `main` links a program. The result is always
three files that belong together: the ES module, its WebAssembly binary, and
its extended source map, all with the same stem. Without `--exe`, the program
uses the native program's path below the output directory with `.mjs` added, so
`titanc --target browser -o out app` writes `out/app.mjs`, `out/app.wasm`, and
`out/app.wasm.map`. An explicit `--exe` must end in `.mjs`:

```text
browser executable output "out/app" must end in .mjs
```

Titan publishes the three files together: a failed link leaves the previous
files in place, so a partial or unextended map is never published.
`--incremental` reuses an unchanged set without relinking. When a web server
serves the program to a browser page, it must serve `app.wasm.map` alongside
`app.wasm` so that the runtime can load the trace map during module
initialization (see [traces](#traces)).

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
for [library archives](#library-archives), so linking also needs Node 26+.

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
count. [Testing with `titan-browser-run`](#testing-with-titan-browser-run)
describes the runner.

Under the default `production` profile, a test image still keeps the frames
of its test modules; see [build profiles](#build-profiles).

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
second step needs Node 26 or newer with JSPI and the browser SDK:

```text
browser provider validation requires Node 26 or newer: node not found (TITAN_NODE unset; not on PATH); set TITAN_NODE to a Node 26 or newer executable
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

### Objects

`-c` compiles each Titan module to a WebAssembly object with its metadata, and
`--c-source FILE` compiles C helpers with the same Emscripten settings.
`--incremental` reuses unchanged objects exactly as for native builds.

## The loader API

Every generated program or test ES module exports one default
`create(options = {})` function. Import that function directly; the raw
Emscripten factory and Module are private. The same image works over HTTP, in
a bundler such as Vite, and in Node 26+:

```javascript
import create from "./out/app.mjs";

const instance = create({
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

The instance has the following methods:

* `initialize(): Promise<void>` instantiates Wasm, creates the persistent Lua
  state, and runs the image's module initializers, but not `main`. Repeated
  calls share one initialization promise. An ordinary initializer error
  rejects with captured Titan error bytes and trace and prints its standard
  report once. The partial state still needs disposal.
  With `requireTrace: true`, a missing or invalid map fails initialization
  before Lua is created or any initializer runs. This failure has message
  bytes and status 1, but no Titan trace because no Titan code ran.
* `run(args = [])` initializes when needed, then invokes `main` once. Strings
  in `args` are UTF-8 encoded; `Uint8Array` arguments are copied byte for byte.
  It resolves `{kind, status, bytes}`, with `"returned"` or `"failed"`, a
  signed 32-bit status, and copied error bytes (empty for a returned run).
  Ordinary initializer or main failure is a failed/status1 result, not a
  fatal-engine rejection. A prior initializer failure is reused without a
  second report.
* `call(callable, ...args)` invokes a callable exported by `titan.browser`.
  It requires successful initialization and remains available after main
  returns. Both this method and `callable.call(...args)` resolve one dense result
  Array: `[]` for zero results, `[value]` for one, and the complete tuple for
  many. A nil result is `null`, including trailing nils. Promise and thenable
  JSHandle values remain untouched elements of that Array; the call does not
  await or handle their rejections. Destructure a result explicitly, then
  separately await it if that is what the application intends.
* `notify(callable, ...args)` synchronously snapshots and enqueues one
  notification without entering Wasm. It copies byte arrays and keeps raw
  JavaScript values by reference. It does not allocate Wasm buffers or handle
  slots. Logically released arguments are rejected again before delivery;
  released or closed targets retire without delivery.
* `drain()` requires successful initialization and delivers one detached FIFO
  batch. A handler error is reported as a `"callback"` event through
  `onNotificationError`, with its captured Titan data, and later notifications still run. Notifications
  enqueued by handlers belong to the next batch. There is no implicit loop or
  scheduling policy.
* `dispose()` closes application admission immediately and returns one stable
  promise. An accepted native entry physically retires before Lua closes.
  Requests and queued work are retired according to their ownership contract.
  Main's lexical defers have already run at return; state finalizers run here.
  All state-owned handles become invalid. A disposed instance never revives.

`initialize`, `run`, `call`, `drain`, and `dispose` always return promises,
including admission errors. Calling `call` or `drain` before initialization
does not initialize implicitly. A callable wrapper also has `call(...args)`
and idempotent, synchronous logical `release()`. Wrappers belong to one
instance and one Lua state; another instance cannot use them.

**Exclusive entry.** One logical operation owns the instance from argument
validation through all protected C entries and output flush. Promise
microtasks used by coroutine switching or GC cleanup do not release that
admission. Immediate reverse calls during a binding or output sink reject
with `TITAN_BROWSER_REENTRY`; they do not synchronously throw into the
binding's `try/catch`. Observe the rejected promise, or use `notify`. A sink
never runs from a Wasm import or an internal JSPI handoff. Independent
instances can progress concurrently.

Options are:

| Option | Contract |
| --- | --- |
| `stdout`, `stderr` | Functions receiving copied `Uint8Array` chunks; absent sinks discard the stream. A sink may return a promise. |
| `stdin` | A byte source receiving a requested capacity and returning copied bytes through a tracked read; absent input is a bridge error, not a prompt or hidden filesystem. |
| `locateFile(name, directory)` | Resolves both Wasm and its extended map; defaults retain recognizable `new URL(..., import.meta.url)` assets for bundlers. |
| `requireTrace` | Boolean, default `false`. Require a ready trace map after Wasm instantiation and before creating Lua or running initializers; failure follows the ordinary saved-initialization-failure contract. |
| `bindings` | Explicit per-instance JavaScript values/functions available to `titan.browser`; no global-name lookup or eval. |
| `onNotificationError({kind, operation, error})` | Observes errors Titan cannot return to a caller: failed notification callbacks and secondary or callerless cleanup failures. A host Promise rejection instead goes to its mandatory typed failure callable. |
| `requestDrain()` | Coalesced announcement of queued work at a complete logical safe point; the application chooses when to call and await `drain()`. |
| `onEngineFailure({kind, cause})` | Observes a terminal engine failure after the instance has been poisoned. Observer exceptions cannot replace that failure. |

The notification-error event's `kind` is `"callback"` or `"cleanup"`.
`operation` identifies `initialize`, `run`, `call`, `drain`, `dispose`, or
`notify`; a failed work announcement uses `requestDrain`, and callerless
physical callable retirement uses `release_callable`. In-operation cleanup
uses the containing public operation's name. A physical release failure is
reported once, without retry; state close remains its retirement fallback.

**Output.** Each stream has one FIFO and at most one actual sink invocation in
flight. The loader flushes only after all entries in the containing operation,
including unterminated C-stdio tails. Later chunks continue after a sink
throws or rejects. An otherwise successful operation rejects with its first
cleanup failure; secondary failures are reported once through
`onNotificationError`. If the operation already failed in Titan, its captured
message and trace remain primary while deliverable output and deferred
retirement are still attempted. There is no cross-stream ordering guarantee.
A completion-carrying write receives its own outcome. A C-only append failure
is returned by the operation that flushes it and stays pending for the next
completion-carrying write, or disposal if no such write consumes it. Empty
flushes and unrelated output-free operations do not fail again with that
pending error, and observing it does not report the same failure twice.

Disposal interrupts a pending sink by detaching its continuation and making
that stream terminal; it cannot overlap the old sink with a finalizer write.
An operation whose failure was already captured keeps that failure if disposal
interrupts its report flush; the interruption is reported once as cleanup,
even when both streams are interrupted. Only an operation not yet failed
rejects `TITAN_BROWSER_DISPOSED`. Disposal retains its own output/error outcome,
including `TITAN_BROWSER_DISPOSED` for interrupted or discarded buffered bytes.
Normal `await run(); await dispose()` does deliver finalizer output. After Lua and
borrowed native owners retire, finalizer bytes move to a JavaScript-only
drain. Even a never-settling sink and an externally retained disposal promise
do not keep the disposed image alive through bridge-generated captures.
Caller closures that independently retain the instance are outside this rule.

**Host work.** A tracked request explicitly chooses detachable work
(`{kind: "detachable", promise, cancel?}`) or guaranteed-terminal retained
ownership (`{kind: "retained", promise, cancel?}`). Never-settling work must be
detachable. A listener uses
`{kind: "listener", subscribe(emit) { return unregister; }}`. Its synchronous
events only enqueue. Cancellation signals the host; it is not proof that
retained work has physically retired. Late and duplicate settlements never
enter Lua after cancellation, release, state close, or disposal.
The bridge reserves the request owner before invoking its host source or
accepting completion-carrying output. If that reservation fails, it does not
start the source, register the listener, or append the output bytes.
Start/listen and completion-carrying byte I/O take both a success callable and
a mandatory failure callable. Failure receives `(message: string,
thrown: JSHandle)`: the message is copied bytes and the handle preserves the
exact rejected JavaScript value. Both outcomes enqueue and use protected
delivery; a Promise rejection is not merely logged to an observer.

**Observation and errors.** `instance.trace` is a fresh frozen `{state,
reason}` snapshot, including before initialization. It preserves the last
map state and reason after ordinary or poisoned disposal without retaining
the Module or mutable trace internals. Ordinary Titan call errors retain copied
message bytes and their original trace; a later valid call still works.
`TITAN_BROWSER_STATE` rejects premature calls and a second main;
`TITAN_BROWSER_DISPOSED` rejects work after disposal begins;
`TITAN_BROWSER_HANDLE` rejects stale or foreign identities; and
`TITAN_BROWSER_SINK` identifies the failed stream. `TITAN_BROWSER_CAPABILITY`
means JSPI is unavailable. Abort, trap, or corrupted completion identity
poisons the instance; all later application entries reject that saved failure.
Disposal then drops references without entering broken Wasm.
The test runner reports observed aborts and traps even if a test catches their
operation rejection. A completion-protocol error that the test explicitly
handles stays local to its poisoned instance; if the operation rejection
escapes, the runner reports a harness failure.

## Testing with `titan-browser-run`

`titan-browser-run` is the test runner for browser images. It runs a program
or test image from the command line, under Node 26 or newer or in headless Chrome or
Chromium, through the same loader that a page uses, and turns the result into
an exit status, so that test suites and continuous integration can check
browser builds. Web pages do not use it.

```sh
titanc --target browser -o out --exe out/app.mjs app
titan-browser-run out/app.mjs -- first second
```

The first command builds `out/app.mjs`, `out/app.wasm`, and `out/app.wasm.map`
from the module `app`, which defines `main`. The second runs the program under
Node with the arguments `first` and `second`, copies its output byte for byte,
and exits with its status. A test image built with `--test` runs the same way
(see [tests](#tests)).

`titan-browser-run` is installed in the SDK directory,
`PREFIX/lib/titan-browser/0.6/titan-browser-run`. Put that directory on `PATH`
or call it by path:

```text
titan-browser-run [--engine node|chromium] [--timeout MS] [--grace MS]
                  [--chrome PATH] [--cdp pipe|port] [--root DIR]
                  [--allow-degraded-trace] [--js-test] FILE [-- ARG...]
```

`FILE` is the program's `.mjs`. Everything after `--` is passed to `main`
unchanged. The tool writes the program's stdout and stderr bytes to its own
stdout and stderr exactly, and writes its own messages, all starting with
`titan-browser-run:`, to stderr only.

| Option | Meaning |
| --- | --- |
| `--engine node` | Run under Node 26 or newer with JSPI (the default). |
| `--engine chromium` | Run in a new headless Chrome or Chromium. |
| `--timeout MS` | Wall-clock limit for the whole run, in milliseconds; default 30000. |
| `--grace MS` | Time to keep watching after the program completes, to catch late traps and aborts; default 1500. |
| `--chrome PATH` | The Chrome or Chromium executable; overrides `TITAN_CHROME`. |
| `--cdp pipe\|port` | How the tool controls Chromium: a private pipe (the default) or a loopback DevTools port. |
| `--root DIR` | The directory served to the engine; defaults to `FILE`'s directory, and must contain `FILE`, its `.wasm`, and (unless `--allow-degraded-trace` is set) its `.wasm.map`. |
| `--allow-degraded-trace` | Permit missing, malformed, or mismatched trace maps by creating images with `requireTrace: false`; otherwise map failure is an ordinary initialization failure before Lua or main, not an infrastructure failure. |
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
| 76 | A loader output sink failed. The runner's own sinks do not fail, so in practice this comes from the sinks of a `--js-test` module. |

A program's own status can coincide with 70 to 76. The stderr message tells
the cases apart: an infrastructure failure always prints one, such as
`titan-browser-run: timed out after 30000 ms` or `titan-browser-run: abort:
<reason>`, while a completed program adds nothing of its own. Test statuses 0,
1, and 2 never coincide with them.

A missing or wrong Node is reported before anything starts, with exit 75:

```text
titan-browser-run: Node 26 or newer is required (node not found (TITAN_NODE unset; not on PATH))
titan-browser-run: Node 26 or newer is required ("/usr/bin/node" reports v24.19.0; expected Node 26 or newer)
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

Main completes when it returns or fails, and its output (including an
unterminated last line) is delivered then. The state and callable handles
remain alive until explicit disposal. The runner awaits disposal and its
finalizer output before reporting completion. Output is binary: NUL, `0xFF`,
and invalid UTF-8 pass through unchanged. Bridge stdin uses the explicitly
supplied byte source; no source is installed by the command-line runner.

### Traces

When a web page or application initializes a browser image (or when tests run
it through `titan-browser-run`), the runtime eagerly loads `<stem>.wasm.map`
before `main` or any module initializer runs, verifies that its embedded build
identity matches the instantiated `.wasm`, and builds an in-memory lookup
index. Nothing is fetched or awaited when an error is raised or when
`titan.backtrace()` is called.

On **Chromium, Chrome, Firefox, and Node**, browser tracebacks have the same
unified Titan/Lua contract as native builds:

* Compiled Titan frames appear as `<basename>:<line>: in <display name>`,
  using the selected physical `.titan` filename (`name.browser.titan`
  included) and Titan display names (`m.func`, `m.Record:method`,
  `m.Record.static`, or `anonymous function at m.titan:12`).
* If a trace captured in an independent child Lua state includes outer native
  frames from a module initialized only in the parent state, those outer frames
  fall back to their C symbol name (or `?` when no symbol is known), as on
  native hosts.
* If a Titan frame's program counter has no line mapping inside its function
  body, the frame uses the no-line form `<basename>: in <display name>` (with
  the function's declaring `.titan` basename, or `?` when none is known), never
  a synthetic `:0:` line.
* Lua frames (`source:line: in name` or `source: in name`), genuine Lua C
  functions (`[C]: in name`), and `(...tail calls...)` interleave with
  compiled Titan runs in innermost-to-outer call order. Entry wrappers,
  runtime frames, Lua core/library C frames, and unmapped helper exports are
  filtered out, and an unmapped helper adjacent to a Titan function never
  inherits a Titan line.
* `titan.backtrace()`, the `traceback` local in a `catch` block, bare `raise`
  re-throwing, caught-trace clearing, and coroutine trace propagation and
  append behave as on native hosts, including across coroutine yields and
  resumptions.

**Optimized frames.** As in a native production build, a `production` image
has no frame for a function that the optimizer inlined into its caller. A
frame that does appear is still exact, and an inlined function's line is
reported under the name of the function that absorbed it. Titan's own trace
fixture `trace_uncaught.titan` shows the difference:

```titan
foreign import "stdio.h"

local function uncaught_leaf()
  raise "trace-uncaught-original"
end

local function uncaught_middle()
  uncaught_leaf()
end

function main(_args: {string}): integer
  defer do
    ffi.fputs("TRACE uncaught cleanup=1\n", ffi.stderr)
    ffi.fflush(ffi.stderr)
  end
  uncaught_middle()
  return 0
end
```

Built with `validation`, it writes this to stderr:

```text
TRACE uncaught cleanup=1
trace_uncaught: trace-uncaught-original
stack traceback:
	trace_uncaught.titan:4: in trace_uncaught.uncaught_leaf
	trace_uncaught.titan:8: in trace_uncaught.uncaught_middle
	trace_uncaught.titan:16: in trace_uncaught.main
	[C]: in ?
```

Built with `production`, where `uncaught_middle` was inlined into `main`, it
writes:

```text
TRACE uncaught cleanup=1
trace_uncaught: trace-uncaught-original
stack traceback:
	trace_uncaught.titan:4: in trace_uncaught.uncaught_leaf
	trace_uncaught.titan:8: in trace_uncaught.main
	[C]: in ?
```

Line 8, the call inside `uncaught_middle`, now appears under `main`, and
`main`'s own line 16 is gone. Whatever a production trace shows keeps its
exact file and line (or the no-line form on WebKit and Safari, below), Lua
frames and the markers below keep their places and order, and internal entry
wrappers and C symbol names never appear. Build with `validation` when a trace
must show every frame; [test images](#build-profiles) keep the frames of their
test modules under both profiles.

**WebKit and Safari reduced fidelity.** On WebKit and Safari, where
JavaScriptCore's `Error.stack` reports WebAssembly frames by function index
without a bytecode offset, browser traces provide reduced, function-level
fidelity: Titan frames appear in the same merged order with Lua frames and with
the same Titan display names, rendered in the no-line form
`<basename>: in <display name>`.

**Depth limits and truncation.** Browser captures have a 512-record WebAssembly
capacity. Firefox's SpiderMonkey also caps synchronous captures at 128 frames;
current WebKit can exceed the 100-frame limit of older releases. Engine
versions can supply shorter stacks, independently of JavaScriptCore's
function-level fidelity. Any host `Error.stackTraceLimit` is preserved across
the capture. When
a trace is cut short by the 512-frame capacity, by a host
`Error.stackTraceLimit` that cannot be raised, or by the engine's capture
limit, the trace ends with one final frame line:

```text
(...native frames truncated...)
```

**Deploying `.wasm.map` and degraded mode.** A web server serving a browser
image must serve `<stem>.wasm.map` next to `<stem>.wasm` (or map both through
`locateFile`). If `<stem>.wasm.map` cannot be loaded, is malformed, or does not
match the instantiated `.wasm` image, Wasm instantiation logs one console
warning (`Titan browser trace: <reason>`). By default an embedding permits
degraded mode; with `requireTrace: true`, initialization instead fails before
Lua or any module initializer runs. In permitted degraded mode, every trace
generated by that instance contains the Lua frames plus one marker line:

```text
(native Titan frames unavailable: trace map not loaded)
```

To catch deployment and staging mistakes in tests, `titan-browser-run` sets
`requireTrace: true` for both direct images and images created by `--js-test`
modules, unless `--allow-degraded-trace` is supplied. A direct image's failed
initialization becomes its saved failed/status1 run result, without entering
main or inventing a Titan traceback.

**Host `Error.prepareStackTrace` and capture failure.** The runtime never calls
a host `Error.prepareStackTrace` callback or invokes property getters or
setters on `Error`. When `Error.prepareStackTrace` cannot be neutralized
safely, or when an unexpected error or nested trace attempt occurs while a
trace is already being built, the runtime skips reading `.stack` and emits the
Lua-only trace with one marker line:

```text
(native Titan frames unavailable: capture failed)
```

The availability and truncation markers are ordinary frame lines without an
error message, header, or tab indentation, and remain part of a pinned trace on
bare `raise`.

## The browser standard library

The browser SDK's `titan.a` holds fourteen standard modules that need no libuv
or other native-only library: thirteen shared modules compiled from the same
sources as the native standard library, plus the browser-only `titan.browser`:

| Module | Contents |
| --- | --- |
| [`coroutine`](coroutines.md) | stackful coroutines |
| [`gc`](standard-library-gc.md) | weak Maps, ephemerons, finalizers, and collector control |
| [`iteration`](standard-library-iteration.md) | Map and Array iteration |
| [`math`](standard-library-math.md) | numeric functions and random numbers |
| [`string`](standard-library-string.md) | byte strings, formatting, packing, writers, and regular expressions |
| [`peg`](standard-library-peg.md) | parsing expressions |
| [`url`](standard-library-url.md) | URL parsing and construction |
| [`path`](standard-library-path.md) | lexical paths |
| [`reflect`](standard-library-reflect.md) | runtime reflection |
| [`json`](standard-library-json.md) | JSON encoding and decoding |
| [`protobuf`](standard-library-protobuf.md) | Protocol Buffers encoding and decoding |
| [`transfer`](standard-library-transfer.md) | transfer policies and native message packets |
| [`test`](standard-library-test.md) | the test API and the native test runner |

Each of these modules is complete. Every public declaration, including the raw
C functions `protobuf.write_resource_index`,
`protobuf.write_resource_index_bytes`, `transfer.copy_message`,
`transfer.discard_message`, and `transfer.transfer_load_module`, has the same
signature as on a native target and behaves as its chapter describes, apart
from the target facts [below](#what-the-browser-target-changes). No member
raises an "unavailable" error or returns a stand-in value. `transfer` encodes
and decodes packets within one instance; the modules that carry packets to
another Lua state or thread are not available.

### Modules that are not available

The other standard modules are absent from the browser target: `uv`, `async`,
`timer`, `io`, `fs`, `net`, `ssl`, `http`, `websocket`, `os`, `lua`,
`sqlite3`, and `thread`. Each of them uses libuv, directly or through its
imports. Their sources exist only as native variants (such as
`titan/os.native.titan`; see [target source
selection](target-source-selection.md)), so a browser build finds no source and
no browser archive for them. Importing one fails with the ordinary
missing-module error, the same as for a module that does not exist:

```text
module 'titan.os' not found
```

There are no stand-in modules for them, and their folder contributors, such as
`titan.uv.tcp`, are not importable on their own. A test module that imports one
of them cannot be built into a browser test image either; keep such cases in
native-only test modules.

Browser versions of `async`, `timer`, `io`, `os`, `lua`, and `http` are
planned, and `fs` is planned together with a browser file system. Until then,
a program writes its output through C's `stdio.h`, as in [the first web
page](#a-first-web-page), and the test runner reports through it too. Either
way the output reaches the loader's sinks byte for byte ([status and output
semantics](#status-and-output-semantics)).

### What the browser target changes

The browser modules follow the target's C facts and its fixed limits:

* **C sizes.** `size_t` and C `long` are 4 bytes, so `string.pack`'s `T`, `l`,
  and `L` options use 4 bytes; `j` and `J` (`lua_Integer`) stay 8 bytes, and
  native byte order is little endian.
* **`long double`.** `printf`'s `%L` conversions format C `long double`
  values with their full precision instead of narrowing them to `double`.
  [`reflect` projections](standard-library-reflect.md) and `protobuf` and
  `transfer` fields carry such values as hexadecimal text, which therefore
  reads back equal to the original. The exact spelling of that text comes from
  the target's C library and is not guaranteed to match a native one.
* **Locale.** The browser's C library uses the C locale's numeric conventions
  whatever `setlocale` selects: the decimal point is always `.`.
* **Paths.** `path` uses POSIX rules: `path.separator` is `/` and
  `path.volume` always returns an empty string.
* **Random numbers.** `math` seeds its generator automatically from the C
  clock functions when it initializes, as on a native target. Explicit seeds
  produce the same sequence as on a native target.
* **Coroutines.** Each coroutine has a 256 KiB C stack instead of 2 MiB, so
  deep recursion inside a coroutine can exhaust its stack sooner. The number
  of live coroutines also depends on the program's other memory use
  ([limits](#limits)).
* **Nesting.** `protobuf`, `transfer`, and `json.encode` use the same library
  nesting policies as native targets ([nesting limits](#nesting-limits)).

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
defines from the build record, and two target defines that C headers can
test: `TITAN_TARGET_BROWSER=1` and `TITAN_COROUTINE_STACK_SIZE=262144`.
The [library nesting policies](#nesting-limits) need no browser-specific
defines. `-I`, `-D`, and `--cflag` options and
`TITAN_EXTRA_CPPFLAGS`/`TITAN_EXTRA_CFLAGS` are added after them, as for
native builds. Flags that only make sense for a native target are rejected
rather than ignored:

`-fPIC`, `-fpic`, `-fPIE`, `-fpie`, `-pie`, `-shared`, `-dynamiclib`,
`-rdynamic`, `-pthread`, `-flto` and `-flto=...`, `-ffat-lto-objects`,
`-march=...`, `-mcpu=...`, `-mtune=...`, `-m32`, `-m64`,
`-f[no-]wasm-exceptions`, `-m[no-]exception-handling`,
`-m[no-]legacy-exception-handling`, an `-sSUPPORT_LONGJMP` setting other
than `wasm`, or an explicit `-sWASM_LEGACY_EXCEPTIONS` setting other than 1.
The check includes joined and split spellings, bare settings, and boolean
`NO_` aliases; a bare longjmp setting or `=1` selects the wrong mode.

The check covers `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`,
`TITAN_EXTRA_LDFLAGS`, `--cflag`, and `--ldflag`, and names the source:

```text
browser target does not support TITAN_EXTRA_CFLAGS flag "-flto"
```

Browser tool spawns clear ambient `EMCC_CFLAGS`; deliberate EH overrides through opaque argument channels (`@file`, `-mllvm`, `-Xclang`, or `-Xlinker`) are unsupported and are not parsed by this check.

`-fno-lto` is accepted. Environment settings meant for native builds, such as
`TITAN_EXTRA_CFLAGS=-O0 -fno-lto -march=native`, must be cleared for browser
invocations.

Flags that change the Wasm feature set, such as `--cflag=-msimd128`, are
reported separately from Lua record errors. The diagnostic lists the supplied
compile flags and the actual versus required target features. Remove the
feature-changing flag; reinstalling browser Lua does not repair that mismatch.

Titan also owns the settings that the runtime and the traceback backend depend
on. The [build profile](#build-profiles) owns the optimization level, inlining,
sibling-call optimization, and frame pointers: every `-O` level, every `-g`
flag, `-finline...`, `-foptimize-sibling-calls`, `-fomit-frame-pointer`, and
their `-fno-` forms. Titan also owns `-gline-tables-only` (for object
compilation), `-gsource-map`, `-g2`, and the WebAssembly optimizer's pass list
`-sBINARYEN_EXTRA_PASSES` (for linking), and source `#line` directives
(`--no-line-directives` and `TITAN_NO_LINE_DIRECTIVES=1`), together with
JSPI and its explicit import/export set, the longjmp mode and legacy EH encoding, the stack and memory sizes, the program lifecycle
and exports, the filesystem layer, full-precision `long double` printing,
assertions and stack checks, and the target defines. Other Emscripten `-s`
settings, such as `-sWASM_BIGINT=1`, may
be passed with `--ldflag`, but a compile or link flag that overrides or
negates one of these owned settings is rejected, as are `--no-entry` and
`--js-library`. The message names the build profile, and says whether the
flag came from the compile flags (`--cflag`, `TITAN_EXTRA_CPPFLAGS`,
`TITAN_EXTRA_CFLAGS`) or the link flags (`--ldflag`, `TITAN_EXTRA_LDFLAGS`):

```text
browser production profile owns compile option "-O2"
browser production profile owns compile option "-fno-inline"
browser production link profile owns option -O3
browser production link profile owns option -sBINARYEN_EXTRA_PASSES=--coalesce-locals
browser production link profile owns option -sJSPI=0
browser target owns option --no-line-directives (TITAN_NO_LINE_DIRECTIVES)
```

A `validation` build names `validation` instead.

## Limits

Before publishing a program or test image, or executing a provider's protocol
image, `titanc` enforces these WebAssembly byte bounds:

| Encoded artifact | Maximum bytes |
| --- | ---: |
| One function body, including its local-declaration vector | 7,654,321 |
| Complete `.wasm` image | 1,073,741,824 (1 GiB) |

Equality is accepted. A function's preceding body-length LEB is not part of
its body size; all sections, including custom sections, count toward the
image size. These are the [WebAssembly JavaScript Interface
limits](https://webassembly.github.io/spec/js-api/index.html#limits), not a
promise of available host memory. Engines may exhaust resources, or reject
other WebAssembly limits, below these two bounds.

An oversized function is diagnosed with its Wasm name (or its zero-based
function index when unnamed), measured body bytes and maximum. The diagnostic
also reports the first mapped source location within that body, such as:

```text
browser image function "example_run" (Wasm index 42) body is 7654322 bytes, exceeds maximum of 7654321 bytes; first mapped source "example.browser.titan":12:3
browser image is 1073741825 bytes, exceeds maximum of 1073741824 bytes
```

Source locations come from the final source map, not from interpreting a
mangled function name. An unmapped or native function without source metadata
reports `source unavailable` and the reason; a native function with a mapping
can name its C source. A nonempty `sourceRoot` is shown separately, as recorded
in the map. Rejection happens before publication and leaves any previously
published `.mjs`, `.wasm` and `.wasm.map` unchanged. Titan does not split or
outline an oversized function automatically.

Static byte size does not bound startup memory. The [implementation
measurements](../implementation/browser-target.md#build-time-image-bounds)
record observed startup memory for a large-function program and a complete
standard-library test image on Linux and macOS; they are measurements, not a
startup-memory guarantee.

A browser program runs with these fixed sizes:

| Resource | Size | When it runs out |
| --- | --- | --- |
| Main linear C stack | 1 MiB | Checked C-stack overflow aborts rather than silently overwriting memory. Lua's ordinary C-call limit can reject mixed recursion first. |
| Coroutine linear C stack | 256 KiB per coroutine (2 MiB natively) | The same checks and bounds follow each continuation across suspension and memory growth. |
| Engine continuation stack | Managed by the JSPI implementation | Engine stack exhaustion is fatal; the linear-stack budget does not bound engine memory. |
| Linear memory | 16 MiB initially, growing to at most 2 GiB | A failed native allocation produces the ordinary Lua/Titan allocation error when the state still has enough memory to report it. Engine allocation failures are fatal. |

Linear coroutine stacks are allocated when a coroutine is created. A finished
engine invocation retires before its native allocation can be freed or reused.
Freed linear blocks are reusable, but grown WebAssembly memory never shrinks
back to the host.

Repository validation locates each measured stack and recursion boundary
between a passing lowest sample and a declared failing ceiling, narrowing to
adjacent samples at the declared step size. Those search ceilings only bound
the measurement; they are not additional program limits or portable
recursion-depth guarantees.

### Lua's C-call limit

Lua counts nested calls through its C API and stops them with its ordinary
`C stack overflow` error when the count reaches its limit, `LUAI_MAXCCALLS`.
The browser build of Lua sets that limit to 100; native builds keep Lua's 200.
The original JavaScript-SJLJ implementation used several WebAssembly and
JavaScript frames per level; with Lua's default of 200, nested `pcall` came
close to running V8's stack out before the catchable Lua error. Wasm EH removes
those longjmp trampolines, but the conservative limit remains 100 until all
recursive Lua/C shapes are requalified across engines and build profiles.
The existing tests check that mixed recursion and nested `pcall` past the
limit raise the catchable error. The [implementation
manual](../implementation/browser-target.md#the-browser-c-call-limit) records
the measurements.

The error is an ordinary catchable error: a `catch` block receives
`C stack overflow` with a trace, and the program continues. Each of these
costs one count per nesting level, and they all share the limit:

* mixed recursion, where Titan calls a Lua function that calls back into
  Titan;
* nested `pcall`, metamethods that run other metamethods (an `__index`
  function chain, a recursing `__tostring`), `table.sort` comparators that
  sort again, and `string.gsub` replacement functions that call `gsub` again;
* coroutines: a coroutine resumed from Lua (`coroutine.resume` or a
  `coroutine.wrap` function) starts from its resumer's count, so a chain of
  coroutines that resume coroutines spends it too, and a resume at the limit
  fails with `C stack overflow`;
* parsing: Lua source that a program loads at run time and that nests
  expressions, table constructors, or function bodies about 100 levels deep
  fails to load with `C stack overflow`, where a native build accepts about
  200 levels.

Two more effects appear only close to the limit:

* Titan's error handler and its trace capture can use the last two counts, so
  an error raised within two counts of the limit can be reported as
  `C stack overflow` instead of with its own message.
* Within two counts of the limit, the collector postpones pending finalizers
  (`__gc` metamethods, including [`gc.finalizable`](standard-library-gc.md#finalizers)
  callbacks) until the calls unwind.

### Nesting limits

The browser uses the native library nesting policies:

| Operation | Every target | Error |
| --- | --- | --- |
| `protobuf` encoding, decoding, and `protobuf.schema`; `transfer` packets and structural records/unions | 127 nested levels with the shared 128-level codec budget | `protobuf: nesting exceeds 128 levels` |
| `json.encode` | configured `max_depth` (default 32), with no additional browser cap | `json.Error` with code `limit_exceeded` and message `value exceeds max_depth` |

These limits bound the library traversal, not stack already used by its caller.
Raising a configurable limit cannot make arbitrary engine recursion safe;
engine stack exhaustion is fatal rather than a Titan error.

Everything else keeps its native limits: `json.decode` (its `max_depth`, and
the PEG matching stack, which rejects deeper documents with an ordinary
error), regular-expression nesting (512 groups) and captures (200), and `peg`
grammars (400 matching-stack entries by default and 200 nested captures). A
program that raises `peg.set_max_stack` far above its default also lets
`json.decode` recurse deeper. Recursion that a program writes itself, such as
a walk over a deep record graph with `reflect`, has no library limit; under
`validation` such a walk exhausted the engine stack after about 3,000 levels.

## Current limits

* The browser standard library has [fourteen of the standard
  modules](#the-browser-standard-library). `async`, timers, files, networking,
  `io`, `os`, `lua`, `thread`, and `sqlite3` are not available, so programs
  write output through C's `stdio.h`, as in [the first web
  page](#a-first-web-page).
* Browser images require JSPI-capable Chrome/Chromium, Firefox, Safari/WebKit,
  or Node 26+. `titan-browser-run` drives Node and headless Chrome/Chromium.
* On WebKit and Safari, traces have reduced, function-level fidelity
  (`<basename>: in <display name>`, without line numbers). Browser traces have
  a 512-record WebAssembly capacity, and Firefox also caps synchronous stack
  captures at 128 frames (see [traces](#traces)).
* Lua's C-call limit is 100 instead of native Lua's 200, which also bounds
  nested `pcall`, metamethod, coroutine-resume, and parser depth (see [Lua's
  C-call limit](#luas-c-call-limit)). The four-engine headroom measurements
  used the previous JavaScript-SJLJ lowering; JSPI/Wasm-EH error, GC, and
  unwind qualification covers Node 26.13.0 and Chromium 156, not a new
  four-engine, two-profile recursion-ceiling matrix.
* A loader instance runs `main` once; calls and explicit notification drains
  remain available afterward. Output sinks may return promises.
* Only Linux and macOS hosts are supported; `Makefile.win` offers neither
  `lua-browser` nor `browser-sdk`.
* The language server analyzes the host target only.
* Native source coverage (`--coverage` and its backend/report options) is not
  supported for the browser target.

See [the browser target](../implementation/browser-target.md) in the
implementation manual for the descriptor, the SDK, the browser standard
library's provider, dependency-closure check, and member inventory, the build
profiles and their measurements, the link profile, the browser C-call limit,
the nesting-limit measurements, the entrypoint, the loader and runner
mechanics, and the evidence behind the design.
