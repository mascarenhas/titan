# Static compiled modules

Static compiled modules extend the compiled-module loader and native-output
pipeline without giving archives a different logical interface or native
calling convention from DSOs. Artifacts carry the current compiled-module ABI. One checked interface can come
from a DSO's callable metadata or from a canonical section embedded in an
archive member.

The implementation is split among:

* `coder.lua`, which emits the section beside each module's native protocol;
* `staticmetadata.lua`, which parses and validates native containers without
  subprocesses;
* `driver.lua`, which owns resolution, provenance, target validation, native
  linking, archive construction, and bundle publication;
* `linkcertificate.lua`, which certifies final provider pairs and executables
  before validation probes or links run; and
* `titanc`, which coordinates module compilation and finalizes invocation-wide
  membership.

## Why metadata is an object section

An archive can contain arbitrary raw bytes, but the native operations Titan
needs do not accept an arbitrary member uniformly. GNU whole-archive linking
rejects a raw metadata member, and Darwin's `libtool -static` and universal
tooling require valid native objects.

Titan instead emits one metadata section in each already-generated logical
module's primary object (part 0 of a
[split module](codegen-overview.md#translation-unit-parts)):

```c
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#define TITAN_META_LINKAGE static
#elif defined(__wasm__)
#define TITAN_META_SECTION \
    __attribute__((aligned(1), section(".titan.meta")))
#define TITAN_META_LINKAGE
#elif defined(__ELF__) || defined(_WIN32)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#define TITAN_META_LINKAGE static
#endif

#if defined(__clang__)
#define TITAN_META_NO_ADDRESS_SANITIZE \
    __attribute__((no_sanitize("address")))
#else
#define TITAN_META_NO_ADDRESS_SANITIZE
#endif

TITAN_META_SECTION TITAN_META_NO_ADDRESS_SANITIZE
TITAN_META_LINKAGE const unsigned char module_\u2119_titan_metadata[] = { /* canonical bytes */ };
```

The numeric byte array has no trailing NUL and no relocations. `aligned(1)`
requests byte alignment, while the Clang-only `no_sanitize("address")`
attribute prevents AddressSanitizer from adding a global redzone to the custom
section. Together they keep the section length equal to the canonical payload
length in both ordinary and sanitized builds. The interface therefore travels
with the object that defines the module's `_abi`, `_types`, `_layouts`, `_init`, and
`luaopen_` entries. Archive flattening naturally retains it, with no aggregate
metadata member to regenerate and no archive leaf name used as logical
identity.

When Emscripten or Clang compiles for `wasm32`, `__ELF__`, `__APPLE__`, and
`_WIN32` are all undefined, so the `__wasm__` branch selects the same
`.titan.meta` name; the trusted `.titan.source` emitter has the same branch
and the enum-carrier `.titan.cprobe` emitter already used the generic name.
Clang emits each array as a named DATA segment recorded in the `linking`
section's segment info. Byte alignment and the absence of relocations keep the
segment length equal to the payload. On Wasm the two payloads are unreferenced
external definitions without `used`: objects and archives keep both segments
for the metadata readers, and the final browser image link (`wasm-ld
--gc-sections`) drops them, like `.titan.cprobe`. No image reads any of them at
run time, and metadata reading never depends on the linked image. Their names
use the compiler-private `\u2119` separator (`coder._private_symbol`), so an
external payload never meets another module's protocol function, such as
`titan_object_source_init` of a module named `titan_object_source`, or a name
that an authored C helper defines.

The standalone entrypoint, runtime objects, `ltitanlib.o`, ordinary native
payload, and the part objects of split modules do not carry logical metadata.
A part object is a metadata-free member like other native payload; it adds no
logical key, and only the primary object identifies the module.

## Canonical payload

`coder.generate` computes the semantic `types.serialize(ast._type)` bytes and
separately encodes the public physical plans with `nominallayout.encode`.
The exact strings feed callable `_types`/`_layouts` entries and their separate
archive fields (shown schematically):

```lua
-- Titan archive module metadata v1
return {
    ["pkg.left"] = {
        abi = "<current ABI>",
        types = "Module('pkg.left', ...)",
        layouts = "<encoded public physical layouts>",
        imports = {
            "other.helper",
        },
    },
}
```

`staticmetadata.render` fixes whitespace, newlines, key spelling, and Lua
`%q` quoting. The banner versions the embedded container independently from
the compiled-module ABI.

Record and union public method/function maps use quoted Lua string keys in
their serialized type expressions. Member positions admit reserved words through
`AnyName` ([grammar](../language/grammar.md#identifiers-and-reserved-words)), so a
member named `end` survives metadata loading just like any other name. Member
ordering remains bytewise deterministic.

Validation compiles the chunk as text with an empty `_ENV`, protected-calls it
while counting results, and accepts exactly one plain table containing one
valid dotted module key. Its value must be a plain table with string
fields `abi` and `types`, plus an optional string `layouts`. Native compilation
requires `layouts` and validates its closed module-specific graph separately;
analysis-only inventory readers may accept its absence and expose only ABI/types.
Traversal uses `next` and `rawget` only after the
metatable checks. The validator then re-renders the entry and requires exact
payload equality.

Native objects also publish `imports`: a dense, strictly bytewise-sorted
list of distinct logical names from written Titan imports, including unused
aliases whose initializers still run. The field contains neither file
paths nor private source data. Strict static closure requires the field
on every reached module; `{}` declares no imports, while absence requests
an archive rebuild. Other readers and browser fixtures can read legacy
payloads. The banner and ABI version do not change.

The driver checks the ABI before evaluating the serialized type expression,
evaluates that expression with `types` as the constructor environment, and
applies the same closed `Type.Module` schema validation used for DSO metadata;
see [Interface recovery and the closed
validator](driver.md#interface-recovery-and-the-closed-validator). The decoded
module name and canonical logical `.so` filename must match the key. An archive
path is never stored in `Type.Module.file`.

Physical plans reconstruct only exported record prefixes and public variants;
private C declarations never enter that graph. Native provider and paired
publication checks compare layout bytes as well as semantic type bytes. See
[Native nominal storage](nominal-storage.md).

The empty environment is a declarative-artifact contract, not a hostile-code
sandbox: static providers are trusted native inputs just like DSOs.

## Bounded container reader

`staticmetadata.lua` reads the file once with an optional size bound and parses
all offsets and integer arithmetic in-process. Lookup does not invoke `ar`,
`nm`, `objcopy`, `lipo`, or a linker.

### Regular archives

The reader accepts `!<arch>\n` and rejects thin archives. It validates each
60-byte header, decimal size, `` `\n `` trailer, complete member range, and
even-byte padding. Supported names/indexes include:

* short `name/` members;
* GNU `/`, `/SYM64/`, `//`, and `/offset`;
* BSD `#1/<length>` attached names; and
* Darwin `__.SYMDEF` 32/64-bit sorted/unsorted variants.

Index and GNU string-table records are retained structurally but excluded from
the ordered object-member list. Every other member must be a supported
relocatable object. Nested archives, raw members, malformed long-name
references, and unsupported object formats are terminal. Duplicate member
leaf names are legal; duplicate logical metadata keys are not.

### ELF

ELF32/ELF64 and either encoded endianness are supported. The object must be
`ET_REL`. The parser validates the ELF identification and header sizes,
section-table bounds, extended section count/string-table index through
section zero, the section-name table, and exact `.titan.meta` matches.

One object may contain at most one metadata section. It must be uncompressed
`SHT_PROGBITS`, in bounds, and not targeted by an `SHT_REL` or `SHT_RELA`
section. The target fingerprint records class, encoded endianness, machine,
and ABI-relevant flags.

### COFF objects

The object reader also accepts ordinary little-endian COFF relocatable objects
with x86, x64, or ARM64 machine identities. It bounds the 20-byte header,
40-byte section records, 18-byte symbol records, string table, section data,
relocation tables (including overflow counts), and legacy line-number tables.
Long section names use their decimal offsets into the COFF string table.
Public `.titan.meta`, trusted `.titan.source`, and enum-query `.titan.cprobe`
keep their names and exact payloads. Selected payload sections must
contain initialized data and no relocations. PE images, short import objects,
BigObj, and other machine identities are rejected.

The COFF target fingerprint contains machine, word size, and little endianness;
it does not claim to identify the compiler or CRT configuration. The generic
archive reader can inspect ordinary COFF members through this same parser.
Windows remains DLL-only: nothing emits or links a static Titan provider there
(see [Experimental Windows build](windows-build.md)). Native dependency import
libraries are a separate linker input, and this reader rejects their short
import-object members.

### Mach-O and universal containers

The reader supports 32/64-bit native and byte-swapped Mach-O headers and
requires `MH_OBJECT`. It bounds `ncmds`/`sizeofcmds`, walks
`LC_SEGMENT`/`LC_SEGMENT_64`, and accepts exactly the regular
`__TEXT,__titanmeta` section with no relocations.

All four 32/64-bit fat magics are supported. Architecture table size,
`(cputype, cpusubtype)` uniqueness, alignment exponent and slice alignment,
non-overlap, and file bounds are checked. A universal provider is a top-level
fat container whose slices are regular archives of single-architecture
Mach-O objects. Fat objects inside a regular archive are rejected.

Every slice must expose the exact same logical key set and byte-identical
canonical payload for each key. Lookup can validate that agreement before
knowing the active target.

### Relocatable WebAssembly

The reader accepts relocatable Wasm objects as produced by `emcc -c` and by
Clang's `wasm32-unknown-emscripten` target, alone or as regular-archive
members written by `emar`/`llvm-ar`. It uses the same `Reader:range` bounds,
`fail(origin, ...)` diagnostics, and archive-member origins as the other
formats, reads the input once, and starts no subprocess.

* **Header.** Magic `\0asm` and version 1 (`unsupported Wasm version <version>`
  otherwise). The LLVM bitcode magics `BC\xC0\xDE` and `\xDE\xC0\x17\x0B` fail
  with `LLVM bitcode (LTO) object is not supported`, as an object or as an
  archive member; any other magic fails with `unsupported native object format`
  through `classify_object` or `unsupported native container format` through
  `scan_bytes`/`scan_archive`.
* **LEB128.** An unsigned 32-bit value has at most five bytes. Padded,
  non-minimal encodings are accepted because LLVM pads relocatable fields;
  a sixth byte (`Wasm u32 LEB128 exceeds 5 bytes`), excess bits in the fifth
  (`Wasm u32 LEB128 overflows`), and a missing terminator or a read past the
  section (`truncated Wasm u32 LEB128`) are rejected. Signed values occur in
  an `i32.const` segment offset (`Wasm i32 LEB128 exceeds 5 bytes`, `Wasm i32
  LEB128 overflows`, `truncated Wasm i32 LEB128`) and in relocation addends,
  decoded at 32-bit width or, for the 64-bit-addend relocation types, with a
  bounded ten-byte decoder (`Wasm i64 LEB128 exceeds 10 bytes`, `Wasm i64
  LEB128 overflows`, `truncated Wasm i64 LEB128`).
* **Sections.** Each section is an id and a u32 size inside the input
  (`Wasm section is outside the input (offset <offset>, size <size>, input size
  <size>)`). Known sections appear at most once and in canonical order, with
  DATACOUNT in its position before CODE (`duplicate Wasm section <id>`,
  `out-of-order Wasm section <id>`); an id that is not a known section is
  `unsupported Wasm section <id>`. A custom section's name lies inside the
  section (`Wasm custom section name is outside its section`). `linking`
  follows every known section, including DATA, and each `reloc.*` section
  follows `linking`.
* **Relocatable objects only.** A module without `linking` is a linked image
  (`Wasm object has no linking section`); `linking` must be version 2
  (`unsupported Wasm linking version <version>`). `dylink.0` marks a side
  module (`Wasm dylink.0 side module is not supported`) and imports from
  `GOT.mem`/`GOT.func` mark PIC code (`Wasm GOT import is not supported`). The
  reader supports only wasm32: the fingerprint's word size is the constant 32,
  and memory64 and shared memory fail with `Wasm memory64 is not supported`
  and `Wasm shared memory is not supported`.
* **DATA.** Each segment's flags (active memory 0 with an `i32.const` offset,
  passive, or an explicit memory index), size, and bounds are checked, and
  DATACOUNT must agree with the segment count (`Wasm DATACOUNT does not match
  DATA segment count`). The reader records each payload's absolute byte offset
  for the relocation checks.
* **`linking`.** The segment-info count must equal the DATA segment count
  (`Wasm segment-info count does not match DATA segment count`); each entry
  supplies the segment name, alignment, and flags (TLS among them). The symbol
  table is read for structural validation, resolving the names of undefined
  function, global, tag, and table symbols through the import index so no
  import loses its name. Init-function and COMDAT entries are only
  bounds-checked, and unknown subsections are skipped inside their bounds.
* **`target_features`.** Entries are `+`, `-`, or `=` prefixes with
  printable, non-whitespace ASCII names. A repeated name is a duplicate
  (`duplicate Wasm target feature "<name>"`) and a name with two different
  prefixes is a conflict (`conflicting Wasm target feature "<name>"`); the
  rest are sorted bytewise into a single-space list.
* **`reloc.*`.** The target section must exist (`Wasm relocation targets
  missing section <index>`), each entry type must be a known relocation type
  (`unsupported Wasm relocation type <type>`), offset plus width must lie
  inside the target section (`Wasm relocation is outside its target section`),
  and addends are parsed at their 32- or 64-bit width. A DATA relocation that
  patches a Titan payload segment fails with `Wasm payload segment "<name>" is
  targeted by a DATA relocation`, as ELF rejects `SHT_REL`/`SHT_RELA` sections
  targeting `.titan.meta`.
* **Payload segments.** `.titan.meta`, `.titan.source`, and `.titan.cprobe`
  occur at most once per object each (`duplicate Wasm payload segment
  "<name>"`) and must be active (`Wasm payload segment "<name>" is not
  active`), non-TLS (`Wasm payload segment "<name>" is TLS`), alignment 1
  (`Wasm payload segment "<name>" alignment is not 1`), untouched by any
  relocation (`Wasm payload segment "<name>" is targeted by a DATA
  relocation`), and inside the caller's size bound (`requested object section
  exceeds size limit`, or `metadata section size <size> exceeds limit <limit>`
  for `.titan.meta`). Other segments may be passive or more strictly aligned.
  `.titan.meta` then goes through the ordinary banner, schema, and re-render
  validation.

Names are decoded by length and bounds only; diagnostics quote them with
control bytes escaped. A parsed Wasm object exposes `format = "wasm"`, its
fingerprint, its DATA segments (`index`, `name`, absolute `offset`, `size`,
`active`, `tls`, `alignment` in bytes, `origin`), the selected metadata
segment and entry, the linking symbols in order (`kind`, `name`, `binding` of
`global`/`local`/`weak`, `defined`, `index`), and the imports in order
(`module`, `name`, `kind`). `staticmetadata.read_object_section` takes a
`wasm` segment name beside its ELF, COFF, and Mach-O selectors, so
`objectmetadata` reads `.titan.source` records and `cprobe` reads enum-carrier
answers from Wasm objects through the same accessor.

The Wasm target fingerprint is `{ format = "wasm", word_size = 32,
linking_version = 2, features = "<canonical list>" }`, where `features` keeps
the object's exact canonical `target_features` list. Fingerprints are compared
field by field in the order `word_size`, `linking_version`, `features`,
reporting `Wasm <field> <actual> does not match target <expected>`; a
different format reports `object format <actual> does not match target format
<expected>`. Features match when the lists are equal, or when both are
canonical and become equal after dropping the standalone `-shared-mem` token
from each, provided neither carries any other `shared-mem` or `atomics` entry
(`+shared-mem`, `=shared-mem`, `+atomics`, `-atomics`, or `=atomics`). LLVM's
`WebAssemblyLowerEmscriptenEHSjLj` pass emits that standalone token per object,
in each translation unit that calls `setjmp` or `longjmp`, so a `catch`-bearing
module and a plain one in the same non-threaded target must match. Every other
feature matches exactly: a subset is not compatible, `-x` never matches `+x`,
and a lookalike name such as `-shared-mem+atomics` is an ordinary feature. A
regular archive that contains any Wasm member requires every member to be Wasm
with a matching fingerprint, even when the caller supplies no expected target,
and names the offending member. In real `emar` archives the symbol index is
record #1, so the first object is `archive member #2`.

`scan_archive(filename, { independent_members = true })` relaxes only that
implicit cross-member inference: without an explicit `target`, each member is
classified on its own, so members with different feature vectors are
accepted. Emscripten's `libclang_rt.builtins.a` has such a member
(`__c_longjmp.o`, with an empty feature vector beside normally featured
members). Only the browser stdlib's
[dependency-closure check](browser-target.md#the-dependency-closure-check)
passes the option, because it inspects archive contents rather than selecting
a provider. An explicit `target` still applies to every member, and member
parsing, metadata validation, and the default scans used for provider lookup
and target selection stay strict.

## Target selection

Interface resolution may scan an archive before source compilation. It must
not infer the active native target from `uname`, foreign-import probes, or
host defaults: `CC` plus `TITAN_EXTRA_CFLAGS` can select another target.

After compiling source modules, the driver parses the first generated logical
module object and treats its fingerprint as authoritative. Every other
generated object, selected archive member, and library-mode `-X` object must
match. A universal input is then reduced to its one matching slice. The
current compiler publishes a regular single-architecture archive; it does not
silently preserve foreign slices that lack the newly generated modules.

For the [browser target](browser-target.md), the expected fingerprint is known
before resolution: it is the descriptor's. Browser archive scans pass it as
the expected target, so a native or differently featured archive fails at scan
time with the member origin, and the first generated object is cross-checked
against it rather than becoming the authority. A Wasm target also reduces a
metadata-only planned provider to a fresh scan of its bytes before structural
validation.

## Resolver state and format passes

One resolver context is shared by every requested root. It caches scanned
archives by normalized absolute path and keeps these concepts separate:

* per-name ordinary provenance: source, static archive, or dynamic DSO;
* selected static names;
* deduplicated selected physical providers;
* complete physical membership of each provider;
* type-only contextual owner recovery;
* native binding constraints; and
* the final direct-name set used by code generation.

Default lookup performs a complete `.so` pass, then a complete `.a` pass, then
source. A native library link refuses archive-only external dependencies;
`--static` executables and their compile-only builds omit the shared pass.
Each compiled pass remains path-root-major and shallow-to-exact, with an
independent occupied-relative-pathname set for its extension. A browser
context has only the `.a` pass, rooted first at the browser SDK directory and
then at the browser Titan path ([Provider lookup](browser-target.md#provider-lookup)).

An ordinary archive claim materializes the requested key in `driver.imported`.
An exact archive without the key is terminal; an ancestor archive without it
is a clean nonclaim.

Explicit roots bypass both compiled passes. If a name was cached earlier as a
compiled dependency, the source request replaces it. Selected providers and
constraints are derived again from final provenance rather than from monotone
probe side effects.

### Demanded archive closure

Native executable preflight traverses written imports of reached archive
members. It first honors the application's sources and already chosen
archives; strict `--static` resolves other reached names through the archive
pass and rejects missing inventories, missing owners and cycles. A default
executable follows a private edge only when its dependency is already
selected or belongs to the importing member's archive. Otherwise it keeps
the recorded DSO fallback. Reached names and archive observations feed
worker selection, the standalone protocol check and final-link certification.
Dormant siblings supply physical collision information only: their imports
and nominal interfaces do not create semantic requirements.

## Resolver provenance versus native binding

Ordinary lookup answers where a logical import came from. Native binding asks
whether an owner's symbols are physically direct in the final image. These
answers differ for a nominal record owner exposed through another compiled
module.

The final direct set is:

```text
all source modules in the invocation
union
all logical keys physically carried by every selected archive
```

When the checker walks an exported interface and encounters another module's
nominal record:

* if the exposing selected archive carries the owner, it reads that exact
  provider entry contextually and records a direct-carried constraint;
* if an exposing DSO carries the owner protocol, it reads the same DSO and
  records a dynamic-carried constraint; otherwise
* it uses compiled lookup in noncommitting type-only mode and records the
  dynamic fallback constraint.

Type-only recovery never adds an archive link input. Native executable
finalization replays reached interfaces, not every stored member. Purely
external dynamic obligations may share the same canonical, verified
provider, including library builds and multiple exposing DSOs. A physically
carried obligation still enforces exact native ownership. Full physical
membership is checked for overlapping names and native symbol collisions.

Public `Type.Module` metadata does not expose private imports. An object's
producer-chosen lowering remains in place; when it elects a dynamic provider,
the [linked provider set](codegen-overview.md#the-linked-provider-set) can
supply an owner from the same executable without changing that lowering.

## Generated import paths

The `direct`, `handle`, and `global` bindings and their generated sequences are
described in [Static vs dynamic dependency
wiring](codegen-overview.md#static-vs-dynamic-dependency-wiring). For static
providers the delta is:

* selecting an archive turns the import into `direct`: `extern` declarations
  and direct `_init`/function/method calls, checking that the returned module
  belongs to the exact linked producer. There is no runtime archive reader;
* finalized same-binary provenance skips runtime compatibility verification
  and keeps provider slot indices constant;
* `handle` and `global` go through the runtime provider descriptor. Only a
  `handle` lookup can elect a linked but uninitialized owner; `global` needs
  a canonical module that an earlier initializer already established.
  Neither binding uses `RTLD_DEFAULT`.

The [compatibility projection](binary-compatibility.md) does not alter archive
metadata or these ownership rules.

## Native composition

Program and test links (`driver.standalone_native_link_inputs`) order inputs as
source objects, selected Titan archives, `--c-source` objects and user `-X`
payload (`extra_objects`), Titan runtime/backtrace/Lua inputs, platform
libraries, `-l` inputs, and final flags. ELF first groups selected providers
with each other, leaves `--c-source` and `-X` inputs outside that group in their
original order (`--c-source` objects in first-source order followed by `-X`
inputs in CLI order), then groups `libtitan.a` with the selected providers at
the runtime position. Selected archives therefore receive an ordinary second
search after runtime members introduce references to metadata-free provider
payload, such as bundled libuv, while `-X` archives are never broadly rescanned
or force-loaded. Backtrace, Lua, platform, `-l`, and final-flag inputs remain
outside both groups. Darwin uses its continual archive search. `--static` never
becomes a system `-static` linker option.

The generated launcher anchors reached native members through their hidden
resolvers; it does not add references to dormant members. Native library
builds do not include another compiled Titan archive. They publish the same
source object list in both provider forms, with primary objects before their
parts. Native `--c-source` objects and metadata-free `-X` payload retain their
existing order. DSO construction force-loads those native payload archives
and `driver.build_static_archive` flattens their members in that same order.
Browser library composition still accepts selected browser archives.

Runtime, backtrace, Lua, `-l`, and final flags are not copied into the archive.

The configured `AR` creates a regular archive with order-preserving `qDc`
operations, split into command batches below a 64 KiB command-line ceiling
(`archive_batches`, `ARCHIVE_SHELL_COMMAND_LIMIT`). The configured `RANLIB`
indexes it with `-D`. `archive_tool_capabilities` probes both tools (for native
`AR`/`RANLIB` and browser `emar`/`emranlib`) and falls back to `qc` and plain
`ranlib` only when deterministic `D` is unsupported; it never substitutes
another tool. Those four capability probes run through `run_argv`'s
output-discard mode (`process.capture`), capturing and discarding tool
stderr/stdout independently of `driver.LIVE_PROGRESS` so expected `qDc` or `-D`
rejections do not leak usage output in quiet or non-live runs, while keeping
`-v` command echoes, the exit status, and the diagnostics of actual archive
writes and indexing. Each input member is staged in a unique numbered directory
so duplicate leaf names remain distinct.

Before archiving, the driver records every object's ordinal, byte length,
target fingerprint, origin, and exact numbered staging file. It then walks the
regular-archive headers sequentially and compares every non-index member with
that file in fixed 64 KiB chunks. This bounded verification retains no
aggregate produced-member payload while requiring the complete sequence to
match byte-for-byte, so it catches loss or reordering of metadata-free native
payload that a logical key check cannot see. The in-process object
scanner then makes its separate full pass to validate targets and the metadata
union.

## Three-way validation

Before publication of a native provider pair, the driver:

1. validates every logical protocol in the staged DSO;
2. scans the staged archive and checks its exact intended key set;
3. compares embedded ABI/types with the DSO callables;
4. force-loads only the staged archive into a private validation DSO, with the
   same final native policy; and
5. validates that image's ABI/types/init/Lua-open entries in a fresh process.

Thus, for every logical name:

```text
embedded archive ABI/types
    == sibling DSO callable ABI/types
    == archive-backed callable ABI/types
```

Standalone builds do not produce a sibling pair. Code generation reports the
physically direct owner modules whose native functions/trampolines the checked
source actually references. The driver links and runs a private
executable-context protocol probe for the ordinary selected archive keys plus
that use-site set, using ordinary archive extraction before publishing the real
executable. Exported-but-unused nominal types therefore do not force unrelated
members out of an archive.

A private archive dependency reaches `package.preload` only when its importer
initializes it; an unused archive sibling is neither extracted nor initialized.
The self-registering preload mechanism is described in [Linking a standalone
program](driver.md#linking-a-standalone-program-drivercompile_program).

For Interfaces, the use-site set includes the owner-exported native,
coercive-Lua, and strict bound-method symbols. Concrete/Interface pair arrays
and adjustment entries remain private to the generated module that needs the
conversion and add no archive protocol entry.

Ordinary archive extraction also completes a split module. The protocol entry
points pull in its primary member, and the parts' module-private definitions
are hidden but still global symbols in the archive index, so the primary's
references to them, and the parts' references to each other, pull in the part
members. No whole-archive option or extra input is needed.

## Provider link pipeline

Before generating synthetic runner or entrypoint sources, running
`driver.run_standalone_archive_probe`, or entering `driver.link_provider_pair`,
`titanc` prepares and checks a final-link certificate (`linkcertificate.prepare`
and `linkcertificate.check`) under `<output>/.titan-links/<key>/`, where
`<key>` is the SHA-256 digest of the canonical sorted final output paths. For a
Unix provider pair, the certified `outputs` set comprises `<provider>.so`,
`<provider>.a`, and `<provider>.so.dSYM` (on Darwin); for a standalone or test
program, it comprises the
executable (plus `.dSYM` on Darwin, or `<executable>.exe` and `<provider>.dll`
on Windows).

The link certificate hashes every input file by actual bytes: `objects` (all
compiled source module object parts in link order), `c_objects` (`--c-source`
nodes), `payloads` (`-X` inputs), `providers` (selected dynamic provider
files), `archives` (`selected_static_providers` `.a` files, covering their
complete member sequence and metadata), and `runtime` archives/objects, along
with `bindings` (`resolver_context.native_bindings`), `roots`, `entry`, `kind`,
`argv`, `toolchain` (compiler toolchain identity plus `AR`, `RANLIB`, `RC`),
`policy`, and `environment`. Because source-object certificates
(`incremental.lua`) fingerprint only the imported module's semantic public
interface and layout inside a binary provider while the link certificate hashes
the selected `providers` and `archives` files by content, an implementation-only
rebuild of a dynamic provider reuses consumer source objects without
recompiling them, while triggering a final relink of the consumer image when
`titanc` runs.

`titanc` restores any missing public foreign headers
(`driver.prepare_foreign_headers`) under the output lock before checking the
link certificate. On a hit (`Titan link hit <target>` under `-v`),
`linkcertificate.check` verifies the saved record, the non-symlink
kind/mode/content snapshot of every owned output file and directory entry, and
the content digests of all recorded linker-reported native library inputs
(`record.native`), and returns without running the standalone archive probe,
`driver.link_provider_pair`, three-way validation, or bundle publication.

On a link miss (`Titan link miss <target>: <reason>` under `-v`), `titanc`
calls `linkcertificate.invalidate` to remove `<output>/.titan-links/<key>/record`
before any final mutation, removes any stale `<ticket.directory>/link.d`, and
passes `link_ticket.dependency_argv` (`-Wl,--dependency-file=<link.d>` on GNU
ld/lld or `-Wl,-dependency_info,<link.d>` on Darwin ld64; compiler
`-print-file-name` fallback when `driver.native_link_backend` is `"none"`) to
the public DSO link (`request.final_link_flags` in `driver.link_provider_pair`)
or the final program link (`driver.compile_program`). Neither the private
`archive-validation.so` link nor `driver.run_standalone_archive_probe` receives
`final_link_flags`.

On Linux and macOS, `titanc` then hands a no-`main` provider to
`driver.link_provider_pair` once its objects are compiled and validated. The
function owns one sibling staging directory: the DSO keeps the public basename
there, beside the staged archive and the private `archive-validation.so`. It
returns the validated DSO/archive pair, which `driver.publish_provider_bundle`
then commits. Windows DLL providers have no archive and keep their synchronous
link and validation.

The pipeline has a fixed order, which is also its diagnostic order:

1. link the staged DSO;
2. build and verify the staged archive ([Native
   composition](#native-composition));
3. validate the DSO family: every logical protocol, the `titan` support entry
   for that reserved provider, archive/DSO equality, and fresh-process loading;
4. link the archive-backed image with the same final native policy as
   `driver.compile_archive_validation_image`;
5. validate the image family with the same four checks; then
6. return the pair for publication.

Concurrency follows the compiler's native job slots: the local bound and
parent GNU Make jobserver rules for generated-C compilation also govern these
links. Links run as native background jobs with captured output and a
completion FIFO.

* **One slot** (`--jobs 1`, `make -j1`, or an advertised but unusable
  jobserver) runs the six steps strictly one after another. Its links are
  still background children, so the pipeline asks `jobs.open_slots` for the
  cancellation guard even at one slot.
* **Several local slots without a usable jobserver.** The DSO link holds the
  recipe's implicit slot while the compiler builds and verifies the archive.
  The archive-backed link still starts only after the DSO link has been
  reaped: on Linux both links use `-flto=auto`, and two links without a
  jobserver would start two independent all-core LTRANS pools. The DSO
  validations then run while the archive-backed link runs.
* **A usable shared jobserver.** Once the archive is ready, the driver polls
  for a token together with the DSO link's completion. A token starts the
  archive-backed link at once under that borrowed slot. If the DSO link
  finishes first, the image link reuses the recipe's slot instead. The child
  inherits `MAKEFLAGS` and the jobserver descriptors, so GCC's LTRANS jobs draw
  from the same pool. The borrowed byte is returned when the link is reaped.
  Because LTRANS already fills the pool, the overlap mainly hides the serial
  WPA, final-link, archive, and validation work rather than halving the link
  time.

Overlap never reorders observable results. Each link's captured output is
replayed at a fixed point: the DSO's after the archive build, and the image's
after the DSO validations. `--verbose` announces the image command after the
DSO's replayed output, regardless of when its slot was granted. The first
failure in the step order above is the one reported, even when a later step
failed first in time; an image-slot acquisition error is likewise reported as
an image-link failure after the DSO steps. A failure, an unexpected error, or
an `INT`/`TERM`/`HUP` interruption does four things: it waits for every
running link, discards unreplayed output, returns borrowed tokens, and removes
the whole staging directory. Neither public path changes, and no temporary
sibling remains. An interruption is returned to `titanc`, which closes its
resolver (removing its own temporaries) and then re-raises the signal under
the restored action: `TERM` and `HUP` terminate the process, while `INT`
reaches the Lua interpreter's `interrupted!` handler. A PID-directed `INT`
that arrives while a synchronous archive tool or fresh-process validator runs
under `system()` can be ignored by the parent, as POSIX `system()` specifies.

`spec/coder/provider_link_pipeline_spec.lua` drives these cases with real
parent Make jobservers. It injects link and validation failures, including
dual failures where the later step fails first, and sends `TERM`, `HUP`, and
`INT` while links are live. The overlapped `TERM` case runs under a shared
jobserver. `spec/coder/lto_spec.lua` repeats its optimized provider pair under
a shared jobserver.

## Browser archive-only providers

A [browser](browser-target.md) library build publishes `<provider>.a` with no
DSO, dSYM, validation image, or fresh-process load. The provider output path,
the preflight reservation, and the certified output set all name the archive
alone, and the native runtime inputs are not linked. `driver.link_provider_pair`
dispatches a browser request to `driver.stage_browser_provider`, which stages
the archive in a sibling directory through `driver.build_static_archive` (see
[Library mode and structural
validation](browser-target.md#library-mode-and-structural-validation)) and then
runs the structural check against the coordinator's expected entries.

### Structural validation

`driver.validate_browser_provider(archive, expected_entries?, generated_objects?)`
inspects the reader's parsed archive and never loads or executes it. Provider
lookup runs it on every browser archive it inspects, without the optional
arguments; publication supplies both.

1. With `expected_entries`, the archive's key set and each entry's ABI,
   serialized types, and layouts must equal the coordinator's entries
   (`driver.compare_archive_entries`).
2. Every member must be a Wasm object:
   `<member-origin>: browser provider requires Wasm objects`.
3. No member may import, or leave undefined, `dlopen`, `dlsym`, `dlerror`, or
   any name beginning `backtrace_` or `__backtrace_`, whatever the symbol kind;
   both the Wasm import list and the undefined linking symbols are checked:
   `<member-origin>: browser provider imports forbidden symbol "<symbol>"`.
4. For each logical key, the member that carries its metadata (the primary
   member) must itself define `<prefix>_abi`, `<prefix>_types`,
   `<prefix>_layouts`, `<prefix>_init`, and `luaopen_<prefix>` as defined,
   global, non-weak functions, where `<prefix>` is the mangled module name.
   A definition in a sibling or a split part does not count, and a weak,
   local, or data definition fails:
   `<member-origin>: browser provider module "<name>" requires global non-weak function "<symbol>"`.
5. With `generated_objects`, every planned object of every module must occur
   in the archive with its original bytes, counting multiplicity:
   `browser provider module "<name>" is missing split part <index>` or
   `browser provider module "<name>" is missing its primary member`.

Generated-object validation reports a split part file that does not exist
with the same split-part diagnostic. This check replaces the host
`_loadlib` inspection that native publication performs; it is not a disabled
check, and publication then runs the [executing protocol
check](browser-target.md#the-executing-protocol-runner), which links a probe
image against the staged archive and runs it under Node.

### Archive-only publication and native companions

`driver.publish_provider_bundle(nil, staged_archive, public_archive, {
archive_only = true, context = ... })` publishes the archive alone:

1. the destination must end in `.a` (`browser provider path must end in .a`);
2. no native companion may exist (see below);
3. the staged archive must be a regular file that does not alias the
   destination;
4. a destination with the same regular-archive contents is kept, with its
   mtime, and the staged copy is removed;
5. otherwise the optional `before_commit` hook runs, the companions are checked
   again, and the rename of the staged archive over the destination is the
   single commit point.

A browser publication cannot know whether an existing native file beside the
archive belongs to it, so it refuses rather than deleting anything. The
companion suffixes are `.so`, `.so.dSYM`, `.dll`, `.dll.def`, `.dylib`,
`.dylib.dSYM`, `.dll.a`, `.lib`, `.exp`, and `.pdb` on the archive's stem.
Files, directories, and symlinks all count, and symlinks are not followed:

```text
browser provider "<archive>" has native companion "<path>"; use a separate --output directory
cannot inspect browser provider companion "<path>": <reason>
```

The check runs in the output preflight (before a warm final-link certificate
could hit), in output-path validation (before the unchanged-archive
shortcut), and again after `before_commit`. A refusal leaves the existing
archive, the staged input, and the companion untouched.

## Publication and installation

`driver.publish_provider_bundle(staged_dso, staged_archive, public_dso,
options)` publishes a no-main provider bundle. It stages the DSO, archive, and
Darwin dSYM on the destination filesystem. After validation, publication backs
up current owned paths, installs the dSYM, publishes the archive, and renames
the DSO last as the default dynamic-path commit point. Caught failures restore
all backups; tests inject them at the `before-dsym`, `after-dsym`,
`before-archive`, `after-archive`, `before-dso`, and `after-dso` boundaries
(`options.fail_at`/`inject_failure`). This is recoverable process-level
publication, not a claim of crash, power-loss, or asynchronous-signal
atomicity.

Before replacing an existing bundle, publication compares the staged DSO,
archive, and Darwin dSYM tree with their public counterparts
(`same_file_contents`, `same_regular_archive_contents`). The DSO and dSYM files
must be byte-identical with matching modes. A regular archive must
have the same record names/order/sizes, index and long-name bytes, member bytes,
padding, and file mode; only the fixed-width archive-header
timestamp/uid/gid/mode fields are ignored, accommodating configured tools that
lack deterministic `D`. When that complete owned set is unchanged, Titan
removes the staged artifacts and preserves the public bundle and its mtimes.
Any changed or missing member takes the ordinary transactional path.

After `driver.publish_provider_bundle` (or `driver.compile_program` /
`driver.publish_windows_provider`) succeeds, `titanc` calls
`linkcertificate.commit`, which re-observes every input file in a
[fresh context](incremental-compilation.md#fresh-verification-contexts),
rehashing only files whose observation changed, snapshots the published
outputs, records the linker-reported native
library inputs from `link.d` (or the compiler fallback), and writes
`<output>/.titan-links/<key>/record` last. Even when `publish_provider_bundle`
finds the staged pair byte-identical to the existing public outputs
and preserves their timestamps, `linkcertificate.commit` writes the updated
link record so subsequent no-op invocations hit before entering the link
pipeline.

Publication owns only the provider pair and its dSYM. It never scans a
directory and never creates or removes Lua files.

Every metadata entry carries `TITAN_ABI_VERSION`, independently of the
container banner version, and static validation checks it before schema
decoding or native linking; see [Compiled-module
ABI](codegen-overview.md#compiled-module-abi). Installing the standard
provider pair is a copy step owned by the build scripts; see [Build and
installation responsibilities](build-script-audit.md).
