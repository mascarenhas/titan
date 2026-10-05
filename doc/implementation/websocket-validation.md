# WebSocket validation

This records issue #193 validation on 2026-10-04. Results apply to the source
and artifacts identified below. Titan remains 0.6.0 with ABI 2; no version marker
was bumped.

## Source and provider boundary

The final production boundary is
`2bf8aae5cdb599173cfd67a640209840a7a81e1f`. It adds the ordinary CONNECT
classification correction to the independently reviewed production source:
`titan/http/server.titan` SHA-256
`45537a628d269d05d68ac32127d477d44b8f0ce176cb7bdf7cdae0508e37dbfe`.
Subsequent native-pressure changes are test fixtures, not production changes.
“Final5” is the frozen regular-provider receipt label, not a Git revision.

| Artifact | SHA-256 |
| --- | --- |
| Final5 Linux `titan.so` | `ba0e5cdfcb6124dcbdd88ff40d18d26b6153311763b7a63999d3d4d98ceea4c1` |
| Final5 Linux `titan.a` | `78e462767fe6af88f614b31c9aa3a037b601749e66661a4217105c32bac85c71` |
| Optimized Linux bundled-OpenSSL `titan.so` | `cb88f24deda64f754538f89878fb8edee7726711d9987571df4180c1ce8db176` |
| Optimized Linux system-OpenSSL `titan.so` | `5438086221d9605c620cdd3eb7af9d73214e0c31b10e0480a585a035846a28f0` |
| Independent ASan/UBSan `titan.so` | `4ce203d79b11a8f7357e618397270a243887a37c9cbd96bb2339a037b24039ae` |
| Full Linux native aggregate, final pressure6 fixtures | `43634428ca04700579251f4bd91a18afe828b89715e1706e87cebd70f2d0c48d` |
| ASan/UBSan aggregate, 8f06394 fixtures | `8a8c7ec80b0bc5aed37c397a5293ee1e7934bbe2a492a2faf396f7e26cf108bd` |
| ASan/UBSan aggregate, pressure6 fixtures | `21d67d15265cc76b95f330644a45ccb9c7fdd99f112a982088380abb2eead7a3` |
| macOS Intel aggregate, pressure6 fixtures | `fe6c77aa023913d899d35b6edbc5cd4a67975009fe8f9b938546236eda53991a` |
| Windows O0 launcher, pressure6 fixtures | `6aaf12845d34fc2a94b0168d18f2315957a2868ac78c732e7d89c9e0da594857` |
| Windows O3 launcher, pressure6 fixtures | `58c38d6e028ae3d29df2fc580ddc7e3c27935de9018af8d9ed1da0051ae8aa5b` |

The final5 integration receipt audits five prefix keys, 98 production sources,
46 generated C/object files and 15 native inputs, with exact compile argv.
Conformance checked these identities before and after execution. Optimized
production-mode receipts separately identify their source corpus, provider and
archive; each mode's provider hashes remained unchanged through its smoke.
Different build policies produce different provider bytes.

The final full Linux native checkpoint uses fixture revision
`8ec7d95e48d41f6f5afa344ec2e53534a7adf70e`. Its 27-root Make DAG and
complete 960-case native run passed with the same one documented platform skip.
Earlier b56, 8f06394, pressure4 and pressure5 checkpoints remain preserved as
history. Only native fixtures and their header dependency changed after the
production boundary.

The final Linux receipt is `linux-final5-pressure6/receipt.json`, SHA-256
`4dd5df3b2b45f1789060c99cc7e4c9ee4baf3e561c021fb90c99c1b8662f6e39`.
It preserves the passing executable, all 100 native test C/object files,
1,021 tracked working-source files and original log, SHA-256
`c65612b1c20577b1c36ed35d295e9e1de8843032895189692dc06a69696115a1`.
Copy and closing checks verified all 98 production-source digests and five
canonical ready-final5 prefix keys. The prefix was read-only during execution,
persistent probe caching was disabled, and preservation invoked no build or test.
The tracked snapshot includes separately recorded documentation edits; native
inputs are pinned per file and no later documentation commit changes them.

## Validation gates

