# PEG standard library

The `peg` standard module provides typed parsing-expression grammars, labeled
failure and recovery, captures, and a source notation derived from LPegLabel's
`relabel` module.

Titan imports it with `import "peg"`, which is parser sugar for
`import "titan.peg"`. Lua uses `require "titan.peg"`.

```titan
local peg = import "peg"

function identifier(): peg.Pattern
  local first = peg.ranges("az", "AZ", "__")
  local rest = peg.ranges("az", "AZ", "__", "09")
  return peg.sequence(first, peg.zero_or_more(rest))
end
```

Patterns operate on bytes. `literal`, `set`, `ranges`, captures, positions,
and failure positions do not imply UTF-8 or Unicode semantics. The explicit
`utf_range` constructor is the only operation that interprets UTF-8
encodings.

The module embeds a private LPegLabel engine. It does not load or modify the
Lua module named `lpeglabel`, and patterns from an external LPegLabel
installation cannot be mixed with `peg.Pattern` values.

## Public types

```text
record Pattern
record Rule
record Definition

record Locale
  alnum: Pattern
  alpha: Pattern
  cntrl: Pattern
  digit: Pattern
  graph: Pattern
  lower: Pattern
  print: Pattern
  punct: Pattern
  space: Pattern
  upper: Pattern
  xdigit: Pattern
end
```

`Pattern`, `Rule`, and `Definition` are opaque. Their native patterns,
grammar entries, definition values, and construction-size accounting cannot
be inspected or changed by callers.

## Constructors

```text
function literal(text: string): Pattern
function any(count: integer?): Pattern
function succeed(): Pattern
function fail(): Pattern
function runtime(
  callback: function (string, integer, string): (...: value)
): Pattern

function set(bytes: string): Pattern
function ranges(...: string): Pattern
function utf_range(first: integer, last: integer): Pattern

function variable(name: string): Pattern
function rule(name: string, pattern: Pattern): Rule
function grammar(start: string, rules: {Rule}): Pattern
function behind(pattern: Pattern): Pattern
function throw(label: string): Pattern
```

The basic constructors have these meanings:

| Function | Meaning |
| --- | --- |
| `literal(text)` | Match the exact binary string. An empty string succeeds without consuming input. |
| `any(n)` | For `n >= 0`, match exactly `n` bytes. For negative `n`, succeed without consuming input only when fewer than `-n` bytes remain. Omitted or nil `n` means 1. |
| `succeed()` | Succeed without consuming input. |
| `fail()` | Fail normally. |
| `runtime(callback)` | Run an immediate matching callback at the current position. |
| `set(bytes)` | Match one byte present in `bytes`. |
| `ranges(parts...)` | Match one byte in any inclusive range. Every part must contain exactly two bytes; no parts means failure. |
| `utf_range(first, last)` | Match a UTF-8 encoding for a code point in the inclusive range. Bounds must satisfy `0 <= first <= last <= 0x10ffff`. |
| `variable(name)` | Construct an open grammar reference. |
| `rule(name, pattern)` | Construct one named or recovery rule. |
| `grammar(start, rules)` | Close an Array of rules into a grammar with the named start rule. |
| `behind(pattern)` | Match `pattern` immediately behind the current position without consuming input. The pattern must be capture-free and have fixed length at most 255 bytes. |
| `throw(label)` | Commit an uncaught labeled failure at the current position. |

`utf_range` follows the pinned engine exactly: it includes UTF-8 encodings of
surrogate code points. It validates code-point range encodings, not Unicode
scalar values, and does not put other patterns into a Unicode mode.

Grammar names and throw labels are strings. Their bytes are significant:
`""`, `"1"`, `"01"`, and strings containing NUL are all distinct. Integer
names and labels are rejected at the Titan/Lua boundary.

The `rules` value is a Titan Array, not a Map. Every position from 1 through
its length must hold a `Rule`; names must be unique, there may be no more than
1000 rules, and one rule must have a name equal to `start`. An ordinary Lua
table does not implicitly become an Array. Lua code that constructs grammars
must receive the canonical Array proxy from Titan code, for example from an
application-specific exported helper that returns `{Rule}`.

