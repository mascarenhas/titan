# String standard library

The `string` standard module provides byte-oriented string operations,
Lua-compatible formatting and binary packing, yielding in-memory streams, and
a compiled regular-expression API with convenience iterators. Titan imports
the canonical module with `import "string"`; Lua uses
`require "titan.string"`.

```titan
local strings = import "string"

function sample(): string
  return strings.upper(strings.sub("hello", 2, 4))
end
```

`string` remains a type keyword, so examples conventionally bind the imported
module to another local name. The short import is parser sugar for
`import "titan.string"`.

Loading `titan.string` does not replace Lua's global `string` table, change the
Lua string metatable, or modify `package.loaded.string`. Titan's regex syntax
is independent of Lua's native string patterns.

## Byte strings and typed boundaries

All operations in this module treat a string as an immutable sequence of
bytes:

* lengths and positions count bytes, not characters;
* an embedded NUL is an ordinary byte unless a documented C-style format
  rejects it;
* character classes, word boundaries, and case conversion are not implicit
  UTF-8 or Unicode operations;
* public positions are one-based, and inclusive end positions are used where
  an API returns a range.

The Lua-derived byte, case, format, and pack operations follow Lua 5.5
semantics for values admitted by their Titan signatures. The regex API below
deliberately uses typed `Regex` and `RegexMatch` records instead of Lua's
pattern-result tuples. A fixed `string` parameter requires an actual string;
unlike some Lua library functions, it does not coerce a number to a string. A
fixed `integer` parameter accepts a Lua integer or an exactly integral,
representable Lua float at the Lua boundary. Fractional and out-of-range
numbers are rejected.

The dynamic `value` operands of `format` and `pack` are checked with Titan
casts selected by the format. Integer branches use `as integer`, floating
branches use `as float`, and binary-string packing branches use `as string`.
Consequently, an exactly integral representable Lua float is accepted by an
integer branch, but numeric strings are not converted to numbers and numbers
are not converted to strings for `c[n]`, `s[n]`, or `z`.

Titan variadic and flexible-result tails contain at most 200 elements. This
module additionally caps each projected result list at 200 total values, even
when its type has a fixed prefix. Thus:

* `byte` returns at most 200 bytes;
* `char`, `format`, and `pack` accept at most 200 variadic operands;
* `unpack` returns at most 200 values, including its final next-position
  result;
* a regex may contain at most 200 capture groups, all of which can be returned
  by `RegexMatch:values`.

Crossing one of the argument or result bounds raises Titan's ordinary variadic
or flexible-result error. `compile_regex` instead reports
`too_many_captures` for the capture bound. For `unpack` and
`RegexMatch:values`, the fixed first result leaves room for at most 199 values
in the flexible tail.

## Byte operations

```titan
function len(subject: string): integer
function sub(subject: string,
             first: integer,
             last: integer?): string
function reverse(subject: string): string
function lower(subject: string): string
function upper(subject: string): string
function rep(subject: string,
             count: integer,
             separator: string?): string

function byte(subject: string,
              first: integer?,
              last: integer?): (...: integer)
function char(...: integer): string

function find(subject: string,
              needle: string,
              init: integer?): (integer?, integer?)
```

`len` returns `#subject`. `reverse` reverses bytes, including NUL and high-bit
bytes.

`sub` uses Lua 5.5 index normalization. A negative index counts from the end;
zero and an overshoot are clamped as in Lua. Omitted or nil `last` means `-1`.
An empty normalized interval returns `""`.

`lower` and `upper` apply the process C locale one byte at a time. They are not
Unicode case transforms. For deterministic ASCII behavior, run under the
`C` locale.

`rep` repeats `subject` `count` times, placing `separator` between adjacent
copies. Omitted or nil `separator` means `""`; a nonpositive count returns
`""`. Result-size arithmetic is checked before allocation.

`byte` defaults `first` to 1 and defaults `last` to that same raw
supplied/defaulted `first` before normalizing either endpoint. This detail
means that `byte("abc", 0)` and a negative overshoot return no values rather
than byte 1. An empty interval likewise returns no values.

`char` returns a string made from its byte operands. Every operand must be in
`0..255`; `char()` returns `""`.

`find` searches for the first literal occurrence of `needle`. Regex
metacharacters have no special meaning, and embedded NUL and high-bit bytes
are ordinary data. Success returns its one-based first and inclusive last
positions; failure returns the fixed pair `nil, nil`. A caller interested only
in success may consume the first result and let ordinary call adjustment
discard the second. `init` uses the same normalization as `sub`: omitted/nil
means 1, zero or a negative overshoot becomes 1, and an in-range negative
value counts from the end. A positive start after `#subject + 1` fails. An
empty needle at a valid start succeeds with `last == first - 1`.

