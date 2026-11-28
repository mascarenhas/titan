# SQLite standard library

`titan.sqlite3` embeds SQLite with prepared statements, streamed query cursors,
explicit transactions, and row-to-record mapping. Database operations suspend
the current [async Task](async-io.md) while a native worker thread or the
browser storage worker executes SQLite; rows and their values are owned
snapshots.

- **Import:** `local sqlite3 = import "sqlite3"` (Titan) · `require "titan.sqlite3"` (Lua)
- **Targets:** Native & Browser (complete — all 26 members; requires a running async Task for database operations and `close`; `Row:get` and `Row:fill` are synchronous; see [On the browser](#on-the-browser))

## Quick example

Create an in-memory database, populate rows inside an explicit transaction,
query with a prepared statement, and map each row onto a Titan record:

```titan
local sqlite3 = import "sqlite3"
local io = import "io"

record Note
  id: integer
  body: string
end

function main(_args: {string}): integer
  local db = sqlite3.connect(":memory:")
  defer db:close()

  local create = db:prepare("CREATE TABLE notes(id INTEGER, body TEXT)")
  defer create:close()
  create:execute()

  local insert = db:prepare("INSERT INTO notes VALUES (?, ?)")
  defer insert:close()
  db:set_autocommit(false)
  insert:execute(1, "first note")
  insert:execute(2, "second note")
  db:commit()

  local select = db:prepare("SELECT id, body FROM notes ORDER BY id")
  defer select:close()
  local cursor = select:query()
  defer cursor:close()
  for row in cursor:fetch do
    local note = Note(0, "")
    row:fill(note)
    io.print(note.id, note.body)
  end
  return 0
end
```

Standalone executables run `main` inside an async Task automatically. When
called from Lua, schedule work and drive the Runtime as described in
[async I/O](async-io.md).

## Connections and statement lifetime

```text
record Connection
record Statement

function connect(name: string): Connection
function Connection:prepare(sql: string): Statement
function Connection:close()
function Statement:close()
```

`connect` opens a database file for reading and writing, creating it if absent.
`":memory:"` creates a private in-memory database, and `""` creates a temporary
database. Filenames reject embedded NUL bytes.

On native targets, the bundled SQLite build enables `SQLITE_THREADSAFE=1` and
opens each connection with `SQLITE_OPEN_FULLMUTEX`; independent connections run
concurrently in libuv's shared worker pool (on Windows, worker threads restore
x87 precision before SQLite runs; see [Windows build](windows-build.md)). On
both native and browser targets, a single `Connection` allows one outstanding
operation at a time; overlapping calls raise `sqlite3.Error` before submission.

`prepare` compiles exactly one SQL statement. Trailing whitespace, comments, and
empty semicolons are allowed; empty SQL, embedded NUL bytes, and multiple
statements are rejected.

A `Statement` retains its `Connection`, and a `Cursor` retains its `Statement`.
While a `Cursor` is active, it reserves execution on the whole `Connection`:
new `execute`/`query` calls and transaction changes raise, and its owning
`Statement` cannot be closed until the `Cursor` finishes or closes. Preparing
other statements, closing idle statements, and reading `get_autocommit` are
permitted when no native call is in flight.

Close resources explicitly with lexical `defer` in Cursor, Statement, Connection
order:

- `close` is idempotent.
- Closing a `Connection` with open statements raises and leaves the
  connection usable.
- Finalizing a `Statement` closes it even if SQLite reports a delayed execution
  error.
- Closing a `Cursor` early resets and clears its statement without rolling back
  any open transaction.
- Garbage collection does not perform database I/O; explicit close is required
  for prompt release.

### Closing the Lua state

Closing a Lua state releases every open `Connection` synchronously on the
closing thread: SQLite finalizes open statements (including active cursors),
rolls back open transactions, and releases descriptors and locks before state
close returns.

A suspended Task's `defer` closes in Cursor, Statement, Connection order succeed
during state teardown even though they cannot await asynchronous I/O (see
[Coroutines](coroutines.md)). If a worker operation is in flight when the state
closes, state teardown waits for that worker before releasing the connection;
the Task never resumes, and an in-flight `COMMIT` may or may not have taken
effect.

## Binding values

```text
record Blob
  const bytes: string
end
```

`execute` and `query` take positional arguments matching SQLite's exact
parameter count (repeated named placeholders share a slot; `?5` requires five
positions). Passing too few or too many arguments raises before the statement is
modified. Trailing `nil` arguments are counted via `#...`, and each call resets
and clears prior bindings before binding the new set.

| Titan argument | SQLite binding |
| --- | --- |
| `nil` | `NULL` |
| `boolean` | `INTEGER` `0` or `1` |
| `integer` | Signed 64-bit `INTEGER` |
| finite `float` | `REAL` (including integral floats) |
| `string` | Valid UTF-8 `TEXT` (no embedded NUL) |
| `sqlite3.Blob` | `BLOB` with explicit byte length |

Use `sqlite3.Blob(bytes)` for arbitrary binary data, including embedded NULs or
non-UTF-8 bytes; an empty `Blob("")` is distinct from `NULL`. `NaN`, infinities,
and composite Titan values (other records, unions, Interfaces, containers,
callables, pointers) are rejected as bindings. Reflection preserves integer vs
float tags on input, though SQLite column affinity may coerce stored values.

## Executing and querying

```text
record Column
  const name: string
  const declared_type: string?
end

record Cursor
  const columns: const {Column}
end

function Statement:execute(...: value): integer
function Statement:query(...: value): Cursor
function Cursor:fetch(): Row?
function Cursor:close()
```

`execute` binds arguments, runs one step requiring `SQLITE_DONE`, captures
`sqlite3_changes64`, and resets/clears the statement for reuse. If the statement
yields a row (`SQLITE_ROW`), `execute` raises an error directing you to `query`
(note that a statement with `RETURNING` may already have modified rows before
returning that row). The returned integer is SQLite's connection
[change counter](https://sqlite.org/c3ref/changes.html) from the latest
completed `INSERT`, `UPDATE`, or `DELETE`; statements such as `CREATE TABLE` or
an empty `SELECT` do not reset it.

`query` accepts statements with result columns (`SELECT` or `RETURNING`). It
binds arguments, executes the first step, captures `Cursor.columns` (after any
SQLite schema reprepare), and buffers the first row. Each `Cursor:fetch()`
returns one owned `Row` and advances the cursor, returning `nil` after the final
row and releasing the connection's execution reservation. An empty result
returns an already-exhausted cursor with populated `columns`. Repeated fetches
on an exhausted cursor return `nil`; fetching an explicitly closed cursor
raises. A failed fetch closes the cursor and retires that execution.

## Rows and mapping

```text
record Row
  const columns: const {Column}
end

function Row:get(i: integer): value
function Row:fill(target: value)
```

`#row.columns` is the column count, and `Row:get(i)` takes 1-based indices in
`1..#row.columns`. A row of all `NULL`s is a non-nil `Row`, and trailing
`NULL`s do not shorten `columns`. `Column.declared_type` is descriptive metadata
(`nil` for expressions) and does not affect value conversion.

| SQLite storage class | `Row:get` result |
| --- | --- |
| `NULL` | `nil` |
| `INTEGER` | `integer` |
| `REAL` | `float` |
| `TEXT` | copied `string` |
| `BLOB` | `sqlite3.Blob` containing copied bytes |

Rows are self-contained snapshots that outlive their `Cursor`, `Statement`, and
`Connection`. Duplicate column names are preserved in `columns` and are
unambiguous by index.

For records with `const` fields, validation invariants, or nested structure,
write a small typed factory:

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

`Row:fill(target)` populates an existing mutable record via
[reflection](standard-library-reflect.md). Before writing any field, it verifies
that column names are unique, match the record's public fields one-to-one, and
target mutable fields of supported types (`nil`, `value`, `boolean`, `integer`,
`float`, `string`, `Blob`, and their Options; `local` fields are ignored).
Writes proceed in field declaration order using ordinary dynamic conversion:
`NULL` requires a nil-admitting field, `TEXT` fills `string`, `BLOB` fills
`Blob`, and `boolean` accepts only integer `0` or `1`. Because validation
precedes writes but per-field conversions run sequentially, a conversion error
can leave earlier fields updated; use a factory when atomic construction is
required.

## Transactions

```text
function Connection:get_autocommit(): boolean
function Connection:set_autocommit(autocommit: boolean)
function Connection:commit()
function Connection:rollback()
```

`get_autocommit` queries SQLite's live autocommit state directly, reflecting
changes made by explicit SQL statements or automatic SQLite rollbacks.

| Call | Behavior |
| --- | --- |
| `set_autocommit(false)` in autocommit | `BEGIN DEFERRED` |
| `set_autocommit(false)` in a transaction | no-op |
| `set_autocommit(true)` in a transaction | `COMMIT` |
| `set_autocommit(true)` in autocommit | no-op |
| `commit()` / `rollback()` in a transaction | `COMMIT` / `ROLLBACK` |
| `commit()` / `rollback()` in autocommit | no-op |

`commit()` and `rollback()` return the connection to autocommit mode without
opening a new transaction. Enabling autocommit commits any open transaction (a
failed `COMMIT` can leave the transaction active). Close active cursors before
changing transaction state, and use SQL `SAVEPOINT`/`RELEASE` statements for
nested savepoints:

```titan
local sqlite3 = import "sqlite3"

function transfer_funds(db: sqlite3.Connection, from_id: integer,
                        to_id: integer, amount: integer)
  local debit = db:prepare("UPDATE accounts SET balance = balance - ? WHERE id = ?")
  defer debit:close()
  local credit = db:prepare("UPDATE accounts SET balance = balance + ? WHERE id = ?")
  defer credit:close()

  db:set_autocommit(false)
  debit:execute(amount, from_id)
  credit:execute(amount, to_id)
  db:commit()
catch
  if not db:get_autocommit() then db:rollback() end
  raise
end
```

## Errors and cancellation

```text
record Error
  const message: string
  const code: integer?
  const extended_code: integer?
  const operation: string
end
```

SQLite failures and contract violations raise `sqlite3.Error`. `operation` names
the public entry point; native SQLite errors populate `code` and
`extended_code`, while wrapper errors leave both `nil`. When execution fails and
statement cleanup also fails, the original SQLite error is preserved with
cleanup details appended to `message`. Busy/locked errors are raised directly
without automatic retries.

Database operations run on libuv's shared worker pool via `async.run_foreign`.
Pending Task cancellation prevents submitting new work, but an already-accepted
operation finishes before cancellation is delivered—so cancellation may arrive
after a write or `COMMIT` has succeeded. Cancellation retains its async
cancellation reason, and worker submission errors raise `async.OperationError`.
Close, reset, and finalization run through ownership cleanup and complete even
when a Task is cancelled.

## Transferring connections

```text
function Connection:to_transfer_payload(): string
function Connection.from_transfer_payload(payload: string): Connection
```

`Connection` implements the
[custom record transfer protocol](async-io.md#custom-record-transfer).
`async.TransferValue.from_value(db)` detaches the native SQLite handle
synchronously, and `:to_value()` adopts it into a fresh `Connection` in the
receiving state (no running Task is required for either hook; subsequent queries
run on the receiving state's worker queue).

Detachment rejects a closed connection, an in-flight operation, an active
cursor, or any open statement—close all cursors and statements first. After
detachment, every alias of the source connection behaves as closed and its
`close()` is a no-op. The exact native database moves intact, including a
private `:memory:` database, open transaction, and savepoints.

Transferring a `Connection` follows the
[shared manual-handoff rules](standard-library-transfer.md#shared-manual-handoff-rules).
`Connection` has no `discard_transfer_payload`: adopt each payload exactly once,
retain it while delivery is pending, and adopt-and-close it locally if delivery
fails (for example, if `async.send` rejects the carrier). Replaying a payload
causes double-close or use-after-free, and abandoning one leaks the database.
The same rules apply when a transferred closure captures a `Connection`.

## On the browser

`titan.sqlite3` exposes all **26** public members on `--target browser`.
Importing `sqlite3` automatically links the
[browser storage runtime](browser-target.md#filesystem-and-durable-storage) and
publishes `<stem>.worker.mjs` and `<stem>.sqlite3.wasm` beside `<stem>.mjs`.

- **Worker-hosted execution:** SQLite runs inside the instance's dedicated
  storage worker, keeping `async` Tasks cooperative and non-blocking. Databases
  may use `":memory:"`, `""`, the ephemeral in-memory filesystem, or durable
  OPFS mounts configured through `create({ vfs })`.
- **Working directory and paths:** `connect` resolves relative database names
  against `os.cwd()`, and every operation carries the calling state's current
  working directory so relative paths resolved by SQLite itself (such as
  `ATTACH` and `VACUUM INTO`) stay coherent with `os.chdir` and `fs.chdir`.
  When the working directory cannot be entered, relative SQLite paths fail with
  `SQLITE_CANTOPEN` while absolute paths work normally. As on native targets,
  `file:` URI filenames are not enabled; database paths must be `":memory:"`,
  `""`, or a filesystem path.
- **Cancellation, Lua-state close, and disposal:** Task cancellation follows the
  native completion-before-cancellation rule: an already-accepted request
  completes in the worker and cleans up unpublished handles before cancellation
  is delivered. Unlike native teardown, closing a Lua state cannot wait
  synchronously for the storage worker: every open connection is retired
  immediately without waiting, and the storage worker finalizes open statements,
  rolls back open transactions, and closes the connection after any
  already-in-flight operation finishes. Graceful `instance.dispose()` waits for
  in-flight SQLite work and queued retirements and flushes durable mounts;
  `instance.dispose({ force: true })` terminates the worker immediately and
  rejects with `TITAN_BROWSER_DISPOSED_DIRTY` if uncommitted writes or open
  write transactions were lost.
- **Transferring connections:** `Connection:to_transfer_payload()` and
  `Connection.from_transfer_payload()` transfer an idle connection across
  `lua.new()` states within the same browser instance. In addition to open
  statements, active cursors, and in-flight operations, detachment rejects a
  connection with pending deferred statement cleanup from a prior finalizer
  (`"connection has pending statement cleanup"`).
- **Browser frame limits:** Single requests and replies are bounded to **64
  MiB**, SQL strings and database paths to **16 MiB**, individual `TEXT` or
  `BLOB` cells to **32 MiB**, bound parameters to **32,766**, open connections
  to **1,024**, and open statements per connection to **4,096**. Exceeding a
  frame, text, or cell bound raises `sqlite3.Error` with `SQLITE_TOOBIG`.