| Platform/gate | Result and scope |
| --- | --- |
| Linux x86_64 retained runtime/packaging | 158 passed; eight retained Busted files. |
| Linux x86_64 compiler/language | 3,833 passed across four private compiler shards. |
| Linux x86_64 full native, final5 + b56 fixtures | Historical checkpoint passed: 960 selected, 959 passed, one documented platform skip, zero failures; all 27 roots selected. |
| Linux x86_64 full native, 8f06394 fixtures | Historical checkpoint passed: 960 selected, 959 passed, the same documented platform skip, zero failures; all 27 roots selected. Log: `/tmp/titan-193-full-linux-native-pressure2.log`. |
| Linux x86_64 full native, final pressure6 fixtures | 960 selected, 959 passed, one documented platform skip, zero failures; all 27 roots selected. Original log: `/tmp/titan-193-full-linux-native-pressure6.log`; immutable source/artifact receipt identified above. Earlier pressure4/5 runs passed and remain preserved. |
| Optimized Linux, bundled and system OpenSSL | Both complete production smokes passed, including archive-backed consumers with the DSO/shims hidden; system SDK/layout and external-DSO promotion canaries 2/2 passed. |
| Independent Linux ASan + UBSan, 8f06394 fixtures | Historical checkpoint: all 27 native roots compiled; 33 nonempty audited focused families, 134/134 cases passed, zero skips and no sanitizer diagnostics. |
| Independent Linux ASan + UBSan, final pressure6 fixtures | Complete 27-root Make DAG and new aggregate passed; the two affected families passed 15/15 and 5/5, zero skips or sanitizer diagnostics. The 114 unaffected cases in 31 families retain their earlier aggregate/source receipts. This is focused lifetime coverage, not the complete sanitizer behavioral suite or one uniform final-aggregate run. |
| Local macOS 15.7.7 VM, Intel x86_64 | Retained tests 154/154; compiler/language 3,832 passed and one skip; optimized bundled and system OpenSSL production smokes passed. Final pressure6 focused 20/20 and full native 956 passed, four platform skips, zero failures; all 27 roots selected and no WebSocket skips. Earlier failed artifacts remain preserved without rerunning. This does not establish arm64 runtime behavior. |
| Local Windows x64 VM, build 26300, CLANG64/UCRT on NTFS | Optimized and `-O0` provider builds/publication, rollback and PE-import checks passed. Final pressure6 focused 20/20; complete `-O0` and `-O3` native runs each passed: 960 selected, 932 passed, 28 documented platform/capability skips, zero failures; all 27 roots selected and no WebSocket skips. Earlier pressure4 complete runs passed in both modes and remain separately preserved. Owned process and scratch cleanup passed for the focused run and both complete runs. |
| Linux amd64 Autobahn | 602 selected uncompressed cases passed, 301 in each Titan role; strict message and Close-result checks. |
| Allocation/lifetime matrix | Final R1 strict-peer rerun 272/272 plus 125 preserved unaffected rows form the accepted 397-row runtime receipt: exact Lua ledgers and release of all 368 tracked endpoints. The 24 session and five no-connection rows have empty weak slots. Separate held-endpoint multi-GC diagnostic 8/8 completed. Independent allocation-report review passed. Background-qualified timing completed 16 pairs; 2/16 met the duration requirement in both lanes. All 16 finite fairness profiles met their sample/duration/capacity checks; independent timing/fairness quantitative review passed. |

The Linux native skip is
`os.process_tests.test_native_exit_codes.nine_thousand_nine`: POSIX process exit
status contains only eight bits. The macOS compiler skip is the documented
default-LTO Linux-only oracle at `spec/coder/lto_spec.lua:104`. Mac native skips
are the same POSIX exit case plus three Linux-only seccomp stdio-denial fixtures:
`uv.runtime_tests.test_parent_denied_unix_stdio_uses_only_valid_per_fd_pipe_hints`,
`test_parent_partial_metadata_denial_preserves_socket_contradictions`, and
`test_parent_stdio_denial_renders_operation_error_fields`.

