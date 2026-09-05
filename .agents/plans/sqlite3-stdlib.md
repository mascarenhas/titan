# SQLite standard library (issue #118)

## Scope and decisions

Implement `titan.sqlite3` / short import `sqlite3` on `feat/sqlite3` from
master 0ac5df1a7a99dddd014ba28f181d13d716a8479f. Follow the issue's recommended
policies under the maintainer's explicit delegation of design decisions.

- Bundle an official checksum-pinned SQLite amalgamation with
  SQLITE_THREADSAFE=1; use FULLMUTEX read/write/create connections.
- Public Connection, Statement, Cursor, Row, Blob, Column, and Error surface
  follows issue #118. Resource constructors are source-private.
- Preserve exact vararg positions and reflection integer/float tags; accept
  NULL, boolean, integer, finite float, UTF-8/NUL-free TEXT, explicit Blob.
- One native operation at a time per Connection; one active Cursor blocks
  new execution. Reject overlap rather than adding queues or a database actor.
- Every SQLite access runs in a native worker batch; worker-owned packets
  contain only native values. Copy bytes across the worker boundary.
- Add a narrow source-private foreign cleanup operation using existing close
  cancellation semantics. Public async.run_foreign remains unchanged. Retain
  accepted work and retire unpublished open/prepare/query resources even when
  cancellation or allocation failure interrupts result publication.
- Native transaction state: disabling autocommit begins DEFERRED; enabling
  commits; commit/rollback do not restart transactions and are idle no-ops.
- Owned rows preserve NULL positions with column count; strict mutable-record
  fill uses public reflection ordinals, checks shape before writes, adapts
  integer 0/1 booleans, and documents possible partial writes on conversion.
- execute requires first-step DONE and reports literal sqlite3_changes64;
  query supports streamed results including RETURNING without retry promises.

## Work plan

1. Implement private cancellation-insensitive native retirement plus regression
   coverage without changing ordinary foreign work.
2. Integrate SQLite dependency, short imports, source/provider/shim/archive/test
   manifests, sanitizer dependency caching, and installed consumer smokes.
3. Implement restricted foreign workers with private native packet declarations,
   deterministic ownership/error cleanup, and explicit handle transfer.
4. Implement public owners, bindings, rows/reflection filling and state checks.
5. Add native behavior tests covering SQL/type/transaction/ownership contracts,
   deterministic worker cancellation and concurrent-loop progress, and focused
   sanitizer lifetime cases. Add compiler specs only for actual new compiler
   behavior or short import coverage.
6. Update both manuals and indexes, provider/build documentation where affected,
   and this plan with implementation/verification evidence.
7. Run focused tests, isolated canonical full local verification, installed
   dynamic/static smoke tests, and independent code review. Address findings.
8. Commit/push, open PR closing #118, and monitor/fix final-head Linux CI and
   coverage. macOS CI is waived; do not dispatch it. Do not merge the PR.

## Coordination and validation

Root owns the public SQLite facade/mapping and overall delivery. Separate
agents own provider/build integration, runtime cleanup, and worker internals.
Use one owner for shared builds, private scratch roots for independent tests,
and an isolated /tmp toolchain prefix. No concurrent agents may mutate shared
native/generated staging. Preserve explicit cancellation as the original
runtime error, and SQLite errors with primary/extended codes plus operation.

## Evidence

- Initial checkout clean; remote master verified at the base above. Issue read
  live on 2026-09-05; recommended design decisions adopted under delegation.
- Implemented the official SQLite 3.53.4 amalgamation (SHA-256
  0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c),
  all four module contributors, native packets, cancellation cleanup, and
  twenty-module provider/build/installer/CI manifests.
- Fresh isolated Lua/LuaRocks/Titan installation succeeded in
  /tmp/titan-mascarenhas-sqlite3. All twenty exact serialized standard
  interfaces match the checked-in fixture.
- Complete unfiltered local luarocks test passed: 129 retained runtime and
  packaging cases; four private compiler shards of 878, 669, 740, and 992 cases
  (3,279 total); and all 306 native tests, including all 64 SQLite cases.
- SQLite tests include eight deterministic static-child cancellation,
  native ownership, loop-progress, and recoverable result-allocation-failure
  scenarios. The broad compiler gate also covers the corrected stored-plan
  expectations for exact mutable C pointer out-parameters.
- Installed bundled dynamic/static production smoke passed, including SQLite
  with the DSO and shims out of search reach for the static consumer. Both
  documented runnable examples compiled and passed unchanged.
- Independent public API/docs, native worker/ownership, compiler, and provider
  integration reviews found no outstanding correctness issues. Persistent
  allocation/submission failure follows the existing async-close limitation;
  no infallible finalizer/destruction claim is made.
- Local implementation, documentation, review, and verification are complete.
  Publication and final-head Linux CI remain the delivery step. The workflow
  includes both provider modes, focused ASan/UBSan SQLite lifetime cases and
  compiler coverage. macOS is explicitly waived; do not dispatch it.
