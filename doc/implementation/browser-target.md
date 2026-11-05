# Browser target

`titanc --target browser` compiles Titan modules and authored C to
relocatable WebAssembly objects with Emscripten, publishes library-mode
providers as self-describing Wasm archives, and links programs and tests into
an ES-module factory (`.mjs`), its WebAssembly binary (`.wasm`), and its
extended source map (`.wasm.map`). A web page or application loads the image
through a Titan-owned loader, and tests and command-line workflows run it
under Node 26+, headless Chromium (`titan-browser-run`), and Playwright
Chromium, Firefox, and WebKit. The user contract is in the [browser-target
chapter](../language/browser-target.md) of
the language manual.

The implementation is spread over:

* `titan-compiler/browsertarget.lua`, which locates and pins the Emscripten
  tools, reads and verifies the fork's Lua build record, probes the target C
  facts, owns each build profile's object flags (`object_flags`), and builds,
  freezes, exports, and imports the browser target descriptor;
* `titan-compiler/browserlink.lua`, which owns the SDK asset layout
  (`sdk_assets`), the SDK readiness check (`require_sdk`), the link profile
  (`profile`), the owned-option check for user link extras
  (`validate_extras`), and the final-image import/export reader
  (`image_inventory`);
* `titan-compiler/browsertrace.lua`, which computes the content-derived image
  identity before entrypoint compilation, reads the final `.wasm` function
  imports, code-section body ranges, and `name` section with the bounded Wasm
  reader, validates the standard v3 `.wasm.map`, and rewrites it with Titan's
  `x_titan_*` trace extensions;
* `titan-compiler/browserentry.lua`, the protected entry, reporting,
  Lua-close, and libc-drain wrapper that every browser image shares;
* `titan-compiler/driver.lua`, which owns `installed_paths(root, target)`,
  context initialization and activation, the semantic-cache generation, the
  probe-cache and output-root isolation, worker transport, browser provider
  lookup, archive construction, structural validation, archive-only
  publication, the executing protocol runner, the program entrypoint, and
  image linking and publication;