Windows has 15 unsupported symbolic-traceback cases, 10 Unix-only platform
fixtures and three capability skips (two `/dev/fd` descriptor-inventory checks
and one symbolic-link privilege check). The exact 28-case list is retained in
the final Windows receipt's `skip_inventory` field and the consolidated
receipt's `windows.skip_inventory` field; the inventory is identical in both
native build modes. No portability or WebSocket cases were skipped.

Linux production uses GCC 16.2.1 on x86_64, ordinary generated-code
`-O3 -flto=auto -ffat-lto-objects` and native `-O2`/Release policies. The two
OpenSSL modes are bundled 3.5.7 and system 3.5.8. The Mac run uses GNU Make
ahead of Apple Make and separately built Mach-O artifacts; Windows uses its
separate native build/output tree and controlled Lua DLL/SDK.

The Mac retained gate records source authority `e1ab1940`; compiler and both
production smokes record `c8409fd1`. Their receipts retain the exact original
overlay tree identities. Later native-fixture and header-prerequisite changes
did not change the production/compiler source or phase scripts, but the earlier
retained gate is not presented as testing those later Make-manifest bytes.
The final native overlay uses authority
`8ec7d95e48d41f6f5afa344ec2e53534a7adf70e` over setup `4722c130`, with
1,019 actual inputs and tree SHA-256
`c65074d6749483a9a78d67946a21e2d68e686e9f724a13978f28d7dce2e6e227`.
This is a recorded prepared-source overlay, not a claim that the whole branch
commit including later benchmark/conformance/documentation files was checked out.

The real Mac archive proof compiled x86_64 and arm64 Mach-O metadata objects,
created a universal archive with `lipo`, selected and repackaged the host slice,
and executed a source-free static consumer on Intel. That does not execute arm64
code. Before both optimized OpenSSL smokes, the runtime archive/config, provider
pair, all 22 shims, canonical test-support source and dSYM were restored with
content, mode and mtime equality against the saved manifest, SHA-256
`dd9d77b1bdfb67e23dc36b57d8ba1cbc1c2b159aebb71984792cf947eb39ec37`.
Mac OpenSSL modes were bundled 3.5.7 and system 3.6.5. The supplemental receipt is
`macos-completed-independent-gates-receipt.json` in the VM evidence directory,
SHA-256 `7fbbb6228b82e4b5af85abd54b591459012d62d72e122badf3e9d51d4a149c67`.
The final Mac native receipt is `macos-pressure6-pass-receipt.json`, SHA-256
`1e2d7380471a088d44259531cc41c6dc21f7fb1c6e48928e17be10436a30d410`.
It preserves all 1,019 source inputs, the new executable and complete artifacts.
Its separate live-SDK checks verify the native bundled provider/archive/runtime
before and after execution; archive integrity checks are recorded separately.

The final Windows native receipt is `windows-pressure6-pass-receipt.json`,
SHA-256 `3bb79c4e2289fc794fc354ada007a3a9abfd2a501ac54c4cb113acc8db10680b`.
Both modes use the same 1,019-input prepared-source overlay and authority/tree
identified above. The source archive and both passing output workspaces were
copied and verified; the new launchers, final PE checks, phase exits and owned
cleanup are recorded separately for each mode. The O0 provider remains
`edc6d540066cbe9288b8253bedff6e90427c3f67b2dc3ff36a6aa5e9c5d4da98`;
the O3 provider remains
`6fca75ec21e4998bc92bd4d8aa0811aae992c1340aae79d52e2bfd2f89aaed66`.
The consolidated VM receipt is `vm-receipt-pressure6-final.json`, SHA-256
`4201bf5c4145ba722a5a096f2fd6df69248b910cb5b0526ed20debe153273299`.
It retains the separate source attribution for earlier Mac compiler, packaging
and production-mode gates. The final Mac native DAG reuses valid prepared
objects; Windows freshly compiled all 27 native roots in each mode.

## Sanitizer provenance and corrected fixture evidence

