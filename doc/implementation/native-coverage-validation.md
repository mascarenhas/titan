# Native line coverage validation

This records the initial Titan-repository implementation of issue #210. The
metric is executable **line coverage**. Generated C branches and functions are
retained in raw gcov evidence but are absent from the public Titan metrics.
Local runs render reports; only CI uploads to Codecov.

## Published core expansion snapshot

The native expansion snapshot is **`c5bba2dc3767b4cfd67105ac35598ca7e01a6426c3b762f1de4c7413300834a2`** at implementation commit
**`abbc2637066179bea74e76dfdc0e7a39aca9912a`**, with 1,156 authored files. Lua remains at
`025bfc35df0885656de347fb7a7c377e90042a75`; the skills pin is
`df1e7837ab0869d98c853f252d6572a0cdde0503`. ABI 2, package 0.6.0 and
language-server API 1 remain unchanged. Commit
`ccafc366473cefcb3364c19323c95c6921bdff5e` then updates only the host-side
compiler-shard count expectation; the final publication commit adds this
validation record. Neither changes the native snapshot. The subsequent CI
collection correction changes test plumbing only. A later POSIX host ownership
correction requires fresh captures against that unchanged native snapshot;
the original r12 captures are retained as historical evidence. The current
ownership verification is recorded below.

The final workflow measures the normal 23-root standard provider: 22 selected
production modules and 69 physical source contributors. An ordinary 28-root
native test consumer uses that provider. Static child fixtures link its same
archive; native test helpers, the runner, allocation hook and generated Lua
shims add no measured source lines. Every shim and final consumer/fixture input
is nevertheless sealed. Preparation counters stay separate from each fresh run.

| Platform | Covered / executable lines | Line coverage | Measured native results |
| --- | --- | --- | --- |
| Linux x86_64, GCC/gcov 16.2.1 | 15,754 / 17,263 | 91.26% | 1,274 passed; 1 platform skip |
| Intel macOS 15.7.7 VM, GCC/gcov 14.4.0 | 15,707 / 17,263 | 90.99% | 1,271 passed; 4 platform skips |
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
The original r12 Mac report is 15,714 / 17,263 (91.03%). Two previously hit SSL
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
fallbacks and three boundary lines for PEM inputs above 2 GiB. The original r12 macOS SSL report has
96 misses, including the two shutdown-error lines described above. The allocation candidates, late
write admission, narrow transport failures and error-queue fallbacks are not
claimed unreachable. SSL remains below the requested near-total target.
The exact classification is retained with source and report hashes in
`/tmp/titan-210-ssl-gap/ssl-r12-full-classification.tar.gz`, SHA256
`28bd1da9571449ea92f709ef8862bd665fb8f98139a3998e931161f914d85f6b`.

The original host gate passed 30 cases; the corrected POSIX host gate passes
all 32 cases. Linux compiler coverage contracts pass
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

The original standalone Linux HTML is also copied to
`.titan-coverage/issue-210-final-linux/coverage.html`; macOS HTML is copied to
`.titan-coverage/issue-210-final-macos/coverage.html`. Both retain LCOV,
Cobertura, normalized lines, raw gcov JSON, seals and run provenance. Public
LCOV contains no function or branch records. Their original run receipts
predate the ownership correction below and must not be used as current
completion evidence. Local runs never upload.
Windows LLVM-gcov support remains a separately coordinated follow-up; its
synthetic feasibility probe is not a native stdlib coverage report.

## First published CI readback

