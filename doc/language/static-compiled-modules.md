# Static compiled modules

Titan libraries have two native forms:

* a shared provider (`.so`), loaded when a program runs; and
* a static provider (`.a`), linked directly into another Titan library or
  executable.

Both forms describe the same logical Titan modules and export the same native
module protocols. A static provider is self-describing: each Titan-generated
object in the archive carries the logical module's ABI and serialized public
type interface. No metadata sidecar is needed.

This is an artifact and dependency-resolution feature. It adds no new Titan
syntax and does not change the meaning of `import`.

## Paired library outputs

A successful `titanc` invocation with no exact-signature `main` publishes both
provider forms. For example:

```sh
titanc geometry.shape geometry.draw
```

produces:

```text
geometry.so
geometry.a
geometry/shape.lua
geometry/draw.lua
```

The provider name is still the longest common sequence of complete dotted
components in the explicitly requested roots. The `.so` and `.a` therefore
always have the same base name. See [Multi-module
libraries](multi-module-libraries.md) for the provider-prefix and generated
Lua-loader rules.

Each logical module remains independent inside the two physical providers. It
keeps its own module state, initializer, ABI entry, type entry, Lua entry, and
nominal record/union/Interface identities. A folder module still produces one
logical object and therefore one metadata entry; contributor filenames are not
modules.

When exactly one requested source root declares
`main(args: {string}): integer`, `titanc` retains executable-only behavior. It
does not publish a provider pair beside the executable.

## Dependency search

An imported module can now originate from source, a shared provider, or a
static provider. The default search order is:

1. every eligible `.so` candidate in the Titan binary path;
2. every eligible `.a` candidate in the Titan binary path; and
3. folder then flat source in the Titan source path.

Within one native format, lookup keeps the existing path-root-major and
shallow-to-exact order. For `a.b.c`, one path root is searched as:

```text
a.so      a/b.so      a/b/c.so
a.a       a/b.a       a/b/c.a
```

The complete `.so` pass finishes before the `.a` pass begins. Consequently a
DSO in a later Titan-path root beats an archive in an earlier root by default.
An existing candidate pathname shadows the same relative pathname in later
roots for that format, even when an ancestor provider does not contain the
requested logical module.

Only after neither compiled format claims the module does source lookup run.
An invalid, unreadable, or incompatible existing compiled candidate is an
error; it is not treated as absence.

Modules named explicitly on the `titanc` command line are always source build
roots. Neither native format can replace an explicit source request.

## Preferring static providers

Pass `--static` to swap the two compiled-format passes:

```sh
titanc --static app
```

The order becomes:

1. every eligible `.a`;
2. every eligible `.so`; and
3. source.

`--static` means “prefer static Titan providers.” It does **not** pass
`-static` to the system linker and it is not a static-only requirement. When
no archive claims an import, a valid DSO or visible source remains a supported
fallback.

A Titan executable can run without a Titan provider DSO when every imported
Titan dependency selected source or a suitable archive. This does not imply a
static libc or an executable with no operating-system dynamic libraries.

## What a static provider contains

Every generated Titan module object contains one canonical metadata section:

```text
ELF:    .titan.meta
Mach-O: __TEXT,__titanmeta
```

The section is a canonical chunk whose returned table has exactly one logical
module key:

```lua
return {
    ["geometry.shape"] = {
        abi = "0.24",
        types = "Module(...)",
    },
}
```

for that object's logical module. These are the same values returned by the
module's `<mangled>_abi` and `<mangled>_types` functions in the shared
provider. The compiler validates the complete archive and rejects malformed
containers, duplicate logical keys, incompatible ABIs, invalid type
interfaces, or disagreement between the embedded and callable forms before
publishing or consuming an artifact.

ABI 0.20 introduced Interfaces, the two-user-value Array proxy, and the
fixed-brand/strict-trailer function-closure protocol. Interface schemas,
per-state nominal metatables, wrapper payloads, vtables, and method trampolines
are part of the same compiled contract. Its generated layout cannot be mixed
with a 0.19 provider, so archive metadata is rejected before native composition
rather than adapted. ABI 0.19 added serialized union/variant schemas and the
reconstructible public module prefix for first-class record/union statics; its
generated userdata/tag contract could not be mixed with a 0.18 interface.
ABI 0.18 previously required
generated standard-library archives and the matching runtime to agree on
promoted callback trampolines and retired libuv/coroutine helpers. ABI 0.17
introduced the current Array
backing/proxy contract even though `Array(...)` serialization and exact native
pointer widths stayed unchanged. A separately installed 0.17 archive remains
in its versioned directory but is rejected as a dependency.

