# Target source selection

Target source selection lets one logical source file `name.titan` have target
variants `name.<label>.titan`, and selects one file per family for the
compilation's target before any source byte is read. The language rules are in
the [language chapter](../language/target-source-selection.md). This chapter
covers the shared policy module, the target carried by the resolver context,
the resolver, the callers routed through it, logical output stems, incremental
certificates, the `titanc` option, test-root discovery, the language-server
helpers, and the repository's Make inventories.

Selection is a source-discovery feature only. It adds no AST node, `Type.*`
variant, interface field, runtime lookup, ABI marker, cache or record schema, or
worker protocol change. `TITAN_ABI_VERSION`, `LANGUAGE_SERVER_API_VERSION`,
`BUILD_WORKER_PROTOCOL`, and every persisted schema version are unchanged.

| Owner | Responsibility |
| --- | --- |
| `titan-compiler/source_selection.lua` | The label list, filename classification, per-target selection rows, label applicability, and the canonical output-stem policy. |
| `titan-compiler/driver.lua` | The driver API, the context target, CLI vocabulary validation, the family probes and folder sweep, every resolver caller, and output-stem consumers. |
| `titanc` | `-T`/`--target` and `TITAN_TARGET`, validated before any lookup. |
| `titan-compiler/testroots.lua` | Variant-aware `--test-dir` candidate naming. |
| `titan-compiler/ffiheaders.lua`, `titan-compiler/coverage.lua` | Logical FFI header origins, coverage output paths, and the GCC dumpbase. |

## The policy module

`source_selection.lua` holds the one copy of the grammar. The driver, the FFI
header owner, coverage, test-root discovery, the Busted Make audits, and the
language server all consume it through the driver exports below; none keeps a
second copy.

* `LABELS` is `{ "windows", "darwin", "linux", "browser", "native" }`.
* `classify(basename)` takes a basename without a directory. A name not ending
  in `.titan` returns a single `nil`. Otherwise the stem's last dot-separated
  component is compared with the label set case-insensitively (`^(.+)%.([^.]+)$`
  requires a nonempty base). No label match returns the basename unchanged: it
  is its own logical filename (`linux.titan`, `x.y.titan`). A match whose
  spelling is not lowercase returns `nil, nil, "mis-cased target label in source
  '<basename>'"`. A match whose base also ends in a label component, compared
  case-insensitively, returns `nil, nil, "stacked target labels in source
  '<basename>'"`. Otherwise it returns `<base>.titan, <label>`.
* `target_labels(target)` returns the labels of a target's row, most specific
  first and without the always-last default: `{ "linux", "native" }` (likewise
  `darwin` and `windows`), `{ "native" }` for the label-less native host, and
  `{ "browser" }`. Any other value raises `invalid source selection target`.
