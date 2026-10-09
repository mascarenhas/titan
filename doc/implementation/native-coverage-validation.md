# Native line coverage validation

This records the initial Titan-repository implementation of issue #210. The
metric is executable **line coverage**. Generated C branches and functions are
retained in raw gcov evidence but are absent from the public Titan metrics.
Local runs render reports; only CI uploads to Codecov.

## Final coverage expansion

The final source snapshot is **`c5bba2dc3767b4cfd67105ac35598ca7e01a6426c3b762f1de4c7413300834a2`** at implementation commit
**`abbc2637066179bea74e76dfdc0e7a39aca9912a`**, with 1,156 authored files. Lua remains at
`025bfc35df0885656de347fb7a7c377e90042a75`; the skills pin is
`df1e7837ab0869d98c853f252d6572a0cdde0503`. ABI 2, package 0.6.0 and
language-server API 1 remain unchanged. Commit
`ccafc366473cefcb3364c19323c95c6921bdff5e` then updates only the host-side
compiler-shard count expectation; the final publication commit adds this
validation record. Neither changes the native snapshot. The records below supersede the
historical baseline sections.

The final workflow measures the normal 23-root standard provider: 22 selected
production modules and 69 physical source contributors. An ordinary 28-root
native test consumer uses that provider. Static child fixtures link its same
archive; native test helpers, the runner, allocation hook and generated Lua
shims add no measured source lines. Every shim and final consumer/fixture input
is nevertheless sealed. Preparation counters stay separate from each fresh run.

| Platform | Covered / executable lines | Line coverage | Measured native results |
| --- | --- | --- | --- |
| Linux x86_64, GCC/gcov 16.2.1 | 15,754 / 17,263 | 91.26% | 1,274 passed; 1 platform skip |
| Intel macOS 15.7.7 VM, GCC/gcov 14.4.0 | 15,714 / 17,263 | 91.03% | 1,271 passed; 4 platform skips |
| Windows 11 x64, CLANG64/UCRT 22.1.8 | Unsupported backend | No percentage | 1,241 passed; 22 classified skips ordinary |

All native runs audit all 28 owners. Ordinary Linux results are 1,274 passed and one platform skip;
ordinary macOS results are 1,263 passed and twelve classified skips. The additional eight ordinary macOS
skips concern allocation-site layouts in system OpenSSL 3.6.5. All twelve real
OpenSSL failure scenarios pass against the measured bundled OpenSSL 3.5.7
provider. The same twelve pass against Linux's system OpenSSL 3.5.9.
Windows checks include clean Lua/native/compiler SDK relocation, the fresh
stdlib executable, compiler coverage contracts and explicit early rejection of
`--coverage` before invoking a nonexistent C compiler or creating output.

| Linux module | Covered / executable lines | Line coverage |
| --- | --- | --- |
| Async | 1,963 / 2,008 | 97.76% |
| OS | 790 / 870 | 90.80% |
| SSL | 815 / 909 | 89.66% |
| UV | 4,277 / 4,937 | 86.63% |

Compared with the retained Linux r8 report, 1,122 formerly zero-count lines are
now covered and no previously covered lines are lost. Correcting authored
foreign `elseif` attribution adds eleven executable SQLite worker lines; every
one is covered. The denominator therefore changes from 17,252 to 17,263.
Compared with the first 80.73% report, overall Linux coverage is now 91.26%.
The final Mac report is 15,714 / 17,263 (91.03%). Two previously hit SSL
shutdown-error lines, `titan/ssl.titan:1682–1683`, have zero counts in this
final run despite identical production/provider bytes and passing tests.
The retained r11 report remains separate; its hits are not merged into the
final report. No denominator exclusions or unions of diagnostic counters
produced these results.

Linux async's remaining 45 lines concern native/allocation failure, private identity
and recovery guards, infeasible admission limits, and conservative defensive
arms. Linux OS retains 80 misses: 28 are explicitly Windows-only; others include
allocation/setup errors, terminal-descriptor diagnostics, accepted-child
rollback and the 30-second escalation path. Some remain reachable and unproven.

