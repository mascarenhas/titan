# Compiler persistence for workspace language-server caches

Scope: compiler-owned payloads required by [vscode-titan#20](https://github.com/mascarenhas/vscode-titan/issues/20), with the server retaining SQLite ownership. Branch: `agent/language-server-cache`, baseline `16d9770684cb4d94a1d20fa81698be4a794f0574`.

## Contracts

- Encode/decode complete checked project entries as literal bounded graph data, never executable Lua. Preserve cycles, sharing, table keys, binary strings, primitive number representations, supported metatables and preprocessor token sidecars. Reject external AST retention, unsupported values, malformed/corrupt/incompatible data as cache misses.
- Decoding creates private graphs without changing compiler globals or filesystem state. Existing cached-source loading restores source-private relationships and recreates resolver-owned checking headers.
- A transport adapter supplies `get(kind, key)` and optional `put(kind, key, payload, inputs)`. The ordinary compiler has no SQLite dependency. The saved indexer stages writes; speculative analyses can read without publishing.
- Completed header payloads use the existing ordered process-cache identity and exact dependency/search closure. Revalidation hashes actual bytes plus followed/lstat/readability identities; preserved mtimes never certify unchanged contents.
- Converted foreign imports are one ordered environment snapshot with shared canonical owners and current-AST import references. Key target/toolchain/header/input/order context, not importer bodies. Replaying must skip foreign conversion on an importer-body edit while normal header/source-private validation and final contextual probes remain authoritative.
- Retain the existing in-memory fast path and complete-operation/compiler ownership. Cache failures degrade to ordinary work.

## Implementation sequence

1. Add graph codec and CPP sidecar ownership helpers; exercise real aliases/cycles/weak metadata and hostile binary payloads.
2. Add project entry export/import validation and external-AST ownership checks; test source-private reuse after restart and the first edit, including fresh checking-header paths.
3. Add completed-header adapter lookup/publication to existing cache validation and verify exact byte/search/identity invalidation with unchanged mtimes.
4. Add ordered foreign-import conversion snapshot/replay, preserving C tags, histories, macro state, enum identities and declaration links. Instrument avoided work.
5. Document APIs and failure behavior; run focused suites in private staging, then coordinate full verification and integration with the extension.

## Verification and delivery

Use existing compiler/Busted layers for codec, driver, C preprocessor/registrar and FFI checker regressions. No shared-prefix rebuild while the extension is compiling. Track compiler codec and conversion work in board-sized Titan issues. No commit/PR until the extension work is locally wrapped; leave both PRs open for maintainer review. Linux CI is expected; macOS dispatch still requires explicit authorization under repository guidance.

## Progress

- [x] Inspected baseline, compiler graph shapes, header cache identity and ordered import semantics.
- [x] Created focused compiler branch and this plan before source edits.
- [x] Graph codec and sidecar round trips.
- [x] Checked project export/import and ownership boundaries.
- [x] Completed header persistence and exact invalidation.
- [x] Converted FFI environment replay.
- [x] API documentation and independent compiler review.
- [x] Complete compiler/Busted gate.
- [x] Native stdlib aggregate and integrated server evidence.
- [x] Final diff and publication evidence prepared after local server verification.

Compiler issues: [#146](https://github.com/mascarenhas/titan/issues/146) owns literal graph/project/header persistence; [#147](https://github.com/mascarenhas/titan/issues/147) owns ordered conversion replay and depends on #146. Both are on Project 3 as P1/L, In progress.

API 6 provides the resolver cache identity, private project encode/decode/registry APIs, optional byte transport and reuse counters. The final 12 project/conversion acceptance cases pass against the refreshed isolated provider. Earlier broader focused runs passed 427 compiler/cache/FFI cases and 243 driver/header/codec/conversion cases. The final acceptance cases cover generic registry restoration, fresh source-private checking headers, stable native-unavailable identity, zero conversion on importer/provider body edits, cross-header completion and macro spacing, changed bytes despite preserved mtime, earlier include shadowing, corrupt payload fallback, read-only cache access, and cancellation identity.

Independent review found no actionable ownership, graph-codec, or FFI-replay issue. A separate live provider/consumer plus external generic-owner probe round-tripped complete project entries and rebuilt the declared registry without retaining external ASTs. Installed/source comparisons cover all 13 changed compiler Lua files; CI partition metadata includes every new spec.

Final current-source Busted verification passed **3,450 tests, zero failures/errors**, in 539.519109 seconds. The complete log is `/tmp/titan-cache-full-compiler-optimized.log`. It ran with `busted --run=checkout spec` in the private checkout, the refreshed extension-owned SDK selected read-only, isolated compiler-probe/cache state, and matching native source/archive/build prerequisites. All 120 compiler spec files are registered in the CI partition metadata.

The isolated LuaRocks-launcher regression now copies the full current compiler/C-parser Lua inventory, so new compiler modules are tested together instead of mixed with an older installed snapshot. Focused native build/packaging reruns pass, including all 16 LPegLabel and rockspec cases.

The full native stdlib aggregate passed **455 tests, zero failures**, using a second private source snapshot and a byte-verified current provider in the temporary Lua/native SDK prefix. The ordinary installed compiler in that prefix contains all 61 current compiler/C-parser Lua modules and reports API 6. Its child compiler processes use the same prefix. The complete log is `/tmp/titan-cache-native-stdlib.log`; the shared extension `.titan` prefix was read-only throughout this gate. Final integrated-server verification and both real-workspace benchmark sequences passed, as recorded below.

## Measured codec optimization and repository prerequisites

The first real vscode-titan benchmark retained 142 MB of checked-project payloads. A bounded read-only attribution on its 2,206,579-byte `server.compiler_io` payload measured 0.652537 s decode CPU (0.567326 s SHA, 86.94%) and 0.612671 s encode CPU (0.519764 s SHA, 84.84%). Both operations hash the 2,206,534-byte body once. Evidence: `/tmp/titan-cache-codec-attribution.log`.

- Add an optional `sha256_binary(bytes) -> digest` callback to graph options and the existing byte-transport adapter. Require a 32-byte binary SHA-256 result; retain the standalone Lua fallback and the exact format/API 6.
- Forward it through project, completed-header and ordered FFI payload encode/decode operations without compiler-global replacement. Invalid results and string failures are cache misses; non-string exception identities remain intact for cancellation.
- Verify callback/fallback cross-mode graphs, binary data, malformed results, exceptions, checksum corruption and adapter propagation. The server owns native SHA integration and unchanged-row reuse; per-entry semantic revision and ordinary dependency invalidation remain authoritative.
- Add the existing `sqlite-autoconf-3530400` directory to this repository's ordered FFI include roots. The first Titan benchmark failed to resolve `sqlite3.h` from the SQLite worker's `native.h`; its preserved diagnostics are in the extension's `.build/cache-benchmarks/titan-20260907/live-diagnostics.json`.
- Rerun focused compiler regressions and full compiler/native components with the current stdlib provider in the private SDK, then repeat integrated and real-workspace performance verification before publication.

The final native-checksum focused suite passed **89 tests, zero failures/errors**, in 29.185898 seconds (`/tmp/titan-cache-native-sha-final-focused.log`). The final full Busted rerun also passed on the synchronized callback source, as recorded above. No compiler production change followed the source synchronization or native gate. The repository now explicitly ignores `.titan-ls/`, making the language server’s per-project cache directory visible in repository policy.

## Final integrated evidence and delivery order

The companion server’s canonical gate passed 287 native tests, 56 JavaScript tests, 12 extension-host tests, the 19-scenario restart/protocol sequence, and package/install/linkage checks. Both actual repositories then passed strict feature, integrity and file-restoration checks against one frozen server image.

| Actual workspace | Cold | Warm restart | Saved body edit | Header edit |
| --- | ---: | ---: | ---: | ---: |
| vscode-titan | 51.291 s | 18.626 s | 17.440 s | 63.773 s |
| Titan | 453.968 s | 67.657 s | 102.670 s | 116.780 s |

The Titan warm process restored all 63 project entries and performed zero project analysis, header preprocessing/parsing or FFI conversion. Its saved body edit checked and encoded only `titan.sqlite3`, with four converted-FFI replay hits and no header/conversion work. The header edit performed one preprocessing/parsing pass and four conversions. These are measured local wall times, not performance thresholds. The benchmark restored source/header bytes, nanosecond mtimes and original cache-directory presence; its cleanup also checked access times.

Publication uses the required two-repository order: commit/push this compiler branch to give extension CI an immutable dependency, open the extension PR, then open the compiler PR and move issues #146/#147 to In review. Leave both PRs open. The compiler’s automatic push workflow runs its regular stdlib/provider, compiler/LuaCov and ASan/UBSan Linux checks; macOS is manual-only and is not dispatched for this work.