* `applies(target, label)` is true when `label` appears in that row.
* `output_stem(native_output, modname)` is the shared stem policy described in
  [logical output stems](#logical-output-stems).

## Driver API

The additions are additive exports on `driver.lua`:

| Export | Result |
| --- | --- |
| `driver.SOURCE_LABELS` | The five labels, in `LABELS` order. |
| `driver.classify_source_filename(basename)` | `logical_basename, label` (label `nil` for a default member); `nil, nil, err` for a stacked or mis-cased label; `nil` for a non-Titan name. |
| `driver.target_selection_labels(target)` | The target's row without the default, most specific first. |
| `driver.target_label_applies(target, label)` | Whether `label` is in the target's row. |
| `driver.new_resolver_context{ target = ... }` | The optional context target; `nil` or `""` means the host. |
| `driver.context_target(context)` | The context's target, or `nil, err` when the host cannot be determined. |
| `driver.validate_target(context, value, origin)` | The `titanc` vocabulary: the selected target, or `nil, err`. |
| `driver.resolve_source(context, modname, source_path?)` | The existing tagged resolver, now target-aware; see [below](#the-resolver). |

### The context target

A target is a string. The labeled targets are `linux`, `darwin`, `windows`, and
`browser`. The label-less native host target is the string `native`, used
internally for a native host whose `uname` is neither `Linux` nor `Darwin`;
its row is `native`, then the default.

`new_resolver_context` accepts `target` as `nil`, `""`, or one of the five
label strings, and raises `invalid source selection target '<value>'` for
anything else. It stores `nil` for `""`. For a host label the driver option is
a source-selection choice: it does not consult the host, so an embedding may
select another host's files, and it changes no toolchain, link policy, or probe
identity. `"browser"` additionally selects the [browser
target](browser-target.md): construction builds the target descriptor, which
owns the toolchain, probe cache, provider lookup, and output policy. Only
`titanc` applies the narrower CLI vocabulary.

`driver.initialize_platform(context)` sets `context.host_target` from the
platform it detects (`Windows` → `windows`, `Linux` → `linux`, a `uname`
containing `Darwin` → `darwin`, any other `uname` → `native`) and fills
`context.target` with the host target when no target was given. It continues to
accept any `uname`. `driver.context_target(context)` returns an explicit
target without initializing the platform. Every constructor returns an
activated context: an explicit host label activates without a `uname`
subprocess, so an offline embedding that names its target performs none for
source selection, while an omitted target initializes the platform through
the context's own I/O strategy during construction and activates the host
target ([Context initialization and
activation](browser-target.md#context-initialization-and-activation)).

The driver library never reads `TITAN_TARGET`. Semantic clients that omit the
option get the host target.

### CLI vocabulary

`driver.validate_target(context, value, origin)` always initializes the
platform first, so it knows the host. `nil` or `""` returns the host target.
`origin` is `"--target"` or `"TITAN_TARGET"`; diagnostics start with
`--target <value>` or `TITAN_TARGET=<value>`. Explicit `native` is always
rejected (`'native' selects source files for native hosts; it is not a
compilation target`), `browser` is returned on a Linux or macOS host and
otherwise rejected as `browser builds are supported from Linux and macOS
hosts (host is <host>)` (without the origin prefix), an OS
label equal to `context.host_target` is returned, another OS label is rejected
as `native cross-compilation is not supported (host is <host>)`, and anything
else is `unknown target '<value>': expected linux, darwin, windows or browser`.
On a label-less host, `host_target` is `native`, so every nonempty value is
rejected.

## The resolver

`resolve_source(paths, modname, context)` obtains the target with
`driver.context_target`, memoizes its row as `context.source_labels`, and walks
the `;`-separated roots. For each root, `source_resolution_in_root` (anchored at
[Tagged source resolution](folder-modules.md#tagged-source-resolution)):

1. probes the main family of the folder form with `select_source_family`: for
   the canonical main `P/B.titan` it tests `P/B.<label>.titan` for each label
   of the row in order, then `P/B.titan`, and returns the first regular file;
2. if a main is selected, enumerates the folder and builds the contributor
   list as described below;
3. otherwise probes the flat family of `P.titan` the same way;
4. before accepting a nested flat file, probes the parent's main family with
   **all five labels**, regardless of the target; any existing member makes the
   result `blocked`;
5. otherwise accepts the flat file, or returns nothing so the next root is
   tried.

Probes go through `context.io:stat` (`regular_file`), so non-regular entries
named like variants are ignored and symlinks keep the existing `stat`
behavior. The probes use the exact lowercase spellings; on a case-insensitive
filesystem a probe inherits that filesystem's case folding, as module paths do.

The folder sweep lists the directory once and, for every entry ending in
`.titan` that is a regular file, calls `classify_source_filename`. A
classification error is returned as the module's hard error, whichever family
the file belongs to and whether or not its label applies: a stacked name in the
main's family or a mis-cased name for another target fails the module too. The
sweep then skips every member of the main family (logical name `B.titan`),
records each remaining file under `families[logical][label or "default"]`,
selects one member per family with the memoized row, drops families with no
applicable member, and sorts the selected logical filenames with
`util.bytewise_less`. The sort key is the logical filename including `.titan`;
for a default member that is its complete filename, so a tree without variants
keeps its order. `files` lists the selected main followed by the selected contributors
in that order. Only names are examined: files for other targets are listed but
never opened.

Selected descriptors carry the canonical output path:

```lua
{
    kind = "flat" | "folder",
    main = "<selected main file>",
    files = { "<selected main>", "<selected contributor>", ... },
    native_output = "<root>/P.titan" | "<root>/P/B.titan",
    program_output = "P" | "P__main",
}
```

`native_output` is the canonical logical path in the selected root whether or
not that file exists. A `blocked` result names the first existing member of the
parent's main family, probed in `SOURCE_LABELS` order and then the default, and
the requested flat contributor.

Specificity applies only within one probe; the order folder, then flat, then
the next root is not affected. A module can therefore resolve as a folder on
one target and as a flat file on another, with `program_output` following the
form.

Fallback is absence-only: once a family member is selected, an enumeration
failure, a classification error, and later read, parse, header, or type errors
are terminal for that module; the resolver never retries a less specific
member, the flat form, or a later root.

### One resolver for every caller

Every source-file decision goes through `resolve_source`, before import
scanning, parsing, or FFI collection:

* the loader's `find_source` in `driver.defaultloader`, shared by command-line
  roots, ordinary source fallback after a binary miss, `--test`/`--source-first`
  source preference, and explicit `.titan` imports (`request.kind ==
  "source-import"`);
* `cached_interface_source_descriptor`, for source-required loads that would
  otherwise reparse from a caller's cached interface (see
  [cache admission](#cache-admission-scope));
* `driver.resolve_source`, used by `testroots.lua` and other library callers;
* `current_source_descriptor`, which publication uses to re-resolve a module
  before installing a staged object;
* `driver.resolve_external_modules`, the language server's metadata-only
  external topology helper.

Planning reads exactly `source.files`: the lexical import scanner
(`build.imports_for`) and certification consume the descriptor the planning
loader resolved. Workers never select files. `driver.plan_descriptor` copies
each planned module's source descriptor into the worker job, and the worker's
own module arrives as a `source_overrides` entry, so the worker compiles the
coordinator's frozen file list.

`driver.imported[M].filename` is the selected main. It remains the checker's
source directory for quoted `foreign import`s; variants are siblings of their
default, so header resolution does not change. The selected files form one
dense AST, and `check_foreign_environment` and `ffiheaders.prepare` build the
one ordered C environment from it, so a `foreign import` in an unselected file
never reaches the environment or the generated `.ffi.h`.

`import "foo.linux.titan"` strips only the explicit-source marker and requests
logical module `foo.linux`, whose source forms are `foo/linux/linux.titan` and
`foo/linux.titan`; the module-name validator already rejects dotted
components, so no request can name a physical variant.

### Cache admission scope

`cached_interface_source_descriptor` is the one cache path that produces a
source descriptor. It validates the caller's cached `filename` and
`source_files`, then re-resolves the module and admits the cached descriptor
only when the fresh resolution is a non-blocked descriptor with the same main
and the same ordered file list; otherwise it returns nothing and the loader
falls through to the fresh resolution. It never invents a selection from cached
paths.

Ordinary caller-certified analysis caches (`cached_source_entries` and
`cached_interfaces` used as public views), including virtual and frozen
completion catalogs, keep their existing contract and are not re-admitted from
disk. Their freshness, including selection changes when a variant is created or
deleted, belongs to the caller; the language server re-selects in that case.
Interface entries reconstructed from `cached_interfaces` carry
`native_output = output_stem(filename, modname) .. ".titan"`, so even a variant
filename yields the logical stem.

### Coordinator and workers

The coordinator passes the target to workers as closed data:
`driver.worker_configuration` stores `resolver.target =
driver.context_target(context)`, and `driver.new_worker_context` passes it
back as the worker context's `target` option. A browser configuration also
carries the closed descriptor as `target_descriptor`
([Worker transport](browser-target.md#worker-transport)). Coordinator and
workers are one installation, so the closed configuration needs no protocol
change.

Publication re-resolves through `current_source_descriptor` and revalidates the
staged object's record against the fresh descriptor
(`incremental.revalidate_record`, or the worker's source-snapshot check for an
uncertified configuration). A variant created mid-build changes the selected path list,
so the staged object is discarded, including for a byte-identical override.

## Logical output stems

Stripping `[.]titan$` from a physical filename would name artifacts after the
variant (`foo.linux.c`, an executable `foo.linux`). Every stem consumer
therefore reads the canonical logical path:

* the resolver sets `native_output` to `<root>/P.titan` or `<root>/P/B.titan`,
  and `driver.relocate_source_output` reroots it under `--output` from the
  logical name and form;
* `driver.module_output_stem` is `source_selection.output_stem`. It takes
  `native_output` (or the logical path from `modname`), classifies only the
  basename, replaces a variant leaf with its logical filename, and removes
  `.titan`. A directory component that looks like a label is never changed.
  Direct checker and compiler APIs that pass a physical source filename
  therefore get the logical stem too;
* `driver.foreign_header_filename`, `driver.ffi_header_filename`,
  `driver.private_header_filename`, `driver.part_c_filename`, and
  `driver.part_object_filename` build on that stem, so `.titan.h`, `.ffi.h`,
  `.priv.h`, split `.c`, and `.o` names are logical;
* foreign-header planning, retained-object header planning, certified-object
  and restored-part names, object invalidation, compile-request object names,
  provider-output preflight, and graph-output reservations consume the same
  helpers;
* `driver.prepare_source_ffi_header` passes the logical path to
  `ffiheaders.prepare`, and `ffiheaders.lua` derives the FFI origin identity
  from `output_stem`;
* `coverage.source` derives the coverage output from the logical path before
  inserting `.coverage`, and the GCC backend's `-dumpbase` is the logical
  basename with `.c`, so `.gcno` and `.gcda` files follow the logical stem.

`program_output` stays logical (`P` or `P__main`). See [Output-directory
routing](output-directory.md).

## Locations

Physical filenames are kept where locations are reported. The parser runs once
per selected file under its real filename, so every node's `loc.filename` is
the selected variant. `#line` directives (`coder/names.lua`), checker
diagnostics, and coverage inventories (`source_files`, matched against gcov
output by exact normalized path) use those names. The native trace filter keeps
frames whose basename ends in `.titan` (`titan-runtime/titan.c`), which every
variant does. None of these needed a new mechanism.

## Certificates

`incremental.source_certificate` already records `layout` and the ordered
`{ path, sha256 }` list of `source.files`, and `source_verdict` misses with
`source-set` on any added, removed, or reordered path
([Own-source content and folder
membership](incremental-compilation.md#own-source-content-and-folder-membership)).
Because selection happens in the resolver, which runs on every invocation, the
required behavior follows without a format change:

* adding or removing `foo.linux.titan` beside `foo.titan` changes the selected
  path and misses with `source-set`;
* switching between byte-identical files misses too, because `#line` paths
  differ;
* editing `foo.windows.titan` on Linux leaves the selected list and its
  digests unchanged: a hit with no compile and no relink;
* a contributor variant added in a folder misses for that module; an
  unrelated dependency remains a hit; and
* imports newly introduced by a selected variant re-plan, because the lexical
  scanner reads the selected files.

A producer's interface digest follows its selection, so importers invalidate
through the existing [interface digests](incremental-compilation.md#interface-digests-contextual-owners-and-bindings).
Certificates record no absent candidates: fresh resolution supplies the
negative evidence. The CLI target is always the host, a pure function of
`driver.UNAME` and `driver.IS_DARWIN`, which already enter the final-link recipe
and the native tool descriptors; no target field is added to any record.

## The `titanc` option

`titanc` declares `-T --target` as an ordinary `argparse` option, so it takes a
separate argument and also accepts `--target=<label>`; `-t` stays `--tree`.
After creating its resolver context, `titanc` reads `args.target`, falling back
to `platform.getenv("TITAN_TARGET")` only when the option is absent (an empty
option wins and selects the host), calls `driver.validate_target`, exits on an
error, and stores the result in `resolver_context.target`. This happens before
the usage check for missing modules, before toolchain errors are reported, and
before test-root discovery or any source lookup, so `-c --c-source`
invocations without Titan roots validate the target too.

`--print-root` returns before the progress reporter, the resolver context, and
target handling exist, so it ignores `-T`/`--target` with any value and
`TITAN_TARGET`, and it does not reject the combination. The run-time SDK
fallback runs that query and must not depend on target settings.

## Test-root discovery

`testroots.discover` obtains the target with `driver.context_target(context)`;
`titanc` has already initialized the platform, so discovery runs no
subprocess, and a bare context detects the host once. `walk` `lstat`s every
entry, then classifies each non-hidden `*.titan` regular file or symbolic link
by name once, before any target access, through `source_candidate`:

* a reserved spelling fails discovery with `invalid test source '<path>':
  <classification error>`; a link spelling is diagnosed only when the link
  resolves to a regular file, so a reserved link to a directory or to a
  missing target is ignored;
* a variant whose base is a valid module component yields the candidate base
  only when `driver.target_label_applies(target, label)`; an inactive variant
  is skipped silently;
* a default member yields its stem when it is a valid component; other dotted
  stems stay non-candidates.

Only a root candidate this classification accepts authorizes following a
symbolic link, so inactive and non-label dotted links are never followed; a
reserved spelling is stat'ed only to decide whether to diagnose it. `walk`
also follows a link whose whole name is a root name (`is_root_name`), which
lets a linked directory stand as a folder-module candidate without being
descended, and ignores entries of another kind (`other`) whatever their name.

The candidate names the root; the ordinary resolver, not the enumerated
spelling, decides which member runs. Several variants of one root reach
`consider` with the same logical name and deduplicate through
`same_source_descriptor`. A folder directory whose main family has no
applicable member resolves to nothing and is skipped like any non-module
directory. Shadowing and ambiguity diagnostics are unchanged. See [Automatic
test-root discovery](build-coordinator.md#automatic-test-root-discovery).

## Language-server helpers and the companion server

The helpers in the [driver API](#driver-api) are part of the
[language-server compiler API](driver.md#language-server-compiler-api), which
stays at `LANGUAGE_SERVER_API_VERSION = 1`: the server classifies workspace
filenames with `classify_source_filename`, obtains its host target with
`context_target`, and selects members with `target_selection_labels` or
`target_label_applies`, rather than mirroring the grammar.

The vscode-titan server analyzes the host target only. Its project discovery
groups variants under their logical module with the host selection and follows
the composition order, privacy, and precedence rules above. Only selected files
carry unsaved editor text into analysis. An inactive variant is never a module
file and gets no `invalid-module` issue; it receives one information-severity
diagnostic that names the selected member, or says that the family has no
active variant. The default contributors of a folder module absent for the
host get the same diagnostic, named after the main family. Such files get no
semantic completion.
Creating or deleting a variant re-selects and re-analyzes the affected module.
The server's `source_overrides` descriptors set `native_output` to the
canonical logical path. `TITAN_TARGET` in the server's environment has no
effect, and the extension adds no target setting.

## Make inventories and audits

The standard library's native-only modules keep their canonical mains as
target variants: the flat `titan/{fs,net,ssl}.native.titan`
and the folder mains `titan/{uv,sqlite3,thread}/<name>.native.titan`.
These six families have no default and no `browser` member, so for
`browser` the resolver selects no main: the module is absent (an import
reports `module 'titan.<name>' not found`), and the folder's contributors are
neither composed nor resolvable as flat modules. Native selection, logical
names, and canonical output stems (such as `titan/uv/uv.titan.h`) are
unchanged; only the physical main is a variant. Fourteen further standard
modules have no variants and form the shared part of the [browser standard
library](browser-target.md#the-browser-standard-library). `titan.timer`'s
flat family has a `native` and a `browser` member (`titan/timer.native.titan`,
`titan/timer.browser.titan`) and no default. `titan.async` has
the shared main `titan/async/async.titan`; its contributor families have
`native` and `browser` members (`runtime`, `external`) or only `native` ones
(`receiver`, `foreign`), so each target composes its own members and the
browser drops the native-only families. The browser-only
`titan/browser.browser.titan` is the opposite of a native-only module: its
family has only a `browser` member, so native targets select no main for
`titan.browser`.

`titan.os` has the shared main `titan/os/os.titan`; its `clock`,
`environment`, `process`, and `stdio` contributor families each have `native`
and `browser` members. `OS_TITAN_SOURCES` enumerates the main and both
members of every family. `OS_TITAN_HEADERS` names the two sibling native
headers and the browser-only `environment.browser.h` declarations. Each
target composes its matching four contributors. The complete shared
`titan.io` facade has the flat main `titan/io.titan` and uses that target's
`os` composition for its standard streams.

`titan.lua` has the shared main `titan/lua/lua.titan` and `worker.titan`, native
and browser `loading` contributors, and a native-only `background` family.
`LUA_TITAN_SOURCES` lists all five sources. Native composition preserves file
loading and worker execution; browser composition keeps synchronous states
and a no-filesystem source-search pass.

`titan.http` has the shared main `titan/http/http.titan` and the shared
contributors `headers.titan` and `options.titan`. Its `client` family has
`native` and `browser` members, and the `pool`, `parser`, `server`,
`transfer`, and `upgrade` families have only `native` ones, so the browser
composes the shared files with `client.browser.titan`. `titan.websocket`'s
main family has `native` and `browser` members (`websocket.native.titan`,
`websocket.browser.titan`) and no default; `types.titan` and `utf8.titan` are
shared, `handshake`, `connection`, `frames`, and `crypto` are native-only,
and `client.browser.titan` is browser-only. `STDLIB_HTTP_SOURCES` and
`WEBSOCKET_TITAN_SOURCES` list every source of both modules.

* The native Makefile source lists (`UV_TITAN_SOURCES` and the other stdlib
  lists under `STDLIB_TITAN_SOURCES`) name every source of a native module
  explicitly. A variant follows its default when the family has one; a
  variant-only family lists just its variants, as each native-only main does,
  `STDLIB_TITAN_SOURCES` lists both `timer` variants, `ASYNC_TITAN_SOURCES`
  lists both members of each `async` family, and `OS_TITAN_SOURCES` lists
  every `os` source, so the list-versus-disk audit sees every folder file.
  There are no wildcards. The
  lists are audit inventories, not Make prerequisites: `titanc --incremental`
  certifies the module graph. The browser provider instead names logical
  roots in `BROWSER_STDLIB_ROOTS`, so the browser-only
  `titan/browser.browser.titan` appears in no native source list.
* `spec/libuv_build_spec.lua` reads the inventory with `stdlib_source_files()`
  and groups it with `source_families()`, which uses
  `driver.classify_source_filename`. Source-policy audits (no explicit source
  imports, foreign-header expectations, the single `lua_setmetatable` owner, no
  uv FFI outside `titan.uv`) iterate every declared file, variants included.
  Output-predicting audits, such as `predicted_foreign_headers`, use
  `host_selected_sources()`, which applies `driver.target_selection_labels`
  for the host. The list-versus-disk audits (`undeclared_folder_sources`,
  `discovered_uv_sources`, `discovered_http_sources`) fail on a folder file,
  including a variant, that no entry declares.
* The native recipes that invoke `titanc` (`stdlib`, `stdlib-objects`,
  `titan-stdlib-test-objects`, `titan-stdlib-test-build`, the native fixture
  rule, and `titan-native-coverage-build`) unset `TITAN_TARGET`, as do the
  Windows build and test scripts; the browser recipes (`browser-sdk` and
  `titan-stdlib-browser-test`) unset it too and pass `--target browser`
  explicitly. See [Repository development workflow](repository-workflow.md).

## Validation

Busted specs cover the mechanism with one fixture tree holding files for all
five labels, built on the host target; expected results are computed from the
host's row, so the specs run unchanged on every platform:

* `spec/driver_spec.lua`: the driver API, the resolver matrix (label beats
  `native` beats default, inapplicable labels, target-only families, unread
  inactive files under a recording I/O strategy, terminal selected errors,
  precedence including folder-on-one-target, any-label privacy, reserved
  spellings), a stubbed `FreeBSD` host, cached-descriptor admission,
  publication re-resolution, logical split artifacts, and the real standard
  library's native-only mains (native selection with canonical output paths on
  every native target, the ordinary missing-module diagnostic for each
  native-only module on `browser`, and blocked folder contributors on every
  target);
* `spec/titanc_parallel_spec.lua`: the CLI vocabulary, flag precedence, empty
  values, validation order, and `--print-root`;
* `spec/coder/folder_modules_spec.lua`: composition order, replaced mains,
  initializers, inactive `foreign import`s, source imports, output stems,
  locations, and the platform fixture whose program prints its selected label;
* `spec/coder/incremental_compilation_spec.lua`: `source-set` misses, inactive
  edits without compile or link, and re-planning;
* `spec/coder/native_coverage_spec.lua` and `spec/coverage_backend_spec.lua`:
  coverage objects, reports, and the logical dumpbase;
* `spec/coder/test_root_discovery_spec.lua`: variant roots, skipped inactive
  roots, deduplication, and reserved spellings; and
* `spec/libuv_build_spec.lua`: the inventory audits and the recipes that unset
  `TITAN_TARGET`.