Linux SSL has 94 remaining lines: 39 disabled native-mode/retry paths, 22 native
construction/reference invariants, five nonreturning tails, five scheduling
guards, seven further-chain/startup allocation candidates, four Titan
allocation/cleanup paths, four transport-timing paths, five native error-queue
fallbacks and three boundary lines for PEM inputs above 2 GiB. macOS SSL has
96 misses, including the two shutdown-error lines described above. The allocation candidates, late
write admission, narrow transport failures and error-queue fallbacks are not
claimed unreachable. SSL remains below the requested near-total target.
The exact classification is retained with source and report hashes in
`/tmp/titan-210-ssl-gap/ssl-r12-full-classification.tar.gz`, SHA256
`28bd1da9571449ea92f709ef8862bd665fb8f98139a3998e931161f914d85f6b`.

Current host contracts pass 30 cases. Linux compiler coverage contracts pass
42 cases; macOS combines 41 initial positives with the corrected focused
temporary-directory case. That regression is additionally rerun on Linux
after the test portability fixes. Windows compiler coverage contracts pass
35 cases with eight GCC-only pending cases. Its build/publication contracts
combine 60 initial positives with two corrected focused cases, leaving 38
platform-dependent pending cases; this is not a fresh 62-case invocation.
The exhaustive compiler manifest contains 152 files, and the source-rock
pack/unpack check passes.
The original complete compiler/runtime/packaging and both OpenSSL production
mode baselines remain separate evidence below; they are not relabeled as a
new all-current full compiler run.

Five independent contract findings are resolved: stale foreign-helper callers,
bounded whole-process-group cleanup, authored foreign `elseif`/`until`
attribution, bare-CR rejection, and generated Lua shim provenance. The retained
review checkpoints have SHA256
`58c3facb0ff9cf1c0dfa42ed0290f22dd8c8abb320f325eeb4d40cf4d8366912`
and `067ec64511b01707ab75e822696dc8a1788e3f4035a677de92f76d24fe9b06df`.
Review was read-only against those frozen artifacts; independent reruns are
not claimed. Native Windows testing also corrected test assumptions about
MinGW uname text, unsupported user/group lookup IDs, and classified PTY skips.

The final provider was built from a captured preflight whose production,
compiler, runtime and native-payload bytes are identical to the final snapshot.
Final fixtures and consumers were rebuilt and sealed after the test-only
changes. Original provider objects, notes, images and native inputs were
hash-checked unchanged before and after collection. This is explicit composed
validation; it is not described as one fresh all-current Make invocation.

Final local receipts and archives:

- Linux receipt: `/tmp/titan-210-followup-linux/linux-final-receipt.json`,
  SHA256 `84027257ea07115422880dd950a986c82f60a704cab48da8cf941aa8c80c7ba1`.
  Archive: `/tmp/titan-210-followup-linux/linux-final-evidence.tar.gz`,
  SHA256 `a22bf82b98ad695e908e8157987ff0a495a2a717875ecbc9bc148d35f60255d3`.
- macOS receipt: `/tmp/titan-210-macos-r12-receipt.json`,
  SHA256 `e31967210280895c578847932ba0f3fbe262f4e5e0709cbc509000443b196afa`.
  Archive: `/tmp/titan-210-macos-r12-evidence.tar.gz`,
  SHA256 `a6ddb2c684f46b9a06c7e86f70107a286b06a5ff1011c3082ff0dd532e6bb5c1`.
- Windows receipt:
  `/tmp/titan-210-platform-evidence/windows-r12-final/windows-r12-final-receipt.json`,
  SHA256 `43f9e65bd793a0d31a9e64fad6fd0b7abf27e7a592c9ce7d63772c44cea0a27d`.
  Archive:
  `/tmp/titan-210-platform-evidence/windows-r12-final/windows-final-retained-evidence.tar.gz`,
  SHA256 `3cf7164753923667bb341d343186f59e372b349b2b37409b1030c7ad5af06078`.