## Value conversion

```titan
function tostring(candidate: value): string
```

`tostring` applies Lua 5.5's built-in value conversion directly, including a
callable `__tostring` metamethod. Replacing `_G.tostring` does not affect it.

This function has one ordinary `value` parameter, not a variadic parameter.
Titan's normal fixed-call adjustment supplies nil for a missing parameter and
discards surplus values. Consequently:

```titan
strings.tostring()                 -- "nil"
strings.tostring(nil)              -- "nil"
strings.tostring(42, "ignored")    -- "42"
```

Surplus argument expressions are still evaluated from left to right before
their values are discarded. This is the general Titan call rule: an API does
not need a variadic tail merely to ignore extra arguments.

## Formatting

```titan
function format(format_string: string, ...: value): string
```

`format` implements Lua 5.5's formatting language:

```text
%%  %c  %d  %i  %u  %o  %x  %X
%a  %A  %e  %E  %f  %g  %G
%p  %q  %s
```

Flags, widths, and precisions follow Lua's accepted combinations. Integer and
floating conversions use the configured target Lua/C widths. `%p` uses the
Lua identity pointer for the value. `%q` writes a Lua-readable literal for a
string, number, boolean, or nil and rejects other values.

`%c`, `%d`, `%i`, `%u`, `%o`, `%x`, and `%X` cast their operand to `integer`;
the floating conversions cast it to `float`. Numeric strings are rejected.
Because the `%q` type dispatch uses the same checked relation as `as`, an
integral float takes `%q`'s integer branch and is written as an integer
literal; a fractional float takes the hexadecimal-float branch.

`%s` first applies the same conversion as this module's `tostring`. It can
therefore call `__tostring` and propagate its error. An unmodified `%s`
preserves the complete converted byte string. A modified `%s` is a C-style
conversion and rejects a converted string containing NUL.

Each conversion consumes one variadic operand; `%%` consumes none. Missing
operands and invalid conversion specifications raise. Surplus operands are
ignored after their expressions have been evaluated.

## Binary packing

```titan
function pack(format_string: string, ...: value): string
function packsize(format_string: string): integer
function unpack(format_string: string,
                data: string,
                initial: integer?): (value, ...: value)
```

The binary format language is the Lua 5.5 language:

| Options | Meaning |
| --- | --- |
| `<`, `>`, `=` | little endian, big endian, or native endian |
| `![n]` | set maximum alignment; omitted `n` uses the target's native maximum |
| `b`, `B` | signed or unsigned byte |
| `h`, `H` | signed or unsigned C `short` |
| `l`, `L` | signed or unsigned C `long` |
| `j`, `J` | signed or unsigned `lua_Integer` |
| `T` | C `size_t` |
| `i[n]`, `I[n]` | signed or unsigned integer in `n` bytes; default C `int`, maximum 16 |
| `f`, `n`, `d` | C `float`, `lua_Number`, or C `double` |
| `c[n]` | fixed-width byte string, padded with zero bytes |
| `s[n]` | byte string prefixed by an unsigned `n`-byte length |
| `z` | NUL-terminated byte string; the operand itself may not contain NUL |
| `x` | one zero padding byte |
| `X<next-option>` | padding needed for the alignment of the following option |
| space | ignored |

Widths, alignments, endianness, and floating representations come from the
exact target C compiler and Lua configuration. Signed and unsigned overflow,
integer sign/zero extension, result sizes, alignment, and short input are
checked.

Integer options cast their dynamic operand to `integer`, and floating options
cast it to `float`; integral floats therefore work in integer options while
numeric strings do not. The `c[n]`, `s[n]`, and `z` options cast to `string`
and reject every non-string operand instead of applying Lua's number-to-string
conversion.

`packsize` returns the size of a fixed-width format and rejects the
variable-length `s[n]` and `z` options.

`unpack` returns every decoded value followed by the one-based position of the
next unread byte. Its fixed `value` result expresses that there is always at
least that final position, even when the format decodes no values; the
flexible tail accounts for the format-dependent remainder. Omitted or nil
`initial` means 1. Zero and a negative overshoot normalize to byte 1; a
negative in range counts from the end. `#data + 1` is valid, while a larger
positive position raises.

## Yielding in-memory streams

The module provides structurally typed in-memory implementations of the
`io.ReaderCloser` and `io.WriterCloser` interfaces without importing `io`:

```titan
record StringReader
record StringWriter

function reader(contents: string): StringReader
function StringReader:read(): string?
function StringReader:read_until(delimiter: string,
                                 chop: boolean?): string?
function StringReader:close()

function writer(): StringWriter
function StringWriter:write(data: string)
function StringWriter:drain(): string
function StringWriter:close()
```

