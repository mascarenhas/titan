# Incremental and separate compilation

Titan can reuse generated objects when a build system has already arranged
the required rebuilds. Object reuse is opt-in; an ordinary `titanc` invocation
continues to load and check selected source modules afresh.

## Options and outputs

| Invocation | Effect |
| --- | --- |
| `titanc project.base project.feature` | Compile selected source modules and publish the usual provider pair and Lua loaders, or an executable when one root has `main`. |
| `titanc --incremental project.base project.feature` | Reuse eligible source objects, including roots, and perform the usual final link. |
| `titanc -c project.feature` | Compile selected source modules to objects and generated headers; produce no provider, Lua loader, or executable. |
| `titanc -c --incremental project.feature` | Rebuild the explicit root and reuse eligible source dependency objects. |

`--compile-only` is the long spelling of `-c`. Every explicit root rebuilds in
this mode, even when encountered first as another root's dependency. Make may
have invoked its recipe because an import, C header, or compiler setting
changed while the root's own source timestamp did not.

Compile-only mode retains source-closure compilation: missing or stale source
dependency objects can also be generated. A complete Make graph builds shared
dependencies before their consumers, so parallel consumer recipes reuse those
objects. `-c` alone does not promise to write only the requested root's files.
Unrelated roots and multiple roots defining `main` can be compiled together
with `-c`; common provider naming and executable selection happen when linking.

Pass `-o out` consistently in the object and final-link invocations to keep
objects and generated headers in the [output tree](output-directory.md).
Incremental lookup and missing-header restoration use that same tree. Without
`--output`, they stay beside each flat source or folder main,
including when `--tree` points elsewhere. A folder module has one object for
the entire module, not one object per contributor.

Use `--source-first` in every phase when source dependencies should take
precedence over installed `.so` or `.a` providers. This option still allows
compiled fallback on an ordinary import's source miss. It does not grant access
to private declarations: only a direct `import "project.base.titan"` requests
the source collaboration view.

`-c` rejects `-l`, `-X`, and `--no-uv-bootstrap` because those options require
linking. `--static` remains a compiled dependency preference. `--incremental`
cannot be combined with `--print-ast`, which requires freshly checked ASTs.
`--test` supports both incremental linking and separate object compilation.

## What object reuse promises

After normal source resolution, `--incremental` looks for the primary companion
object (`<stem>.o`) and any split part objects (`<stem>.part1.o` ..
`<stem>.part(K-1).o` recorded in `<stem>.o`'s `.titan.source` metadata and
`<stem>.parts`), requiring every part object to exist and be no older than every
currently discovered source constituent. Equal timestamps count as current. The
primary object supplies the module's declarations, source-private view, import
and native-link facts, generated header information, and part inventory. Reusing
the complete part set skips parsing, checking, C generation, and C compilation
for that module; if any part is missing or stale, the whole module is rebuilt
from source. `-v` reports reuse and fallback reasons.

Missing or older objects, absent source metadata, failed metadata loading or
execution, and incompatible Titan ABI metadata fall back to source compilation.
Metadata emitted by the compiler is trusted. Explicit roots and direct `.titan`
imports still require actual source files; an orphan object, archive, or DSO
does not substitute for source-private access.

The object metadata reader recognizes ordinary COFF objects for the experimental
Windows port, alongside ELF and Mach-O. This format support alone does not make
Windows compilation available or enable Windows static providers. PE images,
COFF import objects, and BigObj are not reusable source objects.

Reused objects preserve their own native access paths. A module can directly
import a dynamic provider while another module uses that provider's record
methods through a returned value, without importing it. Those objects can be
reused together: the direct importer keeps its provider handle and the indirect
consumer keeps its global symbol lookup. Reuse still rejects incompatible
provider changes and changes between direct native and dynamic binding.

The timestamp check is deliberately limited. **The build system owns every
other invalidation input:** imported modules, C headers, folder membership
changes, compiler changes, flags, SDK/toolchain settings, selected binary
providers, and native payloads. Timestamp eligibility does not compare these
inputs against a previous build; the native-binding compatibility checks do not
replace dependency invalidation. Use the same source-selection and compilation
settings in all phases. A clean rebuild is required after changing settings
unless the build graph already invalidates the affected objects.

Missing generated headers needed by a newly compiled importer can be restored
from a current producer object without rechecking its source. Existing complete
companions are left untouched. Source-foreign headers include eligible inline
function bodies, so consumer rebuild rules must include these headers or the
producer object.

## Optimization and toolchain settings

Titan-generated C defaults to `-O3` on Linux and macOS. On Linux, GCC and Clang
also receive `-flto=auto -ffat-lto-objects` during compilation and linking. These
objects retain native code and readable Titan metadata alongside the compiler's
intermediate representation. The final provider or executable link can inline
and propagate constants across separately compiled source objects and members
of Titan-produced archives. Normal export, private visibility, and provider
identity rules still apply. A dependency used through an existing DSO remains
a dynamic boundary.

The Linux compiler/linker toolchain must support fat LTO objects and the
matching LTO backend. Titan keeps the ordinary native-container contract; it
does not silently fall back to bitcode-only objects or omit requested LTO.

