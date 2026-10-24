# Compiler output-directory routing

The CLI's `-o/--output` argument is a directory.
`titanc` normalizes it to an absolute path and creates it recursively before
compilation (`titan-compiler/driver.lua` `driver.prepare_output_root`). Source
resolution and output routing are separate: the logical module name and source
form determine the source-root-relative native output stem beneath the
destination. No absolute source prefix or `..` component enters an
output-relative stem.

The [language chapter](../language/output-directory.md) defines paths and
compatibility. The implementation lives in `titanc`, `driver.lua`, and
`coverage.lua`.

## One source identity, separate artifact locations

The selected flat or folder source keeps its original filenames and constituent
list. Those identities drive diagnostics, `#line`, source timestamps, quoted
authored-header resolution, coverage source lines, and source-private import
permissions. Only native output and program output paths move. Folder
contributors still form one generated module owned by the canonical main. Its
part files (`<stem>.part<k>.c`/`.o`), `<stem>.priv.h`, and `<stem>.parts` derive
from the same mapped stem
([split parts](codegen-overview.md#translation-unit-parts)).

The resolver's `output_root` option maps the canonical main's
source-root-relative path to `native_output` and `program_output`
(`driver.relocate_source_output`; other generated files use
`driver.generated_output_path`). The stem is the logical name with dots
replaced by slashes, plus the repeated final component for a folder module.
Incremental object lookup and missing-header restoration consume that mapped
stem, so they never pick up source-adjacent objects from another configuration.
Without an output root the resolver keeps source-adjacent paths. Routing changes
neither serialized interfaces nor the generated-code ABI.

Final providers keep common-prefix naming below the output root, and generated
Lua shims keep their logical module paths there. Unix programs and test runners
use mapped program stems. Windows program linking receives the output root for
its `bin/` launcher and `lib/titan/0.6/` provider layout
(`driver.windows_program_paths`). Output routing never changes the source or
binary search paths.

## Headers, temporary files, and coverage

Generated FFI and foreign-function headers follow `native_output`. Checking FFI
bundles and compiler-owned temporary files (diagnostics, child notifications,
native validation) are created under the output root: the resolver context wraps
`io:tmpname` into `<output_root>/.titan-temporary-*`, and `driver.OUTPUT_ROOT`
places the compile-log temporaries. Both keep their normal cleanup. Provider and
archive publication stages sit beside their mapped final paths. The C probe
cache keeps its own storage root.

Coverage applies its `.coverage` transform after ordinary output mapping
(`titan-compiler/coverage.lua` `coverage.output_path`). This keeps the same
source-relative hierarchy while separating coverage objects from ordinary
incremental objects. Unless `--coverage-output` overrides it, the report goes
to `<output-root>/.coverage/report` (`coverage.prepare`). Source and counter
inventories keep absolute paths.

The repository Makefiles pass one output root through separate object recipes
and final links; see [Build and installation
responsibilities](build-script-audit.md) for the object graph. Native test and
coverage configurations use separate subtrees below `out/`. The Windows scripts
keep their private source, SDK, fixture, and launcher trees inside the selected
build root; see [Experimental Windows build](windows-build.md).

## Validation boundaries

`spec/driver_spec.lua` covers mapping and directory preparation. CLI
integration specs (`spec/coder/incremental_compilation_spec.lua`,
`spec/coder/test_runner_spec.lua`, `spec/coder/standalone_paths_spec.lua`)
compile and run external source trees, libraries, folder modules, and test
runners with output paths that contain spaces. Incremental cases verify reuse
and header restoration in the selected tree, and coverage cases verify the
relocated `.coverage` artifacts and default report directory. Packaging specs
check that publication and invalidation consume the output stage. The native
Linux, macOS, and Windows gates exercise real toolchain paths.
