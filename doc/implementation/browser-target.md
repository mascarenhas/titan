# Browser target

`titanc --target browser` compiles Titan modules and authored C to
relocatable WebAssembly objects with Emscripten, publishes library-mode
providers as self-describing Wasm archives, and links programs and tests into
an ES-module factory (`.mjs`), its WebAssembly binary (`.wasm`), and its
extended source map (`.wasm.map`). A web page or application loads the image
through a Titan-owned loader, and tests and command-line workflows run it
under Node 24, headless Chromium (`titan-browser-run`), and Playwright
Chromium, Firefox, and WebKit. The user contract is in the [browser-target
chapter](../language/browser-target.md) of
the language manual.

The implementation is spread over:

* `titan-compiler/browsertarget.lua`, which locates and pins the Emscripten
  tools, reads and verifies the fork's Lua build record, probes the target C
  facts, and builds, freezes, exports, and imports the browser target
  descriptor;
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
* the Make targets `lua-browser` (`scripts/lua_browser.sh`) and `browser-sdk`
  (`scripts/browser_sdk.lua`).

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
runner tool into `lib/titan-browser/<ver>/`; (5) it publishes the minimal
stdlib provider and protocol-probes it against the runtime staged in step
(4); (6) it writes the browser SDK digest manifest last. Missing browser-SDK
paths are diagnosed, naming `make browser-sdk`, only when a program or test
is linked or when library-mode publication runs the executing protocol check;
compile-only work needs only the verified Lua pieces.

Step (4) also installs the browser LPegLabel archive. Every runtime and
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
* `-DLUA_USE_POSIX -DLUA_USE_BROWSER`, without `LUA_USE_DLOPEN` or readline;
* `-sSUPPORT_LONGJMP=emscripten` in `SYSCFLAGS`, with `MYCFLAGS` passed
  through and `CMCFLAGS` applied to every browser object;
* browser `LUA_PATH_DEFAULT`/`LUA_CPATH_DEFAULT` rooted at the empty
  `LUA_ROOT`, without the executable-relative `!/../` root; and
* its own object directory, `src/browser/obj`, separate from the native build.

`make install-browser PREFIX=<root>`, run in the fork, builds the archive if
needed and installs it. It writes only below `<root>/lib/browser`, never runs
a host Lua interpreter, and refuses an effective configuration that would make
the record false: a missing or wrong `emcc`, an effective `LUA_USE_DLOPEN`, a
missing `LUA_USE_POSIX`/`LUA_USE_BROWSER`, a longjmp mode other than the
recorded one, or position-independent flags. `fork_revision` comes from the
fork tree's own `.git`; a tarball build must pass
`FORK_REVISION=<40-hex commit>`. The fork's README documents the installer's
own failure modes and the record's byte formats.

Titan pins the fork commit through the gitlink and the `v5.5.1-1` release, not
through the record's copy of the revision. `archive_sha256` is stable for one
commit, flag set, and Emscripten build, because `emar` archives are
deterministic.

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
| `lpeglabel` | `libtitan-lpeglabel.a` | the five LPegLabel objects (`lplcap.o`, `lplcode.o`, `lplprint.o`, `lpltree.o`, `lplvm.o`), staged for a later browser `peg` provider; no current image links it |
| `provider` | `titan.a` | the browser standard provider, with exactly the roots `titan.test`, `titan.coroutine`, and `titan.gc` |
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
`node_worker`, `page` (`TODO(confirm: exact position of trace_library in require_sdk order)`),
that each asset is a regular file that `context.io` can open and read
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

`make browser-sdk PREFIX=<prefix> [ROCKS_TREE=<tree>]` is, apart from `make
lua-browser`, the only Titan Make step that needs emsdk. It requires the
installed compiler and common headers
and the browser Lua; it never invokes `lua-browser`, the native standard
library, or the native SDK build, and it clears ambient `LUA_PATH`,
`LUA_CPATH`, and `TITAN_TARGET`. It runs the installed `titanc` from
`TITAN_INSTALL_TREE` (then `PREFIX`); a missing compiler stops with
`browser-sdk: installed titanc not found; run 'luarocks make' or 'make
install-compiler-sdk' first`. Every child gets `TITAN_ROOT` set to the
installation tree, `TITAN_PATH_0_6` set to the checkout, and an empty
`TITAN_PATH`. When `TITAN_NODE` is unset or empty, the recipe unsets
`TITAN_NODE` and, when `EMSDK` is set, prepends the first executable
`$EMSDK/node/*/bin` directory to `PATH` ahead of any existing `node`. The
build directory is `TITAN_BROWSER_BUILD_DIR` (default
`$(TITAN_OUTPUT_DIR)/browser-sdk`), a browser `--output` root.