The sanitizer independently built Lua, libbacktrace, libuv, llhttp, SQLite,
bundled OpenSSL and the Titan runtime/provider. It consumed no ordinary
prepared-tree provider. Native payload/Lua use `-O1` instrumentation, generated
Titan/runtime and fixtures use `-O0`, and ordinary `#line` attribution remains.
The flags, ASan/UBSan options and capture/snapshot policy match the sanitizer
recipe in [ci.yml](../../.github/workflows/ci.yml).

Its exact source overlay is base
`4722c13006b0f9573795e7d5cc36a3c098e898d1`, the three committed 2bf8 build/HTTP
paths (`ci.yml`, `spec/libuv_build_spec.lua`, `titan/http/server.titan`), and the
three committed 8f06394 helper paths (`backpressure.titan`,
`backpressure_test.titan`, `fixtures.titan` under
`spec/stdlib/titan/websocket/tests/`). The pressure4 recheck adds only
`backpressure.titan` and `backpressure_test.titan` from
`df7a5677e7693f47aadbe42a32516844df73fd49`; `fixtures.titan` remains unchanged.
Pressure5 then adds the test-local native header and its Make prerequisite;
pressure6 changes only `backpressure_test.titan` to derive the priming release
budget from its frozen admitted chunk count. The final prepared manifest has
1,019 inputs. All 98 production-source digests and 11 recorded instrumented Lua,
runtime, native archive and provider inputs matched before and after each
recheck. Complete prepared-source and WebSocket native-source manifests remain
separately attributed to each boundary. A private SSD
`/tmp` binding avoids host tmpfs quota pressure; matching Fedora sanitizer
libraries and Readline development headers are a recorded read-only SDK
overlay, not a host installation.

The original failed binaries/logs remain preserved. Those strict fixtures
exposed excessive kernel-accepted backlog and cancellation arriving after the
opening timeout under instrumentation. Corrections constrain initial TCP
windows before SYN, require observable pending native output, forward natural
relay EOF only after draining, and separate the cancellation lane's 4-second
opening budget from the timeout lane's unchanged 1-second budget. The 5-second
opening and 8-second stalled-output watchdogs, exact cancellation reason,
masking, single-Close and pending-output assertions remain. The corrected
8f06394 families passed 15/15 and 5/5; the other 31 successful families retain
their original receipts because their exercised source and provider did not
change. This is validation after a specific fixture correction, not a lucky retry or
evidence of production flakiness.

The Linux-passing 8f06394 pressure precondition did not pass both VM kernels.
Their focused failures remain preserved and are not counted as completed native
validation. Pressure4 uses a bounded ordinary HTTP response on the same
connection before the pipelined Upgrade, sustained public write-queue evidence,
and bounded raw peer reads. It verifies priming retirement before allowing the
101, so the later pending output belongs to the opening response. Independent
static review accepted its ownership/cleanup amendment; the fresh ASan/UBSan
aggregate passed all 20 affected cases. Windows pressure4 completed both native
modes; Mac pressure4 failed five focused cases, preserved without retry.

The pressure4 sanitizer receipt is `pressure4-sanitizer-receipt.json`, SHA-256
`43137c635bf20d3c82d1702f97cd96a901a1e9a21273ae5ba1d4e4a2b1d129db`.
The old passing aggregate, complete source archive and logs were copied and
verified before replacement; both passing boundaries remain preserved. The
new 20-case receipt and earlier 114 unaffected cases retain separate source
and executable identities.

The final pressure6 sanitizer receipt is `pressure6-sanitizer-receipt.json`,
SHA-256 `9742ca45811f82d56da4d33f241d8ea9ef027fdb92e2cb066be177283762cdae`.
The complete 27-root Make DAG reused 44 unchanged native test objects and
recompiled the changed WebSocket object, then generated/linked a new aggregate.
Both affected families passed again (15/15 and 5/5), without skips or diagnostics.
Persistent probe caching was disabled and ordinary source-line attribution
preserved. Earlier successful and failed artifacts remain distinct.

