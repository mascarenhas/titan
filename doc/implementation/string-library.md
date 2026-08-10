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
titan.coroutine --> titan.uv --> titan.async
titan.peg --> titan.string -----> titan.async
                    | `--------> titan.net
                    `----------> titan.os
titan.gc ----------------------> titan.string
titan.gc --> titan.peg
private namespaced LPegLabel archive --> titan.peg
```

`titan.peg` does not import `titan.string`; its relabel implementation retains
small private byte/diagnostic helpers to avoid a cycle. Both modules import the
public `titan.gc` surface to configure their weak caches. `titan.string` uses
the typed PEG surface but has no async-runtime dependency. The dependency runs
the other way: `titan.async` uses this module's public byte operations and
synchronous writer for its channel-backed string adapters. `titan.string`
never reaches the embedded PEG engine or private uv continuation layer through
a raw escape hatch. Both
`titan.net` and `titan.os` dogfood the literal
`titan.string.find` and byte-preserving `titan.string.sub` operations.
The independent `titan.url` module imports both public modules: `titan.peg`
compiles and executes its labeled grammar, while `titan.string` supplies its
writer and byte-preserving normalization helpers. Neither dependency exposes
private engine or storage state to URL.
The adapter state and close rules are documented with their owner in
[The libuv continuation runtime](libuv-runtime.md#string-specialized-channel-adapters).
Production places all eighteen logical modules and LPegLabel in one static
bundle.

The installed standard build requests eighteen roots in stable order:

```text
titan.coroutine
titan.uv
titan.async
titan.timer
titan.io
titan.fs
titan.net
titan.ssl
titan.url
titan.http
titan.os
titan.peg
titan.string
titan.math
titan.lua
titan.iter
titan.gc
titan.test
```

The request order keeps `titan.io` before its concrete stream users, places
the high-level SSL, URL, and HTTP layers after `titan.net`, retains the four
independent qualified utility modules, and remains
non-topological. Recursive import loading resolves both the
`titan.async`/`titan.net`/`titan.os` to `titan.string` to `titan.peg` chains
and the `titan.url` PEG/string dependencies while those facades are processed.

The paired `titan.so`/`titan.a` therefore contains eighteen logical protocols
and eighteen archive metadata keys. The DSO exposes nineteen Lua openers: bare
`luaopen_titan` support plus one entry per logical module. The provider's
metadata-free payload begins with `titanlib.o`, then the private
`libtitan-lpeglabel.a`, then the selected libuv payload, private HTTP adapter
and llhttp archive, and the selected OpenSSL payload used directly by
`titan.ssl`.
Those native inputs have no Titan metadata keys and their private
archives/headers are not installed in the compiler SDK.

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
valid only while `owned` is live. Casting the complete owned array to `string`
creates an immutable Lua string with exactly that recorded length, including
embedded and trailing zero bytes; no intermediate `StringBytes` record,
untyped storage cast, or userdata constructor is needed.

`snprintf` destinations are the sole prefix-length exception. They allocate
`required + 1` bytes for C's terminating zero but return only the first
`required` bytes. After verifying the second `snprintf` result, their small
finishing helper copies that prefix into an exact-length owned array and casts
the array directly to `string`. This preserves embedded zero bytes, makes the
zero-length case ordinary Titan code, and avoids manipulating the Lua stack.
Every other exact-size builder casts its complete owned array directly without
the prefix copy.

The target maximum string length is likewise invariant for one loaded module.
The initializer calls `maximum_string_bytes()` once and stores the result in
`MAXIMUM_STRING_BYTES`; hot allocation and growth paths read that module
value.

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

`rep` returns immediately when both the subject and separator are empty. It
then checks one subject-plus-separator unit before multiplying by the count,
and subtracts the unused final separator. It appends the final subject
separately so a maximum count is never incremented. The empty-input fast path
matches Lua 5.5.1 and keeps an arbitrarily large positive count away from the
otherwise unnecessary size arithmetic.

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
5. restores the saved top with `defer`.

This bypasses `_G.tostring` while preserving the native number,
boolean/nil, and `__tostring` behavior. `format`'s `%s` path calls the same
helper.

Format and pack do not push dynamic operands through
`luaL_checkinteger`, `luaL_checknumber`, or `luaL_checklstring`. Their
format-selected branches use ordinary checked Titan casts: `as integer`,
`as float`, or `as string`. That removes the raw stack helpers and deliberately
rejects Lua's numeric-string and number-to-string coercions. The integer cast
still admits an exactly integral representable float.

The `tostring` helper is a trusted standard-library-internal use of the raw
Lua C API, not a general promise that arbitrary Titan FFI code can manipulate
`L` safely. The complete discipline and scope are recorded in
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

Each rendering closure casts its operand to the Titan type selected by the
conversion. Integer families use `as integer`, number families use `as float`,
and `%s` calls the module's explicit `tostring`. C-formatted conversions then
call C99 `snprintf` once to obtain the length and again with a rooted
`required + 1` destination.

The C variadic call is statically explicit for that conversion. Titan does not
attempt to forward a heterogeneous Titan `...` descriptor to C.

`%p` obtains identity through `lua_topointer`; a null pointer is formatted as
`"(null)"` without passing a null `%p` operand. `%q` is written directly in
Titan, including decimal control-byte escapes, Lua-readable minimum-integer,
infinity, NaN, and locale-neutral hexadecimal float forms. Modified `%s`
checks for embedded NUL before entering C formatting; an unmodified `%s`
appends the complete converted string.

`%q` performs its type dispatch with `is`. For numbers, `is integer` has the
same success condition as the checked `as integer` cast, so an integral float
uses the integer literal branch rather than the hexadecimal-float branch.

## Pack translation

One mutable `PackState` carries the format cursor, selected byte order, native
byte order, and maximum alignment. `sizeof` and `alignof` on the imported C
types supply the target's actual widths. The default maximum is the greatest
alignment of Lua 5.5.1's `LUAI_MAXALIGN` members (`long double`, `void *`, and
`long long` in Titan's required C99 mode), so `![n]` stays byte-for-byte
compatible with the linked Lua. A small integer probe determines native
endianness through `memcpy`, without type-punning.

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

The public pack loop obtains integer, floating, and string payloads with
`as integer`, `as float`, and `as string` respectively. Numeric strings and
non-string `c`/`s`/`z` operands fail at that ordinary typed boundary; integral
floats continue through integer options.

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

The source parser is one `titan.peg` relabel grammar compiled during
`titan.string`'s module initializer. Its definitions combine named lexical
patterns from `peg.define` with tightly typed AST and match-time callbacks from
`peg.define_value`; a grammar construction error is therefore an initialization
regression and is not caught or translated into a source diagnostic.

The private regex AST is a local `RegexNode` union rather than a record with
an integer kind field. Its variants are `empty`, `literal`, `any`, `class`,
`sequence`, `choice`, `group`, `repetition`, `backreference`, `word_start`,
and `word_end`. Scalar alternatives carry their source position directly;
the others carry the existing private payload records
(`RegexTextNode`, `RegexChildrenNode`, `RegexGroupNode`,
`RegexRepeatNode`, or `RegexBackreferenceNode`). Constructors are called
positionally, including record payloads in parentheses.

The grammar recognizes complete atoms, escapes, classes, quantifiers, group
delimiters, alternation, and anchors. Syntax punctuation is written as
characters in the grammar or in named byte-set patterns rather than compared
through numeric character codes. At the beginning of that same PEG match, a
constant-depth lexical branch validates the complete source before ordinary
failure rewinds to the AST productions. Labeled failures escape that branch,
preserving the established precedence of class, escape, and group-prefix
diagnostics without a second parser. Successful atom and delimiter productions
then run deterministic match-time actions that receive a per-match state
through `peg.argument(1)`. Those actions append AST nodes to explicit group
frames, finish sequences and choices at `|` and `)`, assign capture numbers at
opening parentheses, and validate backreferences against groups already closed
in source order. Counted-quantifier productions capture typed minimum and
maximum bounds directly rather than reparsing the matched source. The final
action returns one `ParsedRegex` capture directly; no recursive-descent wrapper
or post-PEG syntax pass follows the match.

This explicit frame stack is also the reason the grammar is structurally
constant-depth. It can enforce 512 active capturing or noncapturing groups
while preserving all 200 nested captures even after `peg.set_max_stack(1)`;
group depth does not consume LPegLabel backtrack-stack entries. Token actions
run after a complete atom or closed group and its first quantifier. The only
following guard either succeeds or raises the labeled second-quantifier
diagnostic, so there is no ordinary backtracking path after mutation; the
possessive token repetition likewise never revisits an accepted action. Syntax
failures and semantic checks use the same diagnostic record and are formatted
into the public label/line/column/source/caret message before raising.
LPegLabel's max-stack setting continues to govern execution of the PEG produced
by the regex compiler, not construction of the regex AST.

Compilation is continuation-based. Each AST node is converted with the
pattern that must follow it, which gives greedy repetition its required
backtracking behavior. Ordered choice preserves left bias. Whole-expression
anchors wrap the completed alternation instead of attaching to one branch.
Position lookup, nullability, backreference validation, projected-size
accounting, and continuation lowering dispatch through `case`/`when`. Each
arm is an ordinary block and may bind the payload record. The total compiler
passes list every local `RegexNode` variant, so closed-union control-flow
analysis proves those cases non-fallthrough without defensive impossible
`else` errors. Backreference validation deliberately remains a partial case
whose unmatched variants continue normally.
The translated construction follows `pegex.lua` from ta-regex commit
`857e48682791ba55c98a7dd99c5fc7d71c02597d` and the algorithm in Marcelo
Oikawa, Roberto Ierusalimschy, and Ana Lucia de Moura, [“Converting regexes to
Parsing Expression
Grammars”](https://www.inf.puc-rio.br/~roberto/docs/ry10-01.pdf), PUC-Rio,
2010.

`RegexNode` is local to the combined `titan.string` folder module, but its
constructors and `case` uses span `regex_parser.titan` and
`regex_compile.titan` through the ordinary shared module namespace. The
conversion changes no public `Regex`, `RegexMatch`, function signature,
logical provider key, or Lua API; it is production dogfooding of private
unions, Array payloads, and cross-contributor nominal visibility.

Before construction, the compiler:

* parses counted bounds with checked arithmetic;
* rejects a maximum smaller than its minimum;
* computes nullability and rejects an unbounded nullable repetition;
* numbers captures once in left-to-right opening order;
* bounds active group nesting at 512;
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

A compiled `Regex` stores the expression, capture count, traced `peg.Pattern`,
and the parser's start-anchor bit. Search operations use that bit instead of
reinterpreting the source expression. A `RegexMatch` stores the exact subject,
its whole-match span, and a dense Array of `Span` records. Trailing nil
elements do not contribute to an Array's length, so an unmatched capture uses
the private impossible span `(0, -1)`. Participating spans are one-based;
participating empty captures retain their real `(n, n - 1)` position. Public
accessors translate only the impossible sentinel back to nil and return fresh
records, so every capture slot exists without collapsing empty and unmatched
semantics.

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

The convenience `matches` closure deliberately performs the opposite
projection: it calls the rooted `gmatch` closure, returns nil at exhaustion,
and otherwise forwards `RegexMatch:values`. Consequently an unmatched first
capture is visible as nil and has the language's ordinary generic-for
termination meaning. This limitation is documented rather than hidden behind
an extra public control value.

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

`split` without a delimiter is a small cursor closure over one-byte `sub`
calls. With a regex delimiter it roots the compiled regex, subject, gmatch
iterator, and next field position. Delimiter captures are never projected.
The gmatch previous-end rule provides finite byte progress for zero-width
delimiters, while the separate field cursor preserves leading, trailing, and
adjacent empty fields.

## In-memory stream state

`StringReader` retains only a string and one-based cursor. Its `read` and
literal `read_until` methods synchronously update that cursor without retaining
borrowed pointers. Delimiter search and slicing reuse the module's binary-safe
`find` and `sub`.

`StringWriter` is the checked accumulator used by formatting, packing,
substitution, and other bounded joins. The record itself stores rooted chunks
plus their checked aggregate length. Every public and internal `write` is
synchronous; Task synchronization belongs to the channel-backed adapter owned
by `async`. `drain` performs one exact-size allocation and copy, then replaces
the chunk array and resets the length to zero. This
avoids quadratic repeated concatenation while allowing the same writer to be
reused after a drain.
Neither close method owns a native resource. `StringReader:close` nevertheless
discards its backing string and resets the cursor so it releases unread data
promptly; subsequent reads return `nil`. `StringWriter:close` is a no-op.

## Roots, callbacks, and errors

The regex cache has typed Map shape `{string: Regex}`; ordinary Map lookup
produces `Regex?` for an absent key. Module state creates the cache directly
at that type. Its initializer passes the same table through the public
`gc.weak` boundary, which installs weak-value mode while preserving an existing
metatable. The cast to `{value: value}` is confined to that configuration call;
ordinary cache reads and writes remain typed Map operations. A live regex
roots its PEG pattern, and a live iterator roots the regex, subject, and
current position. During
synchronous `gsub`, the generated frame roots the regex, subject, replacement
function, whole-match argument, and returned string across each callback. The
PEG pattern's native uservalue graph roots constant captures, grammars,
tables, and callbacks.

Runtime/match-time/function captures and `gsub` replacement functions run
through non-yieldable callable paths. They may allocate, collect, or raise,
but only traced objects and checked offsets remain live across the call.
`gsub` uses the ordinary generated function-call and return-conversion path
rather than a manual Lua-stack `pcall`/type-dispatch wrapper. Callback
execution is serial on the current Lua thread; no process-global mutable
matching state is introduced. The separate stack-balanced `%s` conversion
path continues to propagate `__tostring` errors as described above.
