# Folder modules — design and implementation plan

This plan expands the informal folder-module brief from
`pasted-text-1.txt` into a source-grounded design for the current Titan
compiler. A folder module spreads one logical module across several sibling
`.titan` files, but still has one namespace, one checker invocation, one
generated C translation unit, one module initializer, one serialized
interface, and one final shared library.

The motivating and required dogfood is `titan.uv`: move its source from the
single `titan/uv.titan` file into `titan/uv/`, keep the main source at
`titan/uv/uv.titan`, and continue building and installing exactly one
`titan/uv.so` for logical module `titan.uv`.

## 1. Outcome and scope

Given this source tree:

```text
titan/
  uv/
    uv.titan       # main source
    file.titan     # contributor
    tcp.titan      # contributor
```

the compiler treats all three files as the source of module `titan.uv`.
Importers still write:

```titan
local uv = import "titan.uv"
```

and Lua still writes:

```lua
local uv = require "titan.uv"
```

The observable identities do not acquire a per-file component:

| Concern | Identity after the change |
| --- | --- |
| Logical module | `titan.uv` |
| Exported function | `titan.uv._run`, not `titan.uv.task._run` |
| Nominal record | `titan.uv.Task`, not `titan.uv.task.Task` |
| Registry module key | `Titan module titan.uv` |
| Lua entry point | `luaopen_titan_uv` |
| ABI/types/init symbols | `titan_uv_abi`, `titan_uv_types`, `titan_uv_init` |
| Shared library | `titan/uv.so` |
| C translation units | one generated unit for the complete module |

The implementation includes:

- source discovery for flat and folder representations;
- deliberate blocking of direct source imports of folder-module children;
- independent parsing followed by deterministic AST composition;
- enforcement that only the main source may define the module initializer;
- exact per-file syntax/type/runtime source locations;
- collision-free standalone output for a folder module with `main`;
- compiler, build, test-harness, documentation, and `titan.uv` dogfood work.

The implementation does **not** add:

- a new import syntax;
- a declaration that names or includes contributor files;
- submodules, partial modules, per-file visibility, or per-file namespaces;
- recursive source collection below the folder-module directory;
- separate checking, code generation, objects, DSOs, or initialization for
  contributors;
- folder semantics for the in-memory `driver.tableloader` test helper;
- a compiled-module ABI schema change.

## 2. Language and filesystem semantics

### 2.1 Canonical layout

For logical module name `M`, define:

- `P = M` with dots replaced by `/`;
- `B =` the last component of `M`;
- flat source candidate: `P.titan`;
- folder main candidate: `P/B.titan`.

Examples:

| Module | Flat source | Folder main |
| --- | --- | --- |
| `app` | `app.titan` | `app/app.titan` |
| `foo.bar` | `foo/bar.titan` | `foo/bar/bar.titan` |
| `titan.uv` | `titan/uv.titan` | `titan/uv/uv.titan` |

When the folder main exists, every other immediate regular file in the same
directory whose name ends in `.titan` is a contributor. Collection is
non-recursive. Directories, non-`.titan` files, generated `.c`/`.o` files, and
the sibling `titan/uv.lua` provider loader are ignored.

The folder main is identified by the logical module name, not by directory
enumeration. Renaming `uv.titan` to another contributor name makes the folder
representation of `titan.uv` disappear. Conversely, a directory containing
only its canonical main is a valid, if not yet useful, folder module.

### 2.2 Lookup precedence

Preserve the current distinction between an explicitly requested build root
and an imported dependency.

#### Imported dependencies

1. Search all entries of `driver.TITAN_BIN_PATH`, left to right, for the exact
   compiled candidate `P.so`.
2. If a binary is found, recover its interface exactly as today. Source layout
   is not consulted.
3. Only if no binary is found, walk `driver.TITAN_SOURCE_PATH` left to right.
4. Within each source root, resolve in this order:
   1. the folder main `P/B.titan`;
   2. the flat source `P.titan`; before accepting this form, apply the
      contributor-file blocker.
5. Continue to the next source root only when the current root has none of
   those results.

The contributor-file blocker applies only while accepting a requested flat
source, and only when its parent folder-module marker is a regular file in the
same source root. Looking up `titan.uv.file` first considers its own folder form
`titan/uv/file/file.titan`; if that is absent and the flat candidate
`titan/uv/file.titan` exists, the parent marker `titan/uv/uv.titan` blocks the
flat candidate. Looking up `titan.uv.uv` normally has no deeper folder form and
finds that its flat candidate and the marker are the same file, so it is
blocked as well. Once both a constituent flat source and its owner marker are
found in an earlier root, lookup does not fall through to a later source root.

A parent folder main by itself does not reserve all child module names. If
`titan/uv/net.titan` does not exist in that source root, an ordinary nested
flat module at `titan/uv/net.titan` in a later root without that parent marker,
or a nested folder module at
`titan/uv/net/net.titan` in the current root, remains eligible. This keeps the
rule scoped to the brief's constituent `.titan` files rather than inventing a
new ban on submodules beneath a folder module.

If both `titan/uv/net.titan` and `titan/uv/net/net.titan` exist, the requested
folder form wins under the ordinary folder-before-flat rule. The constituent
`net.titan` is still never compiled as `titan.uv.net`; that logical name denotes
the distinct nested folder module in this deliberately colliding layout.

This order has four intentional consequences:

- an earlier source root retains precedence over a later source root;
- within one source root, the folder representation wins over a simultaneous
  flat representation;
- an exact compiled `titan/uv/file.so` can still win before source lookup,
  because binary-first dependencies are an existing invariant and a DSO is an
  independently packaged compiled module, not a source contributor;
- in the ordinary no-binary, no-colliding-nested-module case, contributors and
  the apparent `titan.uv.uv` alias cannot be imported directly. A deliberately
  present deeper folder module resolves as that distinct module, never as the
  constituent flat file.

Once a folder main is selected, an enumeration, read, or syntax error in that
folder representation is the module's error. It must not fall back to a
simultaneous flat source or a later source root, just as a broken flat source
found in an earlier root does not silently select a different module today.

#### Explicit `titanc` roots

Every module named on the `titanc` command line remains a source build request.
It uses the same source-root walk and folder/guarded-flat precedence, without a
binary lookup. Therefore:

- `titanc titan.uv` selects `titan/uv/uv.titan` even when `titan/uv.so` exists;
- with no deeper `titan/uv/file/file.titan` form, `titanc titan.uv.file` fails
  as a blocked constituent even when a `titan/uv/file.so` exists or was cached
  earlier;
- a missing explicit source still fails rather than silently accepting a DSO.

The existing cache rule that discards a binary-only cache entry for a later
explicit root must run before this source resolution.