Mac pressure5 applied and queried its connected socket MSS clamp and enabled
public TCP nodelay. All stopped-output cases passed, including the post-Close
public-status acknowledgment and 250 ms observed positive exact-client queue
with the original writer still waiting. Its four opening cases failed during
priming setup: roughly 320 KiB of admitted body exceeded the independent 256 KiB
drain ceiling. The first failed program, complete source and SDK were preserved;
it was never rerun. Pressure6 freezes the admitted count before releasing the
pending chunk and derives a conservative fixture wire budget, bounded by the
original 2,048-chunk ceiling to 10 MiB plus 64 KiB. Native read steps remain at
most 1 KiB with a 100 ms timer, and the 8-second setup watchdog is unchanged.
The suspended Upgrade handler prevents these reads consuming 101 output;
closed-response, frozen-count and queue-zero checks acknowledge priming retirement.
Independent source review accepted the amendment. All original output deadlines,
masking, one-Close, exact terminal error/cancellation and no-transfer assertions
remain; the final Mac focused and full native gates passed.

## Conformance, allocation and review limits

[Conformance measurement](../../spec/conformance/websocket/measurement.json)
records the accepted final5 run. Autobahn 25.10.1 is pinned by image digest and
source revision in [pins.json](../../spec/conformance/websocket/pins.json).
All 301 base case IDs execute per role; only the exact 216 compression cases
in groups 12/13 are excluded. Both `behavior` and `behaviorClose` are checked;
only the pinned three informational IDs per role are accepted as informational.
The report/orchestration harness tests passed 28/28, including false-green,
deadline, child-exit and owned-process cleanup cases.

The accepted run took 68.287 seconds on a busy host and produced 22.529 MB of
evidence before archival. Its archive SHA-256 is
`765f0c6ac19434ea38b93d3669e5ed1861eea51280e6035dffdfe74687c6d842`.
These measurements justify the documented 600-second case, 900-second role and
100-MiB evidence ceilings; they are not quiet benchmark results. This gate
does not make native Windows/macOS, arm64 or verified-WSS conformance claims.

The original preliminary 397-row allocator receipt remains preserved as
`allocations-1791101775010029792.json`, SHA-256
`38ad2fbd4217be0d1e5e40edaddc2c31541ade493e2161da199c58c12a1287c9`.
The intermediate B1/B2 combined receipt remains preserved with SHA-256
`e0ab35c0da2e06625185853b38f433d71ff9e70ad231a1d9e22a8ca87c81e481`.
After R1's control-marker correction, the final strict-peer target passed
272/272 rows with zero ledger discrepancies. Adding
the 125 unaffected original rows yields the accepted runtime matrix
`build-final5-r1/ACCEPTED-COMBINED397.json`, SHA-256
`95c9e7817a8cfc2f760b3b9de60ee5003206e1880ff24578d2354282a3343c9d`.
Root independently verified that receipt. Per-row provenance is retained;
the combined matrix does not claim one uniform harness revision.

Independent B1/B2/R1 static review closed the partial-EXTRA-frame validation,
sampler-cap calibration and invalid control-marker findings with no further
findings. Root's 16 host harness regressions passed against the exact peer,
runner, measurement and test sources committed in `380f7501`. Two real-native
wrapper checks remain harness-author runtime evidence. This accepts the matrix's
runtime/accounting completion. Independent allocation-report review checked the
397-row accounting, weak-slot qualifications, operation slopes and held-root
measurements. Timing and fairness then ran in one explicitly background-qualified
window; their independent quantitative report review passed after the sampler-capacity
wording amendment. The exact report SHA-256 is
`2270ae9a6c0cf73107f6bea39980ef59a59b479e8dfea2008b3c00b2696e30ed`;
the amended README SHA-256 is
`cb810e67bc6259692d39c8843dfbd12ce61c737e30ba2494ab2c29427a4392ce`.

The separate eight-row held-endpoint diagnostic completed with the endpoint
strongly held through three collections, then absent from its weak table after
release and settling collections. First-GC growth of about 69–154 MB drops on
the second/third collections to about 1.9–2.0 MB of actual total Lua heap:

| 1,000-read workload | Third-GC held heap | Third-GC 1,000 minus zero reads |
| --- | ---: | ---: |
| WS client | 1,896,223 B | 9,144 B |
| WS server | 1,961,735 B | 74,680 B |
| WSS client | 1,962,002 B | 73,584 B |
| WSS server | 2,027,618 B | 139,120 B |

