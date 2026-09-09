# One C environment per Titan module

Approved implementation plan, 2026-09-08. Branch: `codex/single-ffi-and-enum-probes`, based on Titan `788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d`. This updates the design reviewed in vscode-titan PR #59 with the maintainer's two-header revision. Implementation and validation are tracked below; the captured profiling evidence is historical, not a new measurement.

Unbound foreign imports feed one C declaration environment per logical Titan module, accessed through reserved `ffi`. Explicit direct source imports (`import "A.titan"`, with source provenance verified by the loader) inherit that environment through ordinary C includes. Each module produces `A.ffi.h` before checking Titan signatures; a module defining foreign functions additionally produces `A.titan.h` after checking those declarations. C implicit conversions and later native-compiler diagnostics for incompatible C declarations are accepted FFI responsibilities. We remove the old bound foreign-import syntax instead of preserving an alias compatibility layer.

Using the existing quoted header operand, the intended shape is:

```text
foreign import "openssl/err.h"
foreign import "openssl/ssl.h"

-- C values and types use ffi.NAME throughout this Titan module.
```

## Why the large probe family disappears

At the recorded baseline, each foreign import called `cdriver.process_file`, which creates a fresh preprocessor context, parses a flattened header closure, and converts it into a separate `CModule`. The checker then compares ordinary names across those independently extracted graphs and queues declaration-pair probes. See [declarations.lua:604](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/declarations.lua#L604), [cdriver.lua:765](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/c-parser/cdriver.lua#L765), and [declarations.lua:770](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/declarations.lua#L770).

With one ordered input, include guards, macro changes, typedefs and file/prototype tag scopes are interpreted in one preprocessor/parser lifetime. A guarded declaration reached through several headers appears according to that actual combined stream, rather than once per independent extraction. Convert that result once into `ffi`; the cross-import comparison queue and its artificial redeclaration-pair probes no longer have a role. Actual conflicting C declarations remain subject to C parsing/generated-C compilation under the user's relaxed early-diagnostic contract. This does not require probe batching or a cache identity redesign.

## Implementation boundaries

| Area | Required change and evidence anchor |
| --- | --- |
| Parser and AST | Replace the bound `local NAME = foreign import STRING` grammar and the required `localname` field with an unbound header directive carrying its source location. [parser.lua:1141](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/parser.lua#L1141), [parser.lua:1685](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/parser.lua#L1685), [ast.lua:34](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/ast.lua#L34). |
| Collection/checker order | Collect directives before C conversion and ordinary Titan type/body checking. This fits the existing import-first phase, which already completes FFI before aliases, signatures and initializers. [declarations.lua:1667](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/declarations.lua#L1667). |
| Reserved `ffi` | Install one compiler-owned namespace declaration, reserve it against ordinary import binding, and give attempted rebinding a direct diagnostic. Reserve the unshadowable namespace root `ffi`; unrelated member names such as `record.ffi` remain ordinary names. The parser retains `Ast.TopLevelForeignImport` with `loc` and `headername`, removes `localname`, and preserves the quoted header source range. The checker creates a separate implicit declaration for `ffi`; directives are not declarations of that namespace. Do not manufacture one ordinary import alias per header. Current top-level name reservation and generic symbol insertion need explicit handling. [declarations.lua:573](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/declarations.lua#L573), [symtab.lua:57](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/symtab.lua#L57). |
| Combined C driver | Add an ordered-source/ordered-header entry point that shares one configured CPP context, one flattened parse, and one registration result. Retain include search, dependency observations, macro state and source provenance for every constituent header. Reuse the existing parse/register stages instead of concatenating already converted per-header tables. [cdriver.lua:983](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/c-parser/cdriver.lua#L983), [cdriver.lua:1026](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/c-parser/cdriver.lua#L1026), [cdriver.lua:1088](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/c-parser/cdriver.lua#L1088). |
| C values/types | Reuse `CModule.members` and `type_members`: functions, objects and supported macros are value members; typedefs and current tag projections remain type members. Preserve the existing type/value collision rules and C allocation/type pseudo-members. `CModule` can now be named `ffi`, while individual declarations retain their real header origins. [variables.lua:142](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/variables.lua#L142), [type_syntax.lua:226](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/type_syntax.lua#L226), [declarations.lua:812](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/declarations.lua#L812). |
| Code generation | Use the same ordered include description as the combined parser. Direct calls already lower a C-module member to its C identifier; changing the namespace root need not add wrappers or runtime lookup. [calls.lua:646](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/coder/calls.lua#L646), [names.lua:314](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/coder/names.lua#L314). |

## Order, folder modules and visibility

Use the driver's existing logical module order: folder main file first, then bytewise-sorted contributor filenames, preserving directive order within each file. All contributors share one `ffi` environment. The driver already builds one AST in that order. Relative header resolution must retain the module/source-directory rules rather than depend on an incidental generated-file location. See [driver.lua:1685](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/driver.lua#L1685), [driver.lua:1729](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/driver.lua#L1729), and [driver.lua:4000](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/driver.lua#L4000).

Make the new `ffi` namespace module-wide, including module initializers, while keeping the existing sequential restrictions on ordinary Titan imports/variables. This is an explicit simplification from per-alias import visibility. The combined input and emitted C must agree on duplicate directives: codegen currently deduplicates direct includes by rendered spelling and appends source-foreign companion headers afterward. Define that normalization once and share it. Preserve configured forced-header behavior, define dependency-header placement in the shared emission plan, and decide which compiler-private support declarations are exposed through `ffi`. See [generate.lua:158](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/coder/generate.lua#L158), [generate.lua:894](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/coder/generate.lua#L894), and [declarations.lua:1556](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/declarations.lua#L1556).

## Two generated headers and direct source imports

`A.ffi.h` is the complete C declaration environment for A. It contains, in order:

1. The `.ffi.h` of each explicit direct source import, in parsed Titan import order.
2. A's own foreign-import headers, in parsed order (folder main first, then bytewise-sorted contributors).

Preserve each directive rather than silently suppressing repeated includes by spelling: C guards and macro state determine the result. Give each generated module header a deterministic guard. Diamond source-import graphs are handled by those guards. Retain the existing Titan source-cycle policy. Quoted headers retain their source-relative normalized origin, independent of where the temporary checking file lives. Configured forced includes retain the same ordering and search policy as normal generated C.

The checker collects source imports and normalized foreign directives, asks the resolver to render the header, and parses that one header through one configured CPP/C parser lifetime before aliases, signatures, initializers or bodies. A source dependency contributes its `.ffi.h` even if it has no source foreign functions. The implicit `ffi` sees this final module environment everywhere, including earlier initializers. Ordinary Titan imports, locals and private access retain their existing sequential and direct-import restrictions.

`A.titan.h` contains the checked source-foreign function declarations and static-inline bodies. It includes A's `.ffi.h` and any required explicit source dependency `.titan.h` files before those declarations/bodies. A `.ffi.h` never includes a `.titan.h`: this keeps generated Titan function names out of the parsed C namespace and breaks the checker/signature dependency cycle.

Generated `A.c` explicitly includes its own `.ffi.h` before any generated `.titan.h`. The existing runtime preamble stays intact. Establishing the consumer's complete header order before including dependency `.titan.h` avoids giving a producer's inline header first control of conditional C declarations/macros. Non-inline definitions remain in the producer C file; inline exports remain in `.titan.h`. Preserve hidden visibility, module initialization, callable adapters, slot layouts, and source-provider identity checks.

### Shared compiler boundary

The driver supplies `prepare_ffi_header(ast)` through checker options. After source imports have loaded and foreign header spellings have been resolved without separate parsing, the checker calls it once. It records `ast._ffi_header` with `{ modname, logical_name, filename, bundle_root, identity, contents, dependencies, digest }`. The resolver owns one temporary directory containing real `<logical/module>.ffi.h` files, with generated dependency includes relative to each file and authored includes kept normalized absolute/angle. `identity` is the stable native-output-derived `.ffi.h` origin; the SHA-256 `digest` covers the logical name, origin, deterministic content, and ordered dependency logical names/digests. Neither contains temporary pathnames. `dependencies` retains ordered direct descriptors, including repeated directives. Import metadata exposes the descriptor as `ffi_header_descriptor`, final identity as `ffi_header`, and physical path as `checking_ffi_header`; AST source-import nodes retain these separately from the existing `.titan.h` metadata. Only explicit source-proven imports receive these inherited environments.

Native probes place their C source at the root of a real generated bundle and include its stable logical header name relatively, with a deterministic bundle-digest comment in the raw source. No extra include-search directory is introduced. The probe source still solely determines its persistent key. No forwarding header, symlink, path substitution, or flattening of generated/authored includes is required. The C-driver caches the stable descriptor graph and retains real C-header/search observations, excluding resolver-owned generated files from durable filesystem observations. Checking and native compilation keep the real include nesting and therefore preprocessor behavior such as `__INCLUDE_LEVEL__`.

The coder exposes `generate_ffi_header`; final planning resolves every source native output before rendering headers and records `ast._ffi_header_output` separately from `_foreign_header_output`. Both companion paths participate in collision preflight, staging, ownership checks, optional formatting, cleanup, and publication. Analysis-only/LSP checks create resolver-owned temporary files and never publish generated files into user source trees. Register ownership before writes and clean both headers on normal close, failure, or cancellation. Cached checked ASTs recreate both headers dependency-first; durable snapshots discard temporary paths.

Direct checker callers without a resolver use the same ordered include renderer and strategy-owned temporary header files. They do not need to manufacture a fake source module or filesystem alias.

### Removed reconciliation and origin reconstruction

Replace the existing per-directive `cdriver.process_file` calls with one module-input entry point that reuses preprocessing, registration and conversion. Remove the cross-import declaration-pair compatibility queue and its probes. Remove the independent `apply_source_foreign_headers` macro replay; the real header chain supplies the macro state and dependencies.

Generated C includes A's `.ffi.h` rather than reconstructing direct-source origin headers from rendered C types. Remove that collection role of `coder._ffi_include_collector`, `_record_c_type_use`, and the foreign-function AST/type scan for supplemental source headers; retain C declarator rendering itself. Binary-import interfaces retain their existing C-type/origin handling when necessary, because an ordinary binary import does not gain an explicit source environment. Keep provenance that diagnostics, producer-owned type identity and invalidation actually need.

Cache the one converted module environment, not separate import graphs or a pending redeclaration queue. Change converted-FFI/header graph schemas as needed so older records are misses. Keys and manifests include ordered module-header content, explicit dependency header closure, configured parsing context and real dependency/search observations. Temporary checking filenames are never durable identities. The raw compiled-probe cache still hashes only the complete source and uses explicit manual clearing for stale compiler/header state.

Parsed C graphs and generated-header descriptor bundles are immutable compiler
data and are shared directly on reuse. Mutable Titan type conversion and checker
annotations belong to each module's symbol table. Validate cache compatibility
when loading its envelope; successful graph decoding plus the current ABI/schema
is sufficient, without recursive structure checks. Serialize project snapshots
directly, filtering transient paths during the existing graph walk. Generated
include paths may contain `..`; canonical lexical classification must keep every
owned generated file out of the real-header dependency closure. Actual saved
source, authored header and include-search changes still invalidate analyses.

## What remains

One combined parse does not eliminate target-dependent questions at actual C uses: operator legality, unsafe pointer conversions, enum/carrier/range support and flexible-array extent checks remain separate. Operator and conversion probes can keep their existing individual source-keyed form. A second proposal replaces the enum-carrier candidate series with one result-bearing compilation and caches its selected carrier; see [the companion enum-selection plan](enum-selection-design.md). Both keep complete raw source as the cache identity. A single module-wide baseline can remain for header diagnostics in analysis-only tooling; changing that policy is separate from removing per-name redeclaration probes. Relevant entry points are [cprobe.lua:1926](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/cprobe.lua#L1926), [c_types.lua:272](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/c_types.lua#L272), and [c_types.lua:1458](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/checker/c_types.lua#L1458).

`ffi` belongs to a Titan module, not the whole project. Producer-owned C types exposed through Titan source/binary interfaces still need their existing qualifiers, callback signatures, aggregate identity and origin/include metadata. The current type relation already recognizes certain named file-scope tags across producer descriptors when generated C combines their headers; do not accidentally replace that with per-module pointer identity, or broaden prototype-local/anonymous identities by spelling. See [types.lua:1764](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/types.lua#L1764). These use-site identity rules do not require restoring the old per-header redeclaration queue.

## Migration scope

Migrate bound foreign imports and their alias-qualified uses together across the standard library, compiler/runtime fixtures, examples, the language server and downstream modules. Update parser/checker/codegen tests for the new syntax, reserved `ffi`, final macro state, folder order, supported type/value projections and cross-Titan-module C values. Legacy cross-alias early-conflict expectations should be replaced according to the accepted C-compiler diagnostic contract, not preserved as a prerequisite.

Replace the converted-FFI per-import node types, includes and pending queue with a module-environment representation and invalidate the old schema. Header graph entries must describe the ordered input and its complete dependency closure. This is distinct from the unchanged compiled probe source-key contract. See [foreigncache.lua:8](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/foreigncache.lua#L8) and [foreigncache.lua:77](https://github.com/mascarenhas/titan/blob/788b353bed8e2580bbf12bf8ebf4ad9e7f1ab47d/titan-compiler/foreigncache.lua#L77).

The language-server bridge currently requires `TopLevelForeignImport.localname` when extracting declarations; migrate it with the compiler AST and give the built-in namespace appropriate semantic metadata. Syntax highlighting, fixtures and saved-file hover/reference behavior also need review; completion and unsaved-buffer semantics do not follow from this proposal. [compiler_bridge.titan:2354](https://github.com/mascarenhas/vscode-titan/blob/e0bff3b6f46725880b5c8a9b7633eff82643c8a4/src/server/compiler_bridge.titan#L2354), [compiler_bridge.titan:2456](https://github.com/mascarenhas/vscode-titan/blob/e0bff3b6f46725880b5c8a9b7633eff82643c8a4/src/server/compiler_bridge.titan#L2456). Keep the prerelease language-server API version at 1 while updating both sides together.

## Acceptance and delivery checklist

- [x] Parser/AST: unbound directives, reserved ffi, exact source ranges, old syntax rejected; member names named ffi remain valid.
- [x] Checker/C driver: one ordered parse/conversion, module-wide ffi value/type projections, inherited explicit-source headers, macros/guards and folder order; remove cross-import reconciliation probes.
- [x] Header lifecycle: pre-check `.ffi.h`, checked `.titan.h`, consumer ordering, output collisions/cleanup and temporary-header cache replay.
- [x] C contracts: existing target operations, enum/range checks, callable adapters, anonymous/prototype identity, private visibility and binary boundaries remain intentional.
- [x] Persistence: complete real header/search closure invalidation, body-only reuse, malformed records are misses, no stale checking paths.
- [x] Migrate standard library, fixtures/examples, language and implementation manuals, repository guidance and affected inventories.
- [x] Integrate the companion enum-selection result service and check its GCC/Clang/cache contracts.
- [x] Adapt vscode-titan on its independent branch from `origin/main`; keep API 1 and saved-file scope.
- [x] Focused regression suites, independent code review, full local `make test`, and downstream `make verify` pass.
- [x] Measure an isolated cold native workload and compare physical probe families with the retained baseline; report actual measured results.
- [ ] Commit exact paths, push branches, open both PRs only after their local gates (server wrapped before Titan PR); leave both open.
- [ ] Green Linux CI and coverage on the final Titan head, then manually dispatch macOS CI on that head and resolve failures. Update both Projects to In review.

Implementation ownership: root handles syntax, checker/C driver/persistence integration, migrations and delivery; header agent owns driver/coder header lifecycle and related regression tests; probe agent owns typed enum extraction/cache and focused tests; server agent owns the separate vscode-titan adaptation. Any seam change is coordinated before overlapping edits.

## Integration progress

Both implementation branches and owning issues (#154/#155 and vscode-titan #60)
are active. The first private compiler installation built all 21 standard-library
providers. Tracked Titan source migration covered 168 parsed files with no AST
differences beyond the intended import/namespace normalization. Embedded compiler
and test-runner templates are migrated as well.

Final local validation passed after the cache sharing and invalidation fixes:
`make -j4 test PREFIX=/tmp/titan-single-ffi-prefix` rebuilt and installed the
compiler/provider, then passed 131 runtime/packaging cases, 3,331 compiler/language
cases in four private workers, and all 455 native standard-library tests. The
full log is `/tmp/titan-single-ffi-full-test-final-trusted.log`.

The independently based server passed its full `make verify` against a freshly
installed private SDK: 307 native tests, 57 JavaScript tests, 12 Extension Host
tests, protocol/cache-restart/Codex smokes, VSIX inspection, linkage, SDK-free
startup, and staged installation. All 62 compiler/C-parser Lua files matched the
current compiler checkout after verification.

Independent review covered immutable parsed graphs, state-local checker types,
graph aliases and weak-table/CPP sidecar preservation, cancellation, generated
header ownership, and real-header invalidation. A cross-header string/dereference
macro regression reproduced the remaining shared-token mutation and passed after
pointee spelling became a fresh small array. Generated nested `..` paths are
excluded from persisted inputs; authored-header changes still invalidate them.

The first cold capture was interrupted before READY. It exposed 13 discarded
analyses caused by 70 generated paths leaking into the 25 owners' real-header
closures. That partial run is diagnostic evidence, not a startup comparison.
The final isolated native capture passed after both complete local gates:

| Measure | Retained PR #59 baseline | Final implementation |
| --- | ---: | ---: |
| Launch to READY | 1,775.164 s | 309.319 s |
| Indexing to READY | 1,775.141 s | 309.299 s |
| Physical C compiler queries | 9,496 | 346 |
| Ordinary declaration reconciliation queries | 8,729 | 0 |
| Enum-selection compiler queries | 501 | 47 |
| Whole enum questions represented | 47 | 47 |

The final 346 queries comprise 60 header baselines, 214 operators, 47 enum
selections, and 25 pointer queries. All 346 saved raw sources matched their
SHA-256 keys. There were 138 typed enum requests, with 91 service-cache hits.
All 63 project modules committed in exactly one analysis over 135 saved source
files: zero stale/failed analyses, zero remaining dirty modules and zero
diagnostics. Hover, definition, references and folding passed after READY.
Parsed-header retention/hit cloning emitted no events. Shutdown and preservation
of source/configuration, prior cache bytes/modes/mtimes, server and SDK Lua passed.

The capture used the existing native harness from
[vscode-titan PR #59](https://github.com/mascarenhas/vscode-titan/pull/59), a
fresh isolated probe prefix and project cache, and an instrumented copy of the
verified compiler. Local evidence is under
`/tmp/titan-single-ffi-validation/cold-native-final/run/`; `analysis.json`,
`analysis.md`, `summary.json`, and the sibling support preservation manifest
retain the measured values and checks. The observed reductions are 96.36% in
physical queries and 82.58% in launch-to-READY wall time. This is one end-to-end
comparison with migrated sources and compiler semantics; observer events and
overhead also differ from the baseline, so the wall-time change is not an
isolated causal benchmark. The interrupted earlier capture is excluded.

The separately based server PR
[#61](https://github.com/mascarenhas/vscode-titan/pull/61) was opened after local
verification, followed by compiler PR
[#156](https://github.com/mascarenhas/titan/pull/156). Both remain open and all
three owning Project items are In review.

The initial Linux runtime job exposed a test portability error: inherited Make
jobserver flags caused a warning to enter the new exact header-inventory
assertion. Its subprocess now clears those flags, and its inventory recipe uses
a temporary Makefile fragment instead of requiring GNU Make 3.82's `--eval`.
Compiler production code and the cold-capture implementation are unchanged.
The corrected case and all 55 tests in its suite passed with stale inherited
jobserver flags. The canonical full gate then passed again: 131 runtime/packaging,
3,331 compiler/language, and 455 native tests, with log
`/tmp/titan-single-ffi-full-test-ci-portability.log`.
Final-head Linux coverage and the subsequent authorized macOS dispatch remain
tracked in the PR checks.