### 2.3 One module namespace and deterministic declaration order

All declarations from all files share the same module-wide value namespace,
type namespace, nominal-type owner, module state, and public interface. `local`
continues to mean module-private, not file-private. Local helpers, records,
aliases, and callable declarations are visible across every source regardless
of relative placement; imports are likewise module-wide except at the explicit
module-variable frontier described below.

The compiler defines one deterministic conceptual source order:

1. declarations from the main source, in their original order;
2. declarations from contributors sorted by basename with an explicit numeric
   byte comparator, with each file's internal order preserved;
3. the main source's optional module initializer, last.

The main file is always first even if another basename sorts before it. This
lets it serve as the module prelude for shared imports, constants, and state
without requiring shared record declarations to remain there. Do not use plain
Lua string `<`: Lua delegates string order to the active locale's collation.
Compare `string.byte` values numerically,
falling back to length when one basename is a prefix of the other. Sorting this
way makes interface member order, module-variable initialization, generated
code, and diagnostics independent of both `readdir` order and process locale.

The ordinary Titan rules then apply to this combined order:

- ordinary duplicate winners and `_toplevel_order` follow the combined AST;
- imports are processed in combined order but are available to aliases,
  records, callable signatures, and bodies regardless of relative placement;
- aliases, records and their synthesized constructors, ordinary functions,
  methods, and record functions are collected in dependency stages and are
  mutually order-independent;
- each module-variable declaration/initializer sees only earlier imports and
  earlier module variables, while seeing all other declaration kinds;
- top-level variables initialize in combined declaration order and function
  bodies are checked after declaration collection;
- duplicates across files are the same errors as duplicates within one file.

The checker does not rearrange the list to obtain those semantics. Combined
order still controls duplicate precedence, serialized interface/member and
module-slot order, module-variable initialization, and code generation. There
is no implicit import between files and no file-local shadowing rule.

### 2.4 Module initializer

The optional root `do ... end` block remains the initializer of the one logical
module. It may occur only in the canonical main source. A root initializer in
any contributor is a folder-module source error reported at that contributor's
`do` location.

The main initializer is removed temporarily while ASTs are composed, then
appended to the final combined list. It is checked as the existing
`$module_initializer`, emitted once, and invoked once after imports, records,
module variables, function tags/closures, trace names, and the module
metatable have been initialized. The registry's existing module cache keeps it
once-per-Lua-state.

This validation must occur before checking/codegen. The current parser allows
one initializer per independently parsed file, the checker accepts every root
`Ast.StatBlock`, and the coder would emit the same fixed C initializer symbol
for each one. Letting multiple blocks through would produce duplicate C
definitions, not a meaningful multi-initializer order.

### 2.5 Source locations and diagnostics

Every file is parsed with its real discovered filename. Every resulting node
already owns a concrete `{ filename, line, col }`; composition reuses the node
objects without rebasing positions or concatenating source strings.

As a result:

- a syntax error names the contributor that failed to parse;
- a type error names the contributor containing the offending node;
- synthesized checker nodes inherit the originating contributor location;
- runtime errors that embed `node.loc` retain the contributor filename;
- generated `#line N "filename"` directives switch between files as the one C
  translation unit emits functions and statements from different sources;
- DWARF/libbacktrace frames name the actual contributor and line.

Three existing duplicate diagnostics identify the primary node correctly but
describe the earlier declaration as only `line N`. Update them to print the
earlier declaration's complete `filename:line:col`, so a cross-file duplicate
does not point ambiguously at the current file. Factor a small location-format
helper rather than reconstructing that spelling in each checker branch.

### 2.6 Generated and linked artifacts

The canonical main source controls the generated C/object location. The logical
module name controls the importable shared-library location.

| Form | Main source | Generated C/object | Shared library |
| --- | --- | --- | --- |
| Flat `foo.bar` | `foo/bar.titan` | `foo/bar.c`, `foo/bar.o` | `foo/bar.so` |
| Folder `foo.bar` | `foo/bar/bar.titan` | `foo/bar/bar.c`, `foo/bar/bar.o` | `foo/bar.so` |

Only the canonical main gets generated C/object files. Contributors never
produce `file.c`, `file.o`, or `file.so` merely because they contribute source.

A folder module may define Titan's ordinary `main(args: {string}): integer`.
The current executable name `P` would collide with the source directory, so
this plan deliberately gives a folder program a collision-free sibling
executable while leaving the entrypoint at its existing logical-module path:

| Form | Entrypoint | Executable |
| --- | --- | --- |
| Flat `foo.bar` | `foo/bar__entrypoint.c` | `foo/bar` |
| Folder `foo.bar` | `foo/bar__entrypoint.c` | `foo/bar__main` |

Flat behavior is unchanged. This is an explicit completeness decision beyond
the brief's required library case: rejecting `main` would make source
representation change which otherwise valid modules can be programs, while
putting the executable at `P/B` would require creating the source-shaped
directory under the current working directory and fails when `--tree` points
elsewhere. `P__main` stays beside the current `P__entrypoint.c` and needs no
directory beyond the one current logical-module outputs already require. The
module name and `$PROGNAME` embedded in the entrypoint remain `foo.bar` and
`bar`; only the folder representation's executable filename changes.

### 2.7 Compatibility and ABI

Folder modules are a source-discovery and compilation-unit feature. They do not
change:

- Titan grammar or any AST/Type constructor schema;
- serialized callable or module descriptor shapes;
- native function signatures;
- mangling, nominal identity, runtime module loading, or Lua entry points;
- the final `.so` lookup path.

The mechanism alone does not require an ABI change merely because one AST was
assembled from several parser results.

The `titan.uv` dogfood deliberately moves exported declarations into their
semantic contributors. Ordered module members participate in module user-value
slot reconstruction by compiled importers, so the resulting contributor order
changes the old monolithic slot sequence. Advance the repository-wide
compiled-module ABI so pre-boundary importers cannot load the reordered DSO.

An exact `titan_uv_types` string is useful only after making keyed interface
serialization reproducible: `types.serialize(Type.Record)` currently walks the
`methods` and `functions` maps with `pairs`, while module `type_members` uses
locale-aware default sorting. Collect and sort all three sets of names with the
same numeric-byte comparator first, add insertion-order and locale-independence
regressions, rebuild the still-monolithic uv with that compiler, and capture
the deterministic string for comparison. After the split, capture and pin the
new exact interface. Sorting keyed map output changes no descriptor schema
or meaning; the ABI bump is for the intentional ordered-member relocation, not
for keyed serialization.

## 3. Current implementation seams

