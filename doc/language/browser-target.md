# WebAssembly and the Browser Target

`titanc --target browser` compiles Titan programs, tests, and libraries to WebAssembly with `wasi-sdk` and Binaryen so they run in web pages, bundled web apps, and Node 26+. A compiled program consists of an ES module (`.mjs`), its WebAssembly binary (`.wasm`), and its trace table (`.wasm.trace`), plus a source map (`.wasm.map`) for browser developer tools. Pages run the program through Titan's embedded JavaScript [loader](#the-loader-api); command-line tests run the same files through [`titan-browser-run`](#testing-from-the-command-line) under Node or headless Chrome.

## A first web page

This walk-through builds a small Titan program, embeds it in a web page, and serves it to a browser. It assumes the toolchain from [Prerequisites](#prerequisites) is installed, `wasi-sdk` and Binaryen are configured in the shell, and Titan's `bin` directory is on `PATH`. `/path/to/titan` denotes the Titan source checkout.

Write `hello.titan`:

<!-- doc-check: file=hello.titan -->
```titan
local io = import "io"

local function greeting(name: string): string
  return "Hello, " .. name .. ", from Titan!"
end

function main(args: {string}): integer
  io.print(greeting(args[1] or "web page"))
  for count = 1, 3 do
    io.print("Titan counts " .. count)
  end
  return 0
end
```

Build it for the browser into its own output directory:

<!-- doc-check: run -->
```sh
titanc --target browser -o out hello
```

This emits `out/hello.mjs`, `out/hello.wasm`, `out/hello.wasm.trace`, and `out/hello.wasm.map`. The generated ES module embeds Titan's loader, so those first three files are the complete deployable image. Copy them into `site/`:

<!-- doc-check: run -->
```sh
mkdir -p site
cp out/hello.mjs out/hello.wasm out/hello.wasm.trace site/
```

Write the host page `site/index.html`:

<!-- doc-check: file=site/index.html -->
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

    const instance = create({ stdout: show, stderr: show, requireTrace: true });
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

`create(options)` constructs an isolated program instance whose `stdout` and `stderr` sinks receive copied `Uint8Array` chunks. `requireTrace: true` fails initialization if `hello.wasm.trace` is missing or mismatched rather than silently dropping Titan stack frames. `run(["browser"])` initializes the image and calls `main` with `args[1] == "browser"`. Always `await instance.dispose()` in `finally` to close Lua, run finalizers, flush output, and free the image.

### Serving the page

Browsers block ES module scripts and `fetch` requests from `file://` URLs, so serve `site/` over HTTP. Titan includes a small native development server, [`http-dev-server.titan`](http-dev-server.titan). Build it in a separate native output directory:

<!-- doc-check: run -->
```sh
cp /path/to/titan/doc/language/http-dev-server.titan .
titanc -o out-native --exe http-dev-server http-dev-server
```

Serve `site/` on port 8000:

```sh
./http-dev-server site 8000
```

Opening `http://127.0.0.1:8000/` displays:

<!-- doc-check: expect=page -->
```text
Hello, browser, from Titan!
Titan counts 1
Titan counts 2
Titan counts 3
(returned, status 0)
```

Any static HTTP server works provided it serves `.mjs` as JavaScript (such as `text/javascript`) and `.wasm` as `application/wasm` (for streaming compilation). `http-dev-server` listens on `127.0.0.1`, sends `Cache-Control: no-store`, and serves `.wasm.trace` as `application/octet-stream`; use a production web server for public deployments.

### Asset location

By default `hello.mjs` loads `hello.wasm` and `hello.wasm.trace` relative to its own `import.meta.url`. To serve them from another folder or CDN, pass a `locateFile(name, directory)` callback to `create`:

<!-- doc-check: run -->
```sh
mkdir -p site-assets/assets
cp out/hello.mjs site-assets/
cp out/hello.wasm out/hello.wasm.trace site-assets/assets/
```

<!-- doc-check: file=site-assets/index.html -->
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

    const instance = create({
      stdout: show,
      stderr: show,
      requireTrace: true,
      locateFile: (name, directory) => new URL(`assets/${name}`, directory).href,
    });
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

### Using a bundler

Generated images reference `hello.wasm` and `hello.wasm.trace` through standard `new URL(..., import.meta.url)` expressions recognized by bundlers such as [Vite](https://vite.dev/):

<!-- doc-check: run -->
```sh
mkdir -p vite-app
cp site/index.html out/hello.mjs out/hello.wasm out/hello.wasm.trace vite-app/
(cd vite-app && npm install --save-dev vite)
```

Configure `vite-app/vite.config.mjs` with `assetsInlineLimit: 0` so Vite keeps small trace tables as separate files instead of inlining them as `data:` URLs:

<!-- doc-check: file=vite-app/vite.config.mjs -->
```javascript
export default {
  base: "./",
  build: {
    assetsInlineLimit: 0,
  },
};
```

Build into `vite-app/dist/`:

<!-- doc-check: run -->
```sh
(cd vite-app && npx vite build)
```

### Deploying

Serve `hello.mjs`, `hello.wasm`, and `hello.wasm.trace` from the **same build** together (plus `hello.wasm.map` if you want browser DevTools source mapping). Mixing `.mjs` and `.wasm` from different links fails immediately with `TITAN_BROWSER_PROTOCOL`. Cross-origin assets require `Access-Control-Allow-Origin`, and pages using a Content Security Policy need `script-src 'wasm-unsafe-eval'`.

## A complete application

[`browser-app/`](browser-app/) contains a complete browser program ([`app.titan`](browser-app/app.titan), [`index.html`](browser-app/index.html), and [`greeting.txt`](browser-app/greeting.txt)) exercising:

- streaming `http.get` over browser `fetch`;
- typed record exchange with JavaScript via `titan-protobuf.mjs` ([`titan.browser`](standard-library-browser.md));
- passing a Titan callback closure to JavaScript and invoking it back while sharing captured state;
- five concurrent sleeping `async` Tasks joined with `async.all_five` alongside a recurring `timer.ticker`;
- handling `async.OperationError` (`ENOSYS`) from an unconfigured `os.stdin:read()`; and
- unified Titan + Lua stack traces written to `stderr`.

Build and stage it (with `PREFIX` set to your Titan installation root):

<!-- doc-check: run -->
```sh
cp -R /path/to/titan/doc/language/browser-app .
cd browser-app
titanc --target browser -o out app
mkdir -p site
cp index.html greeting.txt out/app.mjs out/app.wasm out/app.wasm.trace site/
cp "$PREFIX/lib/titan-browser/0.6/titan-protobuf.mjs" site/
```

Serve with `../http-dev-server site 8000`. The first panel displays standard output:

<!-- doc-check: expect=app -->
```text
GET greeting.txt: 200 Hello from greeting.txt
The page sent back "HELLO FROM GREETING.TXT", visits 2
The page called back twice, and the count is 3
Task 5 woke after 50 ms
Task 4 woke after 100 ms
Task 3 woke after 150 ms
Task 2 woke after 200 ms
Task 1 woke after 250 ms
All five Tasks returned 1, 2, 3, 4, 5
The ticker ticked while they slept
os.stdin:read() raised ENOSYS in os.InputStream.read
(returned, status 0)
```

The second panel displays standard error, showing unified Titan and Lua frames (on Safari/WebKit, Titan frames omit line numbers):

<!-- doc-check: expect=app-errors -->
```text
This line goes to standard error.
caught: an error raised by Titan code that Lua called
app.titan:132: in app.fail
relay.lua:3: in local 'relay'
relay.lua:5: in main chunk
app.titan:144: in app.report_lua_error
app.titan:156: in app.main
```

## Prerequisites

- **Host OS:** Linux, macOS, or Windows (MSYS2 CLANG64 shell; native PowerShell/`cmd` is unsupported).
- **`wasi-sdk` 34.0 (exact):** Download and unpack `wasi-sdk-34.0` (LLVM 23.1.0), then set `WASI_SDK_PATH` (or put `<wasi-sdk>/bin` on `PATH`):

```sh
export WASI_SDK_PATH=/path/to/wasi-sdk-34.0
```

  Titan locates `clang`, `llvm-ar`, `llvm-ranlib`, and `wasm-ld` via `$WASI_SDK_PATH/bin/` when `WASI_SDK_PATH` is set, or via `clang` on `PATH` (resolving its sibling `llvm-ar`, `llvm-ranlib`, and `wasm-ld`, and `<root>/VERSION`). `CC`, `AR`, and `RANLIB` are ignored for browser builds.
- **Binaryen `version_133` (exact):** Download and unpack Binaryen `version_133`, then set `BINARYEN_ROOT` (or `WASM_OPT`, or put `wasm-opt` on `PATH`):

```sh
export BINARYEN_ROOT=/path/to/binaryen-version_133
```

  Titan checks `WASM_OPT`, then `$BINARYEN_ROOT/bin/wasm-opt`, then `PATH`, and verifies `wasm-opt --version` reports `133`.
- **Node 26+ with WebAssembly JSPI:** Used by `titanc` to validate browser archives and by `titan-browser-run`. Set `TITAN_NODE` or put Node 26+ on `PATH`.
- **JSPI-capable browser:** Chrome/Chromium 137+, Firefox 153+, or Safari 27+ (the loader checks `WebAssembly.promising` and `WebAssembly.Suspending`). For `titan-browser-run --engine chromium`, set `TITAN_CHROME` or put Chrome/Chromium on `PATH`.
- **Browser Lua and Browser SDK:** Installed into your Titan `PREFIX` in order:

```sh
export WASI_SDK_PATH=/path/to/wasi-sdk-34.0
export BINARYEN_ROOT=/path/to/binaryen-version_133
make lua-browser PREFIX="$PREFIX"
make browser-sdk PREFIX="$PREFIX"
```

  On MSYS2 CLANG64, use `make -f Makefile.win lua-browser` and `make -f Makefile.win browser-sdk`. See [Appendix A.1](installation.md#the-browser-lua-and-sdk) for separate `ROCKS_TREE` and uninstall commands.

### Wasm-EH longjmp contract

Browser Lua, Titan's runtime, generated C, and authored C helpers all compile and link with standard WebAssembly `exnref` exceptions (`-mexception-handling -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false`) and `-lsetjmp`, and final images run Binaryen `wasm-opt --stack-check`. Protected calls preserve `catch`, `defer`, and coroutine cleanup across JSPI suspensions. Lua's C-call limit is 100; WebAssembly engine traps and engine stack overflow remain fatal rather than catchable Titan errors.

### Installing the browser SDK

`make lua-browser` installs `liblua.a`, Lua headers, and the build record `liblua-config.txt` under `<PREFIX>/lib/browser/`. `make browser-sdk` installs the browser runtime, loader, runner, and standard library under `<PREFIX>/lib/titan-browser/0.6/`:

| File | Purpose |
| --- | --- |
| `libtitan.a`, `libtitan-lpeglabel.a` | Browser runtime and LPegLabel archives |
| `titan.a` | The 21-module [browser standard library](#the-browser-standard-library) archive |
| `titan-browser.mjs`, `titan-wasm-factory.mjs` | Embedded loader and zero-dependency WebAssembly factory (inlined into each `<stem>.mjs`, not copied separately to pages) |
| `titan-protobuf.mjs` | Standalone JavaScript peer for typed `protobuf` record exchange |
| `titan-browser-run`, `titan-browser-run.mjs`, `titan-browser-page.mjs`, `titan-browser-node-worker.mjs` | Command-line runner for Node and Chromium |
| `build-profile`, `absent-modules`, `analysis-target`, `sdk-digests` | SDK profile (`production`/`validation`), absent-module diagnostics, editor target profile, and digests |

Every browser link verifies that the active `TITAN_BUILD_PROFILE` matches the SDK's `build-profile` and that `liblua-config.txt` matches `wasi-sdk` 34.0 and the installed headers/archive.

### Editor type checking

Editors such as `vscode-titan` type-check browser projects (`target = "browser"` in `titan-config.lua`) using `titan.a`, `analysis-target`, and `absent-modules` from `<PREFIX>/lib/titan-browser/0.6/`—no `wasi-sdk` or Binaryen installation is needed unless a source module requires real C header probes (`foreign import`).

## One target per output directory

`--target browser` (or `TITAN_TARGET=browser`) always requires `-o`/`--output`. The first browser build into an empty output directory writes `<output>/.titan-target` containing `browser`:

- Browser builds refuse nonempty directories without a `browser` marker.
- Native builds refuse directories marked `browser`.

Keep separate output directories for native and browser builds (such as `out/` and `out-browser/`), and separate directories for `production` vs `validation` profiles.

## Build profiles

Browser builds follow `TITAN_BUILD_PROFILE` (`production` by default, or `validation`), which must match the installed browser SDK:

| Profile | Compile & Link | Stack traces |
| --- | --- | --- |
| `production` | `-O3` plus Binaryen `wasm-opt -O3 --stack-check` | Exact `.titan` files/lines for surviving frames; inlined functions merge into their caller |
| `validation` | `-O1 -fno-inline -fno-optimize-sibling-calls` plus `wasm-opt -O1 --stack-check` | Every frame preserved |

Both profiles emit DWARF line tables (`-gdwarf-4 -gline-tables-only`), which `titanc` extracts into `<stem>.wasm.map` and `<stem>.wasm.trace` after `wasm-opt` before stripping `.debug_*` sections from the published `.wasm`. Under `production`, `titanc --target browser --test` disables inlining and function merging on discovered test modules (and skips Binaryen's `inlining-optimizing` and `duplicate-function-elimination` passes) so test failure locations remain exact.

## Building programs, tests, libraries, and C helpers

```sh
titanc --target browser -o out --exe out/app.mjs app             # program (.mjs/.wasm/.wasm.trace/.wasm.map)
titanc --target browser --test -o out --exe out/tests.mjs m_test # browser test image
titanc --target browser -o out-lib geom.shapes geom.area         # browser library archive (geom.a)
titanc --target browser -o out-obj -c app.widgets                # object-only compilation
```

- **Programs:** Explicit `--exe` paths must end in `.mjs`. `main` uses the standard signature `function main(args: {string}): integer`, with `args[1]` as the first user argument. All four output files are published atomically.
- **Library archives:** Non-`main` builds emit only a static archive `<prefix>.a` (no `.so` or Lua loaders). A browser library archive may import an installed source-only module without compiling or owning it (keeping that dependency external; compiled browser archive dependencies retain browser's preexisting separate archive composition). Before publishing, `titanc` validates the archive structurally and runs a quick export and startup check under Node 26+. When a browser program or `--test` image imports prebuilt browser libraries whose reached members recorded dependencies from installed source, `titanc` satisfies each logical module once through ordinary browser lookup—selecting an eligible WebAssembly `.a` archive (standalone or canonical prefix bundle) or compiling `.browser.titan`/shared `.titan` source once into the image (never native host binaries or dynamic loading)—and binds those libraries through the checked public ABI without rebuilding them; see [Source-only modules](modules.md#source-only-modules).
- **Browser dependency path:** Imports resolve in order from (1) `<PREFIX>/lib/titan-browser/0.6/`, (2) `TITAN_PATH_0_6` / `TITAN_PATH` (browser archives only; native ELF/Mach-O/COFF archives are rejected), and (3) source from authored `--tree` roots followed by the read-only installed source fallback `<PREFIX>/lib/titan/0.6/` (searched for `.titan` source only, selecting `.browser.titan` and shared `.titan` variants; native compiled providers there are never eligible). Clear native `TITAN_PATH_0_6` and native `TITAN_EXTRA_*` flags (`-fPIC`, `-flto`, `-march=...`, `-O*`, `-g*`, `--no-line-directives`) when compiling for the browser; browser builds define `TITAN_TARGET_BROWSER=1` and `TITAN_COROUTINE_STACK_SIZE=262144`.

### C helpers and host WebAssembly imports

Pass `--c-source helper.c` to compile authored C helpers with Titan's `wasi-sdk` (`wasm32-wasip1`) flags and link them into the browser image. To call host JavaScript directly from C, declare the imported function with `TITAN_WASM_IMPORT("name")` (from `titan/browser.h`, expanding to `__attribute__((import_module("env"), import_name("name")))` on `__wasm__`) or an explicit `__attribute__((import_module(...), import_name(...)))`, and supply the JavaScript implementation through `create({ imports })`.

`imports` may be a plain object (ordinary or null-prototype, from any realm) or a factory `(context) => importObject` called once before WebAssembly instantiation; each module map inside it must also be a plain object (arrays, `Map`s, class instances, and promises from an async factory are refused with `TypeError` `"must be a plain object …"`). `context` exposes `memory`, `table` (the exported `__indirect_function_table` for invoking C function pointers), `exports`, `HEAPU8` / `HEAPU32` getters that survive memory growth, `readCString(ptr)`, `readBytes(ptr, len)`, `writeBytes(ptr, bytes)`, `trace`, and `abort(msg)`. User imports may use `new WebAssembly.Suspending(asyncFn)` for host suspension (outside synchronous C callbacks). Names under `wasi_snapshot_preview1.*`, `env.titan_browser_*`, and `env.titan_mco_*` are reserved for the Titan runtime: for the object form, invalid shapes or reserved names throw `TypeError` synchronously in `create()`; for the function form, `initialize()`/`run()` reject with `TITAN_BROWSER_PROTOCOL` whose `cause` is that `TypeError`.

Generated `.mjs` modules are strictly **self-contained** and embed zero external `import` statements. For ordinary application JavaScript and ES modules, prefer `create({ bindings })` and [`import "browser"`](standard-library-browser.md) over custom C imports.

## The loader API

Every compiled `.mjs` image exports one default `create(options = {})` function that works in browsers, bundlers, and Node 26+:

```javascript
import create from "./out/app.mjs";

const instance = create({
  stdout: chunk => process.stdout.write(chunk),
  stderr: chunk => process.stderr.write(chunk),
  requireTrace: true,
});
try {
  const result = await instance.run(["first", new Uint8Array([0, 255])]);
  console.error(result.kind, result.status);
} finally {
  await instance.dispose();
}
```

### Instance methods

All async methods (`initialize`, `run`, `call`, `callTask`, `drain`, `dispose`) return promises and begin in a microtask rather than re-entering synchronously:

- **`initialize(): Promise<void>`** — Instantiates Wasm, loads `.wasm.trace`, creates the Lua state, and runs module initializers without running `main`.
- **`run(args = []): Promise<{kind, status, bytes, trace}>`** — Initializes if needed and runs `main` once. Strings in `args` are UTF-8 encoded; `Uint8Array` arguments are copied raw. `kind` is `"returned"`, `"failed"`, or `"exited"`; `status` is a signed 32-bit integer; `bytes` and `trace` hold copied error and traceback bytes when failed.
- **`call(callable, ...args)`** (or `callable.call(...args)`) — Invokes a callable exported via `BrowserValue.is_callable` ([`titan.browser`](standard-library-browser.md)). Arguments and the return value marshal by runtime type (`null`, `boolean`, `BigInt` for `integer`, `number` for `float`, `string`, `Uint8Array` for `is_bytes`, `BrowserHandle` for arbitrary JS objects). Byte/string arguments are snapshotted synchronously before returning the promise.
- **`callTask(callable, args = [], { signal } = {})`** (or `callable.callTask(...)`) — Runs a callable as an `async.Task` ([Task-form calls](#task-form-calls)).
- **`notify(callable, ...args)`** — Synchronously snapshots arguments and enqueues a notification without entering Wasm; throws `TypeError` or `TitanBrowserError` immediately on invalid arguments or state.
- **`drain(): Promise<void>`** — Delivers one detached FIFO batch of queued notifications. Handler failures report through `onNotificationError` without skipping remaining notifications.
- **`dispose(): Promise<void>`** — Closes admission immediately, cancels active Tasks (if an `async` Runtime is active), retires host requests, runs Lua finalizers, flushes output, and releases the instance permanently.
- **`callable.release()`** — Synchronously and idempotently invalidates a callable wrapper and drops Titan's pin immediately without running user Titan code or finalizers.
- **`instance.trace`** — Fresh frozen `{ state, reason }` snapshot of the trace table's status.

### Loader options

| Option | Purpose |
| --- | --- |
| `stdout`, `stderr` | Output sinks receiving copied `Uint8Array` chunks (may return `undefined` or a Promise; absent discards output). |
| `stdin` | Function called per `os.stdin` read, returning a `Uint8Array`, `null`/`undefined`, or a Promise of one. |
| `stdinKind`, `stdoutKind`, `stderrKind` | Optional declared stream kind strings reported by `os.InputStream:kind()` / `OutputStream:kind()`. |
| `stdoutEnd`, `stderrEnd` | Optional hooks called when Titan finishes (`shutdown()`) `os.stdout` or `os.stderr`. |
| `locateFile(name, directory)` | Custom URL resolver for `<stem>.wasm` and `<stem>.wasm.trace`. |
| `requireTrace` | If `true` (default `false`), fail initialization if `<stem>.wasm.trace` cannot be loaded or mismatches. |
| `bindings` | Object of explicit per-instance JS functions/values for `browser.binding(name)` (names starting with `titan:` are reserved). |
| `imports` | Plain object (ordinary or null-prototype, from any realm; module maps must also be plain objects) or `(context) => importObject` supplying user WebAssembly imports declared by `--c-source` or C headers (`wasi_snapshot_preview1.*`, `env.titan_browser_*`, and `env.titan_mco_*` are reserved; invalid/reserved object forms throw `TypeError` synchronously in `create()`, while invalid/reserved function forms reject `initialize()`/`run()` with `TITAN_BROWSER_PROTOCOL` whose `cause` is that `TypeError`). |
| `env` | Initial instance environment map (string keys/values; default empty; isolated from host and peers). |
| `onNotificationError({ kind, operation, error })` | Observes errors that cannot return to a caller (notification callback failures, secondary cleanup errors); defaults to `console.error`. |
| `requestDrain()` | Coalesced hook notified whenever work is queued while idle. |
| `onEngineFailure({ kind, cause })` | Observes terminal `"abort"`, `"trap"`, or `"protocol"` engine failures that poison the instance. |

### Error codes (`TitanBrowserError`)

| `code` | Meaning |
| --- | --- |
| `TITAN_BROWSER_TITAN` | Ordinary Titan error from initialization or a call (`bytes`, `trace`, `status`); instance remains usable. |
| `TITAN_BROWSER_REENTRY` | Concurrent entry or immediate reverse call from inside a binding or output sink. |
| `TITAN_BROWSER_STATE` | Wrong lifecycle state (`call`/`drain`/`notify` before init, second `run`, `callTask` without `async` Runtime). |
| `TITAN_BROWSER_CANCELLED` | `callTask` cancelled by `AbortSignal` or Titan cancellation (`reason` holds signal reason or text). |
| `TITAN_BROWSER_EXITED` | Operation rejected because the instance latched an exit status (`status`). |
| `TITAN_BROWSER_DISPOSED` | Operation rejected or interrupted by `dispose()`. |
| `TITAN_BROWSER_HANDLE` | Released or foreign callable wrapper, or handle of a closed Lua state. |
| `TITAN_BROWSER_SINK` | Output sink threw, rejected, or returned an invalid value (`stream` names the stream). |
| `TITAN_BROWSER_HOST` | Host cleanup hook (`cancel`, `unregister`, `onNotificationError`) threw. |
| `TITAN_BROWSER_CAPABILITY` | Host lacks WebAssembly JSPI. |
| `TITAN_BROWSER_ABORT`, `TITAN_BROWSER_TRAP`, `TITAN_BROWSER_PROTOCOL` | Fatal Wasm abort, trap, or protocol mismatch; instance is permanently poisoned. |

Invalid `create` options, out-of-range `BigInt` values (outside signed 64-bit), and ill-formed UTF-16 strings (lone surrogates) throw or reject with `TypeError`.

### Calls during a drive

Only one logical operation owns an instance at a time. Calling back into the instance synchronously from inside a JS binding or output sink rejects with `TITAN_BROWSER_REENTRY` (use `notify()` instead).

While an `async` Runtime is actively driving Tasks (yielding between browser macrotasks):

| JS call during a drive | Inside binding or sink | Outside binding/sink (e.g. DOM event / timer) |
| --- | --- | --- |
| `call()` | Rejects `TITAN_BROWSER_REENTRY` | Queued and executed at the driver's next turn |
| `callTask()` | Rejects `TITAN_BROWSER_REENTRY` | Queued to start as a Task in the running drive |
| `notify()` | Queued for the driver | Queued for the driver |
| `drain()`, `run()` | Rejects `TITAN_BROWSER_REENTRY` | Rejects `TITAN_BROWSER_REENTRY` |
| `dispose()` | Closes admission and wakes drive | Closes admission and wakes drive |

Buffered `stdout`/`stderr` chunks flush whenever the drive relinquishes the event loop as well as when the operation ends. Calls targeting a child `lua.new()` state are rejected with `TITAN_BROWSER_REENTRY` while the owner state drives.

### Task-form calls

`instance.callTask(callable, args = [], { signal } = {})` starts `callable` as an `async.Task` and resolves to its decoded result (driving the Runtime if idle, or joining an active drive). Passing an `AbortSignal` cancels the Task when aborted (passing `String(signal.reason)` to Titan and rejecting the promise with `TITAN_BROWSER_CANCELLED` carrying `signal.reason`). Images without `async` or callables from a child `lua.new()` state reject with `TITAN_BROWSER_STATE`.

### Exit

Calling `os.exit(code)` / `async.request_exit(code)` inside a browser Task latches the instance as exited without terminating the page or Node process: `run()` resolves `{ kind: "exited", status, bytes }`, active `call`/`callTask` calls reject with `TITAN_BROWSER_EXITED`, and subsequent calls reject with `TITAN_BROWSER_EXITED`. `dispose()` remains available to run finalizers and release memory.

### Disposal with a running Runtime

Calling `dispose()` closes application admission immediately, rejects unsettled queued calls with `TITAN_BROWSER_DISPOSED`, drops queued application notifications, and wakes the `async` Runtime to cancel all running Tasks with `"instance disposed"`. Host requests already started before `dispose()` continue delivering settlements so `defer` cleanup can finish; new host requests fail with `"browser state is closing"`. Once cleanup completes, remaining requests are cancelled and Lua closes.

### Synchronous C callbacks

Host JavaScript imports can invoke a C function pointer synchronously through `context.table.get(fnPtr)`. A C callback that invokes pinned Titan code via `titan_browser_call_sync` runs immediately whenever the instance is open (refused after `dispose()`, exit, or engine failure). Inside any JS binding called from that callback, `call`/`callTask`/`drain`/`run` reject with `TITAN_BROWSER_REENTRY`; outside a binding, they queue until after the callback returns. See [`titan.browser` synchronous C callbacks](standard-library-browser.md#synchronous-c-callbacks).

## Testing from the command line

`titan-browser-run` (installed at `<PREFIX>/lib/titan-browser/0.6/titan-browser-run`) runs any browser `.mjs` program or `--test` image under Node 26+ or headless Chrome/Chromium through the same loader used by web pages:

```sh
titanc --target browser --test -o out --exe out/app_tests.mjs app.calc_test
titan-browser-run out/app_tests.mjs -- --filter='zero$' --verbose
titan-browser-run --engine chromium out/app_tests.mjs
```

Pass program or test-runner arguments after `--`. Key options:

| Option | Meaning |
| --- | --- |
| `--engine node\|chromium` | Execution engine (default `node`, requiring Node 26+ via `TITAN_NODE` or `PATH`). |
| `--timeout MS`, `--grace MS` | Wall-clock run timeout (default 30000 ms) and post-completion watch window (default 1500 ms). |
| `--chrome PATH`, `--cdp pipe\|port` | Headless Chrome/Chromium binary (overrides `TITAN_CHROME`) and DevTools transport. |
| `--root DIR` | Served directory containing `.mjs`, `.wasm`, and `.wasm.trace` (default: directory of `.mjs`). |
| `--imports FILE` | Regular `.mjs` ES module under `--root` whose default export is passed as `create({ imports })` for direct images (and passed to `--js-test` harnesses as `context.imports` so the harness can forward it to `create`) on both Node and Chromium. |
| `--allow-degraded-trace` | Allow missing/mismatched `.wasm.trace` (`requireTrace: false`). |
| `--probe` | Print JSON describing the discovered Node and Chrome binaries without running an image. |

Exit statuses: `status & 255` for normal completion (0/1/2 for test suites), `2` for invalid runner options, `70` abort, `71` Wasm trap, `72` timeout, `73` trap/abort during grace period, `74` unhandled Promise rejection, `75` runner/environment error, and `76` sink error. Set `TITAN_BROWSER_ROOT_NO_SANDBOX=1` when running Chromium as `root` inside a container.

### Traces

At initialization, the loader eagerly fetches `<stem>.wasm.trace` (derived from the source map at link time) and verifies its build identity against `<stem>.wasm`. Nothing is fetched when an error is raised.

- **Chrome, Chromium, Firefox, and Node:** Full unified Titan + Lua tracebacks (`file.titan:line: in module.func`), identical to native builds. Under `production`, frames inlined by the optimizer merge into their caller; build with `validation` to keep every frame.
- **Safari / WebKit:** Function-level fidelity (`file.titan: in module.func`, without line numbers) in the same interleaved order.
- **Limits and degraded mode:** Browser captures hold up to 512 WebAssembly records (Firefox caps synchronous captures at 128 frames), appending `(...native frames truncated...)` if cut short. Without `requireTrace: true`, a missing or mismatched trace table logs a warning and emits `(native Titan frames unavailable: trace table not loaded)` in traces.

## The browser standard library

The browser SDK's `titan.a` provides **21 standard modules**: **14 complete shared modules**, **6 browser-adapted shared modules**, and **1 browser-only module** (`browser`):

| Module | Browser support | Notes |
| --- | --- | --- |
| [`coroutine`](coroutines.md), [`gc`](standard-library-gc.md), [`io`](standard-library-io.md), [`iteration`](standard-library-iteration.md), [`json`](standard-library-json.md), [`math`](standard-library-math.md), [`path`](standard-library-path.md), [`peg`](standard-library-peg.md), [`protobuf`](standard-library-protobuf.md), [`reflect`](standard-library-reflect.md), [`string`](standard-library-string.md), [`test`](standard-library-test.md), [`transfer`](standard-library-transfer.md), [`url`](standard-library-url.md) | **Complete** (14 modules) | Full native public API. `path` uses POSIX rules (`/`). |
| [`timer`](standard-library-timer.md#on-the-browser) | **Browser-adapted** (complete API) | `sleep`, `yield`, and coalescing `Ticker` backed by JavaScript timers (subject to browser clamping/throttling). |
| [`async`](async-io.md#the-browser-target) | **Browser-adapted** (subset) | Tasks, cancellation, `async.channel`, `reader_writer_channel`, combinators, and subscriptions on the owner state. Libuv waits, `run_foreign`, `Receiver`, and `current_loop` are absent. |
| [`os`](standard-library-os.md#on-the-browser) | **Browser-adapted** (subset) | Calendars, wall time, locale, per-instance `getenv`/`setenv`/`unsetenv`, Task `exit`, and embedding `stdin`/`stdout`/`stderr`. CPU `clock`, host paths, processes, and signals are absent. |
| [`lua`](standard-library-lua.md) | **Browser-adapted** (subset) | `load`, `load_from_reader`, preload/custom-searcher `require`, and synchronous `lua.new()` states. `dofile`, `run_async`, and filesystem searches are absent. |
| [`http`](standard-library-http.md#on-the-browser) | **Browser-adapted** (subset) | Streaming HTTP client (`Client`, `get`, `request`, `Headers`, `RequestOptions`) over browser `fetch` (follows redirects by default; respects browser CORS/cookies/cache). Servers and upgrades are absent. |
| [`websocket`](standard-library-websocket.md#on-the-browser) | **Browser-adapted** (subset) | Message-oriented client over host `WebSocket`. Server upgrades, `ping`, custom dial headers/`ca_file`, and transfer hooks are absent. |
| [`browser`](standard-library-browser.md) | **Browser only** (1 module) | JavaScript `bindings`, `BrowserValue` marshalling, handles, pinned callables, tracked requests/listeners, and synchronous C callbacks. |

Every retained declaration in a subset module keeps its exact native signature; absent declarations fail at compile time. Operations that depend on optional host setup—such as reading `os.stdin` without an embedding `stdin` sink, or calling `os.exit` outside a Task—raise a documented `OperationError` (`ENOSYS`) or availability error rather than silently failing.

C target differences on WebAssembly (`wasm32`): `size_t` and C `long` are 4 bytes (affecting `string.pack` `T`/`l`/`L`; `lua_Integer` `j`/`J` stays 8 bytes, little-endian), the C locale always uses `.` as decimal point, and coroutine C stacks are 256 KiB instead of 2 MiB.

### Modules that are not available

Six native standard-library modules are absent on the browser target and fail at compile time with `"not available for target 'browser': <reason>"`:

| Module | Reason |
| --- | --- |
| `fs` | requires a filesystem |
| `net` | requires native sockets |
| `sqlite3` | requires the native SQLite library |
| `ssl` | requires OpenSSL and native sockets |
| `thread` | requires OS threads |
| `uv` | requires libuv |

## Limits

**Build-time WebAssembly bounds:** `titanc` enforces the WebAssembly JavaScript Interface limits before publishing any image: at most **7,654,321 bytes** for a single function body and **1 GiB** (`1,073,741,824` bytes) for the complete `.wasm` file.

**Runtime memory and stacks:**

| Resource | Limit | Behavior at limit |
| --- | --- | --- |
| Main linear C stack | 1 MiB | Checked overflow aborts rather than corrupting memory |
| Coroutine linear C stack | 256 KiB per coroutine | Same checked bounds across suspension and memory growth |
| Linear Wasm memory | ~16 MiB initial, growing up to 2 GiB (never shrinks) | Allocation failure raises a Lua memory error if recoverable; engine OOM is fatal |
| Engine JS/Wasm call stack | Engine-managed | Exhaustion is fatal (not catchable in Titan) |

**Other target constraints:**

- `async` Tasks run only in the instance's owner Lua state, not in child `lua.new()` states.
- A loader instance runs `main` at most once (exported `call` / `callTask` / `drain` remain usable afterward until `dispose()` or exit).
- Native line coverage (`--coverage`) is not supported on `--target browser`.

### Lua's C-call limit

Browser Lua sets `LUAI_MAXCCALLS` to **100** (native Lua uses 200). Exceeding it raises a catchable `C stack overflow` error. This counter is shared across mixed Titan↔Lua recursion, nested `pcall`, metamethod chains, Lua coroutine resume chains, and runtime Lua chunk parsing depth (about 100 nested expressions/blocks). Within two counts of the limit, error capture may report `C stack overflow` directly and finalizers are postponed until calls unwind.

### Nesting limits

Library serialization and parsing nesting limits match native targets:

- `protobuf` and `transfer` nominal/field codecs enforce the shared **128-level** nesting limit (`protobuf: nesting exceeds 128 levels`).
- `json.encode` and `json.decode` enforce their configured `max_depth` (default 32), regular expressions allow up to 512 groups / 200 captures, and `peg` grammars default to 400 matching-stack entries / 200 nested captures.

For compiler internals, the browser SDK build pipeline, and engine benchmarks, see [Browser target internals](../implementation/browser-target.md).