Interface descriptors introduced in ABI-0.20 metadata preserve nominal owner and
declaration-order method signatures. A consumer can therefore validate and use
an imported Interface without seeing a concrete implementation; concrete
record/union-to-Interface wrapper construction remains a statically known
direct coercion rather than dynamic provider discovery. See
[Compiled compatibility](multi-module-libraries.md#compiled-compatibility).

Selecting one logical key makes that archive a native link input. It does not
make every other key in the archive an ordinary lookup result. A later import
of another name still follows the normal `.so`/`.a`/source priority.

The archive's complete physical membership does matter for native composition.
When a selected archive is repackaged into a new provider, all of its object
members are carried into both new native forms. A carried module is freshly
discoverable only when the new provider pathname is an ordinary candidate for
that logical name.

## Direct and dynamic dependencies

Code generated against a selected static provider calls its Titan entries
directly. Code generated against a DSO loads the selected shared provider and
resolves entries through its checked handle.

There is one important transitive case. A compiled module interface may expose
a record, union, or Interface owned by another logical module. If the selected
archive physically carries that owner, the owner's methods and bound-method
entries are direct too. If it does not, the archive's producer already chose a
dynamic owner:
the consumer recovers the owner's type without silently selecting a visible
owner archive, initializes the exposing dependency, and resolves the owner's
native entries from the process-global provider namespace.

An Interface wrapper also strongly retains the concrete value's owning module
state. Consequently a consumer that imports only the Interface owner may call a
wrapper constructed by another module: the retained owner supplies the correct
per-state concrete method context, whether that owner was selected statically
or dynamically.

Titan conservatively rejects a build that independently imports a source,
archive, or DSO implementation of such a producer-dynamic owner. ABI and type
metadata cannot prove that the independently selected implementation is the
same native identity baked into the compiled facade.

Static metadata deliberately contains only ABI and public type information. It
does not contain a dependency graph, provider paths, checksums, or link flags.
Private, non-exported dependencies of precompiled objects therefore retain the
producer's lowering and cannot be reconstructed or globally diagnosed from
the public interface alone.

## Native payloads and final libraries

In library mode, `-X` supplies native object/archive payload to both provider
forms:

```sh
titanc package.one package.two -X native.o helpers.a
```

Archive payload is force-carried into the DSO and flattened into the generated
`.a`; a child archive is never stored as an opaque archive member. Mixed
object/archive `-X` arguments retain their command-line order in both provider
forms.
Metadata-bearing `-X` input is rejected because logical Titan modules must
enter through source or normal archive resolution.

Common final-link inputs are not copied into every package archive:

* Titan's runtime and backtrace archives;
* the matching Lua archive;
* `-l` libraries; and
* `TITAN_EXTRA_LDFLAGS`.

A final static consumer supplies those once. This is ordinary static-library
behavior, not a hidden dependency manifest.

## The standard library and libuv

The canonical installed ABI directory contains:

```text
$ROCKS_TREE/lib/titan/0.24/titan.so
$ROCKS_TREE/lib/titan/0.24/titan.a
```

Both contain the eighteen `titan.*` logical standard modules, including
`titan.io`, `titan.ssl`, `titan.url`, `titan.http`, and `titan.test`, under
ABI 0.24. The DSO also
contains bare native `require "titan"` support, and the archive carries that
support object without inventing a logical module named `titan`.

The private namespaced LPegLabel archive is another metadata-free provider
payload. Its five objects are carried into both forms for `titan.peg` and
`titan.string`, but the archive and headers are not installed in the SDK and
it does not advertise a Titan logical metadata key.

The private llhttp archive is likewise metadata-free payload; the generated
`titan.http` object owns its eight source-defined foreign callbacks and needs no
adapter. `titan.ssl` uses OpenSSL directly and adds no adapter object. Bundled-OpenSSL
mode carries the pinned OpenSSL objects into both provider forms.
System-OpenSSL mode leaves the pkg-config-selected libraries as final-link
inputs, so a static consumer must repeat that ordered link result just as it
does for system libuv.

In bundled-libuv mode, the pinned libuv archive is native provider payload. Its
objects are carried into both `titan.so` and `titan.a`, so a `--static`
standard-library consumer can run without a Titan or libuv DSO after supplying
the documented platform libraries.

In system-libuv mode, the selected pkg-config/user setting remains a final-link
input and libuv is never copied into `titan.a`. Repeat the same setting when
linking a static Titan consumer:

```sh
TITAN_EXTRA_LDFLAGS="$(pkg-config --libs libuv)" titanc --static app
```

If that setting selects shared libuv, the resulting executable keeps a libuv
DSO dependency. If it deliberately selects a static system library, the
system linker may absorb reachable libuv objects into the final image. “System
mode” does not itself mean dynamic.

## Supported containers

Titan reads regular ELF and Mach-O object archives in-process. On macOS it
also consumes x86_64/arm64 universal archive providers and selects the slice
matching the objects generated by the configured C compiler. A newly
published provider archive is a regular single-architecture archive for that
active target.

Thin archives, nested archives, raw non-object members, LTO/bitcode members,
COFF/Windows libraries, and cross-target multi-output builds are not supported
in this version.
