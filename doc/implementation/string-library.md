# String-library implementation

`titan.string` is one logical folder module inside the canonical standard
provider. It combines byte operations translated from Lua 5.5 string-library
semantics with a regex compiler built on the public `titan.peg` binding.
Production code is Titan plus C99 FFI: there is no string-specific C shim and
no delegation to Lua's mutable `string` table.

The user-facing contract is in the
[String standard library](../language/standard-library-string.md).

## Module and provider placement

The source is a folder ensemble rooted at `titan/string/string.titan`.
The main owns every public record, method, and function together with its
implementation. Contributors expose no public declarations; they contain only
module-local records, state, and shared implementation machinery divided among
byte operations, formatting, packing, and regex parsing/compilation. A helper
remains separate when it is reused or represents a real internal operation
such as recursive parsing, callback adaptation, or byte-storage handling, not
merely to receive the unchanged arguments from one public function and return
all of its results. The files are parsed separately but combined into one dense
AST, one checker/code-generator pass, one `titan_string_*` protocol, one
generated object, and one `titan/string.lua` shim.

The dependency direction is:

```text
private namespaced LPegLabel archive
                |
                v
           titan.peg
                |
                v
          titan.string
             /     \
            v       v
       titan.net  titan.os
```

`titan.peg` does not import `titan.string`; its relabel implementation retains
small private byte/diagnostic helpers to avoid a cycle. `titan.string` uses the
typed PEG surface and never reaches the embedded engine through a private raw
escape hatch. Both `titan.net` and `titan.os` dogfood the literal
`titan.string.find` and byte-preserving `titan.string.sub` operations. The
isolated delayed-DNS fixture therefore constructs complete exact PEG and
string providers before its exact net facade; production already places all
nine logical modules and LPegLabel in one static bundle.

The installed standard build requests nine roots in stable order:

```text
titan.coroutine
titan.uv
titan.async
titan.timer
titan.fs
titan.net
titan.os
titan.peg
titan.string
```

The request order preserves the previous seven roots and appends PEG before
string; it is not topological. Recursive import loading resolves both the
`titan.net`/`titan.os` to `titan.string` to `titan.peg` chains while those
facades are processed.

The paired `titan.so`/`titan.a` therefore contains nine logical protocols and
nine archive metadata keys. The DSO exposes ten Lua openers: bare
`luaopen_titan` support plus one entry per logical module. The provider's
metadata-free payload begins with `titanlib.o`, then the private
`libtitan-lpeglabel.a`, then the bundled libuv archive when bundled mode is
selected. LPegLabel has no Titan metadata key and its archive/headers are not
installed in the compiler SDK.

## Exact-byte storage

The shared byte layer treats every input as a `(pointer, length)` pair. It
never uses NUL termination for an ordinary string. A generated result is a
counted owned C array:

```titan
local owned = ffi.titan_ffi_char.new_array(length)
local output = owned as *ffi.titan_ffi_char
```

`new_array` creates the Lua full userdata, records its element count, and
leaves `owned` as the traced GC root. C calls and pointer arithmetic use the
cast pointer while `#owned` recovers the allocation length. The raw pointer is
valid only while `owned` is live. Finalization pushes the exact logical length
with `lua_pushlstring` and converts that stack value back to a Titan string.
Usually that length is `#owned`; `snprintf` destinations are the exception,
because they allocate `required + 1` bytes for the terminating zero but finish
only the `required` result bytes.

All size arithmetic remains in a checked Titan integer until it is known to
fit both `lua_Integer` and target `size_t`. Multiplication and addition use
subtract/divide-first checks, so neither an intermediate expression nor its
later C cast can wrap.

The pointer-lifetime rule is strict:

1. allocate and root the destination;
2. derive a pointer from the input string;
3. perform an allocation-free C scan/copy window;
4. stop using that pointer before any Lua allocation, callback, or error path.

An implementation may instead retain only the rooted string and a byte offset,
then rederive its pointer after a call. A borrowed wrapper pointer never lives
across a callback even though Lua strings themselves are nonmoving.

## Positions and byte operations

The shared normalizers implement Lua 5.5's two endpoint rules without negating
`math.mininteger`:

* an initial endpoint is clipped to at least 1;
* an ending endpoint is clipped to `0..length`.

`byte` deliberately defaults its ending position from the raw initial
argument before either endpoint is normalized. Its result helper emits a
flexible integer tail and checks the 200-element bound before recursion.

Literal `find` uses the initial-position normalizer, then scans the bounded
`(pointer, length)` window with a first-byte check and `memcmp`. It returns
one-based inclusive bounds, including `first, first - 1` for an empty needle,
or the fixed pair `nil, nil` on failure. The fixed option pair exposes the
actual two-slot protocol without an unnecessarily open result tail; ordinary
call adjustment discards the second slot when a caller requests only the
first. The scan never treats NUL as a terminator and does not allocate while
either raw pointer is live.

`lower` and `upper` convert each source byte to C `unsigned char` before
calling `tolower`/`toupper`. This avoids undefined behavior for a negative
plain `char` and preserves Lua's process-locale behavior.