Standalone Linux HTML is also copied to
`.titan-coverage/issue-210-final-linux/coverage.html`; macOS HTML is copied to
`.titan-coverage/issue-210-final-macos/coverage.html`. Both retain LCOV,
Cobertura, normalized lines, raw gcov JSON, seals and run provenance. Public
LCOV contains no function or branch records. Local runs never upload.
Windows LLVM-gcov support remains a separately coordinated follow-up; its
synthetic feasibility probe is not a native stdlib coverage report.

## Historical source and tool identities

Validation used `codex/issue-210-native-coverage` from
`524ca53935c212c6268d584ef098024444b85a82`. The initial compiler, host tool, Make
recipes and tests were captured in a source-only snapshot with SHA256
`d816e10848e78ba1465f873b7076ad13e55558df08ef8a8afcee1213e5531949`.
The Lua fork pin is `025bfc35df0885656de347fb7a7c377e90042a75`; the programmer
and tester skill pin is `a9bea9e0b631b7bb35b396c484559c209567c30e`.
The subsequent coverage-driven UV tests and their fixture/build wiring were
captured in snapshot
`53ceceaf93c88d805556b85bccf5bf5cf8cdeab76b453e0341639a487cace4e3`.
Compiler, host-tool and production stdlib bytes are identical between these
snapshots. The final native correction was captured in snapshot
`31b6ee74d63826991f08f8bf59ad93c36f7d4f7a8ad90a0d6d07019fdd5130c4`:
only the `thread_t:equal` binding changed production code. Documentation and
this evidence record followed validation.

| Platform | Ordinary compiler | Coverage compiler/profiler | Reporter/formatter |
| --- | --- | --- | --- |
| Linux x86_64 | GCC 16.2.1 | GCC/gcov 16.2.1, JSON v2 | gcovr 8.4 / clang-format 22.1.8 |
| macOS 15.7.7 x86_64 VM | Apple Clang 17 | GCC/gcov 14.4.0, JSON v2 | gcovr 8.4 / clang-format 22.1.8 |
| Windows 11 x64 VM | MSYS2 CLANG64/UCRT Clang 22.1.8 | Unsupported; explicit early rejection verified | Normal native testing available |

Each platform used a fresh, separate Lua 5.5 SDK and the validation profile.
macOS used GNU Make 4.4.1. This is Intel macOS evidence; it does not establish
Apple Silicon runtime behavior. No hosted macOS workflow was dispatched.

## Initial Linux baseline

The public `titan-native-coverage` Make target source-linked every production
stdlib root except `titan.test` into the existing 28-root aggregate. The manifest
contains 22 measured module objects, 69 physical Titan source contributors,
83 linked inputs and one executable. Native payload, test owners, helpers and
the runner remain outside the reported source inventory.

The unfiltered run passed 1,140 tests with one classified platform skip:
POSIX exit status cannot preserve a value above eight bits. All 28 test owners
were audited. The report records `complete=true` and `tests_passed=true`:

| Executable lines covered | Executable lines total | Line coverage |
| --- | --- | --- |
| 13,928 | 17,252 | 80.7327% |

The sealed build ID is
`1f1c6834f2c4d2ec6ce07bdd1b0e05676ceb298b79e667acbb431c57e62888b0`.
The LCOV SHA256 is
`aa6a11076fcb5ad426b114cef3c81c64f3dcf4b94298f6115c8d74e091236a66`;
the standalone HTML SHA256 is
`3db2598799ffe7c260a87b82b93d1ab336348477c7ff41fa8c249965ce8c5f1e`.
LCOV contains no function or branch records. The report retains normalized
line JSON, Cobertura, raw gcov JSON, source/image hashes and run receipts.

Local evidence is under `/tmp/titan-issue210-linux/`: `validation-receipt.json`,
`compiler-final.log`, `native-ordinary.log`, `coverage-final.log`, and
`coverage-source/.titan-coverage/final-report/`. These are local artifacts,
not dependencies of a checkout or installed SDK. The full measured build,
run and report took approximately 14 minutes 52 seconds on this host; no
initial percentage threshold was imposed.

## Coverage-driven JSON tests