| Area | Current code | Required change |
| --- | --- | --- |
| Path mapping | `findmodule` in `titan-compiler/driver.lua` maps dots to slashes and checks one extension | Retain for binaries or factor it; add a source resolver with folder/flat/blocked results and per-root precedence |
| Explicit/dependency policy | `driver.defaultloader` has separate source-root and binary-first branches | Feed both branches through the new source resolver without changing their binary policy |
| Source parse/check | `parse_source` reads/parses/checks one file | Accept a source descriptor, parse every file independently, validate/compose, then check once |
| AST shape | parser returns a dense list of root nodes | Concatenate the existing lists; add no source-unit AST tag |
| Locations | `parser.parse` and `location.from_pos` stamp each node | Reuse unchanged; add cross-file regressions |
| Checker | whole-module passes already use `ipairs`; `checker.check` has one `source_dir` | Pass main subject/filename; same-folder contributors make the one foreign-header base correct |
| Duplicate errors | checker cites prior declarations by line only | Cite the prior full location |
| Interface serialization | record method/static maps use `pairs`; type aliases use locale-aware sorting | Sort keyed names with `util.bytewise_less` so an exact interface baseline is reproducible; retain ordered module members and record fields |
| Coder ordering | seven whole-AST passes in `coder.generate`/`allocate_upvalues` use `pairs` | Change numeric root-list walks to `ipairs` so composition order is guaranteed |
| `#line` | `coder.emitline` uses each node's own filename and is already placed at function, statement, call, raise, and throw sites | Preserve it; verify mixed-source generated C and native traces rather than inventing a unit-global directive |
| C/object output | `driver.compile` derives from cached `mod.filename` | Cache the folder main as `filename`; behavior then follows naturally |
| DSO output | `compile_library` derives from logical `modname` | No change |
| Executable output | `compile_program` derives from logical `modname`; `write_entrypoint` already uses the noncolliding `P__entrypoint.c` | Accept an optional executable path, using `P` for flat and `P__main` for folder sources |
| In-memory loader | `driver.tableloader` maps one table entry to one fake file | Leave flat/in-memory; filesystem folder semantics belong to `defaultloader` |
| Stdlib build | Make depends on `titan/uv.titan` and assumes root-level generated C | List every uv source, clean/ignore nested artifacts, keep one `titan/uv.so` target |

## 4. Detailed compiler design

### 4.1 Source-resolution result

Introduce one internal source resolver in `titan-compiler/driver.lua`. It should
return a tagged result for a match or privacy block; reserve `nil` for a clean
miss and use a separate error return if an already-selected folder cannot be
enumerated:

```lua
-- found flat/folder
{
    kind = "flat" | "folder",
    main = "<discovered main filename>",
    program_output = "<module-relative executable path>",
    files = { "<main>", "<sorted contributor>", ... },
}

-- blocked constituent flat source
{
    kind = "blocked",
    owner = "<parent logical module>",
    main = "<parent folder main filename>",
    contributor = "<requested flat source filename>",
}
```

`files` is temporary loader input, not AST metadata. After parsing and
composition, contributor filenames survive only through node locations. The
cache retains only the already-existing canonical `filename` plus the new
logical `program_output` needed for standalone output.

For each source-root entry:

1. derive the requested relative module path and leaf;
2. test the requested folder main as a regular file;
3. if present, enumerate its directory with `lfs.dir`, retain immediate regular
   `*.titan` files, exclude the already known main, sort contributor basenames
   with the numeric-byte comparator, and return main followed by contributors;
4. otherwise test the flat source as a regular file;
5. before accepting a present flat source whose requested name has a parent,
   derive the parent's folder marker and return `blocked` if it is a regular
   file in the same root;
6. otherwise accept the flat source or continue to the next root on a miss.

Use `lfs.attributes(path, "mode") == "file"`, not mere existence, for marker,
main, flat, and contributors. As in the current finder, `nil` or an existing
non-file probe is a miss; once a regular folder main has selected the folder
representation, however, a subsequent `lfs.dir` failure is a hard error. Do
not recurse, follow a second manifest, or create an identity link between
old/new paths.

Factor a small `util.bytewise_less(a, b)` comparator by walking
`1..min(#a, #b)`, comparing
`string.byte(a, i)` and `string.byte(b, i)` as numbers at the first differing
byte, then comparing lengths. Do not call `a < b` inside the comparator. Unit
test ASCII case differences, prefix names, and multibyte UTF-8 filenames as raw
bytes so the proof does not depend on which non-C locales the host installed.

If the chosen folder cannot be enumerated, return that filesystem error as a
hard resolution failure. Do not reinterpret it as a miss and fall back to the
flat source or next root.

The blocked diagnostic should name the requested module, constituent source,
owning folder module, and canonical main path. It must be distinguishable from
`module not found` and from a syntax/type error in the owner.

### 4.2 Parsing and AST composition

Refactor `defaultloader`'s local `parse_source` around the descriptor:

```lua
local function parse_source(modname, source, loader)
    local combined = {}
    local main_input
    local main_initializer

    for index, filename in ipairs(source.files) do
        local input = read(filename)
        local nodes = parser.parse(filename, input)

        if index == 1 then
            main_input = input
            if nodes[#nodes] and nodes[#nodes]._tag == "Ast.StatBlock" then
                main_initializer = table.remove(nodes)
            end
        else
            for _, node in ipairs(nodes) do
                if node._tag == "Ast.StatBlock" then
                    return false, contributor_initializer_error(node.loc,
                        source.main)
                end
            end
        end

        append_all(combined, nodes)
    end

    if main_initializer then table.insert(combined, main_initializer) end

    driver.imported[modname] = CIRCULAR_MARK
    local modtype, errors = checker.check(modname, combined,
        main_input, source.main, loader)
    -- cache one logical module, including source.program_output
end
```

The real implementation must preserve existing read/parse error handling and
dependency-stack cleanup. In particular:

- parse sequentially; the parser is intentionally non-reentrant;
- stop at the first deterministic read/syntax/layout failure;
- do not install `CIRCULAR_MARK` until every file has parsed and the contributor
  initializer rule has passed;
- once checking starts, push/pop exactly one direct-dependency set around the
  one combined checker invocation;
- cache `{ ast, type, filename = source.main, program_output, deps }`;
- retain the current behavior of caching a checked AST even when its type error
  list is nonempty, so callers can report all type errors;
- use the main source for `checker.check`'s compatibility-only `subject` and
  `filename` arguments. Actual diagnostics come from node locations, and the
  main directory is the correct shared base for relative `foreign import`
  headers because every contributor is a sibling.

Do not check files separately, merge checked ASTs, or round-trip contributor
interfaces. One `symtab.new(modname)` and one staged checker invocation are
what make local names, record identity, imports, duplicates, and the module
interface truly shared.

