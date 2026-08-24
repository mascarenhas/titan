# Static compiled modules

Static compiled modules extend the compiled-module loader and native-output
pipeline without giving archives a different logical interface or native
calling convention from DSOs. Current artifacts carry ABI 2. One checked interface can come
from a DSO's callable metadata or from a canonical section embedded in an
archive member.

The implementation is split among:

* `coder.lua`, which emits the section beside each module's native protocol;
* `staticmetadata.lua`, which parses and validates native containers without
  subprocesses;
* `driver.lua`, which owns resolution, provenance, target validation, native
  linking, archive construction, and bundle publication; and
* `titanc`, which finalizes invocation-wide membership before code generation.

## Why metadata is an object section

An archive can contain arbitrary raw bytes, but the native operations Titan
needs do not accept an arbitrary member uniformly. GNU whole-archive linking
rejects a raw metadata member, and Darwin's `libtool -static` and universal
tooling require valid native objects.

Titan instead emits one metadata section in each already-generated logical
module object:

```c
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#elif defined(__ELF__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#endif

#if defined(__clang__)
#define TITAN_META_NO_ADDRESS_SANITIZE \
    __attribute__((no_sanitize("address")))
#else
#define TITAN_META_NO_ADDRESS_SANITIZE
#endif

TITAN_META_SECTION TITAN_META_NO_ADDRESS_SANITIZE
static const unsigned char module_metadata[] = { /* canonical bytes */ };
```

The numeric byte array has no trailing NUL and no relocations. `aligned(1)`
requests byte alignment, while the Clang-only `no_sanitize("address")`
attribute prevents AddressSanitizer from adding a global redzone to the custom
section. Together they keep the section length equal to the canonical payload
length in both ordinary and sanitized builds. The interface therefore travels
with the object that defines the module's `_abi`, `_types`, `_init`, and
`luaopen_` entries. Archive flattening naturally retains it, with no aggregate
metadata member to regenerate and no archive leaf name used as logical
identity.

The standalone entrypoint, runtime objects, `ltitanlib.o`, and ordinary native
payload do not carry logical metadata.

## Canonical payload

`coder.generate` computes `types.serialize(ast._type)` once. The same bytes
feed the callable `_types` entry and:

```lua
-- Titan archive module metadata v1
return {
    ["pkg.left"] = {
        abi = "2",
        types = "Module('pkg.left', ...)",
    },
}
```

`staticmetadata.render` fixes whitespace, newlines, key spelling, and Lua
`%q` quoting. The banner versions the embedded container independently from
the compiled-module ABI.

Validation compiles the chunk as text with an empty `_ENV`, protected-calls it
while counting results, and accepts exactly one plain table containing one
valid dotted module key. Its value must be a plain table with exactly string
fields `abi` and `types`. Traversal uses `next` and `rawget` only after the
metatable checks. The validator then re-renders the entry and requires exact
payload equality.

The driver checks the ABI before evaluating the serialized type expression,
evaluates that expression with `types` as the constructor environment, and
applies the same recursive `Type.Module` schema validation used for DSO
metadata. That closed validation includes union/variant owner, tag,
constructor, namespace, callable-name, and value-facing-wrapper invariants;
`Type.Variant` is legal only in its owning union's variant list. It also
requires every direct `type_members` Interface to have the module/key-matching
owner, a canonical nonempty declaration-order Method list/name map, dense
unique fixed parameter names, and recursively valid value-facing signatures.
Interface/Method descriptors, error-recovery/no-value markers, nested modules,
C FFI descriptors, legacy wrappers, and unknown tags are rejected from
arbitrary value positions. The decoded module name and canonical logical
`.so` filename must
match the key. An archive path is never stored in `Type.Module.file`.

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
source. `--static` swaps the first two. Each compiled pass remains
path-root-major and shallow-to-exact, with an independent occupied-relative-
pathname set for its extension.

An archive claim materializes only the requested key in `driver.imported`.
Other physical keys remain provider metadata, not resolver results. An exact
archive without the key is terminal; an ancestor archive without it is a clean
nonclaim.

Explicit roots bypass both compiled passes. If a name was cached earlier as a
compiled dependency, the source request replaces it. Selected providers and
constraints are derived again from final provenance rather than from monotone
probe side effects.

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
  records dynamic-global binding; otherwise
* it uses compiled lookup in noncommitting type-only mode and records that the
  exposing producer remains dynamic-global.

The type-only path never inserts the owner into `driver.imported` and never
adds an archive link input. Before repackaging, the same walk runs over every
physical interface in each selected archive, including unused carried
facades.

Finalization rejects direct/dynamic identity mixtures, overlapping logical
membership, conflicting physical providers, producer-dynamic exposures from
different archives, independent resolution of a producer-dynamic owner,
mangled-prefix collisions, and known native protocol/member collisions.
Preflight rejects an impossible mixture; it never changes which candidate won.

