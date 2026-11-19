# I/O standard library

The `io` standard module defines Titan's standard byte-stream Interfaces
(`Reader`, `Writer`, `Closer`, and their combinations), formatted standard
output (`io.print`), and ownership-safe line iteration (`io.lines`). Titan
imports it with `local io = import "io"` (parser sugar for
`import "titan.io"`); Lua loads the runtime functions (`print`, `lines`) with
`require "titan.io"`.

**Target availability:** Native & Browser (complete; concrete stream
availability varies by target, see [On the browser](#on-the-browser)).

## Example

Because satisfaction is structural at every conversion site, one function
accepting `io.Reader`, `io.Writer`, or `io.ReaderCloser` works identically on
in-memory strings, files, sockets, TLS connections, and process pipes:

```titan
local io = import "io"
local strings = import "string"

function copy_all(src: io.Reader, dst: io.Writer): integer
  local total = 0
  for chunk in src:read do
    dst:write(chunk)
    total = total + #chunk
  end
  return total
end

function filter_lines(src: io.ReaderCloser, prefix: string): string
  local out = strings.writer()
  defer out:close()
  for line in io.lines(src) do
    if strings.sub(line, 1, #prefix) == prefix then
      out:write(line .. "\n")
    end
  end
  return out:drain()
end

function demo_streams(): (integer, string)
  local buf = strings.writer()
  defer buf:close()
  local copied = copy_all(strings.reader("alpha\nbeta\n"), buf)
  local matched = filter_lines(
    strings.reader("ok:1\nskip\nok:2\n"), "ok:")
  return copied, matched
end
```

## Stream contracts, delimiters, and closing

- **Async Tasks:** Operations reaching an asynchronous concrete stream—including
  `io.print` and stepping an `io.lines` iterator—may suspend and follow that
  stream's async Task contract. Constructing the iterator tuple with
  `io.lines(reader)` does not read or close `reader`. A standalone Titan program
  importing `io` installs the async bootstrap automatically; a Lua host calls
  yielding operations inside `async.run` and drives them with `async.loop`.
- **Chunks and delimiters:** `read()` returns the next binary chunk (possibly
  `""`) or `nil` at end of stream, without promising a particular chunk size.
  `read_until(delimiter, chop?)` searches across chunk boundaries for the first
  literal binary `delimiter`, retaining trailing bytes for later reads; setting
  `chop` to `true` omits `delimiter` from the returned string. An unterminated
  tail at EOF is returned once before the next read returns `nil`. Empty
  delimiters raise.
- **Closing:** A successful `close()` is idempotent. After a failed `close()`,
  calling `close()` again is safe (either retrying pre-commit work or acting as
  a no-op once terminal). Once a `ReaderCloser` or `ReaderWriterCloser` reaches
  its terminal closed state, `read()` and `read_until()` return `nil`.
- **Ownership and errors:** An Interface wrapper keeps its concrete object
  alive without duplicating the underlying OS resource. These Interfaces define
  method shapes rather than a shared error record or cancellation policy;
  concrete implementations raise their own errors.
- **Windows request limit:** On Windows, libuv caps each individual file-read
  or stream-write buffer at 4 GiB minus 1 byte (`2^32 - 1`); larger single
  requests raise a range error rather than truncating.

Interfaces exist only in Titan's type namespace and do not appear as fields on
the Lua `titan.io` module table; Lua code can pass an Interface wrapper
obtained from Titan back into Titan functions expecting that exact Interface.

## Stream interfaces

```text
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

## Printing

```text
function print(...: value)
```

`print` converts every argument left to right with `string.tostring`, joins
adjacent results with `"\t"`, appends `"\n"`, and performs one
`os.stdout:write` call with the complete byte string. With no arguments it
writes `"\n"`. Because all arguments convert before writing, a conversion error
never emits a partial line.

`print` reads the active `os.stdout` module variable at each write; reassigning
`os.stdout` to another `os.OutputStream` redirects subsequent calls. Errors from
conversion or writing propagate directly.

## Line iteration

```text
function lines(reader: ReaderCloser):
    (function (ReaderCloser): (string?), ReaderCloser, nil,
     function (ReaderCloser): ())
```

`lines(reader)` returns the four-slot generic-`for` tuple
`(next_line, reader, nil, close_reader)` and transfers ownership of closing
`reader` to the loop. Each iteration calls `reader:read_until("\n", true)`
(never `read()`), yielding `""` for empty lines and stopping only on `nil` EOF.
The loop closes `reader` on EOF, `break`, `return`, or raised error. Do not
read from or close `reader` separately while the iterator owns it.

```titan
local fs = import "fs"
local io = import "io"

function count_nonempty_lines(file_path: string): integer
  local file = fs.open(file_path, "r")
  local count = 0
  for line in io.lines(file) do
    if #line > 0 then count = count + 1 end
  end
  return count
end
```

## Standard implementations

Standard-library records satisfy these Interfaces structurally at conversion
sites (see [Interfaces](interfaces.md)):

| Concrete type | Interfaces | Dispatch |
| --- | --- | --- |
| `net.Connection` | All seven | Exact |
| `ssl.Connection` | All seven | Exact |
| `fs.File` | All seven | Adjusted |
| `os.InputStream` | `Reader`, `Closer`, `ReaderCloser` | Exact |
| `os.OutputStream` | `Writer`, `Closer`, `WriterCloser` | Exact |
| `os.InputOutputStream` | All seven | Exact |
| `string.StringReader` | `Reader`, `Closer`, `ReaderCloser` | Exact |
| `string.StringWriter` | `Writer`, `Closer`, `WriterCloser` | Exact |
| `async.ChannelReader` | `Reader`, `Closer`, `ReaderCloser` | Exact |
| `async.ChannelWriter` | `Writer`, `Closer`, `WriterCloser` | Exact |
| `net.Server` | `Closer` | Exact |
| `ssl.Server` | `Closer` | Exact |
| `http.ClientResponse` | `Reader`, `Closer`, `ReaderCloser` | Exact |
| `http.Request` | `Reader` | Exact |
| `http.Response` | `Writer`, `Closer`, `WriterCloser` | Exact |
| `http.Server` | `Closer` | Exact |
| `websocket.Connection` | `Closer` | Exact |
| `timer.Ticker` | `Closer` | Exact |

- `fs.File` uses adjusted dispatch because `File:read(max_bytes: integer?)`
  receives `nil` for the Interface's zero-argument `read()`, and
  `File:write(data): integer` has its byte-count return value discarded.
- `os.InputStream` and `os.OutputStream` are named for the Titan caller's
  direction (`process.stdin` is an `OutputStream`; `process.stdout` and
  `process.stderr` are `InputStream` values).
- See concrete contracts in [Filesystem](standard-library-fs.md),
  [OS](standard-library-os.md), [String](standard-library-string.md),
  [Async](async-io.md), [TCP](standard-library-net.md),
  [TLS](standard-library-ssl.md), [HTTP](standard-library-http.md),
  [WebSocket](standard-library-websocket.md), and
  [Timer](standard-library-timer.md).

## On the browser

The complete `io` module is available on the browser target with identical
Interfaces and operations. `io.print` writes through browser `os.stdout`
(awaiting the embedding's output sink), and `io.lines` works over any
browser-available `ReaderCloser`.

Browser-available implementations from the table above are `os.InputStream`,
`os.OutputStream` (embedding parent streams), `string.StringReader`,
`string.StringWriter`, `async.ChannelReader`, `async.ChannelWriter`,
`http.ClientResponse`, `websocket.Connection`, and `timer.Ticker`. Filesystem,
socket, HTTP server, and shell stream types are native-only.