`runtime` receives the subject, the current absolute one-based position, and
the empty whole-match string `""`. Its first result controls the match:

* nil, false, or no result means failure;
* true means success at the current position;
* an integer means success at that new absolute position;
* every later result becomes a capture.

An integer result must be between the current position and one past the
subject's end.

## Composition and repetition

Titan uses named functions in place of LPeg's overloaded operators:

```text
function sequence(...: Pattern): Pattern
function choice(...: Pattern): Pattern
function difference(first: Pattern, ...: Pattern): Pattern

function lookahead(pattern: Pattern): Pattern
function negative(pattern: Pattern): Pattern

function at_least(pattern: Pattern, count: integer): Pattern
function at_most(pattern: Pattern, count: integer): Pattern
function zero_or_more(pattern: Pattern): Pattern
function one_or_more(pattern: Pattern): Pattern
function optional(pattern: Pattern): Pattern
```

`sequence` and `choice` are left folds. Empty `sequence()` is `succeed()`;
empty `choice()` is `fail()`. With one operand they return that operand.

`difference(first, rest...)` is the left fold
`((first - rest[1]) - rest[2])...`; with no tail it returns `first`.
`lookahead` and `negative` are non-consuming positive and negative
predicates.

`at_least(p, n)` is the possessive LPeg repetition `p ^ n`;
`at_most(p, n)` is `p ^ -n`. Counts must be nonnegative.
`at_most(p, 0)` is an empty success. The convenience functions are:

```text
zero_or_more(p) == at_least(p, 0)
one_or_more(p)  == at_least(p, 1)
optional(p)     == at_most(p, 1)
```

Ordered choice catches ordinary failure only. An uncaught `throw` commits
past remaining choices and repetitions. Inside a positive or negative
predicate, a throw becomes predicate failure instead of escaping. A grammar
rule whose name equals the label is a recovery rule: it starts at the throw
position, and a successful recovery resumes the original match.

The string `"fail"` is reserved for ordinary failure:
`throw("fail")` is exactly equivalent to `fail()`. It therefore falls through
ordered choice, terminates a repetition normally, cannot enter a grammar
recovery rule named `"fail"`, and reports the ordinary
`nil, "fail", position` triple.

## Captures

```text
function capture(pattern: Pattern): Pattern
function constant(...: value): Pattern
function match_time(
  pattern: Pattern,
  callback: function (string, integer, value, ...: value): (...: value)
): Pattern
function back_capture(key: value): Pattern
function argument(index: integer): Pattern
function position(): Pattern
function substitution(pattern: Pattern): Pattern
function table_capture(pattern: Pattern): Pattern
function fold_capture(
  pattern: Pattern,
  callback: function (value, ...: value): (value)
): Pattern
function group(pattern: Pattern, key: value): Pattern

function select_capture(pattern: Pattern, index: integer): Pattern
function template_capture(pattern: Pattern, template: string): Pattern
function query_capture(
  pattern: Pattern,
  lookup: {value: value}
): Pattern
function function_capture(
  pattern: Pattern,
  callback: function (value, ...: value): (...: value)
): Pattern
```

The capture operations correspond to LPeg's `C`, `Cc`, `Cmt`, `Cb`, `Carg`,
`Cp`, `Cs`, `Ct`, `Cf`, `Cg`, and the four `/` forms:

* `capture(p)` returns the whole matched substring first, followed by values
  from captures nested in `p`.
* `constant(values...)` captures the values without consuming input.
* `position()` captures the current absolute one-based position.
* `argument(n)` captures match argument `n`. Its range is `1..32767`; an
  absent argument raises while matching.
* `group(p, nil)` is an anonymous group and returns its nested capture
  values. Any non-nil key makes a named group, which returns no value
  directly.
* `back_capture(key)` returns every value from the latest matching named
  group. Its key must be non-nil; a missing group raises while matching.
* `table_capture(p)` puts anonymous values at consecutive integer keys and
  puts the first value of each named group at that group's key.
