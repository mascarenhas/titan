# Compiler output-directory routing

The CLI's `-o/--output` argument is a directory. It is normalized to an absolute
path and created recursively before compilation. The source resolver and output
routing remain separate: the logical module path and source form determine
the source-root-relative native output stem beneath the destination. No
absolute source prefix or `..` component is carried into an
output-relative stem.

The [language chapter](../language/output-directory.md) defines paths and
compatibility. The implementation touches `titanc`, `driver.lua`, and
`coverage.lua`.

## One source identity, separate artifact locations

The selected flat or folder source retains its original filenames and
constituent list. Those identities continue to drive diagnostics, `#line`,
source timestamps, quoted authored-header resolution, coverage source lines,
and source-private import permissions. Only native output and program output
paths change. Folder contributors still form one translation unit owned by
the canonical main.

The resolver's output-root option maps the canonical main's source-root-relative
path to `native_output`. Incremental object lookup and missing-header restoration
consume that mapped stem, so they cannot silently use source-adjacent objects
from another configuration. Without an output root the existing resolver paths
remain unchanged. This routing changes neither serialized interface contracts
nor the generated-code ABI.

Final providers retain common-prefix naming below the output root. Generated
Lua shims preserve their logical module paths there. Unix programs and test
runners use mapped program stems. Windows program linking receives the output
root for its existing `bin/` launcher and `lib/titan/0.6/` provider layout.
Output routing does not mutate the source or binary search paths.

## Headers, temporary files, and coverage

Generated FFI and foreign-function headers follow `native_output`. Checking FFI
bundles and compiler-owned temporary diagnostic, child-notification, and native
validation files use the output root as well and retain their normal cleanup.
Provider and archive publication stages stay beside their mapped final paths.
Probe service storage retains its existing cache ownership.

Coverage applies its `.coverage` path transformation after ordinary output
mapping. This preserves the same source-relative hierarchy while keeping
coverage and ordinary incremental objects separate. Unless explicitly
overridden, report output is `<output-root>/.coverage/report`. Source and
counter inventories retain their ordinary absolute-path contract.

The repository Makefiles pass one output root consistently through separate
object recipes and final links. Publication reads the completed provider pair
and shims from that stage. Native test and coverage configurations use separate
subtrees below `out/`. Windows native scripts retain their private source,
SDK, fixture, and launcher ownership boundaries inside their selected build
root. Authored runtime C objects and native dependency archives remain governed
by their existing build targets.

## Validation boundaries

Driver tests cover mapping and directory preparation; CLI integration tests
compile and execute external source trees, libraries, folder modules, and test
runners with output paths containing spaces. Incremental cases verify reuse and
header restoration in the selected tree. Coverage cases verify the relocated
`.coverage` artifacts and default report directory. Build and packaging tests
check that publication, invalidation, and snapshots consume the new stage.
Native Linux, macOS, and Windows gates exercise actual toolchain paths.
