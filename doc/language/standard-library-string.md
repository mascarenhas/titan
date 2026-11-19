# String standard library

The `string` standard module provides byte-oriented string operations,
Lua-compatible formatting and binary packing, synchronous in-memory streams,
and compiled regular expressions. Titan imports it with
`local strings = import "string"` (parser sugar for `import "titan.string"`,
conventionally bound to `strings` because `string` is a type keyword); Lua
loads the same module with `require "titan.string"`.

**Target availability:** Native & Browser (complete). Loading `titan.string`
does not modify Lua's global `string` table, the string metatable, or
`package.loaded.string`.

## Example

The following module reads lines from an in-memory string, matches `key = value`
entries with a compiled regular expression, and writes a numbered summary into
a `StringWriter`:

```titan
local strings = import "string"

local entry_re = strings.compile_regex(
  [[^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$]])

function format_config(source: string): string
  local reader = strings.reader(source)
  defer reader:close()

  local out = strings.writer()
  defer out:close()

  local count = 0
  while true do
    local line? = reader:read_until("\n", true)
    if line == nil then break end
    local hit? = entry_re:match(line)
    if hit then
      local key?, val? = hit:values()
      if key ~= nil and val ~= nil then
        count = count + 1
        out:write(strings.format("%d. %s = %q\n", count, key, val))
      end
    end
  end
  return out:drain()
end
```

## Byte strings and typed boundaries

Every operation in this module treats a string as an immutable sequence of
bytes:

- Lengths and positions count bytes, not Unicode characters.
- Embedded NUL bytes are ordinary data unless a C-style format explicitly
  rejects them.
- Character classes, word boundaries, and case transforms operate on single
  bytes (ASCII or the process C locale), not UTF-8.
- Public positions are one-based, and returned spans have inclusive end
  positions.

Fixed `string` parameters require strings without coercing numbers. At the Lua
boundary, fixed `integer` parameters accept Lua integers and exact, in-range
integral floats. Dynamic `value` operands of `format` and `pack` use Titan's
`as` conversions selected by the specifier: `as integer` for integer branches,
`as float` for floating-point branches, and `as string` for `c[n]`, `s[n]`, and
`z`. Integral floats therefore work in integer formats, while numeric strings
are rejected and numbers are not implicitly converted to strings for binary
string formats.

Variadic inputs and flexible-result lists in this module are capped at 200
total elements:

- `byte` returns at most 200 bytes.
- `char`, `format`, and `pack` accept at most 200 variadic operands.
- `unpack` returns at most 200 values in total, including its trailing
  next-position result (leaving up to 199 decoded values).
- A regular expression may contain at most 200 capture groups (exceeding this
  raises `too_many_captures`), all of which `RegexMatch:values` can return.

## Byte operations

```text
function len(subject: string): integer
function sub(subject: string, first: integer, last: integer?): string
function reverse(subject: string): string
function lower(subject: string): string
function upper(subject: string): string
function rep(subject: string, count: integer, separator: string?): string
function byte(subject: string, first: integer?, last: integer?): (...: integer)
function char(...: integer): string
function find(subject: string, needle: string, init: integer?): (integer?, integer?)
```

- `len(subject)` returns `#subject`.
- `sub(subject, first, last?)` slices bytes with Lua 5.5 index normalization:
  negative indices count from the end, zero and out-of-range bounds clamp,
  omitted or `nil` `last` defaults to `-1`, and an empty normalized interval
  returns `""`.
- `reverse(subject)` reverses raw bytes, including NUL and high-bit bytes.
- `lower(subject)` and `upper(subject)` transform one byte at a time under the
  process C locale. Run under the `"C"` locale for deterministic ASCII case
  conversion.
- `rep(subject, count, separator?)` repeats `subject` `count` times with
  `separator` (default `""`) between copies. A nonpositive `count` or empty
  `subject` and `separator` returns `""`. Result size is checked before
  allocation.
- `byte(subject, first?, last?)` returns the numeric byte values (`0..255`) in
  the slice. `first` defaults to `1`, and `last` defaults to that raw `first`
  before either bound is normalized. Consequently, `byte("abc", 0)` and
  negative overshoots return zero values rather than byte `1`.
- `char(...: integer)` builds a string from byte values in `0..255`; `char()`
  returns `""`.