The public `Type.Module` metadata cannot reveal private imports. Their
producer-chosen lowering remains in the object and is outside these exported-
interface guarantees.

## Generated import paths

The existing three code-generation paths remain:

* `direct`: `extern` declarations and direct `_init`/function/method calls;
* `handle`: load the selected `Type.Module.file`, check ABI, and use
  handle-scoped `loadsym`; and
* `global`: initialize the exposing DSO and recover a transitive owner with
  `loadglobalsym`.

Static archive selection changes an import to `direct`; it does not introduce
a runtime archive reader.

## Native composition

Final link order is source objects, selected Titan archives, user `-X`
payload, Titan runtime/backtrace/Lua inputs, platform libraries, `-l` inputs,
and final flags. ELF first groups selected providers with each other, leaves
ordinary `-X` inputs outside that group in their original CLI order, then
groups `libtitan.a` with the selected providers at the runtime position.
Selected archives therefore receive an ordinary second search after runtime
members introduce references to metadata-free provider payload, such as
bundled libuv, while `-X` archives are never broadly rescanned or force-loaded.
Backtrace, Lua, platform, `-l`, and final-flag inputs remain outside both
groups. Darwin uses its continual archive search. `--static` never becomes a
system `-static` linker option.

Library-mode DSO construction force-loads selected-provider and `-X` archives.
The paired static archive flattens the identical logical/native payload:

1. source objects in bytewise logical-name order;
2. selected providers in bytewise absolute-path order, preserving member
   order;
3. every `-X` input in CLI order, inserting one object directly or each
   archive's objects in member order at that position.

Runtime, backtrace, Lua, `-l`, and final flags are not copied into the archive.

The configured `AR` creates a regular archive with order-preserving `qDc`
operations, batched below `ARG_MAX`; configured `RANLIB -D` indexes it. A
capability fallback drops only deterministic `D`, never the configured tool.
Each input member is staged in a unique numbered directory so duplicate leaf
names remain distinct.

Before archiving, the driver records every object's ordinal, byte length,
target fingerprint, origin, and exact numbered staging file. It then walks the
regular-archive headers sequentially and compares every non-index member with
that file in fixed 64 KiB chunks. This bounded verification retains no
aggregate produced-member payload while requiring the complete sequence to
match byte-for-byte, so it catches loss or reordering of metadata-free native
payload that a logical key check cannot see. The existing in-process object
scanner then makes its separate full pass to validate targets and the metadata
union.

## Three-way validation

Before publication, the driver:

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
members out of an archive. Selecting the shallow standard `titan.a` also makes
the probe validate `luaopen_titan` and its `_loadlib`/`_loadlibglobal` support
table.

For Interfaces, the use-site set includes the owner-exported native,
coercive-Lua, and strict bound-method symbols. Concrete/Interface pair arrays
and adjustment entries remain private to the source object that needs the
conversion and add no archive protocol entry.

## Publication and installation

A no-main provider bundle stages the DSO, archive, shims, and Darwin dSYM on
the destination filesystem. After validation, publication backs up current
owned paths, installs shims/dSYM, publishes the archive, and renames the DSO
last as the default dynamic-path commit point. Caught and injected failures
restore all backups. This is recoverable process-level publication, not a
claim of crash, power-loss, or asynchronous-signal atomicity.

Before replacing an existing bundle, publication compares the staged DSO,
archive, generated shims, and Darwin dSYM tree with their public counterparts.
The DSO, shims, and dSYM files must be byte-identical with matching modes. A
regular archive must have the same record names/order/sizes, index and
long-name bytes, member bytes, padding, and file mode; only the fixed-width
archive-header timestamp/uid/gid/mode fields are ignored by the equivalence
comparison, accommodating configured tools that lack deterministic `D`. When
that complete owned set is unchanged and no stale shim needs retiring, Titan
removes the staged artifacts and preserves the public bundle and its mtimes.
Any changed or missing member takes the ordinary transactional path.

When replacing a valid prior self-describing archive with fewer keys, its old
key set enumerates the exact stale generated shims eligible for transactional
removal. Titan never scans a directory and never removes an unrecognized Lua
file.

The canonical standard installation places `titan.so` and `titan.a` together
under `lib/titan/0.6`. Post-install recognizes bootstrap-only and complete-pair
states within that active library namespace. Earlier Titan installations are
not migrated, cleaned up, or treated as active-layout predecessors.

The embedded metadata container is independent of the compiled-module ABI,
but every entry carries ABI `2`. Static validation checks it before schema
decoding or native linking. This protects the current Array and function
representations, union and Interface schemas, generic declarations,
source-private provider identity, callable symbol hierarchy, callback
ownership, const/member state, wrapper slots, and qualified Array runtime
state. See [Dense Arrays](dense-arrays.md#abi-boundary).

Bundled libuv enters as shared `-X` provider payload and is present in both
native forms. System libuv remains a repeated final-link setting and never
enters `titan.a`.