`rep` checks one subject-plus-separator unit before multiplying by the count,
then subtracts the unused final separator. It appends the final subject
separately so a maximum count is never incremented.

## Raw Lua conversions and fixed-call adjustment

The public `tostring` signature is:

```titan
function tostring(candidate: value): string
```

It is intentionally fixed rather than variadic. Titan's existing call
adjustment pads an omitted parameter with nil and discards surplus values
after evaluating their expressions. The implementation therefore sees exactly
one `value` in every call path, including generated Lua wrappers and generic
callable dispatch.

The conversion helper:

1. saves `lua_gettop(L)`;
2. pushes the `TValue` carried by `value`;
3. calls `luaL_tolstring`;
4. captures the exact resulting Lua string;
5. restores the saved top in `finally`.

This bypasses `_G.tostring` while preserving the native number,
boolean/nil, and `__tostring` behavior. `format`'s `%s` path calls the same
helper.

The format/pack dynamic operands have their own stack-balanced helpers for
`luaL_checkinteger`, `luaL_checknumber`, and `luaL_checklstring`. Each helper
saves/restores the exact top around one pushed `value`. A caught conversion or
metamethod error therefore cannot accumulate stale roots.

These calls are a trusted standard-library-internal use of the raw Lua C API,
not a general promise that arbitrary Titan FFI code can manipulate `L`
safely. The complete discipline and scope are recorded in
[Lua C API FFI follow-up](ffi-lua-api-followup.md).

## Format translation

The formatter ports the Lua 5.5 conversion grammar and validation tables into
a `titan.peg` pattern built once by the module initializer. Matching a format
string produces one local `FormatPlan`: a dense Array of exact
`FormatPartial` closures of type `(value) -> string`, followed by one literal
trailer. A `FormatFactory` constructs each partial from the literal prefix,
the captured conversion form, and its conversion family. Integer factories
also insert and retain the target-correct C length modifier once while
building the plan.

The PEG grammar folds `%%` into the literal runs surrounding conversions.
Valid conversion captures select the character, signed, unsigned, number,
pointer, literal, or string factory. Ordered fallback captures select partial
closures that raise the stable invalid-specification, invalid-conversion,
modified-`%q`, or overlong-format error when that argument position is
executed. Keeping errors as partials, rather than failing the complete PEG
match, preserves conversion-slot argument checking and error order.

`format` matches once, then walks the plan in argument order. For every
partial it first checks that the corresponding variadic operand exists, calls
the exact closure with that `value`, and appends the returned
literal-prefix-plus-rendering chunk. It finally appends the plan's trailer.
Surplus operands are not visited. The checked builder retains all returned
chunks and their running byte count; at completion it allocates the exact
final destination and concatenates the chunks in one allocation-free copy
window.

Each rendering closure obtains its operand with the exact Lua C conversion,
then calls C99 `snprintf` once to obtain the length and again with an exactly
sized rooted buffer where that conversion uses C formatting.

The C variadic call is statically explicit for that conversion. Titan does not
attempt to forward a heterogeneous Titan `...` descriptor to C.

`%p` obtains identity through `lua_topointer`; a null pointer is formatted as
`"(null)"` without passing a null `%p` operand. `%q` is written directly in
Titan, including decimal control-byte escapes, Lua-readable minimum-integer,
infinity, NaN, and locale-neutral hexadecimal float forms. Modified `%s`
checks for embedded NUL before entering C formatting; an unmodified `%s`
appends the complete converted string.

## Pack translation

One mutable `PackState` carries the format cursor, selected byte order, native
byte order, and maximum alignment. `sizeof` and `alignof` on the imported C
types supply the target's actual widths and the native maximum-alignment
policy. A small integer probe determines native endianness through `memcpy`,
without type-punning.

The format reader classifies one option and then computes alignment padding
from the current output/data position. `X` consumes the following option only
to obtain its alignment. Padding and option size are checked and added
separately, so a pre-check sum cannot overflow. The `s` and `z` dynamic
payloads perform the same incremental checks.

Integers are serialized byte by byte from `lua_Unsigned`; narrow signed and
unsigned operands are checked before conversion. Sizes up to 16 bytes use
explicit zero or sign extension. Floating values are first converted to the
target C scalar, copied with `memcpy`, and reversed when requested byte order
differs from native order.

`unpack` mirrors this path. It checks padding and fixed width against the
remaining byte count before pointer arithmetic, reconstructs the low
`sizeof(lua_Integer)` bytes, validates extension bytes, and sign-extends a
narrow signed value. Float loads use `memcpy` into an aligned automatic C
scalar rather than dereferencing an unaligned pointer.

Decoded values accumulate in a traced `{value}` array. The final one-based
position is appended, then a bounded helper projects the nonempty array into
the fixed `value` prefix and flexible tail. At most 199 data values are
accepted because the position is the 200th total result. `unpack` is therefore
never a zero-result operation.

## Regex parser and compiler

