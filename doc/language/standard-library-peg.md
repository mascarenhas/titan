# PEG standard library

The `peg` standard module provides typed parsing-expression grammars (PEGs)
with Relabel source notation, labeled failure and recovery, captures, and named
combinators. Titan imports it with `local peg = import "peg"` (parser sugar for
`import "titan.peg"`); Lua loads the same module with `require "titan.peg"`.

**Target availability:** Native & Browser (complete). The module embeds a
private LPegLabel engine independent of any external Lua `lpeglabel` library.

## Example

Relabel source notation (`peg.compile`) is the primary way to write grammars.
This module compiles a labeled assignment grammar once and converts match
failures into structured line/column errors:

```titan
local peg = import "peg"

record Assignment
  name: string
  contents: string
end

record ParseError
  label: string
  line: integer
  column: integer
end

local ASSIGNMENT_GRAMMAR = peg.compile([[
  Assignment <- {|
    %s*
    {:name: {Ident / %{expected_name}} :}
    %s* ('=' / %{expected_equals}) %s*
    {:contents: {[^%s]+ / %{expected_value}} :}
    %s* (!. / %{trailing_input})
  |}
  Ident <- [A-Za-z_] [A-Za-z0-9_]*
]])

function parse_assignment(subject: string): (Assignment?, ParseError?)
  local captured, label, pos = ASSIGNMENT_GRAMMAR:match(subject)
  if captured == nil then
    local line, col = peg.line_column(subject, pos as integer)
    return nil, ParseError(label as string, line, col)
  end
  local fields = captured as {value: value}
  return Assignment(fields["name"] as string,
                    fields["contents"] as string), nil
end
```

## Byte orientation, ordered choice, and labels

Four rules govern all PEG matching in Titan:

1. **Patterns operate on bytes.** Literals, sets, ranges, classes, captures,
   and positions count bytes rather than Unicode characters. Only
   `peg.utf_range` interprets UTF-8 encodings.