### 4.3 Checker staging and diagnostics

No new AST tag is needed. The parser marks only its synthesized record
`TopLevelStatic` with `_record_constructor`, and the checker annotates every
root with `_toplevel_order`. Keep the dense AST unchanged while staging
declaration collection:

1. premark ordinary duplicate winners and annotate `_toplevel_order` by
   combined AST order;
2. precollect surviving aliases in their separate type namespace, including
   duplicate-alias and alias/record conflict handling;
3. reserve every surviving ordinary top-level name;
4. visit all Titan and foreign imports in AST order;
5. resolve aliases, then build every record, then attach every parser-marked
   synthesized constructor;
6. collect ordinary callable and module-initializer signatures;
7. attach explicit methods and record functions;
8. check module variables in AST order under `st.initializer_order`;
9. check bodies and validate resolved record-field and alias types.

The symbol table masks the current/later module variables and later
Titan/foreign imports only during step 8. Because all foreign imports have
already been converted, keep source-ordered `foreign_type_history` and
`foreign_name_history` lists and recover the last declaration no later than
the active frontier. Stamp canonical C struct/union owners with
`_definition_order` when a definition completes them in place, and make field
lookup/allocation treat a definition from a later import as absent/incomplete
at an earlier frontier. All other declarations see the complete import, alias,
record, constructor, and callable environment.

Audit the three cross-reference diagnostics in `collect_type_aliases` and the
ordinary duplicate prepass:

- alias conflicts with a record;
- duplicate aliases;
- duplicate ordinary top-level declarations.

Render the earlier declaration's complete location. Keep the current primary
error location and first-declaration-wins `_ignore` behavior. A duplicate
record must also suppress its adjacent marked constructor so it does not
produce a secondary `new` error. Update same-file expected text in specs/manual
examples as needed and add cross-file cases that prove both filenames are
present.

The contributor-initializer diagnostic belongs to driver assembly, not the
parser or checker: the block is valid Titan syntax and valid in the main file,
but invalid for its filesystem role. Nested `do` blocks inside contributor
functions remain ordinary statements and must not be rejected.

### 4.4 Deterministic code generation and source directives

Change the numeric whole-AST walks in `allocate_upvalues` and `coder.generate`
from `pairs(ast)` to `ipairs(ast)`. There are currently four allocation walks
and three emission walks. This makes these orders agree with checker/interface
order:

- exported variable slots;
- exported canonical function-closure slots;
- local/import/record/static slots;
- module-variable initialization;
- record namespaces and methods/statics;
- emitted functions and the sole module initializer.

Leave coder-internal map/set walks whose order is semantically irrelevant as
`pairs`; only the dense root AST has declared emission/allocation order. The
keyed interface-serialization walks are the separate exception in section 2.7
and must use sorted names because their textual output is externally consumed.

Retain the existing `emitline(node)` design. It already C-quotes
`node.loc.filename` and stamps every safe physical-line site. Do not prepend a
single source-unit `#line`, and do not blanket-stamp `codeexp` fragments that
may be embedded mid-line. Add text and runtime tests showing the one generated
C file alternates directives among main and contributor filenames.

### 4.5 Cache and standalone program output

Store `program_output` on source cache entries:

- flat `foo.bar`: `foo/bar`;
- folder `foo.bar`: `foo/bar__main`.

Extend `driver.compile_program` with an optional final executable-path
parameter. Default to the current dotted-name mapping so `tableloader`,
existing tests, and external embeddings keep their behavior. Keep
`write_entrypoint(modname)` and its `P__entrypoint.c` path unchanged. When
`titanc` links the detected main module, pass that module cache entry's
`program_output`. Update the filesystem-based async stdlib child compiler for
the same case; its current modules are libraries, but it should not retain a
hidden folder-main collision.

The optional program output affects only the executable filename. `$MODNAME`,
`$LUAOPEN_FN`, `$PROGNAME`, module symbols, and shared-library paths remain
derived from the logical module name.

### 4.6 Cache, cycles, and dependency closure

Keep all cache/dependency keys as `modname`. A folder module produces exactly
one `driver.imported[modname]` entry and one `direct_deps` set regardless of
which contributor contains an import. The existing `CIRCULAR_MARK`,
`remember_direct_dependency`, `remember_dependency_closure`, and
`driver.dependency_closure` then work unchanged.

Important regressions:

- an import in a contributor is attributed to that contributor but recorded as
  a dependency of the logical module;
- a contributor importing its own logical module reports the ordinary circular
  reference;
- a contributor attempting to import a sibling by `titan.uv.file` reports the
  folder-child block;
- two requested roots that reuse the same folder source compile it once;
- a cached binary dependency can be replaced by a later explicit folder-source
  root exactly as a flat source can today.

## 5. `titan.uv` dogfood design

### 5.1 Invariants to preserve

The split must be a source refactoring, not a runtime redesign. Preserve:

- one `titan.uv` module state and Runtime per Lua state;
- the canonical bundled/system libuv provider boundary;
- all current record names, field layouts, methods/statics, function names,
  types, visibility, named native entry points, and callback ownership;
- the user-observable order of imports and top-level variable initialization,
  plus the bootstrap/shutdown behavior of the sole module initializer;
- every exported name, type, visibility, and record layout;
- the sole initializer's current behavior, including program-argument setup;
- all production and late-FS test-variant behavior;
- one installed versioned `titan/uv.so` and one Lua provider
  loader at `share/lua/5.5/titan/uv.lua`.

After the keyed-interface serialization sort is installed, rebuild the
unchanged monolithic `titan.uv` and capture its deterministic `titan_uv_types`
string in `/tmp` as the compatibility reference. Move each exported record,
the `Task` methods, and all exported
`_run`/`_fs_*`/`_net_*`/`_os_*`/ticker/loop/version declarations into the
related contributor. Capture the new deterministic sequence as the exact
fixture and verify that only declaration order changed.

Keep shared imports/foreign imports, constants, top-level module state, the
bootstrap helper, program-argument setup, and the initializer in the main file.
After the staged declaration-order implementation is in place, move every
remaining private record to the semantic contributor that owns its operations;
move the private `FS` constants instance with `FsConstants` into `file.titan`,
and leave no record in the main. Preserve all other import, variable, and
initializer behavior in their original relative order. The earlier
public-member move is the compatibility boundary; this private relocation
changes internal slot/initialization order but neither the exact
`titan_uv_types` fixture nor importer-visible variable and canonical
exported-function closure slots, so do not bump the ABI again.
Validate initializer behavior with the complete uv suites in addition to
comparing the public interface byte-for-byte.

### 5.2 Proposed files