The first diagnostic report exposed missed deterministic map-key ordering
paths in `titan/json/writer.titan`. The new native tests exercise shared prefixes,
embedded NUL and unsigned UTF-8 key bytes. A companion case checks valid UTF-8
scalar boundaries, malformed third/fourth continuation bytes, error positions,
nested error paths and successful recovery after an invalid encode.

Both new parent cases and their two subtests pass in ordinary and measured
runs. The final complete report increases the writer from 195 to 198 covered
lines out of 202. The previously missed anchors have observable hits:

| Writer source line | Diagnostic count | Count with new tests |
| --- | --- | --- |
| 19 | 0 | 3 |
| 33 | 0 | 4 |
| 109 | 0 | 3 |

The diagnostic aggregate initially exposed a harness link problem: stock Lua C
dependencies require the host Lua API to be exported when the aggregate
source-links the whole stdlib. The coverage-only Make link now exports that
API on Linux and Darwin. The final baseline above is a fresh passing build/run;
the earlier failing diagnostic is not presented as a passing baseline.

## Regression and ordinary gates

Linux passed the complete 151-file compiler catalogue: 4,258 passed and one
Windows-specific environment test skipped, out of 4,259. The six retained
runtime/build/packaging specs passed all 133 cases. The ordinary native suite
also passed 1,140 of 1,141 cases with the same classified exit-status skip.

The coverage-specific gates passed 23 lexical converter cases, 10 real coder
attribution cases, five real GCC compiler cases and 26 host-tool cases. They
cover formatting on/off, nested source/generated/authored-C regions, lexical
continuations and literals, exact source counts, closures and foreign bodies,
notes-only modules, staged paths and aliases, compile-only/incremental reuse,
loaded providers, compatible multi-image/shard merging, threads and joined
children, duplicate/stale evidence, failures, timeouts and incomplete collection.
Raw Unicode separators inside strings and CRLF files retain physical source
line indexes and correct LCOV checksums.

The unselected foreign-helper probe reports only its selected caller, with the
caller line counted once. GCC's generated-header records stay in raw evidence
and do not enter the Titan source denominator.

## Gap concentration

The 3,324 uncovered Linux lines are concentrated rather than evenly spread:

| Module | Uncovered executable lines | Line coverage |
| --- | --- | --- |
| `titan.uv` | 1,925 | 61.0% |
| `titan.async` | 373 | 81.4% |
| `titan.ssl` | 198 | 78.2% |
| `titan.os` | 181 | 79.2% |
| `titan.string` | 153 | 91.5% |

UV accounts for 57.9% of misses; the first three modules account for 75.1%,
and the first five for 85.1%. Outside UV, line coverage is 10,916/12,315
(88.6%). Fifteen of 22 modules exceed 90%; JSON is 99.0%, PEG 98.0%,
WebSocket 94.3% and HTTP 92.3%. The single largest source contributor is
`titan/uv/uv.titan` with 951 misses. Low-level sync, threading, pipe/TTY and
stream-owner contributors also have substantial gaps. These are Linux counts;
platform baselines remain separate.

Source review identifies five nonoverlapping UV clusters containing
1,125/1,925 misses (58.4% of UV misses):

| UV cluster | Missed executable lines | Examples |
| --- | --- | --- |
| Low-level filesystem operations/results | 389 | Request type inspection, directory operations, copy/link/time/ownership wrappers |
| Synchronization and threading | 210 | Rwlocks, condition variables, TLS keys, once, extended thread creation/detach |
| Direct UDP, address conversion and DNS callbacks | 195 | Batch sends, `inet_pton`/`inet_ntop`, reverse-DNS callback bridge |
| TTY handling | 183 | Initialization, modes, reads, close and size |
| Descriptor and filesystem polling | 148 | Watcher initialization, start, delivery and close |

These include whole unexecuted API families. Forty-three TTY lines are
explicitly Windows-only and cannot be exercised by the Linux run. Separately,
180 callback-exception lines remain uncovered across `uv.titan`,
`stream_owners.titan` and `udp.titan`; those overlap the clusters and must not
be added again. This classification is source review of the Linux line data,
not evidence that every uncovered path is feasible on every platform.

## Coverage-driven UV tests

