# I/O standard library

The `io` standard module provides a type vocabulary for byte streams,
formatted standard output, and ownership-safe line iteration.
Titan imports the canonical module with `import "io"`:

```titan
local io = import "io"

function copy_one(reader: io.Reader, writer: io.Writer)
    local bytes = reader:read()
    if bytes then writer:write(bytes) end
end
```

The condition tests presence but does not flow-narrow `bytes`. The `write`
argument is a bare `string` context, so Titan performs the checked option force
automatically; an explicit `bytes as string` is redundant.

The qualified Lua module is `titan.io`. Interfaces exist only in Titan's type
namespace and are not fields of the returned module userdata; the runtime
module exposes `print` and `lines`. Lua can still pass an Interface
wrapper it received from Titan back to a Titan function expecting that exact
Interface type.

Operations that reach a concrete stream follow its async Task contract.
In particular, `print` and iteration over a tuple returned by `lines` can
suspend. Merely constructing the iterator tuple with `lines(reader)` does
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

The experimental Windows build checks native buffer lengths against libuv's
32-bit unsigned length field. A single file-read request or file/stream-write
buffer larger than 4 GiB minus one byte raises a numeric range error before
submission; Titan does not silently truncate or split that buffer. Unix keeps
its native `size_t` length range. Ordinary allocation and operating-system
limits can reject smaller requests as well.

## Printing

```text
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

```text
function lines(reader: ReaderCloser):
    (function (ReaderCloser): (string?), ReaderCloser, nil,
     function (ReaderCloser): ())
```

`lines` transfers responsibility for closing `reader` to a generic-for
iterator. Each step calls exactly
`reader:read_until("\n", true)`, so the newline delimiter is consumed and
omitted. An empty line is returned as `""` and remains a real iteration;
only nil EOF stops the loop.

```text
local fs = import "fs"
local io = import "io"

local file = fs.open("input.txt", "r")
for line in io.lines(file) do
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

## Standard implementations

Satisfaction is structural at each coercion site; none of these records has an
`implements` declaration. The standard library currently supplies:

| Concrete type | Interfaces | Dispatch |
| --- | --- | --- |
| `net.Connection` | all seven | exact |
| `ssl.Connection` | all seven | exact |
| `fs.File` | all seven | adjusted |
| `os.InputStream` | `Reader`, `Closer`, `ReaderCloser` | exact |
| `os.OutputStream` | `Writer`, `Closer`, `WriterCloser` | exact |
| `os.InputOutputStream` | all seven | exact |
| `string.StringReader` | `Reader`, `Closer`, `ReaderCloser` | exact |
| `string.StringWriter` | `Writer`, `Closer`, `WriterCloser` | exact |
| `async.ChannelReader` | `Reader`, `Closer`, `ReaderCloser` | exact |
| `async.ChannelWriter` | `Writer`, `Closer`, `WriterCloser` | exact |
| `net.Server` | `Closer` | exact |
| `ssl.Server` | `Closer` | exact |
| `http.ClientResponse` | `Reader`, `Closer`, `ReaderCloser` | exact |
| `http.Request` | `Reader` | exact |
| `http.Response` | `Writer`, `Closer`, `WriterCloser` | exact |
| `http.Server` | `Closer` | exact |
| `websocket.Connection` | `Closer` | exact |
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

`os.InputOutputStream`, returned by
[`os.popen`](standard-library-os.md#shell-commands), delegates reads and writes
to its one captured input/output pair; its close method coordinates both
endpoints and the child process. Those exact method shapes satisfy every
Interface in this chapter; the additional `wait` method does not affect
structural conversion.

`ssl.Connection` has the same four exact stream method shapes as
`net.Connection`; its transport supervisor permits one reader and one writer
to progress concurrently. The HTTP client response and server request expose their
decoded streaming bodies through exact Reader methods; a Response supplies an
exact Writer/Closer pair. These shapes do not expose their transports or
protocol parser through the Interface.

`net.Server`, `ssl.Server`, `http.Server`, `websocket.Connection`, and
`timer.Ticker` satisfy `Closer`
incidentally through their existing exact, idempotent `close()` methods.
Cancellation and post-close behavior remain concrete concerns.

For the concrete contracts, see [Filesystem](standard-library-fs.md),
[TCP networking](standard-library-net.md),
[TLS](standard-library-ssl.md), [HTTP/1.1](standard-library-http.md),
[WebSocket messages](standard-library-websocket.md),
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