Independent review of the relevant retained-root paths, with all 98 production
digests verified, found no closed endpoint chain of completed-operation history.
Lua 5.5 marks finalizable coroutine owners and their callback/thread/record
uservalues through the first
collection; captured WebSocket Work results and TLS operation data can survive
that cycle and become reclaimable on the next. The held-root measurements
support that mechanism for these workloads. They do not numerically identify
every surviving byte, demonstrate zero retention, or establish universal memory,
queue or starvation bounds. Later samples are actual heap measurements after
allocator restoration and diagnostic-result allocation, not hook-ledger or
timing measurements. Their receipt is `HELD8-MULTIGC.json`, SHA-256
`cb5150112d6633e55f79a69ee383abfb954604a974bc55366079cae548aefb9f`.

Quantitative tables and their reviewed accounting limits are recorded in
[WebSocket allocation results](websocket-allocation-results.md). The separate
[timing and fairness observations](websocket-benchmark-results.md) record 16
paired timing profiles and 16 finite fairness profiles, with 556 successful rows.
Only two timing pairs had every repeated interval in both lanes at least 250 ms;
short lanes are insufficient for robust comparison. All fairness profiles met
the finite sample/duration/capacity checks without truncation. These observations
include external-peer and sampling overhead and establish no scheduler bound.

The background-qualified run completed in 610.90 seconds with both VMs running;
`quiet_host_proven=false` and `host_quiet_claim=false`. Its completion SHA-256 is
`f49a2b8126e40a02e44fd72fd0b526bf78ade8789f978bf37a83f8df23dc63a6`,
and the complete row-export SHA-256 is
`eb99f64f8973c7c7910fa7cbff0d25a044dd19ae803602ec4a98555eac574260`.
The wrapper checked the unchanged original 1,618-entry prefix inventory and the
recorded 164 production/generated/native/prefix-key identities. Earlier attempts
stopped before any rows: one on QEMU activity, one on nine added cache records.
Exactly those nine additions were preserved and removed, and the complete
original prefix fingerprint was independently verified before the fresh run;
no acceptance baseline was rebased. No VM was paused or host setting changed.

Independent frozen-source review covered WebSocket framing/opening/terminal
state, HTTP handoff and rejection, net/public async ownership contracts, and
TLS duplex/retry/native-request retirement and adoption. All nine reported
findings and three additional accepted corrections were checked in the final
source amendment; the later CONNECT classification change received a separate
amendment check. Human WebSocket examples and the tailored programmer skill
were checked against source/bootstrap contracts. Static review does not itself
establish runtime correctness. The allocation and timing/fairness quantitative
reviews, including the status and sampler-capacity wording amendments, passed
independently.

## Reproduction and local receipts

Use a clean private prepared-source snapshot, for example
`/tmp/titan-websocket-validation/source`, separate from the shared checkout.
For the snapshot helper, its absolute prefix must be physically inside that
prepared workspace; run the commands below from the private copy. Follow
[Windows build](windows-build.md) for CLANG64 and
[WebSocket conformance](../../spec/conformance/websocket/README.md) for pinned
Docker prerequisites and strict report rechecking. Canonical Unix gate commands
are:

```sh
unset ROCKS_TREE TITAN_ROCKS_ROOT TITAN_EXTRA_CPPFLAGS TITAN_NO_LINE_DIRECTIVES
unset BUSTED_FILTER TITAN_FILTER
unset TITAN_EXTRA_CFLAGS TITAN_EXTRA_LDFLAGS TITAN_PATH TITAN_PATH_0_6
unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5 LUA_INIT LUA_INIT_5_5
export PREFIX="$PWD/.validation-prefix"
export PATH="$PREFIX/bin:$PATH"
make lua
make luarocks
OPENSSL_MODE=bundled "$PREFIX/bin/luarocks" make --force
"$PREFIX/bin/luarocks" test --prepare
make stdlib-busted-test
make titan-stdlib-test-build
make titan-stdlib-test-run
export TITAN_VALIDATION_ARCHIVE="$PWD/.validation-stdlib.tar"
bash spec/support/ci_stdlib_snapshot.sh save "$TITAN_VALIDATION_ARCHIVE"
bash spec/support/ci_test_groups.sh compiler-uncovered
bash spec/support/ci_stdlib_snapshot.sh restore "$TITAN_VALIDATION_ARCHIVE"
set -o pipefail
OPENSSL_MODE=bundled bash spec/support/ci_dependency_mode_smoke.sh bundled 2>&1 | tee bundled-smoke.log
OPENSSL_MODE=system "$PREFIX/bin/luarocks" make --force
OPENSSL_MODE=system bash spec/support/ci_dependency_mode_smoke.sh system 2>&1 | tee system-smoke.log
```

