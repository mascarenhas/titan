# SQLite standard library

`titan.sqlite3` embeds SQLite and provides reusable prepared statements,
streamed query results, and explicit transactions. Import it with
`local sqlite3 = import "sqlite3"`; Lua loads `require "titan.sqlite3"`.
Database operations suspend the current [async Task](async-io.md) while a
native worker runs SQLite. Rows and their values are owned snapshots.

```titan
local sqlite3 = import "sqlite3"
local io = import "io"

function main(args: {string}): integer
  local db = sqlite3.connect(":memory:")
  defer db:close()
  local create = db:prepare("CREATE TABLE notes(id INTEGER, body TEXT)")
  defer create:close()
  create:execute()

  local insert = db:prepare("INSERT INTO notes VALUES (?, ?)")
  defer insert:close()
  insert:execute(1, "hello")

  local select = db:prepare("SELECT id, body FROM notes ORDER BY id")
  defer select:close()
  local cursor = select:query()
  defer cursor:close()
  for row in cursor:fetch do
    io.print(row:get(1), row:get(2))
  end
  return 0
end
```

The normal standalone bootstrap runs `main` as a Task. A Lua host schedules
Titan work and drives the Runtime as described in [async I/O](async-io.md).
Operations that submit native work need a running Task, including close.
`Row:get` and `Row:fill` are synchronous and need no Runtime.

## Public surface

```text
connect(name: string): Connection

Connection:prepare(sql: string): Statement
Connection:close()
Connection:get_autocommit(): boolean
Connection:set_autocommit(autocommit: boolean)
Connection:commit()
Connection:rollback()
Connection:to_transfer_payload(): string
Connection.from_transfer_payload(payload: string): Connection

Statement:execute(...: value): integer
Statement:query(...: value): Cursor
Statement:close()

Cursor.columns: const {Column}
Cursor:fetch(): Row?
Cursor:close()

Row.columns: const {Column}
Row:get(i: integer): value
Row:fill(target: value)

Blob(bytes: string): Blob
Blob.bytes: string                  -- const field
Column.name: string                 -- const field
Column.declared_type: string?       -- const field

Error.message: string               -- const field
Error.code: integer?                -- primary SQLite code; const field
Error.extended_code: integer?       -- extended SQLite code; const field
Error.operation: string             -- const field
```

Connections, Statements, Cursors, and Rows have source-private constructors.
Create them through their owning operations. `Blob` explicitly distinguishes
binary data from ordinary TEXT strings.

## Connections and statement lifetime

`connect` opens a database for read/write, creating it when necessary. SQLite's
`:memory:` name creates a private in-memory database, and the empty filename
creates a temporary database. Filenames reject embedded NUL. This version has
no URI option, read-only overload, busy timeout, or connection pool.

The bundled build uses `SQLITE_THREADSAFE=1`, and each connection explicitly
requests `SQLITE_OPEN_FULLMUTEX`. A Connection admits only one outstanding
native operation. Overlap raises `Error` before submission. Independent
Connections can run concurrently in libuv's shared worker pool.

`prepare` accepts exactly one SQL statement. Trailing whitespace, empty
semicolons, and comments are allowed; empty/comment-only SQL, embedded NUL,
and a second statement are rejected. SQLite itself parses the tail; quoted
semicolons and trigger bodies retain SQLite's syntax. SQL errors have native
diagnostic codes.

A Statement retains its Connection, and a Cursor retains its Statement. One
active Cursor reserves execution on the whole Connection. Until it exhausts
or closes, new `execute`/`query` calls and transaction changes are rejected.
Preparing another Statement, closing an idle Statement, and reading
autocommit state are allowed when no native operation is outstanding. The
active Statement cannot be finalized directly; close its Cursor first.

Close explicitly, in Cursor, Statement, Connection order, normally with
lexical `defer`. Close is idempotent. A Connection with open Statements refuses
close and remains usable. Statement finalization closes the Statement even if
SQLite reports a delayed execution error. Early Cursor close resets and
clears its Statement; it does not roll back a transaction. Cleanup may raise.
Forgetting explicit close is outside the prompt resource-release guarantee;
ordinary garbage collection does not perform database I/O, but closing the
Lua state does.

### Closing the Lua state

Closing the Lua state closes every Connection that is still open: SQLite
finalizes its Statements, including an active Cursor's execution, and rolls
back an open transaction. Its database
file, descriptor and locks are released before the state's close returns. This
release runs synchronously on the closing thread, so it can briefly block it.

