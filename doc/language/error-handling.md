# Error handling

Titan's error philosophy is the one stated in the
[design philosophy](philosophy.md): *fail early instead of falling back*.
Where Lua reacts to an unexpected value by coercing it, consulting a
metamethod, or taking a slower generic path, Titan raises an error at the
first point where a value does not match its declared type. Most
mismatches are caught at compile time; the rest — values arriving from
Lua, dynamic conversions, a few arithmetic corner cases — raise at run
time rather than letting a bad value propagate.

Titan has **no error-handling construct of its own**: there is no
`error`, no `pcall`, no `try`/`catch` in the language. A run-time error
raised in Titan code is an ordinary Lua error: it unwinds out of the
Titan code into the calling Lua program, where `pcall` catches it as
usual. The recoverable-failure idiom *inside* Titan is
[option types](option-types.md), shown
[below](#recoverable-failures-without-errors-the-option-idiom).

## Compile-time and run-time errors

The distinction between the two kinds of error is project policy (PR
#119): whenever an error is mentioned, the documentation must "state
explicitly whether it is run-time or compile-time (no matter how obvious
it may be to us)" — a rule these chapters follow throughout.

A **compile-time error** is reported by the compiler and prevents any code
from being produced: `titanc` typechecks every requested module and its
dependencies first, reports *all* errors, and exits with status 1 before
generating any C. Compile-time type errors share one format — note the
colon after `type error`:

```
m.titan:3:11: type error: types in declaration of local variable x do not match, expected integer but found string
```

A **run-time error** is raised by compiled Titan code while it runs, using
Lua's standard error mechanism with a string message. Most run-time
messages carry the same `file:line:col` prefix, but with a comma after
`type error`:

```
m.titan:2:1: type error, expected integer but found string
```

This chapter catalogues the run-time errors; compile-time errors are
documented with the constructs that cause them, in the
[types](types.md), [expressions](expressions.md),
[statements](statements.md) and [functions](functions.md) chapters.

## What raises run-time errors

The list below is complete for the current prototype. Note its shape: in
a well-typed, all-Titan program only the arithmetic guards, float→integer
conversions and option unwraps can ever fire; everything else guards the
Lua boundary (see [Lua interoperability](lua-interop.md) for the per-type
boundary rules).

### Wrong argument types from Lua

Every argument of a Titan function, method or static called from Lua is
checked against its declared type before the body runs:

```lua
-- Titan: m.titan
function double(x: integer): integer
    return x * 2
end

-- Lua
local m = require "m"
print(m.double(2.0))   --> 4  (a float with an integral value is accepted)
print(pcall(m.double, "oops"))
--> false   m.titan:2:1: type error, expected integer but found string
```

The shape is `FILE:LINE:COL: type error, expected T but found U`, where
`U` is the Lua type name of the offending value. The location is the
*declaration site* of the function whose parameter was violated (here
`m.titan:2:1`) — the call site is Lua code the Titan compiler never saw.
Particular cases:

* **Arrays and maps report as `table`** (`expected table but found
  number`), and any table is accepted — the *contents* are not checked at
  the boundary; see
  [the deferred container check](#container-element-checks-the-deferred-check).
* **Records report fully-qualified names on both sides** (and a
  non-record argument reports its Lua type name, `found number` etc.):

  ```lua
  -- Titan: m.titan
  record Point x: float y: float end
  record Box w: float end

  function norm(p: Point): float
      return p.x * p.x + p.y * p.y
  end

  -- Lua
  print(pcall(m.norm, m.Box.new(1)))
  --> false   m.titan:5:1: type error, expected m.Point but found m.Box
  ```

* **`boolean` parameters never raise** (any Lua value is accepted, by
  truthiness — inconsistently with boolean record-field and
  module-variable writes from Lua, which require an actual boolean), and
  **`value` parameters never raise** — checks happen later, when the
  value is converted to a concrete type.

### Wrong number of arguments from Lua

Between Titan functions, arity is strict and checked at **compile time**
(see [Functions](functions.md)). From Lua, the same strictness is enforced
at **run time** — no padding with `nil`, no dropping of extras:

```lua
-- Lua
print(pcall(m.double, 2, 3))
--> false   calling Titan function double with 2 arguments, but expected 1
```

The shape is `calling Titan function NAME with N arguments, but expected
M`; this one carries no Titan file/line prefix.

### Failed `value` casts

Converting a [`value`](types.md) to a concrete type — implicitly, where
the context names a type, or explicitly with `as` — compiles to a run-time
check with the same `expected ... but found ...` shape. The location
points at the expression being converted:

```lua
-- Titan: m.titan
function unbox(v: value): integer
    return v
end

-- Lua
print(pcall(m.unbox, {}))
--> false   m.titan:3:12: type error, expected integer but found table
```

### Float-to-integer conversion failures

Wherever a `float` becomes an `integer` — implicit coercion inside Titan,
or a Lua float arriving where Titan expects an integer — an integral value
is accepted and a fractional one is a run-time error:

```lua
-- Lua
print(pcall(m.double, 2.5))
--> false   m.titan:2:1: type error, number '2.5' has no integer representation
```

The boundary variant of the message is
`FILE:LINE:COL: type error, number 'N' has no integer representation`; the
Titan-internal cast (say, `return x` from a function returning `integer`
when `x: float`) raises the same complaint without file or column:
`type error at line N, number 'N' has no integer representation`.

*Limitation:* only integrality is checked, not range. A float that is
integral but too large for an integer (such as `2.0^64`) does **not**
raise; the conversion silently produces an unspecified integer (observed:
`0`). Lua, by contrast, raises "number has no integer representation" for
these too. A second hole: the boundary and container-element checks test
integrality through a single-precision C `float`, so a fractional value
whose fraction is beyond float precision (such as `16777216.5`) is
silently accepted and truncated; the Titan-internal cast checks in full
precision and raises for it.

### Integer division and modulo by zero

Titan arithmetic follows Lua's semantics exactly (see
[Expressions](expressions.md)), including the error cases: integer floor
division `//` and integer modulo `%` by zero are run-time errors, with
messages that carry only a line number:

```lua
-- Titan: m.titan
function idiv(a: integer, b: integer): integer
    return a // b
end

function imod(a: integer, b: integer): integer
    return a % b
end

-- Lua
print(pcall(m.idiv, 1, 0))   --> false   error at line 3, divide by zero
print(pcall(m.imod, 1, 0))   --> false   error at line 7, % by zero
```

Float division never raises: as in Lua, `1.0 / 0.0` is `inf` and
`0.0 / 0.0` is `nan`.

### Option unwraps that find `nil`

Reading an array or map element gives an [option type](option-types.md)
(`integer?` for an `{integer}` element), and using such a value where the
plain base type is required compiles to a run-time nil-check:

```lua
-- Titan: m.titan
function first(xs: {integer}): integer
    local x: integer = xs[1]
    return x
end

-- Lua
print(pcall(m.first, {}))
--> false   m.titan:3:26: type error, expected integer but found nil
```

This is the "fail fast" half of the option-type bargain; the graceful
half is shown
[below](#recoverable-failures-without-errors-the-option-idiom).

The implicit unwrap applies in every position: a value read directly
from an array or map (as in `first` above), a variable *declared* with
an option type (given `local y? = xs[1]`, a later `local z: integer = y`
or `y + 1`), the result of an option-returning call
(`local i: integer = find(xs, v)`), an option used as an array or map
index, in arithmetic, as a call argument, and in string concatenation. A
`nil` found at run time raises the same `expected T but found nil` error
shown above.

### Container element checks (the deferred check)

Arrays and maps cross the Lua boundary by reference — they are the same
Lua table on both sides — and their contents are *not* validated when they
cross. Instead, **every** element read inside Titan re-checks the element
type, so a wrongly-typed value planted by Lua surfaces later,
deterministically, at the Titan read:

```lua
-- Titan: m.titan
function bump(counts: {string:integer}, k: string): integer
    counts[k] = counts[k] + 1
    return counts[k] or 0
end

-- Lua
local t = { hits = 3 }
print(m.bump(t, "hits"))   --> 4 (same table: t.hits is now 4)

t.hits = "wat"             -- legal in Lua; the table is just a table
print(pcall(m.bump, t, "hits"))
--> false   m.titan:3:23: type error, expected integer but found string
```

The location is the read expression inside Titan. The same deferred
check fires for any container: `m.first({"a"})` above fails with
`expected integer but found string`, and a non-integral float found in an
integer array raises the `has no integer representation` error. See
[Arrays and maps](arrays-maps.md) for the access rules themselves.

### Record fields and module variables from Lua

Records cross into Lua as userdata with checked accessors (see
[Records](records.md)). Accessing a field that does not exist — reading or
writing — is a run-time error located at the record declaration, and field
writes from Lua are type-checked:

```lua
-- Lua, with the Point record from above
local p = m.Point.new(1, 2)
print(pcall(function () return p.z end))
--> false   script.lua:3: m.titan:2:1: field 'z' not found in record 'm.Point'
print(pcall(function () p.x = "a" end))
--> false   script.lua:5: m.titan:2:1: type error, expected float but found string
```

(The `script.lua:N:` prefix is the position of the pcall'd Lua closure
the access runs in; see
[the anatomy section](#anatomy-of-an-error-message) for the rule.)

The shape is `FILE:LINE:COL: field 'NAME' not found in record 'FQTN'`;
assigning to a *method* name raises the same `not found` error — methods
are not assignable fields. Exported module variables behave the same way
through the module table: writes from Lua are type-checked (writing a
string to an `integer` variable raises `type error, expected integer but
found string` at the variable's declaration), and touching a name that is
not an exported variable raises `global variable 'NAME' does not exist in
Titan module 'MOD'`, with no Titan file/line prefix.

## Anatomy of an error message

| Error class | Shape |
| --- | --- |
| compile-time, syntax | `FILE:LINE:COL: syntax error: MESSAGE` |
| compile-time, all others | `FILE:LINE:COL: type error: MESSAGE` |
| boundary, cast, unwrap, element checks | `FILE:LINE:COL: type error, expected T but found U` |
| float→integer, at the boundary | `FILE:LINE:COL: type error, number 'N' has no integer representation` |
| float→integer, internal cast | `type error at line LINE, number 'N' has no integer representation` |
| `//` and `%` by zero | `error at line LINE, divide by zero` / `error at line LINE, % by zero` |
| arity from Lua | `calling Titan function NAME with N arguments, but expected M` |
| record field from Lua | `FILE:LINE:COL: field 'NAME' not found in record 'FQTN'` |
| module variable from Lua | `global variable 'NAME' does not exist in Titan module 'MOD'` |

The `FILE:LINE:COL` prefix names the *Titan* source position
responsible: the function declaration for argument checks, the record
declaration for field errors, the expression for casts, unwraps and
element reads. On top of that, the position of the calling Lua code is
prepended when the immediate caller is Lua code, so a failure often
prints as `script.lua:7: m.titan:2:1: type error, ...` — this applies to
every error class above, including the prefix-less arity and
module-variable messages. When the Titan function is passed straight to
`pcall` (as in most examples above), the immediate caller is `pcall`
itself — a C function — and no Lua position is prepended.

## How errors propagate

Titan has no catch construct, so a run-time error always unwinds out of
Titan entirely. From there it is ordinary Lua error handling:

```lua
-- Lua
local ok, err = pcall(m.first, {})
print(ok)    --> false
print(err)   --> m.titan:3:26: type error, expected integer but found nil
```

Everything Lua programmers know applies: `pcall`/`xpcall` catch the
error, the error value is the message string Titan raised, and an
uncaught error terminates the program. One Titan-specific wrinkle: the
interpreter's usual `stack traceback:` block is *not* printed for an
uncaught Titan error — the Titan error handler (next section) takes the
place of the interpreter's traceback-producing message handler for the
duration of the call, so only the message line appears. If the failing
function was called from other Titan functions, the error unwinds through
those frames too — there is no way to intercept it on the way. In a
[standalone Titan program](modules.md) the same rules hold under the
generated entry point: an uncaught run-time error prints the message
(again with no traceback) to standard error and the process exits with a
failure status, while a normal return from `main` makes its integer
result the process exit status.

## The error handler and `titan.backtrace()`

The beginnings of a richer error-reporting story landed in PR #257, in the
project's own words "an experiment towards integrating Lua's error
handling into Titan that makes errors thrown while executing Titan code
throw an object that combines an error object with a stack trace that has
both Titan and Lua functions."

What is implemented today: every Titan function exported to Lua installs
an error handler for the duration of the call. On a run-time error the
handler captures the error message together with a *merged* trace — the
Lua-level traceback plus the C-level backtrace through the compiled Titan
frames — and stores it; the error value itself reaches `pcall` unchanged.
The trace is retrieved from Lua with the `titan` runtime-support module
(installed along with the compiler by `luarocks make
titan-dev-1.rockspec`):

```lua
-- Titan: m.titan
function wrong(): integer
    local x: value = {}
    return x
end

-- Lua
local titan = require "titan"
local m = require "m"

local ok, err = pcall(m.wrong)
assert(not ok)
print(titan.backtrace())
```

This is the usage pattern from the compiler's own test suite. The
output, trimmed:

```
m.titan:4:12: type error, expected integer but found table
stack traceback:
	[C]: in ?
	[C]: in function 'm.wrong'
	[C]: in global 'pcall'
	(command line):4: in main chunk
	[C]: in ?C traceback:
./m.so(errorhandler+0x2b) [...]
...
./m.so(m_wrong_titan+0x92) [...]
...
```

`titan.backtrace()` returns the trace of the most recent Titan error in
the Lua state; each new error overwrites it. The facility is
**experimental**, merged deliberately as a first validation step ("merge
this initial version as is, then build on top of this in other PRs" was
the review plan); its rough edges show in the output, where Titan frames
appear under their mangled C names (`m_wrong_titan`) and the C and Lua
tracebacks sit side by side rather than interleaved.

## Recoverable failures without errors: the option idiom

Since Titan code cannot catch errors, the way to make a failure
*recoverable* is to keep it out of the error system entirely: return an
[option type](option-types.md) and let the caller test or default it.
This is the option-type design rationale (PR #239) — the programmer
should not have to prove a value is present, but the language should
"fail fast if he thinks he is handling a real value but the value is not
actually there, so 'nulls' do not propagate." A worked example — a search
function whose "not found" is a value, not an error:

```lua
-- Titan: m.titan
function find(xs: {integer}, v: integer): integer?
    for i = 1, #xs do
        if xs[i] == v then
            return i
        end
    end
    return nil
end

function find_or_first(xs: {integer}, v: integer): integer
    local i? = find(xs, v)
    return i or 1
end

-- Lua
print(m.find({10, 20, 30}, 20))           --> 2
print(m.find({10, 20, 30}, 99))           --> nil
print(m.find_or_first({10, 20, 30}, 99))  --> 1
```

The pieces, all covered in depth in [Option types](option-types.md):
`return nil` and `return i` both coerce into the declared `integer?`;
`local i? = ...` opts in to keeping the option (a plain `local i = ...`
would instead unwrap immediately and raise on `nil` — see
[the unwrap behaviour](#option-unwraps-that-find-nil)); `i or 1` collapses
`integer?` to `integer` with a default — and `if i then` would test for
presence instead. From Lua, an option return is simply the value or
`nil`, the natural Lua convention for "no result".

*Limitation:* the `or`-default must currently go through a variable, as in
`find_or_first`. Writing `return find(xs, v) or 1` directly — the
option-returning call as the left operand of `or` — produces invalid C and
fails compilation in the current prototype. Defaulting an indexing
expression directly (`return xs[i] or 0`) works fine.

## Design outlook

Error handling is where the prototype stops, not where the design does.
PR #257 — the last substantive feature merged into this compiler — spells
out the intended destination: a Titan error should carry an error object
combined with a single coherent stack trace spanning both languages. The
machinery it anticipates: "The stack trace information for Titan
functions has to be obtained through the C mechanisms (either the
`backtrace` function or libbacktrace or libunwind), Titan functions have
to be identified and demangled, and the Lua/Titan transitions identified
and merged with the Lua stacktrace available through the `Callinfo`
stack." No further error-handling work followed in this repository, so
the language today sits at the first step of that plan: errors are plain
Lua errors, the merged trace exists but is raw, and Titan-side raising
and catching remain future work.

*Implementation note:* the generated code already reserves a stack slot
for an error value on every call from Lua — unused groundwork from PR
#257 for the planned error-object protocol; see
[the interop internals](../implementation/lua-interop-internals.md).