`reader` starts before the first byte. `read` returns the entire unread suffix,
or nil at end of input. `read_until` returns through the first literal,
binary-safe delimiter; a true `chop` omits that delimiter. If no delimiter
remains, it returns the unread suffix, and the next call returns nil. An empty
delimiter raises. Every read call yields one async scheduler turn before
examining the cursor, including an EOF call.

`writer` accumulates binary chunks with checked total-size arithmetic. Every
`write`, including an empty write, yields one scheduler turn. `drain` joins the
current chunks in linear time, clears both its chunks and aggregate length for
reuse, and returns `""` when it was empty. `StringReader:close` discards any
unread suffix, after which both read methods return nil; `StringWriter:close`
is a no-op. Both are idempotent, making these records useful in generic code
that always defers a closer.

## Compiled regular expressions

Regexes operate on bytes. Character classes and word boundaries are ASCII;
there is no implicit UTF-8 or Unicode mode.

```titan
record Span
  first: integer
  last: integer
end

record Regex
record RegexMatch

function compile_regex(expression: string): Regex

function Regex:source(): string
function Regex:group_count(): integer
function Regex:match(subject: string,
                     init: integer?): RegexMatch?
function Regex:gmatch(subject: string,
                      init: integer?): () -> RegexMatch?
function Regex:gsub(subject: string,
                    replacement: (string) -> string,
                    maximum: integer?): (string, integer)

function RegexMatch:span(): Span
function RegexMatch:group_count(): integer
function RegexMatch:group_span(index: integer): Span?
function RegexMatch:whole(): string
function RegexMatch:group(index: integer): string?
function RegexMatch:values(): (string?, ...: string?)
```

`compile_regex` parses once and returns a reusable regex. `source` returns its
expression, and `group_count` returns the number of capturing groups.

`Regex:match` returns a typed match record containing the whole-match and group
spans, or nil. The match roots the exact subject from which its spans are
read. It performs an unanchored search and returns the leftmost match at or
after the normalized `init`; `^` is the explicit way to require the match to
start there. Span accessors return fresh records. `Span.last` is inclusive; an
empty match has `last == first - 1`.

`group_span` and `group` use indices in
`1..RegexMatch:group_count()`. An out-of-range index raises. An unmatched
in-range group returns nil, while an empty participating group returns an
empty span/string. A repeated group retains its final iteration. `values`
returns the whole match when there are no groups; otherwise it returns one
value per group, preserving unmatched nil slots. Its fixed optional prefix
expresses that every match produces at least one projected value.

`Regex:gmatch` returns an iterator whose non-nil result is always a
`RegexMatch`. The record result is intentional: returning an unmatched first
capture as nil would prematurely terminate Titan's generic `for`.

The source-expression conveniences compile through a private weak cache:

```titan
function match(subject: string,
               expression: string,
               init: integer?): RegexMatch?
function gmatch(subject: string,
                expression: string,
                init: integer?): () -> RegexMatch?
function matches(subject: string,
                 pattern: string): () -> (string?, ...: string?)
function split(subject: string,
               delimiter: string?): () -> string?
function gsub(subject: string,
              expression: string,
              replacement: (string) -> string,
              maximum: integer?): (string, integer)
```

Top-level `match` is the cached source-expression form of `Regex:match` and
performs the same leftmost search, returning the same typed record. Call
`RegexMatch:values` when capture strings are the desired result.

`matches` wraps `gmatch` and projects each accepted match with `values`: a
pattern without captures yields the whole match, while a capturing pattern
yields its captures. This direct tuple form has the ordinary generic-for
limitation that an unmatched first capture is nil and therefore terminates a
`for` loop; use `gmatch` and inspect its non-nil `RegexMatch` when the first
capture can be optional. Direct calls to the returned iterator still preserve
all capture slots.

With a nil or omitted delimiter, `split` yields one byte at a time and yields
nothing for an empty subject. A non-nil delimiter is a compiled regex: its
captures are ignored, and leading, trailing, and adjacent delimiters produce
empty fields. Zero-width delimiters use the same byte-progress rule as
`gmatch`, so they cannot loop indefinitely.

### Initial positions and anchors

Regex searches normalize `init` as follows:

| Supplied `init` | Search start |
| --- | --- |
| nil or omitted | byte 1 |
| `0` or a negative overshoot | byte 1 |
| positive `1..#subject+1` | that position |
| negative within range | `#subject + init + 1` |
| positive `>#subject+1` | immediate no-match |

`^` anchors at this normalized search start, not necessarily absolute byte 1.
`$` tests the absolute end of the subject. Position `#subject + 1` can match an
empty expression.

### Regex syntax

