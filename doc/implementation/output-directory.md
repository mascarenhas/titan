# Compiler output-directory routing

The CLI's `-o/--output` argument is a directory.
`titanc` normalizes it to an absolute path and creates it recursively before
compilation (`titan-compiler/driver.lua` `driver.prepare_output_root`). Source
resolution and output routing are separate: the logical module name and source
form determine the source-root-relative native output stem beneath the
destination. No absolute source prefix or `..` component enters an
output-relative stem.

The [language chapter](../language/output-directory.md) defines paths and
compatibility. The implementation lives in `titanc`, `driver.lua`, `build.lua`,
`incremental.lua`, `nativeinputs.lua`, `linkcertificate.lua`, and
`coverage.lua`.

## One source identity, separate artifact locations

The selected flat or folder source keeps its original filenames and constituent
list. Those identities drive diagnostics, `#line`, source content digests and
folder-membership certificates, quoted authored-header resolution, coverage
source lines, and source-private import permissions. Only native output and
program output paths move. Folder contributors still form one generated module
owned by the canonical main. Its part files (`<stem>.part<k>.c`/`.o`) and
`<stem>.priv.h` derive from the same mapped stem ([split
parts](codegen-overview.md#translation-unit-parts)) and are recorded in the
primary `<stem>.o`'s `.titan.source` metadata.

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
Lua shims keep their logical module paths there. Without `--exe`, Unix programs
and test runners use mapped `program_output` stems below the output root, and
Windows programs use `<output>/bin/<logical>.exe` and
`<output>/lib/titan/0.6/<logical/module>.dll` (`driver.windows_program_paths`).
With `--exe PATH`, `PATH` is resolved relative to the invocation working
directory rather than `--output`: on Unix the executable (and Darwin `.dSYM`
bundle) is written at `PATH`, while on Windows the launcher (`.exe` appended if
absent) is written at `PATH`, the companion provider DLL stays at
`<output>/lib/titan/0.6/<logical/module>.dll`, and the launcher embeds the
relative path from `<exe-dir>/../lib/titan/0.6` to that provider DLL (requiring
both paths to share a volume). Output routing never changes the source or
binary search paths.

## Headers, temporary files, and coverage

Generated FFI and foreign-function headers follow `native_output`. Checking FFI
bundles and compiler-owned temporary files (diagnostics, child notifications,
native validation) are created under the output root: the resolver context wraps
`io:tmpname` into `<output_root>/.titan-temporary-*`, and `driver.OUTPUT_ROOT`
places the compile-log temporaries. Both keep their normal cleanup. Before
dispatching a worker for a module miss, the coordinator unlinks the old primary
`<stem>.o` and its recorded part objects (`driver.invalidate_source_object`);
the worker compiles object parts into unique sibling temporaries and the
coordinator renames non-primary parts before renaming `<stem>.o` last. Provider
and archive publication stages sit beside their mapped final paths. The C probe
cache keeps its own storage root.

`titanc` locks `--output`, or without `--output` every `--tree` source root
plus the working directory, and adds `dirname(--exe)` when `--exe` is used.
Under the primary output domain (`--output`, or the first `--tree` source root
when `--output` is omitted), `titanc` also owns:

- `<domain>/.titan-build.lock` (`build.lock_outputs`): the permanent OS lock
  file (`O_NOFOLLOW | O_CLOEXEC` + `flock` on POSIX; `CreateFileW` with
  `FILE_FLAG_OPEN_REPARSE_POINT` and no `FILE_SHARE_DELETE` + `LockFileEx` on
  Windows) held from certification through publication; every other lock
  domain has its own;
- `<domain>/.titan/preamble.c` (`incremental.preamble_identity`): the stable
  synthetic translation unit used to probe and certify the generated C preamble
  and transitive SDK/system headers;
- `<domain>/.titan/digests` (`incremental.load_digest_cache`, only with
  `--output`): the persistent observation-keyed digest cache
  ([Persistent digest cache](incremental-compilation.md#persistent-digest-cache));
- `<domain>/.titan/linker-feature` (`linkcertificate.linker_backend`): the
  persisted GNU ld/LLD dependency-report probe result;
- `<domain>/.native/<sha256(canonical-source-path)>.{o,record}`
  (`nativeinputs.compile`): the compiled object and sidecar certificate
  (`TITAN_NATIVE_RECORD_SCHEMA`) for each `--c-source` input, with
  preprocessed output and dependency files as invocation scratch; and
- `<domain>/.titan-links/<sha256(canonical-final-output-set)>/`
  (`linkcertificate.prepare`): the target's final-link certificate (`record`,
  `TITAN_LINK_RECORD_SCHEMA`), linker dependency output (`link.d`), and
  `synthetic/` directory (`<leaf>__test_runner.{titan,c,o}` and
  `<leaf>__[test_]entrypoint.{c,o}`, plus Windows `.manifest`/`.rc`/`.res` and
  `__coverage_dump.{c,o}` companions), isolating synthetic sources when several
  executables in one output tree share a first root.

Before any worker starts, the coordinator reserves every generated path a
planned module may write, including split parts up to the configured
`--c-parts` maximum, and rejects aliases with inputs or other outputs
([Pre-dispatch output preflight](build-coordinator.md#pre-dispatch-output-preflight)).

Coverage applies its `.coverage` transform after ordinary output mapping
(`titan-compiler/coverage.lua` `coverage.output_path`). This keeps the same
source-relative hierarchy while separating coverage objects from ordinary
incremental objects. Unless `--coverage-output` overrides it, the report goes
to `<output-root>/.coverage/report` (`coverage.prepare`). Source and counter
inventories keep absolute paths.

The repository Makefiles invoke one `titanc --incremental --output ...` command
per target (`out` for `stdlib`/`stdlib-objects`, `out/tests` for
`titan-stdlib-test-build`/`-objects`, `out/tests/native/<helper>.o` for
child-only C fixture preparation, and `out/coverage` for
`titan-native-coverage-build`); see [Build and installation
responsibilities](build-script-audit.md). The Windows scripts keep their
private source, SDK, fixture, native-helper, coverage, and launcher trees
inside the selected build root; see [Experimental Windows
build](windows-build.md).

## Validation boundaries

`spec/driver_spec.lua` covers mapping and directory preparation. CLI
integration specs (`spec/coder/incremental_compilation_spec.lua`,
`spec/coder/build_coordination_spec.lua`, `spec/coder/link_certification_spec.lua`,
`spec/coder/native_inputs_spec.lua`, `spec/coder/test_runner_spec.lua`,
`spec/coder/standalone_paths_spec.lua`) compile and run external source trees,
libraries, folder modules, and test runners with output paths that contain
spaces. Incremental cases verify reuse
and header restoration in the selected tree, and coverage cases verify the
relocated `.coverage` artifacts and default report directory. Packaging specs
check that publication and invalidation consume the output stage. The native
Linux, macOS, and Windows gates exercise real toolchain paths.
