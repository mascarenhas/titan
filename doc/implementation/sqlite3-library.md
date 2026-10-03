# SQLite standard-library implementation

The [public contract](../language/standard-library-sqlite3.md) belongs to the
folder module `titan.sqlite3`. `sqlite3.titan` owns Connection/Statement/Cursor
state and submission, `bindings.titan` owns reflection input validation and
owned output decoding, `row.titan` owns synchronous row mapping, and
`worker.titan` contains restricted source foreign functions. `native.h`
declares native carriers only.

## Provider and dependency

The Makefile pins the official SQLite 3.53.4 autoconf source archive, which
contains its matching amalgamated `sqlite3.c` and `sqlite3.h`, and verifies its
SHA-256 before extraction. The archive pin was checked against SQLite's
published SHA3-256 when selected. `make sqlite3` uses the effective CC, AR,
RANLIB, optimization/sanitizer inputs and `SQLITE_THREADSAFE=1` to build the
private PIC/hidden archive `sqlite3-build/libtitan-sqlite3.a`.

This payload follows private llhttp in the shared provider link and is carried
into both `titan.so` and `titan.a`, in both OpenSSL modes. There is no system
SQLite mode, SQLite child DSO, or independently installed private archive.
The matching public `sqlite3.h` is staged in the compiler SDK. Private symbol
visibility follows the existing bundled native payload policy.

SQLite is one logical standard module in the combined provider, which has
twenty-one module protocols,
twenty-one archive metadata keys/shims, and twenty-two Lua openers including bare
support `luaopen_titan`. Source, provider validation, installer rollback,
snapshot, native aggregate, production smoke, and CI cache manifests include
it explicitly. Native dependency cache identities include the version,
checksum, native toolchain and build policy; sanitizer SQLite is built with
the same instrumented dependency policy as the other native libraries.

## Native packet boundary

Each operation allocates a zeroed `owned *TitanSqlitePacket` before submission.
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
error status, and autocommit, is inside a worker batch. Pure allocation,
memcpy/free, UTF-8 validation, reflection and Titan-value construction run on
the loop thread.

Each operation uses its own exact `foreign function (*void): void` entry. There is no
second operation dispatcher or actor. `sqlite_copy_bytes` always allocates
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

`sqlite_retire_worker` finalizes an unpublished Statement or resets an
unpublished execution, then closes an unpublished Connection. Flags clear only
at their corresponding native retirement/transfer point. Finalize clears its
handle even when it reports a prior execution error; a failed sqlite3_close
keeps its handle. Public explicit cleanup updates the visible owner after
native retirement, so a rejected submission leaves it available for cleanup
again. The module never uses sqlite3_close_v2 zombie ownership or SQLite
process-global shutdown.

## Cancellation

Public ordinary work goes through `async.run_foreign`. A local cleanup adapter
uses public `uv.work_t` and `uv.queue_work` inside `async.await_cleanup`. Its
explicit `argument_owner` retains the owned packet through worker completion
and the entire after-work callback frame. The callback translates a native
status with the existing `async.run_foreign` operation label, settles the exact
wait, and uses fatal-and-rethrow for unexpected terminal callback failures.
Accepted native work remains owned until after-work completion in both paths;
neither uses `uv_cancel` or `sqlite3_interrupt`. Reset, finalize, close, and
unpublished-result retirement use this cleanup adapter without mutating Task
flags or accessing a source-private UV scheduler.

Cleanup can submit and receive ordinary completion during cancellation unwind.
This is not general Task shielding: ordinary operations still receive the
sticky cancellation reason, and the Task's final status stays cancelled.
There are no Task-flag mutations, detached cleanup Tasks, native destructors in
GC callbacks, or blocking SQLite calls on the loop thread.

As with existing async close operations, submission needs runtime allocation
and an accepting worker queue. Persistent allocation exhaustion or failure to
submit native cleanup is not an allocation-infallible destruction guarantee.
The implementation retains ownership through accepted work and handles
cancellation and recoverable result-publication failure; it does not claim
that arbitrary process-wide resource exhaustion can be repaired by a finalizer.

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

## Verification ownership

Public behavior lives under `spec/stdlib/titan/sqlite3/` in the native aggregate,
outside LuaCov. The tests exercise bindings, reusable statements, owned rows,
reflection, transactions, cancellation, and independent-loop progress.
Deterministic worker gates use SQLite's supported native extension hooks in a
normal installed static-consumer child, with no rewritten provider or callback
interposition. Focused ASan/UBSan runs use the instrumented bundled SQLite.
Existing packaging specs verify private native archive linkage, thread mode,
source/shim/archive inventories, and installed dynamic/static consumption.