* `titan-compiler/staticmetadata.lua`, with the bounded relocatable-Wasm and
  final-image section/LEB readers and the Wasm target fingerprint
  ([Static compiled modules](static-compiled-modules.md#relocatable-webassembly));
* `titan-compiler/incremental.lua` and `titan-compiler/linkcertificate.lua`,
  which fold the descriptor identity, the link profile, and the SDK assets
  into object and link certificates;
* `titanc`, which validates the target, requires `--output`, locks and marks
  the output root early, selects the archive-only or three-file image output
  set (`.mjs`, `.wasm`, `.wasm.map`), and checks the SDK before linking;
* the runtime sources `titan.c`, `titan_path.c`, and `ltitanlib.c`, whose
  host-only paths compile out under `TITAN_TARGET_BROWSER`, and the runtime
  headers `titan.h`, `titan/ffi.h`, and `transfer.h`, which carry a `__wasm__`
  include branch;
* `titan-runtime/browser/`: the private C/JS trace adapter header
  `titan-browser-trace.h`, the Emscripten JavaScript libraries
  `titan-browser-library.js` and `titan-browser-trace.js`, the loader
  `titan-browser.mjs`, and the runner `titan-browser-run` with
  `titan-browser-run.mjs`, `titan-browser-node-worker.mjs`, and
  `titan-browser-page.mjs`; and
* the Make targets `lua-browser` (`scripts/lua_browser.sh`), `browser-sdk`
  (`scripts/browser_sdk.lua`), and `titan-stdlib-browser-test`, with the
  build-owned [standard-library checks](#the-browser-standard-library) in
  `scripts/browser_stdlib.lua`, its command-line front end
  `scripts/check_browser_stdlib.lua`, and the suite's stream-separating runner
  wrapper `scripts/run_browser_stdlib.sh`.

The source label and the target name are both `browser`. `wasm32` is a
physical ABI and toolchain fact only: it never names a target, an SDK path
component, or a cache label.

## Scope

The browser target supports four kinds of work, all with an explicit
`--output` directory:

* object compilation with `-c` (with or without `--incremental`), including
  `--c-source` nodes compiled with the descriptor's `emcc` prefix;
* library mode: a no-`main` build publishes `<provider>.a` only, after the
  [structural validation](#library-mode-and-structural-validation) and the
  [executing protocol check](#the-executing-protocol-runner);
* [program and test images](#program-and-test-images): a build with `main`,
  or `--test` without `-c`, links `<stem>.mjs`, `<stem>.wasm`, and
  `<stem>.wasm.map` with the [link profile](#the-link-profile), the [browser
  entrypoint](#the-browser-entrypoint), and the post-link
  [source-map extension rewrite](#source-map-extensions-and-image-identity); and
* the C-only work these require: preamble, profile, enum-carrier, and
  acceptance C probes, and C-header preprocessing for `foreign import`.

`titanc` never runs a program or test image it links; the [runner](#the-runner)
does. The only image `titanc` executes is the temporary protocol probe.
The language server analyzes the host-native selection only: it ignores
`TITAN_TARGET` and creates no browser context.

### Bootstrap order

Bootstrap order: (1) the fork's `browser` target installs the verified browser
Lua (`PREFIX/lib/browser/liblua.a` and its record); (2) `luarocks make`
installs the compiler; (3) with only (1) and (2), `titanc --target browser`
permits C-only work into owned `--output` directories: object compilation,
and internal archive construction checked structurally; (4) `make
browser-sdk` builds and installs the runtime archive, loader library and
runner tool into `lib/titan-browser/<ver>/`; (5) it publishes the [core
stdlib provider](#the-browser-standard-library), protocol-probes it against
the runtime staged in step (4), and checks its dependency closure; (6) it
writes the browser SDK digest manifest last. Missing browser-SDK
paths are diagnosed, naming `make browser-sdk`, only when a program or test
is linked or when library-mode publication runs the executing protocol check;
compile-only work needs only the verified Lua pieces.

Step (4) also installs the browser LPegLabel archive, which step (5) links into
the provider as its only native payload. Every runtime and
LPegLabel object comes from `titanc --target browser -c --incremental
--print-c-objects --c-source ...`, so Make never duplicates the descriptor's
flags, and the archives go through the descriptor's `emar`/`emranlib` and the
staged member-verification path. `luarocks make` stays independent of emsdk,
and `make browser-sdk` works into an empty destination. A missing standard
provider is an ordinary provider miss with source fallback.

## The fork's `browser` target

The Lua fork pinned by the `lua-5.5.1` submodule owns the facts that do not
depend on a linked image. Its `browser` target builds a static Lua archive
with:

* `CC=emcc`, `AR="emar rcu"`, `RANLIB=emranlib`, and no `-fPIC`: a PIC Wasm
  object imports `GOT.mem`/`GOT.func` like a side module, which the static
  consumers reject;
* `-DLUA_USE_POSIX -DLUA_USE_BROWSER`, without `LUA_USE_DLOPEN` or readline,
  and `-DLUAI_MAXCCALLS=100` ([the browser C-call
  limit](#the-browser-c-call-limit));
* `-sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1` in `SYSCFLAGS`,
  with `MYCFLAGS` passed through and `CMCFLAGS` applied to every browser object;
* browser `LUA_PATH_DEFAULT`/`LUA_CPATH_DEFAULT` rooted at the empty
  `LUA_ROOT`, without the executable-relative `!/../` root; and
* its own object directory, `src/browser/obj`, separate from the native build.

`make install-browser PREFIX=<root>`, run in the fork, builds the archive if
needed and installs it. It writes only below `<root>/lib/browser`, never runs
a host Lua interpreter, and refuses an effective configuration that would make
the record false: a missing or wrong `emcc`, an effective `LUA_USE_DLOPEN`, a
missing `LUA_USE_POSIX`/`LUA_USE_BROWSER`, a longjmp mode other than `wasm`,
a missing or disabled explicit legacy EH setting, native exception-lowering
overrides, or position-independent flags. `fork_revision` comes from the
fork tree's own `.git`; a tarball build must pass
`FORK_REVISION=<40-hex commit>`. The fork's README documents the installer's
own failure modes and the record's byte formats.

Titan pins the fork commit through the gitlink, not through the record's copy
of the revision. `archive_sha256` is stable for one
commit, flag set, and Emscripten build, because `emar` archives are
deterministic.

### Wasm-EH longjmp contract

Emscripten 6.0.13 is pinned to `SUPPORT_LONGJMP=wasm` and
`WASM_LEGACY_EXCEPTIONS=1` at both compile and link time. This is the pin's
**legacy** Wasm exception instruction encoding, not the standardized encoding;
the toolchain labels Wasm longjmp experimental. Lua, the runtime, generated
Titan C, authored C helpers, and providers all use the same settings. A link
flag alone cannot change old objects that contain JavaScript SJLJ calls.

The existing record carries `sjlj=wasm`, the explicit encoding in `cflags`,
and `+exception-handling` in `wasm_features`. No record, metadata, or cache
schema version changes: these facts and the descriptor's compile flags already
participate in identities, so prior JavaScript-SJLJ records and objects cannot
qualify as this target. `make lua-browser` rebuilds a stale installation.
JSPI is the sole browser coroutine backend; protected calls never cross a JavaScript SJLJ trampoline.
Wasm EH catches language longjmp transfers, not engine traps, engine stack
overflow, or arbitrary JavaScript exceptions. Native builds and
`LUAI_MAXCCALLS=100` on the browser are unchanged.


### `make lua-browser`

`make lua-browser PREFIX=<root>` is Titan's convenience wrapper around the
fork's `install-browser`, as `make lua` is for the native build. The Makefile
passes `PREFIX`, `LUA_DIR`, `FORK_REVISION`, the optional tool overrides
`LUA_BROWSER_CC`, `LUA_BROWSER_AR`, and `LUA_BROWSER_RANLIB`, and
`LUA_BROWSER_MYCFLAGS`/`LUA_BROWSER_MYLDFLAGS` (default `MYCFLAGS`/`MYLDFLAGS`;
an explicitly empty value stays empty) to `scripts/lua_browser.sh`. The script
selects `emcc` from `LUA_BROWSER_CC`, then `$EMSDK/upstream/emscripten/emcc`,
then `PATH`, requires `emar` and `emranlib` beside it, and reports a missing
tool with the same `browser target requires Emscripten 6.0.13: ...`
diagnostics as the descriptor. Its own failures start with `lua-browser: `.

An existing installation is reused only when all of these hold:

* the effective browser configuration that the fork's `browser-config`
  reports (fork revision, Emscripten version, target, longjmp mode,
  normalized compile flags, sorted `-D` set, preprocessed numeric types, and
  Wasm features) equals the installed record, which must also pass a strict
  syntax check (banner, UTF-8 without NUL or CR, trailing LF, exactly the ten
  keys, no blank, duplicate, or unknown line);
* the installed headers match both the record's `headers_sha256` and the
  fork's current source headers, with the same header count;
* `lib/browser/liblua.a` matches `archive_sha256` and is an intact Wasm
  archive (`!<arch>` magic, `lapi.o` and `linit.o` present, at least 32
  members, every member starting with `\0asm`); and
* when the fork's browser build directory exists, its archive and
  configuration stamp exist, the archive equals the installed one, and no
  source file is newer than it.

A revision-only or existence-only match never qualifies. Otherwise the script
removes the build tree's `liblua.a` and every object that is not Wasm, runs
the fork's `install-browser` with the selected tools and flags (the fork's
configuration stamp rebuilds stale objects in its separate browser object
directory), and verifies the installed archive again. Corrupt installed files
are rebuilt from verified build outputs, never blessed by rewriting the record.
`luarocks make` and `make browser-sdk` never invoke it.

## Installed paths

`driver.installed_paths(root, target)` returns the unchanged native table for
`target == nil` and for every host label. For `"browser"` it returns a
separate table with exactly these keys, relative to the normalized `root`:

| Key | Path |
| --- | --- |
| `root` | the normalized root itself |
| `lua_source` | `lib/browser/include` (the verified Lua headers, internal headers and `luaconf.h` included) |
| `include` | `include` (the installed Titan runtime headers) |
| `lib` | `lib/browser` |
| `liblua` | `lib/browser/liblua.a` |
| `lua_record` | `lib/browser/liblua-config.txt` |
| `titan_bin` | `lib/titan-browser/<ver>`, where `<ver>` is `driver.TITAN_LIBRARY_VERSION` |
| `libtitan` | `lib/titan-browser/<ver>/libtitan.a` |
| `sdk_digests` | `lib/titan-browser/<ver>/sdk-digests` |

There is no `libbacktrace` entry. The browser SDK root `lib/titan-browser/<ver>`
is a sibling of the native provider root `lib/titan/<ver>`, never inside it,
and native lookup never searches it, so a native module named `browser.<m>`
keeps resolving natively. `libtitan` and `sdk_digests` need not exist; object
compilation never checks for them. The table and its closed key set are the
only browser path convention: [the browser SDK](#the-browser-sdk) derives every
other asset from `titan_bin`.

The browser root is `driver.TITAN_ROOT`. In the supported layout `PREFIX` and
`ROCKS_TREE` are equal, so the fork's `PREFIX/lib/browser` is visible there;
`make browser-sdk` stages it into a differing `ROCKS_TREE`. A checkout
compiler also takes the browser Lua pieces from `TITAN_ROOT`, never from the
checkout's native `lua-5.5.1/src`; only its runtime headers come from the
checkout's `titan-runtime/`. An unknown root stops initialization with
`cannot locate the Titan installation root; set TITAN_ROOT to the installation
prefix`.

## The browser SDK

`browserlink.sdk_assets(paths)` is a pure function of the browser
`installed_paths` table. It returns exactly these absolute paths, all in
`titan_bin` (`lib/titan-browser/<ver>`):

| Key | File | Contents |
| --- | --- | --- |
| `runtime` | `libtitan.a` (`paths.libtitan`) | `titan.o`, `minicoro.o`, `titan_path.o`, `ltitanlib.o`, compiled for the browser |
| `js_library` | `titan-browser-library.js` | the Emscripten `--js-library` with the completion and admission imports ([channels](#completion-and-output-channels)) |
| `trace_library` | `titan-browser-trace.js` | the Emscripten `--js-library` with the eager `.wasm.map` run-dependency loader, lookup index, and `Error.stack` capture/symbolization imports ([Browser trace backend](error-handling.md#browser-trace-backend)) |
| `loader` | `titan-browser.mjs` | the [loader](#the-loader) |
| `runner` | `titan-browser-run` | the [runner](#the-runner)'s POSIX shell launcher (mode 0755) |
| `runner_module` | `titan-browser-run.mjs` | the runner's supervisor |
| `node_worker` | `titan-browser-node-worker.mjs` | the runner's Node worker |
| `page` | `titan-browser-page.mjs` | the shared host-test context and Chromium page entry |
| `lpeglabel` | `libtitan-lpeglabel.a` | the five LPegLabel objects (`lplcap.o`, `lplcode.o`, `lplprint.o`, `lpltree.o`, `lplvm.o`), compiled for the browser; the provider build passes it with `-X`, so the same five objects are members of `titan.a` |
| `provider` | `titan.a` | the browser standard provider: the thirteen [core stdlib](#the-browser-standard-library) roots plus the five LPegLabel members |
| `sdk_digests` | `sdk-digests` (`paths.sdk_digests`) | the SDK digest manifest |

None of the four runtime sources is compiled with `-fPIC`, LTO, or
libbacktrace; their host-only paths compile out under the browser target
define ([Runtime guards](#runtime-guards)). Neither the native `lib/titan/<ver>`
nor the native Lua headers are ever written; the common Titan headers
`include/{minicoro.h,titan.h,transfer.h}` and `include/titan/ffi.h` are the
native SDK's own files.

### Readiness and the missing-SDK diagnostic

`browserlink.require_sdk(context, descriptor, install)` checks, in the order
`runtime`, `js_library`, `trace_library`, `loader`, `runner`, `runner_module`,
`node_worker`, `page`, that each asset is a regular file that `context.io` can
open and read
(a bounded read of at most one byte). It executes nothing, reads no manifest, and does
not require `lpeglabel`, `provider`, or `sdk_digests`: the initial provider
publication runs before either exists. The first missing asset returns:

```text
browser SDK is incomplete: missing "<path>"; run 'make browser-sdk PREFIX=<prefix>'
browser SDK is incomplete: missing "<path>"; run 'make browser-sdk PREFIX=<prefix> ROCKS_TREE=<tree>'
```

`driver.require_browser_sdk(context)` supplies `install`: `prefix` is
`driver.INSTALL_PATHS.root` (the descriptor root when unset) and `rocks_tree`
is the nonempty `ROCKS_TREE` environment variable, which selects the second
form. The
check runs only at a program or test link, before the executing protocol
check, and in `make browser-sdk` itself; object compilation never runs it.

### `make browser-sdk`

`make browser-sdk PREFIX=<prefix> [ROCKS_TREE=<tree>]` is, with `make
lua-browser` and `make titan-stdlib-browser-test`, one of the three Titan Make
steps that need emsdk. It requires the
installed compiler and common headers
and the browser Lua; it never invokes `lua-browser`, the native standard
library, or the native SDK build, and it clears ambient `LUA_PATH`,
`LUA_CPATH`, and `TITAN_TARGET`. It runs the installed `titanc` from
`TITAN_INSTALL_TREE` (then `PREFIX`); a missing compiler stops with
`browser-sdk: installed titanc not found; run 'luarocks make' or 'make
install-compiler-sdk' first`. Every child gets `TITAN_ROOT` set to the
installation tree, `TITAN_PATH_0_6` set to the checkout, an empty
`TITAN_PATH`, an empty `CPPFLAGS`, and `TITAN_EXTRA_CPPFLAGS` replaced by
exactly `LPEGLABEL_CPPFLAGS` (`-I<checkout>/vendor/lpeglabel`); the ambient
values of both are discarded, never appended to (`BROWSER_SDK_ENV`). When
`TITAN_NODE` is unset or empty, the recipe unsets it and leaves ordinary
`PATH` selection intact; emsdk's bundled Node does not override it. The
build directory is `TITAN_BROWSER_BUILD_DIR` (default
`$(TITAN_OUTPUT_DIR)/browser-sdk`), a browser `--output` root.

1. `scripts/browser_sdk.lua prepare` stages a differing root (below), checks
   Node 26+ up front with `driver.browser_node_ready` against the checkout's
   runner (`browser provider validation requires Node 26 or newer: <reason>;
   set TITAN_NODE to a Node 26 or newer executable`), removes a stale `sdk-digests` so that
   an interrupted run cannot leave a manifest describing old files, and creates
   `titan_bin`.
2. `titanc --target browser --output <build> -c --incremental
   --print-c-objects` compiles the four runtime sources and the five
   LPegLabel sources as `--c-source` nodes; Make reads the certified object
   paths from stdout.
3. `browser_sdk.lua stage-runtime` builds `libtitan.a` and
   `libtitan-lpeglabel.a` from exactly those objects with
   `driver.build_static_archive` (the descriptor's `emar`/`emranlib` and the
   member-verification path), rejects any member that imports a `GOT.*`
   symbol or refers to `dlopen`, `dlsym`, `dlerror`, or a `backtrace_` name,
   copies the JavaScript and runner assets (the launcher executable), and
   checks readiness with `browserlink.require_sdk` and
   `driver.browser_node_ready` against the staged runner.
4. `titanc --target browser --output <build> --source-first --incremental
   -X <titan_bin>/libtitan-lpeglabel.a <BROWSER_STDLIB_ROOTS>` publishes
   `<build>/titan.a` through ordinary library mode, which runs the executing
   protocol check against the runtime and runner staged in step 3. The thirteen
   roots and the payload are described in [the browser standard
   library](#the-browser-standard-library). No `titan.a` or manifest exists
   yet, and none is required.
5. `browser_sdk.lua finalize` rescans the staged provider with the descriptor
   fingerprint, revalidates it structurally, rejects `GOT.*` imports and
   `dlopen`, `dlsym`, `dlerror`, or `backtrace_` references as step 3 does,
   runs the [dependency-closure
   check](#the-dependency-closure-check) over the staged provider, the
   LPegLabel archive, and every object and link certificate under `<build>`,
   requires exactly the thirteen keys `titan.coroutine`, `titan.gc`,
   `titan.iteration`, `titan.json`, `titan.math`, `titan.path`, `titan.peg`,
   `titan.protobuf`, `titan.reflect`, `titan.string`, `titan.test`,
   `titan.transfer`, and `titan.url` in that order, copies it to `titan.a`, and
   finally writes `sdk-digests` with `incremental.write_sdk_digests` and the
   existing schema.

The manifest records the browser `liblua.a` and its record, every browser Lua
header, the four common Titan headers, and the ten other assets, hashed at
their installed destinations; the manifest never records itself. Every copy
goes through a temporary file and a rename. A missing or invalid manifest is
a digest-reuse miss, never evidence that the runtime is unavailable.

**Differing roots.** When `ROCKS_TREE` is set and resolves to a different
directory than `PREFIX`, `prepare` first builds a descriptor against
`PREFIX/lib/browser` (so an incomplete `PREFIX` fails naming `PREFIX` before
the tree is read or changed), then replaces the browser Lua headers in
`<tree>/lib/browser/include` and copies `liblua.a` and its record, and copies
any missing common Titan header from `PREFIX`. Native Lua headers are never
touched. A common header that is still missing stops with `missing installed
header '<path>'; run 'luarocks make' or 'make install-compiler-sdk' first`.

## The browser standard library

The browser standard provider is a dependency-closed subset of the standard
library, built from the shared `titan/` tree. The user contract is
[the browser standard library](../language/browser-target.md#the-browser-standard-library)
in the language manual.

### Subset policy

The candidates are the thirteen standard modules that reach neither `uv` nor
`async` through their Titan imports: `coroutine`, `gc`, `iteration`, `math`,
`test`, `reflect`, `json`, `protobuf`, `transfer`, `peg`, `string`, `url`, and
`path`. All thirteen are delivered, each with its complete public interface:
no member is omitted, stubbed, or made to raise "unavailable", and none of
them has a `.browser.titan` or `.native.titan` variant. Their foreign imports
are libc, Lua, the Titan SDK headers, and LPegLabel only, and the
target-dependent values they need come from target C defines rather than
whole-file variants: `TITAN_COROUTINE_STACK_SIZE` for `coroutine`, and
`_WIN32` (which `emcc` never defines) through `titan/path_platform.h` for
`path`. The [library nesting policies](#nesting-limits) are shared with
native targets and need no browser-specific defines.

The other thirteen standard modules are absent at compile time: their
canonical mains are the `native` variants `titan/{async,timer,io,fs,net,ssl,os}.native.titan`
and `titan/{uv,http,websocket,sqlite3,lua,thread}/<name>.native.titan`
([Make inventories](target-source-selection.md#make-inventories-and-audits)).
For `browser` the resolver finds no main, so an import reports the ordinary
`module 'titan.<name>' not found`, and a contributor of a folder whose main is
unselected stays blocked rather than resolving as a flat module. The plan for
them is provisional:

| Modules | Browser plan (provisional) |
| --- | --- |
| `async`, `timer` | browser compositions with a browser scheduler and outer suspension |
| `io`, `os`, `lua` | browser compositions with `io.print`, streams, clocks, and Lua loading |
| `http` | a browser composition; the only absent module that may bring llhttp into the browser closure |
| `fs` | only together with a virtual filesystem |
| `uv`, `net`, `ssl` | absent |
| `websocket`, `sqlite3`, `thread` | absent; browser WebSocket, SQLite, and Worker-based threads are possible later additions |

The subset has no raise-on-invoke members, no absence list, and no
complete-interface parity gate. Output goes through
Emscripten stdio only: `titan.test` writes with `putchar`/`fflush` and imports
no Titan module, the generated runner imports only `titan.test` and the test
owners, and the [loader](#the-loader)'s per-byte `Module.stdout`/`Module.stderr`
hooks carry the bytes unchanged. No delivered module registers an async
bootstrap hook, so the [entrypoint](#the-browser-entrypoint) calls `main`
directly.

### Provider recipe

`BROWSER_STDLIB_ROOTS` in the `Makefile` names the thirteen logical roots, and
[`make browser-sdk`](#make-browser-sdk) step 4 compiles them in one library-mode
`titanc --target browser` invocation. The provider's native payload and
include path are LPegLabel only:

* `-X <titan_bin>/libtitan-lpeglabel.a` is the sole `-X` input. Its five
  objects come from step 2's `--c-source` compilation with the descriptor's
  object flags, so they carry neither the native `LPEGLABEL_CFLAGS`
  `-fPIC` nor the host profile's LTO flags (`LPEGLABEL_BUILD_CFLAGS`); the
  staging parser rejects any `GOT.*` import, and `titanc` rejects bitcode
  members. `make browser-sdk TITAN_VERBOSE=1` prints the descriptor flags the
  objects were compiled with.
* `BROWSER_SDK_ENV` sets `TITAN_EXTRA_CPPFLAGS` to exactly
  `LPEGLABEL_CPPFLAGS` and empties `CPPFLAGS`, replacing their ambient values.
  No libuv, OpenSSL, llhttp, or SQLite include directory reaches the build, so
  an accidental `#include <uv.h>` fails at FFI preprocessing instead of
  finding a host header.

The native standard library's single invocation, by contrast, passes every
native archive in `STDLIB_EXTRA_OBJECTS` and concatenates every dependency's
include path ([standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image));
native link inputs come from invocation options, not module metadata, so the
browser recipe states its closure explicitly. The published `titan.a` holds
the thirteen module objects (with their split parts) and the five LPegLabel
members.

### The dependency-closure check

`scripts/browser_stdlib.lua` rejects libuv, OpenSSL, llhttp, and SQLite by
path, by symbol, and through the evidence each certified input carries:

* **Paths** (`check_path`): a header named `uv.h`, `llhttp.h`, `sqlite3.h`, or
  `sqlite3ext.h`, or below a `uv`, `libuv`, `openssl`, `llhttp`, or `sqlite3`
  directory; and an archive named `libuv`, `libssl`, `libcrypto`,
  `libopenssl`, `libllhttp`, `libsqlite3`, `libtitan-llhttp`, or
  `libtitan-sqlite3` followed by `.`, `_`, or `-`.
* **Symbols** (`check_symbol`): any name starting with `uv_`, `SSL_`,
  `OPENSSL_`, `llhttp_`, or `sqlite3_` in the symbol and import inventories
  that the relocatable-Wasm reader parses from each object, whether a function
  or data, defined or undefined.
* **Generated objects**: the C-header dependencies recorded in each object's
  `.titan.source` metadata.
* **Authored C**: each `.native/` directory must hold the `inputs` inventory
  that the latest successful `nativeinputs.compile` call wrote ([`--c-source`
  compilation](build-coordinator.md#--c-source-compilation-and-records)). Every
  object it names needs a readable, nonempty `<stem>.d`, and every header path
  in that file gets the path check, so a header that only contributes macros is
  still caught. A missing or invalid inventory or `.d` fails closed: a missing
  `.d` reports `missing authored-C header provenance`, and a missing inventory
  reports the record reader's own error (`missing record`, or the I/O error).
  The next successful build of those sources writes the evidence again. Unused
  objects that older invocations left in the cache are checked by content but
  need no `.d`.
* **Link certificates**: every `native` input of every final-link record under
  `.titan-links/` gets the path check, and every `.o` or `.a` among them,
  inside or outside the output tree, is read and checked by content: archive
  member names and each member's parsed Wasm symbol and import inventories,
  plus the header metadata of objects that carry it. An authored-C object from
  this output tree must also have its `.d`. Opaque third-party prebuilt inputs need
  no header metadata; their contents are still checked.

Each physical input is decoded once per `check_output` call. The key is its device and inode
(or its real path where those are unavailable) together with its size, mode,
and timestamps, so two different files with the same basename are both
inspected, while hard-link aliases of one file are read once. The path check
runs before deduplication. Referenced archives are scanned with
`independent_members = true`, because a content audit must accept a toolchain
archive whose members carry different feature vectors; provider lookup and
target selection keep their strict scans ([relocatable
WebAssembly](static-compiled-modules.md#relocatable-webassembly)).

`check_archive` applies the path, symbol, and header checks to an archive and
every member, `check_output` applies the generated-object, authored-C, and
link-certificate checks to everything below an output root, and `check_image`
checks a final `.wasm`: its imports, its exports, and every internal function
name from the `name` section, so a dependency that dead-stripping left only
internally is still found, and a missing name inventory fails. The check is
owned by the SDK build and the subset suite (it is never part of `titanc`'s
general link path): `browser_sdk.lua finalize` checks the staged provider, the
LPegLabel archive, and the SDK build tree, and `titan-stdlib-browser-test`
checks its output tree, the installed provider, and each of its test images.
Admitting llhttp would be a deliberate change to these checks; no other
relaxation is part of the policy.

`spec/browser_stdlib_spec.lua` (emsdk-free) covers the path and symbol
matrices, including every archive stem with `.a`, `_a.a`, `_1.48.a`,
`-static.a`, and `.1.a` suffixes, and requires the `browser-sdk` environment
and recipe to name no native-only dependency variable.
`spec/coder/browser_stdlib_closure_spec.lua` holds the real-toolchain negative
fixtures:

* a compiled provider that `foreign import`s an injected `uv.h`, an injected
  `libuv.a`, a neutrally named archive that defines `uv_closure_intruder`, an
  image that keeps that function internally, and an image linked with
  `-X libuv_a.a` whose selected object has no forbidden symbol but whose link
  certificate names the archive;
* an authored C file whose only forbidden header contributes a macro, rejected
  on a cache miss, on a hit, and as an uncacheable node; deleting its `.d` or
  the `.native/inputs` inventory fails closed, and a clean rebuild with an
  unused legacy cache object passes;
* external `.o` and `.a` inputs whose functions have neutral names, so the
  image's function-name check passes, while a denied data symbol is defined,
  or kept live as a weak undefined reference; the closure check rejects both,
  even beside a clean input with the same basename. Replacing the payload with
  a clean opaque prebuilt passes without header metadata, and hard-link aliases
  certified by a second image are read once per physical file.

`spec/staticmetadata_spec.lua` covers the `independent_members` scan option,
and `spec/coder/native_inputs_spec.lua` the retained `.d` and `inputs`
evidence. `spec/browser_sdk_spec.lua` builds the SDK with poisoned ambient
`CPPFLAGS` and `TITAN_EXTRA_CPPFLAGS` (both name a missing forced header, so
appending either fails) and requires the provider's non-compiler members to be
exactly the five LPegLabel objects.

### Interface-derived member inventory

The member list is derived, never written by hand. `scripts/browser_stdlib.lua`
reads the native and browser providers with `staticmetadata.scan_archive`,
decodes each module interface with `driver.decode_module_interface`, and
enumerates public top-level functions, variables, records, unions, Interfaces,
and type aliases, plus their public fields, union variants, methods, and
static functions. A `Type.CFunction` member is a raw `foreign function`
export. A union variant's generated constructor counts once, as the variant.
Each member is compared by kind, rendered signature, and
`types.serialize_semantic` (which excludes documentation and includes
named-call parameter metadata); machine layouts are separate provider metadata
and are not compared. The inventory records no omissions or differences, so
any difference between the native and browser interfaces fails.
`check_browser_stdlib.lua inventory <native titan.a> <browser titan.a>
[table]` prints `Browser stdlib inventory: <modules> modules, <members> public
members, no differences.` and writes the Markdown member table;
`titan-stdlib-browser-test` writes it to `out/browser-stdlib/members.md`.

The raw `foreign function` exports of the subset are
`protobuf.write_resource_index_bytes(dst, index)` (writes a four-byte
little-endian index), `protobuf.write_resource_index(raw_buf, index)`
(reserves and appends four bytes to a caller-owned buffer and returns 0 when
the reservation fails), `transfer.copy_message`, `transfer.discard_message`,
and `transfer.transfer_load_module`. All five are portable C and are
delivered.

### Inventory record

| Module | Delivered | Omitted members | Browser test owners | Final initializer, verified by `init_<module>` and `init_subset` | Raw exports |
| --- | --- | --- | --- | --- | --- |
| `coroutine` | yes | none | `coroutine.tests` (the Lua-host cases are in the native contributor `tests/lua_boundary_test.native.titan`) | creates or checks the `titan.coroutine` registry metatable | none |
| `gc` | yes | none | `gc.tests` | none | none |
| `iteration` | yes | none | `iteration.tests` | none | none |
| `math` | yes | none | `math.tests`, including automatic and argumentless seeding | calls `randomseed()` | none |
| `test` | yes | none | `test.tests`, and every other owner through the runner | loads the Lua trace and pattern helpers when the Lua `string` library is open | none |
| `reflect` | yes | none | `reflect.tests` | metatable, hydration, brand, and tag tables | none |
| `json` | yes | none | `json.tests` | builds the JSON pattern | none |
| `protobuf` | yes | none | `protobuf.tests`, including both raw index writers and the reservation failure | caches the nominal registry, sets up the ephemeron, validates the codec handoff | `write_resource_index`, `write_resource_index_bytes` |
| `transfer` | yes | none | `transfer.tests` (same-instance behavior), including all three raw exports | installs protobuf's packet-context provider and nominal loader, the ephemerons, and `closure_fields` | `copy_message`, `discard_message`, `transfer_load_module` |
| `peg` | yes | none | `peg.tests` | `_initialize_native()` | none |
| `string` | yes | none | `string.core_test`, `string.format_pack_test`, `string.regex_test` | target size, length-modifier, endianness, and alignment facts; the format and regex parsers | none |
| `url` | yes | none | `url.tests` | builds the URL patterns | none |
| `path` | yes | none | `path.tests` | separator from `TITAN_PATH_WINDOWS` (POSIX on the browser) | none |

The subset includes, with their closure, every import of `titan.async` other
than `uv` (`coroutine`, `gc`, `string`, `transfer`, and `iteration`) and the
`reflect` and `gc` modules that inspect and root values. `transfer` covers
verified same-instance data behavior only; no thread, native-resource, or
JavaScript-handle feature is implied.

Initialization audit:

* **`math`.** The automatic seed has two components: `time(NULL) ~ clock()`
  and a value drawn from the generator with `next_random()`, and
  `set_random_seed` takes both. Emscripten's libc supplies `time` and `clock`
  through `wasi_snapshot_preview1` without a JavaScript bridge, on Node and in
  Chromium; its `clock()` measures elapsed time, not process CPU time, which is
  an acceptable component of Lua's weak default seed. No delivered module
  calls `getrandom()`, which does not link.
* **`test`.** The browser entry opens the standard Lua libraries before any
  module initializes, as the native runner does, so the helpers load eagerly.
* **`string`.** The target facts are computed at run time: on wasm32,
  `size_t` and `long` are 4 bytes, and the browser Lua's `lua_Integer` is
  `long long`.
* **Locale.** `math`, `string` (`format`), and `json` (`numbers`) import
  `locale.h`. Emscripten's musl `localeconv` always returns the C locale's
  `.` decimal point, so the alternate-locale parity cases in
  `string.format_pack_test` and `json.tests` take their existing capability
  skip.
* **`transfer`.** Its nominal loader reaches `transfer_load_module`, which
  loads a module through the image's static preload table.

### Test owners and the browser suite

Each browser test owner imports only delivered modules, owner-local support,
and `support.common.titan`. Cases that need `lua`, `fs`, `thread`, or a host
command live in native-only owners or contributors in the same source tree:
`test.host_tests`, `reflect.lua_tests`, `json.lua_tests`,
`protobuf.resource_tests`, and the `coroutine.tests` contributor
`tests/lua_boundary_test.native.titan`. Same-instance `transfer` cases belong
to `transfer.tests`; the Task, thread, and independent-state transfer cases
belong to `async.tests` and `thread.tests`. Both suites share the browser
roots and their portable cases, while target-selected contributors (such as
`coroutine.tests`' `tests/close.browser.titan` and
`tests/unwind_test.native.titan`) add cases to one target only.
`spec/support/stdlib_test_modules.mk` lists the browser
roots in `TITAN_STDLIB_BROWSER_TEST_ROOTS`, next to the native
`TITAN_STDLIB_TEST_ROOTS`:

```text
coroutine.tests iteration.tests gc.tests math.tests peg.tests
string.core_test string.format_pack_test string.regex_test url.tests path.tests
test.tests reflect.tests json.tests protobuf.tests transfer.tests
```

All fifteen owners are compiled into `images/stdlib.mjs`, with its `.wasm`
and `.wasm.map` siblings. `TITAN_STDLIB_BROWSER_TEST_ROOTS_CHECK` rejects an
empty or duplicate root inventory before build setup. The compiler's
[general image bounds](#build-time-image-bounds) apply; the suite has no
separate image-size budget or partition policy. The former four-image,
32,000,000-byte workaround was measured under Asyncify and is not a JSPI
limit. Qualification with the original unsplit transfer regression and all
fifteen owners passes on Node and sandboxed Chromium on Linux and macOS.

`make titan-stdlib-browser-test` (a test goal, so it defaults to the
`validation` profile) needs the installed native provider, the browser SDK,
emsdk, Node 26+, and a JSPI-capable headless Chromium. It:

1. writes `roots.txt` in `$(TITAN_BROWSER_TEST_BUILD_DIR)` (default
   `out/browser-stdlib`), then builds `images/stdlib.mjs` with one installed
   `titanc -q --target browser --test --incremental --tree spec/stdlib/titan`
   invocation over every root. The compiler output is the directory's
   `objects/` subdirectory, which titanc creates and marks. The invocation
   adds `--c-source spec/fixtures/browser_runtime/close.c` (the browser helper
   of `coroutine.tests`) and runs under `BROWSER_SDK_ENV` with `TITAN_PATH_0_6`
   set to the installed browser SDK. The target prints the build duration,
   then runs `check_browser_stdlib.lua closure` against the objects, installed
   browser `titan.a` and final `.wasm`;
2. runs `check_browser_stdlib.lua inventory` once against the installed native
   and browser providers and writes `members.md`;
3. for `node` and then `chromium`, runs the image with the SDK's
   `titan-browser-run --engine <engine> --timeout 300000 --grace 2000` through
   `scripts/run_browser_stdlib.sh`, forwarding a nonempty `TITAN_FILTER` as
   one `--filter=` argument. The wrapper saves stdout in `stdlib.<engine>.log`
   and stderr in `stdlib.<engine>.stderr.log`, replays both, and preserves the
   runner's status. Failure under one engine does not hide the other; and
4. after each engine, audits only stdout with
   `check_browser_stdlib.lua output roots.txt <filter> <stdout-log>`.
   The shared native validator requires nonzero selection, no duplicate or
   foreign cases, complete status/count/timing accounting, classified skips,
   and, without a filter, execution of every root. A filter may omit owners
   but must still select at least one case. The checker prints
   `Browser stdlib image stdlib: <n> cases (N.NN ms total)` from the run clock
   and `Browser stdlib owner <root>: <n> cases (N.NN ms total)` for each
   reported owner interval. The gate summary retains selected/pass/skip/fail
   counts, owner coverage and `images=1`, with `(filtered)` when applicable.
   Counts and available timing remain visible on failure; untimed final
   failure-name references are not second outcomes. The target fails if either
   engine or its audit fails.

The streams stay separate because a case may write to stderr while the runner
is in the middle of a report line, and a merged log then splits that line; the
expected Lua warnings (`Lua warning: error in coroutine cleanup ...`) are such
writes, and the validator rejects a split report. Warnings
stay visible in the `.stderr.log` files and on the console; nothing is
filtered out. `out/browser-stdlib/` therefore holds `objects/` (titanc's output
tree), `images/` (each image's `.mjs`, `.wasm`, and `.wasm.map`), `roots.txt`,
the `<image>.roots.txt` files, `members.md`, and the per-image, per-engine
stdout and stderr logs. The target never writes into `objects/`: titanc creates
it and its `.titan-target` marker on a cold run, because a browser output root
without a marker must be empty when titanc first claims it ([output
roots](#output-roots-and-the-target-marker)), and the suite directory already
holds `images/` and the roots files by then.
`spec/coder/browser_stdlib_closure_spec.lua` runs the target with one owner
from a cold and then a warm directory and checks this layout. The
[`browser-stdlib` job](continuous-integration.md#browser-stdlib-job)
runs the target unfiltered after the SDK is built and uploads everything but
`objects/` when the job fails. It uses Chrome for Testing with the normal
sandbox and no `HigherRendererMemoryLimit` wrapper. The older Asyncify
protobuf-startup footprint is not a requirement of current JSPI images.

### Initialization and fidelity gate

`spec/coder/browser_stdlib_gate_spec.lua` (a real-toolchain gate file) builds
fifteen `--test` images from `spec/fixtures/browser_stdlib/` with the `test`
purpose and assertions 2, and runs them through `gate.mjs` under
`titan-browser-run --js-test` on Node and Chromium:

* `init_<module>.titan`, one per delivered module, imports only that module
  (and the `titan.test` runner every test image has) and must return status
  0, run and pass exactly one case, and write nothing to stderr;
* `init_subset.titan` imports all thirteen and is initialized, run, and
  disposed three times from one cached factory, with a tick and a collection
  between cycles; and
* `fidelity_test.titan` imports the real `coroutine.tests` owner, so its
  browser cases create coroutines first, then writes a marker with NUL, `0xFF`,
  and invalid UTF-8 bytes to stderr and fails a child case whose name and
  message carry the same bytes. The gate requires status 1 through the
  Titan-owned completion channel, the exact name on the run, failure, and
  summary lines, the exact message, and exactly the expected stderr bytes.

The deliberately failing case lives outside every suite root.

### Nesting limits

Browser and native builds share the 128-level codec budget in `transfer.h`:
the innermost field consumes one level, so a structural record chain accepts
127 records. Generated and reflective protobuf paths, `protobuf.schema`,
`TransferValue`, and packet encode/decode share that policy and ordinary
error string. The browser descriptor no longer overrides it.

JSON encoding uses only the call's validated `max_depth` (default 32);
there is no additional target cap or cached writer clamp. The owning native
tests exercise arrays, Maps and records at configured depth 128, rejection
at 129, and recovery; raising `max_depth` admits that next level. Parser
depth and PEG matching-stack limits are unchanged.

The former browser-only codec43 and writer103 restrictions bounded
instrumented protected-call stack costs. They are not JSPI budgets. Engine
stack exhaustion remains fatal, and neither these library limits nor the
linear C-stack sizes account for stack already consumed by an embedding
caller. General unbounded recursion is not promised safe.

## The Lua configuration record

`lib/browser/liblua-config.txt` is UTF-8 text: the banner line, then one
`key=value` line per key, each terminated by LF:

```text
# Lua 5.5.1 browser build record v1
fork_revision=<40 lowercase hex>
archive_sha256=<SHA-256 of lib/browser/liblua.a>
headers_sha256=<digest of the installed Lua headers>
emscripten_version=6.0.13
target=wasm32-unknown-emscripten
wasm_features=<canonical sorted feature list>
sjlj=wasm
lua_defines=<sorted unique -D list>
numeric=integer=<C type>,float=<C type>
cflags=<effective compile flags>
```

The key set is closed. A line splits at its first `=`, so `numeric` and
`cflags` may contain more. The record must start with the exact banner,
contain no NUL or CR, be valid UTF-8, and end with LF; every line must match
`^[a-z][a-z0-9_]*=`. Values must be nonempty single-line UTF-8.
`fork_revision` is 40 lowercase hexadecimal characters and both digests are
64. `wasm_features`, `lua_defines`, and `cflags` are canonical lists: the
words the shell-word splitter produces, joined by one space, must reproduce
the value exactly, so leading, trailing, or repeated whitespace, tabs, and
quoting are rejected. `lua_defines` must be sorted (bytewise) and unique
`-D<identifier>` tokens.

`headers_sha256` lists the regular `*.h` basenames directly in `lua_source`,
sorts them bytewise, concatenates `name .. " " .. sha256(file) .. "\n"` for
each, and hashes the result. File hashes go through `incremental.file_digest`,
so unchanged headers reuse the persistent digest cache. The archive digest
uses the same memo.

### Verification order

`browsertarget.build` verifies the installation once per coordinator context,
in this order; the first failure is reported:

1. `inputs.build_profile` is `production` or `validation` (`invalid browser
   build profile "<value>"`), and the direct-API compile extras pass the
   [unsupported-flag check](#unsupported-flags) and contain no option the
   build profile owns, except the one level that a `trace_control` build may
   add (`browser <profile> profile owns compile option "<flag>"`).
2. `emcc`, `emar`, and `emranlib` are located and `emcc` reports 6.0.13 (see
   [Emscripten pin](#emscripten-pin-and-tool-location)).
3. The record is read and parsed: banner and text encoding, then unknown and
   duplicate keys.
4. Field syntax: missing, non-text, or empty fields, then the three
   hexadecimal fields.
5. The fixed fields: `sjlj` must be `wasm` (matching Lua and `titan.h`),
   `target` must be
   `wasm32-unknown-emscripten`, and `emscripten_version` must equal the pin,
   which step 2 already compared with the running `emcc`.
6. `wasm_features` is a canonical list equal to the expected baseline
   `+bulk-memory +bulk-memory-opt +call-indirect-overlong +exception-handling
   +multivalue +mutable-globals +nontrapping-fptoint +reference-types +sign-ext`.
7. `lua_defines` is canonical, sorted, and unique, and equals the sorted
   unique `-D` tokens of `cflags`.
8. The effective `-sSUPPORT_LONGJMP` mode of `cflags` (the last setting, in
   either the joined or the split `-s SUPPORT_LONGJMP=` spelling; a bare
   setting or `=1` means `emscripten`) equals `sjlj`. The effective explicit
   `WASM_LEGACY_EXCEPTIONS` setting must be 1; joined, split, bare, and boolean
   `NO_` aliases are checked in compiler order.
9. `cflags` contains no unsupported flag.
10. `archive_sha256` matches `liblua`.
11. `headers_sha256` matches the headers in `lua_source`.
12. `numeric` agrees with the probed C profile (`integer=<lua_integer>,float=<lua_number>`).
13. A trivial Titan-flag object compiled with `emcc` matches the expected
    Wasm fingerprint under `staticmetadata.fingerprint_matches`, which
    cross-checks the baseline features against the actual toolchain.

The Lua archive itself is hash-verified, not feature-compared. Objects keep
their exact canonical `target_features` string in `fingerprint.features`.
Wasm-SJLJ objects share the `+exception-handling` baseline even when only some
translation units use `setjmp`. The older JavaScript-SJLJ lowering additionally
marked such units with standalone `-shared-mem`. The general object reader
still ignores that token, and only it, for comparison: both feature lists must
be canonical and become equal after dropping the standalone token, and neither
may carry any other `shared-mem` or `atomics`
entry (`+shared-mem`, `=shared-mem`, `+atomics`, `-atomics`, or `=atomics`).
Every other feature, including a lookalike name such as
`-shared-mem+atomics`, still matches exactly
([Static compiled modules](static-compiled-modules.md#relocatable-webassembly)).
The exact EH encoding is additionally pinned by the explicit legacy setting
in `cflags`; the feature name alone does not distinguish the encodings.
Native exception switches remain unsupported: Wasm SJLJ is selected by
`SUPPORT_LONGJMP=wasm`, not by enabling C++ exceptions with `-fwasm-exceptions`.

### Record diagnostics

Every record diagnostic names the record path, the offending field, and the
fork's install command with the actual root:

```text
browser Lua record "<path>" is unavailable: <reason>; install it with 'make install-browser PREFIX=<root>'
browser Lua record "<path>" is malformed: <detail>; install it with 'make install-browser PREFIX=<root>'
browser Lua record "<path>" field <key> mismatch: recorded "<recorded>", expected "<expected>" (fork_revision=<revision>); install it with 'make install-browser PREFIX=<root>'
```

Malformed details are `invalid banner or text encoding`, `invalid key=value
line`, `unknown field "<key>"`, `duplicate field "<key>"`, `missing field
"<key>"`, and `invalid field "<key>": <reason>`, where the reason is `text
encoding`, `empty value`, `invalid hexadecimal value`, `noncanonical list`, a
shell-word error, `expected sorted unique -D tokens` (for `lua_defines`), or
the unsupported-flag diagnostic (for `cflags`). A mismatch quotes the record's
value as `recorded` and the required or observed value as `expected`: the pin
or fixed value for the fixed fields, the computed digest for
`archive_sha256`/`headers_sha256`, the probed profile for `numeric`, and the
`-D` set or longjmp mode derived from `cflags` (`<missing in cflags>` when
absent). An unreadable archive or header directory reports `expected
"unavailable: <reason>"` in the matching digest field, and a header directory
without `*.h` files reports `unavailable: no installed Lua headers`. When the
fingerprint probe of step 13 disagrees, the failure is a compiler-probe target
mismatch, not a Lua record mismatch. It reports the actual and required target
facts and quotes the supplied compile flags, including feature-changing options
such as `-msimd128`:

```text
browser target compiler probe does not match the required Wasm target: <mismatch>; user compile flags: "<flag>" ...; remove feature-changing flags from TITAN_EXTRA_CPPFLAGS/TITAN_EXTRA_CFLAGS/--cflag
browser target compiler probe does not match the required Wasm target: <mismatch>; check the selected Emscripten 6.0.13 installation
```

The first form applies whenever the invocation supplied compile extras; the
remedy is to remove the feature-changing argument, not reinstall Lua. The
second form, without user flags, points to the selected Emscripten
installation. Actual record-field drift keeps its record diagnostic and its
precedence.

## Emscripten pin and tool location

`browsertarget.EMSCRIPTEN_VERSION` is the single constant `6.0.13`. When
`EMSDK` is set and nonempty it is authoritative: the tools are
`$EMSDK/upstream/emscripten/{emcc,emar,emranlib}`. Otherwise `emcc` is the
first executable regular file named `emcc` along `PATH` (an empty entry means
`.`), and `emar`/`emranlib` must be executable siblings in the same
directory. The host `CC`, `AR`, and `RANLIB` are never consulted. All three
tools are recorded as absolute one-word argv arrays. `emcc --version` runs
once, with stderr merged, and its first `emcc ... <major>.<minor>.<patch>`
version is compared with the pin.

```text
browser target requires Emscripten 6.0.13: emcc not found (EMSDK unset; not on PATH); install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh
browser target requires Emscripten 6.0.13: emcc not found at "<path>" (EMSDK="<root>"); install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh
browser target requires Emscripten 6.0.13: "<path>" reports <found>; install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh
browser target requires Emscripten 6.0.13: <tool> not found at "<path>" (emcc="<cc>"); install it with 'emsdk install 6.0.13 && emsdk activate 6.0.13' and source emsdk_env.sh
```

`<found>` is `unknown` when the output carries no parsable version or the
command fails. `emar` and `emranlib` delegate to LLVM archive tools whose
banners are not Emscripten versions, so only `emcc` is version-checked; the
siblings must come from the same installation directory. The full
`--version` output is kept in the descriptor. `incremental.toolchain_identity`
still folds `emcc`'s `-E -v` banner, which carries the Emscripten and Clang
versions, and adds the descriptor identity
([Object and link identity](#object-and-link-identity)).

## The descriptor

The browser target descriptor is the complete, closed description of one
browser configuration. It is built once per resolver context at the target
initialization boundary, frozen before graph planning, and stored as
`context.target_descriptor`; host contexts leave that field nil. Before
freezing it is exactly this plain data graph (`argv` is a dense array of
strings without NUL, CR, or LF; paths are normalized absolute paths):

```lua
{
  label = "browser", triple = "wasm32-unknown-emscripten", memory_bits = 32,
  tools = { cc = argv, ar = argv, ranlib = argv, version = "6.0.13",
    source = "EMSDK" | "PATH", location = string, version_output = string },
  build_profile = "production" | "validation",
  compile_flags = argv,          -- complete effective flags; include_dirs appended separately
  trace_control = boolean,       -- the harness level hook; optional on import
  include_dirs = { string, ... },
  target_defines = { "-DTITAN_TARGET_BROWSER=1",
    "-DTITAN_COROUTINE_STACK_SIZE=262144" },
  paths = <installed_paths(root, "browser")>,
  lua = { path = string, record = <the ten record fields>, record_sha256 = hex },
  profile_data = <csemantics.export_profile(profile)>, profile_identity = string,
  fingerprint = { format = "wasm", word_size = 32, linking_version = 2,
    features = "<baseline>" },
  probe_cache_directory = string,  -- absent when the probe cache is disabled
  output_policy = { requires_output = true, marker = ".titan-target",
    marker_contents = "browser\n" },
  provider_policy = { archive_only = true, sdk_first = true, dynamic = false },
  identity = "browser:sha256:" .. hex,
}
```

`profile_data` is the existing closed `csemantics.export_profile` format;
the live `CProfile` reconstructed from it with `csemantics.import_profile` is
context-owned (`context.target_profile`), never stored in the frozen graph.

### Compile prefix and target defines

`compile_flags` is, in order:

1. the build profile's owned object flags,
   `browsertarget.object_flags(build_profile)` ([Object flags](#object-flags)):
   `--std=c99`, then `-O1 -fno-inline -fno-optimize-sibling-calls`
   (`validation`) or `-O3` (`production`), then `-Wall`,
   `-Wno-unused-but-set-variable`, `-Wno-unused-function`,
   `-gline-tables-only`, `-sSUPPORT_LONGJMP=wasm`, and `-sWASM_LEGACY_EXCEPTIONS=1`;
2. the record's `lua_defines`, in record order;
3. the ordered `target_defines`: `-DTITAN_TARGET_BROWSER=1`,
   `-DTITAN_COROUTINE_STACK_SIZE=262144`; and
4. the normalized invocation compile extras: `driver.NATIVE_COMPILE_FLAGS`
   when `titanc` installed them (environment extras, then CLI `-I`, `-D`, and
   `--cflag` in written order), otherwise `TITAN_EXTRA_CPPFLAGS` followed by
   `TITAN_EXTRA_CFLAGS`, followed by an internal measurement optimization
   (`-O1` or `-O2`) when `driver.browser_link_options.optimization` selects one
   ([the harness level hook](#the-harness-level-hook)).

There is no `-fPIC` and no LTO. The two build profiles' object and link flags,
the test-image exception, and the measurements behind them are in [Build
profiles](#build-profiles).
Object compilation uses `-gline-tables-only` rather than `-g2` because
Emscripten 6.0.13's `emcc` rewrites `-g2` to `-g0` on compile-only `-c`
invocations (`tools/cmdline.py`), which strips DWARF line tables from `.o`
files and leaves the final `.wasm.map` without `.titan` source attributions;
`-gline-tables-only` preserves the object line tables while the final link
passes `-gsource-map -g2` to emit the source map and retain the Wasm `name`
section. Lua's own `-O2` and debug policy in `liblua.a` stay independent
because Lua C frames are filtered out of Titan traces. The host descriptor
emits no new define. Validation requires both target defines in this order
(`inconsistent browser target defines`) and requires each in
`compile_flags` (`browser target descriptor is missing required compile flag
"<flag>"`), so build, import, and fixtures agree. The target defines reach
generated C, `--c-source` nodes, C probes, and FFI header preprocessing,
because all of them use the same prefix, so the standard library and C headers
read target constants through `foreign import`: `titan/coroutine.titan` reads
`ffi.TITAN_COROUTINE_STACK_SIZE` ([Coroutines](coroutines.md#stacks-and-backends)),
and the coroutine allocation uses that disjoint linear C stack independently
of its engine-managed JSPI continuation. Codec nesting uses the common
native policy and JSON has no target writer cap. Because a measurement
optimization is part of the descriptor, probes, generated objects, authored C,
and imported worker descriptors all compile and certify the same
configuration, and an O1 and an O2 build need separate output trees.

### Include order and the `__wasm__` rule

`include_dirs` is, in order: the verified Lua headers (`paths.lua_source`), the
Titan runtime headers (the installed `include`, or the checkout's
`titan-runtime/`), then the resolver's extra FFI include roots. The descriptor
rejects any graph whose first root is not `lua_source` or whose second root
repeats it (`browser include roots must put verified Lua first and Titan
runtime second`), or any non-normalized include path (`invalid browser include
path`). Relative runtime and extra-FFI roots resolve against the I/O
strategy's working directory without lexical joining, and a POSIX root
containing a `..` component is resolved through `realpath` before
normalization, with `driver.normalize_root`'s fallback for an absent root and
its errors for an existing root that cannot be resolved. The prefix places
these `-I` roots after `compile_flags`, so user `-I` directories are searched
first, as on native hosts.

The installed runtime headers sit in `PREFIX/include` beside the native
`lua.h` and `luaconf.h`. A quoted include is searched first in the including
header's own directory, so a quoted Lua include in a runtime header would
capture the native headers regardless of the `-I` order. `titan.h`,
`titan/ffi.h`, and `transfer.h` therefore have a `#if defined(__wasm__)`
branch that includes the same Lua headers in angle form, which searches only
the `-I` roots; the native branch keeps its quoted includes verbatim. Native
preprocessing output is unchanged by the branch. No browser runtime staging
layout exists.

### Target C facts and the fingerprint probe

The C profile comes from the existing compile-only profile probes
(`cdriver.target_profile_inputs`, `csemantics.build_profile`) run with `emcc`,
the complete compile prefix, and the include roots above; its numeric facts
are cross-checked with the record. A trivial C object compiled with the same
prefix is classified by the Wasm reader, and its fingerprint must equal the
expected baseline. No probe links or executes anything.

### Freezing and identity

The descriptor is recursively immutable. Every table is replaced by a proxy
whose `__newindex` raises `browser target descriptor is immutable` for
existing and new keys at any depth, and whose metatable is protected; `pairs`,
`ipairs`, `#`, and indexing work as on plain data. Raw mutation primitives are
outside the Lua API contract. Freezing happens once, after every probe and
cross-check.

The identity is `"browser:sha256:" .. incremental.digest(context,
"browser-target", data)` over the plain graph without `identity`: the label
and physical facts, the tool argv, version, source, location, and complete
version output, `build_profile` and `trace_control`, the effective flags and
include roots in order, the target
defines, every installed path, the parsed record and the SHA-256 of its raw
bytes (so `fork_revision` is included), the expected fingerprint, the
exported profile and its identity, the probe-cache directory when enabled, and
both policies. No timestamp, inode, or output-root pathname enters it.
Changing the Emscripten installation location, `EMSDK` versus `PATH`
selection, the build profile, a compile extra, or enabling or disabling the
probe cache therefore changes the identity.

`browsertarget.export(descriptor)` copies the frozen graph into plain,
metatable-free data. `browsertarget.import(data)` revalidates the closed shape
and every pure invariant (argv and path forms, sibling tool locations, the
record fields, the build profile and its owned object flags, required flags
and longjmp setting, include order, fingerprint,
policies, profile, identity) and freezes it, without reading files, running
subprocesses, or reselecting sources. `build` runs the same validation before
freezing, so a built and an imported descriptor obey one contract. Import
failures are short structural messages such as `invalid browser target
descriptor` or `invalid browser target identity`.

### Driver accessors

* `driver.context_target_descriptor(context)` returns the descriptor for a
  browser context, `nil` for a host context (and for a `nil` context), or
  `nil, err` when initialization fails.
* `driver.context_target_identity(context)` returns the descriptor identity
  for browser and the selected host label otherwise. It serves semantic-cache
  ownership only; host labels are never written into native records.
* `driver.toolchain_descriptor(context)` returns, for browser, a fresh service
  adapter with the descriptor's `emcc` argv, compile flags, and include roots,
  `language_mode = "c99"`, empty `cppflags`/`cflags`, the context profile and
  its identity, `target_identity = descriptor.identity`, and
  `certification_target_identity`, the `"relocatable-browser-target"` digest
  of the exported descriptor with its compiler-owned SDK paths made
  root-relative. The host result has neither identity field.
* `driver.generated_compile_prefix(context?)` and
  `driver.authored_c_compile_prefix(context?)` take an optional context;
  every browser-capable caller passes it. `nil` keeps the native API.
* `driver.output_tool_descriptors(context, kind)` reports the descriptor's
  `emar`/`emranlib` and no Darwin `dsymutil` for browser.
* `driver.get_target_profile(context)` returns the context's imported
  profile for browser.

Host configuration stays in the process globals `driver.CC`, `CFLAGS`, `AR`,
`RANLIB`, `UNAME`, `IS_DARWIN`, `TARGET_PROFILE`, `INSTALL_PATHS`, and
`PROBE_CACHE_DIRECTORY`. Browser initialization never assigns them, and every
browser compile, probe, archive, or path decision reads the descriptor.

## Context initialization and activation

Every public `driver.new_resolver_context(options)` returns an activated
context:

* an explicit host label (`linux`, `darwin`, `windows`, `native`) activates
  that label at once, without platform initialization;
* no label initializes the platform, resolves the host target, and activates
  it; and
* `target = "browser"` initializes the platform, builds and freezes the
  descriptor, and activates its identity before returning.

A constructor failure raises the specific diagnostic, as other constructor
errors do; `titanc` catches the raise and exits with the message, without a
Lua traceback. The private `driver._new_resolver_context(options,
descriptor?)` serves the public wrapper and the validated worker path; its
bootstrap flag admits only the layout and platform setup that precede the
first activation.

`titanc` constructs its context without a target, validates the CLI target,
and assigns `context.target`. For `browser` it then requires `--output`,
locks and marks the output root, and loads the persistent digest cache
([Output roots](#output-roots-and-the-target-marker)). The next platform
initialization, reached from `driver.configure_foreign_c`, builds the
descriptor and reactivates the context under the descriptor identity. The
early lock matters because descriptor probes write temporary files through
the context's output-scoped I/O, and the digest cache lets the archive and
header digests reuse precise observations. Native invocations keep their
original, later lock boundary.

`driver._finish_target_initialization(context)` performs, for browser:

1. discards the embedded interface provider, its rejection and overlap state,
   and the used embedded target-profile identity;
2. rejects hosts other than Linux and macOS:
   `browser builds are supported from Linux and macOS hosts (host is <host>)`,
   and rejects `driver.EMIT_LINE_DIRECTIVES == false` (`--no-line-directives`
   or `TITAN_NO_LINE_DIRECTIVES=1`) with `browser target owns option
   --no-line-directives (TITAN_NO_LINE_DIRECTIVES)`;
3. unless a descriptor was already imported, validates `TITAN_EXTRA_CPPFLAGS`,
   `TITAN_EXTRA_CFLAGS`, `TITAN_EXTRA_LDFLAGS`, and the normalized `--cflag`
   and `--ldflag` lists, computes the paths and probe-cache directory, and
   calls `browsertarget.build`;
4. reconstructs the context profile from `profile_data`; and
5. activates the semantic caches under the descriptor identity.

`configure_foreign_c` then records the current foreign-C configuration
without running the host profile probe. A browser constructor also skips
decoding a supplied embedded interface provider. Embedded inventories describe
native host code and native C facts, so no browser consumer (shared
availability, completion catalogues, probe-profile comparison, reconciliation,
embedded lookup, overlap rebinding, dependency closure, contextual owner
recovery, selection snapshots, or finalization) ever sees one.

## Unsupported flags

A browser invocation rejects these explicitly spelled flags:

`-fPIC`, `-fpic`, `-fPIE`, `-fpie`, `-pie`, `-shared`, `-dynamiclib`,
`-rdynamic`, `-pthread`, `-flto`, `-flto=*`, `-ffat-lto-objects`, `-march=*`,
`-mcpu=*`, `-mtune=*`, `-m32`, `-m64`, `-f[no-]wasm-exceptions`,
`-m[no-]exception-handling`, `-m[no-]legacy-exception-handling`, and any
`-sSUPPORT_LONGJMP` setting other than `wasm` or `-sWASM_LEGACY_EXCEPTIONS`
setting other than 1 (joined, split, bare, and boolean `NO_` aliases included).

The diagnostic is `browser target does not support <origin> flag "<flag>"`,
where `<origin>` is `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`,
`TITAN_EXTRA_LDFLAGS`, `--cflag` (the normalized compile extras, and
per-request `extra_compile_flags`), `--ldflag` (the normalized link extras),
or `compile_flags` for direct `browsertarget.build` inputs. A split setting
quotes both words. Flags are never dropped silently. `-fno-lto` is harmless
and accepted. Bare and `=1` longjmp settings select the wrong mode and are
rejected; bare legacy EH and `NO_WASM_LEGACY_EXCEPTIONS=0` mean legacy EH is
enabled. Inside the record, the same check reports
`invalid field "cflags": browser target does not support cflags flag "<flag>"`.

Browser tool spawns clear ambient `EMCC_CFLAGS`; deliberate EH overrides through opaque argument channels (`@file`, `-mllvm`, `-Xclang`, or `-Xlinker`) are unsupported and are not parsed by this check.

Emscripten has no fat Wasm objects: `-flto` produces bare LLVM bitcode with no
data segments to read. The descriptor never adds LTO and the Wasm reader
rejects bitcode objects and archive members
(`<origin>: LLVM bitcode (LTO) object is not supported`). Enabling LTO later
requires the same metadata and provider gates.

`titanc` rejects `--coverage` for an explicit or environment-selected browser
target with `--coverage is not supported for --target browser`, before target
validation and tool discovery, output locking and marker publication, and
`coverage.prepare`. This covers object-only, library, test, and authored-C-only
builds; native gcov backend and report options cannot inject host coverage
flags into emcc. Coverage options without `--coverage` retain their ordinary
`coverage options require --coverage` rejection. Disabling `#line` directives
(`--no-line-directives` or `TITAN_NO_LINE_DIRECTIVES=1`) is likewise rejected
at target initialization with `browser target owns option --no-line-directives
(TITAN_NO_LINE_DIRECTIVES)`.

The [link profile](#the-link-profile) owns the image settings the runtime
depends on, and the [build profile](#build-profiles) owns the object flags.
`browsertarget.trace_option(flag)` recognizes flags that would override the
profile's optimization, inlining, tail-call, frame-pointer, or debug settings:
`^-O`, `^-g`, and (after normalizing a leading `-fno-` to `-f`) `^-finline`,
`^-foptimize-sibling-calls`, or `^-fomit-frame-pointer`.
`browsertarget.owned_compile_option(flags, index)` adds every
`BINARYEN_EXTRA_PASSES` spelling: `-sBINARYEN_EXTRA_PASSES[=...]`, the split
`-s BINARYEN_EXTRA_PASSES[=...]`, and the same two forms of
`NO_BINARYEN_EXTRA_PASSES`. `browsertarget.build` rejects an owned compile
option in `inputs.compile_flags` (`browser <profile> profile owns compile
option "<flag>"`, quoting both words of a split spelling); the one exception is
a single `-O0` to `-O3` or `-Os` level in a `trace_control` build. The
descriptor validator enforces the same rule on the finished flags ([Object
flags](#object-flags)).
`browserlink.validate_extras(flags, options, build_profile, origin)` rejects
`trace_option` flags in the normalized compile and link extras and final link
extras unless `options.purpose` is `baseline`, `minicoro`, or `budget`, as well
as every `-s`, `-D`, or `-U` spelling, joined or split and with or without a
`NO_` prefix, of `SUPPORT_LONGJMP`, `WASM_LEGACY_EXCEPTIONS`, `ASYNCIFY`,
every `ASYNCIFY_*` setting, `JSPI`, every `JSPI_*` setting,
`BINARYEN_EXTRA_PASSES`, `STACK_SIZE`, `INITIAL_MEMORY`,
`ALLOW_MEMORY_GROWTH`, `MAXIMUM_MEMORY`, `ABORTING_MALLOC`, `EXIT_RUNTIME`,
`INVOKE_RUN`, `MODULARIZE`, `EXPORT_ES6`, `ENVIRONMENT`, `FORCE_FILESYSTEM`,
`FILESYSTEM`, `MINIMAL_RUNTIME`, `PRINTF_LONG_DOUBLE`, `EXPORTED_FUNCTIONS`,
`EXPORTED_RUNTIME_METHODS`, `INCOMING_MODULE_JS_API`, `ASSERTIONS`,
`STACK_OVERFLOW_CHECK`, and the target defines, plus `--no-entry` and
`--js-library` (`--js-library=...` included). One owned option has one
diagnostic, chosen by `origin`: compile extras (`origin == "compile"`) report
`browser <profile> profile owns compile option "<flag>"`, the same message as
`browsertarget.build`, and link extras report `browser <profile> link profile
owns option <flag>` (`browser link profile owns option <flag>` when the caller
passes no profile). `titanc` checks its normalized compile extras (`--cflag`,
`-I`, `-D`, `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`) as `compile` and its
link extras as `link`, both with `driver.BUILD_PROFILE`; image links and the
protocol probe check link extras under the descriptor's `build_profile`. So
`--cflag=-O2` in a production build reports `browser production profile owns
compile option "-O2"`, and `--ldflag=-O3` reports `browser production link
profile owns option -O3`. Other Emscripten settings pass through, so a later
user flag can never weaken the profile.

## Semantic-cache ownership

`driver.imported` (logical module name → source AST, interface, provider
provenance, restored object, or circular sentinel) and `types.registry` (FQTN
→ nominal owner) are process-global. Without an ownership rule a native
`titan.math`, application module, or nominal type already imported in the
process would supply a browser context's types, source selection, and
provider provenance.

The rule is that the whole nominal closure belongs to one target identity at a
time: the selected host label, or the descriptor identity for browser.

* `driver.activate_target_caches(context, identity)` first rejects a context
  whose generation is already stale. When `identity` differs from the current
  owner it advances the process generation and records the new owner. The
  first activation in a process adopts the `driver.imported`/`types.registry`
  pair that is installed at that moment, so a host that installed or restored
  its own pair for the selected owner keeps it; only a later change of target
  identity replaces both tables with fresh ones. It stamps the context with
  the current generation. Same-target contexts keep the warm caches and the
  existing behavior. Hosts may install or restore a pair only for the
  selected current owner, never across a target change.
* `driver.assert_target_context(context)` raises `compiler target context is
  not initialized` for a context that was never activated, and `compiler
  caches now belong to target <identity>; create a new context` for a context
  whose generation is older than the current one. Reactivation never steals
  the caches back for a stale context.

Replacing the complete closure, rather than pruning entries, preserves nominal
closure. A native → browser → native sequence in one process works without
any caller-side clearing; interleaving contexts of different targets is
rejected, never silently shared. Returning to an earlier target identity
creates a new generation, so an old context of that target stays stale.
Closing a stale context to release its own resources is allowed.

The guard runs at every semantic entry point: layout, platform, and foreign-C
initialization; the default and table loaders, at creation and on every warm
loader call; embedded-cache reconciliation; source lookup and object
restoration; completion catalogues; probe services and target profiles;
resolution plans and every captured plan callback; finalization; dynamic,
static, and dependency provider lookup; compilation preparation, batch
planning and compilation (including their compiled fast paths), captured
materialization, and the `compile_module` fast path; worker compilation and
staged publication; object invalidation; output preflight and target-marker
validation; Windows staging cleanup (including the non-Windows no-op path);
and both borrowed-context forms of the resolver option adapter.

Semantic APIs never construct a context implicitly, so a convenience call
cannot activate the host label and silently make a live browser context
stale. Platform and foreign-C initialization, static and dependency provider
lookup, finalization, the default and table loaders, and external resolution
(`resolve_external_modules(requests, known, context)` or `{context =
context}`) require a constructor-made context; the option adapter rejects an
omitted or raw `{io = ...}` argument (`resolver options require an explicit
context`) and checks a borrowed context's generation before any work. The
non-semantic conveniences take a different path: contextless native compiler
argv, default flags, and `shared_library_flags` detect only the host platform
through a shared synchronous strategy; contextless
`validate_generated_objects` uses an I/O- and digest-only memo for the call
(with a context it checks the generation, even for an empty object list, and
keeps the descriptor checks); and file revalidation
(`restat_c_header_dependencies` without a context, and
`perf.restat_c_header_dependencies`) carries a fresh I/O and header memo with
no generation. None of them creates a resolver, activates a label, or
invalidates a browser context. Explicit `new_resolver_context` calls,
including one with omitted options, remain the way to choose an owner.

### Cache audit

Exactly `driver.imported` and `types.registry` are keyed by logical module
name or FQTN and rebind with the generation. The other mutable globals are not
logical-name authorities:

* driver `loader_contexts` is weak-keyed by loader closure; embedded-provider
  snapshots are weak-keyed by the immutable caller table; compiler-family
  caches are keyed by I/O strategy and parsed argv; provider, contextual,
  layout, source, check, and interface caches belong to resolver contexts;
* `browsertarget`'s proxy map is weak-keyed by the immutable descriptor proxy,
  and its transported data is closed;
* the checker's `nominal_owner_indexes` is weak-keyed by an interface member
  table and holds that graph's own index; other checker globals are
  current-check state and sentinels;
* C-parser and `cdriver` process and generated-header caches are scoped by I/O
  or analysis authority and keyed by content, preprocessor state, or header;
  `cpp` probe caches and counters are I/O-strategy scoped; token spacing and
  spelling maps are weak token-graph maps;
* `foreigncache`'s global map holds only weak I/O-keyed statistics, and
  persisted conversions include profile and header-graph identities owned by
  caller-supplied adapters; and
* `csemantics`' power cache is keyed by integer exponent and `location`'s
  newline cache by a weak source subject; encoder, metadata, and FFI-header
  memos are owned by an operation or context; coder policy resets for each
  code-generation call.

`incremental.fresh_context` is a file-verification memo, never a resolver or a
semantic-cache consumer.

## Probe-cache isolation

The C probe cache key is the digest of the raw probe source only, so a shared
directory would hand LP64 answers to wasm32. Browser results live in
`<prefix>/var/cache/titan-probes/browser-6.0.13/<cprobe_cache.VERSION>/`
(`.../browser-6.0.13/2/` today), where `<prefix>` is `TITAN_PREFIX` when set
and otherwise `TITAN_ROOT`. The Emscripten version in the path keeps a pin
change from reusing stale answers. The native directory
`<prefix>/var/cache/titan-probes/2/` is unchanged. `TITAN_PROBE_CACHE_DISABLE=1`
removes the browser directory from the descriptor, and its root is not even
resolved, so an unusable `TITAN_PREFIX` cannot break a run with the cache
disabled. Transient analysis contexts use no persistent directory for either
target. The probe service for a browser context takes its compiler, flags, and
include roots from the descriptor and does not append the extra FFI roots a
second time.

## Output roots and the target marker

`--target browser` (from the option or `TITAN_TARGET`) without `--output`
fails with `--target browser requires --output`. An output root holds one
target, recorded by the marker `<output>/.titan-target`.
`driver.validate_output_target(context, directory, create)` runs under the
output lock:

* An existing marker must be a regular file (checked with `lstat`) of at most
  16 bytes whose content is one known source label followed by LF. It must
  name the selected target.
* Without a marker, a browser invocation that owns the directory (`create`)
  accepts it only when it is empty apart from the permanent
  `.titan-build.lock`, and then writes exactly `browser\n` before any other
  output. A host invocation never creates a marker.

```text
browser output root "<path>" is not empty and has no .titan-target marker; use a separate --output directory
output root "<path>" belongs to target "<marked>", not "<selected>"; use a separate --output directory
cannot read target marker "<path>": <reason>
cannot write target marker "<path>": <reason>
```

The read diagnostic uses `invalid target marker` as its reason for a
malformed, oversized, or non-regular marker. A valid marker is never
rewritten; it records the label, not the descriptor identity, so a changed
browser configuration in the same root causes certificate misses rather than a
refusal. A leading-dot name cannot be a module stem, so the marker never
collides with a generated file.

`titanc` validates every locked directory: the `--output` root (the only one
it may mark), a separate `--exe` directory, and, for a native build without
`--output`, every source root and the working directory, so a native
source-adjacent build also refuses a browser-marked domain. The [output
preflight](build-coordinator.md#pre-dispatch-output-preflight) validates the
output root and each held lock domain again and reserves every
`.titan-target` path, so no generated output can alias it.

## Object and link identity

* **Objects.** `incremental.toolchain_identity` adds the browser descriptor's
  `certification_target_identity` as `target_identity` to the hashed
  toolchain details, not only to its memo key, so a browser object
  certificate depends on the complete descriptor; only its compiler-owned SDK
  paths are [root-relative](incremental-compilation.md#compiler-owned-root-relocation).
  The native details table keeps its original shape and no target field, so
  native certificates are byte-identical. The compile prefix in the
  `options` component differs as well. A foreign-format object found at an
  expected path parses and misses.
* **Links.** The final-link key is a digest of the output paths only, so
  a program's key covers `<stem>.mjs`, `<stem>.wasm`, and `<stem>.wasm.map`.
  `titanc` always supplies its ordinary native profile identity as
  `policy.target`; `linkcertificate.prepare` is the sole writer of the browser
  value: for a browser context it copies the recipe policy and sets `target`
  to the same relocatable descriptor digest without mutating the caller's
  table, which covers non-CLI callers too. A record written by another target
  or another browser configuration is therefore a miss. The browser policy
  also records `browser_profile`, the link profile's `identity_inputs`, and
  for library mode `browser_probe`, the runner's `--probe` report of the Node
  (and Chrome) that the executing check uses. The `runtime` file field lists
  the eight required SDK assets (`libtitan.a`, `titan-browser-library.js`,
  `titan-browser-trace.js`, the loader, and the four runner files) plus the
  browser `liblua.a` and its record, all certified by content, so changing any
  of them relinks while object certificates still hit.
* **Backends.** `linkcertificate.linker_backend` selects by link kind
  (`request.kind`, else `context.link_kind`, which `titanc` sets to `program`,
  `test`, or `library`). A library uses backend `archive`: the output tools
  are the descriptor's `emar` and `emranlib`, observed without linker
  selection, compiler link-stage discovery, or native library execution, and
  the native library policy carries no native link inputs. A program or test
  uses backend `wasm`: the policy appends `-Wl,--trace` (the pinned `wasm-ld`
  rejects GNU `--dependency-file`) and `prepare` records `policy.trace_inputs`
  (the `FILE_FIELDS` paths); `compile_browser_image` captures the linker's
  stdout through `context.io:run` with stderr inherited and writes it to the
  ticket's `dependency_output`, and on commit each trace line must name a
  regular file, or an `archive(member)` whose archive is resolved by testing
  every `(` boundary against `policy.trace_inputs` first and then against
  regular archives on disk, and every named file is hashed through the existing
  certificate machinery (`NUL in Wasm linker input trace`, `ambiguous Wasm
  linker input trace: <line>`, `invalid Wasm linker input trace: <line>`,
  `empty Wasm linker input trace`). Opaque link-flag mechanisms and uncertified
  inputs still make either record uncacheable; neither backend is a permissive
  fallback.
* **SDK digests.** `titanc` loads the browser SDK digest manifest only from
  `descriptor.paths.sdk_digests`; a missing browser SDK contributes no entries,
  and the native manifest is never loaded for browser.

Native objects, archives, and link records keep their bytes and mtimes on a
warm native build after browser builds in a separate root.

## Worker transport

Workers are separate processes with one target each. `driver.plan_descriptor`
already carries the coordinator's file selection.
`driver.worker_configuration` adds the descriptor as
`configuration.target_descriptor`, the closed `browsertarget.export` data,
beside the existing `configuration.resolver.target`; host configurations omit
the key. Browser configurations skip the native `perf.check_runtime`, because
object compilation needs headers, not a native runtime build.

`driver.new_worker_context` imports and freezes the descriptor before creating
the context and passes it to the private constructor, which reconstructs the
profile from `profile_data` and activates the identity. A browser label
without a valid descriptor, or a descriptor with a host label, fails with
`incompatible build worker configuration`. Workers never select files, run
`emcc --version`, reread or rehash the record, archive, or headers, or read
`TITAN_TARGET`; they still verify the compiler inventory. Coordinator and
workers come from one installation, so `BUILD_WORKER_PROTOCOL` is unchanged.

## Provider lookup

A browser context has no dynamic pass and never calls `support._loadlib`:

* `find_dependency_interface` skips the embedded inventory and searches only
  the static format; `find_dynamic_interface` returns no result; direct legacy
  DSO inspection refuses with `browser providers require static archives`.
* `find_static_interface` searches `descriptor.paths.titan_bin` first, then the
  configured Titan path (`TITAN_PATH_0_6`, then `TITAN_PATH`) expanded with
  `.` as its default, so `;;` inserts `.` and an unset path searches only `.`.
  The native SDK root never appears.
* Each candidate archive is scanned with the descriptor fingerprint as the
  expected target and then checked structurally. A native archive, or a Wasm
  archive with other features, is a terminal error, never a source fallback:
  `cannot inspect static provider '<path>': <member origin>: target mismatch:
  <field mismatch>`.
* Browser inspection never accepts the coordinator's metadata-only view of a
  planned archive; it always rescans the bytes.
* The existing binary-first, `--source-first`/`--test`, and explicit-source
  policies are unchanged. Binding is always `direct`: `handle` and `global`
  bindings cannot arise without dynamic providers. The logical `<path>.so`
  filename inside `Type.Module` remains an identity string only.

The browser SDK root holds the browser standard provider `titan.a`, so the
thirteen [core stdlib](#the-browser-standard-library) modules resolve from it,
ahead of the Titan path and source. The native-only standard modules have no
browser source either, so their imports fail with the ordinary
`module 'titan.<name>' not found` diagnostic ([target source
selection](target-source-selection.md#make-inventories-and-audits)).

## Library mode and structural validation

A no-`main` browser build publishes one archive. `driver.provider_output_path`
uses the `.a` extension, the certified output set is `{<provider>.a}`, the
native runtime link inputs are skipped, and `driver.link_provider_pair`
dispatches to `driver.stage_browser_provider`:

1. compile the objects; `driver.derive_target_fingerprint` cross-checks the
   first generated object against the descriptor fingerprint, and every other
   generated object and split part must match;
2. stage the archive with `driver.build_static_archive(..., context)`, which
   requires the target to match the descriptor fingerprint (`browser archive
   target mismatch: <mismatch>`), uses the descriptor's `emar`/`emranlib`,
   requires the deterministic-tool probe (`browser archive tools require
   deterministic qDc and -D modes`), and batches `qDc` (the capability probes
   capture and discard tool stderr/stdout through `run_argv`'s output-discard
   mode independently of `driver.LIVE_PROGRESS`, while keeping `-v` command
   echoes, exit status, and the diagnostics of actual archive writes and
   indexing);
3. verify the archive's member sequence byte for byte;
4. check the exact key set;
5. compare the embedded ABI, types, and layouts with the coordinator's
   expected entries;
6. run `driver.validate_browser_provider`; and
7. publish only `<provider>.a` through `driver.publish_provider_bundle`, which
   rescans the staged archive with the descriptor fingerprint, validates it
   structurally again, runs the [executing protocol
   check](#the-executing-protocol-runner), and only then considers the
   unchanged-archive shortcut or renames the staged archive over the
   destination as the commit point.

Before linking, `titanc` requires the SDK and a working Node 26+
(`driver.browser_node_ready`, below) for every library build, and records the
`protocol` link profile and the runner's probe report in the link policy.
Structural validation, the companion refusal, and publication are specified in
[Static compiled modules](static-compiled-modules.md#browser-archive-only-providers).
Structural validation verifies the protocol symbols and imports that the host
loader would otherwise inspect; the executing check then runs them. Running the
check before the identical-archive shortcut means that a newly required check,
such as one after a runner or JavaScript library change, executes before a
byte-identical archive is kept. There is no public option that skips it, and a
missing Node, runtime, loader, or runner is diagnosed, never skipped. Internal
archive construction (`driver.build_static_archive` and the staged
member-verification API used by `make browser-sdk`) stays SDK- and
Node-independent.

## The link profile

`browserlink.profile(descriptor, options)` returns the complete set of
Emscripten link settings for one image, `{link_flags, compile_flags,
identity_inputs}`. Every image, including the protocol probe and test-owned
C images, links through it; neither the Makefile nor a test duplicates the
flag list.

`options` is closed: `purpose`, `assertions`, `optimization`, `budgets`, and
`entry` (`unknown browser link profile option <key>`).

* `purpose` is `program`, `test`, `protocol`, `gate`, `minicoro`, `budget`,
  or `baseline` (`invalid browser link profile purpose`). Programs use
  `program` and `--test` images use `test`; the executing check uses
  `protocol`; the others serve the runtime-evidence and measurement harnesses.
* `assertions` is required and is 0 or 2 (`browser assertions must be 0 or
  2`).
* `optimization` is `O1` or `O2`, only for `minicoro`, `budget`, and
  `baseline` (`invalid browser link optimization override`); it yields
  `compile_flags = {"-O1"}` or `{"-O2"}` and the matching link flag.
* `budgets` overrides `stack_size` (a positive multiple of 16),
  `initial_memory`, and `maximum_memory` (positive multiples of 65536,
  initial at most maximum, maximum at most 2147483648), only for `budget`
  (`browser budget overrides require the budget profile`, `invalid browser
  budget override <key>`, `invalid browser memory budgets`).
* `entry` defaults to `titan`; the only alternative, `lua-main`, is for the
  `baseline` measurement of the fork's own Lua interpreter (`invalid browser
  link entry`).
* The descriptor's `build_profile` selects the level and the frame flags
  ([Link flags per purpose](#link-flags-per-purpose)); a descriptor without a
  valid one is refused with `invalid browser build profile`.

`link_flags` is, in order:

| Flags | Purpose |
| --- | --- |
| `<level>`, then `-fno-inline -fno-optimize-sibling-calls` except for a production `program`, then `-gsource-map -g2` | the level is the `optimization` override or else the descriptor's last `-O` flag (`-O1` for validation, `-O3` for production), so the link optimizes like its objects; a production program accepts the frames that inlining costs, while every other profile and purpose keeps the frame flags ([Link flags per purpose](#link-flags-per-purpose)); `-gsource-map -g2` writes the source map and keeps the Wasm `name` section in every profile |
| `-sBINARYEN_EXTRA_PASSES=--skip-pass=inlining-optimizing,--skip-pass=duplicate-function-elimination` only for a production `test` image | retain distinct physical functions for test traces; JSPI needs no instrumentation-local cleanup passes |
| `-sJSPI=1 -sJSPI_IMPORTS=["titan_mco_transfer","titan_mco_destroy"] -sJSPI_EXPORTS=["titan_browser_entry","titan_mco_entry"]` | Emscripten 6.0.13 uses current `WebAssembly.Suspending` imports and `WebAssembly.promising` exports. The `gate` purpose adds its guarded export and `emscripten_sleep`; the interpreter baseline promises `main`. Authored `EM_ASYNC_JS` imports carry their own async declaration. |
| `-sSUPPORT_LONGJMP=<sjlj> -sWASM_LEGACY_EXCEPTIONS=1` | the record's verified longjmp mode, `wasm`, with Emscripten 6.0.13's legacy EH encoding, matching every object and `liblua.a` |
| `-sSTACK_SIZE=1048576` | the main linear C stack; there is no saved instrumentation-stack buffer |
| `-sINITIAL_MEMORY=16777216 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2147483648 -sABORTING_MALLOC=0` | coroutine stacks are committed eagerly, so memory grows; a failed `malloc` returns NULL and becomes Lua's ordinary out-of-memory error instead of aborting |
| `-sEXIT_RUNTIME=0 -sINVOKE_RUN=0 --no-entry` | completion is Titan-owned and the loader calls the entry; there is no native `main` (`--no-entry` is omitted for `lua-main`) |
| `-sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,node` | one ES-module factory call per instance, and one image for both engines |
| `-sFORCE_FILESYSTEM=1` | keeps Emscripten's filesystem and TTY layer in every image (see below) |
| `-sPRINTF_LONG_DOUBLE=1` | links Emscripten's full-precision `long double` printf in every image (see below) |
| `-sEXPORTED_FUNCTIONS=["_titan_browser_entry","_titan_browser_trace_identity","_malloc","_free"]` | the entry, the 64-hex image identity export, and heap allocation for argument marshalling; the `gate` purpose adds `_titan_browser_gate_guarded` and `_titan_browser_gate_observe`; `lua-main` exports `_main`, `_malloc`, and `_free` instead |
| `-sEXPORTED_RUNTIME_METHODS=["ccall","HEAPU8"]` | the promised entry call and current heap view used by the loader |
| `-sINCOMING_MODULE_JS_API=["stdin","stdout","stderr","locateFile","onAbort"]` | the only module options the loader passes |
| `--js-library <sdk>/titan-browser-library.js`, `--js-library <sdk>/titan-browser-trace.js` | the completion/admission and eager trace-map/stack-capture imports (omitted for `lua-main`) |
| `-sASSERTIONS=<0\|2> -sSTACK_OVERFLOW_CHECK=2` | assertions are selectable; linear-stack bounds/cookies are restored on every JSPI context transition in either mode |

`compile_flags` is empty without an override. `identity_inputs` is plain data,
exactly `{target_identity, profile, purpose, entry, assertions, optimization,
backend, budgets, link_flags, compile_flags}`, where `backend` is `"jspi"`, `profile` is the
descriptor's `build_profile`, `optimization` is the override or
else the last `-O` flag of the descriptor's compile prefix and `budgets` holds
all three effective sizes. Image certificates hash it together with the content
of the referenced SDK assets, so a budget, profile, or JavaScript library
change relinks, and incompatible variants use separate output trees.

**Filesystem.** `-sFORCE_FILESYSTEM=1` is set for every purpose, including
`lua-main`. Emscripten 6.0.13 otherwise drops its filesystem for an image whose
only stdio import is `fd_write`, such as a pure-C image, and its WASI
`fd_write` then decodes the bytes as UTF-8 and writes them to the console,
bypassing the per-byte `Module.stdout`/`Module.stderr` hooks. Node happened to
capture that console text, but Chromium did not, and neither kept the bytes
exact. The flag restores the TTY layer, at no `.wasm` cost and 457 more `.mjs`
bytes for images that already use stdio ([Baseline](#baseline)). User
`FORCE_FILESYSTEM`, `FILESYSTEM`, and `MINIMAL_RUNTIME` settings are rejected.

**Long-double formatting.** `-sPRINTF_LONG_DOUBLE=1` is set for every purpose
and entry, including `lua-main`. Clang's wasm32 `long double` is IEEE
binary128: `emcc -dM -E` predefines `__LDBL_MANT_DIG__` as 113 and
`__SIZEOF_LONG_DOUBLE__` as 16. Emscripten 6.0.13 nevertheless defaults to
`PRINTF_LONG_DOUBLE = false` (`src/settings.js`: it prints `long double` "as
64-bit doubles, which saves libc code size"), so its default printf narrows
every `%L` conversion to `double` while `strtold` still parses the full value.
Titan writes `long double` text with `%La` in
`titan_reflect_format_long_double` (`titan-runtime/titan.h`), which the
generated native-field projections (`titan-compiler/coder/reflection.lua`)
call for `reflect` projections and the `protobuf` and `transfer` codecs; under
the default, a projected value no longer reads back equal to the original. The
setting is profile-owned: `-sPRINTF_LONG_DOUBLE=0`, the split `-s` form,
`NO_PRINTF_LONG_DOUBLE`, and the `-D`/`-U` spellings are rejected like the
other owned settings. Because the link flags are part of `identity_inputs`,
the setting relinks every certified image without a cache or certificate
schema change; object flags and the descriptor are unchanged.

Its cost, measured with the validation profile on Linux (three warm serial
samples per image and mode, timing only the certified final `emcc` link; sizes
were identical across samples):

| Image | `.wasm` | `.mjs` | `.wasm.map` | Median final link |
| --- | ---: | ---: | ---: | --- |
| `spec/fixtures/browser_images/long_double.titan` program | +1,719 B (+0.167%) | +8 B | +1,159 B | 0.623 s → 0.666 s |
| a test image of the ten browser owners from `coroutine.tests` through `path.tests` | +1,720 B (+0.006%) | +8 B | +1,175 B | 14.03 s → 15.72 s |

The link times are observed warm medians, not a controlled estimate.
`spec/coder/browser_images_spec.lua` checks the flag for every profile,
purpose, and entry, rejects every override spelling, and formats
`0x1.000000000000001p0` (1 + 2^-60) on Node and Chromium: the browser text
must be `1.00000000000000000087`, and it must equal the native program's text
when the native `long double` is wider than `double`. A host whose
`long double` is as wide as `double`, such as macOS on Arm, has no extended
native reference, so the test checks only the browser text there.

**`HEAPU8`.** `HEAPU8` is a runtime export so that the loader can write
arguments into heap memory and the completion import can copy its payload.
The loader keeps it private: it never publishes the Module, its memory, or a
general call bridge, and it reads `HEAPU8` again after every allocation that
can grow memory instead of retaining an old view.

**Internal selection.** `driver.browser_link_options` is a Lua field for
in-process harnesses (`{purpose=..., assertions=..., ...}`), set before
`titanc` runs in the same Lua process; there is no command-line option or
environment variable, and it must name a purpose. The image kind decides
between `program` and `test`: `driver.browser_link_kind(context)` is `test`
for a `--test` link (`context.link_kind == "test"`) and `program` otherwise.
`driver.browser_link_purpose(context, purpose)` returns that kind when no
purpose is given, passes a harness purpose (`protocol`, `gate`, `minicoro`,
`budget`, or `baseline`) through, and refuses a `program` or `test` purpose
that contradicts a known kind with `browser link purpose "<purpose>" does not
match this <kind> image`, so a test image is never certified or linked with the
program profile. Target initialization does not know the image kind yet, so it
checks only the options' shape: a preset without a purpose is refused with
`browser link profile options require a purpose`, and the options are
validated against the built descriptor. For `baseline`, `minicoro`, and
`budget` it marks the descriptor `trace_control`, and an `optimization`
override enters the descriptor's compile prefix ([the harness level
hook](#the-harness-level-hook)). The kind check happens where the kind is
known. `driver.browser_link_plan(context, purpose)` resolves the purpose
against the kind and returns the plan for the harness options when they are
set (refusing a purposeless preset with the same message) and otherwise for
`{purpose = <resolved kind>, assertions = 2}`. `titanc` certifies the final
link with `browser_link_plan(context, kind)`, and
`driver.compile_browser_image` resolves its purpose the same way, also
checking the purpose of an explicit `options.profile`.

## Build profiles

`TITAN_BUILD_PROFILE` (`driver.BUILD_PROFILE`, `production` by default)
selects the browser object and link profile as well as the native one. Target
initialization passes it to `browsertarget.build` as `inputs.build_profile`,
and the descriptor records it as `build_profile` (D26). Probes, generated
objects, `--c-source` objects, entrypoint compiles, and imported worker
descriptors therefore certify one configuration, and the descriptor identity
changes with the profile even where flags would agree, so the two profiles
never share objects or link records. `make browser-sdk` builds the SDK's
runtime and standard library under the profile in its environment (Make's
default for that goal is `production`), and images link the installed SDK
archives as they are, as native images link the installed standard provider
(D25). The user contract is in [build
profiles](../language/browser-target.md#build-profiles).

### Object flags

`browsertarget.object_flags(build_profile)` is the single source of the owned
object prefix:

| Profile | Owned object flags |
| --- | --- |
| `validation` | `--std=c99 -O1 -fno-inline -fno-optimize-sibling-calls -Wall -Wno-unused-but-set-variable -Wno-unused-function -gline-tables-only -sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1` |
| `production` | `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -gline-tables-only -sSUPPORT_LONGJMP=wasm -sWASM_LEGACY_EXCEPTIONS=1` |

`validation` retains #330's physical-frame settings with the coordinated
Wasm-EH longjmp change. The production level is the one constant
`PRODUCTION_LEVEL = "-O3"`, the native production level,
chosen over `-O2` by [measurement](#measurements) (D34). Both profiles keep
`-gline-tables-only` ([why not `-g2`](#compile-prefix-and-target-defines)),
the warnings, and the longjmp mode; the record's `lua_defines` and the target
defines follow.

The validator, shared by `build` and `import`, requires `compile_flags` to
start with exactly that list (`browser <profile> profile compile flags do not
match its object profile`) and refuses every later owned compile option
(`browsertarget.owned_compile_option`: every `trace_option` flag and every
`-sBINARYEN_EXTRA_PASSES` spelling) with `browser <profile> profile owns
compile option "<flag>"`. The only exception is the [harness level
hook](#the-harness-level-hook).

### Link flags per purpose

`browserlink.profile` takes the link level from the harness `optimization`
override or else from the descriptor's last `-O` compile flag, so a
Titan-entry link optimizes at its objects' level, and it adds the frame flags
everywhere except a production program:

| Profile | Purpose | Level and frame flags | `-sBINARYEN_EXTRA_PASSES=` |
| --- | --- | --- | --- |
| `validation` | every purpose | `-O1` (or the harness level) `-fno-inline -fno-optimize-sibling-calls` | omitted |
| `production` | `program` | `-O3` | omitted |
| `production` | `test` | `-O3 -fno-inline -fno-optimize-sibling-calls` | `--skip-pass=inlining-optimizing,--skip-pass=duplicate-function-elimination` |
| `production` | `protocol`, `gate`, `minicoro`, `budget`, `baseline` | `-O3` (or the harness level) `-fno-inline -fno-optimize-sibling-calls` | omitted |

`-gsource-map -g2` and the rest of [the link profile](#the-link-profile)
follow in every row, and the pass list is omitted for the `lua-main` entry. A
validation test image's flags equal its program image's. The image kind
decides between `program` and `test`; a harness that sets
`driver.browser_link_options` may choose one of the harness purposes instead,
but a contrary `program` or `test` purpose is an error ([internal
selection](#the-link-profile)). The trace gate's `build-trace.lua` therefore
names `test` for its test image and `program` for its uncaught image.

### Binaryen pass order

JSPI does not run a Wasm stack-rewriting pass. Production test images still
skip Binaryen's inlining and duplicate-function elimination because physical
trace identity is part of their contract. The old post-instrumentation
`simplify-locals,reorder-locals` workaround is removed rather than carried
into this backend.


### Test images

A production `--test` image keeps the exact frames that the trace gate
asserts, as native `--test` keeps its own (D25):

* **Test owners.** `driver.test_owner_flags(test_build, test_functions,
  context)` puts `-fno-inline` before `test_runner.TEST_COMPILE_FLAGS`
  (`-fno-optimize-sibling-calls`) for a browser context whose descriptor
  profile is `production`. A worker reads the profile from its imported
  descriptor. The flags follow the descriptor prefix on the owner's generated
  C only, `codegen.test_flags` certifies them, and the descriptor identity
  carries the profile. Other modules, the generated runner, and the SDK
  archives keep the profile's flags.
* **No Binaryen inlining.** The `test` purpose adds
  `--skip-pass=inlining-optimizing` to `BINARYEN_EXTRA_PASSES`. `--skip-pass`
  is a `wasm-opt` option, not a pass: it disables the named pass wherever it
  runs in the selected optimization pipeline; its position relative to other
  pass arguments does not matter. The pipeline's pass is named
  `inlining-optimizing`; `--skip-pass=inlining` disables nothing. An earlier
  pass-timing control measured 3.7e-07 s with the skip against 0.010 s without
  it, and the output differed.
* **No duplicate-function folding (D31).** With only inlining skipped, four
  production test-image rows lost frames: `test_selected_contributor_locations`
  and `test_locations_before_after_yield` (`locations.browser.titan`), and
  `test_static_entry` and `test_lambda_entry` (`wrappers.titan`). Binaryen's
  `duplicate-function-elimination` had folded byte-identical bodies
  (`selected_leaf` into `original_leaf`, `selected_outer` into
  `direct_middle`). Adding `-fno-inline -fno-optimize-sibling-calls` to every
  object did not restore them; `--skip-pass=duplicate-function-elimination`
  did, and no gate assertion changed.
* **Validation needs neither.** Its objects already carry the frame flags,
  and its `-O1` link never runs the Binaryen optimizer.

A production *program* image accepts inlining, as native production does. The
trace gate's production program rows require the shown Titan frames to be an
ordered subsequence of the row's exact frames, with the exact file and
execution line (file only on WebKit), and each name to be the matched frame's
or that of a later expected frame, the enclosing caller it was inlined into
(D28, D32). At least one Titan frame must appear, and the outermost must be the
entry, `trace_uncaught.main`: the entry is called from C and cannot be inlined
away. Every other line must be a `[C]` frame, a Lua frame, or a documented
marker, so an unparsed line fails the row. Lua frames, markers, fallbacks, and
merge order stay exact, and no `titanentry` symbol or mangled C name may
appear. Test-image and validation rows stay byte-exact. The gate takes the
installation profile from `manifest.json` and fails without a valid one, so a
missing profile cannot weaken a production program row.

### Historical instrumentation measurements

The #330/#343 instrumentation-local and engine-stack measurements used
JavaScript SJLJ and Asyncify, before the Wasm-EH and JSPI cutovers. Their
transformation-dependent local counts and recursion ceilings do not describe
current images or justify a current pass list. The surviving production-test
skips preserve trace identity independently of the coroutine backend.


### The harness level hook

When `driver.browser_link_options.purpose` is `baseline`, `minicoro`, or
`budget`, target initialization builds the descriptor with `trace_control =
true` (D27 addendum). Only such a descriptor may carry an owned option after
the profile prefix: exactly one trailing level flag, `-O0` to `-O3` or `-Os`,
which comes from the `optimization` override (`-O1` or `-O2`) or from a
harness `--cflag` (`validate_extras` admits level flags for these three
purposes). One rule, `check_owned_tail`, applies in both `browsertarget.build`
(on the extras, before tool discovery) and the validator (after the profile
prefix): every other owned option, including a second level or any
`BINARYEN_EXTRA_PASSES` spelling, is refused with `browser <profile> profile
owns compile option "<flag>"`. `trace_control` is descriptor data and enters
the identity. The hook is reachable only through the Lua API, and its options
must name a purpose ([internal selection](#the-link-profile)); without it,
`--cflag`, `--ldflag`, and the `TITAN_EXTRA_*` variables are refused as above,
naming the profile. Its users are CI's baseline cell,
`scripts/browser_baseline.lua`, and
the measurement and budget specs. Production builds stay at
`PRODUCTION_LEVEL`.

### Measurements

Measured for #343 before the Wasm-EH cutover, using JavaScript SJLJ with
Emscripten 6.0.13, Node 24.19.0, host Chrome 156.0.8078.79, and
Playwright 1.56.1's Firefox 142.0.1 and WebKit 26.0, one
cold process per depth, on the retained trace fixture
(`spec/fixtures/browser_trace`) and its session-only measurement copy. `-O2`
is the same tree with `PRODUCTION_LEVEL` patched for the comparison; it does
not ship. Engine ceilings are the deepest passing level with Lua's limit out of
the way (a session-only `-DLUAI_MAXCCALLS=60000` install); `a2` and `a0` are
assertions 2 and 0.

Ceilings at assertions 2 / 0 (`—` where a cell was not measured; the WebKit
`-O3` assertions-2 mixed sweep found no failure up to its 4,096 maximum). The
Firefox mixed cells are the fixture's own boundary, not the engine's: one
level deeper, the native case fails its own assertions (it returns status 1)
before the engine raises. In production those failing rows record a failed
capture, `(native Titan frames unavailable: capture failed)` followed by the
truncation marker; the validation rows record only the failed case. The
engine's own `InternalError: too
much recursion` came later. Under validation it appeared at 576 at assertions
2, and at assertions 0 it was first observed at 640. Under production it was
first observed at 1,792 (assertions 2) and 1,776 (assertions 0). The sweeps did
not sample the depths in between.

| Construct, engine | `-O2` | `-O3` (production) | Validation |
| --- | ---: | ---: | ---: |
| Mixed Lua/Titan, Node | 1,208 / 1,210 | 1,220 / 1,222 | 318 / 319 |
| Mixed Lua/Titan, Chromium | 1,226 / — | 1,239 / 1,242 | 320 / 321 |
| Mixed Lua/Titan, Firefox (fixture boundary) | — | 1,757 / 1,763 | 572 / 574 |
| Mixed Lua/Titan, WebKit | — | > 4,096 / 4,095 | 479 (contiguous) / 1,074 |
| Nested `pcall`, Node | 364 / 419 | 362 / 416 | 201 / 204 |
| Nested `pcall`, Chromium | 372 / — | 367 / 421 | 201 / — |
| Nested `pcall`, Firefox | — | 775 / 947 | 385 / — |
| Nested `pcall`, WebKit | — | 2,121 / 2,401 | 639 / — |
| Nested `coroutine.resume`, Node | 369 / 425 | 366 / 421 | 201 / 204 |
| Nested `coroutine.resume`, Chromium | 376 / — | 373 / 434 | 201 / — |
| Nested `coroutine.resume`, Firefox | — | 799 / 994 | 393 / — |
| Nested `coroutine.resume`, WebKit | — | 2,216 / 2,528 | 831 / — |

Production raises the ceilings on every engine. At assertions 2, nested
`pcall` and `coroutine.resume` gain about 1.8× on V8 (362/201, 366/201 on
Node), 2.0× on Firefox (775/385, 799/393), and 3.3× and 2.7× on WebKit
(2,121/639, 2,216/831). Mixed recursion, where inlining removes frames from
each level, gains about 3.8× on V8 (1,220/318 on Node, 1,239/320 on
Chromium), 3.1× on Firefox (1,757/572, both fixture boundaries), and at
least 8.5× on WebKit (more than 4,096/479; 3.8× at assertions 0,
4,095/1,074). The order never changes. Validation binds in every measured
cell, `pcall` and `coroutine.resume` bind on every engine in both profiles,
and V8 binds in both profiles: production `pcall` reaches 362 levels on Node,
against 775 on Firefox and 2,121 on WebKit. Over the measured cells the
minimum was therefore 204 counts, under validation at assertions 2 on
Node and Chromium. Validation `pcall` and `coroutine.resume` were measured at
assertions 0 only on Node, where they reach 204 levels against 201 at
assertions 2.

| Measurement | `-O2` | `-O3` (production) | Validation |
| --- | ---: | ---: | ---: |
| `getCcalls` counts per level, every construct | 1 | 1 | 1 |
| Test image `.wasm` / `.wasm.map` bytes, a2 | 3,182,978 / 871,991 | 3,140,922 / 868,617 | 5,128,240 / 1,227,298 |
| Test image `.wasm` / `.wasm.map` bytes, a0 | 3,171,020 / 869,947 | 3,109,537 / 867,001 | 5,115,589 / 1,221,997 |
| Program image of the same fixture, `.wasm` / `.wasm.map` bytes, a2 | 3,122,463 / 870,683 | 3,142,564 / 913,532 | (links like the test image) |
| Final link, test / program image, a2 | 8.686 s / 9.287 s | 10.951 s / 11.612 s | 9.065 s |
| Maximum function locals, test a2 / test a0 / program a2 | 100 / 67 / 100 | 100 / 68 / 100 | 1,993 / 1,993 / — |

The `-O3` test image is 1.3% smaller than the `-O2` one (3,140,922 against
3,182,978 bytes), while the `-O3` program image is 0.6% larger (3,142,564
against 3,122,463) with a 4.9% larger map; `-O3` links about 2.3 s slower. No
image comes near V8's 50,000-locals limit.

The #329 micro-benchmark program, built as an ordinary program at each level
(median of three runs, in milliseconds), next to the #329 harness re-run on the
same host at the base (`scripts/browser_baseline.lua`, `-O1` with Asyncify):

| Benchmark | Node `-O2` | Node `-O3` (production) | Node, #329 harness | Chromium `-O3` (production) | Chromium, #329 harness |
| --- | ---: | ---: | ---: | ---: | ---: |
| 200 000 calls | 3.8 | 3.3 | 3.7 | 14.1 | 5.8 |
| 50 000 closures | 6.8 | 5.7 | 8.1 | 23.0 | 7.9 |
| 100 000-element Array | 1.4 | 1.2 | 2.1 | 3.6 | 2.4 |
| 5 000-step string build | 1.5 | 1.5 | 2.2 | 5.1 | 2.5 |
| 20 000 coroutine switches | 94.5 | 72.1 | 162.5 | 149.4 | 181.4 |
| 200 suspensions, total | 216 | 216 | 215.4 | 814.2 | 805.8 |

The benchmark images were 1,369,778 (`-O3`) and 1,372,292 (`-O2`) bytes, with
295,199 and 285,073-byte maps; the Chromium `-O3` image was 1,369,468 bytes
with a 295,187-byte map. Between the two production levels on Node, `-O3`
cuts the coroutine-switch time by about 23% and is equal or faster on the
other benchmarks; the suspension round trip is Asyncify-bound and does not
change. The #329
harness columns are a reference, not a like-for-like comparison: that harness
links with the `baseline` purpose, without the trace libraries and the map,
while the production columns are ordinary installed-profile programs. The
Chromium numbers are therefore recorded as measured, with no regression or
speedup claimed against the harness.

The trace gate's own images, as the gate builds them with its current 36
native cases (maximum locals count parameters and declared locals):

| Image | Production `.wasm` / `.wasm.map` bytes, maximum locals | Validation |
| --- | ---: | ---: |
| Test image, a2 | 3,231,911 / 904,919, 104 | 5,261,947 / 1,279,867, 2,164 |
| Test image, a0 | 3,199,994 / 903,404, 68 | 5,249,175 / 1,274,520, 2,164 |
| `trace_uncaught` program, a2 | 659,474 / 118,115, 38 | 1,052,334 / 150,948, 482 |
| `trace_uncaught` program, a0 | 650,671 / 117,374, 38 | 1,043,126 / 147,764, 482 |

Every one of these images instantiates and passes the gate on Node, Chromium,
Firefox, and WebKit.

## Program and test images

`titanc` plans a browser program or test like a native one; the build
coordinator's [output preflight](build-coordinator.md#pre-dispatch-output-preflight)
reserves the executable (`.mjs`), its WebAssembly binary (`.wasm`), and its
source map (`.wasm.map`). `driver.browser_program_path(stem, explicit)` maps
the output: the explicit `--exe` (which must end in `.mjs`: `browser executable
output "<path>" must end in .mjs`) or `<stem>.mjs`, where the stem is the
native program output path, plus its `.wasm` and `.wasm.map` siblings. A test
image's stem is the first root's. Before certification `titanc` requires the
SDK and the program profile; the [executing
check](#the-executing-protocol-runner) then runs for selected archives as on
native hosts, and `driver.compile_program` renders the [browser
entrypoint](#the-browser-entrypoint) and calls `driver.compile_browser_image`.

`driver.compile_browser_image(contents, entrypoint, executable, objects,
archives, extra_objects, verbose, options)` (with `options.context` required,
plus optional `profile`, `link_extra_flags`, `before_commit`, `after_publish`,
`final_link_flags`, and `dependency_output`) links one image:

1. require the SDK, resolve the purpose with `driver.browser_link_purpose`
   (the image kind unless a harness purpose was named), select the plan (an
   explicit `options.profile`, whose purpose passes the same check, otherwise
   `browser_link_plan`), and check the link extras and final link flags with
   `validate_extras` under the descriptor's `build_profile`;
2. scan the runtime archive with the descriptor fingerprint and validate it
   structurally, as a provider;
3. compute the 64-character lowercase hexadecimal image identity with
   `browsertrace.identity(context, contents, compile, identity_flags, groups)`
   ([Source-map extensions and image identity](#source-map-extensions-and-image-identity))
   from the original entrypoint contents and the link's canonical input recipe,
   append `browsertrace.declaration(identity)` (`titan_browser_trace_image_id`
   and `titan_browser_trace_identity(void)`) to the synthetic entrypoint C
   source, and compile it with `driver.generated_compile_prefix(context)` plus
   the plan's compile flags;
4. link into a staging directory beside the destination, under the final
   basenames so that the generated `.mjs` and `.wasm` (`sourceMappingURL`)
   locate `<basename>.wasm` and `<basename>.wasm.map` by name:
   `emcc <link_flags> -o <staged>.mjs <entry.o> <objects> <archives>
   <extra objects> -Wl,--start-group libtitan.a <archives> liblua.a
   -Wl,--end-group <link extras> <final_link_flags>`, capturing the linker
   trace when `dependency_output` is set;
5. require the staged `.mjs`, `.wasm`, and `.wasm.map` to be regular files
   (`staged browser image '<path>' is not a regular file`), read the staged
   Wasm, run `browserlink.image_inventory` (which shares
   `staticmetadata.browser_trace_image` and enforces the
   [byte bounds](#build-time-image-bounds), also rejecting imports named
   `dlopen`, `dlsym`, `dlerror` or `backtrace`, with or without a leading
   underscore: `browser image imports forbidden symbol "<name>"`), and rewrite
   the staged `.wasm.map` in place with
   `browsertrace.rewrite(image_bytes, map_bytes, identity, staged_map)` so
   that `x_titan_image`, `x_titan_function_imports`,
   `x_titan_function_ranges`, and `x_titan_function_names` are bound to the
   final linked `.wasm`;
6. run `before_commit` (which invalidates the link record);
7. validate that any existing destination in `{ <stem>.wasm.map, <stem>.wasm,
   <stem>.mjs }` is a regular file (`browser output '<path>' is not a regular
   file`) and reserve a sibling `.old` backup path for each before touching any
   predecessor; then in order `.wasm.map`, `.wasm`, `.mjs`, move any existing
   predecessor to its backup and rename the staged artifact into place, and run
   `after_publish` (`titanc` commits the link certificate there). The `.mjs`
   rename (followed by `after_publish` when present) is the commit point: if
   any backup rename, publication rename, or `after_publish` fails, rollback
   walks the outputs in reverse order (`.mjs`, `.wasm`, `.wasm.map`), removes
   published new files, and restores every backed-up predecessor (`cannot
   restore browser artifact: <reason>; predecessor retained at <backup>` when
   even restoration fails). An unextended `.wasm.map` is never visible at the
   published path. The backups are removed after the commit.

An image owns no DSO, debug bundle, or dSYM companion
(`validate_program_output_paths` reserves the `.wasm` and `.wasm.map` siblings
in `extra_outputs` and omits `.dSYM` on Darwin hosts for a browser context). A
warm link hit verifies all three files, and a missing or modified `.mjs`,
`.wasm`, or `.wasm.map` forces a relink while objects still hit. Final images
never read `.titan.meta`,
`.titan.source`, or `.titan.cprobe`; `wasm-ld` keeps the `.titan.source` and
`.titan.meta` payloads as named data segments and drops `.titan.cprobe`
([Baseline](#baseline)). Every image imports Lua's `env.exit`, which neither
the entrypoint nor completion uses.

### Build-time image bounds

`browserlink` enforces a maximum of **1,073,741,824 bytes per final `.wasm`**
and **7,654,321 bytes per defined function body**; equality is accepted.
These match the [WebAssembly JavaScript Interface
limits](https://webassembly.github.io/spec/js-api/index.html#limits), also
recorded in [JavaScriptCore's
limits](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/wasm/WasmLimits.h).
They are static rejection bounds, not a guarantee of successful allocation or
instantiation. Other engine limits and resource exhaustion still apply.

`check_image_size` compares the scalar string length before parsing.
`image_inventory` then uses `staticmetadata.browser_trace_image`'s existing
half-open body ranges, including the local-declaration vector and excluding
the preceding length LEB. It checks bodies in Wasm-index order and diagnoses
the first overlarge body. The index is the function-import count plus the
one-based defined index minus one; only function imports affect it. A sparse
name section supplies the name when available, otherwise the diagnostic names
the Wasm index. No body slices or instruction decoding are needed.

On body rejection only, the driver reads the staged source map and calls
`browsertrace.function_source` with that existing range. The same JSON,
source-map validation and VLQ walk used by publication finds the first mapped
instruction inside the body; it never borrows the previous function's
location. Same-offset unmapped replacements and the exclusive end boundary
are respected. Diagnostics include the literal `sources` entry, one-based line
and column, and a separate literal `sourceRoot` when present. They do not
infer a path from a symbol or invent a mapping for native or unnamed code.
Absent, empty, invalid or wholly unmapped source metadata produces an explicit
`source unavailable` reason while preserving the size diagnostic.

All program, generated-test and provider-protocol images share this check
before map rewriting, `before_commit`, protocol execution or three-file
publication. Guard rejection leaves predecessor bytes untouched; the failed
link certificate remains invalidated and the staged candidate is retired.
The existing compiler inventory hashes both guard and source-map Lua owners,
and its digest participates in the final-link recipe. Introducing or changing
the check invalidates older certificates without a version/schema bump.
Unchanged final-link hits return before linking or parsing an image again.

The original 168-line transfer recovery lambda is retained unsplit in the
portable regression. Validation-profile qualification with Emscripten 6.0.13,
Node 26.13.0 and sandboxed CfT 156.0.8078.80 produced these complete
fifteen-owner images and separate fresh-process, zero-case startup samples:

| Host | Wasm bytes | Original lambda body bytes | Node startup maxRSS KiB | Chromium sampled renderer RSS KiB | Chromium virtual-memory sample KiB |
| --- | ---: | ---: | ---: | ---: | --- |
| Linux x64 | 30,463,536 | 667,879 | 224,596 | 297,000 | VmData 1,056,252 |
| macOS arm64 | 30,275,426 | 667,706 | 243,664 | 290,912 | VSZ 2,002,559,040 |

The lambda has 4,869 declared locals plus four parameters on both hosts.
The complete image selected 759 cases per engine, passing 757 with two
existing locale-capability skips; the recovered regression selected and
passed seven. The zero-case runs measure initialization only, not functional
success. Node maxRSS is a process high-water mark, while Chromium RSS and
VmData/VSZ are renderer samples at a requested 10-ms interval; VmData and VSZ
are different virtual-memory measures, not resident RAM. Linear memory grew
from 16,777,216 to 20,185,088 bytes during combined-image initialization.
Default tiering and sandboxing were unchanged, with no memory feature or
forced optimizing-only compiler. These are individual measurements, not
maximum startup-memory guarantees.

## The browser entrypoint

`browserentry.contents(worker, options)` renders the shared C wrapper around a
`static int titan_browser_worker(lua_State *L)` that returns one Lua integer
status. `driver.browser_c_image_contents(worker, options)` exposes it to the
protocol probe and to test-owned C images; `options` adds `declarations`, the
report's `program_name` (default `titan`), and `state_status`, the status for
a state-allocation failure (default 1). The wrapper exports one function:

```c
int titan_browser_entry(int argc, const unsigned char *const *argv,
                        const size_t *lengths);
```

and imports two JavaScript functions from `titan-browser-library.js`:

```c
void titan_browser_complete(int kind, int status,
                            const unsigned char *bytes, size_t length);
int titan_browser_entry_allowed(void);
```

`argv` and `lengths` have `argc` elements, the arguments exclude the program
name, and a zero-length argument need not have a valid pointer. The return
value is admission only, never the program's result: `-1` while another call
is active or when `titan_browser_entry_allowed()` refuses ([Reentry
guard](#the-reentry-guard)), `-2` after the one permitted run, and `0` after an
admitted run. A refusal allocates nothing and transfers no coroutine context.

An admitted run:

1. creates the state with `luaL_newstate`, outside any protection; the fresh
   state's guaranteed `LUA_MINSTACK` (20) slots cover the three nonallocating
   setup pushes of `errorhandler`, the worker, and the argument block without
   a `lua_checkstack` call. A state-allocation failure completes with kind 1,
   the configured state status, and the static payload `not enough memory for
   state`;
2. calls the worker under `lua_pcall` with `errorhandler` as message handler,
   so the Lua libraries, the searcher, the preloads, every module
   initializer, and `main` run inside one protected boundary, and an ordinary
   failure anywhere returns there instead of panicking or aborting;
3. on success, takes the worker's integer result as the status: its low 32
   bits read as a signed 32-bit integer;
4. on failure, sets kind 1 and status 1 and reports under a second
   `lua_pcall` without a message handler, so that converting the error object
   cannot recapture or overwrite the original trace. The report converts the
   value like `lua.c` (string, `__tostring`, or `(error object is a <type>
   value)`), strips the synthetic bootstrap chunk prefix, roots a
   length-aware copy of the message, and writes `<progname>: <message>` and,
   when a trace exists, `stack traceback:` followed by each raw trace line
   after a newline and a tab, to stderr with `fwrite`, so embedded NUL bytes
   survive. A throwing `__tostring` or a failed report completes with
   `error while reporting browser failure` (also written to stderr), and a
   failed copy of the message with `not enough memory to copy browser error`;
   otherwise the message is copied to `malloc`ed storage that outlives the
   state;
5. closes the state, so finalizers and `__close` handlers still write output;
6. drains libc explicitly: `fflush(stdout)`, then `fflush(stderr)`, both
   always attempted. A run that had succeeded becomes kind 1, status 1 with
   `cannot flush browser stdout` or, when only stderr failed, `cannot flush
   browser stderr`; an already failed run keeps its first error;
7. calls `titan_browser_complete` exactly once, frees the copied message after
   that synchronous call returns, and clears the active flag.

Neither the wrapper nor its report ever calls `exit`. The pin, rethrow, and
bootstrap-hook semantics are the native ones; the native `main` template and
its `exit(EXIT_FAILURE)` paths are unchanged.

`driver.browser_entrypoint_contents(modname, program_name, options)` supplies
the program worker. It opens the Lua libraries, installs the Titan searcher,
and preloads the support module (`luaopen_titan` as `titan`) and the main
module, then requires the main module and retrieves `main`. It builds the
argument Array with the string-element writer and `lua_pushlstring` for each
argument, so arguments are byte strings and `args[1]` is the first. It then
calls `main(args)`, or `hook(main, args)` when a bootstrap hook is registered
under `TITAN_MAIN_BOOTSTRAP_KEY` and `--no-uv-bootstrap` was not given. Unlike
the native `pmain`, it publishes no `argc`/`argv` registry values, because no
browser `uv` module exists. `<progname>` is the last component of the main
module's name, or of the first test root's name for a test image.

## Runtime guards

The browser `libtitan.a` contains exactly `titan.o`, `minicoro.o`,
`titan_path.o`, and `ltitanlib.o`; no archive or image references `dlopen`,
`dlsym`, `dlerror`, or libbacktrace. Static images resolve modules through
provider symbol tables (`TitanModuleProvider.symbols`, the explicit-provider
discipline Windows also uses) and `package.preload`. Under
`TITAN_TARGET_BROWSER` the host-only paths compile out and raise a browser
error instead of calling a stub:

| Path | Browser behavior |
| --- | --- |
| `<dlfcn.h>` in `titan.c`, `ltitanlib.c`, `titan_path.c` | not included |
| `titan.c` `loadsym`, opaque-handle `titan_module_symbol`, `titan_check_abi` | `browser target symbol lookup requires an explicit provider symbol table` |
| `titan.c` `loadglobalsym` | `browser target cannot resolve global native symbol '<symbol>'; use the canonical module provider` |
| `ltitanlib.c` `_loadlib`, `_loadlibglobal`, lazy loading | `browser target does not support dynamic provider loading` |
| `titan_path.c` provider open and ABI-checked entry lookup | `browser target does not support dynamic provider loading` |
| `titan_path.c` executable discovery (`/proc/self/exe` and its OS branches) | fails with `browser target cannot locate a host executable` |
| `titan_path.c` compiler-root query (`titanc --print-root`) | fails with `browser target cannot query a host compiler` |
| `ltitanlib.c` `SIGPIPE` guard, its restore, and the POSIX-only support functions | compiled out |
| the libbacktrace and `execinfo` trace backends | replaced by the [browser trace backend](error-handling.md#trace-backends) |

`titan.h` selects `_setjmp`/`_longjmp` under `LUA_USE_POSIX`, as the linked
`liblua.a` does, and declares both for the Wasm build. The common header also
defines `TITAN_COROUTINE_STACK_SIZE` as `(2 * 1024 * 1024)` unless the target
defines it. Native builds change only by these guard lines.

## Source-map extensions, eager loader, and stack survey

### Source-map extensions and image identity

Before compiling the per-link synthetic entrypoint,
`browsertrace.identity(context, contents, compile_flags, link_flags, groups)`
computes a 64-character lowercase hexadecimal SHA-256 identity using
`incremental.digest` under domain `"browser-trace-image"`. The hashed recipe is
canonical and acyclic: the original entrypoint C source (`contents`, before
injecting the identity declaration), the browser target descriptor identity and
exported `tools` table, the effective entrypoint compile flags, the full
effective link flags (including user link extras and final dependency flags),
and ordered `{ path, digest }` groups (normalized via
`linkcertificate.canonical_path` and `incremental.file_digest`) for all user
objects, provider archives, `--c-source` extra objects, resolved `-L`/`-l`
static archives (`linkcertificate.browser_trace_libraries`), and the five
runtime/Lua/JS-library inputs (`libtitan.a`, `liblua.a`, `liblua-config.txt`,
`titan-browser-library.js`, and `titan-browser-trace.js`). An `emcc`-only
system or JavaScript library (such as `-lidbfs.js`) that the static archive
resolver cannot inventory still links: its flag text remains in `link_flags`
within `browsertrace.identity` while the CLI marks the native link policy
uncacheable and withholds the link record and reuse. No timestamps, random
staging paths, inodes, process IDs, or intermediate Wasm digests enter the
hash. `browsertrace.declaration(identity)` then appends:

```c
static const char titan_browser_trace_image_id[] = "<64 lowercase hex>";
const char *titan_browser_trace_identity(void) {
    return titan_browser_trace_image_id;
}
```

`_titan_browser_trace_identity` is exported in every Titan-entry profile and
accessed in `titan-browser-trace.js` with a static property lookup
`wasmExports['titan_browser_trace_identity']`; the pinned JSPI linker keeps
export names stable. Calling it returns the Wasm memory address of the
65-byte NUL-terminated ASCII string.

After `emcc` finishes linking and optimization,
`browsertrace.rewrite(wasm, bytes, identity, origin)` calls
`staticmetadata.browser_trace_image(wasm, origin)` (which reuses the bounded
section and LEB128 reader primitives in `staticmetadata.lua`, accepting valid
bounded padded LEB128 encodings as #328 specifies, and rejecting duplicate or
out-of-order sections, duplicate `name` sections/subsections, overrunning
lengths, invalid UTF-8, or mismatched function/code counts) and validates the
emitted standard version 3 `.wasm.map` (rejecting invalid JSON, wrong `version`
or core field types, unsupported indexed-map `sections`, pre-existing
`x_titan_*` keys, multi-line `;` `mappings` with segments after the first
generated line, malformed VLQ mappings, or out-of-range source/name indexes,
while accepting `sourcesContent: []` or a `#sources`-matched array of
strings/`null`). It splices the four extension keys directly before the root
JSON object's closing `}`, preserving all standard source-map fields, selected
physical `.titan` filenames, `sourceMappingURL` relation, and unknown
extensions:

```json
{
  "x_titan_image": "<64 lowercase hex SHA-256 input identity>",
  "x_titan_function_imports": 3,
  "x_titan_function_ranges": [[100, 120], [124, 165]],
  "x_titan_function_names": [null, null, null, "module_ℳ_f_titan", "module_ℳ_f_titanentry_lua"]
}
```

* `x_titan_image` is the 64-character lowercase hex digest that
  `titan_browser_trace_identity()` returns at run time.
* `x_titan_function_imports` is the exact count of imported functions (excluding
  memory, table, global, and tag imports).
* `x_titan_function_ranges` contains one `[start, end)` pair of zero-based
  absolute module byte offsets for each defined function in code-section order:
  `start` is the first byte after the function body's size LEB (including its
  local-declaration vector) and `end` is `start + body_size`. Row `j`
  (zero-based) describes module function index `imports + j`. Ranges are
  non-empty, strictly ordered, non-overlapping, and contained within the final
  code section.
* `x_titan_function_names` is a dense JSON array of length
  `imports + ranges.length`, indexed by zero-based module function index. Each
  element is the UTF-8 symbol string from final custom `name` section
  subsection 1, or `null` when absent. Source-map `names` are never used as a
  substitute for Wasm function names. The final `.wasm` retains its custom
  `name` section in this milestone for DevTools inspection; runtime
  symbolization reads `x_titan_function_names` so it works identically when the
  `name` section is stripped.

### Eager map loader and trace metadata

`titan-browser-trace.js` registers an `addOnPreRun` callback that adds the run
dependency `titan-trace-map` before user code can start. It resolves
`locateFile('{{{ WASM_BINARY_FILE }}}.map')` (`fetch(path, {credentials:
'same-origin'})` in browsers and `readBinary(path)` in Node), decodes the UTF-8
bytes with `TextDecoder('utf-8', {fatal: true})`, validates the standard v3
source map and `x_titan_*` extensions, verifies that `x_titan_image` equals
`UTF8ToString(wasmExports['titan_browser_trace_identity']())`, builds the
typed-array lookup index
([Browser trace backend](error-handling.md#browser-trace-backend)), publishes a
private result on `Module['titanBrowserTrace']`, and removes
`titan-trace-map`:

```text
{ state: 'ready' | 'degraded', reason: string | null,
  mapBytes: number, loadMilliseconds: number, indexBytes: number }
```

`mapBytes` is the UTF-8 byte length of the fetched `.wasm.map`,
`loadMilliseconds` measures the elapsed time (`performance.now()`) from
request/read start through validated index readiness, and `indexBytes` is the
sum of the six retained typed arrays' `byteLength`s (`pcs`, `sources`, `lines`,
`starts`, `ends`, and `first` — not total JavaScript heap usage; `0` when
degraded). When the map is missing, malformed, missing `x_titan_*` extensions,
or mismatched with the instantiated `.wasm`, `state` is `'degraded'`, `reason`
records the failure, and one `console.warn('Titan browser trace: ' + reason)`
is emitted at load time. Ordinary web pages still run in degraded mode;
`titan-browser-run` and `spec/browser/playwright-run.mjs` inspect
`Module['titanBrowserTrace']` through `observeFactory` after initialization and
fail the run as a harness error (`degraded browser trace: <reason>`) unless
`--allow-degraded-trace` was passed.

Observed trace cost for #330, when both installations still linked what is now
the validation profile, on the representative compiled trace-gate image
`out/browser/trace/assertions-2/runtime.mjs` (which then linked all 34 native
trace fixture cases under the D14 object profile `-O1 -fno-inline
-fno-optimize-sibling-calls -gline-tables-only` and the D18 Titan-entry link
profile `-O1 -fno-inline -fno-optimize-sibling-calls -gsource-map -g2
-sBINARYEN_EXTRA_PASSES=simplify-locals,reorder-locals`):

| Installation | Engine | `.wasm` bytes | `.wasm.map` bytes (`mapBytes`) | Map / Wasm | Eager map/index load (`loadMilliseconds`) | Retained typed-array index (`indexBytes`) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Validation | Node 24.19.0 | 5,126,536 | 1,227,298 | 23.94% (23.9401%) | 96.3 ms | 2,902,884 |
| Production | Node 24.19.0 | 5,127,276 | 1,227,298 | 23.94% (23.9366%) | 95.2 ms | 2,902,884 |
| Validation | Host Chromium 156.0.8078.79 | 5,126,536 | 1,227,298 | 23.94% (23.9401%) | 61.1 ms | 2,902,884 |
| Production | Host Chromium 156.0.8078.79 | 5,127,276 | 1,227,298 | 23.94% (23.9366%) | 73.2 ms | 2,902,884 |
| Validation | Playwright Chromium 141.0.7390.37 | 5,126,536 | 1,227,298 | 23.94% (23.9401%) | 72.5 ms | 2,902,884 |
| Production | Playwright Chromium 141.0.7390.37 | 5,127,276 | 1,227,298 | 23.94% (23.9366%) | 102.4 ms | 2,902,884 |
| Validation | Playwright Firefox 142.0.1 | 5,126,536 | 1,227,298 | 23.94% (23.9401%) | 62.0 ms | 2,902,884 |
| Production | Playwright Firefox 142.0.1 | 5,127,276 | 1,227,298 | 23.94% (23.9366%) | 113.0 ms | 2,902,884 |
| Validation | Playwright WebKit 26.0 | 5,126,536 | 1,227,298 | 23.94% (23.9401%) | 69.0 ms | 2,902,884 |
| Production | Playwright WebKit 26.0 | 5,127,276 | 1,227,298 | 23.94% (23.9366%) | 63.0 ms | 2,902,884 |

Each `loadMilliseconds` entry is one observed eager-load sample from the
passing 72-row / 70-native-case gate run (spanning map read or loopback HTTP
`fetch`, UTF-8 decoding, JSON parsing, `x_titan_image` verification, and
typed-array index construction — not total image startup, a multi-run average,
or a cold-network benchmark). `indexBytes` sums the six retained typed arrays
only (`pcs`, `sources`, `lines`, `starts`, `ends`, and `first`); it excludes
the retained `names` and `bases` JavaScript string arrays and temporary parsing
allocations, so it is not total retained or peak JavaScript heap usage.

Since #343 the production installation links a different image: its current
trace-gate test image is 3,231,911 bytes with a 904,919-byte map, against
5,261,947 and 1,279,867 for validation ([Measurements](#measurements)). Its
eager-load cost has not been measured again.

### WebAssembly stack survey

Before finalizing the stack parser and WebKit renderer, a synthetic C/JS survey
(324 raw stack captures across nine call topologies, named and `name`-stripped
binaries, and default versus raised `Error.stackTraceLimit`) was recorded with
Emscripten 6.0.13 and `-O1 -fno-inline -fno-optimize-sibling-calls -gsource-map
-g2` (the validation frame flags), with the historical JavaScript-SJLJ
Asyncify profile across six engines:

| Engine | Version | Platform |
| --- | --- | --- |
| Node / V8 | Node 24.19.0 (V8 13.6.233.17-node.51) | Linux x64 (bundled in emsdk 6.0.13) |
| Playwright Chromium | 141.0.7390.37 | Linux x64 (`mcr.microsoft.com/playwright:v1.56.1-noble`) |
| Playwright Firefox | 142.0.1 | Linux x64 (`mcr.microsoft.com/playwright:v1.56.1-noble`) |
| Playwright WebKit | 26.0 | Linux x64 (`mcr.microsoft.com/playwright:v1.56.1-noble`) |
| Host Chrome / V8 | 156.0.8078.79 (V8 15.6.75.27) | Linux x64 |
| Safari / JSC | 27.0.1 (macOS 27.0.1, build 26A434) | macOS arm64 (Apple M1) |

The survey recorded the following behavior on those versions and binaries.
Its historical depth and descriptor observations are not universal engine
rules; the current [capture contract](error-handling.md) follows the JSPI
runtime and its current-engine tests.

1. **V8 (Node, Chromium, host Chrome)** formats frames as
   `    at <module>.<func> (<url>:wasm-function[<N>]:0x<PC>)` when the `name`
   section is present and `    at <url>:wasm-function[<N>]:0x<PC>` when
   stripped (`wasm://wasm/...` in Node, `http://...` in Chromium/Chrome),
   preceded by an `Error: ...` title line. Both carry the decimal function
   index `N` and the module-relative hexadecimal byte offset `0xPC`.
2. **SpiderMonkey (Firefox)** formats frames as
   `<name>@<url>:wasm-function[<N>]:0x<PC>` (with an empty `<name>` when
   stripped) and no `Error` title line. After an outer or fiber
   `emscripten_sleep`, the surveyed Firefox appended saved asynchronous
   ancestry starting at a frame line prefixed with `async*` (such as
   `async*handleSleep@...`), repeating earlier suspended Wasm activations
   (`fiber_entry`, `survey_run`). Current JSPI captures also expose
   `VoidFunction*`, `promise callback*`, and `setTimeout handler*` causes.
   The parser stops before any saved-JavaScript-parent cause boundary, rather
   than merely skipping JS-shaped lines and retaining their saved Wasm callers.
3. **JavaScriptCore (Playwright WebKit and Safari)** formats named frames as
   `<func>@<image>.wasm:wasm-function[<N>]` and stripped or cold frames as
   `<N>@wasm-function[<N>]`, with no `Error` title line and no bytecode offset
   `0xPC` in any tested configuration. Cold named runs in Playwright WebKit
   also mix numeric-only and named forms within a single stack. Both forms
   always carry the bracketed decimal function index `[<N>]`, which resolves
   through `x_titan_function_names` and `TITAN_NAMES_KEY` to the Titan display
   name and declaring `.titan` basename for no-line rendering.
4. **Active-chain order and fibers.** Across all six engines, the active Wasm
   call chain is ordered youngest-first without reordering or duplication
   across `setjmp`/`longjmp` (`invoke_*`/`dynCall_*` JS wrappers interleave
   between Wasm runs), outer `emscripten_sleep` rewinds, and tagged minicoro
   fibers before yield, after resume, and after sleep inside a fiber. Inside a
   fiber, the physical stack ends at `fiber_entry`, `_mco_main`,
   `_mco_wrap_main`, and `dynCall_vi`; the resumer's native frames are absent
   and are supplied by `TITAN_TRACE_APPEND_KEY`.
5. **Observed depth limits (`Object.defineProperty` versus assignment).** In
   the surveyed versions, default `Error.stackTraceLimit` was 10 on V8
   (leaving 9 Wasm frames), 100 on JSC, and absent on Firefox. Raising the
   property through `Object.defineProperty` raised V8's capture depth as
   requested (615 frames for a 600-edge recursion at limit 1000). On the
   surveyed JSC builds it changed the visible property but not the hidden
   100-frame limit, while direct assignment updated that hidden state.
   Deleting the property made `.stack` return `undefined` even after descriptor
   restoration. These observations motivated the original JSC 100-frame
   inference and isolated-realm test. Current WebKit 27.2 honors the temporary
   descriptor and captures normally after the property was absent; neither
   historical workaround remains. Firefox's surveyed 128-frame synchronous
   ceiling is still observed in current JSPI captures and still marks
   truncation.
6. **JS wrapper headroom.** In the 48-recursion survey cases, up to 12 non-Wasm
   frames interleaved with 54 Wasm frames on V8. Requesting 640 frames (512
   Wasm capacity + 128 headroom) covers normal wrapper overhead, and the
   adapter conservatively marks any capture that reaches the effective limit as
   truncated.

## Budgets

Linear stack and heap sizes are explicit image/SDK identity inputs:

| Resource | Setting | Ownership |
| --- | --- | --- |
| Main linear C stack | `-sSTACK_SIZE=1048576` | the root entry's address-taken locals and Lua/Titan protected-call data |
| Coroutine linear C stack | `-DTITAN_COROUTINE_STACK_SIZE=262144` | one disjoint minicoro allocation; native default remains 2 MiB |
| Linear memory | `-sINITIAL_MEMORY=16777216 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2147483648` | freed blocks can be reused but the grown Wasm heap never shrinks |
| Engine continuation stacks | JSPI engine-managed | not bounded by the linear C-stack sizes |

`STACK_OVERFLOW_CHECK=2` stays enabled. Each switch saves SP and the current
stack base/end, restores the destination limits and SP before its Wasm
continuation executes, and checks its stack cookie. New stacks receive
their own cookies; memory views are never retained across memory growth.

`browser_budgets_spec.lua` measures checked root/coroutine C-stack limits,
engine-stack limits with live Wasm-register canaries across JSPI waits and
transfers, the catchable Lua C-call limit, forced native allocation failure,
and the delivered 2-GiB heap boundary. The parked canary must remain usable
before exhausted owners are released, and fresh coroutines must work after
collection. Native allocation failures can be ordinary errors; an engine
trap or JS allocation failure poisons the instance instead of pretending
that native cleanup or continuation reuse is safe.


## The browser C-call limit

The fork's browser target compiles Lua with `-DLUAI_MAXCCALLS=100`
(`BROWSER_SYSCFLAGS` in the fork's `src/Makefile`); the native, macOS, and
Windows targets read their own `SYSCFLAGS` and keep Lua's default 200. The
user contract is in [Lua's C-call
limit](../language/browser-target.md#luas-c-call-limit).

### What the limit counts

`LUAI_MAXCCALLS` bounds `getCcalls(L)`, the low 16 bits of `L->nCcalls`
(`lstate.h`). Each recursive C construct adds one per level:

* `ccall`, behind `luaD_call` and `luaD_callnoyield`: `pcall`, metamethod
  calls, `string.gsub` and `table.sort` callbacks, `__tostring`, and every
  call from compiled Titan into a Lua function. A Lua function calling a
  compiled Titan function enters it through `luaD_precall` without a count, so
  one interleaved Lua/Titan level costs one count.
* `lua_resume`, which starts a coroutine from its resumer's count (`L->nCcalls
  = getCcalls(from)`), refuses a resume at the limit with `C stack overflow`,
  and then adds one.
* The parser's `enterlevel`, through `luaE_incCstack`.

Exactly at the limit `luaE_checkcstack` raises `C stack overflow`; up to
`LUAI_MAXCCALLS / 10 * 11` it lets the overflow's error handling run, and
beyond that it raises the error-in-error-handling status.
`luaD_checkminstack` reports no room within two counts of the limit; the
collector then postpones pending `__gc` finalizers, and nothing is raised.
Titan's `errorhandler`, which `luaG_errormsg` calls through
`luaD_callnoyield`, takes one count, and closing the trace builder's spilled
`luaL_Buffer` box (`luaL_pushresult` → `lua_closeslot` → `callclosemethod` →
`luaD_callnoyield`) can take another. An error raised two counts below the
limit is therefore replaced by `C stack overflow` while its trace is built: a
mixed recursion that raises at its leaf, starting from the test runner's count
of 2, passes 195 levels and reports `C stack overflow` at 196 when the limit
is 200 (`LUAI_MAXCCALLS - 5` levels).

### How Titan carries the value

The fork's installer derives the record's `lua_defines` from the browser
build's own `-D` flags, sorted and unique, so the record reads
`lua_defines=-DLUAI_MAXCCALLS=100 -DLUA_USE_BROWSER -DLUA_USE_POSIX` under the
unchanged `# Lua 5.5.1 browser build record v1` banner and closed key set.
Titan verifies it like any other define: `lua_defines` must equal the `-D`
tokens of `cflags` ([verification order](#verification-order), step 7), and
the archive digest must match. `browsertarget.build` appends the record's
defines to the descriptor's compile prefix, and the validator requires each of
them there, so generated C, `--c-source` objects, C probes, and FFI
preprocessing compile against the same limit as `liblua.a` (`titanc -v` shows
the define on every browser compile). Titan does not hard-code the value: the
fork commit that the `lua-5.5.1` gitlink names, recorded as `fork_revision`,
does, and `make lua-browser` rebuilds an installation whose record names
another commit.

### Choosing 100

The measurements in this subsection and [Engine stack per
construct](#engine-stack-per-construct) used the previous JavaScript-SJLJ
lowering. They record why 100 was chosen, not the current Wasm-EH engine
ceilings; 100 is retained until the recursive Lua/C shapes are requalified
across engines and build profiles.

The value had to be greater than 10 (otherwise `LUAI_MAXCCALLS / 10 * 11` is 0
and every overflow escalates to error-in-error-handling), at least 20 in
practice so overflow handling and the two reserved finalizer slots stay
usable, within 16 bits, and at most half the lowest engine ceiling measured in
counts on any engine and either profile (both profiles were measured on all
four engines; see [Measurements](#measurements) and the table below): the
margin rule #330 used for its headroom row. Each construct costs exactly one
count per level wherever it was
measured (mixed recursion on all four engines in both assertion modes, every
construct on Node, and `pcall`, `coroutine.resume`, and mixed recursion in both
profiles), so levels and counts differ only by the starting count (2 in the
mixed fixture, 3 in the construct probe).

The lowest historical ceiling was 204 counts (201 levels): nested `pcall` and
nested `coroutine.resume` on V8 (Node and Chromium), validation, assertions 2.
Half of it is 102, and the maintainer chose 100 (D33). Against that measured
ceiling, a limit of 100 gave a 2.04× margin, or 2.08× against the 98 counts at
which the mixed fixture tripped. At
Lua's default 200, the same `pcall` chain tripped at 195 levels (198 counts),
a 1.03× margin, and mixed recursion passed 195 levels and tripped at 196 on
all four engines in both assertion modes, as a catchable error.

Historical JavaScript-SJLJ validation ceilings with Lua's limit out of the way
(deepest passing level; `-DLUAI_MAXCCALLS=60000`):

| Engine | Assertions | Mixed Lua/Titan | Nested `pcall` | Nested `coroutine.resume` |
| --- | ---: | ---: | ---: | ---: |
| Node 24.19.0 | 2 | 318 | 201 | 201 |
| Node 24.19.0 | 0 | 319 | 204 | 204 |
| Chromium 156.0.8078.79 | 2 | 320 | 201 | 201 |
| Chromium 156.0.8078.79 | 0 | 321 | — | — |
| Firefox 142.0.1 | 2 | 572 | 385 | 393 |
| Firefox 142.0.1 | 0 | 574 | — | — |
| WebKit 26.0 | 2 | 479 (contiguous; 480 fails, 1,024 passed once) | 639 | 831 |
| WebKit 26.0 | 0 | 1,074 | — | — |

V8 fails with `RangeError: Maximum call stack size exceeded`, Firefox with
`InternalError: too much recursion`, and WebKit with `RangeError`. On Firefox
the mixed fixture fails its own assertions first: at 573 and 574 levels at
assertions 2 and at 575 and 576 at assertions 0, each recorded only as a
failed case, before the engine's `InternalError` at 576 (assertions 2) and 640
(assertions 0). The production ceilings, higher
on every engine, are in [Measurements](#measurements).

### Engine stack per construct

Node, validation, assertions 2. The slope between the default stack (984 KB)
and `--stack-size=256` gives the bytes per level, which is also the bytes per
count; for mixed recursion it comes from the 256 KB and 512 KB points:

| Construct | Ceiling at 984 KB | Ceiling at 256 KB | Bytes per count |
| --- | ---: | ---: | ---: |
| Parser: nested parenthesized expressions | 1,784 | 433 | 552 |
| Parser: nested table constructors | 254 | 254 | — (a parser limit binds first: depth 255 is a syntax error) |
| Parser: nested function bodies | 431 | 104 | 2,280 |
| Nested `pcall` | 201 | 49 | 4,904 |
| `__index` function chain | 405 | 98 | 2,428 |
| `string.gsub` with a recursing replacement | 331 | 80 | 2,970 |
| Nested `coroutine.resume` | 201 | 49 | 4,904 |
| `table.sort` with a recursing comparator | 295 | 71 | 3,328 |
| `tostring` with a recursing `__tostring` | 328 | 79 | 2,994 |
| Mixed Lua/Titan recursion | 318 | 63 | 2,913 |

For mixed recursion the 256 KB, 512 KB, and 984 KB points pass 63, 153, and 318
levels: 2,913 bytes per level below 512 KB and 2,929 above it, with an
intercept of about 78.6 KB.

**Why a protected call costs more.** One mixed level, captured from
JavaScript at depth 1 (youngest first), is `luaD_callnoyield`,
`luaV_execute`, `luaD_precall`, the Titan entry wrapper
(`..._titanentry_lua`), two Titan closures around `mixed_recurse`, and
`dynCall_viii` in WebAssembly, then `__asyncify_wrapper_2521`, `outer`, the
Asyncify instrumentation at `runtime.mjs:541`, `invoke_viii`, and the import
thunk in JavaScript. One `pcall` level, captured at depth 6, is `luaD_pcall`,
`lua_pcallk`, `luaB_pcall`, `luaD_pretailcall`, `luaV_execute`,
`luaD_callnoyield`, `f_call`, `dynCall_vii`, `__asyncify_wrapper_2538`,
`outer`, `runtime.mjs:541`, `invoke_vii`, the import thunk, and
`luaD_rawrunprotected`. Both levels leave WebAssembly through an `invoke_*`
import and re-enter it through `dynCall_*` under Asyncify's wrapper; for
`pcall` and `coroutine.resume` that trampoline is Emscripten's SjLj lowering
of the protected call in `luaD_rawrunprotected`, which runs Lua's `setjmp`.
The two levels differ in their WebAssembly frames, and the protected-call
level's frames cost 4,904 − 2,913 ≈ 2 KB more per count. The trampoline's
JavaScript half was a consequence of that historical SJLJ lowering. Wasm EH
removes it without using the unsound `ASYNCIFY_IGNORE_INDIRECT` shortcut.

Two validation levers were measured and not adopted: adding `--coalesce-locals`
after `--asyncify` raised the Node mixed ceiling from 318 to 334, removing
`luaD_callnoyield` from Asyncify (`-sASYNCIFY_REMOVE`) to 324, and both to 339
(+6.6%), at no extra link time; `--simplify-locals-nonesting` and
`--merge-locals` changed nothing. These levers were measured only in
validation. The only post-Asyncify measurement in production removed D18's
pair: without it the `-O3` mixed ceiling stays at or above 1,200 levels, the
`.wasm` is 14 KB smaller, the map 33 KB larger, and the maximum 102 locals
instead of 100 (D34; see the [historical instrumentation
measurements](#historical-instrumentation-measurements)).

### The regression

`spec/fixtures/browser_trace/trace_cases/limits.titan` holds three rows:

* `test_mixed_recursion_headroom` recurses 90 mixed levels, below the 95
  (`LUAI_MAXCCALLS - 5`) that this fixture's accounting leaves room for, and
  must keep at most 91 `mixed_recurse` frames with at most one truncation
  marker.
* `test_mixed_recursion_overflow` and `test_pcall_recursion_overflow` recurse
  toward a bound of 150, above Lua's limit and below the historical engine ceilings,
  through `@trace-shape.lua` and through `@trace-pcall.lua`, a Lua chain whose
  only C boundary is `pcall`, so it costs one count per level (it passed 96
  levels and tripped at 97 on the historical Node fixture). Each must catch
  exactly `C stack overflow`
  with a real capture and return normally. A missing limit reaches the base
  case's `expected C stack overflow` and fails the assertion instead of
  crashing the engine, which a `-DLUAI_MAXCCALLS=60000` install confirmed.

All three passed on Node, Chromium, Firefox, and WebKit, at assertions 2 and 0,
under both profiles before the Wasm-EH cutover. The loader still reports a real
engine failure with its `cause` ([Settlement](#the-loader)); the C-call limit only keeps Lua's
recursion from reaching one.

### JSPI and protected calls

Wasm-EH longjmp keeps protected-call frames inside Wasm while a JSPI import
suspends. It does not catch engine traps or change the conservative
`LUAI_MAXCCALLS=100` browser policy.

## Completion and output channels

`titan-browser-library.js` owns one private `$TitanBrowser` per generated
factory. An initialization callback attaches it through
`Module.titanBrowserAttach`; `titanBrowserSafePoint`, `titanBrowserTrap`,
and `titanBrowserComplete` are the other internal owner callbacks.

**Completion.** `titan_browser_complete` copies `(kind, status, bytes, count)`
through `HEAPU8.slice` while C owns the source bytes. This record alone owns
application status and payload. The promised export's fulfillment proves
engine retirement, not Titan success: the loader waits for both and never
substitutes a promise value, `onExit`, or Emscripten keepalive state.

**Output.** Per-byte stdout/stderr hooks only buffer bytes, ignoring null
flush notifications. Stdin returns null. No user sink or unrelated
notification runs during an internal coroutine transfer, including a
collector finalizer's cleanup. `safe()` means that the whole logical entry
has released its owner; buffered streams are delivered only then.

### JSPI coroutine contexts

The Emscripten branch in `minicoro.h` retains minicoro's SELF/BACK routing,
tag comparator, stacked-handler state transitions, transfer storage and
native unwind protocol. A context owns one disjoint linear C stack and a
JS record keyed by its allocation address. The record holds saved SP,
base/end bounds, one lifetime promise, a parked gate and its BACK identity.
Promises do not replace Lua's transfer-uservalue roots.

`titan_mco_transfer` and `titan_mco_destroy` are explicit suspending imports.
First activation invokes the promised `titan_mco_entry`; subsequent
activation resolves the existing gate. Both sides suspend, preserving the
C-visible rule that `mco_resume` returns only when its selected target yields
or finishes. Tagged yield activates the selected handler's BACK directly;
intermediate stacked contexts remain parked. Before every continuation runs,
the driver restores its linear SP and Emscripten stack-limit globals and
checks its cookie. Engine stacks are separate from those linear allocations.

A terminal transfer records its destination without parking the dead stack
or waking its resumer. `_mco_main` returns out of the engine invocation
first; only its lifetime fulfillment activates that destination. Thus a
resumer can immediately destroy a dead coroutine without freeing storage
that an engine activation still touches. Never-started destruction just
removes its record. Raw minicoro destruction of a live parked context rejects
its gate with a private retirement exception and awaits its engine lifetime
before returning to the C allocator. Only then is the C context pointer
cleared. A failed initialization has no context to retire, and repeated
uninitialization or destroy-after-uninit cannot retire one twice.
Titan abandoned-stack cleanup does not use that shortcut: its existing
floor/TRANSFER_UNWIND protocol runs defers, Lua close handlers and error
retirement to terminal completion first.

### The reentry guard

`TitanBrowser.enter(call)` is the direct internal logical-entry hook. It
acquires admission before invoking a promised Wasm export and keeps it
through all internal microtasks, collector cleanup and terminal handoffs.
Concurrent entry rejects with `TITAN_BROWSER_REENTRY`, `browser instance is
active; reentry is not allowed`. Blocked, failed or completed instances
refuse new admission. `titan_browser_entry_allowed` consumes the one initial
C admission; JSPI continuation wakes do not re-enter that C preamble.

Initialization wraps the general Module exports `titan_browser_entry` and
the gate's `titan_browser_gate_guarded` with this hook. Static
`wasmExports[...]` accesses retain the explicit identity. Emscripten 6.0.13
disables import/export minification for JSPI, including O2/shrink controls;
the optimized guard fixture asserts that pinned naming contract. The driver's
lexical engine-entry export remains private; its published Module alias
always rejects outside use. C-only state-neutral exports such as malloc,
free, trace identity and the gate observer remain synchronous.

`poison(cause)` permanently blocks admission and rejects known parked engine
gates after a fatal error. It never calls C to free or reuse compromised
allocations. An external import can remain unresolved after abort; disposal
drops the unusable instance instead of claiming normal cleanup.

## The loader

`titan-browser.mjs` exports `create(factory, {stdout, stderr, locateFile} =
{})`, where `factory` is the default export of a generated `.mjs`. It has no
Node-specific imports and works in both engines. The returned object is
frozen and has exactly `initialize`, `run`, and `dispose`; it exposes no
Module, memory, or general call bridge. `create` throws `TypeError` for a
non-function factory or sink. The channels own the caller's sinks; the
instance keeps no other reference to them.

* **`initialize()`** calls the factory once with the per-byte hooks, `stdin`,
  `onAbort`, the internal callbacks, and `locateFile` when given, and returns
  the same Promise on every call. It runs no Titan code. A factory result
  without the attached library, a `ccall` function, or a `HEAPU8` view fails
  with `browser image does not provide Titan channels`. A factory that
  settles after disposal is dropped and never re-rooted.
* **`run(args = [])`** rejects with `TITAN_BROWSER_STATE` after disposal,
  with `TITAN_BROWSER_REENTRY` while a run is active, and with
  `TITAN_BROWSER_STATE` after the one admitted run or after any terminal
  failure, including a failed initialization. Otherwise it reserves the
  admission synchronously, before awaiting initialization. It encodes string
  arguments as UTF-8 and copies `Uint8Array` arguments, `malloc`s each one,
  rereading `HEAPU8` after every allocation, then writes the pointer and
  length arrays (little-endian 32-bit) through a `DataView` built after the
  last allocation. It calls `ccall('titan_browser_entry', 'number',
  ['number', 'number', 'number'], [argc, argv, lengths], {async: true})` with
  numeric arguments only, because `ccall`'s stack-based string and array
  conversion cannot own byte arguments across a suspension or a large
  allocation.
* **`dispose()`** is idempotent. It closes admission synchronously, even
  while initialization or a run is pending, waits for an intact active run to
  become quiet (disposal is not cancellation), frees the argument storage, and
  drops the Module, buffers, and callbacks. After a trap or abort it drops the
  unusable Module without calling `free` or waiting for an internal `ccall`
  Promise that may never settle, while still observing that Promise's
  rejection.

**Settlement.** The run Promise settles in one place. A normal run settles
only after the copied completion, fulfillment of the promised native entry,
a safe point and freeing of argument storage; it resolves to `{kind: "returned" | "failed",
status, bytes}`. A sink failure, protocol failure, trap, or abort rejects
instead, and the first failure wins:

* `browser entry completed more than once` and `browser entry reported invalid
  completion kind <kind>` (`TITAN_BROWSER_PROTOCOL`) for a second or malformed
  completion, while an intact admitted run still finishes its cleanup;
* `browser entry returned without completion`
  (`TITAN_BROWSER_PROTOCOL`) when the promised entry has fulfilled
  (`callFulfilled`) and no completion arrived — checking `callFulfilled`
  ensures that an earlier queued safe point never masks a synchronous throw or
  rejected `ccall`, such as an engine `RangeError: Maximum call stack size
  exceeded`, which instead rejects with the engine error preserved as `cause`
  (`spec/browser/runner.test.mjs` injects one; recursion through Lua's C API
  stops at the [browser C-call limit](#the-browser-c-call-limit) first);
* `cannot buffer browser <stream>` (`TITAN_BROWSER_PROTOCOL`) when an output
  buffer cannot grow;
* `TITAN_BROWSER_TRAP` when an original trap was recorded, or a
  `WebAssembly.RuntimeError` arrives without abort evidence;
  `TITAN_BROWSER_ABORT` when `onAbort` was observed; the message is the
  original reason and the original error is the `cause`.

A trap is remembered ahead of a later abort that wraps it. An `onAbort` or a
malformed completion that arrives after settlement throws the typed error, so
a monitor such as the runner can observe late engine failures. A rejected
`ccall` Promise is always consumed.

**Sinks.** At each safe point the loader delivers each stream's buffered
bytes as a fresh owned `Uint8Array`, in per-stream order, including an
unterminated tail. A sink that throws rejects with `browser <stream> sink
failed` and the original error as `cause`; one that returns anything other
than `undefined` rejects with `browser <stream> sink must return undefined`,
after attaching a handler so that a returned Promise's rejection is observed.
Both carry `code` `TITAN_BROWSER_SINK` and `stream`. The failed sink is never
called again, new admission is refused, and an intact admitted continuation
still resumes and finishes its Lua cleanup; the loader never re-enters broken
WebAssembly for cleanup.

**Lifecycle.** new → initializing → ready → running (possibly suspended) →
completed or failed → disposed. Independent instances may run concurrently in
one realm, including two that are suspended at once; one may fail or be
disposed while the other completes.

## The runner

`titan-browser-run` is a POSIX shell launcher. It resolves Node before loading
any SDK JavaScript: `TITAN_NODE` names one executable (a bare name is looked
up on `PATH`), otherwise `node` on `PATH`; it resolves the directory
physically and requires a major version of at least 26. Failures exit 75
with empty stdout:

```text
titan-browser-run: Node 26 or newer is required (node not found (TITAN_NODE unset; not on PATH))
titan-browser-run: Node 26 or newer is required (node not executable at "<path>")
titan-browser-run: Node 26 or newer is required ("<path>" reports <found>; expected Node 26 or newer)
```

where `<found>` is `unknown` without a parsable version. It then locates
`titan-browser-run.mjs` beside itself, never relative to the working directory
(`titan-browser-run: harness failure: runner assets are missing`), and execs
it.

`titan-browser-run.mjs` parses `[--engine node|chromium] [--timeout MS]
[--grace MS] [--chrome PATH] [--cdp pipe|port] [--root DIR]
[--allow-degraded-trace] [--js-test] FILE [-- ARG...]`. Defaults are Node, the
CDP pipe, 30000 ms, and 1500 ms; the
timeout is a positive and the grace a nonnegative safe integer. Misuse prints
`titan-browser-run: <detail>` and the usage to stderr and exits 2; `--help`
prints the usage and `--version` prints `titan-browser-run: Titan 0.6.0
browser runner (Node 26+)`, both to stderr with exit 0. `FILE` must be a
regular `.mjs` file beneath the root, which defaults to its directory. Stdout
carries only program bytes; every runner diagnostic goes to stderr. The module
exports `within(root, path)` and `Monitor` and guards its top-level `main()`
with a `realpath(process.argv[1])` check so that importing it from tests or
`spec/browser/playwright-run.mjs` does not run the CLI while direct invocation
(including through a symlink) works normally.

**Probe.** `--probe` (with an optional `--chrome`) needs no file, SDK, or
browser launch. It prints exactly one LF-terminated JSON object:

```text
{"node":{"path":"<absolute>","version":"v26.x.y","ok":true,"reason":null},
 "chrome":{"path":"<absolute-or-null>","version":"<string-or-null>",
           "ok":<boolean>,"reason":"<string-or-null>"}}
```

Chrome selection is `--chrome`, then `TITAN_CHROME`, then `google-chrome`,
`google-chrome-stable`, `chromium`, `chromium-browser`, and
`chrome-headless-shell` on `PATH`. Chrome is usable when `--version` runs and
prints a recognized Google Chrome (for Testing), Chromium, or Chrome Headless
Shell banner with a four-part version; no fixed major is required. A failure
keeps the path and version found, with a reason such as `headless Chromium not
found; set TITAN_CHROME to a Chrome executable` or `unrecognized
Chrome/Chromium version banner`. A spawn or I/O failure is a harness failure,
never a fabricated capability record. The compiler's `driver.browser_node_ready`
and the specs' toolchain helper both use this probe rather than a second Node
or Chrome resolver.

**Node engine.** The supervisor spawns a separate qualifying Node worker
(`titan-browser-node-worker.mjs`, run with `--expose-gc`) in its own process
group, with stdout and stderr pipes and a private IPC channel. The worker
imports the image and the installed loader, writes the program's bytes to its
pipes, and reports completion and failures only over IPC, never on stdout.
The supervisor owns the wall-clock deadline and the grace period, so a busy
WebAssembly loop cannot prevent a timeout; it never infers success from the
worker's exit, and a worker that exits or disconnects before shutdown is a
harness failure. Output pipes are drained before the runner returns.

**Chromium engine.** The supervisor serves the root under `/root/` and the
read-only SDK directory under `/sdk/` on `127.0.0.1` with an ephemeral port,
correct `.mjs` and `.wasm` types, no caching, and no path traversal or symlink
escape (only `GET` and `HEAD`). It launches the real executable in its own
process group with `--headless=new`, `--disable-gpu`,
`--disable-dev-shm-usage` (keeping shared-memory backing files off
size-limited `/dev/shm` mounts), `--no-first-run`,
`--no-default-browser-check`, the three background-throttling switches, and a
unique `--user-data-dir`, and with real-time timers. The default transport is
`--remote-debugging-pipe` with NUL-delimited CDP JSON written to the child's
fd 3 and read from fd 4; `--cdp port` uses `--remote-debugging-address=127.0.0.1
--remote-debugging-port=0`, reads the endpoint from the profile's
`DevToolsActivePort`, and connects with Node's built-in `WebSocket`. Both use
the same CDP commands; there is no npm dependency and no hidden fallback. The
page reports through a `Runtime.addBinding` binding as base64-encoded JSON, so
program bytes cross byte for byte and console text is never parsed. GC
requests from host tests use `HeapProfiler.collectGarbage`. The runner logs
`Chromium <version>; executable "<path>"; CDP <pipe|port>; pid <pid>; profile
"<path>"` and, after cleanup, `cleanup: profile "<path>" removed`. On an early
Chromium exit or other Chromium harness failure (`Chromium exited before
shutdown`, `CDP pipe closed before shutdown`, `CDP WebSocket closed before
shutdown`), `close()` closes control fds 3 and 4 first and waits up to 1000 ms
for the child's stdio streams to close so that pipe EOF cannot hide the exit
status or final stderr bytes, and `reportFailure()` then logs `Chromium child
status: exit code=<code|null>, signal=<signal|null>` and `Chromium stderr
tail:` followed by the last 8 KiB of trimmed stderr (or `(empty)`). The
sandbox stays on; `TITAN_BROWSER_ROOT_NO_SANDBOX=1` adds `--no-sandbox` only
when the runner runs as root, for root containers such as local `act` runs.

**Status mapping.** A monitor classifies the run:

| Event | Exit | Diagnostic |
| --- | ---: | --- |
| Titan completion | `status & 255` | none (a host test's failure prints `JS test failed: <reason>`) |
| Abort before completion | 70 | `abort: <reason>` |
| Trap before completion | 71 | `trap: <reason>` |
| Wall-clock deadline | 72 | `timed out after <ms> ms` |
| Trap or abort during grace | 73 | `late engine failure: <reason> (<category>)` |
| Unhandled rejection, before completion or during grace | 74 | `unhandled rejection: <reason>` |
| Harness, protocol, or launch failure | 75 | `harness failure: <reason>` |
| Contained sink failure | 76 | `sink failure: <reason>` |

Every diagnostic starts with `titan-browser-run: `. The loader keeps the full
signed status; only the CLI masks it. Grace starts at the actual completion
control, which the page sends after the run settled and the instance was
disposed, never at console output, and a later trap or abort overrides the
completed result. Classification follows the evidence chain: a tagged original
trap (`TITAN_BROWSER_TRAP` anywhere in the `cause` chain) is a trap even when
an abort follows it; an observed `onAbort` otherwise makes the run an abort,
including Emscripten's subsequent `RuntimeError`; and a bare `RuntimeError`
without abort evidence is a trap. Malformed, duplicate, or unknown controls,
a premature engine exit, a crashed page target, a missing or invalid image,
and an interrupted runner (`SIGINT`, `SIGTERM`) are harness failures. Timers
longer than Node's 32-bit limit are armed in bounded slices against a
monotonic deadline.

**Factory observation, trace readiness, and terminal cleanup.** Each image's
factory is wrapped once (`observeFactory`, one cached wrapper per imported
factory, so repeated `image()` calls return the same identity). After the inner
factory resolves and before entry, `observeFactory(factory, control,
allowDegradedTrace)` inspects `module?.titanBrowserTrace`: when `state ===
'degraded'` and `allowDegradedTrace` is false, it reports a `harness` failure
control (`degraded browser trace: <reason>`) and throws, failing the run (exit
75) even if the program or tests would otherwise pass, so missing or stale
`.wasm.map` files fail in CI; fabricated transport test fixtures that do not
link `titan-browser-trace.js` omit `titanBrowserTrace` and are unaffected.
The wrapper also calls the loader's own `onAbort` first and sends an `abort`
observation in `finally`, without exposing the Module. An observation is
evidence, not shutdown: before completion the monitor records the reason,
ignores the raw `RuntimeError` that follows it, and waits for the execution
path's terminal failure, which the page sends only after `dispose()` has
returned. Only then does it classify the run as an abort (70). If disposal
never finishes, the deadline still yields 72. An observation after completion
is a late abort (73), and a completion that arrives after an observation,
including a fulfilled host test, cannot erase it.

**Process cleanup.** Cleanup runs in `finally` on every path, including spawn,
connect, and deadline failures. For Node, the runner asks the worker to shut
down and waits up to 500 ms. For Chromium, it sends `Browser.close` (bounded
to 500 ms) and waits up to 1500 ms for the leader to exit. Then each engine
retires its whole process group independently of whether the leader exited:
`SIGTERM` to the group, up to 500 ms, `SIGKILL` to the group, up to 1500 ms
(`owned process group <pid> survived SIGKILL`), then up to 1000 ms for the
leader (`engine leader <pid> did not exit`). A descendant can keep the group
alive without the leader or a profile argument, so leader exit never permits
skipping that escalation. For Chromium, the runner then scans `ps` for
processes whose arguments contain this run's exact `--user-data-dir`, sends
`SIGTERM` and then `SIGKILL` to those only (`Chromium profile processes
survived cleanup`), closes the CDP transport and the HTTP server, and removes
the profile directory. It never kills by executable name and never relies on
killing a launcher wrapper, which can leave a sandboxed browser running. A
cleanup failure becomes `harness failure: cleanup failed: <reason>` with exit
75, or only that diagnostic when another failure already owns the status.

**Host tests.** With `--js-test`, `FILE` is a JavaScript module exporting
`async run(context)`. The runner passes this shallow-frozen private context,
which is not a public bridge:

```javascript
{
  engine: "node" | "chromium", args: Object.freeze([...argsAfterDashDash]),
  create,                                        // the unmodified loader API
  image: async relativeMjs => ({factory, locateFile}), // frozen, cached per path
  bytes: async relativeFile => Uint8Array,       // fresh owned bytes
  stdout: chunk => undefined, stderr: chunk => undefined, // raw runner sinks
  assert: (condition, message = "assertion failed") => undefined,
  equalBytes: (actual, expected, message = "byte mismatch") => undefined,
  tick: async () => undefined,                   // one macrotask boundary
  gc: async () => undefined                      // Node global.gc or CDP collection
}
```

Paths are slash-separated and relative to `--root`, never to the working
directory or the test file; absolute and escaping paths are rejected.
`image` returns the same wrapped factory for the same path and maps
`locateFile` to the sibling Wasm, including names with literal `#` or `?`.
`gc` fails rather than pretending to collect. A fulfilled `undefined` is
host-test success (status 0), a thrown non-loader error is host-test failure
(status 1), a loader error keeps its category, and any other return value is a
harness failure.

**Playwright supervisor (`spec/browser/playwright-run.mjs`).** To run the same
portable `run(context)` host tests (or a standalone Titan image with `--image`)
across Playwright-managed `chromium`, `firefox`, and `webkit`
(`playwright@1.64.1`), `spec/browser/playwright-run.mjs` parses `--engine
chromium|firefox|webkit [--root DIR] [--sdk DIR] [--timeout MS] [--grace MS]
[--allow-degraded-trace] [--image] FILE [-- ARG...]` (defaults: `timeout`
300000 ms, `grace` 1500 ms, `sdk` `<repo>/titan-runtime/browser/`), loads
`playwright` from `TITAN_PLAYWRIGHT_ROOT` and managed browsers from
`PLAYWRIGHT_BROWSERS_PATH`, and reuses `titan-browser-page.mjs`, the exported
`within` and `Monitor` from `titan-browser-run.mjs`, the loopback `/root/` and
`/sdk/` HTTP server, `page.exposeBinding('__titanRunner', ...)` (with
`page.requestGC()` for host-test collections), and bounded `browserServer`
retirement (`browserServer.close()`, escalating to `browserServer.kill()`). Its
own diagnostics start with `titan-playwright-run: `, while the shared `Monitor`
keeps the runner's `titan-browser-run: ` prefix; its unit suite is
`spec/browser/playwright-runner.test.mjs`. It is repository test
infrastructure, not an installed SDK binary.

## The executing protocol runner

`driver.run_standalone_archive_probe(entries, module_names, libnames,
static_archives, link, verbose, extra_objects, options)` keeps its native
contract for host contexts. With a browser `options.context` and at least one
module, it:

1. requires the SDK and a working Node 26+: `driver.browser_node_ready` runs
   `<runner> --probe` and maps its Node diagnostic to `browser provider
   validation requires Node 26 or newer: <reason>; set TITAN_NODE to a Node
   26 or newer executable`;
2. renders the probe as a browser C image (`program_name`
   `titan-provider-probe`, state status 10) whose worker checks, for each
   module, that `<prefix>_init` and `luaopen_<prefix>` are non-null (20) and
   that `<prefix>_abi`, `<prefix>_types`, and `<prefix>_layouts` each return
   one string (21, 23, 25) equal to the embedded metadata (22, 24, 26), and
   returns 0 when all pass;
3. validates `driver.link_extra_flags()` against `driver.browser_link_options`,
   filters out `browsertarget.trace_option` flags (so a measurement build's
   optimization or shrink extras such as `--ldflag=-Os` do not enter the fixed
   `protocol` link while non-trace link extras keep their order), and links the
   probe in a temporary path under the output root with the `protocol` profile
   against `libnames` and `static_archives` (`selected static provider failed
   executable-context protocol linking (<reason>[, exit <code>])`);
4. runs `<runner> --engine node <probe>.mjs` and requires exit 0
   (`selected static provider failed executable-context protocol validation
   (browser runner exit <code>)`, with 75 when the runner could not start);
   and
5. removes the probe source, object, `.mjs`, `.wasm`, and `.wasm.map` on every
   path.

`titanc` calls it before a program or test link, with the program's objects
and the selected archives, exactly where the native probe runs.
`publish_provider_bundle` calls it for every browser library with the staged
archive alone, after the structural checks and before the unchanged-archive
shortcut and the commit, so a corrupted provider fails with the probe's status
and publishes nothing, the predecessor archive stays, and the staged files are
removed. The initial `titan.a` publication in `make browser-sdk` takes the
same path against the runtime and runner staged a step earlier.

**Archive-only consumers.** A consumer resolves a browser library from its
archive alone: provider lookup reads the archive's metadata, and the image
links the archive with the program. The real-toolchain regression builds a
library, moves its source out of every search root, then builds and runs two
consumer test cases from the archive under Node and Chromium.

## The entry gate decision

JSPI supplies promise-based engine continuation switching, not a scheduler.
One instance owner spans a logical entry, including GC and cleanup. An
internal microtask transfer is not permission to admit an unrelated entry,
drain notifications or call a user sink. The coroutine's linear-stack size
still comes from the target descriptor, and application status still comes
only from Titan completion.

The authored entry-gate fixtures exercise parked mixed Lua/Titan/C frames,
tagged transfers, collection, post-resumption catch/defer, independent
instances and state close through production images. Direct general Module
exports return promises and reject reentry without touching C state. The
state-neutral observer stays callable. Timer/RAF responsiveness measures an
admitted entry containing real external waits; it does not turn internal
coroutine transfers into browser-turn scheduler checkpoints.

Bridge handles/callback queues and scheduler policy remain separate work;
they must use the existing logical owner rather than inventing admission
based on absence of live Wasm frames.

`entry_lifetimes.titan` and its test-owned C guard keep an independent Lua
state across three distinct promised C-entry lifetimes: park ordinary and
STACKED chains, resume them, then run allocation-triggered abandoned cleanup
and close the state. The JS fixture interleaves two instances and checks
entry ownership and sink fencing on every private hop. This exercises the
backend lifetime boundary without adding a repeatable public bridge API.


## Baseline

`scripts/browser_baseline.lua` is a measurement harness, not a performance
gate. It builds the Titan program and a plain fork-interpreter image through
the shared `baseline` profile, at O1 and O2, with one JSPI backend and separate
output trees. Coroutine and external-suspension rows always run; there is no
backend-off control. A cell's one option record feeds planning, child build,
identity and receipt. The format identifier stays unchanged.

The historical tables below belong to #329's pre-JSPI images and are not
current JSPI size, memory, startup or latency guarantees.


| Titan cell | `.wasm` bytes | `.mjs` bytes | Node instantiate / run (ms) | Chromium instantiate / run (ms) | Suspension, Node / Chromium (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| O1, Asyncify | 4082312 | 218265 | 18.6 / 650 | 22.3 / 1371 | 1.08 / 3.99 |
| O1, no Asyncify | 2095004 | 188462 | 12.9 / 15 | 18.3 / 25 | — |
| O2, Asyncify | 2328050 | 218265 | 17.2 / 435 | 20.7 / 1133 | 1.08 / 4.47 |
| O2, no Asyncify | 1893502 | 188462 | 15.1 / 16 | 18.5 / 21 | — |

The Asyncify Titan runs include a 200-suspension loop and the coroutine
benchmark, which the controls omit. Titan micro-benchmark medians under Node,
in milliseconds, with the native build and the fork's standalone interpreter
(`lua.js`) for scale:

| Benchmark | O1 Asyncify | O1 no Asyncify | O2 Asyncify | O2 no Asyncify | native | `lua.js` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 200 000 calls | 7.63 | 2.32 | 5.11 | 2.42 | 3.97 | 11.62 |
| 50 000 closures | 10.38 | 5.04 | 8.89 | 4.82 | 3.63 | 11.48 |
| 100 000-element Array | 2.22 | 0.99 | 1.82 | 1.28 | 1.23 | 4.46 |
| 5 000-step string build | 2.56 | 1.36 | 2.75 | 1.53 | 1.46 | 1.82 |
| 20 000 coroutine switches | 327.05 | — | 189.07 | — | 9.94 | 41.47 |

Lua interpreter cells (`entry = "lua-main"`, running `bench.lua` with an
explicit heap-marshalled `argv` in both engines), median of three repeats:

| Lua cell | `.wasm` bytes | `.mjs` bytes | Node instantiate / run (ms) | Chromium instantiate / run (ms) |
| --- | ---: | ---: | ---: | ---: |
| O1, Asyncify | 1101816 | 199701 | 11.0 / 242 | 14.2 / 390 |
| O1, no Asyncify | 328025 | 181337 | 11.8 / 80 | 14.2 / 77 |
| O2, Asyncify | 529190 | 105285 | 9.7 / 65 | 15.3 / 96 |
| O2, no Asyncify | 297192 | 95960 | 5.3 / 27 | 12.4 / 39 |

Lua interpreter micro-benchmark medians under Node, in milliseconds (the
coroutine row runs only in the Asyncify cells and in the fork `lua.js` lane
above):

| Benchmark | O1 Asyncify | O1 no Asyncify | O2 Asyncify | O2 no Asyncify |
| --- | ---: | ---: | ---: | ---: |
| 200 000 calls | 32.19 | 35.85 | 9.79 | 10.69 |
| 50 000 closures | 22.16 | 22.36 | 9.79 | 6.64 |
| 100 000-element Array | 9.02 | 9.46 | 3.12 | 2.32 |
| 5 000-step string build | 2.10 | 2.30 | 1.40 | 0.90 |
| 20 000 coroutine switches | 43.90 | — | 33.22 | — |

Asyncify roughly doubles the Titan image at `-O1` and costs about a quarter at
`-O2`, and instrumented coroutine switches are an order of magnitude slower
than native ones. Per-suspension cost does not depend on the optimization
level. In the Titan images, the `.titan.source` and `.titan.meta` payloads
survive as ordinary data segments named by the linker's data-segment name
table (`.titan.source` is 339 808 B in the Asyncify cells and 339 814 B in the
Asyncify-off controls; `.titan.meta` is 5 672 B in every cell; ordinary
`.rodata` is 104 368 B at `-O1` and 69 B at `-O2`, and `.data` is 460 B and 8
B, inside a 448 986 to 450 348 B data section), while `.titan.cprobe` is
absent; because the payloads are data segments, custom-section stripping alone
cannot remove them. Every Titan image imports 50 symbols (every Lua
interpreter image 27), none of them `dlopen`, `dlsym`, `dlerror`, or a
backtrace function.

## Host processes

The compiler process never loads a Wasm image or a browser archive. The
subprocesses of a browser invocation are `uname`, once during platform
initialization; `emcc` compile-only and preprocessing commands (`-c`, `-E`,
`-fsyntax-only`); the one `emcc --version` query; the archive tools'
deterministic capability probes (which capture and discard tool
stderr/stdout) and archive operations; the compiler's own worker frontends;
`emcc` final links of images and protocol probes; and the runner, for `--probe`
and for running a protocol probe under Node. The native fresh-process provider
validation, the archive-backed native validation image, `_loadlib`, and the
native runtime build are never entered.

## Windows and other hosts

Browser builds are supported from Linux and macOS hosts. On Windows, and on a
native host without an OS label, `driver.validate_target` and the library
initialization boundary both reject the target with `browser builds are
supported from Linux and macOS hosts (host is <host>)`:
`browser builds are supported from Linux and macOS hosts (host is windows)` on
Windows, and `browser builds are supported from Linux and macOS hosts (host is
native)` on an unlabeled native host. The fork's `make install-browser`
likewise refuses a native Windows shell, `Makefile.win` has neither
`lua-browser` nor `browser-sdk`, and the runner refuses to execute an image on
Windows (`harness failure: browser execution is supported from Linux and macOS
hosts`).

## Validation

* `spec/staticmetadata_spec.lua` — synthesized Wasm objects and archives:
  payload readback, padded LEB128, every malformed case, fingerprints and the
  standalone `-shared-mem` rule, mixed formats and features, bitcode, the
  `independent_members` content-scan option (heterogeneous features accepted
  only with the option and without an explicit target), and
  `incremental.native_input_kind`.
* `spec/browser_target_spec.lua` — the descriptor with hand-made records and
  fake tools: freezing, every record and tool diagnostic, the ordered target
  defines, flags, the two build profiles (the profile in the identity, the
  object profile built from the profile, the other profile's flags refused,
  every owned compile option and `BINARYEN_EXTRA_PASSES` spelling refused
  naming the profile, exactly one certified harness level), paths,
  include-root resolution, the probe-cache directory, worker import, the
  compiler-probe feature diagnostic, the browser `--coverage` refusal, and the
  Windows host scope.
* `spec/browser_isolation_spec.lua` — semantic-cache generations and guards,
  the native → browser → native sequence, output markers, toolchain-detail
  hashing, and unchanged native link records.
* `spec/coder/browser_providers_spec.lua` — provider lookup, structural
  validation, archive-only publication with executing validation and its
  failure boundaries, companions, and the process audit
  (`spec/support/browser_process_audit.lua`).
* `spec/coder/browser_images_spec.lua` — the link profile per build profile
  and purpose (production program levels without frame flags, production test
  images with frame flags and both Binaryen skips, test owners' frame flags,
  validation and harness purposes unchanged), the image-derived link purpose
  and its refusals of a contrary or missing purpose, the owned options named
  by profile, missing-SDK and `.mjs` diagnostics, program and test images with
  statuses, binary arguments, uncaught reports, protected initialization and
  allocation failures, the libc drain, the stdio-only filesystem regression,
  dynamic-loading guards, three-file preflight reservation and repeated-link
  image identity, contributor-prologue `.wasm.map` attribution, image
  inventories, measurement optimization, the native libbacktrace and
  fallback trace invariants, and [long-double
  formatting](#the-link-profile) (`-sPRINTF_LONG_DOUBLE=1` for every profile,
  purpose, and entry, every rejected override spelling, and the
  `spec/fixtures/browser_images/long_double.titan` text compared on native,
  Node, and Chromium). Its production-only pin (`keeps frame flags on
  test owners only and links a production test image as a test image`) is
  pending in a validation installation and runs in the production Chromium
  [`browser-playwright`](continuous-integration.md#browser-playwright-job)
  cell.
* `spec/coder/browser_incremental_spec.lua` — browser object and three-file
  link certificates, shared-asset and `.wasm.map`-change invalidation,
  three-predecessor rollback across backup/publication/certificate boundaries,
  and certified `-L`/`-l` archive reuse versus uncertified `emcc`-only system
  libraries.
* `spec/browser_trace_map_spec.lua` — final-image Wasm section/range/name
  extraction, standard v3 `.wasm.map` validation, `x_titan_*` extension
  rewriting, `browsertrace.identity` recipe, `browser_trace_libraries`
  resolution, and malformed/truncated Wasm and map rejection.
* `spec/coder/browser_trace_entries_spec.lua` — browser-only
  `registry[TITAN_ENTRIES_KEY]` registration across all `titanentry` wrapper
  families, split-unit deduplication, early `_init` ordering before
  dependencies and user initializers, function-definition `#line` ownership on
  both targets (`definitionline` across 1-part, 4-part, immediate and graph
  `.titan.h` foreign-header generation, and `TITAN_GENERATED_C_FILE` across
  1-part and 4-part C outputs), the absent stamps and macro under
  `--no-line-directives`, and native output that no target spelling or prior
  browser generation changes.
* `spec/coder/browser_protocol_spec.lua` — the executing check, corrupted
  providers (exits 21 to 26) without publication, re-execution before
  identical-archive reuse, probe cleanup, and archive-only consumers on both
  engines.
* `spec/browser_sdk_spec.lua` — `make lua-browser` reuse and rebuild,
  `make browser-sdk` into an empty root with poisoned ambient `CPPFLAGS` and
  `TITAN_EXTRA_CPPFLAGS`, the thirteen-module provider whose non-compiler
  members are exactly the five LPegLabel objects, differing roots, digest
  order and contents, and the standalone `-shared-mem` archive regression.
* `spec/browser_stdlib_spec.lua` (emsdk-free) and
  `spec/coder/browser_stdlib_closure_spec.lua` — the [dependency-closure
  check](#the-dependency-closure-check) and its negative fixtures, the
  interface-derived [member inventory](#interface-derived-member-inventory)
  (raw foreign functions, nominal members, named-call metadata, unrecorded
  differences), the image manifest (an exact owner partition and budget, and
  rejection of incomplete, duplicate, empty, or unknown assignments and of
  malformed budgets before any build), the byte budget at its exact boundary,
  the CI failure artifact's image and per-engine log paths, the per-owner
  audit of a failed run, the stdout-only audit of a run whose stderr arrives in
  the middle of a report line, and the union audit, which fails when any image
  fails.
* `spec/coder/browser_stdlib_gate_spec.lua` — the [initialization and
  fidelity gate](#initialization-and-fidelity-gate).
* `spec/coder/browser_entry_gate_spec.lua` — the [entry gate](#the-entry-gate-decision).
* `spec/coder/browser_fixtures_spec.lua` — the coroutine and GC behavior in
  the owning `coroutine.tests` and `gc.tests` modules built for the browser,
  and the real browser trace, pin, bare rethrow, and coroutine-append cases in
  `spec/fixtures/browser_runtime/runtime_trace.titan` (`trace.c`, `trace.h`)
  under Node and Chromium.
* `spec/coder/browser_budgets_spec.lua` — every [budget](#budgets) just below
  and just above its limit.
* `spec/minicoro_spec.lua` — the Emscripten lane of the tagged-behavior probe
  (JSPI with and without `MCO_NO_DEBUG`, `MCO_USE_VMEM_ALLOCATOR`, and the tag
  comparator), the unwind-floor harness, and unstarted/suspended/stacked
  retirement before native allocation reuse, under both engines.
* `spec/browser/loader.test.mjs` with `spec/fixtures/browser_loader/` — the
  portable loader suite under both engines and both assertion modes:
  byte fidelity, statuses, sinks, reentry, 50 collectable create, run, and
  dispose cycles, concurrent instances, lifecycle races, and the optimized
  guard image (`optimized-guard.mjs`).
* `spec/browser/runner.test.mjs` and `spec/browser/runner-fixtures.mjs` — the
  runner's resolver, probe, CLI, `--allow-degraded-trace` and default
  degraded-map harness failure, exported `within`/`Monitor` helpers and symlink
  invocation, status categories, grace, abort and cleanup boundaries,
  process-group retirement, and path containment, over Node and both Chromium
  transports.
* `spec/browser/trace-adapter.test.mjs` and
  `spec/fixtures/browser_trace_adapter/{stacks.json,stacks-jspi-current.json,degraded.mjs,lifecycle.c,filter.c}`
  — Node unit tests for the V8, SpiderMonkey, and JavaScriptCore stack parsers
  (historical survey and current JSPI captures, saved-parent cutoff, V8
  title-line frame-shape filtering, and caller-owned capacity bounds),
  `Error.stackTraceLimit` and
  `Error.prepareStackTrace` descriptor preservation (absent, data, accessor,
  non-writable, and non-configurable descriptors without invoking getters or
  setters or constructing an `Error` on unsafe descriptors), lookup boundary,
  gap, and empty-`sourcesContent` validation, and the compiled `lifecycle.c`
  (preRun/export readiness) and `filter.c` (entry/registered-name precedence
  before `titan.c`/`titan_is_lua_source` basename filtering) fixtures.
* `spec/browser/build-trace.lua`, `spec/browser/trace.test.mjs`,
  `spec/browser/playwright-run.mjs`, `spec/browser/playwright-runner.test.mjs`,
  and `spec/fixtures/browser_trace/` — the
  staged multi-engine browser trace gate (36 discovered native cases in
  `trace_cases` plus `trace_uncaught`, staged into `assertions-2` and
  `assertions-0` with 76 positive `cases` rows and 8 intentional
  `degradedCases` rows in `manifest.json`, which also records the installation
  `profile`) covering direct and `.browser.titan`
  contributor locations, deep recursion and engine truncation, mixed
  `Lua -> Titan -> Lua -> Titan` merge order, mixed and `pcall` recursion past
  the [browser C-call limit](#the-regression), all wrapper families, fresh
  raise versus bare rethrow, coroutine append across yield/resume, adjacent
  unmapped helpers, immediate literal calls, held-storage nested capture, merge
  `LUA_ERRMEM` recovery, and WebKit reduced-fidelity rendering across Node,
  Chromium, Firefox, and WebKit. `build-trace.lua` links the test image with
  the `test` purpose and the uncaught image with `program`; every row is exact
  except a production program row, which follows the [ordered-subsequence
  contract](#test-images).

The Busted files need emcc 6.0.13 and the installed browser Lua; the image,
protocol, SDK, stdlib closure, entry and stdlib gate, fixture, budget, and
minicoro files also need Node 26+ and an installed browser SDK, and all of them
except the stdlib closure file also need a headless Chromium.
`spec/support/browser_toolchain.lua` discovers these through
`require({node=true, chrome=true, sdk=true})` (or the subset a file needs)
and the runner's `--probe`. Its
`lua_defines(info)` reads the installed record's `lua_defines`, so specs that
compile C against the browser Lua archive (`spec/wasm_toolchain_spec.lua` and
`spec/coder/browser_toolchain_spec.lua`) use exactly the archive's macros,
including `LUAI_MAXCCALLS`; a record without them fails. Each real case is
pending when a capability is absent; `TITAN_REQUIRE_BROWSER_TOOLCHAIN=1` turns
absence into a failure, and a present but malformed SDK or probe result always
fails.
Two Linux CI jobs run these files with the real toolchain:
[`browser-toolchain`](continuous-integration.md#browser-toolchain-job) runs
`spec/wasm_toolchain_spec.lua`, `spec/coder/browser_toolchain_spec.lua`, and
the trace-map, trace-entry, and budget files beside the loader, runner,
trace-adapter, and Node trace suites, and
[`browser-stdlib`](continuous-integration.md#browser-stdlib-job) runs the
provider, incremental, image, protocol, SDK, stdlib closure, entry and stdlib
gate, fixture, and minicoro files after the browser core stdlib suite. The
Playwright trace gate runs in
[`browser-playwright`](continuous-integration.md#browser-playwright-job).