The first published head, `149bc2454252d0d0f358f6699cbb4d78907c947a`, ran in
[GitHub Actions run 37880355337](https://github.com/mascarenhas/titan/actions/runs/37880355337).
The producer, both compiler pairs, compiler coverage merger and sanitizer
passed. The independent native coverage job reached its 30-minute job limit
and was cancelled before collection or upload. Its attribution preflight
passed 42 cases from 04:03:59 to 04:07:14 UTC; the covered provider and consumer
build then took 21 minutes 35 seconds. The aggregate started at 04:28:50 and
was still passing cases when the job was cancelled at 04:31:55. The reporter
refused to publish counters from the unfinished run. This CI run produced no
native Codecov report.

[Codecov's compiler check](https://github.com/mascarenhas/titan/pull/213#issuecomment-6074228412)
reported 92.27% project coverage, but patch coverage failed at 286 / 354
executable lines (80.79%) against the existing 90% target. The 68 misses were
41 in `titanc`, 16 in `driver.lua`, eight in `coverage_lines.lua`, and three in
`coder/statements.lua`. The newly added `coverage.lua` was absent from the
collected child-process statistics, so those counts did not include its
executable denominator. The status is scoped to the `compiler` flag; a native
upload cannot repair that compiler result.

The correction supplies the compiler shards with matching GCC/gcov, the pinned
gcovr reporter and clang-format, and makes missing coverage tools a failure in
those configured CI lanes. Real CLI tests explicitly collect their child Lua
processes into private statistics files and merge them into the parent runner
only after verifying that copied, tracked and parent-resolved source bytes
agree. An intentionally modified frontend remains outside that merge.
Native coverage receives a 45-minute job budget for preparation, the full
covered build, the unchanged 600-second aggregate deadline and report upload.
Compiler pairs also receive 45 minutes for the regular specs plus real CLI
coverage regressions, whose source hashing is slower under LuaCov.
No tests, coverage thresholds or measured production sources are removed.

Local verification passes all 36 mapper, CLI and dependency tests without
LuaCov. A full-scope measured invocation passes 26 mapper and seven existing
CLI cases in 877.84 seconds; the final two policy/collector cases pass in a
separate measured invocation, and the final Make dependency case passes in
115.21 seconds. The long invocation loaded its test wrapper before those two
cases and the collection-count assertions were added. The frozen collector,
compiler bytes and existing child argv are identical; the final wrapper also
passes the complete ordinary invocation. These are composed checks, not one
fresh measured invocation of all final test code.

Combining only successful current-source measurements with the two original
CI statistics artifacts gives a local patch projection of **601 / 618
executable lines (97.25%)**. The newly observed `coverage.lua` contributes
250 / 263 lines (95.06%); a repeat-condition case reveals one further active
changed line. Thus the denominator increases from 354 to 618. All changed
driver lines and all 17 changed statement-generator lines are hit; `titanc`
has three remaining misses and the lexical converter retains one defensive
miss. This is a local projection, not a new hosted Codecov result. Initial
statistics from a rejected stale installed compiler are diagnostic-only and
are excluded from the composition.

## POSIX leader-exit ownership correction

Reviewing the failed CI capture exposed a separate host-runner defect in the
published `149bc2454252d0d0f358f6699cbb4d78907c947a` implementation. A test
leader could flush its counters and exit successfully while an unjoined child
remained in the runner's private process group. Before the child's later flush,
the old host could produce `complete=true` and `tests_passed=true`. Subsequent
counter-hash rejection detected the late change but did not prevent that
earlier false success. A retained real GCC reproduction demonstrated the race;
this is not evidence that any particular original stdlib count was wrong.

The correction checks owned process-group emptiness after every leader exit.
After natural leader completion, it retires any surviving group and marks that
run incomplete with status 125 while retaining the raw leader status. Timeout
and interruption remain bounded and retain statuses 124 and 130. No
counter hashing occurs without confirmed group emptiness, including when only
an orphan zombie remains. Reporting rejects unconfirmed ownership even with
`--allow-incomplete`. Run receipts now use version 2; older runs require fresh
capture. Build manifests remain version 1, with no provider or ABI change.
Deliberately escaped sessions/groups are outside the stated ownership boundary.

All 32 Linux host contracts pass, including held-child leader exits 0 and 23,
joined children, ordinary nonzero exits, resistant-child timeout, interruption,
and rejection of legacy or inconsistent receipts. Independent source review
found no material blocker. Against the exact retained GCC fixture, the corrected
host returns 125, records leader status 0 and confirmed empty ownership, and
the report returns 2 with both completion and test-success false. The sealed
receipt is `/tmp/titan-210-posix-early-leader-probe/final-receipt.json`, SHA256
`1e414f8aa1b1029fd4c6ff4b95ce12800f8a288006e1bfc540ab038ab585f0d7`;
the evidence archive is `/tmp/titan-210-posix-ownership-evidence.tar.gz`, SHA256
`c63b4a3c9bde2c07cc54435337e2b7c7a6d97a2949e99d88713944dce1fe8ee2`.
The first hosted native job never collected or uploaded a report, so its
cancellation did not publish a false completed native result. Compiler LuaCov
collection is a separate path.

Fresh Linux capture with the corrected external host reuses the exact sealed
r12 provider, consumer and fixtures without rebuilding or resealing them.
All 1,275 selected cases finish: 1,274 pass and one platform skip, with all
28 owners audited. The version-2 receipt confirms empty ownership without
forced retirement and all 22 expected fresh counters. Coverage remains
15,754 / 17,263 lines (91.26%); all executable-line identities and source MD5s
agree with r12, with no gained or lost hits. Before/after hashes match for all
6,355 inventoried inputs, including the old build, SDK, run and report.
The new report is `.titan-coverage/issue-210-owned-linux/coverage.html`.
The receipt is `/tmp/titan-210-linux-host-lifecycle-r13/evidence/final-receipt.json`,
SHA256 `9472ec07463b861899a986f8811aa09566e253dd9545fd070674ed2d8226374d`;
archive `/tmp/titan-210-linux-host-lifecycle-r13-evidence.tar.gz`, SHA256
`9428a916a3e3e8e83b9544f75ceb57e266a586f9b8962a389be7962d7f47cfb6`.

Fresh Intel macOS capture also reuses the unchanged sealed r12 artifacts.
The six focused lifecycle cases pass, then all 1,275 native cases finish:
1,271 pass and four platform skips, with all 28 owners audited. The version-2
receipt confirms empty ownership without retirement and all 22 fresh counters.
All 3,955 retained input hashes match before and after. The fresh report is
15,707 / 17,263 lines (90.99%), with identical executable-line identities and
source MD5s. Seven r12 hits are now zero: `titan/net.titan:642` and
`titan/ssl.titan:822,828–832`, covering TCP shutdown failure and TLS reciprocal
shutdown-error handling. No previous hits are merged into this report. Current
macOS SSL is 807 / 909 lines, leaving 102 misses. The new report is
`.titan-coverage/issue-210-owned-macos/coverage.html`.
The receipt is
`/tmp/titan-210-macos-host-lifecycle-prep/retrieved/evidence/final-receipt.json`,
SHA256 `3db0de7c009a8db898bd7b4277104303fa06273cad279aefb002538252062a62`;
archive `/tmp/titan-210-macos-host-lifecycle-prep/evidence.tar.gz`, SHA256
`cd45ab6cb079f3ed5211a5664e0fbaa4e633228ff0bf4829581265b88281a482`.

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

## Second published CI native readback

CI run `37887221316` at `e9d3855e3429bb526cf3924eb32c5002fa99b0d0`
completed the native capability gates, complete production build, fresh aggregate
capture and line report successfully. All 1,275 selected cases finished:
1,272 passed, three classified skips, zero failures, with all 28 owners audited.
Two skips reflect absent alternate numeric locales; the third is the POSIX
eight-bit exit-status limit. The hosted GCC 14 report is 15,728 / 17,263 lines
(91.11%). This is separate hosted evidence, not a union with local captures.

The subsequent artifact action failed because its default hidden-file filter
excluded the entire `.titan-coverage` directory. Consequently the CI Codecov
upload was skipped and no native Codecov report was published for this head.
The artifact step now explicitly includes hidden files within that owned
coverage directory; the existing workflow contract checks this setting.
Compiler coverage and Codecov readback for this run are recorded separately
when available. No local report was uploaded as a substitute.

## Measured compiler partition correction

CI run `37890691611` at `b32db0c88e214430f3484b186661bac94605d93b`
passed the stdlib producer, sanitizer, native coverage and compiler pair 1–2.
The retained native artifact independently verified 15,728 / 17,263 lines
(91.11%), 1,272 passed cases, three classified skips and all 28 owners.
Codecov processed that native upload and refreshed the PR report to 91.10%
as displayed by the service.

Compiler pair 3–4 reached its 45-minute limit, so the merger was skipped.
All nine native coverage CLI cases passed, but their file took 1,578.194
seconds rather than its stale 10-second partition weight. Its companion
shard finished almost 20 minutes before cancellation. The interrupted
`native_record_fields_spec.lua` case had no reported assertion failure.
Checks saying no compiler information was found do not establish compiler
coverage acceptance; a fresh complete upload remains required.

The exhaustive 152-file manifest now uses measured covered plus stress file
times from that run, with successful predecessor run `37887221316` supplying
unfinished phases over unchanged compiler and timed-spec sources. The same deterministic
longest-first, least-loaded assignment gives estimated group times of
1,578.194, 1,360.268, 1,360.268 and 1,360.267 seconds, excluding process and
preparation overhead. The costly CLI file occupies one group alone.
These are scheduling estimates, not guaranteed deadlines. All files, stress
oracles, fresh-process boundaries, two-worker concurrency, job budgets and
coverage thresholds are preserved.

The timing provenance is
`/tmp/titan-210-b32-codecov-readback/partition-timing-final-proposal.json`
(SHA-256 `c2da03d2a9c8cb04bce8d7b4f4c3684538b0d2eedf18772f2ef5cf905dc00217`).
The complete cancelled-run receipt is
`/tmp/titan-210-b32-codecov-readback/final-ci-readback-before-rebalance.json`
(SHA-256 `3be57530f1f014f1616158f27a33c33dcfbd8009f82da4c0f4e0e00170eed22b`).

## Current published CI and processed Codecov readback

[Run 37897065036](https://github.com/mascarenhas/titan/actions/runs/37897065036)
at `8609cfb17a00e50a6b752009cf1ce9d52362f265` completed successfully on
2026-10-09: all six jobs passed. The exhaustive compiler run observed all
152 manifest files, 4,267 passed cases, one classified Windows-only skip and
all 13 retained stress cases. The four shard durations were 1,460, 1,242,
1,495 and 1,409 seconds; both pairs completed within their existing budgets.

The independently audited native artifact contains 15,728 / 17,263 covered
lines (91.11%), with 1,272 passed cases, three classified skips, all 28 owners,
22 fresh counters, all 69 exact source identities and 419 link inputs. Its
schema-2 receipt records natural status zero, confirmed process-group emptiness
and no retirement. LCOV and normalized line data agree. Artifact `11602113075`
has ZIP SHA-256 `ae0d62ffa3343a088eb1983e0d7cb33161f3937769136507db9577729934dfe6`.

Codecov processed both current-head uploads. The
[official PR report](https://github.com/mascarenhas/titan/pull/213#issuecomment-6074228412)
shows 92.44% combined coverage. The official compiler patch check passes at
97.24% against its unchanged 90% target; independent exact-source CI-statistics
analysis measures 601 / 618 compiler patch lines (97.25%). The combined patch
adds the covered UV change: 602 / 619, with 17 misses. The green project check
explicitly reports no base coverage, so it does not establish a numeric
compiler-project regression comparison. Earlier no-head checks were not
accepted as compiler coverage evidence. The uncoalesced LuaCov text total
includes installed and checkout copies of the same sources and is not the
processed Codecov project result. The CI-statistics audit coalesces those
aliases using the same-head prepared-SDK contract; it independently retains
checkout source bytes, rather than extracting installed compiler sources from
the prepared-tree archive. Local reports were never uploaded.

Final readback receipt:
`/tmp/titan-210-8609-codecov-readback/final-ci-codecov-receipt-r2.json`,
SHA-256 `041444cf70e0f2510102a80065b1e6b97d32b2c49c3c248cdb3e0fcbb87d4963`.
The compact evidence archive is
`/tmp/titan-210-8609-ci-codecov-evidence-r2.tar.gz`, SHA-256
`468e3759034946abbb7c9f9a7ec1b8aa0d6c0b66451caf23fa33fadbd9033e00`.

## Windows LLVM-gcov follow-up

The follow-up adds an explicit native Windows backend using matching Clang/LLVM
22.1.8, native x64 CPython 3.14.8 and gcovr 8.4. Validation ran on the local
Windows VM in CLANG64/UCRT, with source, SDK and output directories on NTFS.
The measured provider contains all 22 production objects and 69 source
contributors; the ordinary aggregate retains all 28 test owners. Reports
measure executable lines only. Local runs do not upload to Codecov.

The final reporter is `6742d826b950659e73b876005728404c54c2867a4d2c53e4e3b4353d7ec270fe`.
Its frozen compiler/provider build used source inventory `2394256e4403d20adb0780aed90c292670aeec1fd74b9753795a8721ec5be0b0`.
The subsequent native fixture correction is recorded separately below; the
production stdlib, compiler, dependencies and measured objects did not change.

| Gate | Result and scope |
| --- | --- |
| Ordinary Windows installation | Make/LuaRocks install passed in 581.143 s; all 88 installed frontend/host files matched current source. |
| Current host regressions | Linux: 85/85 passed. Windows: six native source-path/template-byte checks passed without skips. Intel macOS: 75 applicable checks on the preceding `b130f32d` reporter, then the new template-byte check separately on `6742d826`. The explicit Bash 4 prerequisite skip excludes nine Windows shell stand-ins on Apple's Bash 3. |
| Compiler integration | Linux and Intel macOS each passed 12 backend and ten native integration checks at compiler `f507558e` and preceding reporter `5c31a6a2`; these are separate retained gates. |
| Windows EXE/DLL controls | Earlier installed `5c31a6a2` captures passed build, seal, capture, reports and additive merge. Ten fixture lines remained in scope, seven hit. Native controls covered selected tests, deliberate failure with retained diagnostic report, notes-only/missing-counter handling, formatting equivalence and ordinary uninstrumented output. |
| Full Windows build | Current provider and 28-owner consumer built successfully in 1,087.877 s; independent validation accepted all 22 objects/notes, 69 contributors and 17,263 executable-line keys. |
| Zero-selected diagnostic | Native status 0, complete collection and 22 counters; selected=0 correctly produced public audit/run/report status 1. All five raw template hashes and HTML/LCOV/Cobertura/normalized data agreed; 2,160 initialization-hit lines remained visible. |
| First full Windows run | 1,282 selected: 1,222 passed, 27 skipped and 33 failed. Product collection completed naturally with status 1, an empty job and all 22 counters. Reformatting the retained run produced 15,620/17,263 lines (90.48%) while preserving native/audit/report status 1. This is a failed-run diagnostic, not an accepted behavior baseline. |
| Corrected Windows reuse | 1,282 selected: 1,255 passed, 27 skipped (17 platform/ten capability), zero failed; all 28 owners audited. Product native/run/audit/report status 0, complete collection and an empty job with 22 fresh counters. HTML/LCOV/Cobertura/normalized data agree on 15,653/17,263 lines (90.67%). |
| Corrected child | One-child compilation against retained providers: Linux 2.099 s, Intel macOS 2.959 s. Both `closed-stderr` and `fatal-origin` passed with exact output on both platforms. Windows compiled the same child alone and passed both modes, each with native status 0, an empty job and 22 fresh counters. The 5,934 Linux, 3,534 macOS and 3,741 Windows retained input files remained unchanged. |

The first full-run failures identified two distinct setup defects. The private
verification harness forced `LC_ALL=C`; its `cygpath` export corrupted and
truncated the Unicode process-fixture pathname. Native Python, Titan and stock
Lua observed the same nonexistent inherited path. The exact sealed Unicode
executable existed and ran successfully when passed its correct path.
The same export under `C.UTF-8` preserved the exact UTF-8 pathname in all three
native readers, and both direct fixture launches passed. One previously failing
OS process test then passed with the unchanged manifest/aggregate/provider,
fresh counters and successful audit: one selected, one passed, no skips; native
status 0, complete collection, an empty job and 22 counters. All 3,741 retained
build files remained byte/mtime-identical. The UTF-8 and targeted archives are
`4e8178df8f5d9d6defe0362ee2196b775b02c01d113c33e36707d27523e45a3b`
and `b0520bcaa4657270b1b9485809939712852ed89ef97f40558d6aeef9a2c177aa`.
The targeted archive's index was generated before its outer stdout capture
closed; that one row has a stale size/hash. The complete archive pins the final
stdout, and every other indexed file and all sealed inputs matched. No test
rerun was used to replace the evidence.

The new closed-stderr child also assumed that `dup2` returns descriptor 2 on
success. POSIX returns that descriptor, while the Windows CRT returns zero.
The fixture now accepts a nonnegative result and still requires successful
closing of the saved descriptor. Its source changed from `e4fff5bb708f305b1ee77f8b18d2210f2404325115659b856ee6cfce020c67f6`
to `af957eb6e7e90a62aa12a9d69ab9934aa791099e8946b86fc2e93063246596b4`.
No production behavior was changed to accommodate the tests.

Iteration now retains the dependency installation, provider, notes and consumer.
Reporter-only fixes use an external updated reporter, the unchanged sealed
manifest/run and a fresh report directory; they require no compilation or test
rerun. Earlier reporter iterations unnecessarily rebuilt the provider and
consumer. For the runtime fixture correction, a new small cwd copy and manifest
record the one changed unmeasured fixture, while the original sealed build and
failed run remain intact. Every test run gets fresh counters; no
cross-platform or failed/successful counter union is used.

The preceding Windows attempts remain failed evidence. Capability probes first
exposed an incorrect repeated-line oracle: LLVM counts the deliberate
`3 -> 4 -> 3` mapping twice on line 3 and once on line 7. The corrected oracle
checks those raw counts. A later fingerprint rejection exposed Windows text
mode truncation at Control-Z; fingerprints now read complete physical bytes,
including authored CRLF source. Subsequent diagnostics exposed relative LLVM
source paths being resolved against the process cwd, and HTML template hashes
being calculated before Windows newline translation. The reporter now resolves
authored paths against the sealed source root and writes the same UTF-8 bytes
that it hashes. Native regressions exercise both fixes. Private stale CMake,
archive transport, path/mode oracle and controller-count mistakes were corrected
as verification setup issues, without relaxing product acceptance.

R30's original product job and its intermediate wrapper both completed naturally
with empty jobs. A separate enclosing scratch supervisor returned incomplete
status 125 after retiring one unidentified live member. The cause remains
unknown and that receipt remains failed; it does not identify a product-runner
ownership defect. Subsequent execution uses the product's own bounded Job
Object supervisor without that redundant nesting. All owned scratch reservations
were released; original build/source/SDK inputs remained unchanged.

The retained receipt/archive identities include: R30 failure `b4ae90e50781021c4bb83b3ed60626ecf0044dc5951f729388f381a78647f1eb`,
qualified closure `1c2a5dfd672936678d76681f6df56d08f377d30acedeb56bc5ad80ffe176b2d2`,
failed-run report archive `463efeda40da73dcf184e95497c15d9b50e26ccc53534df5cc62285a88792b57`,
and independent rendered-report check `906e4fc6458d71e0402822c3fa511688f714e00e4516ff04755814c87c1a3027`.
The corrected-child Linux receipt is `bdf87510200ac3bc95781223aefb8ba4eafa1644ae1c55eaffd455227909f22c`;
Intel macOS receipt `9becadff724a418c61e4a8eb7a330ceca01f95caa05e97b60798a972748a60fc`.
The Windows child archive is `273b2b5e5ce9d3f51e08e2ff643748036b323c73994cc5247b82715b1d8d2e15`.
Final Windows archive `5da60381de02fd41689b5c721156166d6e0813b668e7237e273bac9c2eff076d`, independent raw-counter/provenance/rendered-report receipt `29b2e5704670732d6bcca6659b8cd09501d44afb421f2781ce55ca1e73ec2181`, and independent root report check `22b3872b6ef53e1bcd9a95e96f254c551a794f3fceeccf180960853cb796c0d6`. The new manifest is `608caf01f14d267200badb8b92663ccc57971263c7ce1e2fe50f18c4486dd001`; all 3,811 original linked input entries remain unchanged, with 121 fixed cwd files and their list added. Operations completed at 17:54:34.145254 UTC; completion receipt `d3b5c1c2fdc43d07a68044c22194e9fb2aca4bc5d5dde6abd0e9b4f78dfdf0aa` confirms empty product and package jobs and no further guest calls.

The complete POSIX reports below predate the final collector changes and the
predicate-only child correction. Their source and tool versions remain distinct
from the later focused gates above. Intel macOS validation does not establish
Apple Silicon runtime behavior. Exact feature CI and processed Codecov evidence
is recorded on the follow-up PR after publication; base PR #213's `8609cfb1`
checks do not certify the follow-up commit.

## Follow-up high-level native validation (r14–r17)

The final 19 added native cases passed in the full 28-owner aggregate on Linux x86_64 and the local Intel macOS VM. The additions cover fatal-origin recovery, closed-stderr failure isolation, parent-stdin duplication/read-start failures, unknown signal exit status, writes after child exit, OpenSSL error-string fallback, six TLS late-writer schedules, both public process-spawn shutdown-admission guards, a valid empty locale conversion, synchronous parent-stdout write rejection, and preservation of the original TCP write-shutdown error during a lazy TLS handshake. The late-writer parent plus its six subtests count as seven selected cases; the other twelve regressions each count once. The earlier r14 capture covered the first 14 cases, r15 added the two admission regressions, r16 added the two OS behaviors in existing test/fixture files, and r17 adds one public TLS transport-failure regression. The locale case requires a positive native `[%p]` control producing exactly `[]`, preserves the C-locale `AM` control, and restores the original LC_TIME. The stdout case installs a read-only pipe endpoint in an isolated child, checks nominal `stdio.write`/`EPIPE`, restores fd1 before assertions, and verifies exact successful output in a fresh Runtime. The TLS case completes public TCP write-half-close before adoption, performs no raw I/O after adoption, asserts the exact original transport writability error from the lazy handshake, checks stable plain-TCP EOF at its peer, and verifies idempotent TLS retirement plus a later nominal `TLS_INTERRUPTED` write. Its peer has immediate cleanup registration and an explicit successful join.

| Platform | Ordinary consumer and audit | Fresh measured consumer and audit | Executable lines |
| --- | --- | --- | --- |
| Linux x86_64, GCC/gcov 16.2.1 | 1,294 selected: 1,293 passed, 1 platform skip; 28/28 owners | Same counts; complete schema-2 run | 15,780/17,263 (91.41%) |
| Intel macOS, GCC/gcov 14.4.0 | 1,294 selected: 1,290 passed, 4 platform skips; 28/28 owners | Same counts; complete schema-2 run | 15,740/17,263 (91.18%) |

Both use gcovr 8.4. “Ordinary consumer” means the unmeasured test executable exercising the retained bundled, instrumented r12 provider; it is not a newly rebuilt uncovered or system-OpenSSL provider. Separate earlier focused behavior checks passed with ordinary system OpenSSL 3.5.9. These follow-up gates do not replace the recorded compiler, packaging, or production-mode gates.

| Production module | Linux hit/total | Intel macOS hit/total | Windows hit/total |
| --- | --- | --- | --- |
| `async` | 1968/2008 | 1968/2008 | 1968/2008 |
| `coroutine` | 189/200 | 189/200 | 189/200 |
| `fs` | 393/453 | 393/453 | 396/453 |
| `gc` | 64/67 | 64/67 | 64/67 |
| `http` | 1026/1111 | 1026/1111 | 1032/1111 |
| `io` | 41/42 | 41/42 | 41/42 |
| `iteration` | 16/17 | 16/17 | 16/17 |
| `json` | 783/791 | 783/791 | 782/791 |
| `lua` | 135/144 | 135/144 | 134/144 |
| `math` | 236/237 | 236/237 | 236/237 |
| `net` | 311/361 | 309/361 | 313/361 |
| `os` | 805/870 | 778/870 | 769/870 |
| `path` | 106/180 | 106/180 | 173/180 |
| `peg` | 902/920 | 902/920 | 905/920 |
| `reflect` | 389/428 | 389/428 | 389/428 |
| `sqlite3` | 667/729 | 667/729 | 666/729 |
| `ssl` | 821/909 | 819/909 | 777/909 |
| `string` | 1647/1800 | 1647/1800 | 1699/1800 |
| `timer` | 82/91 | 82/91 | 82/91 |
| `url` | 172/173 | 172/173 | 172/173 |
| `uv` | 4277/4937 | 4269/4937 | 4096/4937 |
| `websocket` | 750/795 | 749/795 | 754/795 |

The Windows column is the separate final LLVM-gcov capture described above, with the corrected child fixture and unchanged production source inventory. The two POSIX platforms used the same source-only r17 snapshot: archive SHA-256 `13676f69510f842811c7d89a03326bd5f5436f07c59a61a4e3f4ca54e66a5f79`, source-inventory SHA-256 `b1b3cbbb205e3ab58b9d7117101d52fbfa229c5698f4067ba6b9f792e914b580` (1,174 authored files plus two snapshot metadata files). Relative to r16, it adds only `ssl/tests/drain_failure_test.titan` as a new native test contributor and updates its explicit stdlib/source-rock inventories; the fourth authored delta is the already completed r16 validation documentation. It adds no native fixture or aggregate link input. All 69 production sources and all 82 frontend/compiler/host files are byte-identical to r16 and r15. The r16 snapshot remains retained separately with archive `c2dd788c66499dfd0b1a126b568ea19eb867d55f459d7745e89bf78215045d61`, source inventory `c6e0cecbfddc5f1770de99e930117b1eb1e14d37cba296ab9c01fa569b95d1e7`, and 1,173 authored files. Its earlier inventory increase from r15 was the published core helper `spec/support/luacov_children.lua`; its native delta was exactly the three existing OS time/read-failure test and fixture files.

These full POSIX captures certify the exact host SHA-256 `4ac01a56ff4883c470af0eee3a5e403e26616fae422b02fa151cdc5e2e285121`; run receipts remain schema 2. Later Windows embedded-runner changes have a separate source and validation boundary. The fresh unmeasured consumers use the copied feature compiler/frontend, while the unchanged measured r12 providers retain their original compiler, object, notes and native-input provenance. Each platform kept its original provider/SDK/native inputs read-only, created a fresh consumer manifest and run-owned counters, and collected exactly 22 counter files. All 6,434 Linux and 4,034 macOS retained-file identities matched before/after. The production inventory remains 22 roots/69 contributors; all 17,263 source-line keys and their source MD5 values match r16, r15, r14 and r13. There was no counter union or denominator change. The earlier r15 source-rock inventory check passed 1/1. In r16 the focused calendar case and its output audit passed 1/1 on each platform, and the stdout regression passed its separate Linux ordinary/measured 1/1 checks and both full platform aggregates. The r17 source-rock inventory check passed 1/1, and its focused TLS case and output audit passed 1/1 without skips on each platform before the full ordinary and measured aggregates.

All 26 targeted previously-zero lines are covered on both platforms: async 642, 645, 792–794; OS 206, 889, 1031–1032, 1045, 1075–1077, 1087, 1164–1166, 1169, 1447, 1604; SSL 203–205, 581, 584, 885. The fresh r17 Linux capture gains exactly SSL 581 and 584, each with count 1, and loses no hits relative to r16. The r17 macOS capture gains those same two targets and naturally recovers seven timing-sensitive hits from its new execution: net 642 (1), SSL 822 (1), 828 (4), 829–830 (1 each), 831 (2), and 832 (1); it loses no hits relative to r16. These seven recoveries are not attributed to new semantic test coverage. The separate r16 capture still records all seven as lost from r15. Its exact losses and original counters remain unchanged: no historical counters were combined to restore them. SSL 1682–1683, already zero in r15 and r16, remain zero in r17.

Linux's single skip is the POSIX eight-bit process exit-code boundary. macOS additionally skips three Linux seccomp metadata-denial fixtures. Its 27 additional OS zeros are exclusively in the parent-stdio metadata/hint classification region, lines 1183–1264. Async hit sets are identical. In r17, macOS additionally leaves SSL 1682–1683 and net 502–503 zero. These platform distinctions and timing-sensitive misses remain in the public denominator.

The requested high-level near-total coverage is **not achieved**: async is 1,968/2,008 (98.01%, 40 missed), OS is 805/870 (92.53%, 65 missed), and SSL is 821/909 (90.32%, 88 missed) on Linux. macOS records OS 778/870 (89.43%, 92 missed) and SSL 819/909 (90.10%, 90 missed). The separate final Windows capture records OS 769/870 (88.39%, 101 missed), SSL 777/909 (85.48%, 132 missed), and UV 4,096/4,937 (82.97%). The remaining gaps include:

- **Async:** four `ChannelReader:read_until` EOF-before-delimiter lines (1469–1472) remain unproven. The completed separate public-close probe passed its behavioral assertions but left all four lines zero: ordinary channel closure raises from `receive`, while an already closed reader returns at an earlier guard. No ordinary deterministic public route to those tails was established. Other zeros include suspension-epoch exhaustion, Lua stack/resource failures, stale-settlement and continuation invariants, and runtime-registration cleanup catches. This review does not claim all other zeros are unreachable.
- **OS:** 19 missed anchors are explicitly Windows-only descriptor adoption, shell construction/arguments, and process flags; another nine are authored Titan sentinel-error conversions fed by native Windows helpers. Remaining groups include metadata-probe/hint failures and rollback/escalation (1639–1654, 1685–1687). The closed-child EPIPE regression covers asynchronous completion failure at 1087, while the r16 read-only-stdout regression now covers synchronous rejection at 1075–1077. Both public shutdown-admission guards (1447, 1604) and the valid empty conversion (206) are covered. The 30-second rollback escalation is deliberately not exercised by this follow-up.
- **SSL:** zeros include 14 anchors naming optional/disabled engine outcomes, native configuration/PEM allocation or postcondition failures, partial-write guards when partial-write mode is disabled, and saved-failure rethrow tails. The original transport-write error rethrow at 581/584 is now covered, while other transport/supervision error paths remain. Two separate public scheduling probes passed exact `TLS_INTERRUPTED`/`ssl.write`, joined Task ownership, and a fresh binary TLS/EOF companion, but left 324 and 488 zero. Ready-child cancellation and native-wait cancellation explain those tested schedules; this does not prove every possible route unreachable.

Windows retains a platform skip for the no-error-strings child: the current static initializer would execute inside a DLL constructor on Windows. A safe future test adaptation can explicitly call documented OpenSSL initialization from a fresh Lua process after DLL loading, before the Titan module entry. That route could exercise SSL 203–205 without private TLS state or error-queue manipulation; it has not been implemented or verified, so the skip and zeros remain.

A separate public UV peer probe reaches SSL 582 on Linux by submitting a malformed empty ServerHello and resetting TCP in the same callback. Its original measured execution and three fresh reset repeats preserve `SSL_ERROR_SSL`/code 1/`ssl.handshake`; an executed no-reset control preserves the same TLS cause and receives the TLS alert without entering the drain-error catch. The four Linux reset outcomes do not establish portable TCP data/RST delivery. The probe remains private and its counters are not included in either complete report. No post-adoption raw transport operation was used.

A private real OpenSSL allocation probe reaches chain-install failure at SSL 1314–1315 with the existing unchanged one-shot allocator fixture and successful same-port recovery. Linux bundled 3.5.7 requires stack-allocation ordinal 176, while system 3.5.9 requires 173; the bundled ordinal fails its intended contract in system mode. This configuration-sensitive scenario was not integrated. Its diagnostic counters remain separate from the full reports, and no platform identity mechanism, new production hook, or fabricated error queue was added merely to raise the metric.

The classification is diagnostic only. A recursive parse of the exact measured sources found no source-defined foreign-native function bodies, including nested expressions: all 111 anonymous functions use ordinary Titan `ExpFunction` bodies; foreign AST nodes here are imports/types/allocation expressions. Every remaining zero maps into an authored Titan function, method, or initializer. Guards around native APIs therefore cannot be removed from the denominator to present a stronger high-level percentage. The exact r17 Linux function grouping is retained in `/tmp/titan-210-highlevel-r17-function-gap-classification-20261009.json`; the separate r16 grouping remains unchanged.

The first r14 setup failures remain preserved: incomplete macOS public-header include selection, an accidentally instrumented standalone C fixture rejected as an extra counter, and Darwin's unavailable imported `signal` member. The final gates use the matching complete public-header layout, an unmeasured standalone fixture, and the approved fresh-exec SIGALRM default-disposition fixture. The Windows descriptor-limit stubs and SIGALRM correction are included in the snapshot. The first r15 link on each platform also preserved a private-harness error: adding the child-only SQLite fixture object to aggregate `-X` caused unresolved SQLite symbols. The corrected r15 link restored the exact previously passing three-object aggregate payload using only the identical objects just compiled in the private tree. The fresh r16 and r17 builds use that three-object payload directly and require no compile/run retry. An r16 source-freeze preparation initially omitted the nested skills submodule; the diagnostic snapshot was preserved and corrected before any build or upload. These behavior regressions change no production stdlib or native-library implementation source.

macOS r17 was released at 08:36:54.643064 UTC, before its 08:45 deadline. Final r17 evidence: Linux receipt SHA-256 `ec284999925f48ab984f3806d0250f2b1e5b7b36b6279aa619d68bf812305d4d`, archive `13b8316e878c5abfa45d1a1d26c846d88fe9069dca97ad8cab63dcf1084028d7`; macOS receipt `ace1c3b93b389c4e7a6a5062a8c71d934934ce8d564f39178f5b598d5507902f`, archive `2cc62f8eb6ed9d6b78f0b87135e0159c2e4fbb89b790fc868a217ce61dcdbc8f`. Exact counts, line deltas, module gaps and local paths are in `/tmp/titan-210-highlevel-r17-final-comparison-20261009.json` (SHA-256 `e0affb5fab79f2a1186b1fd26ed2950938469861909ba11a4863dbc7fb8ebc87`). Local HTML reports are `.titan-coverage/issue-210-final-highlevel-linux-r17/coverage.html` and `.titan-coverage/issue-210-final-highlevel-macos-r17/coverage.html`.

Historical r16 evidence remains unchanged. macOS r16 was released at 08:03:54.274347 UTC, before its 08:10 deadline. Its earlier r15 release remains recorded at 07:04:31.765989 UTC and r14 at 06:27:18.423 UTC. Final r16 evidence: Linux receipt SHA-256 `2887aa4d7ab5c35928d2fc76e74bd34c244c5c4c1f11b67789b33b6893a68943`, archive `39ffb97d974377ae1b62ea3a3d53f67afd12911e477a65e780fa1cbaa2c25219`; macOS receipt `ed0a0736968a0dcfe00ccda4173cf93530173c2fbd63082170bddb3164c4b32e`, archive `19c87102b393ac8775ac8377d47a846eb140e63bc0ac474eecfd50b203fb7b98`. Exact counts, line deltas, module gaps and local paths are in `/tmp/titan-210-highlevel-r16-final-comparison-20261009.json` (SHA-256 `bdd5b2d2b84a95a29155d7219522992fe43c52f7faae019ae61d3f4efc1624ad`). Local HTML reports are `.titan-coverage/issue-210-final-highlevel-linux-r16/coverage.html` and `.titan-coverage/issue-210-final-highlevel-macos-r16/coverage.html`.

Historical r15 evidence remains unchanged: Linux receipt `3cf51ff8a8c17810f645c0f58126f7deed7903600de38f2be360738833c9313d`, archive `d0b2325fa3c17ce4c423968a2acbbd2d4219aa7cb818d6f2c5fcf4be3023bcf9`; macOS receipt `f275119dde355354e9553ba1e256b4995f5e0a62914bc68cd4ae72e660a53d97`, archive `34728873cf9366edb77b2eb7d9b9a0092ef816b051c01476e5ddce8211efce08`. Its exact comparison is `/tmp/titan-210-highlevel-r15-final-comparison-20261009.json` (SHA-256 `d126589ebf370ea611edf82234b7b057a8600c6adcdcd196018293368fb2c410`).

Historical r14 evidence remains separate and unchanged: Linux receipt `1d5e606c46ca3a0e609542ad3fdf87f6eca5d919f19c9caa3f130f7d8c0dd3d7`, archive `51a5eb60261da7a001d4cc83aea8fe49e158194809ced13fc5f2c486f98930c9`; macOS receipt `5c849bed6ff224e9b1c73892af7e81551f6a6b7d2cd5f9f77e03f9c85f31eca2`, archive `71b7ebbab4c735430e45f024cfb39586b9602fc31eed9e04393a9126e4e67090`. Its exact comparison remains `/tmp/titan-210-highlevel-native-final-comparison-20261009.json` (SHA-256 `6a8e9540ba804d176eee9beb3008a465f7a4b5c657e8bd9b6951ad31b48e6528`). The diagnostic channel/admission probes, which are outside those full captures, retain `/tmp/titan-210-public-gap-probes-20261009/final-receipt.json` (SHA-256 `95008e86d113ea799e45d2cdd8f8c9e04d12338acdf4215c5e7649e57ca1bb6b`).
