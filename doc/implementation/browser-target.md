# Browser target

`titanc --target browser` compiles Titan modules and authored C to
relocatable WebAssembly objects with `wasi-sdk` and Binaryen, publishes library-mode
providers as self-describing Wasm archives, and links programs and tests into
a self-contained ES module (`.mjs`), its WebAssembly binary (`.wasm`), its
trace table (`.wasm.trace`), and its extended source map (`.wasm.map`). The
module embeds Titan's loader and
exports one default `create(options)` function, which web pages and
applications import directly. Tests and command-line workflows run the same
images under Node 26+, headless Chromium (`titan-browser-run`), and
Playwright Chromium, Firefox, and WebKit. The user contract is in the
[browser-target chapter](../language/browser-target.md) of the language
manual.

The implementation is spread over:

* `titan-compiler/browsertarget.lua`, which locates and pins `wasi-sdk` and
  Binaryen (`wasm-opt`), reads and verifies the fork's Lua build record, probes
  the target C facts, owns each build profile's object flags (`object_flags`),
  and builds, freezes, exports, and imports the browser build and semantic
  descriptors;
* `titan-compiler/browserlink.lua`, which owns the SDK asset layout
  (`sdk_assets`), the SDK readiness check (`require_sdk`), the link profile
  (`profile`), the owned-option check for user link extras
  (`validate_extras`), the final-image byte bound and import/export reader
  (`check_image_size`, `image_inventory`), and the loader embedding transform
  (`embed`);
