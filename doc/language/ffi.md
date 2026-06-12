# The C FFI

Titan can call C functions and read C constants and variables directly,
without writing any C glue code. You name a C *header file* — the file
that describes a C library's functions and types — and the compiler
parses it and turns its declarations into a module-like value whose
members you call like any imported Titan module. The stated goal of
this facility is to let Titan's own standard library eventually be
written in Titan itself, binding system libraries by declaration rather
than by hand-written adapters.

Everything in this chapter happens at **compile time**: the header is
parsed while your module is typechecked, and calls compile to plain C
function calls with no run-time marshalling machinery. The flip side is
that the FFI is the one place where Titan's safety guarantees end: C
functions can misuse memory and crash the process, and Titan does not
(and cannot) check what they do.

*Implementation note:* the header-parsing pipeline (a pure-Lua C
preprocessor and C99 parser) and the code generated for foreign calls are
described in [the FFI internals](../implementation/ffi-internals.md).

## Importing a header

```lua
-- Titan
local stdio = foreign import "stdio.h"

function hello(): integer
    return stdio.printf("Hello from C!\n")
end
```

`foreign import` is a top-level declaration, like [`import`](modules.md):
it binds a local name to a *foreign module* whose members are the
declarations found in the header. `foreign` and `import` are reserved
words.

### Header names and search

How the header name is resolved depends on its form:

* **A relative name** (`"stdio.h"`, `"SDL2/SDL.h"`) is looked up in the
  *system* include directories — the same directories a C file's
  `#include <...>` would search. The compiler discovers this list by
  asking the system's C preprocessor (`cpp -v`), falling back to
  `/usr/include` if that fails. The generated C contains a matching
  `#include <stdio.h>`.
* **An absolute path** (one starting with `/`) is read directly, and the
  generated C contains `#include "/that/path.h"`. Use an absolute path
  to bind a header of your own that is not installed in a system
  location.

(A relative name not found there is also tried relative to the current
directory, but the generated `#include <...>` will then generally not
be found by the C compiler — relative names are for installed headers.)

If the header cannot be found or fails to preprocess, the import is a
compile-time error:

```
foo.titan:1:1: type error: failed preprocessing 'does_not_exist.h': does_not_exist.h: No such file or directory
```

## What gets imported

Processing a header gives the foreign module these members:

* **Functions** — every C function the header declares becomes a callable
  member with a Titan function type derived from its C prototype
  (`stdio.fopen`, `stdio.printf`, ...). Functions marked `static` in the
  header (private to a C file) are deliberately invisible.
* **Variables** — C global variables declared in the header become
  readable members with the converted type. For example, `errno.errno`
  (the C error-number variable) reads as an `integer`:

  ```lua
  -- Titan
  local stdio = foreign import "stdio.h"
  local errno = foreign import "errno.h"

  function try_open(name: string): integer
      local f = stdio.fopen(name, "r")
      if f ~= nil then
          stdio.fclose(f)
      end
      return errno.errno
  end
  ```

* **`#define` constants** — C constants defined with the preprocessor
  also appear as variables when their type can be inferred from the
  definition: integer constants read as `integer`, floating constants as
  `float`, string constants as `string`. This is how `errno.ENOENT` or
  `SDL.SDL_INIT_VIDEO` work. Function-like macros (macros that take
  arguments) are *not* imported — for instance, SDL's `SDL_LoadBMP` is a
  macro, so the SDL example below calls the real function
  `SDL_LoadBMP_RW` instead.
* **Type names** (`typedef`s such as `FILE`, `size_t`) are recorded and
  used to give types to the functions and variables; you do not use them
  directly in Titan source.

Two practical consequences of how headers work in C:

* **Transitive declarations are visible.** A C header includes other
  headers, and everything the whole expansion declares becomes a
  member; importing one umbrella header (like `SDL2/SDL.h`) gives you
  the whole library.
* **Type names unify across imports in the same module.** Each header
  must declare (or `#include`) the typedefs it uses itself — a later
  header that mentions `FILE` without declaring it fails to parse —
  but typedefs with the same name convert to the same Titan type, so
  values flow between functions from different headers when their C
  types agree: the `pointer to FILE` returned by `stdio.fopen` can be
  passed to a `FILE *` parameter declared in another imported header.

