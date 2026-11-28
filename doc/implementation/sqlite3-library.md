# SQLite standard-library implementation

The [public contract](../language/standard-library-sqlite3.md) belongs to the
folder module `titan.sqlite3`. Shared `validation.titan` owns the public
`Error` record, zero-allocation in-place UTF-8 validation (`valid_text`), and
binding-value classification (`argument_cell`); shared `row.titan` owns
synchronous row mapping. On native targets, `sqlite3.native.titan` owns
Connection/Statement/Cursor state and submission, `bindings.native.titan` owns
native packet encoding and decoding, `worker.native.titan` contains restricted
source foreign functions, and `native.h` declares native carriers. On the
browser target, `sqlite3.browser.titan`, `bindings.browser.titan`, and
declaration-only `sqlite3.browser.h` drive the worker-hosted SQLite service
without linking any SQLite C header or archive into the browser guest
([Browser connections](#browser-connections),
[Browser service frames](#browser-service-frames)).

## Provider and dependency

The Makefile pins the official SQLite 3.53.4 autoconf source archive
(`SQLITE3_VERSION`, `SQLITE3_SHA256`), which contains the matching amalgamated
`sqlite3.c` and `sqlite3.h`, and verifies its SHA-256 before extraction.
`make sqlite3` uses the effective CC, AR, RANLIB, optimization/sanitizer inputs
and `SQLITE_THREADSAFE=1` (`SQLITE3_CFLAGS`) to build the private PIC/hidden
archive `sqlite3-build/libtitan-sqlite3.a`.

The archive is carried into both `titan.so` and `titan.a` in both OpenSSL
modes; its place in the `-X` payload order and the rest of the image are in
[the standard-library image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).
There is no system SQLite mode, SQLite child DSO, or independently installed
private archive. The matching public `sqlite3.h` is installed in the compiler
SDK include directory. Native dependency cache identities include the version,
checksum, native toolchain and build policy; sanitizer SQLite is built with
the same instrumented dependency policy as the other native libraries.

## Native packet boundary

Each operation allocates a zeroed `owned *TitanSqlitePacket` (`native.h`) before submission.
The packet contains only C scalars, SQLite handles, pointers, lengths, and
ownership flags. Inputs are malloc-backed copies. Parameters use an explicit
argument count and native Cell array; varargs are inspected through `#...`
and `...[i]` so trailing nil positions survive. Count and representation
validation finish before any statement mutation.

The suspended Titan frame and its defers retain the owned packet. Its argument
buffers and output arrays remain malloc-owned until `sqlite_free_packet` runs.
Passing a raw pointer to `run_foreign` alone does not root its pointee. No
worker reads a Titan/Lua record, TValue, Udata, closure, Array, or Lua state.
Every SQLite API access, including reset/finalize/close, metadata, binding,
error status, and autocommit, is inside a worker batch, except at
[Lua-state close](#lua-state-close). Pure allocation,
memcpy/free, UTF-8 validation, reflection and Titan-value construction run on
the loop thread.

Each operation uses its own exact `foreign function (*void): void` entry. There is no
second operation dispatcher or actor. Every submission calls that entry through
the `sqlite_run_worker` trampoline, which adds only the Windows
[x87 precision reset](libuv-runtime.md#worker-floating-point-state) before the
entry and the [state-close handoff](#lua-state-close) after it. `sqlite_copy_bytes` (`worker.native.titan`) always allocates
one extra terminator byte, including for an empty BLOB; binding lengths remain
explicit and use `SQLITE_TRANSIENT`.

SQLite's C pointer out-parameters use ordinary mutable-local address coercion,
including `const char *` tail storage passed to `const char **`. This preserves
the inner pointee qualifier. Restricted foreign-function `sizeof`/`alignof`
expressions retain their native size type rather than crossing through a
Titan integer. Focused compiler regressions cover those C-only contracts.

## Reservations and lifetime

A Connection stores its native handle, owned Statement count, one busy flag
for the current native operation/publication sequence, and its active
Statement, if a Cursor owns an execution. A Statement strongly retains its
Connection. A Cursor strongly retains its Statement and owns copied metadata,
an optional first Row, exhausted state, and explicit closed state.

The Connection's busy reservation is acquired before submission and released
after result publication and any dependent cleanup. Overlapping operations
raise before they can alter native state. No callback can preempt running
Titan code; the reservation covers real suspension boundaries rather than
imagined intra-continuation races. Idle prepared Statements may coexist.
An active Cursor prevents new execution and transaction changes on the
Connection until its execution is reset.

Native ownership is explicit in the packet:

| Flag | Native state still owned by the operation |
| --- | --- |
| `owns_db` | newly opened Connection awaiting publication |
| `owns_stmt` | newly prepared Statement awaiting publication |
| `needs_reset` | bound/stepped execution awaiting reset or Cursor transfer |

Public Connection/Statement shells are allocated before their native resource
is acquired. The final handle assignments and transfer of ownership do not
need another public-owner allocation. Query publication additionally builds
Column/Row/Cursor values while the packet still owns execution; failed
publication resets it before releasing its buffers and Connection reservation.
Fetch failure similarly retires the active execution and closes the Cursor.

`sqlite_retire_worker` (`worker.native.titan`) finalizes an unpublished Statement or resets an
unpublished execution, then closes an unpublished Connection. Flags clear only
at their corresponding native retirement/transfer point. Finalize clears its
handle even when it reports a prior execution error; a failed sqlite3_close
keeps its handle. Public explicit cleanup updates the visible owner after
native retirement, so a rejected submission leaves it available for cleanup
again. The module never uses sqlite3_close_v2 zombie ownership or SQLite
process-global shutdown.

## Connection transfer

Connection's custom record hooks move the existing `sqlite3 *` under the
[manual handoff contract](../language/standard-library-sqlite3.md#transferring-connections);
the generic rules (exactly-once adoption, no packet-discard cleanup, lossy
carriers) are in
[manual resource handoff](transfer-library.md#manual-resource-handoff). SQLite
has no `discard_transfer_payload` helper. This section covers the SQLite gate
and schema.

The encoding hook (`Connection:to_transfer_payload`) reserves the Connection with the same closed/busy/active
Cursor checks as close, then rejects any remaining Statement. The reservation
also covers result publication and cancellation cleanup, so a completed
worker whose continuation has not retired is still ineligible. Even an idle
Statement owns a `sqlite3_stmt *` and retains the original Connection; it
cannot follow a detached connection implicitly.

The hook serializes its raw pointer through `connection_transfer_fields`, a
foreign-pointer field that protobuf writes as fixed64, before clearing
`handle`. The same schema is reused for decoding. The source then has
no close authority, and the reservation is released by its ordinary defer.
Decoding validates the wire message and nonnull address,
then allocates a fresh Connection with zero Statements and no active operation.
Neither hook calls SQLite, queues work, captures a source Runtime, or yields.
The existing FULLMUTEX database already supports successive worker threads;
the receiving state's ordinary worker submission can use it directly.
Transaction/savepoint state stays on the native handle.

The payload is a bare pointer, not a reference-counted ticket: repeated
adoption, abandoned payloads and arbitrary pointer injection are the
programmer's responsibility, and ordinary collection performs no database I/O.
A detached source has no handle, so its state-close finalizer releases nothing.

## Cancellation

Public ordinary work goes through `async.run_foreign`, submitted by
`Connection:run_worker`. The local cleanup adapter `Connection:run_cleanup`
(`sqlite3.native.titan`) uses public `uv.work_t` and `uv.queue_work` inside
`async.await_cleanup_with`. Its `CleanupWork` context
records the completion and operation number, and passes the owned packet as
`uv.queue_work`'s `argument_owner`, which retains it through worker completion
and the entire after-work callback frame. The callback `cleanup_completed` saves that exact
completion and number, clears the old request association, and settles the
saved operation, rejecting with the raw native status on failure. After the
cleanup await returns, the adapter translates a rejected status using the
existing `async.run_foreign` operation label. Unexpected terminal callback
failures use the saved capability's fatal method and rethrow.
Accepted native work remains owned until after-work completion in both paths;
neither uses `uv_cancel` or `sqlite3_interrupt`. Reset, finalize, close, and
unpublished-result retirement use this cleanup adapter without mutating Task
flags or accessing a source-private UV scheduler.

Cleanup can submit and receive ordinary completion during cancellation unwind.
This is not general Task shielding: ordinary operations still receive the
sticky cancellation reason, and the Task's final status stays cancelled.
There are no Task-flag mutations, detached cleanup Tasks, or blocking SQLite
calls on the loop thread, except at [Lua-state close](#lua-state-close). The only GC callback is the
[state-close finalizer](#lua-state-close), which ordinary collection leaves
inert.

As with existing async close operations, submission needs runtime allocation
and an accepting worker queue. Persistent allocation exhaustion or failure to
submit native cleanup is not an allocation-infallible destruction guarantee.
The implementation retains ownership through accepted work and handles
cancellation and recoverable result-publication failure; it does not claim
that arbitrary process-wide resource exhaustion can be repaired by a finalizer.

## Lua-state close

Lua state close cannot await the worker pool, so the closing state releases
SQLite resources itself. This is the only place where the module calls
SQLite on the loop thread: finalize, reset, and close, which also rolls back an
open transaction.

Every Connection registers `finalize_connection` with `gc.finalizable` before
it holds a handle, in `connect` and `from_transfer_payload`. The finalizer
returns at once unless `titan_state_closing` is set, so ordinary collection
still performs no database I/O. During close it releases an open, non-busy
Connection with `sqlite_release_connection` (`worker.native.titan`): it
finalizes every statement that `sqlite3_next_stmt` still reports, including an
active execution, then calls `sqlite3_close`. Statement and Cursor shells keep
their dangling handles. `Statement:close` and `Cursor:close` return without a
native call once their Connection has no handle, and every other operation
rejects that Connection in `reserve` before it reads a handle.

`Connection:run_cleanup`, which serves Connection, Statement and Cursor close
and the retirement of unpublished results, calls its C entry synchronously
while the state closes. A `defer db:close()` in an unwinding Task therefore
completes instead of raising. The busy reservation guarantees that no worker
uses the connection at that moment. Finalizers run newest first, and a
Connection can be newer or older than the Task that uses it. Either the
finalizer releases first and the unwinding closes become no-ops, or the
unwinding closes release synchronously and leave the finalizer nothing.
Ordinary misuse checks still run first: `close` of a Connection that owns
Statements, or of a Statement with an active Cursor, raises, and the
finalizer then releases the Connection.

**Abandoned worker waits.** A Task parked in a worker wait is unwound before
the Runtime finalizer drains accepted work, so its worker may still use the
packet and the connection. `run_worker` and `run_cleanup` set the packet's
`pending` before submission and clear it when the wait returns or raises.
`catch` never runs during an unwind, so only an abandoned wait leaves it set.
The submission's `defer` then clears the Connection's handle and calls
`sqlite_abandon_worker`. The `sqlite_run_worker` trampoline and that call each
exchange their mark into the packet's `handoff` atomically
(`titan_sqlite_handoff`, `native.h`). Whichever finds the other's mark calls
`sqlite_release_abandoned`. It releases the packet's connection as above
(the Connection's handle, or the one an abandoned `connect` opened) and frees
every native buffer. The release therefore runs on the loop thread if the
worker had already returned, and on the worker thread right after the
operation otherwise. The frame's own cleanup (`retire_packet`,
`sqlite_free_packet` and the close-result checks) skips a pending packet, and
the finalizer skips the busy Connection. The packet's GC owner outlives the
worker: `lua_close` runs every finalizer, including the Runtime's drain of
accepted work, before it frees any object. Unlike an independent Lua state's
[abandoned-work release](libuv-runtime.md#foreign-workers), this release may
run on the worker because it calls only SQLite on a connection that no other
thread uses; it never waits for the worker pool or a loop.

## Worker operations and errors

Open explicitly requests read/write/create and FULLMUTEX. Prepare uses
sqlite3_prepare_v2 and asks SQLite to parse the remaining tail. An additional
statement is finalized and rejected; no second SQL tokenizer is introduced.
The input copy survives every tail pointer. SQLite documents a null statement
output on prepare failure. See the [prepare contract](https://sqlite.org/c3ref/prepare.html).

Execute resets/clears old bindings, binds all slots, steps once, captures
changes64 on DONE, and resets/clears before returning. Query checks for result
columns, binds and steps, then copies current metadata and an optional first
row. DONE resets and releases execution before returning an exhausted Cursor.
Later fetches copy one row or reset on DONE. Early close resets and clears.

The worker reads each column's original storage class before conversion, uses
the matching pointer accessor before its byte length, and copies bytes before
the next step/reset/finalize. It checks SQLite's error state immediately for
an ambiguous null result pointer. Empty BLOB and SQL NULL remain distinct.
See [column extraction](https://sqlite.org/c3ref/column_blob.html).

Native errors copy the message and capture primary/extended codes before a
later SQLite call can overwrite them. If copying a diagnostic fails, fixed
fallback text preserves the status. Reset/clear errors preserve an earlier
primary failure and append cleanup context; otherwise they become the primary
failure. Output arrays are zeroed and have explicit allocated element counts
so partial metadata/row copying is freed safely. Ordinary async submission and
cancellation failures are not wrapped as SQLite errors.

Transaction workers read actual sqlite3_get_autocommit, conditionally execute
one fixed BEGIN/COMMIT/ROLLBACK with a NULL exec callback, and read the actual
state afterward. No extra driver flag, retry, or COMMIT-plus-BEGIN sequence
can hide an already committed transaction.

## Owned rows and reflection

Rows hold const Arrays of Columns and cells. Column count governs bounds and
iteration because the cells Array can contain holes or trailing nil. Native
result buffers are converted to owned counted character arrays before their
binary-safe string copy. Rows then contain only ordinary Titan values and can
outlive all native owners.

Row filling first validates a one-to-one mapping from unique column names to
every public record field and rejects const/unsupported destinations. Writes
use 1-based public descriptor ordinals, never physical FieldType.index values.
The inspected record exposes its schema through `.type.fields`; each
`FieldType.type` supplies the destination's type. Reflected Blob bindings
recover the original object through `.value`.
The existing reflect setter owns dynamic conversion and the GC write barrier.
Boolean conversion accepts only SQL integer 0/1; Options retain NULL. Named
Blob fields recognize the one exact nominal owner without recursively
expanding arbitrary type schemas. Generic value fields keep their erased
semantics. Shape checks precede writes, but later conversion failures can
leave earlier fields changed.

## Browser connections

On `--target browser`, `titan/sqlite3/` compiles only `validation.titan`,
`row.titan`, `sqlite3.browser.titan`, `bindings.browser.titan`, and
declaration-only `sqlite3.browser.h` (which declares
`TITAN_WASM_IMPORT("titan_browser_sql_retire_sync")`). Neither `titan.a` nor
any browser user image includes `sqlite3.h` or links SQLite objects; the
SQLite engine lives solely in the SDK's standalone `titan-sqlite3-service.wasm`
reactor hosted by the storage worker.

* **State token and lease authority:** `sql_transport()` discovers the calling
  Lua state's 32-bit `state_token` once through a short-lived `browser.pin`
  probe and caches `browser.binding("titan:sqlite3")`. Connections and
  statements are opaque generation-tagged 64-bit integer handles (`connId`,
  `stmtId`) tracked by the single per-instance lease ledger
  (`titanBrowserSql(storage)` in `titan-browser-sql.mjs`), whose `leases` map
  maps each `connId` to its owning state. `Connection:to_transfer_payload()` and
  `Connection.from_transfer_payload()` call synchronous `detach` and `adopt` on
  `titan:sqlite3` carrying `(nonce, connId)` through protobuf; detachment
  refuses closed connections, busy connections, active cursors, open
  statements, or connections with pending deferred cleanup (`has_deferred()`).
* **Working directory coherence:** `database_path()` resolves relative database
  names against `os.cwd()` before `OP_OPEN` (checking `MAX_TEXT_BYTES` before
  concatenation). Every `request(frame)` also sends `working_directory()`
  (`os.cwd()` or `nil`) alongside the frame so the storage worker issues
  worker-internal `OP_CHDIR = 14` before dispatching the SQLite operation.
  Inside `sqlite3_service.c`, a thin default `sqlite3_vfs` wrapper named
  `titan` (copying `unix-dotfile`) overrides `xFullPathname` to refuse every
  relative path (including `..`, `ATTACH`, and `VACUUM INTO`) with
  `SQLITE_CANTOPEN` whenever no guest working directory is active, while
  passing absolute paths through unchanged.
* **Completion before cancellation:** `request(frame)` uses
  `async.await_cleanup` so a cancelled Task waits for an already-accepted
  worker frame to reply and retires any unpublished handle (`OP_FINALIZE`,
  `OP_CLOSE`, or `OP_RESET`) before delivering cancellation.
* **Deferred finalizer cleanup (`Connection:drain()`):** Finalizers cannot
  suspend, so `Connection:cleanup` appends `OP_RESET`/`OP_FINALIZE` frames to
  `self.deferred` (`{string}`) indexed by a head cursor `self.deferred_head`
  (`has_deferred()` holds if and only if `deferred_head <= #deferred`). Before sending any
  new frame, `Connection:drain()` enforces a strict queued → admitted →
  consumed order: if `has_deferred()` holds, it calls `async.running()` **first**
  before touching queue state, loops dynamically while
  `self.deferred_head <= #self.deferred` (draining any further frames queued by
  a finalizer during suspension), and overwrites `self.deferred[index] = ""`
  (never `nil`, avoiding Array holes) and advances `deferred_head` strictly
  **after** `request(frame)` returns cleanly, resetting to `{}` and `1` once
  empty. If transport fails, the unconsumed frame remains at `deferred_head`,
  preserving `has_deferred()` and keeping transfer refused. During Lua-state
  close (`titan_state_closing(L) ~= 0`), and when `Connection:close()` runs
  where `can_wait()` is false (such as inside a finalizer),
  `Connection:retire()` drops `deferred` and calls non-suspending
  `titan_browser_sql_retire_sync(state_token, id)`. In `titan-browser-sql.mjs`,
  `ledger.retire(state, id)` checks `leases.get(id) === state` before queuing
  `CLOSE_CONN` (and transferred source shells already clear `handle = 0`), so
  transferred connections are never touched.

## Browser service frames

The browser wire codec lives in Titan (`titan/sqlite3/bindings.browser.titan`,
using `string.pack`, `string.unpack`, and `string.writer()`), keeping
`titan-browser-sql.mjs` to pure byte forwarding and lease checks and keeping
SQLite inside the standalone plain-C Wasm reactor
`titan-runtime/browser/sqlite3_service.c` + pinned `sqlite3.c`
(`titan-sqlite3-service.wasm`, compiled with `-DSQLITE_THREADSAFE=0
-DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_TEMP_STORE=3` and zero Lua or Titan
runtime).

Version-1 frames are little-endian with a fixed 16-byte header followed by an
opcode-specific body:

* **Request header (16 bytes):** `u8 op`, `u8 version` (`1`), `u16 reserved`
  (`0`), `u32 count` (argument cells for `EXECUTE`/`QUERY`, `<= 32766`; else
  `0`), and `u64 handle` (`connId`, `stmtId`, or `0` for `OPEN` and `CHDIR`).
* **Reply header (16 bytes):** `u8 op` (echoed, or `0` if header malformed),
  `u8 status` (`0` OK, `1` ERROR, `2` PROTOCOL), `u8 writing` (`1` when any
  connection holds an explicit transaction via `sqlite3_get_autocommit() == 0`
  or an implicit write via `sqlite3_txn_state() == SQLITE_TXN_WRITE`), 5
  reserved bytes, and `u64 handle`. Status `1` or `2` carries a failure body:
  `i32 code`, `i32 extended`, `u32 len + UTF-8 message`, `i32 cleanup_code`,
  and `u32 len + cleanup_message` (`len == 0xFFFFFFFF` when absent).

| `op` | Name | Handle | Request body | OK reply body |
| --- | --- | --- | --- | --- |
| 1 | `OPEN` | `0` | `u32 len, path` | — (`handle = connId`) |
| 2 | `PREPARE` | `connId` | `u32 len, sql` | `u32 parameter_count, u32 column_count` (`handle = stmtId`) |
| 3 | `EXECUTE` | `stmtId` | `count` cells | `i64 changes` |
| 4 | `QUERY` | `stmtId` | `count` cells | column descriptors, then row-or-done |
| 5 | `FETCH` | `stmtId` | — | row-or-done |
| 6 | `RESET` | `stmtId` | — | — |
| 7 | `FINALIZE` | `stmtId` | — | — |
| 8 | `CLOSE` | `connId` | — | — |
| 9 | `CLOSE_CONN` | `connId` | — | — (ledger-only retirement; rejected from guest `call`) |
| 10 | `AUTOCOMMIT` | `connId` | — | `u8 autocommit` |
| 11 | `BEGIN` | `connId` | — | `u8 autocommit` |
| 12 | `COMMIT` | `connId` | — | `u8 autocommit` |
| 13 | `ROLLBACK` | `connId` | — | `u8 autocommit` |
| 14 | `CHDIR` | `0` | `u32 len, cwd` (`0` clears) | — (worker-internal; rejected from guest `call`) |

Argument and result cells share the five type tags defined in
`validation.titan`: `1` `INTEGER` (`i64`), `2` `FLOAT` (`f64`), `3` `TEXT`
(`u32 len + UTF-8`, no embedded NUL), `4` `BLOB` (`u32 len + bytes`), and `5`
`NULL` (no payload). Request and reply frames are capped at **64 MiB**, SQL
text and database paths at **16 MiB**, single `TEXT`/`BLOB` cells at **32
MiB**, bound parameters at **32,766**, open connections at **1,024**, and open
statements per connection at **4,096**. `bindings.browser.titan` validates
request bounds before scanning or sending so oversized inputs raise
`SQLITE_TOOBIG` (`18`) directly, while oversized replies return status `1`
with `SQLITE_TOOBIG`.

## Verification ownership

Public behavior lives under `spec/stdlib/titan/sqlite3/` in the native aggregate,
outside LuaCov. The tests exercise bindings, reusable statements, owned rows,
reflection, transactions, cancellation, and independent-loop progress.
Transfer cases cover source invalidation, synchronous hooks, transaction and
savepoint preservation, invalid payloads, rejected-send recovery, and round
trips through an independent state followed by source-state collection. The
existing worker gates also reject transfer during prepare and close, including
when no Statement has been published yet. State-close cases close independent
states that hold a parked Task's Connection, Statement and active Cursor in
both finalizer orders, or an abandoned worker wait that is still running or
already finished, then take an exclusive lock on the same database file.
Deterministic worker gates use SQLite's supported native extension hooks in a
normal installed static-consumer child, with no rewritten provider or callback
interposition. Focused ASan/UBSan runs use the instrumented bundled SQLite.
Existing packaging specs verify private native archive linkage, thread mode,
source/archive inventories, and installed dynamic/static consumption. On the
browser target, `spec/stdlib/titan/sqlite3/` runs in the browser
standard-library test suite alongside storage-worker reactor unit tests
(`spec/browser/vfs-unit.test.mjs`) and durable OPFS tests.