The current `titan/uv.titan` is about 6,800 lines. Use this first-pass split;
the named declaration families are non-overlapping ownership rules, unlike
broad line ranges through the interleaved monolith:

| New file | Named landmarks | Responsibility |
| --- | --- | --- |
| `titan/uv/uv.titan` | shared imports, constants/state; `bootstrap`, `setup_program_args`, root `do` | Shared prelude, bootstrap, and sole initializer; no record or exported member |
| `titan/uv/runtime.titan` | exported `Error`, `_bytes_*`, `_loop`, `_version`; loop/Runtime and byte/text/buffer records; runtime helpers | Trace/storage errors, loop and Runtime ownership, shared byte helpers |
| `titan/uv/task.titan` | exported `Cancelled`, `uv_timer_t`, `Task`, its methods, `_run`/`_sleep`/`_yield`, ticker API; private timer/drive/request/ticker records; task helpers | Task lifecycle, join/cancellation, coroutine/timer driving, ticker and fatal shutdown |
| `titan/uv/file.titan` | exported `uv_file` and `_fs_*`; private FS constant/operation/control/request records; filesystem helpers | File ownership/FIFO, FS requests/callbacks, shutdown repair |
| `titan/uv/tcp.titan` | exported `uv_tcp_t`, `_net_*`, `_net_eof_error`; private address/network request/control/owner records; TCP helpers | TCP/DNS ownership, queues, callbacks, network shutdown |
| `titan/uv/process.titan` | exported `uv_process_t`, `_os_process_*`, `_os_communicate`; private process/pipe/request/helper records; process helpers | Process/pipe ownership, callbacks, child helpers, forced shutdown |
| `titan/uv/os.titan` | exported non-process `_os_*`; private signal spec/control/owner records; signal/OS helpers | One-shot signal ownership/callbacks, portable OS operations, signal teardown |

Before moving code, generate a temporary inventory of every root AST node with
its tag, name, visibility, and original line, and assign each entry to exactly
one file under the rules above. After composition, compare the corresponding
tag/name/visibility multiset and public sequence. Move complete top-level
declarations, never cut through a function/record/block, and parse after each
mechanical batch so a lost `end`, duplicate omission, or changed visibility is
caught close to the move.

This layout deliberately exercises the feature:

- every contributor relies on imports, constants, and state declared in the
  main source and on record types owned by other contributors;
- public records, methods, and API bodies are declared by contributors while
  retaining the single logical `titan.uv` namespace;
- local implementations and native callbacks call one another cyclically
  across files;
- the main initializer calls helpers declared in contributors;
- no contributor can be compiled or imported as its apparent dotted path.

### 5.3 Make and packaging

In `Makefile`:

- introduce an explicit, reviewed `UV_TITAN_SOURCES` list containing the main
  and six contributors; do not rely on a wildcard for build membership;
- make `titan/uv.so` depend on the complete list;
- retain the existing recipe, libuv flags, coroutine prerequisite, target name,
  stdlib ordering, install loop, and one-provider link policy;
- update `clean` for `titan/uv/*.c` and `titan/uv/*.o` (especially
  `titan/uv/uv.c` and `titan/uv/uv.o`);
- update `.gitignore` for generated C below `titan/uv/` (`*.o` is already
  globally ignored).

`titan/uv.lua` stays where it is and coexists with the new `titan/uv/`
directory. The rockspec has no separate stdlib-source manifest; its post-install
hook delegates to Make. Validate that a source rock/install contains the nested
sources and still installs only the canonical DSO.

Update `spec/libuv_build_spec.lua` to parse the reviewed source list and assert
that its normalized set exactly equals the regular `titan/uv/*.titan` files the
compiler will discover. Then table-drive a forced dry run for every listed
source, not only a representative contributor, and assert each rebuilds exactly
`titan/uv.so` with the provider flags. This makes a new contributor fail the
build spec until it is added to Make's dependency graph. Preserve the existing
assertions that async/fs/net/os facades do not receive libuv inputs.

### 5.4 Delayed-FS test variant

`spec/support/async_stdlib.lua` and
`spec/support/make_delayed_fs_callback_variant.lua` currently copy and transform
one monolithic `uv.titan`. Convert the variant flow to directory input/output:

1. create `workspace/src/titan/uv/`;
2. copy the complete production folder ensemble;
3. patch the exact files that own the delayed-owner constant/state, FS callback,
   timer dispatch, test hooks, and main initializer anchor;
4. compile the folder as logical `titan.uv` through the ordinary resolver;
5. never concatenate a private test monolith and never install the variant.

Keep `replace_once`-style anchor assertions per target file, so a production
refactor cannot silently omit or duplicate the timing hook.

## 6. Implementation phases

### Phase A — Characterize current behavior and lock the design

Files: `spec/driver_spec.lua`, new topical coder spec, temporary scripts/output
under `/tmp` only.

- Add focused failing tests for folder-vs-flat lookup, root ordering, direct
  child blocking, explicit-root behavior, and binary-first behavior.
- Add assembly fixtures with main plus deliberately misordered contributor
  creation to prove ordering follows numeric bytes, not `lfs.dir` or locale.
- Capture current flat-module artifact behavior and the folder-`main` collision.
- Add a characterization showing keyed method/static/type-alias serialization
  needs canonical ordering; capture the uv member/record-field order
  semantically, but defer the exact raw-string baseline until Phase C sorts
  keyed maps and rebuilds the monolith.
- Keep `driver.imported` and `types.registry` save/reset discipline in every
  filesystem-loader spec.

Exit: tests state the intended precedence and compatibility rules before the
resolver is changed.

### Phase B — Implement source discovery and AST assembly

Files: `titan-compiler/driver.lua`, `titan-compiler/util.lua`,
`spec/driver_spec.lua`, `spec/util_spec.lua`.

- Factor module-path/leaf derivation without changing binary lookup.
- Add the numeric `util.bytewise_less` helper and its locale-independent byte
  sequence regressions.
- Implement the tagged source resolver and contributor-file blocker.
- Enumerate only immediate regular `.titan` contributors and sort basenames
  with the explicit numeric-byte comparator.
- Refactor `parse_source` to read/parse each file, reject contributor root
  initializers, compose dense AST nodes, append the main initializer last, and
  check/cache once.
- Preserve explicit-root cache invalidation, dependency stack handling, error
  aggregation, and source/binary closure recording.
- Leave `tableloader` unchanged and document that it represents one in-memory
  source per module.

Exit: checker-only folder modules load with correct identity, order, errors,
cache entries, and dependency closures.

### Phase C — Finish diagnostics, determinism, and artifacts