Two independent test contributors exercise the concentrated gaps. The
filesystem/polling contributor covers
copy/link/truncate/sendfile and metadata operations, typed path/statfs/symlink
results, directory ownership and EOF, borrowed-socket descriptor polling,
callback failures, and filesystem polling from absence to creation. The
synchronization/network contributor covers rwlocks, condition-variable permits,
TLS isolation, joined thread identity/name, once contention, affinity contracts,
address conversion, reverse-DNS callback reuse, and immediate/batch UDP sends
with binary payloads. Native worker callbacks use the public UV C adapters and
retain their argument storage until every thread has joined.

The contributors add 19 cases to the existing UV public test owner; the
aggregate still has 28 roots. All 19 pass under instrumentation in a focused
stdlib harness. Compared against the initial full baseline's exact line
inventory, they reach 693 previously uncovered UV lines: 409 from the
filesystem/polling contributor and 284 additional lines from the second.
This removes 36.0% of the initial UV misses. That comparison is a union of
line identities, not a replacement for the fresh complete aggregate report.

The expanded ordinary Linux aggregate passes 1,159/1,160 cases with the same
single platform skip, zero failures and all 28 owners. The prepared-tree
`libuv_build_spec.lua` integration gate passes 72/72. The complete expanded
Linux coverage uses a fresh output directory after the production-mode checks
reinstalled the SDK. Reusing older generated C environments correctly rejected
the replaced native header's inode-sensitive search identity, despite unchanged
header bytes; no compiler or stdlib source correction was needed.

The new thread-identity case exposed an existing Windows binding defect.
`uv_thread_equal` takes pointers to `uv_thread_t`. The old call passed native
field values: Unix scalar IDs received automatic address coercion, while a
Windows HANDLE was cast as a pointer and dereferenced by libuv. Captured Windows
generated C confirmed this caused the access violation. The one-line correction
passes the existing native storage pointers, matching create/join/name/affinity
operations. It preserves source positions, public signatures and ABI. The
unchanged regression checks calling-thread identity and worker inequality.

## Final Linux results

After the native correction, both the ordinary installed-provider suite and
the fresh measured suite pass 1,159/1,160 cases with the same one platform skip,
zero failures and all 28 owners. Provider-only publication preserved the SDK
header identity. The measured rebuild changed only UV: the other 21 objects
and notes retained identical hashes and timestamps.

| Scope | Initial covered / total | Final covered / total | Final line coverage |
| --- | --- | --- | --- |
| Complete production stdlib | 13,928 / 17,252 | 14,621 / 17,252 | 84.7496% |
| UV | 3,012 / 4,937 | 3,705 / 4,937 | 75.0456% |

All 693 gained lines are in UV, and no previously covered lines became zero.
The executable source-line inventory is unchanged. The native correction
changes only the source hash of `titan/uv/threading.titan`; physical source
positions remain stable. UV now accounts for 1,232/2,631 remaining misses
(46.8%), down from 57.9% of the initial misses.

The final report has `complete=true` and `tests_passed=true`, 22 measured
objects, 69 contributors and 83 linked inputs. Its sealed ID is
`346958e76e97acc2808c09623cb5330fe596983a5b8b73275e17c5f606af29ae`.
The LCOV SHA256 is
`3ac43aa289fed1748e1bcecaaca746d0104bb3ed46b296cb37a647177d5675e8`;
the standalone HTML SHA256 is
`b70365717ebf0f1a0e49f42562400604fda641ed590026182760b05561a9f276`.
Final local evidence is `expanded-validation-receipt.json`, `native-r8.log`,
`coverage-final-r8.log`, and
`coverage-source/.titan-coverage/final-r8-report/` under
`/tmp/titan-issue210-linux/`.
The full image/notes/counters/report archive is `r8-final-full.tar.gz`, SHA256
`52fa7fa02d3ea9a1e3c145e4dc3343986988e6439a1130fc662dae9268169af6`.
All 1,134 authored source hashes match the tested snapshot after these gates.

## Installed tools and production modes

