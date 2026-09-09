# One compilation per enum-carrier selection

Approved implementation plan, 2026-09-08. Tracked by Titan issue #155 on
`codex/single-ffi-and-enum-probes`, alongside
`combined-ffi-environment-design.md`. This replaces the profiling proposal with
the implementation contract below. It does not claim unperformed validation.

## Selection contract

Replace the per-carrier acceptance loop with one compile-only query that returns
a typed answer. Preserve the checker's ordered eleven primitive integer carrier
spellings, assigning stable IDs 1 through 11 independently of eligibility-list
positions. Enum values consider carriers whose complete range fits
`lua_Integer`; enumerator expressions consider all available carriers and retain
their separate exact value-range check when the selected carrier is wider.
Preserve outer typedefs, exact tag/expression spelling, qualifiers, and existing
unsupported anonymous/prototype enum diagnostics. Selection updates the same
spelling, signedness, rank, width and numeric metadata as before.

Render the exact enum object declaration once. Compare
`__typeof__(&titan_probe_d)` with each eligible `carrier *` using
`__builtin_types_compatible_p`, a GCC/Clang C99 extension. Pointer comparison
retains pointee qualifiers and avoids enum integer promotions. Each match is an
integer constant expression. Emit the match count and sum of matching stable
IDs as bytes in a small fixed-format `unsigned char` array marked `used` and
aligned to one byte. The source embeds magic, protocol version, exact length,
and the complete ordered eligible ID/type list. A valid no-match or multiple-
match result is a deterministic selection answer, distinct from extraction
failure. A selected ID must belong to the supplied eligible list.

## Object extraction and lifecycle

Compile with `-c` even when an ordinary probe service is configured for syntax
checking only. The query must produce its own object; do not link, load, or run
target code, and do not launch `nm`, `objcopy`, or another extractor. Use a
dedicated ELF `.titan.cprobe` section or Mach-O `__DATA,__titancprobe` section.
Reuse the bounded native object parser in `staticmetadata.lua` through a narrow
raw-section accessor. Require exactly one ordinary initialized, uncompressed,
relocation-free result section with the precise payload length. Cover ELF and
Mach-O, 32/64-bit and both byte orders using existing synthetic object fixtures.
Reject unsupported containers, malformed section tables, duplicates, missing
sections, relocations, and invalid payload bytes.

Read the object with a 16 MiB bound through the compiler I/O strategy after successful
compilation and before per-probe cleanup. Normalize extraction failures as
infrastructure failures and preserve cleanup on every outcome. Artifact cleanup
failure also prevents publication. Compiler execution is still owned by the
existing runner; this change introduces no process or cancellation mechanism.

## Result and cache contract

The cache key remains SHA256 of the complete raw, unpreprocessed query source.
It includes the ordered header environment, exact enum surface, complete
eligibility question, stable IDs, and result protocol version. It does not add
compiler flags, target metadata, authored header contents, or semantic
descriptors to the key. Generated header transport follows the companion plan's source-visible
bundle contract. Helper identifiers are fixed by role.

Extend the versioned bounded result codec with a tagged enum-selection payload.
Preserve that payload through service, shared-analysis, and persistent results;
successful compiler exit alone cannot satisfy a selection query. Old/malformed
records are misses. Keep source-only manual invalidation and the persistent
disable switch. Cache deterministic compiler rejection and valid selected,
none, or multiple answers; never cache missing/malformed/out-of-range output,
read/stat failures, launch/wait/interruption failures, or cleanup failures.
Concurrent yielding requests retain the first completed validated result for a
source. The language-server API version remains 1; the FFI conversion-snapshot
kind is independent of the C-probe result codec.

## Historical motivation

The retained native capture recorded 1,420 candidate requests representing 138
logical selections. Complete eligible-list grouping yielded 47 questions across
501 physical source keys, each with one accepted `int` or `unsigned int`
carrier. Equivalent deterministic reuse would reduce this family by 454
compilations (90.62%). Its historical 56.171 seconds is not an estimate of the
new implementation's time, and the companion header redesign changes contexts.
Baseline checks and other semantic probe families remain outside this count.

## Tasks and validation

- [x] Add bounded ELF/Mach-O raw-section extraction and malformed-object tests.
- [x] Add one-source enum query rendering, stable IDs, payload decoding, and
  object extraction before cleanup.
- [x] Extend typed cache encoding, decoding, all reuse tiers, and malformed/
  infrastructure retry tests while preserving source-only identity.
- [x] Replace only the enum-selection loop in `checker/c_types.lua`; keep
  eligibility and enumerator range checks intact.
- [x] Test selected/none/multiple results, filtered eligibility, exact typedef
  and qualifier spelling, invalid output, syntax-only override, cleanup, and
  GCC/Clang compile-only execution with one candidate invocation per question.
- [x] Run root cprobe/cache/staticmetadata Busted suites.
- [x] Run existing checker/coder enum cases after the shared syntax migration
  is ready.
- [x] Update user and implementation documentation with the combined feature.
- [x] Independent review, full Titan `make test`, downstream `make verify`, and
  measured post-change probe evidence are coordinated by the root agent.
- [ ] Root opens both PRs after local verification; require green final-head
  Linux CI before the authorized manual macOS workflow. Leave PRs open.

Probe agent owns this plan, cprobe result/query code, result codec, native
section accessor, related root Busted tests, and the narrow checker enum block.
Root owns generated-header transport and other checker sections. Coordinate
shared-method changes before editing; no independent commits or pushes.

## Implementation evidence

The complete focused gate passed 104 tests with zero failures/errors after the
wide-carrier matrix was added:

```sh
CC=/usr/bin/cc CCACHE_DISABLE=1 \
  TITAN_ROCKS_ROOT=/var/home/mascarenhas/Code/vscode-titan/.titan \
  TITAN_PROBE_CACHE_DISABLE=1 /tmp/titan-single-ffi-prefix/bin/busted \
  --run=checkout spec/cprobe_spec.lua spec/cprobe_cache_spec.lua \
  spec/staticmetadata_spec.lua
```

The real-compiler matrix ran GCC and the available Clang with
`-Wall -Wextra -Werror`, with and without `-fshort-enums`. It checks exact
typedef and enumerator spellings, pointee qualifiers, stable filtered IDs,
and wide unsigned carriers. Synthetic service cases cover every
cache tier, invalid typed records, missing/malformed objects, bounded I/O,
cleanup, compiler rejection and infrastructure retries. The generic object
accessor covers ELF/Mach-O in 32/64-bit and both byte orders. Broader compiler,
server, CI and macOS validation remain unchecked above until performed.

The final unfiltered compiler gate passed all 3,331 compiler/language cases and
455 native standard-library tests, plus 131 runtime/packaging cases. The server's
complete downstream verification also passed with the current compiler SDK.
The final cold native capture reached READY in 309.319 seconds with all 63
modules committed in one non-stale analysis. It issued 47 physical whole-enum
queries for 47 questions (the retained baseline used 501 compiler invocations),
plus 91 service hits across 138 typed enum requests. The full workload issued
346 physical queries, with zero ordinary declaration-reconciliation queries.
The companion combined-environment plan records the method, preservation checks
and comparison limits. Remote delivery evidence remains coordinated by root.
