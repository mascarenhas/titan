# Compiling for the browser target

`titanc --target browser` compiles Titan programs, tests, and libraries to
WebAssembly with Emscripten, to run inside web pages and web applications. A
program becomes an ES module, its WebAssembly binary, and its trace table,
which belong together, plus a source map for browser developer tools. A page
runs the program through Titan's JavaScript [loader](#the-loader-api). For
tests, the command-line runner
[`titan-browser-run`](#testing-from-the-command-line) runs the same files
under Node and headless Chrome.

## A first web page

This walk-through builds a small Titan program, embeds it in a web page, and
serves the page to a browser. It assumes that the toolchain from
[prerequisites](#prerequisites) is installed, with Emscripten active in the
shell and the `bin` directory of the Titan installation that holds the browser
SDK on `PATH`. `/path/to/titan` stands for the Titan source checkout that the
installation was built from.

The program, `hello.titan`, prints a greeting and three counting lines:

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

The shared `io` module writes through the embedding's standard streams.
`io.print` converts its arguments, appends a newline, and submits one write
to the current `os.stdout`. Standard output and standard error reach the
page through the loader's output sinks.

Build it for the browser:

<!-- doc-check: run -->
```sh
titanc --target browser -o out hello
```

This writes `out/hello.mjs`, `out/hello.wasm`, `out/hello.wasm.trace`, and
`out/hello.wasm.map`: the ES module, its WebAssembly binary, the trace table
that locates Titan frames in errors, and a source map for browser developer
tools, next to the compiler's intermediate files. Copy the first three into a
folder `site/` that will hold the page:

<!-- doc-check: run -->
```sh
mkdir -p site
cp out/hello.mjs out/hello.wasm out/hello.wasm.trace site/
```

The generated ES module already contains Titan's loader. There is no runtime
JavaScript file to copy from the SDK: the three generated files are the whole
program image.

Then write the page, `site/index.html`:

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

The module script imports the program's default `create(options)` function.
Each output sink receives copied `Uint8Array` chunks; this page decodes them
as UTF-8 and appends the text to the `<pre>` element. `requireTrace: true`
makes a missing or damaged trace table fail initialization, so a deployment
that forgets `hello.wasm.trace` shows `(failed, status 1)` at once instead of
quietly losing the Titan frames of later error traces. `run(["browser"])`
initializes the image and runs `main` with `args[1] == "browser"`, resolving to
a `returned` result with status 0. The state remains alive after `main`
returns. **Always await `dispose()` in `finally`**: it closes Lua, runs state
finalizers, drains their output, and releases the image. The
[loader API](#the-loader-api) describes every option and result.

### Serving the page

Browsers do not load module scripts into a page opened from a `file://` URL,
and they refuse the `fetch` requests with which the loader reads the
WebAssembly binary and the trace table, so the page needs an HTTP server.

Titan's source tree includes a small development server written in Titan,
[`http-dev-server.titan`](http-dev-server.titan). It is a native program, so
build it in its own output directory: a [browser output
directory](#one-target-per-output-directory) refuses native builds.

<!-- doc-check: run -->
```sh
cp /path/to/titan/doc/language/http-dev-server.titan .
titanc -o out-native --exe http-dev-server http-dev-server
```

Serve `site/` on port 8000:

```sh
./http-dev-server site 8000
```

It prints `Serving site at http://127.0.0.1:8000/`. Open that address. The
page shows:

<!-- doc-check: expect=page -->
```text
Hello, browser, from Titan!
Titan counts 1
Titan counts 2
Titan counts 3
(returned, status 0)
```

The server listens on `127.0.0.1` only and answers `GET` and `HEAD`; other
methods get 405. A folder serves its `index.html`. It refuses with 403 a path
that leaves the folder, through `..` (percent-encoded or not) or a symbolic
link, or that it has no permission to read, and answers 404 for anything else
that is not a file. Every response carries `Content-Length` and
`Cache-Control: no-store`, so a reload always fetches the files you just
rebuilt. When the port is taken it prints
`http-dev-server: port 8000 is already in use` and exits with status 1. It
is a development server: `titan.http` speaks HTTP/1.1 only, without HTTP/2,
so host a public site with a production web server.

### Content types

Any static web server works if it sends the right content types, as
`http-dev-server` does. Browsers run a module script only when the server
sends it with a JavaScript content type, such as `text/javascript`. The
WebAssembly binary should come as `application/wasm`; with another type the
program still runs, but the browser console shows `wasm streaming compile
failed` and the browser compiles the binary only after downloading all of it.
The loader reads the trace table as plain bytes, so its type does not matter;
`http-dev-server` sends it as `application/octet-stream`.

### Asset location

By default the image looks for `hello.wasm` and `hello.wasm.trace` next to
`hello.mjs`: it resolves their names against the module's own URL,
`import.meta.url`, wherever the page lives. To serve them from somewhere else,
such as a CDN or an `assets/` folder, pass `create` a `locateFile(name,
directory)` function. The loader calls it with each file name, `hello.wasm`
and `hello.wasm.trace`, and the URL of the folder that holds `hello.mjs`, and
fetches the URL it returns. This variant keeps the module beside the page and
moves the two other files into `assets/`:

<!-- doc-check: run -->
```sh
mkdir -p site-assets/assets
cp out/hello.mjs site-assets/
cp out/hello.wasm out/hello.wasm.trace site-assets/assets/
```

Only the `create` call of `site-assets/index.html` changes:

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

`./http-dev-server site-assets 8000` serves it, and the page shows the same
text.

### Using a bundler

A bundler such as [Vite](https://vite.dev/) can build the page and the image
together. The image names its WebAssembly binary and trace table with
`new URL("hello.wasm", import.meta.url)` expressions, which Vite recognizes: it
emits both files into `dist/assets/` under content-hashed names and rewrites
the URLs. Make a project in `vite-app/` from the page and the image, and
install Vite in it:

<!-- doc-check: run -->
```sh
mkdir -p vite-app
cp site/index.html out/hello.mjs out/hello.wasm out/hello.wasm.trace vite-app/
(cd vite-app && npm install --save-dev vite)
```

The parentheses run the command inside `vite-app/` and leave the shell in the
folder that holds `http-dev-server`, where the rest of this chapter works.

Configure it in `vite-app/vite.config.mjs`:

<!-- doc-check: file=vite-app/vite.config.mjs -->
```javascript
export default {
  base: "./",
  build: {
    assetsInlineLimit: 0,
  },
};
```

`assetsInlineLimit: 0` keeps every asset a separate file: without it, Vite
would inline a trace table smaller than 4 KiB into the JavaScript as a `data:`
URL. `base: "./"` makes the emitted URLs relative, so `dist/` can be served
from any path. Vite's default browser targets already support the top-level
`await` of the image and the page. Build the page into `vite-app/dist/`:

<!-- doc-check: run -->
```sh
(cd vite-app && npx vite build)
```

`./http-dev-server vite-app/dist 8000` serves the result, and the page shows
the same text. Vite does not copy `hello.wasm.map`: developer tools find the
source map only when it is served next to the hashed WebAssembly file under
the name that file refers to, which Vite does not arrange.

### Deploying

To deploy the page, serve `hello.mjs`, `hello.wasm`, and `hello.wasm.trace`
together with it. No external loader is required. The trace table lets errors
report Titan source files and lines (see [traces](#traces)); serve
`hello.wasm.map` too if you want browser developer tools to show sources.

Deploy the files of one build together. The module refuses to run with a
WebAssembly binary from another build, and a trace table from another build
fails initialization under `requireTrace: true`, as on this page, or otherwise
costs the Titan frames of error traces ([programs](#programs)). The
browser fetches a module script, and the loader the binary and the table,
in CORS mode, so a page served from another origin than the three files needs
their server to allow it (`Access-Control-Allow-Origin`). A page with a
Content Security Policy must allow WebAssembly compilation with `script-src
'wasm-unsafe-eval'`, as for any WebAssembly module, besides the origin of
`hello.mjs`.

## A complete application

The Titan source tree holds a larger browser program in
[`browser-app/`](browser-app/): [`app.titan`](browser-app/app.titan), its page
[`index.html`](browser-app/index.html), and
[`greeting.txt`](browser-app/greeting.txt), a file that the program fetches.
In order, its `main`:

* fetches `greeting.txt` from the page's own server with
  [`http.get`](standard-library-http.md#on-the-browser) and prints the status
  and the first line;
* sends a `Card` record to the page as a [typed
  copy](standard-library-browser.md#copying-typed-values). The page's
  `publish` binding decodes it with the SDK's `titan-protobuf.mjs` and returns
  a changed copy, which Titan decodes;
* passes a Titan function to the page's `visit` binding, which calls it back
  twice before it settles the request. The function and the request's
  completion share one captured counter
  ([callables](standard-library-browser.md#callables-and-pinning));
* runs five Tasks that sleep for different times while a sixth waits on a
  ticker, and joins the five with `async.all_five`. The page's frame counter
  keeps advancing while they wait;
* reads `os.stdin`, which the page does not supply, and prints the
  [`async.OperationError`](#unavailable-operations) that the read raises;
* writes a line to standard error, which the page shows in a second element;
* runs a Lua chunk that calls a Titan function that raises, catches the
  error, and writes its trace to standard error.

Build it in a folder of its own, beside the `http-dev-server` that you built
for the first page, with `PREFIX` set to the root of the Titan installation:

<!-- doc-check: run -->
```sh
cp -R /path/to/titan/doc/language/browser-app .
cd browser-app
titanc --target browser -o out app
mkdir -p site
cp index.html greeting.txt out/app.mjs out/app.wasm out/app.wasm.trace site/
cp "$PREFIX/lib/titan-browser/0.6/titan-protobuf.mjs" site/
```

The page imports `titan-protobuf.mjs` to read and write the typed copies; it
is served beside the program, not embedded in it. Serve the folder:

```sh
../http-dev-server site 8000
```

The page's first element shows standard output and the result:

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

The second element shows standard error. On Chromium, Chrome and Firefox the
trace names the Titan source lines and the Lua chunk's lines, innermost call
first:

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

The frames of the `async` runtime, which runs `main` as a Task, follow. On
WebKit and Safari the Titan frames have no line (`app.titan: in app.fail`).
This program's frames are the same in both [build profiles](#build-profiles);
in general a `production` trace leaves out the frame of a function that the
optimizer inlined into its caller ([traces](#traces)).

The page loads exactly six files: itself, `app.mjs`, `app.wasm`,
`app.wasm.trace`, `titan-protobuf.mjs`, and `greeting.txt`. Its
`<link rel="icon" href="data:,">` keeps the browser from requesting
`/favicon.ico`.

## Prerequisites

You need:

* **A Linux or macOS host** for the complete SDK and runner workflow below.
  The compiler also accepts compile-only browser work from MSYS2 CLANG64
  on Windows with Emscripten and the fork's installed browser Lua.
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
`emranlib` must sit beside that `emcc`. On Windows the three tool names end
in `.exe`, and the native compiler reads semicolon-separated `PATH` entries.
Your `CC`, `AR`, and `RANLIB` settings are not used for the browser target.
A missing or different Emscripten stops
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
TITAN_NODE to a Node 26 or newer executable`. The SDK installs these files,
and only these, into `lib/titan-browser/0.6/` under the Titan installation
root; other chapters refer to this list:

| File | Contents |
| --- | --- |
| `libtitan.a` | the browser runtime archive |
| `libtitan-lpeglabel.a` | the PEG engine, built for the browser; `make browser-sdk` links it into `titan.a` |
| `titan.a` | the [browser standard library](#the-browser-standard-library): fourteen shared modules including `io`, browser contributors for `async`, `timer`, synchronous `lua`, the `os` subset, and the `http` and `websocket` clients, browser-only `titan.browser`, and the PEG engine |
| `titan-browser.mjs` | the [loader](#the-loader-api) source embedded by the compiler into each generated image; pages do not copy or import it separately |
| `titan-browser-library.js`, `titan-browser-bridge.js`, `titan-browser-trace.js` | the Emscripten JavaScript libraries that Titan-entry browser images link (channels, protected bridge imports, admission, eager trace-table loading, and stack capture) |
| `titan-protobuf.mjs` | the standalone [portable-codec peer](standard-library-browser.md#copying-typed-values), served separately by a page rather than embedded in its image |
| `titan-browser-run`, `titan-browser-run.mjs`, `titan-browser-node-worker.mjs`, `titan-browser-page.mjs` | the [test runner](#testing-from-the-command-line) |
| `titan-browser-module-check.mjs` | the [module check](#c-helpers-and-emscripten-apis) that `titanc` runs on each linked image module, under emcc's Node with emcc's acorn parser |
| `build-profile` | the [build profile](#build-profiles), `production` or `validation`, that compiled the SDK's archives |
| `absent-modules` | the [standard modules that are not available](#modules-that-are-not-available) and the reasons their browser imports report |
| `sdk-digests` | content digests of the browser SDK, written last |

The directory is a sibling of the native `lib/titan/0.6/`, never inside it,
and native builds never search it. `make browser-sdk` works into an empty
directory. Like `make lua-browser`, it needs Emscripten; no native Make target
does. In a
[separate rocks tree](installation.md#a-separate-rocks-tree), pass both roots,
`make browser-sdk PREFIX="$PREFIX" ROCKS_TREE="$ROCKS_TREE"`; it first copies
the verified browser Lua from `PREFIX` into `ROCKS_TREE`.

Rerun `make lua-browser` and `make browser-sdk` after changing Emscripten, the
fork, or Titan. `make uninstall-browser-sdk PREFIX="$PREFIX"` (with the same
`ROCKS_TREE` as the install) removes the files that `make browser-sdk`
installed and keeps any other file in `lib/titan-browser/0.6/`, such as a
library archive; `titan-uninstall` removes them too. See [what each command
removes](installation.md#what-each-command-removes).

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

The SDK's archives were compiled with one build profile, and a link must use
the same one. A link with the other profile is refused before it starts:

```text
browser SDK "/home/me/.local/titan/lib/titan-browser/0.6" was built with the validation profile, but this build uses production; set TITAN_BUILD_PROFILE=validation, or build a production browser SDK in another prefix with 'make browser-sdk PREFIX=<prefix> TITAN_BUILD_PROFILE=production'
```

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
(`-gsource-map -g2`), and Titan derives the trace table from them as described
in [traces](#traces). Every Titan frame that a trace shows is therefore
attributed to its `.titan` file and line as that section describes, and a
deployed program needs its `<stem>.wasm.trace` next to `<stem>.wasm`, in either
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
four files with the same stem: the ES module, its WebAssembly binary, its trace
table, and its source map. Without `--exe`, the program uses the native
program's path below the output directory with `.mjs` added, so
`titanc --target browser -o out app` writes `out/app.mjs`, `out/app.wasm`,
`out/app.wasm.trace`, and `out/app.wasm.map`. An explicit `--exe` must end in
`.mjs`:

```text
browser executable output "out/app" must end in .mjs
```

Titan publishes the four files together: a failed link leaves the previous
files in place. `--incremental` reuses an unchanged set without relinking.
The runtime reads the module, the binary, and the trace table; the source map
is for browser developer tools and the runtime never reads it. A web server
therefore serves `app.wasm.trace` alongside `app.wasm`, so that the runtime can
load it during module initialization (see [traces](#traces)), and serves
`app.wasm.map` only when developer tools should show sources.

The module, binary, and table of one link belong together, and the runtime
checks this before any Titan code runs:

* An `app.mjs` loaded with an `app.wasm` from another link refuses to run.
  `initialize()` and `run()` reject with a `TitanBrowserError` whose `code`
  is `TITAN_BROWSER_PROTOCOL`, for example:

  ```text
  browser image mismatch: app.mjs belongs to image 3f1c0a9b7e42, app.wasm is image 9d07e5a2c6b1
  ```

* An `app.wasm.trace` from another link only degrades traces, as described
  under [deploying `.wasm.trace`](#traces).

Titan publishes the table first, then the map, then the `.wasm`, then the
`.mjs`. A publication that is interrupted, or a server or cache that mixes
files of two links, therefore never runs a Titan program against the wrong
image. Linking again repairs the set.

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
count. [Testing from the command line](#testing-from-the-command-line)
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

A consumer builds against a published browser archive without the library's
source: the archive carries the modules' interfaces for checking and their
code for linking. To install a library, copy its archive into a directory of
its own, laid out like the SDK directory, and name that directory in the
browser Titan path described
[below](#dependencies-and-the-browser-titan-path):

```sh
titanc --target browser -o out-browser geometry.shapes geometry.area
mkdir -p "$HOME/.local/geometry/lib/titan-browser/0.6"
cp out-browser/geometry.a "$HOME/.local/geometry/lib/titan-browser/0.6/"
TITAN_PATH_0_6="$HOME/.local/geometry/lib/titan-browser/0.6" \
  titanc --target browser -o out-app app
```

The first command publishes `out-browser/geometry.a`. The last links `app`
against the installed copy, and works the same once the library's source and
`out-browser` are deleted. Titan checks the installed archive under Node, as
for any archive a link selects.

### Objects

`-c` compiles each Titan module to a WebAssembly object with its metadata, and
`--c-source FILE` compiles C helpers with the same Emscripten settings.
`--incremental` reuses unchanged objects exactly as for native builds.

### C helpers and Emscripten APIs

Emscripten C declarations can be imported directly, including
`foreign import "emscripten/html5.h"`. Function-like macros are not imported:
call the underlying declared function when one is available. For example,
`emscripten_set_click_callback_on_thread` with
`EM_CALLBACK_THREAD_CONTEXT_CALLING_THREAD` is the declared-function form of
the `emscripten_set_click_callback` macro.

`--c-source FILE` adds a C helper to a program or test image, compiled with
the same Emscripten settings. Use it for `EM_JS` or `EM_ASM` blocks and C
operations the FFI cannot express, behind a small header Titan imports; it
is not required merely to call an Emscripten API. An API that calls back
into C runs the callback synchronously. To run Titan code there, pin a
handler and call `titan_browser_call_sync`
([synchronous C callbacks](standard-library-browser.md#synchronous-c-callbacks)).

`EM_JS` and `EM_ASM` code becomes part of the generated module, which is
self-contained: it loads no other module. Titan parses each linked module and
refuses one that imports or re-exports a module, calls `import()`, uses
`require`, or calls `process.getBuiltinModule` for anything beyond the `fs`,
`path` and `url` modules that Emscripten's Node support reads. To use other
JavaScript, including another ES module of the page, pass it to Titan as a
`create({bindings})` value and call it through
[`titan.browser`](standard-library-browser.md). Comments and strings may
mention any of these. The refusal names the construct, its line in the
generated module, and the code there:

```text
browser image module uses dynamic import() at line 1840 (import('./page.mjs')); the image module is self-contained; pass page JavaScript to Titan as create({bindings}) values through titan.browser
browser image module uses require at line 1840 (require); browser images load no Node module; pass page JavaScript to Titan as create({bindings}) values through titan.browser
```

The check keeps generated and `EM_JS` code to what a page, a bundler and Node
can all load; it is not a sandbox for code written to evade it.

## The loader API

Every generated program or test ES module exports one default
`create(options = {})` function. Import that function directly; the raw
Emscripten factory and Module are private. The same image works over HTTP, in
a bundler such as Vite, and in Node 26+. The module imports nothing: under
Node it reaches Node's file and path modules through
`process.getBuiltinModule`, so neither a bundler nor a page sees an import or
a `require` call:

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
  With `requireTrace: true`, a missing or invalid trace table fails initialization
  before Lua is created or any initializer runs. This failure has message
  bytes and status 1, but no Titan trace because no Titan code ran.
* `run(args = [])` initializes when needed, then invokes `main` once. Strings
  in `args` are UTF-8 encoded; `Uint8Array` arguments are copied byte for byte.
  It resolves `{kind, status, bytes, trace}`, with `"returned"`, `"failed"` or
  `"exited"`, a signed 32-bit status, and copied error and raw trace bytes
  (empty unless failed). An ordinary initializer or main failure is a
  failed/status1 result, not a fatal-engine rejection. A program that links
  `async` runs `main` as a Task through the async bootstrap: a failed main
  Task prints its uncaught Task report on stderr, as natively, and `run()`
  resolves `"failed"` with status 1 and that Task's message and trace. The
  standalone report (the program name, the message and a traceback on stderr)
  is printed only for initializer failures, failures of a `main` called
  directly (without `async`, or built with `--no-uv-bootstrap`), and fatal
  Runtime failures that `async.loop()` re-raises. A cancelled main Task
  resolves `"returned"` with status 1, the status a native program exits
  with. A prior initializer failure is reused without a second report.
  `"exited"` reports the status a drive latched with [exit](#exit). An entry
  that failed stays `"failed"` even when its drive latched an exit; otherwise
  the exit latch wins over a main Task failure that the bootstrap reported.
* `call(callable, ...args)` invokes a callable wrapper that Titan exported
  through [`BrowserValue.is_callable`](standard-library-browser.md#callables-and-pinning)
  and passed to JavaScript. It requires successful initialization and remains
  available after main returns. Both this method and `callable.call(...args)`
  marshal arguments by runtime type into `BrowserValue` and resolve to the
  single decoded return value (`null` for `is_nil()`, `BigInt` for
  `is_integer`, `Uint8Array` for `is_bytes`, string for `is_string`, and the
  underlying JavaScript value for `is_handle`). Returning a `BrowserHandle`
  that holds a `Promise` or thenable causes the user-facing `call` promise to
  adopt it, while internal operation admission and `dispose()` depend only on
  the Wasm entry's completion.
  Byte and string arguments are snapshotted synchronously before either method
  returns its promise; later mutations do not change that call. During a
  drive, a call made outside any binding or sink is queued
  ([calls during a drive](#calls-during-a-drive)).
* `callTask(callable, args = [], {signal} = {})` runs the callable as an
  `async` Task and resolves to its single decoded result
  ([Task-form calls](#task-form-calls)). `callable.callTask(args, options)` is
  the wrapper form.
* `notify(callable, ...args)` synchronously snapshots and enqueues one
  notification without entering Wasm. It copies byte arrays, UTF-8-encodes
  well-formed strings, and keeps raw JavaScript values by reference. It does
  not allocate Wasm buffers or handle slots. Because it is synchronous, a wrong
  instance state, a foreign or released wrapper, an out-of-range `BigInt`, or
  an ill-formed UTF-16 string throws immediately; after disposal begins,
  `notify` does nothing. Logically released arguments are rejected again before
  delivery; released or closed targets retire without delivery. During a drive
  the driver delivers the owner state's notifications; a notification for
  another Lua state throws `TITAN_BROWSER_REENTRY` then.
* `drain()` requires successful initialization and delivers one detached FIFO
  batch. A handler error is reported as a `"callback"` event through
  `onNotificationError`, with its captured Titan data, and later
  notifications still run. Notifications enqueued by handlers belong to the
  next batch. `drain()` itself installs no loop or scheduling policy; while a
  drive runs it rejects with `TITAN_BROWSER_REENTRY`.
* `dispose()` closes application admission immediately and returns one stable
  promise. An accepted native entry physically retires before Lua closes.
  Requests and queued work are retired according to their ownership contract.
  Main's lexical defers have already run at return; state finalizers run here.
  All state-owned handles become invalid. A disposed instance never revives.
  With an `async` Runtime, Task cleanup runs first
  ([disposal with a running Runtime](#disposal-with-a-running-runtime)).

`initialize`, `run`, `call`, `callTask`, `drain`, and `dispose` always return
promises, including admission errors. Calling `call` or `drain` before
initialization does not initialize implicitly. Wrappers belong to one
instance and one Lua state; another instance cannot use them. After an exit,
`call`, `callTask`, `drain` and `run` reject and `notify` throws
`TITAN_BROWSER_EXITED`; `dispose` stays available.

A callable wrapper also has `call(...args)`, `callTask(args, options)` and
`release()`. `release()` is synchronous and idempotent and never throws. The
wrapper stops working at once, and in the same call Titan gives up the hold
that the wrapper had on the function, so a function that nothing else holds
can be collected. The call runs none of the program's Titan code and no
finalizer, and it is allowed anywhere, including inside a binding and during
a drive. Where the instance cannot be entered (once `dispose()` has begun,
after an exit, or after an engine failure), `release()` only invalidates the
wrapper, and the function is let go when its Lua state closes.

**Exclusive entry.** One logical operation owns the instance from argument
validation through all protected C entries and output flush. Promise
microtasks used by coroutine switching or GC cleanup do not release that
admission. Immediate reverse calls during a binding or output sink reject
with `TITAN_BROWSER_REENTRY`; they do not synchronously throw into the
binding's `try/catch`. Observe the rejected promise, or use `notify`. A sink
never runs from a Wasm import or an internal JSPI handoff. Independent
instances can progress concurrently. A general entry never starts
synchronously inside the method that requested it: the operation begins in a
later microtask, after the caller's synchronous code returns.

Options are:

| Option | Contract |
| --- | --- |
| `stdout`, `stderr` | Functions receiving copied `Uint8Array` chunks, which they may keep. A sink returns `undefined` or a promise; anything else is a sink failure. An absent sink discards its stream. |
| `stdin` | A function called once per `titan:stdin` read, synchronously as a binding is. Returns a `Uint8Array` chunk (including an empty chunk), `null` or `undefined`, or a promise of one of those values. Without it, `titan:stdin` is an unknown binding. |
| `stdinKind`, `stdoutKind`, `stderrKind` | Declared stream backings, passed through unchanged by `titan:stdio`. The loader supplies no default and does not validate these values. |
| `stdoutEnd`, `stderrEnd` | Functions called by argumentless `titan:stdout` or `titan:stderr` requests, after earlier entries on that stream. Like sinks, they return `undefined` or a promise. A missing hook rejects the request with `TypeError`. |
| `locateFile(name, directory)` | Resolves both the Wasm binary and its trace table (`<stem>.wasm.trace`). The defaults keep bundler-recognizable `new URL(..., import.meta.url)` references to the sibling files. |
| `requireTrace` | Boolean, default `false`. Requires a ready trace table after Wasm instantiation and before Lua is created or any initializer runs; a refusal follows the ordinary initialization-failure contract. |
| `bindings` | An object of explicit per-instance JavaScript values and functions for `titan.browser`; there is no global-name lookup or eval. Names starting with `titan:` are [reserved for the SDK](standard-library-browser.md#reserved-sdk-bindings) and rejected with `TypeError`. |
| `env` | An object whose own enumerable string-named properties have string values, snapshotted at `create`. Absent means empty. Non-objects (including `null`), empty names, `=` or NUL in a name, NUL in a value, and non-string values are rejected with `TypeError`. |
| `onNotificationError({kind, operation, error})` | Observes errors that Titan cannot return to any caller: failed notification callbacks, a request failure event that cannot be delivered, and secondary cleanup failures. A host Promise rejection instead goes to its mandatory failure callable. |
| `requestDrain()` | A coalesced announcement of queued work at a complete logical safe point; the application chooses when to call and await `drain()`. |
| `onEngineFailure({kind, cause})` | Observes a terminal engine failure after the instance has been poisoned; `kind` is `"abort"`, `"trap"`, or `"protocol"`. Observer exceptions cannot replace that failure. |

The notification-error event's `kind` is `"callback"` or `"cleanup"`.
`operation` identifies `initialize`, `run`, `call`, `callTask`, `drain`,
`dispose`, or `notify`; a failed work announcement uses `requestDrain`.
In-operation cleanup, and a notification delivered by a drive, use the
containing public operation's name. Each failure is reported once. Without an
observer, the loader logs each event with `console.error`. An observer that
throws cannot replace a captured or
terminal failure; the current operation, or else the next one that would
otherwise succeed, rejects with `TITAN_BROWSER_HOST`.

**Environment.** Each instance starts with exactly its `env` snapshot, empty
by default, without Emscripten's invented environment variables. Names and
values are encoded as UTF-8. C `getenv` and stock Lua `os.getenv` read the same
libc environment; Titan's C FFI reaches those same functions. C `setenv` and
`unsetenv` change later reads in that instance, not its peers or the host.
`TZ` is an ordinary environment variable: Emscripten's `localtime` follows
the JavaScript host's time zone regardless of its value.

The `stdin` option serves the SDK request source, not C stdio's fd 0. Its
result is marshalled by runtime type; Titan decides which values are valid
input. Calling back into the instance from `stdin` rejects with
`TITAN_BROWSER_REENTRY`, just as from another binding. When supplied, `stdin`,
`stdoutEnd`, and `stderrEnd` must be functions; other values raise `TypeError`
at `create`.

**Output.** Each stream has one FIFO and at most one sink or end-hook call
in flight. The loader flushes after all entries in the containing operation,
including unterminated C-stdio output, and during a drive also whenever the
drive relinquishes the event loop, without waiting there for a pending sink
call: output queued behind that call reaches the sink once the call settles,
if the drive is still relinquished, and otherwise at its next relinquish or
the operation's end. A sink call starts only then, never while the drive
runs. Later chunks continue after a sink throws or rejects. An otherwise
successful operation rejects with its first
cleanup failure; secondary failures are reported once through
`onNotificationError`. If the operation already failed in Titan, its captured
message and trace remain primary while deliverable output is still flushed.
There is no cross-stream ordering guarantee.
C output is copied before the C write returns; sinks do not see a view into
the Wasm heap. Chunk boundaries are not part of the C-stdio contract.
A Titan write through `titan:stdout` or `titan:stderr` is one FIFO entry. Its
request completes only after that entry's sink settles. An argumentless
request is an end entry: its end hook uses the same FIFO and in-flight gate.
A Titan entry's sink or hook failure goes to its failure callable, not also
to the containing operation or cleanup observer.

A C-stdio sink failure is returned by the operation that flushes it, or by
disposal if the operation already failed in Titan. It is also returned once
by the next Titan write request on that stream, after that entry's sink
settles; later writes are unaffected. Empty flushes and unrelated
output-free operations do not fail again with that error, and observing the
operation's failure does not report it again as cleanup.

Disposal interrupts a pending sink by detaching its continuation and making
that stream terminal; it never overlaps the old sink with a finalizer write.
Queued and in-flight Titan entries reject with `TITAN_BROWSER_DISPOSED`
during the cleanup drive, before disposal waits for retained requests.
An operation whose failure was already captured keeps that failure if disposal
interrupts its report flush; the interruption is reported once as cleanup,
even when both streams are interrupted. Only an operation not yet failed
rejects `TITAN_BROWSER_DISPOSED`. Disposal retains its own output/error outcome,
including `TITAN_BROWSER_DISPOSED` for interrupted or discarded buffered bytes.
Normal `await run(); await dispose()` delivers finalizer output. That output
is delivered after the image's native state has been released, so even a
never-settling sink and an externally retained disposal promise do not keep
the disposed image alive. Caller closures that independently retain the
instance are outside this rule.

**Host work.** A tracked request explicitly chooses detachable work
(`{kind: "detachable", promise, cancel?}`) or guaranteed-terminal retained
ownership (`{kind: "retained", promise, cancel?}`). Never-settling work must be
detachable. A listener uses
`{kind: "listener", subscribe(emit) { return unregister; }}`. Its synchronous
events only enqueue. Cancellation signals the host; it is not proof that
retained work has physically retired. Late and duplicate settlements never
enter Lua after cancellation, release, state close, or disposal. If the bridge
cannot create a request's owner, it neither starts the host source nor
registers the listener.

Start and listen take both a success callable and a mandatory failure callable.
One-shot `start` completion receives one `BrowserValue` argument (the settled
value marshalled by runtime type, with `undefined` mapped to `is_nil()`);
`listen` passes each emitted argument marshalled by runtime type. Failure
receives `(BrowserValue.is_string(message), BrowserValue.is_handle(thrown))`:
the diagnostic message text and a handle retaining the exact rejected
JavaScript value (even for a primitive). Both outcomes are queued and
delivered under protection; a Promise rejection is not merely logged to an
observer.

A `start` settlement or `listen` emission that cannot be marshalled is
delivered to `failure` too, with the marshalling error as `thrown`.
Marshalling can fail when the event is queued (an out-of-range `BigInt`) or
when it is delivered (a wrapper argument released in the meantime). In the
second case the failure event joins the queue behind the events already
waiting, so it arrives in a later batch. `onNotificationError` receives what
no callable can: an error that `completion` or `failure` raises when it is
delivered, and a failure event that itself cannot be marshalled.

**Observation and errors.** `instance.trace` is a fresh frozen `{state,
reason}` snapshot, including before initialization. It preserves the last
trace state and reason after ordinary or poisoned disposal without retaining
the image.

A rejected promise, or an exception from a synchronous method, carries an
`Error` whose `name` is `TitanBrowserError`, with a `code`, a message, and,
where there is one, the original error as `cause`:

| `code` | When |
| --- | --- |
| `TITAN_BROWSER_TITAN` | An ordinary Titan error from initialization or a call. `message` decodes the error text; `bytes` holds the exact copied message bytes, `trace` the original raw trace bytes (absent for a required-trace refusal), and `status` the completion status. A later valid call on the intact instance still works. |
| `TITAN_BROWSER_REENTRY` | A general operation while another is active, including an immediate call from a binding or sink, and work for another Lua state while the owner drives. |
| `TITAN_BROWSER_STATE` | `call`, `drain`, or `notify` before successful initialization, a second `run`, an operation that needs a new identity after identities are exhausted, or a Task-form call without an `async` Runtime or for another Lua state. |
| `TITAN_BROWSER_CANCELLED` | A Task-form call whose Task was cancelled; `reason` holds the `AbortSignal`'s reason when the signal cancelled it, otherwise the cancellation reason text. |
| `TITAN_BROWSER_EXITED` | Work after a drive exited, or an entry whose drive exited; `status` holds the latched exit status. |
| `TITAN_BROWSER_DISPOSED` | Work after disposal began, an operation that disposal interrupted before it failed, or buffered output that disposal could not deliver. |
| `TITAN_BROWSER_HANDLE` | A released or foreign callable wrapper, or a handle of a closed Lua state. |
| `TITAN_BROWSER_SINK` | An output sink threw, rejected, or returned something other than `undefined` or a promise; `stream` names the stream. |
| `TITAN_BROWSER_HOST` | Host cleanup that the bridge could not complete, such as a throwing request `cancel` or listener `unregister` during disposal, or a throwing `onNotificationError` observer. |
| `TITAN_BROWSER_CAPABILITY` | The engine lacks WebAssembly JSPI. |
| `TITAN_BROWSER_ABORT`, `TITAN_BROWSER_TRAP`, `TITAN_BROWSER_PROTOCOL` | The engine aborted or trapped, or the image broke the completion protocol. The instance is poisoned: later application methods reject this saved failure, and disposal drops the image without entering Wasm again. |

Invalid `create` options throw `TypeError` synchronously. Out-of-range `BigInt`
values (outside signed 64-bit range) and ill-formed UTF-16 strings (containing
a lone surrogate, where `str.isWellFormed()` is `false`) reject `call` or throw
from `notify` with `TypeError`, as do invalid `run` arguments. Other argument
values cross by runtime type as `BrowserValue`, and a Titan callable that
rejects a variant raises an ordinary Titan error (`TITAN_BROWSER_TITAN`).

Operation identities are never reused, and the last one is reserved for
disposal. Once the others are used up, an operation that needs a new identity
is refused with `TITAN_BROWSER_STATE`. A method that needs none still works:
`notify` enqueues, and a `drain` with nothing to deliver succeeds. A queued
notification that cannot get an identity when it is delivered is reported
through `onNotificationError` with that same error, like any other
notification failure. Disposal's `async` Task cleanup also needs ordinary
identities. With none left, disposal skips that cleanup but still closes the
state with the reserved identity, and `dispose()` rejects with the
`TITAN_BROWSER_STATE` error.

Byte argument snapshots for `call`, `callable.call`, `notify` and `run` read
native `Uint8Array` storage, including subarrays, subclasses and Node Buffers.
Custom iterators, byte-view accessors and constructor/species hooks cannot
substitute bytes. A Proxy around a byte array has no native TypedArray slots,
so `run` rejects it with `TypeError` while `call` and `notify` marshal it by
runtime type as an opaque `is_handle(BrowserHandle)` without invoking Proxy
traps.

The test runner reports observed aborts and traps even if a test catches their
operation rejection. A completion-protocol error that the test explicitly
handles stays local to its poisoned instance; if the operation rejection
escapes, the runner reports a harness failure.

### Calls during a drive

While a drive runs (an `async` Runtime driving its Tasks), the instance keeps
its execution owner for the whole drive, and JavaScript runs either
synchronously inside a binding or sink that Titan invoked, or anywhere else:
in other browser tasks while the driver is relinquished, and in microtasks
between its internal coroutine hops. Admission depends only on that
distinction:

| JavaScript action during a drive | Inside a binding or sink | Anywhere else |
| --- | --- | --- |
| `call()` | rejects `TITAN_BROWSER_REENTRY` | queued; the driver invokes it at its next turn, outside any Task, and its promise settles when the call returns |
| `callTask()` | rejects `TITAN_BROWSER_REENTRY` | queued Task start; its promise settles when the Task's outcome arrives, or rejects at once if the Task cannot start |
| `notify()` | queued for the driver | queued for the driver |
| `drain()`, `run()` | reject `TITAN_BROWSER_REENTRY` | reject `TITAN_BROWSER_REENTRY` |
| `dispose()` | closes admission and wakes the drive | closes admission and wakes the drive |

A queued call's promise settles while the driver is still inside that turn,
so the code awaiting it can run before the turn ends, between two of the
driver's internal steps. A `call()` or `callTask()` made there is queued for
a later turn, and `drain()` and `run()` still reject
`TITAN_BROWSER_REENTRY`.

Calls and notifications for a Lua state other than the instance owner are
refused during a drive with `TITAN_BROWSER_REENTRY` (`"calls for another Lua
state are not admitted while the owner drives"`). A queued call behaves like
an idle call, except that starting another drive inside it fails. A call
queued too late for the drive's last turn runs on its own once the drive's
operation ends. Request settlements, listener events and notifications for
the owner state wake a relinquished drive; they never enter Wasm themselves.
Buffered output reaches the sinks while the drive is relinquished, before the
drive ends, and a slow or forever-pending sink never stalls the drive.

### Task-form calls

`instance.callTask(callable, args = [], {signal} = {})` and
`callable.callTask(args = [], {signal} = {})` start the callable as an `async`
Task with the marshalled arguments and resolve to its single decoded result,
boxed like `call` so a returned thenable never holds admission. On an idle
instance the call drives the Runtime until its Tasks finish; during a drive it
is queued and joins that drive. Admission is as for `call`.

- An image whose owner state has no `async` Runtime rejects with
  `TITAN_BROWSER_STATE` (`"browser image has no async Runtime"`), and a
  callable of another Lua state with `TITAN_BROWSER_STATE` too.
- A Task that fails rejects with `TITAN_BROWSER_TITAN` carrying its `bytes`,
  `trace` and `status: 1`.
- An `AbortSignal` that is already aborted rejects with
  `TITAN_BROWSER_CANCELLED` (`reason`: the signal's reason) without starting a
  Task. Aborting it later cancels the Task with `String(signal.reason)` as
  the cancellation reason; the promise then rejects with
  `TITAN_BROWSER_CANCELLED` and the signal's original `reason`. A Task
  cancelled any other way rejects `TITAN_BROWSER_CANCELLED` with the reason
  text, or `TITAN_BROWSER_DISPOSED` during disposal.
- A Task-form call still running when its drive exits rejects with
  `TITAN_BROWSER_EXITED`. A queued call whose Task already finished keeps
  its result.

### Exit

A drive that ends with an exit status (Titan's `request_exit`) latches the
instance as exited. The entry that drove reports it: `run()` resolves
`{kind: "exited", status, bytes}` with empty bytes, and a `call()` or
`callTask()` whose drive exited rejects with `TITAN_BROWSER_EXITED` (`status`
holds the latched status). An entry that failed reports its failure even
when the latch was set during its drive. In every case the latch stands:
later `call`, `callTask`, `drain` and `run` reject and `notify` throws
`TITAN_BROWSER_EXITED`. `dispose()` stays available and still runs the
state's finalizers. Exiting never touches the page or the Node process.

A queued call that already settled keeps its result, including a Task-form
call whose Task finished before the exit. Calls still running or never
delivered when the drive ends reject with `TITAN_BROWSER_EXITED`.

### Disposal with a running Runtime

`dispose()` closes application admission at once: unsettled queued calls and
Task-form calls reject with `TITAN_BROWSER_DISPOSED`, and queued application
notifications are dropped. A call that already settled keeps its result. A
drive that is running is woken and cancels its Tasks with `"instance disposed"`;
with no drive, the `async` Runtime's own shutdown runs that cleanup. While it
runs, settlements and events of host work started before `dispose()` keep
reaching the owner state, so cleanup that awaits that work completes; new
host work fails with `"browser state is closing"`. Requests still open when
the cleanup ends are then cancelled, retained ones settle, and the state
closes. An exited instance has no Runtime left to clean up.

### Synchronous C callbacks

An Emscripten API that calls a C callback, such as an `html5.h` event
handler, calls it synchronously. A callback that runs Titan code through
`titan_browser_call_sync` is not an entry and does not wait for one: it runs
whenever the instance is open, during a drive or not, and is refused once
`dispose()` has begun, after an exit, or after an engine failure. JavaScript
reached from a callback follows the usual rules: a binding that the callback's
Titan code calls counts as inside a binding, and the JavaScript that dispatched
the callback does not. On an idle instance:

| JavaScript during a synchronous callback | Result |
| --- | --- |
| `call()`, `callTask()`, `drain()` or `run()` in a binding the callback's Titan code called | rejects `TITAN_BROWSER_REENTRY` |
| the same outside any binding, for example in the code that dispatched the event | admitted; the entry starts after the callback returns |
| `notify()` | queued for a later `drain()` or drive |
| `dispose()` | closes admission at once; the state closes after the callback returns |

A callback that ends by an exception instead of returning, including
authored C that suspends inside it, poisons the instance (`onEngineFailure`
kind `"protocol"`). The [JavaScript bindings
chapter](standard-library-browser.md#synchronous-c-callbacks) describes the
Titan and C side.

## Testing from the command line

Pages run programs through the loader. For tests, `titan-browser-run` runs a
program or test image from the command line, under Node 26 or newer or in
headless Chrome or Chromium, through the same loader that a page uses, and
turns the result into an exit status, so that test suites and continuous
integration can check browser builds. Web pages do not use it.

```sh
titanc --target browser -o out --exe out/app.mjs app
titan-browser-run out/app.mjs -- first second
```

The first command builds `out/app.mjs`, `out/app.wasm`, `out/app.wasm.trace`,
and `out/app.wasm.map` from the module `app`, which defines `main`. The second
runs the program under Node with the arguments `first` and `second`, copies
its output byte for byte, and exits with its status. A test image built with
`--test` runs the same way (see [tests](#tests)).

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
| `--root DIR` | The directory served to the engine; defaults to `FILE`'s directory, and must contain `FILE`, its `.wasm`, and (unless `--allow-degraded-trace` is set) its `.wasm.trace`. |
| `--allow-degraded-trace` | Permit missing, malformed, or mismatched trace tables by creating images with `requireTrace: false`; otherwise a table failure is an ordinary initialization failure before Lua or main, not an infrastructure failure. |
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
| `status & 255` | The program completed with `status`: the value `main` returned, 1 after an uncaught error, or the status of an [exit](#exit). A test image exits 0 when every selected case passed, 1 when a case failed, and 2 for invalid test options. |
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

A browser program completes in one of three ways:

* **Returned.** `main` returned an integer. The status is its low 32 bits read
  as a signed 32-bit integer, so `-1` stays `-1` and `4294967297` becomes `1`.
  The runner then exits with `status & 255`.
* **Failed.** An error escaped `main` or the module initializers. With the
  async bootstrap, a failed main Task writes its uncaught Task report to
  stderr. An initializer error or a directly called main writes the standalone
  report: `<progname>: <message>`, then `stack traceback:`, then one
  tab-indented line per frame. The status is 1. `<progname>` is the last
  component of the main module's name, or of the first test root's name for a
  test image. A required trace table that is missing or invalid also fails
  initialization with status 1: stderr receives
  `degraded browser trace: <reason>`, without a traceback because no Titan
  code ran.
* **Exited.** A drive ended with an exit status (`request_exit` in an `async`
  Task) and `main` then completed without an error. The status is the exit
  status's low 32 bits read as a signed 32-bit integer, and the runner exits
  with `status & 255`. An error that escapes `main` after the exit still
  makes the program failed.

Main completes when it returns or fails, and its output (including an
unterminated last line) is delivered then. The state and callable handles
remain alive until explicit disposal. The runner awaits disposal and its
finalizer output before reporting completion. Output is binary: NUL, `0xFF`,
and invalid UTF-8 pass through unchanged. C standard input fails with an
`ENOSYS` error: `fread` returns zero with `ferror` set, not EOF, and opens no
input dialog. There is no filesystem: C file operations such as `fopen`,
`remove`, `rename`, `tmpfile`, and `tmpnam` fail. `system(NULL)` reports no
shell, and `system(command)` fails without executing a host command, under
Node as well as in a web page.

### Traces

When a web page or application initializes a browser image (or when tests run
it through `titan-browser-run`), the runtime eagerly loads `<stem>.wasm.trace`
before `main` or any module initializer runs and verifies that its embedded
build identity matches the instantiated `.wasm`. The compiler derives this
table from the final source map: it holds only the `.titan` locations and the
function names that traces use, so loading it takes a few milliseconds.
Nothing is fetched or awaited when an error is raised or when
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
* If a Titan frame's program counter has no `.titan` line mapping inside its
  function body, the frame uses the no-line form
  `<basename>: in <display name>` (with the function's declaring `.titan`
  basename, or `?` when none is known), never a synthetic `:0:` line. That
  covers an unmapped instruction and C code that the optimizer inlined into
  the function: a Titan frame never shows a C file.
* Lua frames (`source:line: in name` or `source: in name`), genuine Lua C
  functions (`[C]: in name`), and `(...tail calls...)` interleave with
  compiled Titan runs in innermost-to-outer call order. Entry wrappers,
  runtime frames, Lua core/library C frames, and unmapped helper exports are
  filtered out, and an unmapped helper adjacent to a Titan function never
  inherits a Titan line.
* `titan.backtrace()`, the `traceback` local in a `catch` block, bare `raise`
  re-throwing, caught-trace clearing, and coroutine trace propagation and
  append behave as on native hosts, including across coroutine yields and
  resumptions. The same holds for `async` Tasks that the driver resumes after
  it hands control back to the page (a turn, or a wait for a timer, a
  JavaScript request or a channel), for handlers and calls that the driver
  delivers, for `async.Error:raise()` handoffs and for cleanups during
  cancellation. The `trace` that JavaScript receives for a failed Task-form
  call, a failed call or notification that a drive delivered, or a failed
  `main` Task has these same frames.

**Optimized frames.** As in a native production build, a `production` image
has no frame for a function that the optimizer inlined into its caller. A
frame that does appear is still exact, and an inlined Titan function's line is
reported under the name of the function that absorbed it. Where the inlined
code is the runtime's own C, the frame has no line: a production `async`
program's traces show `coroutine.titan: in titan.coroutine.coro_entry_trampoline`
where `validation` shows `coroutine.titan:44`. Titan's own trace fixture
`trace_uncaught.titan` shows the difference:

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

**Deploying `.wasm.trace` and degraded mode.** A web server serving a browser
image must serve `<stem>.wasm.trace` next to `<stem>.wasm` (or map both
through `locateFile`). The source map is optional: the runtime never reads it.
If `<stem>.wasm.trace` cannot be loaded, is malformed, or does not
match the instantiated `.wasm` image, Wasm instantiation logs one console
warning (`Titan browser trace: <reason>`). By default an embedding permits
degraded mode; with `requireTrace: true`, initialization instead fails before
Lua or any module initializer runs. In permitted degraded mode, every trace
generated by that instance contains the Lua frames plus one marker line:

```text
(native Titan frames unavailable: trace table not loaded)
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

The browser SDK's `titan.a` holds twenty-one standard modules that need no
libuv or other native-only library: fourteen complete shared modules, browser
compositions of `async`, `timer`, `os`, `lua`, `http`, and `websocket`, and the
browser-only `titan.browser`. A *complete* module has every public declaration
of its native interface; a *subset* module lacks some of them, and the browser
compiler rejects a use of a missing one like any undeclared name:

| Module | Availability | Contents |
| --- | --- | --- |
| [`coroutine`](coroutines.md) | complete | stackful coroutines |
| [`gc`](standard-library-gc.md) | complete | weak Maps, ephemerons, finalizers, and collector control |
| [`iteration`](standard-library-iteration.md) | complete | Map and Array iteration |
| [`math`](standard-library-math.md) | complete | numeric functions and random numbers |
| [`string`](standard-library-string.md) | complete | byte strings, formatting, packing, writers, and regular expressions |
| [`peg`](standard-library-peg.md) | complete | parsing expressions |
| [`url`](standard-library-url.md) | complete | URL parsing and construction |
| [`path`](standard-library-path.md) | complete | lexical paths |
| [`reflect`](standard-library-reflect.md) | complete | runtime reflection |
| [`json`](standard-library-json.md) | complete | JSON encoding and decoding |
| [`protobuf`](standard-library-protobuf.md) | complete | Protocol Buffers encoding and decoding |
| [`transfer`](standard-library-transfer.md) | complete | transfer policies and native message packets |
| [`test`](standard-library-test.md) | complete | the test API and the native test runner |
| [`io`](standard-library-io.md) | complete | byte-stream Interfaces, one-write printing, and ownership-safe line iteration |
| [`async`](async-io.md#the-browser-target) | subset | Tasks, cancellation, waits, channels, combinators, and subscriptions, driven between browser macrotasks |
| [`timer`](standard-library-timer.md#on-the-browser) | complete | Task delays, yields, and coalescing tickers on JavaScript timers |
| [`os`](standard-library-os.md#on-the-browser) | subset | calendars, wall time, locale, instance environment, Task exit, and embedding-provided parent streams |
| [`lua`](standard-library-lua.md) | subset | string and Reader loading, preload/custom-searcher `require`, and synchronous independent states |
| [`http`](standard-library-http.md#on-the-browser) | subset | headers, request options, and the streaming HTTP client over `fetch` |
| [`websocket`](standard-library-websocket.md#on-the-browser) | subset | the message-oriented WebSocket client over the host's `WebSocket` |
| [`browser`](standard-library-browser.md) | browser only | JavaScript bindings, `BrowserValue` runtime-type marshalling, pinned callables, handles, and tracked host requests |

The six other standard modules are [not available](#modules-that-are-not-available).
A declaration that a browser module keeps has its native signature, including
its parameter names, generic parameters, and whether its records can be built
from a literal and its unions matched exhaustively. A browser module never adds a
public declaration that its native module lacks.

Each of the fourteen shared modules keeps its complete interface. Every public
declaration, including the raw C functions `protobuf.write_resource_index`,
`protobuf.write_resource_index_bytes`, `transfer.copy_message`,
`transfer.discard_message`, and `transfer.transfer_load_module`, has the same
signature as on a native target and behaves as its chapter describes, apart
from the target facts [below](#what-the-browser-target-changes). There are no
stand-in implementations; errors from concrete `io` streams propagate
unchanged. `transfer` encodes and decodes packets within one instance.
`lua` uses its own synchronous cross-state carrier, not packet attachments.

`async` shares its scheduling core with the native module and keeps its
public signatures, except for the members that the browser cannot provide:
the libuv-typed `current_loop`, `await_with`, `await_cleanup_with`,
`await_cancellable_with`, and `await_cancellable`; the native-only
`run_foreign`, `prepare_native_retirement`, `wait_external_native`,
`prepare_external_wait`, `wait_external`, `wait_external_cleanup`,
`version`, `receiver`, `send`, and `Receiver`. `ExternalWait` remains only
as a type with no constructor and no methods, so the `final_wait`
of `run_with_cleanup` can only be `nil`. `Completion` keeps its methods but
no browser function hands one out, since the functions that do are absent.
Its Tasks run only in the
instance's owner state, under a drive that gives the page one macrotask
between turns ([async on the browser target](async-io.md#the-browser-target)).

`timer` keeps its complete interface. Its sleeps and tickers run on
JavaScript timers, with the browser's clamping and throttling; `sleep(0)` is
a yield that arms no timer ([timer on the browser](standard-library-timer.md#on-the-browser)).

`os` keeps its calendar, locale, environment, and parent-stream interfaces.
Its time query uses the host wall clock, environment mutations stay within
the instance, and standard streams use the embedding's byte sinks and optional
input source. CPU time, host paths and identity, child processes, and signals
are absent. See the [per-member availability table](standard-library-os.md#on-the-browser)
and [browser parent streams](standard-library-os.md#browser-parent-streams).

`lua` keeps string and Reader loading, `require`, and independent-state
ownership and synchronous execution. `dofile`, `Lua:run_async`, and
`Lua:run_async_from_loader` are absent. File searches miss, while initialized
linked modules and custom searchers work; the Titan searcher never reads
provider-path environment variables or probes files. Each new state belongs
to the same instance and cannot drive browser Tasks. Stock Lua's `os.clock`
raises instead of reporting CPU time, and its `os.exit` uses Titan's Task exit
or raises outside a Task. See [the Lua chapter](standard-library-lua.md),
including its stock-library table.

`http` keeps its headers, request options, and client: `Client`,
`ClientResponse`, `request`, `get`, and `close_idle_connections` run over the
host's `fetch`. Servers, protocol upgrades, and `Exchange` handoff are absent.
The browser follows redirects by default (natively the redirect response is
returned), applies its HTTP cache, cookies, CORS, and certificate trust,
rejects the request headers that browsers forbid before anything is sent, and
returns decoded response bodies. Network failures raise
`async.OperationError` named `"EIO"`, never `ssl.Error`. See
[HTTP on the browser](standard-library-http.md#on-the-browser).

`websocket` keeps its message-oriented client over the host's `WebSocket`.
The server, `Connection:ping`, and the transfer hooks are absent, and dial
options with headers or a `ca_file` raise. Opening failures raise
`HandshakeError` without a status or headers, the browser negotiates
compression, and `close()` lets the browser finish the closing handshake. See
[WebSocket on the browser](standard-library-websocket.md#on-the-browser).

Both clients need the instance's active async Runtime: in a state created by
`lua.new()`, their network calls raise `"async Runtime is not active"`, while
headers, options, and `http.Client.new` still work.

`titan.browser` is the reviewed target-only exception. It has no native
placeholder and imports only `gc`. Its byte/scalar ABI is not the
native transfer packet format, and schema copies are a separate feature. It
provides the [drive primitives](standard-library-browser.md#driver-interface-low-level)
that the `async` driver uses but schedules nothing itself. See
[JavaScript bindings](standard-library-browser.md).

### Modules that are not available

The other standard modules are absent from the browser target:

| Module | Reason |
| --- | --- |
| `fs` | requires a filesystem |
| `net` | requires native sockets |
| `sqlite3` | requires the native SQLite library |
| `ssl` | requires OpenSSL and native sockets |
| `thread` | requires OS threads |
| `uv` | requires libuv |

Each has only a native main, either a flat variant such as
`titan/fs.native.titan` or a folder main such as `titan/uv/uv.native.titan`
(see [target source selection](target-source-selection.md)), so a browser
build finds no source and no browser archive for them. The browser SDK lists
them, and an import of one, in either the plain or the `.titan` form, fails
with a diagnostic that names the module, the target, and the reason:

```text
module 'titan.fs' is not available for target 'browser': requires a filesystem
```

Before the browser SDK is installed, the same import reports the ordinary
`module 'titan.fs' not found`. There are no stand-in modules for them, and
their folder contributors, such as `titan.uv.tcp`, are not importable on their
own. A test module that imports one of them cannot be built into a browser
test image either; keep such cases in native-only test modules.

### Unavailable operations

No browser member is a placeholder that always raises: a member the browser
cannot provide is absent, so its use fails at compile time. A few members that
do exist depend on something the embedding or the calling context may not
supply. When it is missing, they raise an error whose message starts with the
member's qualified name followed by `is unavailable`:

| Operation | Raised error |
| --- | --- |
| `os.stdin` `read` or `read_until` when the embedding supplied no input source, or a parent stream's `kind` when the embedding declared none | `async.OperationError` with `name` `"ENOSYS"`, `operation` the qualified member (`"os.InputStream.read"`, `"os.InputStream.read_until"`, `"os.InputStream.kind"`, or `"os.OutputStream.kind"`), and the message `"<operation> is unavailable on the browser target"` |
| `os.exit` outside an async Task | `"os.exit is unavailable outside an async Task on the browser target"` |
| stock Lua `os.clock` | `"os.clock is unavailable on the browser target (no process CPU-time clock)"` |

Test an `OperationError` by its `name` and `operation`, not its target-specific
`code`. Each such call raises before it has any effect, and repeating it
raises the same error.

Programs can write through `io.print` and `os.stdout`/`os.stderr`, or through
C's `stdio.h` as in [the program example](#programs).
Both routes reach the loader's sinks byte for byte; Titan stream writes also
await each sink's completion ([status and output semantics](#status-and-output-semantics)).

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

Launcher images disable Emscripten's filesystem; this does not affect binary
standard output and standard error.

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

Titan refuses options that add a file to the generated module or its data:
`--pre-js`, `--post-js`, `--extern-pre-js`, `--extern-post-js`,
`--js-transform`, `--embed-file`, `--preload-file`, and `--exclude-file`.
Titan could not tell when such a file changes, so a rebuild could keep a stale
module. Add JavaScript with `EM_JS` or `EM_ASM` in a [C
helper](#c-helpers-and-emscripten-apis) instead:

```text
browser production link profile does not accept --pre-js; add JavaScript with EM_JS or EM_ASM in a --c-source helper
browser production link profile does not accept --embed-file; browser images have no filesystem
```

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
published `.mjs`, `.wasm`, `.wasm.trace` and `.wasm.map` unchanged. Titan does
not split or outline an oversized function automatically.

Static byte size does not bound startup memory. The [implementation
measurements](../implementation/browser-target.md#build-time-image-bounds)
record observed startup memory for a large-function program and a complete
standard-library test image on Linux and macOS; they are measurements, not a
startup-memory guarantee.

A browser program runs with these sizes:

| Resource | Size | When it runs out |
| --- | --- | --- |
| Main linear C stack | 1 MiB | Checked C-stack overflow aborts rather than silently overwriting memory. Lua's ordinary C-call limit can reject mixed recursion first. |
| Coroutine linear C stack | 256 KiB per coroutine (2 MiB natively) | The same checks and bounds follow each continuation across suspension and memory growth. |
| Engine continuation stack | Managed by the JSPI implementation | Engine stack exhaustion is fatal; the linear-stack budget does not bound engine memory. |
| Linear memory | The program's static data and main stack plus a 15 MiB heap initially (about 16 MiB for a small program), growing to at most 2 GiB | A failed native allocation produces the ordinary Lua/Titan allocation error when the state still has enough memory to report it. Engine allocation failures are fatal. |

Linear coroutine stacks are allocated when a coroutine is created. A finished
engine invocation retires before its native allocation can be freed or reused.
Freed linear blocks are reusable, but grown WebAssembly memory never shrinks
back to the host.

Repository validation locates each measured stack and recursion boundary
between a passing lowest sample and a declared failing ceiling, narrowing to
adjacent samples at the declared step size. Those search ceilings only bound
the measurement; they are not additional program limits or portable
recursion-depth guarantees.

Ordinary Titan recursion, whose frames keep little on the linear stack,
usually runs out of the engine's call stack first, which ends the run as an
engine failure rather than a catchable error. CI records the release
profile's deepest recursion, its Task count at the memory limit, and its
memory use on each engine ([records](../implementation/browser-target.md#records));
they are measurements, not guarantees.

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
| `protobuf` encoding, decoding, and `protobuf.schema`; `transfer` packets and structural records/unions | the shared 128-level codec budget: 127 nested records at a nominal root, or 126 in a field of an anonymous root (`serialize_fields`, `deserialize_fields`, `protobuf.portable` and the SDK peer) | `protobuf: nesting exceeds 128 levels`, with a [position suffix](standard-library-protobuf.md#errors) for located encoding or decoding failures |
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

* The browser standard library has [twenty-one standard
  modules](#the-browser-standard-library), including `io`, the `os` subset,
  synchronous `lua` states, and the `http` and `websocket` clients. Files, raw
  TCP and TLS sockets, HTTP and WebSocket servers, child processes, host
  paths and identity, CPU time, `thread`, and `sqlite3` remain unavailable.
* `async` Tasks run only in the instance's owner state and only while a drive
  runs: the program's `main`, a call that calls `async.loop()`, or a
  Task-form call. Receivers, `run_foreign`, and external waits are
  native-only ([async on the browser target](async-io.md#the-browser-target)).
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
* `Makefile.win` does not install the browser SDK, and the browser runner
  does not execute images on Windows.
* The language server analyzes the host target only.
* Native source coverage (`--coverage` and its backend/report options) is not
  supported for the browser target.

See [the browser target](../implementation/browser-target.md) in the
implementation manual for the descriptor, the SDK, the browser standard
library's provider, dependency-closure check, and subset parity gate, the build
profiles and their measurements, the link profile, the browser C-call limit,
the nesting-limit measurements, the entrypoint, the loader and runner
mechanics, the release profile's [records](../implementation/browser-target.md#records)
of size, startup, memory and recursion per engine, and the evidence behind the
design.