Files: `titan-compiler/location.lua`, `titan-compiler/checker.lua`,
`titan-compiler/coder.lua`, `titan-compiler/driver.lua`,
`titan-compiler/types.lua`, `titanc`, `spec/types_spec.lua`,
`spec/support/async_stdlib_compile.lua`, relevant specs.

- Add/reuse a full-location formatter for prior-declaration diagnostics.
- Switch the seven root-AST coder walks from `pairs` to `ipairs`.
- Sort serialized `Type.Record.methods`, `Type.Record.functions`, and
  `Type.Module.type_members` names with `util.bytewise_less`; prove insertion
  order and process locale cannot change the serialized result, while keeping
  ordered module members and record fields untouched.
- Add/cache the representation's module-relative program output path.
- Thread the optional executable path through `compile_program` and the
  filesystem CLI/helper callers; keep `write_entrypoint` unchanged.
- Prove flat module outputs are byte-for-byte path-compatible.
- Prove folder libraries emit main-stem C/object plus logical-name DSO, and
  folder programs emit/run `P__main`, including when `--tree` is outside CWD.

Exit: deterministic code/interface layout, precise cross-file diagnostics, and
no directory collision for `main`.

### Phase D — Add end-to-end source and traceback coverage

Files: `spec/coder/folder_modules_spec.lua` (new), with narrowly shared support
added to `spec/support/helpers.lua` only if it is genuinely reusable;
`spec/coder/backtrace_spec.lua` if the existing harness is the smaller fit.

- Compile one folder library with records, local helpers, variables, imports,
  and exports spread across files.
- Load it from Lua and import it from Titan; assert one shared interface and
  module state.
- Assert the generated main C file contains directives for every source and no
  contributor C/object/DSO exists.
- Raise through a main-to-contributor call chain and assert each native frame
  uses its own `.titan` filename/exact line, never the main filename for all
  frames and never generated `.c`.
- Exercise a relative quoted foreign header from a contributor to pin the
  same-folder `source_dir` invariant.
- Compile and run a folder module with Titan `main`.

Exit: the public compiler path, not only an internal AST helper, proves the
complete feature.

### Phase E — Dogfood `titan.uv`

Files: `titan/uv/uv.titan` and contributors, `Makefile`, `.gitignore`,
`spec/libuv_build_spec.lua`, `spec/support/async_stdlib.lua`,
`spec/support/make_delayed_fs_callback_variant.lua`, affected stdlib support.

- Create the folder and move complete top-level declarations according to the
  split above.
- Before the first move, rebuild the monolith with the deterministic serializer
  and capture its exact interface string. After moving public declarations into
  semantic contributors, capture and pin the deliberately reordered
  interface exactly.
- Advance the ABI marker, generated metadata, tests, CI, and current
  documentation for the folder-layout boundary.
- Update Make prerequisites/cleanup/ignore rules.
- Make the libuv build spec compare `UV_TITAN_SOURCES` with the discovered
  folder set and force every member, preventing dependency-list drift.
- Convert the delayed-FS variant to copy/patch the ensemble.
- Replace every live hard-coded `titan/uv.titan` assumption with either the
  canonical `titan/uv/uv.titan`, the full source list, or the folder path as its
  purpose requires.
- Build in bundled mode and, where available, system-libuv mode; confirm only
  `titan/uv.so` is the provider and all higher facades still consume it as a
  binary dependency.

Exit: production `titan.uv` itself cannot build unless cross-file declarations,
callbacks, initialization, locations, Make dependencies, and packaging all
work.

### Phase E2 — Generalize declaration order and finish record ownership

Files: `titan-compiler/parser.lua`, `titan-compiler/checker.lua`,
`titan-compiler/symtab.lua`, topical checker/coder/build specs, and the seven uv
sources.

- Mark parser-synthesized record `new` declarations with
  `_record_constructor`; use the marker rather than spelling alone.
- Implement the staged checker sequence from section 4.3 while retaining the
  combined AST unchanged for all downstream order-sensitive consumers.
- Add `initializer_order` masking for current/later module variables and later
  Titan/foreign imports, including source-ordered C type/name histories.
- Prove records, synthesized constructors, ordinary functions, methods, record
  functions, and aliases may precede one another, including across folder
  contributors; prove later imports remain unavailable only to earlier module
  variables.
- Move all private uv records out of `uv.titan` into the contributor owning
  their subsystem, move `FS` beside `FsConstants` in `file.titan`, and leave
  shared imports/constants/module state/bootstrap and the sole initializer in
  the main.
- Compare the exact `titan_uv_types` fixture byte-for-byte before and after the
  private ownership move. Keep the ABI marker unchanged because neither its public interface
  nor native signatures change despite the private slot/initialization reorder.

Exit: imports and module variables are the only mutually source-ordered
declaration families; semantic uv contributors own every record without
changing the pinned public ABI interface.

### Phase F — Complete both manuals and repository guidance

Files: new `doc/language/folder-modules.md`, new
`doc/implementation/folder-modules.md`, both `index.md` files, and the existing
cross-references listed in section 8.

- Document user-visible layout, ordering, privacy/blocking, initializer,
  artifacts, binary precedence, declaration staging/frontiers, and examples.
- Document resolver/assembly/cache/codegen internals, why folder assembly adds
  no AST/native/schema change, and why the uv member relocation still advances
  the compatibility marker while the later private ownership move
  does not advance it again.
- Update all one-file module claims and `titan.uv` paths.
- Update `README.md` and `AGENTS.md` so future compiler/stdlib work uses the new
  source layout and build prerequisites.

Exit: neither manual teaches the old one-file-only model, and repository
instructions accurately describe the dogfood layout.

### Phase G — Full verification and delivery

- Reinstall the edited compiler before Busted so `luarocks.loader` cannot use a
  stale snapshot.
- Run focused compiler, codegen, build, packaging, and stdlib suites.
- Run the full compiler/language group with coverage and library groups without
  LuaCov.
- Run the trusted full `make test` gate.
- Verify `make clean` removes nested generated C/object files but no source.
- Inspect the final diff for accidental uv logic/visibility/interface changes.
- If publishing a PR, wait for push-triggered Linux CI and manually dispatch
  the complete macOS workflow as the pre-merge check.

## 7. Test plan

### 7.1 Source resolver matrix

Add filesystem cases for:

| Case | Expected result |
| --- | --- |
| Folder only | folder main plus all immediate contributors |
| Flat only | flat source |
| Folder and flat in same root | folder wins |
| Folder main/contributor is broken and flat also exists | folder error; no flat fallback |
| Selected folder cannot be enumerated | hard folder error; no fallback |
| Earlier-root flat, later-root folder | earlier flat wins |
| Earlier-root folder, later-root flat | earlier folder wins |
| Earlier-root contributor plus parent marker, later candidate | blocked; no fallthrough |
| Earlier-root parent marker without requested contributor, later candidate | no block; later candidate wins |
| Dependency with exact binary and folder source | binary wins |
| Dependency child with exact binary and parent folder marker | binary wins |
| Explicit root with binary and folder source | folder source wins |
| Explicit root naming contributor/main alias, with no deeper folder form | blocked |
| Parent marker present, no conflicting contributor, nested folder module present | ordinary nested module works |
| Parent marker, contributor, and same-name nested folder all present | requested nested folder wins; contributor stays private |
| Parent marker absent, nested flat module present | ordinary nested module works |
| Non-`.titan` sibling/subdirectory/generated C | ignored |
| Read error/syntax error in contributor | failing contributor path reported |

Use multiple source roots in one path string to test the actual semicolon walk,
not only helper-level candidate selection.

### 7.2 Assembly and checker

- main declarations are first regardless of filename sort;
- contributors follow numeric-byte order even when created in reverse order;
- prefix, ASCII-case, and UTF-8 basenames sort identically under available
  process locales;
- every file's internal root order, including synthesized record `new`, stays
  intact;
- combined root list is dense and has the one main initializer last;
- contributor initializer reports its own `do`, while nested contributor `do`
  is accepted;
- main initializer may call a contributor helper and runs once;
- local imports/helpers/types/records/functions cross file boundaries;
- methods, record functions, `Rec.new`, context-typed constructors, and module
  variables may precede the owning record across files;
- callable signatures and aliases may use a later Titan/foreign import, while
  an earlier module variable cannot;
- a module variable cannot see itself or a later module variable, but does see
  every alias, record, synthesized constructor, and callable;
- duplicate records suppress their synthesized constructors, explicit `new`
  still conflicts with the synthesized one, and method/field conflicts are
  independent of relative placement;
- a contributor import enters the logical module's dependency closure;
- duplicates across main/contributors name both locations;
- public interface contains every contributor export in deterministic order;
- nominal records from contributors remain owned by the logical module;
- `checker.has_main` sees a `main` declared in any contributing file.

### 7.3 Code generation and runtime

- generated C/object use the canonical main path;
- one library uses the logical module path;
- no contributor artifact is generated;
- generated C has `#line` directives naming main and every contributor;
- a contributor function's entry, call/raise site, and anonymous-function
  display name use its own location;
- a cross-file native traceback interleaves the correct filenames/lines;
- Lua `require` and Titan `import` expose one combined API and same module state;
- record construction/method calls and module variables work across files;
- a folder executable uses/runs from the `P__main` sibling path;
- flat library/program paths remain unchanged.

### 7.4 Build, packaging, and uv behavior

- the `UV_TITAN_SOURCES` set exactly matches all discovered folder sources;
- touching every listed source, including `uv.titan` and `file.titan`, rebuilds
  the same `titan/uv.so`;
- no facade receives libuv compile/link inputs;
- bundled provider has no dynamic libuv dependency; system mode has the
  expected one;
- the delayed-FS variant compiles from a copied folder ensemble and its focused
  late-callback suite passes;
- installed `require "titan.uv"` and Titan imports reach the same canonical
  installed DSO;
- no fragment DSO or legacy copy is installed/manifested;
- after keyed-interface sorting, before/after `titan_uv_types` descriptors
  match by name and type and differ only in the intended member order; the
  exact new deterministic serialization matches the ABI fixture;
- moving all remaining private records and the private `FS` constants instance
  to contributors leaves that exact ABI fixture byte-for-byte unchanged,
  leaves no record in `uv.titan`, and keeps `FS` adjacent to `FsConstants.new`;
- `make clean` removes `titan/uv/uv.c` and `titan/uv/uv.o`.

Keep folder-module compiler tests in the compiler/language group. Keep uv/fs/
net/os behavior in the existing non-LuaCov library groups; do not pay LuaCov's
debug-hook cost over the split 6,800-line stdlib just to cover driver code.

## 8. Documentation plan

### Language manual

Create `doc/language/folder-modules.md` and link it from
`doc/language/index.md` next to Modules. Cover:

- the canonical directory/main naming formula;
- an annotated multi-file example;
- one shared namespace and `local` being module-private;
- deterministic main/contributor declaration order;
- folder-over-flat and binary/explicit-root precedence;
- why constituent flat sources and the apparent repeated-basename flat source
  are not selected directly, plus the distinct nested-folder collision case;
- the main-only initializer and once-per-state behavior;
- `.c`/`.o`/`.so` and standalone artifact locations;
- non-recursive collection and ignored files;
- `titan.uv` as the production example.

Update `doc/language/modules.md` at its opening one-file definition,
declaration-order section, module-name/path mapping, `titanc` artifact table,
source lookup section, and current `titan/uv.titan` examples. Cross-link the
new chapter rather than duplicating its full algorithm.

Update `doc/language/functions.md` where its duplicate-declaration example
quotes the old "previous one at line" diagnostic; the new wording includes the
earlier declaration's full location.

### Implementation manual

Create `doc/implementation/folder-modules.md` and link it from
`doc/implementation/index.md` near Driver. Cover:

- the tagged source-resolution outcomes and exact precedence;
- temporary source descriptors versus the unchanged dense AST;
- independent parser calls and plain-node concatenation;
- initializer extraction/validation;
- singular checker invocation/source directory;
- parser `_record_constructor`, checker `_toplevel_order`, staged declaration
  collection, and module-variable `initializer_order` masking;
- source-ordered foreign type/name histories used at that frontier;
- cache/dependency/cycle identity;
- deterministic `ipairs` codegen walks;
- per-node `#line` behavior;
- program-output handling and the folder `main` collision;
- lack of AST/type/native/runtime-loader shape changes and the deliberate
  compatibility-marker transition for reordered uv members;
- the uv build/test-harness migration.

Update:

- `doc/implementation/driver.md` for discovery, cache fields, parsing, compile
  paths, executable paths, and source-root reference table;
- `doc/implementation/checker.md` where the duplicate-declaration example
  quotes the old line-only secondary location, plus its staged declaration and
  symbol-frontier model;
- `doc/implementation/lexer-parser.md` for independently parsed contributor
  filenames and the unchanged non-reentrant parser contract;
- `doc/implementation/codegen-overview.md` for one combined AST/translation
  unit, unchanged source order after checker staging, and mixed-file `#line`
  attribution;
- `doc/implementation/libuv-runtime.md` for contributor-owned public/private
  records while retaining one provider image and the exact ABI interface;
- `README.md` for lookup/build examples;
- `AGENTS.md` for standard-source layout, Make dependencies, generated nested
  artifacts, and `titan.uv` explicit-root examples.