* `titan-compiler/browsertrace.lua`, which computes the content-derived image
  identity before entrypoint compilation, extracts DWARF `.debug_line` from the
  post-`wasm-opt` `.wasm` via `browsertrace.dwarf_map(wasm, map_name, origin)`
  against the final stripped `CODE` payload base (stripping `.debug_*` and any
  existing `sourceMappingURL` section, then appending the new
  `sourceMappingURL` custom section as the image's last section after `name`),
  then runs `browsertrace.rewrite` to emit the extended v3 `.wasm.map`
  (`x_titan_*`) and binary [trace table](#the-trace-table);
* `titan-compiler/browserentry.lua`, the generated browser launcher (`initialize`,
  `entry`, `close`, shared `titan_entry_error_message` conversion), `localtime_r`/
  `localtime`/`mktime` calendar wrappers, and weak C forwards to `titan.browser`'s
  foreign functions (all exported via `TITAN_WASM_EXPORT`);
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
  the output root early, selects the archive-only or four-file image output
  set (`.mjs`, `.wasm`, `.wasm.trace`, `.wasm.map`), and checks the SDK before
  linking;
* the runtime sources `titan.c`, `titan_path.c`, and `ltitanlib.c`, whose
  host-only paths compile out under `TITAN_TARGET_BROWSER`, and the runtime
  headers `titan.h`, `titan/ffi.h`, and `transfer.h`, which carry a `__wasm__`
  include branch;
* the installed bridge contract `titan/browser.h` and the browser-only module
  `titan/browser.browser.titan` ([browser bridge runtime](browser-bridge.md));
* `titan-runtime/browser/`: the private C/JS trace adapter header
  `titan-browser-trace.h`, the zero-dependency WebAssembly factory
  `titan-wasm-factory.mjs` (owning JSPI, the 18 WASI imports, bridge/calendar
  imports, `create({ imports })` merging, and the trace adapter), the loader
  source `titan-browser.mjs` that `browserlink.embed` places alongside the
  factory in every image, the standalone portable peer `titan-protobuf.mjs`,
  and the runner `titan-browser-run` with `titan-browser-run.mjs`,
  `titan-browser-node-worker.mjs`, and `titan-browser-page.mjs`; and
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
  `--c-source` nodes compiled with the descriptor's `clang --target=wasm32-wasip1` prefix;
* library mode: a no-`main` build publishes `<provider>.a` only, after the
  [structural validation](#library-mode-and-structural-validation) and the
  [executing protocol check](#the-executing-protocol-runner);
* [program and test images](#program-and-test-images): a build with `main`,
  or `--test` without `-c`, links `<stem>.mjs`, `<stem>.wasm`,
  `<stem>.wasm.trace`, and `<stem>.wasm.map` with the [link
  profile](#the-link-profile), the [browser entrypoint](#the-browser-entrypoint),
  and the post-link [source-map extension
  rewrite](#source-map-extensions-and-image-identity) and [trace
  table](#the-trace-table); and
* the C-only work these require: preamble, profile, enum-carrier, and
  acceptance C probes, and C-header preprocessing for `foreign import`.

`titanc` never runs a program or test image it links; the [runner](#the-runner)
does. The only image `titanc` executes is the temporary protocol probe.
Semantic clients can instead select a [browser analysis
target](driver.md#browser-analysis-target); this uses the real SDK library
interfaces without building an image. It does not read `TITAN_TARGET`.

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
publishes the semantic target alongside the absent-module list and writes
the browser SDK digest manifest last. Missing browser-SDK
paths are diagnosed, naming `make browser-sdk`, only when a program or test
is linked or when library-mode publication runs the executing protocol check;
compile-only work needs only the verified Lua pieces.

Step (4) also installs the browser LPegLabel archive, which step (5) links into
the provider as its only native payload. Every runtime and
LPegLabel object comes from `titanc --target browser -c --incremental
--print-c-objects --c-source ...`, so Make never duplicates the descriptor's
flags, and the archives go through the descriptor's `llvm-ar`/`llvm-ranlib` and the
staged member-verification path. `luarocks make` stays independent of `wasi-sdk` and Binaryen,
and `make browser-sdk` works into an empty destination. A missing standard
provider is an ordinary provider miss with source fallback.

`Makefile` and `Makefile.win` include `scripts/browser.mk`. On Windows the
recipes pass drive-letter paths to native `lua.exe` and `titanc.exe`; shell
scripts still run under MSYS2. Archive publication and the executing protocol
check belong to the browser target, not the Windows DLL publication path.

## The fork's `browser` target

The Lua fork pinned by the `lua-5.5.1` submodule owns the facts that do not
depend on a linked image. Its `browser` target builds a static Lua archive
with:

* `BROWSER_CC=clang` (or the user-passed path, or the first `clang` on `PATH`),
  `AR="llvm-ar rc"`, `RANLIB=llvm-ranlib`, and no `-fPIC`: a PIC Wasm object
  imports `GOT.mem`/`GOT.func` like a side module, which the static consumers
  reject; `--target=wasm32-wasip1` is the first word of `BROWSER_SYSCFLAGS`, so
  it lands in the record's `cflags`;
* `-DLUAI_MAXCCALLS=100 -DLUA_USE_BROWSER -DLUA_USE_OFF_T
  -D_WASI_EMULATED_PROCESS_CLOCKS -Dl_signalT=int`, without `LUA_USE_POSIX`,
  `LUA_USE_DLOPEN`, or readline ([the browser C-call
  limit](#the-browser-c-call-limit));
* `--target=wasm32-wasip1 -gdwarf-4 -gline-tables-only -mexception-handling
  -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false` in
  `BROWSER_SYSCFLAGS` (no `--sysroot` flag: `wasi-sdk`'s `clang.cfg` supplies
  it), with `MYCFLAGS` passed through and `CMCFLAGS` applied to every browser
  object;
* browser `LUA_PATH_DEFAULT`/`LUA_CPATH_DEFAULT` rooted at the empty
  `LUA_ROOT`, without the executable-relative `!/../` root; and
* its own object directory, `src/browser/obj`, separate from the native build.

`make install-browser PREFIX=<root>`, run in the fork, builds the archive if
needed and installs it. It writes only below `<root>/lib/browser`, never runs
a host Lua interpreter, and refuses an effective configuration that would make
the record false: a missing or wrong `wasi-sdk` `clang`, an effective
`LUA_USE_POSIX`/`LUA_USE_DLOPEN`/`LUA_USE_LINUX`/`LUA_USE_MACOSX`, a missing
`LUA_USE_BROWSER`, a longjmp mode other than `wasm-exnref`, missing standard
Wasm-EH/SJLJ flags, or any flag `browsertarget.validate_flags` refuses in a
record (joined `-mllvm=…`, `-Xclang…`, `--config…`, `@file`, `-target`,
`--sysroot…`, `-mexec-model…`, other exception switches, `-fPIC`/`-fpic`/
`-fPIE`/`-fpie`/`-pie`, `-shared`, `-dynamiclib`, `-rdynamic`, `-pthread`,
`-m32`, `-m64`, LTO, and `-march=`/`-mcpu=`/`-mtune=`). Its `-mllvm OPTION`
values must be exactly `-wasm-enable-sjlj` and `-wasm-use-legacy-eh=false`,
and `scripts/lua_browser.sh`'s reuse check applies the same list.
`fork_revision` comes from the fork tree's own `.git`; a tarball build must
pass `FORK_REVISION=<40-hex commit>`. The fork's README documents the
installer's own failure modes and the record's byte formats.

Titan pins the fork commit through the gitlink, not through the record's copy
of the revision. `archive_sha256` is stable for one
commit, flag set, and `wasi-sdk` build, because `llvm-ar` archives are
deterministic.

### Wasm-EH longjmp contract

Browser builds are pinned to standard WebAssembly `exnref` exceptions and
LLVM Wasm SJLJ (`-mexception-handling -mllvm -wasm-enable-sjlj
-mllvm -wasm-use-legacy-eh=false`, linked with `-lsetjmp`), using the
standardized `exnref` exception instruction encoding. Lua, the runtime,
generated Titan C, authored C helpers, and providers all use the same
settings.

The browser Lua record carries `sjlj=wasm-exnref`, the explicit flags in
`cflags`, and `+exception-handling` in `wasm_features`. Because these facts and
the descriptor's compile flags participate in target identity, objects or
records built under another SJLJ or EH encoding cannot qualify, and `make
lua-browser` rebuilds any stale installation. JSPI is the sole browser
coroutine backend, so protected calls never cross a JavaScript SJLJ trampoline.
Wasm EH catches language longjmp transfers, not engine traps, engine stack
overflow, or arbitrary JavaScript exceptions.

### `make lua-browser`

`make lua-browser PREFIX=<root>` is Titan's convenience wrapper around the
fork's `install-browser`, as `make lua` is for the native build. The Makefile
passes `PREFIX`, `LUA_DIR`, `FORK_REVISION`, the optional tool overrides
`LUA_BROWSER_CC`, `LUA_BROWSER_AR`, and `LUA_BROWSER_RANLIB`, and
`LUA_BROWSER_MYCFLAGS`/`LUA_BROWSER_MYLDFLAGS` (default `MYCFLAGS`/`MYLDFLAGS`;
an explicitly empty value stays empty) to `scripts/lua_browser.sh`. The script
and the fork's `tools/install-browser.sh` `unset` ambient
`CCC_OVERRIDE_OPTIONS`, `CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH`,
`OBJC_INCLUDE_PATH`, `LIBRARY_PATH`, and `COMPILER_PATH`, while the fork's
`src/Makefile` runs its recursive compile/link makes (`browser`, `browser-js`)
under `env -u …` (never empty exports, which would make Clang emit its
`### CCC_OVERRIDE_OPTIONS:` banner to stderr). The script selects `clang` from
`LUA_BROWSER_CC`, then `$WASI_SDK_PATH/bin/clang`, then the first `clang` on
`PATH` that has a sibling `../VERSION` (a host `clang` earlier on `PATH` is
skipped; if none qualifies, it fails early with `no wasi-sdk clang on PATH
(WASI_SDK_PATH is unset, and a wasi-sdk clang has a sibling ../VERSION)`), and
requires `llvm-ar` and `llvm-ranlib` beside `clang` unless overridden. The
major-`34` `VERSION` check happens in the fork's `browser-version-check` (and
the reuse check), not in the script's discovery. Its own failures start with
`lua-browser: `.

An existing installation is reused only when all of these hold:

* the effective browser configuration that the fork's `browser-config`
  reports (fork revision, `wasi-sdk` version, target, longjmp mode,
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
| `factory` | `titan-wasm-factory.mjs` | the zero-dependency WebAssembly factory embedded into generated images (JSPI owner, 18 WASI imports, bridge/calendar imports, `create({ imports })` merging, and the trace adapter) |
| `loader` | `titan-browser.mjs` | the [loader](#the-loader) source embedded into generated images, not a deployment import |
| `runner` | `titan-browser-run` | the [runner](#the-runner)'s POSIX shell launcher (mode 0755) |
| `runner_module` | `titan-browser-run.mjs` | the runner's supervisor |
| `node_worker` | `titan-browser-node-worker.mjs` | the runner's Node worker |
| `page` | `titan-browser-page.mjs` | the shared host-test context and Chromium page entry |
| `build_profile` | `build-profile` | the descriptor's `build_profile` and a newline, written by `make browser-sdk` and [checked at every link](#readiness-and-the-missing-sdk-diagnostic); `sdk-digests` records it |
| `lpeglabel` | `libtitan-lpeglabel.a` | the five LPegLabel objects (`lplcap.o`, `lplcode.o`, `lplprint.o`, `lpltree.o`, `lplvm.o`), compiled for the browser; the provider build passes it with `-X`, so the same five objects are members of `titan.a` |
| `provider` | `titan.a` | the browser standard provider: fourteen shared roots including `io`, browser compositions of `async`, `timer`, synchronous `lua`, the `os` subset, and the `http` and `websocket` clients, browser-only `titan.browser`, and five LPegLabel members |
| `sdk_digests` | `sdk-digests` (`paths.sdk_digests`) | the SDK digest manifest |
The SDK also installs `titan-protobuf.mjs` in `titan_bin`. This standalone ES
module encodes and decodes copied JavaScript values using a portable protobuf
description. Pages deploy and import it separately; the compiler neither
links it nor embeds it in an image, so it is not a `browserlink.sdk_assets`
entry. The SDK also publishes two data-only files that the linker does not
require:

* `absent-modules` lists the modules the target lacks, one `<module>\t<reason>`
  line each, for [missing-module diagnostics](#the-absent-module-diagnostic).
* `analysis-target` records the Titan release and ABI, `wasi-sdk` pin
  (`wasi_sdk_version`), browser Wasm fingerprint, exported C profile, and the
  verified Lua header digest and defines. It uses the bounded graph codec, with
  no tool or installation paths. SHA-256 digests bind it to the exact `titan.a`
  and `absent-modules`
  contents. These three files can move together without the build
  `sdk-digests` manifest, which records installation-specific observations.
  `browsertarget.encode_analysis` projects the validated live descriptor.
  `browsertarget.decode_analysis` accepts only that closed data shape, with a
  64 KiB payload bound, at most 128 graph nodes and at most 1,024 entries.
  It checks that `version.library_series(data.release)` matches
  `TITAN_LIBRARY_VERSION` (rejecting malformed or non-canonical release strings
  and other library series, while retaining `release` as provenance) alongside
  exact matches on `TITAN_ABI_VERSION` and `wasi_sdk_version`, the Wasm/C ABI
  traits, and the Lua record's numeric types and canonical browser defines
  before returning the semantic facts; patch releases of the same
  library series therefore accept each other's `analysis-target` descriptors
  and companion packs when `TITAN_ABI_VERSION` and the other checked traits
  match.
  The encoder visits string keys in bytewise order before assigning graph
  reference IDs, so identical semantic inputs give identical bytes in
  separate Lua processes. Companion pack tooling re-encodes decoded data
  through the same `browsertarget.encode_analysis_data` entry point.

The language manual's [browser SDK
file list](../language/browser-target.md#installing-the-browser-sdk) names every
installed file once; `installer.browser_sdk_owned` is the same list in code,
and `spec/browser_sdk_spec.lua` compares it with a fresh SDK build.

None of the five runtime sources is compiled with `-fPIC`, LTO, or
libbacktrace; their host-only paths compile out under the browser target
define ([Runtime guards](#runtime-guards)). Neither the native `lib/titan/<ver>`
nor the native Lua headers are ever written; the common Titan headers
`include/{minicoro.h,titan.h,transfer.h}` and
`include/titan/{ffi.h,browser.h}` are the native SDK's own files.

### Publishing the browser semantic pack

The release companion for editor distribution is produced offline with
Python 3.9 or newer, Git (including the pinned submodule objects), and the
installed Titan Lua. Start from the unpacked, verified source rock or its
byte-identical checkout, and the finished `make browser-sdk` installation:

```sh
make browser-semantic-pack PREFIX="$P" ROCKS_TREE="$P" \
    SOURCE_ROCK="$R/titan-0.6.2-1.src.rock" TITAN_COMMIT="$C" \
    PACK_OUTPUT="$O/titan-0.6.2-1-browser-semantics.tar.gz"
```

Use the full 40-hex Titan commit and an existing output directory outside
the SDK. With unpacked rock sources, set `PACK_GIT_ROOT` to a local checkout
that has the named commit and its gitlinks. `PACK_PYTHON` selects the Python
executable. The producer compares the rock and live source files with the
commit and recursive gitlinks, and checks the deployed compiler sources,
notices, full browser provider inventory and semantic bytes in the selected
SDK. Unlike consumer-side `browsertarget.decode_analysis`, producer-side
packaging keeps exact release provenance checks: `scripts/browser_semantic_pack.lua`
requires `analysis-target`'s recorded `release` to equal the SDK compiler's
`TITAN_VERSION`, and `scripts/browser_semantic_pack.py` requires matching
`titan-<release>-1.src.rock` and `titan-<release>-1-browser-semantics.tar.gz`
basenames and records exact `release` and `tag` provenance in `manifest.json`.
It checks the semantic-file digests against the final `sdk-digests`
record. The SDK's recorded build profile must match `TITAN_BUILD_PROFILE`;
the public release uses `production`, and `validation` is for local
candidates. The producer changes neither input and does not run `wasi-sdk`,
Binaryen, Node, or a compiler build.

The only payloads are `titan.a`, `analysis-target` and `absent-modules` at
their SDK-relative paths and the corresponding Titan and third-party notices
under `share/titan/`. `manifest.json` carries release/tag, Titan commit,
source-rock basename and SHA-256, library/ABI/API, `wasi-sdk`/Binaryen pins and
build profile, payload sizes and digests, and the matched SDK digest rows
without their absolute paths or stat observations. The manifest is sorted
compact UTF-8 JSON with a final LF. The gzip-compressed ustar has only regular
files, in bytewise path order, with fixed metadata and zero timestamps.
Identical input bytes and provenance produce identical output bytes; rebuilding
the SDK elsewhere is not a promise of identical input bytes.

Only the three semantic SDK files are needed for ordinary editor checking.
The manifest and notices convey release provenance and attribution, and the
WebAssembly build and image-runtime files are not part of this artifact.

### Readiness and the missing-SDK diagnostic

`browserlink.require_sdk(context, descriptor, install)` checks, in the order
`runtime`, `factory`, `loader`, `runner`, `runner_module`, `node_worker`,
`page`, `build_profile`, that each asset is a regular file that `context.io`
can open and read (a bounded
read of at most one byte). It executes nothing, reads no manifest, and does
not require `lpeglabel`, `provider`, or `sdk_digests`: the initial provider
publication runs before either exists. The first missing asset returns:

```text
browser SDK is incomplete: missing "<path>"; run 'make browser-sdk PREFIX=<prefix>'
browser SDK is incomplete: missing "<path>"; run 'make browser-sdk PREFIX=<prefix> ROCKS_TREE=<tree>'
```

It then reads `build-profile` (at most 33 bytes), which must be exactly a
valid profile name and a newline (`browser SDK build profile "<path>" is
invalid; run '<command>'`) and must equal the descriptor's `build_profile`:

```text
browser SDK "<titan_bin>" was built with the <sdk> profile, but this build uses <build>; set TITAN_BUILD_PROFILE=<sdk>, or build a <build> browser SDK in another prefix with 'make browser-sdk PREFIX=<prefix> TITAN_BUILD_PROFILE=<build>'
```

When `install.rocks_tree` is set, the suggested command also names
`ROCKS_TREE=<tree>` after the prefix. The archives in `titan_bin` were compiled
under the SDK's profile, so a link under the other one would mix two object
profiles in one image.

`driver.require_browser_sdk(context)` supplies the repair command's roots.
It keeps the user's original `PREFIX` and `ROCKS_TREE` spelling when called
by the Make recipe, and otherwise uses the installation root and the
nonempty `ROCKS_TREE` environment variable. Identity checks still use
canonical paths. On Windows `browserlink` renders the same command as
`mingw32-make -f Makefile.win browser-sdk`. The check runs only when linking
an image, before the executing protocol check, and during `browser-sdk`;
object compilation never runs it.

### `make browser-sdk`

`make browser-sdk PREFIX=<prefix> [ROCKS_TREE=<tree>]` is, with `make
lua-browser` and `make titan-stdlib-browser-test`, one of the three Titan Make
steps that need `wasi-sdk` and Binaryen. It requires the
installed compiler and common headers
and the browser Lua; it never invokes `lua-browser`, the native standard
library, or the native SDK build, and it clears ambient `LUA_PATH`,
`LUA_CPATH`, and `TITAN_TARGET`. It runs the installed `titanc` from
`TITAN_INSTALL_TREE` (then `PREFIX`); a missing compiler stops with
`browser-sdk: installed titanc not found; run 'luarocks make' or 'make
install-compiler-sdk' first` on Unix, or `browser-sdk: installed titanc not
found; run 'mingw32-make -f Makefile.win compiler' first` on Windows.
`scripts/build_browser_sdk.sh` runs the install sequence once the guarded
Make recipe has set `TITAN_ROOT` to the installation tree, `TITAN_PATH_0_6` to
the checkout, `TITAN_PATH` and `CPPFLAGS` to empty, and
`TITAN_EXTRA_CPPFLAGS` to exactly the vendored lpeglabel include flag.
The native Windows runner helper builds separately against `PREFIX`.
When `TITAN_NODE` is unset or empty, the script unsets it and leaves ordinary
`PATH` selection intact. The
build directory is `TITAN_BROWSER_BUILD_DIR` (default
`$(TITAN_OUTPUT_DIR)/browser-sdk`), a browser `--output` root.

1. `scripts/browser_sdk.lua prepare` retires the previous provider,
   absent-module list, `analysis-target`, `build-profile`, and `sdk-digests`
   before staging a differing root (below). It checks Node 26+ up front
   with `driver.browser_node_ready` against the checkout's runner (`browser
   provider validation requires Node 26 or newer: <reason>; set TITAN_NODE
   to a Node 26 or newer executable`) and creates `titan_bin`.
2. `titanc --target browser --output <build> -c --incremental
   --print-c-objects` compiles the five runtime sources and the five
   LPegLabel sources as `--c-source` nodes; Make reads the certified object
   paths from stdout.
3. `browser_sdk.lua stage-runtime` builds `libtitan.a` and
   `libtitan-lpeglabel.a` from exactly those objects with
   `driver.build_static_archive` (the descriptor's `llvm-ar`/`llvm-ranlib` and
   the member-verification path), rejects any member that imports a `GOT.*`
   symbol or refers to `dlopen`, `dlsym`, `dlerror`, or a `backtrace_` name,
   copies the JavaScript and runner assets (the launcher executable), writes
   the descriptor's profile and a newline to `build-profile`, and checks
   readiness with `browserlink.require_sdk` and
   `driver.browser_node_ready` against the staged runner.
4. `titanc --target browser --output <build> --source-first --incremental
   -X <titan_bin>/libtitan-lpeglabel.a <BROWSER_STDLIB_ROOTS>` publishes
   `<build>/titan.a` through ordinary library mode, which runs the executing
   protocol check against the runtime and runner staged in step 3. The twenty-one
   roots and the payload are described in [the browser standard
   library](#the-browser-standard-library). No `titan.a` or manifest exists
   yet, and none is required.
5. `browser_sdk.lua finalize` rescans the staged provider with the descriptor
   fingerprint, revalidates it structurally, rejects `GOT.*` imports and
   `dlopen`, `dlsym`, `dlerror`, or `backtrace_` references as step 3 does,
   runs the [dependency-closure
   check](#the-dependency-closure-check) over the staged provider, the
   LPegLabel archive, and every object and link certificate under `<build>`,
   requires exactly twenty-one keys, in bytewise order: `titan.async`,
   `titan.browser`, `titan.coroutine`, `titan.gc`, `titan.http`, `titan.io`,
   `titan.iteration`, `titan.json`, `titan.lua`, `titan.math`, `titan.os`,
   `titan.path`, `titan.peg`, `titan.protobuf`, `titan.reflect`,
   `titan.string`, `titan.test`, `titan.timer`, `titan.transfer`, `titan.url`,
   and `titan.websocket`; copies it to `titan.a`; writes `absent-modules`
   from the [status inventory](#subset-parity-gate) and `analysis-target`
   from the validated compiler descriptor; and finally writes
   `sdk-digests` with `incremental.write_sdk_digests` and the existing
   schema.

The manifest records the browser `liblua.a` and its record, every browser Lua
header, the five common Titan headers, and the other browser assets, hashed at
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

The thirteen shared core standard modules reach neither `uv` nor
`async` through their Titan imports: `coroutine`, `gc`, `iteration`, `math`,
`test`, `reflect`, `json`, `protobuf`, `transfer`, `peg`, `string`, `url`, and
`path`. All thirteen are delivered, each with its complete public interface:
no member is omitted, stubbed, or made to raise "unavailable", and none of
them has a `.browser.titan` or `.native.titan` variant. Their foreign imports
are libc, Lua, the Titan SDK headers, and LPegLabel only, and the
target-dependent values they need come from target C defines rather than
whole-file variants: `TITAN_COROUTINE_STACK_SIZE` for `coroutine`, and
`_WIN32` (which `wasm32-wasip1` never defines) through `titan/path_platform.h`
for `path`. The [library nesting policies](#nesting-limits) are shared with
native targets and need no browser-specific defines.

The provider includes the browser-only `titan.browser` in
`titan/browser.browser.titan`, with no native placeholder. It imports only
`gc`; its [foreign entry points and state lifecycle](browser-bridge.md) live in
`titan/browser.browser.titan` and the generated launcher, not in a native-only
dependency or a second coroutine driver.

`titan.async` is composed for the browser from its shared
main `titan/async/async.titan` and the contributors
`runtime.browser.titan` (the [browser driver](libuv-runtime.md#browser-driver))
and `external.browser.titan` (the type-only `ExternalWait`); its native-only
`receiver` and `foreign` families are dropped. Its browser composition imports
`coroutine`, `gc`, `string`, `transfer`, and `titan.browser`.
Its absent members and type-only records are recorded in the
[status inventory](#subset-parity-gate).
`ExternalWait` keeps one private field, so a record literal of it
outside `titan.async` is rejected on both targets, as
`spec/coder/browser_stdlib_closure_spec.lua` checks against the installed
native and browser providers. `ExternalWait` and `Completion` are type-only:
no browser declaration can produce a value of either, which the gate checks.

`titan.timer`'s flat variant `titan/timer.browser.titan`
sits beside `titan/timer.native.titan` with the same public interface. It
imports `async`, `titan.browser` and `errno.h`, and builds one-shot sleeps on
the SDK's `titan:timeout` source. Tickers use `titan:interval` for bounded
periods and chain `titan:timeout` requests for longer ones
([browser timers](libuv-runtime.md#browser-timers)). Its `Ticker` keeps its
methods but holds a host request instead of a uv timer in its private
fields, which the gate's normalization leaves out of the comparison.

`titan.os` composes its shared main with browser clock, environment, process,
and stdio contributors. Calendar and locale code stays shared; environment
and wall time use libc, Task exit uses `async.request_exit`, and parent
streams use SDK sources. Native host queries, CPU time, processes, options,
and signals are absent. The status inventory records those absences;
`InputStream` and `OutputStream` hold browser-specific private fields and
keep every public method. See [the browser owner](os-library.md#browser-parent-stream-owner).
The complete shared `titan.io` facade imports that composition and adds no
foreign boundary or target variant.

`titan.lua` selects its shared main and worker with the browser source-search
contributor. It keeps synchronous independent states in the same instance;
`dofile`, `Lua:run_async`, and `Lua:run_async_from_loader` have no browser
declaration. Source lookup contributes a fixed no-filesystem miss. The Titan
package searcher keeps canonical/preload lookup, then contributes a fixed
no-dynamic-providers miss without reading the environment or probing files.
See [the Lua composition](lua-library.md#browser-states-and-stock-profile).

`titan.http` composes its shared main `titan/http/http.titan` with the shared
`headers.titan` and `options.titan` and the browser contributor
`client.browser.titan`, which imports `titan.browser` and builds the client
on the SDK's `titan:fetch` source ([browser client](http-library.md#browser-client)).
Its servers, upgrades, `Exchange`, and llhttp parser live in `*.native.titan`
contributors that the browser never selects. `titan.websocket` selects its
browser main `websocket.browser.titan` and contributor `client.browser.titan`
beside the shared `types.titan` and `utf8.titan`, and builds the client on the
SDK's `titan:websocket` source ([browser client](websocket-library.md#browser-client)).
Neither brings llhttp, OpenSSL, or libuv into the browser closure. The status
inventory records their absent members.

Six standard modules have only native mains and are absent at compile time:
the flat `titan/{fs,net,ssl}.native.titan` and the folder mains
`titan/{uv,sqlite3,thread}/<name>.native.titan`
([Make inventories](target-source-selection.md#make-inventories-and-audits)).
For `browser` the resolver finds no main, so an import fails with the
[absent-module diagnostic](#the-absent-module-diagnostic), and a contributor
of a folder whose main is unselected stays blocked rather than resolving as a
flat module.
The plan for the six absent modules is provisional:

| Modules | Browser plan (provisional) |
| --- | --- |
| `fs` | only together with a virtual filesystem |
| `uv`, `net`, `ssl` | absent |
| `sqlite3`, `thread` | absent; browser SQLite and Worker-based threads are possible later additions |

No absent capability is exposed as a placeholder: the standard library has no
member that always raises. The [subset parity gate](#subset-parity-gate)
compares every delivered module with its native counterpart. `io` and OS
parent output use the SDK's awaited sinks. Test reporting stays on C stdio:
`titan.test` writes with `putchar`/`fflush`, and
`wasi_snapshot_preview1.fd_write` (`createWasiImports` in the factory) forwards
each nonempty iovec on descriptors 1 and 2 to the [loader](#the-loader)'s
copied-byte queues.
A program that links `titan.async` runs `main` through the async bootstrap
hook, as natively,
unless it is built with `--no-uv-bootstrap`; otherwise the
[entrypoint](#the-browser-entrypoint) calls `main` directly.

### Provider recipe

`BROWSER_STDLIB_ROOTS` in the `Makefile` names the twenty-one logical roots, and
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
the twenty-one module objects (with their split parts) and the five LPegLabel
members.

### The dependency-closure check

`scripts/browser_stdlib.lua` rejects the six browser-absent standard modules
by Titan import and module identity, and libuv, OpenSSL, llhttp, and SQLite by
path, by symbol, and through the evidence each certified input carries:

* **Titan imports** (`check_sources`): logical source candidates below `titan/`
  are resolved through `driver.resolve_source` with a browser context. Only
  its selected `source.files` are scanned, through the compiler's
  `build.imports_for`; a replaced default, an inactive native contributor, or
  a constituent whose folder main is absent is not read. An import of
  `uv`, `net`, `ssl`, `thread`, `sqlite3`, or `fs` fails.
  This also covers explicit source imports. The native Make audit uses a
  validated frozen browser descriptor, as worker restoration does, so source
  selection needs no `wasi-sdk` or Binaryen installation there.
* **Module identity**: the parsed module metadata of each standalone object
  and archive member must not name any of those six absent modules. A neutral
  member filename cannot hide one, while an unrelated application module such
  as `app.fs` is not mistaken for `titan.fs`.
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

`check_archive` applies the path, module-identity, symbol, and header checks to
an archive and every member, `check_output` applies the generated-object,
authored-C, and link-certificate checks to everything below an output root,
and `check_image`
checks a final `.wasm`: its imports, its exports, and every internal function
name from the `name` section, so a dependency that dead-stripping left only
internally is still found, and a missing name inventory fails. The check is
owned by the SDK build and the subset suite (it is never part of `titanc`'s
general link path): `browser_sdk.lua finalize` checks the staged provider, the
LPegLabel archive, and the SDK build tree, and `titan-stdlib-browser-test`
checks its output tree, the installed provider, and each of its test images.
Admitting llhttp would be a deliberate change to these checks; no other
relaxation is part of the policy.

`spec/browser_stdlib_spec.lua` (toolchain-free) covers the path and symbol
matrices, including every archive stem with `.a`, `_a.a`, `_1.48.a`,
`-static.a`, and `.1.a` suffixes. It tests image-name rejection with a hand-built
Wasm module and a passing control, independently of optimizer retention, and
requires the `browser-sdk` environment and recipe to name no native-only
dependency variable.
`spec/coder/browser_stdlib_closure_spec.lua` holds the real-toolchain negative
fixtures:

* a compiled provider that `foreign import`s an injected `uv.h`, an injected
  `libuv.a`, a neutrally named archive that defines `uv_closure_intruder`, an
  authored-C output tree whose object defines that symbol (checked by
  `check_output`), and an image linked with `-X libuv_a.a` whose selected object
  has no forbidden symbol but whose link certificate names the archive;
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

The closure command also checks the selected Titan source tree (the repository
by default; an optional source-tree argument supports isolated injection
fixtures). The real-toolchain closure spec requires every absent module's
import to fail with a diagnostic naming it, and rejects compiled objects and
neutral-name archives whose metadata claims each absent module. Its source
injections exercise the command itself; the toolchain-free unit cases also cover
default and browser contributors, inactive native-only folders,
folder-before-flat selection, and a bare `native.titan` contributor.

### Subset parity gate

The browser standard library is a reviewed subset of the native one: a
delivered module keeps each native declaration it has with the identical
public signature, and every native declaration it lacks is recorded. The gate
in `scripts/browser_stdlib.lua` enforces this over the installed native and
browser providers, which it reads with `staticmetadata.scan_archive` and
decodes with `driver.decode_module_interface`.

**Status inventory.** `scripts/browser_stdlib_inventory.lua` is a Lua data file
the maintainer reviews with every change. Its three tables are:

* `modules`: one row per native module and per browser-only module. A
  `present` row names its test owner and marks the thirteen dependency-free
  modules `core = true`; an `absent` row gives the reason the absent-module
  diagnostic prints; `browser-only` marks `titan.browser`.
* `members`: per present module, one `{ name, status, test }` row for every
  public callable, type, and variable (fields, union variants with their
  constructors, and Interface methods belong to their owner's row). The
  statuses are `implemented`, `raise`, `type-only`, `absent:typed` (the
  declaration names an absent module), and `absent:native-only`. No member
  currently raises.
* `stock_lua`: one row per operation group of the [stock Lua
  profile](lua-library.md#browser-states-and-stock-profile).

A test is `<owner>.<case>` as the runner reports it (subtests joined by `.`),
`os.browser_tests:<name>` for a case of the program-mode OS stream harness, or
a whole `<owner>`, which only implemented members of core modules may name.
`absent:*` and `type-only` rows name no test: the gate is their test.
`M.absent_modules`, the browser-only module set, and the comparison's
omissions are all derived from this file, and `libuv_build_spec.lua` keeps
its present and browser-only rows equal to `BROWSER_STDLIB_ROOTS` and its
present and absent rows equal to `STDLIB_ROOTS`.

**Normalization.** `M.members` flattens an interface into name-keyed rows:
public top-level functions, variables, records, unions, Interfaces, and
aliases, plus their public fields, variants, methods, and statics. A
`Type.CFunction` member is a raw `foreign function` export, and a variant's
generated constructor counts once, as the variant. Each row is compared by
kind, rendered signature, and `types.serialize_semantic`, which excludes
documentation and keeps parameter names, generic scopes and constraints,
alias targets, field order, types and constness, `custom_constructor`, and
module-variable constness. Serialization records a record's total field count
and each public field's physical index, and the same for union variants, so
`M.normalize` first rewrites a copy of each declaration: a record keeps one
hidden field exactly when it has private fields and no custom constructor
(the checker's literal rule in `checker/expression_lists.lua`), a union keeps
one hidden variant exactly when it has private ones (the coverage rule in
`checker/statements.lua`), public fields and variants are renumbered from 0,
module members are sorted, and the native owners of absent methods and
statics drop them. Private layout therefore never reaches the comparison,
while the capabilities it decides do. Interface members are never dropped:
a different method set is a different Interface. Machine layouts are
separate provider metadata and stay unchecked here.

**Checks.** `M.inventory` and `M.check_status` apply:

* A, subset: every compared browser module (every one not marked
  `browser-only`) is native, and every browser row is identical after
  normalization, so a browser module cannot add a public declaration that
  its native module lacks.
* B, absence: every native row of a present module missing from the browser
  has an `absent:*` row, a stale row fails, and the classification is
  checked: an owner is `absent:typed` when its own fields, payloads, or
  generic scope name an absent module, a method or static when its own
  signature does, and a member of an `absent:typed` owner inherits that.
* C, absent modules: the native modules missing from the browser are exactly
  the `absent` rows.
* D, statuses: `implemented`, `raise`, and `type-only` members exist in the
  browser and name tests as above; a raw foreign function is only
  `implemented` or absent; only instance methods of a `type-only` owner are
  `type-only`; and a `type-only` owner can be built neither from a literal nor
  from public variants, and no declaration of any browser module except a
  `raise` member and its own instance methods and fields can produce one. The
  reachability walk treats results, readable fields, variant payloads, const
  variables, and parameters of function-typed parameters as positive, and
  mutable Arrays, Maps, generic arguments, and mutable variables as both.
* E, browser-only modules: `titan.browser` has no native module and is not
  compared, and its raw exports are not native raw-export rows.

**C facts.** `CInteger` spelling, signedness, rank, and bits all compare
exactly. No browser public signature uses an ABI-width C type today; one that
does fails the gate until the policy is decided.

**Test evidence.** `M.require_evidence` checks every test the inventory names
where it runs. `M.passed_cases` counts a `[       OK ]` runner line only when
no subtest below it was skipped or failed, because a parent reports OK after
its subtests whatever their outcome, and counts the names of an `OS-STREAMS`
summary only when its verdict is `PASS`. A skipped case never counts, and a
whole owner needs at least one passed case. `check_browser_stdlib.lua output`
checks the image's owners once per engine on complete runs (a filtered run
skips it), `spec/coder/browser_net_spec.lua` checks `http.browser_tests` and
`websocket.browser_tests`, and `spec/coder/browser_scheduler_spec.lua` checks
`async.browser_tests`, whose runner report the scheduler harness forwards,
and `os.browser_tests` (`M.harness_owners`). A compiler-shard spec in
`spec/browser_stdlib_spec.lua` resolves every referenced owner's
browser-selected sources and requires each named case to be a public
`test_*` function with one named parameter, as the runner discovers it,
each subtest segment to be a string literal of those sources, and a whole
owner to have a case. A harness name must equal a `check('<name>'`
registration of `os-streams.mjs` or match a template registration whose
every `${...}` segment is a quoted literal of the harness. Each harness gate
must run in one of the `browser-stdlib` matrix shards. The same spec rejects a
synthetic inventory naming each kind of stale or misspelled test.

`check_browser_stdlib.lua inventory <native titan.a> <browser titan.a>
[table]` runs the comparison and the status checks, prints `Browser stdlib
inventory: <modules> modules, <members> public members, <absent> absent
members, every status row consistent.`, and writes the Markdown member table
with each row's status and test, followed by the absent members;
`titan-stdlib-browser-test` writes it to `out/browser-stdlib/members.md`.

**Type fixtures.** `spec/fixtures/stdlib/titan_stdlib_browser_types.lua` pins
the documented serialized interface of every browser module as the native
fixture pins the native provider. `check_browser_stdlib.lua fixture <browser
titan.a> [file]` regenerates it through `M.type_fixture`, which gives each
value the lowest long-bracket level whose closing bracket occurs neither in
the text nor across its end (a trailing `]=*` would join it), and quotes a
value that starts with a newline or holds a carriage return, which long
brackets cannot carry. The compiler shard loads the checked-in fixture and
requires one string per browser provider module. The real-toolchain
`browser_stdlib_closure_spec.lua` compares the browser fixture with the
installed browser provider and the native fixture with the installed native
provider's metadata.

The raw `foreign function` exports of the subset are
`protobuf.write_resource_index_bytes(dst, index)` (writes a four-byte
little-endian index), `protobuf.write_resource_index(raw_buf, index)`
(reserves and appends four bytes to a caller-owned buffer and returns 0 when
the reservation fails), `transfer.copy_message`, `transfer.discard_message`,
and `transfer.transfer_load_module`. All five are portable C and are
delivered.

### The absent-module diagnostic

When no lookup finds a module, every not-found site of the loaders,
publication revalidation, and external resolution calls
`driver.missing_module_message(context, modname, source_required)`. For a
browser build it reads `absent-modules` from the descriptor's `titan_bin`
once per resolver context. Browser analysis uses the validated list bound to
its semantic target. A listed module reports `module '<m>' is not
available for target 'browser': <reason>` for a plain and a `.titan` import
alike. Any other name, and any build without the file (no SDK installed yet,
or a native target), keeps `module '<m>' not found` or `source module '<m>'
not found`. The external-resolution probe's `missing` result is unchanged.
The helper is defined inside a `do` block because `driver.lua`'s main chunk is
at Lua's local-variable limit.

### Inventory record

The table summarizes the inventory's module rows and test owners; the status
inventory is the authority for each member.

| Module | Delivered | Absent members | Browser test owners | Final initializer (all delivered modules have init fixtures) | Raw exports |
| --- | --- | --- | --- | --- | --- |
| `coroutine` | yes | none | `coroutine.tests` (the Lua-host cases are in the native contributor `tests/lua_boundary_test.native.titan`) | allocates the module's `mco_runtime` | none |
| `gc` | yes | none | `gc.tests` | none | none |
| `iteration` | yes | none | `iteration.tests` | none | none |
| `math` | yes | none | `math.tests`, including automatic and argumentless seeding | calls `randomseed()` | none |
| `test` | yes | none | `test.tests`, and every other owner through the runner | loads the Lua trace and pattern helpers when the Lua `string` library is open | none |
| `reflect` | yes | none | `reflect.tests` | metatable, hydration, brand, and tag tables | none |
| `json` | yes | none | `json.tests` | builds the JSON pattern | none |
| `protobuf` | yes | none | `protobuf.tests`, including both raw index writers and the reservation failure; `protobuf.portable_tests` for copied-data policy | caches the nominal registry, sets up the ephemeron, validates the codec handoff | `write_resource_index`, `write_resource_index_bytes` |
| `transfer` | yes | none | `transfer.tests` (same-instance behavior), including all three raw exports | installs protobuf's packet-context provider and nominal loader, the ephemerons, and `closure_fields` | `copy_message`, `discard_message`, `transfer_load_module` |
| `peg` | yes | none | `peg.tests` | `_initialize_native()` | none |
| `string` | yes | none | `string.core_test`, `string.format_pack_test`, `string.regex_test` | target size, length-modifier, endianness, and alignment facts; the format and regex parsers | none |
| `url` | yes | none | `url.tests` | builds the URL patterns | none |
| `path` | yes | none | `path.tests` | separator from `TITAN_PATH_WINDOWS` (POSIX on the browser) | none |
| `async` | yes, from its shared main and browser contributors | the libuv-typed `current_loop`, `await_with`, `await_cleanup_with`, `await_cancellable_with`, `await_cancellable`; the native-only `run_foreign`, `prepare_native_retirement`, `wait_external_native`, `prepare_external_wait`, `wait_external`, `wait_external_cleanup`, `version`, `receiver`, `send`, `Receiver`; and `ExternalWait:close`, `:wait`, `:wait_cleanup`, with `ExternalWait` and `Completion` type-only | `async.tests` (its portable contributors; the rest are `.native.titan` contributors), and the scheduler gate owner `async.browser_tests` driven by the scheduler spec | builds the nil-result caches, registers `titan:driver` in the owner state, and registers the bootstrap hook | none |
| `timer` | yes, from its browser variant `titan/timer.browser.titan` | none | `timer.tests` (portable cases; the native-only ones are in `tests/timers.native.titan`), and the timer cases of `async.browser_tests` | none | none |
| `io` | yes, from its complete shared source | none | `io.tests` (shared in-memory cases and browser parent-stream cases; captured-stdio printing is native-only); `os.browser_tests` for embedding-sensitive printing and line iteration | none | none |
| `os` | yes, from its shared main and browser contributors | `clock`; `cwd`, `chdir`, `homedir`, `tmpdir`, `hostname`, `exepath`, `pid`, `ppid`; `spawn`, every `with_*` option, `popen`, `wait_signal`; `ExitStatus`, `SpawnConfig`, `SpawnOption`, `Process`, `InputOutputStream` | `os.tests` (portable calendar/environment cases and browser streams; host commands, CPU time, and forced time zones are native-only); `os.browser_tests` for embedding options and stream lifetimes | constructs stable parent facades and transfer-field descriptors; Stdio owners remain lazy | none |
| `lua` | yes, from its shared main and browser contributors | `dofile`, `Lua:run_async`, `Lua:run_async_from_loader` | `lua.tests` (portable loading, searcher, preload, synchronous state and browser stock-library cases) | none | none |
| `http` | yes, from its shared main, `headers.titan`, `options.titan`, and the browser contributor `client.browser.titan` | `ClientResponse:take_upgrade`, `Exchange`, `Handler`, `Request`, `Response`, `Server`, `UpgradedStream`, `listen`, `listen_tls`, `request_upgrade_on` | `http.tests` (portable header, request-option, fail-fast validation and `lua.new()` refusal cases; socket, server and TLS contributors are `.native.titan`); `http.browser_tests` in the [live network harness](#the-live-browser-network-harness) | none | none |
| `websocket` | yes, from its browser main `websocket.browser.titan`, the shared `types.titan` and `utf8.titan`, and the browser contributor `client.browser.titan` | `AcceptOptions`, `accept`, `Connection:ping`, `Connection:to_transfer_payload`, `Connection.from_transfer_payload`, `Connection.discard_transfer_payload` | `websocket.tests` (portable `DialOptions`, UTF-8 and fail-fast cases; socket, server and transfer contributors are `.native.titan`); `websocket.browser_tests` in the [live network harness](#the-live-browser-network-harness) | none | none |

The table covers fourteen shared modules, `async`, `timer`, `os`, `lua`,
`http`, and `websocket`.
The provider's
browser-only `titan.browser` has no native counterpart; its owners and tests
are described in [browser bridge runtime](browser-bridge.md#test-layers).

The browser composition of `titan.async` imports `coroutine`, `gc`, `string`,
`transfer`, and `titan.browser`; `uv` and `iteration` are imported only by its
native contributors. `transfer` covers verified same-instance data behavior
only; no thread, native-resource, or JavaScript-handle feature is implied.

### Initializer audit

The loader opens the stock Lua libraries before module initialization. The
same ordering holds for independent states created by `lua.new()`. Module-local
initialization remains state-local; loading `async` in an independent state
does not register a second driver.

| Module | Browser initialization | Source site |
| --- | --- | --- |
| `async` | Builds the nil-result caches and stores the bootstrap hook. The browser backend registers `titan:driver` only in the owner state; it performs no signal or process-argument setup. The launcher reads the same bootstrap registry key. | the module `do` block of [`async.titan`](../../titan/async/async.titan), `initialize_backend` in [`runtime.browser.titan`](../../titan/async/runtime.browser.titan), and the `TITAN_MAIN_BOOTSTRAP_KEY` lookup that `driver.browser_entrypoint_contents` generates ([`driver.lua`](../../titan-compiler/driver.lua)) |
| `timer` | Initializes optional source handles to nil; timeout and interval bindings are opened on first use. | the source-handle variables of [`timer.browser.titan`](../../titan/timer.browser.titan) |
| `io` | Imports the selected OS facade and string helpers; no explicit initializer or host operation. | [`io.titan`](../../titan/io.titan) |
| `os` | Constructs stable parent facades and transfer descriptors, with empty lazy Stdio storage. Sources and kind metadata are acquired only by later stream operations. | `stdin`, `stdout` and `stderr` in [`os.titan`](../../titan/os/os.titan); `parent_streams`, `Stdio:open_source` and `Stdio:kind` in [`stdio.browser.titan`](../../titan/os/stdio.browser.titan) |
| `lua` | Creates its loading Map; creating and opening an independent state happens only in `new`, not at module load. The protected state opener installs the same stock profile and searcher as the launcher. | `loading` and `new` in [`lua.titan`](../../titan/lua/lua.titan); `lua_state_open_libraries` in [`worker.titan`](../../titan/lua/worker.titan) |
| `browser` | Allocates and registers its state record, callback thread and handlers. Both owner and independent states initialize without an embedding attach step; only the owner identifies itself as the driver owner. | `state_record` and the module `do` block of [`browser.browser.titan`](../../titan/browser.browser.titan) |
| `math` | Seeds its generator. | the module `do` block of [`math.titan`](../../titan/math.titan) |
| `transfer` | Installs protobuf packet-context and nominal-loader callbacks, configures ephemerons, and builds closure-field descriptors. | the module `do` block of [`transfer.titan`](../../titan/transfer.titan) |
| `coroutine` | Allocates its per-state `mco_runtime` in module storage. | the `runtime` variable of [`coroutine.titan`](../../titan/coroutine.titan) |
| `reflect` | Initializes metatable, hydration, brand and tag tables. | the module `do` block of [`reflect.titan`](../../titan/reflect.titan) |
| `json` | Builds its parsing pattern. | the module `do` block of [`json.titan`](../../titan/json/json.titan) |
| `protobuf` | Retains the state's canonical nominal table, configures the payload ephemeron, and validates its codec handoff. | the module `do` block of [`protobuf.titan`](../../titan/protobuf/protobuf.titan) |
| `peg` | Opens one private LPegLabel engine for the state. | the module `do` block of [`peg.titan`](../../titan/peg/peg.titan) and `_initialize_native` in [`native.titan`](../../titan/peg/native.titan) |
| `string` | Computes target facts, builds format and regex parsers and byte tables, and makes the regex cache weak. | the module `do` block of [`string.titan`](../../titan/string/string.titan) |
| `url` | Builds its URL and request-target patterns. | the module `do` block of [`url.titan`](../../titan/url.titan) |
| `path` | Selects the POSIX separator from the target macro, without querying a host path. | the module `do` block of [`path.titan`](../../titan/path.titan) |
| `test` | Eagerly loads the Lua trace scanner and pattern matcher when the stock helpers are available. | the module `do` block of [`test.titan`](../../titan/test.titan) |
| `gc` | No explicit module initializer. | [`gc.titan`](../../titan/gc.titan) |
| `iteration` | No explicit module initializer. | [`iteration.titan`](../../titan/iteration.titan) |
| `http` | No explicit initializer; the browser client opens the `titan:fetch` source on first use. | [`http.titan`](../../titan/http/http.titan) and [`client.browser.titan`](../../titan/http/client.browser.titan) |
| `websocket` | No explicit initializer; the browser client opens the `titan:websocket` source on first use. The native main's `openings` ephemeron is not part of the browser composition. | [`websocket.browser.titan`](../../titan/websocket/websocket.browser.titan) and [`client.browser.titan`](../../titan/websocket/client.browser.titan) |
| `uv`, `net`, `ssl`, `thread`, `sqlite3`, `fs` | No browser main is selected. Their imports and SDK module metadata are rejected by the closure checks. | [native-only mains](target-source-selection.md#make-inventories-and-audits), `selection.applies` in [`source_selection.lua`](../../titan-compiler/source_selection.lua), [absence checks](../../scripts/browser_stdlib.lua) |

* **`math`.** The automatic seed has two components: `time(NULL) ~ clock()`
  and a value drawn from the generator with `next_random()`, and
  `set_random_seed` takes both. `wasi-libc` supplies `time` and `clock`
  (via `-lwasi-emulated-process-clocks`) through `wasi_snapshot_preview1.clock_time_get`
  without a custom JavaScript bridge, on Node and in Chromium; `clock()`
  measures monotonic elapsed time, not process CPU time, which is an acceptable
  component of Lua's weak default seed. No delivered module calls
  `getrandom()`, which does not link.
* **`test`.** The browser entry opens the standard Lua libraries before any
  module initializes, as the native runner does, so the helpers load eagerly.
* **`string`.** The target facts are computed at run time: on wasm32,
  `size_t` and `long` are 4 bytes, and the browser Lua's `lua_Integer` is
  `long long`.
* **Locale.** `math`, `string` (`format`), and `json` (`numbers`) import
  `locale.h`. `wasi-libc`'s musl `localeconv` always returns the C locale's
  `.` decimal point, so the alternate-locale parity cases in
  `string.format_pack_test` and `json.tests` take their existing capability
  skip. `wasi-libc`'s musl also retains a valid unknown locale name as the
  selection while using C.UTF-8 locale data. OS tests keep that
  selected-name/query and unchanged-format behavior browser-specific; rejection
  of an uninstalled locale remains a native case.
* **`os` calendar.** `browserentry.lua` emits `localtime_r`, `localtime`, and
  `mktime` wrappers backed by `titan_browser_localtime` and
  `titan_browser_mktime`; on every successful call the host fills
  `tm_sec..tm_isdst` (`tm_isdst` in `{0, 1}`) and `__tm_gmtoff`, and the C
  wrapper sets `tm->__tm_zone` to a static per-`tm_isdst` numeric offset name
  (`+hhmm`/`-hhmm`) so `strftime` `%Z` never reads an uninitialized pointer.
* **`transfer`.** Its nominal loader reaches `transfer_load_module`, which
  loads a module through the image's static preload table.

### Test owners and the browser suite

Each browser test owner imports only delivered modules, owner-local support,
and the portable helpers `support.common.titan`, `support.runtime.titan`, and
`support.async.titan`. Cases that need files, worker-based Lua execution,
`thread`, `uv`, or a host command live in native-only owners or contributors:
`test.host_tests`, `reflect.lua_tests`, `json.lua_tests`,
`protobuf.resource_tests`, the `coroutine.tests` contributor
`tests/lua_boundary_test.native.titan`, the `async.tests` contributors named
`*.native.titan` (libuv callbacks, Receivers, foreign work, external waits,
and child Lua states), and the `timer.tests` contributor
`tests/timers.native.titan`. That contributor also counts the native timer
handles that the portable timer cases check; on the browser
`native_timers()` is nil and the scheduler gate counts JavaScript timers
instead. Same-instance `transfer` cases belong to `transfer.tests`; the
Task, thread, and independent-state transfer cases belong to `async.tests`'
native contributors and `thread.tests`. Both suites share the browser roots
and their portable cases, while target-selected contributors (such as
`coroutine.tests`' `tests/close.browser.titan` and
`tests/unwind_test.native.titan`) add cases to one target only.
`support.async` keeps its libuv-driving `drive_until` in the native
contributor `drive.native.titan`.
`io.tests` keeps captured-stdio printing in `printing.native.titan`, while
its shared contributors cover in-memory Readers and `streams.browser.titan`
covers parent-stream conversions and printing. `os.tests` keeps host commands,
CPU clocks, and forced time zones in native contributors; shared cases cover
portable calendars and environment mutations, and browser contributors cover
SDK parent streams and target-specific libc behavior. `os.process_tests`
remains native-only.
`lua.tests` keeps synchronous loading and independent-state cases shared,
including transfer-policy, nominal, custom-hook and closure assertions run
through both chunk and borrowed-Reader entry points. Native contributors own
source files, C-module fixtures, asynchronous worker execution, Receivers and
resource handoff. Browser contributors check destination-stable parent-stream
transfers, stock Lua failures in both state kinds and fixed searcher misses.
`http.tests` keeps its server, socket, TLS, pooling, option, redirect, and
transfer cases in `.native.titan` contributors. Its shared `portable.titan`
covers headers, `RequestOptions` validation, and validation that precedes any
transport, and `validation.browser.titan` covers the browser client's
forbidden headers and method overrides, its method, body, and `ca_file`
checks, and the `lua.new()` refusal. `websocket.tests` likewise keeps
servers, framing, UTF-8 wire cases, and transfer in native contributors; its
shared `portable.titan` covers message kinds, error records, `DialOptions`
validation, and URL and scheme refusal, and `validation.browser.titan` covers
the refusal of dial headers and `ca_file` and the `lua.new()` refusal.
Network behavior of the two browser clients needs
live servers and belongs to `http.browser_tests` and `websocket.browser_tests`,
outside this root inventory ([live harness](#the-live-browser-network-harness)).

The separate embedding-sensitive owner `os.browser_tests` stays outside this
root inventory, like `async.browser_tests`. `browser_scheduler_spec.lua`
builds it as a normal program and runs `os-streams.mjs` (78 named cases) under
Node and Chromium with `TZ=Asia/Kolkata`. Public embedding options supply
delayed and failing streams, input, kinds, end hooks, and environment values.
The cases check binary printing and writes, C-stdio interleaving and return
flushing, cancellation and disposal, TCP shutdown, input and `io.lines`
cleanup, graceful exit, time, calendar zones (`calendar-zone-titan-and-stock`,
verifying `%z %Z` from Titan, stock Lua's owner state, and an independent
`lua.new()` state all equal the host offset `+hhmm`), and environment agreement
with C and stock Lua. Stock Lua checks repeat in public child states;
owner-Task `os.exit` also checks numeric and boolean statuses, while child exit
remains unavailable.
Private published callbacks use `test.assert` without `test.Context` runner
reports, which would pollute the streams under observation; the JavaScript
driver names, counts, and asserts every case. Its normal `main` covers `run()`
return and exit. The async owner's existing `streams.mjs` remains a separate
SDK-source gate, and `io.print_values` shares the Lua conversion probes with
native captured printing.

`spec/support/stdlib_test_modules.mk` lists the browser
roots in `TITAN_STDLIB_BROWSER_TEST_ROOTS`, next to the native
`TITAN_STDLIB_TEST_ROOTS`:

```text
coroutine.tests iteration.tests gc.tests lua.tests math.tests peg.tests
string.core_test string.format_pack_test string.regex_test url.tests path.tests
test.tests reflect.tests json.tests protobuf.tests protobuf.portable_tests transfer.tests async.tests timer.tests os.tests io.tests http.tests websocket.tests
```

All twenty-three owners are compiled into `images/stdlib.mjs`, with its `.wasm`,
`.wasm.trace`, and `.wasm.map` siblings. `TITAN_STDLIB_BROWSER_TEST_ROOTS_CHECK`
rejects an empty or duplicate root inventory before build setup. The compiler's
[general image bounds](#build-time-image-bounds) apply; the suite has no
separate image-size budget or partition policy.

`make titan-stdlib-browser-test` (a test goal, so it defaults to the
`validation` profile) needs the installed native provider, the browser SDK,
`wasi-sdk` 34, Binaryen `version_133`, Node 26+, and a JSPI-capable headless
Chromium. It:

1. writes `roots.txt` in `$(TITAN_BROWSER_TEST_BUILD_DIR)` (default
   `out/browser-stdlib`), then builds `images/stdlib.mjs` with one installed
   `titanc -q --target browser --test --incremental --no-uv-bootstrap --tree spec/stdlib/titan`
   invocation over every root. The compiler output is the directory's
   `objects/` subdirectory, which titanc creates and marks. The invocation
   adds `--c-source spec/fixtures/browser_runtime/close.c` (the browser helper
   of `coroutine.tests`) and runs under `BROWSER_SDK_ENV` with `TITAN_PATH_0_6`
   set to the installed browser SDK. `--no-uv-bootstrap` makes the runner call
   `main` directly, as in the native aggregate: the owners drive their own
   Runtimes through `support.runtime.run`. The target prints the build duration,
   then runs `check_browser_stdlib.lua closure` against the objects, installed
   browser `titan.a` and final `.wasm`;
2. runs `check_browser_stdlib.lua inventory` once against the installed native
   and browser providers, which applies the [subset parity
   gate](#subset-parity-gate), and writes `members.md`;
3. for each engine of `TITAN_BROWSER_TEST_ENGINES` (default `node chromium`),
   runs the image with `TITAN_BROWSER_TEST_RUNNER --engine <engine> --timeout
   300000 --grace 2000` through `scripts/run_browser_stdlib.sh`, forwarding a
   nonempty `TITAN_FILTER` as one `--filter=` argument. The runner is a shell
   command that takes `titan-browser-run`'s options and defaults to the SDK's
   `titan-browser-run`; the validation Playwright cells pass their engine and
   `"$TITAN_NODE" spec/browser/playwright-run.mjs --image --sdk <sdk>`. The
   wrapper saves stdout in `stdlib.<engine>.log` and stderr in
   `stdlib.<engine>.stderr.log`, replays both, and preserves the runner's
   status. Failure under one engine does not hide the other; and
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
   failure-name references are not second outcomes. An unfiltered audit then
   requires every image test the status inventory names to have passed
   ([test evidence](#subset-parity-gate)) and prints `Browser stdlib inventory
   evidence: every named image test passed.` The target fails if either
   engine or its audit fails.

The streams stay separate because a case may write to stderr while the runner
is in the middle of a report line, and a merged log then splits that line; the
expected Lua warnings (`Lua warning: error in coroutine cleanup ...`) are such
writes, and the validator rejects a split report. Warnings
stay visible in the `.stderr.log` files and on the console; nothing is
filtered out. `out/browser-stdlib/` therefore holds `objects/` (titanc's output
tree), `images/` (`stdlib.mjs`, `stdlib.wasm`, `stdlib.wasm.trace`, and
`stdlib.wasm.map`), `roots.txt`, `members.md`, and the per-engine `stdlib.node.log`,
`stdlib.node.stderr.log`, `stdlib.chromium.log`, and
`stdlib.chromium.stderr.log`. The target never writes into `objects/`: titanc
creates it and its `.titan-target` marker on a cold run, because a browser
output root without a marker must be empty when titanc first claims it
([output roots](#output-roots-and-the-target-marker)), and the suite
directory already holds `images/` and `roots.txt` by then.
`spec/coder/browser_stdlib_closure_spec.lua` runs the target with one owner
from a cold and then a warm directory and checks this layout. The
[`browser-stdlib` matrix's `sdk` shard](continuous-integration.md#browser-stdlib-job)
runs the target unfiltered after the SDK is built and uploads everything but
`objects/` when that shard fails. It uses Chrome for Testing with the normal
sandbox and no `HigherRendererMemoryLimit` wrapper.

### Initialization and fidelity gate

`spec/coder/browser_stdlib_gate_spec.lua` (a real-toolchain gate file) builds
twenty-five `--test` images from `spec/fixtures/browser_stdlib/` with the `test`
purpose, and runs them through `gate.mjs` under
`titan-browser-run --js-test` on Node and Chromium. The existing bounded process
batch runs at most two single-slot compiler children, each with an independent
output tree. A multi-root `--test` invocation would combine cases into one
image and would not prove isolated initialization. The isolated fixture list
comes from `BROWSER_STDLIB_ROOTS`; the toolchain-free inventory spec checks each
fixture's direct imports, both combined fixtures, and the child-state module
list against those same roots, and requires the directory's `init_*.titan`
files to be exactly those fixtures, so a stale one cannot go unbuilt:

* `init_<module>.titan`, one for each of the twenty-one delivered roots, imports
  only that module (and the `titan.test` runner every test image has) and must
  return status 0, run and pass exactly one case, and write nothing to stderr.
  These images use `--no-uv-bootstrap`;
* a second image of `init_async` omits `--no-uv-bootstrap`, so the same one-case
  proof also runs through the registered async bootstrap;
* `init_subset.titan` imports all twenty-one roots and is initialized, run, and
  disposed three times through one cached image creator, with a tick and a
  collection between cycles;
* `init_lua_states.titan` requires each root in a fresh `lua.new()` state, then
  requires all twenty-one in one more fresh state. Every state is explicitly
  closed; `async` only loads in the child, without trying to drive it; and
* `fidelity_test.titan` imports the real `coroutine.tests` owner, so its
  browser cases create coroutines first, then writes a marker with NUL, `0xFF`,
  and invalid UTF-8 bytes to stderr and fails a child case whose name and
  message carry the same bytes. The gate requires status 1 through the
  Titan-owned completion channel, the exact name on the run, failure, and
  summary lines, the exact message, and exactly the expected stderr bytes.

The deliberately failing case lives outside every suite root. The browser-only
`titan.browser` participates in the initializer matrix without custom bindings;
the [bridge gates](browser-bridge.md#test-layers) separately exercise its
embedding bindings and request lifecycle.

### The live browser network harness

The browser `http` and `websocket` clients need live servers, which a browser
test image cannot start. The harness in `spec/fixtures/browser_net/` runs from
two places: `spec/coder/browser_net_spec.lua`, a real-toolchain gate file
that is pending unless `TITAN_REQUIRE_BROWSER_TOOLCHAIN` is set, builds it
into `out/browser-net` and runs it on Node and Chromium through the SDK's
`titan-browser-run`; the
[`browser-playwright` job](continuous-integration.md#browser-playwright-job)
runs it on each cell's managed Chromium, Firefox, or WebKit through
`spec/browser/playwright-run.mjs`, in both build profiles.

`spec/browser/build-net.lua OUTPUT` uses the installed `titanc` to build the
native peer `OUTPUT/native/server` from `server.titan`, the test image
`OUTPUT/images/http.mjs` of `http.browser_tests`, and the test image
`OUTPUT/images/websocket.mjs` of `websocket.browser_tests`, which also links
the fixture-only `controls.c`. The browser builds use an empty
`TITAN_PATH_0_6`, so they see only the browser SDK. The builder copies the
JavaScript drivers next to the images.

`run.mjs --root OUTPUT --engine ENGINE --sdk SDK --runner RUNNER --repository
REPO [--persistent-webkit]` owns one run. It starts the native server and
`wire_peer.mjs`, each in its own process group, waits for each `READY` line,
runs the driver with the peers' URLs, checks the final report, and kills and
joins every peer in `finally`. For Linux Chromium, `nss_trust.mjs` first
imports the repository test CA into an NSS database under a private `HOME`
inside `OUTPUT`, through Python `ctypes` over `libnss3`, so verified
`https://` and `wss://` run with no certificate-ignore flag; Node trusts the
CA through `NODE_EXTRA_CA_CERTS`. `--persistent-webkit`, which only the CI step
passes, runs WebKit in a persistent Playwright context inside that private
home, because WebKit's default ephemeral context has no HTTP cache.

* `server.titan` scans loopback ports from 31000 and serves four listeners:
  plain HTTP, and HTTPS with `spec/fixtures/ssl/server.pem` (valid for
  `127.0.0.1` and `localhost`), with `wrong-server.pem` (the same CA, another
  host name), and with the committed self-signed `untrusted.pem`. Its HTTP
  routes echo and inspect requests, report the `Host` and `Content-Length`
  fields received, set `Set-Cookie` fields, answer CORS preflights and expose
  headers (with routes that omit or restrict CORS headers), serve cacheable
  resources with an ETag and hit and revalidation counters, implement every
  redirect status with and without `Location`, a redirect chain past the hop
  limit, and a cross-origin hop, and serve the runner page and the image's
  `.mjs`, `.wasm` and `.wasm.trace` for same-origin requests. Its WebSocket routes echo with subprotocol
  selection and accept the request's own `Origin`, and one route denies every
  origin.
* `wire_peer.mjs` is a Node `node:net` peer for wire behavior that a
  compliant server does not produce: response headers held until
  cancellation, a held body, a chunked stream released on request, gzip with
  the compressed `Content-Length`, a partial body then a reset, and, for
  WebSocket, a 403, a malformed 101, a 101 without the offered subprotocol, a
  held handshake, an empty Close, a Close followed by a reset, a paused
  reader, peer FIN and reset, and a 20 MiB frame. The Close-then-reset route
  waits for the client's Close reply before resetting; after five seconds
  without a reply it records the timeout and resets, and the driver fails
  the missing-reply assertion. Per-route counters report when connections
  open and close.
* `net.test.mjs` is the `run(context)` driver for both runners. It passes the
  URLs in the instance's `env` (`TITAN_TEST_HTTP_URL`,
  `TITAN_TEST_HTTPS_VALID_URL`, `TITAN_TEST_HTTPS_WRONG_HOST_URL`,
  `TITAN_TEST_HTTPS_UNTRUSTED_URL`, the `ws`/`wss` forms of the same listeners
  as `TITAN_TEST_WS_URL` and `TITAN_TEST_WSS_*_URL`, `TITAN_TEST_RAW_URL`)
  with `TITAN_TEST_VERIFIED_TLS` (`"1"` where the CA is trusted),
  `TITAN_TEST_BROWSER`, and `TITAN_TEST_ENGINE`. It runs the HTTP image (39
  active cases, plus two that skip outside their capability context) and four
  Task-form cancellation phases: pending headers, an already-settled headers
  request before adoption, failing metadata, and a pending body. In real
  browsers an iframe from the native server's origin (`same-origin.mjs`,
  created with `requireTrace: true`, so a missing table fails it) runs
  the one filtered case for same-origin cache modes and `no_cors()`. It then
  hands over to `websocket.test.mjs`, which runs the WebSocket image and three
  cancellation phases (opening, read, write). That driver wraps the host
  `WebSocket` constructor to count listeners and sends, and `controls.c`
  wraps the bridge's binding and slot release to count `take` calls, holder
  releases, and Wasm copies, with no production hook.

Each of the four HTTP cancellation phases waits for the peer to see its
aborted connection close before disposal, since disposal is not the leak
oracle. The WebSocket driver, after its suite and after each cancellation
phase, waits for the peer to see every connection it observed close and
requires balanced host listeners on each, before disposal. Both drivers
require that no `onNotificationError` arrives before or during each
`dispose()` they await. The driver ends with one `BROWSER-NET` JSON report
(verdict, 68 cases, the cancellation phases, the same-origin page, engine,
and verified TLS) that `run.mjs` and the spec check.

The tests assert each engine's measured behavior where hosts deviate. Node
aborts the body of a `follow()` redirect response without `Location`. Firefox
and WebKit drop the quoted-list method-override value. WebKit sends a
cache-only miss to the network. Firefox keeps the TCP connection of a
cancelled or timed-out opening until the handshake is answered, and Node
keeps the TCP connection of a rejected opening until the peer closes it, so
those cases release a handshake reply or a peer FIN after their Titan
assertions and only then require the peer-side close. A peer FIN while
writes are buffered is reported late on every engine, so that case requires
that the in-flight or next write raise and that no write succeed once the
socket is not open, not that one particular write fail.

### Nesting limits

Browser and native builds share the 128-level codec budget in `transfer.h`.
The innermost field consumes one level: a nominal-root structural record
chain accepts 127 records, while protobuf's anonymous field root adds a level
and accepts 126, rejecting 127. Generated and reflective protobuf paths,
`protobuf.schema`, `TransferValue`, and packet encode/decode share the budget
and ordinary error string. The browser descriptor does not override it.
Reflective coroutine-stack boundary tests exercise the shared budget on
both targets.

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
# Lua 5.5.1 browser build record v2
fork_revision=<40 lowercase hex>
archive_sha256=<SHA-256 of lib/browser/liblua.a>
headers_sha256=<digest of the installed Lua headers>
wasi_sdk_version=34
target=wasm32-wasip1
wasm_features=<canonical sorted feature list>
sjlj=wasm-exnref
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
`-D<identifier>` or `-D<identifier>=<value>` tokens.

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
2. `wasi-sdk` `clang`, `llvm-ar`, `llvm-ranlib`, and `wasm-ld` (major version `34`)
   and Binaryen `wasm-opt` (version `133`) are located (see
   [Toolchain pins and tool location](#toolchain-pins-and-tool-location)).
3. The record is read and parsed: banner (`v2`) and text encoding, then unknown
   and duplicate keys.
4. Field syntax: missing, non-text, or empty fields, then the three
   hexadecimal fields.
5. The fixed fields: `sjlj` must be `wasm-exnref`, `target` must be
   `wasm32-wasip1`, and `wasi_sdk_version` must equal the major pin (`34`), which
   step 2 already verified from `<sdk>/VERSION`.
6. `wasm_features` is a canonical list matching the expected baseline.
7. `lua_defines` is canonical, sorted, and unique, equals the sorted unique
   `-D` tokens of `cflags`, contains `-DLUA_USE_BROWSER`, and omits
   `-DLUA_USE_POSIX`, `-DLUA_USE_DLOPEN`, `-DLUA_USE_LINUX`, and
   `-DLUA_USE_MACOSX`.
8. `cflags` enables standard WebAssembly `exnref` SJLJ (`-mexception-handling`,
   `-mllvm -wasm-enable-sjlj`, `-mllvm -wasm-use-legacy-eh=false`), matching
   `sjlj=wasm-exnref`, and contains no PIC flags.
9. `cflags` contains no unsupported flag.
10. `archive_sha256` matches `liblua`.
11. `headers_sha256` matches the headers in `lua_source`.
12. `numeric` agrees with the probed C profile (`integer=<lua_integer>,float=<lua_number>`).
13. A trivial Titan-flag object compiled with `clang --target=wasm32-wasip1`
    matches the expected Wasm fingerprint under `staticmetadata.fingerprint_matches`,
    which cross-checks the baseline features against the actual toolchain.

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
The exact EH encoding is additionally pinned by the explicit
`-mexception-handling -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false`
flags in `cflags`; the feature name alone does not distinguish legacy EH from
standardized `exnref` EH.

### Record diagnostics

Every record diagnostic names the record path and the host install command;
field-level diagnostics also name the offending field. Unix uses the fork's
`make install-browser`; Windows uses `mingw32-make -f Makefile.win lua-browser`
from the Titan checkout. Both include the prefix the user supplied. For
example, on Unix:

```text
browser Lua record "<path>" is unavailable: <reason>; install it with 'make install-browser PREFIX=<root>'
browser Lua record "<path>" is malformed: <detail>; install it with 'make install-browser PREFIX=<root>'
browser Lua record "<path>" field <key> mismatch: recorded "<recorded>", expected "<expected>" (fork_revision=<revision>); install it with 'make install-browser PREFIX=<root>'
```

Malformed details are `invalid banner or text encoding`, `invalid key=value
line`, `unknown field "<key>"`, `duplicate field "<key>"`, `missing field
"<key>"`, and `invalid field "<key>": <reason>`, where the reason is `text
encoding`, `empty value`, `invalid hexadecimal value`, `noncanonical list`, a
shell-word error, `expected sorted unique -D tokens`, `<NAME> is unavailable
for browser Lua`, or `requires LUA_USE_BROWSER` (for `lua_defines`), or the
unsupported-flag diagnostic (for `cflags`). A mismatch quotes the record's
value as `recorded` and the required or observed value as `expected`: the pin
or fixed value for the fixed fields, the computed digest for
`archive_sha256`/`headers_sha256`, the probed profile for `numeric`, and the
`target`, `-D` set, or longjmp mode derived from `cflags` (`<missing in
cflags>` when absent). An unreadable archive or header directory reports
`expected "unavailable: <reason>"` in the matching digest field, and a header
directory without `*.h` files reports `unavailable: no installed Lua headers`. When the
fingerprint probe of step 13 disagrees, the failure is a compiler-probe target
mismatch, not a Lua record mismatch. It reports the actual and required target
facts and quotes the supplied compile flags, including feature-changing options
such as `-msimd128`:

```text
browser target compiler probe does not match the required Wasm target: <mismatch>; user compile flags: "<flag>" ...; remove feature-changing flags from TITAN_EXTRA_CPPFLAGS/TITAN_EXTRA_CFLAGS/--cflag
browser target compiler probe does not match the required Wasm target: <mismatch>; check the selected wasi-sdk 34 installation
```

The first form applies whenever the invocation supplied compile extras; the
remedy is to remove the feature-changing argument, not reinstall Lua. The
second form, without user flags, points to the selected `wasi-sdk`
installation. Actual record-field drift keeps its record diagnostic and its
precedence.

## Toolchain pins and tool location

`browsertarget.WASI_SDK_VERSION` is pinned to major `34` (LLVM 23.1) and
`browsertarget.BINARYEN_VERSION` is pinned to `133` (`version_133`).

* **`wasi-sdk`:** When `WASI_SDK_PATH` is set and nonempty it is authoritative:
  the tools are `$WASI_SDK_PATH/bin/{clang,llvm-ar,llvm-ranlib,wasm-ld}`, the
  sysroot is `$WASI_SDK_PATH/share/wasi-sysroot`, and the version file is
  `$WASI_SDK_PATH/VERSION` (line 1 must belong to major `34`, e.g. `34`, `34.0`, `34.1`). Otherwise Titan searches
  `PATH` for `clang` (an empty entry means `.`), resolves `llvm-ar`,
  `llvm-ranlib`, and `wasm-ld` only beside it, and checks its parent
  directory's `VERSION` file and `share/wasi-sysroot`.
* **Binaryen (`wasm-opt`):** Titan checks `WASM_OPT`, then
  `$BINARYEN_ROOT/bin/wasm-opt`, then `PATH`, and verifies `wasm-opt --version`
  reports `133`.

On Windows the basenames end in `.exe` and Titan uses the
[browser toolchain `PATH` search mode](windows-build.md#windows-executable-path-entries).
Native executable resolution must select that exact filename; it may not
append another extension. POSIX requires effective execute permission.
During a Windows `PATH` search, an absent exact candidate permits a later
entry, a present candidate's resolution error stops with its path and cause,
and a resolved executable must still pass its execution check.
The host `CC`, `AR`, and `RANLIB` are never consulted.
`browsertarget.compiler_argv(tools)` wraps `tools.cc[1]` with an `env -u`
envelope unsetting ambient `CCC_OVERRIDE_OPTIONS`, `CPATH`, `C_INCLUDE_PATH`,
`CPLUS_INCLUDE_PATH`, `OBJC_INCLUDE_PATH`, `LIBRARY_PATH`, and
`COMPILER_PATH` (unsetting rather than assigning empty values, because Clang
emits a stderr banner whenever `CCC_OVERRIDE_OPTIONS` is set even to empty),
followed by `{ tools.cc[1], "--target=wasm32-wasip1",
"--sysroot=" .. tools.sysroot }`, so host headers, libraries, or linker
overrides cannot leak into browser builds while `tools.cc[1]` retains the
physical `clang` executable. `tools.cc`, `tools.ar`, `tools.ranlib`,
`tools.ld`, and `tools.optimizer.argv` are absolute one-word argv arrays.
Archive construction proves `llvm-ar` and `llvm-ranlib`'s deterministic `qDc`
and `-D` modes. The full `clang --version` and `wasm-opt --version` outputs are
kept in the descriptor. `incremental.toolchain_identity` still folds `clang`'s
`-E -v` banner and adds the descriptor identity ([Object and link
identity](#object-and-link-identity)).

## The descriptor

The browser target descriptor is the complete, closed description of one
browser configuration. It is built once per resolver context at the target
initialization boundary, frozen before graph planning, and stored as
`context.target_descriptor`; host contexts leave that field nil. Before
freezing it is exactly this plain data graph (`argv` is a dense array of
strings without NUL, CR, or LF; paths are normalized absolute paths):

```lua
{
  label = "browser", triple = "wasm32-wasip1", memory_bits = 32,
  tools = { cc = argv, ar = argv, ranlib = argv, ld = argv, sysroot = string,
    version = "34", source = "WASI_SDK_PATH" | "PATH", location = string,
    version_output = string,
    optimizer = { argv = argv, version = "133", source = "WASM_OPT" | "BINARYEN_ROOT" | "PATH",
      version_output = string } },
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
   `-gdwarf-4`, `-gline-tables-only`, `-mexception-handling`,
   `-mllvm -wasm-enable-sjlj`, `-mllvm -wasm-use-legacy-eh=false`, and
   `-D_WASI_EMULATED_PROCESS_CLOCKS`;
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
Object compilation uses `-gdwarf-4 -gline-tables-only` so every `.o` carries
compact DWARF v4 line tables without full variable debug info; the final link
retains those `.debug_*` sections through `wasm-opt --debuginfo`, after which
`browsertrace.lua` extracts `.wasm.map` and `.wasm.trace` in pure Lua and
strips `.debug_*` from the published `.wasm` while preserving the Wasm `name`
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
(`cdriver.target_profile_inputs`, `csemantics.build_profile`) run with
`clang --target=wasm32-wasip1`, the complete compile prefix, and the include
roots above; its numeric facts are cross-checked with the record. A trivial C
object compiled with the same prefix is classified by the Wasm reader, and its
fingerprint must equal the expected baseline. No probe links or executes
anything.

Clang on Windows may report both slash styles in its include-search banner.
The preprocessor normalizes those separators without rewriting directory
components or search order. `#include_next` can then find the directory that
supplied the current header. Include-root spelling participates in the
semantic C-header digest: old Windows receipts miss once if their recorded
search spelling changes.

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
Changing the `wasi-sdk` or Binaryen installation location, `WASI_SDK_PATH`
versus `PATH` selection, the build profile, a compile extra, or enabling or
disabling the probe cache therefore changes the identity.

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
  adapter with the descriptor's `clang --target=wasm32-wasip1` argv, compile
  flags, and include roots, `language_mode = "c99"`, empty `cppflags`/`cflags`,
  the context profile and its identity, `target_identity = descriptor.identity`,
  and `certification_target_identity`, the `"relocatable-browser-target"` digest
  of the exported descriptor with its compiler-owned SDK paths made
  root-relative. The host result has neither identity field.
* `driver.generated_compile_prefix(context?)` and
  `driver.authored_c_compile_prefix(context?)` take an optional context;
  every browser-capable caller passes it. `nil` keeps the native API.
* `driver.output_tool_descriptors(context, kind)` reports the descriptor's
  `llvm-ar`, `llvm-ranlib`, `wasm-ld`, and `wasm-opt` (`ar`, `ranlib`, `ld`,
  `optimizer`) and no Darwin `dsymutil` for browser, so final-link certificates
  and trace identities certify physical linker and optimizer binaries as well
  as archivers.
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
2. rejects hosts other than Linux, macOS, and Windows:
   `browser builds are supported from Linux, macOS and Windows hosts (host is <host>)`,
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
`-m[no-]exception-handling`, `-m[no-]legacy-exception-handling`,
`-mllvm`, `-mllvm=*`, `-target`, `--target=*`, `--sysroot*`,
`-mexec-model*`, `-Xclang*`, `--config*`, and `@*`.

The diagnostic is `browser target does not support <origin> flag "<flag>"`,
where `<origin>` is `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`,
`TITAN_EXTRA_LDFLAGS`, `--cflag` (the normalized compile extras, and
per-request `extra_compile_flags`), `--ldflag` (the normalized link extras),
or `compile_flags` for direct `browsertarget.build` inputs. A split setting
quotes both words. Flags are never dropped silently. `-fno-lto` is harmless
and accepted. Inside the record, the same check reports
`invalid field "cflags": browser target does not support cflags flag "<flag>"`.

Browser compiler invocations clear ambient `CCC_OVERRIDE_OPTIONS`, `CPATH`,
`C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH`, `OBJC_INCLUDE_PATH`, `LIBRARY_PATH`,
and `COMPILER_PATH` through `browsertarget.compiler_argv`; deliberate EH or
linker overrides through opaque argument channels (`@file`, `-mllvm`, `-Xclang`,
`--config`, or `-Xlinker`) are rejected or unsupported.

`wasm32` has no fat Wasm objects: `-flto` produces bare LLVM bitcode with no
data segments to read. The descriptor never adds LTO and the Wasm reader
rejects bitcode objects and archive members
(`<origin>: LLVM bitcode (LTO) object is not supported`). Enabling LTO later
requires the same metadata and provider gates.

`titanc` rejects `--coverage` for an explicit or environment-selected browser
target with `--coverage is not supported for --target browser`, before target
validation and tool discovery, output locking and marker publication, and
`coverage.prepare`. This covers object-only, library, test, and authored-C-only
builds; native gcov backend and report options cannot inject host coverage
flags into `clang`. Coverage options without `--coverage` retain their ordinary
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
`browsertarget.build` rejects an owned compile option (`trace_option`) in
`inputs.compile_flags` (`browser <profile> profile owns compile option "<flag>"`);
the one exception is a single `-O0` to `-O3` or `-Os` level in a
`trace_control` build. The descriptor validator enforces the same rule on the
finished flags ([Object flags](#object-flags)).
`browserlink.validate_extras(flags, options, build_profile, origin)` rejects
`trace_option` flags in the normalized compile and link extras and final link
extras unless `options.purpose` is `baseline`, `minicoro`, or `budget` (and
`browsertarget.validate_flags` already refuses `-mexec-model*` for every
browser extra, `--ldflag` included). `validate_extras` also owns:

* reactor link/linker flags (including `--no-` inverse spellings such as
  `-Wl,--no-stack-first`): `-Wl,--stack-first`, `-Wl,-z,stack-size`,
  `-Wl,--initial-heap`, `-Wl,--max-memory`, `-Wl,--export-table`,
  `-Wl,--gc-sections`, `-Wl,--allow-undefined`, `-Wl,--no-entry`, driver
  `-z`/`-e`/`-s`/`-nostartfiles`/`-nostdlib`/`-nodefaultlibs`, linker selection
  flags `-fuse-ld=...`/`--ld-path=...`/`-B...`/`--prefix...`, and linker
  response files `-Wl,@file` / `-Xlinker @file`;
* Emscripten content options `--pre-js`, `--post-js`, `--extern-pre-js`,
  `--extern-post-js`, and `--js-library` (refused with guidance to add
  JavaScript through `titan.browser` bindings or `create({ imports })`), plus
  `--embed-file` and `--preload-file` (refused with `browser images have no
  filesystem`);
* the defines `TITAN_CODEC_DEPTH_LIMIT` and `_WASI_EMULATED_PROCESS_CLOCKS`,
  besides the two target defines.

One owned option has one diagnostic, chosen by `origin`: compile extras
(`origin == "compile"`) report `browser <profile> profile owns compile option
"<flag>"`, the same message as `browsertarget.build`, and link extras report
`browser <profile> link profile owns option <flag>` (`browser link profile owns
option <flag>` when the caller passes no profile). `titanc` checks its
normalized compile extras (`--cflag`, `-I`, `-D`, `TITAN_EXTRA_CPPFLAGS`,
`TITAN_EXTRA_CFLAGS`) as `compile` and its link extras as `link`, both with
`driver.BUILD_PROFILE`; image links and the protocol probe check link extras
under the descriptor's `build_profile`. So `--cflag=-O2` in a production build
reports `browser production profile owns compile option "-O2"`, and
`--ldflag=-O3` reports `browser production link profile owns option -O3`.

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
`<prefix>/var/cache/titan-probes/browser-34/<cprobe_cache.VERSION>/`
(`.../browser-34/2/` today), where `<prefix>` is `TITAN_PREFIX` when set
and otherwise `TITAN_ROOT`. The `wasi-sdk` version in the path keeps a pin
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
  a program's key covers `<stem>.mjs`, `<stem>.wasm`, `<stem>.wasm.trace`, and
  `<stem>.wasm.map`.
  `titanc` always supplies its ordinary native profile identity as
  `policy.target`; `linkcertificate.prepare` is the sole writer of the browser
  value: for a browser context it copies the recipe policy and sets `target`
  to the same relocatable descriptor digest without mutating the caller's
  table, which covers non-CLI callers too. A record written by another target
  or another browser configuration is therefore a miss. The browser policy
  also records `browser_profile`, the link profile's `identity_inputs`, and
  for library mode `browser_probe`, the runner's `--probe` report of the Node
  (and Chrome) that the executing check uses. The `runtime` file field lists
  the required SDK assets (`libtitan.a`, `titan-wasm-factory.mjs`, the loader,
  the four runner files, and `build-profile`) plus the browser `liblua.a` and
  its record, all certified by content, so changing any of them relinks while
  object certificates still hit.
* **Backends.** `linkcertificate.linker_backend` selects by link kind
  (`request.kind`, else `context.link_kind`, which `titanc` sets to `program`,
  `test`, or `library`). A library uses backend `archive`: the output tools
  are the descriptor's `llvm-ar` and `llvm-ranlib`, observed without linker
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
`clang --version`/`wasm-opt --version`, reread or rehash the record, archive, or
headers, or read `TITAN_TARGET`; they verify only the compiler inventory.
Coordinator and workers come from one installation.

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
* Binary-first, `--source-first`/`--test`, and explicit-source selection
  policies apply identically; source lookup searches authored `--tree` roots
  and then the read-only installed SDK root `<root>/lib/titan/0.6` for `.titan`
  source only (selecting `.browser.titan` and shared `.titan` variants; native
  providers there are never eligible). Compiled browser archives and owned
  sources use `direct` binding, whereas external installed-source dependencies
  in a browser library archive use the ordinary checked external ABI
  (`handle`/`global` with empty provider filename `""`) so the archive links
  and validates alone and tolerates compatible edits to the installed source
  without rebuilding; consuming browser images satisfy those obligations with
  either an eligible WebAssembly archive or `.browser.titan`/shared `.titan`
  source through `perf.linked_module_catalog` installed in
  `titan_browser_initialize_worker` ([The linked provider
  set](codegen-overview.md#the-linked-provider-set)) only when
  `context.application_source_requirements` is non-nil, reading only in-image
  `symbols` resolver pointers with no dynamic loading, no new Wasm imports, and
  no host JavaScript changes. On browser, the logical `<path>.so` filename inside
  `Type.Module` is an identity string only.

The browser SDK root holds the browser standard provider `titan.a`, so the
twenty-one [browser stdlib](#the-browser-standard-library) modules resolve from it,
ahead of the Titan path and source. Modules with native-only mains have no
browser source, so their imports fail with the [absent-module
diagnostic](#the-absent-module-diagnostic), `module 'titan.<name>' is not
available for target 'browser': <reason>`. The shared `os` main selects its
browser contributors, and the shared `io` facade imports that composition
([target source selection](target-source-selection.md#make-inventories-and-audits)).

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
   target mismatch: <mismatch>`), uses the descriptor's `llvm-ar`/`llvm-ranlib`,
   requires the deterministic-tool probe (`browser archive tools require
   deterministic qDc and -D modes`), and batches `qDc` (the capability probes
   capture and discard tool stderr/stdout through `run_argv`'s output-discard
   mode independently of `driver.LIVE_PROGRESS`, while keeping `-v` command
   echoes, exit status, and the diagnostics of actual archive writes and
   indexing);
3. verify the archive's member sequence byte for byte;
4. check the exact key set;
5. compare the embedded ABI, types, layouts, and optional `source_requirements`
   with the coordinator's expected entries (`driver.compare_archive_entries`);
6. run `driver.validate_browser_provider` (requiring global non-weak
   `<prefix>_source_requirements` whenever `archive.entries[name].source_requirements`
   is present); and
7. publish only `<provider>.a` through `driver.publish_provider_bundle`, which
   rescans the staged archive with the descriptor fingerprint, validates it
   structurally again, runs the [executing protocol
   check](#the-executing-protocol-runner) (`standalone_archive_probe_source`,
   which checks `<prefix>_source_requirements` return shape and bytes, exit
   codes `27` and `28`, when present without requiring the external source to
   be linked), and only then considers the unchanged-archive shortcut or
   renames the staged archive over the destination as the commit point.

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
`wasi-sdk` link and Binaryen `wasm-opt` settings for one image,
`{link_flags, optimizer_flags, compile_flags, identity_inputs}`. Every image,
including the protocol probe and test-owned C images, links through it; neither
the Makefile nor a test duplicates the flag list.

`options` is closed: `purpose`, `optimization`, and `budgets` (`unknown browser
link profile option <key>`).

* `purpose` is `program`, `test`, `protocol`, `gate`, `minicoro`, `budget`,
  or `baseline` (`invalid browser link profile purpose`). Programs use
  `program` and `--test` images use `test`; the executing check uses
  `protocol`; the others serve the runtime-evidence and measurement harnesses.
* `optimization` is `O1` or `O2`, only for `minicoro`, `budget`, and
  `baseline` (`invalid browser link optimization override`); it yields
  `compile_flags = {"-O1"}` or `{"-O2"}` and the matching `wasm-opt` level.
* `budgets` overrides `stack_size` (a positive multiple of 16),
  `initial_heap`, and `maximum_memory` (positive multiples of 65536, stack and
  heap together at most maximum, maximum at most 2147483648), only for
  `budget` (`browser budget overrides require the budget profile`, `invalid
  browser budget override <key>`, `invalid browser memory budgets`).
* The descriptor's `build_profile` selects the level and the frame flags
  ([Link flags per purpose](#link-flags-per-purpose)); a descriptor without a
  valid one is refused with `invalid browser build profile`.

The reactor link command uses `clang --target=wasm32-wasip1 -mexec-model=reactor`
(strict linking, never `--allow-undefined`), followed by `wasm-opt`:

| Flags | Purpose |
| --- | --- |
| `-mexec-model=reactor` | builds a Wasm reactor exporting `_initialize` and `memory` (completion is Titan-owned; no `_start` `main`) |
| `-Wl,--stack-first -Wl,-z,stack-size=1048576` | places the 1 MiB main linear C stack at low memory below static data so stack overflow traps rather than corrupting globals |
| `-Wl,--initial-heap=15728640 -Wl,--max-memory=2147483648` | reserves 15 MiB initial heap above static data and stack, growing up to 2 GiB (failed `malloc` returns `NULL` and raises Lua OOM) |
| `-Wl,--gc-sections` | drops unreferenced `.titan.meta`/`.titan.source`/`.titan.cprobe` segments and dead code |
| `-Wl,--export-table` | exports `__indirect_function_table` so `create({ imports })` hosts can invoke C callbacks via `context.table` |
| `-Wl,--export=__stack_pointer -Wl,--export=__stack_low -Wl,--export=__stack_high` | exports the stack-bound symbols used by `titan-wasm-factory.mjs`; `gate` adds `-Wl,--export=titan_browser_gate_guarded` and `-Wl,--export=titan_browser_gate_observe` |
| `-lc-printscan-long-double -lsetjmp -lwasi-emulated-process-clocks` | links IEEE binary128 `long double` printf (`%La`), standard `exnref` `setjmp`/`longjmp`, and WASI monotonic/process clock emulation |
| `wasm-opt <level> --debuginfo --stack-check` plus `--enable-exception-handling --enable-multivalue --enable-bulk-memory --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int --enable-reference-types` | optimizes the linked `.wasm`, preserves DWARF debug info for `browsertrace.lua`, and injects `__set_stack_limits` runtime stack checking; production `test` images add `--skip-pass=inlining-optimizing --skip-pass=duplicate-function-elimination` |

The generated launcher (`browserentry.lua`) and `browsertrace.lua` annotate
`titan_browser_initialize`, `titan_browser_entry`, `titan_browser_invoke`,
`titan_browser_release_callable`, `titan_browser_close`,
`titan_browser_trace_identity`, and the allocator forwards `malloc` and `free`
(calling the program's allocator so `-Wl,--wrap=malloc,free` wrappers also see
host-allocated blocks and C/JS ownership stays balanced) with
`TITAN_WASM_EXPORT("...")`, and `minicoro.h` exports `titan_mco_entry`. JSPI
`WebAssembly.promising` export wrapping and `WebAssembly.Suspending` import
wrapping happen at instantiation time inside `titan-wasm-factory.mjs`, with no
link-time JSPI flag list.

`identity_inputs` is the closed table that certifies the link configuration:
`{target_identity, profile, purpose, optimization, backend, budgets,
link_flags, optimizer_flags, compile_flags}`, where `backend` is `"jspi"`,
`profile` is the descriptor's `build_profile`, `optimization` is the override
or else the last `-O` flag of the descriptor's compile prefix, and `budgets`
holds all three effective sizes. Image certificates hash it together with the
content of the referenced SDK assets, so a budget, profile, or factory/loader
change relinks, and incompatible variants use separate output trees.

**Filesystem and WASI stubs.** Images have no WASI preopened directories.
`createWasiImports` in `titan-wasm-factory.mjs` implements all 18
`wasi_snapshot_preview1` imports: `fd_write` on descriptors 1 and 2 routes
directly to `owner.output` (copied-byte queues); `fd_fdstat_get` on descriptors
0–2 reports filetype `UNKNOWN` with rights 0 (so `isatty` is false and `stdout`
stays buffered); `fd_prestat_get`/`fd_prestat_dir_name` return `BADF` (so
`wasi-libc` fails filesystem path operations with `ENOENT` before reaching
`path_*`); `fd_read`, `fd_fdstat_set_flags`, `fd_renumber`, and `path_*` return
`NOSYS`; `fd_seek` returns `SPIPE` for fd ≤ 2 (`BADF` otherwise); `fd_close`
succeeds for fd ≤ 2 (`BADF` otherwise); `clock_time_get` implements clock 0
(`Date.now`) and clocks 1–3 (`performance.now`); `environ_sizes_get`/
`environ_get` expose `options.env`; `random_get` uses `crypto.getRandomValues`
in 64 KiB chunks; and `proc_exit` aborts with `exit(N)`.

**Long-double formatting.** `-lc-printscan-long-double` is linked for every
purpose. Clang's wasm32 `long double` is IEEE binary128 (`__LDBL_MANT_DIG__` =
113, `__SIZEOF_LONG_DOUBLE__` = 16). `wasi-libc` defaults to a smaller printf
without full binary128 formatting unless `-lc-printscan-long-double` is linked;
Titan writes `long double` text with `%La` in
`titan_reflect_format_long_double` (`titan-runtime/titan.h`) for `reflect`
projections and the `protobuf` and `transfer` codecs. `spec/coder/browser_images_spec.lua`
verifies that `0x1.000000000000001p0` formats as `1.00000000000000000087` on
Node and Chromium.

**`HEAPU8` / `HEAPU32`.** `titan-wasm-factory.mjs` exposes `HEAPU8` and
`HEAPU32` getters on the per-instance `context` that refresh automatically
after WebAssembly memory growth. The loader keeps `context` private (visible
only to a caller's `create({ imports })` factory function) and never retains
a stale typed-array view across allocations that can grow memory.

**Internal selection.** `driver.browser_link_options` is a Lua field for
in-process harnesses (`{purpose=..., optimization=..., budgets=...}`), set
before `titanc` runs in the same Lua process; there is no command-line option
or environment variable, and it must name a purpose. The image kind decides
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
`{purpose = <resolved kind>}`. `titanc` certifies the final link with
`browser_link_plan(context, kind)`, and `driver.compile_browser_image` resolves
its purpose the same way, also checking the purpose of an explicit
`options.profile`.

## Build profiles

`TITAN_BUILD_PROFILE` (`driver.BUILD_PROFILE`, `production` by default)
selects the browser object and link profile as well as the native one. Target
initialization passes it to `browsertarget.build` as `inputs.build_profile`,
and the descriptor records it as `build_profile`. Probes, generated objects,
`--c-source` objects, entrypoint compiles, and imported worker descriptors
therefore certify one configuration, and the descriptor identity changes with
the profile even where flags agree so the two profiles never share objects or
link records. `make browser-sdk` builds the SDK's runtime and standard library
under the profile in its environment (defaulting to `production`), and images
link the installed SDK archives as built, matching native provider linking.
The user contract is in [build
profiles](../language/browser-target.md#build-profiles).

### Object flags

`browsertarget.object_flags(build_profile)` is the single source of the owned
object prefix:

| Profile | Owned object flags |
| --- | --- |
| `validation` | `--std=c99 -O1 -fno-inline -fno-optimize-sibling-calls -Wall -Wno-unused-but-set-variable -Wno-unused-function -gdwarf-4 -gline-tables-only -mexception-handling -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -D_WASI_EMULATED_PROCESS_CLOCKS` |
| `production` | `--std=c99 -O3 -Wall -Wno-unused-but-set-variable -Wno-unused-function -gdwarf-4 -gline-tables-only -mexception-handling -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -D_WASI_EMULATED_PROCESS_CLOCKS` |

`validation` preserves physical stack frames for exact diagnostics, while
`production` compiles at `PRODUCTION_LEVEL = "-O3"` (matching native
production; see [Measurements](#measurements)). Both profiles include
`-gdwarf-4 -gline-tables-only`, the warning flags, and standard `exnref`
Wasm-EH longjmp; the record's `lua_defines` and target defines follow.

The validator, shared by `build` and `import`, requires `compile_flags` to
start with exactly that list (`browser <profile> profile compile flags do not
match its object profile`) and refuses every later `trace_option` flag with
`browser <profile> profile owns compile option "<flag>"`. The only exception is
the [harness level hook](#the-harness-level-hook).

### Link flags per purpose

`browserlink.profile` takes the `wasm-opt` optimization level from the harness
`optimization` override or else from the descriptor's last `-O` compile flag,
and skips inlining/deduplication on production test images:

| Profile | Purpose | `wasm-opt` level | `wasm-opt` `--skip-pass` flags |
| --- | --- | --- | --- |
| `validation` | every purpose | `-O1` (or the harness level) | omitted |
| `production` | `program` | `-O3` | omitted |
| `production` | `test` | `-O3` | `--skip-pass=inlining-optimizing --skip-pass=duplicate-function-elimination` |
| `production` | `protocol`, `gate`, `minicoro`, `budget`, `baseline` | `-O3` (or the harness level) | omitted |

`--debuginfo --stack-check` and the feature flags of
[the link profile](#the-link-profile) follow in every row. The image kind
decides between `program` and `test`; a harness that sets
`driver.browser_link_options` may choose one of the harness purposes instead,
but a contrary `program` or `test` purpose is an error ([internal
selection](#the-link-profile)). The trace gate's `build-trace.lua` therefore
names `test` for its test image and `program` for its uncaught image.

### Binaryen pass order

JSPI does not run a Wasm stack-rewriting pass. Production test images skip
Binaryen's `inlining-optimizing` and `duplicate-function-elimination` passes
because physical trace identity is part of their contract.

### Test images

A production `--test` image keeps the exact frames that the trace gate
asserts, matching native `--test`:

* **Test owners.** `driver.test_owner_flags(test_build, test_functions,
  context)` puts `-fno-inline` before `test_runner.TEST_COMPILE_FLAGS`
  (`-fno-optimize-sibling-calls`) for a browser context whose descriptor
  profile is `production`. A worker reads the profile from its imported
  descriptor. The flags follow the descriptor prefix on the owner's generated
  C only, `codegen.test_flags` certifies them, and the descriptor identity
  carries the profile. Other modules, the generated runner, and the SDK
  archives keep the profile's flags.
* **No Binaryen inlining.** The production `test` purpose appends
  `--skip-pass=inlining-optimizing` to `optimizer_flags`. `--skip-pass`
  is a `wasm-opt` option that disables the named pass wherever it runs in the
  pipeline; the pass name must be `inlining-optimizing` (`--skip-pass=inlining`
  is a no-op).
* **No duplicate-function folding.** Skipping inlining alone lets Binaryen's
  `duplicate-function-elimination` fold byte-identical test helper bodies into
  a single function, losing distinct frame names (even when every object has
  `-fno-inline -fno-optimize-sibling-calls`). Production `test` also appends
  `--skip-pass=duplicate-function-elimination` to `optimizer_flags`, preserving
  distinct trace frames.
* **Validation needs neither.** Its objects already carry the frame flags;
  every image runs `wasm-opt`, and validation runs it at `-O1` with no skip
  passes.

A production *program* image accepts inlining, as native production does. The
trace gate's production program rows require the shown Titan frames to be an
ordered subsequence of the row's exact frames, with exact file and line (file
only on WebKit), and each name matching either the frame itself or an enclosing
caller it was inlined into. The program's own Titan frames come first, at least
one must appear, and the outermost must be the entry (`trace_uncaught.main` is
called from C, and `trace_async.main` runs as the async bootstrap Task through
a function value, so neither inlines away). In the async row only runtime
frames (`async.titan`, `coroutine.titan`, `runtime.browser.titan`) may follow
the entry. Because a production image inlines minicoro's C
`titan_coroutine_enter` into `coro_entry_trampoline` and the trace adapter
locates frames only from `.titan` segments, a PC in that C renders as the
no-line frame `coroutine.titan: in titan.coroutine.coro_entry_trampoline`;
outside WebKit every other Titan frame must carry a line, and no row accepts a
`.c` location. Lua frames, markers, fallbacks, and merge order stay exact, and
no `titanentry` symbol or mangled C name may appear. Test-image rows stay
byte-exact, and validation program rows show every own frame in exact order.
The gate reads the installation profile from `manifest.json` and fails if it
is missing or invalid.

### Historical instrumentation measurements

Pre-Wasm-EH / pre-JSPI measurements of Asyncify instrumentation locals and
JavaScript-SJLJ engine recursion ceilings do not describe current JSPI images
or justify the current pass list; the two surviving production-test skips
(`inlining-optimizing`, `duplicate-function-elimination`) preserve trace
identity independently of the coroutine backend. The retired tables survive at
the permalink in [retired evidence
records](benchmark-archives.md#retired-evidence-records).

### The harness level hook

When `driver.browser_link_options.purpose` is `baseline`, `minicoro`, or
`budget`, target initialization builds the descriptor with `trace_control =
true`. Only such a descriptor may carry an owned option after the profile
prefix: a single trailing level flag (`-O0`–`-O3` or `-Os`) from the
`optimization` override or a harness `--cflag`. One rule (`check_owned_tail`)
applies in both `browsertarget.build` and the validator, rejecting any other
owned `trace_option` flag with `browser <profile> profile owns compile option
"<flag>"`. `trace_control` enters the descriptor
identity. The hook is reachable only through the Lua API for CI's baseline
cell, `scripts/browser_baseline.lua`, and the measurement/budget specs;
ordinary production builds stay at `PRODUCTION_LEVEL`.

### Measurements

The `-O3` production choice over `-O2` was backed by pre-cutover sweeps across
Node, Chromium, Firefox, and WebKit: `-O3` roughly matched `-O2` in image size
(within ~1%), matched or beat `-O2` across compute micro-benchmarks (cutting
coroutine-switch time by ~23% on Node), raised recursion ceilings 1.8×–8.5×
over validation across all engines, and kept max function locals well under
V8's 50,000-local limit (at most ~100 in production vs ~2,164 in validation).
Those pre-Wasm-EH / pre-JSPI tables are archived in [retired evidence
records](benchmark-archives.md#retired-evidence-records); current JSPI
production measurements live under [Records](#records).

## Program and test images

`titanc` plans a browser program or test like a native one; the build
coordinator's [output preflight](build-coordinator.md#pre-dispatch-output-preflight)
reserves the executable (`.mjs`), its WebAssembly binary (`.wasm`), its trace
table (`.wasm.trace`), and its source map (`.wasm.map`).
`driver.browser_program_path(stem, explicit)` maps the output: the explicit
`--exe` (which must end in `.mjs`: `browser executable output "<path>" must end
in .mjs`) or `<stem>.mjs`, where the stem is the native program output path,
plus its `.wasm`, `.wasm.trace`, and `.wasm.map` siblings. A test
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
4. link into a staging directory beside the destination using
   `env -u CCC_OVERRIDE_OPTIONS … -u COMPILER_PATH <clang> --target=wasm32-wasip1 --sysroot=<sysroot> -mexec-model=reactor <link_flags> -o <staged>.wasm.linked <entry.o> <objects> <archives> <extra objects> libtitan.a liblua.a <link extras> <final_link_flags>`
   (no `--start-group`/`--end-group`; archives appear once), capturing
   `wasm-ld`'s `--trace` stdout when `dependency_output` is set, then run
   `wasm-opt <optimizer_flags> <staged>.wasm.linked -o <staged>.wasm`;
5. read the post-`wasm-opt` Wasm and run `browsertrace.dwarf_map(wasm, map_name,
   origin)` in pure Lua to parse DWARF `.debug_line` against the final stripped
   `CODE` payload base (handling `.debug_*` sections even if they precede
   `CODE`), strip every `.debug_*` and any existing `sourceMappingURL` section,
   and append the new length-prefixed `sourceMappingURL` custom section
   (`<basename>.wasm.map`) as the image's last section after `name`, returning
   the stripped Wasm bytes and the in-memory raw v3 `map_json`;
6. run `browserlink.image_inventory` on the stripped Wasm returned by
   `dwarf_map` (which shares `staticmetadata.browser_trace_image`, enforces the
   [byte bounds](#build-time-image-bounds) using the in-memory `map_json` on
   body rejection, and rejects forbidden imports such as `dlopen`, `dlsym`,
   `dlerror`, or `backtrace`);
7. run `browsertrace.rewrite` on the stripped Wasm and in-memory `map_json` to
   produce the extended source-map bytes (with `x_titan_image`,
   `x_titan_function_imports`, `x_titan_function_ranges`, and
   `x_titan_function_names`) and the binary [trace table](#the-trace-table)
   bytes, then write `<staged>.wasm`, `<staged>.wasm.map`, and
   `<staged>.wasm.trace`;
8. read the installed `titan-wasm-factory.mjs` and `titan-browser.mjs` and call
   `browserlink.embed(factory, loader, wasm_name, identity)` to emit
   `<staged>.mjs`: `embed` rewrites top-level `export function NAME(` test seams
   in the factory to plain `function NAME(`, removes the factory's trailing
   `export default IDENT;`, encloses the loader, and installs the single
   `export default function create(options)` wrapper binding `{identity, wasm,
   directory}` with bundler-visible
   `new URL("<basename>.wasm" | "<basename>.wasm.trace", import.meta.url)`
   expressions (honoring caller `locateFile(name, directory)`). `directory` is
   `new URL('.', import.meta.url).href`, except that a module evaluated from an
   opaque URL (`URL.canParse('.', import.meta.url)` is false: `blob:` and
   `data:` modules, which the playground builds from verified bytes) binds `''`
   when the caller supplies `locateFile`; without one, such a module still
   fails in `create`, since neither default URL can resolve. Both factory
   and loader digests participate in image/certificate identity. Then run
   `before_commit` (which invalidates the link record);
9. validate that any existing destination in `{ <stem>.wasm.trace,
   <stem>.wasm.map, <stem>.wasm, <stem>.mjs }` is a regular file (`browser
   output '<path>' is not a regular file`) and reserve a sibling `.old` backup
   path for each before touching any predecessor; then in order `.wasm.trace`,
   `.wasm.map`, `.wasm`, `.mjs`, move any existing predecessor to its backup
   and rename the staged artifact into place, and run `after_publish` (`titanc`
   commits the link certificate there). The `.mjs` rename (followed by
   `after_publish` when present) is the commit point: if any backup rename,
   publication rename, or `after_publish` fails, rollback walks the outputs in
   reverse order (`.mjs`, `.wasm`, `.wasm.map`, `.wasm.trace`), removes
   published new files, and restores every backed-up predecessor (`cannot
   restore browser artifact: <reason>; predecessor retained at <backup>` when
   even restoration fails). An unextended `.wasm.map` is never visible at the
   published path. The backups are removed after the commit.

An image owns no DSO, debug bundle, or dSYM companion
(`validate_program_output_paths` reserves the `.wasm`, `.wasm.trace`, and
`.wasm.map` siblings in `extra_outputs` and omits `.dSYM` on Darwin hosts for
a browser context). A warm link hit verifies all four files, and a missing or
modified `.mjs`, `.wasm`, `.wasm.trace`, or `.wasm.map` forces a relink while
objects still hit. Final images never read `.titan.meta`, `.titan.source`, or
`.titan.cprobe`, and carry none of them. On Wasm the two metadata payloads are
unreferenced external definitions rather than `used` statics, so objects and
archives keep them for the metadata readers and `wasm-ld --gc-sections` drops
them from every image. Their `<mangled>_\u2119_titan_metadata` and
`<mangled>_\u2119_titan_source` names keep these external symbols apart from
module protocol functions and authored C names; probe payloads never reach an
image ([Baseline](#baseline)). Historically, on Emscripten images, the payloads
were more than a third of an image: the validation trace-gate runtime image
shrank from 19,689,714 to 12,317,007 bytes, and the standard-library aggregate
from 55,845,693 to 35,884,282 bytes, with as much less initial linear memory.
C `exit()` reaches `wasi_snapshot_preview1.proc_exit` (an `entry` import in
`scripts/browser_imports.lua`), which neither the entrypoint nor completion
uses.

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

On body rejection only, the driver passes the in-memory source map that
`dwarf_map` just returned to `browsertrace.function_source` with that existing
range (`<staged>.wasm.map` is only written later, after `image_inventory`
passes). The same JSON,
source-map validation and VLQ walk used by publication finds the first mapped
instruction inside the body; it never borrows the previous function's
location. Same-offset unmapped replacements and the exclusive end boundary
are respected. Diagnostics include the literal `sources` entry, one-based line
and column, and a separate literal `sourceRoot` when present. They do not
infer a path from a symbol or invent a mapping for native or unnamed code.
Absent, empty, invalid or wholly unmapped source metadata produces an explicit
`source unavailable` reason while preserving the size diagnostic.

All program, generated-test and provider-protocol images share this check
before map rewriting, `before_commit`, protocol execution or four-file
publication. Guard rejection leaves predecessor bytes untouched; the failed
link certificate stays invalidated and the staged candidate is retired.
The compiler inventory hashes both guard and source-map Lua owners into the
final-link recipe, so changing either owner invalidates certified links.
Hit links return before linking or parsing an image again.

The 168-line transfer recovery lambda stays unsplit in the portable regression
(~668 KB validation Wasm body, ~4,869 locals), well inside the image bounds on
Linux x64 and macOS arm64 under Node and sandboxed Chromium.

### Self-contained image modules

One generated `.mjs` serves pages, bundlers, and Node without external module
imports. `browserlink.embed` concatenates the zero-dependency
`titan-wasm-factory.mjs` (rewriting its named `export function NAME(` unit-test
seams to plain `function NAME(` and stripping its trailing `export default`)
with `titan-browser.mjs`, and emits a single `export default function
create(options)` wrapper. Node local file and `file:` URL reads inside
`titan-wasm-factory.mjs` use `process.getBuiltinModule('node:fs')` directly,
with no `import` declarations, dynamic `import()`, or `require()`. Page
JavaScript reaches Titan through `create({ bindings })` (`titan.browser`) or
through custom WebAssembly imports passed to `create({ imports })`.

### Import manifest

`scripts/browser_imports.lua` is the reviewed allowlist of the imports a final
browser image may contain. The maintainer reviews every change to it, as for the
[status inventory](#subset-parity-gate). Each row is
`{ class, module, name, signature, provider = ..., reason = ... }`:

* the class says which images may use the import;
* the signature is the Wasm function type as `(params)->(results)`, for
  example `(i32,i64,i32)->(i32)`; a non-function import names its kind
  (`memory`, `table`, `global`, or `tag` and its signature) instead;
* the provider names the JavaScript that implements the import in the
  generated `.mjs`: `titan-wasm-factory.mjs` (JSPI/bridge/trace/calendar or
  `createWasiImports`) or a test fixture supplied via `create({ imports })`; and
* the reason says why images need it.

Every image has the `entry` class: programs, test images, and provider protocol
probes, which all link Titan's launcher. A repository test image adds one class
for each test fixture it links, so one fixture's imports never pass in an
image that does not link that fixture:

| Class | Fixture |
| --- | --- |
| `fixture:controls` | `spec/fixtures/browser_runtime/fixture_controls.h`, the `TITAN_WASM_IMPORT` controls that several C helpers include |
| `fixture:trace` | `spec/fixtures/browser_trace/trace_support.c` |
| `fixture:click` | the DOM click counter `spec/fixtures/browser_bridge/click_host.h` (`counter.titan`, `env.titan_test_set_click_callback`) |
| `fixture:net` | live network harness images (`spec/stdlib/titan/websocket/browser_tests/native.h`) |
| `fixture:loader` | `spec/fixtures/browser_loader/loader.c` |
| `fixture:gate` | `spec/fixtures/browser_runtime/gate.c` |
| `fixture:budget` | `spec/fixtures/browser_runtime/budget.c` (`env.fixture_sleep` and `env.budget_stack_state`) |
| `fixture:images` | entry-close C image (`spec/fixtures/browser_images/entry-close.c`) |
| `fixture:scheduler` | `spec/fixtures/browser_scheduler/mini_driver.c` and `scheduler_child.c` |

Fixture host imports are provided by `spec/fixtures/browser_runtime/fixture-imports.mjs`
through `titan-browser-run --imports`.

No non-function import (memory, table, global or tag) is listed, so any such
import fails the check.

The `entry` rows are the bridge, completion, admission, coroutine, relinquish,
trace, and calendar (`titan_browser_localtime`, `titan_browser_mktime`) `env`
imports implemented by `titan-wasm-factory.mjs`, together with the
`wasi_snapshot_preview1` imports implemented by `createWasiImports` (18 WASI
functions: `clock_time_get`, `environ_sizes_get`, `environ_get`, `fd_write`,
`fd_read`, `fd_close`, `fd_seek`, `fd_fdstat_get`, `fd_fdstat_set_flags`,
`fd_renumber`, `fd_prestat_get`, `fd_prestat_dir_name`, `path_open`,
`path_rename`, `path_unlink_file`, `path_remove_directory`, `random_get`, and
`proc_exit`). The embedded factory therefore implements every `entry` import,
and a browser image needs no external WASI host and no Node.

`staticmetadata.browser_trace_image` reads each function or tag import's
signature from the type section. It refuses:

* a type form other than a function type;
* a value type other than `i32`, `i64`, `f32`, `f64`, `v128`, `funcref`,
  `externref`, or `exnref`;

`scripts/browser_stdlib.lua` provides the checks:

* `allowed_imports(allowlist, classes)` first checks its inputs: a nonempty
  list of known classes, complete rows with a provider and a reason, and one
  row per class, module and name.
* `check_imports(bytes, origin, classes)` then fails with one line per image
  import that no row of the given classes lists with the same signature:
  `<image>: unlisted browser import <module>.<name> <signature> (classes <classes>)`,
  followed by `add a reviewed row for each to scripts/browser_imports.lua`.
* `check_file_imports(strategy, image, classes)` reads the `.wasm` of one
  image, named by its `.mjs` or `.wasm`, and checks it.

The command-line form is
`lua -E scripts/check_browser_stdlib.lua imports CLASS[,CLASS...] WASM...`.

The check runs wherever the repository builds an image, with that image's own
classes:

| Where | Images and classes |
| --- | --- |
| `make titan-stdlib-browser-test`, after the closure check | `images/stdlib.wasm`: `entry` |
| `spec/browser/build-trace.lua` | the runtime, uncaught and async images: `entry,fixture:trace` (the degraded variants copy the runtime image's `.wasm`) |
| `spec/browser/build-bridge.lua` | the bridge and public-state images: `entry,fixture:controls`; `counter`: `entry,fixture:click`; `initializer-failure` and `responsive`: `entry` |
| `spec/browser/build-net.lua` | `http`: `entry`; `websocket`: `entry,fixture:net` |
| `spec/browser/build-delivery.lua` | the chapter's complete application `app`: `entry` |
| The [`browser-toolchain`](continuous-integration.md#browser-toolchain-job) runner and loader image steps | the runner images and `loader_names`: `entry`; `loader_app`, `fidelity`, and the optimized `loader_app` and `fidelity`: `entry,fixture:loader,fixture:controls` |
| `spec/support/browser_toolchain.lua` `check_imports`, called by each spec's build | bridge spec: as `build-bridge.lua`; entry gate: the `gate.c` images `entry,fixture:gate,fixture:controls`, the `entry_lifetimes.c` image `entry,fixture:controls`; scheduler: the mini driver and the scheduler owner `entry,fixture:scheduler`, the others `entry`; images spec: `entry-close` `entry,fixture:images`, the other `entry-*`, `stdio-only`, `dynamic-guards`, and real-image cases `entry`; `browser_toolchain_spec`'s exnref image: `entry`; budget probes: `entry,fixture:budget`; the documented `hello` image of the documentation gate, the archive-only consumer of `browser_protocol_spec.lua`, and the stdlib gate, fixture and minicoro images: `entry` |

The trace-adapter units of the `browser-toolchain` job link
`spec/fixtures/browser_trace_adapter/lifecycle.c` and `filter.c` directly with
`$WASI_SDK_PATH/bin/clang --target=wasm32-wasip1 -mexec-model=reactor` and the
Titan C runtime, instantiating them via `createTrace` and `createWasiImports`
from `titan-wasm-factory.mjs`. They have no Titan launcher, are not final
browser images, and are not checked.

The allowlist is a repository check, not a compiler rule: an application
image may declare its own `TITAN_WASM_IMPORT` functions and supply them via
`create({ imports })`.

## The browser entrypoint

`browserentry.contents(worker, options)` renders the persistent browser
launcher (`titan_browser_initialize`, `titan_browser_entry`,
`titan_browser_close`, `titan_browser_protected_entry`, and the shared
`titan_entry_error_message` error-conversion helpers) and the one-line weak forwards
(`titan_browser_invoke`, `titan_browser_release_callable`) to `titan.browser`'s
public foreign functions. `driver.browser_c_image_contents` is the same
boundary for protocol and test-owned C images. Options supply declarations, a
protected initializer (empty for C-only controls), a program name, and the
state-allocation status. The installed
[`titan/browser.h`](browser-bridge.md#fixed-wasm32-layout) defines the four
promised export signatures, synchronous wrapper release, shared struct layouts,
and JS imports.

The launcher also defines the calendar wrappers (`localtime_r`, `localtime`,
`mktime`) backed by `titan_browser_localtime` and `titan_browser_mktime`
(declared in `titan/browser.h`), setting `tm->__tm_zone` to a static
per-`tm_isdst` numeric offset (`+hhmm`/`-hhmm`) on every successful call so
`strftime` `%Z` never reads an uninitialized pointer. C stdio and WASI file
operations are served directly by `createWasiImports` in
`titan-wasm-factory.mjs` rather than launcher-defined `__wasi_fd_*` or
`__syscall_*` shims.

Initialization creates the owner Lua state and enters the image initializer
under the shared protected gateway. After `luaL_openlibs` and
`titan_install_searcher`, the generated Titan initializer loads and executes
`TITAN_LUA_BROWSER_PROFILE` from `titan/ffi.h`; load or runtime failure reaches
that same protected gateway before any application module loads. The chunk
replaces only stock `os.clock` and `os.exit`; independent states apply the same
chunk in their protected opener ([Lua profile](lua-library.md#browser-states-and-stock-profile)).
`titan.browser` initializes and publishes its module-owned state record in
ordinary dependency order, when linked.
Main runs once on that initialized state and leaves it live. Each promised C entry
receives a nonzero unsigned 64-bit operation id, echoes it with its expected
operation kind in exactly one completion, and returns only an admission code.
The loader waits for both completion and physical promised-entry retirement.

`argv` and `lengths` have `argc` elements, exclude the program name, and carry
byte strings; zero-length arguments need no valid data pointer. The main
worker constructs the normal string Array and calls `main(args)`, or the
existing registered bootstrap hook when enabled. Its low 32 result bits have
the documented signed application-status interpretation.

The launcher uses the fresh owner's preallocated stack; Lua C-function worker
entries receive `LUA_MINSTACK` slots. Saved stack heights bracket the pushed
handler, worker, context and results under `lua_pcall`. Error conversion has a
separate protected report without recapturing the original trace. Completion
copies rooted byte results, messages, and traces before the stack is restored,
so no separate native copy has to outlive the state.

Disposal holds the same execution owner while closing the state directly,
never by a pcall on the state being freed. The module-owned browser record
invalidates its state exactly once at its natural finalization point, after
finalizers of values created after `titan.browser` initialized. An earlier
finalizer can therefore see an invalidated state: close and release are inert,
and binding calls raise a Lua finalizer warning on stderr. The state keeps
`luaL_newstate`'s warning callback. Both libc streams are flushed before
completion; the loader owns final copied stream drainage.
Scope defers run when main returns or raises; state finalizers run at explicit
disposal.

`driver.browser_entrypoint_contents` supplies the separate initializer and
main workers: open libraries, install the Titan searcher/preloads and require
the root during initialization; retrieve the initialized module from the
ordinary loaded table and invoke main later. Native `main`/`pmain` templates
are unchanged. See [browser bridge runtime](browser-bridge.md) for the exact
C layout, state/capture roots, independent-state construction, errors, and
close admission.

## Runtime guards

The browser `libtitan.a` contains the same four runtime objects (`titan.o`,
`minicoro.o`, `titan_path.o`, and `ltitanlib.o`); no archive or image
references `dlopen`, `dlsym`, `dlerror`, or libbacktrace. Static images resolve modules through
provider symbol tables (`TitanModuleProvider.symbols`, the explicit-provider
discipline Windows also uses) and `package.preload`. `TITAN_TARGET_BROWSER`
excludes host-only discovery helpers; retained runtime entries reject operations
that require unavailable host services:

| Path | Browser behavior |
| --- | --- |
| `<dlfcn.h>` in `titan.c`, `ltitanlib.c`, `titan_path.c` | not included |
| `titan.c` `loadsym`, opaque-handle `titan_module_symbol` | `browser target symbol lookup requires an explicit provider symbol table` |
| `ltitanlib.c` `_loadlib`, `_loadlibglobal`, lazy loading | `browser target does not support dynamic provider loading` |
| `titan_path.c` provider open and ABI-checked entry lookup | `browser target does not support dynamic provider loading` |
| `titan_path.c` executable discovery (`/proc/self/exe` and its OS branches) | fails with `browser target cannot locate a host executable` |
| `titan_path.c` native compiler-root query (`titanc --print-root`) | compiled out |
| `ltitanlib.c` `SIGPIPE` guard, its restore, and the POSIX-only support functions | compiled out |
| the libbacktrace and `execinfo` trace backends | replaced by the [browser trace backend](error-handling.md#trace-backends) |

`titan.h` selects `_setjmp`/`_longjmp` under `LUA_USE_POSIX`, matching
`liblua.a`, and declares both for the Wasm build. It also defaults
`TITAN_COROUTINE_STACK_SIZE` to `(2 * 1024 * 1024)` unless overridden by the
target.

## Source-map extensions, eager loader, and stack survey

### Source-map extensions and image identity

Before compiling the per-link synthetic entrypoint,
`browsertrace.identity(context, contents, compile_flags, link_flags, groups)`
computes a 64-character lowercase hexadecimal SHA-256 identity using
`incremental.digest` under domain `"browser-trace-image"`. The hashed recipe is
canonical and acyclic: the original entrypoint C source (`contents`, before
injecting the identity declaration), the browser target descriptor identity and
exported `tools` table plus the file digests of `clang`, `wasm-ld`, and
`wasm-opt` (so replacing a tool in place changes the identity), the effective
entrypoint compile flags, the full link argv (D11 `env -u` envelope, link
flags, every link input, user link extras, and final dependency flags) followed
by the `wasm-opt` argv and `optimizer_flags`, and ordered `{ path, digest }`
groups (normalized via `linkcertificate.canonical_path` and
`incremental.file_digest`) for all user objects, provider archives,
`--c-source` extra objects, resolved `-L`/`-l` static archives
(`linkcertificate.browser_trace_libraries`), and the five runtime, Lua, and
JavaScript inputs (`libtitan.a`, `liblua.a`, `liblua-config.txt`,
`titan-wasm-factory.mjs`, and the loader source `titan-browser.mjs`). A
toolchain-only system library that the static archive resolver cannot inventory
still links: its flag text remains in the link argv hashed by
`browsertrace.identity` while the CLI marks the native link policy
uncacheable and withholds the link record and reuse. No timestamps, random
staging paths, inodes, process IDs, or intermediate Wasm digests enter the
hash. `browsertrace.declaration(identity)` then appends:

```c
static const char titan_browser_trace_image_id[] = "<64 lowercase hex>";
TITAN_WASM_EXPORT("titan_browser_trace_identity")
const char *titan_browser_trace_identity(void) {
    return titan_browser_trace_image_id;
}
```

`titan_browser_trace_identity` is exported in every Titan-entry profile and
accessed in `titan-wasm-factory.mjs` as `exports.titan_browser_trace_identity`.
Calling it returns the Wasm memory address of the 65-byte NUL-terminated ASCII
string.

After `clang` links and `wasm-opt` optimizes the image (retaining DWARF
`.debug_*` sections via `--debuginfo`), `browsertrace.dwarf_map(wasm, map_name,
origin)` parses DWARF `.debug_line` in pure Lua against the final stripped
`CODE` payload base (handling `.debug_*` sections even when they appear before
`CODE`, reading code-section body bounds to resolve overlapping `wasm-ld
--wrap` line sequences so only a body's sole own sequence ending at the body
end survives while ambiguous overlaps and backwards sequences stay unmapped,
and emitting one-field unmapped segments at every DWARF `end_sequence` and
`line == 0` row so unmapped instructions inside a body are never attributed to
a preceding line), strips every `.debug_*` and any existing `sourceMappingURL`
section, appends the new length-prefixed `sourceMappingURL` custom section
(`<basename>.wasm.map`) as the image's last section after `name`, and produces
`stripped_wasm` and `map_json`.
`browsertrace.rewrite(stripped_wasm,
map_json, identity, origin)` then reads `stripped_wasm` through
`staticmetadata.browser_trace_image` (which reuses the bounded section and
LEB128 reader primitives in `staticmetadata.lua`, accepting valid bounded
padded LEB128 encodings and rejecting duplicate or out-of-order sections,
duplicate `name` sections/subsections, overrunning lengths, invalid UTF-8, or
mismatched function/code counts), validates `map_json`, splices Titan's four
`x_titan_*` extension keys into the source map, and returns the extended map
bytes and binary [trace table](#the-trace-table) bytes for the driver to write
to `<stem>.wasm.map` and `<stem>.wasm.trace`:

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
  symbolization reads the same names from the [trace table](#the-trace-table),
  so it works identically when the `name` section is stripped.

### Module and Wasm binding

`create(factory, options, image)` first requires `image` to be the generated
module's binding, `{identity, wasm, directory}` with a 64-digit lowercase
hexadecimal identity, a `.wasm` name, and a base directory URL, and throws a
`TypeError` otherwise. `BrowserOwner.instantiate` reads the instantiated
Wasm's `titan_browser_trace_identity()` string right after the factory resolves
and checks for Titan channels; a module without that export fails the channel
check (`browser image does not provide Titan channels`). It compares the
string with the identity that the generated module passed to `create`. A
difference throws
`failure('PROTOCOL', 'browser image mismatch: <stem>.mjs belongs to image
<12 hex>, <stem>.wasm is image <12 hex>')`, which poisons the owner before any
entry, whatever `requireTrace` says: a module wrapper generated for another
link is never safe to run. A trace table from another link stays a
degraded-trace condition ([eager trace loader](#eager-trace-loader-and-trace-metadata)).

Only the host sees both identities, so the comparison is loader JavaScript;
Titan code never runs before it.

Publication renames the trace table, the map, the `.wasm`, then the `.mjs`.
The runtime never reads the map, so an interruption can leave only two kinds
of mixed sets:

| Interrupted after | Files | Outcome |
| --- | --- | --- |
| the table or map rename | new table (and map), old `.wasm` and `.mjs` | degraded trace, or the `requireTrace` initialization failure |
| the `.wasm` rename | new table, map and `.wasm`, old `.mjs` | the protocol failure above |

The warm-link check relinks either set.

### The trace table

`browsertrace.rewrite` derives `<stem>.wasm.trace` from the same validated walk
of the final map's segments that binds the map's extensions, so the runtime
reads a few compact arrays instead of parsing the map. A row starts where the
location of the code inside a defined function body changes: to a `.titan`
source line, or to a gap, which is an unmapped segment or a non-`.titan`
source such as C the optimizer inlined into the body. Each body starts in a
gap, the last of several segments at one offset wins, consecutive equal
locations share one row, rows never cross a body boundary, and segments outside
every body are dropped. A lookup that takes the last row at or before an
offset inside its body therefore sees exactly what the map's segments say
there. A body's declaring basename is that of its first `.titan` row, and the
table lists only the basenames of `.titan` rows, deduplicated (at most 32,767:
`too many Titan source names for the trace table`), so a segment that a later
one at the same offset replaces names nothing. The table also lists every
function name, imports first, empty when the name section has none. The
reader refuses rows that do not ascend and `.titan` rows without a line.

The layout is little-endian, every 4-byte array starts 4-byte aligned, and the
size is exact:

| Offset | Field |
| --- | --- |
| 0 | magic `TTRC` |
| 4 | u32 format version, 1 |
| 8 | the 64-character image identity |
| 72 | u32 function imports `I` |
| 76 | u32 defined bodies `B` |
| 80 | u32 rows `R` |
| 84 | u32 basenames `S` |
| 88 | u32 string bytes `T` |
| 92 | u32 `[B]` body start gaps, each from the previous body's end (the first from 0) |
| | u32 `[B]` body lengths |
| | u32 `[R]` row offset deltas |
| | u32 `[R]` row line deltas modulo 2<sup>32</sup>; a gap row repeats the previous line, so its delta is 0 |
| | u32 `[S + I + B + 1]` string offsets: basenames, then function names |
| | i16 `[R]` row basename index, -1 for a gap |
| | i16 `[B]` body declaring basename index, -1 when the body has no `.titan` location |
| | `T` bytes of UTF-8 strings |

`browsertrace.trace_table(map_bytes)` derives the same table from a final map,
which keeps the `x_titan_*` extensions as the readable form of the same
binding: developer tools ignore them, and tests and tools read function names
and ranges from them. The trace-gate builder makes its `missing_symbols`
variant this way.

Measured historically on Emscripten 6.0.13 images with Node 26.13.1 (current
maps are DWARF-derived). The map loader that the table replaces took 141–157 ms
on hello and 681 ms on the standard-library aggregate:

| Image | Rows | `.wasm.map` brotli bytes | `.wasm.trace` bytes / brotli | Read |
| --- | ---: | ---: | ---: | ---: |
| validation trace-gate runtime image | 363,566 | 321,184 | 4,245,930 / 221,340 | 1.6 ms |
| production hello | 401,750 | 397,757 | 4,504,015 / 219,249 | 1.9 ms |
| validation standard-library aggregate | 1,229,731 | 865,996 | 14,300,264 / 640,993 | 6.2 ms |

`browsertrace.rewrite` takes 0.63 s on the trace-gate runtime image and
2.29 s on the standard-library aggregate, of which the same parse and walk
without the table writer take 0.49 s and 1.70 s: the table costs those links
about 0.14 s and 0.6 s.

### Eager trace loader and trace metadata

During instantiation, `titan-wasm-factory.mjs` fetches `<stem>.wasm` and
`<stem>.wasm.trace` concurrently through `owner.options.locateFile(name,
owner.image.directory)` (`fetch(path, {credentials: 'same-origin'})` in
browsers, failing with `trace table request failed (<status>)`, and
`fs.promises.readFile` via `process.getBuiltinModule('node:fs')` for local
paths and `file:` URLs in Node; if `locateFile` throws while resolving the
trace file, the error degrades the trace rather than failing initialization)
and passes the promise to `createTrace(views).load(bytesPromise, identity)`.
`readTable(data, identity)` compares against
`readCString(exports.titan_browser_trace_identity())` and checks only what the
bytes could get wrong: the magic and version and the exact size (`invalid trace
table`), the identity (`trace table image does not match`), and every body
bound, row offset and order, basename index, `.titan` row line, and string
offset. It copies a table whose bytes are not 4-byte aligned, decodes the
deltas into absolute `pcs`, `lines`, `starts`, and `ends` arrays, decodes the
basenames, and decodes a function name only when a frame needs it
([Browser trace backend](error-handling.md#browser-trace-backend)). It then
publishes the result on `context.trace`:

```text
{ state: 'ready' | 'degraded', reason: string | null,
  traceBytes: number, loadMilliseconds: number, indexBytes: number }
```

`traceBytes` is the byte length of the fetched table, `loadMilliseconds`
measures the elapsed time (`performance.now()`) from request/read start through
index readiness, and `indexBytes` is the retained table plus the four decoded
arrays (not total JavaScript heap usage; `0` when degraded). When the table is
missing, malformed, or from another link, `state` is `'degraded'`, `reason`
records the failure, and one `console.warn('Titan browser trace: ' + reason)`
is emitted at load time. Embeddings default to permitting degraded mode.
With `requireTrace: true`, `BrowserOwner.initializeEntry` checks the public
trace snapshot after factory readiness, before its first Lua initialization
entry. It saves an ordinary initialization failure with status 1 and message
bytes, but no Titan trace because Lua was never entered. The runner and
Playwright shared page pass `requireTrace: !allowDegradedTrace`; no wrapper
owns another lifecycle or admits a gap between initialization and main.

### WebAssembly stack survey

The stack parser and WebKit renderer follow the engine-specific Wasm stack
formats verified across V8 (Node and Chromium), SpiderMonkey (Firefox), and
JavaScriptCore (WebKit and Safari). The [capture contract](error-handling.md)
follows the JSPI runtime and current-engine tests:

1. **V8 (Node, Chromium, Chrome)** formats frames as
   `    at <module>.<func> (<url>:wasm-function[<N>]:0x<PC>)` when the `name`
   section is present and `    at <url>:wasm-function[<N>]:0x<PC>` when
   stripped (`wasm://wasm/...` in Node, `http://...` in Chromium/Chrome),
   preceded by an `Error: ...` title line. Both carry the decimal function
   index `N` and module-relative hexadecimal byte offset `0xPC`.
2. **SpiderMonkey (Firefox)** formats frames as
   `<name>@<url>:wasm-function[<N>]:0x<PC>` (with an empty `<name>` when
   stripped) and no `Error` title line. After suspension, Firefox appends saved
   asynchronous ancestry starting at cause markers (`async*`, `VoidFunction*`,
   `promise callback*`, `setTimeout handler*`). The parser stops before any
   saved-JavaScript-parent cause boundary rather than retaining saved Wasm
   callers past it.
3. **JavaScriptCore (WebKit and Safari)** formats named frames as
   `<func>@<image>.wasm:wasm-function[<N>]` and stripped or cold frames as
   `<N>@wasm-function[<N>]`, with no `Error` title line and no bytecode offset
   `0xPC` (cold runs may mix both forms in one trace). The bracketed decimal
   function index `[<N>]` resolves through the trace table and `TITAN_NAMES_KEY`
   to the Titan display name and declaring `.titan` basename for no-line
   rendering.
4. **Active-chain order and fibers.** Across all engines, the active Wasm call
   chain is ordered youngest-first. Inside a minicoro fiber, the physical stack
   starts at the exported `titan_mco_entry` → `_mco_main`; the resumer's native
   frames are supplied by the coroutine trace handoff.
5. **Depth limits.** Default `Error.stackTraceLimit` is 10 on V8, 100 on JSC,
   and absent on Firefox; temporarily raising the descriptor captures deeper
   stacks on V8 and WebKit 27.2+, while Firefox's 128-frame synchronous ceiling
   marks truncation.
6. **JS wrapper headroom.** Requesting 640 frames (512 Wasm capacity + 128
   headroom for interleaved JS wrappers) covers normal overhead, and the
   adapter conservatively marks any capture reaching the effective limit as
   truncated.

## Budgets

Linear stack and heap sizes are explicit image/SDK identity inputs:

| Resource | Setting | Ownership |
| --- | --- | --- |
| Main linear C stack | `-Wl,--stack-first -Wl,-z,stack-size=1048576` | the root entry's address-taken locals and Lua/Titan protected-call data |
| Coroutine linear C stack | `-DTITAN_COROUTINE_STACK_SIZE=262144` | one disjoint minicoro allocation; native default remains 2 MiB |
| Linear memory | `-Wl,--initial-heap=15728640 -Wl,--max-memory=2147483648` | initial memory is static data, the main stack and a 15 MiB heap; freed blocks can be reused but the grown Wasm heap never shrinks |
| Engine continuation stacks | JSPI engine-managed | not bounded by the linear C-stack sizes |

Initial memory is the image's memory-section minimum: `wasm-ld` places the
1 MiB main stack first (`--stack-first`) and static data above it, then adds
the 15 MiB `--initial-heap` to that heap base, rounded up to a 64-KiB page.
Using `--initial-heap` rather than a fixed 16 MiB `--initial-memory` ensures
large images (such as the full browser stdlib test suite, whose static data
plus stack exceeds 18 MiB) always link and start with a full 15 MiB heap.

`wasm-opt --stack-check` instruments every stack-pointer write to check against
bounds programmed through `__set_stack_limits`. Each coroutine switch checks
the outgoing context's stack cookie, saves SP and bounds, then programs the
destination bounds before restoring SP. A new coroutine stack receives a
two-word cookie at its low end; the main stack has none because its low bound
is `0` under `--stack-first`. Memory views are never retained across memory
growth.

`browser_budgets_spec.lua` measures checked root/coroutine C-stack limits,
engine-stack limits with live Wasm-register canaries across JSPI waits and
transfers, the catchable Lua C-call limit, forced native allocation failure,
and the delivered 2-GiB heap boundary. `budget.c` reads the stack bounds the
factory installed and the live `__stack_pointer` (plus the two words at the low
bound) through the `fixture:budget` import `env.budget_stack_state`
(`fixture-imports.mjs`). The parked canary must remain usable before exhausted
owners are released, and fresh coroutines must work after collection. Native
allocation failures can be ordinary errors; an engine trap or JS allocation
failure poisons the instance instead of pretending that native cleanup or
continuation reuse is safe.

For each boundary row, the harness checks a positive lowest sample and
qualifies its declared, unit-aligned ceiling with the same limit-failure
classifier used for the final result. It then binary-searches to adjacent
units and attributes the final failing sample. Every probe starts a fresh
instance. The `lua-limit`, `create-failure`, and `exhaust` modes run once per
engine, without a search. Two cookie probes follow the seven
rows: `cookie-boundary` (verifying no cookie at the main stack's zero low bound
and an intact coroutine cookie across a switch) and `cookie-overwrite`
(requiring abort status 70 and `Stack overflow! Stack cookie has been
overwritten at 0x…`). The verdict line reads `rows=7 cookie_checks=2`.

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
`lua_defines=-DLUAI_MAXCCALLS=100 -DLUA_USE_BROWSER -DLUA_USE_OFF_T
-D_WASI_EMULATED_PROCESS_CLOCKS -Dl_signalT=int` under the
`# Lua 5.5.1 browser build record v2` banner and closed key set.
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

`LUAI_MAXCCALLS` must be above 10 (otherwise `LUAI_MAXCCALLS / 10 * 11` is 0
and every overflow escalates to error-in-error-handling), at least 20 in
practice so overflow handling and the two reserved finalizer slots stay
usable, within 16 bits, and at most half the lowest measured engine ceiling.

Under the pre-Wasm-EH JavaScript-SJLJ lowering, the lowest measured ceiling
was 204 counts (201 levels) for nested `pcall` and `coroutine.resume` on V8
(Node and Chromium) in validation mode, giving a chosen limit of 100 (~2.04×
headroom, whereas Lua's default 200 left ~1.03× margin). That limit is
retained until recursive Lua/C shapes are requalified across engines and
profiles under Wasm EH and JSPI. The historical per-engine ceiling table is
archived in [retired evidence
records](benchmark-archives.md#retired-evidence-records).

### Engine stack per construct

Each recursive Lua/C construct consumes one `getCcalls` count per level, but
protected calls (`pcall`, `coroutine.resume`) consume roughly 1.7× as much
engine stack per level as plain mixed Lua/Titan recursion because of their
extra `luaD_rawrunprotected` and error-handling frames. Wasm EH eliminates
the JavaScript `invoke_*`/`dynCall_*` SJLJ trampoline that previously drove
per-level stack cost up to ~4.9 KB on Node validation builds. Full historical
per-construct byte slopes and pre-cutover pass experiments are archived in
[retired evidence records](benchmark-archives.md#retired-evidence-records).

### The regression

`spec/fixtures/browser_trace/trace_cases/limits.titan` holds three rows:

* `test_mixed_recursion_headroom` recurses 90 mixed levels, below the 95
  (`LUAI_MAXCCALLS - 5`) that this fixture's accounting leaves room for, and
  must keep at most 91 `mixed_recurse` frames with at most one truncation
  marker.
* `test_mixed_recursion_overflow` and `test_pcall_recursion_overflow` recurse
  toward a bound of 150 (above Lua's limit of 100 and below engine ceilings)
  through `@trace-shape.lua` and `@trace-pcall.lua`. Each must catch
  `C stack overflow` with a real capture and return normally.

The loader still reports a real
engine failure with its `cause` ([Settlement](#the-loader)); the C-call limit only keeps Lua's
recursion from reaching one.

### JSPI and protected calls

Wasm-EH longjmp keeps protected-call frames inside Wasm while a JSPI import
suspends. It does not catch engine traps or change the conservative
`LUAI_MAXCCALLS=100` browser policy.

## Completion and output channels

`titan-wasm-factory.mjs` owns one per-instance `context` and JSPI execution
owner (`context.bridge.backend`) per instantiated WebAssembly module. Import
validation belongs to the loader's `importTable` (`create()` for the object
form, `owner.userImports(context)` for the function form, refusing non-plain
objects and any override under `wasi_snapshot_preview1.*`,
`env.titan_browser_*`, or `env.titan_mco_*`). `instantiate(owner)` merges the
validated user imports with the runtime imports, fetches `.wasm` and
`.wasm.trace` concurrently, checks required exports (`memory`, `_initialize`,
`__stack_pointer`, `__stack_low`, `__stack_high`, `__set_stack_limits`,
`malloc`, `free`, `titan_browser_trace_identity`,
`__indirect_function_table` — refusing a missing required export with
`TITAN_BROWSER_PROTOCOL`), programs the main stack bounds, and resolves the
context with the trace indexed and C constructors not yet run. The loader then
attaches the context, verifies the Titan channels (including `_initialize`) and
the image identity, and only then calls `exports._initialize()` once, so
constructor output reaches an attached owner and a mismatched image runs no C.

**Completion.** `titan_browser_complete(pointer)` passes the
[completion record](browser-bridge.md#fixed-wasm32-layout) to the loader
owner, which validates its operation identity and kind against the pending
entry and copies its results, message, and raw trace with `HEAPU8.slice`
while C still owns and roots them. This record alone owns application status
and values. The promised export's fulfillment proves engine retirement, not
Titan success: the loader waits for both and never substitutes a promise
value or process exit state.

**Output.** C stdio writes reach `wasi_snapshot_preview1.fd_write`, which
forwards one entry per nonempty iovec for descriptors 1 and 2 to
`owner.output`; the loader copies the bytes before the import returns. Entries
from one call are adjacent; C chunk boundaries are not a contract. C stdin
(`fd_read`) fails with `ENOSYS`, without prompting. No user sink or unrelated
notification runs during an internal coroutine transfer, including a collector
finalizer's cleanup. `safe()` means that the contained C entry has released its
owner. Every sink call starts either from the operation's final flush, after
its whole logical operation retires, or during a drive while the drive is
parked on a relinquish gate ([output, disposal, and
observation](#output-disposal-and-observation)).

### JSPI coroutine contexts

The WebAssembly branch in `minicoro.h` (`#if defined(__wasm__)`) retains
minicoro's SELF/BACK routing, tag comparator, stacked-handler state
transitions, transfer storage, and native unwind protocol. `titan_mco_create`,
`titan_mco_transfer`, and `titan_mco_destroy` are `env` imports, and
`titan_mco_entry` carries `TITAN_WASM_EXPORT`. A context owns one disjoint
linear C stack and a JS record keyed by its allocation address. The record
holds saved SP, base/end bounds, one lifetime promise, a parked gate, and its
BACK identity. Promises do not replace Lua's transfer-uservalue roots.

`titan_mco_transfer` and `titan_mco_destroy` are explicit `WebAssembly.Suspending`
imports. First activation invokes the `WebAssembly.promising`-wrapped
`titan_mco_entry`; subsequent activation resolves the existing gate. Both sides
suspend, preserving the C-visible rule that `mco_resume` returns only when its
selected target yields or finishes. Tagged yield activates the selected
handler's BACK directly; intermediate stacked contexts remain parked. Before
every continuation runs, the factory checks the outgoing context's stack cookie
and saves SP and bounds (skipping cookie reads and writes when `low === 0`, the
main stack), then programs the destination bounds via `__set_stack_limits`
before restoring `__stack_pointer`, and restores parked contexts on both
resolve and reject. Engine stacks are separate from those linear allocations.
Inside a [synchronous C callback](browser-bridge.md#synchronous-c-callbacks),
or with no promising entry holding the owner, `titan_mco_transfer` and the
suspending path of `titan_mco_destroy` poison instead of switching; destroying
a never-started or finished context does not suspend and stays legal there.

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

`TitanBrowser.enter(call, id, kind)` is the internal hook for each contained
C entry. It acquires the execution owner before invoking a promised Wasm
export, installs the pending `{id, kind}` record, and keeps the owner through
all internal microtasks, collector cleanup and terminal handoffs. Another
entry while the owner is held rejects with `TITAN_BROWSER_REENTRY`, `browser
instance is active; reentry is not allowed`; a blocked or poisoned owner
rejects with its saved terminal failure or `TITAN_BROWSER_DISPOSED`. No
lifetime counter refuses later entries: the loader's [logical
operations](#logical-operations-and-protected-entries) decide which entries a
public method contains. `titan_browser_entry_allowed(id, kind)` normalizes the
unsigned identity and admits the C preamble once, only for the pending
identity and kind; JSPI continuation wakes do not re-enter that preamble.

Initialization wraps the four promised state-entering exports
(`titan_browser_initialize`, `titan_browser_entry`, `titan_browser_invoke`,
and `titan_browser_close`) and the gate's `titan_browser_gate_guarded` with
`WebAssembly.promising` and this hook inside `titan-wasm-factory.mjs`. The
factory keeps `context.exports` mutable so test harnesses can inject allocation
and release faults at call time; `titan_mco_entry` always rejects outside
reentry. C-only state-neutral exports (`malloc`, `free`, the trace identity,
and the gate observer) remain synchronous, as does the no-switch
wrapper-release export.

`poison(cause)` permanently blocks admission, rejects known parked engine
gates, and poisons the loader owner after a fatal error. It never calls C to
free or reuse compromised allocations. An external import can remain
unresolved after abort; disposal drops the unusable instance instead of
claiming normal cleanup.

### The relinquish import

`titan_browser_relinquish(state, mode)` is the suspending import for a
[drive](browser-bridge.md#drive-interface-and-delivery). The factory half
poisons with
`TITAN_BROWSER_PROTOCOL` (`"Titan stack switch outside a promising entry or
inside a synchronous callback"`) when no promising entry holds the execution
owner, when a [synchronous C callback](browser-bridge.md#synchronous-c-callbacks)
runs (it then throws to the callback's caller), or when the main context is
not current (`TitanBrowser.current !== 0`). Otherwise it hands the call to
the loader owner. `titan.browser` has already required the owner's main
thread, an active drive and no delivery in progress, and the loader does not
test those again.

The loader owner decides in this order:

1. **Disposal.** Disposal is signalled once: the first relinquish after
   `dispose()` began (or a gate parked when it began) resolves `DISPOSING`
   after one turn.
2. **A turn.** `TURN = 0`, or any wait while an owner item is queued, parks a
   gate and schedules one turn-source macrotask.
3. **Nothing to wait for.** `WAIT = 1` with no loader wake source returns
   `IDLE` as a plain number, so JSPI does not suspend; the terminal
   `titan_mco_transfer` path already relies on that.
4. **A wait.** Any other wait parks a gate until a wake. `WAIT_HELD = 2`
   never returns `IDLE`: `titan.browser` passes it while the state has an
   open `BrowserPin`, a wake source that only Titan knows about.

A gate is created synchronously inside the import, so a wake can never fire
before it exists. Every resumption resolves the gate from the turn source,
never directly from a microtask, with `DISPOSING` once disposal began and
`RESUMED` otherwise.

Outside disposal, every branch that parks a gate also schedules both output
pumps on a microtask, so sinks run once the drive has suspended, never
inside the import, and only while that gate is still parked. A numeric
`IDLE` schedules none, so the coroutine switches of orphan unwinding that
may follow it never meet a sink.

The turn source is `setImmediate` where the host defines it (Node) and
otherwise one `MessageChannel` per instance, created on first use; neither
clamps nested delays the way `setTimeout` does. Its handler is a module-scope
function bound to the owner's detachable turn cell, which disposal clears
before closing the channel. Wakes coalesce into the one scheduled macrotask.
A poisoned owner never resolves a gate: the suspended Wasm stack is dropped
with the image.

## The loader

`titan-browser.mjs` is a compiler/SDK input, not a deployment import. Its
`create(factory, options)` implementation is enclosed in each generated image
by `browserlink.embed` beside `titan-wasm-factory.mjs`; the image exports only
default `create(options)`. There is no public raw Wasm factory, instance,
memory view, or separate loader entry point outside a caller's `create({ imports })`
factory callback. The source has no Node-specific imports.

`create` validates `env` and builds its `NAME=value` string array once from the
object's own enumerable string-named properties. The owner keeps only that
snapshot in its private options, not the embedding's mutable environment
object. `createWasiImports` exposes that array through
`wasi_snapshot_preview1.environ_sizes_get` and `environ_get`, sizing and
writing UTF-8 bytes into `wasi-libc`'s environment. C `getenv` and Lua
`os.getenv` share that environment; C mutations stay in the instance. `TZ` does
not change host-derived local time.

User `create({ imports })` namespaces are validated for own module/name pairs
(rejecting any `wasi_snapshot_preview1.*`, `env.titan_browser_*`, or
`env.titan_mco_*` entry with `TypeError`) and copied into fresh null-prototype
maps before instantiation.

`BrowserOwner` owns persistent lifecycle and public admission. The frozen
public object exposes `initialize`, `run`, `call`, `callTask`, `notify`,
`drain`, `dispose`, and a read-only frozen trace snapshot. General entry
methods reserve logical
admission synchronously and return promises even for state, reentry, and
disposal errors. Only notification admission and logical release are
synchronous. A call's C buffers use the documented plain alloc/free exports;
current `HEAPU8`/`DataView` objects are derived after allocations, never kept
across memory growth.

Lifecycle is `created → initializing → ready ⇄ active → disposing → disposed`,
with a poisoned terminal state. Initialization creates and initializes Lua
without main and is memoized. Ordinary initializer errors retain their copied
completion for one later failed/status1 run result and never print twice.
Main alone is one-shot. Its defers run at return, but the state and callbacks
remain available until explicit disposal.

`requireTrace` defaults to false. Its pre-Lua readiness check belongs to the
same memoized initialization and automatic `run` path. A refusal writes
`degraded browser trace: <reason>` and a newline to the stderr queue once and
saves a failed/status1 record with those message bytes and no trace. The first
`run` returns that saved result and consumes main's single attempt; the Module
remains disposable without ever creating Lua. The map run dependency has
retired before the factory resolves, so this check neither fetches again nor
adds another asynchronous admission boundary.

### Logical operations and protected entries

The loader holds one logical operation from validation and marshaling through
all contained C entries and stream flush.
`TitanBrowser.enter` owns each promising C entry, including all private JSPI
and collector transfers. Its per-entry `entered` flag resets for the next
contained entry; no lifetime completion counter blocks later entries.

Every promising C entry receives the next nonzero instance-local uint64 BigInt
identity, and so does each item that a drive delivers. The admission import
normalizes Wasm's signed i64 presentation back to unsigned before comparison.
One allocator, `nextOperationId`, hands the identities out and keeps the
final one for close. When the others are used up it throws
`TITAN_BROWSER_STATE` without incrementing the counter. Admission itself does
not test for exhaustion, so a method that allocates no identity still works:
`notify` enqueues, and a `drain()` with nothing to deliver succeeds. A
delivered item takes its identity before its arguments are marshalled.
The pending record has that identity, the expected operation kind, and one
completion slot. The non-suspending completion import validates identity and
kind and copies all result/error/trace data while C owns it. Duplicate,
mismatched, or missing completion poisons the image. The export promise
acknowledges physical context retirement only; its numeric value is never
application status. Neither completion arrival nor an intermediate safe point
reopens public admission. Only a drive's parked relinquish gates start sinks
inside an operation ([drives](#drives-the-call-queue-and-wake-sources)).

Only close is reserved. Disposal's `async` shutdown is an ordinary `invoke`,
and its cleanup drive delivers items with ordinary identities, so no fixed
reservation could guarantee that cleanup completes. After exhaustion,
`retireOwner`'s shutdown attempt fails at allocation without entering Wasm;
close still runs with the reserved identity, and `dispose()` rejects with
that `TITAN_BROWSER_STATE` failure. Reaching that point takes 2^64 - 2
operations.

`invokeTarget` boxes the single decoded result as `{value}` inside `operate` so
that internal operation completion, `this.active` release, and `dispose()`
never await a `Promise` or thenable returned in a `BrowserHandle`. Public
`call` and wrapper `call` unwrap `.then(box => box.value)`, resolving to the
bare value (`null` for `is_nil()`, `BigInt` for `is_integer`, string for
`is_string`, `Uint8Array` for `is_bytes`, and the underlying value for
`is_handle`).

Callable wrappers have module-private WeakMap brands and state/slot/generation
records. `release()` marks the record released and removes it from the
callable table, which invalidates the wrapper for every later use. Then,
unless the instance is disposing or poisoned, it calls the synchronous export
`titan_browser_release_callable`. That call is not an operation: it has no
identity, no completion, and no notification error, and the loader ignores
the status it returns. [Synchronous wrapper
release](browser-bridge.md#synchronous-wrapper-release) describes the Titan
side, including the collector stop and what a refused release leaves behind.

A detached FIFO batch revalidates both its target and every branded argument
before any Wasm allocation. A released target drops the notification. A
released argument is a marshalling failure: a plain notification reports it
through `onNotificationError` without entering Lua, and a request event
becomes the request's failure event ([request
boundary](browser-bridge.md#request-boundary)). State-close notification
invalidates every callable, notification, request, and JS slot charged to that
state, including close-phase slots created without Lua finalizer registration.

`drain()` detaches one FIFO batch of notifications under one logical
admission; queued calls stay behind. Each callback has a unique protected
entry and original error completion; one failure does not suppress later
callbacks. Imports append to the next batch. `requestDrain` is coalesced only
after the whole logical operation, including sinks, retires, and announces
only queued notifications. `drain()` installs no scheduler or fairness
policy.

A host invocation in flight (a binding's synchronous call, a listener's
`subscribe`, a request `cancel` or `unregister`, or a sink call) increments
`inHost`. `admission()` rejects `TITAN_BROWSER_REENTRY` while `inHost > 0`
independently of an active operation, so a reverse entry from such code is
refused even on an idle instance. A general entry starts in a microtask after
the requesting method returns, never synchronously inside it.

### Drives, the call queue and wake sources

A drive is a span of one logical operation (its entry hosts the driver)
between `titan_browser_host_drive_begin` and `titan_browser_host_drive_end`.
The loader records the owner state token from `titan_browser_host_owner`.
`titan.browser` enforces drive ownership and order before reporting each
transition; the loader holds the drive's host gate without repeating those
checks.

- **Admission.** While a drive is active, `call()` and `callTask()` made with
  no host invocation in flight are queued as `{kind: 'call'}` items in the
  owner's FIFO, beside notifications and request events, and wake the driver;
  calls and notifications for another state reject or throw
  `TITAN_BROWSER_REENTRY`. Every other method keeps its admission. After an
  exit, every application method rejects (`notify` throws)
  `TITAN_BROWSER_EXITED`.
- **Delivery.** `host_batch` moves the owner's items present now into the
  current batch. `host_item` revalidates each item as `drain()` does, assigns
  it a fresh identity from the operation counter, marshals its arguments, and
  writes the delivery record. `host_settle` validates that identity and
  copies the completion as `receiveCompletion` does; it reports a
  notification's failure as a callback error, and it settles a plain call's
  promise there and then. `host_item_done` frees the item's allocations and
  unadopted temporaries.
  - *Items that cannot be marshalled.* A call's promise rejects with the
    marshalling error. A request's success event becomes its failure event,
    appended to the live queue. A request's failure event is reported through
    `onNotificationError` and handed to Titan as `UNDELIVERED`, with the
    target identity and nothing else, so that Titan can drop a one-shot's
    holds ([request holds](browser-bridge.md#request-holds)). A plain
    notification is reported and skipped.
  - *When the awaiting code runs.* A queued call's promise settles while the
    drive is still inside its turn. Its continuation runs at the next
    microtask checkpoint, which is never under a Wasm frame but can fall
    between two internal coroutine hops of the same turn. A call made from
    that continuation is queued for a later turn.
  - A call queued too late for the drive's last batch runs at the next safe
    point as an ordinary call.
- **Wake sources.** A waiting relinquish stays parked while the owner has a
  queued item, an open request or listener, an open `BrowserPin`, or an
  already scheduled wake; a JS call that might come later does not count. The
  loader knows all of these except the pins, which `titan.browser` counts and
  reports with the wait itself, as `WAIT_HELD`. Every enqueue of an owner
  item, `dispose()`, and `titan_browser_host_wake` schedule the one coalesced
  turn-source macrotask that resolves the parked gate ([relinquish
  import](#the-relinquish-import)). `titan.browser` calls `wake` when the
  owner's last pin closes, so the gate resumes with `RESUMED` and the drive's
  next wait finds out whether a wake source remains.
- **Synchronous C callbacks.** A C callback that enters Titan through
  `titan_browser_call_sync` is not an operation and takes no admission.
  `callbackAdmit`, behind `titan_browser_host_callback`, admits it unless the
  instance is closing, exited or poisoned, during a drive or not.
  `callback_state` has already required an open, configured state.
  JavaScript reached from the callback
  gets ordinary admission: a binding the callback's Titan code calls counts
  in `inHost`, so reverse entries there reject `TITAN_BROWSER_REENTRY`, and an
  entry requested anywhere else starts in a microtask after the callback's
  synchronous chain returns.
- **Task-form calls.** `callTask` validates that the callable belongs to the
  owner state and that the owner registered `titan:driver`, then invokes the
  registered spawn callable with `[callable, settleFn, ...args]`, where
  `settleFn` is a loader function passed as a handle. It receives
  `("started", cancel)`, then one of `("succeeded", value)`,
  `("failed", message, trace)` or `("cancelled", reason)`. An `AbortSignal`
  listener, a module-scope function over a detachable cell, queues one
  notification of `cancel` with `String(signal.reason)`; settlement removes
  it and releases the cancel wrapper. On an idle instance the spawn entry
  itself drives, and its failure wins over a stored outcome. During a drive
  the spawn call is queued, and its promise settles in one of three ways:
  - a spawn entry that fails rejects the promise at once;
  - an outcome that arrived before the spawn entry returned settles the
    promise when that entry returns;
  - otherwise the call waits in `openTasks`, and its outcome settles the
    promise when it arrives.

  Plain calls never enter `openTasks`, and a relinquish settles nothing.
- **Exit.** `host_drive_end` with an exit status latches `exited`. `run()`
  then reports `exited` unless its completion failed, and a call or Task-form
  call whose own entry hosted the exiting drive rejects
  `TITAN_BROWSER_EXITED`. Among the calls queued into that drive, those that
  already settled keep their results, including a Task-form call whose Task
  finished before the exit. The rest reject `TITAN_BROWSER_EXITED`: calls
  that the drive never delivered, and Task-form calls whose Tasks had not
  finished.
- **Main failure.** `titan_browser_host_main_failed(state, message, length,
  trace, length)`, the import behind `browser.main_failed`, copies both byte
  ranges onto the active operation's token when that operation is `run` and
  the state is the owner, and ignores the call otherwise. `runResult` then
  resolves, in order: a failed completion as `failed`, the exit latch as
  `exited`, the mark as `failed` with status 1 and the copied message and
  trace, and otherwise `returned`. Every result carries `bytes` and `trace`,
  empty unless failed.
- **Disposal.** `dispose()` settles every unsettled queued call, including
  `openTasks`, with `TITAN_BROWSER_DISPOSED` and drops application notifications.
  A call that already settled keeps its result. With a drive active, or a
  registered `titan:driver` to clean up and no exit, it keeps the owner state's
  request events and lets new owner settlements keep queueing until the cleanup
  drive ends, deferring request cancellation to that point; `newRequest`
  still refuses new host work with `DISPOSED`. A parked drive is woken with
  the one-shot `DISPOSING`. `retireOwner` awaits the active operation; when
  no drive ran since disposal began, it invokes the registered shutdown
  callable under a `dispose` operation that defers its output to the final
  drain. Then it cancels every remaining request, awaits their terminal
  settlement, and runs the close entry as before.
- **Abort.** Poison rejects every unsettled call, including `openTasks`, the
  current batch and the item in delivery, with the saved failure and drops
  the drive; its gate is never resolved.

### Host owners and detachable continuations

Potentially throwing bridge imports catch at their own boundary and fill the
shared header's status/message/exact-thrown-handle response. Titan raises only
after normal import return. Trusted adoption, release, and state invalidation
remain nonthrowing. Binding call results marshal by runtime type into
`BrowserValue`; a returned Promise becomes `is_handle(BrowserHandle)` and the
bridge does not handle its rejection on the application's behalf.

Requests declare detachable or guaranteed-terminal retained ownership.
Listeners declare subscription/unregistration and enqueue synchronous events.
Cancellation closes application delivery, but retained ownership persists
until actual terminal settlement. Promise/listener continuations are
module-scope functions capturing only a narrow mailbox cell; detachment clears
the cell's sole link to the live owner. Late and duplicate settlements cannot
enter Lua. Disposal permits retirement, never application callbacks into a
released or closed state.

The request's state-owned slot is reserved before invoking a start or listen
source. An identity-allocation refusal therefore accepts no host work. Setup
failure releases the unreturned unit; an already accepted retained operation
still owns its terminal retirement even if cancellation reports an error. C
output needs no request unit.

The loader keeps no account of the callables that a request holds.
`titan.browser` owns those holds and decides when they drop ([request
holds](browser-bridge.md#request-holds)). The loader's part is to drop a
cancelled request's queued events, including the settlement of a one-shot
that settled before the cancel, and to hand an undeliverable failure event
back to a drive.

Every request has both a success target and a mandatory failure target.
One-shot `start` settlement enqueues one argument (the settled value marshalled
by runtime type, with `undefined` mapped to `is_nil`), `listen` emissions
enqueue each emitted argument by runtime type, and Promise rejection queues the
failure notification with `(is_string(message), is_handle(thrown))`, creating
`thrown`'s state-owned handle only on delivery. A success event that cannot
be marshalled, when it is queued or when it is delivered, queues that same
failure notification instead. `onNotificationError` is not a substitute for
the request's outcome. It receives
`{kind: 'callback' | 'cleanup', operation, error}` for errors that have no
other caller: a callback that raises, a failure event that cannot itself be
marshalled, and secondary cleanup failures. Public operation labels are
`initialize`, `run`, `call`, `callTask`, `drain`, `dispose`, and `notify`;
work-announcement failure uses `requestDrain`.

### Output, disposal, and observation

Each `OutputChannel` has a FIFO of copied C bytes and Titan write/end entries,
with at most one actual sink or end-hook invocation. The output import admits
each copied iovec synchronously and never invokes the sink. SDK output sources
admit an entry with its settlement promise through that same queue. A logical
operation flushes both streams after all its C entries retire; later entries
still run after a throw/rejection. During a drive, each parked relinquish
gate starts a single-runner pump without
awaiting it, so a slow or forever-pending sink never stalls the drive.
One invariant governs every sink
call: `OutputChannel.take`, the only place a chunk leaves the FIFO, gives the
final flush every chunk and gives a pump a chunk only while the drive is
parked on a relinquish gate. A runner whose sink call settles while the drive
is parked takes the next published chunk; one whose call settles while the
drive runs (a turn, an internal coroutine handoff) stops there, and the next
gate starts a runner again. A runner retires in the same step as its last
take, so the next gate either feeds it or starts another. Chunks admitted
after a gate therefore wait for the next gate or the final flush, never
only for a sink call to resolve. The operation's final flush awaits a running
pump, then flushes again and drains everything left, and the pump's failures
join that flush's. A sink call increments `inHost`.
Titan failure remains primary while both deliverable stream flushes are
attempted. An otherwise successful operation returns
its first cleanup failure; every secondary failure is reported once through
the tagged observer. A secondary sink failure during a failed operation stays
pending for disposal, while an unrelated or empty flush does not return it
again. Its observed bit tracks delivery, not consumption, so later disposal
cannot notify the same failure twice.

Titan entries and C entries have different completion owners:

1. A terminal stream rejects an admitted Titan entry with its disposal error;
   a C entry retains the existing `firstFailure` accounting.
2. A C sink failure keeps operation-level reporting and latches the first
   unconsumed error on that stream.
3. After a Titan entry's sink settles, its request rejects with the latched
   C error and clears it, otherwise with its own failure, otherwise resolves.
   Its own failure is never captured for the operation, recorded as
   `firstFailure`, or returned as a cleanup failure.
4. An end entry has no bytes. At the head of the same FIFO it calls the
   embedder's end hook under the same gate, or rejects with
   `TypeError('browser <stream> has no end hook')`. JavaScript owns no
   shutdown or EOF policy.

Disposal closes admission before awaiting any work, rejects queued Titan
entries, and interrupts an in-flight sink through a detachable gate. Its
Titan entry rejects through the normal settlement path, before retirement
waits for retained requests. A discarded queue counts only C bytes for the
existing `firstFailure` rule. The interrupted stream becomes terminal, so it
can never overlap the pending sink. Accepted C work retires, retained host
work settles, and close runs as the last legitimate owner-held promised entry.
The backend's permanent block is installed only after close, or immediately
on poison.
Capture the first failure where the action or sink fails, not
after awaiting both streams. Disposal cannot replace an already captured
failure while interrupting its flush. One shared interruption record is
reported once as cleanup even if both streams are interrupted. Only an
operation not yet failed rejects `DISPOSED`; disposal keeps its own output/error
outcome, including `DISPOSED` for undeliverable interrupted or discarded bytes.

Deliverable C finalizer bytes are moved into JS-only drain records containing
only sinks, copied bytes, failure status, and the notification observer.
No Titan entry reaches them: disposal's interrupt already rejected the queued
ones, and `newRequest` refuses SDK requests once disposal begins.
Their module-scope continuation reports secondary disposal failures without
capturing the owner. `retireOwner` clears Module, backend,
bindings, wrappers, and instance callbacks before its promise fulfills with
those records. A separate module-scope continuation waits for their drains;
an externally retained unresolved disposal promise cannot keep the image
alive through an async method frame.

Engine failure latches poison before `onEngineFailure({kind, cause})`.
Observer throws are contained without replacing the original trap/abort.
Later application methods reject the saved failure and disposal never enters
the broken Module. `trace` exposes only a fresh frozen `{state, reason}`, not
mutable trace internals. Before dropping Module, retirement saves that pure
data snapshot; post-disposal reads retain the last map state and reason,
including after poison.

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
it. Native `titanc.exe` runs the same script with `sh.exe` and an argv
vector; it does not interpret the launcher path as a command.
The Windows shell launcher converts backslashes in its own path and in an
explicit `TITAN_NODE` before resolving their directories.

`titan-browser-run.mjs` parses `[--engine node|chromium] [--timeout MS]
[--grace MS] [--chrome PATH] [--cdp pipe|port] [--root DIR]
[--imports FILE] [--allow-degraded-trace] [--js-test] FILE [-- ARG...]`.
Defaults are Node, the CDP pipe, 30000 ms, and 1500 ms; the timeout is a
positive and the grace a nonnegative safe integer. `--imports FILE` must name a
regular `.mjs` file beneath `--root` (otherwise `--imports must name a regular
.mjs file beneath --root`; `--probe` refuses `--imports`), whose default export
is passed as `create({ imports })` for direct images (and exposed as
`context.imports` to `--js-test` harnesses) on both Node and Chromium. Misuse
prints `titan-browser-run: <detail>` and the usage to stderr and exits 2;
`--help` prints the usage and `--version` prints `titan-browser-run: Titan
0.6.2 browser runner (Node 26+)`, both to stderr with exit 0. `FILE` must be a
regular `.mjs` file beneath the root, which defaults to its directory. Stdout
carries only program bytes; every runner diagnostic goes to stderr. The module
exports `within(root, path)` and `Monitor` and guards its top-level `main()`
with a `realpath(process.argv[1])` check so that importing it from tests or
`spec/browser/playwright-run.mjs` does not run the CLI while direct invocation
(including through a symlink) works normally.

On Windows, Node spawns a native Titan helper for each engine, compiled by
`Makefile.win browser-sdk`. The helper attaches an unnamed, non-breakaway
Job Object atomically at `CreateProcessW` and owns its only handle. It
validates each inherited CRT slot and forwards the stdio table with only the
engine handles in the allowlist, preserving the worker IPC descriptor and
Chromium pipe descriptors 3/4. Two private slots carry the supervisor's
lifetime and the helper's post-drain acknowledgement; neither is inherited
by the engine.
The helper uses `CREATE_NO_WINDOW` for the engine. After launch it closes
its copies of the engine's stdin, stdout and protocol descriptors so their
owner can observe EOF without waiting for the engine to exit. It retains
stderr for its own diagnostics.
The launcher is installed as `bin/titan-browser-job.exe`; its provider is
`lib/titan/0.6/_titan_browser/windows_job.dll`, under a private module
namespace in the normal Windows native provider layout. The helper loads it
from the installed tree, then restores the supervisor's original
`TITAN_PATH_0_6` for the engine.
If Node disappears, the lifetime pipe closes; if the helper disappears,
Windows closes the job handle and kills its members. The runner removes a
Chromium profile only after the helper confirms no processes remain.
This preserves the existing `pipe` default and explicit loopback `port`
without silently switching transports. POSIX uses its existing group and
profile retirement rules.

**Probe.** `--probe` (with an optional `--chrome`) needs no file, SDK, or
browser launch. It prints exactly one LF-terminated JSON object:

```text
{"node":{"path":"<absolute>","version":"v26.x.y","ok":true,"reason":null},
 "chrome":{"path":"<absolute-or-null>","version":"<string-or-null>",
           "ok":<boolean>,"reason":"<string-or-null>"}}
```

Chrome selection is `--chrome`, then `TITAN_CHROME`, then `google-chrome`,
`google-chrome-stable`, `chromium`, `chromium-browser`, and
`chrome-headless-shell` on `PATH`. Windows first looks for `chrome.exe`
and uses the [regular Windows `PATH` search mode](windows-build.md#windows-executable-path-entries).
Chrome is usable when `--version` runs and
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
imports the image, whose embedded loader is the only loader it uses, writes
the program's bytes to its pipes, and reports completion and failures only
over IPC, never on stdout.
The supervisor owns the wall-clock deadline and the grace period, so a busy
WebAssembly loop cannot prevent a timeout; it never infers success from the
worker's exit, and a worker that exits or disconnects before shutdown is a
harness failure. Output pipes are drained before the runner returns.

For a plain program, the supervisor declares stdout/stderr backings from
its own descriptors, not the worker's pipes: `isTTY` gives `"tty"`, otherwise
`fstat` gives `"file"` for a regular file or `"pipe"` for a FIFO or socket.
Other backings remain undeclared. The page code passes these two options to
`create`. Plain Chromium programs declare no backings; a `--js-test` driver
continues to own all its `create` options. Neither runner engine supplies
stdin, end hooks, or environment options.

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
`DevToolsActivePort`, and connects with Node's built-in `WebSocket`. Chromium
creates that file before writing it, so empty or partial content is retried for
up to about one second; content that stays malformed is reported verbatim as a
JSON string. A missing file remains subject to the overall runner timeout.
Both transports use the same CDP commands; there is no npm dependency and no
hidden fallback. The page reports through a `Runtime.addBinding` binding as
base64-encoded JSON, so program bytes cross byte for byte and console text is
never parsed. GC
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
trap (`TITAN_BROWSER_TRAP` anywhere in the `cause` chain) or an observed engine
trap (reported through `onEngineFailure` as `{type: "trap", reason}`) is a trap
even when an abort follows or precedes it; both observed traps and observed
aborts are recorded while a catching harness finishes (bounded by `--timeout`),
reporting 71 for a trap, 70 for an abort alone, or 73 for a late observation
after completion. An observed abort without a trap makes the run an abort,
including the factory's subsequent `RuntimeError`; and a bare `RuntimeError`
without abort evidence is a trap. Malformed, duplicate, or unknown controls, a
premature engine exit, a crashed page target, a missing or invalid image, and
an interrupted runner (`SIGINT`, `SIGTERM`) are harness failures. Timers longer
than Node's 32-bit limit are armed in bounded slices against a monotonic
deadline.

**Public image observation, trace readiness, and terminal cleanup.** Each
image's public default creator is wrapped once (`observeImage`, one cached
wrapper per imported creator, so repeated `image()` calls return the same
identity). No wrapper exposes the private Wasm factory or Module. The wrapper
passes `requireTrace: !allowDegradedTrace` to that public creator; the existing
owner checks readiness after the map/factory barrier and before entering Lua.
The runner observes an ordinary initialization failure and lets `run()` return
its saved failed/status1 result. `--js-test` images receive the same option;
there is no post-initialize facade or second admission state. A permitted
degraded embedding continues with the Lua-only marker, while a strict
pre-Lua failure has no invented Titan trace. Transport fixtures are not
compiler-built images and supply their own test-only creator.

The wrapper calls the supplied `onEngineFailure` observer and forwards abort
and trap observations in `finally`, after the loader has latched poison.
Handled completion-protocol errors remain local to their poisoned instance;
their observer still runs and later application methods reject the saved
failure. An uncaught operation rejection follows the normal harness-failure
path (75); an unhandled Promise rejection still follows the unhandled policy
(74). An abort or trap observation is evidence, not shutdown: before
completion the monitor records the reason and waits for the execution path's
terminal failure, which the page sends only after `dispose()` returns. A
deadline still yields 72 if disposal never finishes. Observations after
completion are late engine failures (73), and a later completion, including a
fulfilled host test, cannot erase an observed abort or trap.

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
  image: async relativeMjs => ({create, locateFile}), // frozen, cached per path
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
`image` returns the same observed public creator for the same path, which
supplies `requireTrace: !allowDegradedTrace` and the runner's engine-failure
observer, and maps `locateFile` to the sibling Wasm and map, including names
with literal `#` or `?`. The context has no separate loader entry point.
`gc` fails rather than pretending to collect. A fulfilled `undefined` is
host-test success (status 0), a thrown non-loader error is host-test failure
(status 1), a loader error keeps its category, and any other return value is a
harness failure.

**Playwright supervisor (`spec/browser/playwright-run.mjs`).** To run the same
portable `run(context)` host tests (or a standalone Titan image with `--image`)
across Playwright-managed `chromium`, `firefox`, and `webkit`
(`playwright@1.64.1`), `spec/browser/playwright-run.mjs` parses `--engine
chromium|firefox|webkit [--root DIR] [--sdk DIR] [--timeout MS] [--grace MS]
[--persistent-context DIR] [--allow-degraded-trace] [--image] FILE [-- ARG...]` (defaults: `timeout`
300000 ms, `grace` 1500 ms, `sdk` `<repo>/titan-runtime/browser/`), loads
`playwright` from `TITAN_PLAYWRIGHT_ROOT` and managed browsers from
`PLAYWRIGHT_BROWSERS_PATH`, and reuses `titan-browser-page.mjs`, the exported
`within` and `Monitor` from `titan-browser-run.mjs`, the loopback `/root/` and
`/sdk/` HTTP server, `page.exposeBinding('__titanRunner', ...)` (with
`page.requestGC()` for host-test collections), and bounded `browserServer`
retirement (`browserServer.close()`, escalating to `browserServer.kill()`). Its
own diagnostics start with `titan-playwright-run: `, while the shared `Monitor`
keeps the runner's `titan-browser-run: ` prefix; its unit suite is
`spec/browser/playwright-runner.test.mjs`. `--persistent-context DIR` launches
a persistent context with that profile directory instead of a browser
server; the directory must resolve beneath `--root`, and the caller owns and
removes it. It is repository test
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
4. calls `browserlink.protocol_imports` on the linked probe's inventory to
   synthesize typed zero-valued stand-in functions (`undefined`, `0`, `0n`,
   `null`, or multi-value array) for any non-runtime function import (outside
   `wasi_snapshot_preview1.*`, `env.titan_browser_*`, `env.titan_mco_*`),
   writes them to `<probe>.imports.mjs` when any stand-in is needed, and runs
   `<runner> --engine node [--root <dir> --imports <probe>.imports.mjs] <probe>.mjs`,
   requiring exit 0 (`selected static provider failed executable-context
   protocol validation (browser runner exit <code>)`, with 75 when the runner
   could not start); and
5. removes the probe source, object, `.mjs`, `.wasm`, `.wasm.map`,
   `.wasm.trace`, and any `.imports.mjs` on every path.

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

Bridge notifications and drives follow this rule. Notifications run under a
logical operation, and a drive keeps its entry's logical owner across
relinquish points: the loader delivers queued calls and notifications through
`deliver` inside the drive ([drives, the call queue and wake
sources](#drives-the-call-queue-and-wake-sources)) and never admits an entry
because no Wasm frame is live.

`entry_lifetimes.titan` and its test-owned C guard keep an independent Lua
state across three distinct promised C-entry lifetimes: park ordinary and
STACKED chains, resume them, then run allocation-triggered abandoned cleanup
and close the state. The JS fixture interleaves two instances and checks
entry ownership and sink fencing on every private hop. This exercises the
backend lifetime boundary without adding a repeatable public bridge API.


## Baseline

`scripts/browser_baseline.lua` is a measurement harness, not a performance
gate. It builds the Titan `baseline` program at `-O1` and `-O2` through the
shared `baseline` profile, plus a native executable, with the JSPI backend and
separate output trees (there is no fork-interpreter cell). Coroutine and
external-suspension rows always run, and a cell's single option record drives
planning, child build, identity, and receipt.

Durable structural observations from the baseline images: `.titan.meta`,
`.titan.source`, and `.titan.cprobe` are absent from linked `.wasm` binaries
(`wasm-ld --gc-sections` drops the unreferenced external metadata definitions;
probe payloads never reach an image), and linked Titan images never import
`dlopen`, `dlsym`, `dlerror`, or native backtrace symbols. The retired
pre-JSPI Asyncify benchmark tables live at the permalink in [retired evidence
records](benchmark-archives.md#retired-evidence-records); current JSPI
release-profile measurements are collected under [Records](#records).

## Records

The release profile's records are measurements, not gates; nothing fails on
their values. Two harnesses take them:

* `spec/fixtures/browser_delivery/hosted.mjs --records FILE`, in the
  `production` Playwright cells, one per engine, loads the complete
  application's page five times. It records startup (the first output, the
  WebAssembly instantiation, and the Wasm and trace fetches) and scheduler
  responsiveness: the frames the page draws during the Task phase, their
  largest gap, and the delay of clicks made meanwhile
  ([documentation checks](#documentation-checks)).
* `spec/fixtures/browser_records/collect.mjs`, in the `browser-packaging`
  job, measures the clean checkout's installation (the default `production`
  profile) under Node and in Playwright Chromium:
  * the sizes of the complete application's `app.wasm`, `app.mjs`,
    `app.wasm.trace` and `app.wasm.map`: raw, gzip level 9 and brotli quality
    11, with Node's `zlib`;
  * startup under Node, in five fresh instances: from `create()` until
    `initialize()` resolves, for the application and for `records.mjs`, and
    until `records.mjs` first writes output;
  * memory: `records.mjs memory` prints the WebAssembly memory size
    (`__builtin_wasm_memory_size(0) * 65536`, which never shrinks, so its last
    value is the peak) and the usable bytes handed out by the allocator
    (`records_heap_used()` in `records_heap.c`, linked with
    `-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free` using
    `malloc_usable_size`). It prints them at start; after a warm-up batch of
    256 Tasks has finished and two collections; after each batch of 256 Tasks
    parked on channels of their
    own, until creating a Task fails; and after the parked Tasks finish and
    two collections. The bytes per Task come from the parked batches. A run
    that completes must have stopped at Titan's own `could not create
    coroutine: Out of memory`. An engine that fails first (status 70, 71 or
    75), as a [fatal engine allocation
    failure](../language/browser-target.md#limits) does, is recorded as that
    engine's limit with the last parked count;
  * recursion: the deepest depth that passes for plain recursion in `main`
    and in a new coroutine (`stack.mjs`, which imports neither `async` nor
    `io`, so `main` is not a Task and runs on the main stack), in `main`'s
    Task, and in `main`'s Task with a `timer.sleep(0)` at the deepest call
    (`records.mjs`). Every probe runs in a fresh engine. The depth doubles
    from 1000 until a run fails, then a bisection narrows it to within 1%.
    The failure is recorded by kind from the runner's status: the engine's
    call stack (75 with a call-stack message), an abort (70), a trap (71),
    or a Titan error (1). Any other status fails the step.

Recursion depth is engine-specific, so the `production` Firefox and WebKit
Playwright cells run the collector too, with `--engines` set to their engine
and `--measure memory,recursion`; together the jobs record memory and recursion
on all four engines.

`spec/browser/build-records.lua` builds `records.titan` and `stack.titan` from
`spec/fixtures/browser_records/` with the installation's `titanc`, under the
profile that its browser SDK recorded whatever `TITAN_BUILD_PROFILE` the
environment holds, and checks both images' imports against the `entry` class.
The collector runs Node images
through the SDK's `titan-browser-run` and the other engines through
`spec/browser/playwright-run.mjs`, and writes its JSON file with a Markdown
table beside it: `out/browser-records/packaging.json` in `browser-packaging`
and `records-<engine>.json` in the Playwright cells, where the hosted test
writes `playwright-<engine>.json`. Both jobs upload `out/browser-records/` as
`browser-records-*` artifacts.

## Host processes

The compiler process never loads a Wasm image or a browser archive. The
subprocesses of a browser invocation are `uname`, once during platform
initialization; `wasi-sdk` `clang` compile-only and preprocessing commands
(`-c`, `-E`, `-fsyntax-only`); the one `clang --version` and `wasm-opt --version`
queries; the archive tools' deterministic capability probes (which capture and
discard tool stderr/stdout) and `llvm-ar`/`llvm-ranlib` archive operations; the
compiler's own worker frontends; `clang` final links and `wasm-opt` passes for
images and protocol probes; and the runner, for `--probe` and for running a
protocol probe under Node. The native fresh-process provider validation, the
archive-backed native validation image, `_loadlib`, and the native runtime
build are never entered.

## Windows and other hosts

The driver admits `browser` on Linux, macOS, and Windows. A native host with
no OS label still receives `browser builds are supported from Linux, macOS
and Windows hosts (host is native)`. Browser compilation on Windows uses MSYS2
CLANG64 and the fork's browser Lua; `make install-browser` in the Lua
submodule works there with the pinned `wasi-sdk` 34 and Binaryen
`version_133`. The compiler does not enable native cross-compilation.

`Makefile.win` shares browser Lua/SDK staging, validation, and manifest
publication with `Makefile`. Its native runner helper and provider use the
ordinary Windows executable/DLL layout outside the browser asset directory.
The Wasm profile and verified SDK rules are the same on all three hosts;
Windows browser build and runner commands are supported from MSYS2 CLANG64.
Node timers on Windows follow the host timer granularity.

## Documentation checks

The browser chapter's opening and its complete application are executable.
`scripts/doc_check.lua` runs the fenced blocks that an HTML comment marker
(invisible in rendered Markdown) selects: `file=PATH` writes the block to a
workspace path, `run` and `setup=checkout` run an `sh` block, and
`expect=LABEL` records text for the caller to compare. Unmarked blocks,
including the long-running serve commands, never run, and a marker spelled
inside an unmarked block is text. An unknown or malformed marker, a marker
without a following fence, a `run` block that is not `sh`, and a file path
that is absolute or leaves the workspace are errors.

All marked blocks of the given documents become one `set -eu` script, so a
`cd` or `export` carries over to later blocks, and each document starts in
the workspace. File blocks become quoted heredocs that write the bytes as
shown. Command blocks get a fixed list of exact substitutions, each logged
when it applies: the documented clone command becomes `git -c
protocol.file.allow=always clone --recurse-submodules <checkout> titan` in the
`setup=checkout` block (Git 2.38 and newer refuse local submodule clones
otherwise), the documented `PREFIX` value becomes the job's prefix,
`/path/to/titan` becomes the source checkout, and `npm install --save-dev vite`
becomes a link to the pinned Vite installation. A command that needs a
substitution whose value was not given, a value that no block needs, and a
checkout block without the documented clone command are errors, so the check
fails when the chapter drifts from it. `section(text, heading)` keeps one
`##` section of a document, ending at the next `##` heading outside a fence,
and blanks the other lines, so a caller can check one section and its
diagnostics keep the document's line numbers. `spec/doc_check_spec.lua` tests
the grammar, section selection, the substitutions and the shell's
persistence, runs a clean checkout of a scratch Git repository, and plans the
installation and browser chapters as the clean-checkout job runs them.

`--clean-checkout` is the mode of the [`browser-packaging`
job](continuous-integration.md#browser-packaging-job). It takes a workspace
that must not exist yet and the checkout to clone, both absolute paths. The
checkout block clones that commit into `WORKSPACE/titan`, and the documented
`PREFIX` becomes `WORKSPACE/prefix`. After the document that holds the
checkout block, the script moves the clone to `WORKSPACE/titan-moved`, which
`/path/to/titan` names from then on, so the later documents run against an
installation whose source tree has moved: nothing installed may still point
into it. The shell starts without the variables that select a Titan
installation, profile or build mode, or Lua's module paths
(`doc_check.clean_variables`: `PREFIX`, `ROCKS_TREE`, `TITAN_ROOT`,
`TITAN_BUILD_PROFILE`, `OPENSSL_MODE`, `LUA_PATH`, and the like), so a job's
own settings, including those a workflow sets for all its jobs,
cannot stand in for a documented command. The script needs only Lua 5.4 or
newer, so a job can run it with its distribution's Lua before the clone has
built its own.

`spec/coder/browser_docs_spec.lua` runs the opening section ("A first web
page") in a workspace with the installation's `bin` on `PATH` and no Titan
overrides (`TITAN_ROOT`, `TITAN_PATH_0_6`, `TITAN_TARGET`, and the extra-flag
variables are unset), as a reader's shell would be. It checks the `hello`
image's imports against the `entry` class, then
`spec/fixtures/browser_docs/docs.mjs` imports the image
in plain Node (ready and frozen trace, the documented output), and loads
`site/`, `site-assets/` (`locateFile`) and `vite-app/dist/` in Chromium, each
served by the documented `http-dev-server` on the first free port from 28500.
Every page must show the `expect=page` text; every response must be 200; the
Wasm must arrive once as `application/wasm`, the module as `text/javascript`
and the trace table once; nothing from the SDK is served; and Vite must emit
hashed `.wasm` and `.trace` files and no unhashed one. A copy of `site/`
without `hello.wasm.trace` must end in `(failed, status 1)`, which shows that
the page's `requireTrace: true` would catch a deployment that drops the
table.

`doc/language/http-dev-server.titan` is a single-file native program on
`titan.http`. Its `Site` record holds the folder's canonical path. A request
path is split on `/` and each segment percent-decoded before it is checked,
so `%2e%2e`, an encoded `/` (`%2F`), a backslash and NUL are refused with 403
whatever their spelling. `Site:lookup` then checks that the path's canonical
form (`fs.realpath`) is the folder or lies below it before anything else,
including the redirect of a folder path without a trailing `/`, so a symbolic
link that leads outside is refused with 403 whether it names a file or a
folder. The redirect's location starts at the path's first name, so `//docs`
cannot become a protocol-relative `//docs/`. `fs.stat` returns nil only for a
missing file; lookup errors that mean no file is there (`ENOTDIR`, `ELOOP`,
`ENAMETOOLONG`) answer 404 and permission errors (`EACCES`, `EPERM`) 403, so
these requests get a response rather than ending their connection Task with
an error. A response to `HEAD` sets `Content-Length` and writes no body, as
`titan.http` requires. The native owner
`spec/fixtures/browser_docs/http_dev_server_test.titan` imports the server's
source (`import "http-dev-server.titan"`), serves a scratch folder on a
loopback port in its own Task, and checks content types, `HEAD`, methods,
directories, traversal, symbolic links and lookup errors through the public
HTTP client, plus `main`'s usage and busy-port statuses. Its unreadable-folder
case has nothing to check when the superuser runs it. The docs spec copies the
two files into one source tree and builds them with `--test`, so the
standard-library test tree never resolves modules from the manual.

The "A complete application" section documents `doc/language/browser-app/`:
`app.titan`, its page `index.html`, and `greeting.txt`.
`spec/browser/build-delivery.lua OUTPUT` runs that section's commands with
`doc_check` in the reader's shell: the installation's `bin` on `PATH`,
`PREFIX` naming it, `TITAN_BUILD_PROFILE` set to the profile that its browser
SDK recorded, and no Titan overrides. It builds the documented
`http-dev-server` natively under the same profile, checks the image's imports
against the `entry` class, and writes `delivery.json` with the profile and the
section's `expect=app` and `expect=app-errors` texts. With
`--built WORKSPACE`, it builds and runs nothing: the clean-checkout job has
already run the whole chapter there, so it checks the imports of the first
page's `out/hello.mjs` and of the application, then writes the same
`delivery.json` and copies the Node run's modules.
`spec/fixtures/browser_delivery/hosted.mjs` serves `browser-app/site` with
that server and loads the page in one Playwright engine, in a fresh context
with service workers blocked. The page's output element must hold the
`expect=app` text; its error element must start with the `expect=app-errors`
lines (the Titan frames without lines on WebKit) and continue only with
frames from `async.titan`, `coroutine.titan` and `runtime.browser.titan`
(`expectations.mjs`). The program's own frames are exact in both profiles:
no function on that call chain is inlined. The page must request exactly `/`,
`app.mjs`, `app.wasm`, `app.wasm.trace`, `titan-protobuf.mjs` and
`greeting.txt`, each once and answered with 200, open no WebSocket, and
complete each fetched file in its own Resource Timing; Chromium reports a
fetch whose body is read through a stream reader, as `http.get` reads, as
`net::ERR_ABORTED` to Playwright even after the body completed, so only a
failure before the response counts. The trace table's `responseEnd` must
precede the first output, no resource may start once the caught error is
shown, and the page must draw at least one frame while the Tasks wait. An
init script, not the page, measures: the first output, the WebAssembly
instantiation, the Wasm and trace fetches, animation frames during the Task
phase, and the delay of clicks made then. With `--records FILE` the
test loads the page four more times and writes their medians and maxima;
the numbers never fail the test. `dod.test.mjs`, copied into the output with
`expectations.mjs`, runs the image under `titan-browser-run --engine node
--js-test` with the page's two bindings and the same server, and checks the
same texts.

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
  every owned compile option refused naming the profile, exactly one certified
  harness level), paths,
  include-root resolution, the probe-cache directory, worker import, the
  compiler-probe feature diagnostic, the browser `--coverage` refusal, and the
  Windows host scope.
  The semantic codec round-trips both build profiles without tools and
  rejects malformed fields even when their graph checksum is valid.
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
  dynamic-loading guards, four-file preflight reservation and repeated-link
  image identity, contributor-prologue `.wasm.map` attribution, image
  inventories, program images without `.titan.*` payload segments while their
  objects keep both payload symbols, measurement optimization, the native
  libbacktrace and fallback trace invariants, and [long-double
  formatting](#the-link-profile) (`-lc-printscan-long-double` and the
  `spec/fixtures/browser_images/long_double.titan` text compared on native,
  Node, and Chromium). Its production-only pin (`keeps frame flags on
  test owners only and links a production test image as a test image`) is
  pending in a validation installation and runs in the production Chromium
  [`browser-playwright`](continuous-integration.md#browser-playwright-job)
  cell.
* `spec/coder/browser_incremental_spec.lua` — browser object and four-file
  link certificates, shared-asset and `.wasm.map`- or `.wasm.trace`-change invalidation,
  four-predecessor rollback across backup/publication/certificate boundaries,
  certified `-L`/`-l` archive reuse versus uncertified `wasi-sdk`-only system
  libraries, and, for a program and a test image, an oversize body rejected
  before `before_commit` and publication with predecessors intact and no
  certificate, recovery, a warm final-link hit that does not inventory the
  published image again, and a miss after the copied guard owner changes, and
  the mixed sets an interrupted publication can leave, run under Node
  ([module and Wasm binding](#module-and-wasm-binding)).
* `spec/browser_trace_map_spec.lua` — final-image Wasm section/range/name
  extraction, standard v3 `.wasm.map` validation, `x_titan_*` extension
  rewriting, the [trace table](#the-trace-table) writer (gaps for inlined C
  and unmapped code, the last segment at an offset, including one that
  replaces a body's first segment, coalescing, body
  boundaries, used basenames only and their limit, imports-first names, the
  identity, and the same table from the final map), checked by an independent
  decoder against the segments at every offset of constructed and seeded
  generated maps, `browsertrace.identity` recipe, `browser_trace_libraries`
  resolution, malformed/truncated Wasm and map rejection, the
  [byte bounds](#build-time-image-bounds) (image equality, bodies at and below
  the bound with a padded length, imports-first indexing, quoted and unnamed
  labels), import signatures from the type section and their refusals (type
  form, value type, type length, import type index), and rejected-body source
  attribution (first mapping inside the body, same-offset unmapped
  replacement, the half-open end, unavailable metadata, whole-map validation).
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
  identical-archive reuse, probe cleanup, an oversize protocol body rejected
  with its mapped source before execution or provider publication, and an
  archive-only consumer: a library archive installed into a separate
  `libprefix/lib/titan-browser/0.6/` and named by `TITAN_PATH_0_6`, with its
  source and output deleted, links into a program whose `-v` link names the
  installed archive and compiles no `pkg` source; the program prints the
  expected line and exits 0 under Node and Chromium.
* `spec/browser_sdk_spec.lua` — `make lua-browser` reuse and rebuild,
  `make browser-sdk` into an empty root with poisoned ambient `CPPFLAGS` and
  `TITAN_EXTRA_CPPFLAGS`, the twenty-one-module provider whose non-compiler
  members are exactly the five LPegLabel objects, differing roots, digest
  order and contents, retirement on an interrupted build, installed modes
  under a restrictive umask, the three-file semantic pack relocated without
  build inputs, the standalone `-shared-mem` archive regression, and the
  readiness order with the `build-profile` record's mismatch and invalid
  forms, and `make uninstall-browser-sdk` against a synthesized SDK holding a
  user archive (kept files, empty-directory pruning, refusal before removal).
* `spec/browser_stdlib_spec.lua` (toolchain-free) and
  `spec/coder/browser_stdlib_closure_spec.lua` — the [dependency-closure
  check](#the-dependency-closure-check) and its negative fixtures, the
  [subset parity gate](#subset-parity-gate) (normalization, drift cases,
  status-inventory checks, type-only reachability, test references and
  evidence, the type fixture renderer), the twenty-three-owner
  root inventory and its rejection of empty or
  duplicate inventories before build setup, the cold and warm single-image
  layout and filtered runs, the CI failure artifact's image and per-engine log
  paths, the per-owner audit of a failed run, the stdout-only audit of a run
  whose stderr arrives in the middle of a report line, and the strict
  single-image audit of timing, owner, failure, skip, and filter accounting,
  the rejected `ExternalWait` record literal on both targets, the
  [absent-module diagnostic](#the-absent-module-diagnostic) on the real SDK,
  both type fixtures against the installed providers, and the [import
  manifest](#import-manifest) checker over constructed images (listed imports
  per class, an injected unlisted import, a changed signature, unlisted
  memory and global imports, a fixture's imports refused for an `entry` image
  and for another fixture's image, and malformed, duplicate or unknown-class
  allowlists).
* `spec/coder/browser_stdlib_gate_spec.lua` — the [initialization and
  fidelity gate](#initialization-and-fidelity-gate).
* `spec/coder/browser_net_spec.lua` and `spec/browser/build-net.lua` — the
  [live browser network harness](#the-live-browser-network-harness) for the
  `http` and `websocket` clients under Node and Chromium, and on Chromium,
  Firefox, and WebKit in the `browser-playwright` job, and the evidence of
  the inventory tests it runs.
* `spec/coder/browser_entry_gate_spec.lua` — the [entry gate](#the-entry-gate-decision).
* `spec/coder/browser_fixtures_spec.lua` — the coroutine and GC behavior in
  the owning `coroutine.tests` and `gc.tests` modules built for the browser,
  and the real browser trace, pin, bare rethrow, and coroutine-append cases in
  `spec/fixtures/browser_runtime/runtime_trace.titan` (`trace.c`, `trace.h`)
  under Node and Chromium.
* `spec/coder/browser_budgets_spec.lua` — every [budget](#budgets) just below
  and just above its limit.
* `spec/minicoro_spec.lua` — the WebAssembly/JSPI lane of the tagged-behavior
  probe (JSPI with and without `MCO_NO_DEBUG`, `MCO_USE_VMEM_ALLOCATOR`, and
  the tag comparator), the unwind-floor harness, and
  unstarted/suspended/stacked retirement before native allocation reuse, under
  both engines.
* `spec/coder/browser_bridge_spec.lua`, `spec/browser/build-bridge.lua`,
  `spec/fixtures/browser_bridge/`, and the browser-only owner
  `spec/stdlib/titan/browser/` — the persistent bridge gate under Node and
  Chromium: the native `browser.tests` image with its independent-state C
  helper, the failed-initializer image, and the `browser.public_state_tests`
  image of public `lua.new` lifetimes, driven by `integration.mjs` through
  lifecycle, typed values, callbacks, notifications, requests, stdio, state
  close, public-state invalidation, and WeakRef collection, plus the
  unhandled-rejection (74) and poisoned-retirement (70) diagnostics, and, on
  Chromium, the DOM click counter of synchronous C callbacks (`create({ imports })`
  and `context.table`) and the async driver's responsiveness page test
  (`responsive.mjs`) ([browser bridge runtime](browser-bridge.md#test-layers)).
  `browser_bridge_spec.lua` also runs `environment.mjs` with the libc
  environment fixture under Node and Chromium, checking validation, empty
  defaults, UTF-8, mutation, and instance isolation.
* `spec/coder/browser_docs_spec.lua` with `scripts/doc_check.lua`,
  `spec/fixtures/browser_docs/docs.mjs`, and
  `spec/fixtures/browser_docs/http_dev_server_test.titan` — the browser
  chapter's opening run as documented ([documentation
  checks](#documentation-checks)): plain Node, plain HTTP, relocated assets
  through `locateFile`, and a Vite build, with no external Titan loader
  available, plus the loopback behavior of `http-dev-server.titan`. The
  server is a native program on `titan.http`, so the file belongs to the
  installed-stdlib domain: CI runs it in `native-coverage` after the standard
  provider is installed, where the browser case pends, and in the `chromium`
  Playwright cells, which require both cases.
  `spec/doc_check_spec.lua` tests the runner's marker grammar, section
  selection and substitutions without `wasi-sdk` or Binaryen, and its
  clean-checkout clone and move on a scratch Git repository.
* `spec/browser/build-delivery.lua` with
  `spec/fixtures/browser_delivery/hosted.mjs`, `dod.test.mjs` and
  `expectations.mjs` — the chapter's complete application built by its
  documented commands and served by the documented server to Chromium,
  Firefox and WebKit in the Playwright cells, and run under Node, against
  the documented output and trace, with exact requests and their order
  ([documentation checks](#documentation-checks)). The `browser-packaging`
  job runs both chapters from a fresh clone through `doc_check.lua
  --clean-checkout` and the same tests on the result.
* `spec/browser/build-records.lua` with `spec/fixtures/browser_records/` —
  the release profile's [records](#records) in the `browser-packaging` job
  and the `production` Firefox and WebKit cells; they fail on harness errors
  and on a memory run that completes without Titan's allocation error, never
  on the measured values.
* `spec/browser/loader.test.mjs` with `spec/fixtures/browser_loader/` — the
  portable loader suite under both engines: byte fidelity, statuses, sinks,
  reentry, 50 collectable create, run, and dispose cycles, concurrent instances,
  lifecycle races, the optimized guard image (`optimized-guard.mjs`), the
  refusal of one `loader_app` module paired with another link's `.wasm`, and
  `import-tests.mjs` on the `--names` images (accepting import maps in object
  and function form, null-prototype maps, and foreign-realm maps, and refusing
  arrays, `Map`s, class instances, promises, reserved `wasi_snapshot_preview1.*`
  and `env.titan_{browser,mco}_*` names, and async functions with the documented
  messages).
* `spec/browser/runner.test.mjs` and `spec/browser/runner-fixtures.mjs` — the
  runner's resolver, probe, CLI (including `--imports`),
  `--allow-degraded-trace` and the default required-trace initialization
  failure for direct and `--js-test` images, a real-image case verifying
  initialization waits for a delayed `.wasm.trace` (one lookup, one fetch) and
  that a throwing trace locator degrades the trace (or fails `requireTrace`),
  exported `within`/`Monitor` helpers and symlink invocation, status
  categories, grace, abort and cleanup boundaries, process-group retirement,
  path containment, over Node and both Chromium transports, and, with fake
  images, the loader's protocol failure for a `.wasm` from another link or
  without its identity export, and its `TypeError` for a malformed image
  binding.
* `spec/browser/trace-adapter.test.mjs` and
  `spec/fixtures/browser_trace_adapter/{stacks.json,stacks-jspi-current.json,degraded.mjs,lifecycle.c,filter.c}`
  — Node unit tests for the V8, SpiderMonkey, and JavaScriptCore stack parsers
  (historical survey and current JSPI captures, saved-parent cutoff, V8
  title-line frame-shape filtering, and caller-owned capacity bounds),
  `Error.stackTraceLimit` and
  `Error.prepareStackTrace` descriptor preservation (absent, data, accessor,
  non-writable, and non-configurable descriptors without invoking getters or
  setters or constructing an `Error` on unsafe descriptors), lookup boundaries,
  gaps, indexes and names over tables that the compiler's writer derives from
  synthetic maps, refusal of damaged tables (short, magic, version, image,
  truncated, trailing, counts, bounds, a repeated row offset, a `.titan` row
  without a line, indexes, string offsets) and a table at
  an unaligned offset, the eager loader's ready and degraded results, and the
  compiled `lifecycle.c` (preRun/export readiness) and `filter.c` (entry
  sentinels and registered names are kept, a symbol with no `.titan` basename
  is dropped) fixtures.
* `spec/browser/build-trace.lua`, `spec/browser/trace.test.mjs`,
  `spec/browser/playwright-run.mjs`, `spec/browser/playwright-runner.test.mjs`,
  and `spec/fixtures/browser_trace/` — the staged multi-engine browser trace
  gate (46 discovered native cases in `trace_cases` plus the `trace_uncaught`
  and `trace_async` programs, with positive `cases` rows and intentional
  `degradedCases` rows in `manifest.json`, which also records the installation
  `profile`; the degraded rows pair the runtime image with a
  missing, malformed (the image's own map under the table's name), truncated,
  or flipped-identity trace table, or another link's complete table) covering direct and `.browser.titan`
  contributor locations, deep recursion and engine truncation, mixed
  `Lua -> Titan -> Lua -> Titan` merge order, mixed and `pcall` recursion past
  the [browser C-call limit](#the-regression), all wrapper families, fresh
  raise versus bare rethrow, coroutine append across yield/resume, adjacent
  unmapped helpers, immediate literal calls, held-storage nested capture, merge
  `LUA_ERRMEM` recovery, post-suspension traces in `async` Tasks
  (`tasks.browser.titan`: after turn and wait relinquishes, in a
  delivered handler, through an `async.Error` handoff, rethrow and fresh raise
  across an await, coroutine append in a Task, and a cleanup during
  cancellation), entry traces (the `task_entries` row's failed Task-form call,
  and a call and a notification failing where a drive delivers them), a failed
  async bootstrap `main` Task, and WebKit reduced-fidelity rendering across
  Node, Chromium, Firefox, and WebKit. `build-trace.lua` links the test image
  with the `test` purpose and the uncaught and async images with `program`,
  the async image without `--no-uv-bootstrap`; every row is exact except a
  production program row, which follows the [ordered-subsequence
  contract](#test-images).

The Busted files need `wasi-sdk` 34, Binaryen `version_133`, and the
installed browser Lua; the image,
protocol, SDK, stdlib closure, entry and stdlib gate, bridge, fixture, budget,
and minicoro files also need Node 26+ and an installed browser SDK, and all of
them except the stdlib closure file also need a headless Chromium. The
documentation file's page case instead needs Node 26+, the browser SDK, and
the pinned Vite and Playwright installations named by `TITAN_VITE_ROOT` and
`TITAN_PLAYWRIGHT_ROOT`; `TITAN_REQUIRE_BROWSER_DEPLOYMENT=1` turns their
absence into a failure. Its `http-dev-server` case needs only the native
installation.
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
Three Linux CI jobs run these files with the real toolchain:
[`browser-toolchain`](continuous-integration.md#browser-toolchain-job) runs
`spec/wasm_toolchain_spec.lua`, `spec/coder/browser_toolchain_spec.lua`, and
the trace-map, trace-entry, and budget files beside the loader, runner,
trace-adapter, and Node trace suites. The two
[`browser-stdlib` shards](continuous-integration.md#browser-stdlib-job) divide
the provider, incremental, image, protocol, SDK, stdlib closure, entry, bridge,
scheduler, network, stdlib gate, fixture, and minicoro files, with the browser
core stdlib suite running only in the `sdk` shard.
The Playwright trace, bridge, and documentation gates run in
[`browser-playwright`](continuous-integration.md#browser-playwright-job).