2. **Choice is ordered and repetition is possessive.** `p / q` commits to `p`
   once `p` succeeds, and `p*` or `p+` never gives back characters to help a
   later pattern match (for backtracking regular expressions, use
   [`titan.string`](standard-library-string.md#compiled-regular-expressions)).
3. **`Pattern:match` is anchored at `init`; `peg.match` searches.** Neither
   requires end of input unless you write `!.` (or `peg.negative(peg.any())`).
4. **Labels commit.** Ordinary failure lets ordered choice try the next branch,
   ends a repetition, or advances a search. A thrown label (`%{label}` or
   `peg.throw(label)`) escapes choices and repetitions immediately, unless
   caught by a grammar recovery rule with the same name. The label `"fail"` is
   reserved for ordinary failure.

## Relabel source notation

```text
record Pattern
record Definition
record Match
  first: integer
  last: integer
end

function compile(candidate: value, definitions: {Definition}?): Pattern
function define(name: string, pattern: Pattern): Definition
function define_value(name: string, candidate: value): Definition
function match(subject: string, candidate: value, init: integer?): Match?
function Match:values(): (...: value)
function gsub(subject: string,
              candidate: value,
              replacement: function (string): (string)): string
function update_locale()
function line_column(subject: string, position: integer): (integer, integer)
```

- `compile(candidate, definitions?)` parses a Relabel source string into a
  `Pattern`, or returns an existing `Pattern` unchanged (ignoring
  `definitions`). `definitions`, when supplied, is a dense Titan Array
  `{Definition}` with unique names (ordinary Lua tables are rejected).
  `define(name, pattern)` binds a `Pattern` for `%name`;
  `define_value(name, value)` binds a table, template, selector, or callback
  for `->`, `=>`, or `~>` (rejecting `nil` and `false`). Definition-free source
  strings share a private weak compilation cache cleared by `update_locale()`.
- `match(subject, candidate, init?)` performs a leftmost search for a source
  string or `Pattern` starting at normalized `init`. On success it returns a
  `Match` with one-based inclusive bounds (`last == first - 1` for an empty
  match); `Match:values()` yields the pattern's captures (preserving `nil` and
  trailing `nil` slots, or returning zero values when capture-free). An
  uncaught thrown label stops the search and returns `nil`.
- `gsub(subject, candidate, replacement)` replaces every match with the literal
  string returned by `replacement(whole_match)` and returns only the resulting
  string.
- `update_locale()` rebuilds predefined character classes from the process's
  current C locale and clears the definition-free compilation cache.
- `line_column(subject, position)` maps a one-based byte position in
  `1..#subject + 1` to `(line, column)`, treating CR, LF, and CRLF as single
  line endings.

### Relabel expression language

| Syntax | Meaning |
| --- | --- |
| `'text'`, `"text"` | Exact byte literal (no backslash escapes; switch quotes to embed the other quote) |
| `.` | Any single byte (including LF) |
| `[a-z]`, `[^0-9]` | Byte class with literal bytes, ranges, or `%name` definitions; leading `^` complements |
| `(p)`, `p q`, `p / q` | Grouping, sequence, ordered choice |
| `&p`, `!p` | Non-consuming positive and negative predicates (discard inner captures; eager `=>` callbacks still run) |
| `p?`, `p*`, `p+` | Optional, zero-or-more, one-or-more (possessive) |
| `p^n`, `p^+n`, `p^-n` | Exactly `n`, at least `n`, at most `n` (no space between `^` and `n`) |
| `%name` | Predefined locale class or supplied `Definition` |
| `name <- p`, `name`, `<name>` | Grammar rule (first rule is the start rule) and nonterminal reference |
| `%{label}`, `p^label` | Throw `label`, or `p / %{label}` (no space between `^` and `label`) |
| `{}`, `{ p }` | Position capture; whole-substring capture |
| `{: p :}`, `{:name: p :}` | Anonymous group capture; named group capture |
| `=name` | Match bytes equal to the latest named group's capture |
| `{| p |}`, `{~ p ~}` | Table capture; substitution capture |
| `p -> 0`, `p -> n`, `p -> 'tpl'`, `p -> {}`, `p -> name` | Discard, select (`1..32767`), `%0..%9` template, table, or defined query/callback capture |
| `p => name`, `p ~> name` | Match-time callback; fold capture callback |
| `-- ...` | Lua-style line comment |

Predefined C-locale classes are `alnum`, `alpha`, `cntrl`, `digit`, `graph`,
`lower`, `print`, `punct`, `space`, `upper`, and `xdigit`, with short aliases
`a c d g l p s u w x` (uppercase short forms are complements) and `nl` for LF.
Decimal labels such as `%{01}` produce the exact string `"01"`.

Invalid Relabel source raises a formatted error string with a label, byte
offset, line/column, source line, and caret:

```text
PEG syntax error [ExpPatt1] at L2:C7 (byte 19): expected a pattern after '/'
'a' /
      ^
```

When passing local Titan functions via `define_value`, compile the grammar in
the module's `do ... end` initializer:

```titan
local math = import "math"
local peg = import "peg"

local function parse_int(text: value): integer
  local n? = math.tointeger(text)
  return n or 0
end

local function add_total(acc: value, ...: value): value
  local sum = acc as integer
  for i = 1, #... do
    sum = sum + (...[i] as integer)
  end
  return sum
end

local SUM_PATTERN: peg.Pattern? = nil

function sum_numbers(input: string): integer?
  local result = SUM_PATTERN:match(input)
  if result == nil then return nil end
  return result as integer
end

do
  SUM_PATTERN = peg.compile([[
    Sum <- (Number (%s+ Number)*) ~> add !.
    Number <- {%d+} -> to_int
  ]], {
    peg.define_value("to_int", parse_int),
    peg.define_value("add", add_total),
  })
end
```

## Anchored matching and labeled-error recovery

```text
function Pattern:match(subject: string,
                       init: integer?,
                       ...: value): (value, ...: value)
```

`Pattern:match` attempts one anchored match at the normalized `init` position:

| Supplied `init` | Normalized start |
| --- | --- |
| `nil` or omitted | `1` |
| Positive `1..#subject + 1` | Supplied position |
| Positive `> #subject + 1` | `#subject + 1` |
| `0` | `#subject + 1` |
| Negative in range | `#subject + init + 1` |
| Negative overshoot | `1` |

`-1` selects the last byte, while `0` selects the position after the last byte
(unlike `titan.string` regexes, where `0` clamps to byte `1`). Extra arguments
after `init` are accessible through `peg.argument(n)`.

- **Success:** Returns the pattern's captures (preserving `nil` slots and exact
  arity), or the one-based position immediately after the match when the
  pattern has no captures. Because a pattern can legally capture `nil`, wrap
  arbitrary results in a non-`nil` envelope such as `{| ... |}` if you test
  `first_result == nil` for failure.
