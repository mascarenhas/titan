# Browser playground bundle

`make playground-sdk` builds the files the [Titan playground](https://titan-lang.dev/play/)
loads: the Titan compiler as a WebAssembly module, its JavaScript adapter, the
semantic assets the compiler checks against, and the link-only browser SDK the
page compiles and links user C against with its own in-browser C toolchain.
Everything is derived from the installed **validation** browser SDK and this
checkout; nothing installed is modified.

The page never runs `titanc`, a coordinator or a subprocess. The compiler
checks, describes, completes and emits C entirely in memory; the page compiles
the C, links it with the bundle's archives, runs Binaryen and hands the
optimized image back for its trace table and loader module, exactly as
[`driver.compile_browser_image`](browser-target.md#program-and-test-images)
does for a native build.

## Building the bundle

```sh
make playground-sdk PREFIX="$PREFIX" PLAYGROUND_OUT=/path/to/bundle
```

The prefix must hold a validation installation with its browser Lua and SDK
(`make lua-browser`, `make browser-sdk` with `TITAN_BUILD_PROFILE=validation`);
a production SDK is refused. The recipe needs the browser toolchain
(`wasi-sdk` 34 and Binaryen `version_133`, discovered as for `--target browser`)
and Node 26 or newer (`TITAN_NODE` or `node`) for its final check.
`TITAN_PLAYGROUND_BUILD_DIR` (default `out/playground-build`) holds
intermediate outputs; keep it inside the checkout so its relative layout, and
with it the bytes, stay the same on every machine.

Before writing or removing anything, the recipe checks both directories by
their physical paths. Neither may overlap the checkout's `titan/` sources,
the installation, the prefix, `wasi-sdk` or the other. Each must be missing,
empty or marked by an earlier run: the build directory with
`.playground-build`, the output directory with `.playground-bundle`, a hidden
marker the packager never reads (it reads the bundle's files by name). Only
the build directory's own contents are ever replaced. The output directory
may not be a symbolic link, and a marked one may hold only the bundle's file
names (and `LICENSES/` only the checkout's notices), which the run replaces.
File names alone never prove ownership. Anything else is refused with nothing
changed.

| File | Contents |
| --- | --- |
| `titanc.wasm`, `titanc.mjs` | The compiler and its adapter (`openCompiler`). |
| `stdlib_catalog.bin` | The provider's metadata, captured from one validated scan ([semantic catalog](#the-semantic-catalog)). |
| `analysis-target`, `absent-modules` | The SDK's semantic assets, `analysis-target` rebound to the bundle's `titan.a`. |
| `stdlib-sources.json` | `{ "titan/…": source }`: every selected source file of every provider module, keyed by its checkout-relative path. |
| `titan.a` | The [link-only provider](#the-link-only-provider): the browser standard library without object source records. |
| `libtitan.a`, `libtitan-lpeglabel.a`, `liblua.a` | The runtime, LPegLabel and browser Lua archives a program links. |
| `headers.tar` | Two include roots, `lua` (the verified browser Lua headers) and `sdk` (`browsertarget.SDK_HEADERS`), as a deterministic ustar archive with relative names of at most 100 bytes and directory entries without a trailing slash. |
| `link-plan.json` | `compile_flags`, `include_roots` and the program profile's `link_flags` and `optimizer_flags`, all from the real validated [descriptor](browser-target.md#the-descriptor). |
| `titan-browser.mjs`, `titan-wasm-factory.mjs` | The SDK loader and factory `build_trace` embeds. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md`, `LICENSES/` | Notices for every redistributed file. |

`scripts/playground_sdk.lua` builds them in order:

1. The runtime and LPegLabel archives, compiled by `titanc --target browser -c
   --c-source` from the same sources and descriptor flags as the SDK's, with
   members named after their sources.
2. The browser standard library roots, rebuilt with `--no-source-records`
   against that LPegLabel archive into `titan.a`, which must stay under the
   site's 25 MiB per-file limit. The build claims its output directory for the
   browser target (`driver.validate_output_target`, as titanc claims an empty
   one), copies the checkout's `titan/` tree inside it, and runs there with
   `TITAN_PATH_0_6=.`.
3. `analysis-target` with `provider_sha256` set to the new archive's digest
   (`browsertarget.encode_analysis_data`), and the catalog from
   `driver.browser_analysis_target` over that semantic pack.
4. `stdlib-sources.json`, from `driver.resolve_source` on a browser analysis
   context.
5. `link-plan.json`, from `driver.context_target_descriptor` and
   `browserlink.profile(descriptor, { purpose = "program" })`, with the
   script's own build flags cleared first.
6. `headers.tar`.
7. `titanc.wasm`.
8. The remaining archives, JavaScript and notices.
9. `scripts/playground_smoke.mjs`, which opens the new compiler over its own
   catalog and checks, describes, completes and emits a two-module program.

### Reproducible bytes

The bundle is byte-identical for the same sources and tools wherever the
checkout, prefix and `wasi-sdk` live. Every C object it ships is compiled with
`-ffile-prefix-map` entries that rename the checkout and the provider's
source copy to `.`, the installation to `titan-sdk` and `wasi-sdk` to
`wasi-sdk` (sorted so the most specific prefix wins), so neither line tables
nor `__FILE__` strings name a host path, and provider line tables name
`./titan/...`. A provider module's interface names the C types it uses by
the identity of their declaring header, which is a path; the source copy puts
the headers beside the library's sources under the build's output root, which
the compiler [relocates](incremental-compilation.md) to `<titan:output>`, so
those identities do not name the checkout either. The browser Lua archive
belongs to the fork's own build, whose line tables name the builder's paths;
Lua's C rows never reach a trace table (it keeps only `.titan` rows), so the
bundle's copy is the SDK archive with its debug sections removed
(`llvm-objcopy --strip-debug`). The tar writer zeroes owners and times, JSON
objects are written with sorted keys, and the catalog is a `graphcodec`
encoding with canonical key order.

## The link-only provider

`titanc --no-source-records` omits the trusted source record
([`objectmetadata`](incremental-compilation.md#trusted-source-record)) that
every module object normally carries in its `.titan.source` section. For the
standard library that record is about 8.8 MiB of a 32 MiB browser `titan.a`;
without it the archive keeps its public `.titan.meta` metadata, nominal
layouts, initializers, function names and `.debug_line`, and links and
archives exactly as before.

The build coordinator still needs each record: workers restore planned
dependencies from it and publication revalidates the module's inputs against
it. Under the option the record travels in memory instead:

- `prepare_compile` still certifies and encodes the record but does not
  append its rendering to the primary C file; the materialized compilation
  carries the encoded `record_payload`.
- The worker returns it as its result's `interface`, beside the staged
  objects.
- `driver.publish_staged_module` decodes that record instead of reading the
  staged object, revalidates and publishes the objects as usual, and keeps the
  payload as the certified `interface`.
- `driver.plan_descriptor` hands a dependency's certified `interface` to every
  later worker, which restores the dependency from it.

The policy is part of `context.codegen_policy` (`source_records = false`) and
of the worker configuration. Because no object can be restored afterwards,
`titanc` rejects the option with `--incremental`, `-c` and `--print-ast`.

## The semantic catalog

`driver.browser_analysis_catalog(handle)` encodes the provider of a handle that
`driver.browser_analysis_target` scanned from its archive: for each module its
canonical metadata payload and its archive member description (the origin
without the archive path), plus `format`, the compiled-module ABI and the
analysis-target's `provider_sha256`. The encoding is deterministic, so the
same archive gives the same catalog at any path.

`driver.browser_analysis_target(prefix, { catalog = bytes })` reads
`analysis-target` and `absent-modules` from the prefix as usual but never reads
`titan.a`. It requires the catalog's ABI and provider digest to match, then
validates every payload exactly as an archive scan validates its members
(`staticmetadata.metadata_view`, including the types and the target profile)
and builds the same immutable handle; its `provider_file` is the would-be
archive path. A catalog handle cannot produce another catalog. Archive
structure (Wasm members, symbols, forbidden imports) was validated by the scan
that produced the catalog.

## Emitting C without a toolchain

A resolver context with `target = "browser"`, a `browser_analysis_target`
handle and `emit_c_only = true` checks with the compiled-module ABI (runtime
erasure on, `analysis_only` false) against the handle's provider, and never
builds a descriptor, compiles, links or writes outside its I/O strategy. Like
an analysis context, it checks foreign C with the analysis toolchain started
through its strategy, which the playground's in-memory strategy cannot start,
so there foreign C is a diagnostic. It rejects `analysis_only`, completion
options, an `output_root` and
a target descriptor. The handle's provider entries carry their actual
dependencies (`imports`, `source_requirements`, `dynamic_providers`) and
decoded nominal layouts in such a context, decoded once per handle.

After `driver.finalize_resolver_context`, `driver.emit_module_c(context,
modname)` returns one checked source module's translation unit and generated
headers, `{ unit = { filename, code }, headers = { ... } }`, named after the
module's logical path (`a/b.c`, `a/b.ffi.h`, `a/b.priv.h`). It runs the same
generation as object compilation (`perf.generate_module_code`, which
`prepare_compile` also calls) with one part, so the unit is the object
compilation's C with two differences: no source record is appended, and every
include of a generated header is relative. The unit includes its `.ffi.h`
(and, with foreign functions, `.titan.h`) by the leaf name beside it, and a
generated header includes an explicit source dependency's header by its path
relative to its own, so the emitted files compile wherever they are placed.
The image entry is `driver.browser_entrypoint_contents(main, nil, { context =
context })` followed by `browsertrace.declaration(identity)`, emitted as
`.titan-links/main/synthetic/main__entrypoint.c`: like titanc's synthetic
entry it lives in a `.titan-links` directory, whose dot-led name no module
stem can have, so no module's unit can collide with it.

## The compiler Wasm

`titan-runtime/playground/titanc.c` owns one Lua state. It opens the standard
libraries, preloads `titan` (`luaopen_titan` from `libtitan.a`) and `lpeglabel`
(`titan_lpeglabel_open` from `libtitan-lpeglabel.a`), and runs the generated
`titanc-bundle.lua`, embedded with `#embed`. That chunk installs a
`package.preload` loader for every module of the installation's compiler Lua
(`titan-compiler`, `c-parser`; without `build`, `build_worker` and `process`,
which need `luv` and processes), `relabel`, `inspect` and
`titan-runtime/playground/lfs.lua`, and returns
`require("titan-compiler.playground").host()`. Sources are loaded as text
under their logical chunk names. `lfs.lua` stands in for LuaFileSystem in the
modules that require it at load time: there is no host filesystem, so every
query reports absence.

The module links against the bundle's `liblua.a` (the fork's browser Lua,
with its `LUAI_MAXCCALLS` of 100), `libtitan.a` and `libtitan-lpeglabel.a`, as
a WASI reactor with `--stack-first` and an 8 MiB stack, exporting
`titanc_alloc`, `titanc_free`, `titanc_open` and `titanc_call`. Each call
leaves its reply on the Lua stack, which keeps the borrowed bytes alive until
the next call.

`titan-compiler/playground.lua` serves one opened catalog handle. Every
request builds a fresh [in-memory I/O strategy](driver.md#compiler-io-strategy)
(`compiler_io.new_memory`) with the project at `/` and the SDK's semantic
assets under the reserved `/titan` prefix, resets `driver.imported` and
`types.registry`, and closes its context, so no module, edit or removal of an
earlier snapshot survives. Project paths are relative POSIX names; `titan/`
and `..` are refused. Sources resolve through the ordinary `.` source path, so
files are named `./main.titan` in diagnostics, line tables and frames. The
tree's absolute paths begin with `/`, the path model of `titanc.wasm`'s POSIX
(WASI) host; a Windows host runs this module only under the POSIX lexical
path rules, as `spec/playground_spec.lua` models with
`browser_fixtures.with_posix_host`.

The project's modules are those the ordinary tagged resolver selects for the
browser target. Each `.titan` file proposes its own dotted stem (its target
label removed by `driver.classify_source_filename`) and its folder's, and
`driver.resolve_source` decides: a file belongs to the module whose selected
sources list it. A folder contributor therefore belongs to its folder module,
and a variant for another target, or a flat file a folder module or a
selected variant shadows, belongs to none and is never checked on its own. A
misspelled target label is a diagnostic on its file.

| Operation | Behavior |
| --- | --- |
| `check(files)` | Each project module as a root of an analysis context; diagnostics are `{ message, severity, path, line, col }` (1-based lines, byte columns). |
| `hover(files, cursor)` | In the module owning the cursor's file, the innermost checked node whose written name covers the byte offset: `{ at, signature, summary?, declaration? }`. |
| `complete(files, cursor)` | `completion.prepare`, then, in the module owning the cursor's file, a private analysis context over the transformed snapshot: `{ replace, items }`. Inside an import string the host answers instead, as the [completion contract](completion.md) asks: every import spelling the parser maps to a loadable module, namely the other project modules as `name` and `name.titan`, and each SDK module by its canonical name and its standard shorthand (`driver.browser_analysis_modules`). A spelling `parser.normalize_import` maps to a different module is not offered, and modules absent from the target are not in the catalog. |
| `emit_c(files, identity)` | An emit-only context rooted at `main`: `{ files, units, entry, diagnostics }`; language errors return diagnostics and no units. |
| `build_trace(linked, identity, factory, loader)` | `browsertrace.dwarf_map`, `browserlink.image_inventory`, `browsertrace.rewrite` and `browserlink.embed` on the optimized image, named `app.wasm`. |

The private wire format is a little-endian `u32` count of `u32`-length-prefixed
byte strings in both directions: the operation and its arguments (file maps as
path and contents pairs, offsets in decimal), then `ok` and a JSON result or
`error` and a message; `build_trace` returns its four outputs as further
strings rather than JSON.

`titan-runtime/playground/titanc.mjs` instantiates the module with exactly the
WASI functions it imports (standard output and error and the clocks work;
files and processes fail), and exposes `openCompiler({ wasm, catalog,
analysisTarget, absentModules })`. It converts the page's 0-based UTF-16
offsets to UTF-8 byte offsets on the way in and byte offsets and line/column
positions back on the way out, so its results use the editor's coordinates;
each file is encoded once per request. A refused request (an `error` reply)
leaves the compiler usable. A trap leaves the reactor undefined, so the
adapter then drops the instance, as `dispose()` (idempotent) does, and every
later call is refused before it allocates; a failed open drops it too.
`titanc.c` copies a request into the Lua state inside the protected call, so
no Lua allocation happens unprotected.

## Limits

- The parser's LPegLabel limits are the native compiler's:
  parenthesized expressions nested 24 deep fail with `subcapture nesting too
  deep` (the capture nesting limit) and blocks nested 60 deep with
  `backtrack stack overflow` (the backtrack limit). Both are raised as
  errors, which the adapter throws, rather than reported as diagnostics.
- A `foreign import` needs C header preprocessing, which needs `wasi-sdk`;
  the compiler reports that as a diagnostic. Explicit source imports of pure
  Titan modules need no C and work.

## Verification

`spec/playground_spec.lua` covers the in-memory strategy, the catalog round
trip, its digest binding and its rejections, the emit-only context rules and
`driver.emit_module_c`'s refusals, every playground operation over the
installed SDK (module selection with folders and target variants,
import-string completion, request and project errors, the entry's reserved
directory and pure source imports across directories), a foreign-function
dependency's relative header through a host strategy, a program linked from
emitted C whose trace names its frames (with the browser toolchain), the
`titanc.wasm` request handler over a stand-in service (framing, JSON results
and every refusal, with no SDK), a native `--no-source-records` build whose
objects carry no record, and the recipe's refusal of directories it does not
own. Its SDK cases pend without the browser toolchain and SDK and run in the
[`browser-stdlib`](continuous-integration.md#browser-stdlib-job) scheduler
shard, which also builds the bundle. `spec/driver_spec.lua` publishes lean
worker objects from the records the coordinator carries, and
`spec/titanc_parallel_spec.lua` checks the option's conflicts. `make
playground-sdk` ends with `scripts/playground_smoke.mjs`, which drives the new
`titanc.wasm` through its adapter: every operation, UTF-16 offsets, a failed
open, recovery after refused requests, independent instances and disposal.