* `fold_capture(p, callback)` uses the first nested capture value as its
  accumulator, then calls `callback(accumulator, next...)` for every later
  capture. The variadic `next` tail may be empty. The callback returns the
  one new accumulator. A pattern without an initial capture raises.
* `substitution(p)` replaces captured spans and copies bytes outside those
  spans.
* `select_capture(p, 0)` discards nested captures. An index in `1..32767`
  selects that nested capture.
* `template_capture(p, template)` applies the native `%0..%9` template.
* `query_capture(p, lookup)` indexes the table by the first nested capture
  and honors its ordinary `__index` behavior.
* `function_capture(p, callback)` calls the function with the nested capture
  values, and all callback results become captures.

When an operation needs a nested capture but `p` has none, LPeg applies
operation-specific implicit rules:

| Operation | Result with no nested capture |
| --- | --- |
| anonymous `group(p)` | The whole substring |
| named `group(p, key)` followed by `back_capture(key)` | The group has no direct value; the back capture returns the whole substring |
| `query_capture(p, lookup)` | Lookup by the whole substring |
| `function_capture(p, callback)` | Call with the whole substring |
| `select_capture(p, 1)` | The whole substring |
| `select_capture(p, 0)` | No capture |
| `template_capture(p, "%0")` | The whole substring |
| `template_capture(p, "%1")` | Error |
| `table_capture(p)` | An empty table |
| `fold_capture(p, callback)` | Error because there is no accumulator |

### Immediate and delayed callbacks

Capture timing is part of the contract:

* runtime patterns and `match_time` callbacks run immediately while the
  engine is deciding whether a path matches;
* `function_capture` and `fold_capture` callbacks are delayed until capture
  results are evaluated;
* a delayed capture on an abandoned alternative does not run;
* ordinary capture evaluation may happen zero, one, or multiple times, so
  callbacks attached to captures must not assume exactly-once side effects.

A `match_time` callback receives the subject, the absolute position after its
nested match, and at least one capture-side value. It receives all nested
capture values, or the whole matched substring when there are none. Its first
result follows the same false/true/integer protocol as `runtime`; later
results become captures.

A `function_capture` callback likewise receives all nested captures or the
whole matched substring, but all of its results are delayed capture values.
A fold callback receives the accumulator followed by all values from the next
capture operation and returns exactly one accumulator.

These APIs use their declared function types; callbacks are not hidden behind
an unqualified `value`. Supplying a callback follows Titan's ordinary
function-value rules: an exact Titan function can use the exact call path; an
eligible statically adjusted Titan source may use a fresh target wrapper's
native adapter; an unchanged branded mismatch uses its strict entry; and Lua
functions, C functions, and values with `__call` use the ordinary Lua call path
with dynamic result coercion. Construction does not eagerly reject
a value merely because it is not a raw Lua function. A genuinely noncallable
value raises only if matching or capture evaluation actually invokes it.
Query tables remain tables even if they also have `__call`, because
`query_capture` has the distinct `{value: value}` parameter type. Callback
execution is non-yieldable; attempting to yield raises an ordinary Lua
boundary error.

The pinned engine does not implement LPeg 1.1 accumulator `%` captures.
Upstream calls the delayed `/ function` form a function capture. Its C
internals use “dynamic capture” for the immediate runtime mechanism; Titan
therefore uses `function_capture` for the delayed public operation and
`match_time` for `Cmt`.

## Matching

```text
function Pattern:match(
  subject: string,
  init: integer?,
  ...: value
): (value, ...: value)
```

Matching is anchored at the normalized initial position; it does not search
forward automatically.

| Supplied `init` | Normalized start |
| --- | --- |
| nil or omitted | 1 |
| positive `1..#subject+1` | The supplied position |
| positive `>#subject+1` | `#subject+1` |
| `0` | `#subject+1` |
| negative within range | `#subject + init + 1` |
| negative overshoot | 1 |

Thus `-1` selects the last byte, while zero selects the position after the
last byte.

On success, `match` returns capture values when the pattern has captures.
Without captures it returns the absolute one-based position after the match.
Nil capture slots and their exact arity are preserved. The fixed `value`
prefix records that matching always produces at least one result.

