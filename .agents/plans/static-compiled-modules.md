# Static compiled modules — specification and implementation plan

This plan expands the attached `Static compiled modules` brief into a
source-grounded design for Titan's ABI 0.16 compiler, multi-module providers,
installed toolchain, and standard library.

The feasibility investigation in item 0 changes the draft's artifact shape:
metadata can be embedded portably in a static archive when it is carried by a
valid relocatable object section. Titan should therefore **not** create a
`.tmm` sidecar. Each generated Titan module object carries the same ABI and
serialized `Type.Module` information exposed by its DSO `_abi` and `_types`
entries. A static provider is one self-describing `.a`.

Today a dependency is either compiled from Titan source into the current
artifact or recovered from a `.so` and loaded dynamically. This feature adds a
third origin:

- the compiler scans a candidate `.a` in-process;
- it reads the embedded metadata for the requested logical module;
- the checker uses that recovered `Type.Module`;
- generated C uses the existing direct-`extern` path; and
- the final native link searches that archive.

For a no-`main` build:

```sh
titanc pkg.left pkg.right
```

the provider `pkg` produces:

```text
pkg.so
pkg.a
pkg/left.lua
pkg/right.lua
```

The `.so` and `.a` contain the same logical Titan module closure. Ordinary
dependency lookup prefers the DSO; `titanc --static` prefers the archive.
Source is the final fallback, and modules explicitly named on the command line
remain source build roots.

## 1. Decisions that close ambiguities

| Question | Decision |
| --- | --- |
| Metadata location | Embed it in each already-generated Titan module object: ELF section `.titan.meta`, Mach-O section `__TEXT,__titanmeta`. The containing `.a` is the only static-provider artifact. |
| Why no raw archive member? | A raw text member is accepted by `ar`, but GNU `ld --whole-archive`, Darwin `libtool -static`, and universal-archive tooling require object members. A metadata-bearing relocatable object survives all paths Titan needs. |
| Metadata contents | The section bytes are a canonical Lua chunk which, evaluated with an empty `_ENV`, returns a map keyed by logical module name. Each value has exactly `abi` and serialized `types`: the same information returned by that module's DSO metadata functions. |
| Granularity | Titan emits one one-key metadata section in each logical module's own object. An archive's physical membership map is the validated union of all such sections. This binds interface bytes to the object that defines the native protocol. |
| Search priority | Default is a complete `.so` pass, then a complete `.a` pass, then source. `--static` swaps the first two passes. Path-root-major and shallow-to-exact precedence remain unchanged within each format. |
| Meaning of `--static` | Prefer static Titan providers. It is not the C compiler's `-static` flag and is not a static-only guarantee: the specified `.so` and source fallbacks remain. |
| Explicit CLI roots | Still source-only. The flag changes dependency lookup, not what `titanc foo` means. |
| Per-key versus physical membership | Parsing validates the whole archive, but lookup materializes only the requested logical key. Other archive keys do not override normal per-name resolution priority. Complete membership is retained for validation, overlap checks, and repackaging. |
| Resolver versus native provenance | Selecting key `M` decides how `M` is found and which archive is linked. Separately, code generation records which logical definitions are physically direct in the final image and which transitive owner symbols must still come from a producer-chosen DSO. Physical membership can make a referenced owner direct without making it independently discoverable. |
| Library outputs | Every successful no-`main` invocation publishes a same-base `.so` and `.a`; generated shims and the Darwin dSYM remain as today. No `.tmm` is emitted or installed. |
| Native input policy | The same source objects, selected static-provider archives, and `-X` provider payload feed both outputs. Selected/input archives are force-loaded into the DSO and flattened into the archive. There is no companion-only input list. |
| Common runtime inputs | `libtitan.a`, `libbacktrace.a`, `liblua.a`, `-l` libraries, and final-only flags are supplied once at a final link and are not copied into every produced `.a`. |
| libuv | Bundled `libuv.a` is the same `-X` payload for both outputs, so its objects are in `titan.so` and `titan.a`. System libuv remains a final-link setting and is never copied into `titan.a`; whether that setting selects a shared or static system library is the user's linker/toolchain decision. |
| Repackaging | A no-`main` build force-carries the complete physical membership of each selected static provider into both new native forms. That physical membership is not a promise that an unrelated logical prefix can discover the new provider pathname. |
| Standalone outputs | When exactly one explicitly requested root defines the exact Titan `main(args: {string}): integer`, retain executable-only behavior. Other requested roots may be present. No provider pair is invented beside the executable. |
| ABI | Keep compiled-module ABI 0.16. The native protocol and serialized types do not change. Give the embedded container format its own format banner/version. |
| Platforms | Implement and test ELF/Linux and Mach-O/macOS, including consumption of universal Darwin archives. Windows `.lib`/COFF remains future work. |

The feature does not add Titan syntax, a dependency manifest, a package
manager, a run-time archive reader, or a guarantee that libc and every system
library are statically linked.

## 2. Archive-embedding feasibility and selected design

### 2.1 What the investigation proves

An archive may contain an arbitrary raw file, but that is not enough for
Titan's workflow:

- GNU `ar` and LLVM `ar` accept arbitrary members and index relocatable
  symbols.
- GNU `ld --whole-archive` rejects a raw metadata member as “not an object.”
- Darwin `libtool -static` accepts objects, universal objects, and archives,
  not an arbitrary metadata file.
- `llvm-lipo` rejects a Darwin archive containing a raw metadata member.
- A regular ELF object with `.titan.meta` survives `ar`, `ranlib`, archive
  flattening, and whole-archive linking.
- A Mach-O object with `__TEXT,__titanmeta` survives Darwin-format `ar`,
  `libtool -static`, and x86_64/arm64 universal creation.

The relevant primary tool contracts are:

- [GNU `ar`](https://sourceware.org/binutils/docs/binutils/ar.html)
- [LLVM `llvm-ar`](https://llvm.org/docs/CommandGuide/llvm-ar.html)
- [LLVM `llvm-lipo`](https://llvm.org/docs/CommandGuide/llvm-lipo.html)
- [Darwin `libtool -static`](https://keith.github.io/xcode-man-pages/libtool.1.html)

The implementation should preserve focused regression fixtures for the two
decisive negative cases:

```text
raw member + GNU --whole-archive       => rejected as non-object
raw member + Darwin universal tooling => rejected as invalid object input
```

and the corresponding metadata-object successes.

### 2.2 Why metadata belongs in the module object

There are three possible embedded forms:

1. a raw named member;
2. a separate metadata object for the whole provider; or
3. one metadata section in each existing module object.

Choose the third:

- it is a valid object member for every linker/archive operation;
- the interface travels with the exact object defining `_abi`, `_types`,
  `_init`, and `luaopen_`;
- flattening selected archives naturally preserves metadata;
- no reserved archive member name or `ar p` first-duplicate behavior matters;
- there is no aggregate metadata object to filter/regenerate while composing
  providers; and
- one file rename publishes a self-describing static provider.

Archive member leaf names are not identity. GNU and Darwin archives may contain
duplicate member names, and Titan folder modules can naturally create them.
The scanner must inspect every object and reject duplicate **logical metadata
keys**, never select a member by leaf name.

## 3. Static artifact and metadata contract

### 3.1 Provider naming and logical protocols

The provider rule stays unchanged. In no-`main` mode, deduplicate requested
roots and take their longest common sequence of complete dotted components.
For provider `Q`, publish:

```text
Q with dots replaced by "/" + ".so"
Q with dots replaced by "/" + ".a"
```

Examples:

| Requested roots | Provider | Dynamic | Static |
| --- | --- | --- | --- |
| `foo` | `foo` | `foo.so` | `foo.a` |
| `foo.bar` | `foo.bar` | `foo/bar.so` | `foo/bar.a` |
| `foo.left foo.right` | `foo` | `foo.so` | `foo.a` |
| all seven `titan.*` roots | `titan` | `titan.so` | `titan.a` |

Each logical module still owns:

- its fully qualified name and nominal record identity;
- `<mangled>_abi`;
- `<mangled>_types`;
- `<mangled>_init`;
- `luaopen_<mangled>`;
- its independent registry module `Udata`, variables, closures, records, and
  initializer; and
- one generated Lua shim when published in a DSO.

There is no logical module for a provider prefix unless that module was
actually compiled.

### 3.2 Exact generated section

`coder.generate` computes the module interface values once:

```lua
local interface = {
    abi = driver.TITAN_VER,
    types = types.serialize(ast._type),
}
```

The same `interface.types` feeds `<mangled>_types`; the runtime header's
`TITAN_VER` feeds `<mangled>_abi`, with `spec/abi_spec.lua` continuing to prove
that it equals `driver.TITAN_VER`.

Render one canonical Lua chunk:

```lua
-- Titan archive module metadata v1
return {
    ["pkg.left"] = {
        abi = "0.16",
        types = "Module('pkg.left',{...},{...})",
    },
}
```

Use stable indentation/newlines and Lua `%q`-style string quoting. The banner is
the embedded-format version; it is not an extra module metadata field.

Emit the exact chunk bytes as a numeric C byte array, with no compiler-added
trailing NUL:

```c
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#elif defined(__ELF__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#else
#error unsupported object format for Titan archive metadata
#endif

TITAN_META_SECTION
static const unsigned char pkg_left_titan_metadata[] = {
    /* canonical Lua chunk bytes, wrapped at a stable column */
};
```

Constraints:

- one Titan-generated module object has exactly one metadata section;
- the section is regular bytes, not zero-fill, compressed, or relocated;
- `aligned(1)` makes the section size equal the payload size;
- folder contributors still combine into one logical module object and
  therefore one section;
- the entrypoint object has no module metadata section;
- `titanlib.o`, Titan runtime objects, and ordinary `-X` payload objects have
  no logical module metadata; and
- a metadata-bearing object/archive supplied through generic `-X` is rejected.
  Logical modules must enter through source or archive resolution, not through
  an untracked native-payload channel.

The section may also remain in a linked DSO as an inert section, but DSO lookup
continues to call `_abi`/`_types`; the run-time loader never parses it.

### 3.3 Empty-environment Lua schema

For every section payload:

1. require the exact supported banner;
2. compile with:

   ```lua
   local chunk, load_error = load(payload, "@" .. origin, "t", {})
   ```

3. require `chunk` and report `load_error` otherwise;
4. protected-call it and count results with `table.pack`, so zero results,
   `return table, nil`, and every other multiple-result form are rejected;
5. require exactly one result, a plain table with no metatable;
6. inspect it only through `next`/`rawget` after the metatable check;
7. require exactly one valid logical module key;
8. validate the exact entry schema; and
9. re-render that key/ABI/types with the canonical renderer and require
   byte-for-byte equality with the section payload.

Every top-level key is a nonempty dotted Titan module name with no empty,
leading, or trailing component. Every value is a plain table with exactly:

```text
abi   string
types string
```

Reject numeric keys, unknown fields, metatables, functions, and all other
shapes. Require `abi == driver.TITAN_VER`. Decode `types` with the existing
constructor environment:

```lua
load("return " .. serialized, module_name, "t", types)
```

Protected-call it, require a canonical `Type.Module`, require its name to equal
the table key, and run the same recursive schema/serialization validation as
DSO metadata.

Each object section has exactly one key; the archive-level union is the
brief's table for one or more modules. This preserves the interface-to-object
binding and avoids silently accepting a separate aggregate metadata object.
Duplicate logical keys anywhere in one architecture slice are terminal, even
if their ABI/types bytes are equal.

The canonical re-render check deliberately rejects a valid but hand-formatted
or computational Lua chunk. Empty-`_ENV` evaluation preserves the brief's
metadata semantics and gives precise load/runtime diagnostics; canonical bytes
give deterministic universal-slice comparison and a single producer format.

The empty environment is a declarative-build contract, not a hostile-code
sandbox: a chunk can still loop or allocate. Static archives are trusted native
artifacts just like DSOs.

### 3.4 In-process native-container reader

Add `titan-compiler/staticmetadata.lua`. It must parse bounded byte ranges
directly; dependency lookup must not invoke `ar`, `lipo`, `objcopy`, `nm`, or
the linker.

#### Regular archives

Recognize `!<arch>\n` and reject `!<thin>\n`. Parse every 60-byte member header
with checked decimal sizes, `` `\n `` trailer, even-byte padding, and
overflow-safe bounds.

Support the formats emitted/consumed by GNU, LLVM, and Darwin tools:

- short `name/` members;
- GNU `/` and `/SYM64/` symbol indexes;
- GNU `//` long-name tables and `/offset` references;
- BSD `#1/<length>` extended names;
- Darwin `__.SYMDEF`, `__.SYMDEF SORTED`, `__.SYMDEF_64`, and
  `__.SYMDEF_64 SORTED` indexes; and
- duplicate member leaf names.

Names are used only for diagnostics and to skip recognized index/string-table
members. Inspect every remaining member by object magic. Reject nested archive
members, raw non-object members, truncated members, invalid long-name offsets,
and unsupported object formats. Published Titan archives are regular,
flattened object archives.

For BSD `#1/<length>`, the archive member's recorded size includes the attached
name bytes; begin object payload after that length, bounds-check it within the
member, and trim the name's terminating NUL padding before comparing recognized
index names. Archive even-byte padding is still computed from the complete
recorded member size.

#### ELF relocatable objects

Support ELF32/ELF64 and both encoded endiannesses and require `ET_REL`.
Structural/interface scanning may precede active-target selection; the later
generated-object fingerprint check enforces compatibility. Parse with bounds
checks:

- ELF identification, machine, and header sizes;
- section-table offset/count/entry size;
- extended section count/string-table index through section zero;
- the section-name string table; and
- every exact `.titan.meta` match.

Reject more than one metadata section in an object, non-`SHT_PROGBITS`
metadata, compressed/zero-fill metadata, out-of-bounds names/data, and
unsupported extended forms. Walk the `SHT_REL`/`SHT_RELA` section headers and
reject any whose `sh_info` targets the metadata section; the embedded bytes
must require no relocation. An ordinary relocatable object with no Titan
section is valid native payload and contributes no logical key.

#### Mach-O relocatable objects

Support 32/64-bit and byte-swapped Mach-O headers. Require `MH_OBJECT`, validate
`ncmds`/`sizeofcmds`, and walk bounded `LC_SEGMENT`/`LC_SEGMENT_64` commands and
their section arrays. Match the exact segment/section pair:

```text
__TEXT,__titanmeta
```

Reject duplicate matches, non-`S_REGULAR`/zero-fill metadata, any metadata
section with `nreloc ~= 0`, invalid relocation-table/data offsets or sizes,
malformed load commands, and DSO/bundle/executable file types.

#### Universal Mach-O archives and objects

Recognize exactly `FAT_MAGIC`, `FAT_CIGAM`, `FAT_MAGIC_64`, and
`FAT_CIGAM_64`. Validate architecture count, table size, uniqueness of each
`(cputype, cpusubtype)` pair, alignment exponent before shifting, slice
alignment, nonoverlap, and file bounds.

For a top-level universal `.a`, parse each slice as an independent regular
archive. Build a metadata map per slice and require:

- the exact same logical key set in every slice;
- byte-identical canonical section payload for each key; and
- the same decoded ABI/types values.

Then expose one logical map. Do not run `AR t` on the outer universal file:
ordinary `ar` is not the universal-container inspector. Reject a fat object
member inside a regular archive: Darwin `libtool`/`lipo` do not accept that
noncanonical shape. A supported universal static provider is a top-level fat
container whose slices are regular archives containing single-architecture
`MH_OBJECT` members. A direct top-level fat `-X` object may be sliced to the
active target before it enters either output.

Interface lookup validates container structure and cross-slice metadata but
does not guess the active target from `uname` or from foreign-import macro
state. `driver.configure_foreign_c` only records compiler options, and
`TITAN_EXTRA_CFLAGS` can select a target independently of preprocessor flags.
After source compilation, parse the first generated Titan module object and
require it to be a single-architecture relocatable object. Use its object
header as the authoritative target fingerprint:

- ELF class, encoded endianness, `e_machine`, and ABI-relevant `e_flags`; or
- Mach-O word size, encoded endianness, `cputype`, and `cpusubtype`.

Every other generated object, selected archive member, and no-`main` `-X`
object must match that fingerprint before any native link or archive
construction. Select a top-level universal input's matching slice at this
point. A low-level metadata-only caller may parse interfaces while explicitly
deferring target compatibility. This ordering includes the actual configured
CC and `TITAN_EXTRA_CFLAGS` without adding a per-lookup subprocess.
Cross-target multi-output builds, COFF, LLVM bitcode/LTO archive members, and
unknown formats are explicit unsupported-format diagnostics for this
implementation.

### 3.5 Provider record and cache

Scanning `/root/a/b.a` produces:

```lua
{
    archive = "/root/a/b.a",
    relative_archive = "a/b.a",
    entries = {
        ["a.b.left"] = {
            abi = "0.16",
            types = "Module(...)",
            type = decoded_module_type,
            origin = "a/b.a[x86_64 slice, member 7 @ 0x1234, " ..
                "member.o, section 5 .titan.meta]",
            payload = canonical_section_bytes,
        },
        -- complete physical membership
    },
}
```

Cache this record by normalized absolute archive pathname for the compiler
invocation. When lookup of `M` selects this candidate, materialize only:

```lua
driver.imported[M] = {
    kind = "static",
    type = provider.entries[M].type,
    filename = provider.archive,
    static_archive = provider.archive,
    static_provider = provider,
}
```

Do not insert every provider key into `driver.imported` or make every key a
resolver result. Contextual nominal-owner recovery is the one deliberate
non-discovery use of the complete map and is specified in §5.2.

Never put an archive pathname in `Type.Module.file`. Deserialization may retain
the canonical logical `.so` default, but only a dynamic DSO probe overwrites
that transient field with a selected physical provider. The coder's static
branch ignores it.

Track separately:

```text
selected_static_modules
    names whose committed ordinary resolver provenance is kind = "static"

selected_static_providers
    deduplicated physical records referenced by those names

provider_physical_membership
    complete validated maps used only for overlap, validation, and repackaging

native_static_names
    source names plus every physical key carried by a selected archive;
    controls direct extern code generation, not lookup

native_binding_constraints
    contextual producer-static/direct or producer-dynamic/global requirements
    learned while recovering nominal owners from compiled interfaces
```

If a cached compiled dependency is later named as an explicit source root,
retain current source-root behavior and derive final static selection from
final provenance rather than monotone probe side effects.

### 3.6 ABI and embedded-format compatibility

Keep:

```lua
driver.TITAN_VER = "0.16"
driver.TITAN_VER_SUFFIX = "_0_16"
```

and `TITAN_PATH_0_16`. The native symbols, callable signatures,
`Type.Module` serialization, module layout, and DSO protocol do not change.
An old compiler ignores `.a`; a new compiler can use `.so` or `.a`.

The section banner has its own `v1`. An unknown banner is an archive metadata
format error, not a Titan ABI mismatch. A decoded entry with ABI other than
0.16 is a compile-time ABI error before its type string is executed.

## 4. Module resolution

### 4.1 Candidate sequences

For logical module `a.b.c.d`, define:

```text
DSO candidates:      a.so     a/b.so     a/b/c.so     a/b/c/d.so
archive candidates:  a.a      a/b.a      a/b/c.a      a/b/c/d.a
source candidates:   a/b/c/d/d.titan, then a/b/c/d.titan
```

Generalize `driver.module_binary_candidates` into a suffix-aware compiled
provider helper while retaining a compatibility wrapper if tests/external
callers use the old name. Validate dotted components once.

Both compiled passes use the expanded `TITAN_PATH_0_16`/`TITAN_PATH`. There is
no metadata side path. `;;` continues to insert:

```text
.;<rocks-root>/lib/titan/0.16
```

### 4.2 Global format preference and path precedence

Default:

```text
all .so roots/candidates
then all .a roots/candidates
then folder/flat source
```

`--static`:

```text
all .a roots/candidates
then all .so roots/candidates
then folder/flat source
```

The complete format pass is a deliberate new decision: “prefer static” must
allow a later search root's archive to beat an earlier root's DSO, and default
must symmetrically prefer any DSO. Within each format preserve the current
root-major, shallow-to-exact ordering:

```text
R1/a.ext
R1/a/b.ext
R1/a/b/c.ext
R1/a/b/c/d.ext
R2/a.ext
...
```

Keep independent relative-path occupancy sets for `.so` and `.a`. An earlier
root's existing relative pathname shadows the same extension/path in later
roots, including when an ancestor is a clean nonclaim. One extension does not
shadow the other; format-pass order decides between them.

A different key in an already scanned archive is not implicitly selected. Its
first lookup still runs these passes. Any unsafe physical overlap is diagnosed
after resolution under §5.4, never “fixed” by overriding candidate priority.

### 4.3 Archive claim matrix

For one existing `.a` candidate:

- a valid archive whose metadata map contains the requested name claims it;
- a valid ancestor archive without the key is a clean nonclaim;
- an exact archive without the key is a terminal “no Titan metadata for exact
  module” error;
- a read, archive, object, section, Lua chunk, schema, ABI, type, duplicate-key,
  or universal-slice error is terminal;
- a claimed entry stops deeper archive candidates and lower-priority formats;
  and
- only absent candidates and clean ancestor nonclaims allow scanning to
  continue.

The first valid claim wins; do not scan for ambiguous lower-priority providers.
Preserve current `lstat` occupancy semantics: a broken link, directory, or
unreadable occupied candidate is terminal rather than permission to consult a
later root. A usable external candidate may resolve through a symlink just as a
DSO can; the stricter “regular nonlink” rule applies to Titan's canonical
installed artifacts.
Representative diagnostics must name the logical module, archive, member/slice,
and section where applicable:

```text
cannot inspect static provider '/root/a.a' for module 'a.b': invalid archive member header at offset ...
static provider '/root/a.a' contains duplicate metadata for module 'a.b' in ... and ...
static provider '/root/a.a' has ABI mismatch for module 'a.b': expected 0.16 but found 0.15
static provider '/root/a.a' has invalid types for module 'a.b': ...
universal static provider '/root/a.a' disagrees for module 'a.b' between x86_64 and arm64
exact static provider '/root/a/b.a' contains no metadata for module 'a.b'
```

Metadata and code are one archive, so the sidecar-specific “missing companion
archive” error from the draft disappears by construction. An absent `.a`
candidate is ordinary absence; an existing invalid archive is a compile-time
error.

### 4.4 Source roots and fallback

Only after both compiled-format passes end in absence/nonclaim does the
existing folder-before-flat source resolver run.

Every explicit CLI module remains a source request:

- do not probe `.so` or `.a` for it;
- discard a cached non-source entry before resolving its source, as today;
- preserve contributor blockers and real-file diagnostics; and
- report `source module 'M' not found` rather than accepting a binary.

The one recursive loader propagates the selected preference to every non-root
import. Short standard-library import sugar is unchanged.

### 4.5 Preference is not a strict-static guarantee

The brief's literal order makes `--static` a preference:

- no `.a` + valid `.so` selects the DSO;
- no compiled provider + visible source compiles source;
- corrupt high-priority `.a` is an error, not permission to use `.so`; and
- a valid `.a` selects direct linking even when a DSO is beside it.

Do not advertise `--static` as `cc -static`, “no DSOs under all conditions,” or
a transitive guarantee. Code already compiled inside a selected archive keeps
the static/dynamic lowering chosen by its producer. The embedded metadata has
no dependency or link-flag manifest.

A DSO-free Titan executable is possible when every relevant provider has a
static closure and no `.so` fallback is used. The standard bundled-libuv
provider is the primary supported proof.

## 5. Checker and code-generation semantics

### 5.1 Three origins

| Origin | Interface source | Generated C import | Final native input | Run-time lookup |
| --- | --- | --- | --- | --- |
| Source | checked AST | direct `extern` | generated `.o` | none |
| `.a` | embedded section | direct `extern` | selected archive | none |
| `.so` | callable ABI/types | `loadlib` + `loadsym` | none | exact selected DSO |

No AST or type tag changes. `Ast.TopLevelImport` receives the same validated
`Type.Module` from either compiled format.

### 5.2 Resolver provenance versus native binding

The existing `static_deps` table currently answers two different questions:

1. did ordinary lookup of logical module `M` select source/static/dynamic?; and
2. will a native symbol owned by `M` be present directly in this final image?

They coincide for source and one-module providers but not for a re-exported
nominal owner. Split them.

`selected_static_modules` contains only names whose **ordinary** lookup selected
an archive and therefore causes that physical archive to become a link input.
It controls resolver diagnostics and provider deduplication.

`native_static_names` controls coder lowering. It is:

```text
every source module linked in this invocation
union
every logical metadata key physically present in every selected archive
```

Adding a physical key here does not add it to `driver.imported`, make the
archive a candidate for that name, create a shim by itself, or change search
priority. It only states that direct references to that owner's symbols can be
satisfied by an archive already selected for another key.

When `checker.checkimport` walks a recovered interface and encounters nominal
owner `N`, recover it in the context of the interface that exposed it. Before
repackaging, run the same exported-interface walk over **every physical
metadata entry** in each selected archive, including entries never selected by
ordinary lookup. This makes an unused carried facade's visible owner
constraints participate in preflight.

For each such owner:

- If the exposing dependency is a selected archive and that same archive's
  complete map contains `N`, decode/register that entry directly from the
  provider record and record a `direct-carried` native constraint. Do not run
  ordinary lookup for `N`.
- If a selected DSO exposes a valid `N_abi`/`N_types` protocol through the
  already-opened physical DSO, use it contextually without making that DSO a
  new candidate for `N`; its native symbols remain dynamic-global.
- Otherwise use the ordinary compiled-interface machinery in a
  **noncommitting type-only mode** to register `N`. This mode may read a DSO or
  archive interface, but it does not add an archive link input, populate
  `driver.imported[N]`, or choose native lowering. The exposing compiled
  module's producer already chose the native behavior, so record a
  `dynamic-global-through <exposer>` constraint. If no interface can be
  recovered, preserve the current unresolved-nominal diagnostic behavior.

The last case is essential. Suppose `facade.a` was produced while
`provider.so` was dynamic. Its object code still calls
`loadlib("provider.so")`; finding `provider.a` while compiling a consumer
cannot retroactively change that object. The consumer must initialize the
facade and resolve the provider-owned method/trampoline with `loadglobalsym`,
exactly as a DSO facade does today. Merely type-reading `provider.a` must not
select or link it.

Merge native constraints before code generation:

- direct plus producer-dynamic for the same logical owner is a terminal
  mixed-identity error;
- two different direct physical providers for one owner are a terminal
  overlap error;
- producer-dynamic exposures for the same owner from different physical
  selected archives are terminal because metadata cannot prove that their
  baked DSO paths identify one provider;
- producer-dynamic exposures from entries in the same selected physical
  provider may share the existing global-symbol path; and
- **any** independent ordinary resolution of that owner—source, `.a`, or
  `.so`—is terminal while a selected archive requires producer-dynamic
  binding. Even an interface-compatible DSO cannot be accepted: today's coder
  stores imported handles/function pointers by logical module, so it could
  redirect facade-origin references to the independently selected handle, and
  ABI/types metadata does not carry the baked provider identity needed to
  prove equivalence.

These rules enforce every dependency relationship visible through exported
ABI/types. They cannot reconstruct a selected object's private/non-exported
dynamic Titan imports, because the maintainer-required metadata contains only
ABI and serialized `Type.Module`, not a dependency/native-binding manifest.
Such private producer lowering remains inside the object and may still load a
DSO; the feature does not promise to diagnose a separately linked duplicate
private dependency. Document this limitation instead of claiming a global
producer invariant that the artifact cannot encode. As with DSO machine code,
a malicious hand-crafted object can also violate its declared interface and is
outside the trusted-artifact model.

The coder receives both ordinary import provenance and the finalized native
binding map:

- an explicitly imported dynamic module uses its checked handle;
- a transitive producer-dynamic owner uses `loadglobalsym` after exposing
  imports initialize;
- a source or physically carried owner uses direct `extern`; and
- no archive path enters `Type.Module.file`.

Because independent resolution of a producer-dynamic owner is rejected, the
current module-keyed `mprefixes`/function tables cannot accidentally collapse
those two native origins. This avoids a new per-reference provenance mechanism
that the metadata could not verify anyway.

### 5.3 Bookkeeping and deterministic archive order

Refactor driver/load results to distinguish:

- source modules/objects;
- per-name source/static/dynamic provenance;
- selected static provider records;
- complete physical membership;
- contextual, type-only nominal-owner recovery;
- finalized per-name native bindings/constraints;
- dynamic DSO imports; and
- `-X` native provider payload.

Deduplicate selected archives by normalized absolute pathname. Sort selected
provider paths with `util.bytewise_less`; source objects remain sorted by
logical name, and user `-X` arguments retain CLI order. ELF grouping and
Darwin's continual archive search make the sorted provider order link-safe;
do not alternate between incidental first-use order and bytewise order.

Treat contextual exposures/constraints as edges in the final dependency graph,
not monotone global booleans. If a long-lived loader cache entry is later
replaced because that name is an explicit source root, remove the compiled
entry's provider/exposure edges and derive selected archives,
`native_static_names`, and merged constraints again before preflight.

`tableloader` remains filesystem-free/source-static for unit helpers and
external callers.

### 5.4 Physical-overlap preflight

Run preflight after ordinary per-name resolution. It may reject an impossible
physical mixture, but must not change which provider won.

Inputs:

- all source module names and canonical checked ABI/types;
- all dynamic names and selected DSO paths;
- all actually selected static names/provider paths;
- every selected archive's complete embedded membership; and
- all producer-static/producer-dynamic nominal-owner constraints; and
- the reserved support module name `titan`.

For both library and standalone outputs reject:

- any selected archive's complete-membership overlap with a source or dynamic
  module, even when ABI/types are equal;
- any logical overlap between distinct selected archives;
- any direct versus producer-dynamic constraint for the same owner;
- any ordinary independently resolved module (including a DSO) for an owner
  constrained producer-dynamic by a selected archive;
- producer-dynamic constraints for one owner from different selected physical
  archives;
- any two direct constraints backed by different physical providers;
- mangled-prefix collisions;
- known module protocol/global-symbol collisions; and
- any physical Titan module without valid embedded metadata.

There is no source-shadow exception. Archive extraction is symbol-sensitive,
the metadata table does not enumerate every helper symbol, and an
interface-equal duplicate can still create two module-state or metatable
identities through precompiled dynamic code. Explicit roots remain
source-resolved, but the build fails if another selected archive physically
duplicates one.

For a no-`main` library, selected archives are then force-loaded and flattened.
For a standalone, they retain ordinary archive extraction; the preflight is
still strict because an archive-internal reference can extract a conflicting
implementation even when the current generated objects do not.

The metadata table cannot enumerate every native helper symbol. Known Titan
protocol collisions are preflighted; remaining ordinary native-symbol errors
are diagnosed by the linker with verbose archive paths.

## 6. Native linking and archive construction

### 6.1 Selected-provider final link

Use this conceptual order:

```text
entrypoint object (program only)
generated Titan module objects
selected static-provider archives
ordinary -X objects/archives
libtitan.a
libbacktrace.a
liblua.a
-l inputs
platform runtime libraries
TITAN_EXTRA_LDFLAGS
```

On ELF, rescan selected providers with each other, keep ordinary `-X`
objects/archives outside that group in their CLI order, and then supply the
Titan runtime:

```text
-Wl,--start-group
    <selected provider archives>
-Wl,--end-group
<ordinary -X objects/archives>
libtitan.a
```

The runtime archive's supported three-member contract has no reverse
references into generated/provider modules. Keeping it after `-X` therefore
resolves provider-to-runtime and `-X`-to-runtime references without changing
ordinary `-X` archive extraction; the provider-only group retains
provider-to-provider rescanning.

Keep backtrace/Lua and ordered user flags outside. On Darwin rely on the
documented continual static-library search; do not emit GNU group options.

`--static` never passes the system linker's `-static`.

### 6.2 One native payload for both provider forms

For a no-`main` provider, both outputs receive:

1. every generated source module object;
2. every selected static-provider archive;
3. every regular relocatable `-X` object; and
4. every regular `-X` archive.

DSO construction:

- link source/direct objects normally;
- force-load each selected provider and `-X` archive (`--whole-archive` on ELF,
  `-force_load` on Darwin); and
- return immediately to normal link mode before runtime/final libraries.

Static archive construction:

- add source/direct objects;
- flatten selected provider and `-X` archive members; and
- never insert a child archive as an opaque member.

Before either operation, scan/classify `-X` payload with the same ELF/Mach-O/
fat/archive parser. Reject directories, DSOs, bundles, executables, linker
scripts, thin/nested archives, wrong-host objects, malformed bytes, and any
Titan metadata section. This is an early no-`main` error because silently
omitting a payload would make `.so` and `.a` differ. Preserve broader existing
`-X` final-link behavior for executable-only builds.

Do not copy these common/final inputs into package archives:

```text
libtitan.a
libbacktrace.a
liblua.a
-l libraries
TITAN_EXTRA_LDFLAGS
```

Their unresolved references are ordinary static-library behavior. A consumer
repeats generic final-link requirements. No dependency/link manifest is hidden
in metadata.

### 6.3 Cross-platform archive builder

Add:

```lua
driver.build_static_archive(output, objects, archives, target, verbose)
```

It must:

- parse configured `AR` and `RANLIB` with existing safe argv parsing;
- stage on the destination filesystem;
- remove only its unique temporary output;
- accept paths with spaces/leading dashes;
- preserve the deterministic input order from §5.3;
- produce a regular archive, never thin/nested;
- run configured `RANLIB`;
- validate the complete produced member sequence and native protocols; and
- leave public paths untouched on failure.

Do not use MRI `ADDMOD`/`ADDLIB`. GNU `ar` prepends/reverses those inputs while
LLVM `ar` preserves them, and LLVM rejects combining deterministic `-D` with
`-M`. Instead, use the in-process parser to form one intended flattened
non-index member sequence:

1. generated source objects in deterministic logical order;
2. every object member of each selected provider archive, in archive order;
3. every direct `-X` object in CLI order; and
4. every object member of each `-X` archive, in archive and CLI order.

For a top-level universal input, select the active slice first. Extract/copy
each intended object into a unique numbered staging directory. A safe original
leaf name may be retained inside that directory, so duplicate leaf names
remain representable; archive member names are diagnostic, not semantic.
Never pass a child archive to the output archiver.

On every supported host, create the output with the configured archiver's
order-preserving quick append:

```text
ar qD <temporary.a> <ordered staged objects...>
ranlib -D <temporary.a>
```

Batch `qD` invocations below `ARG_MAX` while preserving sequence. Capability
probe the configured tools once per invocation: if deterministic `D` is not
supported, use `q` and ordinary `ranlib`, preserve content/order, and disable
only the byte-identical-rebuild assertion. Do not silently substitute a
different `AR`/`RANLIB`.

This is valid on GNU, LLVM, and Darwin `ar` because every input is now an
ordinary staged object rather than an archive that needs tool-specific
flattening. Run the configured `RANLIB` afterward. Real macOS CI must also feed
the result through `/usr/bin/libtool -static`, the linker, and universal-input
round trips as compatibility proofs; `libtool` is not a hidden replacement for
the configured `AR`.

Before archiving, record an intended manifest for **every** non-index object:
source origin, ordinal, byte length, object target fingerprint, and the exact
byte range/staged file. After archiving, parse the complete output and compare
the non-index sequence member-for-member and byte-for-byte using bounded
streaming reads. This detects omission, duplication, metadata-free `-X`
reordering, or tool-specific flattening that key-set/protocol checks cannot
see. Then scan the metadata union and build the archive-backed validation image
from §7.2.

The current host-only compiler always publishes a
**single-architecture regular archive**. A universal selected archive or
direct fat `-X` object contributes only the slice matching the authoritative
generated-object fingerprint. Silently preserving nonhost slices without the
new source modules would violate membership equality. A future true
multi-target build can emit all slices explicitly. Do not require `AR t` on a
universal input.

Duplicate object member leaf names are legal; safe staging must not collapse
their contents or order. Logical duplicates come from embedded keys and are
rejected independently.

### 6.4 Repackaging a selected static provider

A no-`main` build selecting one archive becomes a new physical provider:

- force-load the complete selected archive into the new `.so`;
- flatten its complete object membership into the new `.a`;
- carry its metadata sections automatically with those objects;
- add all newly compiled source objects/sections; and
- generate shims for the complete physical logical membership in the DSO.

Before composition, walk exported interfaces for every physical metadata entry
of each selected archive, including otherwise unused carried facades, and
merge those contextual nominal-owner constraints with every new
source/selected input. Reject any independent resolution of a
producer-dynamic owner, including a DSO, and reject conflicting exposures from
different physical archives. This prevents creating an archive that physically
contains `owner` while a visible carried facade still opens a second
`owner.so` identity.

The output archive scanner's intended key set is:

```text
all newly compiled source logical modules
union
all complete key sets from selected provider archives
```

The new provider pathname is discoverable only through ordinary candidate
prefixes. If `app.a` physically carries `third.party`, that entry proves what
the archive contains and supports already-compiled internal references; it
does not make `app.a` a candidate when a fresh compiler resolves
`third.party`. Document this rather than adding a hidden provider registry.

Therefore “repackaged providers can be consumed again” means through any
logical key for which the new pathname is an ordinary shallow-to-exact
candidate. It does not promise fresh direct imports of unrelated carried keys.

A standalone does not force-load selected archives. Its ordinary archive
search extracts only symbols reachable after source objects.

## 7. Output, validation, and publication

### 7.1 Output contract

| Build shape | Outputs |
| --- | --- |
| one or more requested roots, none defines exact Titan `main` | provider `.so`, provider `.a`, one shim per physical logical module, and `.so.dSYM` on Darwin |
| exactly one requested root defines exact Titan `main` (other requested roots allowed) | executable and existing entrypoint artifacts only |
| more than one requested root defines exact Titan `main` | existing compile-time error; publish nothing |

Refactor output planning around one base and preflight every destination:

```text
provider.so
provider.a
provider.so.dSYM
logical/module.lua
```

Preflight all output ancestors, reject symlink/nonregular native destinations,
reject any output that aliases a source/selected-provider/`-X` input, and keep
the exact generated-banner ownership check for shims. A regular existing
provider `.so` is replaceable under Titan's current output semantics; it has no
enumerable ownership marker, so do not claim that the compiler can distinguish
a “user-owned” DSO. Apply the same explicit-provider replacement rule to a
regular existing `.a`. The brief's “always produces” means every no-`main`
library invocation produces both native provider forms. Executable mode keeps
its established output model.

If a valid prior self-describing `provider.a` exists, scan its old physical key
set before replacement. For every old key absent from the new intended set,
derive the old shim pathname and require any existing file to carry Titan's
generated banner and exact provider/entry template. Add those files to the
publication plan as removals. This handles a generated provider rebuilt with
fewer modules without scanning directories or deleting arbitrary Lua files.
If there is no valid prior Titan archive (including the initial migration from
a DSO-only compiler), no old key set is enumerable; do not invent a broad shim
scan.

### 7.2 Staged equality validation

Before public rename:

1. load the staged DSO and validate every intended logical `_abi`, `_types`,
   `_init`, and `luaopen_` entry;
2. retain the fresh-process `luaopen_titan` support-table validation when the
   provider is `titan`;
3. scan the staged archive entirely in-process;
4. require its exact embedded key set to equal intended physical membership;
5. require every embedded ABI/types value to equal the staged DSO callable
   result byte-for-byte;
6. link and inspect an archive-backed validation image; and
7. validate every shim and Darwin dSYM.

Build a second, private shared image by force-loading **only the newly staged
archive** as provider payload, then adding the same runtime/Lua/backtrace,
`-l`, platform, system-libuv, and `TITAN_EXTRA_LDFLAGS` inputs used for the
sibling DSO. Reuse the provider DSO link function, so arbitrary DSO-only linker
flags are never replayed into an executable probe. The resulting image is not
published.

In a fresh child process, run the same native image validator against that
archive-backed image:

- resolve every `<mangled>_abi`, `<mangled>_types`, `<mangled>_init`, and
  `luaopen_<mangled>`;
- call each ABI/types entry and compare exact length/content with both the
  embedded section and sibling DSO result; and
- for provider `titan`, call `luaopen_titan` and validate
  `_loadlib`/`_loadlibglobal`.

This proves the archive itself contains the callable protocols, links with the
same final dependency policy, and catches a forged/stale object whose embedded
section and callable metadata differ. The ordered byte-for-byte member
manifest in §6.3 separately proves that metadata-free native payload was not
lost or reordered.

The normative equality is:

```text
embedded_archive_entry[name].abi
    == sibling .so <mangled>_abi()
    == sibling .a <mangled>_abi()

embedded_archive_entry[name].types
    == sibling .so <mangled>_types()
    == sibling .a <mangled>_types()
```

Both native forms define `_abi`, `_types`, `_init`, and `luaopen_` for exactly
the same physical logical membership. Their complete binary bytes differ
because a DSO resolves process-level runtime/final libraries while a static
consumer supplies those once.

Executable-only builds have no newly produced archive pair to validate, so
they need the corresponding selected-input gate. After compiling source
objects and deriving the target fingerprint, generate a private C validation
`main` for the ordinary selected keys and contextually direct-carried owner
keys actually used by the checked program. Link it as an executable with the
same source objects, selected Titan archives under **ordinary archive search**
(not force-load), ordinary standalone `-X` inputs, runtime/Lua/backtrace, `-l`,
platform inputs, and program `TITAN_EXTRA_LDFLAGS`. Explicit references to
each required ABI/types/init/Lua-open protocol extract exactly the relevant
module objects; unused metadata-bearing modules and metadata-free payload stay
unextracted just as they do in the real program. Call/compare those ABI/types
functions, validate bare Titan support when the program selects it, and run
the probe before linking/publishing the real program. Here the extra flags are
already an executable link policy, unlike the library-output case. This
prevents a consumer from trusting a forged required section without changing
standalone extraction semantics or rejecting an unused member's private
dependency.

### 7.3 Recoverable publication

Generalize the current DSO stage/publisher to one provider bundle:

1. stage `.so`, `.a`, shims, and dSYM under one unique sibling directory;
2. validate everything;
3. move generated public destinations and banner-owned stale shims to unique
   sibling backups;
4. publish new shims and dSYM, leaving retired shim paths absent;
5. publish `.a`;
6. rename `.so` last, preserving the current default-provider commit point;
7. remove backups only after success.

On errors caught by the publisher and injected failpoints in the running
process, restore all backups and remove stage residue. Add failpoints
before/after archive and DSO publication.

No multi-file POSIX transaction is crash-atomic without an identity indirection,
which this design deliberately does not add. Embedding makes each static
provider independently atomic and self-consistent: there is no `.a`/metadata
tear. The archive-first/DSO-last order ensures the default dynamic path changes
last. Do not claim recovery after `SIGKILL`, host crash, or power loss: unique
stale stage/backup paths are not an unambiguous journal and a later run must not
guess which generation to restore. Likewise, ordinary asynchronous
`SIGINT`/`SIGTERM`/`SIGHUP` handlers cannot safely run the Lua rollback
transaction, and the current Make trap only removes the private build stage;
do not promise signal rollback without a journal/cooperative mechanism. Tests
cover caught errors and injected in-process rollback only. Never publish an
unvalidated archive.

### 7.4 Standalone static proof

An end-to-end proof must:

1. build a dependency provider `.so`/`.a`;
2. compile an importing program with `--static`;
3. move the dependency DSO and shims out of search reach;
4. run successfully; and
5. inspect dynamic dependencies to show no Titan provider DSO.

Use `ldd`/`readelf` on Linux and `otool -L` on macOS in platform-gated support.
With bundled libuv, “single executable” means no Titan or libuv DSO; it does
not promise a static libc or removal of ordinary OS dynamic libraries.

## 8. Standard library and installed toolchain

### 8.1 Build and canonical outputs

Make owns:

```make
STDLIB_CONTAINER      := titan.so
STDLIB_STATIC_ARCHIVE := titan.a
STDLIB_PROVIDER_OUTPUTS := \
    $(STDLIB_CONTAINER) \
    $(STDLIB_STATIC_ARCHIVE)
```

The one existing compiler invocation still names all seven roots and passes
`titanlib.o` through `-X`. It now creates:

```text
titan.so
titan.a
titan/coroutine.lua
titan/uv.lua
titan/async.lua
titan/timer.lua
titan/fs.lua
titan/net.lua
titan/os.lua
titan.so.dSYM                 Darwin only
```

Archive scanning yields exactly seven keys. Each entry matches callable
metadata in both native forms. `titan.a` also defines `luaopen_titan` through
`titanlib.o`, which intentionally has no logical module metadata section.

The installer publishes:

```text
$ROCKS_TREE/lib/titan/0.16/titan.so
$ROCKS_TREE/lib/titan/0.16/titan.a
$ROCKS_TREE/lib/titan/0.16/titan.so.dSYM/     Darwin only
$ROCKS_TREE/share/lua/5.5/titan/{coroutine,uv,async,timer,fs,net,os}.lua
```

There is no `titan.tmm`, separate installed `libuv.a`, link, or `lib/lua`
compatibility copy. Direct SDK/stdlib artifacts remain outside the rock
manifest under the current ownership policy.

### 8.2 One libuv mode/input policy

Use `LIBUV_MODE` as the sole policy input.

Bundled mode:

- add the existing pinned `libuv-build/libuv.a` to the same `-X` provider
  payload list as `titanlib.o`;
- let the compiler force-load it into `titan.so`;
- let the compiler flatten it into `titan.a`;
- remove the duplicate whole-archive spelling from provider LDFLAGS; and
- retain only platform final libraries there.

Conceptually:

```make
STDLIB_EXTRA_OBJECTS := $(TITANLIB_O)
# bundled appends $(LIBUV_LIB)
```

Both checkout and post-install compiler calls use:

```text
-X <absolute titanlib.o> [<absolute bundled libuv.a>]
```

Bundled libuv's remaining platform references become part of the supported
final-link baseline:

```text
Linux: existing -ldl -lm, plus -lpthread -lrt
Darwin: existing -lm, plus -lpthread
```

Update installed/source link-input helpers and verify the exact list against
the pinned build in CI.

System mode:

- keep `pkg-config --libs libuv` or its user override as a final-link input;
- do not discover or copy a system `libuv.a` into `titan.a`;
- leave `uv_*` references in `titan.a` for the consumer's final link; and
- require a static-Titan consumer to repeat the same system setting.

Do not define “system” as “dynamic.” If the setting selects shared libuv,
`titan.so` and the final executable retain that DSO dependency. If the user
deliberately selects a static system library, the DSO linker may absorb its
reachable objects into `titan.so`, and a later executable link may absorb them
into the executable. In both cases it remains a repeated final-link input and
is never flattened or copied into the published `titan.a`.

### 8.3 Bootstrap and post-install

Keep the private bootstrap DSO-only. SDK staging may seed/preserve:

```text
$ROCKS_TREE/lib/titan/0.16/titan.so
```

but must not synthesize `titan.a`. The post-install hook explicitly compiles
all standard roots and therefore needs no static provider to create the full
pair.

The unchanged ABI means installation must recognize three predecessor states:

1. bootstrap-only `titan.so`, no standard shims/archive;
2. the normal pre-feature ABI-0.16 installation: a complete seven-module
   `titan.so` and generated shims but no `titan.a`; and
3. a complete post-feature `.so`/`.a`/shim pair.

Validate and transactionally replace state 2 rather than treating the absent
archive as corruption. At every injected failpoint, restore its exact old DSO,
dSYM, and shims and leave `titan.a` absent. This is a same-ABI artifact
migration, not a bootstrap case and not a reason to bump 0.16.

Extend the private destination-filesystem stage and
`scripts/stdlib_installer.lua` to:

- require regular `titan.so` and `titan.a`;
- scan/validate exactly seven archive metadata keys;
- compare embedded entries with DSO and archive callables;
- validate all protocols plus `luaopen_titan`;
- validate shims/dSYM;
- back up/publish/restore the archive with existing artifacts; and
- preserve the first-install bootstrap or previous complete pair on failure.

Factor the archive-backed image builder/validator from §7.2 into an installed
compiler helper used by both `titanc` and the source-only installer. Invoke the
installer under the **same effective build environment** as the immediately
preceding compiler call: configured `CC`, `AR`, `RANLIB`,
`TITAN_EXTRA_CPPFLAGS`, `TITAN_EXTRA_CFLAGS`,
`TITAN_EXTRA_LDFLAGS` (including the selected system-libuv setting),
`TITAN_ROCKS_ROOT`, and runtime-prebuilt mode. The helper derives
`libtitan.a`, libbacktrace, and the matching Lua archive from the supplied
installation root, force-loads staged `titan.a` into a private validation DSO,
and validates it in a fresh child process. Keep the compiler and installer
inside the same environment scope in `rock-post-install`; do not rely on the
current subshell that discards those values before invoking the script.
Pass `AR` and `RANLIB` explicitly to the compiler recipe too; Make variables
that are not exported must not silently fall back to different host tools.
Apply the same environment scope to checkout `stdlib`/`install-stdlib`, not
only `rock-post-install`: the source installer must receive the exact bundled
platform inputs or system `STDLIB_UV_LDFLAGS` that produced the staged pair.

The installer still rescans the current staged archive and compares all three
metadata sources itself. It does not trust a receipt or a probe image left by
the compiler, and no validation side artifact is installed.

Add installer failpoints:

```text
before:titan.a
after:titan.a
before:titan.so
after:titan.so
```

Test each over bootstrap first install, legacy full-0.16-without-archive
migration, and complete-pair upgrade.

### 8.4 Make ownership, warm builds, and CI snapshots

Add exact known generated archives to cleanup:

```text
titan.a
examples/utils.a
examples/artisanal.a
examples/sdl_quit.a
testfiles/selection_sort.a
testfiles/sieve.a
```

Do not add `*.a` or `examples/*.a` globs that could remove user archives.
Update `examples/Makefile` as well as the root `Makefile`: its paired-output
comments must name `.so`/`.a`, and its independent `clean` target must remove
only `utils.a`, `artisanal.a`, and `sdl_quit.a` in addition to its current
known outputs.
Audit every existing spec/helper that performs a no-`main` compile: extend each
manual teardown from its exact `.so` path to the derived exact `.a`, and teach
shared provider helpers to register/remove both. Do this for legacy suites too,
not only new tests; otherwise the new always-paired output leaks root archives.
Do not solve legacy cleanup with a root `*.a` glob.

The stdlib configuration/completion stamp records:

- archive output name;
- effective `AR`/`RANLIB`;
- embedded format/coder inputs;
- libuv mode and bundled archive identity;
- complete `-X` payload;
- platform support inputs; and
- all existing compiler/source/flag inputs.

A warm build validates the archive shape/key set without changing output
mtimes. Missing/corrupt archive invalidates completion and rebuilds the pair.

`spec/support/ci_stdlib_snapshot.sh` snapshots installed artifacts. Beside:

```text
provider=$prefix_rel/lib/titan/0.16/titan.so
```

add:

```text
static_archive=${provider%.so}.a
```

Include the exact path in save presence checks, tar contents, removal before
restore, restore, and mtime/content assertions. Keep checkout-root cleanup
separate.

### 8.5 Production libuv smokes

Extend `spec/support/ci_libuv_mode_smoke.sh`:

- accept inspection scopes `bundled`, `system`, and `both`;
- require installed `titan.a` as a regular nonlink file;
- scan its seven metadata entries and compare them with `titan.so`;
- bundled: prove both native forms contain the bundled closure, build/run a
  `--static` timer/fs or net/OS executable with `titan.so` hidden, and prove no
  libuv DSO;
- system: prove libuv is not copied into the archive and build/run with the
  same `pkg-config` final-link setting; and
- on CI apt/brew packages, first establish that system mode selected shared
  libuv, then require that dependency on both DSO and executable.

Make the script self-contained for its OS/process smoke. If
`TITAN_PROCESS_SMOKE_CHILD` is absent, create a unique temporary directory and
compile `spec/fixtures/stdlib/native/os_process_child.c` directly with the
configured CC, then clean it with the script trap. Do not require
`spec.support.os_test_support`: it imports test-only `luassert` and its bundled
helper assumes checkout `libuv-build/libuv.a`. In bundled mode, use the staged
`$PREFIX/include/uv.h`, installed `titan.a` as the libuv symbol provider, and
the documented bundled platform libraries. In system mode, use the active
`pkg-config`/user CFLAGS and final-link setting. CI may continue supplying one
shared fixture to avoid rebuilding it. Thus the documented commands work from
a clean installed prefix in either mode without an undeclared test dependency.

Installed-mode validation must build and inspect the same artifact:

```sh
LIBUV_MODE=bundled "$PREFIX/bin/luarocks" make --force
bash spec/support/ci_libuv_mode_smoke.sh bundled
LIBUV_MODE=system "$PREFIX/bin/luarocks" make --force
bash spec/support/ci_libuv_mode_smoke.sh system
```

Do not pair checkout-local `make stdlib` with a smoke that inspects the
installed prefix. Keep expensive production builds in the warmed producer and
macOS job, not the coverage consumer.

## 9. Source-level change map

### 9.1 `titanc`

Argument layer:

- add `--static` (“prefer static Titan archive providers”);
- document that no-`main` `-X` objects/archives feed both provider forms; and
- leave explicit root, `--tree`, `-l`, and standalone `-X` semantics intact.

Orchestration:

1. create one shared resolver context with format preference;
2. check requested source roots as today;
3. collect final source/static/dynamic provenance;
4. derive selected archives from actually selected static keys;
5. keep complete archive membership separate;
6. recover nominal owners contextually and merge native binding constraints;
7. build the coder direct set from source plus selected archives' physical
   membership, without bulk resolver activation;
8. run output-mode overlap/collision/binding preflight;
9. compile source modules with embedded sections;
10. derive the authoritative target from the first generated object and
    validate/select all native inputs;
11. link program or staged DSO;
12. in library mode build/validate the paired archive;
13. validate/publish the full bundle.

Replace `mod.ast` as the sole notion of static or output membership. A static
module has no AST in this invocation but its provider participates in the link;
its complete physical membership participates in native binding, overlap,
repackaging, and output validation without becoming ordinary resolver state.

Preserve current main selection: zero requested roots with the exact Titan
`main(args: {string}): integer` signature means library, exactly one means
executable even with other roots, and more than one is an error.

### 9.2 `titan-compiler/staticmetadata.lua` (new)

Own:

- canonical banner/chunk rendering;
- stable numeric C-byte initializer rendering;
- regular/thin archive recognition;
- GNU/BSD/Darwin archive member parsing;
- ELF section parsing;
- Mach-O section/load-command parsing;
- fat container/slice agreement;
- empty-`_ENV` outer schema validation;
- raw origin diagnostics; and
- native payload classification.

Origins must include top-level slice architecture where present, archive member
ordinal and header offset, member display name, and section index/name. A leaf
name alone is not unique.

Expose small interfaces such as:

```lua
staticmetadata.render(modname, abi, serialized_types)
staticmetadata.c_initializer(payload)
staticmetadata.scan_archive(filename, options)
staticmetadata.classify_object(bytes, origin, target)
```

Keep type-constructor decoding/canonical `Type.Module` validation in
`driver.lua` or a shared existing type helper to avoid making the binary parser
own checker semantics. Add this Lua module to the rockspec/compiler install.

### 9.3 `titan-compiler/driver.lua`

Resolver:

- generalize compiled candidates for `.so`/`.a`;
- add global format passes and `--static` option state;
- cache scanned provider records by normalized path;
- tag imports `source | dynamic | static`;
- materialize only requested archive keys;
- retain complete membership separately;
- support noncommitting contextual interface recovery;
- merge direct-carried versus dynamic-global native constraints;
- never set an archive in `Type.Module.file`; and
- make direct dependency bookkeeping use `native_static_names`.

Compilation/link:

- pass `driver.TITAN_VER` explicitly to `coder.generate`;
- factor canonical module-interface validation for DSO/archive reuse;
- classify/scan `-X` payload;
- add selected archives and ELF grouping to programs;
- force-load archives into new DSOs;
- build flattened regular archives;
- select active slices from universal inputs on Darwin;
- derive/validate target fingerprints from generated objects;
- build/inspect archive-backed validation images;
- compile/run selected-archive protocol probes in executable link context;
- generalize output stage/publish to `.so`/`.a`; and
- preserve safe argv construction and detailed `-v` output.

### 9.4 `titan-compiler/coder.lua`

Compute `types.serialize(ast._type)` once. Feed the same string to:

- the existing `_types` function; and
- `staticmetadata.render` for the embedded section.

Use the explicit ABI passed by driver for the section; retain the generated C
`TITAN_VER` function and ABI sync spec. Emit stable numeric bytes and section
attributes in every logical module translation unit.

Generalize the current dynamic/static import branches to accept finalized
native binding provenance. Audit all consumers:

- `import_module`;
- `init_data_from_other_modules`;
- imported functions/methods/statics;
- nominal owner trampolines; and
- initialization order.

An ordinary dynamic import keeps handle-scoped lookup, a producer-dynamic
transitive owner keeps `loadglobalsym`, and a physically carried owner uses
direct `extern`.

Update direct `coder.generate` spec callers for the new ABI argument.

### 9.5 Checker/types

No new AST/type tags or compatibility rules. Reuse:

- `types.serialize`;
- the constructor environment;
- canonical recursive module schema checks; and
- existing nominal owner/import requests.

Keep `Type.Module.file` transient and omitted from serialization. A nominal
owner request becomes contextual: consult the exposing selected archive (or
already opened DSO) only for that known owner, otherwise use noncommitting
type-only recovery. Keep this logic in the driver/checker import seam rather
than teaching general type code about archive paths. It is not a general search
of archive siblings.

### 9.6 Build, packaging, tests, and docs

Update:

- `Makefile` for `titan.a`, one libuv payload, completion/install/clean;
- `examples/Makefile` for exact paired-output comments/clean ownership;
- `titan-dev-1.rockspec` for the new compiler module and output expectations;
- `scripts/stdlib_installer.lua`;
- `spec/support/ci_stdlib_snapshot.sh`;
- `spec/support/ci_libuv_mode_smoke.sh`;
- CI output assertions/group membership; and
- spec helpers for isolated archive roots, archive hiding, and exact cleanup.

No change should be needed in the lexer/parser/AST, Titan native call ABI,
runtime loader, public standard APIs, or generated Lua shim behavior.

## 10. Phased implementation sequence

Reinstall the working compiler with the prefix's `luarocks make` after compiler
Lua changes because the installed rock shadows the checkout.

### Phase 1 — embedded format and bounded readers

1. Add `staticmetadata.lua` and pure binary fixtures.
2. Implement canonical empty-`_ENV` payload rendering/validation.
3. Emit ELF/Mach-O section bytes in generated module objects.
4. Implement ar, ELF, Mach-O, and fat readers with origin diagnostics.
5. Require universal slice agreement.
6. Derive target compatibility from a real generated object before native
   consumption.
7. Add negative raw-member/whole-archive and universal-tooling evidence tests.

Checkpoint: a generated `.o` exposes one validated ABI/types entry through the
in-process reader; real regular and universal archives scan without external
tools, and target compatibility includes actual compile flags.

### Phase 2 — resolver and static executable consumption

1. Add `.a` candidate generation and format passes.
2. Add `--static` and shared resolver cache.
3. Tag per-name provenance and materialize only requested keys.
4. Add contextual nominal-owner recovery and separate native binding
   provenance.
5. Extend direct/dynamic-global coder paths.
6. Collect/deduplicate selected archives.
7. Add ELF group/Darwin link ordering.
8. Add output-specific physical-overlap/binding checks.
9. Add the executable-context selected-archive protocol gate.
10. Add standalone hidden-DSO execution tests.

Checkpoint: `--static` imports an archive and runs with the provider DSO/shims
unavailable, while default still selects the DSO.

### Phase 3 — paired library production

1. Add native payload classification and reject metadata-bearing generic `-X`.
2. Implement ordered extraction plus configured `ar q[D]`/`ranlib [-D]`
   construction and full member-manifest comparison.
3. Handle active-slice extraction for universal inputs.
4. Force-load selected/`-X` archives into DSO and flatten into `.a`.
5. Add exact membership/DSO/archive metadata validation and archive-backed
   validation image.
6. Generalize staging/recoverable publication.
7. Add composition, duplicate member, collision, and failure tests.

Checkpoint: every no-`main` build emits a validated same-membership `.so`/`.a`
pair, and a provider can be flattened/repackaged then consumed statically
through an ordinary discoverable key.

### Phase 4 — standard library and installation

1. Add `titan.a` Make/install ownership.
2. Feed bundled libuv through shared `-X`.
3. Keep system libuv external to archive payload.
4. Add final platform baseline for bundled consumption.
5. Extend post-install/installer validation and rollback.
6. Extend exact clean/completion/snapshot ownership.
7. Add installed bundled/system executable smokes.

Checkpoint: the ABI directory has `titan.so`/`titan.a`; bundled async/libuv
works without either DSO, while system behavior follows the final-link setting.

### Phase 5 — manuals, full gates, and CI

1. Write/cross-link both manuals.
2. Update help, README, build/install guidance, AGENTS/CLAUDE.
3. Run focused suites after each reinstall.
4. Run complete local gates.
5. Verify push Linux CI.
6. Manually dispatch macOS CI and verify universal archive coverage.
7. Run an adversarial resolution/archive/rollback/docs review.

## 11. Detailed test plan

### 11.1 Pure embedded-format/container tests

Add `spec/staticmetadata_spec.lua` with small byte-accurate fixtures. Cover:

- canonical one-key chunk bytes and stable C initializer;
- canonical re-render rejection for whitespace/key-order/quoting variations;
- empty `_ENV`, checked `load`/`pcall`, exact one-result table including
  rejection of `return table, nil`, exact fields, valid keys, no metatables,
  and raw-only traversal;
- syntax/runtime/result/schema/ABI/type failures;
- malformed unused entry invalidating the complete provider;
- normal GNU/BSD short/long member names and all 32/64-bit Darwin index names;
- exact BSD `#1/n` payload/name/padding boundaries;
- duplicate archive member leaf names accepted;
- duplicate logical metadata key rejected with both origins;
- thin, nested, raw-member, truncated, bad-size, bad-padding archives;
- ELF32/64 both endian parsers, extended section counts/indexes;
- ELF wrong type/machine, duplicate/compressed/out-of-bounds sections;
- ELF `SHT_REL`/`SHT_RELA` targeting metadata rejected;
- Mach-O32/64/swapped headers and segment commands;
- Mach DSO/bundle/executable, duplicate/zero-fill/out-of-bounds sections;
- Mach metadata `nreloc ~= 0` and invalid relocation ranges rejected;
- all four fat magics, alignment/bounds/overlap/duplicate-arch failures;
- exact universal key/payload agreement and mismatch diagnostics;
- fat object inside a regular archive rejected;
- active-target mismatch detected from a generated object, including a target
  changed only by `TITAN_EXTRA_CFLAGS`;
- paths/member names containing spaces and diagnostic quoting; and
- no subprocess invocation during scanning.

Keep hand-built parser fixtures small; also generate real ELF/Mach-O archives
in platform integration tests so fixtures cannot merely agree with parser bugs.

### 11.2 Resolver and metadata tests

Extend `spec/driver_spec.lua`:

1. candidate spelling for `a.b.c.d`;
2. default global `.so` before `.a`;
3. `--static` global `.a` before `.so`;
4. root-major/shallow-to-exact order within formats;
5. path variables, `;;`, occupancy/shadowing;
6. archive ancestor nonclaim versus exact markerless error;
7. source only after both passes;
8. explicit roots source-only;
9. cached dependency later explicit root;
10. one archive scanned once and linked once for two keys;
11. selecting archive key `y` does not make its `x` key an ordinary resolver
    result;
12. later `x` lookup still chooses the preferred `x.so` in default mode;
13. a referenced owner physically carried beside `y` is contextually
    type-recovered/direct without making `x` independently discoverable;
14. physical overlap then fails preflight rather than changing provenance;
15. malformed archive/section/ABI/type is terminal; and
16. detailed slice/member-ordinal/header-offset/section origins.

Use observably different but interface-compatible DSO/archive implementations
to prove default executes DSO behavior and `--static` executes archive behavior.

### 11.3 Checker-facing tests

Add `spec/checker/static_compiled_modules_spec.lua`. Prove archive metadata
typechecks variables, functions, records, methods, record functions, aliases,
named parameters, variadics, and flexible returns exactly like DSO metadata.

Also prove:

- a facade archive that physically carries its nominal owner makes owner
  methods/trampolines direct without creating `driver.imported[owner]`;
- a facade archive produced with a dynamic owner preserves
  `loadglobalsym`/producer DSO behavior even when `--static` can see
  `owner.a`;
- type-only archive recovery never selects or links that owner archive;
- a later independent source/static/**dynamic** import of a producer-dynamic
  owner is rejected as unprovable identity, using observably different but
  interface-compatible owner DSOs;
- multiple facades requiring conflicting direct/dynamic owner provenance are
  rejected;
- an otherwise unused facade carried in the selected archive still has its
  exported nominal-owner constraints derived before repackaging;
- multi-key archive scan is cached without bulk `driver.imported` entries;
- bad unused metadata invalidates the provider;
- recovered archive/DSO `types.serialize` values are identical; and
- owner recovery consults only the exposing provider record, not arbitrary
  archive siblings; and
- `Type.Module.file` never carries an archive path.

### 11.4 Coder/executable tests

Add `spec/coder/static_compiled_modules_spec.lua`:

- each generated module object has one correct section;
- its section ABI/types equals its DSO callables;
- default importer generates DSO loading;
- `--static` importer generates direct extern/init/function/method paths;
- static generated C lacks loadlib/ABI/handle/path code;
- executable runs with DSO and shims hidden;
- forged/missing selected-archive ABI/types/init/Lua-open protocols fail the
  private executable-context gate before the real program is published;
- `.so` and source fallback remain;
- two keys from one archive add one physical link input;
- static/dynamic/source mixture works when physical memberships do not overlap;
- deterministic archive ordering and spaces in paths;
- any standalone source/archive physical overlap fails even when interfaces
  match;
- dynamic/static and multi-provider overlaps fail; and
- multiple requested roots with exactly one exact-signature Titan `main` remain
  executable mode.

Platform-gated dependency inspection proves no Titan DSO; bundled standard
tests additionally prove no libuv DSO.

### 11.5 Paired producer/archive composition tests

Extend `spec/coder/multi_module_libraries_spec.lua` or the topical suite:

- flat/folder single roots and compatible multi-root provider paths;
- unrelated roots still fail;
- `.so` and `.a` exact logical key equality;
- all four protocol symbols in both forms;
- exact embedded/DSO/archive callable ABI/types equality;
- forged section/function mismatch rejected by the archive-backed validation
  image;
- no contributor-only metadata entries;
- shims for complete physical DSO membership;
- deterministic archive bytes on unchanged rebuild where tools support it;
- configured tools without deterministic `D` preserve content/order while
  disabling only byte-hash stability;
- warm output mtimes;
- direct `-X` object in both forms;
- `-X` archive force-loaded/flattened;
- ordered full non-index manifest catches omitted, duplicated, and reordered
  metadata-free objects;
- metadata-bearing `-X` rejected;
- duplicate object leaf names/content/order survive unique-directory staging;
- raw/thin/nested/DSO/script payload rejected;
- configured AR/RANLIB wrappers observed;
- GNU and LLVM `q[D]` preserve the same intended order (no MRI);
- failing archiver/ranlib/archive-backed validation leaves old outputs;
- rebuilding a valid prior pair with fewer physical keys transactionally
  retires only the exact old banner-owned shims and restores them on failure;
- real GNU/LLVM archive coverage; and
- real Darwin configured-`ar` construction plus `libtool`/linker compatibility
  and x86_64/arm64 universal input scanning in manual macOS CI.

Build provider B by statically importing provider A, then consume B statically.
Choose a B pathname that is an ordinary candidate for the consumed key. Prove
A's module sections survive flattening, no nested archive exists, and
unrelated-prefix physical entries are not claimed through a fresh name lookup.
Add the negative facade/unrelated-owner lookup explicitly.

On macOS, build an x86_64/arm64 top-level universal provider, resolve it,
select the active slice from the generated-object fingerprint, statically
link/run a consumer, repackage it, and prove the published result is a
single-architecture regular archive with the complete intended metadata/member
sequence. A fat object member inside a regular archive is the paired negative
case.

### 11.6 Installer/publication tests

Extend `spec/stdlib_installer_spec.lua`:

- first install over bootstrap, migration from a complete ABI-0.16
  DSO/dSYM/seven-shim install with no archive, and upgrade over a full pair;
- missing/corrupt/nonregular archive;
- wrong key set, ABI, serialized types;
- embedded/DSO mismatch;
- embedded/archive-callable mismatch;
- missing logical protocol or invalid `luaopen_titan`;
- exact CC/runtime/system-libuv environment reaches the installer's own
  archive-backed validation image;
- failure before/after archive and at DSO commit;
- complete rollback of pair/dSYM/shims in all three predecessor states,
  including keeping the legacy archive absent;
- no stage/backup residue after caught/injected failure, without claiming
  signal/power-loss recovery; and
- successful replacement permissions and executable bits.

Extend `spec/rockspec_spec.lua` for canonical `titan.a`, new compiler module,
post-install expectations, and continued outside-manifest ownership.

### 11.7 Standard-library/libuv tests

Bundled:

- one pinned libuv archive enters through `-X`;
- DSO contains libuv and has no libuv DSO dependency;
- static archive contains bundled libuv members and seven Titan metadata keys;
- static async/timer/fs/net/OS executable runs with Titan/libuv DSOs hidden;
- no separate installed libuv archive.

System:

- archive does not contain libuv;
- it contains seven Titan protocols/metadata entries with unresolved `uv_*`;
- same `pkg-config` final setting consumes it successfully;
- a shared system setting leaves a libuv DSO dependency on `titan.so` and the
  executable;
- a deliberately static system setting may place reachable libuv objects in
  `titan.so`/the executable but still never in `titan.a`;
- CI apt/brew dynamic selection is inspected before requiring a DSO dependency;
  and
- no test claims system mode is universally dynamic.

Keep library behavior outside LuaCov; add only small compiler-focused cases to
covered suites.

### 11.8 Regression gates

Retain:

- current DSO selected-path/ABI/type errors;
- folder/flat source precedence;
- dynamic multi-module shims and `_loadlibglobal`;
- exact main behavior;
- ordered linker flags and standalone `-X`;
- runtime archive exact three-member ownership;
- bootstrap/full-image preservation;
- macOS dSYM transaction;
- library collision diagnostics;
- no cleanup of arbitrary user archives; and
- every legacy no-`main` fixture removes its exact new archive, with a
  post-suite residue assertion for known fixture roots.

## 12. Documentation plan

Create `doc/language/static-compiled-modules.md`:

- source/DSO/archive origins;
- default and `--static` search order;
- `.a` as self-describing static provider;
- embedded ABI/types equivalence to DSO metadata;
- explicit source roots;
- no-`main` paired outputs;
- single/multi-module examples;
- `-X` native payload in both forms;
- preference versus strict/full static;
- DSO/source fallback;
- producer-chosen transitive lowering;
- conservative rejection of independently imported producer-dynamic owners;
- the inability to infer private/non-exported dependency provenance from
  ABI/types-only metadata;
- bundled/system libuv behavior;
- repeated generic/system final-link requirements; and
- precise “single executable” meaning.

Create `doc/implementation/static-compiled-modules.md`:

- feasibility result and rejected raw/sidecar forms;
- generated section names/chunk schema;
- ar/ELF/Mach-O/fat parsers and bounds;
- universal slice agreement;
- candidate state machines/cache/provenance;
- resolver versus native-binding provenance and contextual owner recovery;
- exported-owner guarantees versus private producer dependency limitations;
- direct/handle/global coder paths;
- overlap/link ordering;
- ordered extraction, configured `ar q[D]` archive construction, complete member
  validation, and active-slice handling;
- exact three-way metadata validation;
- publication/installed ownership;
- same-ABI migration from the existing full DSO/shim install with no archive;
- stdlib/libuv policy; and
- why ABI stays 0.16.

Link both indexes and relevant module/import, multi-module, driver, and libuv
chapters. Update README, `titanc --help`, artifact-layout/install docs, and
AGENTS/CLAUDE prerequisites/commands/CI/clean ownership.

Use:

```sh
titanc geometry.shape geometry.draw
# geometry.so, geometry.a, and two shims

titanc --static app
# prefers self-describing geometry.a for Titan dependencies
```

For system libuv:

```sh
TITAN_EXTRA_LDFLAGS="$(pkg-config --libs libuv)" titanc --static app
```

Explain that this remains an external final-link setting; it retains a libuv
DSO when the setting selects shared libuv.

## 13. Validation and delivery gates

Prepare/reinstall:

```sh
export PREFIX="$HOME/.local/titan/titan-dev"
export PATH="$PREFIX/bin:$PATH"
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5
"$PREFIX/bin/luarocks" make
```

Focused:

```sh
busted spec/staticmetadata_spec.lua
busted spec/driver_spec.lua
busted spec/checker/static_compiled_modules_spec.lua
busted spec/coder/static_compiled_modules_spec.lua
busted spec/coder/multi_module_libraries_spec.lua
busted spec/libuv_build_spec.lua
busted spec/rockspec_spec.lua
busted spec/stdlib_installer_spec.lua
```

Installed mode:

```sh
LIBUV_MODE=bundled "$PREFIX/bin/luarocks" make --force
bash spec/support/ci_libuv_mode_smoke.sh bundled
LIBUV_MODE=system "$PREFIX/bin/luarocks" make --force
bash spec/support/ci_libuv_mode_smoke.sh system
```

Full:

```sh
make test
bash spec/support/ci_test_groups.sh libraries
bash spec/support/ci_test_groups.sh compiler
```

Then require:

1. push-triggered Linux CI green;
2. manual macOS dispatch:

   ```sh
   gh workflow run ci.yml --ref <branch>
   ```

3. all macOS jobs green, including real universal archive parsing/consumption;
   and
4. adversarial review before final push/PR handoff.

Do not put standard-library behavior under LuaCov.

## 14. Acceptance criteria

### Embedded artifact contract

- Every successful no-`main` invocation publishes same-base `.so` and `.a`.
- No `.tmm` is generated, searched, installed, snapshotted, or cleaned.
- Every generated logical module object contains exactly one canonical metadata
  section.
- The archive scanner's exact key set equals DSO logical membership.
- Embedded, DSO-callable, and archive-callable ABI/types bytes match for every
  key.
- Both native forms define every key's ABI/types/init/Lua-open protocol.
- Metadata contains no dependency graph, path, linker flags, checksum, or
  build-mode fields.
- Malformed archive/object/section/Lua/schema/ABI/types fails at compile time.
- A selected input archive whose callable ABI/types/protocol disagrees with its
  section fails before either a library bundle or executable is published.
- Universal slices have exact key/payload agreement.

### Resolution/code generation

- Default order is all `.so`, all `.a`, then source.
- `--static` is all `.a`, all `.so`, then source.
- Existing root-major/shallow-to-exact rules hold within a format.
- Explicit roots remain source.
- Selecting one archive key does not bulk-select siblings.
- Complete membership never bulk-enters ordinary resolver state.
- Complete selected-archive membership does enter `native_static_names`, so a
  referenced physically carried owner uses direct symbols.
- A producer-dynamic transitive owner remains global/dynamic; type-only
  recovery cannot select/link a visible owner archive.
- Any independent resolution of a producer-dynamic owner, including a DSO, and
  conflicting exposures from different selected archives fail before code
  generation.
- Exported owner constraints are derived from every carried physical
  interface; private dependency provenance is explicitly not inferable from
  ABI/types-only metadata.
- One physical archive is linked/scanned once for multiple selected keys.
- DSO/source fallback remains documented/tested.

### Native outputs/composition

- The same source objects, selected archives, and `-X` payload feed both native
  forms.
- Selected/input archives are force-loaded into DSO and flattened into `.a`.
- Common runtime/final libraries are not duplicated into package archives.
- Thin/nested/raw/nonobject archives are never published.
- The full ordered non-index member sequence equals the intended flattened
  payload byte-for-byte.
- Linux/Darwin and universal consumption are separately proved.
- A consumed universal provider publishes an active-target,
  single-architecture regular archive.
- Repackaged providers preserve embedded metadata and can be consumed again
  through ordinary discoverable keys; unrelated carried keys remain
  non-discoverable.
- Unsafe physical overlaps fail without changing resolution priority.
- Shrinking a valid generated provider retires only its exact stale
  banner-owned shims transactionally.
- A static standalone runs without its Titan provider DSO/shims.

### Standard library/install

- ABI directory has canonical `titan.so`/`titan.a` plus dSYM/shims.
- Archive has exactly seven standard module entries, all matching both forms.
- Bundled libuv is in both native providers and permits no Titan/libuv DSO.
- System libuv is never copied into `titan.a`. The repeated final-link setting
  leaves it dynamic when it selects a shared library, or lets the linker absorb
  reachable objects into `titan.so`/the executable when it selects a static
  system library.
- No separate libuv archive, sidecar metadata, links, or compatibility copies.
- Bootstrap first install, legacy full-0.16-without-archive migration,
  complete-pair upgrade, injected failure, warm build, snapshot/restore, and
  exact clean behavior preserve ownership.

### Docs/verification

- Both manuals, indexes, cross-links, help, README, and repo guidance ship.
- Targeted tests, full local gates, Linux CI, and manual macOS CI pass.

## 15. Risks, non-goals, and rejected alternatives

### Raw member and `.tmm` sidecar

A raw archive member is readable but incompatible with Titan's force-load and
Darwin universal workflow. A `.tmm` sidecar would work but would ignore the
brief's instruction to prefer archive embedding, duplicate publication
ownership, and permit metadata/code separation.

The valid object-section design uses parser work that is already necessary to
classify portable archive payload. It atomically binds the interface to code
without symbolic links, companion inputs, or a new package identity.

### Parser scope

The in-process reader is security-sensitive binary parsing even for trusted
artifacts. Every offset/count/addition needs checked bounds and origin-rich
errors. Keep it isolated and fuzz/property-testable. Do not shell out during
lookup or silently accept unknown/LTO/COFF forms.

Windows/COFF, cross-target builds, LTO bitcode, and a general package manager
are deferred. A future platform adds an explicit section/container reader and
tests rather than weakening validation.

### Physical membership is not resolver activation

One archive is a physical closure, but selecting one key does not make all
other keys preferred or discoverable. Bulk activation would violate format
priority and create a namespace lookup DSOs do not have. Unsafe overlap is an
output error, not a reason to rewrite provenance.

Physical membership does answer a narrower native question for an owner
already named by a recovered interface. A conforming archive that carries that
owner can satisfy direct symbols from the selected physical archive; an
archive that does not carry it preserves the producer's dynamic/global
lowering. Keeping that distinction out of ordinary resolver state avoids both
hidden discovery and duplicate type identities.

This guarantee is limited to dependencies visible in serialized public
interfaces. An archive object's private/non-exported Titan imports are not in
`Type.Module`; with the required ABI/types-only metadata there is no sound way
to recover their DSO path or native provenance. The object keeps that producer
lowering, and a composition can unknowingly include a separate private
dependency identity. Solving that would require a new dependency/provenance
manifest, which is explicitly outside this artifact contract.

### `--static` is not fully static

It deliberately falls back to DSO/source and does not absorb libc or arbitrary
final libraries. A consumed archive keeps its producer's lowering. Bundled
stdlib can prove no Titan/libuv DSO; system libuv follows the final linker
choice.

### One native input policy

There is no companion archive payload option. In library mode `-X` feeds both
native forms. Final-only `-l`/LDFLAGS remain external. This is the invariant
that puts bundled libuv in both provider payloads while keeping system libuv
out of `titan.a`; a static system selection may still be absorbed by the
ordinary final link into `titan.so` or an executable.

### Avoid these shortcuts

Do not:

- reintroduce `.tmm`;
- store metadata as a raw non-object archive member;
- find metadata by archive member name;
- invoke external tools during lookup;
- put archive paths in `Type.Module.file`;
- bulk-materialize archive keys;
- search source between compiled-format passes;
- make explicit roots binary;
- nest/thin archives;
- accept metadata-bearing generic `-X`;
- serialize link flags/dependencies;
- assume system libuv is necessarily dynamic;
- run `AR t` on an outer universal archive;
- publish before three-way metadata/protocol validation;
- glob arbitrary `.a` files in clean;
- run library behavior under LuaCov; or
- bump ABI 0.16 without a native/serialized protocol change.

## 16. Traceability to the attached brief and maintainer corrections

| Requirement | Plan resolution | Proof |
| --- | --- | --- |
| 0. Prefer metadata embedded/read from archive if feasible | §2 proves a valid object section survives required Linux/macOS workflows; `.tmm` is removed. | Raw-member negative and metadata-object whole-archive/universal tests. |
| 1. Static search between DSO and source, shallow-to-exact | §4 searches `.a` itself because it now contains metadata. | Resolver matrix §11.2. |
| 2. Empty-`_ENV` keyed Lua metadata and compile-time errors | §3.2–§3.4 embeds/evaluates the canonical keyed Lua chunk. | Schema/container failures §11.1. |
| 3. Type/code metadata and same-path static symbols | One `.a` now contains both; there can be no missing sidecar/archive pair. | Direct codegen, scanner, archive-backed link/validation tests §11.3–§11.5. |
| 4. Paired outputs and standard installation | No-`main` builds emit `.so`/self-describing `.a`; stdlib installs both in ABI dir. | Producer/installer tests §11.5–§11.7. |
| 5. `--static` order and single executable | §4.2/§7.4 implement preference and bundled proof. | Priority/runtime/dependency inspection. |
| Metadata has exactly the DSO information | Entries contain only `abi`/`types`; exact three-way equality is normative. | DSO/archive-backed callable checks and extra-field rejection. |
| `.so` and `.a` contents should match | Same module objects and provider payload feed both; physical logical key sets/protocols match. | Staged key/protocol equality. |
| No companion archive inputs | One source/selected-provider/`-X` payload graph feeds both. | Verbose link/archive command assertions. |
| Bundled libuv is static; system libuv stays external to `titan.a` | Bundled archive is flattened/force-loaded. The system setting is final-only and never copied into `titan.a`; it remains a DSO dependency when shared or may be absorbed into `titan.so`/the executable when static. | Bundled/system archive and dependency smokes. |