macOS does not enable LTO by default: its objects retain the ordinary Mach-O
representation consumed by Titan's metadata reader. Bitcode-only object files
are not supported module inputs.

Use the same compiler and build configuration for objects and their final link.
Make must invalidate objects when those settings change. Fixture and debugging
builds can explicitly override the defaults:

```sh
TITAN_EXTRA_CFLAGS='-O0 -fno-lto' TITAN_EXTRA_LDFLAGS='-O0 -fno-lto' \
  titanc project.main
```

Extra C flags are appended to compilation commands; extra linker flags are
appended to final links. Set both when disabling the complete optimization
pipeline. They do not themselves invalidate cached objects: rebuild affected
objects with the same override before an incremental final link.

## A Make build

For two flat modules, where `project.feature` imports `project.base`:

```make
.DELETE_ON_ERROR:
TITANC = titanc
TITAN_BUILD_FLAGS = --source-first --incremental
BUILD_INPUTS = Makefile build-config.mk

project/base.o project/base.ffi.h &: project/base.titan $(BUILD_INPUTS)
	$(TITANC) $(TITAN_BUILD_FLAGS) -c project.base

project/feature.o project/feature.ffi.h &: project/feature.titan \
        project/base.o project/base.ffi.h $(BUILD_INPUTS)
	$(TITANC) $(TITAN_BUILD_FLAGS) -c project.feature

project.so project.a project/base.lua project/feature.lua &: \
        project/base.o project/feature.o $(BUILD_INPUTS)
	$(TITANC) $(TITAN_BUILD_FLAGS) project.base project.feature
```

The grouped targets require GNU Make support for `&:`. With another Make,
use one project-owned completion stamp per recipe, make consumers depend on
that stamp, and remove the stamp when cleaning any of its outputs.

`build-config.mk` is maintained by the project when compiler, flags, or SDK
settings change; Titan neither creates nor interprets it. Add actual C headers,
external providers, and native payloads to the appropriate prerequisites.
Modules defining source foreign functions also produce `.titan.h`; list that
output and make source consumers depend on it. Listing the producer object
conservatively rebuilds consumers for implementation changes too.

For folder modules, explicitly list all constituents and make the file
declaring that inventory a prerequisite. A source directory's timestamp is not
a suitable substitute: writing generated files in it would invalidate the
directory again.

The final command still names logical modules. Titan combines their objects
into its ordinary `.so`/`.a` pair and shims, or links its normal executable.
Keep native support payloads and final libraries in the existing `-X`/`-l`
options on this final command. Titan module objects are not `-X` payloads and
are not a new installed library format. See [Static compiled modules](static-compiled-modules.md)
and [Multi-module libraries](multi-module-libraries.md) for provider contracts.

The standard library uses this same model: one object target per logical
module, followed by the existing combined `titan.so`/`titan.a` publication.
After installing with `luarocks make`, `make stdlib` uses that installed compiler
and its SDK to rebuild changed standard modules and their dependents. With no
changes and the same build settings, it reuses the objects and provider pair
left by the installation. `make install-stdlib` builds if necessary and copies
that pair and its shims into the installation. With the prefix's Lua on `PATH`, these Make commands
detect `PREFIX` automatically; an explicit `PREFIX` still takes precedence.

## Separate standalone executables

The same object workflow supports applications. For example, `app.helper` may
import `titan.math`, while `app.main` imports `app.helper.titan` and a separately
built `vendor.algorithms` provider:

```sh
titanc vendor.algorithms
titanc --static -c --incremental app.helper
titanc --static -c --incremental app.main
titanc --static --incremental app.main
./app/main
```

The final invocation detects `main` from the object metadata, reuses both app
objects, and links the selected standard-library and external-library archives.
Use the same `--static`/source-selection policy for every application phase.
When native payloads or system-provider libraries are required, pass `-X` and
`-l` only on the final invocation, with the active provider's normal link
inputs. Compile-only invocations do not emit an executable or entrypoint.

## Separate native test executables

Compile each test owner after its source dependencies, then link the requested
roots from a consistent build directory and source-selection configuration:

```sh
titanc --test -c --incremental project.unit_tests
titanc --test -c --incremental project.integration_tests
titanc --test --incremental project.unit_tests project.integration_tests
```

`-c --test` discovers cases to apply the test-owner compilation flags but emits
no runner or executable. The final invocation discovers cases from both fresh
source and current objects, generates a new runner, and links the usual test
executable. Application `main` functions in test roots remain ignored. Test
additions/removals become visible after Make rebuilds the owning object.

`titan.test` is an ordinary dependency of the thin generated runner. An
installed SDK supplies its compiled implementation; no separate support source
or object is built. Production source objects may be shared with application
builds when flags, ABI, and selected dependency providers match. A test's
explicit `.titan` import does not change the producer's generated code.
Track imports, foreign headers, provider changes, and configuration inputs in
the same Make graph. Compile actual test owners with `--test` so their native
frames retain the required test flags. `--no-uv-bootstrap`, native payloads,
and link libraries belong on the final command. The standard-library test
aggregate uses this object graph and one final executable; it retains the same
runtime filters and test ownership as an ordinary `--test` build.