Ordinary failure returns:

```text
nil, "fail", absolute_farthest_position
```

An uncaught labeled failure returns:

```text
nil, label, absolute_throw_position
```

Failure positions remain absolute when matching begins after byte 1. Labeled
failures preserve the exact label string, including empty, numeric-looking,
and binary strings. The values after `init` are available to `argument(n)`.

Extra match arguments follow Titan's 200-element variadic limit. The PEG
adapter caps the complete public result list at 200 values; its fixed first
result therefore leaves room for at most 199 values in the flexible tail.
This is a Titan API boundary, not a smaller native capture limit.

## Call adjustment

All declarations use Titan's ordinary call adjustment. A missing fixed
argument is nil-filled, and surplus arguments to a fixed parameter list are
evaluated left to right and then discarded.

That is why `any()` selects its documented nil default, `group(p)` creates an
anonymous group, and `p:match(subject)` starts at 1 without making those
functions variadic. Only a declared variadic tail collects surplus values:
for example, `sequence`, `constant`, and the extra arguments to
`Pattern:match`.

The same rule applies to relabel's optional definition and initial-position
parameters below. Omission is modeled by nil-accepting types, not by
source-level default-argument syntax.

## Locale, version, and engine limits

```text
function locale(): Locale
function set_max_stack(maximum: integer)
function version(): string
```

`locale()` snapshots the character classes of the process's current C locale.
Changing the process locale later does not mutate an existing `Locale`
record.

`set_max_stack` changes only Titan's private engine in the current Lua state.
Its accepted range is `1..21474836`. It does not change an external
`lpeglabel` module's setting.

The native engine's dynamic `type` probe and `ptree`/`pcode` debug printers
are not exported. Titan's `Pattern` type supplies the public distinction
without exposing raw native userdata.

`version()` returns the embedded native version string:

```text
LPegLabel 1.6.1
```

The engine is vendored from LPegLabel release `v1.6.2-1`, commit
`912b0b9e8641074408ffc2259e069b188e0c717b`. The release retained the older
native `VERSION` macro, so the public runtime string and the pinned source
revision intentionally differ.

Titan applies a conservative maximum constructed pattern size of 32757 tree
slots. It validates that limit before entering native constructors, including
literal/byte counts, folds, predicates, captures, grammars, and repetitions.
Other fixed native limits include:

| Feature | Limit |
| --- | --- |
| look-behind width | 255 bytes |
| grammar rules | 1000 |
| `argument` index | `1..32767` |
| `select_capture` index | `0..32767` |
| private match stack | `1..21474836` |

## Relabel source notation

The relabel API compiles a textual pattern notation into the same opaque
`Pattern` type:

```text
function define(name: string, pattern: Pattern): Definition
function define_value(name: string, candidate: value): Definition

record Match
  first: integer
  last: integer
end

function compile(
  candidate: value,
  definitions: {Definition}?
): Pattern
function match(
  subject: string,
  candidate: value,
  init: integer?
): Match?
function Match:values(): (...: value)
function gsub(
  subject: string,
  candidate: value,
  replacement: function (string): (string)
): string
function update_locale()
function line_column(
  subject: string,
  position: integer
): (integer, integer)
```

A pattern `candidate` must be a source string or a `Pattern` from this module.
`compile(pattern, definitions)` returns the same pattern and ignores
`definitions`. Definitions are used only while parsing a source string.

`definitions`, when present, is a Titan Array whose positions all hold
`Definition` values. An ordinary Lua table is not accepted; a Lua caller must
obtain an Array proxy from Titan code. Definition names must be unique, but
are otherwise arbitrary strings. A name that cannot be written by the source
notation (including an empty, punctuated, numeric-only, or binary name) is
accepted and simply remains unreachable from that source. `define` stores a
pattern definition; `define_value` retains any other supplied value for use
by a capture suffix. Nil and false definition values are rejected because the
pinned notation treats them as absent; a particular suffix may impose a
narrower native requirement when it consumes the value.

