# I/O Interfaces

The `io` standard module is a type-only vocabulary for byte streams. Import it
from Titan as `io` or `titan.io`:

```titan
local io = import "io"

function copy_one(reader: io.Reader, writer: io.Writer)
    local bytes = reader:read()
    if bytes then writer:write(bytes as string) end
end
```

The qualified Lua module is `titan.io`, but its returned module userdata has no
Interface members: Interfaces exist only in Titan's type namespace. Lua can
still pass an Interface wrapper it received from Titan back to a Titan function
expecting that exact Interface type.

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

`read` returns the next nonempty binary chunk, or `nil` at end of stream.
`read_until` returns through the first occurrence of `delimiter`; when `chop`
is true, it omits that delimiter from the result. An end-of-stream tail is
returned once before the next read returns `nil`. Implementations reject an
empty delimiter. `write` accepts a binary string, and `close` releases or
finishes the underlying resource according to that resource's own contract.

These Interfaces intentionally describe method shapes rather than one shared
buffering, cancellation, or ownership policy. Consult the concrete module's
chapter for those details.

## Standard implementations

Satisfaction is structural at each coercion site; none of these records has an
`implements` declaration. The standard library currently supplies:

| Concrete type | Interfaces | Dispatch |
| --- | --- | --- |
| `net.Connection` | all seven | exact |
| `fs.File` | all seven | adjusted |
| `os.InputStream` | `Writer`, `Closer`, `WriterCloser` | exact |
| `os.OutputStream` | `Reader` | exact |
| `net.Server` | `Closer` | exact |
| `timer.Ticker` | `Closer` | exact |

`net.Connection` has the exact four primitive method shapes, so every
corresponding wrapper slot points directly to its concrete method.

`fs.File:read(max_bytes: integer?)` accepts the Interface's zero-argument call
by receiving a filled `nil` optional argument. `fs.File:write(data)` returns
the number of bytes written, while the I/O Interfaces promise no result, so
Interface dispatch discards that surplus result. `read_until` and `close` are
otherwise exact. These ordinary callable adjustments make each `fs.File`
wrapper adjusted; they do not make the record and Interface gradually
consistent or lift the conversion through Arrays, Maps, or function types.

`os.InputStream` is the writable stdin side of a spawned process. Its exact
`write` and `close` methods satisfy the three writer/closer combinations.
`os.OutputStream`, used by both stdout and stderr, has exact `read` and
`read_until` methods and therefore satisfies `Reader`. Closing process input
does not imply a close operation on either output stream.

`net.Server` and `timer.Ticker` satisfy `Closer` incidentally through their
existing exact `close()` methods. The Interface does not imply that all
closers share idempotence, cancellation, or post-close behavior.

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
errors. Likewise, `Closer` only supplies the `close()` operation; whether
closing waits for queued work, coalesces concurrent callers, or is safe to
repeat remains part of the concrete type's contract.

An Interface wrapper keeps the concrete object and its owning module alive.
It does not duplicate the resource, and creating several wrappers around one
record does not create several files, sockets, process pipes, servers, or
timers.