- `find(subject, needle, init?)` searches for the first literal, binary-safe
  occurrence of `needle` (regex metacharacters have no special meaning). It
  returns the one-based inclusive `(first, last)` pair, or `(nil, nil)` on
  failure. `init` defaults to `1`; `0` and negative overshoots clamp to `1`;
  negative in-range values count from the end; values greater than
  `#subject + 1` fail. An empty `needle` at a valid start succeeds with
  `last == first - 1`.

## Value conversion

```text
function tostring(candidate: value): string
```

`tostring` invokes Lua 5.5's value-to-string conversion directly, honoring a
callable `__tostring` metamethod and ignoring any replacement of `_G.tostring`.

Because `candidate` is one fixed `value` parameter, Titan's standard fixed-call
adjustment applies: an omitted argument becomes `nil`, and surplus argument
expressions evaluate left to right before their values are discarded:

```text
strings.tostring()                -- "nil"
strings.tostring(nil)             -- "nil"
strings.tostring(42, "ignored")   -- "42"
```

## Formatting

```text
function format(format_string: string, ...: value): string
```

`format` implements Lua 5.5's formatting language with specifiers:

```text
%%  %c  %d  %i  %u  %o  %x  %X
%a  %A  %e  %E  %f  %g  %G
%p  %q  %s
```

Flags, widths, and precisions follow Lua 5.5 rules for the target platform's
Lua/C build. Builds that use Lua's hexadecimal-float fallback (such as the
Windows SDK) accept bare `%a` and `%A` and reject flags, widths, or precisions
on them.

- `%c`, `%d`, `%i`, `%u`, `%o`, `%x`, and `%X` convert their operand with
  `as integer`; floating specifiers convert with `as float`. Numeric strings
  are rejected.
- `%p` formats Lua's identity pointer for the value.
- `%q` formats a Lua-readable literal for strings, numbers, booleans, and
  `nil`, raising for other types. Integral floats take the integer branch;
  fractional floats write hexadecimal-float literals.
- `%s` converts its operand via `tostring` (calling `__tostring` if present).
  Unmodified `%s` preserves embedded NUL bytes; modified `%s` (with flags,
  width, or precision) rejects strings containing NUL.
- `%%` writes a literal `%` and consumes no operand. Missing operands and
  malformed specifiers raise; surplus operands evaluate and are ignored.

```titan
local strings = import "string"

function format_entry(id: integer, rate: float, label: string): string
  return strings.format(
    "[#%04x] rate=%6.2f label=%q", id, rate, label)
end
```

## Binary packing

```text
function pack(format_string: string, ...: value): string
function packsize(format_string: string): integer
function unpack(format_string: string,
                data: string,
                initial: integer?): (value, ...: value)
```

Binary format strings follow Lua 5.5's packing language:

| Option | Meaning |
| --- | --- |
| `<`, `>`, `=` | Little endian, big endian, or native endian |
| `![n]` | Maximum alignment (default: platform `LUAI_MAXALIGN`) |
| `b`, `B` | Signed or unsigned byte |
| `h`, `H` | Signed or unsigned C `short` |
| `l`, `L` | Signed or unsigned C `long` |
| `j`, `J` | Signed or unsigned `lua_Integer` |
| `T` | C `size_t` |
| `i[n]`, `I[n]` | Signed or unsigned integer in `n` bytes (default C `int`, max 16) |
| `f`, `n`, `d` | C `float`, `lua_Number`, or C `double` |
| `c[n]` | Fixed-width byte string, zero-padded |
| `s[n]` | Byte string prefixed by an unsigned `n`-byte length |
| `z` | NUL-terminated byte string (operand may not contain NUL) |
| `x` | One zero padding byte |
| `X<option>` | Padding to match the alignment of the following option |
| space | Ignored |

Widths, alignments, endianness, and floating representations match the target C
compiler and Lua build. Overflow, sign/zero extension, alignment, result sizes,
and truncated inputs are checked. Integer options convert with `as integer`,
floating options with `as float`, and `c[n]`/`s[n]`/`z` with `as string`.

- `packsize(format_string)` returns the fixed byte size of `format_string` and
  rejects variable-length `s[n]` and `z` options.
- `unpack(format_string, data, initial?)` returns every decoded value followed
  by the one-based byte position of the next unread byte. Its fixed leading
  `value` result reflects that the next-position integer is always returned,
  even when the format decodes zero fields. `initial` defaults to `1`; `0` and
  negative overshoots clamp to `1`; negative in-range values count from the
  end; `#data + 1` is valid, and positions past `#data + 1` raise.

