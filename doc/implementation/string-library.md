# String-library implementation

`titan.string` is one logical folder module inside the canonical standard
provider. It combines byte operations translated from Lua 5.5 string-library
semantics with a regex compiler built on the public `titan.peg` binding.
Production code is Titan plus C99 FFI: there is no string-specific C shim and
no delegation to Lua's mutable `string` table.

The user-facing contract is in the
[String standard library](../language/standard-library-string.md).

## Module and provider placement

The source is a folder ensemble rooted at `titan/string/string.titan`. The
main owns every public record, method, and function together with its body.
The contributors `bytes.titan`, `format.titan`, `pack.titan`,
`regex_parser.titan`, `regex_compile.titan`, and `regex_api.titan` declare
nothing public; they hold module-local records, state, and shared machinery
for byte operations, formatting, packing, and regex parsing/compilation. The
[maintenance rules](standard-library-maintenance.md#keep-public-behavior-with-its-declaration)
decide when a helper stays separate. All files form one logical module with
one checker/code-generator pass, one `titan_string_*` protocol, one generated
object, and one `luaopen_titan_string` entry.

`titan.string` imports only `titan.peg` (format grammar, regex parser, and
compiled regexes) and `titan.gc` (weak regex cache). `titan.peg` imports
`titan.gc` but never `titan.string`, so its relabel implementation keeps small
private byte/diagnostic helpers to avoid a cycle. `titan.string` uses only the
typed PEG surface, never the embedded engine, and has no async-runtime
dependency. Dependencies run the other way: most I/O-facing standard modules
import `titan.string`. `titan.async` uses its byte operations and synchronous
writer for the channel-backed string adapters, whose state and close rules
live in [Async channel-backed string
streams](../language/async-io.md#channel-backed-string-streams). `titan.net`
and `titan.os` use literal `find` and byte-preserving `sub`; `titan.url` uses
the writer and byte helpers beside its `titan.peg` grammar.

The module's place in the standard provider (root list, `-X` payload order,
installed files) is described once in [the standard-library
image](multi-module-libraries.md#reserved-titan-and-the-standard-library-image).

## Exact-byte storage

The shared byte layer treats every input as a `(pointer, length)` pair. It
never uses NUL termination for an ordinary string. A generated result is a
counted owned C array:

```titan
local storage: owned char[] = foreign char.new_array(length)
local output = storage as foreign *char
```

`new_array` creates the Lua full userdata, records its element count, and
leaves `storage` as the traced GC root. C calls and pointer arithmetic use the
cast pointer while `#owned` recovers the allocation length. The raw pointer is
valid only while `owned` is live. Casting the complete owned array to `string`
creates an immutable Lua string with exactly that recorded length, including
embedded and trailing zero bytes (`bytes.titan` `copy_interval` is the minimal
example).

`snprintf` destinations are the sole prefix-length exception. They allocate
`required + 1` bytes for C's terminating zero but return only the first
`required` bytes. After verifying the second `snprintf` result, their small
finishing helper copies that prefix into an exact-length owned array and casts
the array directly to `string`. This preserves embedded zero bytes, makes the
zero-length case ordinary Titan code, and avoids manipulating the Lua stack.
Every other exact-size builder casts its complete owned array directly without
the prefix copy.

Machine invariants are computed once by the module's final initializer in
`string.titan`: `MAXIMUM_STRING_BYTES` (`bytes.titan` `maximum_string_bytes`),
`INTEGER_LENGTH_MODIFIER`, `HOST_IS_LITTLE_ENDIAN`, and
`NATIVE_MAXIMUM_ALIGNMENT`. Hot allocation, formatting, and packing paths read
those module values.

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

```text
function tostring(candidate: value): string
```

It is intentionally fixed rather than variadic. Titan's existing call
adjustment pads an omitted parameter with nil and discards surplus values
after evaluating their expressions. The implementation therefore sees exactly
one `value` in every call path, including generated Lua wrappers and generic
callable dispatch.

The conversion helper:

1. saves `lua_gettop(L)`;
2. reserves three stack slots with `lua_checkstack(L, 3)`, raising "cannot
   reserve Lua stack for string conversion" if Lua cannot grow the stack;
3. pushes the `TValue` carried by `value`;
4. calls `luaL_tolstring`;
5. captures the exact resulting Lua string;
6. restores the saved top with `defer`.

The reservation is the helper's peak: the candidate plus the two temporaries
`luaL_tolstring` pushes, either the metatable and event name for
`luaL_getmetafield` or the callable and argument for `luaL_callmeta` (the
default `__name` rendering also stays within candidate, name and result). Lua
grows the stack for a called metamethod itself. A native caller can reach the
helper with no free slots above its frame's top, so pushing without the
reservation violates the raw API discipline; Lua's internal `api_check`
assertions (`-DLUAI_ASSERT`) abort on it.

This bypasses `_G.tostring` while preserving the native number,
boolean/nil, and `__tostring` behavior. `format`'s `%s` path calls the same
helper.

Format and pack never push dynamic operands through `luaL_checkinteger`,
`luaL_checknumber`, or `luaL_checklstring`. Their format-selected branches use
ordinary checked Titan casts: `as integer`, `as float`, or `as string`. This
deliberately rejects Lua's numeric-string and number-to-string coercions; the
integer cast still admits an exactly integral representable float.

The `tostring` helper is a trusted standard-library-internal use of the raw
Lua C API, not a general promise that arbitrary Titan FFI code can manipulate
`L` safely. The complete discipline and scope are recorded in
[Lua C API FFI follow-up](ffi-lua-api-followup.md).

## Format translation

The formatter ports the Lua 5.5 conversion grammar and validation tables into
a `titan.peg` pattern built once by the module initializer (`format.titan`
`build_format_pattern`). Matching a format string produces one local
`FormatPlan` (`build_format_plan`): a dense Array of exact `FormatPartial`
closures of type `function (value): (string)`, followed by one literal
trailer. A `FormatFactory` constructs each partial from the literal prefix,
the captured conversion form, and its conversion family. The signed and
unsigned factories insert the target C length modifier (`add_integer_length`)
once while building the plan; `%q` and `pack` add it at render time.

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
call a bounded native formatter once to obtain the length and again with a
rooted `required + 1` destination. A declaration/macro-only portability header
(`titan/string/format_native.h`)
selects `__mingw_snprintf` on native CLANG64/UCRT and ordinary `snprintf`
elsewhere. Lua's `lprefix.h` selects MinGW ANSI stdio before `luaconf.h` enables
its Windows C89 compatibility mode; reproducing that formatter choice keeps
pointer padding/case and non-finite-number spellings equal without changing
the generated-C feature macros for other FFI users. No formatter algorithm
lives in the header, and both calls retain the exact allocation/result checks.

When the configured Lua headers do not define `lua_number2strx`, the formatter
uses the Lua hexadecimal fallback translated into Titan. It handles signs,
zero, finite mantissas/exponents, and non-finite values, and accepts only bare
`%a`/`%A`, as Lua does in that configuration. `%q` uses the same configured
hexadecimal conversion before normalizing the locale radix. Other Lua builds
retain their native hexadecimal formatter.

The C variadic call is statically explicit for that conversion. Titan does not
attempt to forward a heterogeneous Titan `...` descriptor to C.

`%p` obtains identity through `lua_topointer`; a null pointer is formatted as
`"(null)"` without passing a null `%p` operand. `%q` is written directly in
Titan, including decimal control-byte escapes, Lua-readable minimum-integer,
infinity, NaN, and locale-neutral hexadecimal float forms. An unmodified `%s`
appends the complete converted string. A modified `%s` raises on an embedded
NUL; without a precision, a converted string of at least 100 bytes is then
appended whole, as in Lua, and only shorter or precision-limited strings
reach C formatting (`format.titan` `string_format_partial`).

`%q` performs its type dispatch with `is`. For numbers, `is integer` has the
same success condition as the checked `as integer` cast, so an integral float
uses the integer literal branch rather than the hexadecimal-float branch.

## Pack translation

One mutable `PackState` (`pack.titan`) carries the format cursor, selected
byte order, native byte order, and maximum alignment. `sizeof` and `alignof`
on the imported C types supply the target's actual widths. The maximum
alignment starts at 1, as in Lua. A `!` option without a number sets it to
`NATIVE_MAXIMUM_ALIGNMENT`, which `native_maximum_alignment` computes as the
largest `alignof` among `long double`, `void *`, and `long long` (the members
of Lua 5.5.1's `LUAI_MAXALIGN` in C99 mode), so `!` stays byte-for-byte
compatible with the linked Lua. `host_is_little_endian` determines native
endianness once through `memcpy`, without type-punning.

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
`titan.string`'s module initializer (`regex_parser.titan`
`build_regex_parser`). Its definitions combine named lexical
patterns from `peg.define` with tightly typed AST and match-time callbacks from
`peg.define_value`; a grammar construction error is therefore an initialization
regression and is not caught or translated into a source diagnostic.

The private regex AST is a local `RegexNode` union rather than a record with
an integer kind field. Its variants are `empty`, `literal`, `any`, `class`,
`sequence`, `choice`, `group`, `repetition`, `backreference`, `word_start`,
and `word_end`. Scalar alternatives carry their source position directly;
the others declare named payload parts directly: position/text,
position/children, position/group number/child, position/repetition
bounds/child, or position/backreference number/nullability. There are no
intermediate payload records. Constructors supply their parts positionally.

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

Compilation is continuation-based (`regex_compile.titan`
`regex_compile_node`). Each AST node is converted with the
pattern that must follow it, which gives greedy repetition its required
backtracking behavior. Ordered choice preserves left bias. Whole-expression
anchors wrap the completed alternation instead of attaching to one branch.
Position lookup, nullability, backreference validation, projected-size
accounting, and continuation lowering dispatch through `case`/`when`. Position
lookup binds only the first positional part; the other passes select the
needed named parts, omitting unused values. Each arm is an ordinary block. The total compiler
passes list every local `RegexNode` variant, so closed-union control-flow
analysis proves those cases non-fallthrough without defensive impossible
`else` errors. Backreference validation deliberately remains a partial case
whose unmatched variants return the original node. A nullable referenced
group produces a new backreference variant with its final nullability;
the validation action passes that returned node to quantifier handling.
The translated construction follows `pegex.lua` from ta-regex commit
`857e48682791ba55c98a7dd99c5fc7d71c02597d` and the algorithm in Marcelo
Oikawa, Roberto Ierusalimschy, and Ana Lucia de Moura, [“Converting regexes to
Parsing Expression
Grammars”](https://www.inf.puc-rio.br/~roberto/docs/ry10-01.pdf), PUC-Rio,
2010.

`RegexNode` is local to the combined `titan.string` folder module; its
constructors and `case` uses span `regex_parser.titan` and
`regex_compile.titan` through the ordinary shared module namespace.

Before construction, the compiler:

* parses counted bounds with checked arithmetic;
* rejects a maximum smaller than its minimum;
* computes nullability and rejects an unbounded nullable repetition;
* numbers captures once in left-to-right opening order;
* bounds active group nesting at 512;
* validates each single-digit backreference against a previously closed group;
* projects the resulting PEG tree size, including continuation and capture
  wrappers, against `REGEX_PATTERN_LIMIT` (32757, `SHRT_MAX - 10`) in
  `regex_projected_size` and `string.titan` `compile_regex`;
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

Initial positions are normalized separately from the underlying PEG engine
(`regex_api.titan` `regex_normalized_init`): nil, zero, and negative values
beyond the subject start become 1; other negative values count from the end;
positive overshoot is immediate no-match. `^` is compiled relative to that
normalized search start.

## Iteration and replacement

`gmatch` and `gsub` retain the end-after position of the previous accepted
match. An empty candidate at that same position is suppressed; before
end-of-subject, the next attempt advances one byte, and `gsub` copies that byte
to the output. This is Lua 5.5's previous-end rule, not an unconditional
advance after every empty match.

Replacement has no raw-Lua dispatch or template parser. Both public `gsub`
forms require an exact `function (string): (string)` function. For each accepted match,
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
substitution, and other bounded joins. It stores rooted chunks plus their
checked aggregate length. The local `StringWriter.new()` override in
`format.titan` initializes an empty chunk Array and zero length; internal code
and the public `writer()` factory both call `StringWriter()`, and the
constructor stays source-private. Every `write` is synchronous; Task
synchronization belongs to the channel-backed adapter owned by `async`.
`drain` performs one exact-size allocation and copy, then replaces the chunk
Array and resets the length, which avoids quadratic concatenation and lets the
writer be reused. Neither close method owns a native resource.
`StringReader:close` discards its backing string and resets the cursor so
unread data is released promptly; subsequent reads return `nil`.
`StringWriter:close` is a no-op.

## Roots, callbacks, and errors

The regex cache (`regex_api.titan` `_regex_cache`) is created at its typed
Map shape `{string: Regex}`, so an absent key reads as `Regex?`. The module
initializer passes it once through a `{value: value}` view to `gc.weak`
([weak-mode ledger](gc-library.md#weak-mode-stack-ledger)); ordinary cache reads
and writes stay typed Map operations. A live regex roots its PEG pattern, and
a live iterator roots the regex, subject, and current position. During
synchronous `gsub`, the generated frame roots the regex, subject, replacement
function, whole-match argument, and returned string across each callback.

Capture callbacks and `gsub` replacements follow the PEG callback rules in
[Stack, roots, callbacks, and
errors](lpeglabel-embedding.md#stack-roots-callbacks-and-errors): they cannot
yield, may allocate, collect, or raise, and only traced objects and checked
offsets stay live across them. `gsub` calls the replacement through the
ordinary generated call and return-conversion path, with no manual Lua-stack
`pcall` or type dispatch. The stack-balanced `%s` conversion propagates
`__tostring` errors as described above.