### One flat namespace

The Titan-side names (`stdio.`, `errno.`) are namespacing for the
typechecker only. In the compiled code a foreign call or variable is the
bare C name, and all imported headers are included into the same
generated C file. So two imports that declare the same C name refer to
the same thing:

```lua
-- Titan
local a = foreign import "stdio.h"
local b = foreign import "stdio.h"
-- a.printf and b.printf compile to calls to the same C printf.
```

The compiler does not currently detect genuine conflicts (two different
headers declaring the same name incompatibly); the C compiler will
complain instead.

## The type mapping

C declarations are translated into Titan types as follows:

| C type | Titan type |
| --- | --- |
| `int`, `long` (and `typedef`s that resolve to integer types, e.g. `size_t`) | `integer` |
| `double` | `float` |
| `char *` | `string` |
| `void` (as a return type) | `nil` — the call produces `nil` |
| `void *` | the *void pointer* type |
| any other pointer `T *` | an opaque pointer type, shown as `pointer to T` |

Titan's `integer` is 64-bit and `float` is double-precision, matching
`long` and `double` on the platforms Titan targets.

C types outside this table — bare `char`, `short`, C's single-precision
`float`, `unsigned` variants spelled out in a prototype, structs and
unions passed by value, C arrays, and function pointers — have **no
Titan counterpart**. Declarations that mention them are still listed as
members, but you cannot call or read them: the use crashes the compiler
with an internal error (a Lua traceback ending in
`impossible: Type.Unknown`), not a clean type error.

*Limitation:* struct, union and enum **contents** are parsed but not yet
converted — you cannot access the fields of a C struct from Titan, and
enum constants are unusable either way. The constants of a bare
top-level `enum color { ... };` declaration are not imported at all:
using one is the compile-time error `member '...' not found inside
module '...'`. The constants of a *typedef'd* enum
(`typedef enum { ... } color_t;`) do become members, but their values
are not stored and using one crashes the compiler with an internal
error (a Lua traceback ending in `impossible: Enum`). Struct values are
only usable behind pointers, as opaque values (see below).

## Calling C functions

A foreign call looks exactly like a Titan module call. Arguments are
checked at compile time against the C prototype, with the usual
[implicit coercions](types.md), and arity is strict — except for C
*variadic* functions (those declared with `...`, like `printf`), which
accept any number of extra arguments. Mismatched argument types are
ordinary compile-time type errors.

Each argument is converted per the table above: numbers and booleans
pass through directly, `nil` becomes the C null pointer, strings become
`char *` (see the next section), pointers pass through unchanged, and
Titan *literals* — numbers as well as strings — are emitted directly as
C literals. The result converts back the same way; a `void` function's
result is the value `nil`, so in practice you call it as a statement.

```lua
-- Titan
local stdio = foreign import "stdio.h"

function write_greeting(): integer
    local fd = stdio.fopen("hello.txt", "w")    -- fd: pointer to FILE
    local msg = "Hello, Titan!\n"
    local n: integer = stdio.fwrite(msg, #msg, 1, fd)
    stdio.fclose(fd)
    return n
end
```

The annotation on `n` matters: `fwrite` returns the typedef `size_t`,
and while a typedef-typed value converts to `integer` wherever an
integer is expected, letting type inference give a local the raw
typedef type currently crashes the code generator (an internal error,
`invalid type size_t`).

One C-ism to keep in mind with variadic functions: Titan integers are
passed as 64-bit values, so `printf`-style formats must use 64-bit
conversions (e.g. `%lld`, not `%d`); Titan floats match `%f`/`%g`.
(An integer *literal* argument is the exception: it is emitted as a
plain C literal of type `int`, so the C compiler may warn about `%lld`
there.)

## Strings versus `char *`

Titan strings and C strings are different things, and the FFI converts
between them at the boundary:

* **Titan → C.** Passing a Titan `string` where C expects `char *`
  passes a pointer to the string's internal byte buffer. No copy is
  made. Titan strings are immutable and their buffers end with a zero
  byte, which is what C string functions expect — but this also means:
  the C function must treat the memory as read-only; the pointer is
  only valid during the call (do not bind C functions that stash the
  pointer for later); and a Titan string containing an embedded zero
  byte looks truncated from C's side.