- **Ordinary failure:** Returns `nil, "fail", absolute_farthest_position`.
- **Uncaught label:** Returns `nil, label, absolute_throw_position`.

Inside a grammar, a rule whose name matches a thrown label acts as a **recovery
rule**: execution jumps to that rule at the throw position, and if the recovery
rule succeeds, matching resumes after the throwing expression. Throws inside
`&p` or `!p` become ordinary predicate failures instead of escaping. The
reserved label `"fail"` always triggers ordinary failure and never enters a
recovery rule.

```titan
local peg = import "peg"

local LIST_WITH_RECOVERY = peg.compile([[
  List    <- {| Item (';' Item)* ';'? !. |}
  Item    <- %s* (Word / %{bad_item}) %s*
  Word    <- {[A-Za-z]+}
  bad_item <- [^;]*
]])

function collect_valid_words(input: string): {string}
  local captured = LIST_WITH_RECOVERY:match(input)
  local result: {string} = {}
  if captured == nil then return result end
  local raw = captured as {integer: string}
  for i = 1, #raw do
    result[i] = raw[i]
  end
  return result
end
```

## Named combinator API

Use the named combinator functions when grammars must be constructed
dynamically at run time or need arbitrary binary rule/label names.

### Pattern constructors and grammars

```text
record Rule

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

| Function | Meaning |
| --- | --- |
| `literal(text)` | Match exact bytes; `""` succeeds without consuming input. |
| `any(count?)` | Default `1`. For `count >= 0`, consume `count` bytes; for `count < 0`, succeed without consuming if fewer than `-count` bytes remain. |
| `succeed()` | Succeed without consuming input. |
| `fail()` | Ordinary failure. |
| `runtime(callback)` | Run an immediate callback `(subject, pos, "")` at the current position. |
| `set(bytes)` | Match any single byte present in `bytes`. |
| `ranges(...: string)` | Match one byte in any inclusive 2-byte range (`"az"`, `"09"`); no arguments fails. |
| `utf_range(first, last)` | Match a UTF-8 encoding for a code point in `0 <= first <= last <= 0x10ffff` (including surrogate code-point encodings). |
| `variable(name)` | Reference a grammar rule by name (must be closed inside `grammar`). |
| `rule(name, pattern)` | Create a named or recovery grammar rule. |
| `grammar(start, rules)` | Close a dense `{Rule}` Array (unique names, `start` present, at most 1000 rules). |
| `behind(pattern)` | Non-consuming look-behind; `pattern` must be capture-free and fixed-length (at most 255 bytes). |
| `throw(label)` | Commit labeled failure `label` at the current position (`"fail"` equals `fail()`). |

Rule names and throw labels are exact binary strings (`""`, `"1"`, `"01"`, and
NUL-bearing strings are distinct).

### Composition and repetition

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

`sequence()` returns `succeed()`; `choice()` returns `fail()`; both left-fold
their arguments. `difference(a, b, c)` computes `(a - b) - c`. `lookahead` and
`negative` are non-consuming predicates: neither retains captures produced
inside `pattern` in the match result, though eager `runtime` and `match_time`
callbacks reached while evaluating `pattern` still execute. `at_least` and
`at_most` require nonnegative `count`; `zero_or_more(p)` is `at_least(p, 0)`,
`one_or_more(p)` is `at_least(p, 1)`, and `optional(p)` is `at_most(p, 1)`.

```titan
local peg = import "peg"

