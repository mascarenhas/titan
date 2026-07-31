# I/O standard library

The `io` standard module provides a type vocabulary for byte streams,
formatted standard output, ownership-safe line iteration, and shell-command
I/O. Titan imports the canonical module with `import "io"`:

```titan
local io = import "io"

function copy_one(reader: io.Reader, writer: io.Writer)
    local bytes = reader:read()
    if bytes then writer:write(bytes as string) end
end
```

The qualified Lua module is `titan.io`. Interfaces exist only in Titan's type
namespace and are not fields of the returned module userdata; the runtime
module exposes `print`, `lines`, and `popen`. Lua can still pass an Interface
wrapper it received from Titan back to a Titan function expecting that exact
Interface type.

Operations in this module that reach a stream, process, or yielding string
builder must run inside an async Task. In particular, `print`, iteration over a
tuple returned by `lines`, `popen`, and the resulting process stream's methods
can suspend. Merely constructing the iterator tuple with `lines(reader)` does
not read or close the Reader. A standalone Titan program that imports `io`
gets the async bootstrap transitively; a Lua host should call the yielding
operations from `async.run` and drive them with `async.loop`.

## Interface inventory

The module declares exactly seven nonempty Interfaces:

```titan
interface Reader
    function read(): string?
    function read_until(delimiter: string, chop: boolean?): string?
end

interface Writer
    function write(data: string)
end

interface Closer
    function close()
end

interface ReaderWriter
    function read(): string?
    function read_until(delimiter: string, chop: boolean?): string?
    function write(data: string)
end

interface ReaderCloser
    function read(): string?
    function read_until(delimiter: string, chop: boolean?): string?
    function close()
end

interface WriterCloser
    function write(data: string)
    function close()
end

interface ReaderWriterCloser
    function read(): string?
    function read_until(delimiter: string, chop: boolean?): string?
    function write(data: string)
    function close()
end
```

`read` returns the next binary chunk, which may be empty, or `nil` at end of
stream.
`read_until` returns through the first occurrence of `delimiter`; when `chop`
is true, it omits that delimiter from the result. An end-of-stream tail is
returned once before the next read returns `nil`. Implementations reject an
empty delimiter. `write` accepts a binary string. A successful `close` is
idempotent: later calls succeed without repeating the physical close. A close
that raises is still safe to call again; depending on the resource, that call
either retries a pre-commit close or observes a terminal closed state and does
nothing. Whether close waits for queued work, shields cancellation, or permits
later writes remains the concrete resource's contract. Once a ReaderCloser or
ReaderWriterCloser reaches its terminal closed state, both read operations
return nil.

Except for that repeat-call guarantee, these Interfaces intentionally describe
method shapes rather than one shared buffering, cancellation, or ownership
policy. Consult the concrete module's chapter for those details.

## Printing

```titan
function print(...: value)
```

`print` converts every argument from left to right with
`string.tostring`, places one tab between adjacent results, appends one
newline, and performs exactly one `os.stdout:write` with the complete binary
string. With no arguments it writes just the newline. A conversion error occurs
before the output write, so `print` never emits a prefix of one call.

`os.stdout` is a module variable, and `print` uses its current value at the
write. Replacing it with another `os.OutputStream` therefore redirects later
calls without changing `io`. The conversion and write retain their concrete
error behavior; `print` does not convert failures into status values.

## Line iteration

```titan
function lines(reader: ReaderCloser):
    ((ReaderCloser) -> string?, ReaderCloser, nil,
     (ReaderCloser) -> ())
```

`lines` transfers responsibility for closing `reader` to a generic-for
iterator. Each step calls exactly
`reader:read_until("\n", true)`, so the newline delimiter is consumed and
omitted. An empty line is returned as `""` and remains a real iteration;
only nil EOF stops the loop.

```titan
local fs = import "fs"
local io = import "io"

local file = fs.open("input.txt", "r")
for line: string in io.lines(file) do
  consume(line)
end
```

The returned tuple is `(next_line, reader, nil, close_reader)`. The
ReaderCloser itself is the iterator state, so no wrapper record or bound
closure is needed. The underlying resource reaches its terminal closed state after ordinary EOF,
`break`, `return`, or an error from reading or from the loop body. At EOF
the iterator closes before returning nil; generic-for's final close callback
may call the idempotent closer again. If the EOF close raises, that finalizer
may retry it while the error unwinds. Calling the returned iterator again
after its close function has run calls the closed ReaderCloser, whose
`read_until` returns nil, and then performs another safe close.

`lines` does not call `reader:read()`. The concrete `read_until` and
`close` operations retain their own yielding, cancellation, and error
contracts. Callers must not separately close or consume the Reader while the
iterator owns it.

## Shell commands

```titan
record InputOutputStream

function InputOutputStream:read(): string?
function InputOutputStream:read_until(delimiter: string,
                                      chop: boolean?): string?
function InputOutputStream:write(data: string)
function InputOutputStream:close()
function InputOutputStream:wait(): os.ExitStatus

function popen(command: string): InputOutputStream
```

`popen` intentionally invokes `/bin/sh -c command`; it is the standard
library's shell-string convenience, not an argv parser. Use `os.spawn` when an
executable and arguments must be passed directly or stdout and stderr must
remain separate. The command is text and rejects an embedded NUL before native
resources are created.