* **C → Titan.** A `char *` returned by a C function is immediately
  *copied* into a fresh Titan string. Titan does not take ownership of
  the C pointer: if the C function allocated memory for it and expects
  the caller to free it, that memory leaks, because the pointer itself
  is discarded after the copy. The conversion also assumes the pointer
  is a valid zero-terminated string — a C function that can return a
  null `char *` (like `getenv`) will crash the process on the null
  case.

## Pointers

C functions traffic in *pointers* — addresses of C objects. Titan gives
each pointer type an opaque, statically-checked identity: `fopen`
returns a `pointer to FILE`, `opendir` a `pointer to DIR`, and the two
do not mix — passing one where the other is expected is a compile-time
type error (`... expected pointer to FILE but found pointer to DIR`).

There is no Titan syntax for writing a pointer type; pointers exist
only as the inferred types of locals and expressions inside functions
that use the FFI. They cannot appear in a Titan function's signature,
in arrays or maps, or in record fields, and they never cross into Lua.
What you can do with a pointer:

* **Store it in a local** and pass it to other foreign calls expecting
  the same pointer type.
* **Compare it with `==`/`~=`** against another pointer of the same
  type or against `nil`. Every pointer type is *nullable*: C functions
  signal failure by returning the null pointer, which compares equal
  to `nil`, and you may pass `nil` for any pointer parameter.
  Relational operators (`<`, `<=`, ...) are not allowed on pointers
  (compile-time error `trying to use relational expression ...`).
* **Test it for null — as an explicit `nil` comparison.** The
  "returned null on failure" check must be spelled `== nil`/`~= nil`:
  using a pointer's *truthiness* instead (`if p then`, `not p`)
  currently crashes the compiler with an internal error
  (`invalid type pointer to FILE`).

  ```lua
  -- Titan
  local win = SDL.SDL_CreateWindow(title, 100, 100, 640, 480, flags)
  if win == nil then
      -- creation failed
  end
  ```

* **Coerce it to `void *` implicitly.** C's `void *` is the
  "any pointer" type; every pointer — and also any Titan string —
  converts to it implicitly, so calls like `free(p)` or
  `memcmp(s1, s2, n)` just work.
* **Cast `void *` to `string` explicitly.** This is the one conversion
  that requires an explicit [`as` cast](expressions.md), because it
  reinterprets raw memory as a string buffer. The typical use is C
  functions that *fill* memory you allocated:

  ```lua
  -- Titan
  local stdlib   = foreign import "stdlib.h"
  local string_h = foreign import "string.h"

  function copy_into_memory(): string
      local mem = stdlib.realloc(nil, 100)        -- mem: void pointer
      local s = string_h.strcpy(mem as string, "Hello, cast")
      stdlib.free(mem)
      return s    -- strcpy's char* return was copied into a Titan string
  end
  ```

  Without the cast, the call is the compile-time error
  `expected string but found void pointer`.

Pointers are not managed by the garbage collector. Memory you obtain
from C (as with `realloc` above) must be released through C (`free`),
and Titan does nothing to stop you from using a pointer after the C
library has invalidated it — this is exactly as unsafe as it is in C.

## Reading and writing C globals

Foreign variables (including the `#define` constants) are read like
module variables, as in the `errno.errno` example above. Treat them as
**read-only**: assigning to one is not supported (the assignment
typechecks, but code generation fails with an internal compiler error —
an assertion failure — rather than a clean type error).

## Linking and platform requirements

Importing a header gives the compiler the *declarations*; the compiled
module must still be linked against the *library* that implements them.
Functions in the C standard library need nothing extra, but other
libraries are named with `titanc`'s `-l`/`--link` option (a
comma-separated list, each becoming a `-l<name>` flag for the C
compiler):

```sh
titanc examples.sdl_demo -lSDL2
```

Platform requirements, all at **compile time** (a compiled module has no
extra run-time dependencies beyond the libraries it links):

* A POSIX system. The FFI shells out to `gcc -dM -E` (for the
  compiler's predefined macros) and `cpp -v` (for the include search
  path), so both `gcc` and `cpp` must be on `PATH`, and the imported
  headers must be installed where the C compiler will also find them.
