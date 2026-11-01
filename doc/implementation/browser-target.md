# Browser target

`titanc --target browser` compiles Titan modules and authored C to
relocatable WebAssembly objects with Emscripten, and publishes library-mode
providers as self-describing Wasm archives. The target is compile-only:
nothing in it links, loads, or runs a Wasm image. Program and test linking stop
with a fixed diagnostic until [#329](https://github.com/mascarenhas/titan/issues/329)
adds the browser SDK, the loader, and the executing protocol runner. The user
contract is in the [browser-target chapter](../language/browser-target.md) of
the language manual.

The implementation is spread over:

* `titan-compiler/browsertarget.lua`, which locates and pins the Emscripten
  tools, reads and verifies the fork's Lua build record, probes the target C
  facts, and builds, freezes, exports, and imports the browser target
  descriptor;
* `titan-compiler/driver.lua`, which owns `installed_paths(root, target)`,
  context initialization and activation, the semantic-cache generation, the
  probe-cache and output-root isolation, worker transport, browser provider
  lookup, archive construction, structural validation, archive-only
  publication, and the program-link stops;
* `titan-compiler/staticmetadata.lua`, with the bounded relocatable-Wasm reader
  and the Wasm target fingerprint
  ([Static compiled modules](static-compiled-modules.md#relocatable-webassembly));
* `titan-compiler/incremental.lua` and `titan-compiler/linkcertificate.lua`,
  which fold the descriptor identity into object and link certificates;
* `titanc`, which validates the target, requires `--output`, locks and marks
  the output root early, and selects the archive-only output set; and
* the runtime headers `titan.h`, `titan/ffi.h`, and `transfer.h`, which carry
  a `__wasm__` include branch.

The source label and the target name are both `browser`. `wasm32` is a
physical ABI and toolchain fact only: it never names a target, an SDK path
component, or a cache label.

## Scope

The browser target supports three kinds of work, all with an explicit
`--output` directory:

* object compilation with `-c` (with or without `--incremental`), including
  `--c-source` nodes compiled with the descriptor's `emcc` prefix;
* library mode: a no-`main` build publishes `<provider>.a` only, after the
  [structural validation](#library-mode-and-structural-validation) below; and
* the C-only work these require: preamble, profile, enum-carrier, and
  acceptance C probes, and C-header preprocessing for `foreign import`.

Program and test linking stop before any runner or entrypoint synthesis,
native link discovery, or execution (see [Program and test
linking](#program-and-test-linking)). The language server analyzes the
host-native selection only: it ignores `TITAN_TARGET` and creates no browser
context.

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

Steps (4) to (6) and those diagnostics belong to #329. In the current
compiler, every program and test link stops with the fixed diagnostic below,
whether or not a browser SDK exists, and object and archive work never checks
for one. `luarocks make` stays independent of emsdk.

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
and archive work never checks for them.

The browser root is `driver.TITAN_ROOT`. In the supported layout `PREFIX` and
`ROCKS_TREE` are equal, so the fork's `PREFIX/lib/browser` is visible there.
A checkout compiler also takes the browser Lua pieces from `TITAN_ROOT`, never
from the checkout's native `lua-5.5.1/src`; only its runtime headers come from
the checkout's `titan-runtime/`. An unknown root stops initialization with
`cannot locate the Titan installation root; set TITAN_ROOT to the installation
prefix`.

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
13. A trivial Titan-flag object compiled with `emcc` has exactly the expected
    Wasm fingerprint, which cross-checks the baseline features against the
    actual toolchain.

The Lua archive itself is hash-verified, not feature-compared: Lua's `ldo.o`
calls `setjmp` and legitimately adds `-shared-mem`. Exact feature equality
applies to Titan objects and Titan provider archives. A Wasm-exceptions mode
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
fingerprint probe of step 13 disagrees, the `wasm_features` diagnostic carries
the fingerprint mismatch description in the `recorded` slot and the baseline
as `expected`.

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
  target_defines = { "-DTITAN_TARGET_BROWSER=1" },
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

1. `--std=c99`, `-O2` (`-O0` under the `validation` build profile), `-Wall`,
   `-Wno-unused-but-set-variable`, `-Wno-unused-function`,
   `-gline-tables-only`, and `-sSUPPORT_LONGJMP=emscripten`;
2. the record's `lua_defines`, in record order;
3. the ordered `target_defines`, currently only `-DTITAN_TARGET_BROWSER=1`;
   and
4. the normalized invocation compile extras: `driver.NATIVE_COMPILE_FLAGS`
   when `titanc` installed them (environment extras, then CLI `-I`, `-D`, and
   `--cflag` in written order), otherwise `TITAN_EXTRA_CPPFLAGS` followed by
   `TITAN_EXTRA_CFLAGS`.

There is no `-fPIC` and no LTO. The optimization and debug levels are
provisional; the final browser profile belongs to a later milestone, and
#329 owns every link setting. The host descriptor emits no new define. The
target defines reach generated C, `--c-source` nodes, C probes, and FFI header
preprocessing, because all of them use the same prefix, so the standard library
and C headers read target constants through `foreign import`.

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
  owner it replaces `driver.imported` and `types.registry` with fresh tables,
  advances the process generation, and records the new owner. It stamps the
  context with the current generation. Same-target contexts keep the warm
  caches and the existing behavior.
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
and both borrowed-context forms of the resolver option adapter. Pure file
revalidation (`perf.restat_c_header_dependencies`) is not a semantic consumer:
uncertified publication calls it with a fresh I/O and header memo that carries
no generation.

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
* **Links.** The final-link key remains a digest of the output paths only. For
  browser, `titanc` writes the descriptor identity into `policy.target`, and
  `linkcertificate.prepare` copies the recipe policy and sets `target` to the
  identity without mutating the caller's table, so a record written by another
  target or another browser configuration is a miss. Host `policy.target`
  remains the native profile identity.
* **Archive backend.** A browser link record uses backend `archive`: the
  output tools are the descriptor's `emar` and `emranlib`, observed without
  linker selection, compiler link-stage discovery, or native library
  execution, and the native library policy carries no native link inputs.
  Opaque link-flag mechanisms and uncertified inputs still make the record
  uncacheable; the browser backend is not a permissive fallback.
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

The browser SDK root is empty until #329 installs the runtime and standard
library, so in this milestone a browser compilation finds only browser
archives on its Titan path and source modules.

## Library mode and structural validation

A no-`main` browser build publishes one archive. `driver.provider_output_path`
uses the `.a` extension, the certified output set is `{<provider>.a}`, the
native runtime link inputs are skipped, and `driver.link_provider_pair`
dispatches to `driver.stage_browser_provider`:

1. compile the objects; `driver.derive_target_fingerprint` cross-checks the
   first generated object against the descriptor fingerprint, and every other
   generated object and split part must match;
2. stage the archive with `driver.build_static_archive(..., context)`, which
   requires the target to equal the descriptor fingerprint (`browser archive
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
7. publish only `<provider>.a`, with the archive rename as the commit point.

Structural validation, the companion refusal, and publication are specified in
[Static compiled modules](static-compiled-modules.md#browser-archive-only-providers).
It is a real check, not a disabled one: it verifies the protocol symbols and
imports the host loader would otherwise inspect, and #329 adds the executing
check on top.

## Program and test linking

Every browser program and test link stops with `browser program linking is
not available yet`: `titanc` checks `--test` without `-c` before planning and
a detected `main` before output selection, the preflight checks a planned
program, and `driver.run_standalone_archive_probe` and `driver.compile_program`
refuse a browser context. The stop precedes runner or entrypoint synthesis,
native output and link discovery, and execution. #329 replaces it.

## No executing probes

No browser path executes a Wasm or host program. The only subprocesses are
`emcc` compile-only and preprocessing commands (`-c`, `-E`, `-fsyntax-only`),
the one `emcc --version` query, the archive tools' deterministic capability
probes (which capture and discard tool stderr/stdout) and archive operations,
and the compiler's own worker frontends. The fresh-process provider validation,
the archive-backed validation image, the standalone archive probe, `_loadlib`,
and the native runtime build are never entered.

## Windows and other hosts

Browser builds are supported from Linux and macOS hosts. On Windows, and on a
native host without an OS label, `driver.validate_target` and the library
initialization boundary both reject the target with `browser builds are
supported from Linux and macOS hosts (host is <host>)`:
`browser builds are supported from Linux and macOS hosts (host is windows)` on
Windows, and `browser builds are supported from Linux and macOS hosts (host is
native)` on an unlabeled native host. The fork's `make install-browser`
likewise refuses a native Windows shell.

## Validation

* `spec/staticmetadata_spec.lua` — synthesized Wasm objects and archives:
  payload readback, padded LEB128, every malformed case, fingerprints, mixed
  formats and features, bitcode, and `incremental.native_input_kind`.
* `spec/browser_target_spec.lua` — the descriptor with hand-made records and
  fake tools: freezing, every record and tool diagnostic, flags, paths,
  include-root resolution, the probe-cache directory, worker import, and the
  Windows host scope.
* `spec/browser_isolation_spec.lua` — semantic-cache generations and guards,
  the native → browser → native sequence, output markers, toolchain-detail
  hashing, and unchanged native link records.
* `spec/coder/browser_providers_spec.lua` — provider lookup, structural
  validation, archive-only publication and companions, the link stops, and
  the process audit (`spec/support/browser_process_audit.lua`).
* The real-toolchain gate files `spec/wasm_toolchain_spec.lua`,
  `spec/coder/browser_toolchain_spec.lua`,
  `spec/coder/browser_providers_spec.lua`, and
  `spec/coder/browser_incremental_spec.lua` need emcc 6.0.13 and the fork's
  installed browser Lua (`spec/support/browser_toolchain.lua`). Each real case
  is pending when they are absent; `TITAN_REQUIRE_BROWSER_TOOLCHAIN=1` turns
  absence into a failure. The Linux CI job that runs them is described in
  [Continuous integration](continuous-integration.md#browser-toolchain-job).