function balanced_parens(): peg.Pattern
  local text = peg.one_or_more(peg.difference(peg.any(), peg.set("()")))
  local rules: {peg.Rule} = {
    peg.rule("Start", peg.sequence(
      peg.variable("Balanced"), peg.negative(peg.any()))),
    peg.rule("Balanced", peg.sequence(
      peg.literal("("),
      peg.zero_or_more(peg.choice(text, peg.variable("Balanced"))),
      peg.literal(")"))),
  }
  return peg.grammar("Start", rules)
end
```

### Captures and callbacks

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
function query_capture(pattern: Pattern, lookup: {value: value}): Pattern
function function_capture(
  pattern: Pattern,
  callback: function (value, ...: value): (...: value)
): Pattern
```

- `capture(p)` yields the whole matched substring followed by any nested
  captures.
- `constant(...)` yields constant values without consuming input; `position()`
  yields the current one-based byte position; `argument(n)` (`1..32767`) yields
  the `n`-th extra match argument (raising if absent).
- `group(p, nil)` (or `group(p)`) creates an anonymous group yielding nested
  captures (or the whole substring if none). A non-`nil` `key` creates a named
  group with no direct output; `back_capture(key)` yields the latest matching
  named group's captures (raising if missing).
- `table_capture(p)` collects anonymous captures at consecutive integer keys
  and the first value of each named group at its key.
- `substitution(p)` replaces captured spans and copies unmatched bytes.
- `select_capture(p, index)` discards nested captures when `index == 0` or
  selects capture `index` (`1..32767`).
- `template_capture(p, template)` expands `%0` (whole substring) through `%9`
  (nested captures).
- `query_capture(p, lookup)` looks up the first nested capture (or whole
  substring) in `lookup`, honoring `__index`.
- `function_capture(p, callback)` calls `callback` with nested captures (or
  whole substring); every returned value becomes a capture.
- `fold_capture(p, callback)` uses the first nested capture as the accumulator
  and calls `callback(acc, next...)` for each remaining capture operation,
  returning the single updated accumulator (raises if `p` produces no initial
  capture).

When `p` produces no nested capture, implicit defaults apply:

| Operation | Behavior without nested captures |
| --- | --- |
| Anonymous `group(p)` | Yields whole substring |
| Named `group(p, key)` + `back_capture(key)` | Group yields nothing; `back_capture` yields whole substring |
| `query_capture`, `function_capture`, `select_capture(p, 1)` | Uses whole substring |
| `select_capture(p, 0)` | No capture |
| `template_capture(p, "%0")` / `template_capture(p, "%1")` | Whole substring / raises error |
| `table_capture(p)` | Empty table |
| `fold_capture(p, callback)` | Raises error (no initial accumulator) |

**Callback timing and rules:**

- `runtime` and `match_time` execute immediately while matching (and may run on
  alternatives that later fail). `match_time` receives
  `(subject, pos_after_p, nested_captures_or_whole...)`. Their first return
  value controls the match: `nil`, `false`, or no result fails; `true` succeeds
  at the current position; an integer in `current_pos..#subject + 1` succeeds
  at that position; remaining return values become captures.
- `function_capture` and `fold_capture` are delayed until capture evaluation
  and do not run on abandoned branches. Do not rely on exactly-once side
  effects in capture callbacks.
- All callbacks are non-yieldable and propagate errors directly. Titan
  functions, Lua functions, C functions, and `__call` values are accepted; a
  non-callable value raises only if invoked.

## Locale, version, and engine limits

```text
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

function locale(): Locale
function set_max_stack(maximum: integer)
function version(): string
```

`locale()` snapshots the current C-locale character classes into a `Locale`
record (subsequent `os.setlocale` calls do not mutate existing snapshots).
`set_max_stack(maximum)` configures the match execution stack for the current
Lua state (`1..21474836`). `version()` returns `"LPegLabel 1.6.1"`.

| Limit | Value |
| --- | --- |
| Constructed pattern tree slots | 32,757 |
| Look-behind fixed width (`behind`) | 255 bytes |
| Grammar rules | 1,000 |
| `argument` index | `1..32,767` |
| `select_capture` index | `0..32,767` |
| Match stack (`set_max_stack`) | `1..21,474,836` |
| Variadic match arguments / public results | 200 |