1. `scripts/browser_sdk.lua prepare` stages a differing root (below), checks
   Node 24 up front with `driver.browser_node_ready` against the checkout's
   runner (`browser provider validation requires Node 24: <reason>; set
   TITAN_NODE to a Node 24 executable`), removes a stale `sdk-digests` so that
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
   titan.test titan.coroutine titan.gc` publishes `<build>/titan.a` through
   ordinary library mode, which runs the executing protocol check against the
   runtime and runner staged in step 3. No `titan.a` or manifest exists yet,
   and none is required.
5. `browser_sdk.lua finalize` rescans the staged provider with the descriptor
   fingerprint, revalidates it structurally, requires exactly the keys
   `titan.coroutine`, `titan.gc`, and `titan.test` in that order, copies it to
   `titan.a`, and finally writes `sdk-digests` with
   `incremental.write_sdk_digests` and the existing schema.

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
sjlj=emscripten
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

1. The direct-API compile extras pass the [unsupported-flag
   check](#unsupported-flags).
2. `emcc`, `emar`, and `emranlib` are located and `emcc` reports 6.0.13 (see
   [Emscripten pin](#emscripten-pin-and-tool-location)).
3. The record is read and parsed: banner and text encoding, then unknown and
   duplicate keys.
4. Field syntax: missing, non-text, or empty fields, then the three
   hexadecimal fields.
5. The fixed fields: `sjlj` must be `emscripten` (Titan's mode, because
   `titan.h` mirrors `lua_longjmp`), `target` must be
   `wasm32-unknown-emscripten`, and `emscripten_version` must equal the pin,
   which step 2 already compared with the running `emcc`.
6. `wasm_features` is a canonical list equal to the expected baseline
   `+bulk-memory +bulk-memory-opt +call-indirect-overlong +multivalue
   +mutable-globals +nontrapping-fptoint +reference-types +sign-ext`.
7. `lua_defines` is canonical, sorted, and unique, and equals the sorted
   unique `-D` tokens of `cflags`.
8. The effective `-sSUPPORT_LONGJMP` mode of `cflags` (the last setting, in
   either the joined or the split `-s SUPPORT_LONGJMP=` spelling; a bare
   setting or `=1` means `emscripten`) equals `sjlj`.
9. `cflags` contains no unsupported flag.
10. `archive_sha256` matches `liblua`.
11. `headers_sha256` matches the headers in `lua_source`.
12. `numeric` agrees with the probed C profile (`integer=<lua_integer>,float=<lua_number>`).
13. A trivial Titan-flag object compiled with `emcc` matches the expected
    Wasm fingerprint under `staticmetadata.fingerprint_matches`, which
    cross-checks the baseline features against the actual toolchain.

The Lua archive itself is hash-verified, not feature-compared. Objects keep
their exact canonical `target_features` string in `fingerprint.features`,
including the standalone `-shared-mem` token that LLVM's
`WebAssemblyLowerEmscriptenEHSjLj` pass records in each translation unit that
calls `setjmp` or `longjmp`, such as Lua's `ldo.o`, a Titan module with a
`catch`, or authored C that uses them. Fingerprint comparison ignores that one
token, and only it: two feature lists match when they are equal, or when both
are canonical and become equal after dropping the standalone `-shared-mem`
token from each, provided neither carries any other `shared-mem` or `atomics`
entry (`+shared-mem`, `=shared-mem`, `+atomics`, `-atomics`, or `=atomics`).
Every other feature, including a lookalike name such as
`-shared-mem+atomics`, still matches exactly
([Static compiled modules](static-compiled-modules.md#relocatable-webassembly)).
A Wasm-exceptions mode
would need coordinated Lua, Titan, and generated-code settings; the `sjlj` and
`wasm_features` checks and the unsupported `-fwasm-exceptions` flag reject it.

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
  compile_flags = argv,          -- complete effective flags; include_dirs appended separately
  include_dirs = { string, ... },
  target_defines = { "-DTITAN_TARGET_BROWSER=1",
    "-DTITAN_COROUTINE_STACK_SIZE=262144", "-DMCO_ASYNCFY_STACK_SIZE=65536" },
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

1. `--std=c99`, `-O1`, `-fno-inline`, `-fno-optimize-sibling-calls`, `-Wall`,
   `-Wno-unused-but-set-variable`, `-Wno-unused-function`, `-g2`, and
   `-sSUPPORT_LONGJMP=emscripten`;
2. the record's `lua_defines`, in record order;
3. the ordered `target_defines`: `-DTITAN_TARGET_BROWSER=1`,
   `-DTITAN_COROUTINE_STACK_SIZE=262144`, and `-DMCO_ASYNCFY_STACK_SIZE=65536`
   (minicoro's own `ASYNCFY` spelling); and
4. the normalized invocation compile extras: `driver.NATIVE_COMPILE_FLAGS`
   when `titanc` installed them (environment extras, then CLI `-I`, `-D`, and
   `--cflag` in written order), otherwise `TITAN_EXTRA_CPPFLAGS` followed by
   `TITAN_EXTRA_CFLAGS`, followed by an internal measurement optimization
   (`-O1` or `-O2`) when `driver.browser_link_options.optimization` selects one
   ([The link profile](#the-link-profile)).

There is no `-fPIC` and no LTO. Both `production` and `validation`
installations share the trace-preserving compile flags `-O1 -fno-inline
-fno-optimize-sibling-calls -g2` (currently the candidate trace profile;
`TODO(confirm: freeze as release trace profile after all #330 gates pass)`).
Lua's own `-O2` and debug policy in `liblua.a` stay independent because Lua C
frames are filtered out of Titan traces. The host descriptor emits no new
define. Validation requires all three target defines in this order
(`inconsistent browser target defines`) and requires each in
`compile_flags` (`browser target descriptor is missing required compile flag
"<flag>"`), so build, import, and fixtures agree. The target defines reach
generated C, `--c-source` nodes, C probes, and FFI header preprocessing,
because all of them use the same prefix, so the standard library and C headers
read target constants through `foreign import`: `titan/coroutine.titan` reads
`ffi.TITAN_COROUTINE_STACK_SIZE` ([Coroutines](coroutines.md#stacks-and-backends)),
and the Emscripten fiber backend in `minicoro.h` sizes its Asyncify buffers
with `MCO_ASYNCFY_STACK_SIZE`. Because a measurement
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
version output, the effective flags and include roots in order, the target
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
record fields, required flags and longjmp setting, include order, fingerprint,
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
  its identity, and `target_identity = descriptor.identity`. The host result
  is unchanged and has no `target_identity`.
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
   `browser builds are supported from Linux and macOS hosts (host is <host>)`;
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

A browser invocation rejects these flags wherever they appear:

`-fPIC`, `-fpic`, `-fPIE`, `-fpie`, `-pie`, `-shared`, `-dynamiclib`,
`-rdynamic`, `-pthread`, `-flto`, `-flto=*`, `-ffat-lto-objects`, `-march=*`,
`-mcpu=*`, `-mtune=*`, `-m32`, `-m64`, `-fwasm-exceptions`, and any
`-sSUPPORT_LONGJMP` setting other than `emscripten` (joined
`-sSUPPORT_LONGJMP=<mode>` or split `-s SUPPORT_LONGJMP=<mode>`).

The diagnostic is `browser target does not support <origin> flag "<flag>"`,
where `<origin>` is `TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`,
`TITAN_EXTRA_LDFLAGS`, `--cflag` (the normalized compile extras, and
per-request `extra_compile_flags`), `--ldflag` (the normalized link extras),
or `compile_flags` for direct `browsertarget.build` inputs. A split longjmp
setting quotes both words. Flags are never dropped silently. `-fno-lto` is
harmless and accepted, as are the bare and `=1` longjmp spellings. Inside the
record, the same check reports `invalid field "cflags": browser target does
not support cflags flag "<flag>"`.

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
`coverage options require --coverage` rejection.

The [link profile](#the-link-profile) owns the image settings the runtime
depends on. `browserlink.validate_extras(flags)` rejects, in the normalized
compile and link extras (`titanc` checks both lists right after normalizing
native inputs) and again in the final link extras, user flags that override the
owned trace-preserving optimization, inlining, tail-call, debug, and
source-map settings (`-O*`, `-finline*`/`-fno-inline*`,
`-foptimize-sibling-calls`/`-fno-optimize-sibling-calls`, `-g*`,
`-gsource-map*`; `TODO(confirm: exact owned trace flag patterns in browserlink.validate_extras)`),
as well as every `-s`, `-D`, or `-U`
spelling, joined or split and with or without a `NO_` prefix, of
`SUPPORT_LONGJMP`, `ASYNCIFY` and every `ASYNCIFY_*` setting, `STACK_SIZE`,
`INITIAL_MEMORY`, `ALLOW_MEMORY_GROWTH`, `MAXIMUM_MEMORY`, `ABORTING_MALLOC`,
`EXIT_RUNTIME`, `INVOKE_RUN`, `MODULARIZE`, `EXPORT_ES6`, `ENVIRONMENT`,
`FORCE_FILESYSTEM`, `FILESYSTEM`, `MINIMAL_RUNTIME`, `EXPORTED_FUNCTIONS`,
`EXPORTED_RUNTIME_METHODS`, `INCOMING_MODULE_JS_API`, `ASSERTIONS`,
`STACK_OVERFLOW_CHECK`, and the three target defines, plus `--no-entry` and
`--js-library`, with `browser link profile owns option <flag>`. Other
Emscripten settings pass through, so a later user flag can never weaken the
profile.

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

* **Objects.** `incremental.toolchain_identity` adds the descriptor identity
  as `target_identity` to the hashed toolchain details, not only to its memo
  key, so a browser object certificate depends on the complete descriptor.
  The native details table keeps its original shape and no target field, so
  native certificates are byte-identical. The compile prefix in the
  `options` component differs as well. A foreign-format object found at an
  expected path parses and misses.
* **Links.** The final-link key remains a digest of the output paths only, so
  a program's key covers `<stem>.mjs`, `<stem>.wasm`, and `<stem>.wasm.map`.
  `titanc` always supplies its ordinary native profile identity as
  `policy.target`; `linkcertificate.prepare` is the sole writer of the browser
  value: for a browser context it copies the recipe policy and sets `target`
  to the descriptor identity without mutating the caller's table, which covers
  non-CLI callers too. A record written by another target or another browser
  configuration is therefore a miss. The browser policy also records
  `browser_profile`, the link profile's `identity_inputs`, and for library
  mode `browser_probe`, the runner's `--probe` report of the Node (and Chrome)
  that the executing check uses. The `runtime` file field lists the eight
  required SDK assets (`libtitan.a`, `titan-browser-library.js`,
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
modules `titan.test`, `titan.coroutine`, and `titan.gc` resolve from it, ahead
of the Titan path and source.

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

Before linking, `titanc` requires the SDK and a working Node 24
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

`options` is closed: `purpose`, `assertions`, `optimization`, `asyncify`,
`budgets`, and `entry` (`unknown browser link profile option <key>`).

* `purpose` is `program`, `protocol`, `gate`, `minicoro`, `budget`, or
  `baseline` (`invalid browser link profile purpose`). Programs and tests use
  `program`; the executing check uses `protocol`; the others serve the
  runtime-evidence and measurement harnesses.
* `assertions` is required and is 0 or 2 (`browser assertions must be 0 or
  2`).
* `asyncify` defaults to true; only `minicoro` and `baseline` may turn it off,
  for named control measurements (`this browser link profile requires
  Asyncify`).
* `optimization` is `O1` or `O2`, only for `minicoro`, `budget`, and
  `baseline` (`invalid browser link optimization override`); it yields
  `compile_flags = {"-O1"}` or `{"-O2"}` and the matching link flag.
* `budgets` overrides `stack_size`, `asyncify_stack_size` (positive multiples
  of 16), `initial_memory`, and `maximum_memory` (positive multiples of 65536,
  initial at most maximum, maximum at most 2147483648), only for `budget`
  (`browser budget overrides require the budget profile`, `invalid browser
  budget override <key>`, `invalid browser memory budgets`).
* `entry` defaults to `titan`; the only alternative, `lua-main`, is for the
  `baseline` measurement of the fork's own Lua interpreter (`invalid browser
  link entry`).

`link_flags` is, in order:

| Flags | Purpose |
| --- | --- |
| `-O1 -fno-inline -fno-optimize-sibling-calls -gsource-map -g2` | the candidate Titan-entry trace link profile (`TODO(confirm: release trace profile freeze after integrator gates)`); measurement purposes (`minicoro`, `budget`, `baseline`) apply an explicit `-O1` or `-O2` `optimization` override when selected |
| `-sASYNCIFY=1` | minicoro's Emscripten fiber backend refuses to create fibers without Asyncify, and Asyncify carries the outer suspension. Indirect calls keep the default conservative instrumentation: closures and the module ABI call through function pointers, so there are no `ASYNCIFY_IGNORE_INDIRECT`, `ASYNCIFY_ONLY`, or `ASYNCIFY_REMOVE` lists. `-sASYNCIFY=0` only for a control. |
| `-sSUPPORT_LONGJMP=<sjlj>` | the record's verified longjmp mode, `emscripten`, matching `liblua.a` and `titan.h` |
| `-sSTACK_SIZE=1048576`, `-sASYNCIFY_STACK_SIZE=65536` | the main C stack and the outer Asyncify data budget ([Budgets](#budgets)); the second only with Asyncify |
| `-sINITIAL_MEMORY=16777216 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2147483648 -sABORTING_MALLOC=0` | coroutine stacks are committed eagerly, so memory grows; a failed `malloc` returns NULL and becomes Lua's ordinary out-of-memory error instead of aborting |
| `-sEXIT_RUNTIME=0 -sINVOKE_RUN=0 --no-entry` | completion is Titan-owned and the loader calls the entry; there is no native `main` (`--no-entry` is omitted for `lua-main`) |
| `-sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,node` | one ES-module factory call per instance, and one image for both engines |
| `-sFORCE_FILESYSTEM=1` | keeps Emscripten's filesystem and TTY layer in every image (see below) |
| `-sEXPORTED_FUNCTIONS=["_titan_browser_entry","_titan_browser_trace_identity","_malloc","_free"]` | the entry, the 64-hex image identity export, and heap allocation for argument marshalling; the `gate` purpose adds `_titan_browser_gate_guarded` and `_titan_browser_gate_observe`; `lua-main` exports `_main`, `_malloc`, and `_free` instead |
| `-sEXPORTED_RUNTIME_METHODS=["ccall","HEAPU8"]` | the Asyncify-aware call path and the heap view used by the loader |
| `-sINCOMING_MODULE_JS_API=["stdin","stdout","stderr","locateFile","onAbort"]` | the only module options the loader passes |
| `--js-library <sdk>/titan-browser-library.js`, `--js-library <sdk>/titan-browser-trace.js` | the completion/admission and eager trace-map/stack-capture imports (omitted for `lua-main`) |
| `-sASSERTIONS=<0\|2> -sSTACK_OVERFLOW_CHECK=2` | Emscripten detects reentry corruption only with assertions; the suites also pass with assertions off; stack checking stays on in both |

`compile_flags` is empty without an override. `identity_inputs` is plain data,
exactly `{target_identity, purpose, entry, assertions, optimization, asyncify,
budgets, link_flags, compile_flags}`, where `optimization` is the override or
else the last `-O` flag of the descriptor's compile prefix and `budgets` holds
all four effective sizes. Image certificates hash it together with the content
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

**`HEAPU8`.** `HEAPU8` is a runtime export so that the loader can write
arguments into heap memory and the completion import can copy its payload.
The loader keeps it private: it never publishes the Module, its memory, or a
general call bridge, and it reads `HEAPU8` again after every allocation that
can grow memory instead of retaining an old view.

**Internal selection.** `driver.browser_link_options` is a Lua field for
in-process harnesses (`{purpose=..., assertions=..., ...}`), set before
`titanc` runs in the same Lua process; there is no command-line option or
environment variable. Target initialization validates it against the built
descriptor, and an `optimization` override enters the descriptor's compile
prefix ([Compile prefix](#compile-prefix-and-target-defines)).
`driver.browser_link_plan(context, purpose)` returns the plan for those
options, or `{purpose=purpose or "program", assertions=2}` without them.

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
plus optional `profile`, `before_commit`, `after_publish`, `final_link_flags`,
and `dependency_output`) links one image:

1. require the SDK, select the plan (an explicit `options.profile`, otherwise
   `browser_link_plan`), and check the final link extras with
   `validate_extras`;
2. scan the runtime archive with the descriptor fingerprint and validate it
   structurally, as a provider;
3. compute the 64-character lowercase hexadecimal image identity
   ([Source-map extensions and image identity](#source-map-extensions-and-image-identity))
   from the original entrypoint contents and the link's canonical input recipe,
   inject `titan_browser_trace_image_id` and `titan_browser_trace_identity(void)`
   into the synthetic entrypoint C source, and compile it with
   `driver.generated_compile_prefix(context)` plus the plan's compile flags;
4. link into a staging directory beside the destination, under the final
   basenames so that the generated `.mjs` and `.wasm` (`sourceMappingURL`)
   locate `<basename>.wasm` and `<basename>.wasm.map` by name:
   `emcc <link_flags> -o <staged>.mjs <entry.o> <objects> <archives>
   <extra objects> -Wl,--start-group libtitan.a <archives> liblua.a
   -Wl,--end-group <link extras> <final_link_flags>`, capturing the linker
   trace when `dependency_output` is set;
5. require the staged `.mjs`, `.wasm`, and `.wasm.map` to be regular files,
   read the staged Wasm, run `browserlink.image_inventory` (which reads the
   final image's import and export sections and rejects any import named
   `dlopen`, `dlsym`, `dlerror`, or `backtrace`, with or without a leading
   underscore: `browser image imports forbidden symbol "<name>"`), and rewrite
   the staged `.wasm.map` in place with `browsertrace` so that `x_titan_image`,
   `x_titan_function_imports`, `x_titan_function_ranges`, and
   `x_titan_function_names` are bound to the final post-Asyncify `.wasm`;
6. run `before_commit` (which invalidates the link record);
7. move any existing `.wasm.map` (`browser source map output '<path>' is not a
   regular file`; `TODO(confirm: exact non-regular map diagnostic wording in driver.lua)`),
   `.wasm` (`browser Wasm output '<path>' is not a regular file`), and, when
   `after_publish` is set, `.mjs` (`browser module output '<path>' is not a
   regular file`) aside, rename the staged `.wasm.map` and `.wasm` into place,
   rename the staged `.mjs` over the destination, and run `after_publish`
   (`titanc` commits the link certificate there). The `.mjs` rename (followed
   by `after_publish` when present) is the commit point: if any rename or
   `after_publish` fails, the new files are removed and all prior artifacts are
   restored (`cannot restore browser module: <reason>; predecessor retained at
   <path>`, `cannot restore Wasm: <reason>; predecessor retained at <path>`,
   and `cannot restore browser source map: <reason>; predecessor retained at
   <path>`; `TODO(confirm: exact map restore diagnostic in driver.lua)`). An
   unextended `.wasm.map` is never visible at the published path. The backups
   are removed after the commit.

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
admitted run. A refusal allocates nothing and switches no fiber.

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

Before compiling the per-link synthetic entrypoint, `browsertrace` computes a
64-character lowercase hexadecimal SHA-256 identity using `incremental.digest`
under domain `"browser-trace-image"` (`TODO(confirm: exact function name in browsertrace.lua)`).
The hashed recipe is canonical and acyclic: the original entrypoint C source
(before injecting the identity declaration), the browser target descriptor
identity and toolchain, the effective entrypoint compile flags, the full
effective link flags (including user link extras and final dependency flags),
and ordered path-plus-content-digest lists for all user objects, `--c-source`
extra objects, provider archives, `libtitan.a`, `liblua.a` and its record, and
both Titan JavaScript libraries (`titan-browser-library.js` and
`titan-browser-trace.js`). No timestamps, random staging paths, inodes, process
IDs, or pre-Asyncify Wasm digests enter the hash. The synthetic entrypoint then
includes:

```c
static const char titan_browser_trace_image_id[] = "<64 lowercase hex>";
const char *titan_browser_trace_identity(void) {
    return titan_browser_trace_image_id;
}
```

`_titan_browser_trace_identity` is exported in every Titan-entry profile and
accessed in `titan-browser-trace.js` with a static property lookup
`wasmExports['titan_browser_trace_identity']` so Emscripten export minification
preserves it. Calling it returns the Wasm memory address of the 65-byte
NUL-terminated ASCII string.

After `emcc` finishes linking and running Asyncify/optimization, `browsertrace`
reads the final `.wasm` using the bounded section and LEB128 reader primitives
in `staticmetadata.lua` (accepting valid bounded padded LEB128 encodings as
#328 specifies, and rejecting duplicate relevant sections/subsections,
overrunning lengths, invalid UTF-8, or mismatched function/code counts) and
validates the emitted standard version 3 `.wasm.map` (rejecting invalid JSON,
wrong `version` or core field types, unsupported indexed-map `sections`,
malformed VLQ mappings, or out-of-range source/name indexes). It preserves all
standard source-map fields, selected physical `.titan` filenames,
`sourceMappingURL` relation, and unknown extensions, and adds four keys:

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
`locateFile('<generated-wasm-basename>.map')` (fetching it in browsers and
reading it from disk in Node), parses the JSON and `x_titan_*` extensions,
verifies that `x_titan_image` equals the string at
`wasmExports['titan_browser_trace_identity']()`, builds the typed-array lookup
index ([Browser trace backend](error-handling.md#browser-trace-backend)),
publishes a private result on `Module['titanBrowserTrace']`, and removes
`titan-trace-map`:

```text
{ state: 'ready' | 'degraded', reason: string | null,
  mapBytes: number, loadMilliseconds: number, indexBytes: number }
```

`mapBytes` is the UTF-8 byte length of the fetched `.wasm.map`,
`loadMilliseconds` measures the elapsed time from request/read start through
validated index readiness, and `indexBytes` is the sum of the retained typed
arrays' `byteLength`s (not total JavaScript heap usage). When the map is
missing, malformed, missing `x_titan_*` extensions, or mismatched with the
instantiated `.wasm`, `state` is `'degraded'`, `reason` records the failure, and
one console warning prefixed with `Titan browser trace: ` is emitted at load
time. Ordinary web pages still run in degraded mode; `titan-browser-run` and
`spec/browser/playwright-run.mjs` inspect `Module['titanBrowserTrace']` through
their factory wrapper after initialization and fail the run as a harness error
unless `--allow-degraded-trace` was passed.

Trace cost on the representative browser trace gate image (`TODO(confirm: fill in exact measured mapBytes, .wasm bytes, ratio, loadMilliseconds, and indexBytes across Node, Chromium, Firefox, and WebKit from integrator gate)`):

| Metric | Value |
| --- | --- |
| `.wasm` bytes / `.wasm.map` bytes (`mapBytes`) | `TODO(confirm)` |
| Retained typed-array index (`indexBytes`) | `TODO(confirm)` |
| Load and index time (`loadMilliseconds`, Node / Chromium / Firefox / WebKit) | `TODO(confirm)` |

### WebAssembly stack survey

Before finalizing the stack parser and WebKit renderer, a synthetic C/JS survey
(324 raw stack captures across nine call topologies, named and `name`-stripped
binaries, and default versus raised `Error.stackTraceLimit`) was recorded with
Emscripten 6.0.13 and `-O1 -fno-inline -fno-optimize-sibling-calls -gsource-map
-g2` plus the base Asyncify/longjmp link profile across six engines:

| Engine | Version | Platform |
| --- | --- | --- |
| Node / V8 | Node 24.19.0 (V8 13.6.233.17-node.51) | Linux x64 (bundled in emsdk 6.0.13) |
| Playwright Chromium | 141.0.7390.37 | Linux x64 (`mcr.microsoft.com/playwright:v1.56.1-noble`) |
| Playwright Firefox | 142.0.1 | Linux x64 (`mcr.microsoft.com/playwright:v1.56.1-noble`) |
| Playwright WebKit | 26.0 | Linux x64 (`mcr.microsoft.com/playwright:v1.56.1-noble`) |
| Host Chrome / V8 | 156.0.8078.79 (V8 15.6.75.27) | Linux x64 |
| Safari / JSC | 27.0.1 (macOS 27.0.1, build 26A434) | macOS arm64 (Apple M1) |

The survey established six implementation facts:

1. **V8 (Node, Chromium, host Chrome)** formats frames as
   `    at <module>.<func> (<url>:wasm-function[<N>]:0x<PC>)` when the `name`
   section is present and `    at <url>:wasm-function[<N>]:0x<PC>` when
   stripped (`wasm://wasm/...` in Node, `http://...` in Chromium/Chrome),
   preceded by an `Error: ...` title line. Both carry the decimal function
   index `N` and the module-relative hexadecimal byte offset `0xPC`.
2. **SpiderMonkey (Firefox)** formats frames as
   `<name>@<url>:wasm-function[<N>]:0x<PC>` (with an empty `<name>` when
   stripped) and no `Error` title line. After an outer or fiber
   `emscripten_sleep`, Firefox appends saved asynchronous ancestry starting at
   a frame line prefixed with `async*` (such as `async*handleSleep@...`), which
   repeats earlier suspended Wasm activations (`fiber_entry`, `survey_run`). The
   parser must stop at the first `async*` line rather than merely skipping
   JS-shaped lines.
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
5. **Effective depth limits (`Object.defineProperty` versus assignment).** Default
   `Error.stackTraceLimit` is 10 on V8 (leaving 9 Wasm frames), 100 on JSC, and
   absent on Firefox. Raising `Error.stackTraceLimit` via
   `Object.defineProperty` (which avoids invoking host setters) raises V8's
   capture depth as requested (615 frames captured for a 600-edge recursion at
   limit 1000). On JSC, `Object.defineProperty` updates the visible property
   value without updating JSC's hidden capture limit, which stays at 100 total
   frames (whereas direct `=` assignment updates the hidden state but cannot be
   used or restored through descriptors without side effects). On Firefox,
   neither `Object.defineProperty` nor `=` assignment raises synchronous capture
   past 128 frames. Both the 100-frame WebKit limit (D10) and the 128-frame
   Firefox synchronous ceiling (D11) are therefore documented engine truncation
   boundaries that set `TRUNCATED`.
6. **JS wrapper headroom.** In the 48-recursion survey cases, up to 12 non-Wasm
   frames interleaved with 54 Wasm frames on V8. Requesting 640 frames (512
   Wasm capacity + 128 headroom) covers normal wrapper overhead, and the
   adapter conservatively marks any capture that reaches the effective limit as
   truncated.

## Budgets

Every stack and memory budget is explicit and part of the image or SDK
identity:

| Budget | Setting | Emscripten 6.0.13 default | Notes |
| --- | --- | --- | --- |
| Main C stack | `-sSTACK_SIZE=1048576` | 64 KiB | The shadow stack for Lua C recursion and compiled Titan frames; native frames also use the engine's own stack. |
| Coroutine C stack | `-DTITAN_COROUTINE_STACK_SIZE=262144` (target define) | `titan.h` default 2 MiB | minicoro's virtual-memory allocator commits each stack eagerly when a coroutine is created and reclaims it (`munmap`) for reuse when the coroutine is destroyed; the grown WebAssembly linear memory does not shrink. |
| Outer Asyncify data | `-sASYNCIFY_STACK_SIZE=65536` | 4096 B | Allocated with `malloc` for each outer suspension. |
| Fiber Asyncify data | `-DMCO_ASYNCFY_STACK_SIZE=65536` (target define) | 16384 B | Added to every coroutine's allocation and to one static main-context buffer. |
| Linear memory | `-sINITIAL_MEMORY=16777216`, growth on, `-sMAXIMUM_MEMORY=2147483648` | growth off; 2 GiB maximum | The heap never shrinks after coroutines are destroyed, although freed blocks are reused. |

`spec/coder/browser_budgets_spec.lua` measures each budget just below and just
above its delivered limit with one-case Titan test images
(`spec/fixtures/browser_runtime/budget_probe.titan`, with the C helpers
`budget.c`, `budget_pad.c`, and `budget.h`) linked through the `budget`
profile, in all four cells (Node 24.19.0 and Chrome for Testing
156.0.8078.80, each with assertions 2 and 0). Every boundary is identical
across the four cells:

| Probe | Budget | Largest safe | First failing | Failure above the limit |
| --- | --- | ---: | ---: | --- |
| Titan recursion, 304 B frames | main C stack | 3424 frames | 3425 | abort (70): `Aborted(stack overflow (Attempt to set SP to ..., with stack limits [...]) ...)` |
| Fixed 256 B and 16 B C frames | main C stack | 1041632 B | 1041648 B | abort (70), `stack overflow`; 6944 B are used by entry and runner frames |
| Titan recursion in a coroutine | coroutine C stack | 855 frames | 856 | abort (70), `stack overflow` |
| Fixed C frames in a coroutine, without yielding | coroutine C stack | 260704 B | 260720 B | abort (70), `stack overflow`; 1440 B are used by the coroutine entry |
| 4 Titan + 5 Lua + n 32-register C frames across `emscripten_sleep(1)` | outer Asyncify data | 407 | 408 | trap (71), `unreachable`; the same depth plus 8 without waiting passes |
| The same mix across a coroutine yield | fiber Asyncify data | 409 | 410 | trap (71), `unreachable`; the same depth plus 8 without yielding passes |
| The same mix switching from the main context into a coroutine | minicoro's static `main_asyncify_stack` | 405 | 406 | trap (71), `unreachable` |
| The outer mix with `ASYNCIFY_STACK_SIZE=32768` (a reduced supplement) | outer Asyncify data | 196 | 197 | trap (71), `unreachable` |

The C stacks are checked: `-sSTACK_OVERFLOW_CHECK=2` bounds-checks every
function prologue, so an overrun aborts before it writes outside the stack
(the probes use fixed-size frames because a dynamic `alloca` bypasses that
check). An Asyncify data overflow is a bare `unreachable` trap whose message
blames `ASYNCIFY_STACK_SIZE` even when the cause is corruption, so a generic
`unreachable` is not attribution by itself; the paired no-wait controls are.

The recoverable limits are ordinary errors in every cell:

* recursion through nested `pcall` in loaded Lua reaches Lua's own limit and
  raises the catchable `C stack overflow` long before the 1 MiB stack is
  exhausted;
* a forced `mco_create` failure raises exactly `could not create coroutine:
  Out of memory`, and a fresh coroutine can then be created and resumed; and
* creating coroutines while a canary coroutine is parked grows memory through
  35 heap resizes from 16 MiB to the 2 GiB maximum, where the 5455th creation
  fails in `mco_create` with that same catchable error after 5454 succeeded.
  The parked canary still resumes while every owner is live; after the owners
  are released and collected, memory stays at 2 GiB but a fresh coroutine is
  created and resumed in the reclaimed space.

Because `-sABORTING_MALLOC=0` makes allocation failure return NULL, running out
of linear memory never aborts the instance. A coroutine's stack size changes
only through the target define, which is part of the compile prefix and the
descriptor identity; the native default stays 2 MiB. At 2 MiB, about 992
coroutines would fit in 2 GiB; 256 KiB admits 5454.

## Completion and output channels

`titan-browser-library.js` defines a private `$TitanBrowser` object inside
each generated factory, so every instance has its own state; there is no
process-global instance state. It is installed by the library's postset and
announces itself to the loader through the internal Module callback
`titanBrowserAttach`. Its other internal callbacks are
`titanBrowserSafePoint`, `titanBrowserTrap`, and `titanBrowserComplete`.

**Completion.** `titan_browser_complete` (signature `viiii`) copies the
payload with `HEAPU8.slice` while C still owns it, never retaining a heap view,
passes `(kind, status, bytes, count)` to the loader with an incremented
completion count, and schedules a safe point. It is the only result channel:
the loader ignores the entry's return value and the fulfilled value of its
`ccall` Promise, and Titan never consults `onExit`, `exitJS`,
`EXIT_RUNTIME`, or `keepRuntimeAlive`, because Emscripten leaks one keepalive
count per created fiber. `kind` is 0 (returned) or 1 (failed); `status` is a
signed 32-bit integer.

**Output.** The factory receives per-byte `stdout(byte)` and `stderr(byte)`
hooks, which Emscripten's TTY layer calls for every byte (with `null` for a
flush notification, which is ignored). The hooks only append to a
stream-local `Uint8Array` that doubles from 1024 bytes; they never decode,
forward to the console, or call user code while WebAssembly is live.
`stdin` returns `null`, so reads see end of file and no browser prompt can
appear.

**Safe points.** Sinks run only when `TitanBrowser.safe()` holds: no compiled
entry is live (`liveDepth` is 0), Asyncify's export call stack is empty, and
no fiber trampoline is running. The library queues at most one microtask at a
time that calls `titanBrowserSafePoint(suspensionPending)` when safe, after
every compiled export returns and after every completion and rewind. A fiber
switch alone is never a safe point, and nothing is delivered from Asyncify's
`sleepCallbacks`, which run inside a rewind. Because an already resolved wake
can run its rewind before the queued microtask, the `doRewind` wrapper first
delivers the fully unwound batch when safe. The three real delivery points
are therefore return from a WebAssembly entry, a fully unwound outer
suspension, and completion after the entrypoint's libc drain.

**Pinned seams.** The library wraps four Asyncify functions of Emscripten
6.0.13 instead of patching emsdk: `instrumentWasmExports` (to collect the
guarded export identities), `instrumentFunction` (an outer wrapper around each
export that counts depth, records a `WebAssembly.RuntimeError` as the original
trap through `titanBrowserTrap`, and schedules a safe point; it is stored in
`Asyncify.funcWrappers` so that rewinds use it and it stays live through
`maybeStopUnwind`'s whole fiber trampoline), `handleSleep` (sets
`suspensionPending` before the compiled caller unwinds and clears it when a
rewind finishes with no Asyncify data left; `Asyncify.State.Normal` alone is
not enough, because `currData` survives `stop_unwind`), and `doRewind`.

### The reentry guard

Re-entering an instance while an outer suspension is pending aborts with
`RuntimeError: unreachable`, detected only by assertion-mode checks; a
guarded export that unwinds or switches fibers must therefore refuse new
external admission. The guarded exports are `titan_browser_entry` and, in
gate images, `titan_browser_gate_guarded`; non-suspending exports such as
`malloc`, `free`, and `titan_browser_gate_observe` stay callable.

The library keeps two depths. `liveDepth` counts every live compiled entry,
including the internal `invoke_*`/`dynCall_*` reentries of the longjmp
lowering, and governs safe delivery. `admissionDepth`, the named Titan-facing
admission depth, counts only live guarded exports. During a rewind,
`continuing` holds the admission depth of the admitted continuation (one more
when the rewound function is itself guarded). `titan_browser_entry_allowed`
(signature `i`) returns 1 when the call is that admitted continuation at its
exact depth, or when the instance is not blocked, has no terminal failure, has
not completed, has no pending suspension, and the caller is the only live
guarded export (`admissionDepth == 1`; without Asyncify, in control images,
the depth condition is dropped). Keeping the internal longjmp reentries out of
`admissionDepth` is what lets a ready raw guarded call through while a
suspended one is refused. The C entry consults this import after its own
active and used flags, and the loader checks the same state before it
marshals anything.

The guarded identities are read with static property accesses,
`wasmExports['titan_browser_entry']` and
`wasmExports['titan_browser_gate_guarded']`. Emscripten's export-name
minification rewrites static accesses but not a dynamic `exports[name]`
lookup, so the guard survives minified images. The pinned Emscripten runs that
minification (`will_metadce`) only at `-O3` or a shrink level (`-Os`, `-Oz`),
not at the profile's `-O2`; a dedicated harness image linked with
`--ldflag=-Os` proves the minified case.

A refused external call through the loader rejects with `TitanBrowserError`
`TITAN_BROWSER_REENTRY`, `browser instance is suspended; reentry is not
allowed`, and a refused raw guarded C call returns `-1`. Neither touches Lua,
switches a fiber, completes the original run, or poisons it.

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
only after completion, a safe point, no pending suspension, and the freeing
of the argument storage; it resolves to `{kind: "returned" | "failed",
status, bytes}`. A sink failure, protocol failure, trap, or abort rejects
instead, and the first failure wins:

* `browser entry completed more than once` and `browser entry reported invalid
  completion kind <kind>` (`TITAN_BROWSER_PROTOCOL`) for a second or malformed
  completion, while an intact admitted run still finishes its cleanup;
* `browser entry returned without completion or suspension`
  (`TITAN_BROWSER_PROTOCOL`) when the entry has returned, nothing is pending,
  and no completion arrived;
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
physically and requires `node --version` to report `v24.`. Failures exit 75
with empty stdout:

```text
titan-browser-run: Node 24 is required (node not found (TITAN_NODE unset; not on PATH))
titan-browser-run: Node 24 is required (node not executable at "<path>")
titan-browser-run: Node 24 is required ("<path>" reports <found>; expected Node 24)
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
browser runner (Node 24)`, both to stderr with exit 0. `FILE` must be a
regular `.mjs` file beneath the root, which defaults to its directory. Stdout
carries only program bytes; every runner diagnostic goes to stderr.

**Probe.** `--probe` (with an optional `--chrome`) needs no file, SDK, or
browser launch. It prints exactly one LF-terminated JSON object:

```text
{"node":{"path":"<absolute>","version":"v24.x.y","ok":true,"reason":null},
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

**Node engine.** The supervisor spawns a separate Node 24 worker
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
factory resolves and before entry, the wrapper inspects
`Module['titanBrowserTrace']`: when `state === 'degraded'` and
`--allow-degraded-trace` was not enabled, the run fails as a harness failure
(exit 75) even if the program or tests would otherwise pass, so missing or
stale `.wasm.map` files fail in CI; fabricated transport test fixtures that do
not link `titan-browser-trace.js` omit `titanBrowserTrace` and are unaffected.
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
portable `run(context)` host tests across Playwright-managed `chromium`,
`firefox`, and `webkit` (`playwright@1.56.1`), `spec/browser/playwright-run.mjs`
reuses `titan-browser-page.mjs`, the loopback root/SDK HTTP server, and the
same completion, abort, and `--allow-degraded-trace` rules with an explicit
`--engine chromium|firefox|webkit` (`context.engine` reflects the selected
engine; `TODO(confirm: exact CLI flags of spec/browser/playwright-run.mjs)`).
It is repository test infrastructure, not an installed SDK binary.

## The executing protocol runner

`driver.run_standalone_archive_probe(entries, module_names, libnames,
static_archives, link, verbose, extra_objects, options)` keeps its native
contract for host contexts. With a browser `options.context` and at least one
module, it:

1. requires the SDK and a working Node 24: `driver.browser_node_ready` runs
   `<runner> --probe` and maps the runner's Node diagnostic to `browser
   provider validation requires Node 24: <reason>; set TITAN_NODE to a Node 24
   executable`;
2. renders the probe as a browser C image (`program_name`
   `titan-provider-probe`, state status 10) whose worker checks, for each
   module, that `<prefix>_init` and `luaopen_<prefix>` are non-null (20) and
   that `<prefix>_abi`, `<prefix>_types`, and `<prefix>_layouts` each return
   one string (21, 23, 25) equal to the embedded metadata (22, 24, 26), and
   returns 0 when all pass;
3. links it in a temporary path under the output root with the `protocol`
   profile, against `libnames` and `static_archives` (`selected static provider
   failed executable-context protocol linking (<reason>[, exit <code>])`);
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

The browser scheduler design depends on one premise: the main (scheduler)
context can suspend through Asyncify, return to JavaScript, and later resume
while real Titan coroutines stay parked on their own minicoro fibers. That
premise is retained. The rules that follow from it bind the browser runtime
and its later scheduler:

* only the scheduler's main context suspends;
* results and exit status travel through Titan-owned completion, never through
  `ccall {async: true}` values, `main`'s return value, or `exit()`/`onExit`;
* the reentry guard covers every export that unwinds or switches fibers;
* Asyncify budgets are explicit;
* the coroutine stack size comes from a target define; and
* output uses per-byte hooks.

Suspending inside a fiber works but parks its resumer and starves every other
coroutine, so it is not a scheduling mechanism.

The decision rests on `spec/coder/browser_entry_gate_spec.lua` and its
fixtures in `spec/fixtures/browser_runtime/` (`entry_gate.titan`,
`final_fiber.titan`, `gate.c`, `gate.h`, `entry-gate.mjs`). Test-only C
exports perform real outer suspensions on the main context, through
`emscripten_sleep` and through an `EM_ASYNC_JS` `setTimeout` wait, and native
Titan tests drive them through the production loader and runner. Each of the
four cells (Node 24.19.0, then Google Chrome for Testing 156.0.8078.80 over the
CDP pipe, each with `-sASSERTIONS=2` and `-sASSERTIONS=0`; Emscripten 6.0.13)
runs 15 count-checked native cases: three early repeated instantiations of
one factory, the nine-item selection, an isolated responsiveness case, a
busy-wait control, and the fiber-internal-sleep negative, plus standalone
final-fiber status runs. Every item passed in every cell with both wait
forms:

| Item | Observation in every cell |
| --- | --- |
| 1. Return to JS, later completion | The host regained control before completion with 4 mixed owners parked, holding 16 authored FFI frames, recursive Titan depth 4, loaded-Lua depth 6, and recursive authored C depth 4; 4 pending defers retired after resumption. |
| 2. Interleaving | Per wait form, 64 coroutines × 20 outer waits: 1280 real suspensions and 1344 sequence and stack-canary checks. |
| 3. GC while parked | 8 parked owners, one full collection and 80 generational steps across 4 waits; 168 checks intact. |
| 4. Errors after resumption | A `catch` set before the suspension received an error raised after the rewind; success and failure paths each ran 2 ordered defers once. |
| 5. Nested and tagged coroutines | 2 nested coroutines and a tagged nonlocal transfer kept their identity across 2 waits. |
| 6. Promise entry | Completion statuses 0, 7, and 2 were exact, including when the last action was a fiber switch; `ccall` values were never read as results. |
| 7. Responsiveness | See below. |
| 8. Reentry refused | A ready raw guarded call ran a real `setjmp`/`longjmp` and returned 1; during a suspension a JavaScript timer saw the exact wrapper rejection and a raw `-1`, the observe export stayed callable, the original wait completed, and no `unreachable` occurred. |
| 9. Close | `lua_close` retired 3 retained nested pairs: 6 exact deferred identities ran once, and no abandoned `catch` or continuation body ran. |

Each nine-item selection made exactly 2578 outer waits per cell. The
per-suspension cost of item 2's 1 ms waits, which includes the requested wait
and scheduling, was about 1.1 ms under Node and about 4.2 ms under Chromium,
whose timers clamp near 4 ms:

| Assertions | Engine | `emscripten_sleep` (ms) | `EM_ASYNC_JS` (ms) |
| ---: | --- | ---: | ---: |
| 2 | Node | 1.172 | 1.100 |
| 2 | Chromium | 4.217 | 4.238 |
| 0 | Node | 1.134 | 1.112 |
| 0 | Chromium | 4.184 | 4.172 |

Item 7 runs a 10 ms `setInterval` during a 600 ms outer wait (300 ms per form).
Its window starts at the first fully unwound pending safe point, not before
startup work, and ends at completion; both the full host window and the wait
window are recorded. The thresholds are a tick ratio of 0.75 to 1.25 of the
elapsed time over 10 ms, a largest gap of at most 100 ms, and, in Chromium, at
least 2 `requestAnimationFrame` callbacks; a separately timed 150 ms busy-wait
control must see exactly 0 ticks over at least 140 ms:

| Assertions | Engine | Host / wait window (ms) | Ticks | Ratio | Largest gap (ms) | RAF | Busy control |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 2 | Node | 601.7 / 600.2 | 59 | 0.983 | 10.4 | — | 152.1 ms, 0 ticks |
| 2 | Chromium | 603.6 / 601.6 | 60 | 0.997 | 10.1 | 37 | 155.8 ms, 0 ticks |
| 0 | Node | 602.8 / 601.4 | 59 | 0.981 | 10.7 | — | 152.7 ms, 0 ticks |
| 0 | Chromium | 605.0 / 602.5 | 60 | 0.996 | 10.8 | 37 | 153.0 ms, 0 ticks |

In the fiber-internal negative, a 60 ms sleep inside a fiber left an
already due ticker 50.3 to 51.4 ms late, with no peer step during the sleep.
The responsiveness and per-suspension numbers are those of the current link
profile, including `-sFORCE_FILESYSTEM=1`, under which every item observation
above also holds. A change to the entry, the guard, or the fiber
configuration requires running the gate again; a failure permits only an
Asyncify configuration or ownership correction, and any other scheduler
design needs a new decision with fresh evidence.

## Baseline

The size and speed baseline is a measurement, not a gate. It feeds the later
release-profile and packaging work. `scripts/browser_baseline.lua` builds the
micro-benchmark program (`spec/fixtures/browser_baseline/`) through the
`baseline` profile (`entry = "titan"`) and the fork's Lua interpreter (`entry
= "lua-main"`, built from `lua-5.5.1/src/*.c` with the profile's flags) at
`-O1` and `-O2`, each with and without Asyncify (the Asyncify-off controls
create no coroutine of either kind and never suspend), in separate output
trees, and runs each image three times per engine; every published value below
is the median of the three raw repeats (`format = "titan-browser-baseline-2"`).
Toolchain: Emscripten 6.0.13, Node 24.19.0, Google Chrome for Testing
156.0.8078.80 headless shell, fork commit `4f740a4b`, all with
`-sFORCE_FILESYSTEM=1`.

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
  standalone `-shared-mem` rule, mixed formats and features, bitcode, and
  `incremental.native_input_kind`.
* `spec/browser_target_spec.lua` — the descriptor with hand-made records and
  fake tools: freezing, every record and tool diagnostic, the three target
  defines, flags, paths, include-root resolution, the probe-cache directory,
  worker import, the compiler-probe feature diagnostic, the browser
  `--coverage` refusal, and the Windows host scope.
* `spec/browser_isolation_spec.lua` — semantic-cache generations and guards,
  the native → browser → native sequence, output markers, toolchain-detail
  hashing, and unchanged native link records.
* `spec/coder/browser_providers_spec.lua` — provider lookup, structural
  validation, archive-only publication with executing validation and its
  failure boundaries, companions, and the process audit
  (`spec/support/browser_process_audit.lua`).
* `spec/coder/browser_images_spec.lua` — the link profile and its owned
  options, missing-SDK and `.mjs` diagnostics, program and test images with
  statuses, binary arguments, uncaught reports, protected initialization and
  allocation failures, the libc drain, the stdio-only filesystem regression,
  dynamic-loading guards, three-file certificates and rollback, image
  inventories, measurement optimization, and the native libbacktrace and
  fallback trace invariants.
* `spec/browser_trace_map_spec.lua` — final-image Wasm section/range/name
  extraction, standard v3 `.wasm.map` validation, `x_titan_*` extension
  rewriting, malformed/truncated Wasm and map rejection, three-file rollback,
  and link-certificate invalidation when `.wasm.map` changes.
* `spec/coder/browser_trace_entries_spec.lua` — browser-only
  `registry[TITAN_ENTRIES_KEY]` registration across all `titanentry` wrapper
  families, split-unit deduplication, early `_init` ordering before
  dependencies and user initializers, and byte-identical native code
  generation.
* `spec/coder/browser_protocol_spec.lua` — the executing check, corrupted
  providers (exits 21 to 26) without publication, re-execution before
  identical-archive reuse, probe cleanup, and archive-only consumers on both
  engines.
* `spec/browser_sdk_spec.lua` — `make lua-browser` reuse and rebuild,
  `make browser-sdk` into an empty root, differing roots, digest order and
  contents, and the standalone `-shared-mem` archive regression.
* `spec/coder/browser_entry_gate_spec.lua` — the [entry gate](#the-entry-gate-decision).
* `spec/coder/browser_fixtures_spec.lua` — the coroutine and GC behavior in
  the owning `coroutine.tests` and `gc.tests` modules built for the browser,
  and the real browser trace, pin, bare rethrow, and coroutine-append cases
  under Node and Chromium.
* `spec/coder/browser_budgets_spec.lua` — every [budget](#budgets) just below
  and just above its limit.
* `spec/minicoro_spec.lua` — the Emscripten lane of the tagged-behavior probe
  (fiber backend with and without `MCO_NO_DEBUG`, `MCO_USE_VMEM_ALLOCATOR`,
  and the tag comparator) and the unwind-floor harness under both engines, and
  the no-Asyncify control, which must fail with `ASYNCIFY is not enabled`.
* `spec/browser/loader.test.mjs` with `spec/fixtures/browser_loader/` — the
  portable loader suite under both engines and both assertion modes:
  byte fidelity, statuses, sinks, reentry, 50 collectable create, run, and
  dispose cycles, concurrent instances, lifecycle races, and the minified
  guard image (`optimized-guard.mjs`).
* `spec/browser/runner.test.mjs` and `spec/browser/runner-fixtures.mjs` — the
  runner's resolver, probe, CLI, status categories, grace, abort and cleanup
  boundaries, process-group retirement, and path containment, over Node and
  both Chromium transports.
* `spec/browser/trace-adapter.test.mjs` and
  `spec/fixtures/browser_trace_adapter/` — Node unit tests for the V8,
  SpiderMonkey, and JavaScriptCore stack parsers (built from the recorded survey
  strings), `Error.stackTraceLimit` and `Error.prepareStackTrace` descriptor
  preservation (absent, data, accessor, non-writable, and non-configurable
  descriptors without invoking getters or setters), lookup boundary and gap
  validation, and degraded/capture-failed fallbacks.
* `spec/browser/build-trace.lua`, `spec/browser/trace.test.mjs`,
  `spec/browser/playwright-run.mjs`, and `spec/fixtures/browser_trace/` — the
  staged multi-engine browser trace gate (`assertions-2` and `assertions-0`,
  normal and `--allow-degraded-trace` manifest rows) covering direct and
  `.browser.titan` contributor locations, deep recursion and engine truncation,
  mixed `Lua -> Titan -> Lua -> Titan` merge order, all wrapper families, fresh
  raise versus bare rethrow, coroutine append across yield/resume, adjacent
  unmapped helpers, immediate literal calls, merge `LUA_ERRMEM` recovery, and
  WebKit reduced-fidelity rendering across Node, Chromium, Firefox, and WebKit.

The Busted files need emcc 6.0.13 and the installed browser Lua; the image,
protocol, SDK, gate, fixture, budget, and minicoro files also need Node 24, a
headless Chromium, and an installed browser SDK, which
`spec/support/browser_toolchain.lua` discovers through `require({node=true,
chrome=true, sdk=true})` and the runner's `--probe`. Each real case is pending
when a capability is absent; `TITAN_REQUIRE_BROWSER_TOOLCHAIN=1` turns absence
into a failure, and a present but malformed SDK or probe result always fails.
The Linux CI job that runs them is described in
[Continuous integration](continuous-integration.md#browser-toolchain-job).