The child gets a captured stdin pipe and one captured pipe shared by stdout and
stderr. `InputOutputStream:write` writes the child's stdin, while `read` and
`read_until` consume that one merged output stream. There is exactly one
high-level facade over the merged pipe, so no second reader can race through a
separate stderr object. The record satisfies `ReaderWriterCloser` exactly and
adds `wait`.

`wait` reaps the child and stores its complete `os.ExitStatus`. Later calls
return the stored status without waiting again; normal and signal termination
retain the same representation documented by `os.Process:wait`.

`close` is idempotent. Its first call closes stdin, requests `term` only when
the child is still running, and waits for that termination when necessary.
A final cleanup always closes the one merged InputStream and discards unread
buffered output. The composite facade reaches its terminal closed state only
after process cleanup completes. If cancellation or an error interrupts that
cleanup, a later `close` retries the remaining process observation while the
already-disposed output close is a no-op. If `wait` has already stored a
status, `close` does not signal the exited child. A later `wait` returns the
cached or already-retained process status; after output disposal, later `read`
and `read_until` calls return nil.

For large bidirectional traffic, schedule writing and reading concurrently so
neither operating-system pipe can fill while the other direction is waiting.
Read merged output through EOF before an ordinary `wait` when the child may
produce more than one pipe buffer. Errors and cancellation follow the same
Task and native-owner cleanup rules as direct process streams.

## Standard implementations

Satisfaction is structural at each coercion site; none of these records has an
`implements` declaration. The standard library currently supplies:

| Concrete type | Interfaces | Dispatch |
| --- | --- | --- |
| `net.Connection` | all seven | exact |
| `fs.File` | all seven | adjusted |
| `os.InputStream` | `Reader`, `Closer`, `ReaderCloser` | exact |
| `os.OutputStream` | `Writer`, `Closer`, `WriterCloser` | exact |
| `io.InputOutputStream` | all seven | exact |
| `string.StringReader` | `Reader`, `Closer`, `ReaderCloser` | exact |
| `string.StringWriter` | `Writer`, `Closer`, `WriterCloser` | exact |
| `net.Server` | `Closer` | exact |
| `timer.Ticker` | `Closer` | exact |

These Interface relations do not create a universal stream class.
`os.InputStream` and `os.OutputStream` are concrete process-stdio records,
covering the Titan process and captured child endpoints. An `fs.File` remains
a `File`, and a `net.Connection` remains a socket connection, even though each
can be converted structurally to compatible Reader, Writer, or Closer views.

`net.Connection` has the exact four primitive method shapes, so every
corresponding wrapper slot points directly to its concrete method.

`fs.File:read(max_bytes: integer?)` accepts the Interface's zero-argument call
by receiving a filled `nil` optional argument. `fs.File:write(data)` returns
the number of bytes written, while the I/O Interfaces promise no result, so
Interface dispatch discards that surplus result. `read_until` and `close` are
otherwise exact. These ordinary callable adjustments make each `fs.File`
wrapper adjusted; they do not make the record and Interface gradually
consistent or lift the conversion through Arrays, Maps, or function types.

`os.InputStream`, used by parent stdin and captured child output, has exact
`read`, `read_until`, and `close` methods and therefore satisfies `Reader`,
`Closer`, and `ReaderCloser`.
`os.OutputStream`, used by parent stdout/stderr and captured child stdin, has
exact `write` and `close` methods satisfying the three writer/closer
combinations. These names describe the Titan caller's direction, not a child
descriptor name. Calling `process.stdin:close()` does not imply a close
operation on either readable stream.

`io.InputOutputStream` delegates reads and writes to its one captured
input/output pair; its close method coordinates both endpoints and the child
process. Those exact method shapes satisfy every Interface in this chapter;
the additional `wait` method does not affect structural conversion.

`net.Server` and `timer.Ticker` satisfy `Closer` incidentally through their
existing exact, idempotent `close()` methods. Cancellation and post-close
behavior remain concrete concerns.

For the concrete contracts, see [Filesystem](standard-library-fs.md),
[TCP networking](standard-library-net.md),
[Operating-system helpers](standard-library-os.md), and
[Timers](standard-library-timer.md). For wrapper conversion, nominal identity,
casts, and Lua behavior, see [Interfaces](interfaces.md).

## Delimiter and chunk boundaries

`read_until` searches the logical byte stream, not only each native chunk. An
implementation must therefore recognize a delimiter split across two
underlying reads and retain any bytes after the match for the next call.
`chop` affects only the returned match; it does not change which bytes were
consumed.

The `Reader` contract does not promise a particular chunk size. Code that
needs the complete stream should read until `nil` and combine the chunks, or
use a concrete module's whole-input helper when available.

## Closing and errors

The Interfaces do not add a common error record. Concrete implementations
raise their ordinary Titan errors, including cancellation and resource
errors. `Closer` requires every later close call to be safe: a terminal close
becomes an idempotent no-op, while a pre-commit failure may retry. Whether
closing waits for queued work or coalesces concurrent callers remains part of
the concrete type's contract.

An Interface wrapper keeps the concrete object and its owning module alive.
It does not duplicate the resource, and creating several wrappers around one
record does not create several files, sockets, process pipes, servers, or
timers.