Complete native/runtime/packaging gates before compiler tests. On macOS the
snapshot/restore preserves the canonical provider pair, dSYM, shims, test-support
source and Make-owned runtime archive before both production-mode smokes.
Keep production optimization defaults for both mode smokes. Sanitizer preparation
requires its complete independent CI native-build environment; reuse the
aggregate for fresh filtered processes, without trailing `$` when a parent
registers deferred child cases. For example:

```sh
bash spec/support/ci_sanitizer_capture.sh websocket-backpressure \
  make titan-stdlib-test-run TITAN_FILTER=test_stopped_socket_output_aborts_before_native_drain
bash spec/support/ci_sanitizer_capture.sh websocket-opening-abort \
  make titan-stdlib-test-run TITAN_FILTER=test_server_opening_aborts_pending_101_before_transfer
```

Local evidence, retained outside the repository:

- Linux: `/tmp/titan-193-full-linux-busted-final.log`,
  `/tmp/titan-193-full-linux-busted-final5.log`,
  `/tmp/titan-193-full-linux-native-final5.log`,
  `/tmp/titan-193-full-linux-native-pressure2.log`,
  `/tmp/titan-193-full-linux-native-pressure4.log`,
  `/tmp/titan-193-full-linux-native-pressure5.log`,
  `/tmp/titan-193-full-linux-native-pressure6.log`; their source, generated files,
  executable, log and provider inputs are preserved in the respective
  `linux-final5-pressure4/`, `linux-final5-pressure5/` and `linux-final5-pressure6/`
  directories under `/var/home/mascarenhas/.cache/chatgpt-tmp/titan-193-storage/`.
  Optimized mode receipts remain in
  `/var/home/mascarenhas/.cache/chatgpt-tmp/titan-193-linux-production/`.
- Sanitizer: `/var/home/mascarenhas/.cache/chatgpt-tmp/titan-193-asan/final-sanitizer-receipt.json`,
  siblings `pressure4-sanitizer-receipt.json`, `pressure5-sanitizer-receipt.json`
  and `pressure6-sanitizer-receipt.json`, per-family captured logs, source
  manifests and generated-C diagnostic snapshot. Historical failures remain in
  `artifacts-initial/` and `artifacts-b56/`; passing boundaries remain in
  `artifacts-8f06394-pass/`, `artifacts-pressure4-pass/`,
  `artifacts-pressure5-pass/` and `artifacts-pressure6-pass/`.
- VM source/archive digests, amendments and live logs:
  `/var/home/mascarenhas/.cache/chatgpt-tmp/titan-193-vm-validation-4722c13006b0/`.
- Allocation original preliminary receipt:
  `/var/home/mascarenhas/Documents/Codex/2026-10-04/task-6/build-final5-attempt2/`;
  intermediate receipt in the sibling `build-final5-b1b2/`, final accepted
  combined receipt and summary in `build-final5-r1/`,
  and held-root diagnostic/binding in `held8-multigc-final5/`. Completed timing
  and fairness receipts are in `build-final5-r1/background-lane-attempt2/`; the
  earlier zero-row attempts remain separately preserved. The cache-restoration
  receipt is in `/var/home/mascarenhas/.cache/chatgpt-tmp/titan-193-storage/benchmark-cache-restoration-20261004T1002/`.
- Independent source reviews and amendment hashes:
  `/var/home/mascarenhas/.cache/chatgpt-tmp/titan-193-independent-review-01a1057f/`.