The final feature was installed into the isolated Linux SDK with stock
LuaRocks. The installed host script and both installed coverage Lua modules
hash-match the checkout. A tiny compiler fixture built, sealed, ran and rendered
through installed commands: three executable lines hit, while an untaken
return and an uncalled function remained zero (3/5). Evidence is under
`/tmp/titan-210-installed-cli/`.

The bundled and system OpenSSL production smokes both completed successfully
with shared and static consumers. Their retained log is
`/tmp/titan-issue210-linux/production-modes-final-piped.log`.

## Initial macOS VM baseline

The six retained runtime/packaging specs passed 129 cases. The complete
4,259-case compiler catalogue was followed by a corrected mock-spec rerun
(driver and parallel specs, 230/230) and the dedicated real GCC suite (5/5).
This is composed validation: the first full catalogue had one test-double
failure, corrected in the final source. The five initially skipped coverage
cases passed with configured GCC/gcov/gcovr. The three remaining ordinary
compiler skips are platform-specific: live Windows environment updates,
Linux default LTO, and GNU/ELF whole-archive semantics.

The ordinary native suite and the fresh complete measured suite each passed
1,137/1,141 cases with four classified platform skips and all 28 owners.
The host gate passed 26/26, lexical/coder cases 33/33, and both bundled/system
OpenSSL shared/static production smokes passed.

The separate Mac baseline is 13,920/17,252 lines (80.6863%), with
`complete=true` and `tests_passed=true`. It has 22 measured objects,
69 contributors, 85 linked inputs and no unmeasured modules. Its sealed ID is
`659865d23c6939fa5d82e7c8079e89cb3da905ead6b3d7940a4dc700f378f060`.
Source hashes matched the final tested snapshot after the gates.

## Initial Windows VM baseline

The complete compiler catalogue passed 4,208 of 4,259 cases, with 51
documented platform/backend skips. Runtime/packaging passed 83 cases with
50 documented pending cases and no failures/errors. Fresh exact-pin
Lua/native/compiler SDK and relocation/publication checks passed. The installed
compiler rejects coverage before invoking a deliberately nonexistent C
compiler or creating an output directory. Windows source-attribution/coder
tests passed 33/33. The final baseline native executable passed 1,128/1,141
cases, with 13 classified skips (10 platform and three capability), zero
failures and all 28 owners. Capability skips are two `/dev/fd` inventory
checks and symlink privilege. Owned scratch cleanup and process reaping
passed. The corrected compiler-spec rerun passed 227/230 with three
symlink-capability pending cases and no failures/errors. Authored source
hashes matched the tested snapshot after the gates.

## Final macOS VM results

After the UV binding correction, the ordinary and measured native aggregates
each pass 1,156/1,160 cases, with four platform skips, zero failures and all
28 owners. The formerly failing Windows thread-identity regression also passes
its focused macOS run. Provider-only publication preserves all 24 SDK header
identities. The measured rebuild changes only UV; the other 21 objects and
notes retain identical hashes and timestamps. Every one of the 1,134 authored
source hashes matches the final tested snapshot after the gates.

| Scope | Initial covered / total | Final covered / total | Final line coverage |
| --- | --- | --- | --- |
| Complete production stdlib | 13,920 / 17,252 | 14,609 / 17,252 | 84.6800% |
| UV | 3,006 / 4,937 | 3,695 / 4,937 | 74.8430% |

All 689 gained lines are in UV, no previously covered lines became zero, and
the executable source-line inventory is unchanged. This is a separate Intel
macOS measurement; platform reports are not merged. The final report has
`complete=true` and `tests_passed=true`, 22 measured objects, 69 contributors,
85 linked inputs and no unmeasured modules. Its sealed ID is
`844d6dfe82a1805ff62bb103f7d0aefa4ccaf967d3520a789fbb5cdbcc6fb368`.

Final local evidence is `macos-r8-final-receipt.json`,
`macos-r8-line-delta.json`, and
`macos-r8-final-report/coverage-r8/report/` under
`/tmp/titan-210-platform-evidence/`. The full image/objects/notes/counters/report
archive is `macos-r8-full.tar.gz`, SHA256
`6c673b2d92e1309366402e812d4857d5a00f0c62faed786c4add00e4e8caa14c`.
The standalone report archive is `macos-r8-final-report.tar.gz`, SHA256
`16fe787e0b9c7c0a6b1499ef3e556e8a14eeef968b8263f73a6d652375cc2b81`.
The complete compiler/runtime and production-mode validation remains the
composed baseline described above; compiler and host-tool bytes did not change
in the final UV correction.