A suspended Task's `defer` close made in the documented Cursor, Statement,
Connection order completes during the close instead of raising, although it
cannot [await](coroutines.md#cleanup-that-needs-asynchronous-io). Ordinary
misuse errors, such as closing a Connection that still owns Statements, still
raise, and the state close then releases the Connection anyway. Closing a
Statement or Cursor whose Connection the state close already released does
nothing.

A Task can be waiting for a database operation when the state closes. That
operation's worker may still be running, so its Connection is never released
under it: the Connection is released when the operation returns, which the
state close waits for. The Task never sees the result. As with cancellation, a
COMMIT may or may not have taken effect.

## Transferring connections

Connection implements the [custom record transfer protocol](async-io.md#custom-record-transfer).
`async.TransferValue.from_value(connection)` detaches its native SQLite handle;
the resulting carrier's `to_value()` adopts it into a fresh Connection. Both
hooks are synchronous and need no running Task. Ordinary operations and close
on the receiving Connection still use the receiving state's worker queue.

Transfer rejects a closed Connection, an outstanding operation, an active
Cursor, or any open Statement before detaching. Close every Cursor and
Statement first, including idle Statements. Successful detachment makes every
alias of the source Connection behave as closed; its `close()` becomes a no-op.
The same native database moves, including a private `:memory:` database, open
transaction, and savepoints. Transfer does not commit or roll back anything.

Encoding finishes before the source handle is cleared.
`Connection.from_transfer_payload` rejects malformed bytes (including a
mismatched field kind) and a null native handle. It trusts that a nonnull handle
came from this protocol; it cannot validate an arbitrary address or detect prior
adoption.

This is a manual ownership handoff under the
[shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules).
Connection has no public `discard_transfer_payload`. Adopt the payload exactly
once, retain it while delivery is pending, and recover it yourself after failed
delivery. For example, a carrier rejected by `async.send` can be adopted locally
with `:to_value()` and then closed. Replaying a carrier can create two owners
and cause use-after-free or double-close; abandoning one leaks the database.
Transfer does not roll back detachment when later packing or delivery fails, and
queue disposal does not close a pointer payload. These rules also apply when a
Connection is captured by a transferred closure.

## Binding values

Each invocation supplies exactly SQLite's parameter-slot count. Repeated
named placeholders share a slot. The highest numbered placeholder determines
the count: `?5` requires five positions, including fillers for the lower slots.
Arguments remain positional even when the SQL uses names. A record, Map, or
Array is never automatically expanded into bindings.

| Titan argument | SQL binding |
| --- | --- |
| nil | NULL |
| boolean | INTEGER 0 or 1 |
| integer | signed 64-bit INTEGER, without conversion through float |
| finite float | REAL, including an integral floating value |
| string | UTF-8 TEXT with an explicit byte length |
| exact `sqlite3.Blob` | BLOB with an explicit byte length |

Argument count uses `#...`, so trailing nil arguments are preserved. Every
argument is inspected and validated before the statement is changed. Each
accepted execution resets and clears the preceding binding set and binds the
complete new set; omitted values never inherit prior bindings.

TEXT must be valid UTF-8 and contain no NUL. Use `Blob(bytes)` for arbitrary
bytes, including empty data, embedded NUL, and invalid UTF-8. Empty BLOB is
distinct from NULL. NaN and positive/negative infinity are rejected as inputs.
Other records, unions, Interfaces, containers, functions, threads, raw
pointers, and owned C storage are unsupported scalar bindings.

Reflection preserves the actual input integer/float tag at the bind boundary.
SQLite column affinity can change the stored representation; there is no
promise that every database column preserves the input tag. SQLite has no
separate Boolean or date storage class.

## Executing and querying

`execute` binds, performs one step, requires `SQLITE_DONE`, captures
`sqlite3_changes64`, and resets/clears the Statement for reuse. A first-step
`SQLITE_ROW` raises an Error suggesting `query`. That rejection does not
promise an absence of side effects: a modifying statement with `RETURNING`
may already have changed the database.

The returned count is literally SQLite's connection change counter for its
latest completed INSERT/UPDATE/DELETE. Other successful statements need not
reset it. For example, CREATE TABLE after an INSERT may return that INSERT's
count; a zero-row SELECT accepted by `execute` can do the same. It excludes
SQLite's documented auxiliary trigger/foreign-key effects. See SQLite's
[change-counter contract](https://sqlite.org/c3ref/changes.html).

`query` requires result columns and supports both SELECT and statements with
`RETURNING`. It binds and performs the first step before returning. Current
column metadata is copied after that step, including SQLite's automatic schema
reprepare. A first result row is buffered in the Cursor; each later `fetch`
performs one step and returns one owned Row. No implicit retry is added.

An empty result returns an already exhausted Cursor with its column metadata.
On natural exhaustion, reset/clear completes before `fetch` returns nil, and
the execution reservation is released. Repeated exhausted fetches return nil.
Fetching an explicitly closed Cursor raises. A failed native fetch or failed
row publication retires that execution and closes the Cursor.

## Rows and mapping

`#row.columns` is the authoritative column count, and `Row:get(i)` accepts
1-based indices through that count. NULL returns nil. A row containing only
NULLs is still a nonnil Row; a trailing NULL does not truncate its columns.

| SQLite storage class | `Row:get` result |
| --- | --- |
| NULL | nil |
| INTEGER | integer |
| REAL | float |
| TEXT | copied string |
| BLOB | Blob containing copied bytes |

Rows remain valid after later fetches and after every Cursor, Statement, and
Connection closes. Columns are ordered and preserve duplicate names; indexed
access remains unambiguous. `declared_type` is descriptive metadata and can be
nil for expressions. It does not determine result conversion.

An explicit application factory is the primary route to domain records,
especially records with const fields or invariants:

```titan
local sqlite3 = import "sqlite3"

record Note
  const id: integer
  const body: string
end

function note_from_row(row: sqlite3.Row): Note
  return Note(row:get(1), row:get(2))
end
```

`Row:fill(target)` fills an existing mutable record through
[public reflection](standard-library-reflect.md). Before writing, it rejects
duplicate column names, missing/extra public fields, const destination fields,
and unsupported field kinds. Local fields are invisible and left alone.
Supported destinations are nil, value, boolean, integer, float, string, Blob,
and their eligible Options. Erased generic `value` fields remain `value`.

Writes follow public field declaration order and use each field's ordinary
dynamic conversion/range checks. SQL NULL requires a nil-capable destination.
TEXT fills strings, BLOB fills Blob, and Boolean fields explicitly accept only
SQL integer 0 or 1 as false/true, including inside Options. Nested structures
require an application mapper.

Shape validation precedes writes, but conversion failure can leave earlier
fields changed. `fill` does not promise atomic mutation. Use a factory that
validates all cells before construction when atomic object creation matters.

## Transactions

`get_autocommit` reads SQLite's actual state, including changes caused by
explicit SQL or automatic rollback after an error. No driver-mode flag is
maintained.

| Operation | Behavior |
| --- | --- |
| `set_autocommit(false)` in autocommit | BEGIN DEFERRED |
| `set_autocommit(false)` in a transaction | no-op |
| `set_autocommit(true)` in a transaction | COMMIT |
| `set_autocommit(true)` in autocommit | no-op |
| `commit()` / `rollback()` in a transaction | COMMIT / ROLLBACK |
| `commit()` / `rollback()` in autocommit | no-op |

Commit/rollback do not start a replacement transaction. Enabling autocommit
commits; it does not adopt LuaSQL's SQLite manual-mode rollback policy. A
failed COMMIT can leave the transaction active. Close active Cursors before
changing transaction state, and keep a transaction with one logical caller.
Use explicit SQL SAVEPOINT/RELEASE for SQLite's nested savepoint mechanism.

## Errors and cancellation

SQLite failures and wrapper contract violations raise `sqlite3.Error`.
`message` identifies the failure, and `operation` identifies its public
operation. Native errors include primary and extended SQLite codes; wrapper
errors have nil codes. Execution errors retain the original SQLite diagnostic
when reset/clear also fails, with cleanup context appended to the message.
There is no automatic BUSY/LOCKED retry.

Ordinary native work uses `async.run_foreign`. Pending cancellation prevents
new ordinary work from being submitted; once accepted, the native operation
finishes before cancellation is delivered. Cancellation can therefore arrive
after SQL side effects or a commit. Do not retry merely because the Task was
cancelled. Prompt SQLite interruption is not provided.

Close/reset/finalize and retirement of unpublished handles use the private
ownership-cleanup path and complete despite pending cancellation. They never
perform blocking SQLite work on the event-loop thread, except while the
[Lua state closes](#closing-the-lua-state). Native packets and all referenced
buffers remain owned until their accepted callbacks finish.
Submission failure remains an `async.OperationError`, and cancellation retains
its original async reason instead of becoming a SQLite Error.

The worker pool is shared with filesystem and DNS work. The module does not
change its process-wide size or create a thread per Connection.