```titan
local strings = import "string"

record FrameHeader
  version: integer
  kind: integer
  length: integer
end

const HEADER_FORMAT = ">BBH"

function encode_header(header: FrameHeader): string
  return strings.pack(
    HEADER_FORMAT, header.version, header.kind, header.length)
end

function decode_header(data: string): (FrameHeader?, integer)
  if #data < strings.packsize(HEADER_FORMAT) then
    return nil, 1
  end
  local ver, kind, length, next_pos = strings.unpack(HEADER_FORMAT, data)
  return FrameHeader(ver as integer, kind as integer, length as integer),
         next_pos as integer
end
```

## In-memory streams

`StringReader` and `StringWriter` structurally satisfy `io.ReaderCloser` and
`io.WriterCloser` without importing `io`:

```text
record StringReader
record StringWriter

function reader(contents: string): StringReader
function StringReader:read(): string?
function StringReader:read_until(delimiter: string, chop: boolean?): string?
function StringReader:close()

function writer(): StringWriter
function StringWriter:write(data: string)
function StringWriter:drain(): string
function StringWriter:close()
```

- `reader(contents)` positions a synchronous reader before byte `1`.
  `read()` returns the entire unread suffix, or `nil` at end of input.
  `read_until(delimiter, chop?)` reads through the first literal, binary-safe
  `delimiter` (omitting it when `chop` is `true`), or returns the unread suffix
  if `delimiter` does not occur; a subsequent call returns `nil`. An empty
  delimiter raises while unread bytes remain; an exhausted or closed reader
  returns `nil`. `close()` discards unread bytes and is idempotent.
- `writer()` accumulates chunks synchronously with checked total-size
  arithmetic. `drain()` joins all written chunks in linear time, resets the
  writer for reuse, and returns `""` when empty. `close()` is an idempotent
  no-op so generic code can always pair `defer` with a closer.

```titan
local strings = import "string"

function render_csv(rows: {{string}}): string
  local out = strings.writer()
  defer out:close()

  for r = 1, #rows do
    local row? = rows[r]
    if row then
      for c = 1, #row do
        if c > 1 then out:write(",") end
        out:write(row[c] or "")
      end
      out:write("\n")
    end
  end
  return out:drain()
end
```

For Task-synchronized streams across cooperative tasks, use
`async.reader_writer_channel` in [Asynchronous I/O and tasks](async-io.md).

## Compiled regular expressions

Regular expressions operate on bytes with ASCII character classes and word
boundaries.

```text
record Span
  first: integer
  last: integer
end
-- Synthesized constructor: Span(first: integer, last: integer): Span

record Regex
record RegexMatch

function compile_regex(expression: string): Regex

function Regex:source(): string
function Regex:group_count(): integer
function Regex:match(subject: string, init: integer?): RegexMatch?
function Regex:gmatch(subject: string, init: integer?): function (): (RegexMatch?)
function Regex:gsub(subject: string,
                    replacement: function (string): (string),
                    maximum: integer?): (string, integer)

function RegexMatch:span(): Span
function RegexMatch:group_count(): integer
function RegexMatch:group_span(index: integer): Span?
function RegexMatch:whole(): string
function RegexMatch:group(index: integer): string?
function RegexMatch:values(): (string?, ...: string?)
```

Top-level convenience functions compile through an internal weak cache:

```text
function match(subject: string, expression: string, init: integer?): RegexMatch?
function gmatch(subject: string,
                expression: string,
                init: integer?): function (): (RegexMatch?)
function matches(subject: string,
                 pattern: string): function (): (string?, ...: string?)
function split(subject: string, delimiter: string?): function (): (string?)
function gsub(subject: string,
              expression: string,
              replacement: function (string): (string),
              maximum: integer?): (string, integer)
```

- `compile_regex(expression)` parses `expression` once into a reusable `Regex`.
  `source()` returns its pattern string, and `group_count()` returns the number
  of capturing groups.
- `Regex:match(subject, init?)` performs an unanchored leftmost search starting
  at the normalized `init` and returns a `RegexMatch` or `nil`. `Span` bounds
  are one-based and inclusive; an empty match has `last == first - 1`.
- `group_span(index)` and `group(index)` accept `1..group_count()` and raise
  out of range. An unmatched optional group returns `nil`; an empty matched
  group returns `""` and an empty `Span`. A repeated group keeps its last
  iteration.
- `RegexMatch:values()` returns the whole match when there are no capturing
  groups, or one slot per group preserving `nil` for unmatched groups.