Module-level `match` performs a leftmost search at or after the same normalized
initial position used by `Pattern:match`. It returns nil on no match, or a
`Match` containing the one-based inclusive range. An empty match has
`last == first - 1`. `Match:values()` returns exactly the candidate pattern's
captures, preserving nil and trailing-nil slots; it returns zero values when
the candidate has no captures. Thus the match record is a strict superset of
the old position-only search result. Use `Pattern:match` when matching must be
anchored at the initial position or when the native failure label and position
are required. Search bookkeeping consumes no capture slots, so `values()` can
project the complete 200-value Titan capture limit.

`match` is the module's sole search operation. PEG matching has no useful
literal-versus-pattern distinction analogous to `string.find`, so the module
does not export `find`.

`gsub` returns only the transformed string, unlike Lua's `string.gsub`, which
also returns a count. Its replacement is always a `function (string): (string)` function.
The function receives the whole matched byte string exactly once for each
accepted replacement, independent of captures inside the candidate, and its
string result is inserted literally. Template, capture-index, and table
replacement forms remain available inside the relabel expression language;
they are not overloaded onto the public `gsub` parameter.

Definition-free source strings are held in one private weak compilation cache
shared by `compile`, `match`, and `gsub`. `update_locale()` rebuilds the
predefined classes from the current C locale and clears the cache.

### Expression language

Relabel accepts:

* grouping with `(p)`, concatenation by juxtaposition, and ordered choice
  `p / q`;
* positive `&p` and negative `!p` predicates;
* suffix repetitions `p?`, `p*`, `p+`, exact `p^n`, at least `p^+n`, and at
  most `p^-n`;
* single- and double-quoted literal strings, byte classes such as `[a-z]`,
  and `.` for any byte;
* predefined or external definitions written `%name`;
* recursive grammars with `name <- expression`, bare nonterminal names, and
  `<name>`;
* position `{}`, substring `{ p }`, anonymous group `{: p :}`, named group
  `{:name: p :}`, substitution `{~ p ~}`, and table `{| p |}` captures;
* named back captures `=name`;
* `-> string`, `-> number`, `-> {}`, and `-> name` capture suffixes;
* match-time `=> name` and fold `~> name` suffixes;
* `%{label}` throws, where an identifier or decimal token supplies its exact
  string bytes as the label;
* whitespace and Lua-style `--` line comments.

A quoted literal ends at the next matching quote; this notation has no
backslash escape layer inside the literal. Use the other quote delimiter when
the text contains one quote kind. Character classes may contain literal
bytes, inclusive `a-z` ranges, and `%name` definitions; a leading `^`
complements the class.

After `^`, an identifier with no intervening space is a failure label:
`p^label` means `choice(p, throw("label"))`. A decimal operand is repetition.
The reserved label `fail`, whether written `%{fail}` or as `p^fail`, is
ordinary failure. A decimal throw such as `%{01}` has the string label
`"01"`; it is not converted to an integer.

The predefined locale names are `alnum`, `alpha`, `cntrl`, `digit`, `graph`,
`lower`, `print`, `punct`, `space`, `upper`, and `xdigit`, plus short names
`a,c,d,g,l,p,s,u,w,x`. Uppercase short names are their complements, and `nl`
matches LF.

### Syntax diagnostics and positions

Invalid source notation raises an ordinary string with a stable label,
one-based byte position, line and column, source line, and caret:

```text
PEG syntax error [ExpPatt1] at L2:C7 (byte 19): expected a pattern after '/'
<source line>
      ^
```

CRLF counts as one line ending. At end of input, the caret may point one byte
past the source line.

`line_column(subject, position)` applies the same convention and accepts
positions in `1..#subject+1`. It intentionally corrects the pinned Lua
`relabel` helper's inconsistent newline and end-of-input offsets.

The embedding and rooting rules behind this module are documented in
[LPegLabel embedding and `titan.peg`](../implementation/lpeglabel-embedding.md).
The [`url` standard module](standard-library-url.md) is a shipped Relabel
dogfood example: it compiles its labeled RFC 3986-derived grammar once and
turns match labels into a nonthrowing structured error value.