Run a final repository search for `titan/uv.titan` and classify every match:
replace live path claims, while preserving any deliberately historical text.

## 9. Validation commands

Use the active standalone Lua 5.5/Titan prefix and disable ccache where the
sandbox requires it:

```sh
export PREFIX="$HOME/.local/titan/titan-dev"
export PATH="$PREFIX/bin:$PATH"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
export CCACHE_DISABLE=1

"$PREFIX/bin/luarocks" make --force

busted spec/util_spec.lua
busted spec/types_spec.lua
busted spec/driver_spec.lua
busted spec/checker/declaration_order_spec.lua
busted spec/coder/folder_modules_spec.lua
busted spec/coder/backtrace_spec.lua
busted spec/libuv_build_spec.lua
busted spec/rockspec_spec.lua

make stdlib
busted spec/stdlib/uv_late_fs_callbacks_spec.lua
bash spec/support/ci_test_groups.sh compiler
bash spec/support/ci_test_groups.sh libraries
make test
```

Also run the repository's existing bundled/system libuv mode smoke in the same
way CI does when the host has system libuv available. After the full build:

```sh
test -f titan/uv.so
test -f titan/uv/uv.c
test -f titan/uv/uv.o
test ! -e titan/uv/file.so

make clean
test ! -e titan/uv/uv.c
test ! -e titan/uv/uv.o
```

For a published branch, push-triggered CI proves Linux. Then run:

```sh
gh workflow run ci.yml --ref <branch>
```

and wait for the manual macOS suite before merge.

## 10. Acceptance criteria

1. For `M`, source resolution recognizes `P/B.titan` as the folder main before
   `P.titan` within the same source root.
2. Existing binary-first dependency lookup and explicit source-root behavior
   remain intact and are tested together with folder sources.
3. An immediate `.titan` constituent of a source folder module, including its
   apparent repeated-basename flat source, is never selected directly once
   lookup reaches source. A same-name deeper folder may still win as a distinct
   nested module, and unrelated nested module names remain legal.
4. Every immediate regular `.titan` sibling contributes; collection is
   non-recursive and deterministic.
5. Files are parsed independently and then combined as one dense AST without a
   new source-unit node or per-file namespace.
6. Main declarations precede contributor declarations sorted by an explicit
   locale-independent numeric-byte comparator, and each file's internal order
   is preserved.
7. Only the main source may contain the root module initializer; it is the sole
   final initializer node and runs once.
8. The combined module is checked/generated once under exactly `M`, with one
   module type, dependency closure, C translation unit, registry identity, and
   initializer.
9. Syntax/type/layout errors in a contributor name that contributor and exact
   line/column; cross-file duplicate diagnostics name both locations.
10. Generated `#line` directives and native tracebacks attribute functions,
    calls, raises, and anonymous functions to their actual source files.
11. A folder library emits main-stem `.c`/`.o` and logical-name `.so`; it emits
    no contributor artifacts.
12. A folder module with Titan `main` retains the `P__entrypoint.c` entrypoint,
    emits and runs the collision-free `P__main` executable even with an
    external `--tree`, and leaves flat artifact paths unchanged.
13. No AST/Type schema, native call convention, or runtime DSO lookup rule
    changes. The compiled-module ABI advances solely to segregate the
    deliberately reordered `titan.uv` public member slots from pre-boundary
    artifacts; later checker staging and private record/`FS` relocation keep
    the marker unchanged.
14. `titan.uv` is split into the documented folder, contributor files own their
    related exports and every public/private record, `uv.titan` retains only
    shared imports/constants/state/bootstrap/initializer concerns,
    `titanc titan.uv` pins the exact deterministic interface, and
    bundled/system modes each produce exactly one canonical `titan/uv.so`.
15. `UV_TITAN_SOURCES` exactly matches the discovered uv ensemble, touching
    any member rebuilds that one DSO, and cleanup, source install, packaging,
    and the delayed-FS variant understand the ensemble.
16. Both manuals, their indexes, existing module/driver/libuv chapters,
    `README.md`, and `AGENTS.md` describe the implemented layout accurately.
17. Focused tests, grouped compiler/library suites, and `make test` pass; Linux
    and manually dispatched macOS CI are green before merge when published.
18. Records, aliases, functions, methods, record functions, and imports used by
    non-module-variable declarations are placement-independent. Only imports
    and module variables retain their mutual combined-order frontier, and the
    checker achieves this without reordering the AST consumed by interfaces or
    code generation.

## 11. Principal risks and review traps

- **Treating contributors as submodules.** While compiling a folder ensemble,
  any mangling, nominal name, module state, interface, or DSO that adds the
  contributor basename violates the core design. A separately present deeper
  folder module is an ordinary distinct module, not the constituent.
- **Checking fragments separately.** That creates separate symbol tables and
  record identities even if their ASTs are concatenated later.
- **Concatenating source text.** It corrupts local line numbers, lets file
  boundaries affect lexing, and defeats the brief's per-file diagnostics.
- **Depending on directory order or `pairs(ast)`.** That makes initialization
  and importer-visible slots nondeterministic.
- **Reordering the AST to implement forward declarations.** Checker visitation
  may be staged, but physical order remains the interface/slot/init/codegen
  contract; mutate the sequence and the ABI fixture can drift silently.
- **Leaving the main initializer in the middle or accepting contributor
  initializers.** The former loses the combined parser invariant; the latter
  emits duplicate fixed C symbols.
- **Making `local` file-private.** Existing Titan has one module scope; a new
  source-file scope would be a different language feature.
- **Blocking binaries while adding source privacy.** The brief adds a source
  representation after binary miss; changing dependency binary precedence
  would regress installation behavior.
- **Letting a blocked earlier-root contributor fall through.** Once both the
  constituent source and its folder main are found, exposing a different
  module from a later search root would defeat the source privacy rule.
- **Using one `#line` for the translation unit.** Generated code interleaves
  nodes from several files; attribution must remain per node and at safe
  physical-line sites.
- **Ignoring the standalone collision.** `foo/bar` is a directory for a folder
  module, so the old executable path cannot work.
- **Reordering the uv serialized interface.** Public member order feeds module
  slots used by compiled consumers; first canonicalize keyed interface maps,
  then keep the ordered contract and compare the deterministic snapshot
  exactly.
- **Using a Make wildcard without review.** The compiler may deliberately
  collect every `.titan` sibling, but the production build should list its
  intended uv sources explicitly so additions change the reviewed build graph.
- **Keeping the late-FS test as a monolith.** That would stop dogfooding the
  real source layout precisely where cancellation/GC timing coverage matters.
- **Testing the library under LuaCov.** Folder resolution needs compiler
  coverage; the 6,800-line uv behavior suites remain non-LuaCov library tests.