- `gmatch` yields non-`nil` `RegexMatch` records, making it safe in generic
  `for` loops even when group `1` is optional. `matches` yields `values()`
  directly; because generic `for` stops on a `nil` first value, use `gmatch`
  when group `1` can be unmatched.
- `split(subject, delimiter?)` yields one byte at a time when `delimiter` is
  omitted or `nil` (yielding nothing for `""`). A string `delimiter` is
  compiled as a regex whose captures are ignored; leading, trailing, and
  adjacent delimiters yield empty fields.

```titan
local strings = import "string"

local tag_re = strings.compile_regex([[(\w+)(?::(\d+))?]])

record Tag
  name: string
  port: string?
  start: integer
end

function extract_tags(input: string): {Tag}
  local found: {Tag} = {}
  for m in tag_re:gmatch(input) do
    local name = m:group(1) or ""
    local port? = m:group(2)
    found[#found + 1] = Tag(name, port, m:span().first)
  end
  return found
end

function mask_digits(input: string): (string, integer)
  return strings.gsub(input, [[\d+]], function (digits)
    return strings.rep("#", #digits)
  end)
end
```

### Initial positions and anchors

`match` and `gmatch` normalize `init` as follows:

| Supplied `init` | Search start |
| --- | --- |
| `nil` or omitted | Byte `1` |
| `0` or negative overshoot | Byte `1` |
| Positive `1..#subject + 1` | That byte position |
| Negative in range | `#subject + init + 1` |
| Positive `> #subject + 1` | Immediate no-match |

`^` anchors at the normalized search start (not necessarily byte `1`). `$`
matches the end of `subject`. Position `#subject + 1` can match an empty
pattern.

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

Supported features:

- Literal bytes and `.` (any byte except LF; CR matches `.`).
- Character classes `[...]`, ranges `a-z`, and negation `[^...]`. Inside a
  class, escape `]` as `\]`; `-` is literal when first, last, or escaped.
- Left-biased alternation (`a|ab` matches `"a"` in `"ab"`).
- Capturing `(...)` and non-capturing `(?:...)` groups.
- Greedy, backtracking quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`.
- Outer anchors `^` and `$` covering the entire alternation (`^a|b$` anchors
  both branches; anchors inside subexpressions are rejected).
- ASCII classes `\w` (`[A-Za-z0-9_]`), `\W`, `\d`, `\D`, `\s` (space, tab, VT,
  LF, CR — excluding FF), and `\S`.
- Control escapes `\t`, `\n`, `\r`, `\f`, `\e`, `\a`, and word boundaries
  `\<` and `\>`.
- Single-digit backreferences `\1`..`\9` referring to an earlier closed group
  (an unmatched referenced group produces an ordinary mismatch).
- Escaped metacharacters `()[]{}\?*+|.^$`. Literal braces must be escaped;
  `\v`, `\b`, octal/hex escapes, and multi-digit backreferences are rejected.

Empty expressions, alternatives, and groups (`""`, `"|"`, `"()"`, `"(?:)"`) are
valid. Nullable operands under unbounded repetition (`*`, `+`, `{n,}`) and
inverted bounds (`{5,2}`) are rejected at compile time.

### Iteration and substitution

`gmatch`, `matches`, `split`, and `gsub` follow Lua 5.5's empty-match progress
rule: an empty match immediately at the end of the previous accepted match is
suppressed, advancing one byte so iteration always terminates.

`gsub` takes a callback `function (string): (string)` invoked once per accepted
match with the whole matched substring (captures are not forwarded as separate
arguments; use `match` or `gmatch` to inspect groups). The returned string is
inserted literally with no `%` template expansion; return the argument
unchanged to keep it or `""` to delete it. The returned count is the number of
accepted matches. Omitted or `nil` `maximum` allows up to `#subject + 1`
replacements; a nonpositive `maximum` performs none.

### Regex diagnostics and limits

Invalid expressions raise a diagnostic string with a stable label, one-based
byte position, line/column, source line, and caret:

```text
invalid regular expression [bad_quantifier_bounds] at L1:C6 (byte 6): maximum repeat is smaller than minimum
a{5,2}
     ^
```

| Limit | Value |
| --- | --- |
| Capturing groups | 200 (`too_many_captures`) |
| Group nesting depth (capturing + non-capturing) | 512 (`group_nesting_too_deep`) |
| Match execution stack | Governed by [`peg.set_max_stack`](standard-library-peg.md) |
