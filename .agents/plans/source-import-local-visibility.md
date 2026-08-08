# Local module member visibility through source imports

Local module members (functions/records/unions/type aliases/fields) should be visible
through source imports, so modules that will end up in the same `.so`/`.a` file as other
modules they import will be able to see and use local members of these imported modules.

This is also going to be used by the upcoming testing system as a way to have
test modules test local members of the module they are testing, without needing to
inject the tests in the module source at compile-time.

Visibility is still through the imported alias, this does not mean that the other
module members are visible without qualification.

This also means that FFI types are also visible through these local member declarations,
even if the importing module did not directly import the header. On the code generation side
this should be as simple as generating the closure of the FFI `#include`s coming from source
imports.

This does not extend to modules imported through a static `.a` archive, which are binary
imports that use the existing visibility rules. This means that the change does not affect
module metadata written to `.so` and `.a` files.

Example (not comprehensive):

```a.titan
local stdio = foreign import "stdio.h"

local record Foo
  x: integer
end

record Bar
  local hidden: string
end

local function Bar:hidden_method(): integer
  return 2
end

local function hidden_func(): integer
  return 3
end

local function fopen(path: string, mode: string): *stdio.FILE
  return stdio.fopen(path, mode)
end

local function fclose(file: *stdio.FILE): integer
  return stdio.fclose(file) as integer
end

local function fputs(s: string, file: *stdio.FILE): integer
  return stdio.fputs(s, file) as integer
end
```

```b.titan
-- binary import of stdlib module
-- either statically through titan.a
-- or dynamically through titan.so
local io = import "io"
-- source import
local a = import "a"

function test()
  local f = Foo.new(1) -- can see local record
  local b: Bar = { hidden = "foo" } -- can construct record with local fields
  io.print(b:hidden_func()) -- can call local method
  b.hidden = "bar" -- can access local field
  io.print(hidden_func()) -- can call local function
  -- can use FFI types transitively
  local file = a.fopen("test.txt", "w") -- file has type *stdio.FILE
  defer a.fclose(file)
  local stream = io.popen("ls")
  --[[
     The following line would fail to compile because
     stream.process is local to the io module (binary)
     and the io module does not have visibility into a
  ]]
  -- stream.process:wait()
  for line in io.lines(stream) do
    a.fputs(line, file)
  end
end
```

This change should be dogfooded by making most of the `uv` module local (and dropping
the `_` prefixes), possibly all of it will become local and the module becomes
opaque to non-stdlib modules. Any public surface of `uv` would have to be a valid
extension point that would let another module binding to libuv plug into it, but
the existing architecture with the `Call` union is not extensible in this manner.

Another consequence is that records in `uv` that only exist to wrap non-exportable
FFI types for consumption by the high-level stdlib modules should be removed, since
the high-level stdlib will be able to use the libuv FFI types directly. Do
a thorough simplification pass and remove trivial wrappers (either record wrappers or
function wrappers).