## Final Windows VM results

The corrected installed provider and native aggregate pass 1,145/1,160 cases,
with 15 classified skips, zero failures and all 28 owners. The focused
thread-identity regression passes 1/1. Captured generated C now passes native
storage addresses to `uv_thread_equal`. Owned scratch cleanup and process
reaping pass, the SDK FFI header identity is unchanged, and all 1,134 authored
source hashes match the final tested snapshot after the run.

The skips comprise 11 platform cases and four capability cases. The two
additional skips introduced by the new tests are integer-descriptor polling
(Windows uses native socket tokens rather than CRT descriptors) and symlink
timestamp/results (the VM lacks symlink creation privilege). The socket-poll
case and all new synchronization, thread, TLS and UDP cases pass.
The build-contract gate passes 50 cases with 22 Unix-specific pending cases.
Normal Windows behavior and early rejection of the unsupported coverage
backend are verified; no Windows native coverage percentage is claimed.

Final local evidence is `windows-r8-final-receipt.json`, including every exact
skip reason, and `windows-r8-thread-equal-proof.json`, under
`/tmp/titan-210-platform-evidence/`. The final archive is
`windows-r8-final-evidence.tar.gz`, SHA256
`5dc161fab4e3bf89398e29c677f39f438178fe54b388725cc087f23c4effd4a3`.
The original access-violation evidence is retained separately. The complete
compiler/runtime baseline and corrected compiler-spec rerun are described
above; compiler and host-tool bytes did not change in the final UV correction.

## Windows backend follow-up probe

A bounded synthetic CLANG64/UCRT probe used Clang, llvm-cov, llvm-profdata,
and clang-format 22.1.8 on the same Windows VM. Clang `--coverage` plus
`llvm-cov gcov -i` preserved two Titan-style `#line` filenames, exact taken and
untaken counts, multiline anchors, and authored C locations with formatting
on/off in both an executable and a loaded/unloaded DLL. Notes without counters
reported zero lines; atomic profile updates emitted actual atomic operations.
Fresh `GCOV_PREFIX` collection required `GCOV_PREFIX_STRIP=1` to remove the
Windows drive component and left original counters unchanged. LLVM source-based
coverage instead reported physical C locations and omitted both virtual Titan
files, so it cannot directly consume the current source-attribution scheme.

This proves feasibility for a separate LLVM-gcov backend, not Windows support
in the initial GCC backend. LLVM rejects `--json-format`, requiring its own
strict intermediate reader/version contract. Joined thread/child collection,
termination and incomplete-run accounting, locking, and production packaging
remain acceptance work. Oobii recommends that backend as a separate follow-up;
this delivery retains explicit Windows rejection and ordinary VM verification.
The complete local probe receipt is
`/tmp/titan-210-windows-coverage-probe/README.md`; asserted `result.json` SHA256
`9c91b1a07818dab412f74a66ae69c8aeb34bf91a5c99972e193cb773cc8c03a2`,
archive SHA256
`ea11dd08a2ee4036c103afb3ee05acb0e8dedddb7c5fd4e068cc11cc87e35239`.
No product sources or SDK bytes were changed by the probe.

## Reproduction

Prepare a separate validation SDK, then follow the explicit dependencies and
build/run/report commands in [native coverage](../language/native-coverage.md).
The checked-in requirements pin gcovr 8.4; use matching GCC/gcov 14 or newer.
Keep platform receipts separate and choose a new build directory after changing
compiler/settings identity and a new run directory for every run.

CI repeats the backend/attribution/collection gates, builds this complete
inventory, retains the reports and raw evidence, then separately uploads LCOV
with the `native-stdlib` Codecov flag. The existing LuaCov `compiler` upload
remains a separate component. Hosted CI and Codecov upload were not exercised
by this local validation.