```text
regex         ::= "^"? alternation "$"? EOF
alternation   ::= concatenation ("|" concatenation)*
concatenation ::= piece*
piece         ::= atom quantifier?
quantifier    ::= "*" | "+" | "?"
                | "{" decimal "}"
                | "{" decimal "," "}"
                | "{" decimal "," decimal "}"
atom          ::= "."
                | literal
                | escape
                | character-class
                | "(" alternation ")"
                | "(?:" alternation ")"
                | backreference
```

The supported operations are:

* literal bytes and `.` (any byte except LF; CR is included);
* classes, ordered ranges, and leading-`^` class negation;
* left-biased alternation;
* capturing and `(?:...)` noncapturing groups;
* greedy, continuation-aware `*`, `+`, `?`, `{n}`, `{n,}`, and `{n,m}`;
* complete-expression `^` and `$`;
* ASCII `\w`, `\W`, `\d`, `\D`, `\s`, and `\S`;
* `\t`, `\n`, `\r`, `\f`, `\e`, and `\a`;
* word boundaries `\<` and `\>`;
* single-digit backreferences `\1` through `\9`.

`\w` is `[A-Za-z0-9_]`. `\s` is space, tab, vertical tab, LF, and CR; it
deliberately excludes form feed.

Alternatives commit left to right: `a|ab` matches `"a"` in `"ab"`.
Repetition is greedy but can shorten to allow its continuation to match.
Outer anchors bind the complete alternation, so `^a|b$` anchors both branches.
An anchor elsewhere is an error.

Empty expressions, alternatives, and groups are valid: `""`, `"|"`, `"()"`,
`"(?:)"`, `"a|"`, and `"|a"` all compile.

Inside a class, `]` is literal only as `\]`; `-` is literal when first, last,
or escaped. Empty/unclosed classes and reversed ranges are errors. Outside a
class, the metacharacters `()[]{}\?*+|.^$` can be escaped to become literal.
Unknown escapes, `\v`, hexadecimal/octal escapes, `\b`, and multi-digit
backreferences are unsupported. Literal braces must be escaped.

A backreference may refer only to a previously closed group 1 through 9. If
that group did not participate in the chosen alternative, the backreference
is an ordinary mismatch.

Nullable operands cannot be placed under an unbounded repetition. Repeat
bounds are checked, the maximum must not be smaller than the minimum, and
oversized compiled patterns are rejected before native construction.

### Iteration and substitution

`gmatch` and `gsub` follow Lua 5.5's empty-match progress rule: an empty match
at the end of the previous accepted match is suppressed, and searching then
makes byte progress. This prevents an iterator or substitution from looping
forever without discarding bytes.

`gsub` accepts exactly one replacement function of type
`(string) -> string`. It calls the function once for each accepted match and
passes the whole matched string as its sole argument, whether or not the
regular expression contains captures. Capture groups remain available through
the `RegexMatch` operations returned by `match` and `gmatch`; `gsub` does not
project them into callback arguments.

The callback's returned string replaces the match. Return the supplied
whole-match argument to retain the original text, or `""` to delete it.
Percent signs in the returned string are ordinary bytes; `gsub` has no
replacement-template language. A callback error propagates, and a Lua
callback that returns a non-string observes the ordinary typed-return error.

An accepted empty match passes `""` to the callback. An empty candidate
suppressed by the progress rule does not call it. The count is the number of
accepted matched occurrences, including occurrences for which the callback
returns the original text. Omitted or nil `maximum` allows at most
`#subject + 1` substitutions; a nonpositive maximum performs none.

### Regex diagnostics and limits

Invalid expressions raise a string with a stable label, one-based byte
position, line/column, source line, and caret:

```text
invalid regular expression [bad_quantifier_bounds] at L1:C6 (byte 6): maximum repeat is smaller than minimum
a{5,2}
     ^
```

Labels distinguish malformed groups/classes/ranges/quantifiers, nullable
repetition, dangling or unsupported escapes, misplaced anchors/quantifiers,
invalid backreferences, excessive captures/group nesting/pattern size, and
trailing input. CRLF counts as one line ending.

Capturing and noncapturing groups share a stable maximum nesting depth of 512.
The 200-capture limit therefore remains valid even when all captures are
nested. Exceeding the nesting limit raises `group_nesting_too_deep`;
`peg.set_max_stack` does not control which group depths compile. It still
controls LPegLabel's execution stack when a compiled regex is matched.

Regex compilation exposes no raw PEG-engine error. The relabel grammar builds
its AST through constant-depth match-time actions, so parsing cannot leak a
depth-dependent backtrack-stack overflow and remains independent of
`peg.set_max_stack`. During matching, a backreference to a group which did not
participate is ordinary mismatch rather than a missing-back-capture error.
