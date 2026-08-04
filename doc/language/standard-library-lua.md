# Lua loading standard library

The `titan.lua` module compiles Lua chunks, reads chunks through Titan I/O,
executes Lua files asynchronously, and loads Lua, C, or Titan modules into the
current Lua state. Import it by its qualified name:

```titan
local lua = import "titan.lua"
```

There is deliberately no compiler-level `lua` import alias, and this module
does not replace Lua's global `load`, `dofile`, or `require`. Lua code
loads the standard-provider module with `require "titan.lua"`.

## Loading a string

```titan
function load(chunk: string, name: string?, env: value):
    (...: value) -> (...: value)
```

`load` compiles all bytes in `chunk` as a Lua text or binary chunk. It uses
an explicit byte length, so an embedded zero byte is never mistaken for the end
of the input. An invalid text chunk, an invalid binary chunk, or any other load
failure raises the Lua error; unlike Lua's global `load`, this API does not
return a `(nil, message)` pair.

`name` is the chunk name used in diagnostics. When it is omitted or nil, the
chunk string itself is the name, matching Lua's default. The returned callable
forwards a run-time-sized sequence of `value` arguments and results, including
nil elements:

```titan
local lua = import "titan.lua"

local chunk = lua.load("return ...", "=passthrough", nil)
return chunk("first", nil, "third")
```

When `env` is omitted or nil, the chunk retains the ordinary global
environment. A nonnil value replaces its first upvalue, which is `_ENV` for
an ordinary text chunk. This is Lua's environment rule: the supplied value need
not be a Map, and indexing a value that cannot satisfy the chunk's global
accesses raises when the chunk runs. For a binary chunk, the first upvalue is
set regardless of its debug name; a chunk with no upvalues simply ignores the
environment.

`load` compiles but does not execute the chunk. Errors raised later by the
callable propagate normally.

## Loading through a Reader

```titan
function load_from_reader(reader: io.Reader, name: string?, env: value):
    (...: value) -> (...: value)
```

`load_from_reader` uses `reader:read` as a generic-for iterator. Every nonnil
string, including `""`, is the next exact chunk of Lua input, and nil is EOF.
After EOF the collected bytes are compiled with the same name, environment,
error, and flexible-call rules as `load`.

Reader methods may yield; each accepted chunk is appended through a
synchronous `titan.string` writer so loading adds no scheduling boundary of
its own. When the supplied Reader yields, the function must run in an async
Task with the usual loop discipline. It never closes the Reader, whether
reading or compilation succeeds or raises; ownership remains with the caller.

## Executing a file

```titan
function dofile(filename: string, ...: value): (...: value)
```

`dofile` opens `filename` with
[`fs.open`](standard-library-fs.md), compiles the complete file with chunk
name `@filename`, and executes it. It forwards every argument to the chunk and
every result back to its caller without collapsing inner nil values. The File
is closed after success, a read or syntax error, or an error raised while the
chunk runs.

Opening and reading use asynchronous filesystem operations. A call which
reaches those operations must therefore run in an async Task with the usual
[`async`](async-io.md) loop discipline.

## Loading modules

```titan
function require(modname: string): value
```

`require` shares Lua's registry-backed `package.loaded` table. A truthy
cached value is returned immediately. A loader's nonnil result is stored and
returned; if both its result and `package.loaded[modname]` are nil, `true`
is installed as the fallback. A stored false value deliberately causes the
next call to load the module again.

Loader lookup preserves the ordinary Lua ordering while replacing only the
blocking source-file operation:

1. Call `package.searchers[1]`, normally the preload searcher.
2. Search every template in `package.path` with asynchronous `fs`
   operations. Dots in `modname` become directory separators and every `?`
   in a template becomes that path. A readable candidate is compiled and
   receives `(modname, filename)` when its loader runs.
3. Call searchers at indexes 3 and above, normally the two C searchers followed
   by any appended custom searchers, until the first nil slot.

This source pass loads ordinary Lua files and generated Titan Lua shims. A shim
then performs its normal exact-provider lookup, so `titan.lua.require` does
not need a special Titan-loader branch. C modules continue through Lua's
installed C searchers.

The second searcher slot is reserved for the asynchronous source pass and is
never called. Replacing `package.searchers[2]` therefore does not replace that
pass. Moving or copying Lua's built-in source searcher to another slot is not
supported, because invoking it there would reintroduce blocking file I/O.
Replacement or appended custom searchers in the callable slots are supported;
they receive the module name and may return a loader plus loader data, or a
diagnostic string. Searchers and loaders are invoked through Titan's
non-yieldable Lua-callable boundary. A custom searcher or loader that attempts
to yield raises rather than suspending.

Missing source candidates contribute `no file` lines, and diagnostic strings
from other searchers are accumulated into the final
`module ... not found` error. Once a source candidate opens, a read or
compilation failure is terminal instead of being treated as another miss.
Task cancellation during open or reading remains authoritative: the Task's
terminal status is `cancelled` with its original
`async.CancellationReason`, and no contextual source-load failure is reported
as an uncaught Task error.

Source lookup can yield between the start of a load and installing its cache
entry. A simultaneous or recursive `titan.lua.require` for that same module
raises `module 'name' is already being loaded`; it does not start a duplicate
loader and does not wait on hidden scheduler state. The guard is removed after
both success and error, so a later call can retry. Different module names may
load concurrently.

`require` returns only the module value. Lua 5.5's additional loader-data
result is intentionally not part of this typed API.