A nonrecursive `titan.peg` pre-pass scans character classes, escapes, and group
prefixes and uses labeled throws for their lexical failures. Grouping,
alternation, anchors, quantifier placement, and the private byte-oriented AST
belong to the following recursive descent, whose nodes retain source byte
offsets. Keeping structural recursion out of the PEG pre-pass means its stack
use no longer scales with group depth or LPegLabel's mutable backtrack-stack
setting. The recursive descent allows 512 nested capturing or noncapturing
groups before raising the stable `group_nesting_too_deep` diagnostic; this
protects the C stack while preserving all 200 nested captures. Syntax failures
and later semantic checks use the same diagnostic record and are formatted
into the public label/line/column/source/caret message before raising.
LPegLabel's max-stack setting still governs execution of a compiled pattern;
the parser change removes only the accidental compilation-depth dependency.

Compilation is continuation-based. Each AST node is converted with the
pattern that must follow it, which gives greedy repetition its required
backtracking behavior. Ordered choice preserves left bias. Whole-expression
anchors wrap the completed alternation instead of attaching to one branch.
The translated construction follows `pegex.lua` from ta-regex commit
`857e48682791ba55c98a7dd99c5fc7d71c02597d` and the algorithm in Marcelo
Oikawa, Roberto Ierusalimschy, and Ana Lucia de Moura, [“Converting regexes to
Parsing Expression
Grammars”](https://www.inf.puc-rio.br/~roberto/docs/ry10-01.pdf), PUC-Rio,
2010.

Before construction, the compiler:

* parses counted bounds with checked arithmetic;
* rejects a maximum smaller than its minimum;
* computes nullability and rejects an unbounded nullable repetition;
* numbers captures once in left-to-right opening order;
* bounds recursive group nesting at 512;
* validates each single-digit backreference against a previously closed group;
* projects the resulting PEG tree size, including continuation and capture
  wrappers, against `SHRT_MAX - 10`;
* limits the expression to the string API's 200-value projection bound.

A private sentinel named capture is installed for every group. A participating
group overwrites it on the current successful path; a backreference callback
treats the sentinel as ordinary mismatch. This prevents a group skipped by
alternation from leaking LPegLabel's missing-back-capture error and lets native
capture/backtracking order retain the latest participating value.

## Match records and result projection

A compiled `Regex` stores the expression, capture count, and traced
`peg.Pattern`. A `RegexMatch` stores the exact subject, its whole-match span,
and a dense array of local `GroupSpan` wrappers. The wrapper is necessary
because trailing nil elements do not contribute to a Titan Array's length.
Each group slot therefore exists independently of whether that group
participated.

Match operations preserve byte offsets while callbacks may run and rederive
raw pointers afterward. Public span accessors construct fresh records so a
caller cannot mutate cached match state. Both compiled `Regex:match` and the
cached source-expression `match` return `RegexMatch?`; capture projection is
explicit through `RegexMatch:values`. This keeps the public signatures typed
and allows all 200 groups. `RegexMatch:values` likewise has a fixed optional
string prefix because it returns either the whole match or at least the first
capture before its genuinely variable tail. The typed `gmatch` iterator
likewise returns a non-nil `RegexMatch`, avoiding a nil first capture becoming
generic-for termination.

Initial positions are normalized separately from the underlying PEG engine:
zero and negative overshoot become 1, positive overshoot is immediate
no-match, and `^` is compiled relative to that normalized search start.

## Iteration and replacement

`gmatch` and `gsub` retain the end-after position of the previous accepted
match. An empty candidate at that same position is suppressed; before
end-of-subject, the next attempt advances one byte, and `gsub` copies that byte
to the output. This is Lua 5.5's previous-end rule, not an unconditional
advance after every empty match.

Replacement has no raw-Lua dispatch or template parser. Both public `gsub`
forms require an exact `(string) -> string` function. For each accepted match,
the implementation materializes `RegexMatch:whole()`, calls the replacement
through Titan's ordinary typed callable path with that one string, and appends
the returned string. Captures never change callback arity, and `%` bytes in
the result have no special meaning. Returning the supplied string retains the
match; returning `""` deletes it.

An accepted zero-width match therefore calls the replacement with `""`; a
zero-width candidate suppressed by the previous-end rule never calls it.
Callback errors and wrong Lua return types propagate through the ordinary call
and result-conversion machinery.

## Roots, callbacks, and errors

The regex cache is weak-valued. A live regex roots its PEG pattern, and a live
iterator roots the regex, subject, and current position. During synchronous
`gsub`, the generated frame roots the regex, subject, replacement function,
whole-match argument, and returned string across each callback. The PEG
pattern's native uservalue graph roots constant captures, grammars, tables,
and callbacks.

Runtime/match-time/function captures and `gsub` replacement functions run
through non-yieldable callable paths. They may allocate, collect, or raise,
but only traced objects and checked offsets remain live across the call.
`gsub` uses the ordinary generated function-call and return-conversion path
rather than a manual Lua-stack `pcall`/type-dispatch wrapper. Callback
execution is serial on the current Lua thread; no process-global mutable
matching state is introduced. The separate stack-balanced `%s` conversion
path continues to propagate `__tostring` errors as described above.