* The header is parsed by Titan's own built-in C preprocessor and C99
  parser — not by the system compiler — so headers must be within what
  that parser accepts. In practice it tolerates the common GNU/Clang
  and macOS extensions found in real system headers (`__attribute__`,
  `__asm__`, `_Bool`, `__int128`, anonymous unions, Apple availability
  macros and blocks), and it ignores `#error` and `#pragma`; exotic
  compiler-specific headers may still fail to parse, which surfaces as
  the compile-time `failed parsing: ...` error.

## A complete example: SDL

The repository's two-module SDL program (`examples/sdl_demo.titan` and
`examples/sdl_quit.titan`) exercises most of this chapter: a third-party
library bound through one umbrella header, `#define` constants, opaque
pointers tested for null, `nil` arguments, variadic `printf`, and
linking with `-l`. (The committed example writes its null tests as
`if not win`, which trips the pointer-truthiness compiler bug described
above; the excerpt below shows the `== nil` form the current compiler
accepts.)

```lua
-- Titan: examples/sdl_quit.titan
local stdio  = foreign import "stdio.h"
local SDL    = foreign import "SDL2/SDL.h"
local stdlib = foreign import "stdlib.h"

function quit(sdlquit: boolean, msg: string)
    stdio.printf(msg .. ": %s\n", SDL.SDL_GetError())
    if sdlquit then
        SDL.SDL_Quit()
    end
    stdlib.exit(1)
end
```

```lua
-- Titan: examples/sdl_demo.titan (trimmed)
local SDL = foreign import "SDL2/SDL.h"
local sdl_quit = import "examples.sdl_quit"

function main(args: {string}): integer
    if SDL.SDL_Init(SDL.SDL_INIT_VIDEO) ~= 0 then
        sdl_quit.quit(false, "SDL_init error")
    end
    local SDL_WINDOW_SHOWN = 0x04
    local win = SDL.SDL_CreateWindow("Hello World!", 100, 100, 640, 480,
                                     SDL_WINDOW_SHOWN)
    if win == nil then
        sdl_quit.quit(true, "SDL_CreateWindow error")
    end
    local bmp = SDL.SDL_LoadBMP_RW(SDL.SDL_RWFromFile("examples/hello.bmp", "rb"), 1)
    local ren = SDL.SDL_CreateRenderer(win, -1, 0x02 | 0x04)
    local tex = SDL.SDL_CreateTextureFromSurface(ren, bmp)
    SDL.SDL_FreeSurface(bmp)
    for i = 1, 3 do
        SDL.SDL_RenderClear(ren)
        SDL.SDL_RenderCopy(ren, tex, nil, nil)
        SDL.SDL_RenderPresent(ren)
        SDL.SDL_Delay(1000)
    end
    SDL.SDL_DestroyTexture(tex)
    SDL.SDL_DestroyRenderer(ren)
    SDL.SDL_DestroyWindow(win)
    SDL.SDL_Quit()
    return 42
end
```

Because `sdl_demo` defines `main(args: {string}): integer`, compiling it
produces a standalone executable (see [Modules](modules.md) and
[Functions](functions.md)):

```sh
titanc examples.sdl_demo -lSDL2
./examples/sdl_demo
```

## Summary of current limitations

* No access to struct/union fields or enum values (bare-enum constants
  are missing members; typedef'd-enum constants crash the compiler);
  structs only as opaque pointers.
* No C arrays, no function pointers, no by-value structs, and no
  mapping for bare `char`, `short`, C `float`, or explicit `unsigned`
  types in prototypes.
* Function-like macros are not imported.
* Foreign variables are effectively read-only.
* Pointer truthiness tests (`if p`, `not p`) crash the compiler; write
  `p == nil` / `p ~= nil` instead.
* Letting inference type a local from a typedef-returning call (e.g.
  `size_t`) crashes the code generator; annotate such locals.
* One flat C namespace across all imports, without conflict detection.
* Pointers cannot appear in Titan type annotations, containers, record
  fields, or exported signatures, and never cross into Lua.
* Compile-time POSIX dependency (`gcc`, `cpp`, `/dev/null`).
* No lifetime or memory safety for pointers: the FFI is exactly as
  unsafe as the C it binds.
